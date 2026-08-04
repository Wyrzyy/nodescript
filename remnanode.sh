#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
# REMNANODE LAUNCHER — Ubuntu 24.04 / Debian 12
# Remnanode · Selfsteal · Hysteria2 · WARP · MTProto · SWAP · UFW · Тесты
# Версия: 2026.8.21
#
# Запуск лаунчера (меню со всеми возможностями):
#   bash <(curl -Ls "https://raw.githubusercontent.com/Wyrzyy/nodescript/refs/heads/main/remnanode.sh?$(date +%s)") @ install
#
# Скрипт сам перезапустится из tempfile (фикс Termius /dev/fd).
# Установка ноды — пункт меню «1», не через аргумент @ install.
# Selfsteal — русифицированная копия в этом же репозитории (selfsteal.sh).
###############################################################################

# Версия лаунчера — литерал + pin (os-release/env не должны её затереть)
_REMNANODE_VER_PIN="2026.8.21"
_REMNANODE_VER="$_REMNANODE_VER_PIN"
RN_VERSION="$_REMNANODE_VER_PIN"
SCRIPT_VERSION="$_REMNANODE_VER_PIN"

# Если запущены через bash <(curl …) (/dev/fd/…) — копируем себя в файл и
# перезапускаемся. Иначе в Termius/SSH часто «пропадают» prompt и шаги.
_SRC="${BASH_SOURCE[0]:-$0}"
if [[ "$_SRC" == /dev/fd/* || "$_SRC" == /proc/self/fd/* || "$_SRC" == /dev/stdin ]]; then
  _RN_TMP="$(mktemp /tmp/remnanode-run.XXXXXX.sh)"
  cat "$_SRC" > "$_RN_TMP"
  chmod +x "$_RN_TMP"
  # не оставляем копию скрипта в /tmp после завершения
  exec bash -c 'trap "rm -f \"$1\"" EXIT; shift; exec bash "$0" "$@"' "$_RN_TMP" "$_RN_TMP" "$@"
fi
APP="remnanode"
DIR="/opt/$APP"
COMPOSE="$DIR/docker-compose.yml"
ENV_FILE="$DIR/.env"
LOG="/var/log/${APP}-install.log"
SPEEDTEST_DIR="$DIR/tests"
SPEEDTEST_LAST="$SPEEDTEST_DIR/speedtest-last.txt"
SPEEDTEST_LOG="$SPEEDTEST_DIR/speedtest-history.log"
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
GREEN='\033[1;32m'; RED='\033[1;31m'; BLUE='\033[1;34m'; YELLOW='\033[1;33m'
CYAN='\033[1;36m'; WHITE='\033[1;37m'; GRAY='\033[0;37m'; BOLD='\033[1m'
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
ok()   { _msg "$GREEN" "✅" "$1"; }
info() { _msg "$CYAN" "ℹ️ " "$1"; }
warn() { _msg "$YELLOW" "⚠️ " "$1"; }
err()  {
  _msg "$RED" "❌" "$1"
  _msg "$GRAY" "📋" "последние строки лога → ${LOG}"
  tail -n 30 "$LOG" 2>/dev/null >"$_TTY" || tail -n 30 "$LOG" 2>/dev/null || true
  exit 1
}

mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
# Не затираем лог при каждом запуске — только ротация если > 2 МБ
if [[ -f "$LOG" ]] && [[ "$(wc -c <"$LOG" 2>/dev/null || echo 0)" -gt 2097152 ]]; then
  tail -c 1048576 "$LOG" >"${LOG}.tmp" 2>/dev/null && mv -f "${LOG}.tmp" "$LOG" || true
fi
{
  echo
  echo "======== $(date '+%F %T') | start pid=$$ ========"
} >>"$LOG" 2>/dev/null || true
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

# Секретный ввод: короткая маска (макс. 12 «•») + счётчик символов в той же строке.
# Длинные ключи Remnawave (~2–3 КБ) больше не заливают экран тысячами точек.
ask_secret() {
  local prompt="$1" varname="$2"
  local _ans="" _char="" _tty_in="/dev/tty"
  local _mask_max=12 _n _dots _i _show
  [[ -r $_tty_in ]] || _tty_in="/dev/stdin"

  local _stty_save=""
  _stty_save=$(stty -g <"$_tty_in" 2>/dev/null || true)
  stty -echo -icanon min 1 time 0 <"$_tty_in" 2>/dev/null || true

  # первая отрисовка
  _tty_printf '\r\033[K  %b%s%b: %b[0]%b' "$WHITE" "$prompt" "$NC" "$GRAY" "$NC"

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
      else
        continue
      fi
    elif [[ "$_char" == $'\x03' ]]; then
      # Ctrl-C — вернуться в меню, не валить весь скрипт
      [[ -n "$_stty_save" ]] && stty "$_stty_save" <"$_tty_in" 2>/dev/null || true
      _tty_echo ""
      warn "Ввод прерван"
      printf -v "$varname" '%s' ""
      return 1
    elif [[ "$_char" < ' ' ]]; then
      continue
    else
      _ans+="$_char"
    fi

    _n=${#_ans}
    _dots=""
    _show=$_n
    (( _show > _mask_max )) && _show=$_mask_max
    for ((_i = 0; _i < _show; _i++)); do _dots+="•"; done
    _tty_printf '\r\033[K  %b%s%b: %s%b  [%s]%b' \
      "$WHITE" "$prompt" "$NC" "$_dots" "$GRAY" "$_n" "$NC"
  done

  [[ -n "$_stty_save" ]] && stty "$_stty_save" <"$_tty_in" 2>/dev/null || stty sane <"$_tty_in" 2>/dev/null || true
  _tty_echo ""
  if [[ -n "$_ans" ]]; then
    _tty_printf "  %b👁  принято, символов: %s%b\n" "$GRAY" "${#_ans}" "$NC"
  else
    _tty_printf "  %b(пусто)%b\n" "$YELLOW" "$NC"
  fi
  printf -v "$varname" '%s' "$_ans"
}

# Короткий выбор пункта меню
ask_choice() {
  local varname="$1" prompt="${2:->}"
  local _ans
  # пробел после emoji-prompt (👉/👉 ), чтобы не слипалось с курсором
  case "$prompt" in
    *[[:space:]]) ;;
    *) prompt="${prompt} " ;;
  esac
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

# Полоса загрузки — ОДНА строка, ширина << терминала (иначе Termius
# переносит строку и \r рисует «диагональный дождь» как на скрине).
_PROGRESS_W=12
_PROGRESS_COLS="${COLUMNS:-80}"
# ширина tty (тихо; если нет — оставляем COLUMNS/80)
if [[ -r /dev/tty ]]; then
  _tc=$(stty size </dev/tty 2>/dev/null | awk '{print $2}' || true)
  [[ -n "$_tc" && "$_tc" -gt 0 ]] && _PROGRESS_COLS="$_tc"
fi
[[ "$_PROGRESS_COLS" =~ ^[0-9]+$ ]] || _PROGRESS_COLS=80
(( _PROGRESS_COLS < 40 )) && _PROGRESS_COLS=80
# весь прогресс-текст держим ≤ 56 колонок (с запасом для узких Termius)
_PROGRESS_MAX=56
(( _PROGRESS_MAX > _PROGRESS_COLS - 2 )) && _PROGRESS_MAX=$((_PROGRESS_COLS - 2))
(( _PROGRESS_MAX < 36 )) && _PROGRESS_MAX=36
unset _tc

_progress_bar_frame() {
  local pos=$1 w="${_PROGRESS_W}" i bar="" head=3
  local p=$((pos % (w + head)))
  for ((i = 0; i < w; i++)); do
    local d=$((i - p))
    if (( d == 0 )); then bar+="▓"
    elif (( d == 1 )); then bar+="█"
    elif (( d == 2 )); then bar+="▓"
    else bar+="░"
    fi
  done
  printf '%s' "$bar"
}

_progress_bar_done() {
  local w="${_PROGRESS_W}" i bar=""
  for ((i = 0; i < w; i++)); do bar+="█"; done
  printf '%s' "$bar"
}

_progress_bar_fail() {
  local w="${_PROGRESS_W}" i bar=""
  for ((i = 0; i < w; i++)); do bar+="▒"; done
  printf '%s' "$bar"
}

# Обрезать строку по видимым символам (без учёта ANSI)
_progress_trunc() {
  local s="$1" max="$2"
  if (( ${#s} > max )); then
    printf '%s' "${s:0:$((max - 1))}…"
  else
    printf '%s' "$s"
  fi
}

# Одна короткая строка: очистка + \r (без гигантского pad → без wrap)
_progress_draw() {
  local bar="$1" msg="$2" suffix="$3" color="${4:-$CYAN}"
  # бюджет: 2 + bar(12) + 1 + msg + 1 + suffix ≤ _PROGRESS_MAX
  local budget=$((_PROGRESS_MAX - 2 - _PROGRESS_W - 1 - 1 - ${#suffix}))
  (( budget < 8 )) && budget=8
  local m
  m=$(_progress_trunc "$msg" "$budget")
  # \033[2K — стереть ВСЮ строку, затем \r в начало
  _tty_printf '\033[2K\r  %b%s%b %s %b%s%b' \
    "$color" "$bar" "$NC" "$m" "$GRAY" "$suffix" "$NC"
}

spin() {
  local pid=$1 msg=$2
  local i=0 start=$SECONDS el=0 bar
  trap '_tty_printf "\033[?25h\r\033[2K"' RETURN
  _tty_printf '\033[?25l'
  bar=$(_progress_bar_frame 0)
  _progress_draw "$bar" "$msg" "0с" "$CYAN"
  while kill -0 "$pid" 2>/dev/null; do
    el=$((SECONDS - start))
    bar=$(_progress_bar_frame "$i")
    _progress_draw "$bar" "$msg" "${el}с" "$CYAN"
    i=$((i + 1))
    sleep 0.15
  done
  wait "$pid"
  local rc=$?
  el=$((SECONDS - start))
  # финальная строка — тоже короткая и понятная
  _tty_printf '\033[2K\r'
  if [[ $rc -eq 0 ]]; then
    _tty_printf '  %b✅%b %s %b— готово (%sс)%b\n' \
      "$GREEN" "$NC" "$msg" "$GRAY" "$el" "$NC"
  else
    _tty_printf '  %b❌%b %s %b— ошибка (%sс)%b\n' \
      "$RED" "$NC" "$msg" "$GRAY" "$el" "$NC"
  fi
  _tty_printf '\033[?25h'
  trap - RETURN
  return "$rc"
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

# Мягкий шаг: fail не валит установку (тюнинг, optional)
run_step_soft() {
  local msg="$1" cmd="$2"
  echo "=== $(date '+%F %T') | $msg (soft) ===" >&3
  ( eval "$cmd" >&3 2>&3 ) &
  local pid=$!
  if ! spin "$pid" "$msg"; then
    warn "└─ шаг пропущен (некритично): $msg — см. ${LOG}"
    return 0
  fi
  return 0
}

# Запуск функции со спиннером; UI info/warn/ok функции глушатся (идут в лог)
# Возврат = код функции. Пример: spin_fn "apt update" apt_update_safe
spin_fn() {
  local msg="$1"; shift
  echo "=== $(date '+%F %T') | $msg ===" >&3
  (
    ok()   { echo "OK: $*" >&3; }
    info() { echo "INFO: $*" >&3; }
    warn() { echo "WARN: $*" >&3; }
    "$@"
  ) &
  local pid=$!
  spin "$pid" "$msg"
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
  local candidate bust
  bust="$(date +%s)"
  while IFS= read -r candidate; do
    [[ -z "$candidate" ]] && continue
    # anti-cache для raw.githubusercontent / зеркал
    if [[ "$candidate" == *"raw.githubusercontent.com"* || "$candidate" == *"ghfast.top"* || "$candidate" == *"ghproxy.com"* ]]; then
      if [[ "$candidate" == *\?* ]]; then
        candidate="${candidate}&_=${bust}"
      else
        candidate="${candidate}?_=${bust}"
      fi
    fi
    if curl -fsSL --connect-timeout 8 --max-time 120 --retry 2 \
        -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' \
        -o "$dest" "$candidate" 2>/dev/null; then
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

# os-release задаёт VERSION=... — жёстко восстанавливаем pin версии лаунчера
. /etc/os-release
_REMNANODE_VER="$_REMNANODE_VER_PIN"
RN_VERSION="$_REMNANODE_VER_PIN"
SCRIPT_VERSION="$_REMNANODE_VER_PIN"
case "$ID" in
  ubuntu|debian) ;;
  *) err "Поддерживается только Ubuntu/Debian. Найдено: $ID" ;;
esac

ARCH=$(dpkg --print-architecture 2>/dev/null || echo amd64)
CODENAME=${VERSION_CODENAME:-}
if [[ -z "$CODENAME" ]]; then
  CODENAME=$(lsb_release -cs 2>/dev/null || true)
fi
if [[ -z "$CODENAME" ]]; then
  case "${VERSION_ID:-}" in
    24.04*) CODENAME=noble ;;
    22.04*) CODENAME=jammy ;;
    20.04*) CODENAME=focal ;;
    12*)    CODENAME=bookworm ;;
    11*)    CODENAME=bullseye ;;
    *)      CODENAME=noble ;;
  esac
  warn "VERSION_CODENAME пуст — используем ${CODENAME}"
fi
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

# Актуальная версия лаунчера (никогда не пустая, никогда не из os-release)
launcher_version() {
  local v=""
  v="${_REMNANODE_VER_PIN:-}"
  [[ -n "$v" ]] || v="${_REMNANODE_VER:-}"
  [[ -n "$v" ]] || v="${RN_VERSION:-}"
  [[ -n "$v" ]] || v="${SCRIPT_VERSION:-}"
  # Запасной путь: первая строка вида _REMNANODE_VER="YYYY...."
  if [[ -z "$v" || "$v" == "unknown" ]]; then
    local src="${BASH_SOURCE[0]:-$0}"
    if [[ -f "$src" ]]; then
      v=$(grep -E '^_REMNANODE_VER(_PIN)?="[0-9]{4}\.' "$src" 2>/dev/null | head -1 \
        | sed -E 's/^[^=]+=//; s/["'\'']//g; s/[[:space:]]//g' || true)
    fi
  fi
  [[ -n "$v" ]] || v="0.0.0"
  _REMNANODE_VER="$v"
  RN_VERSION="$v"
  SCRIPT_VERSION="$v"
  printf '%s' "$v"
}

show_header() {
  ui_clear
  local ver
  ver=$(launcher_version)

  # Рамка ASCII + цвет; emoji только вне линий фиксированной ширины
  _tty_printf '%b' "${CYAN}${BOLD}"
  _tty_echo "  =================================================="
  _tty_echo "   🚀  REMNANODE LAUNCHER"
  _tty_printf '%b' "${NC}${CYAN}"
  _tty_echo "   версия ${ver}"
  _tty_printf '%b' "${GRAY}"
  _tty_echo "   🛰️ Нода · 🎭 Selfsteal · ⚡ H2 · 🔒 Прокси · 🧪 Тесты"
  _tty_printf '%b' "${CYAN}${BOLD}"
  _tty_echo "  =================================================="
  _tty_printf '%b' "${NC}"
  _tty_echo ""
  _tty_printf '  %b💻 OS:%b        %s\n' "$WHITE" "$NC" "${PRETTY_NAME:-$ID}"
  _tty_printf '  %b🧠 CPU/RAM:%b   %s\n' "$WHITE" "$NC" "${CPU} cores | ${RAM_MB} MB | ${ARCH}"
  _tty_printf '  %b🌐 Public IP:%b %b%s%b\n' "$WHITE" "$NC" "$CYAN" "${PUBLIC_IP:-n/a}" "$NC"
  _tty_printf '  %b🏠 Local IP:%b  %s\n' "$WHITE" "$NC" "${LOCAL_IP:-n/a}"
  # Порт ноды: «слушает» = процесс, «firewall» = наше OPEN (не UFW)
  local _np
  _np=$(get_node_port 2>/dev/null || true)
  if [[ -n "$_np" ]]; then
    local _listen_lbl _fw_lbl
    if is_node_port_listening "$_np"; then
      _listen_lbl="${GREEN}[слушает]${NC}"
    else
      _listen_lbl="${RED}[не слушает]${NC}"
    fi
    if _ports_has OPEN tcp "$_np" 2>/dev/null; then
      _fw_lbl="${GREEN}[firewall OPEN]${NC}"
    else
      _fw_lbl="${GRAY}[firewall —]${NC}"
    fi
    _tty_printf '  %b🔌 NODE_PORT:%b  %b%s%b  %b  %b\n' \
      "$WHITE" "$NC" "$CYAN" "$_np" "$NC" "$_listen_lbl" "$_fw_lbl"
  fi
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
      # /opt/remnanode есть и у лаунчера (installer.sh) — это НЕ установка ноды
      local np
      np=$(get_node_port 2>/dev/null || true)
      if is_remnanode_up; then
        if [[ -n "$np" ]] && is_node_port_listening "$np"; then
          echo "работает :${np}"
        elif [[ -n "$np" ]]; then
          echo "порт :${np} ✗"
        else
          echo "работает"
        fi
      elif is_remnanode_installed; then
        if [[ -n "$np" ]]; then
          echo "офлайн :${np}"
        else
          echo "установлен"
        fi
      else
        echo "не установлен"
      fi
      ;;
    selfsteal)
      # Не считать «установленным» просто из‑за /opt/caddy (чужой Caddy)
      if docker ps --format '{{.Names}}' 2>/dev/null | grep -qiE 'selfsteal'; then
        echo "работает"
      elif [[ -f /opt/caddy/docker-compose.yml ]] || [[ -f /opt/nginx-selfsteal/docker-compose.yml ]]; then
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -qiE '^(caddy|nginx)(-|$)'; then
          echo "работает"
        else
          echo "установлен"
        fi
      elif [[ -d /opt/nginx-selfsteal ]]; then
        echo "установлен"
      else
        echo "не установлен"
      fi
      ;;
    warp)
      if command -v warp-cli >/dev/null 2>&1; then
        local _ws=""
        _ws=$(warp-cli --accept-tos status 2>/dev/null || true)
        if echo "$_ws" | grep -qiE 'connected|Status[[:space:]]*[:=]?[[:space:]]*Connected'; then
          if ss -tlnp 2>/dev/null | grep -qE ":${WARP_PORT}\\b"; then
            echo "подключён"
          else
            echo "установлен"
          fi
        else
          echo "установлен"
        fi
      else
        echo "не установлен"
      fi
      ;;
    hysteria)
      if docker ps --format '{{.Names}}' 2>/dev/null | grep -qiE 'hysteria'; then
        echo "настроено"
      elif [[ -f /opt/hysteria/config.yaml ]] || [[ -f /opt/hysteria/config.json ]]; then
        echo "настроено"
      elif [[ -d /opt/hysteria/certs ]] && compgen -G '/opt/hysteria/certs/*' >/dev/null 2>&1; then
        echo "настроено"
      elif [[ -f "$COMPOSE" ]] && grep -qE 'hysteria|/opt/hysteria' "$COMPOSE" 2>/dev/null; then
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
    antiddos)
      if antiddos_active; then
        if [[ -f "$DDOS_CONF" ]] && grep -q '^SYNPROXY=1' "$DDOS_CONF" 2>/dev/null; then
          echo "SYNPROXY"
        else
          echo "активен"
        fi
      else
        echo "не активен"
      fi
      ;;
    ports)
      local n_open=0 n_block=0
      if [[ -f "$PORTS_CONF" ]]; then
        n_open=$(grep -cE '^OPEN[[:space:]]' "$PORTS_CONF" 2>/dev/null || true)
        n_block=$(grep -cE '^BLOCK[[:space:]]' "$PORTS_CONF" 2>/dev/null || true)
        n_open=${n_open:-0}
        n_block=${n_block:-0}
      fi
      if (( n_open + n_block > 0 )); then
        if ports_active 2>/dev/null; then
          echo "OPEN ${n_open}/BLOCK ${n_block}"
        else
          echo "сохранены"
        fi
      else
        echo "не настроен"
      fi
      ;;
    node_cli)
      local np
      np=$(get_node_port 2>/dev/null || true)
      if is_remnanode_up; then
        if [[ -n "$np" ]] && is_node_port_listening "$np"; then
          echo "online :${np}"
        elif [[ -n "$np" ]]; then
          echo "online, :${np} ✗"
        else
          echo "нода online"
        fi
      elif is_remnanode_installed; then
        if [[ -n "$np" ]]; then
          echo "offline :${np}"
        else
          echo "нода offline"
        fi
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
    "работает"|"подключён"|"настроено"|"патч активен"|"BBR включён"|"нода online"|"SYNPROXY")
      _badge "$GREEN" "$text"
      ;;
    работает\ :*|online\ :*|OPEN\ *)
      _badge "$GREEN" "$text"
      ;;
    активен*)
      _badge "$GREEN" "$text"
      ;;
    "установлен"|"ядро скачано"|"частично"|"выключен"|"только CLI"|"нода offline"|"сохранены")
      _badge "$YELLOW" "$text"
      ;;
    офлайн\ :*|offline\ :*)
      _badge "$YELLOW" "$text"
      ;;
    порт\ :*|online,\ :*)
      _badge "$RED" "$text"
      ;;
    "не установлен"|"не настроено"|"не применён"|"не создан"|"не настроен"|"нет CLI"|"неизвестно"|"не активен")
      _badge "$RED" "$text"
      ;;
    *)
      _badge "$YELLOW" "$text"
      ;;
  esac
}

# Колонки:  ICON  NN)  TITLE........  DESC................  [STATUS]
# После emoji — минимум два ASCII-пробела (Termius «съедает» один у ☁️✈️🛡️⚙️)
menu_item() {
  local icon="$1" num="$2" title="$3" desc="$4" badge="${5:-}"
  local num_s title_s desc_s gap="  "

  # убрать хвостовые пробелы у icon, зазор задаём сами
  icon="${icon%"${icon##*[![:space:]]}"}"
  num_s=$(pad_right "${num})" 4)
  title_s=$(pad_right "$title" 12)
  desc_s=$(pad_right "$desc" 20)

  _tty_printf '  %s%s%b%s%b %b%s%b %b%s%b'     "$icon" "$gap" "$WHITE" "$num_s" "$NC" "$WHITE" "$title_s" "$NC" "$GRAY" "$desc_s" "$NC"
  if [[ -n "$badge" ]]; then
    _tty_printf '  '
    service_badge_color "$badge"
  fi
  _tty_printf '\n'
}

section() {
  local title="$1" lead rest
  _tty_echo ""
  # emoji + два ASCII-пробела + текст (Termius часто «съедает» один пробел)
  if [[ "$title" == *" "* ]]; then
    lead="${title%% *}"
    rest="${title#* }"
    # схлопнуть лишние пробелы в начале rest
    rest="${rest#"${rest%%[![:space:]]*}"}"
    title="${lead}  ${rest}"
  fi
  _tty_printf '  %b%s%b\n' "${WHITE}${BOLD}" "$title" "$NC"
  hline 56
}

###############################################################################
# Базовые пакеты (без SWAP/UFW — они отдельными пунктами)
###############################################################################

# Паттерны битых/ненужных сторонних репозиториев (ломают apt update на noble+)
_APT_BAD_RE_='packagecloud\.io/ookla|ookla/speedtest|speedtest-cli|packagecloud\.io/.*/speedtest'

# Занят ли apt/dpkg (лок или живой процесс)?
_apt_is_busy() {
  local l
  for l in \
    /var/lib/dpkg/lock-frontend \
    /var/lib/dpkg/lock \
    /var/lib/apt/lists/lock \
    /var/cache/apt/archives/lock
  do
    [[ -e "$l" ]] || continue
    if command -v fuser >/dev/null 2>&1; then
      fuser "$l" >/dev/null 2>&1 && return 0
    elif command -v lsof >/dev/null 2>&1; then
      lsof "$l" >/dev/null 2>&1 && return 0
    elif command -v flock >/dev/null 2>&1; then
      flock -n "$l" -c true 2>/dev/null || return 0
    fi
  done
  if pgrep -x apt-get >/dev/null 2>&1 \
    || pgrep -x apt >/dev/null 2>&1 \
    || pgrep -x dpkg >/dev/null 2>&1 \
    || pgrep -x unattended-upgr >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# PID-ы, держащие apt/dpkg lock
_apt_lock_pids() {
  local l pids=""
  for l in \
    /var/lib/dpkg/lock-frontend \
    /var/lib/dpkg/lock \
    /var/lib/apt/lists/lock \
    /var/cache/apt/archives/lock
  do
    [[ -e "$l" ]] || continue
    if command -v fuser >/dev/null 2>&1; then
      pids+=" $(fuser "$l" 2>/dev/null | tr -s ' ' || true)"
    fi
  done
  # плюс известные фоновые
  pids+=" $(pgrep -x unattended-upgr 2>/dev/null || true)"
  pids+=" $(pgrep -x packagekitd 2>/dev/null || true)"
  printf '%s' "$pids" | tr -s ' ' '\n' | grep -E '^[0-9]+$' | sort -u
}

# Можно ли безопасно убить процесс (фоновый update/upgrade, не наш install)
_apt_pid_is_background() {
  local pid="$1" args
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  # не трогаем себя
  [[ "$pid" == "$$" ]] && return 1
  args=$(ps -p "$pid" -o args= 2>/dev/null || true)
  [[ -z "$args" ]] && return 1
  # unattended / packagekit / daily
  echo "$args" | grep -qiE 'unattended-upgrade|packagekit|apt\.systemd\.daily' && return 0
  # apt-get update / upgrade / dist-upgrade / autoclean (не наш install -y docker)
  if echo "$args" | grep -qE 'apt-get|apt '; then
    echo "$args" | grep -qE ' (update|upgrade|dist-upgrade|full-upgrade|autoclean|autoremove)( |$)' && return 0
    # cloud-init стиль: apt-get --assume-yes --quiet update
    echo "$args" | grep -qE -- '--quiet update|--quiet dist-upgrade|--quiet upgrade' && return 0
  fi
  return 1
}

# Остановить авто-apt Ubuntu/cloud-init и убрать фоновые update/dist-upgrade
apt_takeover() {
  # таймеры/сервисы — runtime mask до ребута
  systemctl stop unattended-upgrades.service 2>/dev/null || true
  systemctl stop apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
  systemctl stop packagekit.service 2>/dev/null || true
  systemctl kill --kill-who=all apt-daily.service 2>/dev/null || true
  systemctl kill --kill-who=all apt-daily-upgrade.service 2>/dev/null || true
  systemctl kill --kill-who=all unattended-upgrades.service 2>/dev/null || true
  systemctl mask --runtime apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
  systemctl mask --runtime unattended-upgrades.service 2>/dev/null || true

  local pid args killed=0
  while IFS= read -r pid; do
    [[ -z "$pid" ]] && continue
    if _apt_pid_is_background "$pid"; then
      args=$(ps -p "$pid" -o args= 2>/dev/null | head -c 120 || true)
      info "Останавливаю фоновый apt (pid ${pid}): ${args}"
      kill -TERM "$pid" 2>/dev/null || true
      killed=1
    fi
  done < <(_apt_lock_pids)

  if (( killed )); then
    sleep 2
    # если не умер — KILL
    while IFS= read -r pid; do
      [[ -z "$pid" ]] && continue
      if _apt_pid_is_background "$pid" && kill -0 "$pid" 2>/dev/null; then
        warn "Принудительно завершаю зависший apt pid ${pid}"
        kill -KILL "$pid" 2>/dev/null || true
      fi
    done < <(_apt_lock_pids)
    sleep 1
    # dpkg мог остаться в состоянии — попробуем --configure -a мягко позже
  fi
  return 0
}

# Совместимость со старыми вызовами
apt_pause_background() { apt_takeover; }

# Ждать освобождения apt-lock. После половины таймаута — убиваем фоновый apt.
# usage: apt_wait_locks [timeout_sec]
apt_wait_locks() {
  local timeout="${1:-300}"
  local waited=0 shown=0
  local pidinfo=""
  local half=$(( timeout / 2 ))
  (( half < 15 )) && half=15

  apt_takeover

  while _apt_is_busy; do
    if (( waited >= timeout )); then
      warn "apt-блокировка не снялась за ${timeout}с — последний шанс: kill фонового apt"
      apt_takeover
      sleep 2
      if _apt_is_busy; then
        warn "apt всё ещё занят"
        if command -v fuser >/dev/null 2>&1; then
          fuser -v /var/lib/apt/lists/lock /var/lib/dpkg/lock-frontend 2>&1 | sed 's/^/    /' >&3 || true
        fi
        return 1
      fi
      return 0
    fi
    if (( shown == 0 )); then
      pidinfo=$(pgrep -a -x apt-get 2>/dev/null | head -2 || true)
      [[ -z "$pidinfo" ]] && pidinfo=$(pgrep -a unattended-upgr 2>/dev/null | head -1 || true)
      if [[ -n "$pidinfo" ]]; then
        info "⏳ Жду освобождения apt (занято: ${pidinfo})…"
      else
        info "⏳ Жду освобождения apt-блокировки…"
      fi
      shown=1
    fi
    # после половины таймаута — агрессивно гасим фоновые update/upgrade
    if (( waited >= half )); then
      apt_takeover
    else
      (( waited % 20 == 0 )) && apt_takeover
    fi
    sleep 3
    waited=$((waited + 3))
  done
  return 0
}

_apt_err_is_lock() {
  local f="$1"
  grep -qiE 'Could not get lock|Unable to lock directory|Unable to acquire the dpkg frontend lock|is another process using it' "$f" 2>/dev/null
}

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

# Надёжный + быстрый apt-get update.
# Кэш TTL; таймауты зеркал; жёсткий лимит на одну попытку (не висеть 8 минут).
# Принудительно: apt_update_safe force  (после добавления docker/cloudflare репо).
_APT_UPDATE_TTL="${_APT_UPDATE_TTL:-1800}"   # 30 минут
_APT_UPDATED_AT=0
_APT_STAMP_FILE="/var/cache/remnanode/apt-updated.stamp"
# Одна попытка apt-get update не дольше N секунд (иначе timeout)
_APT_UPDATE_TIMEOUT="${_APT_UPDATE_TIMEOUT:-90}"
_APT_ACQUIRE=(
  -o Acquire::Retries=1
  -o Acquire::http::Timeout=15
  -o Acquire::https::Timeout=15
  -o Acquire::ftp::Timeout=15
  -o Acquire::Languages=none
)

_apt_lists_fresh() {
  local now stamp age newest
  now=$(date +%s)

  # 1) уже обновляли в этой сессии лаунчера
  if (( _APT_UPDATED_AT > 0 )); then
    age=$((now - _APT_UPDATED_AT))
    if (( age >= 0 && age < _APT_UPDATE_TTL )); then
      return 0
    fi
  fi

  # 2) stamp от прошлого успешного update нашего скрипта
  if [[ -f "$_APT_STAMP_FILE" ]]; then
    stamp=$(tr -dc '0-9' <"$_APT_STAMP_FILE" 2>/dev/null | head -c 12 || true)
    stamp=${stamp:-0}
    if [[ "$stamp" =~ ^[0-9]+$ ]] && (( stamp > 0 )); then
      age=$((now - stamp))
      if (( age >= 0 && age < _APT_UPDATE_TTL )); then
        _APT_UPDATED_AT=$stamp
        return 0
      fi
    fi
  fi

  # 3) mtime файлов /var/lib/apt/lists (система недавно обновляла сама)
  newest=$(find /var/lib/apt/lists -maxdepth 1 -type f \
    ! -name 'lock' ! -name '*partial*' ! -name 'auxfiles' \
    -printf '%T@\n' 2>/dev/null | sort -nr | head -1 | cut -d. -f1 || true)
  if [[ -n "$newest" && "$newest" =~ ^[0-9]+$ ]]; then
    age=$((now - newest))
    if (( age >= 0 && age < _APT_UPDATE_TTL )); then
      return 0
    fi
  fi
  return 1
}

_apt_mark_updated() {
  _APT_UPDATED_AT=$(date +%s)
  mkdir -p "$(dirname "$_APT_STAMP_FILE")" 2>/dev/null || true
  printf '%s\n' "$_APT_UPDATED_AT" >"$_APT_STAMP_FILE" 2>/dev/null || true
}

# Запуск apt-get update с жёстким таймаутом (не висеть на мёртвых зеркалах)
_apt_get_update() {
  local errfile="$1"; shift
  local rc=0
  if command -v timeout >/dev/null 2>&1; then
    timeout "$_APT_UPDATE_TIMEOUT" apt-get update "${_APT_ACQUIRE[@]}" "$@" >"$errfile" 2>&1
    rc=$?
    # 124 = timeout
    if (( rc == 124 )); then
      echo "=== apt-get update TIMEOUT after ${_APT_UPDATE_TIMEOUT}s ===" >>"$errfile"
      return 124
    fi
    return "$rc"
  fi
  apt-get update "${_APT_ACQUIRE[@]}" "$@" >"$errfile" 2>&1
}

# usage: apt_update_safe [force]
apt_update_safe() {
  local force="${1:-0}"
  case "$force" in
    force|--force|1|yes|Y|y) force=1 ;;
    *) force=0 ;;
  esac

  if [[ "$force" != "1" ]] && _apt_lists_fresh; then
    local now age=0
    now=$(date +%s)
    if (( _APT_UPDATED_AT > 0 )); then
      age=$(( now - _APT_UPDATED_AT ))
    fi
    (( _APT_UPDATED_AT == 0 )) && _APT_UPDATED_AT=$now
    if (( age >= 60 )); then
      info "apt уже актуален (~$((age / 60)) мин) — пропускаю update"
    else
      info "apt уже актуален — пропускаю update"
    fi
    echo "=== $(date '+%F %T') | apt-get update SKIPPED (fresh, ttl=${_APT_UPDATE_TTL}s) ===" >&3
    return 0
  fi

  local errfile="/tmp/rn-apt-update.err"
  local attempt=1
  local max=3
  local lock_rounds=0

  sanitize_apt_repos
  apt_wait_locks 60 || true

  while (( attempt <= max )); do
    apt_wait_locks 45 || true
    echo "=== $(date '+%F %T') | apt-get update (попытка ${attempt}/${max}, timeout=${_APT_UPDATE_TIMEOUT}s) ===" >&3
    if _apt_get_update "$errfile"; then
      _apt_mark_updated
      return 0
    fi
    cat "$errfile" >&3 2>/dev/null || true

    if _apt_err_is_lock "$errfile"; then
      lock_rounds=$((lock_rounds + 1))
      if (( lock_rounds > 4 )); then
        warn "apt-блокировка не отпускает — пропускаю update"
        break
      fi
      warn "apt занят — жду (${lock_rounds}/4)…"
      apt_wait_locks 60 || sleep 3
      continue
    fi

    # Битый third-party — отключаем и пробуем снова
    if grep -qiE 'does not have a Release file|NO_PUBKEY|not signed|Release file|404[[:space:]]+Not Found|packagecloud|ookla|speedtest' "$errfile" 2>/dev/null; then
      warn "apt: битый репозиторий — отключаю (${attempt}/${max})…"
      apt_disable_from_errors "$errfile"
      sanitize_apt_repos
      attempt=$((attempt + 1))
      continue
    fi

    # timeout / медленные зеркала — сразу пробуем только системные источники
    if grep -qiE 'TIMEOUT|Temporary failure|Connection timed out|Failed to fetch' "$errfile" 2>/dev/null \
       || [[ "$(tail -1 "$errfile" 2>/dev/null)" == *TIMEOUT* ]]; then
      warn "apt update медленный/таймаут — переключаюсь на системные репо"
      break
    fi

    attempt=$((attempt + 1))
  done

  # Быстрый резерв: только ubuntu.sources / debian.sources (+ docker/warp если есть)
  local tmpparts
  tmpparts=$(mktemp -d /tmp/rn-apt-parts.XXXXXX)
  [[ -f /etc/apt/sources.list.d/ubuntu.sources ]] && cp -a /etc/apt/sources.list.d/ubuntu.sources "$tmpparts/" || true
  [[ -f /etc/apt/sources.list.d/debian.sources ]] && cp -a /etc/apt/sources.list.d/debian.sources "$tmpparts/" || true
  [[ -f /etc/apt/sources.list ]] && cp -a /etc/apt/sources.list "$tmpparts/sources.list.bak" || true
  [[ -f /etc/apt/sources.list.d/docker.list ]] && cp -a /etc/apt/sources.list.d/docker.list "$tmpparts/" || true
  [[ -f /etc/apt/sources.list.d/cloudflare-client.list ]] && cp -a /etc/apt/sources.list.d/cloudflare-client.list "$tmpparts/" || true

  if compgen -G "$tmpparts/*" >/dev/null 2>&1; then
    warn "apt: быстрый update только системных репозиториев…"
    apt_wait_locks 45 || true
    local src_list="/dev/null"
    [[ -f "$tmpparts/sources.list.bak" ]] && src_list="$tmpparts/sources.list.bak"
    if _apt_get_update "$errfile" \
        -o Dir::Etc::sourcelist="$src_list" \
        -o Dir::Etc::sourceparts="$tmpparts" \
        -o APT::Get::List-Cleanup=0; then
      rm -rf "$tmpparts"
      ok "apt update (системные репо)"
      _apt_mark_updated
      return 0
    fi
    cat "$errfile" >&3 2>/dev/null || true
  fi
  rm -rf "$tmpparts"

  warn "apt update не идеален — продолжаю с текущим кэшем пакетов"
  return 1
}

# Быстрый update ТОЛЬКО одного нового репозитория (docker/warp)
apt_update_one_repo() {
  local listfile="$1"
  [[ -f "$listfile" ]] || return 1
  local errfile="/tmp/rn-apt-one.err"
  apt_wait_locks 45 || true
  if _apt_get_update "$errfile" \
      -o Dir::Etc::sourcelist="$listfile" \
      -o Dir::Etc::sourceparts=/dev/null \
      -o APT::Get::List-Cleanup=0; then
    return 0
  fi
  cat "$errfile" >&3 2>/dev/null || true
  return 1
}

# Каких пакетов из списка нет в системе
_pkgs_missing() {
  local p out=""
  for p in "$@"; do
    dpkg -s "$p" >/dev/null 2>&1 || out+="$p "
  done
  printf '%s' "${out% }"
}

# Минимальный набор для Docker / Remnanode / лаунчера.
# Тяжёлые утилиты (htop, fail2ban, ufw…) — не блокируют установку ноды.
ensure_packages() {
  sanitize_apt_repos
  apt_pause_background

  local want="curl ca-certificates gnupg jq"
  local missing
  # shellcheck disable=SC2086
  missing=$(_pkgs_missing $want)

  if [[ -z "$missing" ]]; then
    ok "Базовые пакеты уже установлены — пропускаю apt"
    return 0
  fi

  apt_wait_locks 30 || true
  info "Ставлю недостающее: ${missing}"
  # Сначала без update — часто хватает текущего кэша (секунды вместо минут)
  if DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
      -o APT::Get::AllowUnauthenticated=false $missing >/tmp/rn-apt-inst.err 2>&1; then
    ok "Базовые пакеты готовы (без apt update)"
    return 0
  fi
  cat /tmp/rn-apt-inst.err >&3 2>/dev/null || true

  info "Нужен apt update (лимит ~${_APT_UPDATE_TIMEOUT}с на попытку)…"
  spin_fn "обновление apt" apt_update_safe || warn "update с ошибками — пробую install из кэша"
  apt_wait_locks 45 || true
  if DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends $missing; then
    ok "Базовые пакеты готовы"
    return 0
  fi

  # Минимум для продолжения: curl + ca-certificates
  warn "Полный набор не встал — ставлю минимум (curl/ca-certificates/gnupg)"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
    curl ca-certificates gnupg || true
  command -v curl >/dev/null 2>&1 || err "Не удалось установить curl — без него дальше нельзя"
  ok "Минимальные пакеты готовы"
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

# --- Анти-DDoS: защита от SYN-флуда (L4) ---
# syncookies спасают, когда очередь SYN переполнена флудом
net.ipv4.tcp_syncookies = 1
# меньше повторов SYN/ACK — быстрее отбрасываем полуоткрытые соединения
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 3
# защита от старых/дублей SYN в TIME_WAIT (RFC1337)
net.ipv4.tcp_rfc1337 = 1
# не завышаем max_orphans, чтобы флуд не съедал память
net.ipv4.tcp_max_orphans = 262144
# быстрее убирать полуоткрытые в conntrack (SYN_RECV)
net.netfilter.nf_conntrack_tcp_timeout_syn_recv = 20
net.netfilter.nf_conntrack_tcp_timeout_syn_sent = 20
# не считать соединение invalid при потере пакета под флудом
net.netfilter.nf_conntrack_tcp_loose = 1

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

  run_step_soft "CPU governor: performance" \
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
    run_step_soft "RPS / IRQ balance" \
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
# Анти-DDoS (L4): nftables — SYN-флуд, мусорные пакеты, пер-IP лимиты
# Совместимо с Remnawave: policy accept, режем только явный мусор и флуд.
###############################################################################
DDOS_DIR="/etc/remnanode"
DDOS_RULES="$DDOS_DIR/ddos.nft"
DDOS_CONF="$DDOS_DIR/ddos.conf"
DDOS_UNIT="/etc/systemd/system/remna-ddos.service"
DDOS_TABLE="remna_ddos"

# Значения по умолчанию (щедрые, чтобы не резать легитимных VPN-клиентов)
DDOS_SYN_RATE_DEFAULT=60        # новых SYN в секунду с одного IP
DDOS_SYN_BURST_DEFAULT=120
DDOS_CONN_PER_IP_DEFAULT=400    # одновременных соединений с одного IP
DDOS_GLOBAL_SYN_DEFAULT=15000   # глобальный потолок новых SYN/с (бэкстоп)
DDOS_ICMP_RATE_DEFAULT=50

antiddos_active() {
  command -v nft >/dev/null 2>&1 || return 1
  nft list table inet "$DDOS_TABLE" >/dev/null 2>&1
}

# Собрать список защищаемых TCP-портов (нода + типовые VPN + SSH)
_ddos_service_ports() {
  local node_port ssh_port ports
  node_port=$(cat "$DIR/.node_port" 2>/dev/null || echo "")
  ssh_port=$(grep -E '^[[:space:]]*Port[[:space:]]+' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | tail -1)
  [[ -z "$ssh_port" ]] && ssh_port=22
  ports="22, 80, 443"
  [[ -n "$ssh_port" && "$ssh_port" != "22" ]] && ports="$ports, $ssh_port"
  [[ -n "$node_port" ]] && ports="$ports, $node_port"
  # уникализируем
  echo "$ports" | tr ',' '\n' | sed 's/[[:space:]]//g' | grep -E '^[0-9]+$' \
    | sort -un | paste -sd, -
}

_ddos_write_rules() {
  local syn_rate="$1" syn_burst="$2" conn_ip="$3" gsyn="$4" icmp_rate="$5" synproxy="$6"
  local ports mss
  ports=$(_ddos_service_ports)
  [[ -z "$ports" ]] && ports="22, 80, 443"
  mss=1400

  mkdir -p "$DDOS_DIR"

  local synproxy_pre="" synproxy_in=""
  if [[ "$synproxy" == "1" ]]; then
    synproxy_pre="
    # SYNPROXY: не трекать входящие SYN до валидации (снимает нагрузку с conntrack)
    chain pre_synproxy {
        type filter hook prerouting priority raw; policy accept;
        tcp dport { ${ports} } tcp flags syn / fin,syn,rst,ack ct state new notrack
    }"
    synproxy_in="
        # SYNPROXY на сервисных портах — аппаратно-подобная защита от SYN-флуда
        tcp dport { ${ports} } tcp flags syn / fin,syn,rst,ack ct state untracked synproxy mss ${mss} wscale 7 timestamp sack-perm
        tcp dport { ${ports} } ct state invalid drop"
  fi

  cat > "$DDOS_RULES" <<NFT
#!/usr/sbin/nft -f
# remnanode anti-DDoS (L4). policy accept — режем только мусор и флуд.
# Управление: команда remnanode → меню → Анти-DDoS
table inet ${DDOS_TABLE}
delete table inet ${DDOS_TABLE}
table inet ${DDOS_TABLE} {
${synproxy_pre}
    chain input {
        type filter hook input priority mangle; policy accept;

        # loopback и уже установленные соединения — не трогаем
        iif "lo" accept
        ct state established,related accept

        # битые/фейковые пакеты conntrack
        ct state invalid drop
${synproxy_in}

        # Мусорные комбинации TCP-флагов (сканеры/флуд)
        tcp flags & (fin|syn) == (fin|syn) drop
        tcp flags & (syn|rst) == (syn|rst) drop
        tcp flags & (fin|rst) == (fin|rst) drop
        tcp flags & (fin|ack) == fin drop
        tcp flags & (ack|urg) == urg drop
        tcp flags & (fin|syn|rst|psh|ack|urg) == 0 drop
        tcp flags & (fin|syn|rst|psh|ack|urg) == (fin|syn|rst|psh|ack|urg) drop

        # Глобальный бэкстоп по новым SYN (до syncookies)
        tcp flags syn / fin,syn,rst,ack ct state new limit rate over ${gsyn}/second burst 5000 packets drop

        # Пер-IP лимит новых SYN на сервисные порты (анти SYN-флуд с одного источника)
        tcp dport { ${ports} } tcp flags syn / fin,syn,rst,ack ct state new \\
            meter syn_per_ip { ip saddr limit rate over ${syn_rate}/second burst ${syn_burst} packets } drop
        tcp dport { ${ports} } tcp flags syn / fin,syn,rst,ack ct state new \\
            meter syn6_per_ip { ip6 saddr limit rate over ${syn_rate}/second burst ${syn_burst} packets } drop

        # Пер-IP лимит одновременных соединений
        tcp dport { ${ports} } ct state new \\
            meter conn_per_ip { ip saddr ct count over ${conn_ip} } drop
        tcp dport { ${ports} } ct state new \\
            meter conn6_per_ip { ip6 saddr ct count over ${conn_ip} } drop

        # ICMP: пинг разрешён, но с ограничением скорости
        ip protocol icmp icmp type echo-request limit rate over ${icmp_rate}/second burst 100 packets drop
        ip6 nexthdr icmpv6 icmpv6 type echo-request limit rate over ${icmp_rate}/second burst 100 packets drop
    }
}
NFT
  chmod 0644 "$DDOS_RULES"

  cat > "$DDOS_CONF" <<CONF
SYN_RATE=${syn_rate}
SYN_BURST=${syn_burst}
CONN_PER_IP=${conn_ip}
GLOBAL_SYN=${gsyn}
ICMP_RATE=${icmp_rate}
SYNPROXY=${synproxy}
PORTS=${ports}
CONF
}

_ddos_write_unit() {
  cat > "$DDOS_UNIT" <<UNIT
[Unit]
Description=Remnanode anti-DDoS (nftables L4)
After=network-online.target nftables.service docker.service
Wants=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f ${DDOS_RULES}
ExecStop=/usr/sbin/nft delete table inet ${DDOS_TABLE}
[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload 2>/dev/null || true
}

_ddos_load_synproxy_modules() {
  modprobe nf_synproxy 2>/dev/null || modprobe nft_synproxy 2>/dev/null || true
  # для корректной работы SYNPROXY нужны syncookies + timestamps
  sysctl -qw net.ipv4.tcp_syncookies=1 2>/dev/null || true
  sysctl -qw net.ipv4.tcp_timestamps=1 2>/dev/null || true
}

apply_antiddos() {
  local synproxy="${1:-0}"
  local syn_rate="${2:-$DDOS_SYN_RATE_DEFAULT}"
  local syn_burst="${3:-$DDOS_SYN_BURST_DEFAULT}"
  local conn_ip="${4:-$DDOS_CONN_PER_IP_DEFAULT}"
  local gsyn="${5:-$DDOS_GLOBAL_SYN_DEFAULT}"
  local icmp_rate="${6:-$DDOS_ICMP_RATE_DEFAULT}"

  if ! command -v nft >/dev/null 2>&1; then
    info "Устанавливаю nftables…"
    apt_wait_locks 120 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nftables || {
      err "Не удалось установить nftables"
    }
  fi

  if [[ "$synproxy" == "1" ]]; then
    _ddos_load_synproxy_modules
  fi

  _ddos_write_rules "$syn_rate" "$syn_burst" "$conn_ip" "$gsyn" "$icmp_rate" "$synproxy"

  # Пробная загрузка правил
  if ! nft -f "$DDOS_RULES" 2>/tmp/rn-ddos.err; then
    warn "nft отклонил правила — подробности:"
    sed 's/^/    /' /tmp/rn-ddos.err >"$_TTY" 2>/dev/null || cat /tmp/rn-ddos.err || true
    if [[ "$synproxy" == "1" ]]; then
      warn "Пробую без SYNPROXY (ядро/VPS может не поддерживать)…"
      _ddos_write_rules "$syn_rate" "$syn_burst" "$conn_ip" "$gsyn" "$icmp_rate" "0"
      nft -f "$DDOS_RULES" 2>/tmp/rn-ddos.err || {
        err "Не удалось применить правила анти-DDoS"
      }
      synproxy=0
    else
      err "Не удалось применить правила анти-DDoS"
    fi
  fi

  _ddos_write_unit
  systemctl enable remna-ddos.service >/dev/null 2>&1 || true

  ok "Анти-DDoS активирован"
  echo
  echo -e "  ${WHITE}Параметры защиты:${NC}"
  echo -e "    • SYN/с на IP:        ${CYAN}${syn_rate}${NC} (burst ${syn_burst})"
  echo -e "    • Соединений на IP:   ${CYAN}${conn_ip}${NC}"
  echo -e "    • Глобальный SYN/с:   ${CYAN}${gsyn}${NC}"
  echo -e "    • ICMP echo/с:        ${CYAN}${icmp_rate}${NC}"
  if [[ "$synproxy" == "1" ]]; then
    echo -e "    • SYNPROXY:           ${GREEN}включён${NC}"
  else
    echo -e "    • SYNPROXY:           ${GRAY}выключен${NC}"
  fi
  echo -e "    • Порты:              ${GRAY}$(_ddos_service_ports)${NC}"
  echo
  info "Правила сохранены: ${DDOS_RULES} (автозагрузка после ребута)"
}

disable_antiddos() {
  nft delete table inet "$DDOS_TABLE" 2>/dev/null || true
  systemctl disable remna-ddos.service >/dev/null 2>&1 || true
  rm -f "$DDOS_UNIT" 2>/dev/null || true
  systemctl daemon-reload 2>/dev/null || true
  rm -f "$DDOS_RULES" "$DDOS_CONF" 2>/dev/null || true
  ok "Анти-DDoS отключён, правила удалены"
}

show_antiddos_status() {
  echo -e "  ${WHITE}Состояние анти-DDoS:${NC}"
  if antiddos_active; then
    echo -e "    ${GREEN}● Активен${NC}"
    if [[ -f "$DDOS_CONF" ]]; then
      sed 's/^/      /' "$DDOS_CONF"
    fi
    echo
    echo -e "  ${WHITE}Счётчики (drop-правила):${NC}"
    nft list table inet "$DDOS_TABLE" 2>/dev/null | grep -E 'drop|synproxy' | sed 's/^/    /' | head -30 || true
  else
    echo -e "    ${GRAY}○ Не активен${NC}"
  fi
}

setup_antiddos() {
  show_header
  echo -e "${WHITE}${BOLD}  🛡️  Анти-DDoS (L4 / SYN-флуд)${NC}"
  hline 56
  echo
  info "nftables-защита от SYN-флуда и мусорного L4-трафика."
  info "Политика accept — режем только явный флуд/мусор, панель работает штатно."
  echo
  show_antiddos_status
  echo
  echo -e "  ${WHITE}1)${NC} 🛡️  Включить защиту ${GRAY}(рекомендуемые лимиты)${NC}"
  echo -e "  ${WHITE}2)${NC} 🚀 Включить + SYNPROXY ${GRAY}(максимум против SYN-флуда)${NC}"
  echo -e "  ${WHITE}3)${NC} 🎚️  Включить со своими лимитами"
  echo -e "  ${WHITE}4)${NC} 📊 Показать статус и счётчики"
  echo -e "  ${WHITE}5)${NC} ♻️  Перезагрузить правила (после смены портов)"
  echo -e "  ${WHITE}6)${NC} ⛔ Отключить защиту"
  echo -e "  ${GRAY}0)${NC} 🔙 Назад"
  echo
  ask_choice ch

  case "$ch" in
    1) apply_antiddos 0 ;;
    2)
      info "SYNPROXY эффективнее всего против SYN-флуда, но требует поддержки ядра."
      apply_antiddos 1
      ;;
    3)
      local sr sb cip gs ic sp
      ask "SYN/с на один IP" sr "$DDOS_SYN_RATE_DEFAULT"
      ask "Burst SYN на IP" sb "$DDOS_SYN_BURST_DEFAULT"
      ask "Макс. соединений на IP" cip "$DDOS_CONN_PER_IP_DEFAULT"
      ask "Глобальный лимит SYN/с" gs "$DDOS_GLOBAL_SYN_DEFAULT"
      ask "ICMP echo/с" ic "$DDOS_ICMP_RATE_DEFAULT"
      ask_yes_no "Включить SYNPROXY?" sp N
      [[ "$sp" =~ ^[Yy]$ ]] && sp=1 || sp=0
      apply_antiddos "$sp" "$sr" "$sb" "$cip" "$gs" "$ic"
      ;;
    4) show_antiddos_status ;;
    5)
      if [[ -f "$DDOS_CONF" ]]; then
        # перечитать сохранённые параметры и пересобрать (порты могли измениться)
        local SYN_RATE SYN_BURST CONN_PER_IP GLOBAL_SYN ICMP_RATE SYNPROXY
        # shellcheck disable=SC1090
        . "$DDOS_CONF"
        apply_antiddos "${SYNPROXY:-0}" "${SYN_RATE}" "${SYN_BURST}" "${CONN_PER_IP}" "${GLOBAL_SYN}" "${ICMP_RATE}"
      else
        warn "Защита ещё не настраивалась — выберите пункт 1 или 2"
      fi
      ;;
    6) disable_antiddos ;;
    0) return 0 ;;
    *) ;;
  esac
}

