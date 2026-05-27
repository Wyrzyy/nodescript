#!/usr/bin/env bash
set -Eeuo pipefail

APP="remnanode"
INSTALL_DIR="/opt/${APP}"

GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok(){ echo -e "${GREEN}[✓]${NC} $1"; }
info(){ echo -e "${BLUE}[i]${NC} $1"; }
warn(){ echo -e "${YELLOW}[!]${NC} $1"; }
fail(){ echo -e "${RED}[x]${NC} $1"; exit 1; }

[[ $EUID -ne 0 ]] && fail "Run as root"

export DEBIAN_FRONTEND=noninteractive

clear

echo "========================================="
echo "      REMNANODE INSTALLER"
echo "========================================="

sleep 1

############################################
# PACKAGES
############################################

info "Installing packages..."

apt update -qq

apt install -y -qq \
curl \
wget \
git \
jq \
nftables \
fail2ban \
ca-certificates \
gnupg \
lsb-release \
apt-transport-https \
software-properties-common \
irqbalance >/dev/null

ok "Packages installed"

############################################
# SYSCTL
############################################

info "Applying kernel optimization..."

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

net.netfilter.nf_conntrack_max=1048576

fs.file-max=2097152

fs.inotify.max_user_instances=8192
fs.inotify.max_user_watches=524288
EOF

sysctl --system >/dev/null

ok "Kernel optimized"

############################################
# LIMITS
############################################

info "Applying limits..."

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

ok "Limits applied"

############################################
# JOURNALD
############################################

info "Optimizing journald..."

mkdir -p /etc/systemd/journald.conf.d

cat >/etc/systemd/journald.conf.d/remnanode.conf <<'EOF'
[Journal]
SystemMaxUse=200M
RuntimeMaxUse=100M
RateLimitIntervalSec=30s
RateLimitBurst=200
EOF

systemctl restart systemd-journald

ok "Journald optimized"

############################################
# DOCKER
############################################

if ! command -v docker >/dev/null; then

info "Installing Docker..."

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
  "userland-proxy": false,
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF

systemctl enable docker >/dev/null
systemctl restart docker

ok "Docker configured"

############################################
# NFTABLES
############################################

info "Configuring firewall..."

cat >/etc/nftables.conf <<'EOF'
#!/usr/sbin/nft -f

flush ruleset

table inet filter {

    chain input {

        type filter hook input priority 0;

        policy drop;

        iif lo accept

        ct state established,related accept
        ct state invalid drop

        tcp dport 22 ct state new limit rate 15/minute accept

        tcp dport {80,443,3000} accept
        udp dport 443 accept

        ip protocol icmp accept
        ip6 nexthdr ipv6-icmp accept

        limit rate 5/second accept
    }

    chain forward {
        type filter hook forward priority 0;
        policy drop;
    }

    chain output {
        type filter hook output priority 0;
        policy accept;
    }
}
EOF

systemctl enable nftables >/dev/null
systemctl restart nftables

ok "Firewall configured"

############################################
# FAIL2BAN
############################################

info "Configuring Fail2Ban..."

cat >/etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime = 24h
findtime = 10m
maxretry = 5
backend = systemd
banaction = nftables-multiport

[sshd]
enabled = true
EOF

systemctl enable fail2ban >/dev/null
systemctl restart fail2ban

ok "Fail2Ban configured"

############################################
# IRQBALANCE
############################################

CPU_CORES=$(nproc)

if (( CPU_CORES >= 4 )); then
    systemctl enable irqbalance --now >/dev/null
    ok "irqbalance enabled"
fi

############################################
# INSTALL DIRECTORY
############################################

mkdir -p "${INSTALL_DIR}"

############################################
# SECRET KEY
############################################

echo
read -rp "SECRET_KEY: " SECRET_KEY

[[ -z "${SECRET_KEY}" ]] && fail "SECRET_KEY required"

############################################
# DOCKER COMPOSE
############################################

info "Creating compose..."

cat >"${INSTALL_DIR}/docker-compose.yml" <<EOF
services:

  remnanode:

    image: remnawave/node:latest

    container_name: remnanode

    restart: unless-stopped

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

    volumes:
      - /var/log/remnanode:/var/log/remnanode
EOF

############################################
# START
############################################

info "Starting container..."

cd "${INSTALL_DIR}"

docker compose pull >/dev/null
docker compose up -d >/dev/null

ok "Container started"

############################################
# REMNANODE CLI
############################################

info "Installing CLI..."

cat >/usr/local/bin/remnanode <<'EOF'
#!/usr/bin/env bash

set -e

while true; do

clear

echo "================================="
echo "         REMNANODE"
echo "================================="
echo
echo "1) Status"
echo "2) Logs"
echo "3) Restart"
echo "4) Stop"
echo "5) Start"
echo "6) Docker Stats"
echo "7) Firewall"
echo "8) Fail2Ban"
echo "9) Update"
echo "10) Reinstall"
echo "0) Exit"
echo

read -rp "Select: " opt

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
nft list ruleset
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

0)
exit 0
;;

*)
echo "Invalid option"
;;

esac

echo
read -rp "Press Enter..."
done
EOF

chmod +x /usr/local/bin/remnanode

ok "CLI installed"

############################################
# SAVE INSTALLER
############################################

cp "$0" /opt/remnanode/install.sh 2>/dev/null || true

############################################
# DONE
############################################

echo
echo "========================================="
echo "         INSTALL COMPLETE"
echo "========================================="
echo
echo "Command:"
echo
echo "   remnanode"
echo
echo "Ports:"
echo
echo "   443/tcp"
echo "   443/udp"
echo "   3000/tcp"
echo
