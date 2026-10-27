# Test harness: stubs for the launcher's helpers + the real H2 block under test.
set -Eeuo pipefail
T="${T:?}"; export T
export PATH="$T/bin:$PATH"
GREEN=''; RED=''; BLUE=''; YELLOW=''; CYAN=''; WHITE=''; GRAY=''; BOLD=''; DIM=''; NC=''
_TTY=/dev/stdout
LOG="$T/install.log"; : > "$LOG"; exec 3>>"$LOG"
_tty_printf() { printf "$@"; }
_tty_echo()   { echo -e "$@"; }
ok()   { echo "[ok]   $*"; }
info() { echo "[info] $*"; }
warn() { echo "[warn] $*"; }
err()  { echo "[err]  $*"; exit 1; }
hline() { :; }
show_header() { :; }
pause() { :; }
_is_back() { local s="${1:-}"; s="${s,,}"; [[ "$s" == q || "$s" == b || "$s" == "н" || "$s" == "назад" ]]; }
strip_paste_noise() { printf '%s' "$1"; }
_next_answer() { local f="$T/answers"; local a=""; if [[ -s "$f" ]]; then a=$(head -n1 "$f"); tail -n +2 "$f" > "$f.tmp"; mv "$f.tmp" "$f"; fi; printf '%s' "$a"; }
_tty_read() { _next_answer; }
ask()        { local _a; _a=$(_next_answer); [[ -z "$_a" ]] && _a="${3:-}"; printf -v "$2" '%s' "$_a"; echo "[ask]  $1 -> ${_a}" >> "$T/asks.log"; }
ask_yes_no() { local _a; _a=$(_next_answer); [[ -z "$_a" ]] && _a="${3:-N}"; printf -v "$2" '%s' "$_a"; echo "[askyn] $1 -> ${_a}" >> "$T/asks.log"; }
ask_choice() { local _a; _a=$(_next_answer); printf -v "$1" '%s' "$_a"; echo "[choice] -> ${_a}" >> "$T/asks.log"; }
spin_fn() { local m="$1"; shift; "$@"; }
ensure_packages() { return 0; }
apt_takeover() { return 0; }
apt_wait_locks() { return 0; }
apt_update_safe() { return 0; }
PUBLIC_IP="${PUBLIC_IP:-203.0.113.10}"; LOCAL_IP="$PUBLIC_IP"
DIR="$T/opt/remnanode"; COMPOSE="$DIR/docker-compose.yml"; ENV_FILE="$DIR/.env"
mkdir -p "$DIR"
get_node_port() { echo 3000; }
is_node_port_listening() { [[ -f "$T/node_up" ]]; }
is_remnanode_installed() { [[ -f "$COMPOSE" ]]; }
is_remnanode_up() { [[ -f "$T/node_up" ]]; }
fix_remnanode_s6_init() { return 1; }
ports_open() { echo "ports_open $*" >> "$T/calls.log"; ok "Firewall: открыт ${2^^}/$1"; }
# block under test
H2_DIR="$T/opt/hysteria"; H2_LE="$T/etc/letsencrypt"; H2_HOP_NFT="$T/etc/hysteria-hop.nft"
H2_HOP_UNIT="$T/etc/systemd/system/hysteria-hop.service"; H2_SYSCTL_FILE="$T/etc/sysctl.d/98-hysteria2.conf"
mkdir -p "$T/etc/sysctl.d" "$T/etc/systemd/system" "$H2_LE"
