<details open>
<summary>🇬🇧 English</summary>

# VWN — Xray Management Panel

Automated installer for Xray VLESS with WebSocket+TLS, Reality, Cloudflare WARP, CDN, Relay, Psiphon, and Tor support.

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
- A domain pointed at the server (for WS+TLS)
- For Reality — only the server IP is needed, no domain required

## Features

- ✅ **VLESS + WebSocket + TLS** — connections via Cloudflare CDN
- ✅ **VLESS + Reality** — direct connections without CDN (router, Clash) — installed together with WS
- ✅ **Nginx mainline** — reverse proxy with a stub/decoy site, auto-installs from nginx.org
- ✅ **Cloudflare WARP** — route selected domains or all traffic
- ✅ **Psiphon** — censorship bypass with exit country selection
- ✅ **Tor** — censorship bypass with exit country selection, bridge support (obfs4, snowflake, meek)
- ✅ **Relay** — external outbound (VLESS/VMess/Trojan/SOCKS via link)
- ✅ **CF Guard** — blocks direct access, only Cloudflare IPs allowed
- ✅ **Multi-user** — multiple UUIDs with labels, individual QR codes and subscription URLs
- ✅ **Subscription URL** — per-user `.txt` (clients) and `.html` (browser with QR) pages
- ✅ **CPU Guard** — prioritises xray/nginx over background processes, prevents host throttling
- ✅ **Backup & Restore** — manual backup/restore of all configs
- ✅ **Diagnostics** — full system check with per-component breakdown
- ✅ **WARP Watchdog** — auto-reconnect WARP on failure (lockfile, double-check, hard restart fallback)
- ✅ **Fail2Ban + Web-Jail** — brute-force and scanner protection
- ✅ **BBR** — TCP acceleration
- ✅ **Anti-Ping** — ICMP disabled
- ✅ **IPv6 toggle** — enable/disable system-wide IPv6
- ✅ **Privacy** — access logs off, sniffing disabled
- ✅ **RU / EN interface** — language selector on first run

## Architecture

```
Client (CDN/mobile)
    └── Cloudflare CDN → 443/HTTPS → Nginx → VLESS+WS → Xray → outbound

Client (router/Clash/direct)
    └── IP:8443/TCP → VLESS+Reality → Xray → outbound

outbound (by routing rules):
    ├── free    — direct exit (default)
    ├── warp    — Cloudflare WARP (SOCKS5:40000)
    ├── psiphon — Psiphon tunnel (SOCKS5:40002)
    ├── tor     — Tor (SOCKS5:40003)
    ├── relay   — external server (vless/vmess/trojan/socks)
    └── block   — blackhole (geoip:private, SMTP, BitTorrent)
```

## Ports

| Port  | Purpose                           |
|-------|-----------------------------------|
| 22    | SSH (configurable)                |
| 443   | VLESS+WS+TLS via Nginx            |
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
   VWN — Xray Management Panel  18.03.2026 12:00
================================================================
  ── Protocols ──────────────────────────────────────────
  WS:      RUNNING,  WARP: ACTIVE | Split
  Reality: RUNNING,  SSL: OK (89d)
  Nginx:   RUNNING,  CF Guard: OFF
  CDN:     cdn.example.com
  ── Tunnels ────────────────────────────────────────────
  Relay: OFF,  Psiphon: OFF,  Tor: OFF
  ── Security ───────────────────────────────────────────
  BBR: ON,  F2B: ON,  Jail: PROTECTED,  IPv6: OFF,  CPU Guard: ON
----------------------------------------------------------------
  1.  Install
  2.  Manage users

  ── Protocols ──────────────────────────────────────────
  3.  Manage WS + CDN
  4.  Manage VLESS + Reality

  ── Tunnels ────────────────────────────────────────────
  5.  Manage Relay (external)
  6.  Manage Psiphon
  7.  Manage Tor

  ── WARP ───────────────────────────────────────────────
  8.  Toggle WARP mode (Global/Split/OFF)
  9.  Add domain to WARP
  10. Remove domain from WARP
  11. Edit WARP list (Nano)
  12. Check IP (Real vs WARP)
  13. Install WARP Watchdog

  ── Security ───────────────────────────────────────────
  14. Enable BBR
  15. Enable Fail2Ban
  16. Enable Web-Jail
  17. Change SSH port
  18. Manage UFW
  19. Toggle IPv6
  20. CPU Guard (priority)

  ── Logs ───────────────────────────────────────────────
  21. Xray logs (access)
  22. Xray logs (error)
  23. Nginx logs (access)
  24. Nginx logs (error)
  25. Clear all logs

  ── Services ───────────────────────────────────────────
  26. Restart all services
  27. Update Xray-core
  28. Diagnostics
  29. Backup & Restore
  30. Change language
  31. Full removal

  ── Exit ───────────────────────────────────────────────
  0.  Exit
