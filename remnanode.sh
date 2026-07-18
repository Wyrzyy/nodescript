#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
# REMNANODE LAUNCHER — Ubuntu 24.04 / Debian 12
# Remnanode · Selfsteal · Hysteria2 · WARP · MTProto · SWAP · UFW · Тесты
# Версия: 2026.7.9
#
# Запуск (рекомендуется — скачать в файл, затем выполнить):
#   curl -fsSL -o /tmp/remnanode.sh https://raw.githubusercontent.com/Wyrzyy/nodescript/main/remnanode.sh
#   sudo bash /tmp/remnanode.sh
#
# Или одной строкой (скрипт сам перезапустится из файла):
#   bash <(curl -fsSL https://raw.githubusercontent.com/Wyrzyy/nodescript/main/remnanode.sh)
###############################################################################

SCRIPT_VERSION="2026.7.9"

# Если запущены через bash <(curl …) (/dev/fd/…) — копируем себя в файл и
# перезапускаемся. Иначе в Termius/SSH часто «пропадают» prompt и шаги.
_SRC="${BASH_SOURCE[0]:-$0}"
if [[ "$_SRC" == /dev/fd/* || "$_SRC" == /proc/self/fd/* || "$_SRC" == /dev/stdin ]]; then
  _RN_TMP="$(mktemp /tmp/remnanode-run.XXXXXX.sh)"
  cat "$_SRC" > "$_RN_TMP"
  chmod +x "$_RN_TMP"
  exec bash "$_RN_TMP" "$@"
fi
APP="remnanode"
DIR="/opt/$APP"
COMPOSE="$DIR/docker-compose.yml"
ENV_FILE="$DIR/.env"
LOG="/var/log/${APP}-install.log"
CUSTOM_XRAY_DIR="$DIR/custom-xray"
XRAY_VERSION_DEFAULT="v26.6.1"
PANEL_IP_DEFAULT="141.98.7.57"
WARP_PORT=9091
LAUNCHER_PATH="/opt/remnanode/installer.sh"
CLI_PATH="/usr/local/bin/remnanode"

# Внешние скрипты
SELFSTEAL_RAW="https://raw.githubusercontent.com/DigneZzZ/remnawave-scripts/main/selfsteal.sh"
H2_RAW="https://raw.githubusercontent.com/Origamidnd/h2-script/master/setup.sh"
MTPROTO_BOOTSTRAP_RAW="https://raw.githubusercontent.com/sleep3r/mtproto.zig/main/deploy/bootstrap.sh"
XRAY_RELEASE_BASE="https://github.com/XTLS/Xray-core/releases/download"

export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none
export NEEDRESTART_MODE=a
# Нужно для корректной ширины кириллицы в меню
export LANG="${LANG:-C.UTF-8}"
export LC_ALL="${LC_ALL:-C.UTF-8}"

# Цвета
GREEN='\033[0;32m'; RED='\033[0;31m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; WHITE='\033[1;37m'; GRAY='\033[0;37m'; BOLD='\033[1m'
DIM='\033[2m'; NC='\033[0m'

# UI-вывод всегда в /dev/tty (если есть) — один раз, без потери в pipe/<(curl)
_msg() {
  local color="$1" icon="$2" text="$3"
  local line
  printf -v line '%b%s %s%b' "$color" "$icon" "$text" "$NC"
  if [[ -w /dev/tty ]]; then
    echo -e "$line" > /dev/tty
  else
    echo -e "$line"
  fi
}
ok()   { _msg "$GREEN" "✅" "$1"; }
info() { _msg "$BLUE" "ℹ️ " "$1"; }
warn() { _msg "$YELLOW" "⚠️ " "$1"; }
err()  {
  _msg "$RED" "❌" "$1"
  _msg "$GRAY" "📋" "последние строки лога → ${LOG}"
  if [[ -w /dev/tty ]]; then
    tail -n 30 "$LOG" 2>/dev/null > /dev/tty || true
  else
    tail -n 30 "$LOG" 2>/dev/null || true
  fi
  exit 1
}

mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
: > "$LOG" 2>/dev/null || true
exec 3>>"$LOG" 2>/dev/null || exec 3>/dev/null

hline() { echo -e "${GRAY}$(printf '─%.0s' $(seq 1 "${1:-56}"))${NC}"; }

# Всегда общаемся с реальным терминалом (/dev/tty).
# Нужно для bash <(curl …) / Termius: иначе prompt и ввод «пропадают».
_TTY="/dev/tty"
if [[ ! -r $_TTY || ! -w $_TTY ]]; then
  _TTY="/dev/stdin"
fi

_tty_printf() { printf "$@" >"$_TTY" 2>/dev/null || printf "$@"; }
_tty_echo()   { echo -e "$@" >"$_TTY" 2>/dev/null || echo -e "$@"; }

# Прочитать строку с терминала (не из pipe скрипта)
_tty_read() {
  local _silent="${1:-0}" _ans=""
  if [[ -r /dev/tty ]]; then
    if [[ "$_silent" == "1" ]]; then
      read -rs _ans < /dev/tty || true
    else
      read -r _ans < /dev/tty || true
    fi
  else
    if [[ "$_silent" == "1" ]]; then
      read -rs _ans || true
    else
      read -r _ans || true
    fi
  fi
  printf '%s' "$_ans"
}

pause() {
  _tty_echo ""
  _tty_printf "  ⏎  Нажмите Enter для продолжения..."
  _tty_read >/dev/null
  _tty_echo ""
}

# Видимый вопрос → переменная. Всегда пишет prompt в /dev/tty.
# ask "Текст" VAR [default]
ask() {
  local prompt="$1" varname="$2" default="${3:-}" _ans
  if [[ -n "$default" ]]; then
    _tty_printf "  %b%s%b %b[%s]%b: " "$WHITE" "$prompt" "$NC" "$GRAY" "$default" "$NC"
  else
    _tty_printf "  %b%s%b: " "$WHITE" "$prompt" "$NC"
  fi
  _ans=$(_tty_read)
  if [[ -z "$_ans" && -n "$default" ]]; then
    _ans="$default"
  fi
  printf -v "$varname" '%s' "$_ans"
}

ask_secret() {
  local prompt="$1" varname="$2" _ans
  _tty_printf "  %b%s%b: " "$WHITE" "$prompt" "$NC"
  _ans=$(_tty_read 1)
  _tty_echo ""
  printf -v "$varname" '%s' "$_ans"
}

# Короткий выбор пункта меню
ask_choice() {
  local varname="$1" prompt="${2:-👉}"
  local _ans
  _tty_printf "  %b%s%b " "$WHITE" "$prompt" "$NC"
  _ans=$(_tty_read)
  printf -v "$varname" '%s' "$_ans"
}

ask_yes_no() {
  # ask_yes_no "Вопрос?" VAR [default N|Y]
  local prompt="$1" varname="$2" default="${3:-N}" _ans _hint
  if [[ "$default" =~ ^[Yy]$ ]]; then _hint="Y/n"; else _hint="y/N"; fi
  _tty_printf "  %b%s%b %b[%s]%b: " "$WHITE" "$prompt" "$NC" "$GRAY" "$_hint" "$NC"
  _ans=$(_tty_read)
  if [[ -z "$_ans" ]]; then _ans="$default"; fi
  printf -v "$varname" '%s' "$_ans"
}

spin() {
  local pid=$1 msg=$2
  local s='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' i=0 out=/dev/tty
  [[ -w $out ]] || out=/dev/stdout
  # Сразу показываем строку шага
  printf "  ${CYAN}⏳${NC} %s " "$msg" >"$out"
  while kill -0 "$pid" 2>/dev/null; do
    printf "\b%s" "${s:$((i++ % ${#s})):1}" >"$out"
    sleep 0.1
  done
  wait "$pid"
  local rc=$?
  if [[ $rc -eq 0 ]]; then
    printf "\b ${GREEN}✅${NC}\n" >"$out"
  else
    printf "\b ${RED}❌${NC}\n" >"$out"
    return $rc
  fi
}

# Шаг с видимым статусом; подробности — в лог, итог — на экран
run_step() {
  local msg="$1" cmd="$2"
  echo "=== $(date '+%F %T') | $msg ===" >&3
  ( eval "$cmd" >&3 2>&3 ) &
  local pid=$!
  spin "$pid" "$msg" || {
    warn "└─ подробности в логе: ${LOG}"
    err "Ошибка на шаге: $msg"
  }
}

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || err "Запустите от root: sudo bash $0"
}

###############################################################################
# GitHub / загрузки — зеркала для РФ и зарубежья
###############################################################################
# Порядок: прямой URL → прокси-зеркала (часто доступны из РФ)
gh_candidates() {
  local url="$1"
  echo "$url"
  case "$url" in
    https://raw.githubusercontent.com/*)
      local path="${url#https://raw.githubusercontent.com/}"
      echo "https://ghproxy.net/https://raw.githubusercontent.com/${path}"
      echo "https://ghfast.top/https://raw.githubusercontent.com/${path}"
      echo "https://ghproxy.com/https://raw.githubusercontent.com/${path}"
      # jsDelivr: user/repo/branch/path → user/repo@branch/path
      if [[ "$path" =~ ^([^/]+)/([^/]+)/([^/]+)/(.*)$ ]]; then
        echo "https://cdn.jsdelivr.net/gh/${BASH_REMATCH[1]}/${BASH_REMATCH[2]}@${BASH_REMATCH[3]}/${BASH_REMATCH[4]}"
      fi
      ;;
    https://github.com/*/releases/download/*)
      echo "https://ghproxy.net/${url}"
      echo "https://ghfast.top/${url}"
      echo "https://ghproxy.com/${url}"
      ;;
    https://github.com/*)
      echo "https://ghproxy.net/${url}"
      echo "https://ghfast.top/${url}"
      echo "https://ghproxy.com/${url}"
      ;;
  esac
}

# Скачать URL в файл (с зеркалами). Возврат 0 при успехе.
gh_download() {
  local url="$1" dest="$2"
  local candidate
  while IFS= read -r candidate; do
    [[ -z "$candidate" ]] && continue
    if curl -fsSL --connect-timeout 8 --max-time 120 --retry 2 -o "$dest" "$candidate" 2>/dev/null; then
      if [[ -s "$dest" ]]; then
        echo "$candidate" >&3
        return 0
      fi
    fi
  done < <(gh_candidates "$url")
  return 1
}

# Выполнить remote bash-скрипт: скачать во временный файл и запустить
gh_run_bash() {
  local url="$1"
  shift
  local tmp
  tmp=$(mktemp /tmp/rn-remote.XXXXXX.sh)
  if ! gh_download "$url" "$tmp"; then
    rm -f "$tmp"
    warn "Не удалось скачать скрипт (прямая ссылка и зеркала): $url"
    return 1
  fi
  chmod +x "$tmp"
  set +e
  bash "$tmp" "$@"
  local rc=$?
  set -e
  rm -f "$tmp"
  return $rc
}

# bash <(curl ...) эквивалент с зеркалами + поддержка "@ install"
gh_pipe_bash() {
  local url="$1"
  shift
  gh_run_bash "$url" "$@"
}

###############################################################################
# OS / система
###############################################################################
require_root

. /etc/os-release
case "$ID" in
  ubuntu|debian) ;;
  *) err "Поддерживается только Ubuntu/Debian. Найдено: $ID" ;;
esac

ARCH=$(dpkg --print-architecture 2>/dev/null || echo amd64)
CODENAME=${VERSION_CODENAME:-}
CPU=$(nproc)
RAM_MB=$(free -m | awk '/^Mem:/ {print $2}')

if   (( CPU <= 1 )); then BACKLOG=4096
elif (( CPU <= 2 )); then BACKLOG=16384
elif (( CPU <= 4 )); then BACKLOG=32768
else                      BACKLOG=65535
fi

get_public_ip() {
  curl -fsS4 --max-time 3 https://api.ipify.org 2>/dev/null \
    || curl -fsS4 --max-time 3 https://ifconfig.me 2>/dev/null \
    || curl -fsS4 --max-time 3 https://icanhazip.com 2>/dev/null \
    || curl -fsS4 --max-time 3 https://ifconfig.io 2>/dev/null \
    || echo "неизвестен"
}

PUBLIC_IP=$(get_public_ip)
LOCAL_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')

###############################################################################
# UI — ровные колонки через пробелы (без \033[nG — ломается в Termius и др.)
###############################################################################

# Ширина строки в символах UTF-8 (не байтах)
str_width() {
  # ${#s} при LC_ALL=C.UTF-8 считает символы
  printf '%s' "${#1}"
}

# Обрезать/добить пробелами до ровно w символов
pad_right() {
  local s="$1" w="$2" n=${#1}
  if (( n > w )); then
    # bash substring по символам в UTF-8 locale
    s="${s:0:w}"
    n=$w
  fi
  printf '%s%*s' "$s" "$((w - n))" ''
}

show_header() {
  clear
  # Рамка без «центрирования по ${#}» — эмодзи ломают ширину в Termius
  echo -e "${CYAN}${BOLD}"
  echo "  ╔══════════════════════════════════════════════════════╗"
  echo "  ║  🚀 REMNANODE LAUNCHER  v${SCRIPT_VERSION}                     ║"
  echo "  ║  🛰️  Нода · 🎭 Selfsteal · ⚡ H2 · 🔒 Прокси · 🧪 Тесты ║"
  echo "  ╚══════════════════════════════════════════════════════╝"
  echo -e "${NC}"
  printf "  %b%-12s%b %s\n" "$WHITE" "💻 OS:" "$NC" "$PRETTY_NAME"
  printf "  %b%-12s%b %s\n" "$WHITE" "🧠 CPU/RAM:" "$NC" "${CPU} cores | ${RAM_MB} MB | ${ARCH}"
  printf "  %b%-12s%b %b%s%b\n" "$WHITE" "🌐 Public IP:" "$NC" "$CYAN" "$PUBLIC_IP" "$NC"
  printf "  %b%-12s%b %s\n" "$WHITE" "🏠 Local IP:" "$NC" "${LOCAL_IP:-n/a}"
  echo
}

# Статус без паддинга: [текст]
_badge() {
  local color="$1" text="$2"
  printf '%b[%s]%b' "$color" "$text" "$NC"
}

service_status_text() {
  local name="$1"
  case "$name" in
    remnanode)
      if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^remnanode$'; then
        echo "работает"
      elif [[ -f "$COMPOSE" ]] || [[ -d "$DIR" ]]; then
        echo "установлен"
      else
        echo "не установлен"
      fi
      ;;
    selfsteal)
      if docker ps --format '{{.Names}}' 2>/dev/null | grep -qE '(caddy|nginx).*selfsteal|selfsteal'; then
        echo "работает"
      elif [[ -d /opt/caddy ]] || [[ -d /opt/nginx-selfsteal ]] || command -v selfsteal >/dev/null 2>&1; then
        echo "установлен"
      else
        echo "не установлен"
      fi
      ;;
    warp)
      if command -v warp-cli >/dev/null 2>&1; then
        if warp-cli --accept-tos status 2>/dev/null | grep -qi connected; then
          echo "подключён"
        else
          echo "установлен"
        fi
      else
        echo "не установлен"
      fi
      ;;
    hysteria)
      if [[ -d /opt/hysteria/certs ]] \
        || { [[ -f "$COMPOSE" ]] && grep -qE 'hysteria|/opt/hysteria' "$COMPOSE" 2>/dev/null; }; then
        echo "настроено"
      else
        echo "не настроено"
      fi
      ;;
    xrayfix)
      if [[ -f "$COMPOSE" ]] && grep -q 'custom-xray/xray' "$COMPOSE" 2>/dev/null \
        && [[ -x "$CUSTOM_XRAY_DIR/xray" ]]; then
        echo "патч активен"
      elif [[ -x "$CUSTOM_XRAY_DIR/xray" ]]; then
        echo "ядро скачано"
      else
        echo "не применён"
      fi
      ;;
    mtproto)
      if systemctl is-active --quiet mtproto-proxy 2>/dev/null; then
        echo "работает"
      elif command -v mtbuddy >/dev/null 2>&1 \
        || systemctl list-unit-files mtproto-proxy.service 2>/dev/null | grep -q mtproto; then
        echo "установлен"
      else
        echo "не установлен"
      fi
      ;;
    swap)
      local sw sw_h
      sw=$(free -m | awk '/^Swap:/ {print $2}')
      if (( sw > 0 )); then
        sw_h=$(free -h | awk '/^Swap:/ {print $2}')
        echo "активен ${sw_h}"
      else
        echo "не создан"
      fi
      ;;
    ufw)
      if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi 'Status: active'; then
        echo "активен"
      elif command -v ufw >/dev/null 2>&1 && [[ -f /etc/ufw/ufw.conf ]]; then
        echo "выключен"
      else
        echo "не настроен"
      fi
      ;;
    tune)
      local cc
      cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")
      if [[ -f /etc/sysctl.d/99-remnanode.conf ]] && [[ "$cc" == "bbr" ]]; then
        echo "BBR включён"
      elif [[ -f /etc/sysctl.d/99-remnanode.conf ]]; then
        echo "частично"
      else
        echo "не применён"
      fi
      ;;
    node_cli)
      if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^remnanode$'; then
        echo "нода online"
      elif [[ -f "$COMPOSE" ]]; then
        echo "нода offline"
      elif [[ -x "$CLI_PATH" ]] || command -v remnanode >/dev/null 2>&1; then
        echo "только CLI"
      else
        echo "нет CLI"
      fi
      ;;
    *) echo "неизвестно" ;;
  esac
}

service_badge_color() {
  local name="$1" text
  text=$(service_status_text "$name")
  case "$text" in
    "работает"|"подключён"|"настроено"|"патч активен"|"BBR включён"|"нода online")
      _badge "$GREEN" "$text"
      ;;
    активен*)
      _badge "$GREEN" "$text"
      ;;
    "установлен"|"ядро скачано"|"частично"|"выключен"|"только CLI"|"нода offline")
      _badge "$YELLOW" "$text"
      ;;
    "не установлен"|"не настроено"|"не применён"|"не создан"|"не настроен"|"нет CLI"|"неизвестно")
      _badge "$RED" "$text"
      ;;
    *)
      _badge "$YELLOW" "$text"
      ;;
  esac
}

# Колонки:  😀 NN)  TITLE........  DESC................  [STATUS]
menu_item() {
  local icon="$1" num="$2" title="$3" desc="$4" badge="${5:-}"
  local num_s title_s desc_s

  num_s=$(pad_right "${num})" 4)
  title_s=$(pad_right "$title" 12)
  desc_s=$(pad_right "$desc" 20)

  printf '  %s %b%s%b %s  %b%s%b' "$icon" "$WHITE" "$num_s" "$NC" "$title_s" "$GRAY" "$desc_s" "$NC"
  if [[ -n "$badge" ]]; then
    printf '  '
    service_badge_color "$badge"
  fi
  printf '\n'
}

section() {
  echo
  printf '  %b%s%b\n' "${WHITE}${BOLD}" "$1" "$NC"
  printf '  %b%s%b\n' "$GRAY" "------------------------------------------------------------" "$NC"
}

###############################################################################
# Базовые пакеты (без SWAP/UFW — они отдельными пунктами)
###############################################################################
ensure_packages() {
  run_step "Обновление apt" "apt-get update -qq"
  run_step "Установка пакетов" \
"apt-get install -y -qq curl wget ca-certificates gnupg lsb-release \
 jq htop iftop ethtool irqbalance dnsutils unzip \
 ufw fail2ban || true"
}

###############################################################################
# Тюнинг производительности ноды (актуально на 2026)
###############################################################################
apply_performance_tuning() {
  info "⚙️  Применяем тюнинг производительности VPN-ноды (BBR / буферы / RPS)"

  run_step "Swappiness" \
"bash -c 'cat > /etc/sysctl.d/98-swap.conf <<EOF
vm.swappiness = 10
vm.vfs_cache_pressure = 50
EOF'"

  run_step "Тюнинг ядра (TCP BBR + UDP + conntrack)" \
"bash -c 'cat > /etc/sysctl.d/99-remnanode.conf <<EOF
# Congestion / qdisc — лучший дефолт для прокси/VPN в 2026
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 60
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_max_tw_buckets = 1440000
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_moderate_rcvbuf = 1

# Очереди и backlog
net.core.somaxconn = $BACKLOG
net.core.netdev_max_backlog = $BACKLOG
net.ipv4.tcp_max_syn_backlog = $BACKLOG
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 3

# Буферы (критично для Reality / Hysteria2 / высоких скоростей)
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.optmem_max = 65536
net.ipv4.tcp_rmem = 4096 131072 67108864
net.ipv4.tcp_wmem = 4096 131072 67108864
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
net.ipv4.udp_mem = 65536 131072 262144
net.ipv4.ip_local_port_range = 1024 65535

# Conntrack
net.netfilter.nf_conntrack_max = 2097152
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.netfilter.nf_conntrack_udp_timeout = 30
net.netfilter.nf_conntrack_udp_timeout_stream = 180

# Forwarding / базовая защита
net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.log_martians = 0

fs.file-max = 2097152
fs.nr_open = 2097152
vm.max_map_count = 262144
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
EOF
modprobe nf_conntrack 2>/dev/null || true
echo nf_conntrack > /etc/modules-load.d/nf_conntrack.conf
echo 524288 > /sys/module/nf_conntrack/parameters/hashsize 2>/dev/null || true
# BBR модуль
modprobe tcp_bbr 2>/dev/null || true
echo tcp_bbr > /etc/modules-load.d/bbr.conf 2>/dev/null || true
sysctl --system >/dev/null 2>&1 || sysctl -p /etc/sysctl.d/99-remnanode.conf >/dev/null 2>&1 || true'"

  run_step "Системные лимиты (nofile)" \
"bash -c 'cat > /etc/security/limits.d/99-remnanode.conf <<EOF
* soft nofile 1048576
* hard nofile 1048576
* soft nproc  unlimited
* hard nproc  unlimited
root soft nofile 1048576
root hard nofile 1048576
EOF
mkdir -p /etc/systemd/system.conf.d
cat > /etc/systemd/system.conf.d/limits.conf <<EOF
[Manager]
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=infinity
EOF'"

  run_step "CPU governor: performance" \
"bash -c 'for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
  [ -w \"\$cpu\" ] && echo performance > \"\$cpu\" || true
done
cat > /etc/systemd/system/cpu-performance.service <<EOF
[Unit]
Description=Set CPU governor to performance
After=multi-user.target
[Service]
Type=oneshot
ExecStart=/bin/bash -c \"for c in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do [ -w \\\$c ] && echo performance > \\\$c || true; done\"
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload && systemctl enable cpu-performance.service >/dev/null 2>&1 || true'"

  if (( CPU > 1 )); then
    run_step "RPS / IRQ balance" \
"bash -c 'IFACE=\$(ip route show default | awk \"/default/ {print \\\$5; exit}\")
if [ -n \"\$IFACE\" ]; then
  MASK=\$(printf \"%x\" \$(( (1 << $CPU) - 1 )))
  for q in /sys/class/net/\$IFACE/queues/rx-*/rps_cpus; do
    [ -w \$q ] && echo \$MASK > \$q || true
  done
  echo 32768 > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null || true
  for q in /sys/class/net/\$IFACE/queues/rx-*/rps_flow_cnt; do
    [ -w \$q ] && echo 4096 > \$q || true
  done
  # ethool offloads где безопасно
  ethtool -K \$IFACE gro on gso on tso on 2>/dev/null || true
fi
cat > /etc/systemd/system/rps-tune.service <<EOF
[Unit]
Description=RPS network tuning
After=network-online.target
[Service]
Type=oneshot
ExecStart=/bin/bash -c \"IFACE=\\\$(ip route show default | awk \\\"/default/ {print \\\\\\\$5; exit}\\\"); MASK=\\\$(printf %x \\\$(( (1 << $CPU) - 1 ))); for q in /sys/class/net/\\\$IFACE/queues/rx-*/rps_cpus; do [ -w \\\$q ] && echo \\\$MASK > \\\$q; done\"
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload && systemctl enable rps-tune.service >/dev/null 2>&1 || true
systemctl enable irqbalance >/dev/null 2>&1 && systemctl restart irqbalance || true'"
  fi

  # Предпочитать IPv4 (часто чинит docker pull на VPS с битым IPv6)
  if ! grep -q '^precedence ::ffff:0:0/96' /etc/gai.conf 2>/dev/null; then
    if grep -q '^#precedence ::ffff:0:0/96' /etc/gai.conf 2>/dev/null; then
      sed -i 's/^#precedence ::ffff:0:0\/96.*/precedence ::ffff:0:0\/96  100/' /etc/gai.conf
    else
      echo 'precedence ::ffff:0:0/96  100' >> /etc/gai.conf
    fi
  fi

  ok "Тюнинг производительности применён"
}

###############################################################################
# Docker
###############################################################################
install_docker() {
  if command -v docker >/dev/null 2>&1; then
    info "Docker уже установлен"
  else
    run_step "Docker репозиторий" \
"install -m 0755 -d /etc/apt/keyrings && \
 curl -fsSL https://download.docker.com/linux/${ID}/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg && \
 chmod a+r /etc/apt/keyrings/docker.gpg && \
 echo \"deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${ID} ${CODENAME} stable\" > /etc/apt/sources.list.d/docker.list && \
 apt-get update -qq"

    run_step "Установка Docker" \
"apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin && \
 systemctl enable docker && systemctl start docker"
  fi

  run_step "Docker daemon config" \
"bash -c 'mkdir -p /etc/docker && cat > /etc/docker/daemon.json <<EOF
{
  \"log-driver\": \"json-file\",
  \"log-opts\": {
    \"max-size\": \"10m\",
    \"max-file\": \"3\"
  },
  \"live-restore\": true,
  \"userland-proxy\": false,
  \"default-ulimits\": {
    \"nofile\": {
      \"Name\": \"nofile\",
      \"Hard\": 1048576,
      \"Soft\": 1048576
    }
  }
}
EOF
systemctl restart docker'"
}

