
# region Unwrap-RedirectUrl
if (-not ("System.Web.HttpUtility" -as [type])) {
  Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue | Out-Null
}
function Unwrap-RedirectUrl {
  param([string]$u)
  try {
    function _TryB64Url([string]$s){
      try {
        if (-not $s) { return $null }
        $x = [System.Web.HttpUtility]::UrlDecode($s)
        $x = $x.Replace('-', '+').Replace('_','/')
        switch ($x.Length % 4) { 2 { $x += "=="; break } 3 { $x += "="; break } default {} }
        $bytes = [Convert]::FromBase64String($x)
        $t = [Text.Encoding]::UTF8.GetString($bytes)
        if ($t -match '^https?://') { return $t }
      } catch {}
      return $null
    }

    $abs = $null
    if (-not [Uri]::TryCreate($u, [UriKind]::Absolute, [ref]$abs)) { return $u }

    $domain = $abs.Host.ToLowerInvariant()
    $qraw   = if ([string]::IsNullOrEmpty($abs.Query)) { '' } else { $abs.Query.TrimStart('?') }
    $qs     = [System.Web.HttpUtility]::ParseQueryString($qraw)

    switch -Wildcard ($domain) {
      'www.linkedin.com' { if ($qs['url']) { return [System.Web.HttpUtility]::UrlDecode($qs['url']) } }

      'l.facebook.com'   { if ($qs['u'])   { return [System.Web.HttpUtility]::UrlDecode($qs['u'])   } }
      'l.messenger.com'  { if ($qs['u'])   { return [System.Web.HttpUtility]::UrlDecode($qs['u'])   } }

      'www.google.com' {
        if ($abs.AbsolutePath -like '/url*') {
          if     ($qs['url']) { return [System.Web.HttpUtility]::UrlDecode($qs['url']) }
          elseif ($qs['u'])   { return [System.Web.HttpUtility]::UrlDecode($qs['u'])   }
          elseif ($qs['q'])   { return [System.Web.HttpUtility]::UrlDecode($qs['q'])   }
        }
      }

      'r20.rs6.net'      { if ($qs['u'])   { return [System.Web.HttpUtility]::UrlDecode($qs['u'])   } } # Constant Contact
      'urlsand.es'       { if ($qs['u'])   { return [System.Web.HttpUtility]::UrlDecode($qs['u'])   } } # Proofpoint
      'urldefense.com'   {
        $m = [regex]::Match($abs.AbsoluteUri, '__https?://[^_]+__')
        if ($m.Success) { return $m.Value.Trim('_') }
      }
      'urldefense.*'     { if ($qs['u'])   { return [System.Web.HttpUtility]::UrlDecode($qs['u'])   } } # Proofpoint v2

      'nam*.safelinks.protection.outlook.com' { if ($qs['url']) { return [System.Web.HttpUtility]::UrlDecode($qs['url']) } }
      '*.linkprotect.cudasvc.com'             { if ($qs['u'])   { return [System.Web.HttpUtility]::UrlDecode($qs['u'])   } }
      '*.mimecast.com'                        { if ($qs['u'])   { return [System.Web.HttpUtility]::UrlDecode($qs['u'])   } }
      'protect-*.mimecast.com'                { if ($qs['u'])   { return [System.Web.HttpUtility]::UrlDecode($qs['u'])   } }

      'click.email.*' {
        if     ($qs['u'])   { return [System.Web.HttpUtility]::UrlDecode($qs['u']) }
        elseif ($qs['url']) { return [System.Web.HttpUtility]::UrlDecode($qs['url']) }
      }

      't.umblr.com' {
        if ($qs['z']) {
          $t = _TryB64Url $qs['z']; if ($t) { return $t }
        }
      }

      default { }
    }

    foreach ($k in $qs.AllKeys) {
      if (-not $k) { continue }
      $t = _TryB64Url $qs[$k]
      if ($t) { return $t }
    }
  } catch {}
  return $u
}
# endregion

