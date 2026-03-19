#!/usr/bin/env bash

# 🚀 REMNANODE FULL SETUP
# Безопасная автоматическая настройка сервера под RemnaNode

set -Eeuo pipefail

# =========================
# Цвета
# =========================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
NC='\033[0m'

# =========================
# Глобальные переменные
# =========================
SCRIPT_NAME="$(basename "$0")"
TMP_DIR="/tmp/remnanode-setup"
SYSCTL_BBR_FILE="/etc/sysctl.d/99-remnanode-bbr.conf"
SWAP_SYSCTL_FILE="/etc/sysctl.d/99-remnanode-swap.conf"
SSH_BACKUP_FILE=""
SSH_SERVICE=""
INSTALL_REMNANODE="true"
XRAY_INSTALL="false"
NODE_PORT="3000"

mkdir -p "$TMP_DIR"

# =========================
# Вывод
# =========================
print_step() {
    echo -e "${BLUE}┌─[${NC} ${CYAN}⚡${NC} ${BLUE}]────────────────────────────────────────────${NC}"
    echo -e "${BLUE}│${NC} ${CYAN}➜${NC} $1"
    echo -e "${BLUE}└──────────────────────────────────────────────────────────${NC}"
}

print_success() { echo -e "${GREEN}✅ $1${NC}"; }
print_error()   { echo -e "${RED}❌ $1${NC}" >&2; }
print_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
print_info()    { echo -e "${CYAN}ℹ️  $1${NC}"; }
print_ask()     { echo -ne "${YELLOW}👉 $1 ${NC}"; }

# =========================
# Обработчики ошибок
# =========================
on_error() {
    local exit_code=$?
    local line_no="${1:-unknown}"
    print_error "Скрипт завершился с ошибкой на строке: $line_no (код: $exit_code)"
    print_info "Проверь логи выше. Изменения, уже применённые до ошибки, могли сохраниться."
    exit "$exit_code"
}
trap 'on_error $LINENO' ERR

# =========================
# Проверки
# =========================
require_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        print_error "Запусти скрипт от root: sudo bash $SCRIPT_NAME"
        exit 1
    fi
}

detect_ssh_service() {
    if systemctl list-unit-files | grep -q '^ssh\.service'; then
        SSH_SERVICE="ssh"
    elif systemctl list-unit-files | grep -q '^sshd\.service'; then
        SSH_SERVICE="sshd"
    else
        SSH_SERVICE="ssh"
    fi
}

restart_ssh_service() {
    detect_ssh_service
    systemctl restart "$SSH_SERVICE"
}

validate_ssh_config() {
    sshd -t
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

get_docker_compose_cmd() {
    if docker compose version >/dev/null 2>&1; then
        echo "docker compose"
    elif command_exists docker-compose; then
        echo "docker-compose"
    else
        echo ""
    fi
}

pause_small() {
    sleep 1
}

# =========================
# Меню / ввод
# =========================
show_menu() {
    local title="$1"
    shift
    local options=("$@")
    local choice
    local max="${#options[@]}"

    echo -e "\n${PURPLE}════════════════════════════════════════════════════════════${NC}"
    echo -e "${PURPLE}   $title${NC}"
    echo -e "${PURPLE}════════════════════════════════════════════════════════════${NC}"

    for i in "${!options[@]}"; do
        echo -e "  ${GREEN}[$((i+1))]${NC} ${options[$i]}"
    done

    while true; do
        echo
        print_ask "Выберите номер [1-$max]:"
        read -r choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= max )); then
            printf '%s\n' "$choice"
            return 0
        fi
        print_error "Неверный ввод. Введи число от 1 до $max."
    done
}

ask_input() {
    local prompt="$1"
    local default="${2:-}"
    local value

    if [[ -n "$default" ]]; then
        print_ask "$prompt [$default]:"
    else
        print_ask "$prompt:"
    fi

    read -r value
    if [[ -z "$value" ]]; then
        value="$default"
    fi
    printf '%s\n' "$value"
}

