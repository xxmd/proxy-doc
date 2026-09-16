# 自建代理工具箱 · 香港 Xray REALITY + Clash

个人自用的一套方案：**阿里云香港服务器 + Xray (VLESS + XTLS-Vision + REALITY)**，客户端用 **Clash Verge (mihomo 内核)**。

附带一整套「测量优先」的工具脚本 —— 入口链路体检、机场节点落地真身核查、带宽延迟压测。这套东西的价值不只是配置，而是**用数据判断线路好坏的方法**。

---

## ⚠️ 先读：密钥隔离

**本仓库不含任何真实凭据。** 所有密钥、UUID、密码都在 `secrets/` 目录，而该目录已被 `.gitignore` 排除。

| 目录 | 是否进 git | 内容 |
|---|---|---|
| `server/` `client/` `docs/` | ✅ 进 | 脚本 + 带占位符的示例配置 + 文档 |
| `secrets/` | ❌ **不进** | 真实配置、私钥、UUID、机场订阅密码、探测结果 |

**为什么这么做**：泄露 `secrets/xray-config.json`（REALITY 私钥）等于把服务器送人；泄露 `secrets/probe-anytls.yaml` 等于把你的机场订阅密码公开（别人白嫖你的流量）。

### 回家前怎么把 secrets 带回去（三选一）

| 方式 | 做法 | 安全性 |
|---|---|---|
| **A. 加密压缩包**（推荐） | 7-Zip 带密码打包 `secrets/`，通过微信/U盘/网盘带回家 | 🟢 好 |
| **B. 密码管理器** | 把 `secrets/` 里几个文件的完整内容存进 Bitwarden / 1Password 的 Note | 🟢 好 |
| **C. 私有仓库直接提交** | 把 `.gitignore` 里的 `secrets/*` 两行删掉，一起提交 | 🟡 仅限**私有**仓库，且要接受风险 |

> 如果选 C，请务必确认仓库是 **Private**。公开仓库提交私钥，几分钟内就会被人扫到并盗用。

---

## 目录结构

```
.
├── README.md                      ← 你在这里
├── .gitignore                     ← 密钥与产物隔离规则
│
├── server/                        ← 服务端脚本（在 VPS 上跑）
│   ├── README.md
│   ├── xray-config.example.json   ← 服务端配置模板（占位符）
│   ├── xray-setup.sh              ← 一键部署：装配置 + BBR + systemd + 验证
│   ├── xray-verify.sh             ← 全链路自检（自动从已部署配置读取密钥）
│   ├── test-reality-targets.sh    ← REALITY target 候选站批量测试
│   └── bench-server.sh            ← 服务器侧基准：BBR 调优 + iperf3 端点 + 系统快照
│
├── client/                        ← 客户端脚本（在你电脑上跑）
│   ├── README.md
│   ├── clash-hk.example.yaml      ← Clash/mihomo 配置模板（占位符）
│   ├── bench-client.ps1           ← 入口链路体检：ICMP/TCP握手/节点延迟/吞吐
│   └── bench-nodes.ps1            ← 逐节点探测：落脚 IP/ASN/colo/延迟
│
├── docs/                          ← 经验与方法论
│   ├── 01-REALITY原理.md          ← VLESS / Vision / REALITY 各干什么
│   ├── 02-部署记录.md             ← 本次部署的完整参数与验证结果
│   └── 03-排错记录.md             ← 踩过的坑（含 microsoft target 不兼容）
│
└── secrets/                       ← 🔒 不进 git
    ├── README.md
    ├── xray-config.json           ← 真实服务端配置（含私钥）
    ├── clash-hk.yaml              ← 真实客户端配置（含 UUID/公钥）
    ├── probe-anytls.yaml          ← 机场订阅节点（含订阅密码）
    ├── probe-result.csv           ← 机场 36 节点落地探测结果
    ├── client-test.yaml           ← 独立内核测试用配置
    └── xray-client-selftest.json  ← 服务端自检用客户端配置
```

---

## 快速开始

### 场景一：回家后在新电脑上用（最常用）

```powershell
# 1. 克隆仓库
git clone <你的仓库地址> proxy
cd proxy

# 2. 放入 secrets 目录（用加密压缩包解压 / 从密码管理器粘贴）
#    解压后应该是：proxy\secrets\clash-hk.yaml 等文件
#    没有 secrets 的话，复制示例并填入自己的值：
#    copy client\clash-hk.example.yaml client\clash-hk.yaml

# 3. 导入 Clash Verge
#    打开 Clash Verge → 「配置」页 → 把 clash-hk.yaml 拖进去 → 点击激活
#    到「代理」页确认 PROXY 组选中 HK-Reality

# 4. 验证：浏览器打开 https://ip.sb
#    出口 IP 应该等于你的服务器 IP
```

### 场景二：服务器重装后重新部署

