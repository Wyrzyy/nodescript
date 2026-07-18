#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
# REMNANODE LAUNCHER — Ubuntu 24.04 / Debian 12
# Remnanode · Selfsteal · Hysteria2 · WARP · MTProto · SWAP · UFW · Тесты
# Версия: 2026.7.17
#
# Запуск лаунчера (меню со всеми возможностями):
#   bash <(curl -Ls https://raw.githubusercontent.com/Wyrzyy/nodescript/refs/heads/main/remnanode.sh) @ install
#
# Скрипт сам перезапустится из tempfile (фикс Termius /dev/fd).
# Установка ноды — пункт меню «1», не через аргумент @ install.
# Selfsteal — русифицированная копия в этом же репозитории (selfsteal.sh).
###############################################################################

# Версия лаунчера — литерал + несколько имён (env/os-release не должны её затереть)
_REMNANODE_VER="2026.7.17"
RN_VERSION="$_REMNANODE_VER"
SCRIPT_VERSION="$_REMNANODE_VER"

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

# Внешние / наши скрипты (UI — на русском)
LAUNCHER_RAW="https://raw.githubusercontent.com/Wyrzyy/nodescript/refs/heads/main/remnanode.sh"
# Selfsteal: русифицированная копия DigneZzZ в этом репо
SELFSTEAL_RAW="https://raw.githubusercontent.com/Wyrzyy/nodescript/refs/heads/main/selfsteal.sh"
SELFSTEAL_LOCAL="/opt/remnanode/selfsteal.sh"
# Hysteria2: upstream уже на русском
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

# Всегда общаемся с реальным терминалом (/dev/tty).
# Нужно для bash <(curl …) / Termius: иначе prompt и текст «пропадают».
_TTY="/dev/tty"
if [[ ! -r $_TTY || ! -w $_TTY ]]; then
  _TTY="/dev/stdout"
fi

_tty_printf() { printf "$@" >"$_TTY" 2>/dev/null || printf "$@"; }
_tty_echo()   { echo -e "$@" >"$_TTY" 2>/dev/null || echo -e "$@"; }

# Полная очистка экрана (Termius/SSH: убирает артефакты и alt-screen)
ui_clear() {
  stty sane <"$_TTY" 2>/dev/null || stty sane 2>/dev/null || true
  # выйти из alternate screen, сбросить атрибуты, очистить экран + scrollback
  _tty_printf '\033[?1049l\033[0m\033[2J\033[3J\033[H'
}

# UI-вывод всегда в /dev/tty
_msg() {
  local color="$1" icon="$2" text="$3"
  _tty_printf '%b%s %s%b\n' "$color" "$icon" "$text" "$NC"
}
ok()   { _msg "$GREEN" "+" "$1"; }
info() { _msg "$CYAN" ">" "$1"; }
warn() { _msg "$YELLOW" "!" "$1"; }
err()  {
  _msg "$RED" "x" "$1"
  _msg "$GRAY" "#" "последние строки лога → ${LOG}"
  tail -n 30 "$LOG" 2>/dev/null >"$_TTY" || tail -n 30 "$LOG" 2>/dev/null || true
  exit 1
}

mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
: > "$LOG" 2>/dev/null || true
exec 3>>"$LOG" 2>/dev/null || exec 3>/dev/null

hline() {
  local n="${1:-52}"
  _tty_printf '  %b%s%b\n' "$GRAY" "$(printf '%.0s-' $(seq 1 "$n"))" "$NC"
}

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