###############################################################################
# Установка CLI-панели (команда remnanode)
###############################################################################
install_self_cli() {
  local src="${BASH_SOURCE[0]:-$0}"
  mkdir -p "$DIR"
  if [[ "$(readlink -f "$src" 2>/dev/null || echo "$src")" != "$(readlink -f "$LAUNCHER_PATH" 2>/dev/null || echo "$LAUNCHER_PATH")" ]]; then
    cp -f "$src" "$LAUNCHER_PATH" 2>/dev/null || true
    chmod +x "$LAUNCHER_PATH" 2>/dev/null || true
  fi
  ln -sfn "$LAUNCHER_PATH" "$CLI_PATH"
  chmod +x "$CLI_PATH" 2>/dev/null || true
  ok "📡 Команда управления: ${CYAN}remnanode${NC}"
}

###############################################################################
# REMNANODE — установка (своя стабильная, не из DigneZzZ)
###############################################################################
is_remnanode_installed() { [[ -f "$COMPOSE" ]] || [[ -d "$DIR" ]]; }
is_remnanode_up() { docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^remnanode$'; }

remove_existing_remnanode() {
  warn "Найдена существующая установка Remnanode."
  echo
  [[ -d "$DIR" ]] && echo -e "    • 📁 Директория: ${GRAY}$DIR${NC}"
  if is_remnanode_up; then
    echo -e "    • 🐳 Контейнер: ${GRAY}remnanode${NC}"
  fi
  echo
  local ans=""
  ask_yes_no "❓ Удалить старую установку перед продолжением?" ans N
  if [[ ! "$ans" =~ ^[Yy]$ ]]; then
    warn "Установка отменена."
    return 1
  fi
  echo
  info "🧹 Удаляю старую установку…"
  if [[ -f "$COMPOSE" ]]; then
    run_step "Остановка контейнера" "cd '$DIR' && docker compose down -v 2>/dev/null || true"
  fi
  docker rm -f remnanode 2>/dev/null || true
  if [[ -d "$DIR" ]]; then
    run_step "Удаление файлов" "rm -rf '$DIR'"
  fi
  ok "Старая установка удалена"
  echo
  return 0
}

install_remnanode() {
  show_header
  echo -e "${WHITE}${BOLD}  🚀 Установка Remnanode${NC}"
  hline 56
  echo
  info "Стабильная установка ноды Remnawave."
  info "UFW / SWAP — отдельные пункты меню, с нодой не ставятся."
  echo

  if is_remnanode_installed; then
    remove_existing_remnanode || return 0
  fi

  echo -e "  ${WHITE}${BOLD}📝 Параметры ноды${NC}"
  hline 40
  local PANEL_IP="" NODE_PORT="" XTLS_API_PORT=""
  ask "🌐 IP панели Remnawave" PANEL_IP "$PANEL_IP_DEFAULT"
  [[ "$PANEL_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || err "Некорректный IP: $PANEL_IP"

  ask "🔌 NODE_PORT" NODE_PORT "3000"
  [[ "$NODE_PORT" =~ ^[0-9]+$ ]] || err "NODE_PORT должен быть числом"

  ask "🔗 XTLS_API_PORT" XTLS_API_PORT "61000"

  echo
  info "🔑 SECRET_KEY скопируйте из панели Remnawave → Nodes → Create"
  local K1="" K2=""
  while true; do
    ask_secret "SECRET_KEY" K1
    ask_secret "Повтор SECRET_KEY" K2
    [[ -z "$K1" ]] && { warn "Пусто — введите ключ"; continue; }
    [[ "$K1" != "$K2" ]] && { warn "Не совпадает — ещё раз"; continue; }
    break
  done
  ok "Ключ принят (${#K1} символов)"
  echo

  echo -e "  ${WHITE}${BOLD}⚙️  Установка (шаги видны ниже)${NC}"
  hline 40
  info "1️⃣  Базовые пакеты"
  ensure_packages
  info "2️⃣  Тюнинг производительности"
  apply_performance_tuning
  info "3️⃣  Docker"
  install_docker
  info "4️⃣  Конфиг и запуск ноды"

  mkdir -p "$DIR"

  cat > "$ENV_FILE" <<EOF
### NODE ###
NODE_PORT=${NODE_PORT}

### XRAY ###
SECRET_KEY=${K1}

### Internal ###
XTLS_API_PORT=${XTLS_API_PORT}
EOF
  chmod 600 "$ENV_FILE"
  ok ".env сохранён"

  cat > "$COMPOSE" <<EOF
services:
  remnanode:
    image: remnawave/node:latest
    container_name: remnanode
    hostname: remnanode
    network_mode: host
    restart: always
    env_file:
      - .env
    cap_add:
      - NET_ADMIN
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    volumes:
      - /dev/shm:/dev/shm
EOF
  chmod 600 "$COMPOSE"
  ok "docker-compose.yml создан"

  # Сохраним IP панели для будущего UFW
  echo "$PANEL_IP" > "$DIR/.panel_ip"
  echo "$NODE_PORT" > "$DIR/.node_port"

  cd "$DIR"
  info "5️⃣  Скачивание образа (может занять время)…"
  run_step "Pull образа remnawave/node" "docker compose pull"
  info "6️⃣  Запуск контейнера"
  run_step "Запуск контейнера" "docker compose down >/dev/null 2>&1 || true; docker compose up -d"

  echo -n "  ⏳ Жду готовности контейнера"
  local i
  for i in 1 2 3 4 5 6; do
    sleep 1
    echo -n "."
    is_remnanode_up && break
  done
  echo

  if ! is_remnanode_up; then
    echo -e "  ${RED}Логи контейнера:${NC}"
    docker logs --tail 40 remnanode 2>&1 | sed 's/^/    /' || true
    err "Контейнер не запустился. Логи: docker logs remnanode"
  fi
  ok "Контейнер remnanode запущен"

  if ss -tlnp 2>/dev/null | grep -q ":${NODE_PORT} "; then
    ok "Нода слушает порт ${NODE_PORT}"
  else
    warn "Порт ${NODE_PORT} пока может подниматься — проверьте через пару секунд"
  fi

  info "7️⃣  Установка команды управления"
  install_self_cli

  echo
  echo -e "${GREEN}${BOLD}"
  echo "  ╔════════════════════════════════════════════════════╗"
  echo "  ║           ✅  REMNANODE УСТАНОВЛЕН                 ║"
  echo "  ╚════════════════════════════════════════════════════╝"
  echo -e "${NC}"
  echo -e "  🌐 Public IP:   ${CYAN}${PUBLIC_IP}${NC}"
  echo -e "  🖥️  Панель IP:   ${PANEL_IP}"
  echo -e "  🔌 NODE_PORT:   ${NODE_PORT}"
  echo -e "  🔗 XTLS_API:    ${XTLS_API_PORT}"
  echo -e "  📡 Управление:  ${CYAN}remnanode${NC}"
  echo -e "  📋 Лог:         ${GRAY}${LOG}${NC}"
  echo
  echo -e "  ${YELLOW}💡 Рекомендуется отдельно:${NC}"
  echo -e "    • 🛡️  UFW — ограничить NODE_PORT только IP панели"
  echo -e "    • 💾 SWAP — если мало RAM"
  echo -e "    • ⚡ Hysteria2 — если нужен UDP-протокол"
  echo
}

###############################################################################
# SELFSTEAL — флоу как у DigneZzZ: @ install
###############################################################################
install_selfsteal() {
  show_header
  echo -e "${WHITE}${BOLD}  🎭 Установка Selfsteal (Reality-маскировка)${NC}"
  hline 56
  echo
  info "🎭 Официальный установщик DigneZzZ (Caddy / Nginx)."
  echo -e "  ${GRAY}Источник: github.com/DigneZzZ/remnawave-scripts${NC}"
  echo

  if ! command -v docker >/dev/null 2>&1; then
    info "Docker не найден — устанавливаем"
    ensure_packages
    install_docker
  fi

  echo -e "  ${WHITE}🌐 Веб-сервер:${NC}"
  echo -e "    ${WHITE}1)${NC} 🟩 Caddy   ${GRAY}(проще, авто-SSL)${NC}"
  echo -e "    ${WHITE}2)${NC} 🟧 Nginx   ${GRAY}(Unix socket + acme.sh)${NC}"
  echo
  ask "🌐 Выбор веб-сервера" ws_choice "1"

  local ws_flag="--caddy"
  case "$ws_choice" in
    2) ws_flag="--nginx" ;;
    *) ws_flag="--caddy" ;;
  esac

  echo
  info "Запуск: bash <(curl …/selfsteal.sh) @ install ${ws_flag}"
  echo

  # Аналог: bash <(curl -Ls …) @ install --caddy|--nginx
  set +e
  gh_pipe_bash "$SELFSTEAL_RAW" @ install "$ws_flag"
  local rc=$?
  set -e
  if [[ $rc -eq 0 ]]; then
    echo
    echo -e "${GREEN}${BOLD}"
    echo "  ╔════════════════════════════════════════════════════╗"
    echo "  ║        ✅  SELFSTEAL УСТАНОВЛЕН                   ║"
    echo "  ╚════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo -e "  Управление:  ${CYAN}selfsteal${NC}"
    echo -e "  Шаблоны:     ${CYAN}selfsteal template${NC}"
    echo -e "  Логи:        ${CYAN}selfsteal logs${NC}"
    echo
  else
    warn "Установка Selfsteal завершилась с кодом $rc"
  fi
}

###############################################################################
# HYSTERIA2 — через h2-script (без установки ноды из того скрипта)
###############################################################################
install_hysteria2() {
  show_header
  echo -e "${WHITE}${BOLD}  ⚡ Автонастройка Hysteria2${NC}"
  hline 56
  echo
  info "Скрипт Origamidnd/h2-script: certbot, сертификаты, volume в remnanode, BBR."
  echo -e "  ${GRAY}https://github.com/Origamidnd/h2-script${NC}"
  echo
  warn "⚠️  Нода Remnanode уже должна быть установлена."
  echo

  if ! is_remnanode_installed; then
    warn "Сначала установите Remnanode (пункт меню «Remnanode»)."
    return 1
  fi

  ensure_packages

  echo
  info "Запуск setup.sh из h2-script (с зеркалами GitHub)…"
  echo

  set +e
  gh_pipe_bash "$H2_RAW"
  local rc=$?
  set -e
  if [[ $rc -eq 0 ]]; then
    ok "Hysteria2 настроен"
    echo
    echo -e "  ${WHITE}✨ Дополнительно:${NC}"
    echo -e "    • Привяжите Hysteria2 config profile в панели Remnawave"
    echo -e "    • Порт 80/tcp нужен только для ACME — можно закрыть после выпуска"
    echo
    echo -e "  ${YELLOW}Если онлайн в ноде не отображается (ядро 26.3.x) —${NC}"
    echo -e "  ${YELLOW}используйте пункт «Фикс онлайна Hysteria2» (благодарность @markrouting).${NC}"
    echo
  else
    warn "Настройка Hysteria2 завершилась с кодом $rc"
  fi
}

###############################################################################
# Фикс онлайна Hysteria2 — custom Xray (@markrouting)
###############################################################################
fix_hysteria2_online() {
  show_header
  echo -e "${WHITE}${BOLD}  🔧 Фикс онлайна Hysteria2 (custom Xray)${NC}"
  hline 56
  echo
  echo -e "  ${GRAY}Проблема:${NC} с ядром ~26.3.27 Remna не видит онлайн и не считает трафик."
  echo -e "  ${GRAY}Решение:${NC}  прокинуть более новое ядро Xray в контейнер ноды."
  echo
  echo -e "  ${CYAN}🙏 Способ описал @markrouting — благодарите его.${NC}"
  echo
  echo -e "  ${WHITE}1)${NC} ✅ Применить патч (скачать Xray ${XRAY_VERSION_DEFAULT} и смонтировать)"
  echo -e "  ${WHITE}2)${NC} ↩️  Откатить патч (убрать volume, вернуть штатное ядро)"
  echo -e "  ${WHITE}3)${NC} 🔍 Проверить версию Xray в контейнере"
  echo -e "  ${GRAY}0)${NC} 🔙 Назад"
  echo
  ask_choice ch

  case "$ch" in
    1) apply_custom_xray_patch ;;
    2) rollback_custom_xray_patch ;;
    3)
      if is_remnanode_up; then
        docker exec remnanode xray version 2>/dev/null || warn "Не удалось выполнить xray version"
      else
        warn "Контейнер remnanode не запущен"
      fi
      ;;
    *) return 0 ;;
  esac
}

