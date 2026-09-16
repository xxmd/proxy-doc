param(
  [string]$ClashApi = 'http://127.0.0.1:9099',
  [string]$Proxy    = 'http://127.0.0.1:7899',
  [string]$Group    = 'CMP',
  [int]$Rounds      = 5,           # TTFB 采样轮数
  [int]$SpeedSec    = 15,          # 每个吞吐目标的最长下载时间
  [string]$OutDir   = '.'
)

$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$csv = Join-Path $OutDir "compare-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
$UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36'

function Median($a) {
  if (-not $a -or $a.Count -eq 0) { return $null }
  $s = @($a | Sort-Object)
  $s[[int][math]::Floor(($s.Count - 1) / 2)]
}
function P90($a) {
  if (-not $a -or $a.Count -eq 0) { return $null }
  $s = @($a | Sort-Object)
  $s[[int][math]::Floor(($s.Count - 1) * 0.9)]
}

# 经代理抓 TTFB / TLS 握手耗时（毫秒）
function Get-Ttfb($url, $rounds) {
  $ttfb = @(); $tls = @()
  for ($i = 0; $i -lt $rounds; $i++) {
    $o = & curl.exe -s -A $UA -o NUL -x $Proxy --max-time 25 `
        -w "%{time_starttransfer}|%{time_appconnect}|%{http_code}" $url 2>$null
    if ($o) {
      $p = "$o".Trim() -split '\|'
      if ($p.Count -ge 3 -and $p[2] -eq '200') {
        $ttfb += [double]$p[0] * 1000
        if ([double]$p[1] -gt 0) { $tls += [double]$p[1] * 1000 }
      }
    }
    Start-Sleep -Milliseconds 250
  }
  [pscustomobject]@{ Ttfb = $ttfb; Tls = $tls }
}

# 经代理测吞吐（Mbps）
# 注意：--max-time 到点后 curl 退出码是 28，但数据是有效的，不能当失败处理
function Get-Speed($url, $seconds) {
  $o = & curl.exe -s -L -A $UA -o NUL -x $Proxy --max-time $seconds `
      -w "%{speed_download}|%{http_code}|%{size_download}" $url 2>$null
  if (-not $o) { return $null }
  $p = "$o".Trim() -split '\|'
  $bps = [double]$p[0]
  if ($bps -le 0) { return $null }
  [pscustomobject]@{
    Mbps  = [math]::Round($bps * 8 / 1MB, 2)
    Bytes = [long]$p[2]
    Code  = $p[1]
  }
}

# ---------- 探测目标 ----------
$tgTtfb = [ordered]@{
  'TG-Web'  = 'https://t.me/telegram'          # TG 网页前端
  'TG-Core' = 'https://core.telegram.org/'     # TG 官网
  'TG-CDN'  = 'https://telegram.org/img/t_logo.png'
}
$speedTargets = [ordered]@{
  'TG-Desktop' = 'https://telegram.org/dl/desktop/win64'   # TG 官方分发（真实 TG 文件）
  'TG-APK'     = 'https://telegram.org/dl/android/apk'     # TG 安卓包
  'Baseline'   = 'http://speedtest.tele2.net/100MB.zip'    # 中性带宽基线
}

Write-Host "`n=== 香港节点对比（自建 vs 机场）@ $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ===" -ForegroundColor Cyan
$root  = ConvertFrom-Json (& curl.exe -s --max-time 5 "$ClashApi/proxies")
$g     = $root.proxies.PSObject.Properties[$Group].Value
$nodes = $g.all
$original = $g.now
Write-Host "节点: $($nodes -join ' / ')`n" -ForegroundColor Yellow

$all = New-Object System.Collections.Generic.List[object]

foreach ($node in $nodes) {
  Write-Host "[$node]" -ForegroundColor Green
  try {
    Invoke-RestMethod -Uri "$ClashApi/proxies/$Group" -Method Put -Body (@{name=$node}|ConvertTo-Json) -ContentType 'application/json' | Out-Null
    Start-Sleep -Milliseconds 800
  } catch { Write-Host "  切换失败" -ForegroundColor Red; continue }

  $row = [ordered]@{ Node = $node }

  foreach ($k in $tgTtfb.Keys) {
    $r = Get-Ttfb $tgTtfb[$k] $Rounds
    $row["$k-TTFB"] = if ($r.Ttfb.Count) { [math]::Round((Median $r.Ttfb),0) } else { $null }
    $row["$k-p90"]  = if ($r.Ttfb.Count) { [math]::Round((P90 $r.Ttfb),0) } else { $null }
    $row["$k-TLS"]  = if ($r.Tls.Count)  { [math]::Round((Median $r.Tls),0) } else { $null }
    $row["$k-ok"]   = "$($r.Ttfb.Count)/$Rounds"
    Write-Host ("   {0,-8} TTFB中位={1,5}ms  p90={2,5}ms  TLS={3,5}ms  ({4})" -f $k, $row["$k-TTFB"], $row["$k-p90"], $row["$k-TLS"], $row["$k-ok"])
  }

  foreach ($k in $speedTargets.Keys) {
    $s = Get-Speed $speedTargets[$k] $SpeedSec
    $row["$k-Mbps"] = if ($s) { $s.Mbps } else { $null }
    $row["$k-MB"]   = if ($s) { [math]::Round($s.Bytes/1MB,1) } else { 0 }
    Write-Host ("   {0,-10} {1,7} Mbps   下载 {2,6} MB" -f $k, $row["$k-Mbps"], $row["$k-MB"])
  }

  $all.Add([pscustomobject]$row)
}

try { Invoke-RestMethod -Uri "$ClashApi/proxies/$Group" -Method Put -Body (@{name=$original}|ConvertTo-Json) -ContentType 'application/json' | Out-Null } catch { }

Write-Host "`n================= 对比结果 =================" -ForegroundColor Cyan
$all | Format-Table -AutoSize
$all | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8
Write-Host "CSV: $csv`n" -ForegroundColor Green

Write-Host "判读要点:" -ForegroundColor Cyan
Write-Host "  * TG-*-TTFB  点开图片/视频多久开始动 —— 越低越跟手"
Write-Host "  * TG-Desktop / TG-APK  真实 Telegram 文件下载速度 —— 决定视频能否流畅播"
Write-Host "  * Baseline   中性带宽基线 —— 用来分离「节点带宽」和「TG CDN 速度」"
Write-Host "  * p90 与中位数差距大 = 抖动大，TG 会表现为偶尔转圈"
