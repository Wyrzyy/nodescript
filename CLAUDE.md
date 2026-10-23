# CLAUDE.md — nodescript

Контекст для ИИ, чтобы продолжать работу без потери нити. Пиши сжато, по делу.
Отвечать пользователю — на русском; код/термины/команды — в оригинале.

## Суть проекта
Bash-лаунчер для развёртывания и обслуживания VPN-ноды **Remnawave** (ядро **Xray Reality**)
на Ubuntu/Debian VPS. UI на русском, заточен под запуск через `bash <(curl …)` в Termius/SSH.
Репозиторий: `Wyrzyy/nodescript` (ветка `main`). Автор апстрима selfsteal — DigneZzZ (MIT).

Пользователь — владелец VPN-проекта. Хочет: быстрый, профессиональный, визуально чистый скрипт,
который «бодро» всё качает, даёт буст скорости ноды и ставит всё удобно.

## ⚠️ ГЛАВНОЕ ПРАВИЛО (не нарушать)
Любая правка, которая вынудит пользователя что-то менять **в панели Remnawave** (порт ноды,
Reality `serverNames`/`dest`/`xver`, `SECRET_KEY`, outbound, образ) — ОБЯЗАТЕЛЬНО пометить и
предупредить явно («⚠ ТРЕБУЕТСЯ ДЕЙСТВИЕ В ПАНЕЛИ»). Серверные правки (sysctl/tuning/firewall)
панели не касаются — предупреждать не нужно.

## Стек / окружение
- bash (`set -Eeuo pipefail`), curl, jq, docker + docker compose, nftables/iptables, systemd.
- Только Ubuntu/Debian (проверка `ID` в os-release, иначе `err`).
- Весь интерактив и вывод идут в `/dev/tty` (`$_TTY`) — иначе в Termius «пропадают» prompt/текст.
- Подробный лог шагов: `/var/log/remnanode-install.log`, fd `3` (`run_step` пишет `>&3`).

## Файлы
- `remnanode.sh` (~5800 строк) — ГЛАВНЫЙ лаунчер. Меню + все установщики + сервис.
- `selfsteal.sh` (~5570 строк) — маскировочный веб-сервер Reality (Caddy/Nginx). Русиф. копия DigneZzZ.
  Лаунчер вызывает его как внешний скрипт (`run_selfsteal`), копию кладёт в `/opt/remnanode/selfsteal.sh`.
- `CLAUDE.md` — этот файл.
- Нет тестов/CI. Проверка перед коммитом: `bash -n remnanode.sh && bash -n selfsteal.sh`.

## remnanode.sh — карта (ищи по именам функций)
Точка входа — низ файла: self-reexec из tempfile (фикс `/dev/fd` в Termius) → конфиг-переменные (1-88)
→ определения функций → в самом низу `case "${1:-}"` диспетчер аргументов.

- Конфиг/переменные: строки ~33-68. `DIR=/opt/remnanode`, `COMPOSE`, `ENV_FILE`, `PANEL_IP_DEFAULT`,
  `NODE_IMAGE_DEFAULT=remnawave/node:latest`, `PANEL_IMAGE=remnawave/backend:3`, `WARP_PORT=9091`,
  `LAUNCHER_PATH=/opt/remnanode/installer.sh`, `CLI_PATH=/usr/local/bin/remnanode`, зеркала RAW-URL.
- UI-хелперы: `_tty_printf/_tty_echo`, `ok/info/warn/err` (err → exit 1), `hline`, `ask`, `ask_secret`
  (чанковый raw-ввод длинного ключа, фикс bracketed-paste), `ask_choice`, `ask_yes_no`, `_is_back`
  (назад = q/b/н/назад), прогресс `_progress_draw`/`spin`/`run_step`/`run_step_soft`/`spin_fn`.
- SECRET_KEY: `normalize_secret_key`, `secret_key_valid` (base64 JSON с caCertPem/jwtPublicKey/
  nodeCertPem/nodeKeyPem), `secret_key_preview`, `write_remnanode_env` (printf, umask 077, chmod 600).
- GitHub-загрузки с зеркалами для РФ: `gh_candidates` (ghproxy.net/ghfast.top/ghproxy.com/jsdelivr),
  `gh_download`, `gh_run_bash`, `gh_pipe_bash`. `run_selfsteal` — мост к selfsteal.sh через `/dev/tty`.
- apt: `apt_takeover`/`apt_wait_locks`/`sanitize_apt_repos`/`apt_update_safe`/`apt_update_one_repo`/
  `ensure_packages` (борьба с cloud-init/unattended-upgrades локами).
