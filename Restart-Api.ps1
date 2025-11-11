param(
    [int]$WaitSec = 2,
    [string]$BaseUrl = "http://localhost:8000"
)

Write-Host "Reiniciando servicio API..."
docker compose restart api | Out-Null

Start-Sleep -Seconds $WaitSec

Write-Host "Verificando health..."
powershell -NoProfile -ExecutionPolicy Bypass -File ".\Test-Api.ps1" -BaseUrl $BaseUrl