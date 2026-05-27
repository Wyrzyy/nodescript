#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
# REMNANODE INSTALLER — Ubuntu 24.04 / Debian 12
# Оптимизировано под XRay Reality (TCP) + Hysteria2 (UDP)
# Версия: 2026.1
###############################################################################

APP="remnanode"
DIR="/opt/$APP"
COMPOSE="$DIR/docker-compose.yml"
LOG="/var/log/${APP}-install.log"
PANEL_IP_DEFAULT="141.98.7.57"

export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none
export NEEDRESTART_MODE=a

GREEN='\033[0;32m'; RED='\033[0;31m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; NC='\033[0m'

ok()   { echo -e "${GREEN}✔ $1${NC}"; }
info() { echo -e "${BLUE}ℹ $1${NC}"; }
warn() { echo -e "${YELLOW}⚠ $1${NC}"; }
err()  { echo -e "${RED}✖ $1${NC}"; echo "--- last 30 log lines ---"; tail -n 30 "$LOG" 2>/dev/null || true; exit 1; }

: > "$LOG"
exec 3>>"$LOG"

spin() {
  local pid=$1 msg=$2
  local s='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' i=0
  while kill -0 "$pid" 2>/dev/null; do
    printf "\r%s %s" "$msg" "${s:$((i++%${#s})):1}"
    sleep 0.08
  done
  wait "$pid"
  local rc=$?
  if [[ $rc -eq 0 ]]; then
    printf "\r${GREEN}✔${NC} %s\n" "$msg"
  else
    printf "\r${RED}✖${NC} %s\n" "$msg"
    return $rc
  fi
}

run_step() {
  local msg="$1" cmd="$2"
  echo "=== $msg ===" >&3
  ( eval "$cmd" >&3 2>&3 ) &
  spin $! "$msg" || err "Ошибка на шаге: $msg"
}

trap 'err "Скрипт прерван на строке $LINENO"' ERR

[[ $EUID -ne 0 ]] && err "Запусти от root: sudo bash $0"

clear
echo -e "${BLUE}===================================="
echo -e "   🚀 REMNANODE INSTALL (2026)"
echo -e "====================================${NC}"

###############################################################################
# OS detection
###############################################################################
. /etc/os-release
case "$ID" in
  ubuntu|debian) ok "OS: $PRETTY_NAME" ;;
  *) err "Поддерживается только Ubuntu/Debian. Найдено: $ID" ;;
esac

ARCH=$(dpkg --print-architecture)
CODENAME=$VERSION_CODENAME

###############################################################################
# System info
###############################################################################
CPU=$(nproc)
RAM_MB=$(free -m | awk '/^Mem:/ {print $2}')
info "CPU: $CPU cores | RAM: ${RAM_MB}MB | ARCH: $ARCH"

# Адаптивные значения backlog
if   (( CPU <= 1 )); then BACKLOG=4096
elif (( CPU <= 2 )); then BACKLOG=16384
elif (( CPU <= 4 )); then BACKLOG=32768
else                      BACKLOG=65535
fi

