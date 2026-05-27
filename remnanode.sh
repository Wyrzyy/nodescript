#!/usr/bin/env bash
set -Eeuo pipefail

########################################
# НАСТРОЙКИ
########################################

APP="remnanode"
INSTALL_DIR="/opt/${APP}"
COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"

########################################
# ЦВЕТА
########################################

GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok(){ echo -e "${GREEN}[✓]${NC} $1"; }
info(){ echo -e "${BLUE}[i]${NC} $1"; }
warn(){ echo -e "${YELLOW}[!]${NC} $1"; }
fail(){ echo -e "${RED}[x]${NC} $1"; exit 1; }

########################################
# ROOT
########################################

[[ $EUID -ne 0 ]] && fail "Запустите скрипт от root"

export DEBIAN_FRONTEND=noninteractive

clear

echo "=================================================="
echo "            REMNANODE INSTALLER"
echo "=================================================="
echo

########################################
# ПРОВЕРКА ОС
########################################

if ! grep -qiE 'ubuntu|debian' /etc/os-release; then
    fail "Поддерживается только Ubuntu/Debian"
fi

########################################
# ИНФОРМАЦИЯ О СЕРВЕРЕ
########################################

RAM=$(free -m | awk '/Mem:/ {print $2}')
CPU=$(nproc)

info "RAM: ${RAM} MB"
info "CPU: ${CPU} cores"

if (( RAM < 1800 )); then
    warn "Рекомендуется минимум 2GB RAM"
fi

########################################
# ПАКЕТЫ
########################################

info "Установка пакетов..."

apt update -qq

apt install -y -qq \
curl \
wget \
git \
jq \
sudo \
ca-certificates \
gnupg \
lsb-release \
apt-transport-https \
software-properties-common \
fail2ban \
iptables \
iptables-persistent \
netfilter-persistent \
irqbalance \
unzip >/dev/null

ok "Пакеты установлены"

########################################
# IPTABLES BACKEND
########################################

info "Настройка iptables backend..."

update-alternatives --set iptables /usr/sbin/iptables-nft >/dev/null
update-alternatives --set ip6tables /usr/sbin/ip6tables-nft >/dev/null

ok "iptables-nft включен"

########################################
# SYSCTL
########################################

info "Оптимизация ядра..."

cat >/etc/sysctl.d/99-remnanode.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr

net.core.somaxconn=65535
net.core.netdev_max_backlog=262144

net.ipv4.tcp_max_syn_backlog=262144

net.ipv4.ip_local_port_range=1024 65535

net.ipv4.tcp_fastopen=3
net.ipv4.tcp_slow_start_after_idle=0

net.ipv4.tcp_fin_timeout=15

net.ipv4.tcp_keepalive_time=600
net.ipv4.tcp_keepalive_intvl=30
net.ipv4.tcp_keepalive_probes=5

net.ipv4.tcp_mtu_probing=1

net.ipv4.ip_forward=1

net.ipv4.tcp_rmem=4096 87380 67108864
net.ipv4.tcp_wmem=4096 65536 67108864

net.core.rmem_max=67108864
net.core.wmem_max=67108864

net.netfilter.nf_conntrack_max=1048576

net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0

net.ipv4.conf.all.secure_redirects=0
net.ipv4.conf.default.secure_redirects=0

net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.default.send_redirects=0

net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.default.rp_filter=1

net.ipv4.icmp_echo_ignore_broadcasts=1
net.ipv4.icmp_ignore_bogus_error_responses=1

fs.file-max=2097152

vm.swappiness=10

fs.inotify.max_user_instances=8192
fs.inotify.max_user_watches=524288
EOF

sysctl --system >/dev/null

ok "Ядро оптимизировано"

########################################
# LIMITS
########################################

info "Настройка лимитов..."

cat >/etc/security/limits.d/99-remnanode.conf <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF

mkdir -p /etc/systemd/system.conf.d

cat >/etc/systemd/system.conf.d/99-remnanode.conf <<'EOF'
[Manager]
DefaultLimitNOFILE=1048576
EOF

systemctl daemon-reexec

ok "Лимиты настроены"

########################################
# JOURNALD
########################################

info "Оптимизация логов..."

mkdir -p /etc/systemd/journald.conf.d

