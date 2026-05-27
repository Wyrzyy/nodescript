#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
# REMNANODE LAUNCHER — Ubuntu 24.04 / Debian 12
# Установщик: Remnanode + Selfsteal + WARP + GeoAssets (Loyalsoldier)
# Версия: 2026.3.0
###############################################################################

APP="remnanode"
DIR="/opt/$APP"
COMPOSE="$DIR/docker-compose.yml"
ASSETS_DIR="$DIR/assets"
LOG="/var/log/${APP}-install.log"
PANEL_IP_DEFAULT="141.98.7.57"
WARP_PORT=9091

# Источник geo-файлов
GEOSITE_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"
GEOIP_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"

export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none
export NEEDRESTART_MODE=a

GREEN='\033[0;32m'; RED='\033[0;31m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; WHITE='\033[1;37m'; GRAY='\033[0;37m'; NC='\033[0m'

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

###############################################################################
# OS detection + server info
###############################################################################
. /etc/os-release
case "$ID" in
  ubuntu|debian) ;;
  *) err "Поддерживается только Ubuntu/Debian. Найдено: $ID" ;;
esac

ARCH=$(dpkg --print-architecture)
CODENAME=$VERSION_CODENAME
CPU=$(nproc)
RAM_MB=$(free -m | awk '/^Mem:/ {print $2}')

get_public_ip() {
  curl -fsS4 --max-time 3 https://api.ipify.org 2>/dev/null \
    || curl -fsS4 --max-time 3 https://ifconfig.me 2>/dev/null \
    || curl -fsS4 --max-time 3 https://icanhazip.com 2>/dev/null \
    || echo "неизвестен"
}

PUBLIC_IP=$(get_public_ip)
LOCAL_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')

if   (( CPU <= 1 )); then BACKLOG=4096
elif (( CPU <= 2 )); then BACKLOG=16384
elif (( CPU <= 4 )); then BACKLOG=32768
else                      BACKLOG=65535
fi

###############################################################################
# Стартовый экран
###############################################################################
show_header() {
  clear
  echo -e "${BLUE}╔══════════════════════════════════════════╗"
  echo -e "║   🚀 REMNANODE LAUNCHER (2026)           ║"
  echo -e "╚══════════════════════════════════════════╝${NC}"
  echo
  echo -e "  ${WHITE}OS:${NC}        $PRETTY_NAME"
  echo -e "  ${WHITE}CPU/RAM:${NC}   $CPU cores | ${RAM_MB}MB | $ARCH"
  echo -e "  ${WHITE}Public IP:${NC} ${CYAN}${PUBLIC_IP}${NC}"
  echo -e "  ${WHITE}Local IP:${NC}  ${LOCAL_IP:-неизвестен}"
  echo
}

###############################################################################
# Проверка существующих установок
###############################################################################
check_existing_remnanode() {
  if [[ -d "$DIR" ]] || docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q '^remnanode$'; then
    return 0
  fi
  return 1
}

remove_existing_remnanode() {
  warn "Найдена существующая установка Remnanode."
  echo
  echo -e "  ${WHITE}Что есть:${NC}"
  [[ -d "$DIR" ]] && echo -e "    • Директория: ${GRAY}$DIR${NC}"
  docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q '^remnanode$' \
    && echo -e "    • Контейнер: ${GRAY}remnanode${NC}"
  echo
  read -rp "  Удалить старую установку перед продолжением? [y/N]: " ans
  if [[ ! "$ans" =~ ^[Yy]$ ]]; then
    echo
    warn "Установка отменена."
    exit 0
  fi

  echo
  if [[ -d "$DIR" ]] && [[ -f "$COMPOSE" ]]; then
    run_step "Остановка контейнера" "cd $DIR && docker compose down -v 2>/dev/null || true"
  fi
  docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q '^remnanode$' \
    && run_step "Удаление контейнера" "docker rm -f remnanode 2>/dev/null || true"
  [[ -d "$DIR" ]] && run_step "Удаление файлов" "rm -rf $DIR"
  ok "Старая установка удалена"
  echo
}

###############################################################################
# Базовая подготовка системы (общая для всех установщиков)
###############################################################################
prepare_system() {
  run_step "Обновление apt" "apt-get update -qq"

  run_step "Установка пакетов" \
"apt-get install -y -qq curl wget git jq ca-certificates gnupg lsb-release \
 nftables fail2ban irqbalance ethtool htop iftop \
 unattended-upgrades apt-listchanges \
 systemd-zram-generator dnsutils"

  # SWAP + ZRAM
  if (( RAM_MB <= 4096 )); then
    if [[ ! -f /swapfile ]]; then
      local SWAP_SIZE=$(( RAM_MB <= 2048 ? 2 : 1 ))
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
  fi

  run_step "Swappiness" \
"bash -c 'cat > /etc/sysctl.d/98-swap.conf <<EOF
vm.swappiness = 10
vm.vfs_cache_pressure = 50
EOF'"

  # SYSCTL — тюнинг ядра
  run_step "Тюнинг ядра (TCP/UDP/conntrack)" \
"bash -c 'cat > /etc/sysctl.d/99-remnanode.conf <<EOF
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
net.core.somaxconn = $BACKLOG
net.core.netdev_max_backlog = $BACKLOG
net.ipv4.tcp_max_syn_backlog = $BACKLOG
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 3
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.optmem_max = 65536
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
net.ipv4.udp_mem = 262144 524288 16777216
net.ipv4.ip_local_port_range = 1024 65535
net.netfilter.nf_conntrack_max = 1048576
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.netfilter.nf_conntrack_udp_timeout = 30
net.netfilter.nf_conntrack_udp_timeout_stream = 180
net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.log_martians = 1
fs.file-max = 2097152
fs.nr_open = 2097152
vm.max_map_count = 262144
EOF
modprobe nf_conntrack 2>/dev/null || true
echo nf_conntrack > /etc/modules-load.d/nf_conntrack.conf
echo 262144 > /sys/module/nf_conntrack/parameters/hashsize 2>/dev/null || true
sysctl --system >/dev/null'"

  # Limits
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

  # CPU governor
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

  # RPS
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

  # Auto security updates
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
}

###############################################################################
# Docker
###############################################################################
install_docker() {
  if command -v docker >/dev/null; then
    info "Docker уже установлен"
  else
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
}

###############################################################################
# GEO ASSETS — Loyalsoldier geosite.dat + geoip.dat
###############################################################################
install_geoassets() {
  info "Установка расширенных geo-файлов (Loyalsoldier)"
  info "Категории: yandex-ads, vk-ads, mail-ru-ads, category-ads-all и др."
  echo

  mkdir -p "$ASSETS_DIR"

  run_step "Скачивание geosite.dat" \
"curl -fsSL --retry 3 --max-time 60 -o $ASSETS_DIR/geosite.dat.new $GEOSITE_URL && \
 mv $ASSETS_DIR/geosite.dat.new $ASSETS_DIR/geosite.dat"

  run_step "Скачивание geoip.dat" \
"curl -fsSL --retry 3 --max-time 60 -o $ASSETS_DIR/geoip.dat.new $GEOIP_URL && \
 mv $ASSETS_DIR/geoip.dat.new $ASSETS_DIR/geoip.dat"

  # Хелпер для ручного обновления
  cat > /usr/local/bin/remnanode-geo-update <<EOF
#!/usr/bin/env bash
set -e
ASSETS_DIR="$ASSETS_DIR"
GEOSITE_URL="$GEOSITE_URL"
GEOIP_URL="$GEOIP_URL"

echo "[\$(date '+%F %T')] Обновление geo-файлов..."
mkdir -p "\$ASSETS_DIR"

curl -fsSL --retry 3 --max-time 60 -o "\$ASSETS_DIR/geosite.dat.new" "\$GEOSITE_URL" || { echo "geosite.dat: fail"; exit 1; }
curl -fsSL --retry 3 --max-time 60 -o "\$ASSETS_DIR/geoip.dat.new" "\$GEOIP_URL" || { echo "geoip.dat: fail"; exit 1; }

mv "\$ASSETS_DIR/geosite.dat.new" "\$ASSETS_DIR/geosite.dat"
mv "\$ASSETS_DIR/geoip.dat.new" "\$ASSETS_DIR/geoip.dat"
echo "Файлы обновлены. Перезапуск контейнера..."

cd /opt/remnanode && docker compose restart remnanode
echo "Готово."
EOF
  chmod +x /usr/local/bin/remnanode-geo-update

  # Cron на еженедельное обновление (воскресенье 4:00)
  run_step "Установка cron для автообновления" \
"bash -c 'cat > /etc/cron.d/remnanode-geo-update <<EOF
# Еженедельное обновление geo-файлов для Remnanode (Loyalsoldier)
0 4 * * 0 root /usr/local/bin/remnanode-geo-update >> /var/log/remnanode-geo-update.log 2>&1
EOF
chmod 644 /etc/cron.d/remnanode-geo-update'"

  local geosite_size geoip_size
  geosite_size=$(du -h "$ASSETS_DIR/geosite.dat" 2>/dev/null | cut -f1)
  geoip_size=$(du -h "$ASSETS_DIR/geoip.dat" 2>/dev/null | cut -f1)

  ok "Geo-файлы установлены (geosite: ${geosite_size}, geoip: ${geoip_size})"
  info "Ручное обновление: ${CYAN}remnanode-geo-update${NC}"
  info "Автообновление:    каждое воскресенье в 04:00"
}

###############################################################################
# nftables firewall — динамический, в зависимости от установленных сервисов
###############################################################################
setup_firewall() {
  local panel_ip="$1"
  local node_port="$2"
  local ssh_port="$3"
  local has_selfsteal="${4:-false}"

  local extra_tcp=""
  local extra_comment=""
  if [[ "$has_selfsteal" == "true" ]]; then
    extra_tcp=", 80, 9443"
    extra_comment="# Selfsteal: 80 (HTTP redirect) + 9443 (HTTPS)"
  fi

  run_step "nftables firewall" \
"bash -c 'cat > /etc/nftables.conf <<EOF
#!/usr/sbin/nft -f
flush ruleset

table inet filter {
  set panel_ips {
    type ipv4_addr
    elements = { ${panel_ip} }
  }

  chain input {
    type filter hook input priority 0; policy drop;

    iif lo accept
    ct state established,related accept
    ct state invalid drop

    ip protocol icmp limit rate 10/second accept

    tcp dport ${ssh_port} ct state new limit rate 10/minute accept
    tcp dport ${ssh_port} accept

    # NODE API — только панель
    tcp dport ${node_port} ip saddr @panel_ips accept
    tcp dport ${node_port} log prefix \"nft drop NODE_PORT: \" drop

    # XRay Reality + Hysteria2 ${extra_comment}
    tcp dport { 443, 8443${extra_tcp} } accept
    udp dport { 443, 8443 } accept

    # SYN flood защита
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
port = ${ssh_port}
EOF
systemctl enable fail2ban >/dev/null 2>&1
systemctl restart fail2ban'"
}

###############################################################################
# УСТАНОВКА REMNANODE
###############################################################################
install_remnanode() {
  show_header
  echo -e "${WHITE}🚀 Установка Remnanode${NC}"
  echo -e "${GRAY}────────────────────────────────${NC}"
  echo

  if check_existing_remnanode; then
    remove_existing_remnanode
  fi

  read -rp "🌐 IP панели Remnawave [${PANEL_IP_DEFAULT}]: " PANEL_IP
  PANEL_IP=${PANEL_IP:-$PANEL_IP_DEFAULT}
  [[ ! "$PANEL_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] && err "Некорректный IP: $PANEL_IP"

  read -rp "🔌 NODE_PORT [3000]: " NODE_PORT
  NODE_PORT=${NODE_PORT:-3000}
  [[ ! "$NODE_PORT" =~ ^[0-9]+$ ]] && err "NODE_PORT должен быть числом"

  read -rp "🔑 SSH порт [22]: " SSH_PORT
  SSH_PORT=${SSH_PORT:-22}

  echo
  info "SECRET_KEY скопируй из панели Remnawave → Nodes → Create"
  while true; do
    read -rsp "🔑 SECRET_KEY: " K1; echo
    read -rsp "🔑 Повтор:     " K2; echo
    [[ -z "$K1" ]] && { warn "Пусто"; continue; }
    [[ "$K1" != "$K2" ]] && { warn "Не совпадает"; continue; }
    break
  done
  ok "Ключ принят (${#K1} символов)"

  prepare_system
  install_docker

  local has_selfsteal=false
  [[ -d /opt/caddy ]] || [[ -d /opt/nginx-selfsteal ]] && has_selfsteal=true
  setup_firewall "$PANEL_IP" "$NODE_PORT" "$SSH_PORT" "$has_selfsteal"

  mkdir -p "$DIR"

  # Скачиваем geo-файлы ДО запуска контейнера, чтобы было что монтировать
  install_geoassets

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
      - XRAY_LOCATION_ASSET=/usr/local/share/xray
    cap_add:
      - NET_ADMIN
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    volumes:
      - /dev/shm:/dev/shm
      - ${ASSETS_DIR}/geosite.dat:/usr/local/share/xray/geosite.dat:ro
      - ${ASSETS_DIR}/geoip.dat:/usr/local/share/xray/geoip.dat:ro
EOF
  chmod 600 "$COMPOSE"
  ok "docker-compose.yml создан (с подменой geo-файлов)"

  cd "$DIR"
  run_step "Pull образа" "docker compose pull -q"
  run_step "Запуск контейнера" "docker compose down >/dev/null 2>&1 || true; docker compose up -d"

  sleep 5
  if ! docker ps --format '{{.Names}}' | grep -q '^remnanode$'; then
    err "Контейнер не запустился. Логи: docker logs remnanode"
  fi

  if ss -tlnp 2>/dev/null | grep -q ":${NODE_PORT} "; then
    ok "Контейнер работает и слушает порт ${NODE_PORT}"
  else
    warn "Контейнер запущен, но порт ${NODE_PORT} ещё не слушается"
  fi

  install_cli_panel

  echo
  echo -e "${GREEN}╔══════════════════════════════════════════╗"
  echo -e "║  ✔ REMNANODE УСТАНОВЛЕН                  ║"
  echo -e "╚══════════════════════════════════════════╝${NC}"
  echo
  echo -e "  Public IP:        ${CYAN}${PUBLIC_IP}${NC}"
  echo -e "  Панель IP:        ${PANEL_IP}"
  echo -e "  NODE_PORT:        ${NODE_PORT}"
  echo -e "  SSH порт:         ${SSH_PORT}"
  echo -e "  Geo-файлы:        ${CYAN}${ASSETS_DIR}/${NC}"
  echo -e "  Обновление geo:   ${CYAN}remnanode-geo-update${NC}"
  echo -e "  Управление:       ${CYAN}remnanode${NC}"
  echo
}

###############################################################################
# Переустановка только geo-файлов (для уже установленной ноды)
###############################################################################
reinstall_geoassets() {
  show_header
  echo -e "${WHITE}🌍 Обновление/установка geo-файлов${NC}"
  echo -e "${GRAY}────────────────────────────────${NC}"
  echo

  if ! [[ -f "$COMPOSE" ]]; then
    err "Remnanode не установлен. Сначала установи ноду."
  fi

  install_geoassets

  # Проверяем, есть ли уже volume-маунт в compose
  if ! grep -q "geosite.dat" "$COMPOSE"; then
    info "В docker-compose.yml нет volume-маунта для geo-файлов — добавляем"

    # Бэкап
    cp "$COMPOSE" "${COMPOSE}.bak.$(date +%Y%m%d-%H%M%S)"

    # Добавляем env-переменную и volumes через python (если есть) или sed
    python3 <<PYEOF
import re
with open("$COMPOSE") as f:
    content = f.read()

# Добавляем XRAY_LOCATION_ASSET в environment, если его нет
if "XRAY_LOCATION_ASSET" not in content:
    content = re.sub(
        r'(environment:\s*\n(?:\s+-\s+\S+\s*\n)+)',
        r'\1      - XRAY_LOCATION_ASSET=/usr/local/share/xray\n',
        content, count=1
    )

# Добавляем volumes
if "geosite.dat" not in content:
    if "volumes:" in content:
        content = re.sub(
            r'(volumes:\s*\n(?:\s+-\s+\S+.*\n)+)',
            r'\1      - $ASSETS_DIR/geosite.dat:/usr/local/share/xray/geosite.dat:ro\n      - $ASSETS_DIR/geoip.dat:/usr/local/share/xray/geoip.dat:ro\n',
            content, count=1
        )
    else:
        # Если секции volumes нет — добавим её
        content = content.rstrip() + """
    volumes:
      - $ASSETS_DIR/geosite.dat:/usr/local/share/xray/geosite.dat:ro
      - $ASSETS_DIR/geoip.dat:/usr/local/share/xray/geoip.dat:ro
"""

with open("$COMPOSE", "w") as f:
    f.write(content)
PYEOF
    ok "docker-compose.yml обновлён"
  fi

  run_step "Перезапуск контейнера" "cd $DIR && docker compose down && docker compose up -d"
  sleep 3
  if docker ps --format '{{.Names}}' | grep -q '^remnanode$'; then
    ok "Контейнер запущен с новыми geo-файлами"
  else
    err "Контейнер не запустился. Логи: docker logs remnanode"
  fi
}

###############################################################################
# УСТАНОВКА SELFSTEAL (через официальный скрипт DigneZzZ)
###############################################################################
install_selfsteal() {
  show_header
  echo -e "${WHITE}🎭 Установка Selfsteal (Reality маскировка)${NC}"
  echo -e "${GRAY}────────────────────────────────${NC}"
  echo
  info "Selfsteal — это веб-сервер (Caddy/Nginx) с фейковым сайтом для маскировки Reality-трафика."
  echo

  if [[ -d /opt/caddy ]] || [[ -d /opt/nginx-selfsteal ]]; then
    warn "Найдена существующая установка Selfsteal."
    read -rp "  Удалить и переустановить? [y/N]: " ans
    if [[ "$ans" =~ ^[Yy]$ ]]; then
      [[ -d /opt/caddy ]] && (cd /opt/caddy && docker compose down -v 2>/dev/null || true) && rm -rf /opt/caddy
      [[ -d /opt/nginx-selfsteal ]] && (cd /opt/nginx-selfsteal && docker compose down -v 2>/dev/null || true) && rm -rf /opt/nginx-selfsteal
      ok "Старая установка Selfsteal удалена"
      echo
    else
      warn "Установка отменена"
      return 0
    fi
  fi

  if ! command -v docker >/dev/null; then
    info "Docker не установлен — устанавливаем"
    install_docker
  fi

  echo -e "${WHITE}Выбор веб-сервера:${NC}"
  echo "  1) Caddy   (проще, авто-SSL)"
  echo "  2) Nginx   (быстрее, Unix socket, ACME через acme.sh)"
  echo
  read -rp "  Выбор [1/2, по умолчанию 1]: " ws_choice
  ws_choice=${ws_choice:-1}

  local ws_flag="--caddy"
  case "$ws_choice" in
    1) ws_flag="--caddy" ;;
    2) ws_flag="--nginx" ;;
    *) warn "Невалидный выбор, используем Caddy"; ws_flag="--caddy" ;;
  esac

  echo
  read -rp "🌐 Домен для маскировки (должен указывать на этот сервер): " STEAL_DOMAIN
  [[ -z "$STEAL_DOMAIN" ]] && err "Домен не может быть пустым"

  echo
  info "Запускаем официальный установщик Selfsteal от DigneZzZ"
  echo -e "${GRAY}  Источник: https://github.com/DigneZzZ/remnawave-scripts${NC}"
  echo

  bash <(curl -Ls https://github.com/DigneZzZ/remnawave-scripts/raw/main/selfsteal.sh) @ install $ws_flag

  local rc=$?
  if [[ $rc -eq 0 ]]; then
    if [[ -f /etc/nftables.conf ]] && grep -q "panel_ips" /etc/nftables.conf; then
      info "Обновляем firewall — добавляем порты Selfsteal"
      local panel_ip ssh_port node_port
      panel_ip=$(grep -oP 'elements = \{ \K[^ ]+' /etc/nftables.conf | head -1)
      ssh_port=$(grep -oP 'tcp dport \K[0-9]+(?= ct state new limit)' /etc/nftables.conf | head -1)
      node_port=$(grep -oP 'tcp dport \K[0-9]+(?= ip saddr @panel_ips)' /etc/nftables.conf | head -1)
      setup_firewall "${panel_ip:-$PANEL_IP_DEFAULT}" "${node_port:-3000}" "${ssh_port:-22}" "true"
    fi

    echo
    echo -e "${GREEN}╔══════════════════════════════════════════╗"
    echo -e "║  ✔ SELFSTEAL УСТАНОВЛЕН                  ║"
    echo -e "╚══════════════════════════════════════════╝${NC}"
    echo
    echo -e "  Управление Selfsteal:  ${CYAN}selfsteal${NC}"
    echo -e "  Сменить шаблон сайта:  ${CYAN}selfsteal template${NC}"
    echo -e "  Логи Selfsteal:        ${CYAN}selfsteal logs${NC}"
    echo
  else
    err "Установка Selfsteal завершилась с ошибкой"
  fi
}

###############################################################################
# УСТАНОВКА WARP (Cloudflare WARP в proxy-режиме)
###############################################################################
install_warp() {
  show_header
  echo -e "${WHITE}🌍 Установка Cloudflare WARP (SOCKS5 прокси)${NC}"
  echo -e "${GRAY}────────────────────────────────${NC}"
  echo
  info "WARP даст исходящий IP Cloudflare. Используется как outbound в XRay для обхода блокировок ChatGPT, Spotify, Netflix и т.п."
  echo

  if command -v warp-cli >/dev/null 2>&1; then
    warn "WARP уже установлен: $(warp-cli --version 2>/dev/null | head -1)"
    read -rp "  Переустановить? [y/N]: " ans
    if [[ ! "$ans" =~ ^[Yy]$ ]]; then
      warn "Установка отменена"
      return 0
    fi
    run_step "Удаление старой версии WARP" \
"systemctl stop warp-svc warp-auto 2>/dev/null || true
warp-cli --accept-tos disconnect 2>/dev/null || true
apt-get remove -y --purge cloudflare-warp 2>/dev/null || true
rm -f /etc/apt/sources.list.d/cloudflare-client.list /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
rm -f /etc/systemd/system/warp-auto.service /usr/local/bin/warp-fix-network.sh
systemctl daemon-reload"
  fi

  while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
    sleep 2
  done

  local warp_codename="$CODENAME"
  case "$CODENAME" in
    bullseye|bookworm|jammy|noble) ;;
    *) warn "Codename '$CODENAME' не поддерживается Cloudflare — используем 'noble'"; warp_codename="noble" ;;
  esac

  run_step "Добавление репозитория Cloudflare" \
"curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | \
 gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg && \
 echo \"deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ ${warp_codename} main\" > /etc/apt/sources.list.d/cloudflare-client.list && \
 apt-get update -qq"

  run_step "Установка cloudflare-warp" "apt-get install -y -qq cloudflare-warp"

  if ! command -v warp-cli >/dev/null 2>&1; then
    rm -f /etc/apt/sources.list.d/cloudflare-client.list
    apt-get update -qq >/dev/null 2>&1
    err "Не удалось установить cloudflare-warp"
  fi

  fix_warp_network_inline() {
    local iface prefix
    iface=$(ip route show default 2>/dev/null | awk '{print $5}' | head -1)
    [[ -z "$iface" ]] && return 0
    prefix=$(ip -4 addr show dev "$iface" 2>/dev/null | awk '/inet / {split($2,a,"/"); print a[2]}' | head -1)
    if [[ "$prefix" == "32" ]] || [[ -z "$prefix" ]]; then
      info "VPS /32 fix: добавляем 172.30.255.1/24 на $iface"
      ip addr add 172.30.255.1/24 dev "$iface" 2>/dev/null || true
      systemctl restart warp-svc &>/dev/null || true
      sleep 8
    fi
  }
  fix_warp_network_inline

  sleep 5

  run_step "Регистрация WARP" \
"warp-cli --accept-tos registration delete >/dev/null 2>&1 || true
warp-cli --accept-tos registration new >/dev/null 2>&1 || (sleep 3 && warp-cli --accept-tos registration new >/dev/null 2>&1) || true"

  run_step "Режим: SOCKS5 proxy на порту $WARP_PORT" \
"warp-cli --accept-tos mode proxy >/dev/null 2>&1 || true
warp-cli --accept-tos proxy port $WARP_PORT >/dev/null 2>&1 || true
warp-cli --accept-tos connect >/dev/null 2>&1 || true"

  local connected=false
  for i in {1..15}; do
    if warp-cli --accept-tos status 2>/dev/null | grep -qi "connected"; then
      connected=true
      break
    fi
    sleep 2
  done

  cat > /usr/local/bin/warp-fix-network.sh <<'FIXSCRIPT'
#!/bin/bash
iface=$(ip route show default 2>/dev/null | awk '{print $5}' | head -1)
[ -z "$iface" ] && exit 0
prefix=$(ip -4 addr show dev "$iface" 2>/dev/null | awk '/inet / {split($2,a,"/"); print a[2]}' | head -1)
if [ "$prefix" = "32" ] || [ -z "$prefix" ]; then
    ip addr add 172.30.255.1/24 dev "$iface" 2>/dev/null || true
    systemctl restart warp-svc
    sleep 5
fi
FIXSCRIPT
  chmod +x /usr/local/bin/warp-fix-network.sh

  cat > /etc/systemd/system/warp-auto.service <<'SYSTEMD'
[Unit]
Description=Cloudflare WARP auto-connect
After=network.target warp-svc.service
Requires=warp-svc.service

[Service]
Type=oneshot
ExecStartPre=/usr/local/bin/warp-fix-network.sh
ExecStart=/usr/bin/warp-cli --accept-tos connect
RemainAfterExit=yes
ExecStop=/usr/bin/warp-cli --accept-tos disconnect

[Install]
WantedBy=multi-user.target
SYSTEMD

  run_step "Автозапуск WARP" \
"systemctl daemon-reload && systemctl enable warp-auto >/dev/null 2>&1"

  sleep 3
  local warp_ip
  warp_ip=$(curl -s --max-time 10 --socks5 "127.0.0.1:${WARP_PORT}" https://cloudflare.com/cdn-cgi/trace 2>/dev/null | grep "^ip=" | cut -d= -f2)

  echo
  if [[ "$connected" == true ]] && [[ -n "$warp_ip" ]]; then
    ok "WARP работает. Cloudflare IP: ${CYAN}${warp_ip}${NC}"
  elif [[ -n "$warp_ip" ]]; then
    ok "Прокси отвечает (IP: $warp_ip), но статус ещё не 'connected'"
  else
    warn "WARP установлен, но прокси пока не отвечает. Проверь: warp-cli status"
  fi

  echo
  echo -e "${GREEN}╔══════════════════════════════════════════╗"
  echo -e "║  ✔ WARP УСТАНОВЛЕН                       ║"
  echo -e "╚══════════════════════════════════════════╝${NC}"
  echo
  echo -e "  SOCKS5 прокси:  ${CYAN}127.0.0.1:${WARP_PORT}${NC}"
  echo -e "  Статус:         ${CYAN}warp-cli status${NC}"
  echo -e "  Тест:           ${CYAN}curl --socks5 127.0.0.1:${WARP_PORT} https://cloudflare.com/cdn-cgi/trace${NC}"
  echo
  echo -e "${WHITE}XRay outbound config:${NC}"
  cat <<EOF
  {
    "tag": "warp",
    "protocol": "socks",
    "settings": {
      "servers": [{ "address": "127.0.0.1", "port": ${WARP_PORT} }]
    }
  }
EOF
  echo
}

###############################################################################
# CLI PANEL (устанавливается отдельно)
###############################################################################
install_cli_panel() {
cat > /usr/local/bin/remnanode <<'CLIEOF'
#!/usr/bin/env bash

GREEN='\033[0;32m'; RED='\033[0;31m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; WHITE='\033[1;37m'; GRAY='\033[0;37m'; NC='\033[0m'

LAUNCHER_LOCAL="/opt/remnanode/installer.sh"

pause(){ read -rp $'\nEnter для продолжения...' _; }

get_public_ip_cached() {
  local cache="/tmp/.remnanode_public_ip"
  if [[ -f "$cache" ]] && [[ $(( $(date +%s) - $(stat -c %Y "$cache" 2>/dev/null || echo 0) )) -lt 600 ]]; then
    cat "$cache"
  else
    local ip
    ip=$(curl -fsS4 --max-time 3 https://api.ipify.org 2>/dev/null || \
         curl -fsS4 --max-time 3 https://ifconfig.me 2>/dev/null || \
         echo "неизвестен")
    echo "$ip" > "$cache"
    echo "$ip"
  fi
}

live_panel() {
  trap 'return 0' INT
  while true; do
    clear
    echo -e "${BLUE}====================================="
    echo -e "        📡 LIVE PANEL"
    echo -e "  (Ctrl+C — выход в меню)"
    echo -e "=====================================${NC}"

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

    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qE '(caddy|nginx)-selfsteal'; then
      printf "  Selfsteal: ${GREEN}● running${NC}\n"
    fi

    if command -v warp-cli >/dev/null 2>&1; then
      if warp-cli --accept-tos status 2>/dev/null | grep -qi connected; then
        printf "  WARP:     ${GREEN}● connected${NC}\n"
      else
        printf "  WARP:     ${YELLOW}● not connected${NC}\n"
      fi
    fi

    # Geo-файлы
    if [[ -f /opt/remnanode/assets/geosite.dat ]]; then
      GEOSITE_AGE=$(( ( $(date +%s) - $(stat -c %Y /opt/remnanode/assets/geosite.dat) ) / 86400 ))
      printf "  GeoData:  ${GREEN}● установлено${NC} (обновлено %s дн. назад)\n" "$GEOSITE_AGE"
    else
      printf "  GeoData:  ${YELLOW}● не установлено${NC}\n"
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
      sleep 1
    fi

    sleep 1
  done
  trap - INT
}

manage_geo() {
  clear
  echo -e "${BLUE}====================================="
  echo -e "       🌍 GEO ASSETS"
  echo -e "=====================================${NC}"
  echo

  if [[ -f /opt/remnanode/assets/geosite.dat ]]; then
    GEOSITE_SIZE=$(du -h /opt/remnanode/assets/geosite.dat | cut -f1)
    GEOSITE_DATE=$(stat -c '%y' /opt/remnanode/assets/geosite.dat | cut -d. -f1)
    echo -e "  geosite.dat:  ${GREEN}${GEOSITE_SIZE}${NC}  (${GRAY}${GEOSITE_DATE}${NC})"
  else
    echo -e "  geosite.dat:  ${RED}не установлен${NC}"
  fi

  if [[ -f /opt/remnanode/assets/geoip.dat ]]; then
    GEOIP_SIZE=$(du -h /opt/remnanode/assets/geoip.dat | cut -f1)
    GEOIP_DATE=$(stat -c '%y' /opt/remnanode/assets/geoip.dat | cut -d. -f1)
    echo -e "  geoip.dat:    ${GREEN}${GEOIP_SIZE}${NC}  (${GRAY}${GEOIP_DATE}${NC})"
  else
    echo -e "  geoip.dat:    ${RED}не установлен${NC}"
  fi

  echo
  if [[ -f /etc/cron.d/remnanode-geo-update ]]; then
    echo -e "  Автообновление: ${GREEN}включено${NC} (вс. 04:00)"
  else
    echo -e "  Автообновление: ${YELLOW}не настроено${NC}"
  fi

  echo
  echo "  1) Обновить сейчас"
  echo "  2) Показать лог автообновлений"
  echo "  3) Откатить на v2fly (стандартный)"
  echo "  0) Назад"
  echo
  read -rp "  → " ch

  case "$ch" in
    1)
      if [[ -x /usr/local/bin/remnanode-geo-update ]]; then
        /usr/local/bin/remnanode-geo-update
      else
        echo -e "${RED}Скрипт обновления не найден. Переустанови ноду.${NC}"
      fi
      pause
      ;;
    2)
      if [[ -f /var/log/remnanode-geo-update.log ]]; then
        tail -50 /var/log/remnanode-geo-update.log
      else
        echo "Лог пуст (автообновление ещё не запускалось)"
      fi
      pause
      ;;
    3)
      echo
      warn "Откат удалит расширенные geo-файлы и убёрет volume-mount."
      warn "Все правила geosite:yandex-ads, vk-ads, mail-ru-ads перестанут работать!"
      read -rp "Продолжить? [y/N]: " ans
      if [[ "$ans" =~ ^[Yy]$ ]]; then
        rm -f /opt/remnanode/assets/geosite.dat /opt/remnanode/assets/geoip.dat
        rm -f /etc/cron.d/remnanode-geo-update
        rm -f /usr/local/bin/remnanode-geo-update
        echo "Файлы удалены. Не забудь убрать volume-mount из docker-compose.yml вручную."
      fi
      pause
      ;;
  esac
}

run_speedtest() {
  clear
  echo -e "${BLUE}====================================="
  echo -e "        🚀 SPEEDTEST"
  echo -e "=====================================${NC}"
  echo

  if ! command -v speedtest >/dev/null 2>&1 && ! command -v speedtest-cli >/dev/null 2>&1; then
    echo "Speedtest не установлен. Установить?"
    echo "  1) Ookla speedtest (рекомендуется, точнее)"
    echo "  2) speedtest-cli (Python, без регистрации)"
    echo "  0) Отмена"
    read -rp "→ " ch
    case "$ch" in
      1)
        echo
        echo "Устанавливаем Ookla speedtest..."
        curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | bash >/dev/null 2>&1
        apt-get install -y speedtest >/dev/null 2>&1 || { echo "Ошибка установки"; pause; return; }
        speedtest --accept-license --accept-gdpr >/dev/null 2>&1 || true
        ;;
      2)
        echo
        apt-get install -y speedtest-cli >/dev/null 2>&1 || { echo "Ошибка установки"; pause; return; }
        ;;
      *) return ;;
    esac
    echo
  fi

  echo "Выбери тест:"
  echo "  1) Быстрый тест (ближайший сервер)"
  echo "  2) Только ping и jitter"
  echo "  3) С подробным выводом"
  echo "  0) Назад"
  read -rp "→ " ch

  case "$ch" in
    1|3)
      echo
      if command -v speedtest >/dev/null 2>&1; then
        speedtest --accept-license --accept-gdpr
      else
        speedtest-cli ${ch:+--simple}
      fi
      ;;
    2)
      echo
      if command -v speedtest >/dev/null 2>&1; then
        speedtest --accept-license --accept-gdpr -f json 2>/dev/null | jq -r '
          "Ping:    \(.ping.latency) ms",
          "Jitter:  \(.ping.jitter) ms",
          "Server:  \(.server.name) (\(.server.location))"
        ' 2>/dev/null || speedtest --accept-license --accept-gdpr
      else
        speedtest-cli --simple
      fi
      ;;
    *) return ;;
  esac

  echo
  pause
}