###############################################################################
# Порты — открыть/закрыть отдельно от UFW (своя таблица nftables)
###############################################################################
PORTS_DIR="/etc/remnanode"
PORTS_CONF="$PORTS_DIR/ports.conf"
PORTS_RULES="$PORTS_DIR/ports.nft"
PORTS_UNIT="/etc/systemd/system/remna-ports.service"
PORTS_TABLE="remna_ports"

_ports_ensure_nft() {
  if ! command -v nft >/dev/null 2>&1; then
    info "Устанавливаю nftables…"
    apt_wait_locks 120 || true
    if _apt_lists_fresh 2>/dev/null; then
      :
    else
      apt_update_safe || true
    fi
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nftables; then
      warn "Не удалось установить nftables"
      return 1
    fi
  fi
  return 0
}

_ports_conf_init() {
  mkdir -p "$PORTS_DIR"
  [[ -f "$PORTS_CONF" ]] || printf '# remnanode ports (OPEN|BLOCK proto port)\n' >"$PORTS_CONF"
}

# Список: "OPEN tcp 443" / "BLOCK udp 53"
_ports_list() {
  _ports_conf_init
  grep -E '^(OPEN|BLOCK)[[:space:]]+(tcp|udp)[[:space:]]+[0-9]+' "$PORTS_CONF" 2>/dev/null || true
}

