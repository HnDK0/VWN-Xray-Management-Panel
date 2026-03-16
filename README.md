<details open>
<summary>🇬🇧 English</summary>

# VWN — Xray Management Panel

Automated installer for Xray VLESS with WebSocket+TLS, XHTTP, gRPC, Reality, Cloudflare WARP, CDN, Relay, Psiphon, and Tor support.

## Quick Install

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/HnDK0/VLESS-WebSocket-TLS-Nginx-WARP/main/install.sh)
```

After installation the script is available as a command:
```bash
vwn
```

Update modules (without touching configs):
```bash
vwn update
```

## Requirements

- Ubuntu 22.04+ / Debian 11+
- Root access
- A domain pointed at the server (for WS+TLS/XHTTP/gRPC)
- For Reality — only the server IP is needed, no domain required

## Features

- ✅ **VLESS + WebSocket + TLS** — connections via Cloudflare CDN
- ✅ **VLESS + XHTTP + TLS** — HTTP-based multiplexed transport via CDN (CDN-optimised, xmux)
- ✅ **VLESS + gRPC + TLS** — gRPC transport via CDN (HTTP/2)
- ✅ **VLESS + Reality** — direct connections without CDN (router, Clash)
- ✅ **Nginx** — reverse proxy with a stub/decoy site, WS + XHTTP + gRPC on port 443
- ✅ **Cloudflare WARP** — route selected domains or all traffic
- ✅ **Psiphon** — censorship bypass with exit country selection
- ✅ **Tor** — censorship bypass with exit country selection, bridge support (obfs4, snowflake, meek)
- ✅ **Relay** — external outbound (VLESS/VMess/Trojan/SOCKS via link)
- ✅ **CF Guard** — blocks direct access, only Cloudflare IPs allowed
- ✅ **Multi-user** — multiple UUIDs with labels, individual QR codes and subscription URLs
- ✅ **Subscription URL** — per-user `/sub/` link for v2rayNG, Hiddify, Nekoray and others
- ✅ **HTML config page** — per-user browser page with Copy/QR buttons, token-protected
- ✅ **Backup & Restore** — manual backup/restore of all configs (incl. Psiphon, Tor)
- ✅ **Diagnostics** — full system check with per-component breakdown, user sync check
- ✅ **WARP Watchdog** — auto-reconnect WARP on failure
- ✅ **Fail2Ban + Web-Jail** — brute-force and scanner protection
- ✅ **BBR** — TCP acceleration
- ✅ **Anti-Ping** — ICMP disabled
- ✅ **IPv6 disabled system-wide** — forced IPv4
- ✅ **Privacy** — access logs off, sniffing disabled
- ✅ **RU / EN interface** — language selector on first run

## Architecture

```
Client (CDN/mobile)
    └── Cloudflare CDN → 443/HTTPS → Nginx
            ├── /path       → VLESS+WS    → Xray ws-inbound
            ├── /pathx      → VLESS+XHTTP → Xray xhttp-inbound
            └── /pathg      → VLESS+gRPC  → Xray grpc-inbound
                                                └── outbound

Client (router/Clash/direct)
    └── IP:8443/TCP → VLESS+Reality → Xray → outbound

outbound (by routing rules):
    ├── free    — direct exit (default)
    ├── warp    — Cloudflare WARP (SOCKS5:40000)
    ├── psiphon — Psiphon tunnel (SOCKS5:40002)
    ├── tor     — Tor (SOCKS5:40003)
    ├── relay   — external server (vless/vmess/trojan/socks)
    └── block   — blackhole (geoip:private)
```

## Ports

| Port  | Purpose                                      |
|-------|----------------------------------------------|
| 22    | SSH (configurable)                           |
| 443   | VLESS+WS / XHTTP / gRPC via Nginx            |
| 8443  | VLESS+Reality (default)                      |
| N     | Xray WS inbound (default 16500, loopback)    |
| N+1   | Xray XHTTP inbound (default 16501, loopback) |
| N+2   | Xray gRPC inbound (default 16502, loopback)  |
| 40000 | WARP SOCKS5 (warp-cli, local)                |
| 40002 | Psiphon SOCKS5 (local)                       |
| 40003 | Tor SOCKS5 (local)                           |
| 40004 | Tor Control Port (local)                     |

## CLI Commands

```bash
vwn           # Open interactive menu
vwn update    # Update modules (no config changes)
```

## Menu

```
================================================================
   VWN — Xray Management Panel  17.03.2026 21:00
