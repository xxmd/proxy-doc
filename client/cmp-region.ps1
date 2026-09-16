param(
  [string]$ClashApi = 'http://127.0.0.1:9099',
  [string]$Proxy    = 'http://127.0.0.1:7899',
  [string]$Group    = 'CMP',
  [string[]]$Nodes  = @('HK-Self','SSRDOG-HK-02'),
  [int]$Sec         = 12,
  [int]$Times       = 2
)

$UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/120.0'

# 欧洲 vs 亚洲 对照目标（TG 的 DC 分布在阿姆斯特丹/新加坡/迈阿密）
$targets = [ordered]@{
  'NL-Amsterdam' = 'https://mirror.nl.leaseweb.net/speedtest/100mb.bin'
  'SG-Singapore' = 'https://speedtest.singapore.linode.com/100MB-singapore.bin'
  'US-Miami'     = 'https://mirror.us-midwest-1.nexcess.net/speedtest/100mb.bin'
}

function Get-Speed($url, $sec) {
  $o = & curl.exe -s -L -A $UA -o NUL -x $Proxy --max-time $sec -w "%{speed_download}|%{http_code}|%{size_download}" $url 2>$null
  if (-not $o) { return $null }
  $p = "$o".Trim() -split '\|'
  if ([double]$p[0] -le 0) { return $null }
  [math]::Round([double]$p[0] * 8 / 1MB, 1)
}

Write-Host "`n=== 方向性带宽对照（TG DC 在阿姆斯特丹/新加坡/迈阿密）===" -ForegroundColor Cyan
$rows = New-Object System.Collections.Generic.List[object]

foreach ($n in $Nodes) {
  Invoke-RestMethod -Uri "$ClashApi/proxies/$Group" -Method Put -Body (@{name=$n}|ConvertTo-Json) -ContentType 'application/json' | Out-Null
  Start-Sleep -Milliseconds 900
  $row = [ordered]@{ Node = $n }
  Write-Host "[$n]"
  foreach ($k in $targets.Keys) {
    $v = @()
    for ($i = 0; $i -lt $Times; $i++) { $v += (Get-Speed $targets[$k] $Sec) }
    $ok = @($v | Where-Object { $_ -ne $null })
    $row[$k] = if ($ok.Count) { [math]::Round(($ok | Measure-Object -Average).Average, 1) } else { 0 }
    Write-Host ("   {0,-14} {1} Mbps   (原始: {2})" -f $k, $row[$k], (($v | ForEach-Object { if ($null -eq $_) {'失败'} else {$_} }) -join ' / '))
  }
  $rows.Add([pscustomobject]$row)
}

Write-Host "`n=== 汇总（Mbps）==="
$rows | Format-Table -AutoSize