_ports_has() {
  local kind="$1" proto="$2" port="$3"
  grep -qE "^${kind}[[:space:]]+${proto}[[:space:]]+${port}\$" "$PORTS_CONF" 2>/dev/null
}

_ports_add_line() {
  local kind="$1" proto="$2" port="$3"
  _ports_conf_init
  # убрать противоположное/дубликаты для того же proto+port
  sed -i -E "/^(OPEN|BLOCK)[[:space:]]+${proto}[[:space:]]+${port}\$/d" "$PORTS_CONF" 2>/dev/null || true
  printf '%s %s %s\n' "$kind" "$proto" "$port" >>"$PORTS_CONF"
}

_ports_del_line() {
  local proto="$1" port="$2"
  _ports_conf_init
  sed -i -E "/^(OPEN|BLOCK)[[:space:]]+${proto}[[:space:]]+${port}\$/d" "$PORTS_CONF" 2>/dev/null || true
}

_ports_rebuild_nft() {
  _ports_ensure_nft || return 1
  _ports_conf_init
  local opens blocks line kind proto port
  opens=""
  blocks=""
  while read -r kind proto port; do
    [[ -z "$kind" ]] && continue
    case "$kind" in
      OPEN)
        if [[ "$proto" == "tcp" ]]; then
          opens="${opens}        tcp dport ${port} accept comment \"remna-open-tcp-${port}\"
