import io, re

p = "/app/main.py"
src = open(p, "r", encoding="utf-8", errors="ignore").read()
changed = False

block = """
# --- force UTF-8 for JSON responses ---
from fastapi.responses import JSONResponse as _JSONResponse

class _UTF8JSONResponse(_JSONResponse):
    media_type = "application/json; charset=utf-8"

@app.middleware("http")
async def _force_utf8_json(request, call_next):
    resp = await call_next(request)
    ct = resp.headers.get("content-type","")
    if ct.startswith("application/json") and "charset=" not in ct:
        resp.headers["content-type"] = "application/json; charset=utf-8"
    return resp
# --- end utf-8 patch ---
"""

if "_force_utf8_json" not in src:
    # Inserta justo despu?s de 'app = FastAPI()' si existe; si no, lo agrega al final
    if "app = FastAPI()" in src:
        src = src.replace("app = FastAPI()", "app = FastAPI()\n" + block, 1)
    else:
        src = src + "\n" + block
    changed = True

open(p + ".bak.utf8", "w", encoding="utf-8").write(src)
open(p, "w", encoding="utf-8").write(src)
print("CHANGED_UTF8=", changed)
