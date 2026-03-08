<details open>
<summary>🇬🇧 English</summary>

# VWN — Xray Management Panel

Automated installer for Xray VLESS with WS+TLS, gRPC+TLS, Reality, Cloudflare WARP, CDN, Relay, Psiphon, and Tor support.

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
- A domain pointed at the server (for WS/gRPC+TLS)
- For Reality — only the server IP is needed, no domain required

## Features

- ✅ **VLESS + WebSocket + TLS** — connections via Cloudflare CDN (HTTP/1.1)
- ✅ **VLESS + gRPC + TLS** — connections via Cloudflare CDN (HTTP/2, no traffic limits)
- ✅ **VLESS + Reality** — direct connections without CDN (router, Clash)
- ✅ **Transport switch** — toggle between WS and gRPC without reinstalling
- ✅ **Nginx** — reverse proxy with a stub/decoy site
- ✅ **Cloudflare WARP** — route selected domains or all traffic
- ✅ **Psiphon** — censorship bypass with exit country selection
- ✅ **Tor** — censorship bypass with exit country selection, bridge support (obfs4, snowflake, meek)
- ✅ **Relay** — external outbound (VLESS/VMess/Trojan/SOCKS via link)
- ✅ **CF Guard** — blocks direct access, only Cloudflare IPs allowed
- ✅ **Multi-user** — multiple UUIDs with labels, individual QR codes and subscription URLs
- ✅ **Subscription URL** — per-user `/sub/` link for v2rayNG, Hiddify, Nekoray and others
- ✅ **Backup & Restore** — manual backup/restore of all configs
- ✅ **Diagnostics** — full system check with per-component breakdown
- ✅ **WARP Watchdog** — auto-reconnect WARP on failure
- ✅ **Fail2Ban + Web-Jail** — brute-force and scanner protection
- ✅ **BBR** — TCP acceleration
- ✅ **Anti-Ping** — ICMP disabled
- ✅ **IPv6 disabled system-wide** — forced IPv4
- ✅ **Privacy** — access logs off, sniffing disabled
- ✅ **RU / EN interface** — language selector on first run

## Architecture

```
Client (CDN/mobile) — WS mode
    └── Cloudflare CDN → 443/HTTPS (HTTP/1.1) → Nginx → VLESS+WS → Xray → outbound

Client (CDN/mobile) — gRPC mode
    └── Cloudflare CDN → 443/HTTPS (HTTP/2)   → Nginx → VLESS+gRPC → Xray → outbound

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

## WS vs gRPC

Both transports are configured during installation. Only one runs at a time.

| | WS | gRPC |
|--|--|--|
| HTTP version | HTTP/1.1 | HTTP/2 |
| Cloudflare traffic limits | Yes (technically) | No |
| Client support | Universal | Most modern clients |
| Switch | Item 3 → 5 | Item 3 → 5 |

Switch is instant — stops one service, flips `listen 443 ssl` ↔ `listen 443 ssl http2`, starts the other. Subscriptions regenerate automatically with only the active transport link.

> **Note:** To use gRPC via Cloudflare CDN, enable gRPC in the Cloudflare dashboard: **Network → gRPC → On**.

## Ports

| Port  | Purpose                           |
|-------|-----------------------------------|
| 22    | SSH (configurable)                |
| 443   | VLESS+WS or VLESS+gRPC via Nginx  |
| 8443  | VLESS+Reality (default)           |
| 40000 | WARP SOCKS5 (warp-cli, local)     |
| 40002 | Psiphon SOCKS5 (local)            |
| 40003 | Tor SOCKS5 (local)                |
| 40004 | Tor Control Port (local)          |

## CLI Commands

```bash
vwn           # Open interactive menu
vwn update    # Update modules (no config changes)
```

## Menu

```
================================================================
   VWN — Xray Management Panel  07.03.2026 21:00
