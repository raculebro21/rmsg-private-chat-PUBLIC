import json, urllib.request

def post_json(url, obj):
    data = json.dumps(obj).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers={"Content-Type":"application/json"})
    with urllib.request.urlopen(req) as r:
        return json.loads(r.read().decode("utf-8"))

ollama = "http://ollama:11434"
qdrant = "http://qdrant:6333"

q = "línea de pintura Kroma en Chihuahua"

# 1) Embedding (Ollama espera 'prompt', no 'input')
emb = post_json(ollama + "/api/embeddings", {"model":"nomic-embed-text","prompt": q})["embedding"]

# 2) Búsqueda en Qdrant filtrando por namespace (y opcionalmente source)
body = {
  "vector": emb,
  "limit": 3,
  "with_payload": True,
  "filter": {
    "must": [
      { "key": "namespace", "match": { "value": "rmsg_docs" } },
      # descomenta si quieres forzar solo las notas manuales:
      # { "key": "source", "match": { "value": "manual" } }
    ]
  }
}

res = post_json(qdrant + "/collections/rmsg_docs/points/search", body)
print(json.dumps(res, ensure_ascii=False, indent=2))