run_installer() {
  echo
  echo -e "${WHITE}🔧 Установщики${NC}"
  echo "  1) Установить Remnanode (переустановка)"
  echo "  2) Установить Selfsteal"
  echo "  3) Установить WARP"
  echo "  4) 🌍 Установить/обновить Geo-файлы"
  echo "  0) Назад"
  echo
  read -rp "→ " c

  if [[ -f "$LAUNCHER_LOCAL" ]]; then
    case "$c" in
      1) bash "$LAUNCHER_LOCAL" install-remnanode ;;
      2) bash "$LAUNCHER_LOCAL" install-selfsteal ;;
      3) bash "$LAUNCHER_LOCAL" install-warp ;;
      4) bash "$LAUNCHER_LOCAL" install-geoassets ;;
      *) return ;;
    esac
  else
    echo -e "${YELLOW}Локальный установщик не найден.${NC}"
    pause
  fi
}

menu(){
while true; do
  clear
  PUBLIC_IP=$(get_public_ip_cached)
  echo -e "${BLUE}╔══════════════════════════════════════════╗"
  echo -e "║      🚀 REMNANODE PANEL                  ║"
  echo -e "╚══════════════════════════════════════════╝${NC}"
  echo -e "  Public IP: ${CYAN}${PUBLIC_IP}${NC}"
  echo
  echo " 1) Статус"
  echo " 2) Логи"
  echo " 3) Перезапуск"
  echo " 4) Стоп"
  echo " 5) Старт"
  echo " 6) Docker stats"
  echo " 7) LIVE мониторинг"
  echo " 8) 🚀 Speedtest"
  echo " 9) 🌍 Geo-файлы (обновить/откатить)"
  echo "10) 🔧 Установщики (Remnanode/Selfsteal/WARP/Geo)"
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
    8) run_speedtest ;;
    9) manage_geo ;;
    10) run_installer ;;
    0) exit 0 ;;
    *) ;;
  esac