================================================================
  ── Protocols ──────────────────────────────────────────
  WS:      RUNNING,  WARP: ACTIVE | Split
  Reality: RUNNING,  SSL: OK (89d)
  Nginx:   RUNNING,  CF Guard: OFF
  CDN:     www.exemple.com
  ── Tunnels ────────────────────────────────────────────
  Relay: OFF,  Psiphon: OFF,  Tor: OFF
  ── Security ───────────────────────────────────────────
  BBR: ON,  F2B: ON,  Jail: PROTECTED
----------------------------------------------------------------
  1.  Install Xray (VLESS+WS/gRPC+TLS+WARP+CDN)
  2.  Manage users

  ── Protocols ──────────────────────────────────────────
  3.  Manage VLESS + WS/gRPC + Nginx
  4.  Manage VLESS + Reality
  ...
```

## WS + gRPC Management (item 3)

Submenu for managing both transports:

| Item | Action |
|------|--------|
| 1 | Change WS port |
| 2 | Change WS path |
| 3 | Change gRPC port |
| 4 | Change gRPC service name |
| 5 | Switch transport (WS ↔ gRPC) |
| 6 | Change domain |
| 7 | Connection address (CDN domain) |
| 8 | Reissue SSL certificate |
| 9 | Change stub site |
| 10 | CF Guard — Cloudflare-only access |
| 11 | Update Cloudflare IPs |
| 12 | Manage SSL auto-renewal |
| 13 | Manage log auto-clear |
| 14 | Change UUID |

The header shows the currently active transport with its port and path/service name.

### Status indicators

| Status | Meaning |
|--------|---------|
| `ACTIVE \| Global` | All traffic routed through tunnel |
| `ACTIVE \| Split` | Only domains from the list |
| `ACTIVE \| route OFF` | Service running but not in routing |
| `OFF` | Service not running |

## Multi-user (item 2)

Multiple VLESS UUIDs with labels (e.g. "iPhone Vasya", "Laptop work").

- Each user gets their own UUID applied to both WS/gRPC and Reality configs instantly
- Add / Remove / Rename users
- Individual QR code per user — shows only the active transport (WS or gRPC) + Reality
- Individual subscription URL per user — contains only active transport link
- Cannot delete the last user
- Users stored in `/usr/local/etc/xray/users.conf` (format: `UUID|label|token`)

On first open, the existing UUID is automatically imported as user `default`.

## Subscription URL

Each user gets a personal subscription URL:

```
https://your-domain.com/sub/label_token.txt
```

The file is base64-encoded and contains connection links for the **active transport** only (WS or gRPC) plus Reality if installed. Compatible with v2rayNG, Hiddify, Nekoray, Mihomo/Clash Meta and others.

- URL does not change when configs are updated — only the content changes
- URL changes only when the user is renamed
- After switching transport, rebuild subscriptions via item 2 → item 5 (or switching does it automatically)

## Backup & Restore (item 27)

Backups stored in `/root/vwn-backups/` with timestamps. No auto-deletion.

What is backed up: Xray configs (WS + gRPC + Reality), Nginx + SSL certs, Cloudflare API key, cron tasks, Fail2Ban rules.

## Diagnostics (item 26)

Full scan or per-component check via submenu:

| Section | Checks |
|---------|--------|
| System | RAM, disk, swap, clock sync |
| Xray | WS config, gRPC config, active service, ports |
| Nginx | Config, service, port 443, SSL expiry, DNS |
| WARP | warp-svc, connection, SOCKS5 response |
| Tunnels | Psiphon / Tor / Relay status |
| Connectivity | Internet, domain reachability |

Output: `✓` / `✗` per check, summary of issues at the end.

## SSL Certificates

**Method 1 — Cloudflare DNS API** (recommended): port 80 not needed.  
**Method 2 — Standalone**: temporarily opens port 80.

Auto-renewal via cron every 35 days at 03:00.

## CF Guard (item 3 → 10)

Blocks direct server access — only requests coming through Cloudflare IPs are allowed. Enable after setting up the orange cloud in Cloudflare DNS. Use item 3 → 11 to refresh the Cloudflare IP list.

Note: Real IP restoration (`CF-Connecting-IP`) is applied automatically on installation and is independent of CF Guard.

## File Structure

```
/usr/local/lib/vwn/
├── lang.sh       # Localisation (RU/EN)
├── core.sh       # Variables, utilities, status
├── xray.sh       # Xray WS+TLS / gRPC config
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
├── config.json              # VLESS+WS config
├── config-grpc.json         # VLESS+gRPC config
├── reality.json             # VLESS+Reality config
├── reality_client.txt       # Reality client params
├── vwn.conf                 # VWN settings (lang, etc.)
├── users.conf               # User list (UUID|label|token)
├── connect_host             # CDN connect address (optional)
├── sub/                     # Subscription files
│   └── label_token.txt
├── warp_domains.txt
├── psiphon.json
├── psiphon_domains.txt
├── tor_domains.txt
├── relay.conf
└── relay_domains.txt

