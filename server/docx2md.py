import argparse, pathlib, re, sys
import docx2txt

def clean_text(t: str) -> str:
    t = t.replace("\r\n", "\n").replace("\r", "\n")
    t = re.sub(r"[ \t]+", " ", t)
    t = re.sub(r"\n{3,}", "\n\n", t)
    return t.strip()

def convert_one(docx_path: pathlib.Path, out_dir: pathlib.Path):
    try:
        txt = docx2txt.process(str(docx_path)) or ""
        txt = clean_text(txt)
        out_dir.mkdir(parents=True, exist_ok=True)
        out_path = out_dir / (docx_path.stem + ".md")
        out_path.write_text(f"# {docx_path.stem}\n\n{txt}\n", encoding="utf-8")
        print(f"[ok] {docx_path.name} -> {out_path}")
    except Exception as e:
        print(f"[skip] {docx_path.name}: {e}", file=sys.stderr)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", required=True)
    ap.add_argument("--dst", required=True)
    args = ap.parse_args()

    src = pathlib.Path(args.src)
    dst = pathlib.Path(args.dst)
    files = sorted(src.rglob("*.docx"))
    if not files:
        print("[warn] No se encontraron .docx")
    for f in files:
        convert_one(f, dst)

if __name__ == "__main__":
    main()
