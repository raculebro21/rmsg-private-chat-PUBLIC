import os, io, sys, uuid, csv
from pathlib import Path
from typing import List, Dict
from tqdm import tqdm

from sentence_transformers import SentenceTransformer
from qdrant_client import QdrantClient
from qdrant_client.http.models import Distance, VectorParams, PointStruct

# -------- Config --------
HOST = "127.0.0.1"
PORT = 6333
COLL = "rmsg_docs"
MODEL_NAME = "all-MiniLM-L6-v2"  # 384-dims
DIM = 384
CHUNK_SIZE = 800
CHUNK_OVERLAP = 120

ROOT = Path(__file__).resolve().parents[1]
DOC_DIRS = [ROOT / "quick_texts", ROOT / "content"]
EXTRA_FILES = [
    ROOT / "festivos.csv",               # generado antes
]
# Si quieres agregar exports, descomenta:
# EXTRA_FILES += [ROOT / "exports" / "gmail.txt", ROOT / "exports" / "drive.txt"]

# -------- Helpers --------
def read_text_file(p: Path) -> str:
    return p.read_text(encoding="utf-8", errors="ignore")

def read_md_file(p: Path) -> str:
    # simple: lee como texto, sin convertir a HTML
    return p.read_text(encoding="utf-8", errors="ignore")

def read_pdf_file(p: Path) -> str:
    from pypdf import PdfReader
    out = []
    with open(p, "rb") as f:
        r = PdfReader(f)
        for page in r.pages:
            try:
                out.append(page.extract_text() or "")
            except Exception:
                out.append("")
    return "\n".join(out)

def read_docx_file(p: Path) -> str:
    import docx2txt
    return docx2txt.process(str(p)) or ""

def read_csv_file(p: Path) -> str:
    # Concatena filas como líneas; si tiene headers, usa DictReader
    try:
        with open(p, "r", encoding="utf-8", errors="ignore", newline="") as f:
            sniffer = csv.Sniffer()
            sample = f.read(2048)
            f.seek(0)
            has_header = False
            try:
                has_header = sniffer.has_header(sample)
            except Exception:
                pass
            f.seek(0)
            rows = []
            if has_header:
                for row in csv.DictReader(f):
                    # Toma los campos útiles si existen
                    vals = []
                    for k in ("summary","start","end","htmlLink","snippet","subject"):
                        if k in row and row[k]:
                            vals.append(f"{k}={row[k]}")
                    rows.append(" | ".join(vals) if vals else ", ".join(row.values()))
            else:
                reader = csv.reader(f)
                for row in reader:
                    rows.append(", ".join(row))
            return "\n".join(rows)
    except Exception as e:
        return ""

def chunk_text(text: str, size: int = CHUNK_SIZE, overlap: int = CHUNK_OVERLAP) -> List[str]:
    text = " ".join(text.split())
    if not text:
        return []
    chunks = []
    start = 0
    n = len(text)
    while start < n:
        end = min(n, start + size)
        chunks.append(text[start:end])
        if end == n:
            break
        start = max(0, end - overlap)
    return chunks

def load_file(path: Path) -> List[Dict]:
    ext = path.suffix.lower()
    try:
        if ext in [".txt"]:
            txt = read_text_file(path)
        elif ext in [".md", ".markdown"]:
            txt = read_md_file(path)
        elif ext in [".pdf"]:
            txt = read_pdf_file(path)
        elif ext in [".docx"]:
            txt = read_docx_file(path)
        elif ext in [".csv"]:
            txt = read_csv_file(path)
        else:
            return []
    except Exception:
        return []

    chs = chunk_text(txt)
    out = []
    for i, ch in enumerate(chs):
        out.append({
            "text": ch,
            "meta": {
                "source_path": str(path),
                "title": path.stem,
                "ext": ext,
                "chunk_index": i
            }
        })
    return out

def gather_documents() -> List[Dict]:
    files = []
    for d in DOC_DIRS:
        if d.exists():
            for p in d.rglob("*"):
                if p.is_file() and p.suffix.lower() in (".txt",".md",".markdown",".pdf",".docx",".csv"):
                    files.append(p)
    for p in EXTRA_FILES:
        if p.exists() and p.is_file():
            files.append(p)
    docs = []
    for p in files:
        docs.extend(load_file(p))
    return docs

# -------- Main --------
def main():
    print(f"[ingest] Conectando a Qdrant {HOST}:{PORT} …")
    qc = QdrantClient(host=HOST, port=PORT)

    # crear colección si no existe
    try:
        qc.get_collection(COLL)
        print(f"[ingest] Colección '{COLL}' ya existe.")
    except Exception:
        print(f"[ingest] Creando colección '{COLL}' …")
        qc.create_collection(
            collection_name=COLL,
            vectors_config=VectorParams(size=DIM, distance=Distance.COSINE),
        )

    print("[ingest] Cargando documentos…")
    docs = gather_documents()
    print(f"[ingest] Total chunks: {len(docs)}")

    if not docs:
        print("[ingest] No hay documentos para indexar.")
        return

    print(f"[ingest] Cargando modelo {MODEL_NAME} …")
    model = SentenceTransformer(MODEL_NAME)

    batch, points, id_counter = [], [], 0
    BATCH_SIZE = 128

    def flush(batch_items):
        nonlocal id_counter
        if not batch_items:
            return
        vectors = model.encode([it["text"] for it in batch_items], convert_to_numpy=True)
        pts = []
        for vec, it in zip(vectors, batch_items):
            pid = int(uuid.uuid4().int % 1_000_000_000_000_000)
            pts.append(PointStruct(id=pid, vector=vec.tolist(), payload=it["meta"] | {"text": it["text"]}))
        qc.upsert(collection_name=COLL, points=pts)

    print("[ingest] Indexando en Qdrant…")
    for it in tqdm(docs):
        batch.append(it)
        if len(batch) >= BATCH_SIZE:
            flush(batch)
            batch.clear()
    flush(batch)

    # conteo
    try:
        cnt = qc.count(COLL, exact=True).count
        print(f"[ingest] Listo. Puntos en '{COLL}': {cnt}")
    except Exception:
        print("[ingest] Listo. (No se pudo leer el conteo)")

if __name__ == "__main__":
    main()
