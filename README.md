# 自建代理工具箱 · 香港 Xray REALITY + Clash

个人自用的一套方案：**阿里云香港服务器 + Xray (VLESS + XTLS-Vision + REALITY)**，客户端用 **Clash Verge (mihomo 内核)**。

附带一整套「测量优先」的工具脚本 —— 入口链路体检、机场节点落地真身核查、带宽延迟压测。这套东西的价值不只是配置，而是**用数据判断线路好坏的方法**。

---

## 🚀 快速使用（回家后 2 分钟）

```powershell
# 1. 克隆
git clone https://github.com/xxmd/proxy-doc.git proxy
cd proxy

# 2. 导入客户端配置
#    打开 Clash Verge → 「配置」页 → 把 client\clash-hk.yaml 拖进去 → 点击激活
#    到「代理」页确认 PROXY 组选中 HK-Reality

# 3. 验证：浏览器打开 https://ip.sb ，出口 IP 应为 47.86.26.23
```

**节点信息**（完整凭据见 `docs/04-完整配置信息.md`）：

| 项目 | 值 |
|---|---|
| 地址 / 端口 | `47.86.26.23:443` |
| 协议 | VLESS + XTLS-Vision + REALITY |
| SNI | `www.hkex.com.hk` |
| 服务端 Xray | **v26.6.27（锁定，不要升）** |

> ⚠️ **服务器上的 Xray 不要升到 v26.7.11 以上、尤其是 v26.9.9 以上** —— 新版 REALITY 服务端会拒绝 mihomo
> （Clash Verge 内核）的认证，节点直接 `Timeout`。原因和实测数据见 `docs/03-排错记录.md` **坑 10**。

---

## ⚠️ 关于凭据

**本仓库包含真实密钥**（REALITY 私钥、UUID、公钥、shortId、机场订阅密码），这是仓库主人的明确选择，目的是方便换机时一键恢复。

需要注意的实际影响：**仓库若公开可见，任何看到的人都能直接使用此节点** —— 服务器可能因此被滥用、限速或被墙。如果哪天发现节点变慢或连不上，优先怀疑这一点，届时用 `xray x25519` 换一套新密钥即可（步骤见 `docs/04-完整配置信息.md` 第七节）。

---

## 目录结构

```
.
├── README.md                      ← 你在这里
│
├── server/                        ← 服务端（在 VPS 上跑）
│   ├── README.md
│   ├── xray-config.json           ← ✅ 真实配置（含私钥）
│   ├── xray-config.example.json   ← 占位符模板
│   ├── xray-setup.sh              ← 一键部署：装配置 + BBR + systemd + 验证
│   ├── xray-verify.sh             ← 全链路自检（自动从已部署配置读取密钥）
│   ├── test-reality-targets.sh    ← REALITY target 候选站批量测试
│   ├── xray-client-selftest.json  ← 自检用客户端配置
│   └── bench-server.sh            ← 服务器侧基准：BBR + iperf3 端点 + 系统快照
│
├── client/                        ← 客户端（在自己电脑上跑）
│   ├── README.md
│   ├── clash-hk.yaml              ← ✅ 真实配置（直接导入 Clash Verge）
│   ├── clash-hk.example.yaml      ← 占位符模板
│   ├── standalone-test.yaml       ← 独立 mihomo 内核测试用（7899/9099）
│   ├── airport-nodes-anytls.yaml  ← 机场订阅节点（36 个，备用线路）
│   ├── bench-client.ps1           ← 入口链路体检
│   └── bench-nodes.ps1            ← 逐节点落地真身探测
│
└── docs/                          ← 经验与方法论
    ├── 01-REALITY原理.md          ← VLESS / Vision / REALITY 各干什么
    ├── 02-部署记录.md             ← 本次部署的参数与验证结果
    ├── 03-排错记录.md             ← 踩过的 10 个坑
    ├── 04-完整配置信息.md          ← 🔑 全部凭据 + 恢复步骤
    └── airport-probe-result.csv   ← 机场 36 节点落地探测原始数据
```

---

## 常见操作

### 服务器重装后重新部署

```bash
# 装依赖 + Xray（⚠️ 必须锁 v26.6.27，装 latest 会让 Clash Verge 连不上，见 docs/03-排错记录.md 坑 10）
apt-get update -qq && apt-get install -y -qq unzip
curl -fsSL -o /tmp/xray-install.sh https://github.com/XTLS/Xray-install/raw/main/install-release.sh
bash /tmp/xray-install.sh install
curl -fsSL -o /tmp/x.zip https://github.com/XTLS/Xray-core/releases/download/v26.6.27/Xray-linux-64.zip
unzip -oq /tmp/x.zip -d /tmp/xr26627 && install -m 0755 /tmp/xr26627/xray /usr/local/bin/xray

# 上传并部署
scp server/xray-config.json server/*.sh root@<SERVER_IP>:/tmp/
ssh root@<SERVER_IP> "bash /tmp/xray-setup.sh /tmp/xray-config.json"
ssh root@<SERVER_IP> "bash /tmp/xray-verify.sh"

# ⚠️ xray-verify.sh 用的是 Xray 自家客户端，它能通 ≠ mihomo 能通。
#    最终验收一定要用 mihomo/Clash Verge 连一次。
```

