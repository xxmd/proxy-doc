<#
.SYNOPSIS
  香港代理链路 —— 大陆客户端侧基准测试（延迟 / 丢包 / 握手 / 端到端吞吐）

.DESCRIPTION
  分四层测量，结果打印成表并写入 CSV：
    1) ICMP 延迟与丢包      —— 到 HK 机器的裸链路质量
    2) TCP 握手延迟         —— ICMP 被禁时用这个
    3) Clash/mihomo 节点延迟 —— 真正经代理的 HTTP 往返（需要 external-controller）
    4) 经代理的下载吞吐     —— curl 走本地代理端口拉大文件

  兼容 Windows PowerShell 5.1 与 PowerShell 7。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\bench-client.ps1 -ServerIP 203.0.113.10 -Port 443 -ProxyName "HK-Reality"

.EXAMPLE
  # 晚高峰对比：分别在 09:00 和 21:00 各跑一次，比较 CSV
  powershell -ExecutionPolicy Bypass -File .\bench-client.ps1 -ServerIP 203.0.113.10 -Port 443 -DownloadRounds 5
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$ServerIP,      # HK 服务器 IP
  [int]$Port = 443,                                    # 代理监听端口（测 TCP 握手用）
  [string]$Proxy = 'http://127.0.0.1:7890',            # Clash 本地混合代理端口
  [string]$ClashApi = 'http://127.0.0.1:9090',         # mihomo external-controller
  [string]$ClashSecret = '',                           # external-controller secret（没有就留空）
  [string]$ProxyName = '',                             # 节点名，留空则跳过第 3 层
  [int]$PingCount = 30,
  [int]$DownloadRounds = 3,
  [long]$DownloadBytes = 100000000,                    # 每轮下载字节数（默认 100MB）
  [string]$OutDir = '.'
)

$ErrorActionPreference = 'Continue'
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$csv = Join-Path $OutDir "bench-client-$stamp.csv"
$rows = New-Object System.Collections.Generic.List[object]

function Add-Row([string]$Metric, $Value, [string]$Note = '') {
  $rows.Add([pscustomobject]@{ Time = (Get-Date -Format 'HH:mm:ss'); Metric = $Metric; Value = $Value; Note = $Note })
}

function Get-Stats([double[]]$Values) {
  if (-not $Values -or $Values.Count -eq 0) { return $null }
  $s = @($Values | Sort-Object)
  $avg = ($Values | Measure-Object -Average).Average
  $idx = [int][math]::Floor(($s.Count - 1) * 0.95)
  [pscustomobject]@{
    N   = $Values.Count
    Avg = [math]::Round($avg, 1)
    Min = [math]::Round($s[0], 1)
    Max = [math]::Round($s[-1], 1)
    P95 = [math]::Round($s[$idx], 1)
  }
}

Write-Host "`n=== HK 代理链路基准测试 @ $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ===" -ForegroundColor Cyan
Write-Host "目标: $ServerIP`:$Port   代理: $Proxy`n"

# ---------- 1) ICMP ----------
Write-Host "[1/4] ICMP 延迟与丢包 ($PingCount 次)..." -ForegroundColor Yellow
$lat = @()
try {
  $tcParams = @{ Count = $PingCount; ErrorAction = 'SilentlyContinue' }
  if ((Get-Command Test-Connection).Parameters.ContainsKey('TargetName')) { $tcParams['TargetName'] = $ServerIP }
  else { $tcParams['ComputerName'] = $ServerIP }   # Windows PowerShell 5.1
  $resp = Test-Connection @tcParams
  foreach ($r in $resp) {
    $v = if ($null -ne $r.Latency) { $r.Latency } elseif ($null -ne $r.ResponseTime) { $r.ResponseTime } else { $null }
    if ($null -ne $v) { $lat += [double]$v }
  }
} catch { }

if ($lat.Count -gt 0) {
  $st = Get-Stats $lat
  $loss = [math]::Round(100.0 * ($PingCount - $lat.Count) / $PingCount, 1)
  $jitr = if ($lat.Count -gt 1) { [math]::Round((Get-Stats $lat).P95 - (Get-Stats $lat).Min, 1) } else { 0 }
  Write-Host ("      avg={0}ms  min={1}  max={2}  p95={3}  丢包={4}%" -f $st.Avg, $st.Min, $st.Max, $st.P95, $loss)
  Add-Row 'icmp_avg_ms' $st.Avg "min=$($st.Min) max=$($st.Max) p95=$($st.P95) loss=${loss}%"
} else {
  Write-Host "      ICMP 无响应（被防火墙/运营商屏蔽）—— 看第 2 层 TCP 握手" -ForegroundColor DarkYellow
  Add-Row 'icmp_avg_ms' 'N/A' 'ICMP blocked or 100% loss'
}

