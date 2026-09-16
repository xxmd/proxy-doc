#!/bin/bash
# Xray VLESS + XTLS-Vision + REALITY 部署助手 (Ubuntu 24.04)
# 用法: bash xray-setup.sh /tmp/xray-config.json

CONF_SRC="${1:-/tmp/xray-config.json}"
CONF_DST=/usr/local/etc/xray/config.json

echo "=== 1. 安装配置 ==="
if [ ! -f "$CONF_SRC" ]; then echo "ERROR: 找不到 $CONF_SRC"; exit 1; fi
install -m 644 -o root -g root "$CONF_SRC" "$CONF_DST" && echo "OK -> $CONF_DST"

echo
echo "=== 2. 指定 geoip/geosite 资源路径 ==="
mkdir -p /etc/systemd/system/xray.service.d
cat > /etc/systemd/system/xray.service.d/10-asset.conf <<'EOF'
[Service]
Environment=XRAY_LOCATION_ASSET=/usr/local/share/xray
EOF
cat /etc/systemd/system/xray.service.d/10-asset.conf
systemctl daemon-reload && echo "daemon-reload OK"

echo
echo "=== 3. 日志目录权限（服务以 nobody 运行）==="
mkdir -p /var/log/xray
chown -R nobody:nogroup /var/log/xray
chmod 750 /var/log/xray
ls -ld /var/log/xray

echo
echo "=== 4. 开启 BBR + fq ==="
cat > /etc/sysctl.d/99-xray-tuning.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 131072 33554432
net.ipv4.tcp_wmem = 4096 16384 33554432
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fastopen = 3
EOF
sysctl --system >/dev/null 2>&1
echo -n "congestion_control = "; sysctl -n net.ipv4.tcp_congestion_control
echo -n "default_qdisc      = "; sysctl -n net.core.default_qdisc

echo
echo "=== 5. 配置语法检查 ==="
/usr/local/bin/xray run -test -config "$CONF_DST" 2>&1 | tail -n 3
/usr/local/bin/xray -test -config "$CONF_DST" 2>&1 | tail -n 3

echo
echo "=== 6. 重启服务 ==="
systemctl restart xray
sleep 2
echo -n "active = "; systemctl is-active xray

echo
echo "=== 7. 监听状态 ==="
ss -tlnp | grep ':443' || echo "WARN: 443 未监听"

echo
echo "=== 8. 服务环境变量 ==="
systemctl show xray -p Environment

echo
echo "=== 9. 服务日志（最后 15 行）==="
journalctl -u xray -n 15 --no-pager

echo
echo "=== 10. 本机自测：REALITY 伪装是否生效 ==="
echo "-- 用 www.microsoft.com 的 SNI 连本机 443，应返回微软真实响应 --"
curl -s -o /dev/null -w "http_code=%{http_code}  ssl_verify=%{ssl_verify_result}  time=%{time_total}s\n" \
  --resolve www.microsoft.com:443:127.0.0.1 https://www.microsoft.com --max-time 15
