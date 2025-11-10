import os, re, importlib, inspect, sys, pathlib, shutil

def find_app_module():
    # 1) APP_MODULE (formato "main:app"), 2) candidatos comunes, 3) escaneo /app
    cand = (os.getenv("APP_MODULE") or "main:app").split(":",1)[0]
    candidates = [cand, "main", "app", "api", "server", "api.main", "app.main", "src.main", "src.api"]
    seen=set()
    for name in [c for c in candidates if c]:
        if name in seen: continue
        seen.add(name)
        try:
            m = importlib.import_module(name)
            if hasattr(m, "app"):
                return name, m
        except Exception:
            pass
    # Escanear /app buscando FastAPI y variable app
    for p in pathlib.Path("/app").rglob("*.py"):
        try:
            src = p.read_text(encoding="utf-8", errors="ignore")
        except Exception:
            continue
        if "FastAPI(" in src and re.search(r"\bapp\s*=\s*FastAPI\(", src):
            modname = str(p.relative_to("/app"))[:-3].replace("\\","/").replace("/",".")
            try:
                m = importlib.import_module(modname)
                if hasattr(m, "app"):
                    return modname, m
            except Exception:
                pass
    return None, None

modname, m = find_app_module()
if not m:
    print("NO_MODULE"); sys.exit(2)

path = inspect.getsourcefile(m) or ("/app/"+modname.replace(".","/")+".py")
print("TARGET_FILE="+path)

with open(path, "r", encoding="utf-8", errors="ignore") as f:
    src = f.read()

changed = False

# 1) Import del router si falta
if "from rag import rag_router" not in src:
    if re.search(r"from\s+fastapi\s+import\s+FastAPI", src):
        src = re.sub(r"(from\s+fastapi\s+import\s+FastAPI[^\n]*\n)", r"\1from rag import rag_router\n", src, count=1)
    else:
        src = "from rag import rag_router\n" + src
    changed = True

# 2) include_router si falta (lo añadimos al final)
if "include_router(rag_router" not in src:
    src = src.rstrip() + "\n\napp.include_router(rag_router, prefix='/rag', tags=['rag'])\n"
    changed = True

# Backup + write
bk = path + ".bak.rag"
try:
    shutil.copy2(path, bk)
    print("BACKUP="+bk)
except Exception as e:
    print("BACKUP_FAIL="+str(e))

with open(path, "w", encoding="utf-8") as f:
    f.write(src)

print("CHANGED="+str(changed))