# region Get-GmailIds
function Get-GmailIds {

  param([int]$Max = 100)

  $acc = [System.Collections.Generic.List[string]]::new()
  $tok = $null

  while ($acc.Count -lt $Max) {
    $body = @{}
    if ($tok) { $body.pageToken = $tok }

    $resp = Invoke-RestMethod -Uri "$script:MailApiBase/gmail/list" `
                              -Method Post -ContentType 'application/json' `
                              -Body ($body | ConvertTo-Json)

    if (-not $resp) { break }

    # Normaliza a colección de "mensajes"
    $msgs = @()
    if ($resp.messages) { $msgs = @($resp.messages) }
    elseif ($resp.items) { $msgs = @($resp.items) }

    if (-not $msgs) { break }

    foreach ($m in $msgs) {
      $id = $null
      try {
        $id = if ($m -is [string]) { $m } else { $m.id }
      } catch {}

      if ($id) { [void]$acc.Add([string]$id) }
      if ($acc.Count -ge $Max) { break }
    }

    if ($acc.Count -ge $Max) { break }
    $tok = $resp.nextPageToken
    if (-not $tok) { break }
  }

  $acc | Select-Object -First $Max -Unique

}
# endregion


# region Get-Mail
function Get-Mail {
 param([Parameter(Mandatory=$true)][string]$Id) Get-GmailMessage -Id $Id 
}
# endregion


