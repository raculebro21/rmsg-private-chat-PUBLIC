param(
  [string]$Base = 'http://127.0.0.1:8088',
  [int]$MaxItems = 50,
  [string]$Query,                     # opcional; tu endpoint puede ignorarlo si no está implementado
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

# --- construir querystring ---
$Headers = @{ 'Accept-Encoding' = 'identity' }
$qs = @("max_items=$MaxItems")
if ($Query) { $qs += "q=$([Uri]::EscapeDataString($Query))" }
$qs = $qs -join '&'

# --- llamada ---
$items = Get-JsonUtf8 "$Base/gmail/threads?$qs" -Headers $Headers

# Por si el endpoint devolviera JSON de error
if ($items -is [hashtable] -and $items.ContainsKey('error')) {
  Write-Error ("API error: {0}`n{1}" -f $items.error, $items.trace)
  exit 1
}

# --- proyección + normalización (NFC) ---
$norm = [Text.NormalizationForm]::FormC
$rows = $items | ForEach-Object {
  # El endpoint actual devuelve: id, snippet, historyId
  [pscustomobject]@{
    id        = $_.id
    snippet   = ($_.snippet).Normalize($norm)
    historyId = $_.historyId
  }
}

# --- salida ---
if (-not $OutFile) {
  $rows | Format-Table -AutoSize
  return
}

$encNoBom = [Text.UTF8Encoding]::new($false)
switch ($OutFormat) {
  'csv'  {
    $tmp = New-TemporaryFile
    $rows | Export-Csv -Path $tmp -NoTypeInformation -Encoding UTF8
    [IO.File]::WriteAllText($OutFile, (Get-Content $tmp -Raw), $encNoBom)
    Remove-Item $tmp -Force
  }
  'json' {
    $json = $rows | ConvertTo-Json -Depth 6
    [IO.File]::WriteAllText($OutFile, $json, $encNoBom)
  }
  default { # table
    $txt = $rows | Format-Table -AutoSize | Out-String
    [IO.File]::WriteAllText($OutFile, $txt, $encNoBom)
  }
}
Write-Host "✅ Exportado: $OutFile"
