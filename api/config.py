from pydantic import BaseModel
import os

class Settings(BaseModel):
    app_name: str = "RMSG Private Chat"
    version: str = os.getenv("APP_VERSION", "1.0.0")
    cors_allow_origins: list[str] = os.getenv(
        "CORS_ALLOW_ORIGINS",
        "http://localhost:3000,http://127.0.0.1:3000,*"
    ).split(",")

settings = Settings()
