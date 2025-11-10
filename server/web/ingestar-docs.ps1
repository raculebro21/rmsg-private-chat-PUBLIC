<# 
ingestar-docs.ps1
Sube (ingesta) todos los archivos de una carpeta a tu servidor local usando tu token y un namespace.
Funciona con subcarpetas, maneja espacios en rutas y muestra un resumen al final.
#>

param(
  [string]$Token,                       # opcional: si no lo pasas, te lo pedimos
  [string]$Namespace = "industrial",    # puedes cambiar el default si quieres
  [string]$Folder                      # opcional: si no lo pasas, usamos Desktop\Docs
)

# --------- 1) Valores por defecto / pedir datos ----------
try {
  if (-not $Token -or $Token.Trim().Length -ne 64) {
    $Token = Read-Host "Pega tu token (64 caracteres)"
  }
  if (-not $Namespace) {
    $Namespace = Read-Host "Namespace (ej. industrial)"
  }
  if (-not $Folder) {
    $Desktop = [Environment]::GetFolderPath('Desktop')
    $Folder  = Join-Path $Desktop 'Docs'
    Write-Host "Usando carpeta por defecto: $Folder"
  }

  if (-not (Test-Path $Folder)) {
    Write-Error "No existe la carpeta: $Folder"
    exit 1
  }
}
catch {
  Write-Error $_.Exception.Message
  exit 1
}

# --------- 2) Checar salud del backend ----------
try {
  $health = Invoke-RestMethod "http://127.0.0.1:8080/health" -TimeoutSec 10
  if ($health.status -ne "ok") { Write-Warning "El /health no respondió OK: $($health | ConvertTo-Json -Compress)" }
} catch {
  Write-Error "No pude contactar al backend en http://127.0.0.1:8080 . ¿Está levantado? (docker compose up -d)"
  exit 1
}

# --------- 3) Recorrer archivos y subir ----------
$files = Get-ChildItem -Path $Folder -File -Recurse
if (-not $files) {
  Write-Warning "No se encontraron archivos en $Folder"
  exit 0
}

$TotalFiles   = 0
$TotalChunks  = 0
$Failures     = @()

Write-Host "=== Ingestando a namespace '$Namespace' desde '$Folder' ===`n"

foreach ($f in $files) {
  $TotalFiles++
  $full = $f.FullName
  Write-Host ("[{0}/{1}] {2}" -f $TotalFiles, $files.Count, $full)

  # Nota: pasamos namespace por query param (más estable)
  $url = "http://127.0.0.1:8080/ingest?namespace=$([uri]::EscapeDataString($Namespace))"
  $args = @("-H", "Authorization: Bearer $Token", "-F", "files=@""$full""", $url)

  try {
    $raw = & curl.exe @args 2>$null
    if (-not $raw) { throw "Respuesta vacía" }

    # Puede venir como JSON o como texto: intentamos parsear
    try {
      $json = $raw | ConvertFrom-Json
      if ($json.inserted_chunks -ge 0) {
        $TotalChunks += [int]$json.inserted_chunks
        Write-Host ("    → OK: {0} chunks (namespace: {1})" -f $json.inserted_chunks, $json.namespace)
      } else {
        Write-Warning "    → Respuesta sin 'inserted_chunks': $raw"
      }
    } catch {
      # No era JSON (p.ej. no-cors). Igual mostramos el texto.
      Write-Warning "    → Respuesta no JSON: $raw"
    }
  }
  catch {
    Write-Host "    → ERROR subiendo este archivo."
    $Failures += $full
  }
}

# --------- 4) Resumen ----------
Write-Host "`n=== Resumen ==="
Write-Host "Archivos procesados: $TotalFiles"
Write-Host "Chunks insertados:  $TotalChunks"
if ($Failures.Count -gt 0) {
  Write-Host "Fallidos ($($Failures.Count)):"
  $Failures | ForEach-Object { Write-Host " - $_" }
} else {
  Write-Host "Sin fallas 🎉"
}
