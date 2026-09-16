#!/bin/bash
XRAY=/usr/local/bin/xray
SRV=/usr/local/etc/xray/config.json
UUID=367e8d69-3769-4355-857d-f2c48db57ecf
PRIV=6FBlLhQFSFzFl0z9aQvhoTWlk36wxGI5_kFHvz2aWGk
PUB=pkRXGVRAllSNLATNBPMP7KuDe0ej5BsbsKrUEfXAM2k
SID=95d78701bfdcb44b

write_server() {   # $1 = target host   $2 = network (tcp|raw)
  cat > $SRV <<EOF
{
  "log": { "loglevel": "info", "access": "/var/log/xray/access.log", "error": "/var/log/xray/error.log" },
  "inbounds": [{
    "listen": "0.0.0.0", "port": 443, "protocol": "vless",
    "settings": { "clients": [ { "id": "$UUID", "flow": "xtls-rprx-vision" } ], "decryption": "none" },
    "streamSettings": { "network": "$2", "security": "reality", "realitySettings": {
      "show": false, "dest": "$1:443", "xver": 0,
      "serverNames": ["$1"], "privateKey": "$PRIV", "shortIds": ["$SID"] } }
  }],
  "outbounds": [ { "protocol": "freedom", "tag": "direct" } ]
}
EOF
}

write_client() {   # $1 = target host   $2 = network
  cat > /tmp/c3.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [ { "listen": "127.0.0.1", "port": 10808, "protocol": "socks", "settings": { "udp": true, "auth": "noauth" } } ],
  "outbounds": [ { "protocol": "vless",
    "settings": { "vnext": [ { "address": "127.0.0.1", "port": 443,
      "users": [ { "id": "$UUID", "encryption": "none", "flow": "xtls-rprx-vision" } ] } ] },
    "streamSettings": { "network": "$2", "security": "reality", "realitySettings": {
      "serverName": "$1", "fingerprint": "chrome", "password": "$PUB", "shortId": "$SID" } } } ]
}
EOF
}

test_one() {   # $1 = label  $2 = target host  $3 = network
  pkill -f c3.json 2>/dev/null
  write_server "$2" "$3"
  write_client "$2" "$3"
  : > /var/log/xray/error.log
  systemctl restart xray
  sleep 2
  nohup $XRAY run -c /tmp/c3.json > /tmp/c3.log 2>&1 &
  sleep 2
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" --socks5-hostname 127.0.0.1:10808 --max-time 10 https://www.google.com)
  local srv=""
  srv=$(grep -m1 'REALITY' /var/log/xray/error.log | sed 's/.*REALITY/REALITY/')
  echo ">>> $1  code=$code"
  echo "    server: ${srv:-<no reality log>}"
  pkill -f c3.json 2>/dev/null
}

echo "########## target x network matrix ##########"
for t in www.microsoft.com www.apple.com www.cloudflare.com www.amazon.com www.lovelive-anime.jp www.hkex.com.hk; do
  out=$(timeout 20 $XRAY tls ping $t 2>&1)
  ver=$(echo "$out" | grep -m1 'TLS Version' | sed 's/.*: *//')
  pq=$(echo "$out" | grep -m1 'Post-Quantum' | sed 's/.*: *//' | cut -c1-4)
  echo "--- $t : tls=${ver:-?} pq=${pq:-?}"
  if echo "$ver" | grep -q '1.3'; then
    test_one "$t/tcp" "$t" tcp
  else
    echo "    skip (no TLS1.3)"
  fi
done

echo
echo "########## extra: microsoft with network=raw ##########"
test_one "microsoft/raw" www.microsoft.com raw

echo
echo "########## restore ##########"
write_server www.microsoft.com tcp
systemctl restart xray
sleep 1
systemctl is-active xray
