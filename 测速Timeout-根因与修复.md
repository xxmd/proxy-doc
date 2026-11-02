# 节点「没速度 / Timeout」的根因：测速地址被禁回国规则拦掉

> 2026-11-02 定位并**已彻底解决**：分流规则全部删除，现在**全部流量走代理**。
> 技术细节见 `docs/03-排错记录.md` **坑 11**，这里只留结论。

## 现象

- 手机 Clash Meta：阿里云节点有延迟，野草云节点**没有数字**；但两个节点都能正常上网。
- 电脑 Clash Verge：两个节点都正常显示延迟。
- 同一个节点两次测速可以一次 `Timeout`、一次 `72 ms`。

## 根因（一句话）

**测速地址 `https://www.gstatic.com/generate_204` 会解析到 Google 的中国前置 IP `203.208.49.66`（geoip=CN），
被服务端的「禁回国流量」规则 block 掉——测速失败，节点本身没坏。**

所以不是节点问题、不是手机兼容性问题、跟野草云也没关系，**两个节点一模一样**；
"偶发"是因为 gstatic 有多个 A 记录，解析到美国 IP 时测速就成功。

## 最终解决：不做分流，全部流量走代理

把 `geosite:cn` / `geoip:cn` 这套分流规则**全删了**（连带那行 gstatic 白名单也不需要了）。

**服务端** `server/xray-config.json` 现在只剩两条：

```json
{ "type": "field", "ip": ["geoip:private"],    "outboundTag": "block" },   // 私有地址
{ "type": "field", "protocol": ["bittorrent"], "outboundTag": "block" }    // 防滥用
```

**客户端** `client/clash-hk.yaml` 现在只剩两条：

```yaml
- 'GEOIP,private,DIRECT,no-resolve'   # 局域网直连
- 'MATCH,PROXY'                        # 其余全部走代理
```

两台服务器（`47.86.26.23` 阿里云、`85.189.40.202` 野草云）都已部署，客户端重新应用一次配置即可。

## 验证结果（两台都测）

| 检查项 | 结果 |
|---|---|
| gstatic 测速 | **37 ms 成功**（原来 0/6 全失败） |
| `https://www.baidu.com` 走代理 | **200** |
| `https://www.taobao.com` 走代理 | **200** |
| 出口 IP | 服务器 IP（说明确实走了代理） |
| 规则命中 | mihomo 日志 `match Match using PROXY`，不再有 `DIRECT` 分流 |

> 代价：访问国内站点也绕香港，个别站（如 `qq.com`）会对境外 IP 返回 501，属于正常现象。

## 顺带核实的两个事实

| 原文 | 实测 |
|---|---|
| 阿里云 Xray `26.10.29` | **`26.6.27`**（2026-10-30 降级，见坑 10）。若真是 26.10.29，手机 Clash Meta 根本握不上手 |
| 野草云"出口 Hong Kong" | 落地确实在香港（`colo=HKG`、上海 RTT 35 ms），但 **IP 注册在英国公司 `AS139659 LUCIDACLOUD` 名下**，`ip-api` 判 United Kingdom。部分网站会当英国 IP |
| （未记录） | 两台服务器**共用同一套 UUID / 公钥 / shortId**，只有 IP 不同 → 换密钥要两台一起换 |

## 一句话记住

> **节点"没速度"先看是不是测速地址被拦，别急着关 TUN、换节点、改 DNS。**
> 想要省事，就别搞分流 —— 全部走代理，什么都不会被误伤。
