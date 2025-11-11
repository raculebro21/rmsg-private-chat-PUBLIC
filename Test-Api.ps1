param(
    [string]$BaseUrl = "http://localhost:8000",
    [int]$TimeoutSec = 120,
    [switch]$OpenDocs
)

Write-Host "Probando $BaseUrl/health con reintentos hasta $TimeoutSec s..."

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$healthy = $false
while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
    try {
        $resp = iwr "$BaseUrl/health" -TimeoutSec 2 -ErrorAction Stop
        if ($resp.StatusCode -eq 200 -and $resp.Content -match '"status":"ok"') {
            $healthy = $true
            break
        }
    } catch {
        Start-Sleep -Seconds 1
    }
}

if (-not $healthy) {
    Write-Error "Health check falló tras $TimeoutSec s"
    exit 1
}

Write-Host "OK. Leyendo $BaseUrl/version ..."
$i = iwr "$BaseUrl/version" -TimeoutSec 5 | Select-Object -Expand Content
Write-Host $i

if ($OpenDocs) { Start-Process "$BaseUrl/docs" }