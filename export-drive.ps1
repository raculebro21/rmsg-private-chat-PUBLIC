param(
  [string]$Base = 'http://127.0.0.1:8088',
  [int]$MaxItems = 50,
  [string]$NameLike,                # filtro opcional por nombre (regex); client-side
  [string]$ModifiedSince,           # ISO (o cualquier formato reconocible por [datetime]); client-side
  [ValidateSet('table','csv','json')]
  [string]$OutFormat = 'table',
  [string]$OutFile
)

function Get-JsonUtf8 {
  param([string]$Url, [hashtable]$Headers = @{})
  $resp = Invoke-WebRequest $Url -Headers $Headers
  $sr   = New-Object IO.StreamReader($resp.RawContentStream, [Text.Encoding]::UTF8, $true)
  $json = $sr.ReadToEnd(); $sr.Close()
  return $json | ConvertFrom-Json
}

# --- llamada al backend ---
$Headers = @{ 'Accept-Encoding' = 'identity' }
$items = Get-JsonUtf8 "$Base/drive/files?max_items=$MaxItems" -Headers $Headers

# Por si el endpoint devolviera JSON de error
if ($items -is [hashtable] -and $items.ContainsKey('error')) {
  Write-Error ("API error: {0}`n{1}" -f $items.error, $items.trace)
  exit 1
}

# --- proyección + normalización ---
$norm = [Text.NormalizationForm]::FormC
$rows = $items | ForEach-Object {
  # backend devuelve: id, name, mimeType, modifiedTime
  $dt = $null
  if ($_.modifiedTime) {
    try { $dt = [datetime]::Parse($_.modifiedTime).ToUniversalTime() } catch { $dt = $null }
  }
  [pscustomobject]@{
    id            = $_.id
    name          = ($_.name).Normalize($norm)
    mimeType      = $_.mimeType
    modifiedTime  = $dt
    modified_iso  = if ($dt) { $dt.ToString('yyyy-MM-ddTHH:mm:ssZ') } else { $null }
  }
}

# --- filtros client-side opcionales ---
if ($NameLike)      { $rows = $rows | Where-Object { $_.name -match $NameLike } }
if ($ModifiedSince) {
  try {
    $cut = [datetime]::Parse($ModifiedSince).ToUniversalTime()
    $rows = $rows | Where-Object { $_.modifiedTime -and $_.modifiedTime -ge $cut }
  } catch { Write-Warning "No pude interpretar ModifiedSince: $ModifiedSince" }
}

# --- ordenar por fecha (desc) si tenemos fecha, si no, por nombre ---
$rows = $rows | Sort-Object @{Expression='modifiedTime';Descending=$true}, 'name'

# --- salida ---
if (-not $OutFile) {
  $rows |
    Select-Object name, mimeType, modified_iso, id |
    Format-Table -AutoSize
  return
}

$encNoBom = [Text.UTF8Encoding]::new($false)
switch ($OutFormat) {
  'csv'  {
    $tmp = New-TemporaryFile
    $rows |
      Select-Object name, mimeType, modified_iso, id |
      Export-Csv -Path $tmp -NoTypeInformation -Encoding UTF8
    [IO.File]::WriteAllText($OutFile, (Get-Content $tmp -Raw), $encNoBom)
    Remove-Item $tmp -Force
  }
  'json' {
    $json = $rows | ConvertTo-Json -Depth 6
    [IO.File]::WriteAllText($OutFile, $json, $encNoBom)
  }
  default { # table
    $txt = ($rows | Select-Object name, mimeType, modified_iso, id | Format-Table -AutoSize | Out-String)
    [IO.File]::WriteAllText($OutFile, $txt, $encNoBom)
  }
}
Write-Host "✅ Exportado: $OutFile"
