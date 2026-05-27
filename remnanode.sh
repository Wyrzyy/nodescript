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
      sleep 0.06
    done
  done
  printf "\r%s ✔\n" "$msg"
}

run_step(){
  local msg="$1"
  local cmd="$2"

  echo
  echo -e "${BLUE}➡ $msg${NC}"

  (
    eval "$cmd" >/dev/null 2>&1
  ) &

  spin $! "$msg"
}

[[ $EUID -ne 0 ]] && err "Запусти от root"

clear
echo -e "${BLUE}===================================="
echo -e "        🚀 REMNANODE INSTALL"
echo -e "====================================${NC}"

########################################
# SYSTEM INFO
########################################

CPU=$(nproc)
RAM_MB=$(free -m | awk '/Mem:/ {print $2}')

info "CPU: $CPU | RAM: ${RAM_MB}MB"

########################################
# CPU MODE (ВАЖНО)
########################################

if (( CPU <= 1 )); then
  MODE="LOW"
  BACKLOG=1024
elif (( CPU <= 2 )); then
  MODE="MID"
  BACKLOG=8192
else
  MODE="HIGH"
  BACKLOG=65535
fi

info "Режим сервера: $MODE"

########################################
# SWAP + ZRAM
########################################

setup_memory() {
  if (( RAM_MB <= 4096 )); then

    if [[ ! -f /swapfile ]]; then
      local size=$(( RAM_MB <= 2048 ? 2 : 1 ))
      run_step "Создание swap ${size}G" "fallocate -l ${size}G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile && echo '/swapfile none swap sw 0 0' >> /etc/fstab"
    fi

    if (( RAM_MB <= 2048 )); then
      run_step "Активация ZRAM" "modprobe zram 2>/dev/null || true"
    fi

  else
    info "Swap не требуется"
  fi
}

setup_memory

########################################
# PACKAGES
########################################

run_step "Установка пакетов" \
"apt update -qq && apt install -y -qq curl wget git jq fail2ban iptables irqbalance"

########################################
# SYSCTL (FIXED + CPU ADAPTIVE)
########################################

run_step "Настройка ядра" "bash -c '
cat >/etc/sysctl.d/99-remnanode.conf <<EOF
net.core.somaxconn=$BACKLOG
net.core.netdev_max_backlog=$BACKLOG
net.ipv4.tcp_max_syn_backlog=$BACKLOG
net.ipv4.tcp_congestion_control=bbr
net.core.default_qdisc=fq
net.ipv4.tcp_fastopen=3
net.ipv4.ip_local_port_range=1024 65535
fs.file-max=2097152
EOF
sysctl --system >/dev/null
'"

########################################
# LIMITS
########################################

run_step "Ограничения системы" \
"bash -c 'echo \"* soft nofile 1048576
* hard nofile 1048576\" > /etc/security/limits.d/99-remnanode.conf'"

########################################
# FAIL2BAN
########################################

run_step "Fail2Ban" \
"bash -c 'cat >/etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 6h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
EOF
systemctl restart fail2ban >/dev/null 2>&1'"

########################################
# DOCKER (FIX NETWORK BUG)
########################################

if ! command -v docker >/dev/null; then
run_step "Docker установка" \
"curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker.gpg &&
echo \"deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable\" > /etc/apt/sources.list.d/docker.list &&
apt update -qq && apt install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin &&
systemctl enable docker && systemctl start docker"
fi

########################################
# SECRET KEY SAFE INPUT
########################################

echo
while true; do
  read -rsp "🔑 SECRET_KEY: " K1; echo
  read -rsp "🔑 Повтор: " K2; echo

  [[ -z "$K1" ]] && { warn "Пусто"; continue; }
  [[ "$K1" != "$K2" ]] && { warn "Не совпадает"; continue; }
  break
done

ok "Ключ принят"

mkdir -p "$DIR"

########################################
# DOCKER COMPOSE FIX
########################################

cat >"$COMPOSE" <<EOF
services:
  remnanode:
    image: remnawave/node:latest
    container_name: remnanode
    network_mode: host
    restart: unless-stopped

    environment:
      - SECRET_KEY=${K1}
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

run_step "Запуск контейнера" \
"docker compose down >/dev/null 2>&1 || true && docker compose pull -q && docker compose up -d"

sleep 2

docker ps | grep -q remnanode || err "Контейнер не запущен"

ok "Нода работает"

########################################
# CLI PANEL
########################################

cat >/usr/local/bin/remnanode <<'EOF'
#!/usr/bin/env bash

menu(){
while true; do
clear
echo "🚀 REMNANODE PANEL"
echo "1) Статус"
echo "2) Логи"
echo "3) Перезапуск"
echo "4) Стоп"
echo "5) Старт"
echo "6) Stats"
echo "7) LIVE"
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

########################################
# DONE
########################################

echo
echo -e "${GREEN}===================================="
echo -e "✔ УСТАНОВКА ЗАВЕРШЕНА"
echo -e "====================================${NC}"
echo "Команда: remnanode"
