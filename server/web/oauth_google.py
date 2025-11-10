from fastapi import APIRouter, Request, HTTPException
from fastapi.responses import HTMLResponse
import os, json, time
from pathlib import Path
from google_auth_oauthlib.flow import Flow
from google.oauth2.credentials import Credentials

router = APIRouter()

ROOT = Path(__file__).resolve().parents[2]
SECRETS = ROOT / "secrets" / "google"
TOKENS = SECRETS / "tokens"
TOKENS.mkdir(parents=True, exist_ok=True)

CLIENT_SECRETS_FILE = str(SECRETS / "client_secret.json")
TOKEN_FILE = os.getenv("GOOGLE_TOKEN_PATH", "secrets/google/tokens/google_token.json")
REDIRECT_URI = os.getenv("GOOGLE_OAUTH_REDIRECT_URI", "http://127.0.0.1:8089/oauth/callback")
SCOPES = (os.getenv("GOOGLE_SCOPES") or "").split()
STATE_FILE = TOKENS / "oauth_state.json"

def _save_json(p: Path, data: dict):
    p.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")

def _load_json(p: Path):
    return json.loads(p.read_text(encoding="utf-8")) if p.exists() else None

@router.get("/auth/status")
def auth_status():
    have = Path(TOKEN_FILE).exists()
    scopes_have = []
    if have:
        try:
            c = Credentials.from_authorized_user_file(TOKEN_FILE)
            scopes_have = sorted(list(c.scopes or []))
        except Exception:
            pass
    need = sorted(SCOPES)
    return {
        "token_file": TOKEN_FILE,
        "present": have,
        "scopes_have": scopes_have,
        "scopes_need": need,
        "ok": have and set(need).issubset(set(scopes_have)),
    }

@router.get("/oauth/url")
def oauth_url():
    if not SCOPES:
        raise HTTPException(500, "GOOGLE_SCOPES vacío en .env")
    flow = Flow.from_client_secrets_file(
        CLIENT_SECRETS_FILE,
        scopes=SCOPES,
        redirect_uri=REDIRECT_URI,
    )
    auth_url, state = flow.authorization_url(
        access_type="offline",
        include_granted_scopes="true",
        prompt="consent",
    )
    _save_json(STATE_FILE, {"state": state, "ts": time.time()})
    return {"auth_url": auth_url, "state": state, "redirect_uri": REDIRECT_URI, "scopes": SCOPES}

@router.get("/oauth/callback")
def oauth_callback(request: Request):
    q = dict(request.query_params)
    if "error" in q:
        return HTMLResponse(f"<h3>OAuth error:</h3><pre>{q['error']}</pre>", status_code=400)
    state_req = q.get("state")
    state_saved = _load_json(STATE_FILE) or {}
    if not state_saved or state_saved.get("state") != state_req:
        raise HTTPException(400, "state inválido (reintenta /oauth/url)")

    try:
        flow = Flow.from_client_secrets_file(
            CLIENT_SECRETS_FILE,
            scopes=SCOPES,
            redirect_uri=REDIRECT_URI,
        )
        flow.fetch_token(authorization_response=str(request.url))
        creds = flow.credentials
        Path(TOKEN_FILE).write_text(creds.to_json(), encoding="utf-8")
        return HTMLResponse("<h2>✅ Autorizado correctamente.</h2><p>Ya puedes cerrar esta pestaña.</p>")
    except Exception as e:
        return HTMLResponse(f"<h3>OAuth exchange error</h3><pre>{e}</pre>", status_code=500)



from googleapiclient.discovery import build

def _creds():
    from google.oauth2.credentials import Credentials
    return Credentials.from_authorized_user_file(TOKEN_FILE)

@router.get("/me")
def me():
    svc = build("oauth2", "v2", credentials=_creds())
    return svc.userinfo().get().execute()

@router.get("/gmail/threads")
def gmail_threads(max_items: int = 5):
    svc = build("gmail", "v1", credentials=_creds())
    r = svc.users().threads().list(userId="me", maxResults=max_items).execute()
    return r.get("threads", [])

@router.get("/drive/files")
def drive_files(max_items: int = 5):
    svc = build("drive", "v3", credentials=_creds())
    r = svc.files().list(pageSize=max_items, fields="files(id,name,mimeType,modifiedTime)").execute()
    return r.get("files", [])

@router.get("/calendar/events")
def calendar_events(
    max_items: int = 5,
    calendarId: str | None = None,
    timeMin: str | None = None,
    timeMax: str | None = None,
    q: str | None = None
):
    from datetime import datetime, timezone
    import traceback
    try:
        svc = build("calendar", "v3", credentials=_creds(), cache_discovery=False)
        cal_id = calendarId or "primary"

        # Si no envías timeMin, por defecto "ahora"
        if not timeMin:
            timeMin = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")

        kwargs = dict(
            calendarId=cal_id,
            maxResults=max_items,
            singleEvents=True,
            orderBy="startTime",
            timeMin=timeMin,
        )
        if timeMax:
            kwargs["timeMax"] = timeMax
        if q:
            kwargs["q"] = q

        r = svc.events().list(**kwargs).execute()
        return r.get("items", [])
    except Exception as e:
        import traceback
        return {"error": str(e), "trace": traceback.format_exc()}
    except Exception as e:
        return {"error": str(e), "trace": traceback.format_exc()}
@router.get("/calendar/_probe1")
def calendar_probe1():
    import traceback
    try:
        svc = build("calendar", "v3", credentials=_creds(), cache_discovery=False)
        return {"ok": True, "msg": "calendar service built"}
    except Exception as e:
        import traceback
        return {"ok": False, "stage": "build", "error": str(e), "trace": traceback.format_exc()}

@router.get("/calendar/_probe2")
def calendar_probe2():
    import traceback
    try:
        from datetime import datetime, timezone
        svc = build("calendar", "v3", credentials=_creds(), cache_discovery=False)
        now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
        req = svc.events().list(calendarId="primary", maxResults=1, singleEvents=True, orderBy="startTime", timeMin=now)
        # No ejecutamos .execute(), solo devolvemos el tipo del objeto para confirmar que se creó bien
        return {"ok": True, "req_type": str(type(req))}
    except Exception as e:
        return {"ok": False, "stage": "build+list", "error": str(e), "trace": traceback.format_exc()}

@router.get("/calendar/_probe3")
def calendar_probe3():
    import traceback
    try:
        from datetime import datetime, timezone
        svc = build("calendar", "v3", credentials=_creds(), cache_discovery=False)
        now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
        r = svc.events().list(calendarId="primary", maxResults=1, singleEvents=True, orderBy="startTime", timeMin=now).execute()
        return {"ok": True, "items_len": len(r.get("items", []))}
    except Exception as e:
        return {"ok": False, "stage": "execute", "error": str(e), "trace": traceback.format_exc()}

@router.get("/calendar/list")
def calendar_list(max_items: int = 100):
    import traceback
    try:
        svc = build("calendar", "v3", credentials=_creds(), cache_discovery=False)
        r = svc.calendarList().list(maxResults=max_items).execute()
        return r.get("items", [])
    except Exception as e:
        return {"error": str(e), "trace": traceback.format_exc()}