- Docker: `install_docker` (get.docker.com → apt fallback), `ensure_docker_daemon_config`.
- Производительность: `apply_performance_tuning` (BBR/буферы/RPS и т.п.) — серверная, панели не касается.
- Нода (РЕФАКТОРЕНО): `_rn_collect_params` (интерактивный сбор в globals `RN_PANEL_IP/RN_NODE_PORT/
  RN_XTLS/RN_SECRET`, 0=ок/1=отмена) → `install_remnanode` (шапка + предочистка + collect + do) →
  `_rn_do_install` (шаги 0-8 из `RN_*`: apt/пакеты/тюнинг/docker/.env+compose/pull/up/ожидание/
  открытие порта + сводка + `run_tspu_check auto`). Делёж нужен, чтобы «Самое нужное» спросило всё заранее.
- Диагностика: `diagnose_remnanode_eproto`/`update_remnanode_secret` (EPROTO/handshake 40 = порт/ключ ≠ панели).
- Панель: `update_remnawave_panel` (пин `backend:3`, бэкап, миграция env).
- Selfsteal-мост: `install_selfsteal` (выбор Caddy/Nginx → `run_selfsteal @ install --caddy|--nginx`).
- ⭐ `install_essentials` — «Самое нужное»: Remnanode + Selfsteal + WARP за один заход. Все вопросы
  ЗАРАНЕЕ (collect ноды + домен/ws/порт selfsteal + да/нет WARP), один финальный confirm, затем без
  участия: `_rn_do_install` → `run_selfsteal @ --caddy --force --domain … --port … install` →
  WARP (install или `warp_ensure_running`). В конце — блок «⚠ ТРЕБУЕТСЯ ДЕЙСТВИЕ В ПАНЕЛИ».
- Hysteria2 (переработано 2026-10-23, по рабочей ноде DE): меню `hysteria2_menu` (пункт 3) → `install_hysteria2`
  (0 версия Xray в ноде ≥ `H2_XRAY_MIN` 26.6.1 · 1 DNS · 2 UDP 443 + порт-хоппинг 20000–29999→443 (`_h2_setup_hop`, nft
  `remna_hy2` + unit `remna-hy2-hop`) · 3 certbot standalone, 80/tcp ТОЛЬКО на время выпуска/продления через хуки
  `renewal-hooks/pre|post/remna-acme-*.sh` (временная таблица `remna_acme`, стоп/старт держателя :80 = Caddy selfsteal,
  своё правило UFW пользователя не трогают) · 4 certs → /opt/hysteria/certs (ключ 600, или 644 если не читается в контейнере,
  `.keymode`), deploy-hook · 5 volume в compose · 6 `inbound.json` (hysteria v2, TLS alpn h3, finalmask salamander
  packetSize 900-1300 + quicParams bbr; пароль salamander один раз в `.obfs`) · 7 `ИНСТРУКЦИЯ.txt` — пошагово для панели:
  inbound в УЖЕ привязанный профиль (новый профиль вытеснит Reality!), включить на ноде, сквад, хост (Address=домен, SNI, ALPN h3)).
  `check_hysteria2` (CLI `h2-check`): Xray жив, UDP 443 слушает, сертификат/SAN, монтирование, читаемость ключа, логи.
  Inbound провалидирован `xray run -test`. Старое: `install_hysteria2_legacy`, `fix_hysteria2_online` (кастомное ядро).
- WARP: `install_warp` (офиц. пакет cloudflare-warp: репо Cloudflare, /32-fix, mode proxy + порт `WARP_PORT`,
  `warp-auto.service`). **Фолбэк**: если apt даёт «held broken packages» → `--fix-broken` → `install_warp_wgcf`
  (wgcf + wireproxy, userspace WireGuard → тот же SOCKS5 `127.0.0.1:$WARP_PORT`, БЕЗ пакета и kernel-модулей,
  systemd `warp-wireproxy.service`, конфиг `/etc/wireproxy/`). Outbound в панели менять НЕ нужно (порт тот же).
  Хелперы метод-агностичны: `_warp_installed`/`_warp_is_wireproxy`, `warp_is_connected` (cli: парсит
  `warp-cli status`, «Disconnected» содержит «connected» → проверяем оба; wireproxy: `systemctl is-active`),
  `warp_port_listening`, `warp_ensure_running` (автохил при запуске, 1 раз/процесс, guard `_WARP_CHECKED`,
  оба метода). CLI: `remnanode warp-wgcf` — форсить альтернативный метод. MTProto: `install_mtproto`.
- Система: `setup_swap`, `setup_ufw`, `setup_ports`/`ports_open`/`ports_open_panel` (firewall через nft,
  это НЕ UFW), `apply_performance_tuning`, анти-DDoS `setup_antiddos`/`apply_antiddos`.
