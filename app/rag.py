from __future__ import annotations
import os, io, json, time, mimetypes, sqlite3, hashlib
from pathlib import Path
from typing import List, Dict, Any, Tuple

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

rag_router = APIRouter()

STATIC_DIR = Path(os.getenv("STATIC_DIR", "/app/static")).resolve()
RAG_DIR = Path(os.getenv("RAG_DIR", "/app/rag")).resolve()
RAG_DIR.mkdir(parents=True, exist_ok=True)

DB_PATH = Path(os.getenv("RAG_DB_PATH", str(RAG_DIR / "rag.sqlite")))
INDEX_PATH = Path(os.getenv("RAG_INDEX_PATH", str(RAG_DIR / "faiss.index")))
MODEL_NAME = os.getenv("RAG_MODEL_NAME", "intfloat/e5-base-v2")
EMB_DIM_DEFAULT = int(os.getenv("RAG_EMB_DIM", "768"))

# --- utils ligeras ---
def now_ts() -> float: return time.time()

def esc_segments_for_url(path_rel: Path) -> str:
    from urllib.parse import quote
    parts = []
    for seg in str(path_rel).replace("\\", "/").split("/"):
        parts.append(quote(seg, safe=""))
    return "/static/" + "/".join(parts)

def guess_mime(p: Path) -> str:
    mt, _ = mimetypes.guess_type(str(p))
    return mt or "application/octet-stream"

def file_sha1(p: Path) -> str:
    h = hashlib.sha1()
    with open(p, "rb") as f:
        while True:
            b = f.read(1 << 20)
            if not b: break
            h.update(b)
    return h.hexdigest()

def chunk_by_chars(text: str, max_len=800, overlap=200):
    text = text.replace("\x00", " ")
    n = len(text)
    if n <= max_len: return [(0, n, text)]
    chunks = []; start = 0
    while start < n:
        end = min(n, start + max_len)
        cut = text[start:end]
        last_nl = cut.rfind("\n\n")
        if last_nl > 300: end = start + last_nl
        chunks.append((start, end, text[start:end]))
        if end >= n: break
        start = max(0, end - overlap)
    return chunks

# ---- lazy loaders ----
_EMBED = None
_EMB_DIM = None
def _np():
    try:
        import numpy as _np_  # lazy
        return _np_
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"numpy no disponible: {e}")

def _get_embedder():
    global _EMBED, _EMB_DIM
    if _EMBED is not None: return _EMBED
    try:
        from sentence_transformers import SentenceTransformer  # lazy
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"sentence-transformers no disponible: {e}")
    _EMBED = SentenceTransformer(MODEL_NAME)
    try:
        v = _EMBED.encode(["__probe__"], normalize_embeddings=True)
        _EMB_DIM = int(v.shape[1])
    except Exception:
        _EMB_DIM = EMB_DIM_DEFAULT
    try: (RAG_DIR / "emb_dim.txt").write_text(str(_EMB_DIM))
    except Exception: pass
    return _EMBED

def _emb_dim():
    global _EMB_DIM
    if _EMB_DIM is not None: return _EMB_DIM
    try:
        _EMB_DIM = int((RAG_DIR / "emb_dim.txt").read_text().strip())
        return _EMB_DIM
    except Exception:
        return EMB_DIM_DEFAULT

# ---- SQLite helpers ----
def with_conn(fn):
    def _wrap(*a, **k):
        conn = sqlite3.connect(str(DB_PATH))
        conn.execute("PRAGMA journal_mode=WAL;")
        conn.execute("PRAGMA synchronous=NORMAL;")
        try:
            r = fn(conn, *a, **k); conn.commit(); return r
        finally:
            conn.close()
    return _wrap

@with_conn
def init_db(conn: sqlite3.Connection):
    conn.execute("""
    CREATE TABLE IF NOT EXISTS documents(
      id INTEGER PRIMARY KEY,
      path_abs TEXT UNIQUE,
      path_rel TEXT,
      web_url TEXT,
      mtime REAL,
      size INTEGER,
      sha1 TEXT,
      mime TEXT,
      title TEXT,
      source TEXT,
      author TEXT,
      created_at REAL,
      extra TEXT
    );""")
    conn.execute("""
    CREATE TABLE IF NOT EXISTS chunks(
      id INTEGER PRIMARY KEY,
      doc_id INTEGER REFERENCES documents(id) ON DELETE CASCADE,
      chunk_index INTEGER,
      text TEXT,
      start_char INTEGER,
      end_char INTEGER,
      n_chars INTEGER,
      embedding BLOB
    );""")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_chunks_doc ON chunks(doc_id);")

def np_to_blob(x) -> bytes:
    np = _np()
    return np.asarray(x, dtype=np.float32).tobytes(order="C")

