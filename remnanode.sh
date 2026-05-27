#!/bin/bash
set -euo pipefail

# Цвета
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
ok() { echo -e "${GREEN}[✓]${NC} $1"; }
info() { echo -e "${BLUE}[i]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err() { echo -e "${RED}[✗]${NC} $1"; exit 1; }

[[ $EUID -ne 0 ]] && err "Запустите с root."

# ==========================================
# Функция удаления старой ноды
# ==========================================
check_and_remove_existing() {
    local exists=0
    docker ps -a --format '{{.Names}}' | grep -q "^remnanode$" && exists=1
    [[ -d "/opt/remnanode" ]] && exists=1
    if [[ $exists -eq 1 ]]; then
        echo -n -e "${YELLOW}[?] Удалить старую ноду и установить заново? (y/N): ${NC}"
        read -r answer
        if [[ "$answer" =~ ^[Yy]$ ]]; then
            docker stop remnanode 2>/dev/null || true
            docker rm remnanode 2>/dev/null || true
            rm -rf /opt/remnanode
            ok "Старая установка удалена."
        else
            info "Установка отменена."
            exit 0
        fi
    fi
}

# ==========================================
# 1. Базовые пакеты
# ==========================================
info "Обновление системы и установка пакетов..."
apt update -y
pkgs=(curl wget git ufw fail2ban software-properties-common gnupg lsb-release ca-certificates haveged irqbalance)
for pkg in "${pkgs[@]}"; do
    if ! dpkg -l | grep -qw "$pkg"; then
        apt install -y "$pkg"
        ok "Установлен $pkg"
    else
        info "$pkg уже установлен"
    fi
done

# ==========================================
# 2. Sysctl (только если изменился)
# ==========================================
SYSCTL_CONF="/etc/sysctl.d/99-remnawave.conf"
NEW_MD5=$(cat <<'EOF' | md5sum | cut -d' ' -f1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
net.ipv4.tcp_mem = 786432 1048576 1572864
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_abort_on_overflow = 0
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_fack = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.icmp_echo_ignore_all = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
fs.file-max = 2097152
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches = 524288
EOF
)
if [[ ! -f "$SYSCTL_CONF" ]] || [[ "$(md5sum "$SYSCTL_CONF" | cut -d' ' -f1)" != "$NEW_MD5" ]]; then
    cat > "$SYSCTL_CONF" <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
net.ipv4.tcp_mem = 786432 1048576 1572864
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_abort_on_overflow = 0
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_fack = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.icmp_echo_ignore_all = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
fs.file-max = 2097152
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches = 524288
EOF
    sysctl -p "$SYSCTL_CONF"
    ok "Параметры ядра обновлены."
else
    info "Параметры ядра уже актуальны."
fi

# ==========================================
# 3. Ulimits
# ==========================================
LIMITS_CONF="/etc/security/limits.d/99-remnawave.conf"
if ! grep -q "soft nofile 1048576" "$LIMITS_CONF" 2>/dev/null; then
    cat > "$LIMITS_CONF" <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
* soft nproc unlimited
* hard nproc unlimited
root soft nofile 1048576
root hard nofile 1048576
EOF
    ok "Ulimits настроены."
else
    info "Ulimits уже настроены."
fi

SYSTEMD_LIMITS="/etc/systemd/system.conf.d/99-limits.conf"
if ! grep -q "DefaultLimitNOFILE" "$SYSTEMD_LIMITS" 2>/dev/null; then
    mkdir -p /etc/systemd/system.conf.d/
    cat > "$SYSTEMD_LIMITS" <<'EOF'
[Manager]
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=infinity
EOF
    systemctl daemon-reload
    ok "Systemd limits настроены."
else
    info "Systemd limits уже настроены."
fi

# ==========================================
# 4. Docker
# ==========================================
if ! command -v docker &> /dev/null; then
    info "Установка Docker..."
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt update -y
    apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    systemctl enable docker
    systemctl start docker
    ok "Docker установлен."
else
    ok "Docker уже установлен."
fi

# ==========================================
# 5. UFW (полностью идемпотентно, без интерактива)
# ==========================================
info "Настройка UFW..."
# Сброс только если UFW не активен или правила не те
if ! ufw status | grep -q "Status: active"; then
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    ufw default deny forward
    ufw allow 22/tcp comment 'SSH'
    ufw allow 80/tcp comment 'HTTP'
    ufw allow 443/tcp comment 'HTTPS/VLESS'
    ufw allow 3000/tcp comment 'Remnawave API'
    # Сохраняем оригинальный before.rules
    cp /usr/share/ufw/before.rules /etc/ufw/before.rules.orig
    cp /etc/ufw/before.rules.orig /etc/ufw/before.rules
fi

# Добавляем анти-DDoS правила, если их нет
if ! grep -q "# === Remnawave Anti-DDoS Rules ===" /etc/ufw/before.rules; then
    # Удалим возможные старые вставки (по ключевому слову)
    sed -i '/# === Remnawave Anti-DDoS Rules ===/,/# FINISH/d' /etc/ufw/before.rules
    cat >> /etc/ufw/before.rules <<'EOF'

# === Remnawave Anti-DDoS Rules ===
-A ufw-before-input -p tcp --syn -m limit --limit 3/s --limit-burst 10 -j ACCEPT
-A ufw-before-input -p tcp --syn -j DROP
-A ufw-before-input -m state --state INVALID -j DROP
-A ufw-before-input -p tcp --dport 443 -m connlimit --connlimit-above 30 --connlimit-mask 32 -j DROP
-A ufw-before-input -p tcp --tcp-flags ALL NONE -j DROP
-A ufw-before-input -p tcp --tcp-flags ALL ALL -j DROP
-A ufw-before-input -p tcp --dport 443 -m limit --limit 50/s --limit-burst 100 -j ACCEPT
-A ufw-before-input -p tcp --dport 443 -j DROP
EOF
    ok "Анти-DDoS правила добавлены в before.rules."
else
    info "Анти-DDoS правила уже присутствуют."
fi

# Принудительно включаем/перезагружаем UFW без вопросов
ufw --force enable
ufw reload
ok "UFW активен и правила загружены."

# ==========================================
# 6. Fail2Ban
# ==========================================
if ! systemctl is-active --quiet fail2ban; then
    apt install -y fail2ban
    cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime = 1h
findtime = 60
maxretry = 20
banaction = ufw
ignoreip = 127.0.0.1/8

[sshd]
enabled = true
port = 22
maxretry = 5
bantime = 1h
EOF
    systemctl restart fail2ban
    systemctl enable fail2ban
    ok "Fail2Ban настроен."
else
    info "Fail2Ban уже запущен."
fi

# ==========================================
# 7. Удаление старой ноды (по желанию)
# ==========================================
check_and_remove_existing

# ==========================================
# 8. Установка Remnawave Node
# ==========================================
info "Установка Remnawave Node..."
INSTALL_DIR="/opt/remnanode"
mkdir -p "$INSTALL_DIR"

# Определяем SECRET_KEY
if [[ -f "$INSTALL_DIR/docker-compose.yml" ]]; then
    OLD_KEY=$(grep "SECRET_KEY=" "$INSTALL_DIR/docker-compose.yml" | cut -d'=' -f2 | tr -d ' ' | head -1)
    if [[ -n "$OLD_KEY" ]]; then
        SECRET_KEY="$OLD_KEY"
        info "Используем существующий SECRET_KEY."
    else
        echo -n -e "${YELLOW}[?] Введите SECRET_KEY: ${NC}"
        read -r SECRET_KEY
    fi
else
    echo -n -e "${YELLOW}[?] Введите SECRET_KEY: ${NC}"
    read -r SECRET_KEY
fi
[[ -z "$SECRET_KEY" ]] && err "SECRET_KEY не может быть пустым."

cat > "$INSTALL_DIR/docker-compose.yml" <<EOF
services:
  remnanode:
    container_name: remnanode
    hostname: remnanode
    image: remnawave/node:latest
    network_mode: host
    restart: always
    cap_add:
      - NET_ADMIN
    environment:
      - NODE_PORT=3000
      - SECRET_KEY=${SECRET_KEY}
    logging:
      driver: "json-file"
      options:
        max-size: "50m"
        max-file: "5"
        compress: "true"
    volumes:
      - '/var/log/remnanode:/var/log/remnanode'
      - '/etc/timezone:/etc/timezone:ro'
      - '/etc/localtime:/etc/localtime:ro'
EOF

cd "$INSTALL_DIR"
docker compose down 2>/dev/null || true
docker compose up -d
ok "Remnawave Node запущена."

# ==========================================
# 9. Автоблокировка аномальных IP
# ==========================================
if ! crontab -l 2>/dev/null | grep -q "/root/auto-ban.sh"; then
    cat > /root/auto-ban.sh <<'EOF'
#!/bin/bash
ss -tn | grep :443 | awk '{print $5}' | cut -d: -f1 | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | sort | uniq -c | sort -nr | awk '{if ($1 > 30) print $2}' | while read ip; do
    if ! ufw status | grep -q "$ip"; then
        echo "$(date): AUTO-BAN $ip ($1 соединений)" >> /root/auto-ban.log
        ufw deny from $ip to any port 443 comment "AUTO_BAN_$(date +%s)"
    fi
done
EOF
    chmod +x /root/auto-ban.sh
    (crontab -l 2>/dev/null; echo "*/2 * * * * /root/auto-ban.sh") | crontab -
    ok "Автоблокировка через cron добавлена."
else
    info "Автоблокировка уже настроена."
fi

# ==========================================
# 10. Дополнительные сервисы
# ==========================================
systemctl enable haveged --now 2>/dev/null || true
systemctl enable irqbalance --now 2>/dev/null || true
ok "Haveged и irqbalance (опционально) запущены."

# ==========================================
# Итог
# ==========================================
echo ""
echo "============================================================"
ok "УСТАНОВКА ЗАВЕРШЕНА!"
echo "============================================================"
echo ""
echo -e "${GREEN}Установленные компоненты:${NC}"
echo "  ✓ BBR + TCP-оптимизация"
echo "  ✓ UFW + анти-DDoS правила"
echo "  ✓ Fail2Ban"
echo "  ✓ Docker + Remnawave Node (NET_ADMIN)"
echo "  ✓ Автоблокировка аномальных IP (cron)"
echo ""
echo -e "${BLUE}Проверка:${NC}"
echo "  docker ps | grep remnanode"
echo "  ufw status numbered"
echo "  tail -f /root/auto-ban.log"
echo ""
echo -e "${YELLOW}Рекомендации:${NC}"
echo "  • Добавьте ноду в панель Remnawave по IP:3000"
echo "  • Для дополнительной защиты настройте Cloudflare"
echo "============================================================"