ask_yes_no() {
    local prompt="$1"
    local default="${2:-y}"
    local value

    while true; do
        if [[ "$default" == "y" ]]; then
            print_ask "$prompt [Y/n]:"
        else
            print_ask "$prompt [y/N]:"
        fi

        read -r value
        value="${value:-$default}"

        case "$value" in
            y|Y) return 0 ;;
            n|N) return 1 ;;
            *) print_error "Введи y или n." ;;
        esac
    done
}

# =========================
# SSH проверки
# =========================
get_sshd_effective_value() {
    local key="$1"
    sshd -T 2>/dev/null | awk -v k="$key" '$1==k {print $2; exit}'
}

check_ssh_status() {
    echo -e "\n${CYAN}🔍 ПРОВЕРКА SSH СТАТУСА:${NC}"
    echo -e "${PURPLE}────────────────────────────────────────────────────────────${NC}"

    local auth_file="/root/.ssh/authorized_keys"
    local key_count=0
    local pass_auth=""
    local kbd_auth=""
    local pubkey_auth=""

    if [[ -f "$auth_file" ]]; then
        key_count=$(grep -Ec '^(ssh-|ecdsa-|sk-ssh-)' "$auth_file" 2>/dev/null || true)
        echo -e "  📄 Файл authorized_keys: ${GREEN}✅ существует${NC}"
        echo -e "  🔑 Количество ключей: ${CYAN}${key_count}${NC}"
    else
        echo -e "  📄 Файл authorized_keys: ${RED}❌ отсутствует${NC}"
    fi

    pass_auth="$(get_sshd_effective_value passwordauthentication || true)"
    kbd_auth="$(get_sshd_effective_value kbdinteractiveauthentication || true)"
    pubkey_auth="$(get_sshd_effective_value pubkeyauthentication || true)"

    echo -e "\n  ⚙️  Эффективная SSH конфигурация:"
    echo -e "     PubkeyAuthentication: ${CYAN}${pubkey_auth:-unknown}${NC}"
    echo -e "     PasswordAuthentication: ${CYAN}${pass_auth:-unknown}${NC}"
    echo -e "     KbdInteractiveAuthentication: ${CYAN}${kbd_auth:-unknown}${NC}"

    echo -e "\n  📊 ИТОГ:"
    if [[ "$pubkey_auth" == "yes" && "$pass_auth" == "no" && "$kbd_auth" == "no" && "$key_count" -gt 0 ]]; then
        echo -e "     ${GREEN}✅ SSH выглядит безопасно: вход по ключу активен, пароль отключён${NC}"
        return 0
    fi

    echo -e "     ${YELLOW}⚠️  SSH не полностью ужесточён или ключей нет${NC}"
    return 1
}

# =========================
# Система
# =========================
update_system() {
    print_step "Обновление системы"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get upgrade -y
    apt-get install -y \
        curl wget unzip ca-certificates gnupg lsb-release \
        software-properties-common apt-transport-https \
        ufw jq
    print_success "Система обновлена"
}

# =========================
# BBR
# =========================
enable_bbr() {
    print_step "Проверка и включение BBR"

    local current_cc
    local available
    current_cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
    available="$(sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"

    if [[ "$current_cc" == "bbr" ]]; then
        print_success "BBR уже включён"
        return 0
    fi

    if ! lsmod | grep -q '^tcp_bbr'; then
        modprobe tcp_bbr || true
    fi

    mkdir -p /etc/modules-load.d
    if ! grep -qx 'tcp_bbr' /etc/modules-load.d/remnanode-bbr.conf 2>/dev/null; then
        echo 'tcp_bbr' > /etc/modules-load.d/remnanode-bbr.conf
    fi

    cat > "$SYSCTL_BBR_FILE" <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF

    sysctl --system >/dev/null

    current_cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
    if [[ "$current_cc" == "bbr" ]]; then
        print_success "BBR успешно включён"
    else
        print_warning "Не удалось подтвердить активацию BBR. Доступные алгоритмы:"
        echo "$available"
    fi
}

