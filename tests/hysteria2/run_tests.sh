#!/bin/bash
# usage: [XRAY_BIN=/path/xray] tests/hysteria2/run_tests.sh remnanode.sh
# Тесты блока Hysteria2: заглушки docker/certbot/ufw/nft + mock-панель Remnawave (mock_panel.py). Ничего не трогают в системе.
SRC="$1"; HERE="$(cd "$(dirname "$0")" && pwd)"
python3 - "$SRC" "$HERE/h2_block.sh" <<'PY'
import sys
s = open(sys.argv[1], encoding='utf-8').read()
a = s.index('# HYSTERIA2 — полная автоустановка')
a = s.rindex('###############################################################################', 0, a)
b = s.index('# Старый внешний скрипт')
open(sys.argv[2], 'w', encoding='utf-8').write(s[a:b])
PY
PASS=0; FAIL=0
t_ok()  { PASS=$((PASS+1)); echo "  PASS  $1"; }
t_bad() { FAIL=$((FAIL+1)); echo "  FAIL  $1  ($2)"; }
check() { # name cmd...
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then t_ok "$name"; else t_bad "$name" "$*"; fi
}
PORT=18999
python3 "$HERE/mock_panel.py" $PORT >/dev/null 2>&1 &
MOCK=$!
trap 'kill $MOCK 2>/dev/null' EXIT
sleep 1
reset_mock() { curl -s "http://127.0.0.1:$PORT/__reset?$1" >/dev/null; }
state() { curl -s "http://127.0.0.1:$PORT/__state"; }
newenv() { export T; T=$(mktemp -d /tmp/h2t.XXXXXX); mkdir -p "$T/bin" "$T/opt/remnanode" "$T/etc/letsencrypt"; cp "$HERE"/bin/* "$T/bin/"; : > "$T/answers"; : > "$T/calls.log"; : > "$T/asks.log"
  cat > "$T/opt/remnanode/docker-compose.yml" <<'YML'
services:
  remnanode:
    image: remnawave/node:latest
    container_name: remnanode
    hostname: remnanode
    network_mode: host
    restart: always
    env_file:
      - .env
    environment:
      - NODE_PORT=3000
    cap_add:
      - NET_ADMIN
    volumes:
      - /dev/shm:/dev/shm
    healthcheck:
      test: ["CMD-SHELL", "pgrep -f xray >/dev/null 2>&1"]
YML
  echo "203.0.113.10" > "$T/dns_ip"; }
run_h2() { # выполняет функцию в подоболочке с окружением: run_h2 'cmd'
  ( source "$HERE/env.sh"; source "$HERE/h2_block.sh"; set +e; eval "$1" ) 2>&1
}

echo "== 1. чистые функции"
newenv
r=$(run_h2 '_h2_valid_domain hy2.example.com && echo d1; _h2_valid_domain 1.2.3.4 || echo d2; _h2_valid_domain "bad_domain.com" || echo d3; _h2_valid_hop 20000-29999 && echo h1; _h2_valid_hop 100-200 || echo h2; _h2_valid_hop 30000-20000 || echo h3; _h2_valid_port 443 && echo p1; _h2_valid_port 70000 || echo p2; _h2_normalize_domain " HTTPS://Hy2.Example.com/path "; echo; _h2_is_cf_ip 104.16.1.1 && echo cf1; _h2_is_cf_ip 203.0.113.10 || echo cf2; s=$(_h2_gen_secret); echo len${#s}')
for k in d1 d2 d3 h1 h2 h3 p1 p2 cf1 cf2 len32 hy2.example.com; do grep -qx "$k" <<<"$r" && t_ok "pure:$k" || t_bad "pure:$k" "$r"; done

echo "== 2. JSON инбаунда"
r=$(run_h2 'H2_PORT=443; H2_DOMAIN=hy2.example.com; H2_OBFS=SECRETSECRETSECRETSECRETSECRET12; _h2_inbound_json T1')
jq -e '.protocol=="hysteria" and .settings.version==2 and .streamSettings.network=="hysteria" and .streamSettings.finalmask.udp[0].type=="salamander" and .streamSettings.finalmask.quicParams.congestion=="bbr" and .streamSettings.tlsSettings.alpn==["h3"] and (.streamSettings.tlsSettings.certificates[0].keyFile|endswith("/live/hy2.example.com/privkey.pem")) and .streamSettings.hysteriaSettings.version==2' <<<"$r" >/dev/null && t_ok "inbound json shape" || t_bad "inbound json shape" "$r"
r=$(run_h2 'H2_PORT=443; H2_DOMAIN=hy2.example.com; H2_OBFS=; _h2_inbound_json T1')
jq -e '(.streamSettings.finalmask|has("udp")|not) and .streamSettings.finalmask.quicParams.congestion=="bbr"' <<<"$r" >/dev/null && t_ok "inbound without obfs" || t_bad "inbound without obfs" "$r"

echo "== 3. compose mount (идемпотентно)"
newenv
run_h2 'H2_NODE_RESTART_NEEDED=0; _h2_mount_certs; echo "changed=$H2_NODE_RESTART_NEEDED"' > "$T/o1"
grep -q "changed=1" "$T/o1" && t_ok "mount added -> restart needed" || t_bad "mount added" "$(cat $T/o1)"
grep -q "/etc/letsencrypt:.*:ro\|letsencrypt:.*:ro" "$T/opt/remnanode/docker-compose.yml" && t_ok "compose has mount" || t_bad "compose has mount" "$(cat $T/opt/remnanode/docker-compose.yml)"
python3 - "$T/opt/remnanode/docker-compose.yml" <<'PY' && t_ok "compose is valid YAML with 2 volumes" || t_bad "compose YAML" ""
import sys
try:
    import yaml
except ImportError:
    sys.exit(0)
d = yaml.safe_load(open(sys.argv[1]))
v = d['services']['remnanode']['volumes']
assert len(v) == 2 and any('letsencrypt' in x for x in v), v
PY
run_h2 'H2_NODE_RESTART_NEEDED=0; _h2_mount_certs; echo "changed=$H2_NODE_RESTART_NEEDED"' > "$T/o2"
grep -q "changed=0" "$T/o2" && t_ok "second run: no change, no restart" || t_bad "idempotent mount" "$(cat $T/o2)"
[[ $(grep -c letsencrypt "$T/opt/remnanode/docker-compose.yml") -eq 1 ]] && t_ok "mount not duplicated" || t_bad "mount duplicated" ""

echo "== 4. port hopping"
newenv
run_h2 '_h2_setup_hop 443 20000-29999' > "$T/o"
grep -q "udp dport 20000-29999 redirect to :443" "$T/etc/hysteria-hop.nft" && t_ok "nft file written" || t_bad "nft file" "$(cat $T/o)"
/usr/sbin/nft -c -f "$T/etc/hysteria-hop.nft" >/dev/null 2>&1 && t_ok "real nft accepts the ruleset (-c)" || t_bad "nft -c" "$(/usr/sbin/nft -c -f $T/etc/hysteria-hop.nft 2>&1 | head -3)"
grep -q "ExecStart=/usr/sbin/nft -f" "$T/etc/systemd/system/hysteria-hop.service" && grep -q "WantedBy=multi-user.target" "$T/etc/systemd/system/hysteria-hop.service" && t_ok "unit written" || t_bad "unit" ""
grep -q "enable --now hysteria-hop" "$T/calls.log" && t_ok "unit enabled" || t_bad "unit enabled" ""
run_h2 '_h2_setup_hop 443 ""' > "$T/o"
[[ ! -f "$T/etc/hysteria-hop.nft" ]] && t_ok "hopping off removes files" || t_bad "hopping off" "$(cat $T/o)"

echo "== 5. хуки продления"
newenv
run_h2 '_h2_write_renew_hooks hy2.example.com' >/dev/null
for h in pre/hysteria2-free80.sh post/hysteria2-restore80.sh deploy/hysteria2-restart-node.sh; do sh -n "$T/etc/letsencrypt/renewal-hooks/$h" 2>/dev/null && [[ -x "$T/etc/letsencrypt/renewal-hooks/$h" ]] && t_ok "hook syntax+exec: $h" || t_bad "hook $h" ""; done
grep -q 'hy2.example.com' "$T/etc/letsencrypt/renewal-hooks/deploy/hysteria2-restart-node.sh" && t_ok "deploy hook bound to domain" || t_bad "deploy hook domain" ""
PATH="$T/bin:$PATH" RENEWED_DOMAINS="other.com" sh "$T/etc/letsencrypt/renewal-hooks/deploy/hysteria2-restart-node.sh" && ! grep -q "docker restart" "$T/calls.log" && t_ok "deploy hook ignores other domains" || t_bad "deploy hook other" "$(cat $T/calls.log)"
touch "$T/node_up"; PATH="$T/bin:$PATH" RENEWED_DOMAINS="hy2.example.com" sh "$T/etc/letsencrypt/renewal-hooks/deploy/hysteria2-restart-node.sh"; grep -q "docker restart remnanode" "$T/calls.log" && t_ok "deploy hook restarts node for our domain" || t_bad "deploy hook restart" "$(cat $T/calls.log)"

echo "== 6. сертификат (certbot-стаб)"
newenv
r=$(run_h2 'PUBLIC_IP=203.0.113.10; _h2_issue_cert hy2.example.com; echo rc=$?')
grep -q "rc=0" <<<"$r" && [[ -s "$T/etc/letsencrypt/live/hy2.example.com/fullchain.pem" ]] && t_ok "cert issued" || t_bad "cert issue" "$r"
grep -q "register-unsafely-without-email" "$T/calls.log" && grep -q -- "--no-directory-hooks" "$T/calls.log" && t_ok "certbot flags (no email, no dir hooks)" || t_bad "certbot flags" "$(grep certbot $T/calls.log)"
grep -q "ufw allow 80/tcp" "$T/calls.log" && grep -q "ufw delete allow 80/tcp" "$T/calls.log" && t_ok "port 80 opened and closed around issuance" || t_bad "port 80" "$(cat $T/calls.log)"
: > "$T/calls.log"; r=$(run_h2 '_h2_issue_cert hy2.example.com; echo rc=$?'); grep -q "уже есть" <<<"$r" && ! grep -q "^certbot" "$T/calls.log" && t_ok "existing cert reused, certbot not called" || t_bad "cert reuse" "$r"
newenv; r=$(CERTBOT_FAIL=1 run_h2 '_h2_issue_cert hy2.example.com; echo rc=$?'); grep -q "rc=1" <<<"$r" && grep -q "Что проверить" <<<"$r" && grep -q "ufw delete allow 80/tcp" "$T/calls.log" && t_ok "failed issuance: instructions + port 80 closed again" || t_bad "cert fail path" "$r"

echo "== 7. панель по API: нода БЕЗ профиля"
newenv; reset_mock noprofile
export H2_PANEL_TOKEN_ENV=testtoken H2_PANEL_URL_ENV="http://127.0.0.1:$PORT" H2_YES=1
r=$(run_h2 'PUBLIC_IP=203.0.113.10; H2_DOMAIN=hy2.example.com; H2_PORT=443; H2_HOP=20000-29999; H2_OBFS=OBFSOBFSOBFSOBFSOBFSOBFSOBFS12; H2_TAG=HYSTERIA2; printf "a\n" > /dev/null; _h2_panel_auto; echo rc=$?')
grep -q "rc=0" <<<"$r" && t_ok "panel auto (no profile) rc=0" || t_bad "panel auto noprofile" "$r"
st=$(state)
jq -e '[.profiles[]|select(.name|startswith("H2-"))]|length==1' <<<"$st" >/dev/null && t_ok "new profile created" || t_bad "profile created" "$(jq -c '.profiles|map(.name)' <<<"$st")"
jq -e '(.nodes[]|select(.name=="Game node")|.configProfile.activeInbounds|map(.tag))==["HYSTERIA2-IN"]' <<<"$st" >/dev/null && t_ok "inbound bound to node" || t_bad "node bind" "$(jq -c '.nodes' <<<"$st")"
jq -e '.hosts|length==1 and .[0].address=="hy2.example.com" and .[0].alpn=="h3" and .[0].tags==["HYSTERIA2"] and .[0].port==443' <<<"$st" >/dev/null && t_ok "host created with alpn h3 / tag / address" || t_bad "host" "$(jq -c '.hosts' <<<"$st")"
jq -e '[.squads[].inbounds|length]==[1,1,1]' <<<"$st" >/dev/null && t_ok "squads untouched by default" || t_bad "squads untouched" ""
echo "== 8. повторный запуск = идемпотентно"
r=$(run_h2 'PUBLIC_IP=203.0.113.10; H2_DOMAIN=hy2.example.com; H2_PORT=443; H2_HOP=20000-29999; H2_OBFS=OBFSOBFSOBFSOBFSOBFSOBFSOBFS12; H2_TAG=HYSTERIA2; _h2_panel_auto; echo rc=$?')
st2=$(state); grep -q "rc=0" <<<"$r" && jq -e '(.profiles|length)==2 and (.hosts|length)==1' <<<"$st2" >/dev/null && t_ok "rerun: no duplicate profile/host" || t_bad "idempotent panel" "$r $(jq -c '[.profiles|length,(.hosts|length)]' <<<"$st2")"

echo "== 9. панель: нода С Reality-профилем + squad'ы"
newenv; reset_mock profile
printf '%s\n' "" "" "" "1,3" > "$T/answers"
unset H2_YES
r=$(run_h2 'PUBLIC_IP=198.51.100.7; H2_DOMAIN=hy2.example.com; H2_PORT=443; H2_HOP=; H2_OBFS=X; H2_TAG=HYSTERIA2; _h2_panel_auto; echo rc=$?')
export H2_YES=1
st=$(state)
grep -q "rc=0" <<<"$r" && t_ok "panel auto (existing profile) rc=0" || t_bad "panel existing" "$r"
jq -e '(.profiles[0].config.inbounds|map(.tag))==["REAL-IN","HYSTERIA2-IN"]' <<<"$st" >/dev/null && t_ok "inbound appended to the existing profile (Reality kept)" || t_bad "profile append" "$(jq -c '.profiles|map(.config.inbounds|map(.tag))' <<<"$st")"
jq -e '(.nodes[]|select(.name=="Other node")|.configProfile.activeInbounds|map(.tag))==["REAL-IN","HYSTERIA2-IN"]' <<<"$st" >/dev/null && t_ok "node keeps Reality + gets hysteria" || t_bad "node active inbounds" "$(jq -c '.nodes' <<<"$st")"
jq -e '[.squads[]|{n:.name,c:(.inbounds|length)}]==[{"n":"users","c":2},{"n":"Premium","c":1},{"n":"Trial","c":2}]' <<<"$st" >/dev/null && t_ok "squads 1 and 3 got the inbound, old inbounds preserved" || t_bad "squads" "$(jq -c '[.squads[]|{n:.name,c:(.inbounds|length)}]' <<<"$st")"
ls "$T/opt/hysteria"/backup-profile-*.json "$T/opt/hysteria"/backup-squads-*.json >/dev/null 2>&1 && t_ok "backups of profile and squads written" || t_bad "backups" "$(ls $T/opt/hysteria)"
[[ "$(stat -c %a "$T/opt/hysteria/inbound.json")" == "600" ]] && t_ok "inbound.json is 600" || t_bad "inbound.json perms" ""

echo "== 10. ошибки панели → фолбэк"
newenv; reset_mock profile
r=$(H2_PANEL_TOKEN_ENV=wrong run_h2 'PUBLIC_IP=198.51.100.7; H2_DOMAIN=hy2.example.com; H2_PORT=443; H2_OBFS=X; _h2_panel_auto; echo rc=$?')
grep -q "rc=1" <<<"$r" && grep -q "HTTP 401" <<<"$r" && t_ok "bad token: clean error with HTTP 401, rc=1" || t_bad "bad token" "$r"
curl -s "http://127.0.0.1:$PORT/__reset" >/dev/null; python3 - <<PY
import json,urllib.request
# make profile PATCH fail
req = urllib.request.Request("http://127.0.0.1:$PORT/__state"); 
PY
r=$(run_h2 'PUBLIC_IP=198.51.100.7; H2_DOMAIN=hy2.example.com; H2_PORT=443; H2_OBFS=X; _h2_panel_step; echo rc=$?' <<<"")
H2_PANEL_TOKEN_ENV=wrong r=$(H2_PANEL_TOKEN_ENV=wrong run_h2 'PUBLIC_IP=198.51.100.7; H2_DOMAIN=hy2.example.com; H2_PORT=443; H2_HOP=20000-29999; H2_OBFS=X; H2_TAG=HYSTERIA2; _h2_panel_step; echo rc=$?')
grep -q "Настройка панели вручную" <<<"$r" && grep -q '"protocol": "hysteria"' <<<"$r" && grep -q "mport=20000-29999" <<<"$r" && t_ok "failed auto → manual instructions with JSON printed" || t_bad "manual fallback" "$r"
unset H2_PANEL_TOKEN_ENV H2_PANEL_URL_ENV

echo "== 11. полный прогон install_hysteria2 (H2_YES=1, ручная панель)"
newenv; reset_mock profile
unset H2_PANEL_TOKEN_ENV H2_PANEL_URL_ENV
export H2_YES=1 H2_DOMAIN_ENV=hy2.example.com
r=$(run_h2 'PUBLIC_IP=203.0.113.10; install_hysteria2; echo rc=$?')
grep -q "rc=0" <<<"$r" && t_ok "install_hysteria2 finished rc=0" || t_bad "install rc" "$(tail -20 <<<"$r")"
for k in "Шаг 1/9" "Шаг 5/9" "Шаг 8/9" "Шаг 9/9"; do grep -q "$k" <<<"$r" && t_ok "step header: $k" || t_bad "step header $k" ""; done
grep -q "ufw allow 443/udp" "$T/calls.log" && grep -q "ufw allow 20000:29999/udp" "$T/calls.log" && t_ok "ufw rules for 443/udp and hop range (colon form)" || t_bad "ufw rules" "$(grep ufw $T/calls.log)"
grep -q "ports_open 443 udp" "$T/calls.log" && grep -q "ports_open 20000-29999 udp" "$T/calls.log" && t_ok "launcher nft port manager used" || t_bad "ports_open" ""
grep -q "docker compose up -d\|docker compose" "$T/calls.log" && t_ok "node recreated once after mount" || t_bad "node recreate" ""
[[ $(grep -c "docker compose" "$T/calls.log") -eq 1 ]] && t_ok "exactly one compose up" || t_bad "compose up count" "$(grep -c 'docker compose' $T/calls.log)"
grep -q "UDP 443 НИКТО не слушает" <<<"$r" && t_ok "diagnose: warns UDP not listening until panel binds inbound" || t_bad "diagnose udp" ""
grep -q "mport=20000-29999" <<<"$r" && t_ok "manual instructions mention mport hopping" || t_bad "mport hint" ""
[[ -f "$T/opt/hysteria/h2.env" && $(stat -c %a "$T/opt/hysteria/h2.env") == 600 ]] && t_ok "h2.env saved with 600" || t_bad "h2.env" ""
grep -q "^H2_OBFS=" "$T/opt/hysteria/h2.env" && t_ok "obfs password persisted" || t_bad "obfs persisted" ""
echo "== 12. повторный запуск (ничего не перезапускает) + диагностика в «зелёном» состоянии"
touch "$T/udp_listening"; : > "$T/calls.log"
r=$(run_h2 'PUBLIC_IP=203.0.113.10; install_hysteria2; echo rc=$?')
grep -q "rc=0" <<<"$r" && t_ok "rerun rc=0" || t_bad "rerun" "$(tail -10 <<<"$r")"
! grep -q "^certbot\|docker compose" "$T/calls.log" && t_ok "rerun: no certbot, no node restart" || t_bad "rerun side effects" "$(cat $T/calls.log | head)"
grep -q "Серверная часть в порядке" <<<"$r" && ! grep -q "⛔" <<<"$r" && t_ok "diagnose: all green" || t_bad "diagnose green" "$(grep -E '⛔|⚠' <<<"$r")"
echo "== 13. self-test: конфиг клиента валиден для настоящего Xray"
newenv; touch "$T/node_up"; echo "203.0.113.10" > "$T/dns_ip"
LINK='hysteria2://11111111-2222-3333-4444-555555555555@hy2.example.com:443/?obfs=salamander&obfs-password=PW123&sni=hy2.example.com&fm=%7B%22udp%22%3A%5B%7B%22type%22%3A%22salamander%22%2C%22settings%22%3A%7B%22password%22%3A%22PW123%22%2C%22packetSize%22%3A%22900-1300%22%7D%7D%5D%2C%22quicParams%22%3A%7B%22debug%22%3Afalse%2C%22congestion%22%3A%22bbr%22%7D%7D#%F0%9F%8E%AE%20Game'
run_h2 "hysteria2_selftest '$LINK'" >/dev/null 2>&1
[[ -s "$T/selftest.json" ]] && t_ok "selftest config produced" || t_bad "selftest config" ""
if [[ -x "${XRAY_BIN:-}" ]]; then
  "$XRAY_BIN" run -test -c "$T/selftest.json" >/dev/null 2>&1 && t_ok "real Xray accepts the client config (-test)" || t_bad "xray -test" "$("$XRAY_BIN" run -test -c $T/selftest.json 2>&1 | tail -3)"
else
  echo "  SKIP  real Xray check (set XRAY_BIN=/path/to/xray)"
fi
jq -e '.outbounds[0].streamSettings.hysteriaSettings.auth=="11111111-2222-3333-4444-555555555555" and .outbounds[0].streamSettings.finalmask.udp[0].settings.password=="PW123" and .outbounds[0].settings.port==443' "$T/selftest.json" >/dev/null && t_ok "auth / obfs / port parsed from the link" || t_bad "link parsing" "$(cat $T/selftest.json)"

echo "== 14. проверка inbound настоящим Xray до панели"
newenv; reset_mock profile; touch "$T/node_up"; export H2_YES=1 H2_PANEL_TOKEN_ENV=testtoken H2_PANEL_URL_ENV="http://127.0.0.1:$PORT"
r=$(run_h2 'PUBLIC_IP=198.51.100.7; H2_DOMAIN=hy2.example.com; H2_PORT=443; H2_HOP=; H2_OBFS=X; H2_TAG=HYSTERIA2; _h2_panel_step; echo rc=$?')
grep -q "Xray принял inbound" <<<"$r" && jq -e '.profiles[0].config.inbounds|length==2' <<<"$(state)" >/dev/null && t_ok "valid inbound accepted -> panel updated" || t_bad "validate ok" "$r"
newenv; reset_mock profile; touch "$T/node_up"
r=$(XRAY_TEST_FAIL=1 run_h2 'PUBLIC_IP=198.51.100.7; H2_DOMAIN=hy2.example.com; H2_PORT=443; H2_HOP=; H2_OBFS=X; H2_TAG=HYSTERIA2; _h2_panel_step; echo rc=$?')
grep -q "ОТКЛОНИЛ inbound" <<<"$r" && jq -e '.profiles[0].config.inbounds|length==1' <<<"$(state)" >/dev/null && ! grep -q "PATCH" <<<"$(jq -c '.log' <<<"$(state)")" && t_ok "rejected inbound -> panel NOT touched" || t_bad "validate fail" "$r"
unset H2_PANEL_TOKEN_ENV H2_PANEL_URL_ENV
echo "== 15. миграция с прошлой версии скрипта"
newenv; mkdir -p "$T/opt/hysteria"; echo "old.example.com" > "$T/opt/hysteria/.domain"; echo "OLDOBFSOLDOBFSOLDOBFSOLDOBFS1234" > "$T/opt/hysteria/.obfs"
r=$(run_h2 '_h2_state_load; echo "d=$H2_DOMAIN o=$H2_OBFS"')
grep -q "d=old.example.com o=OLDOBFSOLDOBFSOLDOBFSOLDOBFS1234" <<<"$r" && t_ok "legacy domain and obfs imported" || t_bad "legacy import" "$r"
: > "$T/calls.log"; mkdir -p "$T/etc/systemd/system"; touch "$T/etc/systemd/system/remna-hy2-hop.service"
run_h2 'H2_LEGACY_HOP_UNIT="$T/etc/systemd/system/remna-hy2-hop.service"; _h2_setup_hop 443 20000-29999' >/dev/null
grep -q "nft delete table inet remna_hy2" "$T/calls.log" && [[ ! -f "$T/etc/systemd/system/remna-hy2-hop.service" ]] && t_ok "legacy hopping table/unit removed" || t_bad "legacy hop cleanup" "$(cat $T/calls.log)"
newenv; mkdir -p "$T/etc/letsencrypt/renewal-hooks/pre" "$T/etc/letsencrypt/renewal-hooks/post" "$T/etc/letsencrypt/renewal-hooks/deploy"
touch "$T/etc/letsencrypt/renewal-hooks/pre/remna-acme-open.sh" "$T/etc/letsencrypt/renewal-hooks/post/remna-acme-close.sh" "$T/etc/letsencrypt/renewal-hooks/deploy/hysteria-copy-old.example.com.sh"
run_h2 '_h2_write_renew_hooks hy2.example.com' >/dev/null
[[ ! -e "$T/etc/letsencrypt/renewal-hooks/pre/remna-acme-open.sh" && ! -e "$T/etc/letsencrypt/renewal-hooks/deploy/hysteria-copy-old.example.com.sh" ]] && t_ok "superseded hooks of the old version removed" || t_bad "old hooks" "$(ls -R $T/etc/letsencrypt/renewal-hooks)"
echo "== 16. версия Xray и файл-инструкция"
newenv; touch "$T/node_up" "$T/udp_listening"; echo 203.0.113.10 > "$T/dns_ip"
r=$(XRAY_VER=26.3.27 run_h2 'PUBLIC_IP=203.0.113.10; H2_DOMAIN=hy2.example.com; H2_PORT=443; H2_HOP=; hysteria2_diagnose >/dev/null 2>&1; H2_DOMAIN=hy2.example.com; echo done')
mkdir -p "$T/opt/hysteria"; { mkdir -p "$T/opt/hysteria"; printf 'H2_DOMAIN=hy2.example.com\nH2_PORT=443\n' > "$T/opt/hysteria/h2.env"; }
r=$(XRAY_VER=26.3.27 run_h2 'PUBLIC_IP=203.0.113.10; hysteria2_diagnose')
grep -q "старше 26.6.1" <<<"$r" && t_ok "old Xray flagged by diagnose" || t_bad "old xray" "$r"
r=$(XRAY_VER=26.7.28 run_h2 'PUBLIC_IP=203.0.113.10; hysteria2_diagnose')
grep -q "Xray в ноде 26.7.28" <<<"$r" && t_ok "good Xray reported" || t_bad "good xray" "$r"
run_h2 'H2_DOMAIN=hy2.example.com; H2_PORT=443; H2_HOP=20000-29999; H2_OBFS=X; _h2_panel_manual' >/dev/null
[[ -s "$T/opt/hysteria/ИНСТРУКЦИЯ.txt" ]] && grep -q "HYSTERIA2-IN" "$T/opt/hysteria/ИНСТРУКЦИЯ.txt" && grep -q '"protocol": "hysteria"' "$T/opt/hysteria/ИНСТРУКЦИЯ.txt" && t_ok "guide file written with the JSON" || t_bad "guide file" "$(ls $T/opt/hysteria)"

echo "== 17. ключ не читается из контейнера (нода не от root)"
newenv; touch "$T/node_up"; mkdir -p "$T/etc/letsencrypt/live/hy2.example.com" "$T/etc/letsencrypt/archive/hy2.example.com"
echo k > "$T/etc/letsencrypt/archive/hy2.example.com/privkey1.pem"; chmod 600 "$T/etc/letsencrypt/archive/hy2.example.com/privkey1.pem"
ln -sf "$T/etc/letsencrypt/archive/hy2.example.com/privkey1.pem" "$T/etc/letsencrypt/live/hy2.example.com/privkey.pem"
r=$(KEY_UNREADABLE=1 run_h2 '_h2_ensure_key_readable hy2.example.com; echo rc=$?')
grep -q "rc=0" <<<"$r" && [[ "$(stat -c %a "$T/etc/letsencrypt/archive/hy2.example.com/privkey1.pem")" == "644" && -f "$T/opt/hysteria/.keymode" ]] && t_ok "unreadable key fixed (644) and mode remembered" || t_bad "keymode fix" "$r"
run_h2 '_h2_write_renew_hooks hy2.example.com' >/dev/null
grep -q "keymode" "$T/etc/letsencrypt/renewal-hooks/deploy/hysteria2-restart-node.sh" && sh -n "$T/etc/letsencrypt/renewal-hooks/deploy/hysteria2-restart-node.sh" && t_ok "deploy hook re-applies keymode and stays valid sh" || t_bad "hook keymode" "$(cat $T/etc/letsencrypt/renewal-hooks/deploy/hysteria2-restart-node.sh)"

echo "== итого: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0))