================================================================
  ── Protocols ──────────────────────────────────────────────
  WS:      RUNNING,  WARP: ACTIVE | Split
  Reality: RUNNING,  SSL: OK (89d)
  Nginx:   RUNNING,  CF Guard: OFF
  CDN:     cdn.example.com
  XHTTP path: /abc123x   gRPC svc: abc123g
  ── Tunnels ────────────────────────────────────────────────
  Relay: OFF,  Psiphon: OFF,  Tor: OFF
  ── Security ───────────────────────────────────────────────
  BBR: ON,  F2B: ON,  Jail: PROTECTED
----------------------------------------------------------------
  1.  Install / Reinstall
  2.  Manage users

  ── Protocols ──────────────────────────────────────────────
  3.  Manage WS + XHTTP + gRPC + CDN
  4.  Manage VLESS + Reality
  ...
```

### Status indicators

| Status | Meaning |
|--------|---------|
| `ACTIVE \| Global` | All traffic routed through tunnel |
| `ACTIVE \| Split` | Only domains from the list |
| `ACTIVE \| route OFF` | Service running but not in routing |
| `OFF` | Service not running |

## Multi-user (item 2)

Multiple VLESS UUIDs with labels (e.g. "iPhone Vasya", "Laptop work").

- Each user gets their own UUID applied to **all three inbounds** (WS, XHTTP, gRPC) and Reality instantly
- Add / Remove / Rename users
- Individual QR code per user (WS, XHTTP, gRPC and Reality links)
- Individual subscription URL per user (base64, all protocols)
- **HTML config page** per user — token-protected browser page with Copy/QR for every link
- Cannot delete the last user
- Users stored in `/usr/local/etc/xray/users.conf` (format: `UUID|label|token`)

On first open, the existing UUID is automatically imported as user `default`.

## Subscription URL

Each user gets a personal subscription URL:

```
https://your-domain.com/sub/label_token.txt
```

The file is base64-encoded and contains all connection links for that user (WS, XHTTP, gRPC, and Reality if installed). Compatible with v2rayNG, Hiddify, Nekoray, Mihomo/Clash Meta and others.

- URL does not change when configs are updated — only the content changes
- URL changes only when the user is renamed
- Manage via item 2 → item 3 (QR + Subscription URL) or item 5 (Rebuild all)

## HTML Config Page

Each user also gets a browser-accessible config page:

```
https://your-domain.com/sub/label_token.html
```

Features: dark theme, Copy button, QR code popup for each protocol link. Protected by the 24-character random token in the URL — no login required, not guessable.

## WS + XHTTP + gRPC + CDN Management (item 3)

Submenu for managing the WS/XHTTP/gRPC+TLS setup:

| Item | Action |
|------|--------|
| 1 | Change Xray port (updates all three inbounds) |
| 2 | Change path (updates WS, XHTTP, gRPC paths atomically) |
| 3 | Change domain |
| 4 | Connection address (CDN domain) |
| 5 | Reissue SSL certificate |
| 6 | Change stub site |
| 7 | CF Guard — Cloudflare-only access (block direct) |
| 8 | Update Cloudflare IPs |
| 9 | Manage SSL auto-renewal |
| 10 | Manage log auto-clear |
| 11 | Change UUID |

Path scheme: given base path `/abc123`:
- WS  → `/abc123`
- XHTTP → `/abc123x`
- gRPC → `abc123g` (serviceName)

## CDN Transport Comparison

| Protocol | CDN | Multiplexing | Notes |
|----------|-----|-------------|-------|
| WS | ✅ | ❌ | Best compatibility, HTTP/1.1 |
| XHTTP | ✅ | ✅ xmux | Recommended for mobile/unstable links |
| gRPC | ✅ | ✅ H/2 | Low latency, requires HTTP/2 on CDN |
| Reality | ❌ | ❌ | Direct only, best disguise |

**XHTTP** is recommended for Cloudflare CDN — it uses `xmux` (3–5 concurrent streams per connection), `scStreamUpServerSecs=60-240` to keep upstream alive through CF's 100s idle timeout, and `xPaddingBytes=400-800` for traffic obfuscation.

## Backup & Restore (item 27)

Backups stored in `/root/vwn-backups/` with timestamps. No auto-deletion.

What is backed up: Xray configs, Nginx + SSL certs, Cloudflare API key, cron tasks, Fail2Ban rules, Psiphon service + data, Tor config.

## Diagnostics (item 26)

Full scan or per-component check via submenu:

| Section | Checks |
|---------|--------|
| System | RAM, disk, swap, clock sync |
| Xray | Config validity, service status, WS/XHTTP/gRPC ports, users.conf sync |
| Nginx | Config, service, port 443, SSL expiry, DNS match |
| WARP | warp-svc, connection, SOCKS5 response |
| Tunnels | Psiphon / Tor / Relay status |
| Connectivity | Internet, domain reachability, HTTP status |

Output: `✓` / `✗` per check, summary of issues at the end.

## SSL Certificates

**Method 1 — Cloudflare DNS API** (recommended): port 80 not needed.  
**Method 2 — Standalone**: temporarily opens port 80.

Auto-renewal via cron every 35 days at 03:00.

## CF Guard (item 3 → 7)

Blocks direct server access — only requests coming through Cloudflare IPs are allowed. Enable after setting up the orange cloud in Cloudflare DNS. Use item 3 → 8 to refresh the Cloudflare IP list.

Note: Real IP restoration (`CF-Connecting-IP`) is applied automatically on installation and is independent of CF Guard.

## File Structure

```
/usr/local/lib/vwn/
├── lang.sh       # Localisation (RU/EN)
├── core.sh       # Variables, utilities, status
├── xray.sh       # Xray WS+XHTTP+gRPC config
├── nginx.sh      # Nginx, CDN, SSL, subscriptions
├── warp.sh       # WARP management
├── reality.sh    # VLESS+Reality
├── relay.sh      # External outbound
├── psiphon.sh    # Psiphon tunnel
├── tor.sh        # Tor tunnel
├── security.sh   # UFW, BBR, Fail2Ban, SSH
├── logs.sh       # Logs, logrotate, cron
├── backup.sh     # Backup & Restore
├── users.sh      # Multi-user management
├── diag.sh       # Diagnostics
└── menu.sh       # Main menu

