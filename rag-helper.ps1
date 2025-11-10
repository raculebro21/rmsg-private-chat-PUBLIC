function Invoke-RagAsk {
  param(
    [Parameter(Mandatory=$true)][string]$Query,
    [int]$K = 5,
    [string]$Base = "http://127.0.0.1:8088"
  )
  $h = @{ 'Accept-Encoding'='identity' }
  $u = "$Base/rag/ask?q=$( [uri]::EscapeDataString($Query) )&k=$K"
  $r = Invoke-WebRequest $u -Headers $h -TimeoutSec 120
  $obj = $r.Content | ConvertFrom-Json
  # Muestra hits en tabla breve
  $obj.hits | Select-Object score, title, chunk_index, source_path, @{n='text';e={$_.text.Substring(0,[Math]::Min(120,$_.text.Length))}}
  return $obj
}
