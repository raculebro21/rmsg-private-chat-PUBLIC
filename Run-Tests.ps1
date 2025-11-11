Write-Host "Ejecutando pytest dentro de docker compose..." -ForegroundColor Yellow

# Asegura que el servicio está arriba
docker compose up -d | Out-Null

# Ejecuta pytest (usa el nombre del servicio en docker-compose: 'api')
docker compose exec api sh -lc "pytest -q" 