/usr/local/etc/xray/
├── config.json              # VLESS+WS+XHTTP+gRPC config
├── reality.json             # VLESS+Reality config
├── reality_client.txt       # Reality client params
├── vwn.conf                 # VWN settings (lang, XHTTP_PATH, GRPC_SERVICE)
├── users.conf               # User list (UUID|label|token)
├── sub/                     # Subscription files
│   ├── label_token.txt      # base64 subscription (all protocols)
│   └── label_token.html     # HTML config page with Copy/QR
├── warp_domains.txt
├── psiphon.json
├── psiphon_domains.txt
├── tor_domains.txt
├── relay.conf
└── relay_domains.txt

/root/vwn-backups/
└── vwn-backup-YYYY-MM-DD_HH-MM-SS.tar.gz
```

## Troubleshooting

```bash
# Something not working — run diagnostics
vwn  # item 26

# WARP won't connect
systemctl restart warp-svc && sleep 5 && warp-cli --accept-tos connect

# Psiphon logs
tail -50 /var/log/psiphon/psiphon.log

# Reality won't start
xray -test -config /usr/local/etc/xray/reality.json

# Nginx after IPv6 disable
sed -i '/listen \[::\]:443/d' /etc/nginx/conf.d/xray.conf && nginx -t && systemctl reload nginx

# Tor — try bridges (item 7 → 11)
tail -50 /var/log/tor/notices.log

