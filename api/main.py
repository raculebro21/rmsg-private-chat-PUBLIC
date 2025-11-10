from typing import TYPE_CHECKING

# Carga robusta de settings: funciona al correr como script (uvicorn main:app)
# y también cuando se importa como paquete (from api.main import app).
if TYPE_CHECKING:
    # solo para tipos (evita que mypy se queje si 'config' no existe en un modo)
    from api.config import Settings as _Settings  # noqa: F401

try:
    from config import settings  # 
except ImportError:  # pragma: no cover
    from api.config import settings  # 

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

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


@app.get("/version")
def version():
    return {"app": settings.app_name, "version": settings.version}
