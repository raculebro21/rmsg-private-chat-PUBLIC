param(
  [string]$Base = 'http://127.0.0.1:8088',
  [string]$CalendarId = 'primary',
  [int]$MaxItems = 50,
  [string]$TimeMin,
  [string]$TimeMax,
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

# Parámetros por defecto
$Headers = @{ 'Accept-Encoding' = 'identity' }
if (-not $TimeMin) { $TimeMin = (Get-Date).ToUniversalTime().ToString('o').Replace('+00:00','Z') }

# Construir query
$calEnc = [Uri]::EscapeDataString($CalendarId)   # maneja IDs con '#'
$qs = @(
  "calendarId=$calEnc"
  "max_items=$MaxItems"
  "timeMin=$TimeMin"
) -join '&'
if ($TimeMax) { $qs += "&timeMax=$TimeMax" }

# Llamada
$items = Get-JsonUtf8 "$Base/calendar/events?$qs" -Headers $Headers

# Por si el endpoint devolviera error en JSON
if ($items -is [hashtable] -and $items.ContainsKey('error')) {
  Write-Error ("API error: {0}`n{1}" -f $items.error, $items.trace)
  exit 1
}

# Proyección + normalización
$norm = [Text.NormalizationForm]::FormC
$rows = $items | ForEach-Object {
  [pscustomobject]@{
    summary  = ($_.summary).Normalize($norm)
    start    = if ($_.start.date) { $_.start.date } else { $_.start.dateTime }
    end      = if ($_.end.date)   { $_.end.date   } else { $_.end.dateTime   }
    htmlLink = $_.htmlLink
  }
}

# Salida
if (-not $OutFile) {
  $rows | Format-Table -AutoSize
  return
}

$encNoBom = [Text.UTF8Encoding]::new($false)
switch ($OutFormat) {
  'csv' {
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
