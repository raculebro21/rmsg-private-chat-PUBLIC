import pytest
import os
os.environ.setdefault("APP_VERSION", "test-1.0")

from fastapi.testclient import TestClient
from api.main import app

client = TestClient(app)

def test_health_ok():
    r = client.get("/health")
    assert r.status_code == 200
    assert r.json().get("status") == "ok"

def test_version():
    r = client.get("/version")
    assert r.status_code == 200
    body = r.json()
    assert body.get("version") == "test-1.0"
