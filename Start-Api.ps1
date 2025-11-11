param(
    [int]$TimeoutSec = 60,
    [string]$HealthUrl = "http://localhost:8000/health",
    [switch]$OpenDocs
)

Write-Host "▶  Levantando contenedores con docker compose..." -ForegroundColor Cyan
docker compose up -d

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$healthy = $false

Write-Host "⏳ Esperando a que /health responda OK ..."
while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
    try {
        $resp = iwr $HealthUrl -TimeoutSec 2 -ErrorAction Stop
        if ($resp.StatusCode -eq 200 -and $resp.Content -match '"status":"ok"') {
            $healthy = $true
            break
        }
    } catch {
        Start-Sleep -Seconds 1
    }
}

if (-not $healthy) {
    Write-Host "❌ No respondió /health en $TimeoutSec s. Revisa logs." -ForegroundColor Red
    exit 1
}

Write-Host "✅ API saludable en $($sw.Elapsed.TotalSeconds.ToString("0.0")) s" -ForegroundColor Green
iwr http://localhost:8000/version | Select-Object -Expand Content | Write-Host

if ($OpenDocs) {
    Start-Process "http://localhost:8000/docs"
}