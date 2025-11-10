function Get-CharsetEncoding {
  param([string]$Charset)
  try { [System.Text.Encoding]::RegisterProvider([System.Text.CodePagesEncodingProvider]::Instance) | Out-Null } catch {}
  $c = $Charset; if ([string]::IsNullOrWhiteSpace($c)) { $c = 'utf-8' }; $c = $c.ToLowerInvariant()
  switch -regex ($c) {
    'utf-?8'               { return [System.Text.Encoding]::UTF8 }
    'iso-8859-1|latin-?1'  { return [System.Text.Encoding]::GetEncoding(28591) }
    'windows-1252|cp1252'  { return [System.Text.Encoding]::GetEncoding(1252) }
    default { try { return [System.Text.Encoding]::GetEncoding($c) } catch { return [System.Text.Encoding]::UTF8 } }
  }
}

function Decode-EncodedWord {
  param([string]$Text)
  if (-not $Text) { return $Text }
  try { [System.Text.Encoding]::RegisterProvider([System.Text.CodePagesEncodingProvider]::Instance) | Out-Null } catch {}
  $pattern = '=\?([^?]+)\?([bBqQ])\?([^?]+)\?='
  $evaluator = {
    param($m)
    $enc = Get-CharsetEncoding $m.Groups[1].Value
    if ($m.Groups[2].Value -match '^[qQ]$') {
      $q = $m.Groups[3].Value -replace '_',' '
      $bytes = New-Object System.Collections.Generic.List[byte]
      $i = 0
      while ($i -lt $q.Length) {
        if ($q[$i] -eq '=') {
          if ($i + 2 -lt $q.Length -and $q.Substring($i+1,2) -match '^[0-9A-Fa-f]{2}$') {
            [byte]$b = [Convert]::ToByte($q.Substring($i+1,2),16); $bytes.Add($b); $i += 3
          } else { $bytes.Add([byte][char]'='); $i++ }
        } else { $bytes.Add([byte][char]$q[$i]); $i++ }
      }
      return $enc.GetString($bytes.ToArray())
    } else {
      try { return $enc.GetString([Convert]::FromBase64String($m.Groups[3].Value)) }
      catch { return $m.Value }
    }
  }
  return [regex]::Replace($Text, $pattern, $evaluator)
}

function Convert-FromMojibake {
  param([string]$Text)
  if (-not $Text) { return $Text }
  if ($Text -notmatch '[ÃÂâ¢°·]') { return $Text }
  try { [System.Text.Encoding]::RegisterProvider([System.Text.CodePagesEncodingProvider]::Instance) | Out-Null } catch {}
  $utf8   = [System.Text.Encoding]::UTF8
  $cp1252 = [System.Text.Encoding]::GetEncoding(1252)
  $latin1 = [System.Text.Encoding]::GetEncoding(28591)
  $bytes1 = $cp1252.GetBytes($Text)
  $fix1   = $utf8.GetString($bytes1)
  if ($fix1 -match '[ÃÂâ¢°·]') {
    $bytes2 = $latin1.GetBytes($Text)
    $fix2   = $utf8.GetString($bytes2)
    if ($fix2 -notmatch '[ÃÂâ¢°·]') { return $fix2 }
  }
  return $fix1
}

function Fix-HeaderText {
  param([string]$Text)
  if (-not $Text) { return $Text }
  $t = Decode-EncodedWord $Text
  if ($t -match '[ÃÂâ¢°·]') { $t = Convert-FromMojibake $t }
  return ($t -replace '^\s+|\s+$','')
}

# Find-EmailsFast robusto: prueba varias rutas y limpia From/Subject con Fix-HeaderText
function Find-EmailsFast {
  param([int]$Max = 50)

  function Invoke-SafeJson {
    param([string]$Url)
    try { return Invoke-RestMethod -Uri $Url -Method GET -TimeoutSec 10 } catch { return $null }
  }
  function Extract-IdsRec {
    param([object]$Obj, [ref]$Bag)
    if (-not $Obj) { return }
    if ($Obj -is [System.Collections.IEnumerable] -and -not ($Obj -is [string])) {
      foreach ($it in $Obj) { Extract-IdsRec -Obj $it -Bag $Bag }
      return
    }
    $props = $Obj | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name
    if ($props -contains 'id') {
      $id = [string]$Obj.id
      if (-not [string]::IsNullOrWhiteSpace($id)) { $Bag.Value.Add($id) | Out-Null }
    }
    foreach ($p in $props) {
      $v = $Obj.$p
      if ($v -is [string]) { continue }
      Extract-IdsRec -Obj $v -Bag $Bag
    }
  }

  $base = 'http://localhost:8088'
  $listPaths = @('/messages','/gmail/messages','/list','/gmail/list','/messages/recent','/gmail/messages/recent')

  $ids = New-Object System.Collections.Generic.List[string]
  foreach ($p in $listPaths) {
    $urls = @("$base$p?max=$Max", "$base$p")
    foreach ($u in $urls) {
      $json = Invoke-SafeJson $u
      if ($json) {
        Extract-IdsRec -Obj $json -Bag ([ref]$ids)
        if ($ids.Count -gt 0) { break }
      }
    }
    if ($ids.Count -gt 0) { break }
  }
  if ($ids.Count -eq 0) {
    Write-Error "Find-EmailsFast: no se pudieron obtener IDs desde $base (rutas probadas: $($listPaths -join ', '))."
    return @()
  }

  $take = [Math]::Min($Max, $ids.Count)
  $out = New-Object System.Collections.Generic.List[object]
  for ($i=0; $i -lt $take; $i++) {
    $id = $ids[$i]
    try {
      $m = Get-Mail $id   # tu función existente (posicional)
      if ($m) {
        $from = $m.From;  $subj = $m.Subject
        try { $from = Fix-HeaderText $from } catch {}
        try { $subj = Fix-HeaderText $subj } catch {}
        $out.Add([pscustomobject]@{ Id=$id; Date=$m.Date; From=$from; Subject=$subj }) | Out-Null
      }
    } catch {}
  }
  return $out
}
