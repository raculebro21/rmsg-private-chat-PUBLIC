param(
  [string]$Base = 'http://127.0.0.1:8088',
  [ValidateSet('table','csv','json')]
  [string]$OutFormat = 'table',
  [string]$OutFile
)

function Get-JsonUtf8 {
  param([string]$Url, [hashtable]$Headers=@{})
  $resp = Invoke-WebRequest $Url -Headers $Headers
  $sr   = New-Object IO.StreamReader($resp.RawContentStream, [Text.Encoding]::UTF8, $true)
  $json = $sr.ReadToEnd(); $sr.Close()
  $json | ConvertFrom-Json
}

$h = @{ 'Accept-Encoding' = 'identity' }
$p = Get-JsonUtf8 "$Base/me" -Headers $h

$norm = [Text.NormalizationForm]::FormC
$row = [pscustomobject]@{
  id          = $p.id
  email       = $p.email
  verified    = $p.verified_email
  name        = ($p.name).Normalize($norm)
  given_name  = ($p.given_name).Normalize($norm)
  family_name = ($p.family_name).Normalize($norm)
  picture     = $p.picture
  hd          = $p.hd
}

if (-not $OutFile) { $row | Format-Table -AutoSize; return }

$enc = [Text.UTF8Encoding]::new($false)
switch ($OutFormat) {
  'csv'  {
    $tmp = New-TemporaryFile
    $row | Export-Csv $tmp -NoTypeInformation -Encoding UTF8
    [IO.File]::WriteAllText($OutFile,(Get-Content $tmp -Raw),$enc)
    Remove-Item $tmp -Force
  }
  'json' { [IO.File]::WriteAllText($OutFile, ($row | ConvertTo-Json -Depth 6), $enc) }
  default{ [IO.File]::WriteAllText($OutFile, ($row | Format-Table -AutoSize | Out-String), $enc) }
}
Write-Host "✅ Exportado: $OutFile"
