from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
import os, logging

app = FastAPI()
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"], allow_credentials=True,
    allow_methods=["*"], allow_headers=["*"],
)

@app.get("/health")
def health():
    return {"ok": True}

if os.path.isdir("static"):
    app.mount("/static", StaticFiles(directory="static", html=True), name="static")
else:
    logging.warning("Static dir not found; skipping /static mount")

# Import “defensivo”: si falla, no tumba la app
try:
    from .routes_gmail import router as gmail_router
    app.include_router(gmail_router, prefix="/gmail")
except Exception as e:
    logging.exception("No pude cargar server.routes_gmail (la app sigue viva): %s", e)