@with_conn
def upsert_document(conn: sqlite3.Connection, meta: Dict[str, Any]) -> int:
    cur = conn.execute("SELECT id, sha1, mtime, size FROM documents WHERE path_abs=?", (meta["path_abs"],))
    row = cur.fetchone()
    if row:
        doc_id, sha1_old, mtime_old, size_old = row
        if sha1_old == meta["sha1"] and mtime_old == meta["mtime"] and size_old == meta["size"]:
            return doc_id
        conn.execute("""
          UPDATE documents
          SET path_rel=?, web_url=?, mtime=?, size=?, sha1=?, mime=?, title=?, source=?, author=?, created_at=?, extra=?
          WHERE id=?""",
          (meta["path_rel"], meta["web_url"], meta["mtime"], meta["size"], meta["sha1"], meta["mime"],
           meta.get("title"), meta.get("source","static"), meta.get("author"),
           meta.get("created_at", now_ts()), json.dumps(meta.get("extra", {})), doc_id))
        conn.execute("DELETE FROM chunks WHERE doc_id=?", (doc_id,))
        return doc_id
    else:
        cur = conn.execute("""
          INSERT INTO documents(path_abs, path_rel, web_url, mtime, size, sha1, mime, title, source, author, created_at, extra)
          VALUES (?,?,?,?,?,?,?,?,?,?,?,?)""",
          (meta["path_abs"], meta["path_rel"], meta["web_url"], meta["mtime"], meta["size"], meta["sha1"],
           meta["mime"], meta.get("title"), meta.get("source","static"), meta.get("author"),
           meta.get("created_at", now_ts()), json.dumps(meta.get("extra", {}))))
        return cur.lastrowid

@with_conn
def insert_chunks(conn: sqlite3.Connection, doc_id: int, chunks: List[Dict[str, Any]]):
    conn.executemany("""
      INSERT INTO chunks(doc_id, chunk_index, text, start_char, end_char, n_chars, embedding)
      VALUES (?,?,?,?,?,?,?)""",
      [(doc_id, c["chunk_index"], c["text"], c["start"], c["end"], len(c["text"]), np_to_blob(c["emb"])) for c in chunks])

@with_conn
def fetch_all_chunk_vectors(conn: sqlite3.Connection):
    np = _np()
    rows = conn.execute("SELECT id, embedding FROM chunks ORDER BY id ASC").fetchall()
    if not rows:
        return np.zeros((0, _emb_dim()), dtype=np.float32), []
    vecs = np.vstack([np.frombuffer(r[1], dtype=np.float32).reshape(1, _emb_dim()) for r in rows])
    ids = [r[0] for r in rows]
    return vecs, ids

@with_conn
def chunks_by_ids(conn: sqlite3.Connection, ids: List[int]) -> List[Dict[str, Any]]:
    if not ids: return []
    qmarks = ",".join(["?"] * len(ids))
    rows = conn.execute(f"""
      SELECT c.id, c.doc_id, c.chunk_index, c.text, c.start_char, c.end_char, d.path_rel, d.web_url, d.title, d.mime
      FROM chunks c
      JOIN documents d ON d.id = c.doc_id
      WHERE c.id IN ({qmarks})""", ids).fetchall()
    id2row = {}
    for r in rows:
        id2row[r[0]] = {
            "chunk_id": r[0], "doc_id": r[1], "chunk_index": r[2],
            "text": r[3] or "", "start": r[4], "end": r[5],
            "path_rel": r[6], "web_url": r[7], "title": r[8], "mime": r[9],
        }
    return [id2row[i] for i in ids if i in id2row]

# ---- FAISS helpers ----
def save_faiss(index, ids: List[int]):
    import faiss
    faiss.write_index(index, str(INDEX_PATH))
    (RAG_DIR / "faiss_ids.json").write_text(json.dumps(ids))

def load_faiss():
    import faiss, json
    if not INDEX_PATH.exists(): raise FileNotFoundError("faiss.index not found")
    index = faiss.read_index(str(INDEX_PATH))
    ids = json.loads((RAG_DIR / "faiss_ids.json").read_text())
    return index, ids

def rebuild_faiss_from_sqlite():
    import faiss
    vecs, ids = fetch_all_chunk_vectors()
    dim = _emb_dim()
    index = faiss.IndexFlatIP(dim)
    if vecs.shape[0] > 0: index.add(vecs)
    save_faiss(index, ids)
    return {"vectors": int(vecs.shape[0]), "dim": dim}

# ---- extracción de texto (lazy OCR/libs) ----
def extract_text_from_pdf(p: Path) -> str:
    try:
        from pypdf import PdfReader
        reader = PdfReader(str(p))
        content = []
        for pg in reader.pages:
            txt = (pg.extract_text() or "") if pg else ""
            content.append(txt)
        txt_all = "\n".join(content).strip()
        if len(txt_all) >= 200: return txt_all
    except Exception:
        pass
    try:
        from pdf2image import convert_from_path
        import pytesseract
        images = convert_from_path(str(p))
        ocr_all = [pytesseract.image_to_string(img) for img in images]
        return "\n".join(ocr_all)
    except Exception:
        return ""

