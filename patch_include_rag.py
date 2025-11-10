import re
p="/app/main.py"
src=open(p,"r",encoding="utf-8",errors="ignore").read()
changed=False

# Envuelve la PRIMERA aparición de app.include_router(rag_router, ...)
if "include_router(rag_router" in src and "if rag_router is not None" not in src:
    src = re.sub(
        r'^[ \t]*app\.include_router\(\s*rag_router[^\n]*\n',
        'if rag_router is not None:\n    app.include_router(rag_router, prefix="/rag", tags=["rag"])\n',
        src, count=1, flags=re.MULTILINE
    )
    changed=True

if changed:
    open(p+".bak.rag2","w",encoding="utf-8").write(src)
    open(p,"w",encoding="utf-8").write(src)

print("CHANGED_INCLUDE=", changed)