cat >/etc/systemd/journald.conf.d/remnanode.conf <<'EOF'
[Journal]
SystemMaxUse=200M
RuntimeMaxUse=100M
RateLimitIntervalSec=30s
RateLimitBurst=200
Compress=yes
EOF

systemctl restart systemd-journald

ok "Journald оптимизирован"

########################################
# SSH HARDENING
########################################

info "Усиление SSH..."

sed -i 's/^#*MaxAuthTries.*/MaxAuthTries 3/' /etc/ssh/sshd_config
sed -i 's/^#*LoginGraceTime.*/LoginGraceTime 20/' /etc/ssh/sshd_config

systemctl restart ssh || true

ok "SSH усилен"

########################################
# DOCKER
########################################

if ! command -v docker >/dev/null; then

info "Установка Docker..."

mkdir -p /etc/apt/keyrings

curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
| gpg --dearmor -o /etc/apt/keyrings/docker.gpg

echo \
"deb [arch=$(dpkg --print-architecture) \
signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu \
$(lsb_release -cs) stable" \
>/etc/apt/sources.list.d/docker.list

apt update -qq

apt install -y -qq \
docker-ce \
docker-ce-cli \
containerd.io \
docker-compose-plugin >/dev/null

fi

mkdir -p /etc/docker

cat >/etc/docker/daemon.json <<'EOF'
{
  "live-restore": true,
  "iptables": true,
  "userland-proxy": false,
  "storage-driver": "overlay2",
  "log-driver": "json-file",
  "shutdown-timeout": 15,
  "log-opts": {
    "max-size": "10m",
    "max-file": "3",
    "compress": "true"
  }
}
EOF

systemctl enable docker >/dev/null
systemctl restart docker

ok "Docker настроен"

########################################
# FIREWALL
########################################

info "Настройка firewall..."

iptables -F
iptables -X

iptables -P INPUT DROP
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT

iptables -A INPUT -i lo -j ACCEPT

iptables -A INPUT \
-m conntrack \
--ctstate ESTABLISHED,RELATED \
-j ACCEPT

iptables -A INPUT \
-m conntrack \
--ctstate INVALID \
-j DROP

iptables -A INPUT \
-p tcp \
--dport 22 \
-m connlimit \
--connlimit-above 10 \
-j DROP

iptables -A INPUT \
-p tcp \
--dport 22 \
-j ACCEPT

iptables -A INPUT \
-p tcp \
-m multiport \
--dports 80,443,3000 \
-j ACCEPT

iptables -A INPUT \
-p udp \
--dport 443 \
-j ACCEPT

iptables -A INPUT \
-p icmp \
-j ACCEPT

iptables-save >/etc/iptables/rules.v4

systemctl enable netfilter-persistent >/dev/null
systemctl restart netfilter-persistent

ok "Firewall настроен"

########################################
# FAIL2BAN
########################################

info "Настройка Fail2Ban..."

cat >/etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime = 24h
findtime = 10m
maxretry = 5
backend = systemd
banaction = iptables-multiport

[sshd]
enabled = true
EOF

systemctl enable fail2ban >/dev/null
systemctl restart fail2ban

ok "Fail2Ban настроен"

########################################
# IRQBALANCE
########################################

if (( CPU >= 4 )); then
    systemctl enable irqbalance --now >/dev/null
    ok "irqbalance включен"
fi

########################################
# ДИРЕКТОРИИ
########################################

mkdir -p "${INSTALL_DIR}"
mkdir -p /var/log/remnanode

########################################
# SECRET KEY
########################################

while true; do

echo
read -rp "Введите SECRET_KEY: " SECRET_KEY

echo
read -rp "Подтвердите SECRET_KEY: " SECRET_KEY_CONFIRM

[[ -z "${SECRET_KEY}" ]] && {
    warn "SECRET_KEY не может быть пустым"
    continue
}

[[ "${SECRET_KEY}" != "${SECRET_KEY_CONFIRM}" ]] && {
    warn "SECRET_KEY не совпадает"
    continue
}

break

done

ok "SECRET_KEY подтвержден"

########################################
# ПРОВЕРКА ПОРТОВ
########################################

if ss -tulpn | grep -q ':443 '; then
    fail "Порт 443 уже занят"
fi

########################################
# DOCKER COMPOSE
########################################

info "Создание docker compose..."

