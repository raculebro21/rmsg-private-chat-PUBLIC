from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from config import settings

app = FastAPI(title=settings.app_name, version=settings.version)

app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.cors_allow_origins,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

@app.get("/health")
def health():
    return {"status": "ok"}

@app.get("/ready")
def ready():
    # Aquí podrías checar conexiones (Qdrant, etc.)
    return {"status": "ready"}

@app.get("/version")
def version():
    return {"app": settings.app_name, "version": settings.version}
