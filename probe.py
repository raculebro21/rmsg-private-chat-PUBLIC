import time, urllib.request
for i in range(10):
    try:
        with urllib.request.urlopen("http://127.0.0.1:8080/health", timeout=2) as r:
            print(i, r.status, r.read().decode("utf-8","ignore"))
    except Exception as e:
        print(i, "ERR", e)
    time.sleep(1)
