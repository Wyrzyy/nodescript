#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
# REMNANODE INSTALLER — Ubuntu 24.04 / Debian 12
# Оптимизировано под XRay Reality (TCP) + Hysteria2 (UDP)
# Версия: 2026.1.3
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

PUBLIC_IP=$(curl -fsS4 --max-time 3 https://api.ipify.org 2>/dev/null \
         || curl -fsS4 --max-time 3 https://ifconfig.me 2>/dev/null \
         || curl -fsS4 --max-time 3 https://icanhazip.com 2>/dev/null \
         || echo "неизвестен")
LOCAL_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')

info "CPU: $CPU cores | RAM: ${RAM_MB}MB | ARCH: $ARCH"
info "Public IP:  $PUBLIC_IP"
info "Local IP:   ${LOCAL_IP:-неизвестен}"

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
# SWAP + ZRAM
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

run_step "Swappiness" \
"bash -c 'cat > /etc/sysctl.d/98-swap.conf <<EOF
vm.swappiness = 10
vm.vfs_cache_pressure = 50
EOF'"

###############################################################################
# SYSCTL
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

# ===== Backlogs =====
net.core.somaxconn = $BACKLOG
net.core.netdev_max_backlog = $BACKLOG
net.ipv4.tcp_max_syn_backlog = $BACKLOG

# ===== SYN flood =====
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

# ===== UDP (Hysteria2 / QUIC) =====
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
net.ipv4.udp_mem = 262144 524288 16777216

# ===== Порты =====
net.ipv4.ip_local_port_range = 1024 65535

# ===== Conntrack =====
net.netfilter.nf_conntrack_max = 1048576
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.netfilter.nf_conntrack_udp_timeout = 30
net.netfilter.nf_conntrack_udp_timeout_stream = 180

# ===== IP forwarding =====
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

# ===== Файлы =====
fs.file-max = 2097152
fs.nr_open = 2097152
vm.max_map_count = 262144
EOF

modprobe nf_conntrack 2>/dev/null || true
echo nf_conntrack > /etc/modules-load.d/nf_conntrack.conf
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
# CPU governor
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

###############################################################################
# RPS
###############################################################################
if (( CPU > 1 )); then
  run_step "RPS (Receive Packet Steering)" \
"bash -c 'IFACE=\$(ip route show default | awk \"/default/ {print \\\$5; exit}\")
if [ -n \"\$IFACE\" ]; then
  MASK=\$(printf \"%x\" \$(( (1 << $CPU) - 1 )))
  for q in /sys/class/net/\$IFACE/queues/rx-*/rps_cpus; do
    [ -w \$q ] && echo \$MASK > \$q || true
  done
  echo 32768 > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null || true
  for q in /sys/class/net/\$IFACE/queues/rx-*/rps_flow_cnt; do
    [ -w \$q ] && echo 4096 > \$q || true
  done
fi

cat > /etc/systemd/system/rps-tune.service <<EOF
[Unit]
Description=RPS network tuning
After=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c \"IFACE=\\\$(ip route show default | awk \\\"/default/ {print \\\\\\\$5; exit}\\\"); MASK=\\\$(printf %x \\\$(( (1 << $CPU) - 1 ))); for q in /sys/class/net/\\\$IFACE/queues/rx-*/rps_cpus; do [ -w \\\$q ] && echo \\\$MASK > \\\$q; done\"
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload && systemctl enable rps-tune.service >/dev/null 2>&1 || true
systemctl enable irqbalance >/dev/null 2>&1 && systemctl restart irqbalance || true'"
fi

###############################################################################
# nftables FIREWALL
###############################################################################
run_step "nftables firewall" \
"bash -c 'cat > /etc/nftables.conf <<EOF
#!/usr/sbin/nft -f
flush ruleset

table inet filter {
  set panel_ips {
    type ipv4_addr
    elements = { ${PANEL_IP} }
  }

  chain input {
    type filter hook input priority 0; policy drop;

    iif lo accept
    ct state established,related accept
    ct state invalid drop

    ip protocol icmp limit rate 10/second accept

    tcp dport ${SSH_PORT} ct state new limit rate 10/minute accept
    tcp dport ${SSH_PORT} accept

    tcp dport ${NODE_PORT} ip saddr @panel_ips accept
    tcp dport ${NODE_PORT} log prefix \"nft drop NODE_PORT: \" drop

    tcp dport { 443, 8443 } accept
    udp dport { 443, 8443 } accept

    tcp flags & (fin|syn|rst|ack) == syn ct state new limit rate 200/second burst 50 packets accept
    tcp flags & (fin|syn|rst|ack) == syn ct state new drop

    limit rate 5/minute log prefix \"nft drop: \"
  }

  chain forward {
    type filter hook forward priority 0; policy accept;
    ct state invalid drop
  }

  chain output {
    type filter hook output priority 0; policy accept;
  }
}
EOF

systemctl enable nftables >/dev/null 2>&1
systemctl restart nftables
nft list ruleset > /dev/null'"

###############################################################################
# Fail2Ban
###############################################################################
run_step "Fail2Ban" \
"bash -c 'cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
banaction = nftables-multiport
banaction_allports = nftables-allports
bantime = 24h
findtime = 10m
maxretry = 3
backend = systemd

[sshd]
enabled = true
port = ${SSH_PORT}
EOF
systemctl enable fail2ban >/dev/null 2>&1
systemctl restart fail2ban'"

###############################################################################
# Auto security upgrades
###############################################################################
run_step "Auto security updates" \
"bash -c 'cat > /etc/apt/apt.conf.d/50unattended-upgrades <<EOF
Unattended-Upgrade::Allowed-Origins {
    \"\${distro_id}:\${distro_codename}-security\";
    \"\${distro_id}ESMApps:\${distro_codename}-apps-security\";
    \"\${distro_id}ESM:\${distro_codename}-infra-security\";
};
Unattended-Upgrade::Automatic-Reboot \"false\";
Unattended-Upgrade::Remove-Unused-Dependencies \"true\";
EOF
cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists \"1\";
APT::Periodic::Unattended-Upgrade \"1\";
EOF
systemctl enable unattended-upgrades >/dev/null 2>&1
systemctl restart unattended-upgrades'"

###############################################################################
# Docker
###############################################################################
if ! command -v docker >/dev/null; then
  run_step "Docker репозиторий" \
"install -m 0755 -d /etc/apt/keyrings && \
 curl -fsSL https://download.docker.com/linux/${ID}/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg && \
 chmod a+r /etc/apt/keyrings/docker.gpg && \
 echo \"deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${ID} ${CODENAME} stable\" > /etc/apt/sources.list.d/docker.list && \
 apt-get update -qq"

  run_step "Docker установка" \
"apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin && \
 systemctl enable docker && systemctl start docker"
fi

run_step "Docker daemon config" \
"bash -c 'mkdir -p /etc/docker && cat > /etc/docker/daemon.json <<EOF
{
  \"log-driver\": \"json-file\",
  \"log-opts\": {
    \"max-size\": \"10m\",
    \"max-file\": \"3\"
  },
  \"live-restore\": true,
  \"userland-proxy\": false,
  \"default-ulimits\": {
    \"nofile\": {
      \"Name\": \"nofile\",
      \"Hard\": 1048576,
      \"Soft\": 1048576
    }
  }
}
EOF
systemctl restart docker'"