/etc/systemd/system/
├── xray.service             # WS service
├── xray-grpc.service        # gRPC service (one active at a time)
└── xray-reality.service     # Reality service

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

# gRPC won't connect through Cloudflare
# Make sure gRPC is enabled: Cloudflare dashboard → Network → gRPC → On

# Nginx after IPv6 disable
sed -i '/listen \[::\]:443/d' /etc/nginx/conf.d/xray.conf && nginx -t && systemctl reload nginx

# Tor — try bridges (item 7 → 11)
tail -50 /var/log/tor/notices.log

# Subscription not updating after transport switch
vwn  # item 2 → item 5 (Rebuild all subscription files)
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

Автоматический установщик Xray VLESS с поддержкой WS+TLS, gRPC+TLS, Reality, Cloudflare WARP, CDN, Relay, Psiphon и Tor.

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
- Домен, направленный на сервер (для WS/gRPC+TLS)
- Для Reality — только IP сервера, домен не нужен

## Особенности

- ✅ **VLESS + WebSocket + TLS** — подключения через Cloudflare CDN (HTTP/1.1)
- ✅ **VLESS + gRPC + TLS** — подключения через Cloudflare CDN (HTTP/2, без лимитов трафика)
- ✅ **VLESS + Reality** — прямые подключения без CDN (роутер, Clash)
- ✅ **Переключение транспорта** — мгновенный переход между WS и gRPC без переустановки
- ✅ **Nginx** — reverse proxy с сайтом-заглушкой
- ✅ **Cloudflare WARP** — роутинг выбранных доменов или всего трафика
- ✅ **Psiphon** — обход блокировок с выбором страны выхода
- ✅ **Tor** — обход блокировок с выбором страны выхода, поддержка мостов (obfs4, snowflake, meek)
- ✅ **Relay** — внешний outbound (VLESS/VMess/Trojan/SOCKS по ссылке)
- ✅ **CF Guard** — блокировка прямого доступа, только Cloudflare IP
- ✅ **Мульти-пользователи** — несколько UUID с метками, индивидуальные QR коды и ссылки подписки
- ✅ **Ссылка подписки** — персональный `/sub/` URL для v2rayNG, Hiddify, Nekoray и других
- ✅ **Бэкап и восстановление** — ручной бэкап/восстановление всех конфигов
- ✅ **Диагностика** — полная проверка системы с детализацией по компонентам
- ✅ **WARP Watchdog** — автовосстановление WARP при обрыве
- ✅ **Fail2Ban + Web-Jail** — защита от брутфорса и сканеров
- ✅ **BBR** — ускорение TCP
- ✅ **Anti-Ping** — отключение ICMP
- ✅ **IPv6 отключён системно** — принудительный IPv4
- ✅ **Приватность** — access логи отключены, sniffing выключен
- ✅ **RU / EN интерфейс** — выбор языка при первом запуске

