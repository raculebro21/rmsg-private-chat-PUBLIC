# ================= QDRANT-TOOLS.ps1 =================
# Utilidades robustas para listar y borrar puntos en Qdrant usando /points/scroll
# (evita /points/count, que falla con algunos builds).

param(
  [string]$QDRANT = "http://localhost:6333",
  [string]$COLL   = "rmsg_docs"
)

function Get-QdrantIdsByFilter {
  <#
    .SYNOPSIS
      Devuelve IDs (string) de puntos que cumplan el filtro.
    .PARAMETER Filter
      Hashtable con formato de filtro Qdrant:
      @{ must = @(@{ key="source"; match=@{ value="/app/content/foo.md" }}) }
  #>
  param(
    [hashtable]$Filter,
    [int]$Limit = 1000
  )
  $ids = New-Object System.Collections.Generic.List[string]
  $offset = $null

  do {
    $reqObj = @{
      limit         = [Math]::Min($Limit, 200)  # 200 seguro
      with_payload  = $false
      filter        = $Filter
    }
    if ($offset) { $reqObj.offset = $offset }

    $body = $reqObj | ConvertTo-Json -Depth 8 -Compress
    $resp = Invoke-RestMethod -Uri "$QDRANT/collections/$COLL/points/scroll" `
             -Method Post -ContentType "application/json" `
             -Body ([Text.Encoding]::UTF8.GetBytes($body))

    foreach ($p in $resp.result.points) {
      $ids.Add([string]$p.id) | Out-Null
    }
    $offset = $resp.result.next_page_offset
  } while ($offset -ne $null)

  return ,$ids
}

function Remove-QdrantPointsByIds {
  <#
    .SYNOPSIS
      Borra puntos por lista de IDs.
  #>
  param(
    [string[]]$Ids
  )
  if (!$Ids -or $Ids.Count -eq 0) {
    Write-Host "No hay IDs para borrar. (Nada que hacer)"
    return
  }
  $delBody = @{ points = $Ids } | ConvertTo-Json -Compress
  Invoke-RestMethod -Uri "$QDRANT/collections/$COLL/points/delete?wait=true" `
    -Method Post -ContentType "application/json" `
    -Body ([Text.Encoding]::UTF8.GetBytes($delBody)) | Out-Null
}

function Remove-QdrantByFilter {
  <#
    .SYNOPSIS
      Borra puntos que cumplan un filtro (usa scroll + delete).
    .PARAMETER Filter
      Hashtable de filtro Qdrant.
    .PARAMETER DryRun
      Si se especifica, no borra; solo lista y cuenta.
  #>
  param(
    [hashtable]$Filter,
    [switch]$DryRun
  )
  $ids = Get-QdrantIdsByFilter -Filter $Filter
  Write-Host ("Coincidencias: {0}" -f $ids.Count)

  if ($DryRun) {
    Write-Host "DryRun=ON -> no se borra nada. Muestra primeros 10 IDs:"
    $ids | Select-Object -First 10 | ForEach-Object { " - $_" }
    return
  }

  if ($ids.Count -gt 0) {
    Write-Host "Borrando..."
    Remove-QdrantPointsByIds -Ids $ids
    Start-Sleep -Milliseconds 300
    $postIds = Get-QdrantIdsByFilter -Filter $Filter
    Write-Host ("Quedan: {0}" -f $postIds.Count)
  } else {
    Write-Host "Nada que borrar."
  }
}
# =============== FIN QDRANT-TOOLS.ps1 ===============