# Секретный ввод: каждый символ → «•», Backspace работает
ask_secret() {
  local prompt="$1" varname="$2"
  local _ans="" _char="" _tty_in="/dev/tty"
  [[ -r $_tty_in ]] || _tty_in="/dev/stdin"

  _tty_printf "  %b%s%b: " "$WHITE" "$prompt" "$NC"
  local _stty_save=""
  _stty_save=$(stty -g <"$_tty_in" 2>/dev/null || true)
  stty -echo -icanon min 1 time 0 <"$_tty_in" 2>/dev/null || true

  while true; do
    _char=""
    IFS= read -r -n1 -s _char <"$_tty_in" || true
    # Enter
    if [[ -z "$_char" || "$_char" == $'\n' || "$_char" == $'\r' ]]; then
      break
    fi
    # Backspace / Delete
    if [[ "$_char" == $'\x7f' || "$_char" == $'\b' ]]; then
      if [[ -n "$_ans" ]]; then
        _ans="${_ans%?}"
        _tty_printf '\b \b'
      fi
      continue
    fi
    # Ctrl-C
    if [[ "$_char" == $'\x03' ]]; then
      [[ -n "$_stty_save" ]] && stty "$_stty_save" <"$_tty_in" 2>/dev/null || true
      _tty_echo ""
      err "Ввод прерван"
    fi
    _ans+="$_char"
    _tty_printf '•'
  done

  [[ -n "$_stty_save" ]] && stty "$_stty_save" <"$_tty_in" 2>/dev/null || stty sane <"$_tty_in" 2>/dev/null || true
  _tty_echo ""
  if [[ -n "$_ans" ]]; then
    _tty_printf "  %b👁  Введено символов: %s%b\n" "$GRAY" "${#_ans}" "$NC"
  else
    _tty_printf "  %b(пусто)%b\n" "$YELLOW" "$NC"
  fi
  printf -v "$varname" '%s' "$_ans"
}

# Короткий выбор пункта меню
ask_choice() {
  local varname="$1" prompt="${2:->}"
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
  local frames=('|' '/' '-' '\\') i=0
  _tty_printf "  %b*%b %s " "$CYAN" "$NC" "$msg"
  while kill -0 "$pid" 2>/dev/null; do
    _tty_printf '\b%s' "${frames[$((i++ % 4))]}"
    sleep 0.1
  done
  wait "$pid"
  local rc=$?
  if [[ $rc -eq 0 ]]; then
    _tty_printf '\b %bok%b\n' "$GREEN" "$NC"
  else
    _tty_printf '\b %bfail%b\n' "$RED" "$NC"
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

# Лёгкая русификация UI скачанного скрипта (безопасные замены фраз)
russify_script_file() {
  local f="$1" kind="${2:-generic}"
  [[ -f "$f" ]] || return 0
  case "$kind" in
    mtproto)
      sed -i \
        -e 's/One more step — create your proxy and get a Telegram link:/Остался шаг — создайте прокси и получите ссылку Telegram:/g' \
        -e 's/Prefer a guided setup?/Нужен мастер настройки?/g' \
        -e 's/See all options:/Все опции:/g' \
        "$f" 2>/dev/null || true
      ;;
  esac
  return 0
}

# Выполнить remote bash-скрипт: скачать во временный файл и запустить
# gh_run_bash URL [args...] 
# Опционально: RN_RUSSIFY=mtproto gh_run_bash ...
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
  if [[ -n "${RN_RUSSIFY:-}" ]]; then
    russify_script_file "$tmp" "$RN_RUSSIFY"
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

# Selfsteal: всегда свежая RU-копия из репо (или рядом со скриптом)
run_selfsteal() {
  local src=""
  local here_dir
  here_dir=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)
  mkdir -p "$(dirname "$SELFSTEAL_LOCAL")" 2>/dev/null || true
  if [[ -n "$here_dir" && -f "$here_dir/selfsteal.sh" ]]; then
    src="$here_dir/selfsteal.sh"
    cp -f "$src" "$SELFSTEAL_LOCAL" 2>/dev/null || true
  else
    info "🎭 Selfsteal (RU): обновляю из репозитория…"
    if gh_download "$SELFSTEAL_RAW" "$SELFSTEAL_LOCAL"; then
      src="$SELFSTEAL_LOCAL"
    fi
  fi
  if [[ -z "$src" || ! -f "$src" ]]; then
    warn "Не удалось получить selfsteal.sh — пробую прямой запуск"
    gh_pipe_bash "$SELFSTEAL_RAW" "$@"
    return $?
  fi
  chmod +x "$src" "$SELFSTEAL_LOCAL" 2>/dev/null || true
  info "🎭 Selfsteal (RU): $src"
  set +e
  bash "$src" "$@"
  local rc=$?
  set -e
  return $rc
}

