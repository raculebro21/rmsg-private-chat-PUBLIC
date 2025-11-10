FROM python:3.11-slim

# deps de sistema (Faiss + healthcheck)
RUN apt-get update && apt-get install -y --no-install-recommends \
    libgomp1 wget \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Torch CPU (sin CUDA)
RUN pip install --no-cache-dir --index-url https://download.pytorch.org/whl/cpu torch==2.5.1

# Resto de dependencias
COPY requirements.txt /app/
RUN pip install --no-cache-dir -r requirements.txt

# Código
COPY . /app

EXPOSE 8080
CMD ["uvicorn","main:app","--host","0.0.0.0","--port","8080"]
