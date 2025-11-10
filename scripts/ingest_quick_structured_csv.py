import os, io, sys, uuid, csv
from pathlib import Path
from typing import List, Dict
from tqdm import tqdm

from sentence_transformers import SentenceTransformer
from qdrant_client import QdrantClient
from qdrant_client.http.models import Distance, VectorParams, PointStruct

# -------- Config --------
HOST = os.getenv("QDRANT_HOST", "127.0.0.1")
PORT = int(os.getenv("QDRANT_PORT", "6333"))
COLL = os.getenv("QDRANT_COLLECTION", "rmsg_docs")
MODEL_NAME = os.getenv("EMBED_MODEL", "all-MiniLM-L6-v2")  # 384-dims
DIM = 384

ROOT = Path(__file__).resolve().parents[1]
TARGET_CSV = ROOT / "festivos.csv"

def read_festivos_rows(p: Path):
    rows = []
    with open(p, "r", encoding="utf-8", errors="ignore", newline="") as f:
        rdr = csv.DictReader(f)
        idx = 0
        for row in rdr:
            # Campos esperados por tus pruebas
            summary  = (row.get("summary") or "").strip()
            start    = (row.get("start") or "").strip()
            end      = (row.get("end") or "").strip()
            htmlLink = (row.get("htmlLink") or "").strip()
            # Texto para embedding: breve y estable
            text = " | ".join([x for x in [summary, start, end] if x])
            payload = {
                "source_path": str(p),
                "title": p.stem,
                "ext": p.suffix.lower(),
                "row_index": idx,
                # Campos estructurados
                "summary": summary or None,
                "start": start or None,
                "end": end or None,
                "htmlLink": htmlLink or None,
                "text": text,
            }
            rows.append(payload)
            idx += 1
    return rows

def main():
    if not TARGET_CSV.exists():
        print(f"[ingest-structured] No existe {TARGET_CSV}. Nada que hacer.")
        return

    print(f"[ingest-structured] Conectando a Qdrant {HOST}:{PORT} …")
    qc = QdrantClient(host=HOST, port=PORT)

    # crea coleccion si no existe
    try:
        qc.get_collection(COLL)
        print(f"[ingest-structured] Colección '{COLL}' ya existe.")
    except Exception:
        print(f"[ingest-structured] Creando colección '{COLL}' …")
        qc.create_collection(
            collection_name=COLL,
            vectors_config=VectorParams(size=DIM, distance=Distance.COSINE),
        )

    print(f"[ingest-structured] Leyendo filas de {TARGET_CSV.name} …")
    rows = read_festivos_rows(TARGET_CSV)
    print(f"[ingest-structured] Filas a upsertear: {len(rows)}")

    if not rows:
        print("[ingest-structured] 0 filas. Saliendo.")
        return

    print(f"[ingest-structured] Cargando modelo {MODEL_NAME} …")
    model = SentenceTransformer(MODEL_NAME)

    BATCH = 128
    batch = []

    def flush(items):
        if not items:
            return
        texts = [it.get("text") or "" for it in items]
        vectors = model.encode(texts, convert_to_numpy=True)
        pts = []
        for vec, pl in zip(vectors, items):
            pid = int(uuid.uuid4().int % 1_000_000_000_000_000)
            pts.append(PointStruct(id=pid, vector=vec.tolist(), payload=pl))
        qc.upsert(collection_name=COLL, points=pts)

    print("[ingest-structured] Upsert a Qdrant …")
    for it in tqdm(rows):
        batch.append(it)
        if len(batch) >= BATCH:
            flush(batch)
            batch.clear()
    flush(batch)

    try:
        cnt = qc.count(COLL, exact=True).count
        print(f"[ingest-structured] Listo. Total puntos en '{COLL}': {cnt}")
    except Exception:
        print("[ingest-structured] Listo. (No se pudo leer el conteo)")

if __name__ == "__main__":
    main()