### 线路变差了，做一次体检

```powershell
# 入口链路：延迟 / 丢包 / 路由 AS / 端口可达性
.\client\bench-client.ps1 -ServerIP 47.86.26.23 -Port 443 -ProxyName "HK-Reality"

# 逐节点落地真身（需要 Clash 运行且开启 external-controller）
.\client\bench-nodes.ps1 -GeoOnly
```

> ⚠️ 测延迟前先关掉 Clash 的 **TUN 模式**，否则所有 TCP 握手都是 1–2ms（连的是本地虚拟网卡），数据全废。

### 服务端常用命令

```bash
systemctl status xray            # 状态
systemctl restart xray           # 重启
tail -f /var/log/xray/access.log # 访问日志（谁在连、连了什么）
tail -f /var/log/xray/error.log  # 错误日志
xray tls ping example.com        # 检查某站能否做 REALITY target

# 看是否有人在主动探测你
grep -c "processed invalid connection" /var/log/xray/error.log
```

---

## 这套方案为什么这么选

| 决策 | 理由 |
|---|---|
| **REALITY 而不是裸 TLS 代理** | 裸 HTTPS 代理（gost `http+tls`）发一个 `GET /` 就被主动探测识破；REALITY 让未认证流量**原样转发到真实网站**，探测者看到的是真站的证书和响应 |
| **XTLS-Vision** | 处理 TLS-in-TLS 的包长与时序特征，这是 TLS 类代理最容易被识别的破绽 |
| **端口 443** | 最不惹眼，且避免非标端口被 QoS |
| **不用 WSS** | Xray 官方已将其列为 deprecated（ALPN 特征明显） |
| **服务端屏蔽回国流量** | 用代理访问境内网站，代理 IP 会被记录/标记 |
| **target 选香港本地站** | 握手时需要实时连目标站取证书，越近越快；官方建议「从同一 ASN 借证书」 |

---

## 实测结论（重要经验）

### 1. REALITY 的 target 不是随便选的 ⭐

Xray 26.x 上实测：

| target | 结果 |
|---|---|
| `www.microsoft.com` | ❌ **不兼容**（所有客户端 `handshake did not complete successfully`） |
| `www.apple.com` / `www.cloudflare.com` / `www.amazon.com` / `www.lovelive-anime.jp` / `www.hkex.com.hk` | ✅ 均可 |

选 target 前用 `xray tls ping <域名>` 预检（需 **TLS 1.3**），并避开 apple/icloud（Xray 明确警告会被 GFW 针对）和 Cloudflare（服务器会变成 CF 的免费转发器）。

### 2. 「HTTPS 代理不会被封」是个误解

封不封你，和用不用 TLS 关系不大。IP 封锁、主动探测、TLS-in-TLS 检测、流量模型、QoS 限速 —— 这些都不需要解密你的流量。**决定生存率的是：IP 干净度 + 协议选择 + 是否被邻居波及。**

### 3. 测延迟时务必确认本机没有 TUN

开着 TUN 时 `TcpClient` 连任何地址都是 1–2ms。检查：`Get-NetRoute -DestinationPrefix 0.0.0.0/0`，看默认路由是否指向 `Meta` 之类的虚拟网卡。

### 4. 机场的「多国节点」常常是缩水的

某个机场 36 个节点实测：**36 个出口 IP 但只有 10 个 ASN，25 个来自同一家**；「台湾节点」TCP 握手实测 292ms（台北到上海物理上不可能），属典型假落地。详见 `docs/03-排错记录.md`。

### 5. `Timeout` 不一定是墙、不一定是 TUN，很可能是**版本不兼容** ⭐⭐

Clash Verge 里节点一直 `Timeout`，而同一台机器上用 **Xray 官方客户端**连同一个节点秒通 —— 这时问题基本就锁定在
「客户端实现 ↔ 服务端版本」上了。实测根因：**Xray ≥ v26.9.9 的 REALITY 服务端强制要求 ClientHello 带
`X25519MLKEM768`（后量子混合密钥），而 mihomo 只发纯 X25519**，于是被当成探测流量转发给真站，客户端报
`REALITY authentication failed`，界面显示 `Timeout`。另外 Xray v26.7.11~v26.7.28 还额外有
`minClientVer=26.3.27` 的门槛（mihomo 上报的版本是 `1.8.2`）。

**结论**：只要客户端是 mihomo 系（Clash Verge / Mihomo Party / FlClash / OpenClash），服务端 Xray 就必须锁在
**≤ v26.6.27**（v26.7.28 需手写 `"minClientVer": "0.0.0"`）。完整证据链、源码依据和 A/B 对照表见
`docs/03-排错记录.md` **坑 10**。

---

## 免责声明

本项目仅供个人学习网络协议与网络测量使用。请遵守你所在地区的法律法规，不要用于任何违法用途，也不要转售节点。
