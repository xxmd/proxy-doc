# 🔒 secrets/ —— 不进 git 的目录

这个目录被 `.gitignore` 排除，**不会**被提交到仓库。

## 里面有什么

| 文件 | 内容 | 泄露后果 |
|---|---|---|
| `xray-config.json` | 服务端完整配置，含 REALITY **私钥** | 别人可直接连你的服务器、蹭你的带宽 |
| `clash-hk.yaml` | 客户端配置，含服务器 IP / UUID / 公钥 / shortId | 同上 |
| `probe-anytls.yaml` | 机场订阅节点配置，含**订阅密码** | 别人白嫖你的付费流量，用光你的配额 |
| `probe-result.csv` | 机场 36 节点的落地 IP / ASN / 地理信息 | 暴露机场基础设施 |
| `client-test.yaml` | 独立 mihomo 内核测试配置 | 含节点凭据 |
| `xray-client-selftest.json` | 服务端自检用客户端配置 | 含节点凭据 |

## 怎么带回家

**方式 A：加密压缩包（推荐）**

```powershell
# 用 7-Zip 带密码打包
& "C:\Program Files\7-Zip\7z.exe" a -p"你的密码" -mhe=on secrets.7z secrets\
```
然后把 `secrets.7z` 通过微信 / U 盘 / 网盘带回家，解压回 `secrets/` 即可。

**方式 B：密码管理器**

把 `xray-config.json` 和 `clash-hk.yaml` 的完整内容存进 Bitwarden / 1Password 的 Secure Note。

**方式 C：私有仓库直接提交**

```powershell
# 删除 .gitignore 里的这两行：
#   secrets/*
#   !secrets/README.md
# 然后正常提交
```
⚠️ **仅限 Private 仓库。** 公开仓库提交私钥，几分钟内就会被自动化工具扫到并盗用。

## 注意

- `xray-config.json` 里的私钥一旦泄露，**必须重新生成**：`xray x25519` 生成新密钥对，服务端换 `privateKey`，客户端换 `public-key`，然后重启 xray。
- 上传任何截图、日志、配置到公开场合前，先检查是否包含这里的值。