###############################################################################
# docker-compose.yml
# Переменная NODE_PORT (НЕ APP_PORT!) — официальное имя у Remnawave node.
# sysctls внутри контейнера не задаются — они применены на хосте,
# а host network namespace их подхватывает автоматически.
###############################################################################
mkdir -p "$DIR"

cat > "$COMPOSE" <<EOF
services:
  remnanode:
    image: remnawave/node:latest
    container_name: remnanode
    hostname: remnanode
    network_mode: host
    restart: always
    environment:
      - SECRET_KEY=${K1}
      - NODE_PORT=${NODE_PORT}
    cap_add:
      - NET_ADMIN
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
EOF

chmod 600 "$COMPOSE"
ok "docker-compose.yml создан (chmod 600)"

###############################################################################
# Запуск
###############################################################################
cd "$DIR"
run_step "Pull образа" "docker compose pull -q"
run_step "Запуск контейнера" "docker compose down >/dev/null 2>&1 || true; docker compose up -d"

sleep 5

if ! docker ps --format '{{.Names}}' | grep -q '^remnanode$'; then
  err "Контейнер не запустился. Логи: docker logs remnanode"
fi

# Проверка, что NODE_PORT реально слушается
if ss -tlnp 2>/dev/null | grep -q ":${NODE_PORT} "; then
  ok "Контейнер remnanode работает и слушает порт ${NODE_PORT}"
else
  warn "Контейнер запущен, но порт ${NODE_PORT} ещё не слушается — проверь: docker logs remnanode"
fi

###############################################################################
# CLI panel
###############################################################################
cat > /usr/local/bin/remnanode <<'CLIEOF'
#!/usr/bin/env bash