# =========================
# Docker
# =========================
install_docker_if_needed() {
    print_step "Проверка Docker"

    if command_exists docker; then
        print_success "Docker уже установлен"
    else
        print_info "Docker не найден, устанавливаем"
        curl -fsSL https://get.docker.com | sh
        systemctl enable docker
        systemctl start docker
        print_success "Docker установлен"
    fi

    local compose_cmd
    compose_cmd="$(get_docker_compose_cmd)"
    if [[ -z "$compose_cmd" ]]; then
        print_info "Плагин docker compose не найден, пробуем установить"
        apt-get install -y docker-compose-plugin || true
    fi

    compose_cmd="$(get_docker_compose_cmd)"
    if [[ -z "$compose_cmd" ]]; then
        print_error "Не удалось найти ни 'docker compose', ни 'docker-compose'"
        exit 1
    fi

    print_success "Команда compose: $compose_cmd"
}

# =========================
# RemnaNode
# =========================
prepare_existing_installation() {
    print_step "Проверка существующей установки RemnaNode"

    if [[ -d /opt/remnanode ]]; then
        print_warning "Обнаружена существующая папка /opt/remnanode"

        local compose_cmd
        compose_cmd="$(get_docker_compose_cmd)"
        if [[ -n "$compose_cmd" && -f /opt/remnanode/docker-compose.yml ]]; then
            ( cd /opt/remnanode && $compose_cmd down ) || true
        fi

        local choice
        choice="$(show_menu "УПРАВЛЕНИЕ СУЩЕСТВУЮЩЕЙ УСТАНОВКОЙ" \
            "Удалить и установить заново" \
            "Пропустить установку и использовать существующую" \
            "Выйти из скрипта")"

        case "$choice" in
            1)
                print_step "Удаление старой установки"
                rm -rf /opt/remnanode
                rm -rf /var/lib/remnanode
                INSTALL_REMNANODE="true"
                print_success "Старая установка удалена"
                ;;
            2)
                INSTALL_REMNANODE="false"
                print_info "Будет использована существующая установка"
                ;;
            3)
                print_info "Выход по запросу пользователя"
                exit 0
                ;;
        esac
    else
        INSTALL_REMNANODE="true"
    fi
}

install_remnanode() {
    if [[ "$INSTALL_REMNANODE" != "true" ]]; then
        return 0
    fi

    print_step "Установка RemnaNode"

    local secret_key
    secret_key="$(ask_input "Введите SECRET_KEY из Remnawave-Panel")"
    if [[ -z "$secret_key" ]]; then
        print_error "SECRET_KEY не может быть пустым"
        exit 1
    fi

    NODE_PORT="$(ask_input "Введите порт для Node" "3000")"
    if [[ ! "$NODE_PORT" =~ ^[0-9]+$ ]] || (( NODE_PORT < 1 || NODE_PORT > 65535 )); then
        print_error "Некорректный порт: $NODE_PORT"
        exit 1
    fi

    local xray_choice
    xray_choice="$(show_menu "УСТАНОВКА XRAY" \
        "Установить Xray-core" \
        "Пропустить установку Xray")"

    if [[ "$xray_choice" == "1" ]]; then
        XRAY_INSTALL="true"
    else
        XRAY_INSTALL="false"
    fi

    mkdir -p /opt/remnanode /var/lib/remnanode

    curl -fsSL https://raw.githubusercontent.com/DigneZzZ/remnawave-scripts/main/remnanode.sh -o /usr/local/bin/remnanode
    chmod 755 /usr/local/bin/remnanode

    cat > /opt/remnanode/.env <<EOF
### NODE ###
NODE_PORT=${NODE_PORT}

### XRAY ###
SECRET_KEY=${secret_key}
XTLS_API_PORT=61000
EOF

    cat > /opt/remnanode/docker-compose.yml <<'EOF'
services:
  remnanode:
    container_name: remnanode
    hostname: remnanode
    image: ghcr.io/remnawave/node:latest
    env_file:
      - .env
    network_mode: host
    restart: always
    cap_add:
      - NET_ADMIN
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
EOF

    if [[ "$XRAY_INSTALL" == "true" ]]; then
        install_xray
        cat >> /opt/remnanode/docker-compose.yml <<'EOF'
    volumes:
      - /var/lib/remnanode/xray:/usr/local/bin/xray:ro
      - /var/lib/remnanode/geoip.dat:/usr/local/share/xray/geoip.dat:ro
      - /var/lib/remnanode/geosite.dat:/usr/local/share/xray/geosite.dat:ro
EOF
    fi

    print_success "RemnaNode подготовлен в /opt/remnanode"
}