apply_custom_xray_patch() {
  if ! [[ -f "$COMPOSE" ]]; then
    err "Remnanode не установлен"
  fi

  ask "📦 Версия Xray" XV "$XRAY_VERSION_DEFAULT"
  [[ "$XV" == v* ]] || XV="v${XV}"

  local arch_zip="Xray-linux-64.zip"
  case "$(uname -m)" in
    aarch64|arm64) arch_zip="Xray-linux-arm64-v8a.zip" ;;
    x86_64|amd64)  arch_zip="Xray-linux-64.zip" ;;
    *) warn "Архитектура $(uname -m) — пробуем Xray-linux-64.zip" ;;
  esac

  mkdir -p "$CUSTOM_XRAY_DIR"
  cd "$CUSTOM_XRAY_DIR"

  ensure_packages
  command -v unzip >/dev/null || apt-get install -y -qq unzip

  local zip_url="${XRAY_RELEASE_BASE}/${XV}/${arch_zip}"
  info "Скачивание ${XV} / ${arch_zip} (с зеркалами)…"
  if ! gh_download "$zip_url" "${CUSTOM_XRAY_DIR}/${arch_zip}"; then
    err "Не удалось скачать Xray: $zip_url"
  fi

  run_step "Распаковка Xray" "cd $CUSTOM_XRAY_DIR && unzip -o ${arch_zip}"
  [[ -x "$CUSTOM_XRAY_DIR/xray" ]] || chmod +x "$CUSTOM_XRAY_DIR/xray"
  ok "Бинарник: $CUSTOM_XRAY_DIR/xray"

  cp "$COMPOSE" "${COMPOSE}.bak.$(date +%Y%m%d-%H%M%S)"

  local mount_line="      - '${CUSTOM_XRAY_DIR}/xray:/usr/local/bin/xray:ro'"
  if grep -q 'custom-xray/xray:/usr/local/bin/xray' "$COMPOSE"; then
    info "Volume уже есть в docker-compose.yml"
  else
    python3 - "$COMPOSE" "$CUSTOM_XRAY_DIR" <<'PY'
