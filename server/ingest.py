# server/ingest.py
import os
import sys
import json
import uuid
import urllib.request

OLLAMA_URL = os.getenv("OLLAMA_URL", "http://ollama:11434")
QDRANT_URL = os.getenv("QDRANT_URL", "http://qdrant:6333")
QDRANT_COLLECTION = os.getenv("QDRANT_COLLECTION", "rmsg_docs")
EMBEDDINGS_MODEL = os.getenv("EMBEDDINGS_MODEL", os.getenv("EMBED_MODEL", "nomic-embed-text"))

def _post_json(url: str, obj: dict, timeout: int = 60) -> dict:
    data = json.dumps(obj).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8"))

def _put_json(url: str, obj: dict, timeout: int = 60) -> dict:
    data = json.dumps(obj).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"}, method="PUT")
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8"))

def _get_json(url: str, timeout: int = 30) -> dict:
    with urllib.request.urlopen(url, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8"))

def _embed(text: str) -> list:
    # OJO: Ollama embeddings espera 'prompt'
    resp = _post_json(f"{OLLAMA_URL}/api/embeddings", {"model": EMBEDDINGS_MODEL, "prompt": text})
    vec = resp.get("embedding", [])
    if not vec:
        raise RuntimeError("Embedding vacío")
    return vec

def _ensure_collection(size: int):
    # Si ya existe, no hace nada; si no, la crea con distancia Cosine
    try:
        _get_json(f"{QDRANT_URL}/collections/{QDRANT_COLLECTION}")
        return
    except Exception:
        pass
    body = {"vectors": {"size": size, "distance": "Cosine"}}
    _post_json(f"{QDRANT_URL}/collections/{QDRANT_COLLECTION}", body)

def upsert_texts(texts, namespace="rmsg_docs", source="manual"):
    # Detecta dimensiones automáticamente
    dims = len(_embed("hola"))
    _ensure_collection(dims)

    points = []
    for t in texts:
        vec = _embed(t)
        points.append({
            "id": str(uuid.uuid4()),
            "vector": vec,
            "payload": {
                "namespace": namespace,
                "source": source,
                "content": t,
                "text": t
            },
        })

    _put_json(f"{QDRANT_URL}/collections/{QDRANT_COLLECTION}/points?wait=true", {"points": points})

if __name__ == "__main__":
    # Pasa los textos como argumentos de línea de comandos
    if len(sys.argv) < 2:
        print('Uso: python ingest.py "texto 1" "texto 2" ...')
        sys.exit(1)
    upsert_texts(sys.argv[1:])
    print(f"Ingresados {len(sys.argv)-1} textos en '{QDRANT_COLLECTION}'.")