install_xray() {
    print_step "Установка Xray-core"

    local arch
    local latest_release
    local xray_filename
    local xray_url

    case "$(uname -m)" in
        x86_64) arch="64" ;;
        aarch64|arm64) arch="arm64-v8a" ;;
        *) arch="64" ;;
    esac

    latest_release="$(curl -fsSL https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -r '.tag_name')"
    if [[ -z "$latest_release" || "$latest_release" == "null" ]]; then
        print_warning "Не удалось определить последнюю версию Xray"
        return 0
    fi

    xray_filename="Xray-linux-${arch}.zip"
    xray_url="https://github.com/XTLS/Xray-core/releases/download/${latest_release}/${xray_filename}"

    cd /var/lib/remnanode
    wget -qO "$xray_filename" "$xray_url"
    unzip -o "$xray_filename" >/dev/null
    rm -f "$xray_filename"

    chmod +x /var/lib/remnanode/xray || true

    [[ -f /var/lib/remnanode/geoip.dat ]] || print_warning "geoip.dat не найден"
    [[ -f /var/lib/remnanode/geosite.dat ]] || print_warning "geosite.dat не найден"

    print_success "Xray-core установлен"
}

# =========================
# UFW
# =========================
setup_ufw() {
    print_step "Настройка UFW"

    local panel_ip
    panel_ip="$(ask_input "Введите IP панели, которой разрешить доступ к NODE_PORT (${NODE_PORT})")"

    if [[ -z "$panel_ip" ]]; then
        print_error "IP панели не может быть пустым"
        exit 1
    fi

    if ! [[ "$panel_ip" =~ ^[0-9a-fA-F:.]+(/[0-9]+)?$ ]]; then
        print_warning "IP/сеть выглядит необычно: $panel_ip"
        if ! ask_yes_no "Продолжить с этим значением?" "n"; then
            exit 1
        fi
    fi

    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing

    ufw limit 22/tcp comment 'SSH rate limit'
    ufw allow 443/tcp comment 'HTTPS/Reality'
    ufw allow 443/udp comment 'QUIC/HTTP3'
    ufw allow 8443/tcp comment 'HTTPS alt'
    ufw allow 8443/udp comment 'HTTPS alt QUIC'
    ufw allow 9999/tcp comment 'HAProxy backend public'
    ufw allow from "$panel_ip" to any port "$NODE_PORT" proto tcp comment 'Node management panel only'

    ufw --force enable

    print_success "UFW настроен"
}