```

### Status indicators

| Status | Meaning |
|--------|---------|
| `ACTIVE \| Global` | All traffic routed through tunnel |
| `ACTIVE \| Split` | Only domains from the list |
| `ACTIVE \| route OFF` | Service running but not in routing |
| `OFF` | Service not running |
| `CPU Guard: ON` | xray/nginx have priority over background processes |

## Multi-user (item 2)

Multiple VLESS UUIDs with labels (e.g. "iPhone Vasya", "Laptop work").

- Add / Remove / Rename users
- Changes applied instantly to both WS and Reality configs
- Individual QR code per user (WS and Reality links)
- Individual subscription URL per user
- Cannot delete the last user
- Users stored in `/usr/local/etc/xray/users.conf` (format: `UUID|label|token`)

On first open, the existing UUID is automatically imported as user `default`.

## Subscription URL

Each user gets two personal subscription pages:

```
https://your-domain.com/sub/label_token.txt   ← clients (v2rayNG, Hiddify, Nekoray…)
https://your-domain.com/sub/label_token.html  ← browser page with QR codes + copy buttons
```

The `.txt` file is base64-encoded and contains all connection links (WS+TLS and Reality if installed).  
The `.html` page shows each link with a **copy button** and a **QR code on click** (one at a time, no clutter).

- URL does not change when configs are updated — only the content changes
- URL changes only when the user is renamed
- Manage via item 2 → item 3 (QR + Subscription URL) or item 2 → item 5 (Rebuild all)

## WS + CDN Management (item 3)

| Item | Action |
|------|--------|
| 1 | Change Xray port |
| 2 | Change WS path |
| 3 | Change domain |
| 4 | Connection address (CDN domain) |
| 5 | Reissue SSL certificate |
| 6 | Change stub site |
| 7 | CF Guard — Cloudflare-only access |
| 8 | Update Cloudflare IPs |
| 9 | Manage SSL auto-renewal |
| 10 | Manage log auto-clear |
| 11 | Change UUID |

## CPU Guard (item 20)

Protects against host throttling caused by stray processes consuming CPU.

Sets `CPUWeight=200` and `Nice=-10` for xray, xray-reality, and nginx — they always get CPU first.  
Sets `CPUWeight=20` for `user.slice` (SSH sessions, background scripts) — limited to ~16% CPU.

Settings are written to systemd drop-in files and survive reboot:
```
/etc/systemd/system/xray.service.d/cpuguard.conf
/etc/systemd/system/nginx.service.d/cpuguard.conf
/etc/systemd/system/user.slice.d/cpuguard.conf
```

Status is shown in the menu header: `CPU Guard: ON / OFF`.

## VLESS + Reality (item 4)

Direct connections without CDN. Separate `xray-reality` service.  
Can be installed **together with WS** during initial setup — the installer asks at the end.

```
vless://UUID@IP:8443?security=reality&sni=microsoft.com&fp=chrome&pbk=KEY&sid=SID&type=tcp&flow=xtls-rprx-vision
```

## Tunnels (items 5–7)

All tunnels support **Global / Split / OFF** modes. Applied to both WS and Reality configs.

### Relay (item 5)

Supported: `vless://` `vmess://` `trojan://` `socks5://`

### Psiphon (item 6)

Exit country selection: DE, NL, US, GB, FR, AT, CA, SE and others.  
Optional WARP+Psiphon chained mode.

### Tor (item 7)

Exit country via `ExitNodes`. Bridge support: obfs4, snowflake, meek-azure.  
**Recommended: Split mode** — Tor is slower than direct internet.

## WARP (items 8–13)

**Split** (default domains): `openai.com, chatgpt.com, oaistatic.com, oaiusercontent.com, auth0.openai.com`

**Global** — all traffic via WARP. **OFF** — removed from routing.

**WARP Watchdog (item 13)** — cron every 5 minutes. Checks port 40000, double-verifies before action, soft reconnect first, hard restart only as last resort. Prevents parallel runs via lockfile.

## SSL Certificates

**Method 1 — Cloudflare DNS API** (recommended): port 80 not needed.  
**Method 2 — Standalone**: temporarily opens port 80.

