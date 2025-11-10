# =========================
# scripts/run-rag-tests.ps1
# =========================
param(
  [string]$ApiUrl      = "http://localhost:8088/chat",
  [string]$Namespace   = "industrial",
  [int]   $K           = 25,
  [string]$Out         = ".\rag_report.json",
  [int]   $TimeoutSec  = 240,
  [int]   $MaxCtxChars = 12000
)

$ErrorActionPreference = "Stop"

function Invoke-Chat {
  param([string]$Message)

  $payload = @{
    message               = $Message
    namespace             = $Namespace
    k                     = $K
    return_sources        = $true
    return_debug          = $true
    return_debug_snippets = $true
    max_chars_context     = $MaxCtxChars
  } | ConvertTo-Json -Depth 6 -Compress

  try {
    $resp = Invoke-RestMethod -Method Post -Uri $ApiUrl `
      -ContentType "application/json; charset=utf-8" `
      -Body $payload -TimeoutSec $TimeoutSec
  } catch {
    return @{
      error = "HTTP error: $($_.Exception.Message)"
      raw   = $_ | Out-String
    }
  }

  $docList = @()
  if ($resp.sources) {
    foreach ($s in $resp.sources) {
      if ($s.PSObject.Properties.Match('source').Count -gt 0 -and $s.source) {
        $docList += [string]$s.source
      } elseif ($s.PSObject.Properties.Match('doc_id').Count -gt 0 -and $s.doc_id) {
        $docList += [string]$s.doc_id
      } elseif ($s.PSObject.Properties.Match('title').Count -gt 0 -and $s.title) {
        $docList += "[title] " + [string]$s.title
      }
    }
  }

  return @{
    answer  = [string]$resp.answer
    sources = $docList
    debug   = $resp.debug
    raw     = $resp
  }
}

function Assert-True {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw $Message }
}

function Assert-Match {
  param([string]$Text, [string]$Pattern, [string]$Message)
  if ($null -eq $Text -or -not ($Text -match $Pattern)) { throw $Message }
}

