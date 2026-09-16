<#
.SYNOPSIS
  逐节点探测「真实落地」：出口 IP / ISP / ASN / Cloudflare colo / 落地 ping + 端到端延迟

.DESCRIPTION
  适用场景：中转机场（所有"节点"共用同一个入口 IP，仅端口不同），其地区标签常常
  与实际出口不符（假落地）。本脚本通过 mihomo external-controller 依次把代理组切到
  每个真实节点，再经本地代理端口发起探测：

    [落地真身] https://api.ip.sb/geoip                  -> 出口IP / ISP / ASN / 国家 / 城市
               https://www.cloudflare.com/cdn-cgi/trace -> colo(离出口最近的 CF 机房) / loc
               http://ip-api.com/json/                  -> 备用源（前两个失败时兜底）
    [落地延迟] 直接 ping 出口 IP（-PingExit）—— 最硬的"你->落地"物理 RTT 证据
    [端到端]   mihomo API delay(多URL) + curl TTFB（-GeoOnly 可跳过）

  重要：AnyTLS 不是标准 HTTP/SOCKS 协议，必须由 mihomo/Clash 客户端承载。
  不开 Clash 就无法探测任何节点的落地 —— 这一步必须先启动 Clash Verge。

.EXAMPLE
  # 最快：只做落地真身普查
  powershell -ExecutionPolicy Bypass -File .\bench-nodes.ps1 -GeoOnly -Restore

.EXAMPLE
  # 重点地区：落地真身 + 出口 ping + 端到端延迟
  powershell -ExecutionPolicy Bypass -File .\bench-nodes.ps1 -NodeFilter 'Hong Kong|Japan|United States' -PingExit -Rounds 3