Auto-renewal via cron every 35 days at 03:00.  
Nginx is started before SSL issuance so the reload hook succeeds.

## CF Guard (item 3 → 7)

Blocks direct server access — only requests from Cloudflare IPs are allowed.  
Enable after setting up the orange cloud in Cloudflare DNS.  
Use item 3 → 8 to refresh the Cloudflare IP list.

Real IP restoration (`CF-Connecting-IP`) is applied automatically on install, independent of CF Guard.

## Backup & Restore (item 29)

Backups stored in `/root/vwn-backups/` with timestamps. No auto-deletion.

What is backed up: Xray configs, Nginx + SSL certs, Cloudflare API key, cron tasks, Fail2Ban rules.

## Diagnostics (item 28)

| Section | Checks |
|---------|--------|
| System | RAM, disk, swap, clock sync |
| Xray | Config validity, service status, ports |
| Nginx | Config, service, port 443, SSL expiry, DNS |
| WARP | warp-svc, connection, SOCKS5 response |
| Tunnels | Psiphon / Tor / Relay status |
| Connectivity | Internet, domain reachability |

Output: `✓` / `✗` per check, summary of issues at the end.

## File Structure

```
/usr/local/lib/vwn/
├── lang.sh       # Localisation (RU/EN)
├── core.sh       # Variables, utilities, status, vwn_conf_*
├── xray.sh       # Xray WS+TLS config
├── nginx.sh      # Nginx, CDN, SSL, subscriptions
├── warp.sh       # WARP management + watchdog
├── reality.sh    # VLESS+Reality
├── relay.sh      # External outbound
├── psiphon.sh    # Psiphon tunnel
├── tor.sh        # Tor tunnel
├── security.sh   # UFW, BBR, Fail2Ban, SSH, IPv6, CPU Guard
├── logs.sh       # Logs, logrotate, cron
├── backup.sh     # Backup & Restore
├── users.sh      # Multi-user management + HTML subscription
├── diag.sh       # Diagnostics
└── menu.sh       # Main menu

/usr/local/etc/xray/
├── config.json              # VLESS+WS config
├── reality.json             # VLESS+Reality config
├── reality_client.txt       # Reality client params
├── vwn.conf                 # VWN settings (lang, domain, pubkey…)
├── users.conf               # User list (UUID|label|token)
├── sub/                     # Subscription files
│   ├── label_token.txt      # base64 links for clients
│   └── label_token.html     # Browser page (QR + copy)
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
vwn  # item 28

# WARP won't connect
systemctl restart warp-svc && sleep 5 && warp-cli connect

# Psiphon logs
tail -50 /var/log/psiphon/psiphon.log

# Reality won't start
xray -test -config /usr/local/etc/xray/reality.json

# Nginx after IPv6 disable
sed -i '/listen \[::\]:443/d' /etc/nginx/conf.d/xray.conf && nginx -t && systemctl reload nginx

# Tor — try bridges (item 7 → 11)
tail -50 /var/log/tor/notices.log

# Subscription not updating
vwn  # item 2 → item 5 (Rebuild all subscription files)

# CPU Guard — check priorities
systemctl show xray.service -p CPUWeight
```

## Removal

```bash
vwn  # item 31
```

Backups in `/root/vwn-backups/` are not removed automatically.

## Dependencies