###############################################################################
# Ввод данных
###############################################################################
echo
read -rp "🌐 IP панели Remnawave [${PANEL_IP_DEFAULT}]: " PANEL_IP
PANEL_IP=${PANEL_IP:-$PANEL_IP_DEFAULT}
[[ ! "$PANEL_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] && err "Некорректный IP: $PANEL_IP"

read -rp "🔌 NODE_PORT [3000]: " NODE_PORT
NODE_PORT=${NODE_PORT:-3000}
[[ ! "$NODE_PORT" =~ ^[0-9]+$ ]] && err "NODE_PORT должен быть числом"

read -rp "🔑 SSH порт (для firewall) [22]: " SSH_PORT
SSH_PORT=${SSH_PORT:-22}

echo
info "SECRET_KEY скопируй из панели Remnawave → Nodes → Create → копировать содержимое .env"
while true; do
  read -rsp "🔑 SECRET_KEY: " K1; echo
  read -rsp "🔑 Повтор:     " K2; echo
  [[ -z "$K1" ]] && { warn "Пусто, повтори"; continue; }
  [[ "$K1" != "$K2" ]] && { warn "Не совпадает"; continue; }
  break
done
ok "Ключ принят (длина: ${#K1} символов)"

###############################################################################
# Базовые пакеты
###############################################################################
run_step "Обновление apt" "apt-get update -qq"

run_step "Установка пакетов" \
"apt-get install -y -qq curl wget git jq ca-certificates gnupg lsb-release \
 nftables fail2ban irqbalance ethtool htop iftop \
 unattended-upgrades apt-listchanges \
 systemd-zram-generator"

###############################################################################
# SWAP + ZRAM (правильно)
###############################################################################
if (( RAM_MB <= 4096 )); then
  if [[ ! -f /swapfile ]]; then
    SWAP_SIZE=$(( RAM_MB <= 2048 ? 2 : 1 ))
    run_step "Swap ${SWAP_SIZE}G" \
"fallocate -l ${SWAP_SIZE}G /swapfile && chmod 600 /swapfile && \
 mkswap /swapfile && swapon /swapfile && \
 echo '/swapfile none swap sw 0 0' >> /etc/fstab"
  fi

  if (( RAM_MB <= 2048 )); then
    run_step "ZRAM (50% RAM)" \
"bash -c 'cat > /etc/systemd/zram-generator.conf <<EOF
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
EOF
systemctl daemon-reload && systemctl restart systemd-zram-setup@zram0.service || true'"
  fi
else
  info "RAM > 4GB — swap не создаём"
fi

# Параметры swap для VPN-нагрузки
run_step "Swappiness" \
"bash -c 'cat > /etc/sysctl.d/98-swap.conf <<EOF
vm.swappiness = 10
vm.vfs_cache_pressure = 50
EOF'"

###############################################################################
# SYSCTL — главная оптимизация (TCP + UDP + conntrack)
###############################################################################
run_step "Тюнинг ядра (TCP/UDP/conntrack)" \
"bash -c 'cat > /etc/sysctl.d/99-remnanode.conf <<EOF
# ===== TCP =====
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 131072
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 60
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_max_tw_buckets = 1440000

# ===== Backlogs (адаптивно под $CPU CPU) =====
net.core.somaxconn = $BACKLOG
net.core.netdev_max_backlog = $BACKLOG
net.ipv4.tcp_max_syn_backlog = $BACKLOG

# ===== SYN flood защита =====
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 3

# ===== Буферы TCP =====
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.optmem_max = 65536
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# ===== UDP буферы (Hysteria2 / QUIC) =====
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
net.ipv4.udp_mem = 262144 524288 16777216

# ===== Порты =====
net.ipv4.ip_local_port_range = 1024 65535

# ===== Conntrack (критично под нагрузкой) =====
net.netfilter.nf_conntrack_max = 1048576
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.netfilter.nf_conntrack_udp_timeout = 30
net.netfilter.nf_conntrack_udp_timeout_stream = 180

# ===== IP forwarding (для Docker host networking) =====
net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1

# ===== Защита =====
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.log_martians = 1

# ===== Файлы и память =====
fs.file-max = 2097152
fs.nr_open = 2097152
vm.max_map_count = 262144
EOF

# nf_conntrack должен быть загружен до применения
modprobe nf_conntrack 2>/dev/null || true
echo nf_conntrack > /etc/modules-load.d/nf_conntrack.conf

# Hash table для conntrack
echo 262144 > /sys/module/nf_conntrack/parameters/hashsize 2>/dev/null || true

sysctl --system >/dev/null'"

###############################################################################
# LIMITS
###############################################################################
run_step "Системные лимиты" \
"bash -c 'cat > /etc/security/limits.d/99-remnanode.conf <<EOF
* soft nofile 1048576
* hard nofile 1048576
* soft nproc  unlimited
* hard nproc  unlimited
root soft nofile 1048576
root hard nofile 1048576
EOF
mkdir -p /etc/systemd/system.conf.d
cat > /etc/systemd/system.conf.d/limits.conf <<EOF
[Manager]
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=infinity
EOF'"

###############################################################################
# CPU governor → performance
###############################################################################
run_step "CPU governor: performance" \
"bash -c 'for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
  [ -w \$cpu ] && echo performance > \$cpu || true
done

cat > /etc/systemd/system/cpu-performance.service <<EOF
[Unit]
Description=Set CPU governor to performance
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c \"for c in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do [ -w \\\$c ] && echo performance > \\\$c || true; done\"
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload && systemctl enable cpu-performance.service >/dev/null 2>&1 || true'"

########################