# ---------- 2) TCP 握手 ----------
Write-Host "[2/4] TCP 握手延迟 x10..." -ForegroundColor Yellow
$tcp = @()
for ($i = 0; $i -lt 10; $i++) {
  $c = $null; $sw = [System.Diagnostics.Stopwatch]::StartNew()
  try {
    $c = [System.Net.Sockets.TcpClient]::new()
    $ar = $c.BeginConnect($ServerIP, $Port, $null, $null)
    if ($ar.AsyncWaitHandle.WaitOne(3000)) { $c.EndConnect($ar); $sw.Stop(); $tcp += $sw.Elapsed.TotalMilliseconds }
  } catch { } finally { if ($c) { $c.Close() } }
  Start-Sleep -Milliseconds 150
}
if ($tcp.Count -gt 0) {
  $st = Get-Stats $tcp
  Write-Host ("      avg={0}ms  min={1}  max={2}  p95={3}  成功率={4}/10" -f $st.Avg, $st.Min, $st.Max, $st.P95, $tcp.Count)
  Add-Row 'tcp_connect_avg_ms' $st.Avg "ok=$($tcp.Count)/10 p95=$($st.P95)"
} else {
  Write-Host "      端口 $Port 连不上（服务没起 / 被墙 / 防火墙未放行）" -ForegroundColor Red
  Add-Row 'tcp_connect_avg_ms' 'FAIL' "port $Port unreachable"
}

# ---------- 3) Clash 节点真实延迟 ----------
if ($ProxyName) {
  Write-Host "[3/4] Clash 节点延迟: $ProxyName x10..." -ForegroundColor Yellow
  $hdr = @{}
  if ($ClashSecret) { $hdr['Authorization'] = "Bearer $ClashSecret" }
  $url = "$ClashApi/proxies/$([uri]::EscapeDataString($ProxyName))/delay?timeout=5000&url=http://www.gstatic.com/generate_204"
  $d = @()
  for ($i = 0; $i -lt 10; $i++) {
    try {
      $r = Invoke-RestMethod -Uri $url -Headers $hdr -TimeoutSec 8 -ErrorAction Stop
      if ($null -ne $r.delay) { $d += [double]$r.delay }
    } catch { }
    Start-Sleep -Milliseconds 150
  }
  if ($d.Count -gt 0) {
    $st = Get-Stats $d
    Write-Host ("      avg={0}ms  min={1}  max={2}  p95={3}  成功={4}/10" -f $st.Avg, $st.Min, $st.Max, $st.P95, $d.Count)
    Add-Row 'clash_node_avg_ms' $st.Avg "ok=$($d.Count)/10 p95=$($st.P95)"
  } else {
    Write-Host "      全部超时：检查 ClashApi/secret/节点名，或节点本身不通" -ForegroundColor Red
    Add-Row 'clash_node_avg_ms' 'FAIL' 'all timeout'
  }
} else {
  Write-Host "[3/4] 跳过 Clash 节点延迟（未指定 -ProxyName）" -ForegroundColor DarkGray
}

# ---------- 4) 经代理的吞吐 ----------
Write-Host "[4/4] 经代理下载吞吐 x$DownloadRounds （每轮 $([math]::Round($DownloadBytes/1MB)) MB）..." -ForegroundColor Yellow
$curl = (Get-Command curl.exe -ErrorAction SilentlyContinue)
if (-not $curl) {
  Write-Host "      找不到 curl.exe，跳过" -ForegroundColor Red
} else {
  $urls = @(
    "https://speed.cloudflare.com/__down?bytes=$DownloadBytes",  # Cloudflare 就近节点
    "https://cachefly.cachefly.net/100mb.test"                   # 海外 CDN，看长距离链路
  )
  foreach ($u in $urls) {
    $sp = @()
    for ($i = 1; $i -le $DownloadRounds; $i++) {
      # curl 的 speed_download 单位是 byte/s
      $out = & curl.exe -s -x $Proxy -o NUL --max-time 90 `
        -w "%{speed_download}|%{time_total}|%{http_code}" $u 2>$null
      if ($LASTEXITCODE -eq 0 -and $out) {
        $p = "$out".Trim() -split '\|'
        $mbps = [math]::Round([double]$p[0] * 8 / 1MB, 2)
        Write-Host ("      [{0}] {1:N1} Mbps  用时 {2}s  HTTP {3}" -f $i, $mbps, $p[1], $p[2])
        if ($mbps -gt 0) { $sp += $mbps }
      } else {
        Write-Host "      [$i] 失败 (exit=$LASTEXITCODE)" -ForegroundColor DarkYellow
      }
      Start-Sleep -Seconds 2
    }
    if ($sp.Count -gt 0) {
      $st = Get-Stats $sp
      $host_ = ([uri]$u).Host
      Add-Row "dl_${host_}_mbps" $st.Avg "min=$($st.Min) max=$($st.Max) n=$($st.Count)"
    }
  }
  Write-Host "`n  提示：单流 curl 只反映『单线程体验』。总带宽上限请用 iperf3 -P 8 经 TUN 测。" -ForegroundColor DarkGray
}

# ---------- 输出 ----------
$rows | Format-Table -AutoSize
$rows | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8
Write-Host "结果已保存: $csv`n" -ForegroundColor Green
Write-Host "判读要点:" -ForegroundColor Cyan
Write-Host "  * ICMP ~40ms 而节点延迟 >250ms  => 代理软件/DNS/端口被干扰"
Write-Host "  * 丢包 >1% 或 p95 远大于 avg    => 线路拥塞，考虑 Hysteria2 或换线路"
Write-Host "  * 白天快、20:00-23:00 断崖下跌  => 运营商跨境 QoS / 商家超售"