## Архитектура

```
Клиент (CDN/мобильный) — WS режим
    └── Cloudflare CDN → 443/HTTPS (HTTP/1.1) → Nginx → VLESS+WS → Xray → outbound

Клиент (CDN/мобильный) — gRPC режим
    └── Cloudflare CDN → 443/HTTPS (HTTP/2)   → Nginx → VLESS+gRPC → Xray → outbound

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

## WS vs gRPC

Оба транспорта настраиваются при установке. Одновременно активен только один.

| | WS | gRPC |
|--|--|--|
| HTTP версия | HTTP/1.1 | HTTP/2 |
| Лимиты трафика Cloudflare | Формально да | Нет |
| Поддержка клиентами | Универсальная | Большинство современных |
| Переключение | Пункт 3 → 5 | Пункт 3 → 5 |

Переключение мгновенное — останавливает один сервис, меняет `listen 443 ssl` ↔ `listen 443 ssl http2`, запускает другой. Подписки пересоздаются автоматически — содержат только активный транспорт.

> **Примечание:** Для работы gRPC через Cloudflare CDN необходимо включить gRPC в панели Cloudflare: **Network → gRPC → On**.

## Порты

| Порт  | Назначение                        |
|-------|-----------------------------------|
| 22    | SSH (изменяемый)                  |
| 443   | VLESS+WS или VLESS+gRPC через Nginx |
| 8443  | VLESS+Reality (по умолчанию)      |
| 40000 | WARP SOCKS5 (warp-cli, локальный) |
| 40002 | Psiphon SOCKS5 (локальный)        |
| 40003 | Tor SOCKS5 (локальный)            |
| 40004 | Tor Control Port (локальный)      |

## CLI команды

```bash
vwn           # Открыть интерактивное меню
vwn update    # Обновить модули (без изменения конфигов)
```

## Меню управления

```
================================================================
   VWN — Xray Management Panel  07.03.2026 21:00
================================================================
  ── Протоколы ──────────────────────────────────────────
  WS:      RUNNING,  WARP: ACTIVE | Split
  Reality: RUNNING,  SSL: OK (89d)
  Nginx:   RUNNING,  CF Guard: OFF
  CDN:     www.exemple.com
  ── Туннели ────────────────────────────────────────────
  Relay: OFF,  Psiphon: OFF,  Tor: OFF
  ── Безопасность ───────────────────────────────────────
  BBR: ON,  F2B: ON,  Jail: PROTECTED
----------------------------------------------------------------
  1.  Установить Xray (VLESS+WS/gRPC+TLS+WARP+CDN)
  2.  Управление пользователями

  ── Протоколы ──────────────────────────────────────────
  3.  Управление VLESS + WS/gRPC + Nginx
  4.  Управление VLESS + Reality
  ...