GREEN='\033[0;32m'; RED='\033[0;31m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; NC='\033[0m'

pause(){ read -rp $'\nEnter для продолжения...' _; }

live_panel() {
  trap 'return 0' INT
  while true; do
    clear
    echo -e "${BLUE}===================================="
    echo -e "        📡 LIVE PANEL"
    echo -e "  (Ctrl+C — выход в меню)"
    echo -e "====================================${NC}"

    echo -e "${YELLOW}── SYSTEM STATS ──${NC}"
    UPTIME=$(uptime -p 2>/dev/null | sed 's/^up //')
    LOAD=$(awk '{print $1", "$2", "$3}' /proc/loadavg)
    CPU_CORES=$(nproc)
    CPU_USAGE=$(top -bn1 | awk '/Cpu\(s\)/ {printf "%.1f", 100 - $8}')
    MEM=$(free -m | awk '/^Mem:/ {printf "%s / %s MB (%.0f%%)", $3, $2, $3*100/$2}')
    SWAP=$(free -m | awk '/^Swap:/ {if($2>0) printf "%s / %s MB", $3, $2; else print "—"}')
    DISK=$(df -h / | awk 'NR==2 {printf "%s / %s (%s)", $3, $2, $5}')

    printf "  Uptime:   %s\n" "$UPTIME"
    printf "  Load:     %s  (cores: %s)\n" "$LOAD" "$CPU_CORES"
    printf "  CPU:      %s%%\n" "$CPU_USAGE"
    printf "  RAM:      %s\n" "$MEM"
    printf "  Swap:     %s\n" "$SWAP"
    printf "  Disk /:   %s\n" "$DISK"

    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^remnanode$'; then
      CSTATS=$(docker stats --no-stream --format '{{.CPUPerc}} | {{.MemUsage}}' remnanode 2>/dev/null)
      printf "  Node:     ${GREEN}● running${NC}  (%s)\n" "$CSTATS"
    else
      printf "  Node:     ${RED}● stopped${NC}\n"
    fi

    echo
    echo -e "${YELLOW}── CONNECTIONS ──${NC}"
    TOTAL=$(ss -ntu 2>/dev/null | tail -n +2 | wc -l)
    EST=$(ss -tn state established 2>/dev/null | tail -n +2 | wc -l)
    TW=$(ss -tn state time-wait 2>/dev/null | tail -n +2 | wc -l)
    UDP=$(ss -un 2>/dev/null | tail -n +2 | wc -l)
    CT_USED=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo "?")
    CT_MAX=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo "?")

    printf "  Total:        %s\n" "$TOTAL"
    printf "  Established:  %s\n" "$EST"
    printf "  TIME-WAIT:    %s\n" "$TW"
    printf "  UDP:          %s\n" "$UDP"
    printf "  Conntrack:    %s / %s\n" "$CT_USED" "$CT_MAX"

    echo
    echo -e "${YELLOW}── TOP 10 IP (established) ──${NC}"
    ss -tn state established 2>/dev/null \
      | awk 'NR>1 {split($5,a,":"); print a[1]}' \
      | sort | uniq -c | sort -nr | head -10 \
      | awk '{printf "  %5s  %s\n", $1, $2}'

    echo
    echo -e "${YELLOW}── NETWORK I/O (1s) ──${NC}"
    IFACE=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
    if [[ -n "$IFACE" ]]; then
      RX1=$(cat /sys/class/net/$IFACE/statistics/rx_bytes)
      TX1=$(cat /sys/class/net/$IFACE/statistics/tx_bytes)
      sleep 1
      RX2=$(cat /sys/class/net/$IFACE/statistics/rx_bytes)
      TX2=$(cat /sys/class/net/$IFACE/statistics/tx_bytes)
      RX_KBS=$(( (RX2 - RX1) / 1024 ))
      TX_KBS=$(( (TX2 - TX1) / 1024 ))
      printf "  %-6s  RX: %6s KB/s   TX: %6s KB/s\n" "$IFACE" "$RX_KBS" "$TX_KBS"
    else
      echo "  Интерфейс не найден"
      sleep 1
    fi

    sleep 1
  done
  trap - INT
}

menu(){
while true; do
  clear
  echo -e "${BLUE}===================================="
  echo -e "      🚀 REMNANODE PANEL"
  echo -e "====================================${NC}"
  echo " 1) Статус"
  echo " 2) Логи"
  echo " 3) Перезапуск"
  echo " 4) Стоп"
  echo " 5) Старт"
  echo " 6) Stats"
  echo " 7) LIVE"
  echo " 0) Выход"
  echo "------------------------------------"
  read -rp " → " c
  case $c in
    1) docker ps --filter "name=remnanode"; pause ;;
    2) docker logs -f --tail 50 remnanode ;;
    3) docker restart remnanode; pause ;;
    4) docker stop remnanode; pause ;;
    5) docker start remnanode; pause ;;
    6) docker stats remnanode ;;
    7) live_panel ;;
    0) exit 0 ;;
    *) ;;
  esac
done
}

menu
CLIEOF

chmod +x /usr/local/bin/remnanode

###############################################################################
# DONE
###############################################################################
echo
echo -e "${GREEN}===================================="
echo -e "  ✔ УСТАНОВКА ЗАВЕРШЕНА"
echo -e "====================================${NC}"
echo
echo " Public IP:               ${PUBLIC_IP}"
echo " Панель IP (whitelisted): ${PANEL_IP}"
echo " NODE_PORT:               ${NODE_PORT}"
echo " SSH порт:                ${SSH_PORT}"
echo " Лог установки:           ${LOG}"
echo
echo " Управление:              remnanode"
echo " Проверка firewall:       nft list ruleset"
echo " Логи ноды:               docker logs -f remnanode"
echo
warn "Рекомендую сделать reboot, чтобы все sysctl/limits применились окончательно."