import sys, re
path, xdir = sys.argv[1], sys.argv[2]
mount = f"      - '{xdir}/xray:/usr/local/bin/xray:ro'\n"
with open(path) as f:
    content = f.read()
if "custom-xray/xray:/usr/local/bin/xray" in content:
    sys.exit(0)
# Если есть секция volumes — вставляем сразу после строки volumes:
m = re.search(r'(^[ \t]*volumes:[ \t]*\n)', content, re.M)
if m:
    pos = m.end()
    content = content[:pos] + mount + content[pos:]
else:
    # Добавляем секцию в конец сервиса remnanode
    if not content.endswith("\n"):
        content += "\n"
    content += "    volumes:\n" + mount
with open(path, "w") as f:
    f.write(content)
PY
    ok "Volume добавлен в docker-compose.yml"
  fi

  run_step "Перезапуск ноды" "cd $DIR && docker compose down && docker compose up -d"
  sleep 3
  echo
  info "Версия Xray в контейнере:"
  docker exec remnanode xray version 2>/dev/null || warn "Проверьте вручную: docker exec -it remnanode xray version"
  echo
  ok "✅ Патч применён. Если не помогло — откатите через пункт 2."
}

rollback_custom_xray_patch() {
  if ! [[ -f "$COMPOSE" ]]; then
    err "Remnanode не установлен"
  fi
  cp "$COMPOSE" "${COMPOSE}.bak.$(date +%Y%m%d-%H%M%S)"
  # Удаляем строки с custom-xray mount
  sed -i "\|custom-xray/xray:/usr/local/bin/xray|d" "$COMPOSE"
  ok "Строка volume удалена"
  run_step "Перезапуск ноды" "cd $DIR && docker compose down && docker compose up -d"
  sleep 2
  info "Текущая версия Xray:"
  docker exec remnanode xray version 2>/dev/null || true
  ok "Откат выполнен — используется ядро из образа контейнера"
}

###############################################################################
# WARP
###############################################################################
install_warp() {
  show_header
  echo -e "${WHITE}${BOLD}  ☁️  Cloudflare WARP (SOCKS5)${NC}"
  hline 56
  echo
  info "Исходящий IP Cloudflare — outbound в XRay для ChatGPT / Spotify и т.п."
  echo

  if command -v warp-cli >/dev/null 2>&1; then
    warn "WARP уже установлен: $(warp-cli --version 2>/dev/null | head -1)"
    ask_yes_no "🔄 Переустановить?" ans N
    if [[ ! "$ans" =~ ^[Yy]$ ]]; then
      return 0
    fi
    run_step "Удаление WARP" \
"systemctl stop warp-svc warp-auto 2>/dev/null || true
warp-cli --accept-tos disconnect 2>/dev/null || true
apt-get remove -y --purge cloudflare-warp 2>/dev/null || true
rm -f /etc/apt/sources.list.d/cloudflare-client.list /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
rm -f /etc/systemd/system/warp-auto.service /usr/local/bin/warp-fix-network.sh
systemctl daemon-reload"
  fi

  ensure_packages

  local warp_codename="$CODENAME"
  case "$CODENAME" in
    bullseye|bookworm|jammy|noble) ;;
    *) warn "Codename '$CODENAME' — используем noble"; warp_codename="noble" ;;
  esac

  run_step "Репозиторий Cloudflare" \
"curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | \
 gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg && \
 echo \"deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ ${warp_codename} main\" > /etc/apt/sources.list.d/cloudflare-client.list && \
 apt-get update -qq"

  run_step "Установка cloudflare-warp" "apt-get install -y -qq cloudflare-warp"

  # /32 VPS fix
  local iface prefix
  iface=$(ip route show default 2>/dev/null | awk '{print $5}' | head -1)
  prefix=$(ip -4 addr show dev "$iface" 2>/dev/null | awk '/inet / {split($2,a,"/"); print a[2]}' | head -1)
  if [[ "$prefix" == "32" ]] || [[ -z "$prefix" ]]; then
    info "VPS /32 fix на $iface"
    ip addr add 172.30.255.1/24 dev "$iface" 2>/dev/null || true
    systemctl restart warp-svc &>/dev/null || true
    sleep 5
  fi

  sleep 3
  run_step "Регистрация WARP" \
"warp-cli --accept-tos registration delete >/dev/null 2>&1 || true
warp-cli --accept-tos registration new >/dev/null 2>&1 || (sleep 3 && warp-cli --accept-tos registration new >/dev/null 2>&1) || true"

  run_step "Режим SOCKS5 :${WARP_PORT}" \
"warp-cli --accept-tos mode proxy >/dev/null 2>&1 || true
warp-cli --accept-tos proxy port $WARP_PORT >/dev/null 2>&1 || true
warp-cli --accept-tos connect >/dev/null 2>&1 || true"

  cat > /usr/local/bin/warp-fix-network.sh <<'FIXSCRIPT'
#!/bin/bash
iface=$(ip route show default 2>/dev/null | awk '{print $5}' | head -1)
[ -z "$iface" ] && exit 0
prefix=$(ip -4 addr show dev "$iface" 2>/dev/null | awk '/inet / {split($2,a,"/"); print a[2]}' | head -1)
if [ "$prefix" = "32" ] || [ -z "$prefix" ]; then
    ip addr add 172.30.255.1/24 dev "$iface" 2>/dev/null || true
    systemctl restart warp-svc
    sleep 5
fi
FIXSCRIPT
  chmod +x /usr/local/bin/warp-fix-network.sh

  cat > /etc/systemd/system/warp-auto.service <<'SYSTEMD'
[Unit]
Description=Cloudflare WARP auto-connect
After=network.target warp-svc.service
Requires=warp-svc.service
[Service]
Type=oneshot
ExecStartPre=/usr/local/bin/warp-fix-network.sh
ExecStart=/usr/bin/warp-cli --accept-tos connect
RemainAfterExit=yes
ExecStop=/usr/bin/warp-cli --accept-tos disconnect
[Install]
WantedBy=multi-user.target
SYSTEMD

  systemctl daemon-reload
  systemctl enable warp-auto >/dev/null 2>&1 || true

  local warp_ip
  warp_ip=$(curl -s --max-time 10 --socks5 "127.0.0.1:${WARP_PORT}" https://cloudflare.com/cdn-cgi/trace 2>/dev/null | grep "^ip=" | cut -d= -f2)

  echo
  echo -e "${GREEN}${BOLD}"
  echo "  ╔════════════════════════════════════════════════════╗"
  echo "  ║        ✅  WARP УСТАНОВЛЕН                        ║"
  echo "  ╚════════════════════════════════════════════════════╝"
  echo -e "${NC}"
  echo -e "  SOCKS5:  ${CYAN}127.0.0.1:${WARP_PORT}${NC}"
  [[ -n "$warp_ip" ]] && echo -e "  CF IP:   ${CYAN}${warp_ip}${NC}"
  echo -e "  Статус:  ${CYAN}warp-cli status${NC}"
  echo
}

###############################################################################
# Telegram MTProto — mtproto.zig / mtbuddy
###############################################################################
install_mtproto() {
  show_header
  echo -e "${WHITE}${BOLD}  ✈️  Прокси Telegram (mtproto.zig)${NC}"
  hline 56
  echo
  info "Лёгкий MTProto-прокси со маскировкой под HTTPS (TLS 1.3)."
  echo -e "  ${GRAY}https://github.com/sleep3r/mtproto.zig${NC}"
  echo
  echo -e "  ${WHITE}1)${NC} 📦 Установить mtbuddy (bootstrap) и запустить мастер"
  echo -e "  ${WHITE}2)${NC} ⚡ Быстрая установка (порт / домен)"
  echo -e "  ${WHITE}3)${NC} 🎛️  Управление: mtbuddy --interactive"
  echo -e "  ${WHITE}4)${NC} 📌 Статус сервиса"
  echo -e "  ${GRAY}0)${NC} 🔙 Назад"
  echo
  ask_choice ch

  case "$ch" in
    1)
      info "Скачивание bootstrap.sh (с зеркалами)…"
      if gh_pipe_bash "$MTPROTO_BOOTSTRAP_RAW"; then
        ok "mtbuddy установлен"
        echo
        info "Запуск интерактивного мастера…"
        if command -v mtbuddy >/dev/null 2>&1; then
          mtbuddy --interactive || true
        else
          warn "mtbuddy не найден в PATH — перелогиньтесь или проверьте /usr/local/bin"
        fi
      else
        err "Bootstrap mtproto.zig не удался"
      fi
      ;;
    2)
      if ! command -v mtbuddy >/dev/null 2>&1; then
        info "Сначала ставим mtbuddy…"
        gh_pipe_bash "$MTPROTO_BOOTSTRAP_RAW" || err "Bootstrap не удался"
      fi
      ask "🔌 Порт" mp_port "443"
      ask "🌐 Домен-маскировка (например rutube.ru)" mp_domain
      [[ -z "$mp_domain" ]] && { warn "Домен обязателен"; return 0; }
      ask "👤 Имя пользователя" mp_user "user"
      echo
      mtbuddy install --port "$mp_port" --domain "$mp_domain" --user "$mp_user" --yes || warn "Установка вернула ошибку"
      ;;
    3)
      command -v mtbuddy >/dev/null 2>&1 || { warn "mtbuddy не установлен"; return 0; }
      mtbuddy --interactive || true
      ;;
    4)
      systemctl status mtproto-proxy --no-pager 2>/dev/null || warn "Сервис mtproto-proxy не найден"
      command -v mtbuddy >/dev/null 2>&1 && mtbuddy status 2>/dev/null || true
      ;;
    *) return 0 ;;
  esac
}

###############################################################################
# SWAP — отдельная кнопка с навигацией
###############################################################################
setup_swap() {
  show_header
  echo -e "${WHITE}${BOLD}  💾 Управление SWAP${NC}"
  hline 56
  echo
  echo -e "  ${WHITE}📊 Текущее состояние:${NC}"
  free -h | sed 's/^/    /'
  echo
  if [[ -f /swapfile ]]; then
    local sz
    sz=$(du -h /swapfile 2>/dev/null | awk '{print $1}')
    echo -e "  Файл: ${CYAN}/swapfile${NC} (${sz})"
    swapon --show 2>/dev/null | sed 's/^/    /' || true
  else
    echo -e "  Файл ${GRAY}/swapfile${NC}: не создан"
  fi
  echo
  echo -e "  ${WHITE}1)${NC} 💾 Создать / включить SWAP 1 ГБ  ${GRAY}(рекомендуется)${NC}"
  echo -e "  ${WHITE}2)${NC} 💾 Создать / включить SWAP 2 ГБ"
  echo -e "  ${WHITE}3)${NC} 💾 Создать / включить SWAP 4 ГБ"
  echo -e "  ${WHITE}4)${NC} ✏️  Свой размер (ГБ)"
  echo -e "  ${WHITE}5)${NC} 🗑️  Отключить и удалить /swapfile"
  echo -e "  ${WHITE}6)${NC} 📊 Показать free -h"
  echo -e "  ${GRAY}0)${NC} 🔙 Назад"
  echo
  ask_choice ch

  local size_gb=""
  case "$ch" in
    1) size_gb=1 ;;
    2) size_gb=2 ;;
    3) size_gb=4 ;;
    4)
      ask "📏 Размер в ГБ" size_gb "1"
      [[ "$size_gb" =~ ^[0-9]+$ ]] || { warn "Нужно число"; return 0; }
      ;;
    5)
      swapoff /swapfile 2>/dev/null || true
      sed -i '\|^/swapfile\s|d' /etc/fstab 2>/dev/null || true
      rm -f /swapfile
      ok "SWAP удалён"
      free -h
      return 0
      ;;
    6) free -h; return 0 ;;
    *) return 0 ;;
  esac

  info "Создаём SWAP ${size_gb}G…"
  # Супер-команда v2.0 (адаптирована под размер)
  swapoff /swapfile 2>/dev/null || true
  rm -f /swapfile
  if ! fallocate -l "${size_gb}G" /swapfile 2>/dev/null; then
    dd if=/dev/zero of=/swapfile bs=1M count=$((size_gb * 1024)) status=progress
  fi
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  grep -qE '^/swapfile\s' /etc/fstab || echo '/swapfile none swap sw 0 0' | tee -a /etc/fstab >/dev/null

  # Мягкий swappiness
  cat > /etc/sysctl.d/98-swap.conf <<EOF
vm.swappiness = 10
vm.vfs_cache_pressure = 50
EOF
  sysctl -p /etc/sysctl.d/98-swap.conf >/dev/null 2>&1 || true

  echo
  ok "💾 SWAP ${size_gb}G активен"
  echo
  free -h
  echo
  info "В строке Swap должно быть ~${size_gb}.0Gi — защита от OOM."
}

###############################################################################
# UFW — отдельный пункт (не вместе с нодой)
###############################################################################
setup_ufw() {
  show_header
  echo -e "${WHITE}${BOLD}  🛡️  Защита UFW и порты${NC}"
  hline 56
  echo
  info "Настраивается отдельно от установки ноды — по желанию."
  echo

  ensure_packages
  command -v ufw >/dev/null || apt-get install -y -qq ufw

  local panel_ip node_port ssh_port
  panel_ip=$(cat "$DIR/.panel_ip" 2>/dev/null || echo "$PANEL_IP_DEFAULT")
  node_port=$(cat "$DIR/.node_port" 2>/dev/null || echo "3000")
  ssh_port=$(ss -tlnp 2>/dev/null | awk '/sshd/ {print $4}' | sed 's/.*://' | head -1)
  ssh_port=${ssh_port:-22}

  echo -e "  ${WHITE}1)${NC} 🛡️  Быстрая защита ноды (SSH + NODE_PORT с панели + 443)"
  echo -e "  ${WHITE}2)${NC} 🧙 Мастер настройки портов"
  echo -e "  ${WHITE}3)${NC} 🔓 Открыть порт"
  echo -e "  ${WHITE}4)${NC} 🔒 Закрыть порт"
  echo -e "  ${WHITE}5)${NC} 📋 Статус UFW"
  echo -e "  ${WHITE}6)${NC} ⛔ Отключить UFW"
  echo -e "  ${WHITE}7)${NC} 🚨 Fail2Ban (базовый jail для SSH)"
  echo -e "  ${GRAY}0)${NC} 🔙 Назад"
  echo
  ask_choice ch

  case "$ch" in
    1)
      ask "🌐 IP панели" panel_ip "$panel_ip"
      ask "🔌 NODE_PORT" node_port "$node_port"
      ask "🔑 SSH порт" ssh_port "$ssh_port"
      ask_yes_no "Открыть 443/tcp+udp (Reality/Hysteria)?" p443 Y
      ask_yes_no "Открыть 80/tcp (ACME/Selfsteal)?" p80 N

      ufw --force reset >/dev/null 2>&1 || true
      ufw default deny incoming
      ufw default allow outgoing
      ufw allow "${ssh_port}/tcp" comment 'SSH'
      ufw allow from "$panel_ip" to any port "$node_port" proto tcp comment 'Remnanode panel'
      if [[ "$p443" =~ ^[Yy]$ ]]; then
        ufw allow 443/tcp comment 'Reality'
        ufw allow 443/udp comment 'Hysteria2'
      fi
      if [[ "$p80" =~ ^[Yy]$ ]]; then
        ufw allow 80/tcp comment 'ACME/HTTP'
      fi
      ufw --force enable
      ok "🛡️  UFW включён"
      ufw status numbered
      echo "$panel_ip" > "$DIR/.panel_ip" 2>/dev/null || true
      echo "$node_port" > "$DIR/.node_port" 2>/dev/null || true
      ;;
    2)
      echo
      ask "🔑 SSH порт" ssh_port "$ssh_port"
      ufw allow "${ssh_port}/tcp" comment 'SSH'
      while true; do
        ask "➕ Порт (8443/tcp или 443/udp, пусто = готово)" pr
        [[ -z "$pr" ]] && break
        ufw allow "$pr" || warn "Не удалось: $pr"
      done
      ask_yes_no "Включить UFW сейчас?" en Y
      [[ "$en" =~ ^[Yy]$ ]] && ufw --force enable
      ufw status numbered
      ;;
    3)
      ask "🔓 Порт (напр. 8443/tcp)" pr
      [[ -n "$pr" ]] && ufw allow "$pr" && ok "Открыт $pr"
      ;;
    4)
      ufw status numbered
      ask "🗑️  Номер правила для удаления" num
      [[ -n "$num" ]] && ufw --force delete "$num"
      ;;
    5) ufw status verbose ;;
    6) ufw disable; ok "UFW выключен" ;;
    7)
      apt-get install -y -qq fail2ban
      cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 24h
