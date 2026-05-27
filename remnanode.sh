#!/bin/bash
set -euo pipefail

# ==========================================
# Цвета и стили для понятного вывода
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
# Обновление системы и установка базовых пакетов
# ==========================================
info "Обновление списка пакетов и установка необходимых утилит..."
apt update -y && apt upgrade -y
apt install -y curl wget git ufw fail2ban software-properties-common \
                gnupg lsb-release ca-certificates haveged

ok "Базовые пакеты установлены."

# ==========================================
# Определение сетевого интерфейса
# ==========================================
DEFAULT_IF=$(ip route | grep default | awk '{print $5}' | head -1)
[[ -z "$DEFAULT_IF" ]] && DEFAULT_IF="eth0"
info "Основной сетевой интерфейс: $DEFAULT_IF"

# ==========================================
# Оптимизация ядра для максимальной скорости (TCP/UDP)
# ==========================================
info "Настройка параметров ядра (BBR, буферы, защита)..."

cat > /etc/sysctl.d/99-remnawave.conf <<'EOF'
# ---------- СКОРОСТЬ И ПРОИЗВОДИТЕЛЬНОСТЬ ----------
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0

# Увеличение сетевых буферов (для высоких скоростей)
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
net.ipv4.tcp_mem = 786432 1048576 1572864

# Увеличение лимитов очередей
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_abort_on_overflow = 0

# Быстрое закрытие соединений (уменьшает нагрузку)
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 1024 65535

# ---------- ЗАЩИТА БЕЗ ПОТЕРИ СКОРОСТИ ----------
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_fack = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_no_metrics_save = 1

# Игнорируем ICMP редиректы (безопасность)
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
info "Настройка лимитов (ulimit)..."
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
# Установка Docker (официальный репозиторий)
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
ufw default deny incoming
ufw default allow outgoing
ufw default deny forward

ufw allow 22/tcp comment 'SSH'
ufw allow 80/tcp comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS/VLESS'
ufw allow 3000/tcp comment 'Remnawave API'

# Вставляем защитные правила в before.rules
sed -i '/# End required/d' /etc/ufw/before.rules
cat >> /etc/ufw/before.rules <<'EOF'

# === АНТИ-DDOS ПРАВИЛА (сохраняют скорость для легитимных юзеров) ===
# Защита от SYN Flood
-A ufw-before-input -p tcp --syn -m limit --limit 3/s --limit-burst 10 -j ACCEPT
-A ufw-before-input -p tcp --syn -j DROP

# Отбрасываем невалидные пакеты
-A ufw-before-input -m state --state INVALID -j DROP

# Максимум 30 соединений с одного IP на 443 порту (безопасно для реальных пользователей)
-A ufw-before-input -p tcp --dport 443 -m connlimit --connlimit-above 30 --connlimit-mask 32 -j DROP

# Защита от сканирования портов
-A ufw-before-input -p tcp --tcp-flags ALL NONE -j DROP
-A ufw-before-input -p tcp --tcp-flags ALL ALL -j DROP

# Rate limit (50 новых соединений в секунду – достаточно для любого легитимного трафика)
-A ufw-before-input -p tcp --dport 443 -m limit --limit 50/s --limit-burst 100 -j ACCEPT
-A ufw-before-input -p tcp --dport 443 -j DROP
# End required
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

[sshd-ddos]
enabled = true
port = 22
maxretry = 10
findtime = 30
bantime = 2h
EOF

systemctl restart fail2ban
systemctl enable fail2ban
ok "Fail2Ban активирован (бан через UFW)."

# ==========================================
# Установка Remnawave Node
# ==========================================
info "Подготовка к установке Remnawave Node..."
INSTALL_DIR="/opt/remnanode"
mkdir -p $INSTALL_DIR

echo -n -e "${YELLOW}[?]${NC} Введите SECRET_KEY для ноды (из панели управления): "
read -r SECRET_KEY
[[ -z "$SECRET_KEY" ]] && err "SECRET_KEY не может быть пустым."

info "Создание docker-compose.yml с ограничением ресурсов и NET_ADMIN..."
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
    deploy:
      resources:
        limits:
          cpus: '2'
          memory: 2G
        reservations:
          cpus: '0.5'
          memory: 512M
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
ok "Remnawave Node запущена (контейнер remnanode)."

# ==========================================
# Автоматическая блокировка аномальных IP (cron)
# ==========================================
info "Настройка автоматической блокировки атакующих IP..."
cat > /root/auto-ban.sh <<'EOF'
#!/bin/bash
# Блокирует IP, создающие более 30 соединений на порту 443
ss -tn | grep :443 | awk '{print $5}' | cut -d: -f1 | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | sort | uniq -c | sort -nr | awk '{if ($1 > 30) print $2}' | while read ip; do
    if ! ufw status | grep -q "$ip"; then
        echo "$(date): AUTO-BAN $ip ($1 соединений)" >> /root/auto-ban.log
        ufw deny from $ip to any port 443 comment "AUTO_BAN_$(date +%s)"
    fi
done
EOF

chmod +x /root/auto-ban.sh
(crontab -l 2>/dev/null; echo "*/2 * * * * /root/auto-ban.sh") | crontab -
ok "Автоблокировка IP через cron добавлена (каждые 2 минуты)."

# ==========================================
# Дополнительные улучшения для скорости
# ==========================================
info "Включение генератора случайных чисел (haveged) для ускорения TLS..."
systemctl enable haveged
systemctl start haveged

info "Настройка планировщика CPU для сетевых прерываний (IRQ)..."
apt install -y irqbalance
systemctl enable irqbalance
systemctl start irqbalance

# ==========================================
# Итоговый вывод
# ==========================================
echo ""
echo "============================================================"
ok "УСТАНОВКА ЗАВЕРШЕНА УСПЕШНО!"
echo "============================================================"
echo ""
echo -e "${CYAN}Установленные компоненты:${NC}"
echo "  ✓ BBR + полная TCP-оптимизация (максимальная скорость)"
echo "  ✓ Увеличенные буферы и лимиты файлов"
echo "  ✓ UFW (порты 22,80,443,3000) + встроенная DDoS-защита"
echo "  ✓ Fail2Ban (блокировка подозрительных IP через UFW)"
echo "  ✓ Docker и Docker Compose"
echo "  ✓ Remnawave Node (контейнер с NET_ADMIN и лимитами CPU/RAM)"
echo "  ✓ Автоматическая блокировка IP с >30 соединений (cron)"
echo "  ✓ Haveged (ускорение шифрования) + irqbalance"
echo ""
echo -e "${CYAN}Проверка работы:${NC}"
echo "  docker ps | grep remnanode"
echo "  ufw status numbered"
echo "  tail -f /root/auto-ban.log"
echo ""
echo -e "${YELLOW}Рекомендации:${NC}"
echo "  • Настройте Cloudflare для дополнительной защиты от DDoS"
echo "  • Регулярно обновляйте систему: apt update && apt upgrade"
echo "  • Для отслеживания нагрузки: docker stats remnanode"
echo "============================================================"