```

## Управление WS + gRPC (пункт 3)

| Пункт | Действие |
|-------|----------|
| 1 | Изменить порт WS |
| 2 | Изменить путь WS |
| 3 | Изменить порт gRPC |
| 4 | Изменить service name gRPC |
| 5 | Переключить транспорт (WS ↔ gRPC) |
| 6 | Сменить домен |
| 7 | Адрес подключения (CDN домен) |
| 8 | Перевыпустить SSL сертификат |
| 9 | Изменить сайт-заглушку |
| 10 | CF Guard — только Cloudflare IP |
| 11 | Обновить IP Cloudflare |
| 12 | Управление автообновлением SSL |
| 13 | Управление автоочисткой логов |
| 14 | Сменить UUID |

В заголовке подменю отображается активный транспорт с его портом и путём/service name.

### Статусы в заголовке

| Статус | Описание |
|--------|----------|
| `ACTIVE \| Global` | Весь трафик идёт через туннель |
| `ACTIVE \| Split` | Только домены из списка |
| `ACTIVE \| маршрут OFF` | Сервис запущен, но не в роутинге |
| `OFF` | Сервис не запущен |

## Мульти-пользователи (пункт 2)

Несколько VLESS UUID с произвольными метками ("iPhone Vasya", "Ноутбук работа").

- Добавить / Удалить / Переименовать / QR для каждого
- Изменения мгновенно применяются к конфигам WS, gRPC и Reality
- QR и подписка содержат только **активный транспорт** (WS или gRPC) + Reality
- Последнего пользователя удалить нельзя
- Хранится в `/usr/local/etc/xray/users.conf` (формат: `UUID|метка|токен`)

При первом открытии существующий UUID импортируется как пользователь `default`.

## Ссылка подписки

Каждый пользователь получает персональную ссылку подписки:

```
https://ваш-домен.com/sub/label_token.txt
```

Файл закодирован в base64 и содержит ссылки **только активного транспорта** (WS или gRPC) + Reality. Совместим с v2rayNG, Hiddify, Nekoray, Mihomo/Clash Meta и другими.

- URL не меняется при обновлении конфигов
- URL меняется только при переименовании пользователя
- После переключения транспорта подписки пересоздаются автоматически

## Бэкап и восстановление (пункт 27)

Бэкапы в `/root/vwn-backups/` с датой и временем. Автоудаления нет.

Включает: конфиги Xray (WS + gRPC + Reality), Nginx + SSL, API ключи Cloudflare, cron, Fail2Ban.

## Диагностика (пункт 26)

| Раздел | Проверки |
|--------|----------|
| Система | RAM, диск, swap, часы |
| Xray | WS конфиг, gRPC конфиг, активный сервис, порты |
| Nginx | Конфиг, сервис, SSL, DNS |
| WARP | warp-svc, подключение, SOCKS5 |
| Туннели | Psiphon / Tor / Relay |
| Связность | Интернет, домен |

## SSL сертификаты

**Метод 1 — Cloudflare DNS API** (рекомендуется): порт 80 не нужен.  
**Метод 2 — Standalone**: временно открывает порт 80.

Автообновление через cron раз в 35 дней в 3:00.

## CF Guard (пункт 3 → 10)

Блокирует прямой доступ — пропускает только запросы с IP Cloudflare. Включайте после настройки оранжевого облака в Cloudflare DNS. Пункт 3 → 11 — обновить список IP вручную.

## Структура файлов

```
/usr/local/lib/vwn/
├── lang.sh       # Локализация (RU/EN)
├── core.sh       # Переменные, утилиты, статусы
├── xray.sh       # Xray WS / gRPC конфиг
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
├── config.json              # Конфиг VLESS+WS
├── config-grpc.json         # Конфиг VLESS+gRPC
├── reality.json             # Конфиг VLESS+Reality
├── reality_client.txt       # Параметры клиента Reality
├── vwn.conf                 # Настройки VWN (язык и др.)
├── users.conf               # Список пользователей (UUID|метка|токен)
├── connect_host             # CDN адрес подключения (опционально)
├── sub/                     # Файлы подписок
│   └── label_token.txt
├── warp_domains.txt
├── psiphon.json
├── psiphon_domains.txt
├── tor_domains.txt
├── relay.conf
└── relay_domains.txt

/etc/systemd/system/
├── xray.service             # WS сервис
├── xray-grpc.service        # gRPC сервис (одновременно активен один)
└── xray-reality.service     # Reality сервис

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

# gRPC не работает через Cloudflare
# Включить: Cloudflare dashboard → Network → gRPC → On

# Nginx после отключения IPv6
sed -i '/listen \[::\]:443/d' /etc/nginx/conf.d/xray.conf && nginx -t && systemctl reload nginx

# Tor — попробовать мосты (пункт 7 → 11)
tail -50 /var/log/tor/notices.log

# Подписка не обновилась после переключения транспорта
vwn  # пункт 2 → пункт 5 (Пересоздать файлы подписки)
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