```bash
# 上传配置和脚本
scp secrets/xray-config.json server/*.sh root@<SERVER_IP>:/tmp/

# 一键部署（安装配置 + BBR + systemd + 权限 + 自检）
ssh root@<SERVER_IP> "bash /tmp/xray-setup.sh /tmp/xray-config.json"

# 全链路验证
ssh root@<SERVER_IP> "bash /tmp/xray-verify.sh"
```

### 场景三：怀疑线路变差，做一次体检

```powershell
# 入口链路：延迟 / 丢包 / 路由 AS / 端口可达性
.\client\bench-client.ps1 -ServerIP <SERVER_IP> -Port 443 -ProxyName "HK-Reality"

# 逐节点落地真身（需要 Clash 运行且开启 external-controller）
.\client\bench-nodes.ps1 -GeoOnly
```

---

## 节点信息

真实值全部在 `secrets/` 里，此处只列结构：

| 项目 | 说明 |
|---|---|
| 协议 | VLESS + XTLS-Vision + REALITY |
| 端口 | 443/tcp |
| SNI / serverName | 见 `secrets/clash-hk.yaml` 的 `servername` |
| UUID / 公钥 / shortId | 见 `secrets/clash-hk.yaml` |
| 服务端私钥 | 见 `secrets/xray-config.json` |
| 服务端系统 | Ubuntu 24.04，2 vCPU / 1.5 GB / 40 GB |

---

## 这套方案为什么这么选

| 决策 | 理由 |
|---|---|
| **REALITY 而不是裸 TLS 代理** | 裸 HTTPS 代理（gost `http+tls`）发一个 `GET /` 就被主动探测识破；REALITY 让未认证流量**原样转发到真实网站**，探测者看到的是真站的证书和响应 |
| **XTLS-Vision** | 处理 TLS-in-TLS 的包长与时序特征，这是 TLS 类代理最容易被识别的破绽 |
| **端口 443** | 最不惹眼，且避免非标端口被 QoS |
| **不用 WSS** | Xray 官方已将其列为 deprecated（ALPN 特征明显） |
| **服务端屏蔽回国流量** | 用代理访问境内网站，代理 IP 会被记录/标记 |
| **target 选香港本地站** | 握手时需要实时连目标站取证书，目标站越近越快；且官方建议「从同一 ASN 借证书」 |

---

## 实测结论（重要经验）

### 1. REALITY 的 target 不是随便选的

Xray 26.x 上实测：

| target | 结果 |
|---|---|
| `www.microsoft.com` | ❌ **不兼容**（`REALITY: handshake did not complete successfully`） |
| `www.apple.com` / `www.cloudflare.com` / `www.amazon.com` / `www.lovelive-anime.jp` / `www.hkex.com.hk` | ✅ 均可 |

选 target 前用 `xray tls ping <域名>` 预检：需要 **TLS 1.3**，且尽量避开 apple/icloud（Xray 明确警告会被 GFW 针对）和 Cloudflare（会让你的服务器变成 CF 的免费转发器）。

### 2. 「HTTPS 代理不会被封」是个误解

封不封你，和用不用 TLS 关系不大。IP 封锁、主动探测、TLS-in-TLS 检测、流量模型、QoS 限速 —— 这些都不需要解密你的流量。**真正决定生存率的是：IP 干净度 + 协议选择 + 是否被邻居波及。**

### 3. 测延迟时务必确认本机没有 TUN

如果开着 Clash 的 TUN 模式，`TcpClient` 连任何地址都是 1–2ms（连的是本地 TUN），测出来的数字全是假的。用 `Get-NetRoute -DestinationPrefix 0.0.0.0/0` 确认默认路由没有指向 `Meta` 之类的虚拟网卡。

### 4. 机场的「多国节点」常常是假的

对某个机场 36 个节点做过落地探测：**36 个节点 = 36 个出口 IP，但只有 10 个 ASN，其中 25 个来自同一家**；「台湾节点」实测 `TCP` 握手 292ms（台北到上海物理上不可能超过 60ms），属于典型假落地。详见 `docs/03-排错记录.md`。

---

## 常用命令速查

### 服务端

```bash
systemctl status xray            # 状态
systemctl restart xray           # 重启
tail -f /var/log/xray/access.log # 访问日志（谁在连、连了什么）
tail -f /var/log/xray/error.log  # 错误日志
xray tls ping example.com        # 检查某站能否做 REALITY target

# 看是否有人在主动探测你
grep -c "processed invalid connection" /var/log/xray/error.log
```

### 客户端

```powershell
# 入口体检
.\client\bench-client.ps1 -ServerIP <IP> -Port 443 -ProxyName "HK-Reality"

# 逐节点落地真身 + 延迟
.\client\bench-nodes.ps1 -GeoOnly
.\client\bench-nodes.ps1 -NodeFilter 'Hong Kong|Japan' -PingExit -Rounds 3
```

---

## 免责声明

本项目仅供个人学习网络协议与网络测量使用。请遵守你所在地区的法律法规，不要用于任何违法用途，也不要分享、转售节点。