- Тесты/РКН: `run_speedtest_menu` и др.; **`run_tspu_check`** (~5222) — проверка блокировки из РФ через
  **check-host.net**: TCP IP:порт из городов РФ (1 узел/город, ранжир по крупным городам, до 10) +
  контрольные узлы вне РФ; вердикт блок-по-IP / ТСПУ / частично / глобально недоступно. `_ch_get`/`_ch_status_of`.
- Статусы/меню: `show_header` (шапка главного меню: OS/CPU/IP/NODE_PORT/Selfsteal/**WARP**),
  `menu_item`/`section`/`service_badge_color`, `node_status_screen`, `remnanode_menu` (управление нодой),
  `main_menu` (корневое меню), `tests_menu`, `system_menu`.

## selfsteal.sh — карта
- Шапка: срезает лидирующий `@`, парсит `--debug/--source`, затем основной `case` аргументов (~1300+):
  `--nginx/--caddy`, `--force/-f`, `--domain`, `--port`, `--template`, `--acme-port`, `--tcp/--socket`, команда.
- **Неинтерактивный режим** (используется в «Самое нужное»):
  `selfsteal --caddy --force --domain <d> [--port 9443] [--template 1-11] install` — пропускает DNS-проверку,
  все prompt'ы и confirm, при существующей установке авто-переустанавливает. Caddy = авто-SSL, полностью сам.
  Nginx — через acme.sh (нужен DNS + свободный 80/8443). `DEFAULT_PORT=9443`.
- Ключевое: `install_command` (~2677), `create_caddy_config`/`create_nginx_config`, `issue_ssl_certificate`
  (acme.sh), `download_template` (11 шаблонов + анти-fingerprint рандомизация), `install_management_script`,
  команды up/down/restart/status/logs/renew-ssl/reissue-cert/uninstall/edit/update, `main_menu`.
- Директории: Caddy → `/opt/caddy`, Nginx → `/opt/nginx-selfsteal`. Домен в `.env` (`SELF_STEAL_DOMAIN`).

## Ключевые решения и почему
- **Re-exec из tempfile**: `bash <(curl…)` даёт `/dev/fd/*`, где prompt'ы ломаются в Termius → копируем себя в /tmp.
- **Всё в /dev/tty**: иначе интерактив теряется под `curl | bash`.
- **Node image = latest** (3.3.x) + **панель backend:3**: latest-нода стыкуется только с панелью 3.3+.
  EPROTO/handshake 40 почти всегда = в панели Node Port стоит 443 или ключ/порт ≠ ноде.
- **Reality dest/xver**: Caddy → `xver=0`; Nginx → `xver=1` (proxy_protocol). dest = `127.0.0.1:<selfsteal port>`.
- **ports_* (nft) ≠ UFW**: это отдельный «firewall OPEN» для порта ноды к IP панели. UFW — отдельный пункт.
- **WARP /32-fix**: на VPS с /32 WARP не поднимается без `172.30.255.1/24` на интерфейсе (`warp-fix-network.sh`).
- **WARP автохил**: пользователю НЕ нужен фоновой демон — повторный запуск лаунчера проверяет и чинит WARP
  (`warp_ensure_running` в начале `main_menu`/`remnanode_menu`), статус виден в строке WARP шапки.
- **Зеркала GitHub**: доступ из РФ к raw.githubusercontent часто закрыт → ghproxy/ghfast/jsdelivr + антикэш `?_=ts`.

## Соглашения по коду
- `set -Eeuo pipefail` глобально. В меню — «мягкий режим» `_menu_soft_mode` (`set +e; trap - ERR`),
  чтобы ошибка команды не убивала UI. `err()` делает `exit 1` (фатально даже в мягком режиме).
- Ввод: `ask`/`ask_secret`/`ask_yes_no`/`ask_choice` + `_is_back` для «назад». Отмена = `return 0/1`, не exit.
- Длинные шаги: `run_step "msg" "cmd"` (спиннер + лог в fd 3). Мягкий — `run_step_soft`.
- Параметры ноды передаются через globals `RN_*` между `_rn_collect_params` и `_rn_do_install`.
- Эмодзи в меню: после иконки МИНИМУМ два ASCII-пробела (Termius «съедает» один у ☁️✈️🛡️⚙️).
  НЕ использовать широкие рамки фикс-ширины с эмодзи ВНУТРИ линий — ломает выравнивание в Termius.
- Секреты: `.env` с `chmod 600`, ключ не печатать (только preview/длина).
- Коммиты/PR: НЕ вставлять идентификатор модели никуда в репозиторий (только в чат).
  Хвост коммита: `Co-Authored-By: Claude …` + `Claude-Session: …` (см. актуальный system-reminder).

## Команды (CLI `remnanode` / аргументы)
- Меню: `bash <(curl -Ls "<RAW>/remnanode.sh?$(date +%s)") @ install`  или просто `remnanode`.
- `essentials|all|setup|quick` → «Самое нужное» (нода+selfsteal+warp).
- `install-remnanode`, `install-selfsteal`, `install-warp`, `install-hysteria2|h2`, `install-mtproto`.
- `warp-check|warp-up|warp-fix` → поднять/проверить WARP.
- `secret|eproto|doctor` → диагностика EPROTO. `panel-update` → обновить панель. `restart|logs|status|up|down`.
- `self-update` → обновить лаунчер. selfsteal: `selfsteal <template|logs|status|renew-ssl|edit|uninstall>`.
- В меню: пункт `A` = «Самое нужное» (пункты 1/2/5 — раздельная установка ноды/selfsteal/warp сохранены).

## run_tspu_check — мультисервисный детектор (переработано)
Было: один check-host.net, только TCP IP:порт. Стало (строки ~5222+):
- **Источник 1 check-host.net**: TCP IP:порт по городам РФ (до 16, расширенный rank-список) + контроль вне РФ;
  + HTTPS/SNI по домену маскировки через `/check-http` (парсер `_ch_http_status_of`, flag==1&&httpCode!=null ⇒ TLS ок).
- **Источник 2 globalping** (api.globalping.io, только интерактив): `_gp_measure` (POST+poll, без `-f`, читаем http_code),
  reachability IP:443 + SNI домена + пооператорная матрица по ASN (`_OP_ASN`: МТС/Билайн/Мегафон/Tele2/Ростелеком),
  честная деградация «нет проб» где у globalping нет живых RU-проб оператора. Токен опц. `GP_TOKEN`.
- **Graceful degradation**: оба легли → локальная `openssl s_client` проба (без РФ-vantage, честно помечена).
- **Опционально через env**: `GP_TOKEN` (лимит globalping), `IPINFO_TOKEN` (метка ASN хостера), `RIPE_ATLAS_KEY` (не реализован, задел).
- **Вердикт** раздельный: блок-по-IP / блок-по-SNI / чисто / частично / глобально-недоступно, с тегами
  действий `[VPS]`/`[панель]`/`[клиент]` и оговоркой: active-probing / uTLS-fingerprint снаружи НЕ видны.
- **auto-режим** (после install, 3302/3832) — лёгкий: только check-host TCP (без globalping/SNI), чтобы не тормозить установку и не жечь лимит.
- **Опрос check-host = 18 итераций** (было 8): при НЕдоступном сервере узлы отдают таймаут-FAIL ~10с,
  8с не хватало → показывало «не успел» вместо ⛔. Ранний выход при готовности сохранён (доступный сервер — быстро).
  Если ВСЕ (РФ + контроль) по 443 = ⛔ → на 443 никто не слушает глобально = Reality-inbound не настроен в панели (частый кейс после установки).
- ⚠️ Парсеры провалидированы на мок-JSON по докам, но ЖИВЬЁМ из sandbox не протестированы (egress 403 на оба API).
  Нужен один прогон `remnanode rkn` на VPS для сверки форматов /check-http и globalping; парсеры защитные (деградируют, не падают).
- ASN операторов (на 2026): МТС AS8359/25513, Билайн AS3216/16345, Мегафон AS31133/31205/25159,
  Tele2 AS15378/12958/41330, Ростелеком AS12389/42610. Мобильные операторы free-API покрывает частично (датацентр-смещение).

## Известные баги / TODO
- [ ] Общий аудит улучшений (перф ноды / скорость загрузок / UX / надёжность) — [research workflow, по итогу показать пользователю].
- [ ] `run_tspu_check`: сверить живьём форматы check-host `/check-http` и globalping на VPS; при расхождении — поправить парсеры.
- [ ] (опц.) RIPE Atlas для настоящей пооператорной TLS-матрицы — только с `RIPE_ATLAS_KEY` (кредиты).
- [ ] Валидация домена в `install_essentials` отклоняет кириллические/punycode-домены (regex ASCII-FQDN) — ок для Reality, но помнить.

## История (git, свежее)
- feat: UX установки ноды, РКН из городов РФ, назад в меню.
- backend:3 + нода latest; пин node:2.7.0 (latest 3.x давал EPROTO на панели 2.7.4) — сейчас перешли на latest+backend:3.
- Фиксы EPROTO/handshake 40 (не портить SECRET_KEY при вставке), @ install не залипает на старой версии.
