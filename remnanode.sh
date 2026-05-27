#!/usr/bin/env bash
set -Eeuo pipefail

APP="remnanode"
DIR="/opt/$APP"
COMPOSE="$DIR/docker-compose.yml"

export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none

GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok(){ echo -e "${GREEN}✔ $1${NC}"; }
info(){ echo -e "${BLUE}ℹ $1${NC}"; }
warn(){ echo -e "${YELLOW}⚠ $1${NC}"; }
err(){ echo -e "${RED}✖ $1${NC}"; exit 1; }

spin(){
  local pid=$1 msg=$2
  local s='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  while kill -0 $pid 2>/dev/null; do
    for ((i=0;i<${#s};i++)); do
      printf "\r%s %s" "$msg" "${s:$i:1}"
      sleep 0.07
    done
  done
  printf "\r%s ✔\n" "$msg"
}

bar(){
  local c=$1 t=$2 m=$3
  local p=$((c*100/t))
  local f=$((p/10))
  printf "\r[%d/%d] %-20s [" "$c" "$t" "$m"
  for i in {1..10}; do
    [[ $i -le $f ]] && printf "█" || printf "-"
  done
  printf "] %d%%" "$p"
  [[ $c -eq $t ]] && echo
}

[[ $EUID -ne 0 ]] && err "Запусти от root"

clear
echo -e "${BLUE}==== REMNANODE INSTALL ====${NC}"

CPU=$(nproc)
RAM_MB=$(free -m | awk '/Mem:/ {print $2}')

info "CPU: $CPU | RAM: ${RAM_MB}MB"

########################################
# SWAP + ZRAM
########################################

if [[ $RAM_MB -le 4096 ]]; then
  info "Настройка swap..."

  if [[ ! -f /swapfile ]]; then
    fallocate -l $(( RAM_MB <= 2048 ? 2 : 1 ))G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
  fi

  if [[ $RAM_MB -le 2048 ]]; then
    modprobe zram 2>/dev/null || true
    echo lz4 > /sys/block/zram0/comp_algorithm 2>/dev/null || true
    echo $((RAM_MB * 1024 * 1024 / 2)) > /sys/block/zram0/disksize 2>/dev/null || true
    mkswap /dev/zram0 >/dev/null 2>&1 || true
    swapon /dev/zram0 >/dev/null 2>&1 || true
  fi

  ok "Swap/ZRAM настроены"
else
  info "Swap не требуется"
fi

########################################
# PACKAGES
########################################

(
apt update -qq >/dev/null 2>&1
apt install -y -qq curl wget git jq fail2ban iptables irqbalance >/dev/null 2>&1
) & spin $! "Пакеты"

bar 1 5 "Пакеты"

########################################
# SYSCTL SAFE
########################################

cat >/etc/sysctl.d/99-remnanode.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.somaxconn=65535
net.core.netdev_max_backlog=$((CPU * 2048))
net.ipv4.tcp_max_syn_backlog=$((CPU * 2048))
net.ipv4.tcp_fastopen=3
net.ipv4.ip_local_port_range=1024 65535
fs.file-max=$((RAM_MB * 1024))
vm.swappiness=$([[ $RAM_MB -le 2048 ]] && echo 60 || echo 20)
EOF

sysctl --system >/dev/null 2>&1 & spin $! "Sysctl"
bar 2 5 "Kernel"

########################################
# LIMITS
########################################

cat >/etc/security/limits.d/99-remnanode.conf <<EOF
* soft nofile 1048576
* hard nofile 1048576
EOF

bar 3 5 "Limits"

########################################
# FAIL2BAN
########################################

cat >/etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 6h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
EOF

systemctl restart fail2ban >/dev/null 2>&1
bar 4 5 "Fail2Ban"

########################################
# DOCKER
########################################

if ! command -v docker >/dev/null; then
(
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
apt update -qq >/dev/null 2>&1
apt install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin >/dev/null 2>&1
systemctl enable docker >/dev/null
systemctl start docker >/dev/null
) & spin $! "Docker"
fi

bar 5 5 "Docker"

########################################
# SECRET KEY SAFE INPUT
########################################

echo
while true; do
  read -rsp "🔑 SECRET_KEY: " KEY1
  echo
  read -rsp "🔑 Подтверждение: " KEY2
  echo

  [[ -z "$KEY1" ]] && { warn "Пусто"; continue; }
  [[ "$KEY1" != "$KEY2" ]] && { warn "Не совпадает"; continue; }

  break
done

ok "Ключ принят"

mkdir -p "$DIR"

########################################
# DOCKER COMPOSE (FIX NETWORK ISSUE)
########################################

cat >"$COMPOSE" <<EOF
services:
  remnanode:
    image: remnawave/node:latest
    container_name: remnanode
    network_mode: host
    restart: unless-stopped
    environment:
      - SECRET_KEY=${KEY1}
      - NODE_PORT=3000
    cap_add:
      - NET_ADMIN
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
EOF

########################################
# START
########################################

(
docker compose down >/dev/null 2>&1 || true
docker compose pull -q >/dev/null 2>&1
docker compose up -d >/dev/null 2>&1
) & spin $! "Запуск ноды"

sleep 3

docker ps | grep -q remnanode || err "Контейнер не запустился"

ok "Нода работает"

########################################
# CLI PANEL
########################################

cat >/usr/local/bin/remnanode <<'EOF'
#!/usr/bin/env bash

menu(){
while true; do
clear
echo "🚀 REMNANODE ПАНЕЛЬ"
echo "1) Статус"
echo "2) Логи"
echo "3) Перезапуск"
echo "4) Стоп"
echo "5) Старт"
echo "6) Stats"
echo "7) LIVE Dashboard"
echo "0) Выход"

read -rp "→ " c

case $c in
1) docker ps | grep remnanode ;;
2) docker logs -f --tail 50 remnanode ;;
3) docker restart remnanode ;;
4) docker stop remnanode ;;
5) docker start remnanode ;;
6) docker stats remnanode ;;
7)
while true; do
clear
echo "=== LIVE ==="
echo "CPU/RAM:"
top -bn1 | head -5
echo
echo "CONN:"
ss -ntu | wc -l
echo
echo "TOP IP:"
ss -ntu | awk '{print $5}' | cut -d: -f1 | sort | uniq -c | sort -nr | head -5
sleep 2
done
;;
0) exit ;;
esac

read -rp "Enter..."
done
}

menu
EOF

chmod +x /usr/local/bin/remnanode

ok "CLI готов"

########################################
# FINISH
########################################

echo
echo -e "${GREEN}✔ УСТАНОВКА ЗАВЕРШЕНА${NC}"
echo "Запуск: remnanode"
echo "Порт: 3000"