"
        else
          opens="${opens}        udp dport ${port} accept comment \"remna-open-udp-${port}\"
"
        fi
        ;;
      BLOCK)
        if [[ "$proto" == "tcp" ]]; then
          blocks="${blocks}        tcp dport ${port} drop comment \"remna-block-tcp-${port}\"
"
        else
          blocks="${blocks}        udp dport ${port} drop comment \"remna-block-udp-${port}\"
"
        fi
        ;;
    esac
  done < <(_ports_list | awk '{print $1,$2,$3}')

  # priority -15: раньше UFW/filter, чтобы «открыть» работало даже при UFW deny
  # (закрытие DROP тоже сработает до UFW allow)
  cat > "$PORTS_RULES" <<NFT
#!/usr/sbin/nft -f
# remnanode port manager — отдельно от UFW
table inet ${PORTS_TABLE}
delete table inet ${PORTS_TABLE}
table inet ${PORTS_TABLE} {
    chain input {
        type filter hook input priority -15; policy accept;
        iif "lo" accept
        ct state established,related accept
${blocks}${opens}    }
}
NFT
  chmod 0644 "$PORTS_RULES"

  if ! nft -f "$PORTS_RULES" 2>/tmp/rn-ports.err; then
    warn "nft отклонил правила портов:"
    sed 's/^/    /' /tmp/rn-ports.err >"$_TTY" 2>/dev/null || cat /tmp/rn-ports.err || true
    return 1
  fi

  cat > "$PORTS_UNIT" <<UNIT
[Unit]
Description=Remnanode port manager (nftables, separate from UFW)
After=network-online.target nftables.service
Wants=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f ${PORTS_RULES}
ExecStop=/usr/sbin/nft delete table inet ${PORTS_TABLE}
[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload 2>/dev/null || true
  systemctl enable remna-ports.service >/dev/null 2>&1 || true
  # отметим oneshot как active (правила уже загружены через nft -f)
  systemctl start remna-ports.service >/dev/null 2>&1 || true
  return 0
}

ports_active() {
  command -v nft >/dev/null 2>&1 || return 1
  nft list table inet "$PORTS_TABLE" >/dev/null 2>&1
}

ports_count_open() {
  local n
  n=$(_ports_list | grep -c '^OPEN ' 2>/dev/null || true)
  echo "${n:-0}"
}