findtime = 10m
maxretry = 4
[sshd]
enabled = true
port = ${ssh_port}
EOF
      systemctl enable fail2ban >/dev/null 2>&1
      systemctl restart fail2ban
      ok "Fail2Ban настроен для SSH"
      ;;
    *) return 0 ;;
  esac
}

###############################################################################
# ТЕСТЫ — свои, без внешних bash-скриптов
###############################################################################

# Установка Ookla CLI напрямую (без packagecloud)
ensure_ookla_speedtest() {
  if command -v speedtest >/dev/null 2>&1; then
    return 0
  fi

  info "Устанавливаем Ookla Speedtest CLI…"
  local tmpdir arch_tag tgz url
  tmpdir=$(mktemp -d)
  case "$(uname -m)" in
    x86_64|amd64)  arch_tag="linux-x86_64" ;;
    aarch64|arm64) arch_tag="linux-aarch64" ;;
    *) warn "Архитектура $(uname -m) не поддерживается Ookla CLI"; rm -rf "$tmpdir"; return 1 ;;
  esac

  # Прямой бинарник с CDN Ookla (не зависит от packagecloud)
  url="https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-${arch_tag}.tgz"
  if ! curl -fsSL --connect-timeout 10 --max-time 90 -o "$tmpdir/speedtest.tgz" "$url"; then
    warn "Не удалось скачать Ookla с CDN"
    rm -rf "$tmpdir"
    return 1
  fi

  tar -xzf "$tmpdir/speedtest.tgz" -C "$tmpdir" 2>/dev/null || {
    warn "Ошибка распаковки Ookla"
    rm -rf "$tmpdir"
    return 1
  }

  if [[ -f "$tmpdir/speedtest" ]]; then
    install -m 0755 "$tmpdir/speedtest" /usr/local/bin/speedtest
    ok "Ookla Speedtest установлен: /usr/local/bin/speedtest"
    /usr/local/bin/speedtest --accept-license --accept-gdpr >/dev/null 2>&1 || true
    rm -rf "$tmpdir"
    return 0
  fi

  warn "Бинарник speedtest не найден в архиве"
  rm -rf "$tmpdir"
  return 1
}

# Свой download-speed через curl (запасной вариант без Ookla)
run_curl_speed_test() {
  local label="$1" url="$2" bytes="${3:-0}"
  local out t_total speed_bps speed_mbps size
  echo -e "  ${WHITE}${label}${NC}"
  echo -e "  ${GRAY}${url}${NC}"

  out=$(curl -L -o /dev/null -w '%{time_total} %{size_download} %{speed_download}' \
    --connect-timeout 10 --max-time 60 "$url" 2>/dev/null) || {
    warn "  Не удалось: $label"
    echo
    return 1
  }

  t_total=$(echo "$out" | awk '{print $1}')
  size=$(echo "$out" | awk '{print $2}')
  speed_bps=$(echo "$out" | awk '{print $3}')
  speed_mbps=$(awk -v s="$speed_bps" 'BEGIN{printf "%.2f", s*8/1000000}')
  local size_mb
  size_mb=$(awk -v s="$size" 'BEGIN{printf "%.2f", s/1048576}')

  printf "     Размер:  %s МБ\n" "$size_mb"
  printf "     Время:   %.2f сек\n" "$t_total"
  printf "     Скорость:${CYAN} %s Мбит/с${NC}\n" "$speed_mbps"
  echo
}

run_latency_test() {
  clear
  echo -e "${CYAN}${BOLD}"
  echo "  ╔════════════════════════════════════════════════════╗"
  echo "  ║              📶 ЗАДЕРЖКА / PING                    ║"
  echo "  ╚════════════════════════════════════════════════════╝"
  echo -e "${NC}"

  local hosts=("1.1.1.1" "8.8.8.8" "9.9.9.9" "77.88.8.8" "google.com" "cloudflare.com")
  local h
  for h in "${hosts[@]}"; do
    echo -e "  ${WHITE}$h${NC}"
    if ping -c 5 -W 2 "$h" 2>/dev/null | tail -2 | sed 's/^/     /'; then
      :
    else
      echo -e "     ${RED}нет ответа${NC}"
    fi
    echo
  done
}

run_dns_test() {
  clear
  echo -e "${CYAN}${BOLD}"
  echo "  ╔════════════════════════════════════════════════════╗"
  echo "  ║                  🧭 DNS ТЕСТ                       ║"
  echo "  ╚════════════════════════════════════════════════════╝"
  echo -e "${NC}"

  local resolvers=("1.1.1.1" "8.8.8.8" "9.9.9.9" "77.88.8.8")
  local domains=("google.com" "cloudflare.com" "github.com" "youtube.com")
  local r d t0 t1 ms

  for r in "${resolvers[@]}"; do
    echo -e "  ${WHITE}Резолвер ${r}${NC}"
    for d in "${domains[@]}"; do
      t0=$(date +%s%N)
      if getent hosts "$d" >/dev/null 2>&1 || dig @"$r" +short +time=2 +tries=1 "$d" >/dev/null 2>&1; then
        t1=$(date +%s%N)
        ms=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.1f", (b-a)/1000000}')
        # Более точный замер через dig, если есть
        if command -v dig >/dev/null 2>&1; then
          local dig_ms
          dig_ms=$(dig @"$r" +stats +time=2 +tries=1 "$d" 2>/dev/null | awk '/Query time:/ {print $4; exit}')
          if [[ -n "$dig_ms" ]]; then
            printf "     %-22s ${GREEN}%s ms${NC}\n" "$d" "$dig_ms"
          else
            printf "     %-22s ${YELLOW}%s ms${NC}\n" "$d" "$ms"
          fi
        else
          printf "     %-22s ${GREEN}ok${NC} (~%s ms)\n" "$d" "$ms"
        fi
      else
        printf "     %-22s ${RED}fail${NC}\n" "$d"
      fi
    done
    echo
  done
}

