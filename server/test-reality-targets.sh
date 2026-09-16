#!/bin/bash
# ============================================================
#  REALITY target 候选站批量测试
#
#  为什么需要这个脚本：
#    实测 www.microsoft.com 在 Xray 26.x 上会导致所有客户端
#    握手失败（REALITY: handshake did not complete successfully），
#    而换成 www.hkex.com.hk 立刻正常。target 选错 = 全盘不可用。
#
#  它会：
#    1) 用 xray tls ping 检查每个候选站的 TLS 版本与后量子支持
#    2) 对支持 TLS 1.3 的站，逐个改服务端配置 + 重启 + 起客户端实测
#
#  用法:
#    bash test-reality-targets.sh                 # 测默认候选列表
#    bash test-reality-targets.sh a.com b.com     # 测指定域名
#
#  ⚠️ 会反复重启 xray 服务，请在维护窗口执行。
#     测试结束后会把服务端配置恢复成原样（target 不变）。
# ============================================================
XRAY=/usr/local/bin/xray
CONF=/usr/local/etc/xray/config.json
BACKUP=/tmp/xray-config.backup.json
UUID=; PRIV=; SID=

DEFAULT_TARGETS="www.microsoft.com www.apple.com www.cloudflare.com www.amazon.com www.lovelive-anime.jp www.hkex.com.hk www.samsung.com www.tesla.com"

extract() { grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$CONF" | head -n1 | sed 's/.*"\([^"]*\)"$/\1/'; }

# ---------- 读取当前配置（保留 keys，只换 target）----------
if [ ! -f "$CONF" ]; then echo "找不到 $CONF，请先部署"; exit 1; fi
cp "$CONF" "$BACKUP"
UUID=$(extract id); PRIV=$(extract privateKey)
SID=$(grep -o '"shortIds"[[:space:]]*:[[:space:]]*\[[^]]*\]' "$CONF" | grep -o '"[^"]*"' | head -n1 | tr -d '"')
CURRENT=$(extract dest); [ -z "$CURRENT" ] && CURRENT=$(extract target)
CURRENT_HOST=${CURRENT%%:*}

if [ -z "$UUID" ] || [ -z "$PRIV" ]; then echo "无法从配置里读到 UUID/privateKey"; exit 1; fi
echo "当前 target: $CURRENT_HOST"
echo "备份已存到: $BACKUP"

TARGETS="${*:-$DEFAULT_TARGETS}"

write_server() {
  cat > "$CONF" <<EOF
{
  "log": { "loglevel": "info", "access": "/var/log/xray/access.log", "error": "/var/log/xray/error.log" },
  "inbounds": [{
    "listen": "0.0.0.0", "port": 443, "protocol": "vless",
    "settings": { "clients": [ { "id": "$UUID", "flow": "xtls-rprx-vision" } ], "decryption": "none" },
    "streamSettings": { "network": "tcp", "security": "reality", "realitySettings": {
      "show": false, "dest": "$1:443", "xver": 0,
      "serverNames": ["$1"], "privateKey": "$PRIV", "shortIds": ["$SID"] } }
  }],
  "outbounds": [ { "protocol": "freedom", "tag": "direct" } ]
}
EOF
}

test_target() {
  local host="$1"
  pkill -f _target_test.json 2>/dev/null; sleep 1
  write_server "$host"
  : > /var/log/xray/error.log 2>/dev/null
  systemctl restart xray; sleep 2

  cat > /tmp/_target_test.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [ { "listen": "127.0.0.1", "port": 10808, "protocol": "socks",
                  "settings": { "udp": true, "auth": "noauth" } } ],
  "outbounds": [ { "protocol": "vless",
    "settings": { "vnext": [ { "address": "127.0.0.1", "port": 443,
      "users": [ { "id": "$UUID", "encryption": "none", "flow": "xtls-rprx-vision" } ] } ] },
    "streamSettings": { "network": "tcp", "security": "reality", "realitySettings": {
      "serverName": "$host", "fingerprint": "chrome",
      "password": "$($XRAY x25519 -i "$PRIV" | grep -i Password | sed 's/.*: *//')",
      "shortId": "$SID" } } } ]
}
EOF
  nohup $XRAY run -c /tmp/_target_test.json > /tmp/_target_test.log 2>&1 &
  sleep 2
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" --socks5-hostname 127.0.0.1:10808 --max-time 12 https://www.google.com)
  local err=""
  err=$(grep -m1 'REALITY' /var/log/xray/error.log 2>/dev/null | sed 's/.*REALITY/REALITY/')
  if [ "$code" = "200" ]; then
    echo "  ✅ $host  →  code=$code"
  else
    echo "  ❌ $host  →  code=$code"
    [ -n "$err" ] && echo "        $err"
  fi
  pkill -f _target_test.json 2>/dev/null
}

echo
echo "########## 第 1 步：候选站 TLS 能力预检 ##########"
for t in $TARGETS; do
  out=$(timeout 20 $XRAY tls ping $t 2>&1)
  ver=$(echo "$out" | grep -m1 'TLS Version' | sed 's/.*: *//')
  pq=$(echo "$out" | grep -m1 'Post-Quantum' | sed 's/.*: *//' | cut -c1-4)
  printf "  %-26s tls=%-10s pq=%s\n" "$t" "${ver:-?}" "${pq:-?}"
done

echo
echo "########## 第 2 步：端到端实测（逐个改配置重启）##########"
for t in $TARGETS; do
  test_target "$t"
done

echo
echo "########## 恢复原配置 ##########"
cp "$BACKUP" "$CONF"
systemctl restart xray
sleep 1
echo -n "xray = "; systemctl is-active xray
echo "target 已恢复为: $(extract dest)"
pkill -f _target_test.json 2>/dev/null

echo
echo "把上面 ✅ 的域名填进 serverNames/dest，并同步更新客户端 servername。"