show_ports_status() {
  echo -e "  ${WHITE}Управляемые порты (не UFW):${NC}"
  echo -e "  ${GRAY}OPEN = firewall разрешил вход · «слушает» = процесс на порту (это разное)${NC}"
  local lines n_open=0 n_block=0
  lines=$(_ports_list)
  if [[ -z "$lines" ]]; then
    echo -e "    ${GRAY}(пусто — ничего не открыто/не заблокировано)${NC}"
  else
    while read -r kind proto port; do
      [[ -z "$kind" ]] && continue
      local listen=""
      if [[ "$proto" == "tcp" ]]; then
        if is_node_port_listening "$port" 2>/dev/null; then
          listen=" ${GREEN}· процесс слушает${NC}"
        else
          listen=" ${YELLOW}· процесс не слушает${NC}"
        fi
      fi
      if [[ "$kind" == "OPEN" ]]; then
        n_open=$((n_open + 1))
        echo -e "    ${GREEN}▲ OPEN${NC}  ${proto^^}/${port}${listen}"
      else
        n_block=$((n_block + 1))
        echo -e "    ${RED}▼ BLOCK${NC} ${proto^^}/${port}"
      fi
    done <<< "$lines"
  fi
  echo
  if ports_active; then
    echo -e "    nftables ${GREEN}● применено${NC}  (таблица ${PORTS_TABLE})"
  else
    echo -e "    nftables ${GRAY}○ не загружено${NC}"
  fi
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi 'Status: active'; then
    echo -e "    ${YELLOW}⚠ UFW активен${NC} — наши OPEN идут раньше UFW (priority -15)."
    echo -e "    ${GRAY}  BLOCK тоже сработает до правил UFW.${NC}"
  fi
}

ports_open() {
  local port="$1" proto_choice="$2"
  local protos=()
  case "$proto_choice" in
    1|tcp|TCP) protos=(tcp) ;;
    2|udp|UDP) protos=(udp) ;;
    3|both|BOTH|*) protos=(tcp udp) ;;
  esac
  local p
  for p in "${protos[@]}"; do
    _ports_add_line OPEN "$p" "$port"
    ok "Firewall: открыт ${p^^}/${port}"
  done
  if ! _ports_rebuild_nft; then
    warn "Правила сохранены, но nft не применил — см. лог"
    return 1
  fi
  return 0
}

# Открыть NODE_PORT для связи панели Remnawave с нодой (только TCP)
ports_open_panel() {
  local port=""
  port=$(get_node_port 2>/dev/null || true)
  if [[ -z "$port" ]]; then
    ask "NODE_PORT ноды (для панели Remnawave)" port "3000"
  fi
  [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )) || {
    warn "Нужен порт 1–65535"
    return 1
  }

  echo
  info "Открываю TCP/${port} для взаимодействия с Remnawave Panel…"
  info "Это правило firewall (nftables), не запуск процесса на порту."
  ports_open "$port" tcp

  # Сохраним как известный порт ноды, если файла ещё нет
  mkdir -p "$DIR" 2>/dev/null || true
  if [[ ! -f "$DIR/.node_port" ]]; then
    echo "$port" > "$DIR/.node_port" 2>/dev/null || true
  fi

  echo
  if is_node_port_listening "$port"; then
    ok "Порт ${port}: firewall OPEN и процесс слушает — панель может подключаться"
  else
    warn "Firewall OPEN для TCP/${port}, но процесс пока НЕ слушает этот порт."
    if is_remnanode_up || docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q '^remnanode$'; then
      if remnanode_compose_has_bad_init || remnanode_logs_show_s6_pid1; then
        warn "Причина: конфликт Docker init:true с s6-overlay (can only run as pid 1)."
        ask_yes_no "Исправить compose и перезапустить ноду?" ans Y
        if [[ "$ans" =~ ^[Yy]$ ]]; then
          restart_remnanode_safe || true
          sleep 4
          if is_node_port_listening "$port"; then
            ok "После фикса порт ${port} слушает"
          else
            warn "Всё ещё не слушает. Логи: docker logs --tail 50 remnanode"
            docker logs --tail 30 remnanode 2>&1 | sed 's/^/    /' || true
          fi
        fi
      elif is_remnanode_up; then
        warn "Контейнер remnanode запущен, но нода не приняла порт — смотрите логи / перезапуск."
        ask_yes_no "Перезапустить контейнер remnanode?" ans N
        if [[ "$ans" =~ ^[Yy]$ ]]; then
          restart_remnanode_safe || true
          sleep 3
          if is_node_port_listening "$port"; then
            ok "После перезапуска порт ${port} слушает"
          else
            warn "Всё ещё не слушает. Логи: docker logs --tail 50 remnanode"
            docker logs --tail 30 remnanode 2>&1 | sed 's/^/    /' || true
          fi
        fi
      fi
    elif is_remnanode_installed; then
      warn "Нода установлена, но контейнер не запущен — пункт «Нода» → Запустить."
    else
      warn "Нода ещё не установлена — сначала пункт 1) Remnanode."
    fi
  fi
  return 0
}

ports_close() {
  local port="$1" proto_choice="$2" do_block="$3"
  local protos=()
  case "$proto_choice" in
    1|tcp|TCP) protos=(tcp) ;;
    2|udp|UDP) protos=(udp) ;;
    3|both|BOTH|*) protos=(tcp udp) ;;
  esac
  local p
  for p in "${protos[@]}"; do
    _ports_del_line "$p" "$port"
    if [[ "$do_block" =~ ^[Yy]$ ]]; then
      _ports_add_line BLOCK "$p" "$port"
      ok "Закрыт и заблокирован (DROP) ${p^^}/${port}"
    else
      ok "Убрано открытие ${p^^}/${port}"
    fi
  done
  _ports_rebuild_nft || warn "Правила сохранены, но nft не применил — см. лог"
}

ports_clear_all() {
  _ports_conf_init
  printf '# remnanode ports (OPEN|BLOCK proto port)\n' >"$PORTS_CONF"
  nft delete table inet "$PORTS_TABLE" 2>/dev/null || true
  systemctl disable remna-ports.service >/dev/null 2>&1 || true
  rm -f "$PORTS_RULES" "$PORTS_UNIT" 2>/dev/null || true
  systemctl daemon-reload 2>/dev/null || true
  ok "Все правила портов сброшены"
}

setup_ports() {
  show_header
  echo -e "${WHITE}${BOLD}  🔓 Порты — открыть / закрыть${NC}"
  hline 56
  echo
  info "Отдельно от UFW: своя таблица nftables (remna_ports)."
  info "OPEN = разрешить вход в firewall. «Слушает» = процесс ноды на порту."
  echo
  show_ports_status
  echo
  local np
  np=$(get_node_port 2>/dev/null || true)
  if [[ -n "$np" ]]; then
    echo -e "  ${WHITE}1)${NC} 📡 Открыть порт ноды для Remnawave Panel ${GRAY}(TCP/${np})${NC}"
  else
    echo -e "  ${WHITE}1)${NC} 📡 Открыть порт ноды для Remnawave Panel"
  fi
  echo -e "  ${WHITE}2)${NC} 🔓 Открыть произвольный порт"
  echo -e "  ${WHITE}3)${NC} 🔒 Закрыть порт"
  echo -e "  ${WHITE}4)${NC} 📋 Список / статус"
  echo -e "  ${WHITE}5)${NC} ♻️  Применить правила заново"
  echo -e "  ${WHITE}6)${NC} 🗑️  Сбросить все правила портов"
  echo -e "  ${GRAY}0)${NC} 🔙 Назад"
  echo
  ask_choice ch

  local port proto block
  case "$ch" in
    1)
      ports_open_panel
      echo
      show_ports_status
      ;;
    2)
      ask "Номер порта" port
      [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )) || {
        warn "Нужен порт 1–65535"; return 0
      }
      echo -e "  ${WHITE}Протокол:${NC}  1) TCP  2) UDP  3) TCP+UDP"
      ask "Выбор" proto "3"
      ports_open "$port" "$proto"
      echo
      if [[ "$proto" == "1" || "$proto" == "tcp" || "$proto" == "3" || "$proto" == "both" || -z "$proto" ]]; then
        if ! is_node_port_listening "$port" 2>/dev/null; then
          info "Firewall открыт. Если нужен процесс на порту — это делает сервис (нода), не это меню."
        fi
      fi
      show_ports_status
      ;;
    3)
      ask "Номер порта" port
      [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )) || {
        warn "Нужен порт 1–65535"; return 0
      }
      echo -e "  ${WHITE}Протокол:${NC}  1) TCP  2) UDP  3) TCP+UDP"
      ask "Выбор" proto "3"
      ask_yes_no "Заблокировать вход (DROP), а не только убрать OPEN?" block N
      ports_close "$port" "$proto" "$block"
      echo
      show_ports_status
      ;;
    4) show_ports_status ;;
    5)
      if _ports_rebuild_nft; then
        ok "Правила переприменены"
      fi
      show_ports_status
      ;;
    6)
      ask_yes_no "Точно сбросить все OPEN/BLOCK?" ans N
      [[ "$ans" =~ ^[Yy]$ ]] && ports_clear_all
      ;;
    0) return 0 ;;
    *) ;;
  esac
}

###############################################################################
# Docker
###############################################################################
# Установка Docker через официальный convenience-скрипт (обходит зависший apt lock)
_install_docker_via_get_docker() {
  info "Fallback: установка Docker через get.docker.com…"
  apt_takeover
  apt_wait_locks 120 || true
  local tmp
  tmp=$(mktemp /tmp/rn-get-docker.XXXXXX.sh)
  if ! curl -fsSL --connect-timeout 10 --max-time 60 https://get.docker.com -o "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  # скрипт сам делает apt update/install; перед этим ещё раз захватим apt
  apt_takeover
  apt_wait_locks 180 || true
  if ! sh "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  rm -f "$tmp"
  systemctl enable docker >/dev/null 2>&1 || true
  systemctl start docker >/dev/null 2>&1 || true
  command -v docker >/dev/null 2>&1
}