# Subscription / HTML page not updating
vwn  # item 2 → item 5 (Rebuild subscriptions + HTML pages)

# Check all three Xray inbound ports are listening
ss -tlnp | grep -E ':(16500|16501|16502)'

# Test XHTTP path in nginx
curl -sk https://your-domain.com/abc123x -o /dev/null -w "%{http_code}"
```

## Removal

```bash
vwn  # item 29
```

Note: backups in `/root/vwn-backups/` are not removed automatically.

## Dependencies

- [Xray-core](https://github.com/XTLS/Xray-core)
- [Cloudflare WARP](https://1.1.1.1/)
- [Psiphon tunnel core](https://github.com/Psiphon-Labs/psiphon-tunnel-core-binaries)
- [acme.sh](https://github.com/acmesh-official/acme.sh)
- nginx, jq, ufw, tor, obfs4proxy, qrencode

## License

MIT License

</details>

---

<details>
<summary>🇷🇺 Русский</summary>

# VWN — Xray Management Panel

Автоматический установщик Xray VLESS с поддержкой WebSocket+TLS, XHTTP, gRPC, Reality, Cloudflare WARP, CDN, Relay, Psiphon и Tor.

## Быстрая установка

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/HnDK0/VLESS-WebSocket-TLS-Nginx-WARP/main/install.sh)
```

После установки скрипт доступен как команда:
```bash
vwn
```

Обновить модули (без изменения конфигов):
```bash
vwn update
```

## Требования

- Ubuntu 22.04+ / Debian 11+
- Root доступ
- Домен, направленный на сервер (для WS+TLS / XHTTP / gRPC)
- Для Reality — только IP сервера, домен не нужен

## Особенности

- ✅ **VLESS + WebSocket + TLS** — подключения через Cloudflare CDN
- ✅ **VLESS + XHTTP + TLS** — HTTP-транспорт с мультиплексированием через CDN (CDN-оптимизирован, xmux)
- ✅ **VLESS + gRPC + TLS** — gRPC транспорт через CDN (HTTP/2)
- ✅ **VLESS + Reality** — прямые подключения без CDN (роутер, Clash)
- ✅ **Nginx** — reverse proxy с сайтом-заглушкой, WS + XHTTP + gRPC на порту 443
- ✅ **Cloudflare WARP** — роутинг выбранных доменов или всего трафика
- ✅ **Psiphon** — обход блокировок с выбором страны выхода
- ✅ **Tor** — обход блокировок с выбором страны выхода, поддержка мостов (obfs4, snowflake, meek)
- ✅ **Relay** — внешний outbound (VLESS/VMess/Trojan/SOCKS по ссылке)
- ✅ **CF Guard** — блокировка прямого доступа, только Cloudflare IP
- ✅ **Мульти-пользователи** — несколько UUID с метками, индивидуальные QR коды и ссылки подписки
- ✅ **Ссылка подписки** — персональный `/sub/` URL для v2rayNG, Hiddify, Nekoray и других
- ✅ **HTML страница конфигов** — персональная страница в браузере с кнопками Copy/QR, защищена токеном
- ✅ **Бэкап и восстановление** — ручной бэкап/восстановление всех конфигов (включая Psiphon, Tor)
- ✅ **Диагностика** — полная проверка системы, синхронизация пользователей
- ✅ **WARP Watchdog** — автовосстановление WARP при обрыве
- ✅ **Fail2Ban + Web-Jail** — защита от брутфорса и сканеров
- ✅ **BBR** — ускорение TCP
- ✅ **Anti-Ping** — отключение ICMP
- ✅ **IPv6 отключён системно** — принудительный IPv4
- ✅ **Приватность** — access логи отключены, sniffing выключен
- ✅ **RU / EN интерфейс** — выбор языка при первом запуске

## Архитектура