done
}

menu
CLIEOF
  chmod +x /usr/local/bin/remnanode

  if [[ "${BASH_SOURCE[0]:-$0}" != "/opt/remnanode/installer.sh" ]]; then
    mkdir -p /opt/remnanode
    cp -f "${BASH_SOURCE[0]:-$0}" /opt/remnanode/installer.sh 2>/dev/null || true
    chmod +x /opt/remnanode/installer.sh 2>/dev/null || true
  fi
}

###############################################################################
# Главное меню лаунчера
###############################################################################
main_menu() {
  while true; do
    show_header

    local rn_status="${RED}не установлен${NC}"
    local ss_status="${RED}не установлен${NC}"
    local wp_status="${RED}не установлен${NC}"
    local geo_status="${RED}не установлено${NC}"

    docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^remnanode$' \
      && rn_status="${GREEN}● running${NC}" \
      || { [[ -d "$DIR" ]] && rn_status="${YELLOW}● stopped${NC}"; }

    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qE '(caddy|nginx)-selfsteal'; then
      ss_status="${GREEN}● running${NC}"
    elif [[ -d /opt/caddy ]] || [[ -d /opt/nginx-selfsteal ]]; then
      ss_status="${YELLOW}● stopped${NC}"
    fi

    if command -v warp-cli >/dev/null 2>&1; then
      if warp-cli --accept-tos status 2>/dev/null | grep -qi connected; then
        wp_status="${GREEN}● connected${NC}"
      else
        wp_status="${YELLOW}● disconnected${NC}"
      fi
    fi

    if [[ -f "$ASSETS_DIR/geosite.dat" ]]; then
      geo_status="${GREEN}● установлено${NC}"
    fi

    echo -e "  ${WHITE}Статус сервисов:${NC}"
    echo -e "    • Remnanode:  $rn_status"
    echo -e "    • Selfsteal:  $ss_status"
    echo -e "    • WARP:       $wp_status"
    echo -e "    • GeoAssets:  $geo_status"
    echo
    echo -e "${WHITE}Что устанавливаем?${NC}"
    echo
    echo -e "  ${WHITE}1)${NC} 🚀 Remnanode   ${GRAY}— нода Remnawave VPN (включает geo)${NC}"
    echo -e "  ${WHITE}2)${NC} 🎭 Selfsteal   ${GRAY}— фейковый сайт для маскировки Reality${NC}"
    echo -e "  ${WHITE}3)${NC} 🌍 WARP        ${GRAY}— Cloudflare SOCKS5 outbound${NC}"
    echo -e "  ${WHITE}4)${NC} 🗺  GeoAssets   ${GRAY}— расширенный geosite/geoip (Loyalsoldier)${NC}"
    echo -e "  ${WHITE}5)${NC} 📦 Всё сразу   ${GRAY}— Remnanode → Selfsteal → WARP${NC}"
    echo
    echo -e "  ${GRAY}0)${NC} Выход"
    echo
    read -rp "  → " choice

    case "$choice" in
      1) install_remnanode; echo; read -rp "Enter..." ;;
      2) install_selfsteal; echo; read -rp "Enter..." ;;
      3) install_warp; echo; read -rp "Enter..." ;;
      4) reinstall_geoassets; echo; read -rp "Enter..." ;;
      5)
        install_remnanode
        install_selfsteal
        install_warp
        echo; read -rp "Enter..."
        ;;
      0) exit 0 ;;
      *) ;;
    esac
  done
}

###############################################################################
# Точка входа
###############################################################################
case "${1:-}" in
  install-remnanode) install_remnanode ;;
  install-selfsteal) install_selfsteal ;;
  install-warp)      install_warp ;;
  install-geoassets) reinstall_geoassets ;;
  *)                 main_menu ;;
esac
