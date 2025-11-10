import os, pathlib, http.server, socketserver, urllib.parse
from google_auth_oauthlib.flow import InstalledAppFlow

SCOPES = [
    "https://www.googleapis.com/auth/gmail.readonly",
    "https://www.googleapis.com/auth/drive.readonly",
]

REDIRECT = "http://localhost:8089/"

class CatchHandler(http.server.BaseHTTPRequestHandler):
    code = None
    def do_GET(self):
        qs = urllib.parse.urlparse(self.path).query
        params = urllib.parse.parse_qs(qs)
        CatchHandler.code  = (params.get("code") or [None])[0]
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"Autorizado. Ya puedes cerrar esta pesta\xc3\xb1a.")
    def log_message(self, *a, **k): pass

def main():
    client_secret_path = os.environ.get("GOOGLE_OAUTH_CLIENT_SECRET_PATH", "/app/secrets/google/client_secret.json")
    token_dir = os.environ.get("GOOGLE_OAUTH_TOKEN_DIR", "/app/secrets/google/tokens")
    pathlib.Path(token_dir).mkdir(parents=True, exist_ok=True)

    flow = InstalledAppFlow.from_client_secrets_file(client_secret_path, SCOPES)
    # Definimos UNA sola vez el redirect en el flow
    flow.redirect_uri = REDIRECT

    # ¡OJO! NO pasamos redirect_uri aquí: el flow ya lo sabe
    auth_url, _ = flow.authorization_url(
        access_type="offline",
        include_granted_scopes="true",
        prompt="consent select_account",
        login_hint=os.environ.get("LOGIN_HINT","")
    )

    print("\n=== ABRE ESTA URL EN INCOGNITO (UNA SOLA VEZ) ===\n")
    print(auth_url, "\n")
    print("Tras autorizar, Google volvera a", REDIRECT)

    # Servidor que captura el code UNA sola vez
    with socketserver.TCPServer(("0.0.0.0", 8089), CatchHandler) as httpd:
        httpd.handle_request()

    if not CatchHandler.code:
        raise SystemExit("No se recibi\xc3\xb3 'code' en el callback")

    # ¡Clave! NO volver a pasar redirect_uri aquí
    flow.fetch_token(code=CatchHandler.code)
    creds = flow.credentials

    token_path = os.path.join(token_dir, "gmail_token.json")
    with open(token_path, "w", encoding="utf-8") as f:
        f.write(creds.to_json())
    print(f"\nTokens guardados en: {token_path}\n")

if __name__ == "__main__":
    main()
