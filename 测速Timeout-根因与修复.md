# 节点「没速度 / Timeout」的根因：测速地址被禁回国规则拦掉

> 原文档叫《移动端与电脑端节点测速现象-待诊断》，2026-11-02 已定案并修复，改名留存。
> 完整的技术细节见 `docs/03-排错记录.md` **坑 11**，这里只留结论。

## 现象

- 手机 Clash Meta：阿里云节点有延迟，野草云节点**没有数字**；但两个节点都能正常上网。
- 电脑 Clash Verge：两个节点都正常显示延迟。
- 同一个节点两次测速可以一次 `Timeout`、一次 `72 ms`。

## 根因（一句话）

**测速地址 `https://www.gstatic.com/generate_204` 会解析到 Google 的中国前置 IP `203.208.49.66`（geoip=CN），
命中服务端的「禁回国流量」规则被 block 掉——测速失败，节点本身没坏。**

所以这不是节点问题、不是手机兼容性问题、跟野草云也没关系，**两个节点一模一样**；
"偶发"是因为 gstatic 有多个 A 记录，解析到美国 IP 时测速就成功。

服务端日志（`loglevel: info`）曾直接写着：

```text
sniffed domain: www.gstatic.com
taking detour [block] for [tcp:www.gstatic.com:443]
```

## 修复（2026-11-02 已上线，两台服务器都改了）

服务端 `server/xray-config.json` 在 block 规则**之前**加一条白名单：

```json
{ "type": "field", "domain": ["domain:gstatic.com", "domain:googleapis.cn", "domain:google.cn"], "outboundTag": "direct" }
```

已部署到 `47.86.26.23`（阿里云）和 `85.189.40.202`（野草云），客户端**不用改任何东西**。

## 验证结果

| 检查项 | 修复前 | 修复后 |
|---|---|---|
| 阿里云 gstatic 测速 | 0/6 失败 | **6/6 成功**（134–411 ms） |
| 野草云 gstatic 测速 | 0/6 失败 | **6/6 成功**（35–48 ms） |
| 两节点 `https://www.gstatic.com/generate_204` | 000 | **204** |
| 两节点 baidu（禁回国） | 000 | **000**（规则没被破坏） |
| 带宽（单连接 20 MB） | — | 阿里云 6.6–7.5 Mbps / 野草云 6.9–8.2 Mbps |

> 阿里云 gstatic 延迟偏高（134–411 ms）是因为它真的去连了 Google 的中国前置 IP。
> **想测更准的延迟，客户端把测速地址换成 `https://cp.cloudflare.com/generate_204`**（两节点都是 38–53 ms，很稳）。

## 顺带核实的两个事实

| 原文 | 实测 |
|---|---|
| 阿里云 Xray `26.10.29` | **`26.6.27`**（2026-10-30 降级，见坑 10）。若真是 26.10.29，手机 Clash Meta 根本握不上手 |
| 野草云"出口 Hong Kong" | 落地确实在香港（`colo=HKG`、上海 RTT 35 ms），但 **IP 注册在英国公司 `AS139659 LUCIDACLOUD` 名下**，`ip-api` 判 United Kingdom。部分网站会当英国 IP |
| （未记录） | 两台服务器**共用同一套 UUID / 公钥 / shortId**，只有 IP 不同 → 换密钥要两台一起换 |

## 一句话记住

> **节点"没速度"先看是不是测速地址被拦，别急着关 TUN、换节点、改 DNS。**
