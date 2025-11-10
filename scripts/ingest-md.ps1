param(
  [string]$Folder = "$(Get-Location)\content\converted",
  [string]$Namespace = "industrial",
  [string]$Collection = "rmsg_docs",
  [int]$ChunkChars = 800,
  [int]$Overlap = 150
)

$ErrorActionPreference = "Stop"
chcp 65001 | Out-Null
$OutputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::UTF8

function Get-Chunks($text, $chunkSize, $overlap) {
  $chunks = @()
  for ($i=0; $i -lt $text.Length; $i += ($chunkSize - $overlap)) {
    $end = [Math]::Min($i + $chunkSize, $text.Length)
    $chunks += $text.Substring($i, $end - $i)
    if ($end -eq $text.Length) { break }
  }
  return ,$chunks
}

Write-Host "Carpeta: $Folder"
$files = Get-ChildItem $Folder -Filter *.md -File -Recurse
if (!$files) { Write-Host "No hay .md para ingestar."; exit 0 }

foreach ($f in $files) {
  Write-Host "`n===> $($f.FullName)"
  $text = [string](Get-Content $f.FullName -Raw -Encoding UTF8)
  $chunks = Get-Chunks $text $ChunkChars $Overlap

  $i = 0
  foreach ($c in $chunks) {
    $i++
    # Embedding con 'prompt' (Ollama)
    $embBody = @{ model="nomic-embed-text"; prompt=$c } | ConvertTo-Json -Compress
    $embRes  = Invoke-RestMethod -Uri http://localhost:11434/api/embeddings `
                -Method Post -ContentType "application/json" `
                -Body ([Text.Encoding]::UTF8.GetBytes($embBody))
    $vec = $embRes.embedding
    if (!$vec -or $vec.Count -ne 768) {
      Write-Warning "Embedding inválido en chunk #$i ($($vec?.Count)) -> salto"
      continue
    }

    $uuid=[guid]::NewGuid().Guid

    # Mapea ruta host -> contenedor 'api'  (C:\...\rmsg-private-chat-starter\rmsg-private-chat -> /app)
    $src = ($f.FullName -replace [regex]::Escape($(Get-Location)), "/app") -replace "\\","/"

    $point = @{
      points = @(@{
        id = $uuid
        vector = $vec
        payload = @{
          source    = $src
          namespace = $Namespace
          title     = [IO.Path]::GetFileNameWithoutExtension($f.Name)
          text      = $c
        }
      })
    } | ConvertTo-Json -Depth 6 -Compress

    Invoke-RestMethod -Uri "http://localhost:6333/collections/$Collection/points?wait=true" `
      -Method Put -ContentType "application/json" `
      -Body ([Text.Encoding]::UTF8.GetBytes($point)) | Out-Null
  }
}
Write-Host "`nListo."
