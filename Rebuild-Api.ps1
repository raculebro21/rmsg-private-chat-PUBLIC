param(
    [switch]$OpenDocs
)

Write-Host "Bajando stack..."
docker compose down

Write-Host "Actualizando imagen base..."
docker pull python:3.11-slim | Out-Null

Write-Host "Levantando stack..."
docker compose up -d | Out-Null

Write-Host "Probando health..."
$args = @("-NoProfile","-ExecutionPolicy","Bypass","-File",".\Test-Api.ps1","-TimeoutSec","120")
if ($OpenDocs) { $args += "-OpenDocs" }
powershell @args