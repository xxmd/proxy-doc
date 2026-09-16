#!/bin/bash
XRAY=/usr/local/bin/xray
UUID=367e8d69-3769-4355-857d-f2c48db57ecf
PUB=pkRXGVRAllSNLATNBPMP7KuDe0ej5BsbsKrUEfXAM2k
SID=95d78701bfdcb44b
TARGET=www.hkex.com.hk

echo "=== 1. install config ==="
install -m 644 -o root -g root /tmp/xray-config.json /usr/local/etc/xray/config.json
$XRAY run -test -config /usr/local/etc/xray/config.json 2>&1 | tail -n 2

echo
echo "=== 2. restart ==="
systemctl restart xray
sleep 2
echo -n "active = "; systemctl is-active xray
ss -tlnp | grep ':443' | head -n 1

echo
echo "=== 3. unauthenticated fallback (should look like a real site) ==="
curl -s -o /dev/null -w "fallback http_code=%{http_code} ssl_verify=%{ssl_verify_result}\n" \
  --resolve $TARGET:443:127.0.0.1 https://$TARGET --max-time 15

echo
echo "=== 4. REALITY client -> full chain ==="
cat > /tmp/cv.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [ { "listen": "127.0.0.1", "port": 10808, "protocol": "socks", "settings": { "udp": true, "auth": "noauth" } } ],
  "outbounds": [ { "protocol": "vless",
    "settings": { "vnext": [ { "address": "127.0.0.1", "port": 443,
      "users": [ { "id": "$UUID", "encryption": "none", "flow": "xtls-rprx-vision" } ] } ] },
    "streamSettings": { "network": "tcp", "security": "reality", "realitySettings": {
      "serverName": "$TARGET", "fingerprint": "chrome", "password": "$PUB", "shortId": "$SID" } } } ]
}
EOF
pkill -f cv.json 2>/dev/null
sleep 1
nohup $XRAY run -c /tmp/cv.json > /tmp/cv.log 2>&1 &
sleep 2
echo "google  : $(curl -s -o /dev/null -w '%{http_code}  %{time_total}s' --socks5-hostname 127.0.0.1:10808 --max-time 20 https://www.google.com)"
echo "youtube : $(curl -s -o /dev/null -w '%{http_code}  %{time_total}s' --socks5-hostname 127.0.0.1:10808 --max-time 20 https://www.youtube.com)"
echo "baidu   : $(curl -s -o /dev/null -w '%{http_code}  %{time_total}s' --socks5-hostname 127.0.0.1:10808 --max-time 10 https://www.baidu.com)  <- expect fail (CN blocked)"
echo
echo "exit IP : $(curl -s --socks5-hostname 127.0.0.1:10808 --max-time 20 'http://ip-api.com/json/?fields=country,city,isp,as,query')"
pkill -f cv.json 2>/dev/null

echo
echo "=== 5. access log (proxy worked if entries exist) ==="
tail -n 5 /var/log/xray/access.log
echo
echo "=== 6. recent errors ==="
tail -n 5 /var/log/xray/error.log