- [Xray-core](https://github.com/XTLS/Xray-core)
- [Cloudflare WARP](https://1.1.1.1/)
- [Psiphon tunnel core](https://github.com/Psiphon-Labs/psiphon-tunnel-core-binaries)
- [acme.sh](https://github.com/acmesh-official/acme.sh)
- nginx (mainline from nginx.org), jq, ufw, tor, obfs4proxy, qrencode

## License

MIT License

</details>

---

<details>
<summary>🇷🇺 Русский</summary>

# VWN — Xray Management Panel

Автоматический установщик Xray VLESS с поддержкой WebSocket+TLS, Reality, Cloudflare WARP, CDN, Relay, Psiphon и Tor.

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
- Домен, направленный на сервер (для WS+TLS)
- Для Reality — только IP сервера, домен не нужен

## Особенности

- ✅ **VLESS + WebSocket + TLS** — подключения через Cloudflare CDN
- ✅ **VLESS + Reality** — прямые подключения без CDN (роутер, Clash) — устанавливается вместе с WS
- ✅ **Nginx mainline** — reverse proxy с сайтом-заглушкой, автоустановка с nginx.org
- ✅ **Cloudflare WARP** — роутинг выбранных доменов или всего трафика
- ✅ **Psiphon** — обход блокировок с выбором страны выхода
- ✅ **Tor** — обход блокировок с выбором страны выхода, поддержка мостов (obfs4, snowflake, meek)
- ✅ **Relay** — внешний outbound (VLESS/VMess/Trojan/SOCKS по ссылке)
- ✅ **CF Guard** — блокировка прямого доступа, только Cloudflare IP
- ✅ **Мульти-пользователи** — несколько UUID с метками, индивидуальные QR коды и ссылки подписки
- ✅ **Ссылка подписки** — `.txt` для клиентов и `.html` страница с QR в браузере
- ✅ **CPU Guard** — приоритет xray/nginx над фоновыми процессами, защита от ограничений хостера
- ✅ **Бэкап и восстановление** — ручной бэкап/восстановление всех конфигов
- ✅ **Диагностика** — полная проверка системы с детализацией по компонентам
- ✅ **WARP Watchdog** — автовосстановление WARP при обрыве (lockfile, двойная проверка, hard restart в крайнем случае)
- ✅ **Fail2Ban + Web-Jail** — защита от брутфорса и сканеров
- ✅ **BBR** — ускорение TCP
- ✅ **Anti-Ping** — отключение ICMP
- ✅ **Переключение IPv6** — включить/отключить IPv6 системно
- ✅ **Приватность** — access логи отключены, sniffing выключен
- ✅ **RU / EN интерфейс** — выбор языка при первом запуске

## Архитектура

```
Клиент (CDN/мобильный)
    └── Cloudflare CDN → 443/HTTPS → Nginx → VLESS+WS → Xray → outbound

Клиент (роутер/Clash/прямое)
    └── IP:8443/TCP → VLESS+Reality → Xray → outbound

outbound (по routing rules):
    ├── free    — прямой выход (default)
    ├── warp    — Cloudflare WARP (SOCKS5:40000)
    ├── psiphon — Psiphon tunnel (SOCKS5:40002)
    ├── tor     — Tor (SOCKS5:40003)
    ├── relay   — внешний сервер (vless/vmess/trojan/socks)
    └── block   — blackhole (geoip:private, SMTP, BitTorrent)
```

## Порты

| Порт  | Назначение                        |
|-------|-----------------------------------|
| 22    | SSH (изменяемый)                  |
| 443   | VLESS+WS+TLS через Nginx          |
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
   VWN — Xray Management Panel  18.03.2026 12:00
================================================================
  ── Протоколы ──────────────────────────────────────────
  WS:      RUNNING,  WARP: ACTIVE | Split
  Reality: RUNNING,  SSL: OK (89d)
  Nginx:   RUNNING,  CF Guard: OFF
  CDN:     cdn.example.com
  ── Туннели ────────────────────────────────────────────
  Relay: OFF,  Psiphon: OFF,  Tor: OFF
  ── Безопасность ───────────────────────────────────────
  BBR: ON,  F2B: ON,  Jail: PROTECTED,  IPv6: OFF,  CPU Guard: ON
----------------------------------------------------------------
  1.  Установить
  2.  Управление пользователями

  ── Протоколы ──────────────────────────────────────────
  3.  Управление WS + CDN
  4.  Управление VLESS + Reality

  ── Туннели ────────────────────────────────────────────
  5.  Управление Relay (внешний сервер)
  6.  Управление Psiphon
  7.  Управление Tor

  ── WARP ───────────────────────────────────────────────
  8.  Переключить режим WARP (Global/Split/OFF)
  9.  Добавить домен в WARP
  10. Удалить домен из WARP
  11. Редактировать список WARP (Nano)
  12. Проверить IP (Real vs WARP)
  13. Установить WARP Watchdog

  ── Безопасность ───────────────────────────────────────
  14. Включить BBR
  15. Включить Fail2Ban
  16. Включить Web-Jail
  17. Сменить SSH порт
  18. Управление UFW
  19. Вкл/Выкл IPv6
  20. CPU Guard (приоритеты)

  ── Логи ───────────────────────────────────────────────
  21. Логи Xray (access)
  22. Логи Xray (error)
  23. Логи Nginx (access)
  24. Логи Nginx (error)
  25. Очистить все логи

  ── Сервисы ────────────────────────────────────────────
  26. Перезапустить все сервисы
  27. Обновить Xray-core
  28. Диагностика
  29. Бэкап и восстановление
  30. Сменить язык / Change language
  31. Полное удаление

  ── Выход ──────────────────────────────────────────────
  0.  Выйти
```

### Статусы в заголовке

| Статус | Описание |
|--------|----------|
| `ACTIVE \| Global` | Весь трафик идёт через туннель |
| `ACTIVE \| Split` | Только домены из списка |
| `ACTIVE \| маршрут OFF` | Сервис запущен, но не в роутинге |
| `OFF` | Сервис не запущен |
| `CPU Guard: ON` | xray/nginx имеют приоритет над фоновыми процессами |

## Мульти-пользователи (пункт 2)

Несколько VLESS UUID с произвольными метками ("iPhone Vasya", "Ноутбук работа").

- Добавить / Удалить / Переименовать
- Изменения мгновенно применяются к обоим конфигам (WS и Reality)
- Индивидуальный QR код для каждого пользователя (WS и Reality ссылки)
- Индивидуальная ссылка подписки для каждого пользователя
- Последнего пользователя удалить нельзя
- Хранится в `/usr/local/etc/xray/users.conf` (формат: `UUID|метка|токен`)

При первом открытии существующий UUID импортируется как пользователь `default`.

## Ссылка подписки

Каждый пользователь получает две персональные страницы:

```
https://ваш-домен.com/sub/label_token.txt   ← клиенты (v2rayNG, Hiddify, Nekoray…)
https://ваш-домен.com/sub/label_token.html  ← браузер: QR коды + кнопки копирования
```

`.txt` файл закодирован в base64 и содержит все ссылки подключения (WS+TLS и Reality если установлен).  
`.html` страница показывает каждую ссылку с **кнопкой копирования** и **QR кодом по клику** — по одному, без нагромождения.

- URL не меняется при обновлении конфигов — меняется только содержимое
- URL меняется только при переименовании пользователя
- Управление: пункт 2 → 3 (QR + Subscription URL) или пункт 2 → 5 (Пересоздать все)

## Управление WS + CDN (пункт 3)

| Пункт | Действие |
|-------|----------|
| 1 | Изменить порт Xray |
| 2 | Изменить путь WS |
| 3 | Сменить домен |
| 4 | Адрес подключения (CDN домен) |
| 5 | Перевыпустить SSL сертификат |
| 6 | Изменить сайт-заглушку |
| 7 | CF Guard — только Cloudflare IP |
| 8 | Обновить IP Cloudflare |
| 9 | Управление автообновлением SSL |
| 10 | Управление автоочисткой логов |
| 11 | Сменить UUID |

## CPU Guard (пункт 20)

Защита от ограничений хостера из-за посторонних процессов нагружающих CPU.

Устанавливает `CPUWeight=200` и `Nice=-10` для xray, xray-reality и nginx — они всегда получают CPU первыми.  
Устанавливает `CPUWeight=20` для `user.slice` (SSH сессии, фоновые скрипты) — максимум ~16% CPU.

Настройки записываются в drop-in файлы systemd и переживают перезагрузку:
```
/etc/systemd/system/xray.service.d/cpuguard.conf
/etc/systemd/system/nginx.service.d/cpuguard.conf
/etc/systemd/system/user.slice.d/cpuguard.conf
```

Статус виден в шапке меню: `CPU Guard: ON / OFF`.

## VLESS + Reality (пункт 4)

Прямые подключения без CDN. Отдельный сервис `xray-reality`.  
Можно установить **вместе с WS** во время первичной установки — установщик предложит в конце.

```
vless://UUID@IP:8443?security=reality&sni=microsoft.com&fp=chrome&pbk=KEY&sid=SID&type=tcp&flow=xtls-rprx-vision
```

## Туннели (пункты 5–7)

Все туннели поддерживают режимы: **Global / Split / OFF**. Применяются к обоим конфигам (WS и Reality).

### Relay (пункт 5)

Поддерживает: `vless://` `vmess://` `trojan://` `socks5://`

### Psiphon (пункт 6)

Выбор страны выхода: DE, NL, US, GB, FR, AT, CA, SE и др.  
Поддерживается режим WARP+Psiphon (цепочка туннелей).

### Tor (пункт 7)

Выбор страны выхода через `ExitNodes`. Поддержка мостов: obfs4, snowflake, meek-azure.  
**Рекомендуется Split режим** — Tor медленнее обычного интернета.

## WARP (пункты 8–13)

**Split** (домены по умолчанию): `openai.com, chatgpt.com, oaistatic.com, oaiusercontent.com, auth0.openai.com`

**Global** — весь трафик через WARP. **OFF** — отключён от роутинга.

**WARP Watchdog (пункт 13)** — cron каждые 5 минут. Проверяет порт 40000, двойная проверка перед действием, сначала мягкое переподключение, жёсткий рестарт только в крайнем случае. Защита от параллельных запусков через lockfile.

## SSL сертификаты

**Метод 1 — Cloudflare DNS API** (рекомендуется): порт 80 не нужен.  
**Метод 2 — Standalone**: временно открывает порт 80.

Автообновление через cron раз в 35 дней в 3:00.  
Nginx запускается до выпуска сертификата — reload hook срабатывает корректно.

## CF Guard (пункт 3 → 7)

Блокирует прямой доступ к серверу — пропускает только запросы с IP Cloudflare.  
Включайте после настройки оранжевого облака в Cloudflare DNS.  
Пункт 3 → 8 — обновить список IP Cloudflare вручную.

Восстановление реального IP (`CF-Connecting-IP`) применяется автоматически при установке и не зависит от CF Guard.

## Бэкап и восстановление (пункт 29)

Бэкапы в `/root/vwn-backups/` с датой и временем. Автоудаления нет.

Включает: конфиги Xray, Nginx + SSL, API ключи Cloudflare, cron, Fail2Ban.

## Диагностика (пункт 28)

| Раздел | Проверки |
|--------|----------|
| Система | RAM, диск, swap, часы |
| Xray | Конфиги, сервисы, порты |
| Nginx | Конфиг, сервис, SSL, DNS |
| WARP | warp-svc, подключение, SOCKS5 |
| Туннели | Psiphon / Tor / Relay |
| Связность | Интернет, домен |

Вывод: `✓` / `✗` по каждой проверке + итоговый список проблем.

## Структура файлов

```
/usr/local/lib/vwn/
├── lang.sh       # Локализация (RU/EN)
├── core.sh       # Переменные, утилиты, статусы, vwn_conf_*
├── xray.sh       # Xray WS+TLS конфиг
├── nginx.sh      # Nginx, CDN, SSL, подписки
├── warp.sh       # WARP управление + watchdog
├── reality.sh    # VLESS+Reality
├── relay.sh      # Внешний outbound
├── psiphon.sh    # Psiphon туннель
├── tor.sh        # Tor туннель
├── security.sh   # UFW, BBR, Fail2Ban, SSH, IPv6, CPU Guard
├── logs.sh       # Логи, logrotate, cron
├── backup.sh     # Бэкап и восстановление
├── users.sh      # Управление пользователями + HTML подписки
├── diag.sh       # Диагностика
└── menu.sh       # Главное меню

/usr/local/etc/xray/
├── config.json              # Конфиг VLESS+WS
├── reality.json             # Конфиг VLESS+Reality
├── reality_client.txt       # Параметры клиента Reality
├── vwn.conf                 # Настройки VWN (язык, домен, pubkey…)
├── users.conf               # Список пользователей (UUID|метка|токен)
├── sub/                     # Файлы подписок
│   ├── label_token.txt      # base64 ссылки для клиентов
│   └── label_token.html     # Браузерная страница (QR + копирование)
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
vwn  # пункт 28

# WARP не подключается
systemctl restart warp-svc && sleep 5 && warp-cli connect

# Логи Psiphon
tail -50 /var/log/psiphon/psiphon.log

# Reality не запускается
xray -test -config /usr/local/etc/xray/reality.json

# Nginx после отключения IPv6
sed -i '/listen \[::\]:443/d' /etc/nginx/conf.d/xray.conf && nginx -t && systemctl reload nginx

# Tor — попробовать мосты (пункт 7 → 11)
tail -50 /var/log/tor/notices.log

# Подписка не обновляется
vwn  # пункт 2 → пункт 5 (Пересоздать файлы подписки)

# CPU Guard — проверить приоритеты
systemctl show xray.service -p CPUWeight
```

## Удаление

```bash
vwn  # Пункт 31
```

Бэкапы в `/root/vwn-backups/` автоматически не удаляются.

## Зависимости

- [Xray-core](https://github.com/XTLS/Xray-core)
- [Cloudflare WARP](https://1.1.1.1/)
- [Psiphon tunnel core](https://github.com/Psiphon-Labs/psiphon-tunnel-core-binaries)
- [acme.sh](https://github.com/acmesh-official/acme.sh)
- nginx (mainline с nginx.org), jq, ufw, tor, obfs4proxy, qrencode

## Лицензия

MIT License

</details>