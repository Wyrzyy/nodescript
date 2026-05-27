#!/bin/bash
set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Проверка на root
if [ "$EUID" -ne 0 ]; then
    print_error "Пожалуйста, запустите скрипт с правами root (sudo)"
    exit 1
fi

# Обновление списка пакетов и системы
print_info "Обновление системы и пакетов..."
apt update -y && apt upgrade -y
apt install -y curl wget git ufw fail2ban iptables-persistent netfilter-persistent software-properties-common gnupg lsb-release ca-certificates

# Определение основного сетевого интерфейса
DEFAULT_INTERFACE=$(ip route | grep default | awk '{print $5}' | head -1)
print_info "Основной сетевой интерфейс: $DEFAULT_INTERFACE"

# ============================================
# 1. Системные оптимизации и TCP Tuning
# ============================================
print_info "Настройка системных параметров и TCP..."

cat > /etc/sysctl.d/99-remnawave.conf <<EOF
# ------------------------------------------------------------------
# Remnawave Node Performance & Protection Tuning
# ------------------------------------------------------------------

# 1. BBR + FQ (для максимальной производительности TCP)
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# 2. Увеличение лимитов для обработки большого числа соединений
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_abort_on_overflow = 0

# 3. Оптимизация памяти для сетевых буферов
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728
net.ipv4.tcp_mem = 786432 1048576 1572864

# 4. Ускорение закрытия соединений и переиспользование портов
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_tw_recycle = 0
net.ipv4.ip_local_port_range = 1024 65535

# 5. Защита от DDoS и вредоносных пакетов
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_fack = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_no_metrics_save = 1

# 6. Игнорируем ICMP редиректы (безопасность)
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# 7. Защита от ICMP flood
net.ipv4.icmp_echo_ignore_all = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

# 8. Увеличение лимитов для файлов (для высоких нагрузок)
fs.file-max = 2097152
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches = 524288
EOF

sysctl -p /etc/sysctl.d/99-remnawave.conf
print_success "Системные параметры применены"

# ============================================
# 2. Лимиты для пользователя (ulimits)
# ============================================
print_info "Настройка ulimits..."

cat > /etc/security/limits.d/99-remnawave.conf <<EOF
* soft nofile 1048576
* hard nofile 1048576
* soft nproc unlimited
* hard nproc unlimited
root soft nofile 1048576
root hard nofile 1048576
EOF

# Настройка systemd лимитов
mkdir -p /etc/systemd/system.conf.d/
cat > /etc/systemd/system.conf.d/99-limits.conf <<EOF
[Manager]
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=infinity
EOF

systemctl daemon-reload
print_success "Ulimits настроены"

# ============================================
# 3. Установка Docker
# ============================================
print_info "Установка Docker..."

# Добавление официального репозитория Docker
mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

apt update -y
apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
systemctl enable docker
systemctl start docker

print_success "Docker и Docker Compose установлены"

# ============================================
# 4. Настройка UFW (Uncomplicated Firewall)
# ============================================
print_info "Настройка UFW..."

# Сброс к дефолтным настройкам
yes | ufw reset

# Политики по умолчанию
ufw default deny incoming
ufw default allow outgoing
ufw default deny forward

# Разрешаем только нужные порты
ufw allow 22/tcp comment 'SSH'
ufw allow 80/tcp comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS/VLESS'
ufw allow 3000/tcp comment 'Remnawave API'

# Защита от SYN flood на уровне UFW
# (это дополнение к iptables правилам)
cat >> /etc/ufw/before.rules <<'EOF'

# === Remnawave Anti-DDoS Rules ===
# Ограничение SYN пакетов
-A ufw-before-input -p tcp --syn -m limit --limit 3/s --limit-burst 10 -j ACCEPT
-A ufw-before-input -p tcp --syn -j DROP

# Отбрасываем невалидные пакеты
-A ufw-before-input -m state --state INVALID -j DROP

# Ограничение на количество соединений с одного IP (для 443 порта)
-A ufw-before-input -p tcp --dport 443 -m connlimit --connlimit-above 30 --connlimit-mask 32 -j DROP

# Защита от сканирования портов
-A ufw-before-input -p tcp --tcp-flags ALL NONE -j DROP
-A ufw-before-input -p tcp --tcp-flags ALL ALL -j DROP
EOF

# Включаем UFW
yes | ufw enable
print_success "UFW настроен: открыты порты 22, 80, 443, 3000"

# ============================================
# 5. Установка и настройка Fail2Ban
# ============================================
print_info "Установка Fail2Ban..."

apt install -y fail2ban