function Parse-Number {
  param([string]$s)
  if ($null -eq $s) { return $null }
  $clean = $s `
    -replace '\u00A0',' ' `
    -replace '[\s,\.](?=\d{3}\b)', '' `
    -replace ',', '.'
  [double]::Parse($clean, [Globalization.CultureInfo]::InvariantCulture)
}

# =========================
# TESTS
# =========================

$tests = @()

# 1) 3 vinetas exactas + Fuente: [S1]
$tests += @{
  name   = "bullets_apodaca_t2_2024_exact3"
  prompt = @'
Usa SOLO mis documentos. Submercado: Apodaca, Periodo: T2 2024.
Devuelve EXACTAMENTE 3 vinetas con: (1) Renta objetivo, (2) Vacancia, (3) Absorcion neta T2.
Si algun dato no esta en el contexto, escribe "ND".
Formato:
- Renta objetivo: ...
- Vacancia: ...
- Absorcion neta T2: ...
Al final, una linea: Fuente: [S1]
'@
  validate = {
    param($resp)
    $ans = $resp.answer

    $lines = ($ans -split '\r?\n') | Where-Object { $_ -match '\S' }
    $bulletLines = $lines | Where-Object { $_ -match '^[\-\*]\s' }
    $sourceLine  = $lines | Where-Object { $_ -match '^Fuente:\s*\[S1\]' }

    Assert-True ($bulletLines.Count -eq 3) "Se esperaban exactamente 3 vinetas."
    Assert-True ($sourceLine.Count -eq 1)  "Falta linea de fuente 'Fuente: [S1]'."

    Assert-Match $bulletLines[0] '^[\-\*]\s*Renta objetivo:' "La vineta 1 debe iniciar con 'Renta objetivo:'"
    Assert-Match $bulletLines[1] '^[\-\*]\s*Vacancia:'       "La vineta 2 debe iniciar con 'Vacancia:'"
    Assert-Match $bulletLines[2] '^[\-\*]\s*Absorcion neta T2:' "La vineta 3 debe iniciar con 'Absorcion neta T2:'"

    # Rango de renta: permitir guion normal o cualquier dash unicode mediante \p{Pd}
    $rentMatch = [regex]::Match(
      $bulletLines[0],
      'Renta objetivo:\s*MXN\s*([0-9][0-9\.,]*)\s*(?:-|\p{Pd})\s*([0-9][0-9\.,]*)\s*/\s*m\s*/\s*mes',
      [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    Assert-True $rentMatch.Success "No se detecto rango de renta (MXN A-B / m / mes)."
    $rMin = Parse-Number $rentMatch.Groups[1].Value
    $rMax = Parse-Number $rentMatch.Groups[2].Value
    Assert-True ($rMin -eq 120 -and $rMax -eq 140) "Renta esperada 120-140; obtuvo $rMin-$rMax."

    $vacMatch = [regex]::Match(
      $bulletLines[1],
      'Vacancia:\s*([0-9]+(?:\.[0-9]+)?)\s*%',
      [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    Assert-True $vacMatch.Success "No se detecto vacancia en formato 'X %'."
    $vac = Parse-Number $vacMatch.Groups[1].Value
    Assert-True ([Math]::Abs($vac - 3.2) -lt 0.001) "Vacancia esperada 3.2 %; obtuvo $vac."

    # Absorcion: solo exigimos que haya una "m" despues del numero (evita problemas de m2/m^2/m2)
    $absMatch = [regex]::Match(
      $bulletLines[2],
      'Absorcion neta T2:\s*([0-9][0-9\.,]*)\s*m',
      [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    Assert-True $absMatch.Success "No se detecto absorcion neta 'NNN m...'."
    $abs = Parse-Number $absMatch.Groups[1].Value
    Assert-True ($abs -eq 120000) "Absorcion esperada 120000 m2; obtuvo $abs."

    $hasApodaca = ($resp.sources | Where-Object { $_ -match 'apodaca_t2_2024' }).Count -gt 0
    Assert-True $hasApodaca "Las fuentes no incluyen 'apodaca_t2_2024'."
  }
}

# 2) JSON estricto con null si falta
$tests += @{
  name   = "json_apodaca_t2_2024"
  prompt = @'
SOLO mis documentos. Devuelve JSON (sin texto extra):
{
  "market": "Apodaca",
  "period": "T2 2024",
  "rent_mxn_m2_month": "...",
  "vacancy_pct": "...",
  "net_absorption_m2": "...",
  "source_ids": ["S1"]
}
Usa null si no hay dato.
'@
  validate = {
    param($resp)
    $ans = $resp.answer.Trim()

    $m = [regex]::Match(
      $ans,
      '^\s*```(?:json)?\s*(?<j>.+?)\s*```\s*$',
      [System.Text.RegularExpressions.RegexOptions]::Singleline
    )
    if ($m.Success) { $ans = $m.Groups['j'].Value }

    try {
      $obj = $ans | ConvertFrom-Json -ErrorAction Stop
    } catch {
      throw "No devolvio JSON valido."
    }
    Assert-True ($obj.market -eq "Apodaca") "market debe ser 'Apodaca'."
    Assert-True ($obj.period -eq "T2 2024") "period debe ser 'T2 2024'."
    Assert-True ($obj.source_ids.Count -ge 1) "source_ids vacio."

    Assert-True ($obj.rent_mxn_m2_month -match '120' -and $obj.rent_mxn_m2_month -match '140') "Rango de renta no encontrado en JSON."
    Assert-True ($obj.vacancy_pct -match '3\.?2') "Vacancy 3.2 no encontrado en JSON."
    Assert-True ($obj.net_absorption_m2 -match '120000') "Absorcion 120000 no encontrada en JSON."
  }
}

# 3) ND cuando periodo no existe (T3 2030)
$tests += @{
  name   = "nd_when_missing"
  prompt = @'
Usa SOLO mis documentos. Submercado: Apodaca, Periodo: T3 2030.
Devuelve EXACTAMENTE 3 vinetas (Renta/Vacancia/Absorcion neta T3).
Si algun dato no esta en el contexto, escribe "ND".
Al final: Fuente: [S1] o Fuente: ND
'@
  validate = {
    param($resp)
    $ans = $resp.answer
    $lines = ($ans -split '\r?\n') | Where-Object { $_ -match '\S' }
    $bulletLines = $lines | Where-Object { $_ -match '^[\-\*]\s' }
    Assert-True ($bulletLines.Count -eq 3) "Se esperaban 3 vinetas."
    foreach ($b in $bulletLines) {
      Assert-True ($b -match 'ND') "Cuando falta dato debe poner 'ND'. Linea: $b"
    }
  }
}

# 4) Boolean + linea de construccion 450,000 m...
$tests += @{
  name   = "boolean_y_linea_construccion"
  prompt = @'
Se menciona "Construccion en curso: 450,000 m2" para Apodaca T2 2024 en mis documentos?
Responde en UNA linea: true/false | "<linea exacta>" | [S1]
Solo si es true incluye la linea y [S1].
'@
  validate = {
    param($resp)
    $ans = ($resp.answer -split '\r?\n' | Where-Object { $_ -match '\S' } | Select-Object -First 1)
    Assert-True ($ans -match '^(true|false)\s*\|') "Formato booleano no detectado (true/false | ...)."
    Assert-True ($ans -match '^true\s*\|' -and $ans -match '\[S1\]') "Deberia ser true e incluir [S1]."
    Assert-True ($ans -match '450,?000\s*m') "No contiene '450,000 m...' en la linea."
  }
}

# 5) Frase exacta (sin acentos por robustez)
$tests += @{
  name   = "frase_logistica_ultima_milla"
  prompt = @'
Busca literalmente la frase "logistica de ultima milla" (sin acentos) en mis documentos de Apodaca T2 2024.
Devuelve: Si/No | "<fragmento>" | [S1]
'@
  validate = {
    param($resp)
    $ans = ($resp.answer -split '\r?\n' | Where-Object { $_ -match '\S' } | Select-Object -First 1)
    Assert-True ($ans -match '^(Si|No)\s*\|') "Respuesta debe iniciar con Si/No |"
    Assert-True ($ans -match '^Si\s*\|' -and $ans -match '\[S1\]') "Esperaba Si y [S1]."
    Assert-True ($ans -match 'logistica de ultima milla') "No se encontro la frase sin acentos."
  }
}

# 6) Tabla comparacion Apodaca vs Guadalupe
$tests += @{
  name   = "tabla_apodaca_vs_guadalupe"
  prompt = @'
Usa SOLO mis documentos. Compara Apodaca vs Guadalupe en:
- Renta objetivo (MXN/m/mes)
- Vacancia (%)
Periodo: T2 2024 si aplica; si falta en Guadalupe, pon ND.
Devuelve una tabla Markdown con filas Apodaca, Guadalupe, y al final: Fuente: [S1] [S2]
'@
  validate = {
    param($resp)
    $ans = $resp.answer
    # Correccion: usar (?m) para multilinea en vez de un sufijo 'm' invalido
    Assert-True ($ans -match '(?m)^\|.*\|.*\|.*\|') "No parece tabla Markdown."
    Assert-True ($ans -match 'Apodaca' -and $ans -match 'Guadalupe') "Faltan filas Apodaca/Guadalupe."
    Assert-True ($ans -match 'Fuente:\s*\[S1\]') "Falta Fuente: [S1]"
  }
}

# =========================
# RUNNER
# =========================

$results = New-Object System.Collections.Generic.List[object]
$swAll = [System.Diagnostics.Stopwatch]::StartNew()

foreach ($t in $tests) {
  $name = $t.name
  $msg  = $t.prompt
  Write-Host ""
  Write-Host "=== TEST: $name ==="
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $status = "PASS"
  $errorMsg = $null
  $sources = @()
  $kwhits  = $null

  try {
    $resp = Invoke-Chat -Message $msg
    if ($resp.error) { throw $resp.error }
    $sources = $resp.sources
    if ($resp.debug) { $kwhits = $resp.debug.had_keyword_hits }
    & $t.validate $resp
  } catch {
    $status = "FAIL"
    $errorMsg = $_.Exception.Message
  } finally {
    $sw.Stop()
  }

  $row = [ordered]@{
    test    = $name
    status  = $status
    ms      = $sw.ElapsedMilliseconds
    error   = $errorMsg
    sources = ($sources -join "; ")
    kw_hits = if ($kwhits -ne $null) { [string]$kwhits } else { "" }
  }
  $results.Add([pscustomobject]$row) | Out-Null

  if ($status -eq "PASS") {
    Write-Host "PASS ($($row.ms) ms)"
  } else {
    Write-Host "FAIL: $errorMsg"
    if ($row.sources) { Write-Host "Sources: $($row.sources)" }
  }
}

$swAll.Stop()
Write-Host ""
Write-Host "===== RESUMEN ====="
$pass = ($results | Where-Object { $_.status -eq "PASS" }).Count
$fail = ($results | Where-Object { $_.status -eq "FAIL" }).Count
Write-Host ("Total: {0} | PASS: {1} | FAIL: {2} | {3} ms" -f ($results.Count), $pass, $fail, $swAll.ElapsedMilliseconds)

$results | Format-Table -AutoSize
$results | ConvertTo-Json -Depth 5 | Set-Content -Encoding utf8 $Out
Write-Host ""
Write-Host "Reporte guardado en: $Out"
