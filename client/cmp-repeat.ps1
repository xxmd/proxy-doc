param(
  [string]$ClashApi = 'http://127.0.0.1:9099',
  [string]$Proxy    = 'http://127.0.0.1:7899',
  [string]$Group    = 'CMP',
  [string[]]$Nodes  = @('HK-Self','SSRDOG-HK-05','SSRDOG-HK-02','SSRDOG-HK-01'),
  [int]$Times       = 3,
  [int]$Sec         = 12
)

$UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/120.0'
$targets = [ordered]@{
  'TG-Desktop' = 'https://telegram.org/dl/desktop/win64'
  'Baseline'   = 'http://speedtest.tele2.net/100MB.zip'
}

function Measure-Speed($url, $sec) {
  $o = & curl.exe -s -L -A $UA -o NUL -x $Proxy --max-time $sec -w "%{speed_download}|%{size_download}" $url 2>$null
  if (-not $o) { return 0 }
  $p = "$o".Trim() -split '\|'
  if ([double]$p[0] -le 0) { return 0 }
  [math]::Round([double]$p[0] * 8 / 1MB, 1)
}

Write-Host "`n重复吞吐测试：每节点每目标 $Times 次，每次最长 $Sec 秒`n"
$rows = New-Object System.Collections.Generic.List[object]

foreach ($n in $Nodes) {
  Invoke-RestMethod -Uri "$ClashApi/proxies/$Group" -Method Put -Body (@{name=$n}|ConvertTo-Json) -ContentType 'application/json' | Out-Null
  Start-Sleep -Milliseconds 900
  $row = [ordered]@{ Node = $n }
  foreach ($k in $targets.Keys) {
    $vals = @()
    for ($i = 0; $i -lt $Times; $i++) { $vals += (Measure-Speed $targets[$k] $Sec) }
    $sorted = @($vals | Sort-Object)
    $row["$k 各次"] = ($vals -join ' / ')
    $row["$k 中位"] = $sorted[[int][math]::Floor(($sorted.Count-1)/2)]
    $row["$k 最好"] = $sorted[-1]
  }
  $rows.Add([pscustomobject]$row)
  Write-Host ("[{0}]" -f $n)
  foreach ($k in $targets.Keys) { Write-Host ("   {0,-12} 各次 {1}   中位 {2} Mbps   最好 {3} Mbps" -f $k, $row["$k 各次"], $row["$k 中位"], $row["$k 最好"]) }
}

Write-Host "`n=== 汇总 ==="
$rows | Format-Table -AutoSize
