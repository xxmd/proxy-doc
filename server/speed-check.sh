#!/bin/bash
# Server-side egress speed + Telegram DC latency
# Separates "server international bandwidth" from "tunnel/client path"
UA='Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/120.0'

echo "=== 1. server egress speed (12s each) ==="
for pair in \
  "TG-Desktop|https://telegram.org/dl/desktop/win64" \
  "Tele2-SE|http://speedtest.tele2.net/100MB.zip" \
  "CF-100MB|https://speed.cloudflare.com/__down?bytes=100000000" ; do
  name=${pair%%|*}; url=${pair#*|}
  out=$(curl -s -L -A "$UA" -o /dev/null --max-time 12 -w "%{speed_download}|%{http_code}|%{size_download}" "$url" 2>/dev/null)
  bps=${out%%|*}; rest=${out#*|}; code=${rest%%|*}; size=${rest##*|}
  mbps=$(awk -v b="$bps" 'BEGIN{printf "%.2f", b*8/1048576}')
  mb=$(awk -v s="$size" 'BEGIN{printf "%.1f", s/1048576}')
  printf "  %-12s %8s Mbps  %6s MB  (HTTP %s)\n" "$name" "$mbps" "$mb" "$code"
done

echo
echo "=== 2. server -> Telegram DC RTT (ICMP) ==="
for pair in \
  "DC1-Miami|149.154.175.53" \
  "DC2-Amsterdam|149.154.167.51" \
  "DC4-Amsterdam|149.154.167.91" \
  "DC5-Singapore|91.108.56.130" ; do
  name=${pair%%|*}; ip=${pair#*|}
  out=$(ping -c 4 -W 2 "$ip" 2>/dev/null)
  avg=$(echo "$out" | grep -o 'min/avg/max[^ ]*' | head -1)
  vals=$(echo "$out" | tail -n 2 | head -1)
  loss=$(echo "$out" | grep -o '[0-9]*% packet loss' | head -1)
  printf "  %-14s %-16s %s\n" "$name" "$ip" "${vals:-no reply} ${loss}"
done

echo
echo "=== 3. server -> TG DC TCP/443 handshake ==="
for ip in 149.154.167.51 91.108.56.130; do
  t=$( { time -p timeout 5 bash -c "echo > /dev/tcp/$ip/443" ; } 2>&1 | grep real )
  printf "  %-16s %s\n" "$ip" "${t:-fail}"
done

echo
echo "=== 4. server public IP + route to Europe vs Asia ==="
echo -n "  public IP: "; curl -s --max-time 8 http://ip-api.com/line/?fields=query,country,isp
echo "  route to hetzner.de (DE):"
traceroute -n -m 12 -w 1 speed.hetzner.de 2>/dev/null | tail -n 6 || echo "    (traceroute unavailable)"