def extract_text_from_image(p: Path) -> str:
    try:
        from PIL import Image
        import pytesseract
        img = Image.open(str(p))
        return pytesseract.image_to_string(img)
    except Exception:
        return ""

def extract_text_generic(p: Path) -> str:
    mt = guess_mime(p)
    if mt == "application/pdf": return extract_text_from_pdf(p)
    elif mt and mt.startswith("image/"): return extract_text_from_image(p)
    elif mt and mt.startswith("text/"):
        try: return p.read_text(encoding="utf-8", errors="ignore")
        except Exception: return ""
    else: return ""

# ---- Schemas & endpoints ----
class IngestRequest(BaseModel):
    base_dir: str | None = None
    glob: str | None = None
    exts: List[str] | None = None
    reindex: bool | None = False

@rag_router.get("/stats")
def rag_stats():
    init_db()
    conn = sqlite3.connect(str(DB_PATH))
    try:
        docs = conn.execute("SELECT COUNT(*) FROM documents").fetchone()[0]
        chks = conn.execute("SELECT COUNT(*) FROM chunks").fetchone()[0]
    finally:
        conn.close()
    present = INDEX_PATH.exists()
    return {"docs": docs, "chunks": chks, "faiss_index_present": present, "emb_dim": _emb_dim()}

@rag_router.post("/ingest")
def rag_ingest(req: IngestRequest):
    init_db()
    base = Path(req.base_dir or STATIC_DIR).resolve()
    if not str(base).startswith(str(STATIC_DIR)): base = STATIC_DIR
    patterns = req.glob or "**/*"
    val_exts = set((req.exts or ["pdf","png","jpg","jpeg","txt","md"]))
    files = [p for p in base.glob(patterns) if p.is_file() and p.suffix.lower().strip(".") in val_exts]
    if not files: return {"ingested": 0, "reindexed": False, "notes": "No se encontraron archivos candidatos."}

    try: EMB = _get_embedder()
    except HTTPException as e: raise e
    except Exception as e: raise HTTPException(status_code=500, detail=f"No se pudo inicializar el embedder: {e}")

    np = _np()
    total_chunks = 0
    for f in files:
        rel = f.relative_to(STATIC_DIR)
        web_url = esc_segments_for_url(rel)
        meta = {
            "path_abs": str(f.resolve()), "path_rel": str(rel), "web_url": web_url,
            "mtime": f.stat().st_mtime, "size": f.stat().st_size, "sha1": file_sha1(f),
            "mime": guess_mime(f), "title": f.stem, "source": "static", "created_at": now_ts(), "extra": {}
        }
        doc_id = upsert_document(meta)
        txt = extract_text_generic(f) or ""
        if not txt.strip():
            emb = np.zeros((_emb_dim(),), dtype=np.float32)
            ch = [{"chunk_index": 0, "text": "", "start": 0, "end": 0, "emb": emb}]
            insert_chunks(doc_id, ch); total_chunks += 1; continue
        chs = []
        for idx,(s,e,chunk) in enumerate(chunk_by_chars(txt, 800, 200)):
            emb = EMB.encode([chunk], normalize_embeddings=True)[0]
            chs.append({"chunk_index": idx, "text": chunk, "start": s, "end": e, "emb": emb})
        insert_chunks(doc_id, chs); total_chunks += len(chs)
    stats = rebuild_faiss_from_sqlite()
    return {"ingested": len(files), "chunks": total_chunks, "faiss": stats}

class QueryRequest(BaseModel):
    q: str
    top_k: int = 5

@rag_router.post("/query")
def rag_query(req: QueryRequest):
    try: import faiss
    except Exception as e: raise HTTPException(status_code=500, detail=f"FAISS no disponible: {e}")
    if not INDEX_PATH.exists(): raise HTTPException(status_code=400, detail="Índice FAISS no existe. Ejecuta /rag/ingest primero.")
    try:
        index, ids = load_faiss()
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"No se pudo cargar FAISS: {e}")
    try:
        EMB = _get_embedder()
        qv = EMB.encode([req.q], normalize_embeddings=True)
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"No se pudo obtener embedding de la consulta: {e}")
    D, I = index.search(qv, max(1, min(50, int(req.top_k or 5))))
    the_ids = [ids[i] for i in I[0] if 0 <= i < len(ids)]
    rows = chunks_by_ids(the_ids)
    hits = []
    for rank, (score, row) in enumerate(zip(D[0].tolist(), rows), start=1):
        snippet = row["text"] or ""
        if len(snippet) > 600: snippet = snippet[:600] + "…"
        hits.append({
            "rank": rank, "score": float(score),
            "path_rel": row["path_rel"], "web_url": row["web_url"],
            "title": row["title"], "mime": row["mime"],
            "chunk_id": row["chunk_id"], "chunk_index": row["chunk_index"],
            "excerpt": snippet
        })
    return {"q": req.q, "top_k": req.top_k, "hits": hits}

@rag_router.post("/rebuild")
def rag_rebuild():
    init_db(); stats = rebuild_faiss_from_sqlite(); return {"faiss": stats}
