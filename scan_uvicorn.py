import glob, os
for path in glob.glob("/proc/[0-9]*/cmdline"):
    try:
        with open(path, "rb") as f:
            cmd = b" ".join(filter(None, f.read().split(b"\0")))
        if b"uvicorn" in cmd:
            print(path[:-8].decode(), ":", cmd.decode("utf-8","ignore"))
    except Exception:
        pass
