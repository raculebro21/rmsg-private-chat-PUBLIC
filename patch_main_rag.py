import re, io

p = "/app/main.py"
src = open(p, "r", encoding="utf-8", errors="ignore").read()
changed = False

# a) Import condicional para rag_router
if "from rag import rag_router" in src and "try:\n    from rag import rag_router" not in src:
    src = src.replace(
        "from rag import rag_router",
        "try:\n    from rag import rag_router\nexcept Exception as e:\n    rag_router = None\n    import logging as _l\n    _l.getLogger(__name__).warning(f\"RAG disabled: {e}\")"
    )
    changed = True
elif "rag_router = None" not in src:
    # Asegura que exista la variable si el import no está
    src = "rag_router = None\n" + src
    changed = True

# b) include_router condicional
if "include_router(rag_router" in src and "if rag_router is not None" not in src:
    # Convierte la primera aparición en bloque condicional
    src = re.sub(
        r"(\\n\\s*)app\\.include_router\\(\\s*rag_router(.*)\\)",
        r"\\1if rag_router is not None:\\n\\1    app.include_router(rag_router\\2)",
        src,
        count=1,
        flags=re.DOTALL
    )
    changed = True

if changed:
    open(p + ".bak.rag", "w", encoding="utf-8").write(src)
    open(p, "w", encoding="utf-8").write(src)

print("CHANGED_MAIN=", changed)