```
Клиент (CDN/мобильный)
    └── Cloudflare CDN → 443/HTTPS → Nginx
            ├── /path       → VLESS+WS    → Xray ws-inbound
            ├── /pathx      → VLESS+XHTTP → Xray xhttp-inbound
            └── /pathg      → VLESS+gRPC  → Xray grpc-inbound
                                                └── outbound

Клиент (роутер/Clash/прямое)
    └── IP:8443/TCP → VLESS+Reality → Xray → outbound

outbound (по routing rules):
    ├── free    — прямой выход (default)
    ├── warp    — Cloudflare WARP (SOCKS5:40000)
    ├── psiphon — Psiphon tunnel (SOCKS5:40002)
    ├── tor     — Tor (SOCKS5:40003)
    ├── relay   — внешний сервер (vless/vmess/trojan/socks)
    └── block   — blackhole (geoip:private)
```

## Порты

| Порт  | Назначение                                        |
|-------|---------------------------------------------------|
| 22    | SSH (изменяемый)                                  |
| 443   | VLESS+WS / XHTTP / gRPC через Nginx               |
| 8443  | VLESS+Reality (по умолчанию)                      |
| N     | Xray WS inbound (default 16500, loopback)         |
| N+1   | Xray XHTTP inbound (default 16501, loopback)      |
| N+2   | Xray gRPC inbound (default 16502, loopback)       |
| 40000 | WARP SOCKS5 (warp-cli, локальный)                 |
| 40002 | Psiphon SOCKS5 (локальный)                        |
| 40003 | Tor SOCKS5 (локальный)                            |
| 40004 | Tor Control Port (локальный)                      |

## CLI команды

```bash
vwn           # Открыть интерактивное меню
vwn update    # Обновить модули (без изменения конфигов)
```

## Меню управления

```
================================================================
   VWN — Xray Management Panel  17.03.2026 21:00
================================================================
  ── Протоколы ────────────────────────────────────────────────
  WS:      RUNNING,  WARP: ACTIVE | Split
  Reality: RUNNING,  SSL: OK (89d)
  Nginx:   RUNNING,  CF Guard: OFF
  CDN:     cdn.example.com
  XHTTP путь: /abc123x   gRPC svc: abc123g
  ── Туннели ──────────────────────────────────────────────────
  Relay: OFF,  Psiphon: OFF,  Tor: OFF
  ── Безопасность ─────────────────────────────────────────────
  BBR: ON,  F2B: ON,  Jail: PROTECTED
----------------------------------------------------------------
  1.  Установить / Переустановить
  2.  Управление пользователями

  ── Протоколы ──────────────────────────────────────────────
  3.  Управление WS + XHTTP + gRPC + CDN
  4.  Управление VLESS + Reality
  ...
```

### Статусы в заголовке

| Статус | Описание |
|--------|----------|
| `ACTIVE \| Global` | Весь трафик идёт через туннель |
| `ACTIVE \| Split` | Только домены из списка |
| `ACTIVE \| маршрут OFF` | Сервис запущен, но не в роутинге |
| `OFF` | Сервис не запущен |

## Мульти-пользователи (пункт 2)

Несколько VLESS UUID с произвольными метками ("iPhone Vasya", "Ноутбук работа").

- Каждый пользователь получает свой UUID, применяемый ко **всем трём inbound'ам** (WS, XHTTP, gRPC) и Reality одновременно
- Добавить / Удалить / Переименовать / QR для каждого
- Индивидуальная ссылка подписки (base64, все протоколы)
- **HTML страница конфигов** для каждого пользователя — тёмная, с Copy/QR, защищена токеном
- Последнего пользователя удалить нельзя
- Хранится в `/usr/local/etc/xray/users.conf` (формат: `UUID|метка|токен`)

При первом открытии существующий UUID импортируется как пользователь `default`.

## Ссылка подписки

Каждый пользователь получает персональную ссылку подписки:

```
https://ваш-домен.com/sub/label_token.txt
```

Файл закодирован в base64 и содержит все ссылки подключения: WS, XHTTP, gRPC, Reality (если установлен). Совместим с v2rayNG, Hiddify, Nekoray, Mihomo/Clash Meta и другими.

- URL не меняется при обновлении конфигов — меняется только содержимое
- URL меняется только при переименовании пользователя
- Управление через пункт 2 → пункт 3 (QR + Subscription URL) или пункт 5 (Пересоздать все)