_install_docker_via_apt() {
  info "🐳 Добавляю репозиторий Docker…"
  install -m 0755 -d /etc/apt/keyrings
  local _dk_tmp
  _dk_tmp=$(mktemp /tmp/rn-docker-gpg.XXXXXX)
  if ! curl -fsSL --connect-timeout 10 --max-time 30 "https://download.docker.com/linux/${ID}/gpg" \
      | gpg --batch --yes --dearmor -o "$_dk_tmp" 2>/dev/null; then
    rm -f "$_dk_tmp"
    warn "Не удалось скачать GPG-ключ Docker"
    return 1
  fi
  install -m 0644 "$_dk_tmp" /etc/apt/keyrings/docker.gpg
  rm -f "$_dk_tmp"
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${ID} ${CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list

  apt_takeover
  apt_wait_locks 180 || true
  info "Обновление apt под Docker-репозиторий…"
  if ! spin_fn "apt (docker-репо)" apt_update_one_repo /etc/apt/sources.list.d/docker.list; then
    warn "Точечный update Docker-репо не удался — полный update…"
    apt_takeover
    apt_wait_locks 120 || true
    spin_fn "apt (docker-репо, полный)" apt_update_safe force || true
  fi

  local attempt=1
  local errf="/tmp/rn-docker-apt.err"
  while (( attempt <= 4 )); do
    apt_takeover
    if ! apt_wait_locks 180; then
      warn "apt занят перед установкой Docker (попытка ${attempt}/4)…"
    fi
    # починить прерванный dpkg после kill фонового apt
    DEBIAN_FRONTEND=noninteractive dpkg --configure -a >/dev/null 2>&1 || true
    echo "=== $(date '+%F %T') | apt install docker (попытка ${attempt}/4) ===" >&3
    if DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
        docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin \
        >"$errf" 2>&1; then
      systemctl enable docker >/dev/null 2>&1 || true
      systemctl start docker >/dev/null 2>&1 || true
      ok "Docker Engine установлен"
      return 0
    fi
    cat "$errf" >&3 2>/dev/null || true
    if _apt_err_is_lock "$errf" || grep -qiE 'Could not get lock|Unable to acquire' "$errf" 2>/dev/null; then
      warn "Docker: apt lock (попытка ${attempt}/4) — жду и повторяю…"
      apt_takeover
      sleep 5
      attempt=$((attempt + 1))
      continue
    fi
    warn "apt install docker не удался — см. лог"
    return 1
  done
  return 1
}

install_docker() {
  sanitize_apt_repos
  apt_takeover

  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    ok "Docker уже установлен"
    run_step_soft "настройка daemon.json" "ensure_docker_daemon_config"
    return 0
  fi
  if command -v docker >/dev/null 2>&1; then
    info "Docker есть, проверяю compose-plugin…"
  fi

  if _install_docker_via_apt; then
    :
  else
    warn "Установка Docker через apt не вышла — пробую get.docker.com"
    if ! _install_docker_via_get_docker; then
      err "Не удалось установить Docker. Освободите apt: systemctl stop unattended-upgrades; затем повторите."
    fi
    ok "Docker установлен через get.docker.com"
  fi

  command -v docker >/dev/null 2>&1 || err "docker не найден после установки"
  run_step_soft "настройка daemon.json" "ensure_docker_daemon_config"
}

# Аккуратно настроить daemon.json: не затирать чужие зеркала/настройки
ensure_docker_daemon_config() {
  mkdir -p /etc/docker
  local cfg=/etc/docker/daemon.json
  local changed=0

  if [[ ! -f "$cfg" ]]; then
    cat > "$cfg" <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "live-restore": true,
  "userland-proxy": false,
  "default-ulimits": {
    "nofile": {
      "Name": "nofile",
      "Hard": 1048576,
      "Soft": 1048576
    }
  }
}
EOF
    changed=1
    info "Создан /etc/docker/daemon.json"
  elif command -v jq >/dev/null 2>&1; then
    local tmp before after
    tmp=$(mktemp)
    before=$(wc -c <"$cfg" 2>/dev/null || echo 0)
    # Мержим только недостающие ключи — не трогаем registry-mirrors и пр.
    if jq '
      .["log-driver"] = (.["log-driver"] // "json-file") |
      .["log-opts"] = (.["log-opts"] // {}) |
      .["log-opts"]["max-size"] = (.["log-opts"]["max-size"] // "10m") |
      .["log-opts"]["max-file"] = (.["log-opts"]["max-file"] // "3") |
      .["live-restore"] = (.["live-restore"] // true) |
      .["userland-proxy"] = (.["userland-proxy"] // false) |
      .["default-ulimits"] = (.["default-ulimits"] // {}) |
      .["default-ulimits"]["nofile"] = (.["default-ulimits"]["nofile"] // {"Name":"nofile","Hard":1048576,"Soft":1048576})
    ' "$cfg" >"$tmp" 2>/dev/null; then
      after=$(wc -c <"$tmp" 2>/dev/null || echo 0)
      if ! cmp -s "$cfg" "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$cfg"
        changed=1
        info "Обновлён /etc/docker/daemon.json (merge)"
      else
        rm -f "$tmp"
        info "Docker daemon.json уже настроен — без изменений"
      fi
    else
      rm -f "$tmp"
      info "Docker daemon.json есть — оставляю как есть"
    fi
  else
    info "Docker daemon.json уже есть — не перезаписываю"
  fi

  if [[ "$changed" -eq 1 ]]; then
    systemctl restart docker 2>/dev/null || true
  fi
  return 0
}

###############################################################################
# Установка CLI-панели (команда remnanode)
###############################################################################
install_self_cli() {
  local src="${BASH_SOURCE[0]:-$0}"
  local src_dir="" quiet="${RN_QUIET:-0}" force="${1:-}"
  src_dir=$(cd "$(dirname "$src")" 2>/dev/null && pwd || true)
  mkdir -p "$DIR"

  # Всегда обновляем установленный лаунчер из текущего файла
  if [[ -f "$src" && "$src" != "/dev/stdin" && "$src" != /dev/fd/* ]]; then
    cp -f "$src" "$LAUNCHER_PATH" 2>/dev/null || true
  fi

  # Версия установленной копии (только литерал YYYY.…, не ${…:-})
  local inst_ver=""
  if [[ -f "$LAUNCHER_PATH" ]]; then
    inst_ver=$(grep -E '^_REMNANODE_VER(_PIN)?="[0-9]{4}\.' "$LAUNCHER_PATH" 2>/dev/null | head -1 \
      | sed -E 's/^[^=]+=//; s/["'\'']//g' || true)
  fi

  # Устарело / нет файла / force — качаем свежий с GitHub (anti-cache)
  if [[ "$force" == "force" ]] \
     || [[ ! -f "$LAUNCHER_PATH" ]] \
     || [[ -z "$inst_ver" ]] \
     || [[ "$inst_ver" != "$_REMNANODE_VER_PIN" ]]; then
    if [[ -f "$src" && "$src" != "/dev/stdin" && "$src" != /dev/fd/* ]] \
       && grep -qE "^_REMNANODE_VER_PIN=\"${_REMNANODE_VER_PIN}\"" "$src" 2>/dev/null; then
      cp -f "$src" "$LAUNCHER_PATH" 2>/dev/null || true
    else
      info "Обновляю лаунчер с GitHub → ${_REMNANODE_VER_PIN}…"
      gh_download "$LAUNCHER_RAW" "$LAUNCHER_PATH" 2>/dev/null || true
    fi
  fi
  chmod +x "$LAUNCHER_PATH" 2>/dev/null || true

  # Selfsteal рядом с лаунчером
  if [[ -n "$src_dir" && -f "$src_dir/selfsteal.sh" ]]; then
    cp -f "$src_dir/selfsteal.sh" "$SELFSTEAL_LOCAL" 2>/dev/null || true
    chmod +x "$SELFSTEAL_LOCAL" 2>/dev/null || true
  else
    gh_download "$SELFSTEAL_RAW" "$SELFSTEAL_LOCAL" 2>/dev/null || true
    chmod +x "$SELFSTEAL_LOCAL" 2>/dev/null || true
  fi
  ln -sfn "$LAUNCHER_PATH" "$CLI_PATH"
  chmod +x "$CLI_PATH" 2>/dev/null || true
  if [[ "$quiet" != "1" ]]; then
    ok "Команда управления: remnanode  (v$(launcher_version))"
  fi
}

# Если запущена старая копия из /opt — подтянуть свежую и перезапуститься
_self_update_if_stale() {
  [[ -f "$LAUNCHER_PATH" ]] || return 0
  # уже свежий процесс (запущен не из старого installer)
  local running="${BASH_SOURCE[0]:-$0}"
  local run_ver pin
  pin="${_REMNANODE_VER_PIN:-}"
  [[ -n "$pin" ]] || return 0
  run_ver=$(grep -E '^_REMNANODE_VER_PIN="[0-9]{4}\.' "$running" 2>/dev/null | head -1 \
    | sed -E 's/^[^=]+=//; s/["'\'']//g' || true)
  # если в этом файле уже есть актуальный pin — ок
  [[ "$run_ver" == "$pin" ]] && return 0

  # скачать свежий и exec
  local tmp
  tmp=$(mktemp /tmp/remnanode-upd.XXXXXX.sh)
  if gh_download "$LAUNCHER_RAW" "$tmp"; then
    if grep -qE "^_REMNANODE_VER_PIN=\"[0-9]{4}\." "$tmp" 2>/dev/null; then
      cp -f "$tmp" "$LAUNCHER_PATH" 2>/dev/null || true
      chmod +x "$tmp" "$LAUNCHER_PATH" 2>/dev/null || true
      info "Найдена новая версия лаунчера — перезапуск…"
      exec bash "$tmp" "$@"
    fi
  fi
  rm -f "$tmp"
  return 0
}

###############################################################################
# REMNANODE — установка (своя стабильная, не из DigneZzZ)
###############################################################################
# Порт ноды из установки (.node_port или NODE_PORT в .env)
get_node_port() {
  local p=""
  if [[ -f "$DIR/.node_port" ]]; then
    p=$(tr -dc '0-9' <"$DIR/.node_port" 2>/dev/null | head -c 8 || true)
  fi
  if [[ -z "$p" && -f "$ENV_FILE" ]]; then
    p=$(grep -E '^NODE_PORT=' "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2 | tr -dc '0-9' || true)
  fi
  [[ "$p" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$p"
}

# Слушает ли TCP-порт на хосте (host-network нода)
is_node_port_listening() {
  local port="${1:-}"
  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  ss -tlnp 2>/dev/null | grep -qE ":${port}([[:space:]]|$)" \
    || ss -tln 2>/dev/null | grep -qE ":${port}([[:space:]]|$)"
}

# Нода установлена только при реальных артефактах compose/.env/контейнере.
# Один каталог /opt/remnanode НЕ считается установкой: туда кладётся лаунчер.
is_remnanode_installed() {
  if [[ -f "$COMPOSE" ]] && grep -qE 'container_name:[[:space:]]*remnanode|remnawave/node' "$COMPOSE" 2>/dev/null; then
    return 0
  fi
  # .env считаем установкой только при непустом SECRET_KEY
  if [[ -f "$ENV_FILE" ]] && grep -qE '^SECRET_KEY=.+' "$ENV_FILE" 2>/dev/null; then
    return 0
  fi
  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q '^remnanode$'; then
    return 0
  fi
  return 1
}
is_remnanode_up() { docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^remnanode$'; }

# remnawave/node использует s6-overlay → ему нужен PID 1.
# Docker Compose «init: true» подставляет tini и ломает контейнер:
#   s6-overlay-suexec: fatal: can only run as pid 1
remnanode_compose_has_bad_init() {
  [[ -f "$COMPOSE" ]] || return 1
  grep -qE '^[[:space:]]*init:[[:space:]]*true[[:space:]]*$' "$COMPOSE" 2>/dev/null
}

remnanode_logs_show_s6_pid1() {
  docker logs --tail 40 remnanode 2>&1 | grep -qi 'can only run as pid 1'
}

# Убрать init: true из compose. Возвращает 0 если правили файл.
fix_remnanode_s6_init() {
  remnanode_compose_has_bad_init || return 1
  info "Исправляю конфликт s6-overlay: убираю init: true из docker-compose.yml…"
  sed -i -E '/^[[:space:]]*init:[[:space:]]*true[[:space:]]*$/d' "$COMPOSE"
  ok "compose без init: true (s6-overlay сможет стать PID 1)"
  return 0
}

# Перезапуск ноды с авто-фиксом s6/init при необходимости
restart_remnanode_safe() {
  [[ -f "$COMPOSE" ]] || { warn "docker-compose.yml не найден"; return 1; }
  fix_remnanode_s6_init || true
  (cd "$DIR" && docker compose down && docker compose up -d) || {
    warn "Перезапуск remnanode не удался"
    return 1
  }
  return 0
}

# Удалить только файлы ноды; лаунчер (installer.sh / selfsteal.sh) оставляем
_remove_remnanode_files() {
  if [[ -f "$COMPOSE" ]]; then
    # без -v: не сносить чужие named volumes (certs H2/selfsteal)
    (cd "$DIR" && docker compose down 2>/dev/null) || true
  fi
  docker rm -f remnanode 2>/dev/null || true
  rm -f "$COMPOSE" "$ENV_FILE" \
    "$DIR/.panel_ip" "$DIR/.node_port" 2>/dev/null || true
  rm -rf "$CUSTOM_XRAY_DIR" 2>/dev/null || true
}

remove_existing_remnanode() {
  warn "Найдена существующая установка Remnanode."
  echo
  [[ -f "$COMPOSE" ]] && echo -e "    • 📄 Compose: ${GRAY}$COMPOSE${NC}"
  [[ -f "$ENV_FILE" ]] && echo -e "    • 🔐 .env: ${GRAY}$ENV_FILE${NC}"
  if is_remnanode_up; then
    echo -e "    • 🐳 Контейнер: ${GRAY}remnanode (online)${NC}"
  elif docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q '^remnanode$'; then
    echo -e "    • 🐳 Контейнер: ${GRAY}remnanode (stopped)${NC}"
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
  run_step "Остановка и очистка ноды" "_remove_remnanode_files"
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
    ask_secret "SECRET_KEY" K1 || { warn "Отмена ввода ключа"; return 0; }
    ask_secret "Повтор SECRET_KEY" K2 || { warn "Отмена ввода ключа"; return 0; }
    [[ -z "$K1" ]] && { warn "Пусто — введите ключ"; continue; }
    [[ "$K1" != "$K2" ]] && { warn "Не совпадает — ещё раз"; continue; }
    break
  done
  ok "Ключ принят (${#K1} символов)"
  echo

  echo -e "  ${WHITE}${BOLD}⚙️  Установка (шаги 0–8, со статусом)${NC}"
  hline 40
  info "0️⃣/8  Проверка apt-репозиториев"
  run_step_soft "проверка репозиториев" "apt_takeover; sanitize_apt_repos; apt_wait_locks 120 || true"
  info "1️⃣/8  Базовые пакеты"
  ensure_packages
  info "2️⃣/8  Тюнинг производительности"
  apply_performance_tuning
  info "3️⃣/8  Docker"
  install_docker
  info "4️⃣/8  Конфиг ноды (.env + compose)"

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
    stop_grace_period: 30s
    env_file:
      - .env
    cap_add:
      - NET_ADMIN
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    volumes:
      - /dev/shm:/dev/shm
    healthcheck:
      test: ["CMD-SHELL", "pgrep -f xray >/dev/null 2>&1 || pgrep -f node >/dev/null 2>&1"]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 45s
EOF
  chmod 600 "$COMPOSE"
  ok "docker-compose.yml создан"

  # Сохраним IP панели для будущего UFW
  echo "$PANEL_IP" > "$DIR/.panel_ip"
  echo "$NODE_PORT" > "$DIR/.node_port"

  cd "$DIR"
  info "5️⃣/8  Скачивание образа (может занять несколько минут)…"
  run_step "скачивание образа ноды" "docker compose pull"
  info "6️⃣/8  Запуск контейнера"
  run_step "запуск контейнера" "docker compose down >/dev/null 2>&1 || true; docker compose up -d"

  info "7️⃣/8  Ожидание готовности ноды…"
  _tty_printf '\033[?25l'
  local i ready=0
  for i in $(seq 1 30); do
    local filled=$(( i * _PROGRESS_W / 30 )) j mix=""
    for ((j = 0; j < _PROGRESS_W; j++)); do
      if (( j < filled )); then mix+="█"; else mix+="░"; fi
    done
    _progress_draw "$mix" "ожидание порта ${NODE_PORT}" "${i}/30с" "$CYAN"
    sleep 1
    if is_remnanode_up; then
      if ss -tlnp 2>/dev/null | grep -qE ":${NODE_PORT}\\b"; then
        ready=1
        break
      fi
      (( i >= 10 )) && ready=1 && break
    fi
  done
  _tty_printf '\033[2K\r'
  if is_remnanode_up; then
    _tty_printf '  %b✅%b ожидание ноды %b— готово%b\n' "$GREEN" "$NC" "$GRAY" "$NC"
  fi
  _tty_printf '\033[?25h'

  if ! is_remnanode_up; then
    echo -e "  ${RED}Логи контейнера:${NC}"
    docker logs --tail 40 remnanode 2>&1 | sed 's/^/    /' || true
    err "Контейнер не запустился. Логи: docker logs remnanode"
  fi
  ok "Контейнер remnanode запущен"

  if ss -tlnp 2>/dev/null | grep -qE ":${NODE_PORT}\\b"; then
    ok "Нода слушает порт ${NODE_PORT}"
  else
    warn "Порт ${NODE_PORT} пока не слушает — проверяю типичный конфликт s6/init…"
    if remnanode_compose_has_bad_init || remnanode_logs_show_s6_pid1; then
      fix_remnanode_s6_init || true
      (cd "$DIR" && docker compose up -d --force-recreate) || true
      sleep 5
      if ss -tlnp 2>/dev/null | grep -qE ":${NODE_PORT}\\b"; then
        ok "После фикса s6/init нода слушает порт ${NODE_PORT}"
      else
        warn "Порт ${NODE_PORT} всё ещё не слушает — docker logs remnanode"
      fi
    else
      warn "Порт ${NODE_PORT} пока может подниматься — проверьте: ss -tlnp | grep ${NODE_PORT}"
    fi
  fi

  # По стандарту: открыть указанный при установке NODE_PORT для панели
  info "8️⃣/8  Открытие TCP/${NODE_PORT} для Remnawave Panel (firewall, не UFW)…"
  if ports_open "$NODE_PORT" tcp; then
    ok "Порт ${NODE_PORT}/tcp открыт для взаимодействия с панелью"
  else
    warn "Не удалось открыть TCP/${NODE_PORT} — позже: меню «Порты» → пункт 1"
  fi

  info "Установка команды управления…"
  install_self_cli

  echo
  echo -e "${GREEN}${BOLD}"
  echo "  ╔════════════════════════════════════════════════════╗"
  echo "  ║           ✅  REMNANODE УСТАНОВЛЕН                 ║"
  echo "  ╚════════════════════════════════════════════════════╝"
  echo -e "${NC}"
  echo -e "  🌐 Public IP:   ${CYAN}${PUBLIC_IP}${NC}"
  echo -e "  🖥️  Панель IP:   ${PANEL_IP}"
  echo -e "  🔌 NODE_PORT:   ${NODE_PORT}  ${GRAY}(firewall OPEN)${NC}"
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
  RN_QUIET=1 install_self_cli >/dev/null 2>&1 || true

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
    if command -v python3 >/dev/null 2>&1; then
      python3 - "$COMPOSE" "$CUSTOM_XRAY_DIR" <<'PY'
import sys, re
path, xdir = sys.argv[1], sys.argv[2]
mount = f"      - '{xdir}/xray:/usr/local/bin/xray:ro'\n"
with open(path) as f:
    content = f.read()
if "custom-xray/xray:/usr/local/bin/xray" in content:
    sys.exit(0)
m = re.search(r'(^[ \t]*volumes:[ \t]*\n)', content, re.M)
if m:
    pos = m.end()
    content = content[:pos] + mount + content[pos:]
else:
    if not content.endswith("\n"):
        content += "\n"
    content += "    volumes:\n" + mount
with open(path, "w") as f:
    f.write(content)
PY
    else
      # fallback без python3: вставить mount после volumes: или добавить секцию
      if grep -qE '^[[:space:]]*volumes:' "$COMPOSE"; then
        sed -i "/^[[:space:]]*volumes:/a\\${mount_line}" "$COMPOSE"
      else
        printf '\n    volumes:\n%s\n' "$mount_line" >> "$COMPOSE"
      fi
    fi
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
  local _wg_tmp
  _wg_tmp=$(mktemp /tmp/rn-warp-gpg.XXXXXX)
  if ! curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
      | gpg --batch --yes --dearmor -o "$_wg_tmp" 2>/dev/null; then
    rm -f "$_wg_tmp"
    err "Не удалось скачать GPG-ключ Cloudflare WARP"
  fi
  install -m 0644 "$_wg_tmp" /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
  rm -f "$_wg_tmp"
  echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ ${warp_codename} main" \
    > /etc/apt/sources.list.d/cloudflare-client.list
  apt_wait_locks 180 || true
  # новое репо Cloudflare: обновляем только его список (быстро)
  if ! spin_fn "apt (WARP-репо)" apt_update_one_repo /etc/apt/sources.list.d/cloudflare-client.list; then
    warn "Точечный update WARP-репо не удался — полный update…"
    apt_wait_locks 180 || true
    if ! spin_fn "apt (WARP-репо, полный)" apt_update_safe force; then
      err "apt update после добавления Cloudflare-репозитория не удался"
    fi
  fi
  ok "Репозиторий Cloudflare"

  apt_wait_locks 120 || true
  run_step "Установка cloudflare-warp" "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq cloudflare-warp"

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
  info "Регистрация и подключение WARP…"
  warp-cli --accept-tos registration delete >/dev/null 2>&1 || true
  if ! warp-cli --accept-tos registration new >/dev/null 2>&1; then
    sleep 3
    if ! warp-cli --accept-tos registration new >/dev/null 2>&1; then
      warn "Регистрация WARP не удалась — проверьте: warp-cli registration new"
    fi
  fi
  warp-cli --accept-tos mode proxy >/dev/null 2>&1 || true
  warp-cli --accept-tos proxy port "$WARP_PORT" >/dev/null 2>&1 || true
  if ! warp-cli --accept-tos connect >/dev/null 2>&1; then
    sleep 2
    warp-cli --accept-tos connect >/dev/null 2>&1 || warn "WARP connect не удался"
  fi

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

  local warp_ip warp_ok=0
  sleep 2
  if ss -tlnp 2>/dev/null | grep -qE ":${WARP_PORT}\\b"; then
    warp_ok=1
  fi
  warp_ip=$(curl -s --max-time 10 --socks5 "127.0.0.1:${WARP_PORT}" https://cloudflare.com/cdn-cgi/trace 2>/dev/null | grep "^ip=" | cut -d= -f2 || true)

  echo
  if [[ "$warp_ok" -eq 1 && -n "$warp_ip" ]]; then
    echo -e "${GREEN}${BOLD}"
    echo "  ╔════════════════════════════════════════════════════╗"
    echo "  ║        ✅  WARP УСТАНОВЛЕН И РАБОТАЕТ             ║"
    echo "  ╚════════════════════════════════════════════════════╝"
    echo -e "${NC}"
  else
    echo -e "${YELLOW}${BOLD}"
    echo "  ╔════════════════════════════════════════════════════╗"
    echo "  ║     ⚠️  WARP УСТАНОВЛЕН, НО SOCKS ЕЩЁ НЕ ГОТОВ    ║"
    echo "  ╚════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    warn "Проверьте: warp-cli status && ss -tlnp | grep ${WARP_PORT}"
  fi
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
  # Надёжнее: порт из sshd_config, затем ss
  ssh_port=$(grep -E '^[[:space:]]*Port[[:space:]]+' /etc/ssh/sshd_config 2>/dev/null \
    | awk '{print $2}' | tail -1)
  if [[ -z "$ssh_port" ]]; then
    ssh_port=$(ss -tlnp 2>/dev/null | awk '/sshd|ssh\.service/ {print $4}' | sed 's/.*://' | head -1)
  fi
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
      info "Обнаружен SSH-порт: ${ssh_port} — убедитесь, что верный (иначе lockout!)"
      ask_yes_no "Открыть 443/tcp+udp (Reality/Hysteria)?" p443 Y
      ask_yes_no "Открыть 80/tcp (ACME/Selfsteal)?" p80 N
      ask_yes_no "⚠️  Сбросить все правила UFW (ufw reset)?" do_reset N

      if [[ "$do_reset" =~ ^[Yy]$ ]]; then
        ufw --force reset >/dev/null 2>&1 || true
      fi
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

# --- Сохранение результатов Speedtest (чтобы можно было открыть после skip) ---
speedtest_prepare_store() {
  mkdir -p "$SPEEDTEST_DIR" 2>/dev/null || true
}

# Запустить блок теста: вывод на экран + сохранение в last/history
# usage: speedtest_capture "Название"  bash -c '...'
speedtest_capture() {
  local title="$1"
  shift
  speedtest_prepare_store
  local tmp rc=0
  tmp=$(mktemp /tmp/rn-speedtest.XXXXXX)

  {
    echo "============================================================"
    echo "  Speedtest: ${title}"
    echo "  Дата:      $(date '+%F %T')"
    echo "  Хост:      $(hostname 2>/dev/null || echo '?') | IP: ${PUBLIC_IP:-?}"
    echo "============================================================"
    echo
  } >"$tmp"

  set +e
  # shellcheck disable=SC2068
  "$@" 2>&1 | tee -a "$tmp"
  rc=${PIPESTATUS[0]}
  set -e

  {
    echo
    echo "------------------------------------------------------------"
    echo "  Конец: $(date '+%F %T')  (код: ${rc})"
    echo "============================================================"
  } >>"$tmp"
  # короткий хвост на экран (итог уже был в tee выше)
  echo
  echo -e "  ${GRAY}Конец: $(date '+%F %T')  (код: ${rc})${NC}"

  cp -f "$tmp" "$SPEEDTEST_LAST"
  {
    echo
    cat "$tmp"
    echo
  } >>"$SPEEDTEST_LOG"
  # История не раздуваем бесконечно (~200 КБ)
  if [[ -f "$SPEEDTEST_LOG" ]] && [[ "$(wc -c <"$SPEEDTEST_LOG")" -gt 200000 ]]; then
    tail -c 150000 "$SPEEDTEST_LOG" >"${SPEEDTEST_LOG}.tmp" && mv -f "${SPEEDTEST_LOG}.tmp" "$SPEEDTEST_LOG"
  fi
  rm -f "$tmp"
  echo
  ok "Результат сохранён"
  info "Последний:  ${SPEEDTEST_LAST}"
  info "История:    ${SPEEDTEST_LOG}"
  # Не валим интерактивное меню из‑за ненулевого кода теста
  return 0
}

show_speedtest_last() {
  speedtest_prepare_store
  ui_clear
  echo -e "${CYAN}${BOLD}"
  echo "  ╔════════════════════════════════════════════════════╗"
  echo "  ║           📄 ПОСЛЕДНИЙ SPEEDTEST                   ║"
  echo "  ╚════════════════════════════════════════════════════╝"
  echo -e "${NC}"
  if [[ ! -f "$SPEEDTEST_LAST" || ! -s "$SPEEDTEST_LAST" ]]; then
    warn "Сохранённых результатов ещё нет — сначала запустите тест"
    return 0
  fi
  echo -e "  ${GRAY}${SPEEDTEST_LAST}${NC}"
  echo
  # Без ANSI-цветов файл читается нормально; на экран — как есть
  sed 's/\x1b\[[0-9;]*m//g' "$SPEEDTEST_LAST" | sed 's/^/  /'
  echo
}

show_speedtest_history() {
  speedtest_prepare_store
  ui_clear
  echo -e "${CYAN}${BOLD}"
  echo "  ╔════════════════════════════════════════════════════╗"
  echo "  ║           📚 ИСТОРИЯ SPEEDTEST                     ║"
  echo "  ╚════════════════════════════════════════════════════╝"
  echo -e "${NC}"
  if [[ ! -f "$SPEEDTEST_LOG" || ! -s "$SPEEDTEST_LOG" ]]; then
    warn "История пуста — сначала запустите тест"
    return 0
  fi
  echo -e "  ${GRAY}${SPEEDTEST_LOG}${NC}"
  echo -e "  ${GRAY}(показаны последние ~80 строк)${NC}"
  echo
  sed 's/\x1b\[[0-9;]*m//g' "$SPEEDTEST_LOG" | tail -n 80 | sed 's/^/  /'
  echo
  info "Полный файл: less ${SPEEDTEST_LOG}"
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
      local dig_ms="" ok_r=0
      if command -v dig >/dev/null 2>&1; then
        dig_ms=$(dig @"$r" +stats +time=2 +tries=1 "$d" 2>/dev/null | awk '/Query time:/ {print $4; exit}')
        if [[ -n "$dig_ms" ]]; then
          ok_r=1
          printf "     %-22s ${GREEN}%s ms${NC}\n" "$d" "$dig_ms"
        fi
      fi
      if [[ "$ok_r" -eq 0 ]]; then
        # fallback: dig +short или getent (без привязки к резолверу)
        if dig @"$r" +short +time=2 +tries=1 "$d" >/dev/null 2>&1 \
          || host "$d" "$r" >/dev/null 2>&1; then
          printf "     %-22s ${GREEN}ok${NC}\n" "$d"
        else
          printf "     %-22s ${RED}fail${NC}\n" "$d"
        fi
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

  if [[ -f "$SPEEDTEST_LAST" && -s "$SPEEDTEST_LAST" ]]; then
    echo -e "  ${GRAY}Есть сохранённый результат: ${SPEEDTEST_LAST}${NC}"
    echo
  fi

  echo -e "  ${WHITE}1)${NC} 🚀 Ookla Speedtest       ${GRAY}(полный тест)${NC}"
  echo -e "  ${WHITE}2)${NC} 📶 Ookla — только ping/jitter"
  echo -e "  ${WHITE}3)${NC} 📥 Свой тест скачивания  ${GRAY}(curl, без Ookla)${NC}"
  echo -e "  ${WHITE}4)${NC} 📊 Комплекс: Ookla + ping + замер времени"
  echo -e "  ${WHITE}5)${NC} 📄 Показать последний результат"
  echo -e "  ${WHITE}6)${NC} 📚 История результатов"
  echo -e "  ${GRAY}0)${NC} 🔙 Назад"
  echo
  ask_choice ch

  local t0 t1
  case "$ch" in
    1)
      ensure_ookla_speedtest || { warn "Ookla недоступен — попробуйте пункт 3"; return; }
      speedtest_capture "Ookla полный" bash -c '
        t0=$(date +%s.%N)
        echo "  Старт: $(date "+%F %T")"
        speedtest --accept-license --accept-gdpr || echo "  Ookla вернул ошибку"
        t1=$(date +%s.%N)
        echo
        awk -v a="$t0" -v b="$t1" "BEGIN{printf \"  Длительность: %.1f сек\\n\", b-a}"
      '
      ;;
    2)
      ensure_ookla_speedtest || { warn "Ookla недоступен"; return; }
      speedtest_capture "Ookla ping/jitter" bash -c '
        if speedtest --accept-license --accept-gdpr -f json 2>/dev/null | jq -r "
            \"  Ping:    \\(.ping.latency) ms\",
            \"  Jitter:  \\(.ping.jitter) ms\",
            \"  Server:  \\(.server.name) (\\(.server.location))\",
            \"  ISP:     \\(.isp // \"?\")\"
          " 2>/dev/null; then
          :
        else
          speedtest --accept-license --accept-gdpr --ping || true
        fi
      '
      ;;
    3)
      speedtest_capture "Curl download CDN" bash -c '
        echo "  Замер download через несколько CDN…"
        echo
        t0=$(date +%s.%N)
        # функции скрипта недоступны в subshell — вызываем curl напрямую
        for item in \
          "Cloudflare 10МБ|https://speed.cloudflare.com/__down?bytes=10000000" \
          "Cloudflare 25МБ|https://speed.cloudflare.com/__down?bytes=25000000" \
          "Hetzner 100МБ|https://speed.hetzner.de/100MB.bin" \
          "ThinkBroadband 10МБ|http://ipv4.download.thinkbroadband.com/10MB.zip"
        do
          label="${item%%|*}"; url="${item#*|}"
          echo "  $label"
          echo "  $url"
          out=$(curl -L -o /dev/null -w "%{time_total} %{size_download} %{speed_download}" \
            --connect-timeout 10 --max-time 60 "$url" 2>/dev/null) || { echo "  Не удалось"; echo; continue; }
          t_total=$(echo "$out" | awk "{print \$1}")
          size=$(echo "$out" | awk "{print \$2}")
          speed_bps=$(echo "$out" | awk "{print \$3}")
          speed_mbps=$(awk -v s="$speed_bps" "BEGIN{printf \"%.2f\", s*8/1000000}")
          size_mb=$(awk -v s="$size" "BEGIN{printf \"%.2f\", s/1048576}")
          printf "     Размер:  %s МБ\n" "$size_mb"
          printf "     Время:   %.2f сек\n" "$t_total"
          printf "     Скорость: %s Мбит/с\n" "$speed_mbps"
          echo
        done
        t1=$(date +%s.%N)
        awk -v a="$t0" -v b="$t1" "BEGIN{printf \"  Общее время: %.1f сек\\n\", b-a}"
        echo
        echo "  RTT:"
        ping -c 4 -W 2 1.1.1.1 2>/dev/null | tail -2 | sed "s/^/  /" || true
      '
      ;;
    4)
      ensure_ookla_speedtest || warn "Ookla пропущен"
      speedtest_capture "Комплекс Ookla+curl+ping" bash -c '
        t0=$(date +%s.%N)
        echo "  Старт: $(date "+%F %T")"
        if command -v speedtest >/dev/null 2>&1; then
          speedtest --accept-license --accept-gdpr || true
        fi
        echo
        echo "  Cloudflare 25 МБ"
        out=$(curl -L -o /dev/null -w "%{time_total} %{size_download} %{speed_download}" \
          --connect-timeout 10 --max-time 60 \
          "https://speed.cloudflare.com/__down?bytes=25000000" 2>/dev/null) || out=""
        if [[ -n "$out" ]]; then
          speed_bps=$(echo "$out" | awk "{print \$3}")
          speed_mbps=$(awk -v s="$speed_bps" "BEGIN{printf \"%.2f\", s*8/1000000}")
          printf "     Скорость: %s Мбит/с\n" "$speed_mbps"
        fi
        echo
        echo "  Ping:"
        ping -c 5 -W 2 1.1.1.1 2>/dev/null | tail -2 | sed "s/^/  /"
        ping -c 5 -W 2 8.8.8.8 2>/dev/null | tail -2 | sed "s/^/  /"
        t1=$(date +%s.%N)
        echo "  Финиш: $(date "+%F %T")"
        awk -v a="$t0" -v b="$t1" "BEGIN{printf \"  Длительность: %.2f сек\\n\", b-a}"
      '
      ;;
    5) show_speedtest_last ;;
    6) show_speedtest_history ;;
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
    echo -e "  ${WHITE}2)${NC} 📄 Последний Speedtest ${GRAY}— если скипнули результат${NC}"
    echo -e "  ${WHITE}3)${NC} 📶 Задержка (ping)"
    echo -e "  ${WHITE}4)${NC} 🧭 DNS"
    echo -e "  ${WHITE}5)${NC} 🌐 Информация об IP"
    echo -e "  ${WHITE}6)${NC} 🖥️  Система / CPU / диск"
    echo -e "  ${WHITE}7)${NC} 🔌 Порты и контейнеры"
    echo -e "  ${WHITE}8)${NC} 🏁 Полный прогон       ${GRAY}— speed + ping + DNS…${NC}"
    echo
    echo -e "  ${GRAY}0)${NC} 🔙 Назад"
    echo
    ask_choice choice

    case "$choice" in
      1) run_speedtest_menu; pause ;;
      2) show_speedtest_last; pause ;;
      3) run_latency_test; pause ;;
      4) run_dns_test; pause ;;
      5) run_ip_info_test; pause ;;
      6) run_system_bench; pause ;;
      7) run_ports_check; pause ;;
      8)
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
    echo -e "  SWAP:  $(service_status_text swap)"
    echo -e "  UFW:   $(service_status_text ufw)"
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
  local ver
  ver=$(launcher_version)
  _tty_printf '%b  📡 RemnaNode — управление%b  %bv%s%b\n' "${CYAN}${BOLD}" "$NC" "$GRAY" "$ver" "$NC"
  hline 56
  _tty_echo ""

  if is_remnanode_up; then
    local node_port node_ver xray_ver
    node_port=$(grep -E '^NODE_PORT=' "$ENV_FILE" 2>/dev/null | cut -d= -f2)
    node_port=${node_port:-3000}
    _tty_printf '  %b✅ Статус ноды: РАБОТАЕТ%b\n' "$GREEN" "$NC"
    _tty_echo ""
    _tty_printf '  %b🌐 Подключение:%b\n' "$WHITE" "$NC"
    _tty_printf '     %-10s %b%s%b\n' "IP:" "$CYAN" "$PUBLIC_IP" "$NC"
    _tty_printf '     %-10s %b%s%b\n' "Порт:" "$CYAN" "$node_port" "$NC"
    _tty_printf '     %-10s %b%s:%s%b\n' "URL:" "$CYAN" "$PUBLIC_IP" "$node_port" "$NC"
    _tty_echo ""
    _tty_printf '  %b🧩 Компоненты:%b\n' "$WHITE" "$NC"
    node_ver=$(docker inspect --format '{{.Config.Image}}' remnanode 2>/dev/null || echo "?")
    _tty_printf '     %-10s %b%s%b\n' "Образ:" "$CYAN" "$node_ver" "$NC"
    xray_ver=$(docker exec remnanode xray version 2>/dev/null | head -1 || echo "н/д")
    _tty_printf '     %-10s %s\n' "Xray:" "$xray_ver"
    if grep -q 'custom-xray/xray' "$COMPOSE" 2>/dev/null; then
      _tty_printf '     %b⚡ custom Xray смонтирован (фикс онлайна)%b\n' "$YELLOW" "$NC"
    fi
    _tty_echo ""
    _tty_printf '  %b💾 Ресурсы:%b\n' "$WHITE" "$NC"
    local cstats
    cstats=$(docker stats --no-stream --format '{{.CPUPerc}} | {{.MemUsage}}' remnanode 2>/dev/null || echo "n/a")
    _tty_printf '     %-10s %s\n' "Контейнер:" "$cstats"
    _tty_printf '     %-10s %s\n' "RAM хоста:" "$(free -h | awk '/^Mem:/ {printf "%s / %s", $3, $2}')"
  elif is_remnanode_installed; then
    _tty_printf '  %b❌ Статус ноды: ОСТАНОВЛЕНА%b\n' "$RED" "$NC"
    _tty_printf '  %bИспользуйте пункт 2 для запуска%b\n' "$GRAY" "$NC"
  else
    _tty_printf '  %b📦 Статус: НЕ УСТАНОВЛЕНА%b\n' "$GRAY" "$NC"
    _tty_printf '  %bИспользуйте пункт 1 для установки%b\n' "$GRAY" "$NC"
  fi
  _tty_echo ""
  hline 56
}

remnanode_menu() {
  RN_QUIET=1 install_self_cli >/dev/null 2>&1 || true

  while true; do
    PUBLIC_IP=$(get_public_ip)
    node_status_screen

    _tty_printf '  %b🛠️  Установка и управление:%b\n' "$WHITE" "$NC"
    _tty_echo "    ${WHITE} 1)${NC} 🚀 Установить RemnaNode"
    _tty_echo "    ${WHITE} 2)${NC} ▶️  Запустить"
    _tty_echo "    ${WHITE} 3)${NC} ⏹️  Остановить"
    _tty_echo "    ${WHITE} 4)${NC} 🔄 Перезапустить"
    _tty_echo "    ${WHITE} 5)${NC} 🗑️  Удалить RemnaNode"
    _tty_echo ""
    _tty_printf '  %b📊 Мониторинг и логи:%b\n' "$WHITE" "$NC"
    _tty_echo "    ${WHITE} 6)${NC} 📌 Статус (docker ps / compose)"
    _tty_echo "    ${WHITE} 7)${NC} 📋 Логи контейнера"
    _tty_echo "    ${WHITE} 8)${NC} 📈 Docker stats"
    _tty_echo "    ${WHITE} 9)${NC} 📺 LIVE-мониторинг"
    _tty_echo ""
    _tty_printf '  %b⚙️  Обновления и конфигурация:%b\n' "$WHITE" "$NC"
    _tty_echo "    ${WHITE}10)${NC} ⬆️  Обновить образ RemnaNode"
    _tty_echo "    ${WHITE}11)${NC} 🔧 Фикс онлайна Hysteria2 / custom Xray"
    _tty_echo "    ${WHITE}12)${NC} 📝 Редактировать docker-compose.yml"
    _tty_echo "    ${WHITE}13)${NC} 🔐 Редактировать .env"
    _tty_echo "    ${WHITE}14)${NC} 🔌 Показать порты"
    _tty_echo "    ${WHITE}15)${NC} ⚙️  Тюнинг производительности"
    _tty_echo ""
    _tty_printf '  %b✨ Дополнительно:%b\n' "$WHITE" "$NC"
    _tty_echo "    ${WHITE}16)${NC} ⚡ Настройка Hysteria2"
    _tty_echo "    ${WHITE}17)${NC} 🎭 Selfsteal"
    _tty_echo "    ${WHITE}18)${NC} 🏠 Открыть главное меню лаунчера"
    _tty_echo "    ${WHITE}19)${NC} 📡 Открыть порт ноды для Remnawave Panel"
    _tty_echo ""
    hline 56
    _tty_echo "    ${GRAY}0)${NC} 🚪 Выход"
    _tty_echo ""
    ask_choice choice "👉 Выберите пункт [0-19]:"

    case "$choice" in
      1) install_remnanode; pause ;;
      2)
        [[ -f "$COMPOSE" ]] || { warn "Не установлено"; pause; continue; }
        fix_remnanode_s6_init || true
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
        restart_remnanode_safe
        ok "Перезапущено"; pause
        ;;
      5)
        if is_remnanode_installed; then
          ask_yes_no "🗑️  Точно удалить RemnaNode?" ans N
          if [[ "$ans" =~ ^[Yy]$ ]]; then
            _remove_remnanode_files
            ok "Удалено (лаунчер в /opt/remnanode сохранён)"
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
      19) ports_open_panel; pause ;;
      0) exit 0 ;;
      *) ;;
    esac
  done
}

live_panel() {
  local _live_stop=0
  trap '_live_stop=1' INT
  while (( _live_stop == 0 )); do
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
      (( _live_stop == 1 )) && break
      RX2=$(cat /sys/class/net/$IFACE/statistics/rx_bytes)
      TX2=$(cat /sys/class/net/$IFACE/statistics/tx_bytes)
      printf "\n  %-6s  RX: %6s KB/s   TX: %6s KB/s\n" "$IFACE" "$(( (RX2-RX1)/1024 ))" "$(( (TX2-TX1)/1024 ))"
    else
      sleep 1
    fi
    (( _live_stop == 1 )) && break
    sleep 1
  done
  trap - INT
  return 0
}

###############################################################################
# Главное меню лаунчера
###############################################################################
main_menu() {
  # Чтобы команда remnanode была доступна сразу
  RN_QUIET=1 install_self_cli >/dev/null 2>&1 || true

  while true; do
    PUBLIC_IP=$(get_public_ip)
    show_header

    section "📦  Установка"
    menu_item "🚀" "1"  "Remnanode"  "VPN-нода Remnawave" remnanode
    menu_item "🎭" "2"  "Selfsteal"  "маскировка Reality" selfsteal
    menu_item "⚡" "3"  "Hysteria2"  "автонастройка"      hysteria
    menu_item "🔧" "4"  "Фикс H2"    "custom Xray"        xrayfix
    menu_item "☁️" "5"  "WARP"       "Cloudflare SOCKS5"  warp
    menu_item "✈️" "6"  "MTProto"    "прокси Telegram"    mtproto

    section "🛠️  Система"
    menu_item "💾" "7"  "SWAP"       "файл подкачки"      swap
    menu_item "🛡️" "8"  "UFW"        "firewall (UFW)"     ufw
    menu_item "🔓" "9"  "Порты"      "открыть / закрыть"  ports
    menu_item "⚙️" "10" "Тюнинг"     "BBR / буферы / RPS" tune
    menu_item "🧱" "11" "Анти-DDoS"  "SYN-флуд / L4"      antiddos

    section "🎛️  Сервис"
    menu_item "📡" "12" "Нода"       "меню управления"    node_cli
    menu_item "🧪" "13" "Тесты"      "speed / ping / DNS"
    _tty_echo ""
    menu_item "🚪" "0"  "Выход"      ""
    _tty_echo ""
    ask_choice choice "👉"

    case "$choice" in
      1)  install_remnanode; pause ;;
      2)  install_selfsteal; pause ;;
      3)  install_hysteria2; pause ;;
      4)  fix_hysteria2_online; pause ;;
      5)  install_warp; pause ;;
      6)  install_mtproto; pause ;;
      7)  setup_swap; pause ;;
      8)  setup_ufw; pause ;;
      9)  setup_ports; pause ;;
      10) apply_performance_tuning; pause ;;
      11) setup_antiddos; pause ;;
      12) remnanode_menu ;;
      13) tests_menu ;;
      0)  exit 0 ;;
      *)  ;;
    esac
  done
}

###############################################################################
# Точка входа
###############################################################################
entry_name="$(basename "${BASH_SOURCE[0]:-$0}")"

# Мягкий режим для меню: ошибка команды не убивает весь UI
_menu_soft_mode() {
  set +e
  trap - ERR
}

# Стиль DigneZzZ: bash <(curl …) @ install  →  меню лаунчера (не установка ноды)
if [[ "${1:-}" == "@" ]]; then
  shift
fi

case "${1:-}" in
  # @ install / install — поставить CLI и открыть главное меню
  install|launcher|menu)
    _menu_soft_mode
    RN_QUIET=0 install_self_cli force || true
    main_menu
    ;;
  self-update|update-self|update-launcher)
    _menu_soft_mode
    install_self_cli force
    ok "Лаунчер обновлён до v$(launcher_version)"
    info "Запуск: remnanode   или   bash $LAUNCHER_PATH"
    ;;
  install-remnanode)           install_remnanode ;;
  install-selfsteal)           install_selfsteal ;;
  install-hysteria2|hysteria2) install_hysteria2 ;;
  fix-hysteria|fix-online)    fix_hysteria2_online ;;
  install-warp)                install_warp ;;
  install-mtproto|mtproto)     install_mtproto ;;
  swap)                        _menu_soft_mode; setup_swap ;;
  ufw|firewall)                _menu_soft_mode; setup_ufw ;;
  ports|port|open-port)        _menu_soft_mode; setup_ports ;;
  panel-port|open-panel-port)  _menu_soft_mode; ports_open_panel ;;
  tune|performance)            apply_performance_tuning ;;
  antiddos|ddos)               _menu_soft_mode; setup_antiddos ;;
  antiddos-on|ddos-on)         apply_antiddos 0 ;;
  antiddos-synproxy)           apply_antiddos 1 ;;
  antiddos-off|ddos-off)       disable_antiddos ;;
  tests|test)                  _menu_soft_mode; tests_menu ;;
  up)
    cd "$DIR" && docker compose up -d
    ;;
  down)
    cd "$DIR" && docker compose down
    ;;
  restart)
    restart_remnanode_safe || exit 1
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
    _menu_soft_mode
    remnanode_menu
    ;;
  *)
    _menu_soft_mode
    # при обычном запуске remnanode — если копия в /opt устарела, обновим
    if [[ "${BASH_SOURCE[0]:-$0}" == "$LAUNCHER_PATH" || "$(readlink -f "${BASH_SOURCE[0]:-$0}" 2>/dev/null)" == "$LAUNCHER_PATH" ]]; then
      _iv=""
      _iv=$(grep -E '^_REMNANODE_VER_PIN="[0-9]{4}\.' "$LAUNCHER_PATH" 2>/dev/null | head -1 \
        | sed -E 's/^[^=]+=//; s/["'\'']//g' || true)
      if [[ -z "$_iv" || "$_iv" != "${_REMNANODE_VER_PIN:-}" ]]; then
        _tmp=$(mktemp /tmp/remnanode-upd.XXXXXX.sh)
        if gh_download "$LAUNCHER_RAW" "$_tmp" && grep -qE '^_REMNANODE_VER_PIN=' "$_tmp"; then
          cp -f "$_tmp" "$LAUNCHER_PATH" 2>/dev/null || true
          chmod +x "$LAUNCHER_PATH" "$_tmp" 2>/dev/null || true
          ln -sfn "$LAUNCHER_PATH" "$CLI_PATH" 2>/dev/null || true
          info "Лаунчер обновлён — перезапуск…"
          exec bash "$_tmp" "$@"
        fi
        rm -f "$_tmp"
      fi
    fi
    if [[ "$entry_name" == "remnanode" ]]; then
      remnanode_menu
    else
      main_menu
    fi
    ;;
esac