run_ip_info_test() {
  clear
  echo -e "${CYAN}${BOLD}"
  echo "  ╔════════════════════════════════════════════════════╗"
  echo "  ║                 🌐 ИНФО ОБ IP                      ║"
  echo "  ╚════════════════════════════════════════════════════╝"
  echo -e "${NC}"

  local ip4 ip6
  ip4=$(curl -fsS4 --max-time 5 https://api.ipify.org 2>/dev/null || curl -fsS4 --max-time 5 https://ifconfig.me 2>/dev/null || echo "н/д")
  ip6=$(curl -fsS6 --max-time 5 https://api64.ipify.org 2>/dev/null || echo "н/д")

  echo -e "  ${WHITE}IPv4:${NC}  ${CYAN}${ip4}${NC}"
  echo -e "  ${WHITE}IPv6:${NC}  ${CYAN}${ip6}${NC}"
  echo

  if [[ "$ip4" != "н/д" ]]; then
    info "Гео / ASN (ipinfo.io / ifconfig.co)…"
    local geo
    geo=$(curl -fsS --max-time 8 "https://ipinfo.io/${ip4}/json" 2>/dev/null \
      || curl -fsS --max-time 8 "https://ifconfig.co/json" 2>/dev/null || true)
    if [[ -n "$geo" ]] && command -v jq >/dev/null 2>&1; then
      echo "$geo" | jq -r '
        "  Страна:   \(.country // .country_iso // "?")",
        "  Город:    \(.city // "?")",
        "  Регион:   \(.region // .region_name // "?")",
        "  Org/ASN:  \(.org // .asn // "?")",
        "  Hostname: \(.hostname // "?")"
      ' 2>/dev/null | sed 's/^/  /' || echo "$geo" | sed 's/^/  /'
    elif [[ -n "$geo" ]]; then
      echo "$geo" | sed 's/^/  /'
    else
      warn "Гео-данные недоступны"
    fi
  fi
  echo
}

run_system_bench() {
  clear
  echo -e "${CYAN}${BOLD}"
  echo "  ╔════════════════════════════════════════════════════╗"
  echo "  ║              🖥️  СИСТЕМА / CPU BENCH               ║"
  echo "  ╚════════════════════════════════════════════════════╝"
  echo -e "${NC}"

  echo -e "  ${WHITE}Система:${NC}"
  echo -e "    OS:     $PRETTY_NAME"
  echo -e "    Kernel: $(uname -r)"
  echo -e "    Arch:   $(uname -m)"
  echo -e "    CPU:    $(nproc) ядер — $(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs || echo '?')"
  echo -e "    RAM:    $(free -h | awk '/^Mem:/ {printf "%s / %s", $3, $2}')"
  echo -e "    Swap:   $(free -h | awk '/^Swap:/ {print $2}')"
  echo -e "    Disk /: $(df -h / | awk 'NR==2 {printf "%s used / %s (%s)", $3, $2, $5}')"
  echo

  info "CPU bench (256 МБ через sha256sum)…"
  local t0 t1
  t0=$(date +%s.%N)
  dd if=/dev/zero bs=1M count=256 2>/dev/null | sha256sum >/dev/null
  t1=$(date +%s.%N)
  awk -v a="$t0" -v b="$t1" 'BEGIN{printf "    256 МБ sha256: %.2f сек (≈ %.0f МБ/с)\n", b-a, 256/(b-a)}'

  echo
  info "Диск (запись 256 МБ)…"
  local wr
  wr=$(dd if=/dev/zero of=/tmp/.rn_disk_bench bs=1M count=256 conv=fdatasync 2>&1 | awk -F', ' '/copied|записано|copied/ {print $NF}' | tail -1)
  rm -f /tmp/.rn_disk_bench
  echo -e "    Запись: ${CYAN}${wr:-н/д}${NC}"
  echo
}

run_ports_check() {
  clear
  echo -e "${CYAN}${BOLD}"
  echo "  ╔════════════════════════════════════════════════════╗"
  echo "  ║            🔌 СЛУШАЮЩИЕ ПОРТЫ / СЕРВИСЫ            ║"
  echo "  ╚════════════════════════════════════════════════════╝"
  echo -e "${NC}"

  echo -e "  ${WHITE}TCP/UDP listeners:${NC}"
  ss -tulnp 2>/dev/null | head -50 | sed 's/^/    /' || netstat -tulnp 2>/dev/null | head -50 | sed 's/^/    /'
  echo
  echo -e "  ${WHITE}Docker:${NC}"
  docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null | sed 's/^/    /' || echo "    docker н/д"
  echo
}

run_speedtest_menu() {
  clear
  echo -e "${CYAN}${BOLD}"
  echo "  ╔════════════════════════════════════════════════════╗"
  echo "  ║                 🚀 SPEEDTEST                       ║"
  echo "  ╚════════════════════════════════════════════════════╝"
  echo -e "${NC}"

  echo -e "  ${WHITE}1)${NC} 🚀 Ookla Speedtest       ${GRAY}(полный тест)${NC}"
  echo -e "  ${WHITE}2)${NC} 📶 Ookla — только ping/jitter"
  echo -e "  ${WHITE}3)${NC} 📥 Свой тест скачивания  ${GRAY}(curl, без Ookla)${NC}"
  echo -e "  ${WHITE}4)${NC} 📊 Комплекс: Ookla + ping + замер времени"
  echo -e "  ${GRAY}0)${NC} 🔙 Назад"
  echo
  ask_choice ch

  local t0 t1
  case "$ch" in
    1)
      ensure_ookla_speedtest || { warn "Ookla недоступен — попробуйте пункт 3"; return; }
      t0=$(date +%s.%N)
      echo -e "  ${GRAY}Старт: $(date '+%F %T')${NC}"
      speedtest --accept-license --accept-gdpr || warn "Ookla вернул ошибку"
      t1=$(date +%s.%N)
      echo
      awk -v a="$t0" -v b="$t1" 'BEGIN{printf "  ⏱ Длительность: %.1f сек\n", b-a}'
      ;;
    2)
      ensure_ookla_speedtest || { warn "Ookla недоступен"; return; }
      if speedtest --accept-license --accept-gdpr -f json 2>/dev/null | jq -r '
          "  Ping:    \(.ping.latency) ms",
          "  Jitter:  \(.ping.jitter) ms",
          "  Server:  \(.server.name) (\(.server.location))",
          "  ISP:     \(.isp // "?")"
        ' 2>/dev/null; then
        :
      else
        speedtest --accept-license --accept-gdpr --ping || true
      fi
      ;;
    3)
      echo
      info "📥 Замер download через несколько CDN…"
      echo
      t0=$(date +%s.%N)
      run_curl_speed_test "Cloudflare 10 МБ" "https://speed.cloudflare.com/__down?bytes=10000000"
      run_curl_speed_test "Cloudflare 25 МБ" "https://speed.cloudflare.com/__down?bytes=25000000"
      run_curl_speed_test "Hetzner 100 МБ"   "https://speed.hetzner.de/100MB.bin"
      run_curl_speed_test "ThinkBroadband 10 МБ" "http://ipv4.download.thinkbroadband.com/10MB.zip"
      t1=$(date +%s.%N)
      awk -v a="$t0" -v b="$t1" 'BEGIN{printf "  ⏱ Общее время: %.1f сек\n", b-a}'
      echo
      info "RTT:"
      ping -c 4 -W 2 1.1.1.1 2>/dev/null | tail -2 | sed 's/^/  /' || true
      ;;
    4)
      ensure_ookla_speedtest || warn "Ookla пропущен"
      t0=$(date +%s.%N)
      echo -e "  ${GRAY}Старт: $(date '+%F %T')${NC}"
      if command -v speedtest >/dev/null 2>&1; then
        speedtest --accept-license --accept-gdpr || true
      fi
      echo
      run_curl_speed_test "Cloudflare 25 МБ" "https://speed.cloudflare.com/__down?bytes=25000000"
      echo -e "  ${WHITE}Ping:${NC}"
      ping -c 5 -W 2 1.1.1.1 2>/dev/null | tail -2 | sed 's/^/  /'
      ping -c 5 -W 2 8.8.8.8 2>/dev/null | tail -2 | sed 's/^/  /'
      t1=$(date +%s.%N)
      echo -e "  ${GRAY}Финиш: $(date '+%F %T')${NC}"
      awk -v a="$t0" -v b="$t1" 'BEGIN{printf "  ⏱ Длительность: %.2f сек\n", b-a}'
      ;;
    *) return ;;
  esac
}

tests_menu() {
  while true; do
    clear
    echo -e "${CYAN}${BOLD}"
    echo "  ╔════════════════════════════════════════════════════╗"
    echo "  ║                     🧪 ТЕСТЫ                       ║"
    echo "  ╚════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo -e "  ${WHITE}1)${NC} 🚀 Speedtest           ${GRAY}— Ookla / свой curl-тест${NC}"
    echo -e "  ${WHITE}2)${NC} 📶 Задержка (ping)"
    echo -e "  ${WHITE}3)${NC} 🧭 DNS"
    echo -e "  ${WHITE}4)${NC} 🌐 Информация об IP"
    echo -e "  ${WHITE}5)${NC} 🖥️  Система / CPU / диск"
    echo -e "  ${WHITE}6)${NC} 🔌 Порты и контейнеры"
    echo -e "  ${WHITE}7)${NC} 🏁 Полный прогон       ${GRAY}— 1→6 подряд${NC}"
    echo
    echo -e "  ${GRAY}0)${NC} 🔙 Назад"
    echo
    ask_choice choice

    case "$choice" in
      1) run_speedtest_menu; pause ;;
      2) run_latency_test; pause ;;
      3) run_dns_test; pause ;;
      4) run_ip_info_test; pause ;;
      5) run_system_bench; pause ;;
      6) run_ports_check; pause ;;
      7)
        run_ip_info_test
        run_latency_test
        run_dns_test
        run_speedtest_menu
        run_system_bench
        run_ports_check
        ok "🏁 Полный прогон завершён"
        pause
        ;;
      0) return 0 ;;
      *) ;;
    esac
  done
}

###############################################################################
# Системное меню (SWAP / UFW / тюнинг)
###############################################################################
system_menu() {
  while true; do
    show_header
    echo -e "${WHITE}${BOLD}  🛠️  Система и защита${NC}"
    hline 56
    echo -e "  SWAP:  $(service_badge swap)"
    echo -e "  UFW:   $(service_badge ufw)"
    echo
    echo -e "  ${WHITE}1)${NC} 💾 SWAP — создать / удалить"
    echo -e "  ${WHITE}2)${NC} 🛡️  UFW и порты"
    echo -e "  ${WHITE}3)${NC} ⚙️  Тюнинг производительности (BBR, буферы, RPS)"
    echo -e "  ${WHITE}4)${NC} 📦 Только базовые пакеты"
    echo -e "  ${GRAY}0)${NC} 🔙 Назад"
    echo
    ask_choice ch
    case "$ch" in
      1) setup_swap; pause ;;
      2) setup_ufw; pause ;;
      3) apply_performance_tuning; pause ;;
      4) ensure_packages; pause ;;
      0) return 0 ;;
      *) ;;
    esac
  done
}

###############################################################################
# Управление нодой — меню в стиле DigneZzZ remnanode.sh
###############################################################################
node_status_screen() {
  clear
  echo -e "${WHITE}${BOLD}  📡 RemnaNode — управление${NC}  ${GRAY}v${SCRIPT_VERSION}${NC}"
  hline 56
  echo

  if is_remnanode_up; then
    local node_port node_ver xray_ver
    node_port=$(grep -E '^NODE_PORT=' "$ENV_FILE" 2>/dev/null | cut -d= -f2)
    node_port=${node_port:-3000}
    echo -e "  ${GREEN}✅ Статус ноды: РАБОТАЕТ${NC}"
    echo
    echo -e "  ${WHITE}🌐 Подключение:${NC}"
    printf "     %-14s ${CYAN}%s${NC}\n" "IP:" "$PUBLIC_IP"
    printf "     %-14s ${CYAN}%s${NC}\n" "Порт:" "$node_port"
    printf "     %-14s ${CYAN}%s:%s${NC}\n" "URL:" "$PUBLIC_IP" "$node_port"
    echo
    echo -e "  ${WHITE}🧩 Компоненты:${NC}"
    node_ver=$(docker inspect --format '{{.Config.Image}}' remnanode 2>/dev/null || echo "?")
    printf "     %-14s %s\n" "Образ:" "$node_ver"
    xray_ver=$(docker exec remnanode xray version 2>/dev/null | head -1 || echo "н/д")
    printf "     %-14s %s\n" "Xray:" "$xray_ver"
    if grep -q 'custom-xray/xray' "$COMPOSE" 2>/dev/null; then
      echo -e "     ${YELLOW}custom Xray смонтирован (фикс онлайна)${NC}"
    fi
    echo
    echo -e "  ${WHITE}💾 Ресурсы:${NC}"
    local cstats
    cstats=$(docker stats --no-stream --format '{{.CPUPerc}} | {{.MemUsage}}' remnanode 2>/dev/null || echo "n/a")
    printf "     %-14s %s\n" "Контейнер:" "$cstats"
    printf "     %-14s %s\n" "RAM хоста:" "$(free -h | awk '/^Mem:/ {printf "%s / %s", $3, $2}')"
  elif is_remnanode_installed; then
    echo -e "  ${RED}❌ Статус ноды: ОСТАНОВЛЕНА${NC}"
    echo -e "  ${GRAY}Используйте пункт 2 для запуска${NC}"
  else
    echo -e "  ${GRAY}📦 Статус: НЕ УСТАНОВЛЕНА${NC}"
    echo -e "  ${GRAY}Используйте пункт 1 для установки${NC}"
  fi
  echo
  hline 56
}

