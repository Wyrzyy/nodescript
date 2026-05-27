#!/bin/bash
set -euo pipefail

# ==========================================
# Цвета для понятного вывода
# ==========================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

ok()   { echo -e "${GREEN}[✓]${NC} $1"; }
info() { echo -e "${BLUE}[i]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }

# ==========================================
# Проверка прав root
# ==========================================
[[ $EUID -ne 0 ]] && err "Скрипт должен запускаться от root (sudo)."

# ==========================================
# Функция проверки и удаления существующей ноды
# ==========================================
check_and_remove_existing() {
    local exists=0
    if docker ps -a --format '{{.Names}}' | grep -q "^remnanode$"; then
        exists=1
        warn "Обнаружен Docker-контейнер 'remnanode'."
    fi
    if [[ -d "/opt/remnanode" ]]; then
        exists=1
        warn "Обнаружена директория /opt/remnanode (предыдущая установка)."
    fi
    if [[ $exists -eq 1 ]]; then
        echo -n -e "${YELLOW}[?]${NC} Удалить старую версию Remnawave Node и установить заново? (y/N): "
        read -r answer
        if [[ "$answer" =~ ^[Yy]$ ]]; then
            info "Удаляем старую установку..."
            # Останавливаем и удаляем контейнер
            docker stop remnanode 2>/dev/null || true
            docker rm remnanode 2>/dev/null || true
            # Удаляем директорию с конфигами
            rm -rf /opt/remnanode
            # (Опционально) удаляем образ, чтобы скачать свежий
            # docker rmi remnawave/node:latest 2>/dev/null || true
            ok "Старая установка удалена."
        else
            info "Установка отменена пользователем. Выход."
            exit 0
        fi
    fi
}

# ==========================================
# Обновление системы и установка пакетов
# ==========================================
info "Обновление системы и установка базовых пакетов..."
apt update -y && apt upgrade -y
apt install -y curl wget git ufw fail2ban software-properties-common \
                gnupg lsb-release ca-certificates haveged irqbalance

ok "Базовые пакеты установлены."

# ==========================================
# Определение сетевого интерфейса
# ==========================================
DEFAULT_IF=$(ip route | grep default | awk '{print $5}' | head -1)
[[ -z "$DEFAULT_IF" ]] && DEFAULT_IF="eth0"
info "Основной сетевой интерфейс: $DEFAULT_IF"

# ==========================================
# Оптимизация ядра (BBR, буферы, защита)
# ==========================================
info "Настройка параметров ядра для максимальной скорости и защиты..."
cat > /etc/sysctl.d/99-remnawave.conf <<'EOF'
# ---------- СКОРОСТЬ ----------
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0

# Увеличение буферов (для высоких скоростей)
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
net.ipv4.tcp_mem = 786432 1048576 1572864

# Увеличение очередей
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_abort_on_overflow = 0

# Быстрое закрытие соединений
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 1024 65535

# ---------- ЗАЩИТА ----------
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_fack = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_no_metrics_save = 1

# Игнорируем ICMP редиректы
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# Защита от ICMP flood
net.ipv4.icmp_echo_ignore_all = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

# Лимиты файлов (для большого числа соединений)
fs.file-max = 2097152
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches = 524288
EOF

sysctl -p /etc/sysctl.d/99-remnawave.conf
ok "Параметры ядра применены."

# ==========================================
# Ulimits (файловые дескрипторы)
# ==========================================
info "Настройка ulimits..."
cat > /etc/security/limits.d/99-remnawave.conf <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
* soft nproc unlimited
* hard nproc unlimited
root soft nofile 1048576
root hard nofile 1048576
EOF

mkdir -p /etc/systemd/system.conf.d/
cat > /etc/systemd/system.conf.d/99-limits.conf <<'EOF'
[Manager]
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=infinity
EOF
systemctl daemon-reload
ok "Ulimits настроены."

# ==========================================
# Установка Docker (без ограничений ресурсов)
# ==========================================
info "Установка Docker..."
if ! command -v docker &> /dev/null; then
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
# Настройка UFW (порты + анти-DDoS)
# ==========================================
info "Настройка файрвола UFW..."
ufw --force reset

# Политики по умолчанию
ufw default deny incoming
ufw default allow outgoing
ufw default deny forward

# Разрешаем нужные порты
ufw allow 22/tcp comment 'SSH'
ufw allow 80/tcp comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS/VLESS'
ufw allow 3000/tcp comment 'Remnawave API'

# Восстанавливаем оригинальный before.rules, чтобы избежать ошибок
cp /usr/share/ufw/before.rules /etc/ufw/before.rules

# Добавляем защитные правила
cat >> /etc/ufw/before.rules <<'EOF'

# === АНТИ-DDOS ПРАВИЛА ===
-A ufw-before-input -p tcp --syn -m limit --limit 3/s --limit-burst 10 -j ACCEPT
-A ufw-before-input -p tcp --syn -j DROP
-A ufw-before-input -m state --state INVALID -j DROP
-A ufw-before-input -p tcp --dport 443 -m connlimit --connlimit-above 30 --connlimit-mask 32 -j DROP
-A ufw-before-input -p tcp --tcp-flags ALL NONE -j DROP
-A ufw-before-input -p tcp --tcp-flags ALL ALL -j DROP
-A ufw-before-input -p tcp --dport 443 -m limit --limit 50/s --limit-burst 100 -j ACCEPT
-A ufw-before-input -p tcp --dport 443 -j DROP
EOF

yes | ufw enable
ok "UFW настроен (порты 22,80,443,3000 открыты)."

# ==========================================
# Настройка Fail2Ban (бан через ufw)
# ==========================================
info "Настройка Fail2Ban..."
systemctl stop fail2ban 2>/dev/null || true
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
ok "Fail2Ban активирован."

# ==========================================
# Проверка и удаление существующей ноды
# ==========================================
check_and_remove_existing

# ==========================================
# Установка Remnawave Node (без лимитов ресурсов)
# ==========================================
info "Установка Remnawave Node..."
INSTALL_DIR="/opt/remnanode"
mkdir -p $INSTALL_DIR

echo -n -e "${YELLOW}[?]${NC} Введите SECRET_KEY для ноды: "
read -r SECRET_KEY
[[ -z "$SECRET_KEY" ]] && err "SECRET_KEY не может быть пустым."

cat > $INSTALL_DIR/docker-compose.yml <<EOF
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

cd $INSTALL_DIR
docker compose up -d
ok "Remnawave Node запущена."

# ==========================================
# Автоматическая блокировка аномальных IP (cron)
# ==========================================
info "Настройка автоматической блокировки атакующих IP..."
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

# ==========================================
# Дополнительные сервисы для производительности
# ==========================================
systemctl enable haveged --now
systemctl enable irqbalance --now
ok "Haveged и irqbalance запущены (ускорение TLS и распределение прерываний)."

# ==========================================
# Итоговый вывод
# ==========================================
echo ""
echo "============================================================"
ok "УСТАНОВКА ЗАВЕРШЕНА!"
echo "============================================================"
echo ""
echo -e "${CYAN}Установленные компоненты:${NC}"
echo "  ✓ BBR + полная TCP-оптимизация"
echo "  ✓ Увеличенные буферы и лимиты файлов"
echo "  ✓ UFW + анти-DDoS правила (без ограничений железа)"
echo "  ✓ Fail2Ban"
echo "  ✓ Docker + Remnawave Node (NET_ADMIN, без лимитов CPU/RAM)"
echo "  ✓ Автоматическая блокировка аномальных IP (cron)"
echo ""
echo -e "${CYAN}Проверка:${NC}"
echo "  docker ps | grep remnanode"
echo "  ufw status numbered"
echo "  tail -f /root/auto-ban.log"
echo ""
echo -e "${YELLOW}Рекомендации:${NC}"
echo "  • Добавьте ноду в панель Remnawave по IP:3000"
echo "  • Для дополнительной защиты настройте Cloudflare"
echo "============================================================"
