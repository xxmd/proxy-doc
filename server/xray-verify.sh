#!/bin/bash
# ============================================================
#  Xray VLESS + XTLS-Vision + REALITY 全链路自检
#
#  自动从已部署的 /usr/local/etc/xray/config.json 读取
#  UUID / 私钥 / shortId / target，无需手工填写。
#
#  用法: bash xray-verify.sh
# ============================================================
XRAY=/usr/local/bin/xray
CONF=/usr/local/etc/xray/config.json
PASS=0; FAIL=0

ok()  { echo "  ✅ $1"; PASS=$((PASS+1)); }
bad() { echo "  ❌ $1"; FAIL=$((FAIL+1)); }

extract() { grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$CONF" | head -n1 | sed 's/.*"\([^"]*\)"$/\1/'; }

echo "=========================================="
echo " Xray REALITY 全链路自检"
echo " $(date '+%Y-%m-%d %H:%M:%S')"
echo "=========================================="

# ---------- 0. 读取已部署的密钥 ----------
if [ ! -f "$CONF" ]; then echo "找不到 $CONF"; exit 1; fi
UUID=$(extract id)
PRIV=$(extract privateKey)
DEST=$(extract dest)
[ -z "$DEST" ] && DEST=$(extract target)
SID=$(grep -o '"shortIds"[[:space:]]*:[[:space:]]*\[[^]]*\]' "$CONF" | grep -o '"[^"]*"' | head -n1 | tr -d '"')
TARGET=${DEST%%:*}

if [ -z "$UUID" ] || [ -z "$PRIV" ] || [ -z "$DEST" ]; then
  echo "配置解析失败：UUID/privateKey/dest 有空值"; exit 1
fi

PUB=$($XRAY x25519 -i "$PRIV" 2>/dev/null | grep -i 'Password' | sed 's/.*: *//')
[ -z "$PUB" ] && PUB=$($XRAY x25519 --input "$PRIV" 2>/dev/null | grep -i 'Public' | sed 's/.*: *//')
if [ -z "$PUB" ]; then echo "无法从私钥推导公钥，请检查 Xray 版本"; exit 1; fi

echo
echo "已部署参数："
echo "  target     = $TARGET"
echo "  shortId    = $SID"
echo "  uuid       = ${UUID:0:8}…（已隐藏）"
echo "  publicKey  = ${PUB:0:12}…（已隐藏）"

# ---------- 1. 配置语法 ----------
echo
echo "[1/5] 配置语法"
if $XRAY run -test -config "$CONF" 2>&1 | grep -q 'Configuration OK'; then
  ok "Configuration OK"
else
  bad "配置语法有误"
  $XRAY run -test -config "$CONF" 2>&1 | tail -n 5
fi

# ---------- 2. 服务与监听 ----------
echo
echo "[2/5] 服务状态与端口"
systemctl is-active --quiet xray && ok "xray.service active" || bad "xray.service 未运行"
if ss -tlnp 2>/dev/null | grep -q ':443'; then ok "443 端口已监听"; else bad "443 未监听"; fi

# 版本门槛：mihomo（Clash Verge / Mihomo Party / FlClash / OpenClash）只能连 ≤ v26.6.27 的 REALITY 服务端
VER=$($XRAY version 2>/dev/null | head -n1 | awk '{print $2}')
if [ -n "$VER" ]; then
  IFS=. read -r V1 V2 V3 <<< "$VER"
  if [ -n "$V1" ] && { [ "$V1" -gt 26 ] || { [ "$V1" -eq 26 ] && { [ "$V2" -gt 6 ] || { [ "$V2" -eq 6 ] && [ "$V3" -gt 27 ]; }; }; }; }; then
    bad "Xray $VER 高于 v26.6.27 —— mihomo 系客户端会 REALITY 认证失败、节点 Timeout（见 docs/03-排错记录.md 坑 10）"
  else
    ok "Xray $VER（≤ v26.6.27，mihomo 兼容）"
  fi
fi

# ---------- 3. 伪装效果（未认证流量应被转发到真实网站）----------
echo
echo "[3/5] REALITY 伪装（未认证流量 → 真实网站）"
FB=$(curl -s -o /dev/null -w "%{http_code}|%{ssl_verify_result}" \
      --resolve "$TARGET:443:127.0.0.1" "https://$TARGET" --max-time 15 2>/dev/null)
FB_CODE=${FB%%|*}; FB_SSL=${FB##*|}
if [ "$FB_SSL" = "0" ]; then
  ok "证书校验通过（外人看到的是真网站，HTTP $FB_CODE）"
else
  bad "证书校验异常（ssl_verify=$FB_SSL）—— target 可能不可用"
fi

# ---------- 4. 代理链路（完整协议栈）----------
echo
echo "[4/5] 代理链路（本机起客户端实例走完整 REALITY）"
cat > /tmp/_verify_client.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [ { "listen": "127.0.0.1", "port": 10808, "protocol": "socks",
                  "settings": { "udp": true, "auth": "noauth" } } ],
  "outbounds": [ { "protocol": "vless",
    "settings": { "vnext": [ { "address": "127.0.0.1", "port": 443,
      "users": [ { "id": "$UUID", "encryption": "none", "flow": "xtls-rprx-vision" } ] } ] },
    "streamSettings": { "network": "tcp", "security": "reality", "realitySettings": {
      "serverName": "$TARGET", "fingerprint": "chrome",
      "password": "$PUB", "shortId": "$SID" } } } ]
}
EOF

pkill -f _verify_client.json 2>/dev/null
sleep 1
nohup $XRAY run -c /tmp/_verify_client.json > /tmp/_verify_client.log 2>&1 &
sleep 3

if ss -tln 2>/dev/null | grep -q 10808; then ok "客户端实例已启动"; else bad "客户端实例启动失败"; fi

for pair in "google:https://www.google.com" "youtube:https://www.youtube.com"; do
  name=${pair%%:*}; url=${pair#*:}
  code=$(curl -s -o /dev/null -w "%{http_code}" --socks5-hostname 127.0.0.1:10808 --max-time 20 "$url")
  if [ "$code" = "200" ]; then ok "$name → 200"; else bad "$name → $code"; fi
done

code=$(curl -s -o /dev/null -w "%{http_code}" --socks5-hostname 127.0.0.1:10808 --max-time 15 https://www.baidu.com)
if [ "$code" = "200" ]; then ok "baidu → 200（全流量代理，国内站点也走代理）"; else bad "baidu → $code（全流量代理下应该能通）"; fi

echo "  出口 IP: $(curl -s --socks5-hostname 127.0.0.1:10808 --max-time 20 'http://ip-api.com/json/?fields=country,city,isp,as,query' 2>/dev/null)"

pkill -f _verify_client.json 2>/dev/null
sleep 1

# ---------- 5. 系统调优 ----------
echo
echo "[5/5] 系统调优"
cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
[ "$cc" = "bbr" ] && ok "拥塞控制 = bbr" || bad "拥塞控制 = ${cc:-未知}（建议开 BBR）"
qd=$(sysctl -n net.core.default_qdisc 2>/dev/null)
[ "$qd" = "fq" ] && ok "队列算法 = fq" || bad "队列算法 = ${qd:-未知}"

# ---------- 汇总 ----------
echo
echo "=========================================="
echo " 通过 $PASS 项，失败 $FAIL 项"
echo "=========================================="
if [ "$FAIL" -eq 0 ]; then
  echo "全部通过 ✅"
  echo
  echo "⚠️ 注意：本脚本用的是 Xray 官方客户端，它能通 ≠ mihomo/Clash Verge 能通。"
  echo "   如果这里全绿、Clash Verge 里还是 Timeout，那是 REALITY 客户端版本不兼容，"
  echo "   看 docs/03-排错记录.md 坑 10（服务端要锁在 ≤ v26.6.27）。"
else
  echo "有失败项 ❌  排查建议："
  echo "  · target 相关失败 → 跑 test-reality-targets.sh 换一个 target"
  echo "  · 链路失败        → tail -n 30 /var/log/xray/error.log"
  echo "  · BBR 未开        → sysctl --system 或检查 /etc/sysctl.d/"
fi
