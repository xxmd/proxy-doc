#!/usr/bin/env bash
# 香港 VPS 服务端 —— 初始化 + iperf3 带宽测试端点
#
#   bash bench-server.sh setup          # 装工具、开 BBR、放行端口、起 iperf3 服务
#   bash bench-server.sh report         # 打印内核/Qdisc/网卡/出口测速 快照
#   bash bench-server.sh iperf-start    # 只启动 iperf3 server (5201/tcp+udp)
#   bash bench-server.sh iperf-stop
#
# 客户端（大陆机器，需经代理/TUN）：iperf3 -c <HK_IP> -p 5201 -t 30     单流
#                                    iperf3 -c <HK_IP> -p 5201 -t 30 -P 8 多流
#                                    iperf3 -c <HK_IP> -p 5201 -u -b 200M  UDP(测 Hysteria2 环境)
set -uo pipefail

IPERF_PORT=5201
SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo"

log() { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[!]\033[0m %s\n' "$*"; }

need_tools() {
  if command -v apt-get >/dev/null 2>&1; then
    $SUDO apt-get update -qq
    $SUDO apt-get install -y -qq curl mtr-tiny iperf3 ca-certificates >/dev/null
  elif command -v dnf >/dev/null 2>&1; then
    $SUDO dnf install -y -q curl mtr iperf3 >/dev/null
  else
    warn "未知包管理器，请手动安装: curl mtr iperf3"
  fi
}

enable_bbr() {
  log "开启 BBR + fq（TCP 单流吞吐提升最大的一项）"
  cat <<'EOF' | $SUDO tee /etc/sysctl.d/99-proxy-tuning.conf >/dev/null
# --- TCP 拥塞控制与队列 ---
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
# --- 高 BDP 链路窗口 ---
net.ipv4.tcp_rmem = 4096 131072 33554432
net.ipv4.tcp_wmem = 4096 16384 33554432
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fastopen = 3
# --- 连接数（多设备/多并发） ---
net.core.somaxconn = 8192
net.ipv4.ip_local_port_range = 10000 65000
net.ipv4.tcp_tw_reuse = 1
fs.file-max = 1048576
EOF
  $SUDO sysctl --system >/dev/null 2>&1
  log "当前: cc=$(sysctl -n net.ipv4.tcp_congestion_control) qdisc=$(sysctl -n net.core.default_qdisc)"
}

open_ports() {
  log "放行 $IPERF_PORT/tcp+udp"
  if command -v ufw >/dev/null 2>&1 && $SUDO ufw status 2>/dev/null | grep -q "Status: active"; then
    $SUDO ufw allow ${IPERF_PORT}/tcp >/dev/null; $SUDO ufw allow ${IPERF_PORT}/udp >/dev/null
  elif command -v firewall-cmd >/dev/null 2>&1; then
    $SUDO firewall-cmd --add-port=${IPERF_PORT}/tcp --permanent >/dev/null
    $SUDO firewall-cmd --add-port=${IPERF_PORT}/udp --permanent >/dev/null
    $SUDO firewall-cmd --reload >/dev/null
  else
    warn "没检测到活动防火墙；请确认云厂商安全组也放行了 $IPERF_PORT 与你的代理端口"
  fi
}

iperf_start() {
  pkill -f "iperf3 -s" 2>/dev/null
  nohup iperf3 -s -p "$IPERF_PORT" >/var/tmp/iperf3.log 2>&1 &
  sleep 1
  log "iperf3 server 已启动 (端口 $IPERF_PORT)，日志 /var/tmp/iperf3.log"
}

iperf_stop() { pkill -f "iperf3 -s" 2>/dev/null; log "iperf3 server 已停止"; }

report() {
  echo "---------- 系统 ----------"
  echo "CPU:    $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | xargs) x$(nproc)"
  command -v openssl >/dev/null && echo "AES-NI: $(grep -qm1 aes /proc/cpuinfo && echo 支持 || echo '不支持(性能会差)')"
  echo "内存:   $(free -h | awk '/Mem:/{print $2" 总 / "$7" 可用"}')"
  echo "虚拟化: $(systemd-detect-virt 2>/dev/null || echo unknown)"
  echo
  echo "---------- 内核网络 ----------"
  echo "拥塞控制: $(sysctl -n net.ipv4.tcp_congestion_control)"
  echo "默认 qdisc: $(sysctl -n net.core.default_qdisc)"
  echo "MTU:      $(ip route get 1.1.1.1 2>/dev/null | grep -o 'mtu [0-9]*' || echo n/a)"
  echo
  echo "---------- 网卡累计流量 ----------"
  cat /proc/net/dev | awk 'NR>2 && $1!~/lo:/{gsub(":","",$1); printf "  %-10s RX %.2f GB  TX %.2f GB\n", $1, $2/1073741824, $10/1073741824}'
  echo
  echo "---------- 当前带宽使用 (3 秒采样) ----------"
  R1=$(awk 'NR>2 && $1!~/lo:/{rx+=$2; tx+=$10} END{print rx, tx}' /proc/net/dev)
  sleep 3
  R2=$(awk 'NR>2 && $1!~/lo:/{rx+=$2; tx+=$10} END{print rx, tx}' /proc/net/dev)
  awk -v a="$R1" -v b="$R2" 'BEGIN{split(a,x," ");split(b,y," ");printf "  ↓ %.2f Mbps   ↑ %.2f Mbps\n",(y[1]-x[1])*8/3/1e6,(y[2]-x[2])*8/3/1e6}'
  echo
  echo "---------- VPS 自身出口测速（≠ 回大陆速度） ----------"
  if ! command -v speedtest >/dev/null 2>&1; then
    log "安装 Ookla speedtest..."
    (curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | $SUDO bash) >/dev/null 2>&1
    $SUDO apt-get install -y -qq speedtest >/dev/null 2>&1
  fi
  if command -v speedtest >/dev/null 2>&1; then
    speedtest --accept-license --accept-gdpr -f human-readable 2>/dev/null | tail -n 12
  else
    warn "speedtest 安装失败，可手动: curl -sL https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-x86_64.tgz | tar xz"
  fi
  echo
  echo "提示: 服务端出口能跑 1Gbps 不代表你在大陆能跑满 —— 瓶颈通常在回程线路。"
}

case "${1:-}" in
  setup)       need_tools; enable_bbr; open_ports; iperf_start; report ;;
  report)      report ;;
  iperf-start) iperf_start ;;
  iperf-stop)  iperf_stop ;;
  *) sed -n '2,12p' "$0"; exit 1 ;;
esac