## HTML страница конфигов

Кроме подписки каждый пользователь получает страницу в браузере:

```
https://ваш-домен.com/sub/label_token.html
```

Тёмная страница с кнопками Copy и QR-кодом для каждого протокола. Защищена 24-символьным случайным токеном в URL — авторизация не нужна, подобрать невозможно.

## Управление WS + XHTTP + gRPC + CDN (пункт 3)

Подменю управления WS/XHTTP/gRPC+TLS установкой:

| Пункт | Действие |
|-------|----------|
| 1 | Изменить порт Xray (обновляет все три inbound'а) |
| 2 | Изменить пути (WS, XHTTP и gRPC обновляются атомарно) |
| 3 | Сменить домен |
| 4 | Адрес подключения (CDN домен) |
| 5 | Перевыпустить SSL сертификат |
| 6 | Изменить сайт-заглушку |
| 7 | CF Guard — только Cloudflare IP (блок прямого доступа) |
| 8 | Обновить IP Cloudflare |
| 9 | Управление автообновлением SSL |
| 10 | Управление автоочисткой логов |
| 11 | Сменить UUID |

Схема путей при базовом пути `/abc123`:
- WS → `/abc123`
- XHTTP → `/abc123x`
- gRPC → `abc123g` (serviceName)

## Сравнение CDN транспортов

| Протокол | CDN | Мультиплекс | Примечание |
|----------|-----|-------------|------------|
| WS | ✅ | ❌ | Максимальная совместимость, HTTP/1.1 |
| XHTTP | ✅ | ✅ xmux | Рекомендуется для мобильных/нестабильных сетей |
| gRPC | ✅ | ✅ H/2 | Низкая задержка, требует HTTP/2 на CDN |
| Reality | ❌ | ❌ | Только прямое подключение, лучшая маскировка |

**XHTTP** рекомендуется для Cloudflare CDN — использует `xmux` (3–5 параллельных потоков на соединение), `scStreamUpServerSecs=60-240` для удержания upstream потока через 100-секундный idle timeout CF, и `xPaddingBytes=400-800` для обфускации трафика.

## Бэкап и восстановление (пункт 27)

Бэкапы в `/root/vwn-backups/` с датой и временем. Автоудаления нет.

Включает: конфиги Xray, Nginx + SSL, API ключи Cloudflare, cron, Fail2Ban, Psiphon сервис и данные, конфиг Tor.

## Диагностика (пункт 26)

| Раздел | Проверки |
|--------|----------|
| Система | RAM, диск, swap, часы |
| Xray | Валидность конфигов, сервисы, порты WS/XHTTP/gRPC, синхронизация users.conf |
| Nginx | Конфиг, сервис, SSL, DNS |
| WARP | warp-svc, подключение, SOCKS5 |
| Туннели | Psiphon / Tor / Relay |
| Связность | Интернет, домен, HTTP-статус |

Вывод: `✓` / `✗` по каждой проверке + итоговый список проблем.

## Туннели (пункты 5–7)

Все туннели поддерживают режимы: **Global / Split / OFF**. Применяются к обоим конфигам (WS+XHTTP+gRPC и Reality).

### VLESS + Reality (пункт 4)

Прямые подключения без CDN. Отдельный сервис `xray-reality`.

```
vless://UUID@IP:8443?security=reality&sni=microsoft.com&fp=chrome&pbk=KEY&sid=SID&type=tcp&flow=xtls-rprx-vision
```

### Relay (пункт 5)

Поддерживает: `vless://` `vmess://` `trojan://` `socks5://`

### Psiphon (пункт 6)

Выбор страны выхода: DE, NL, US, GB, FR, AT, CA, SE и др.

### Tor (пункт 7)

Выбор страны выхода через `ExitNodes`. Поддержка мостов: obfs4, snowflake, meek-azure. **Рекомендуется Split режим** — Tor медленнее обычного интернета.

## WARP (пункты 8–13)

**Split** (по умолчанию): `openai.com, chatgpt.com, oaistatic.com, oaiusercontent.com, auth0.openai.com`

**Global** — весь трафик через WARP. **OFF** — отключён от роутинга.

**WARP Watchdog (пункт 13)** — cron каждые 2 минуты, автопереподключение.

## SSL сертификаты

**Метод 1 — Cloudflare DNS API** (рекомендуется): порт 80 не нужен.  
**Метод 2 — Standalone**: временно открывает порт 80.

Автообновление через cron раз в 35 дней в 3:00.

## CF Guard (пункт 3 → 7)

Блокирует прямой доступ к серверу — пропускает только запросы с IP Cloudflare. Включайте после настройки оранжевого облака в Cloudflare DNS. Пункт 3 → 8 — обновить список IP Cloudflare вручную.

Примечание: восстановление реального IP (`CF-Connecting-IP`) применяется автоматически при установке и не зависит от CF Guard.

## Структура файлов

```
/usr/local/lib/vwn/
├── lang.sh       # Локализация (RU/EN)
├── core.sh       # Переменные, утилиты, статусы
├── xray.sh       # Xray WS+XHTTP+gRPC конфиг
├── nginx.sh      # Nginx, CDN, SSL, подписки
├── warp.sh       # WARP управление
├── reality.sh    # VLESS+Reality
├── relay.sh      # Внешний outbound
├── psiphon.sh    # Psiphon туннель
├── tor.sh        # Tor туннель
├── security.sh   # UFW, BBR, Fail2Ban, SSH
├── logs.sh       # Логи, logrotate, cron
├── backup.sh     # Бэкап и восстановление
├── users.sh      # Управление пользователями
├── diag.sh       # Диагностика
└── menu.sh       # Главное меню

/usr/local/etc/xray/
├── config.json              # Конфиг VLESS+WS+XHTTP+gRPC
├── reality.json             # Конфиг VLESS+Reality
├── reality_client.txt       # Параметры клиента Reality
├── vwn.conf                 # Настройки VWN (язык, XHTTP_PATH, GRPC_SERVICE)
├── users.conf               # Список пользователей (UUID|метка|токен)
├── sub/                     # Файлы подписок
│   ├── label_token.txt      # base64 подписка (все протоколы)
│   └── label_token.html     # HTML страница с Copy/QR
├── warp_domains.txt
├── psiphon.json
├── psiphon_domains.txt
├── tor_domains.txt
├── relay.conf
└── relay_domains.txt

/root/vwn-backups/
└── vwn-backup-YYYY-MM-DD_HH-MM-SS.tar.gz
```

## Решение проблем

```bash
# Что-то не работает — запустить диагностику
vwn  # пункт 26

# WARP не подключается
systemctl restart warp-svc && sleep 5 && warp-cli --accept-tos connect

# Логи Psiphon
tail -50 /var/log/psiphon/psiphon.log

# Reality не запускается
xray -test -config /usr/local/etc/xray/reality.json

# Nginx после отключения IPv6
sed -i '/listen \[::\]:443/d' /etc/nginx/conf.d/xray.conf && nginx -t && systemctl reload nginx

# Tor — попробовать мосты (пункт 7 → 11)
tail -50 /var/log/tor/notices.log

# Подписка / HTML страница не обновляется
vwn  # пункт 2 → пункт 5 (Пересоздать подписки и HTML-страницы)

# Проверить что все три inbound'а Xray слушают
ss -tlnp | grep -E ':(16500|16501|16502)'

# Проверить путь XHTTP через nginx
curl -sk https://ваш-домен.com/abc123x -o /dev/null -w "%{http_code}"
```

## Удаление

```bash
vwn  # Пункт 29
```

Бэкапы в `/root/vwn-backups/` автоматически не удаляются.

## Зависимости

- [Xray-core](https://github.com/XTLS/Xray-core)
- [Cloudflare WARP](https://1.1.1.1/)
- [Psiphon tunnel core](https://github.com/Psiphon-Labs/psiphon-tunnel-core-binaries)
- [acme.sh](https://github.com/acmesh-official/acme.sh)
- nginx, jq, ufw, tor, obfs4proxy, qrencode

## Лицензия

MIT License

</details>