# region Get-MailHtmlRaw
function Get-MailHtmlRaw {

  param([Parameter(Mandatory=$true)][string]$Id)

  $html = $null
  try { $html = Invoke-RestMethod "$script:MailApiBase/gmail/get_body?id=$( [uri]::EscapeDataString($Id) )&format=html" -TimeoutSec 10 } catch {}
  if (-not $html) { try { $html = Invoke-RestMethod "$script:MailApiBase/gmail/get_body?id=$( [uri]::EscapeDataString($Id) )" -TimeoutSec 10 } catch {} }
  if (-not $html) {
    try {
      $html = Invoke-RestMethod -Uri "$script:MailApiBase/gmail/get_body" -Method POST -TimeoutSec 10 `
               -ContentType 'application/json' -Body (@{ id=$Id; format='html' } | ConvertTo-Json -Depth 5)
    } catch {}
  }
  if (-not $html) { throw "get_body no devolvió HTML para $Id" }
  [string]$html

}
# endregion


# region Repair-HtmlEncodingSmart
function Repair-HtmlEncodingSmart {

  param([Parameter(Mandatory=$true)][string]$Html)

  try { [Text.Encoding]::RegisterProvider([System.Text.CodePagesEncodingProvider]::Instance) | Out-Null } catch {}
  try { Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue } catch {}

  # 0) Decodifica entidades HTML por si vienen escapadas
  $s = try { [System.Web.HttpUtility]::HtmlDecode($Html) } catch { $Html }

  # Si parece sano, salimos
  if ($s -notmatch 'Ã|Â|â€™|â€“|â€”|â€¢|â€œ|â€\S|ï»¿|�') { return $s }

  $utf8   = [Text.Encoding]::UTF8
  $latin1 = [Text.Encoding]::GetEncoding(28591)
  $cp1252 = [Text.Encoding]::GetEncoding(1252)

  $cands = @($s)
  try { $cands += $utf8.GetString($latin1.GetBytes($s)) } catch {}
  try { $cands += $utf8.GetString($cp1252.GetBytes($s)) } catch {}

  function _Score([string]$t) {
    # menos patrones feos = mejor
    ([regex]::Matches($t,'Ã|Â(?![a-zA-Z])|â€™|â€“|â€”|â€¢|â€œ|â€\S|ï»¿|�')).Count
  }

  $best = $cands | Sort-Object @{e={ _Score $_ }}, @{e={ -($_.Length) }} | Select-Object -First 1

  # Normaliza charset: elimina metas previas y fuerza utf-8
  $best = [regex]::Replace($best,'(?is)<meta[^>]+charset\s*=\s*[^"''\s>]+[^>]*>','')
  $best = [regex]::Replace($best,'(?is)<head\b[^>]*>','${0}<meta charset="utf-8">')

  return $best

}
# endregion


# region Remove-TrackingFromHtmlV4
function Remove-TrackingFromHtmlV4 {

  param(
    [Parameter(Mandatory=$true)][string]$Html,
    [string[]]$Allow = @('^id$','^q$','^query$','^page$','^lang$','^s$'),
    [switch]$AllowOnly,
    [switch]$IncludeUnsubscribe   # <— NUEVO
  )

  try { Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue } catch {}

  $block = @(
    '^utm_','^trk','^li_','^mkt_','^mc_','^_hs','^hs','^hsa_','^ver','^spm','^sc_',
    '^gclid$','^fbclid$','^igshid$','^ref_src$','^yclid$','^oly_','^sr_share$',
    '^midToken$','^lipi$','^dm_t$','^eid$','^e$','^ocid$','^si$','^ga_','^_openstat$'
  )

  $pat = 'href\s*=\s*(["''])([^"''#]+)\1'

  return [regex]::Replace($Html, $pat, {
    param($m)
    $q  = $m.Groups[1].Value
    $u0 = $m.Groups[2].Value

    if (-not $u0 -or $u0 -match '^(mailto|tel):' -or $u0.StartsWith('#')) { return $m.Value }

    # ⬇️ ANTES se devolvía tal cual; ahora es opcional
    if (-not $IncludeUnsubscribe -and $u0 -match '(?i)\b(unsubscribe|optout|opt-out)\b') { return $m.Value }

    if (Get-Command Unwrap-RedirectUrl -ErrorAction SilentlyContinue) {
      $u0 = Unwrap-RedirectUrl $u0
    }

    $abs = $null
    $base = [Uri]::new('https://dummy.local/')
    $uri  = if ([Uri]::TryCreate($u0, [UriKind]::Absolute, [ref]$abs)) { $abs } else { [Uri]::new($base, $u0) }

    if ([string]::IsNullOrEmpty($uri.Query)) { return "href=$q$u0$q" }

    $src = [System.Web.HttpUtility]::ParseQueryString($uri.Query)
    $dst = [System.Web.HttpUtility]::ParseQueryString("")

    foreach ($k in $src.AllKeys) {
      if (-not $k) { continue }
      $isBlocked = $false; foreach ($rx in $block) { if ($k -match $rx) { $isBlocked = $true; break } }
      if ($isBlocked) { continue }
      $isAllowed = $false; foreach ($ax in $Allow) { if ($k -match $ax) { $isAllowed = $true; break } }
      if ($AllowOnly) { if ($isAllowed) { $dst[$k] = $src[$k] } }
      else { $dst[$k] = $src[$k] }
    }

    $b = [UriBuilder]$uri
    $b.Query = $dst.ToString()

    if ([Uri]::IsWellFormedUriString($u0, [UriKind]::Absolute)) {
      "href=$q$($b.Uri.AbsoluteUri)$q"
    } else {
      $rel = $b.Path
      if ($b.Query)    { $rel += '?' + $dst.ToString() }
      if ($b.Fragment) { $rel += $b.Fragment }
      "href=$q$rel$q"
    }
  }, 'IgnoreCase')

}
# endregion


# region Open-MailHtmlSmart
function Open-MailHtmlSmart {

  param([Parameter(Mandatory=$true)][string]$Id, [switch]$StripTracking, [switch]$AllowOnly, [switch]$IncludeUnsubscribe)
  $s   = Get-MailHtmlRaw -Id $Id
  $low = $s.ToLowerInvariant()
  $idx = -1; foreach ($tok in '<!doctype','<html','<head','<body','<table','<div'){ $p=$low.IndexOf($tok); if($p -ge 0){$idx=$p; break}}
  if ($idx -gt 0) { $s = $s.Substring($idx) }
  $s = Repair-HtmlEncodingSmart $s
  if ($StripTracking) { $s = Remove-TrackingFromHtmlV4 -Html $s -AllowOnly:$AllowOnly -IncludeUnsubscribe:$IncludeUnsubscribe }
  $path = Join-Path $env:TEMP ("mail_clean2_" + $Id + ".html")
  Set-Content -Path $path -Value $s -Encoding UTF8
  Start-Process $path | Out-Null
  $path

}
# endregion


# region Unwrap-RedirectUrl
function Unwrap-RedirectUrl {

  param([string]$u)
  try {
    function _TryB64Url([string]$s){
      try {
        if (-not $s) { return $null }
        $x = [System.Web.HttpUtility]::UrlDecode($s)
        $x = $x.Replace('-', '+').Replace('_','/')
        switch ($x.Length % 4) { 2 { $x += "=="; break } 3 { $x += "="; break } default {} }
        $bytes = [Convert]::FromBase64String($x)
        $t = [Text.Encoding]::UTF8.GetString($bytes)
        if ($t -match '^https?://') { return $t }
      } catch {}
      return $null
    }

    $abs = $null
    if (-not [Uri]::TryCreate($u, [UriKind]::Absolute, [ref]$abs)) { return $u }

    $domain = $abs.Host.ToLowerInvariant()
    $qraw   = if ([string]::IsNullOrEmpty($abs.Query)) { '' } else { $abs.Query.TrimStart('?') }
    $qs     = [System.Web.HttpUtility]::ParseQueryString($qraw)

    switch -Wildcard ($domain) {
      'www.linkedin.com' { if ($qs['url']) { return [System.Web.HttpUtility]::UrlDecode($qs['url']) } }

      'l.facebook.com'   { if ($qs['u'])   { return [System.Web.HttpUtility]::UrlDecode($qs['u'])   } }
      'l.messenger.com'  { if ($qs['u'])   { return [System.Web.HttpUtility]::UrlDecode($qs['u'])   } }

      'www.google.com' {
        if ($abs.AbsolutePath -like '/url*') {
          if     ($qs['url']) { return [System.Web.HttpUtility]::UrlDecode($qs['url']) }
          elseif ($qs['u'])   { return [System.Web.HttpUtility]::UrlDecode($qs['u'])   }
          elseif ($qs['q'])   { return [System.Web.HttpUtility]::UrlDecode($qs['q'])   }
        }
      }

      'r20.rs6.net'      { if ($qs['u'])   { return [System.Web.HttpUtility]::UrlDecode($qs['u'])   } } # Constant Contact
      'urlsand.es'       { if ($qs['u'])   { return [System.Web.HttpUtility]::UrlDecode($qs['u'])   } } # Proofpoint
      'urldefense.com'   {
        $m = [regex]::Match($abs.AbsoluteUri, '__https?://[^_]+__')
        if ($m.Success) { return $m.Value.Trim('_') }
      }
      'urldefense.*'     { if ($qs['u'])   { return [System.Web.HttpUtility]::UrlDecode($qs['u'])   } } # Proofpoint v2

      'nam*.safelinks.protection.outlook.com' { if ($qs['url']) { return [System.Web.HttpUtility]::UrlDecode($qs['url']) } }
      '*.linkprotect.cudasvc.com'             { if ($qs['u'])   { return [System.Web.HttpUtility]::UrlDecode($qs['u'])   } }
      '*.mimecast.com'                        { if ($qs['u'])   { return [System.Web.HttpUtility]::UrlDecode($qs['u'])   } }
      'protect-*.mimecast.com'                { if ($qs['u'])   { return [System.Web.HttpUtility]::UrlDecode($qs['u'])   } }

      'click.email.*' {
        if     ($qs['u'])   { return [System.Web.HttpUtility]::UrlDecode($qs['u']) }
        elseif ($qs['url']) { return [System.Web.HttpUtility]::UrlDecode($qs['url']) }
      }

      't.umblr.com' {
        if ($qs['z']) {
          $t = _TryB64Url $qs['z']; if ($t) { return $t }
        }
      }

      default { }
    }

    foreach ($k in $qs.AllKeys) {
      if (-not $k) { continue }
      $t = _TryB64Url $qs[$k]
      if ($t) { return $t }
    }
  } catch {}
  return $u

}
# endregion


# region Get-CharsetEncoding
function Get-CharsetEncoding {

  param([string]$Charset)
  try { [System.Text.Encoding]::RegisterProvider([System.Text.CodePagesEncodingProvider]::Instance) | Out-Null } catch {}
  if ([string]::IsNullOrWhiteSpace($Charset)) { return [System.Text.Encoding]::UTF8 }
  $c = $Charset.ToLowerInvariant()
  switch -regex ($c) {
    'utf-?8'              { [Text.Encoding]::UTF8 }
    'iso-8859-1|latin-?1' { [Text.Encoding]::GetEncoding(28591) }
    'windows-1252|cp1252' { [Text.Encoding]::GetEncoding(1252) }
    default { try { [Text.Encoding]::GetEncoding($c) } catch { [Text.Encoding]::UTF8 } }
  }

}
# endregion


# region Decode-EncodedWord
function Decode-EncodedWord {

  param([string]$Text)
  if (-not $Text) { return $Text }
  $pattern = '=\?([^?]+)\?([bBqQ])\?([^?]+)\?='
  $evaluator = {
    param($m)
    $enc  = Get-CharsetEncoding $m.Groups[1].Value
    $mode = $m.Groups[2].Value
    $data = $m.Groups[3].Value
    if ($mode -match '^[qQ]$') {
      $q = $data -replace '_',' '
      $bytes = New-Object 'System.Collections.Generic.List[byte]'
      $i=0; while ($i -lt $q.Length) {
        if ($q[$i] -eq '=') {
          if ($i+2 -lt $q.Length -and $q.Substring($i+1,2) -match '^[0-9A-Fa-f]{2}$') {
            [void]$bytes.Add([Convert]::ToByte($q.Substring($i+1,2),16)); $i+=3
          } else { [void]$bytes.Add([byte][char]'='); $i++ }
        } else { [void]$bytes.Add([byte][char]$q[$i]); $i++ }
      }
      $enc.GetString($bytes.ToArray())
    } else {
      try { $enc.GetString([Convert]::FromBase64String($data)) } catch { $m.Value }
    }
  }
  [regex]::Replace($Text, $pattern, $evaluator)

}
# endregion


# region Convert-FromMojibake
function Convert-FromMojibake {

  param([string]$Text)
  if (-not $Text) { return $Text }
  if ($Text -notmatch '[ÃÂâ¢°·]') { return $Text }
  try { [System.Text.Encoding]::RegisterProvider([System.Text.CodePagesEncodingProvider]::Instance) | Out-Null } catch {}
  $utf8=[Text.Encoding]::UTF8
  $cp1252=[Text.Encoding]::GetEncoding(1252)
  $latin1=[Text.Encoding]::GetEncoding(28591)
  $fix1 = $utf8.GetString($cp1252.GetBytes($Text))
  if ($fix1 -match '[ÃÂâ¢°·]') {
    $fix2 = $utf8.GetString($latin1.GetBytes($Text))
    if ($fix2 -notmatch '[ÃÂâ¢°·]') { return $fix2 }
  }
  $fix1

}
# endregion


# region Fix-HeaderText
function Fix-HeaderText {

  param([string]$Text)
  if (-not $Text) { return $Text }
  $t = Decode-EncodedWord $Text
  if ($t -match '[ÃÂâ¢°·]') { $t = Convert-FromMojibake $t }
  ($t -replace '^\s+|\s+$','')

}
# endregion


# region Repair-MojibakeSmartV2
function Repair-MojibakeSmartV2 {

  param([string]$Text)
  if (-not $Text) { return $Text }

  # Paso 0: estándar
  $t = Fix-HeaderText $Text

  # Paso 1: decode entidades HTML (si hubiera)
  try {
    Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue
    $t = [System.Web.HttpUtility]::HtmlDecode($t)
  } catch {}

  if ($t -notmatch '[�Ãð]|\?\?') { return $t }

  # Paso 2: intentos cp1252/latin1 -> utf8
  try {
    $utf8   = [Text.Encoding]::UTF8
    $latin1 = [Text.Encoding]::GetEncoding(28591)
    $cp1252 = [Text.Encoding]::GetEncoding(1252)
    $cand1  = $utf8.GetString($latin1.GetBytes($t))
    $cand2  = $utf8.GetString($cp1252.GetBytes($t))

    function _Score([string]$s){
      ([regex]::Matches($s,'[�Ãð]').Count) + ([regex]::Matches($s,'\?\?').Count)
    }
    $t = @($t,$cand1,$cand2) | Sort-Object @{e={ _Score $_ }}, @{e={ -($_.Length) }} | Select-Object -First 1
  } catch {}

  # Paso 3: heurísticas suaves (sin Unicode en los literales)
  $rsquo = [string][char]0x2019

  # a) letra ?? letra  → apóstrofo tipográfico
  $rep_a = '$1' + $rsquo + '$2'
  $t = [regex]::Replace($t, '(\p{L})\?\?(\p{L})', $rep_a)

  # b) letra ?? (fin/puntuación) → apóstrofo
  $rep_b = '$1' + $rsquo
  $t = [regex]::Replace($t, '(\p{L})\?\?(?=\s|$|[.!,;:])', $rep_b)

  # c) ?? rodeado de espacios → em-dash
  $t = [regex]::Replace($t, '\s\?\?\s', ' — ')

  # d) limpieza final
  $t = [regex]::Replace($t, '�+', '')
  $t = [regex]::Replace($t, '\?{2,}', '?')

  return $t.Trim()

}
# endregion

