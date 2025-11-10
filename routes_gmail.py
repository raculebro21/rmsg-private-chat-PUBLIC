from fastapi import APIRouter, HTTPException
from pydantic import BaseModel
import os, base64, re
from email.header import decode_header, make_header
from google.oauth2.credentials import Credentials
from googleapiclient.discovery import build

router = APIRouter()  # <<< SIN prefijo aquí

SCOPES = ["https://www.googleapis.com/auth/gmail.readonly"]
TOKEN_PATH = "/app/secrets/google/tokens/gmail_token.json"

class ListReq(BaseModel):
    query: str = ""
    max: int = 10
    pageToken: str | None = None

class GetReq(BaseModel):
    id: str

class GetBodyReq(BaseModel):
    id: str

class GetAttachmentReq(BaseModel):
    message_id: str
    attachment_id: str

def _gmail_service():
    if not os.path.exists(TOKEN_PATH):
        raise HTTPException(status_code=400, detail="Token de Gmail no encontrado en /app/secrets/google/tokens/gmail_token.json")
    creds = Credentials.from_authorized_user_file(TOKEN_PATH, SCOPES)
    return build("gmail", "v1", credentials=creds, cache_discovery=False)

def _b64url_to_bytes(data: str) -> bytes:
    if not data: return b""
    padding = "=" * (-len(data) % 4)
    return base64.urlsafe_b64decode(data + padding)

def _pick_charset(headers: list[dict]) -> str | None:
    for h in headers or []:
        if h.get("name","").lower()=="content-type":
            v = h.get("value","")
            m = re.search(r'charset= *"?([^";]+)', v, flags=re.I)
            if m: return m.group(1).strip().lower()
    return None

def _looks_mojibake(s: str) -> bool:
    return ("Ã" in s) or ("Â" in s)

def _decode_bytes(raw: bytes, preferred: str | None) -> str:
    for enc in [preferred, "utf-8", "latin-1", "windows-1252"]:
        if not enc: continue
        try:
            txt = raw.decode(enc)
            if _looks_mojibake(txt):
                try:
                    fixed = txt.encode("latin-1","ignore").decode("utf-8","ignore")
                    if not _looks_mojibake(fixed): return fixed
                except: pass
            return txt
        except: pass
    return raw.decode("utf-8","ignore")

def _normalize_html_charset(s: str) -> str:
    if not s: return s
    s = s.lstrip("\ufeff")
    s = re.sub(r'(?is)<meta[^>]+charset\s*=\s*["\']?[^"\'>]+["\']?[^>]*>', '', s)
    s = re.sub(r'(?is)<meta[^>]+http-equiv\s*=\s*["\']?Content-Type["\']?[^>]*>', '', s)
    meta = '<meta charset="utf-8">'
    if re.search(r'(?is)<html', s):
        if re.search(r'(?is)<head.*?>', s):
            return re.sub(r'(?is)<head.*?>', lambda m: m.group(0) + meta, s, count=1)
        else:
            return f'<!doctype html><head>{meta}</head>{s}'
    else:
        return f'<!doctype html><html><head>{meta}</head><body>{s}</body></html>'

def _decode_hdr(v: str | None) -> str | None:
    if not v: return v
    try:
        return str(make_header(decode_header(v)))
    except Exception:
        return v

def _extract_body(payload: dict):
    text, html = None, None
    attachments = []
    msg_level_headers = payload.get("headers", []) or []
    msg_level_charset = _pick_charset(msg_level_headers)

    def walk(p: dict):
        nonlocal text, html, attachments
        mime = p.get("mimeType","") or ""
        body = p.get("body",{}) or {}
        data = body.get("data")
        filename = p.get("filename") or ""
        headers = p.get("headers",[]) or []
        if data:
            raw = _b64url_to_bytes(data)
            charset = _pick_charset(headers) or msg_level_charset
            if mime == "text/plain" and text is None:
                text = _decode_bytes(raw, charset)
            elif mime == "text/html" and html is None:
                html = _decode_bytes(raw, charset)
        if filename and body.get("attachmentId"):
            attachments.append({
                "filename": filename,
                "attachmentId": body.get("attachmentId"),
                "size": body.get("size"),
                "mimeType": mime
            })
        for sp in p.get("parts",[]) or []:
            walk(sp)

    walk(payload or {})
    return text, html, attachments

@router.post("/list")
def list_messages(req: ListReq):
    svc = _gmail_service()
    params = dict(userId="me", q=(req.query or None), maxResults=req.max)
    if req.pageToken: params["pageToken"] = req.pageToken
    resp = svc.users().messages().list(**params).execute()

    items = []
    for m in resp.get("messages", []):
        detail = svc.users().messages().get(
            userId="me", id=m["id"], format="metadata",
            metadataHeaders=["Subject","From","Date"]
        ).execute()
        headers = {h["name"]: h["value"] for h in detail.get("payload",{}).get("headers",[])}
        items.append({
            "id": m["id"],
            "threadId": m.get("threadId"),
            "subject": _decode_hdr(headers.get("Subject")),
            "from": _decode_hdr(headers.get("From")),
            "date": headers.get("Date"),
            "snippet": detail.get("snippet"),
        })
    return {
        "messages": items,
        "resultSizeEstimate": resp.get("resultSizeEstimate"),
        "nextPageToken": resp.get("nextPageToken")
    }

@router.post("/get")
def get_message(req: GetReq):
    svc = _gmail_service()
    return svc.users().messages().get(userId="me", id=req.id, format="full").execute()

@router.post("/get_body")
def get_body(req: GetBodyReq):
    svc = _gmail_service()
    msg = svc.users().messages().get(userId="me", id=req.id, format="full").execute()
    payload = msg.get("payload", {}) or {}
    headers = {h["name"]: h["value"] for h in payload.get("headers", [])}
    text, html, attachments = _extract_body(payload)
    html_doc = _normalize_html_charset(html) if html else None
    return {
        "id": msg.get("id"),
        "threadId": msg.get("threadId"),
        "subject": _decode_hdr(headers.get("Subject")),
        "from": _decode_hdr(headers.get("From")),
        "date": headers.get("Date"),
        "text": text,
        "html": html,
        "html_doc": html_doc,
        "attachments": attachments,
        "snippet": msg.get("snippet"),
    }

@router.post("/attachment")
def get_attachment(req: GetAttachmentReq):
    svc = _gmail_service()
    att = svc.users().messages().attachments().get(userId="me", messageId=req.message_id, id=req.attachment_id).execute()
    raw = _b64url_to_bytes(att.get("data",""))
    data_b64 = base64.b64encode(raw).decode("ascii")
    msg = svc.users().messages().get(userId="me", id=req.message_id, format="full").execute()
    filename, mime = None, None
    def hunt(p):
        nonlocal filename, mime
        body = p.get("body",{}) or {}
        if body.get("attachmentId") == req.attachment_id:
            filename = p.get("filename"); mime = p.get("mimeType")
        for sp in p.get("parts",[]) or []: hunt(sp)
    hunt(msg.get("payload",{}) or {})
    return {"messageId": req.message_id, "attachmentId": req.attachment_id,
            "filename": filename, "mimeType": mime, "size": len(raw),
            "data_base64": data_b64}