# =========================
# SSH hardening
# =========================
configure_ssh_key_only() {
    print_step "Настройка SSH входа только по ключу"

    local ssh_dir="/root/.ssh"
    local auth_file="${ssh_dir}/authorized_keys"
    local user_key='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICp1kvEpQtmWf15TBVOhkBWQakvAVjBv+G+8ak/PGyXg Generated By Termius'

    mkdir -p "$ssh_dir"
    chmod 700 "$ssh_dir"
    touch "$auth_file"
    chmod 600 "$auth_file"

    if [[ -f "$auth_file" ]]; then
        cp "$auth_file" "${auth_file}.backup.$(date +%Y%m%d_%H%M%S)"
        print_info "Бэкап authorized_keys сохранён"
    fi

    if ! grep -Fqx "$user_key" "$auth_file"; then
        echo "$user_key" >> "$auth_file"
        print_success "SSH ключ добавлен"
    else
        print_info "SSH ключ уже присутствует"
    fi

    SSH_BACKUP_FILE="/etc/ssh/sshd_config.backup.$(date +%Y%m%d_%H%M%S)"
    cp /etc/ssh/sshd_config "$SSH_BACKUP_FILE"
    print_info "Бэкап sshd_config: $SSH_BACKUP_FILE"

    # Убираем старые директивы, чтобы не плодить дубли
    sed -i '/^[#[:space:]]*PasswordAuthentication[[:space:]]\+/d' /etc/ssh/sshd_config
    sed -i '/^[#[:space:]]*ChallengeResponseAuthentication[[:space:]]\+/d' /etc/ssh/sshd_config
    sed -i '/^[#[:space:]]*KbdInteractiveAuthentication[[:space:]]\+/d' /etc/ssh/sshd_config
    sed -i '/^[#[:space:]]*PubkeyAuthentication[[:space:]]\+/d' /etc/ssh/sshd_config

    cat >> /etc/ssh/sshd_config <<'EOF'

# RemnaNode hardening
PubkeyAuthentication yes
PasswordAuthentication no
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no
EOF

    validate_ssh_config
    restart_ssh_service

    print_success "SSH конфиг применён и сервис перезапущен"

    echo
    check_ssh_status

    echo
    print_warning "СЕЙЧАС ВАЖНО: открой вторую SSH-сессию и проверь вход по ключу."
    if ask_yes_no "Ты успешно вошёл во второй сессии по ключу?" "n"; then
        print_success "Подтверждено: вход по ключу работает"
    else
        print_warning "Откатываем изменения SSH"
        cp "$SSH_BACKUP_FILE" /etc/ssh/sshd_config
        validate_ssh_config
        restart_ssh_service
        print_success "SSH конфиг восстановлен из бэкапа"
    fi
}

maybe_configure_ssh() {
    print_step "Проверка безопасности SSH"

    echo -e "\n${CYAN}📋 СОСТОЯНИЕ SSH ДО ИЗМЕНЕНИЙ:${NC}"
    check_ssh_status || true

    local choice
    choice="$(show_menu "РЕЖИМ ВХОДА ПО SSH" \
        "Отключить пароль и оставить только вход по ключу" \
        "Оставить вход по паролю как есть")"

    if [[ "$choice" == "1" ]]; then
        configure_ssh_key_only
    else
        print_info "Настройки SSH оставлены без изменений"
    fi
}

# =========================
# Swap
# =========================
setup_swap() {
    print_step "Настройка swap"

    local choice
    local swap_size="0"

    choice="$(show_menu "ВЫБОР РАЗМЕРА SWAP" \
        "Не создавать swap" \
        "1 GB" \
        "2 GB" \
        "4 GB" \
        "8 GB" \
        "Свой размер")"

    case "$choice" in
        1) swap_size="0" ;;
        2) swap_size="1" ;;
        3) swap_size="2" ;;
        4) swap_size="4" ;;
        5) swap_size="8" ;;
        6)
            swap_size="$(ask_input "Введите размер swap в GB")"
            if [[ ! "$swap_size" =~ ^[0-9]+$ ]] || (( swap_size < 1 )); then
                print_error "Некорректный размер swap"
                swap_size="0"
            fi
            ;;
    esac

    if (( swap_size == 0 )); then
        print_info "Swap не создаётся"
        return 0
    fi

    if swapon --show | grep -q '^/swapfile'; then
        print_warning "Swapfile уже существует, пересоздаём"
        swapoff /swapfile || true
        rm -f /swapfile
    fi

    print_step "Создание swap ${swap_size}GB"

    if command_exists fallocate; then
        fallocate -l "${swap_size}G" /swapfile
    else
        dd if=/dev/zero of=/swapfile bs=1M count=$((swap_size * 1024)) status=progress
    fi

    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile

    if ! grep -qE '^/swapfile[[:space:]]+none[[:space:]]+swap' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi

    cat > "$SWAP_SYSCTL_FILE" <<'EOF'
