# client/ —— 客户端脚本与配置

在你自己的电脑上运行（Windows / PowerShell）。

---

## clash-hk.example.yaml

Clash / mihomo 配置模板。仓库里已有可直接使用的 `clash-hk.yaml`；本模板是给你换机/分享用的占位符版本。

### 需要替换的占位符

| 占位符 | 对应服务端 | 说明 |
|---|---|---|
| `<SERVER_IP>` | 服务器公网 IP | |
| `<UUID>` | `clients[].id` | `xray uuid` 生成 |
| `<PUBLIC_KEY>` | `privateKey` 对应的公钥 | `xray x25519 -i "<私钥>"` 输出的 `Password (PublicKey)` |
| `<SHORT_ID>` | `shortIds[0]` | 必须完全一致 |
| `<TARGET_DOMAIN>` | `realitySettings.dest` / `serverNames` | **必须完全一致**，否则服务端报 `server name mismatch` |

### 相比常见订阅配置，这份模板修掉了几个坑

| 项 | 常见写法 | 这份模板 | 原因 |
|---|---|---|---|
| DNS fallback | `[1.1.1.1, 8.8.8.8]` 明文 | 全部 **DoH** | 实测这两个 IP 的 TCP/443 在国内完全不通；明文 UDP/53 虽通但返回**投毒结果** |
| `allow-lan` | `true` + `bind-address: '*'` | `false`，只监听 `127.0.0.1` | 否则同一局域网（宿舍/公司 WiFi）任何人都能把你的代理当免费跳板 |
| DNS 监听 | `0.0.0.0:1053` | `127.0.0.1:1053` | 同上，避免开放递归解析 |
| 自动选择组 | `type: fallback` | `type: url-test` | fallback 是按顺序选第一个能通的，永远停在列表第一个，等于没优选 |

### 导入 Clash Verge

1. 打开 Clash Verge → 「配置」页
2. 把 yaml 文件**拖进去**（或点 `+` → 本地 → 新建后粘贴内容）
3. **点击该配置激活**
4. 到「代理」页确认 `PROXY` 组选中 `HK-Reality`
5. 浏览器访问 `https://ip.sb`，出口 IP 应等于你的服务器 IP

> TUN 模式和系统代理都可以正常开着，不影响。

### 节点显示 Timeout 时，第一步做什么

**不要先怀疑 TUN、DNS、防火墙。** 先看 mihomo 自己的报错：

1. 把配置里 `log-level` 改成 `debug`，或 Clash Verge →「设置」→ 日志等级 `debug`
2. 日志页看 `dial HK-Reality` 那一行，如果是：

   ```text
   connect error: REALITY authentication failed
   ```

   → **不是网络问题，是服务端版本不兼容**：mihomo 的 REALITY 认证被服务端拒了（服务端 Xray ≥ v26.7.11 的门槛）。
   解决办法是把服务端 Xray 降回 **≤ v26.6.27**，详见 `../docs/03-排错记录.md` **坑 10**。

3. 对照实验（5 分钟定性）：同一个节点参数用 **Xray 官方客户端** 连一次。
   - Xray 客户端通、mihomo 不通 → 客户端实现/版本问题（就是上面这种）
   - 两个都不通 → 才轮到怀疑服务器、网络、防火墙

---

## bench-client.ps1

**入口链路体检**。测四层：

1. ICMP 延迟与丢包
2. TCP 握手延迟（ICMP 被禁时用这个）
3. Clash 节点真实延迟（走 mihomo API）
4. 经代理的下载吞吐（curl 走本地代理端口拉大文件）

```powershell
# 基础用法
.\bench-client.ps1 -ServerIP <SERVER_IP> -Port 443 -ProxyName "HK-Reality"

# 想看更多轮次
.\bench-client.ps1 -ServerIP <SERVER_IP> -Port 443 -ProxyName "HK-Reality" -DownloadRounds 5

# Clash 设了 external-controller 密钥的话
.\bench-client.ps1 -ServerIP <SERVER_IP> -ClashSecret "你的密钥"
```

> ⚠️ **测之前确认本机没有开 TUN。** 开着 TUN 时 `TcpClient` 连任何地址都是 1–2ms（连的是本地虚拟网卡），数据全废。
> 检查：`Get-NetRoute -DestinationPrefix 0.0.0.0/0`，如果默认路由指向 `Meta` 之类的虚拟网卡，先关掉 TUN。

---

## bench-nodes.ps1

**逐节点落地真身探测**。按顺序切换代理组里的每个节点，测量：

| 项目 | 数据源 |
|---|---|
| 出口 IP / ISP / ASN / 城市 | `api.ip.sb/geoip`（失败时回退 `ip-api.com`） |
| 离出口最近的 Cloudflare 机房 | `cloudflare.com/cdn-cgi/trace` 的 `colo` |
| 你→出口的物理 RTT | 直连 ping 出口 IP（`-PingExit`） |
| 端到端延迟 | mihomo API delay + curl TTFB |

```powershell
# 最快：只看落地真身
.\bench-nodes.ps1 -GeoOnly

# 重点地区 + 落地 ping + 多轮延迟
.\bench-nodes.ps1 -NodeFilter 'Hong Kong|Japan|United States' -PingExit -Rounds 3

# 代理组不叫默认名时
.\bench-nodes.ps1 -GeoOnly -Group SSRDOG
```

### 判读

| 现象 | 结论 |
|---|---|
| 标签 `United States` 但 `colo=HKG` | 假落地，出口实际在香港 |
| 所有节点出口 IP 相同且是本地 ISP | 请求没走代理（规则命中 DIRECT） |
| 出口 ASN 是 `AS13335 Cloudflare` | 落地是 WARP 出口，地区标签不可信 |
| `ExitPing` 有值 | 这是「你→落地」的物理 RTT，和 TTFB 的差值就是中转绕行的开销 |
| `TTFB-ok` 不满 | 该节点丢包/不稳定 —— Clash 永远不会告诉你这一点 |

> ⚠️ **脚本会自动跳过 mihomo 内置的 `GLOBAL` 组**（在 `mode: rule` 下切它不影响流量），优先选择 `/rules` 里真正被引用的组，选不中会打警告。

---

## 前置条件

- PowerShell 5.1 或 7+（脚本已做双版本兼容，含 BOM 处理）
- Clash Verge / mihomo 运行中，且 `external-controller` 已开启（默认 `127.0.0.1:9090`）
