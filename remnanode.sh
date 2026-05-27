#!/usr/bin/env bash
set -Eeuo pipefail

APP="remnanode"
DIR="/opt/${APP}"
COMPOSE="${DIR}/docker-compose.yml"

GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok(){ echo -e "${GREEN}[✓]${NC} $1"; }
info(){ echo -e "${BLUE}[i]${NC} $1"; }
warn(){ echo -e "${YELLOW}[!]${NC} $1"; }
fail(){ echo -e "${RED}[x]${NC} $1"; exit 1; }

[[ $EUID -ne 0 ]] && fail "root required"

clear
echo "==== REMNANODE INSTALL ===="

########################################
# BASE PACKAGES (silent)
########################################

info "Установка пакетов..."

apt update -qq >/dev/null

apt install -y -qq \
curl wget git jq \
ca-certificates gnupg lsb-release \
fail2ban iptables iptables-persistent \
netfilter-persistent irqbalance >/dev/null

ok "Пакеты готовы"

########################################
# SYSCTL (safe performance only)
########################################

info "Настройка ядра..."

cat >/etc/sysctl.d/99-remnanode.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr

net.core.somaxconn=65535
net.core.netdev_max_backlog=262144
net.ipv4.tcp_max_syn_backlog=262144

net.ipv4.tcp_fastopen=3
net.ipv4.tcp_slow_start_after_idle=0

net.ipv4.tcp_mtu_probing=1

net.ipv4.ip_local_port_range=1024 65535

fs.file-max=2097152
EOF

sysctl --system >/dev/null
ok "Kernel OK"

########################################
# LIMITS
########################################

cat >/etc/security/limits.d/99-remnanode.conf <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
EOF

ok "Limits OK"

########################################
# FAIL2BAN (minimal stable)
########################################

cat >/etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime = 12h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
EOF

systemctl enable fail2ban >/dev/null
systemctl restart fail2ban >/dev/null

ok "Fail2Ban OK"

########################################
# DOCKER
########################################

if ! command -v docker >/dev/null; then
  info "Docker install..."

  mkdir -p /etc/apt/keyrings

  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | gpg --dearmor -o /etc/apt/keyrings/docker.gpg

  echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
  > /etc/apt/sources.list.d/docker.list

  apt update -qq >/dev/null
  apt install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin >/dev/null

  systemctl enable docker >/dev/null
  systemctl start docker >/dev/null
fi

ok "Docker ready"

########################################
# SECRET KEY SAFE INPUT
########################################

while true; do
  echo
  read -r -p "SECRET_KEY: " SECRET
  echo
  read -r -p "CONFIRM SECRET_KEY: " CONFIRM

  [[ -z "$SECRET" ]] && { warn "empty"; continue; }

  [[ "$SECRET" != "$CONFIRM" ]] && { warn "mismatch"; continue; }

  break
done

ok "KEY OK"

########################################
# DIR
########################################

mkdir -p "$DIR"
mkdir -p /var/log/remnanode

########################################
# DOCKER COMPOSE (FIXED - NO NETWORK BUG)
########################################

info "Compose..."

cat >"$COMPOSE" <<EOF
services:

  remnanode:

    image: remnawave/node:latest

    container_name: remnanode

    hostname: remnanode

    network_mode: host

    restart: unless-stopped

    stop_grace_period: 10s

    environment:
      - SECRET_KEY=${SECRET}
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

    volumes:
      - /var/log/remnanode:/var/log/remnanode
EOF

ok "Compose OK"

########################################
# START (quiet FIX)
########################################

info "Starting..."

cd "$DIR"

docker compose pull -q >/dev/null 2>&1
docker compose up -d >/dev/null 2>&1

sleep 3

if ! docker ps | grep -q remnanode; then
  docker logs remnanode --tail 50
  fail "FAILED"
fi

ok "RUNNING"

########################################
# CLI
########################################

cat >/usr/local/bin/remnanode <<'EOF'
#!/usr/bin/env bash

while true; do
  clear
  echo "===== REMNANODE ====="
  echo
  echo "1 Status"
  echo "2 Logs"
  echo "3 Restart"
  echo "4 Stop"
  echo "5 Start"
  echo "6 Stats"
  echo "0 Exit"
  echo

  read -r -p ">" c

  case $c in
    1) docker ps | grep remnanode ;;
    2) docker logs -f --tail 100 remnanode ;;
    3) docker restart remnanode ;;
    4) docker stop remnanode ;;
    5) docker start remnanode ;;
    6) docker stats remnanode ;;
    0) exit ;;
  esac

  echo
  read -r -p "enter..."
done
EOF

chmod +x /usr/local/bin/remnanode

ok "CLI ready"

########################################
# FINAL
########################################

echo
echo "========================"
ok "INSTALL COMPLETE"
echo "========================"
echo "run: remnanode"
echo "port: 3000"
echo "========================"