# Создаем фильтры для защиты от DDoS
cat > /etc/fail2ban/filter.d/remnawave-ddos.conf <<'EOF'
[Definition]
failregex = ^.*rate limit exceeded.*remote_ip": "<HOST>".*$
ignoreregex =
EOF

cat > /etc/fail2ban/filter.d/remnawave-connlimit.conf <<'EOF'
[Definition]
failregex = ^.*connlimit.*\s<HOST>\s.*$
ignoreregex =
EOF

# Настройка jail.local
cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime = 1h
findtime = 60
maxretry = 20
banaction = iptables-multiport
ignoreip = 127.0.0.1/8

[sshd]
enabled = true
port = 22
filter = sshd
maxretry = 5
bantime = 1h

[remnawave-ddos]
enabled = true
port = 80,443
filter = remnawave-ddos
logpath = /var/log/caddy/access.log
         /var/log/remnanode/access.log
maxretry = 30
findtime = 30
bantime = 4h

[remnawave-connlimit]
enabled = true
port = 80,443
filter = remnawave-connlimit
logpath = /var/log/ufw.log
maxretry = 5
findtime = 10
bantime = 1h
EOF

systemctl restart fail2ban
systemctl enable fail2ban
print_success "Fail2Ban настроен"

# ============================================
# 6. Установка Remnawave Node
# ============================================
print_info "Установка Remnawave Node..."

# Директория для установки
INSTALL_DIR="/opt/remnanode"
mkdir -p ${INSTALL_DIR}

# Запрос SECRET_KEY у пользователя
echo ""
print_warning "Введите SECRET_KEY для Remnawave ноды (можно получить в панели управления):"
read -p "SECRET_KEY: " SECRET_KEY

if [ -z "$SECRET_KEY" ]; then
    print_error "SECRET_KEY не может быть пустым!"
    exit 1
fi

# Создание docker-compose.yml с NET_ADMIN и лимитами ресурсов
cat > ${INSTALL_DIR}/docker-compose.yml <<EOF
services:
  remnanode:
    container_name: remnanode
    hostname: remnanode
    image: remnawave/node:latest
    network_mode: host
    restart: always
    
    # Добавляем NET_ADMIN для управления соединениями
    cap_add:
      - NET_ADMIN
    
    # Ограничение ресурсов контейнера
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

# Запуск ноды
cd ${INSTALL_DIR}
docker compose up -d

print_success "Remnawave Node установлена и запущена"

# ============================================
# 7. Дополнительные iptables правила (дублирование защиты)
# ============================================
print_info "Применение дополнительных iptables правил..."

# Очистка старых правил, но сохранение важных
iptables -F
iptables -X

# Базовые разрешения
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -p tcp --dport 22 -j ACCEPT

# SYN Flood защита
iptables -A INPUT -p tcp --syn -m limit --limit 3/s --limit-burst 10 -j ACCEPT
iptables -A INPUT -p tcp --syn -j DROP

# Невалидные пакеты
iptables -A INPUT -m state --state INVALID -j DROP

# Connlimit для порта 443
iptables -A INPUT -p tcp --dport 443 -m connlimit --connlimit-above 30 --connlimit-mask 32 -j DROP

# Rate limit для порта 443 (пропускаем легитимный трафик)
iptables -A INPUT -p tcp --dport 443 -m limit --limit 50/s --limit-burst 100 -j ACCEPT
iptables -A INPUT -p tcp --dport 443 -j DROP

# Сохраняем правила
netfilter-persistent save

print_success "Дополнительные iptables правила применены"

# ============================================
# 8. Информация о установке
# ============================================
echo ""
echo "=========================================="
print_success "УСТАНОВКА ЗАВЕРШЕНА УСПЕШНО!"
echo "=========================================="
echo ""
print_info "Установлены компоненты:"
echo "  ✓ BBR + TCP Tuning"
echo "  ✓ UFW (порты: 22, 80, 443, 3000)"
echo "  ✓ Защита от SYN flood"
echo "  ✓ Fail2Ban с кастомными правилами"
echo "  ✓ Docker + Remnawave Node"
echo ""
print_info "Проверка статуса:"
docker ps | grep remnanode
echo ""
print_info "Логи ноды:"
echo "  docker logs -f remnanode"
echo ""
print_info "Проверка BBR:"
echo "  sysctl net.ipv4.tcp_congestion_control"
echo ""
print_warning "Рекомендации:"
echo "  1. Настройте Cloudflare для дополнительной защиты"
echo "  2. Регулярно обновляйте систему: apt update && apt upgrade"
echo "  3. Настройте мониторинг: docker stats remnanode"
echo "=========================================="
