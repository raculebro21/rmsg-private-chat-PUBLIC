from fastapi import APIRouter, Query
import os
from typing import List, Dict, Any

from sentence_transformers import SentenceTransformer
from qdrant_client import QdrantClient

router = APIRouter(prefix="/rag", tags=["rag"])

QDRANT_HOST = os.getenv("QDRANT_HOST", "host.docker.internal")
QDRANT_PORT = int(os.getenv("QDRANT_PORT", "6333"))
COLLECTION  = os.getenv("QDRANT_COLLECTION", "rmsg_docs")
MODEL_NAME  = os.getenv("EMBED_MODEL", "all-MiniLM-L6-v2")

_model = None
_client = None

def get_model():
    global _model
    if _model is None:
        _model = SentenceTransformer(MODEL_NAME)
    return _model

def get_client():
    global _client
    if _client is None:
        _client = QdrantClient(host=QDRANT_HOST, port=QDRANT_PORT)
    return _client

@router.get("/ask")
def ask(q: str = Query(..., min_length=1), k: int = 5) -> Dict[str, Any]:
    m = get_model()
    c = get_client()

    vec = m.encode([q])[0].tolist()
    hits = c.search(
        collection_name=COLLECTION,
        query_vector=vec,
        limit=k,
        with_payload=True
    )

    out: List[Dict[str, Any]] = []
    for h in hits:
        payload = h.payload or {}
        # devolvemos tanto algunos campos planos útiles como TODO el payload
        out.append({
            "score": float(h.score),
            "text": payload.get("text", ""),
            "source_path": payload.get("source_path"),
            "title": payload.get("title"),
            "chunk_index": payload.get("chunk_index") or payload.get("row_index"),
            "summary": payload.get("summary"),
            "start": payload.get("start"),
            "end": payload.get("end"),
            "htmlLink": payload.get("htmlLink"),
            "payload": payload,  # por si luego quieres más cosas
        })
    return {"query": q, "k": k, "hits": out}
# ---- RAG ops: status & export ----
from fastapi.responses import StreamingResponse, JSONResponse, PlainTextResponse
import io, csv

@router.get("/ingest/status")
def rag_ingest_status():
    c = get_client()
    # Hacemos un scroll para traer payloads en lotes y contar source_path en memoria.
    # Para colecciones grandes, convendría paginar externamente o filtrar por prefijo.
    limit = 1024
    next_page = None
    counts = {}
    total = 0
    while True:
        res = c.scroll(collection_name=COLLECTION, with_payload=True, limit=limit, offset=next_page)
        points, next_page = res[0], res[1]
        for p in points:
            total += 1
            sp = None
            try:
                sp = (p.payload or {}).get("source_path")
            except Exception:
                sp = None
            counts[sp] = counts.get(sp, 0) + 1
        if next_page is None:
            break
    # Ordenamos por conteo desc
    rows = [{"source_path": k, "count": v} for k, v in counts.items()]
    rows.sort(key=lambda r: r["count"], reverse=True)
    return {"collection": COLLECTION, "total": total, "by_source_path": rows}
from fastapi.responses import StreamingResponse
import io, csv

@router.get("/ask.csv")
def ask_csv(q: str = Query(..., min_length=1), k: int = 5):
    m = get_model()
    c = get_client()
    vec = m.encode([q])[0].tolist()
    hits = c.search(collection_name=COLLECTION, query_vector=vec, limit=k, with_payload=True)

    out = io.StringIO()
    writer = csv.writer(out)
    writer.writerow(["score","summary","start","end","htmlLink","title","chunk_index","source_path","text"])
    for h in hits:
        payload = h.payload or {}
        writer.writerow([
            float(h.score),
            (payload.get("summary") or ""),
            (payload.get("start") or ""),
            (payload.get("end") or ""),
            (payload.get("htmlLink") or ""),
            (payload.get("title") or ""),
            (payload.get("chunk_index") or ""),
            (payload.get("source_path") or ""),
            (payload.get("text") or "")
        ])
    out.seek(0)
    headers = {"Content-Disposition": f'attachment; filename="rag_{k}_hits.csv"'}
    return StreamingResponse(iter([out.getvalue()]), media_type="text/csv", headers=headers)