#>
[CmdletBinding()]
param(
  [string]$ClashApi = 'http://127.0.0.1:9090',
  [string]$ClashSecret = '',                       # Clash Verge 设置里的「密钥」，没有就留空
  [string]$Proxy = 'http://127.0.0.1:7890',        # Clash 的 mixed-port，只走端口，不需要开 TUN
  [string]$Group = '',                             # 留空自动选第一个 Selector 组
  [string]$NodeFilter = '',                        # 正则过滤节点名，例如 'Hong Kong|Japan'
  [int]$Rounds = 3,
  [string[]]$Urls = @(
    'http://cp.cloudflare.com/generate_204',       # 机场默认测速目标（anycast，各国都近）
    'https://www.google.com/generate_204',
    'https://www.youtube.com/'
  ),
  [string]$TtfbUrl = 'https://www.gstatic.com/generate_204',
  [switch]$SkipGeo,                                # 跳过落地真身探测
  [switch]$GeoOnly,                                # 只做落地真身，不测延迟
  [switch]$PingExit,                               # 额外 ping 出口 IP（每节点多花约 3-5 秒）
  [switch]$SkipTtfb,
  [switch]$Restore,                                # 结束时恢复原来的节点选择
  [string]$OutDir = '.'
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$csv = Join-Path $OutDir "probe-nodes-$stamp.csv"

# ---------- 地区标签与 CF colo 映射 ----------
$regionMap = [ordered]@{
  'Hong Kong' = 'HK'; 'Taiwan' = 'TW'; 'Japan' = 'JP'; 'Korea' = 'KR'; 'Singapore' = 'SG'
  'United States' = 'US'; 'Canada' = 'CA'; 'Great Britain' = 'GB'; 'France' = 'FR'
  'Germany' = 'DE'; 'Philippines' = 'PH'; 'Netherlands' = 'NL'; 'Turkey' = 'TR'
  'Vietnam' = 'VN'; 'Malaysia' = 'MY'; 'Thailand' = 'TH'
}
$coloMap = @{
  HKG = 'HK'; NRT = 'JP'; KIX = 'JP'; ICN = 'KR'; SIN = 'SG'; TPE = 'TW'; KHH = 'TW'
  LAX = 'US'; SJC = 'US'; SEA = 'US'; DFW = 'US'; ORD = 'US'; EWR = 'US'; IAD = 'US'
  ATL = 'US'; MIA = 'US'; YYZ = 'CA'; YVR = 'CA'; LHR = 'GB'; MAN = 'GB'
  CDG = 'FR'; MRS = 'FR'; FRA = 'DE'; DUS = 'DE'; AMS = 'NL'
  BKK = 'TH'; SGN = 'VN'; HAN = 'VN'; KUL = 'MY'; MNL = 'PH'; IST = 'TR'
}

function Get-LabelRegion([string]$Name) {
  foreach ($k in $regionMap.Keys) { if ($Name -like "*$k*") { return $regionMap[$k] } }
  return ''
}

function Get-Verdict([string]$Label, [string]$GeoCC, [string]$Colo) {
  $coloCC = ''
  if ($Colo -and $coloMap.ContainsKey($Colo)) { $coloCC = $coloMap[$Colo] }
  $bad = @()
  if ($Label -and $GeoCC -and $Label -ne $GeoCC) { $bad += "geo=$GeoCC" }
  if ($Label -and $coloCC -and $Label -ne $coloCC) { $bad += "colo=$Colo" }
  if ($bad.Count -gt 0) { return "疑似假落地($($bad -join ','))" }
  if ($Label -and ($GeoCC -or $coloCC)) { return 'OK' }
  return '未知'
}

# ---------- mihomo API（手工 UTF-8 解码，避开 PS 5.1 对 emoji 节点名的乱码）----------
function Invoke-MihomoApi {
  param([string]$Path, [string]$Method = 'GET', $Body = $null)
  $wc = New-Object System.Net.WebClient
  $wc.Encoding = New-Object System.Text.UTF8Encoding($false)
  if ($ClashSecret) { $wc.Headers.Add('Authorization', "Bearer $ClashSecret") }
  $uri = $ClashApi.TrimEnd('/') + $Path
  try {
    if ($Method -eq 'GET') {
      $bytes = $wc.DownloadData($uri)
      return [System.Text.Encoding]::UTF8.GetString($bytes)
    }
    try { $wc.Headers['Content-Type'] = 'application/json' } catch { }
    return $wc.UploadString($uri, $Method, ($Body | ConvertTo-Json -Compress))
  } finally { $wc.Dispose() }
}

# 经本地代理端口抓文本（system 代理/TUN 都不需要）
function Get-ProxyText([string]$Url) {
  $out = & curl.exe -s -A 'Mozilla/5.0' -x $Proxy --max-time 12 $Url 2>$null
  if ($LASTEXITCODE -ne 0 -or -not $out) { return $null }
  return (($out | Out-String).Trim())
}

function Get-PingAvg([string]$Target, [int]$Count = 3) {
  $lat = @()
  try {
    $p = @{ Count = $Count; ErrorAction = 'SilentlyContinue' }
    if ((Get-Command Test-Connection).Parameters.ContainsKey('TargetName')) { $p['TargetName'] = $Target }
    else { $p['ComputerName'] = $Target }        # Windows PowerShell 5.1
    foreach ($r in (Test-Connection @p)) {
      $v = if ($null -ne $r.Latency) { $r.Latency } elseif ($null -ne $r.ResponseTime) { $r.ResponseTime } else { $null }
      if ($null -ne $v) { $lat += [double]$v }
    }
  } catch { }
  if ($lat.Count -eq 0) { return $null }
  return [math]::Round(($lat | Measure-Object -Average).Average, 0)
}

function Get-Percentile {
  param([double[]]$Values, [double]$P)
  if (-not $Values -or $Values.Count -eq 0) { return $null }
  $s = @($Values | Sort-Object)
  return [math]::Round($s[[int][math]::Floor(($s.Count - 1) * $P)], 0)
}

# ---------- 拉取节点清单 ----------
Write-Host "`n=== 节点落地真身 + 延迟探测 @ $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ===" -ForegroundColor Cyan
$root = ConvertFrom-Json (Invoke-MihomoApi '/proxies')
$allProps = @($root.proxies.PSObject.Properties)

# 规则里真正被引用的策略组 = 切换它才会影响流量
$ruleTargets = @()
try {
  $rj = ConvertFrom-Json (Invoke-MihomoApi '/rules')
  $ruleTargets = @($rj.rules | ForEach-Object { $_.proxy } | Where-Object { $_ } | Select-Object -Unique)
} catch { }

if (-not $Group) {
  # 关键：mihomo 内置的 GLOBAL 组永远存在，但在 mode=rule 下切它不影响流量，必须排除
  $cands = @($allProps | Where-Object {
      $_.Value.type -in @('Selector', 'Fallback', 'URLTest', 'LoadBalance') -and $_.Name -ne 'GLOBAL'
    } | ForEach-Object { $_.Name })
  $hit = @($cands | Where-Object { $ruleTargets -contains $_ })
  if ($hit.Count -gt 0) { $Group = $hit[0] }
  elseif ($cands.Count -gt 0) { $Group = $cands[0] }
  else { throw "没有找到可切换的代理组，请用 -Group 指定" }
}
$gObj = $root.proxies.PSObject.Properties[$Group].Value
if (-not $gObj) { throw "找不到代理组: $Group" }
$original = $gObj.now
Write-Host "代理组: $Group   当前选择: $original"
if ($ruleTargets.Count -gt 0 -and ($ruleTargets -notcontains $Group)) {
  Write-Host "⚠ 警告: 该组未被任何规则引用，在 rule 模式下切换它不会改变实际出口！" -ForegroundColor Yellow
  Write-Host "  规则实际指向: $($ruleTargets -join ', ')" -ForegroundColor Yellow
}

$groupTypes = @('Selector', 'URLTest', 'Fallback', 'LoadBalance', 'Direct', 'Reject', 'Compatible', 'Pass', 'Relay')
$nodes = @()
foreach ($n in $gObj.all) {
  $p = $root.proxies.PSObject.Properties[$n]
  if (-not $p) { continue }
  if ($p.Value.type -in $groupTypes) { continue }        # 跳过嵌套策略组
  if ($NodeFilter -and $n -notmatch $NodeFilter) { continue }
  $nodes += $n
}
Write-Host "待测节点: $($nodes.Count) 个`n" -ForegroundColor Yellow
if ($nodes.Count -eq 0) { throw "过滤后没有节点可测" }

# ---------- 逐节点探测 ----------
$rows = New-Object System.Collections.Generic.List[object]
$fakeCount = 0; $okCount = 0
$i = 0
foreach ($node in $nodes) {
  $i++
  Write-Host ("[{0}/{1}] {2}" -f $i, $nodes.Count, $node) -ForegroundColor Green

  try {
    $null = Invoke-MihomoApi "/proxies/$([uri]::EscapeDataString($Group))" -Method 'PUT' -Body @{ name = $node }
    Start-Sleep -Milliseconds 500
  } catch {
    Write-Host "      切换失败: $($_.Exception.Message)" -ForegroundColor Red
  }

  $row = [ordered]@{ Node = $node }
  $label = Get-LabelRegion $node
  $row['Label'] = $label

  # ---- 落地真身 ----
  if (-not $SkipGeo) {
    $geo = $null; $tr = $null
    $t1 = Get-ProxyText 'https://api.ip.sb/geoip'
    if ($t1) { try { $geo = ConvertFrom-Json $t1 } catch { } }
    $t2 = Get-ProxyText 'https://www.cloudflare.com/cdn-cgi/trace'
    if ($t2) { $tr = $t2 }
    if (-not ($geo -and ($geo.ip -or $geo.query))) {
      $t3 = Get-ProxyText 'http://ip-api.com/json/?fields=status,country,countryCode,city,isp,org,as,query'
      if ($t3) { try { $fb = ConvertFrom-Json $t3; if ($fb.status -eq 'success') { $geo = $fb } } catch { } }
    }

    $exitIp = ''; $isp = ''; $asn = ''; $geoCC = ''; $geoCity = ''; $geoCountry = ''
    if ($geo) {
      $exitIp = if ($geo.ip) { $geo.ip } elseif ($geo.query) { $geo.query } else { '' }
      $isp = if ($geo.isp) { $geo.isp } else { '' }
      if ($geo.asn -and $geo.asn_organization) { $asn = "AS$($geo.asn) $($geo.asn_organization)" }
      elseif ($geo.org) { $asn = $geo.org }
      elseif ($geo.as) { $asn = $geo.as }
      elseif ($geo.asn) { $asn = "AS$($geo.asn)" }
      $geoCC = if ($geo.country_code) { $geo.country_code } elseif ($geo.countryCode) { $geo.countryCode } else { '' }
      $geoCity = if ($geo.city) { $geo.city } else { '' }
      $geoCountry = if ($geo.country) { $geo.country } else { '' }
    }
    $colo = ''
    if ($tr) {
      foreach ($line in ($tr -split "`n")) {
        $kv = $line.Trim() -split '=', 2
        if ($kv.Count -eq 2) {
          if ($kv[0] -eq 'colo') { $colo = $kv[1] }
          elseif ($kv[0] -eq 'loc' -and -not $geoCC) { $geoCC = $kv[1] }
          elseif ($kv[0] -eq 'ip' -and -not $exitIp) { $exitIp = $kv[1] }
        }
      }
    }

    $exitPing = $null
    if ($PingExit -and $exitIp -match '^\d+\.\d+\.\d+\.\d+$') { $exitPing = Get-PingAvg $exitIp 3 }

    $verdict = Get-Verdict $label $geoCC $colo
    if ($verdict -like '疑似*') { $fakeCount++ } elseif ($verdict -eq 'OK') { $okCount++ }

    $row['ExitIP'] = $exitIp
    $row['ISP'] = $isp
    $row['ASN'] = $asn
    $row['GeoCC'] = $geoCC
    $row['GeoCity'] = $geoCity
    $row['Colo'] = $colo
    $row['ExitPing'] = $exitPing
    $row['Verdict'] = $verdict

    if (-not $exitIp) {
      Write-Host "      落地探测失败（该节点不通 / 被规则判为 DIRECT / API 被限流）" -ForegroundColor DarkYellow
    } else {
      $color = if ($verdict -like '疑似*') { 'Red' } elseif ($verdict -eq 'OK') { 'Green' } else { 'DarkYellow' }
      $pingTxt = if ($null -ne $exitPing) { "$exitPing ms" } else { 'n/a' }
      Write-Host ("      出口 {0} | {1} | {2}/{3} | colo={4} | 出口ping={5} | {6}" -f `
        $exitIp, $asn, $geoCountry, $geoCity, $colo, $pingTxt, $verdict) -ForegroundColor $color
    }
  }

  # ---- 端到端延迟 ----
  if (-not $GeoOnly) {
    foreach ($u in $Urls) {
      $samples = @()
      for ($r = 0; $r -lt $Rounds; $r++) {
        try {
          $enc = [uri]::EscapeDataString($u)
          $res = ConvertFrom-Json (Invoke-MihomoApi "/proxies/$([uri]::EscapeDataString($node))/delay?timeout=5000&url=$enc")
          if ($res.delay -and [double]$res.delay -gt 0) { $samples += [double]$res.delay }
        } catch { }
        Start-Sleep -Milliseconds 120
      }
      $key = switch -Regex ($u) {
        'cp\.cloudflare' { 'CF204' }
        'google'         { 'Google' }
        'youtube'        { 'YouTube' }
        default          { ([uri]$u).Host }
      }
      $row["$key-p50"] = if ($samples.Count) { Get-Percentile $samples 0.5 } else { $null }
      $row["$key-ok"] = "$($samples.Count)/$Rounds"
    }

    if (-not $SkipTtfb) {
      $ttfb = @()
      for ($r = 0; $r -lt $Rounds; $r++) {
        $fmt = '%{time_namelookup}|%{time_connect}|%{time_appconnect}|%{time_starttransfer}'
        $out = & curl.exe -s -x $Proxy -o NUL --max-time 20 -w $fmt $TtfbUrl 2>$null
        if ($LASTEXITCODE -eq 0 -and $out) {
          $parts = "$out".Trim() -split '\|'
          if ($parts.Count -ge 4) {
            $ttfb += [double]$parts[3]
            $row['dns-s'] = [math]::Round([double]$parts[0], 2)
            $row['tls-s'] = [math]::Round([double]$parts[2] - [double]$parts[1], 2)
          }
        }
        Start-Sleep -Milliseconds 200
      }
      $row['TTFB-p50-ms'] = if ($ttfb.Count) { [math]::Round((Get-Percentile $ttfb 0.5) * 1000, 0) } else { $null }
      $row['TTFB-ok'] = "$($ttfb.Count)/$Rounds"
    }
  }

  $rows.Add([pscustomobject]$row)
}

# ---------- 恢复原选择 ----------
if ($Restore -and $original) {
  try {
    $null = Invoke-MihomoApi "/proxies/$([uri]::EscapeDataString($Group))" -Method 'PUT' -Body @{ name = $original }
    Write-Host "`n已恢复节点选择: $original" -ForegroundColor DarkGray
  } catch { Write-Host "恢复选择失败，请手动切回 $original" -ForegroundColor Red }
}

# ---------- 输出 ----------
if (-not $SkipGeo) {
  Write-Host "`n=== 落地真身一览 ===" -ForegroundColor Cyan
  $geoCols = @('Node', 'Label', 'ExitIP', 'ASN', 'GeoCC', 'GeoCity', 'Colo', 'ExitPing', 'Verdict')
  $rows | Format-Table -Property $geoCols -AutoSize
  Write-Host ("与标签一致: {0} 个    疑似假落地: {1} 个" -f $okCount, $fakeCount) -ForegroundColor $(if ($fakeCount) { 'Yellow' } else { 'Green' })
}

if (-not $GeoOnly) {
  Write-Host "`n=== 延迟一览（ms）===" -ForegroundColor Cyan
  $cols = @()
  foreach ($r in $rows) { foreach ($c in $r.PSObject.Properties.Name) { if ($cols -notcontains $c) { $cols += $c } } }
  $rows | Format-Table -Property $cols -AutoSize
}

$rows | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8
Write-Host "CSV: $csv`n" -ForegroundColor Green

Write-Host "判读要点:" -ForegroundColor Cyan
Write-Host "  * Colo = 离出口最近的 Cloudflare 机房代码。标着 United States 却是 colo=HKG => 假落地"
Write-Host "  * ASN/ISP 是数据中心(如 Alibaba/Tencent/M247)还是家宽，决定 IP 干净度与解锁能力"
Write-Host "  * ExitPing = 你直接 ping 该出口 IP 的物理 RTT，是最硬的证据（n/a 表示 ICMP 被禁）"
Write-Host "  * 所有节点 ExitIP 完全相同且是本地 ISP => 请求没走代理（规则命中 DIRECT）"
Write-Host "  * CF204 列各国接近是正常现象（anycast）；YouTube/TTFB 列才反映真实差距"