###############################################################################
# OS / система
###############################################################################
require_root

# os-release задаёт VERSION=... — восстанавливаем версию лаунчера сразу после
. /etc/os-release
_REMNANODE_VER="${_REMNANODE_VER:-2026.7.17}"
RN_VERSION="$_REMNANODE_VER"
SCRIPT_VERSION="$_REMNANODE_VER"
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
# UI — без «рамки+эмодзи» (ломает Termius), всё в /dev/tty
###############################################################################

# Обрезать/добить пробелами до ровно w символов (UTF-8, без эмодзи внутри)
pad_right() {
  local s="$1" w="$2" n=${#1}
  if (( n > w )); then
    s="${s:0:w}"
    n=$w
  fi
  printf '%s%*s' "$s" "$((w - n))" ''
}

# Актуальная версия лаунчера (никогда не пустая)
launcher_version() {
  local v=""
  v="${_REMNANODE_VER:-}"
  [[ -n "$v" ]] || v="${RN_VERSION:-}"
  [[ -n "$v" ]] || v="${SCRIPT_VERSION:-}"
  # Запасной путь: прочитать из самого файла скрипта
  if [[ -z "$v" || "$v" == "unknown" ]]; then
    local src="${BASH_SOURCE[0]:-$0}"
    if [[ -f "$src" ]]; then
      v=$(grep -E '^_REMNANODE_VER=' "$src" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"'\''[:space:]' || true)
    fi
  fi
  [[ -n "$v" ]] || v="2026.7.17"
  # Синхронизируем все имена
  _REMNANODE_VER="$v"
  RN_VERSION="$v"
  SCRIPT_VERSION="$v"
  printf '%s' "$v"
}

show_header() {
  ui_clear
  # Версию берём напрямую — без вложенных пустых env
  local ver="2026.7.17"
  ver=$(launcher_version)
  [[ -n "$ver" && "$ver" != "unknown" ]] || ver="2026.7.17"

  # Простая шапка БЕЗ emoji внутри линий — иначе Termius съезжает и «теряет» текст
  _tty_printf '%b' "${CYAN}${BOLD}"
  _tty_echo "  =================================================="
  _tty_echo "   REMNANODE LAUNCHER"
  _tty_echo "   версия ${ver}"
  _tty_echo "   Нода | Selfsteal | H2 | Прокси | Тесты"
  _tty_echo "  =================================================="
  _tty_printf '%b' "${NC}"
  _tty_echo ""
  _tty_printf '  %b%-11s%b %s\n' "$WHITE" "OS:" "$NC" "${PRETTY_NAME:-$ID}"
  _tty_printf '  %b%-11s%b %s\n' "$WHITE" "CPU/RAM:" "$NC" "${CPU} cores | ${RAM_MB} MB | ${ARCH}"
  _tty_printf '  %b%-11s%b %b%s%b\n' "$WHITE" "Public IP:" "$NC" "$CYAN" "${PUBLIC_IP:-n/a}" "$NC"
  _tty_printf '  %b%-11s%b %s\n' "$WHITE" "Local IP:" "$NC" "${LOCAL_IP:-n/a}"
  _tty_echo ""
}

# Статус без паддинга: [текст] → сразу в tty
_badge() {
  local color="$1" text="$2"
  _tty_printf '%b[%s]%b' "$color" "$text" "$NC"
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

# Колонки без emoji-width:  NN)  TITLE........  DESC................  [STATUS]
# icon оставлен для совместимости вызовов, в строку не печатаем (ломает Termius)
menu_item() {
  local _icon="$1" num="$2" title="$3" desc="$4" badge="${5:-}"
  local num_s title_s desc_s

  num_s=$(pad_right "${num})" 4)
  title_s=$(pad_right "$title" 14)
  desc_s=$(pad_right "$desc" 22)

  _tty_printf '  %b%s%b %s  %b%s%b' "$WHITE" "$num_s" "$NC" "$title_s" "$GRAY" "$desc_s" "$NC"
  if [[ -n "$badge" ]]; then
    _tty_printf '  '
    service_badge_color "$badge"
  fi
  _tty_printf '\n'
}

section() {
  _tty_echo ""
  _tty_printf '  %b%s%b\n' "${WHITE}${BOLD}" "$1" "$NC"
  hline 52
}

###############################################################################
# Базовые пакеты (без SWAP/UFW — они отдельными пунктами)
###############################################################################

# Паттерны битых/ненужных сторонних репозиториев (ломают apt update на noble+)
_APT_BAD_RE_='packagecloud\.io/ookla|ookla/speedtest|speedtest-cli|packagecloud\.io/.*/speedtest'

# Отключить файл источника apt (не удаляем навсегда — .disabled-by-remnanode)
_apt_disable_file() {
  local f="$1"
  [[ -e "$f" ]] || return 0
  # уже отключён
  [[ "$f" == *.disabled-by-remnanode ]] && return 0
  local dest="${f}.disabled-by-remnanode"
  if mv -f "$f" "$dest" 2>/dev/null; then
    echo "=== $(date '+%F %T') | apt: disabled $f → $dest ===" >&3
    return 0
  fi
  rm -f "$f" 2>/dev/null || true
  echo "=== $(date '+%F %T') | apt: removed $f ===" >&3
}

# Закомментировать строки в sources.list по regex (grep -E)
_apt_comment_lines() {
  local file="$1" pattern="$2"
  [[ -f "$file" ]] || return 0
  local tmp lines
  tmp=$(mktemp)
  lines=$(grep -n -iE "$pattern" "$file" 2>/dev/null | cut -d: -f1 || true)
  if [[ -z "$lines" ]]; then
    rm -f "$tmp"
    return 0
  fi
  cp -a "$file" "$tmp"
  local n
  while IFS= read -r n; do
    [[ -z "$n" ]] && continue
    sed -i -E "${n}s|^[[:space:]]*([^#])|# remnanode-disabled \\1|" "$tmp" 2>/dev/null || true
  done <<< "$lines"
  mv -f "$tmp" "$file"
}

# Жёсткая зачистка известных проблемных репозиториев (по имени и по содержимому)
sanitize_apt_repos() {
  local f removed=0
  shopt -s nullglob

  # 1) По имени файла
  for f in \
    /etc/apt/sources.list.d/ookla_speedtest-cli.list \
    /etc/apt/sources.list.d/ookla-speedtest-cli.list \
    /etc/apt/sources.list.d/packagecloud_ookla_speedtest-cli.list \
    /etc/apt/sources.list.d/*ookla* \
    /etc/apt/sources.list.d/*speedtest* \
    /etc/apt/sources.list.d/*packagecloud*
  do
    [[ -e "$f" ]] || continue
    # packagecloud бывает не только Ookla — отключаем файл только если внутри ookla/speedtest
    if [[ "$f" == *packagecloud* && "$f" != *ookla* && "$f" != *speedtest* ]]; then
      if ! grep -qiE "$_APT_BAD_RE_" "$f" 2>/dev/null; then
        continue
      fi
    fi
    _apt_disable_file "$f" && removed=1
  done

  # 2) По содержимому — любой .list / .sources
  for f in /etc/apt/sources.list.d/*; do
    [[ -f "$f" ]] || continue
    [[ "$f" == *.disabled-by-remnanode ]] && continue
    if grep -qiE "$_APT_BAD_RE_" "$f" 2>/dev/null; then
      _apt_disable_file "$f" && removed=1
    fi
  done

  # 3) Основной sources.list
  if [[ -f /etc/apt/sources.list ]] && grep -qiE "$_APT_BAD_RE_" /etc/apt/sources.list 2>/dev/null; then
    _apt_comment_lines /etc/apt/sources.list "$_APT_BAD_RE_"
    removed=1
  fi

  # 4) Кэш списков битого репо (иначе apt иногда продолжает ругаться)
  rm -f /var/lib/apt/lists/*ookla* /var/lib/apt/lists/*speedtest* \
        /var/lib/apt/lists/*packagecloud* 2>/dev/null || true

  shopt -u nullglob
  if [[ "$removed" -eq 1 ]]; then
    info "🧹 Отключены проблемные apt-репозитории (Ookla/packagecloud/speedtest)"
  fi
  return 0
}

# По stderr apt-get update — найти URL битых репо и отключить файлы, где они прописаны
apt_disable_from_errors() {
  local errfile="$1"
  [[ -f "$errfile" ]] || return 0
  local url hostpath f disabled=0
  local urls
  urls=$(grep -oE "https?://[^'\"[:space:]]+" "$errfile" 2>/dev/null | sed 's|[)/]*$||' | sort -u || true)
  [[ -z "$urls" ]] && return 0

  while IFS= read -r url; do
    [[ -z "$url" ]] && continue
    # укоротить до «схемы+хост+путь» без хвоста Release
    url="${url%%/Release*}"
    url="${url%/InRelease}"
    hostpath="${url#http://}"
    hostpath="${hostpath#https://}"

    shopt -s nullglob
    for f in /etc/apt/sources.list /etc/apt/sources.list.d/*; do
      [[ -f "$f" ]] || continue
      [[ "$f" == *.disabled-by-remnanode ]] && continue
      if grep -qF "$url" "$f" 2>/dev/null || grep -qF "$hostpath" "$f" 2>/dev/null; then
        if [[ "$f" == "/etc/apt/sources.list" ]]; then
          # литеральный hostpath, разделитель sed — #
          local hp_esc
          hp_esc=$(printf '%s' "$hostpath" | sed 's/[#|&]/\\&/g')
          sed -i -E "\\#${hp_esc}#s|^[[:space:]]*([^#])|# remnanode-disabled \\1|" "$f" 2>/dev/null || true
          disabled=1
        else
          _apt_disable_file "$f" && disabled=1
        fi
      fi
    done
    shopt -u nullglob
  done <<< "$urls"

  # Типичные маркеры без URL в удобном виде
  if grep -qiE 'does not have a Release file|NO_PUBKEY|not signed|Release file' "$errfile" 2>/dev/null; then
    sanitize_apt_repos
  fi

  [[ "$disabled" -eq 1 ]] && return 0
  return 0
}

# Надёжный apt-get update: чистит битые third-party репо и повторяет.
# Возвращает 0 если индекс обновлён (хотя бы основными зеркалами).
apt_update_safe() {
  local errfile="/tmp/rn-apt-update.err"
  local attempt=1
  local max=6

  sanitize_apt_repos

  while (( attempt <= max )); do
    echo "=== $(date '+%F %T') | apt-get update (попытка ${attempt}/${max}) ===" >&3
    # Не используем -qq на ошибках: нужен полный текст для парсинга URL
    if apt-get update -o Acquire::Retries=3 >"$errfile" 2>&1; then
      return 0
    fi
    cat "$errfile" >&3 2>/dev/null || true

    # Битый third-party / Release / ключ — отключаем и пробуем снова
    if grep -qiE 'does not have a Release file|NO_PUBKEY|not signed|Release file|404[[:space:]]+Not Found|packagecloud|ookla|speedtest' "$errfile" 2>/dev/null; then
      warn "apt: битый репозиторий — отключаю и повторяю (${attempt}/${max})…"
      apt_disable_from_errors "$errfile"
      sanitize_apt_repos
      attempt=$((attempt + 1))
      continue
    fi

    # Иное: пробуем allow-releaseinfo-change
    if apt-get update --allow-releaseinfo-change -o Acquire::Retries=3 >"$errfile" 2>&1; then
      return 0
    fi
    cat "$errfile" >&3 2>/dev/null || true
    apt_disable_from_errors "$errfile"
    sanitize_apt_repos
    attempt=$((attempt + 1))
  done

  # Последний резерв: только основной sources.list (без sources.list.d)
  warn "apt: обновляю только основной sources.list (без сторонних)"
  if apt-get update \
      -o Dir::Etc::sourcelist=/etc/apt/sources.list \
      -o Dir::Etc::sourceparts=/dev/null \
      -o APT::Get::List-Cleanup=0 \
      -o Acquire::Retries=3 >"$errfile" 2>&1; then
    ok "apt update (основные репозитории)"
    return 0
  fi

  # Ubuntu 24.04+ часто держит источники в /etc/apt/sources.list.d/ubuntu.sources
  if [[ -f /etc/apt/sources.list.d/ubuntu.sources ]] || [[ -f /etc/apt/sources.list.d/debian.sources ]]; then
    local tmpparts
    tmpparts=$(mktemp -d /tmp/rn-apt-parts.XXXXXX)
    [[ -f /etc/apt/sources.list.d/ubuntu.sources ]] && cp -a /etc/apt/sources.list.d/ubuntu.sources "$tmpparts/" || true
    [[ -f /etc/apt/sources.list.d/debian.sources ]] && cp -a /etc/apt/sources.list.d/debian.sources "$tmpparts/" || true
    # плюс docker/cloudflare если уже добавлены нами — чтобы install не сломался
    [[ -f /etc/apt/sources.list.d/docker.list ]] && cp -a /etc/apt/sources.list.d/docker.list "$tmpparts/" || true
    [[ -f /etc/apt/sources.list.d/cloudflare-client.list ]] && cp -a /etc/apt/sources.list.d/cloudflare-client.list "$tmpparts/" || true
    if apt-get update \
        -o Dir::Etc::sourcelist=/dev/null \
        -o Dir::Etc::sourceparts="$tmpparts" \
        -o APT::Get::List-Cleanup=0 \
        -o Acquire::Retries=3 >"$errfile" 2>&1; then
      rm -rf "$tmpparts"
      ok "apt update (системные .sources)"
      return 0
    fi
    rm -rf "$tmpparts"
  fi

  warn "apt update с ошибками — см. ${errfile} и ${LOG}"
  return 1
}

ensure_packages() {
  sanitize_apt_repos
  info "Обновление apt…"
  if apt_update_safe; then
    ok "Обновление apt"
  else
    warn "apt update не идеален — пробую установить пакеты из кэша/основных зеркал"
  fi
  # Установка не должна валить весь сценарий из‑за одного optional пакета
  if ! apt-get install -y -qq \
      curl wget ca-certificates gnupg lsb-release \
      jq htop iftop ethtool irqbalance dnsutils unzip \
      ufw fail2ban; then
    warn "Повтор apt update + install…"
    apt_update_safe || true
    apt-get install -y -qq \
      curl wget ca-certificates gnupg lsb-release \
      jq unzip ca-certificates || \
      err "Не удалось установить базовые пакеты (curl/ca-certificates)"
  fi
  ok "Базовые пакеты"
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
  sanitize_apt_repos
  if command -v docker >/dev/null 2>&1; then
    info "Docker уже установлен"
  else
    info "🐳 Добавляю репозиторий Docker…"
    install -m 0755 -d /etc/apt/keyrings
    if ! curl -fsSL "https://download.docker.com/linux/${ID}/gpg" \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg; then
      err "Не удалось скачать GPG-ключ Docker"
    fi
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${ID} ${CODENAME} stable" \
      > /etc/apt/sources.list.d/docker.list
    if ! apt_update_safe; then
      err "apt update после добавления Docker-репозитория не удался"
    fi
    ok "Репозиторий Docker"

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
  local src_dir=""
  src_dir=$(cd "$(dirname "$src")" 2>/dev/null && pwd || true)
  mkdir -p "$DIR"

  # Всегда обновляем установленный лаунчер из текущего файла (или с GitHub)
  if [[ -f "$src" && "$src" != "/dev/stdin" && "$src" != /dev/fd/* ]]; then
    cp -f "$src" "$LAUNCHER_PATH" 2>/dev/null || true
  fi
  # Если в установленной копии нет версии — скачать свежий с GitHub
  if [[ ! -f "$LAUNCHER_PATH" ]] \
     || ! grep -qE '^_REMNANODE_VER="?2026\.' "$LAUNCHER_PATH" 2>/dev/null; then
    gh_download "$LAUNCHER_RAW" "$LAUNCHER_PATH" 2>/dev/null || true
  fi
  chmod +x "$LAUNCHER_PATH" 2>/dev/null || true

  # Кладём/обновляем русифицированный Selfsteal рядом с лаунчером
  if [[ -n "$src_dir" && -f "$src_dir/selfsteal.sh" ]]; then
    cp -f "$src_dir/selfsteal.sh" "$SELFSTEAL_LOCAL" 2>/dev/null || true
    chmod +x "$SELFSTEAL_LOCAL" 2>/dev/null || true
  else
    gh_download "$SELFSTEAL_RAW" "$SELFSTEAL_LOCAL" 2>/dev/null || true
    chmod +x "$SELFSTEAL_LOCAL" 2>/dev/null || true
  fi
  ln -sfn "$LAUNCHER_PATH" "$CLI_PATH"
  chmod +x "$CLI_PATH" 2>/dev/null || true
  ok "Команда управления: remnanode"
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
  info "0️⃣  Проверка apt-репозиториев"
  sanitize_apt_repos
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

  _tty_printf "  * Жду готовности контейнера"
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
  info "🎭 Русифицированный Selfsteal (логика DigneZzZ, UI на русском)."
  echo -e "  ${GRAY}Источник: github.com/Wyrzyy/nodescript (selfsteal.sh)${NC}"
  echo

  if ! command -v docker >/dev/null 2>&1; then
    info "Docker не найден — устанавливаем"
    ensure_packages
    install_docker
  fi

  # Обновим локальную RU-копию перед запуском
  install_self_cli >/dev/null 2>&1 || true

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
  info "Запуск Selfsteal @ install ${ws_flag}"
  echo

  set +e
  run_selfsteal @ install "$ws_flag"
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
  info "Скрипт Origamidnd/h2-script (уже на русском): certbot, сертификаты, volume, BBR."
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
  info "Запуск setup.sh (RU) из h2-script…"
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

  info "☁️  Добавляю репозиторий Cloudflare WARP…"
  curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | \
    gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ ${warp_codename} main" \
    > /etc/apt/sources.list.d/cloudflare-client.list
  if ! apt_update_safe; then
    err "apt update после добавления Cloudflare-репозитория не удался"
  fi
  ok "Репозиторий Cloudflare"

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
      info "Скачивание bootstrap.sh (с зеркалами, UI на русском)…"
      if RN_RUSSIFY=mtproto gh_pipe_bash "$MTPROTO_BOOTSTRAP_RAW"; then
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
        RN_RUSSIFY=mtproto gh_pipe_bash "$MTPROTO_BOOTSTRAP_RAW" || err "Bootstrap не удался"
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
  ui_clear
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
  ui_clear
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
  ui_clear
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
  ui_clear
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
  ui_clear
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
  ui_clear
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
    ui_clear
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
  ui_clear
  _tty_printf '%b  RemnaNode — управление%b  %bv%s%b\n' "${WHITE}${BOLD}" "$NC" "$GRAY" "$(launcher_version)" "$NC"
  hline 52
  _tty_echo ""

  if is_remnanode_up; then
    local node_port node_ver xray_ver
    node_port=$(grep -E '^NODE_PORT=' "$ENV_FILE" 2>/dev/null | cut -d= -f2)
    node_port=${node_port:-3000}
    _tty_printf '  %bСтатус ноды: РАБОТАЕТ%b\n' "$GREEN" "$NC"
    _tty_echo ""
    _tty_echo "  Подключение:"
    _tty_printf '     %-10s %b%s%b\n' "IP:" "$CYAN" "$PUBLIC_IP" "$NC"
    _tty_printf '     %-10s %b%s%b\n' "Порт:" "$CYAN" "$node_port" "$NC"
    _tty_printf '     %-10s %b%s:%s%b\n' "URL:" "$CYAN" "$PUBLIC_IP" "$node_port" "$NC"
    _tty_echo ""
    _tty_echo "  Компоненты:"
    node_ver=$(docker inspect --format '{{.Config.Image}}' remnanode 2>/dev/null || echo "?")
    _tty_printf '     %-10s %s\n' "Образ:" "$node_ver"
    xray_ver=$(docker exec remnanode xray version 2>/dev/null | head -1 || echo "н/д")
    _tty_printf '     %-10s %s\n' "Xray:" "$xray_ver"
    if grep -q 'custom-xray/xray' "$COMPOSE" 2>/dev/null; then
      _tty_printf '     %bcustom Xray смонтирован (фикс онлайна)%b\n' "$YELLOW" "$NC"
    fi
    _tty_echo ""
    _tty_echo "  Ресурсы:"
    local cstats
    cstats=$(docker stats --no-stream --format '{{.CPUPerc}} | {{.MemUsage}}' remnanode 2>/dev/null || echo "n/a")
    _tty_printf '     %-10s %s\n' "Контейнер:" "$cstats"
    _tty_printf '     %-10s %s\n' "RAM хоста:" "$(free -h | awk '/^Mem:/ {printf "%s / %s", $3, $2}')"
  elif is_remnanode_installed; then
    _tty_printf '  %bСтатус ноды: ОСТАНОВЛЕНА%b\n' "$RED" "$NC"
    _tty_echo "  Используйте пункт 2 для запуска"
  else
    _tty_echo "  Статус: НЕ УСТАНОВЛЕНА"
    _tty_echo "  Используйте пункт 1 для установки"
  fi
  _tty_echo ""
  hline 52
}

remnanode_menu() {
  install_self_cli >/dev/null 2>&1 || true

  while true; do
    PUBLIC_IP=$(get_public_ip)
    node_status_screen

    _tty_echo "  Установка и управление:"
    _tty_echo "     1) Установить RemnaNode"
    _tty_echo "     2) Запустить"
    _tty_echo "     3) Остановить"
    _tty_echo "     4) Перезапустить"
    _tty_echo "     5) Удалить RemnaNode"
    _tty_echo ""
    _tty_echo "  Мониторинг и логи:"
    _tty_echo "     6) Статус (docker ps / compose)"
    _tty_echo "     7) Логи контейнера"
    _tty_echo "     8) Docker stats"
    _tty_echo "     9) LIVE-мониторинг"
    _tty_echo ""
    _tty_echo "  Обновления и конфигурация:"
    _tty_echo "    10) Обновить образ RemnaNode"
    _tty_echo "    11) Фикс онлайна Hysteria2 / custom Xray"
    _tty_echo "    12) Редактировать docker-compose.yml"
    _tty_echo "    13) Редактировать .env"
    _tty_echo "    14) Показать порты"
    _tty_echo "    15) Тюнинг производительности"
    _tty_echo ""
    _tty_echo "  Дополнительно:"
    _tty_echo "    16) Настройка Hysteria2"
    _tty_echo "    17) Selfsteal"
    _tty_echo "    18) Открыть главное меню лаунчера"
    _tty_echo ""
    hline 52
    _tty_echo "     0) Выход"
    _tty_echo ""
    ask_choice choice "Выберите пункт [0-18]:"

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
    ui_clear
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

    section "Установка"
    menu_item "-" "1"  "Remnanode"  "VPN-нода Remnawave" remnanode
    menu_item "-" "2"  "Selfsteal"  "маскировка Reality" selfsteal
    menu_item "-" "3"  "Hysteria2"  "автонастройка"      hysteria
    menu_item "-" "4"  "Фикс H2"    "custom Xray"        xrayfix
    menu_item "-" "5"  "WARP"       "Cloudflare SOCKS5"  warp
    menu_item "-" "6"  "MTProto"    "прокси Telegram"    mtproto

    section "Система"
    menu_item "-" "7"  "SWAP"       "файл подкачки"      swap
    menu_item "-" "8"  "UFW"        "порты и защита"     ufw
    menu_item "-" "9"  "Тюнинг"     "BBR / буферы / RPS" tune

    section "Сервис"
    menu_item "-" "10" "Нода"       "меню управления"    node_cli
    menu_item "-" "11" "Тесты"      "speed / ping / DNS"
    _tty_echo ""
    menu_item "-" "0"  "Выход"      ""
    _tty_echo ""
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

# Стиль DigneZzZ: bash <(curl …) @ install  →  меню лаунчера (не установка ноды)
if [[ "${1:-}" == "@" ]]; then
  shift
fi

case "${1:-}" in
  # @ install / install — поставить CLI и открыть главное меню
  install|launcher)
    install_self_cli >/dev/null 2>&1 || true
    main_menu
    ;;
  install-remnanode)           install_remnanode ;;
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
  menu)
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