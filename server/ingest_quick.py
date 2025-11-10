# server/ingest_quick.py
import os, json, uuid, argparse, urllib.request, urllib.error

def _json_req(url: str, obj: dict, method: str = "POST"):
    data = json.dumps(obj).encode("utf-8")
    req = urllib.request.Request(url, data=data, method=method,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req) as r:
        return json.loads(r.read().decode("utf-8"))

def _json_get(url: str):
    req = urllib.request.Request(url, method="GET")
    with urllib.request.urlopen(req) as r:
        return json.loads(r.read().decode("utf-8"))

def ensure_collection(qdrant_url: str, collection: str, size: int = 768, distance: str = "Cosine"):
    try:
        _json_get(f"{qdrant_url}/collections/{collection}")
        return
    except urllib.error.HTTPError as e:
        if e.code != 404:
            raise
    body = {"vectors": {"size": size, "distance": distance}}
    _json_req(f"{qdrant_url}/collections/{collection}", body, method="PUT")

def embed_text(ollama_url: str, model: str, text: str):
    # OJO: Ollama embeddings espera 'prompt', no 'input'
    res = _json_req(f"{ollama_url}/api/embeddings", {"model": model, "prompt": text}, method="POST")
    emb = res.get("embedding") or []
    if not emb:
        raise RuntimeError("Embedding vacío (¿usaste 'input' en lugar de 'prompt'?).")
    return emb

def upsert_points(qdrant_url: str, collection: str, points: list):
    body = {"points": points}
    return _json_req(f"{qdrant_url}/collections/{collection}/points?wait=true", body, method="PUT")

def count_namespace(qdrant_url: str, collection: str, namespace: str):
    body = {
        "exact": True,
        "filter": {"must": [{"key": "namespace", "match": {"value": namespace}}]}
    }
    res = _json_req(f"{qdrant_url}/collections/{collection}/points/count", body, method="POST")
    return (res.get("result") or {}).get("count", 0)

def main():
    parser = argparse.ArgumentParser(description="Ingesta rápida de textos a Qdrant usando embeddings de Ollama.")
    parser.add_argument("--namespace", required=True, help="Namespace (p.ej. rmsg_docs)")
    parser.add_argument("--collection", default=os.getenv("QDRANT_COLLECTION", "rmsg_docs"),
                        help="Colección de Qdrant (default: env QDRANT_COLLECTION o rmsg_docs)")
    parser.add_argument("--ollama", default=os.getenv("OLLAMA_URL", "http://ollama:11434"),
                        help="URL de Ollama (default: env OLLAMA_URL o http://ollama:11434)")
    parser.add_argument("--qdrant", default=os.getenv("QDRANT_URL", "http://qdrant:6333"),
                        help="URL de Qdrant (default: env QDRANT_URL o http://qdrant:6333)")
    parser.add_argument("--embed-model", default=os.getenv("EMBEDDINGS_MODEL", "nomic-embed-text"),
                        help="Modelo de embeddings en Ollama (default: env EMBEDDINGS_MODEL o nomic-embed-text)")
    parser.add_argument("--source", default="quick", help="Valor de payload.source (default: quick)")
    parser.add_argument("--text", action="append", help="Texto a ingestar (repetible: --text '...')")
    args = parser.parse_args()

    if not args.text:
        raise SystemExit("Debes pasar al menos un --text '...'. Puedes repetir la bandera para varios textos.")

    # 1) Asegurar colección
    ensure_collection(args.qdrant, args.collection, size=768, distance="Cosine")

    # 2) Embeddings + upsert
    points = []
    for t in args.text:
        emb = embed_text(args.ollama, args.embed_model, t)
        points.append({
            "id": str(uuid.uuid4()),
            "vector": emb,
            "payload": {
                "namespace": args.namespace,
                "source": args.source,
                "text": t,
                "content": t
            }
        })

    up_res = upsert_points(args.qdrant, args.collection, points)
    total = count_namespace(args.qdrant, args.collection, args.namespace)

    out = {
        "upserted": len(points),
        "operation": up_res.get("result", {}),
        "namespace": args.namespace,
        "collection": args.collection,
        "count_in_namespace": total
    }
    print(json.dumps(out, ensure_ascii=False, indent=2))

if __name__ == "__main__":
    main()
