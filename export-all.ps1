param(
  [string]$Base        = 'http://127.0.0.1:8088',
  [string]$OutDir      = '.\exports',
  [string]$CalendarId  = 'primary',
  [int]$CalMax         = 50,
  [string]$CalTimeMin,
  [string]$CalTimeMax,
  [int]$GmailMax       = 50,
  [int]$DriveMax       = 50
)

function Ensure-File {
  param([string]$Path)
  if (-not (Test-Path $Path)) { throw "No se encontró: $Path" }
}

function Run-Step {
  param([string]$Label, [scriptblock]$Action)
  Write-Host "▶ $Label..."
  try {
    & $Action
    Write-Host "✔ $Label listo."
  } catch {
    Write-Warning "⚠ $Label falló: $($_.Exception.Message)"
  }
}

Ensure-File ".\export-profile.ps1"
Ensure-File ".\export-cal.ps1"
Ensure-File ".\export-gmail.ps1"
Ensure-File ".\export-drive.ps1"

if (-not $CalTimeMin) { $CalTimeMin = (Get-Date).ToUniversalTime().ToString('o').Replace('+00:00','Z') }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

Run-Step "Perfil" {
  .\export-profile.ps1 -Base $Base -OutFormat json  -OutFile (Join-Path $OutDir 'me.json')
  .\export-profile.ps1 -Base $Base -OutFormat table -OutFile (Join-Path $OutDir 'me.txt')
}

Run-Step "Calendario ($CalendarId)" {
  $calArgs = @{
    Base       = $Base
    CalendarId = $CalendarId
    MaxItems   = $CalMax
    TimeMin    = $CalTimeMin
    OutFormat  = 'csv'
    OutFile    = (Join-Path $OutDir 'cal.csv')
  }
  if ($CalTimeMax) { $calArgs.TimeMax = $CalTimeMax }
  .\export-cal.ps1 @calArgs

  $calArgs.OutFormat = 'table'
  $calArgs.OutFile   = (Join-Path $OutDir 'cal.txt')
  .\export-cal.ps1 @calArgs
}

Run-Step "Gmail (threads)" {
  .\export-gmail.ps1 -Base $Base -MaxItems $GmailMax -OutFormat csv   -OutFile (Join-Path $OutDir 'gmail.csv')
  .\export-gmail.ps1 -Base $Base -MaxItems $GmailMax -OutFormat table -OutFile (Join-Path $OutDir 'gmail.txt')
}

Run-Step "Drive (archivos)" {
  .\export-drive.ps1 -Base $Base -MaxItems $DriveMax -OutFormat csv   -OutFile (Join-Path $OutDir 'drive.csv')
  .\export-drive.ps1 -Base $Base -MaxItems $DriveMax -OutFormat table -OutFile (Join-Path $OutDir 'drive.txt')
}

Write-Host ""
Write-Host "✅ Exportación completa. Archivos en: $(Resolve-Path $OutDir)"
# --- ZIP automático al final ---
try {
  $ts = Get-Date -Format "yyyyMMdd_HHmmss"
  $zipPath = Join-Path (Get-Location) ("exports_{0}.zip" -f $ts)
  if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
  Compress-Archive -Path (Join-Path $OutDir '*') -DestinationPath $zipPath -Force
  Write-Host ("🗜 ZIP creado: {0}" -f (Resolve-Path $zipPath))
} catch {
  Write-Warning ("No se pudo crear el ZIP: {0}" -f $_.Exception.Message)
}
