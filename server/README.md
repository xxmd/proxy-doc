# server/ —— 服务端脚本

在 VPS（Ubuntu 24.04 / 26.04）上运行。

---

## ⚠️ 0. 先看这一条：Xray 版本必须锁在 ≤ v26.6.27

如果客户端是 **mihomo 系**（Clash Verge / Mihomo Party / FlClash / OpenClash），服务端 Xray **不能**随便升级：

| 服务端 Xray | mihomo 能不能连 | 原因 |
|---|---|---|
| ≤ v26.6.27 | ✅ | REALITY 认证接受纯 X25519 客户端 |
| v26.7.11 ~ v26.7.28 | ⚠️ 默认不行 | REALITY 服务端默认 `minClientVer = 26.3.27`，mihomo 上报 `1.8.2`，被拒。手写 `"minClientVer": "0.0.0"` 可解 |
| ≥ v26.9.9 | ❌ 怎么配都不行 | REALITY 服务端**强制要求** ClientHello 带 `X25519MLKEM768`，mihomo 只发纯 X25519，认证根本进不去 |

安装 / 重装时这样锁版本：

```bash
curl -fsSL -o /tmp/x.zip https://github.com/XTLS/Xray-core/releases/download/v26.6.27/Xray-linux-64.zip
unzip -oq /tmp/x.zip -d /tmp/xr26627
install -m 0755 /tmp/xr26627/xray /usr/local/bin/xray
xray version | head -1     # 必须是 Xray 26.6.27
```

> `bash install-release.sh install` 默认装 **latest**，会把版本悄悄带上去 → Clash Verge 立刻变回 Timeout。
> 完整证据链见 `../docs/03-排错记录.md` **坑 10**。`xray-verify.sh` 会自动检查这一条。

---

## xray-config.example.json

服务端配置模板，含完整的 VLESS + XTLS-Vision + REALITY 配置，以及：

- **全部流量走代理，不做分流**：`routing` 里只留两条 block
- **只 block 两类**：
  - `geoip:private` → 私有地址（防止客户端把局域网地址发上来）
  - `bittorrent` → 防止服务器被判定滥用（阿里云对 BT 很敏感）
- **policy 去默认值**：`handshake: 3` / `connIdle: 180`（默认的 60/300 是明显指纹）
- **只监听 IPv4**：`domainStrategy: UseIPv4`（v4-only 机器避免 IPv6 绕路）

> 早期版本有 `geosite:cn` / `geoip:cn` 的「禁回国」规则，2026-11-02 已删除：它会把
> `www.gstatic.com`（解析到 Google 中国前置 IP）也拦掉，导致客户端默认测速地址永远失败
> ——就是"节点没速度/Timeout"那次问题的根因。详见 `../docs/03-排错记录.md` 坑 11。

### 需要替换的占位符

| 占位符 | 怎么生成 |
|---|---|
| `<REALITY_PRIVATE_KEY>` | `xray x25519` 输出的 `PrivateKey` |
| `<SHORT_ID>` | `openssl rand -hex 8` |
| `<TARGET_DOMAIN>` | 先跑 `test-reality-targets.sh` 选一个能用的 |
| `<UUID>` | `xray uuid` |

> ⚠️ **客户端的 `public-key` = `xray x25519 -i "<私钥>"` 输出的 `Password (PublicKey)`。**
> Xray 新版把客户端这个字段从 `publicKey` 改名成了 `password`。

---

## xray-setup.sh

一键部署。做五件事：

1. 安装配置到 `/usr/local/etc/xray/config.json` 并做语法检查
2. 给 systemd 加 `XRAY_LOCATION_ASSET=/usr/local/share/xray`（否则 `geoip:cn` 这类规则找不到数据文件）
3. 修正 `/var/log/xray` 权限（服务以 `nobody` 运行）
4. 开启 **BBR + fq** 及 TCP 缓冲区调优
5. 重启服务并做一次本机伪装自测

```bash
scp xray-config.json xray-setup.sh root@<SERVER_IP>:/tmp/
ssh root@<SERVER_IP> "bash /tmp/xray-setup.sh /tmp/xray-config.json"
```

---

## xray-verify.sh

**全链路自检**，自动从已部署的配置里读取 UUID / 私钥 / shortId / target，无需手填。验证五项：

1. 配置语法
2. 服务状态 + 443 监听 + **Xray 版本门槛**（高于 v26.6.27 会直接报红）
3. **伪装效果**：未认证流量是否被原样转发到真实网站（应返回真站的 HTTP 状态码 + 证书校验通过）
4. **代理链路**：本机起一个 Xray 客户端实例走完整协议栈，测试 google / youtube / baidu（**全流量代理，三个都应通**）
5. BBR / fq 是否生效

> ⚠️ 第 4 步用的是 **Xray 官方客户端**，它和你的 mihomo 不是同一个实现。这里全绿**不代表** Clash Verge 能连，
> 最终验收必须再用 mihomo 连一次（原因见 `../docs/03-排错记录.md` 坑 10）。

```bash
ssh root@<SERVER_IP> "bash /tmp/xray-verify.sh"
```

预期输出：

```
google  : 200  0.15s
youtube : 200  0.26s
baidu   : 200  0.26s   <- 全流量代理，国内站点也走代理
exit IP : {"country":"Hong Kong", ...}
```

---

## test-reality-targets.sh

批量测试候选域名能否作为 REALITY 的 `target`。**这一步不能省** —— 实测 `www.microsoft.com` 在 Xray 26.x 上会导致所有客户端握手失败。

脚本会：
1. 用 `xray tls ping` 检查每个候选站的 TLS 版本与后量子密钥交换支持
2. 对支持 TLS 1.3 的站，逐个改配置、重启服务、起客户端实测

```bash
ssh root@<SERVER_IP> "bash /tmp/test-reality-targets.sh"
```

### 选 target 的原则

| 原则 | 原因 |
|---|---|
| 必须支持 **TLS 1.3** | REALITY 只工作在 TLS 1.3 |
| 尽量**同 ASN / 地理邻近** | 每次握手都要连它取证书，越近越快；官方建议「从同一 ASN 借证书」 |
| ❌ 避开 **apple / icloud** | Xray 二进制里明确警告：`Choosing apple, icloud, etc. as the target may get your IP blocked by the GFW` |
| ❌ 避开 **Cloudflare 后面的站** | 未认证流量会被转发过去，你的服务器会变成 CF 的免费加速节点，可能被滥用 |
| ❌ 不要用被墙域名 | 握手直接失败 |
| ❌ 不要用国内域名 | 会产生回国流量，一眼 REALITY |

---

## bench-server.sh

服务器侧基准测试工具：

```bash
bash bench-server.sh setup    # 装 iperf3/mtr + 开 BBR + 起 iperf3 服务端
bash bench-server.sh report   # 系统 / Qdisc / 网卡流量 / VPS 自身出口测速
bash bench-server.sh iperf-stop
```

配合客户端使用：

```bash
iperf3 -c <SERVER_IP> -p 5201 -t 30        # 单流（决定单线程体验）
iperf3 -c <SERVER_IP> -p 5201 -t 30 -P 8   # 多流（决定总带宽上限）
iperf3 -c <SERVER_IP> -p 5201 -u -b 200M   # UDP（评估 QUIC/Hysteria2 环境）
```