remnanode_menu() {
  install_self_cli >/dev/null 2>&1 || true

  while true; do
    PUBLIC_IP=$(get_public_ip)
    node_status_screen

    echo -e "  ${WHITE}🛠️  Установка и управление:${NC}"
    echo -e "    ${WHITE} 1)${NC} 🚀 Установить RemnaNode"
    echo -e "    ${WHITE} 2)${NC} ▶️  Запустить"
    echo -e "    ${WHITE} 3)${NC} ⏹️  Остановить"
    echo -e "    ${WHITE} 4)${NC} 🔄 Перезапустить"
    echo -e "    ${WHITE} 5)${NC} 🗑️  Удалить RemnaNode"
    echo
    echo -e "  ${WHITE}📊 Мониторинг и логи:${NC}"
    echo -e "    ${WHITE} 6)${NC} 📌 Статус (docker ps / compose)"
    echo -e "    ${WHITE} 7)${NC} 📋 Логи контейнера"
    echo -e "    ${WHITE} 8)${NC} 📈 Docker stats"
    echo -e "    ${WHITE} 9)${NC} 📺 LIVE-мониторинг"
    echo
    echo -e "  ${WHITE}⚙️  Обновления и конфигурация:${NC}"
    echo -e "    ${WHITE}10)${NC} ⬆️  Обновить образ RemnaNode"
    echo -e "    ${WHITE}11)${NC} 🔧 Фикс онлайна Hysteria2 / custom Xray"
    echo -e "    ${WHITE}12)${NC} 📝 Редактировать docker-compose.yml"
    echo -e "    ${WHITE}13)${NC} 🔐 Редактировать .env"
    echo -e "    ${WHITE}14)${NC} 🔌 Показать порты"
    echo -e "    ${WHITE}15)${NC} ⚙️  Тюнинг производительности"
    echo
    echo -e "  ${WHITE}✨ Дополнительно:${NC}"
    echo -e "    ${WHITE}16)${NC} ⚡ Настройка Hysteria2"
    echo -e "    ${WHITE}17)${NC} 🎭 Selfsteal"
    echo -e "    ${WHITE}18)${NC} 🏠 Открыть главное меню лаунчера"
    echo
    hline 56
    echo -e "    ${GRAY}0)${NC} 🚪 Выход"
    echo
    ask_choice choice "👉 Выберите пункт [0-18]:"

    case "$choice" in
      1) install_remnanode; pause ;;
      2)
        [[ -f "$COMPOSE" ]] || { warn "Не установлено"; pause; continue; }
        cd "$DIR" && docker compose up -d
        ok "Запущено"; pause
        ;;
      3)
        [[ -f "$COMPOSE" ]] || { warn "Не установлено"; pause; continue; }
        cd "$DIR" && docker compose down
        ok "Остановлено"; pause
        ;;
      4)
        [[ -f "$COMPOSE" ]] || { warn "Не установлено"; pause; continue; }
        cd "$DIR" && docker compose down && docker compose up -d
        ok "Перезапущено"; pause
        ;;
      5)
        if is_remnanode_installed; then
          ask_yes_no "🗑️  Точно удалить RemnaNode?" ans N
          if [[ "$ans" =~ ^[Yy]$ ]]; then
            cd "$DIR" 2>/dev/null && docker compose down -v 2>/dev/null || true
            docker rm -f remnanode 2>/dev/null || true
            rm -rf "$DIR"
            ok "Удалено"
          fi
        else
          warn "Не установлено"
        fi
        pause
        ;;
      6)
        docker ps -a --filter name=remnanode
        echo
        [[ -f "$COMPOSE" ]] && (cd "$DIR" && docker compose ps) || true
        pause
        ;;
      7)
        docker logs -f --tail 100 remnanode || true
        ;;
      8)
        docker stats remnanode || true
        ;;
      9) live_panel ;;
      10)
        [[ -f "$COMPOSE" ]] || { warn "Не установлено"; pause; continue; }
        cd "$DIR" && docker compose pull && docker compose up -d
        ok "Обновлено"; pause
        ;;
      11) fix_hysteria2_online; pause ;;
      12)
        ${EDITOR:-nano} "$COMPOSE"
        ask_yes_no "🔄 Перезапустить ноду?" ans N
        [[ "$ans" =~ ^[Yy]$ ]] && cd "$DIR" && docker compose up -d
        pause
        ;;
      13)
        ${EDITOR:-nano} "$ENV_FILE"
        ask_yes_no "🔄 Перезапустить ноду?" ans N
        [[ "$ans" =~ ^[Yy]$ ]] && cd "$DIR" && docker compose up -d
        pause
        ;;
      14)
        echo
        info "Слушающие порты:"
        ss -tulnp 2>/dev/null | head -40 | sed 's/^/  /'
        echo
        if [[ -f "$ENV_FILE" ]]; then
          echo -e "  ${WHITE}.env:${NC}"
          grep -E 'PORT|SECRET' "$ENV_FILE" | sed 's/SECRET_KEY=.*/SECRET_KEY=***/' | sed 's/^/    /'
        fi
        pause
        ;;
      15) apply_performance_tuning; pause ;;
      16) install_hysteria2; pause ;;
      17) install_selfsteal; pause ;;
      18) main_menu; return 0 ;;
      0) exit 0 ;;
      *) ;;
    esac
  done
}

live_panel() {
  trap 'return 0' INT
  while true; do
    clear
    echo -e "${BLUE}${BOLD}  📺 LIVE PANEL${NC}  ${GRAY}(Ctrl+C — в меню)${NC}"
    hline 56
    UPTIME=$(uptime -p 2>/dev/null | sed 's/^up //')
    LOAD=$(awk '{print $1", "$2", "$3}' /proc/loadavg)
    CPU_USAGE=$(top -bn1 | awk '/Cpu\(s\)/ {printf "%.1f", 100 - $8}')
    MEM=$(free -m | awk '/^Mem:/ {printf "%s / %s MB (%.0f%%)", $3, $2, $3*100/$2}')
    SWAP=$(free -m | awk '/^Swap:/ {if($2>0) printf "%s / %s MB", $3, $2; else print "—"}')
    DISK=$(df -h / | awk 'NR==2 {printf "%s / %s (%s)", $3, $2, $5}')

    printf "  Uptime:  %s\n" "$UPTIME"
    printf "  Load:    %s\n" "$LOAD"
    printf "  CPU:     %s%%\n" "$CPU_USAGE"
    printf "  RAM:     %s\n" "$MEM"
    printf "  Swap:    %s\n" "$SWAP"
    printf "  Disk:    %s\n" "$DISK"

    if is_remnanode_up; then
      CSTATS=$(docker stats --no-stream --format '{{.CPUPerc}} | {{.MemUsage}}' remnanode 2>/dev/null)
      printf "  Node:    ${GREEN}● running${NC}  (%s)\n" "$CSTATS"
    else
      printf "  Node:    ${RED}● stopped${NC}\n"
    fi

    echo
    echo -e "${YELLOW}── 🔗 Соединения ──${NC}"
    TOTAL=$(ss -ntu 2>/dev/null | tail -n +2 | wc -l)
    EST=$(ss -tn state established 2>/dev/null | tail -n +2 | wc -l)
    printf "  Total: %s | Established: %s\n" "$TOTAL" "$EST"

    echo
    echo -e "${YELLOW}── 🏆 TOP IP ──${NC}"
    ss -tn state established 2>/dev/null \
      | awk 'NR>1 {split($5,a,":"); print a[1]}' \
      | sort | uniq -c | sort -nr | head -8 \
      | awk '{printf "  %5s  %s\n", $1, $2}'

    IFACE=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
    if [[ -n "$IFACE" ]]; then
      RX1=$(cat /sys/class/net/$IFACE/statistics/rx_bytes)
      TX1=$(cat /sys/class/net/$IFACE/statistics/tx_bytes)
      sleep 1
      RX2=$(cat /sys/class/net/$IFACE/statistics/rx_bytes)
      TX2=$(cat /sys/class/net/$IFACE/statistics/tx_bytes)
      printf "\n  %-6s  RX: %6s KB/s   TX: %6s KB/s\n" "$IFACE" "$(( (RX2-RX1)/1024 ))" "$(( (TX2-TX1)/1024 ))"
    else
      sleep 1
    fi
    sleep 1
  done
  trap - INT
}

###############################################################################
# Главное меню лаунчера
###############################################################################
main_menu() {
  # Чтобы команда remnanode была доступна сразу
  install_self_cli >/dev/null 2>&1 || true

  while true; do
    PUBLIC_IP=$(get_public_ip)
    show_header

    section "📦 Установка"
    menu_item "🚀" "1"  "Remnanode"  "VPN-нода Remnawave" remnanode
    menu_item "🎭" "2"  "Selfsteal"  "маскировка Reality" selfsteal
    menu_item "⚡" "3"  "Hysteria2"  "автонастройка"      hysteria
    menu_item "🔧" "4"  "Фикс H2"    "custom Xray"        xrayfix
    menu_item "☁️ " "5"  "WARP"       "Cloudflare SOCKS5"  warp
    menu_item "✈️ " "6"  "MTProto"    "прокси Telegram"    mtproto

    section "🛠️  Система"
    menu_item "💾" "7"  "SWAP"       "файл подкачки"      swap
    menu_item "🛡️ " "8"  "UFW"        "порты и защита"     ufw
    menu_item "⚙️ " "9"  "Тюнинг"     "BBR / буферы / RPS" tune

    section "🎛️  Сервис"
    menu_item "📡" "10" "Нода"       "меню управления"    node_cli
    menu_item "🧪" "11" "Тесты"      "speed / ping / DNS"
    echo
    menu_item "🚪" "0"  "Выход"      ""
    echo
    ask_choice choice

    case "$choice" in
      1)  install_remnanode; pause ;;
      2)  install_selfsteal; pause ;;
      3)  install_hysteria2; pause ;;
      4)  fix_hysteria2_online; pause ;;
      5)  install_warp; pause ;;
      6)  install_mtproto; pause ;;
      7)  setup_swap; pause ;;
      8)  setup_ufw; pause ;;
      9)  apply_performance_tuning; pause ;;
      10) remnanode_menu ;;
      11) tests_menu ;;
      0)  exit 0 ;;
      *)  ;;
    esac
  done
}

###############################################################################
# Точка входа
###############################################################################
# Снимаем ERR-trap для интерактивных меню (иначе Ctrl+C / cancel ломают UI)
entry_name="$(basename "${BASH_SOURCE[0]:-$0}")"

case "${1:-}" in
  install-remnanode|install)   install_remnanode ;;
  install-selfsteal)           install_selfsteal ;;
  install-hysteria2|hysteria2) install_hysteria2 ;;
  fix-hysteria|fix-online)    fix_hysteria2_online ;;
  install-warp)                install_warp ;;
  install-mtproto|mtproto)     install_mtproto ;;
  swap)                        setup_swap ;;
  ufw|firewall)                setup_ufw ;;
  tune|performance)            apply_performance_tuning ;;
  tests|test)                  tests_menu ;;
  up)
    cd "$DIR" && docker compose up -d
    ;;
  down)
    cd "$DIR" && docker compose down
    ;;
  restart)
    cd "$DIR" && docker compose down && docker compose up -d
    ;;
  status)
    docker ps -a --filter name=remnanode
    [[ -f "$COMPOSE" ]] && (cd "$DIR" && docker compose ps) || true
    ;;
  logs)
    docker logs -f --tail 100 remnanode
    ;;
  update)
    cd "$DIR" && docker compose pull && docker compose up -d
    ;;
  manage|node|panel)
    remnanode_menu
    ;;
  menu|launcher)
    main_menu
    ;;
  *)
    if [[ "$entry_name" == "remnanode" ]]; then
      remnanode_menu
    else
      main_menu
    fi
    ;;
esac