vm.swappiness = 10
EOF
    sysctl --system >/dev/null

    print_success "Swap ${swap_size}GB создан"
}

# =========================
# Запуск контейнера
# =========================
start_remnanode() {
    print_step "Запуск RemnaNode"

    if [[ ! -f /opt/remnanode/docker-compose.yml ]]; then
        print_warning "Файл /opt/remnanode/docker-compose.yml не найден, запуск пропущен"
        return 0
    fi

    local compose_cmd
    compose_cmd="$(get_docker_compose_cmd)"
    if [[ -z "$compose_cmd" ]]; then
        print_error "Команда docker compose не найдена"
        exit 1
    fi

    (
        cd /opt/remnanode
        $compose_cmd up -d
    )

    pause_small
    if docker ps --format '{{.Names}}' | grep -qx 'remnanode'; then
        print_success "Контейнер remnanode запущен"
    else
        print_warning "Контейнер remnanode не найден среди активных"
        print_info "Проверь логи: docker logs remnanode"
    fi
}

# =========================
# Финальный отчёт
# =========================
final_report() {
    clear
    echo -e "${GREEN}"
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║     ✅ НАСТРОЙКА REMNANODE ЗАВЕРШЕНА                     ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    echo -e "\n${CYAN}📊 СТАТУС UFW:${NC}"
    ufw status numbered || true

    echo -e "\n${CYAN}📊 СТАТУС BBR:${NC}"
    sysctl net.ipv4.tcp_congestion_control || true

    echo -e "\n${CYAN}📊 СТАТУС SWAP:${NC}"
    free -h || true
    swapon --show || true

    echo -e "\n${CYAN}🔐 СТАТУС SSH:${NC}"
    check_ssh_status || true

    echo -e "\n${CYAN}🚀 REMNANODE:${NC}"
    if [[ -f /opt/remnanode/.env ]]; then
        local final_port
        final_port="$(grep '^NODE_PORT=' /opt/remnanode/.env | cut -d= -f2 || true)"
        echo "   Порт: ${final_port:-3000}"
    fi
    echo "   Папка: /opt/remnanode"

    if docker ps --format '{{.Names}}' | grep -qx 'remnanode'; then
        echo -e "   Статус: ${GREEN}✅ РАБОТАЕТ${NC}"
    else
        echo -e "   Статус: ${YELLOW}⏸️  НЕ ЗАПУЩЕН${NC}"
    fi

    echo -e "\n${GREEN}════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}🔥 Сервер настроен${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
}

# =========================
# Main
# =========================
main() {
    require_root
    detect_ssh_service

    clear
    echo -e "${CYAN}"
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║        🔥 REMNANODE - АВТОМАТИЧЕСКАЯ НАСТРОЙКА           ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    update_system

    local bbr_choice
    bbr_choice="$(show_menu "НАСТРОЙКА BBR" \
        "Включить BBR (рекомендуется)" \
        "Пропустить")"
    if [[ "$bbr_choice" == "1" ]]; then
        enable_bbr
    else
        print_info "BBR пропущен"
    fi

    install_docker_if_needed
    prepare_existing_installation
    install_remnanode
    setup_ufw
    maybe_configure_ssh
    setup_swap
    start_remnanode
    final_report
}

main "$@"
