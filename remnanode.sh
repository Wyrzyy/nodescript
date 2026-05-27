#!/usr/bin/env bash
set -Eeuo pipefail

APP="remnanode"
DIR="/opt/${APP}"
COMPOSE="${DIR}/docker-compose.yml"

export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none

# ===== UI =====
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok(){ echo -e "${GREEN}✔ $1${NC}"; }
info(){ echo -e "${BLUE}ℹ $1${NC}"; }
warn(){ echo -e "${YELLOW}⚠ $1${NC}"; }
fail(){ echo -e "${RED}✖ $1${NC}"; exit 1; }

spin() {
  local pid=$1 msg=$2
  local c='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  while kill -0 $pid 2>/dev/null; do
    for ((i=0; i<${#c}; i++)); do
      printf "\r%s %s" "$msg" "${c:$i:1}"
      sleep 0.08
    done
  done
  printf "\r%s ✔\n" "$msg"
}

bar() {
  local cur=$1 total=$2 msg=$3
  local p=$((cur*100/total))
  local fill=$((p/10))

  printf "\r[%d/%d] %-25s [" "$cur" "$total" "$msg"
  for i in $(seq 1 10); do
    [[ $i -le $fill ]] && printf "█" || printf "-"
  done
  printf "] %d%%" "$p"
  [[ $cur -eq $total ]] && echo
}

[[ $EUID -ne 0 ]] && fail "Запусти от root"

clear
echo -e "${BLUE}===================================="
echo -e "        🚀 REMNANODE INSTALL"
echo -e "====================================${NC}"

########################################
# SYSTEM INFO
########################################

RAM=$(free -m | awk '/Mem:/ {print $2}')
CPU=$(nproc)

info "RAM: ${RAM} MB | CPU: ${CPU}"

########################################
# PACKAGES
########################################

(
apt update -qq >/dev/null 2>&1
apt install -y -qq curl wget git jq fail2ban iptables iptables-persistent netfilter-persistent irqbalance >/dev/null 2>&1
) & spin $! "📦 Установка пакетов"

bar 1 5 "Пакеты"

########################################
# SYSCTL SAFE
########################################

cat >/etc/sysctl.d/99-remnanode.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.somaxconn=65535
net.core.netdev_max_backlog=262144
net.ipv4.tcp_max_syn_backlog=262144
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_mtu_probing=1
net.ipv4.ip_local_port_range=1024 65535
fs.file-max=2097152
EOF

(sysctl --system >/dev/null 2>&1) & spin $! "⚙️ Настройка ядра"
bar 2 5 "Ядро"

########################################
# LIMITS
########################################

cat >/etc/security/limits.d/99-remnanode.conf <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
EOF

bar 3 5 "Лимиты"

########################################
# FAIL2BAN
########################################

cat >/etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime = 12h
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
) & spin $! "🐳 Docker"
fi

bar 5 5 "Docker"

########################################
# SECRET KEY SAFE
########################################

echo
while true; do
  read -r -p "🔑 Введите SECRET_KEY: " KEY
  read -r -p "🔑 Подтвердите: " KEY2

  [[ -z "$KEY" ]] && { warn "Пусто"; continue; }
  [[ "$KEY" != "$KEY2" ]] && { warn "Не совпадает"; continue; }

  break
done

ok "Ключ принят"

mkdir -p "$DIR"

########################################
# COMPOSE FIXED (NO DOCKER BUG)
########################################

cat >"$COMPOSE" <<EOF
services:
  remnanode:
    image: remnawave/node:latest
    container_name: remnanode
    network_mode: host
    restart: unless-stopped

    stop_grace_period: 10s

    environment:
      - SECRET_KEY=${KEY}
      - NODE_PORT=3000

    cap_add:
      - NET_ADMIN

    security_opt:
      - no-new-privileges:true

    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
EOF

ok "Docker конфиг создан"

########################################
# START (silent)
########################################

(
docker compose pull -q >/dev/null 2>&1
docker compose up -d >/dev/null 2>&1
) & spin $! "🚀 Запуск ноды"

sleep 3

docker ps | grep -q remnanode || fail "Не запустилась"

ok "Нода активна"

########################################
# CLI + LIVE DASHBOARD
########################################

cat >/usr/local/bin/remnanode <<'EOF'
#!/usr/bin/env bash

GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

dashboard() {
  while true; do
    clear

    echo -e "${BLUE}========== LIVE DASHBOARD ==========${NC}"

    CPU=$(top -bn1 | awk '/Cpu/ {print $2+$4}')
    MEM=$(free | awk '/Mem/ {printf "%.0f", $3/$2 * 100}')

    CONN=$(ss -ntu | wc -l)
    IPTOP=$(ss -ntu | awk '{print $5}' | cut -d: -f1 | sort | uniq -c | sort -nr | head -5)

    echo "CPU Load: ${CPU}%"
    echo "RAM Load: ${MEM}%"
    echo "Connections: ${CONN}"
    echo
    echo "TOP IPs:"
    echo "$IPTOP"

    echo -e "${BLUE}====================================${NC}"
    echo "CTRL+C — назад"
    sleep 2
  done
}

menu() {
  while true; do
    clear
    echo "🚀 REMNANODE PANEL"
    echo "-------------------"
    echo "1 📊 Статус"
    echo "2 📜 Логи"
    echo "3 🔄 Перезапуск"
    echo "4 ⛔ Стоп"
    echo "5 ▶️ Старт"
    echo "6 📈 Stats"
    echo "7 🧠 LIVE Dashboard"
    echo "0 ❌ Выход"
    echo

    read -r -p "Выбор: " c

    case $c in
      1) docker ps | grep remnanode ;;
      2) docker logs -f --tail 100 remnanode ;;
      3) docker restart remnanode ;;
      4) docker stop remnanode ;;
      5) docker start remnanode ;;
      6) docker stats remnanode ;;
      7) dashboard ;;
      0) exit ;;
    esac

    read -r -p "Enter..."
  done
}

menu
EOF

chmod +x /usr/local/bin/remnanode

ok "CLI установлен"

########################################
# FINAL
########################################

echo
echo -e "${GREEN}====================================${NC}"
echo -e "${GREEN}     УСТАНОВКА ЗАВЕРШЕНА 🚀${NC}"
echo -e "${GREEN}====================================${NC}"
echo
echo "Команда: remnanode"
echo "Порт: 3000"
echo
echo "LIVE dashboard показывает:"
echo " - CPU / RAM"
echo " - активные подключения"
echo " - TOP IP (анализ нагрузки / DDoS)"
echo
echo "===================================="
