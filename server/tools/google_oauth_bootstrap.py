import os, pathlib, json
from google_auth_oauthlib.flow import InstalledAppFlow

SCOPES = [
    "https://www.googleapis.com/auth/gmail.readonly",
    "https://www.googleapis.com/auth/drive.readonly",
]

def main():
    client_secret_path = os.environ.get("GOOGLE_OAUTH_CLIENT_SECRET_PATH", "/app/secrets/google/client_secret.json")
    token_dir = os.environ.get("GOOGLE_OAUTH_TOKEN_DIR", "/app/secrets/google/tokens")
    pathlib.Path(token_dir).mkdir(parents=True, exist_ok=True)

    # Modo consola (copia/pega URL y código)
    flow = InstalledAppFlow.from_client_secrets_file(client_secret_path, SCOPES)
    creds = flow.run_console()

    # Guarda tokens reutilizables
    token_path = os.path.join(token_dir, "gmail_token.json")
    with open(token_path, "w", encoding="utf-8") as f:
        f.write(creds.to_json())

    print(f"Tokens guardados en: {token_path}")

if __name__ == "__main__":
    main()