cat >"${COMPOSE_FILE}" <<EOF
services:

  remnanode:

    image: remnawave/node:latest

    container_name: remnanode

    hostname: remnanode

    restart: unless-stopped

    stop_grace_period: 15s

    ports:
      - "443:443/tcp"
      - "443:443/udp"
      - "3000:3000/tcp"

    cap_add:
      - NET_ADMIN

    security_opt:
      - no-new-privileges:true

    pids_limit: 512

    mem_limit: 2g

    cpus: 2.0

    environment:
      - SECRET_KEY=${SECRET_KEY}
      - NODE_PORT=3000

    healthcheck:
      test: ["CMD", "curl", "-f", "http://127.0.0.1:3000/health"]
      interval: 30s
      timeout: 5s
      retries: 3

    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
        compress: "true"

    volumes:
      - /var/log/remnanode:/var/log/remnanode
EOF

ok "Compose создан"

########################################
# ЗАПУСК
########################################

info "Запуск контейнера..."

cd "${INSTALL_DIR}"

docker network prune -f >/dev/null 2>&1 || true

docker compose pull >/dev/null

docker compose up -d >/dev/null

sleep 5

if ! docker ps | grep -q remnanode; then
    docker logs remnanode --tail 50
    fail "Контейнер не запустился"
fi

ok "Контейнер успешно запущен"

########################################
# AUTO CLEANUP
########################################

info "Настройка автоочистки Docker..."

cat >/etc/cron.daily/docker-cleanup <<'EOF'
#!/usr/bin/env bash
docker system prune -af >/dev/null 2>&1
EOF

chmod +x /etc/cron.daily/docker-cleanup

ok "Автоочистка настроена"

########################################
# LOGROTATE
########################################

cat >/etc/logrotate.d/remnanode <<'EOF'
/var/log/remnanode/*.log {
    daily
    rotate 7
    compress
    missingok
    notifempty
    copytruncate
}
EOF

########################################
# CLI
########################################

info "Установка CLI..."

cat >/usr/local/bin/remnanode <<'EOF'
#!/usr/bin/env bash

while true; do

clear

STATUS=$(docker inspect -f '{{.State.Status}}' remnanode 2>/dev/null || echo "not_found")

echo "======================================="
echo "             REMNANODE"
echo "======================================="
echo
echo "Статус: ${STATUS}"
echo
echo "1) Статус контейнера"
echo "2) Логи"
echo "3) Перезапуск"
echo "4) Остановить"
echo "5) Запустить"
echo "6) Docker Stats"
echo "7) Firewall"
echo "8) Fail2Ban"
echo "9) Обновить контейнер"
echo "10) Переустановить"
echo "11) Healthcheck"
echo "0) Выход"
echo

read -rp "Выберите пункт: " opt

case $opt in

1)
docker ps --filter name=remnanode
;;

2)
docker logs -f --tail 100 remnanode
;;

3)
docker restart remnanode
;;

4)
docker stop remnanode
;;

5)
docker start remnanode
;;

6)
docker stats remnanode
;;

7)
iptables -L -n -v
;;

8)
fail2ban-client status
;;

9)
cd /opt/remnanode
docker compose pull
docker compose up -d
;;

10)
bash /opt/remnanode/install.sh
;;

11)
docker inspect \
--format='{{json .State.Health}}' \
remnanode | jq
;;

0)
exit 0
;;

*)
echo "Неверный пункт"
;;

esac

echo
read -rp "Нажмите Enter..."
done
EOF

chmod +x /usr/local/bin/remnanode

ok "CLI установлен"

########################################
# СОХРАНЕНИЕ INSTALLER
########################################

cp "$0" /opt/remnanode/install.sh 2>/dev/null || true

########################################
# ФИНАЛ
########################################

clear

echo "=================================================="
echo "             УСТАНОВКА ЗАВЕРШЕНА"
echo "=================================================="
echo
echo "Установлено:"
echo
echo "✓ Docker"
echo "✓ Remnanode"
echo "✓ BBR"
echo "✓ Firewall"
echo "✓ Fail2Ban"
echo "✓ Docker hardening"
echo "✓ Auto cleanup"
echo "✓ Healthcheck"
echo "✓ CLI manager"
echo
echo "Команда управления:"
echo
echo "remnanode"
echo
echo "Порты:"
echo
echo "443/tcp"
echo "443/udp"
echo "3000/tcp"
echo
echo "=================================================="
