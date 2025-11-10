import argparse, pathlib, re
from pdfminer.high_level import extract_text

def clean_text(t: str) -> str:
    # normaliza saltos y espacios
    t = t.replace("\r\n", "\n").replace("\r", "\n")
    # une palabras cortadas por guión al final de línea: "indus-\ntrial" -> "industrial"
    t = re.sub(r"(\w)-\n(\w)", r"\1\2\n", t)
    # colapsa espacios múltiples
    t = re.sub(r"[ \t]+", " ", t)
    # colapsa líneas en blanco múltiples
    t = re.sub(r"\n{3,}", "\n\n", t)
    return t.strip()

def convert_one(pdf_path: pathlib.Path, out_dir: pathlib.Path, ext: str) -> None:
    try:
        txt = extract_text(str(pdf_path)) or ""
        txt = clean_text(txt)
        out_dir.mkdir(parents=True, exist_ok=True)
        out_path = out_dir / (pdf_path.stem + f".{ext}")
        header = f"# {pdf_path.stem}\n\n" if ext == "md" else ""
        out_path.write_text(header + txt, encoding="utf-8")
        print(f"[ok] {pdf_path.name} -> {out_path}")
    except Exception as e:
        print(f"[skip] {pdf_path.name}: {e}")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", required=True, help="Carpeta con PDFs")
    ap.add_argument("--dst", required=True, help="Carpeta destino para .md/.txt")
    ap.add_argument("--ext", choices=["md","txt"], default="md")
    args = ap.parse_args()

    src = pathlib.Path(args.src)
    dst = pathlib.Path(args.dst)
    pdfs = sorted(p for p in src.rglob("*.pdf"))
    if not pdfs:
        print("[warn] No se encontraron PDFs")
    for p in pdfs:
        convert_one(p, dst, args.ext)

if __name__ == "__main__":
    main()
