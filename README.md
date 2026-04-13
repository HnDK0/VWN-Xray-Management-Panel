<details open>
<summary>🇬🇧 English</summary>

# VWN — Xray Management Panel

Automated installer for Xray VLESS with WebSocket+TLS, Reality, Vision, Cloudflare WARP, CDN, Relay, Psiphon, and Tor support.

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

## Unattended Install (`--auto`)

Fully non-interactive installation — pass all parameters as arguments, no prompts.

### Minimal (WS+CDN, standalone SSL via HTTP-01)
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/HnDK0/VLESS-WebSocket-TLS-Nginx-WARP/main/install.sh) \
  --auto --domain vpn.example.com
```

### Full (WS + Reality + Vision, SSL via Cloudflare DNS, BBR, Fail2Ban)
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/HnDK0/VLESS-WebSocket-TLS-Nginx-WARP/main/install.sh) \
  --auto \
  --domain vpn.example.com \
  --stub https://microsoft.com/ \
  --cert-method cf --cf-email me@example.com --cf-key YOUR_CF_KEY \
  --reality --reality-dest www.apple.com:443 --reality-port 8443 \
  --stream \
  --vision --vision-domain dir.example.com --vision-cert-method cf \
  --bbr --fail2ban
```

### Reality only (no WS, no Nginx, no domain needed)
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/HnDK0/VLESS-WebSocket-TLS-Nginx-WARP/main/install.sh) \
  --auto --skip-ws \
  --reality --reality-dest microsoft.com:443 --reality-port 8443
```

### All `--auto` options

| Option | Default | Description |
|--------|---------|-------------|
| `--domain DOMAIN` | — | CDN domain for VLESS+WS+TLS. **Required** unless `--skip-ws` |
| `--stub URL` | `https://httpbin.org/` | Fake/decoy site URL proxied by Nginx |
| `--port PORT` | `16500` | Internal Xray WS listen port |
| `--lang ru\|en` | `ru` | Interface language |
| `--reality` | off | Also install VLESS+Reality |
| `--reality-dest HOST:PORT` | `microsoft.com:443` | Reality SNI destination |
| `--reality-port PORT` | `8443` | Reality listen port |
| `--cert-method cf\|standalone` | `standalone` | SSL method: `cf` = Cloudflare DNS API, `standalone` = HTTP-01 |
| `--cf-email EMAIL` | — | Cloudflare account email (required for `--cert-method cf`) |
| `--cf-key KEY` | — | Cloudflare API key (required for `--cert-method cf`) |
| `--skip-ws` | off | Skip WS install entirely (Reality-only mode) |
| `--stream` | off | Activate Stream SNI — serve WS + Reality on port 443 via SNI multiplexing |
| `--vision` | off | Install VLESS+TLS+Vision (requires WS+TLS + Stream SNI) |
| `--vision-domain DOMAIN` | — | Direct domain for Vision. **Required** with `--vision`. No Cloudflare proxy! |
| `--vision-cert-method cf\|standalone` | `standalone` | SSL method for the Vision domain |
| `--bbr` | off | Enable BBR TCP congestion control |
| `--fail2ban` | off | Install Fail2Ban + WebJail (nginx scanner protection) |
| `--no-warp` | off | Skip Cloudflare WARP setup |

> **SSL methods:**  
> `standalone` — temporarily opens port 80 for Let's Encrypt HTTP-01 challenge. The domain must already point to the server.  
> `cf` — uses Cloudflare DNS API, port 80 not needed. Recommended when the domain is behind Cloudflare.

> **Vision domain:** must be a **direct** A-record pointing to the server IP. Cloudflare orange-cloud proxy must be **disabled** for this domain — Vision uses raw TLS, not HTTP, so Cloudflare cannot proxy it.

## Requirements

- Ubuntu 22.04+ / Debian 11+
- Root access
- A domain pointed at the server (for WS+TLS and Vision)
- For Reality — only the server IP is needed, no domain required

## Features

- ✅ **VLESS + WebSocket + TLS** — connections via Cloudflare CDN
- ✅ **VLESS + Reality** — direct connections without CDN (router, Clash) — installed together with WS
- ✅ **VLESS + TLS + Vision** — direct connections with `xtls-rprx-vision` flow, own TLS cert, fallback to nginx stub
- ✅ **Stream SNI** — serve WS, Reality, and Vision all on port 443 via SNI multiplexing, no extra ports exposed
- ✅ **Nginx mainline** — reverse proxy with a stub/decoy site, auto-installs from nginx.org
- ✅ **Cloudflare WARP** — route selected domains or all traffic (applied to all configs: WS, Reality, Vision)
- ✅ **Psiphon** — censorship bypass with exit country selection
- ✅ **Tor** — censorship bypass with exit country selection, bridge support (obfs4, snowflake, meek)
- ✅ **Relay** — external outbound (VLESS/VMess/Trojan/SOCKS via link)
- ✅ **CF Guard** — blocks direct access, only Cloudflare IPs allowed
- ✅ **Multi-user** — multiple UUIDs with labels, individual QR codes and subscription URLs
- ✅ **Subscription URL** — per-user `.txt` (clients) and `.html` (browser with QR) pages
- ✅ **CPU Guard** — prioritises xray/nginx over background processes, prevents host throttling
- ✅ **Privacy Mode** — Xray access logs off, Nginx access_log off, journald suppressed for all Xray services, `/var/log/xray` on tmpfs (RAM), existing logs shredded
- ✅ **Adblock** — blocks ads and trackers via built-in `geosite:category-ads-all` (EasyList, EasyPrivacy, AdGuard, regional lists); applied to all configs
- ✅ **Backup & Restore** — manual backup/restore of all configs including Vision
- ✅ **Diagnostics** — full system check with per-component breakdown including Vision
- ✅ **Fail2Ban + Web-Jail** — brute-force and scanner protection
- ✅ **BBR** — TCP acceleration
- ✅ **Anti-Ping** — ICMP disabled
- ✅ **IPv6 toggle** — enable/disable system-wide IPv6
- ✅ **Subscription auth** — `/sub/` pages protected by HTTP basic auth
- ✅ **Unattended install** — full setup via CLI flags, no interactive prompts
- ✅ **RU / EN interface** — language selector on first run

## Architecture

```
Client (CDN/mobile)
    └── Cloudflare CDN → 443/HTTPS → Nginx → VLESS+WS → Xray → outbound

Client (router/Clash — Reality)
    └── IP:8443/TCP  → VLESS+Reality → Xray → outbound        (default)
    └── IP:443/TCP   → stream SNI → VLESS+Reality → Xray      (with Stream SNI)

Client (router/Clash — Vision)
    └── domain:443/TCP → stream SNI → VLESS+TLS+Vision → Xray → outbound
                              ↓ fallback (non-Vision traffic)
                         nginx stub (shared with WS)

Stream SNI map (port 443):
    ws.example.com   → 127.0.0.1:7443   (nginx HTTP → Xray WS)
    dir.example.com  → 127.0.0.1:20xxx  (Xray Vision, auto-assigned port)
    default          → 127.0.0.1:10443  (Xray Reality)

outbound (by routing rules, applied to WS + Reality + Vision):
    ├── direct  — direct exit (default)
    ├── warp    — Cloudflare WARP (SOCKS5:40000)
    ├── psiphon — Psiphon tunnel (SOCKS5:40002)
    ├── tor     — Tor (SOCKS5:40003)
    ├── relay   — external server (vless/vmess/trojan/socks)
    └── block   — blackhole (geoip:private, ads via adblock)
```

## Ports

| Port | Purpose |
|------|---------|
| 22 | SSH (configurable) |
| 443 | VLESS+WS+TLS via Nginx (+ Reality + Vision when Stream SNI enabled) |
| 8443 | VLESS+Reality (default, external, before Stream SNI) |
| 7443¹ | Nginx HTTP (internal, Stream SNI mode) |
| 10443¹ | VLESS+Reality (internal, Stream SNI mode) |
| 20000–20999¹ | VLESS+Vision (internal, auto-assigned free port) |
| 40000 | WARP SOCKS5 (local) |
| 40002 | Psiphon SOCKS5 (local) |
| 40003 | Tor SOCKS5 (local) |
| 40004 | Tor Control Port (local) |

¹ Internal ports when Stream SNI is enabled.

## CLI Commands

```bash
vwn                  # Open interactive menu
vwn update           # Update modules (no config changes)
```

## Menu

```
================================================================
   VWN — Xray Management Panel  01.01.2026 12:00
================================================================
  ── Protocols ──────────────────────────────────────────
  WS:      RUNNING,  WARP: ACTIVE | Split
  Reality: RUNNING,  SSL: OK (89d)
  Vision:  RUNNING,  Nginx: RUNNING,  CF Guard: OFF
  CDN:     cdn.example.com
  ── Tunnels ────────────────────────────────────────────
  Relay: OFF,  Psiphon: OFF,  Tor: OFF
  ── Security ───────────────────────────────────────────
  BBR: ON,  F2B: ON,  Jail: PROTECTED,  IPv6: OFF,  CPU Guard: ON,  Adblock: OFF,  Privacy: OFF
----------------------------------------------------------------
  1.  Install
  2.  Manage users

  ── Protocols ──────────────────────────────────────────
  3.  Manage WS + CDN
  4.  Manage VLESS + Reality
  5.  Manage Vision (VLESS+TLS+Vision)

  ── Tunnels ────────────────────────────────────────────
  6.  Manage Relay (external)
  7.  Manage Psiphon
  8.  Manage Tor

  ── WARP ───────────────────────────────────────────────
  9.  Toggle WARP mode (Global/Split/OFF)
  10. Add domain to WARP
  11. Remove domain from WARP
  12. Edit WARP list (Nano)
  13. Check IP (Real vs WARP)

  ── Security ───────────────────────────────────────────
  14. Enable BBR
  15. Enable Fail2Ban
  16. Enable Web-Jail
  17. Change SSH port
  18. Manage UFW
  19. Toggle IPv6
  20. CPU Guard (priority)
  21. Adblock (block ads)

  ── Logs ───────────────────────────────────────────────
  22. Xray logs (access)
  23. Xray logs (error)
  24. Nginx logs (access)
  25. Nginx logs (error)
  26. Clear all logs
  27. Privacy mode (disable logging)

  ── Services ───────────────────────────────────────────
  28. Restart all services
  29. Update Xray-core
  30. Diagnostics
  31. Backup & Restore
  32. Change language
  33. Full removal

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
| `Adblock: ON` | Ads and trackers blocked via geosite:category-ads-all |
| `Privacy: ON` | All traffic logging disabled, logs in RAM |

## Multi-user (item 2)

Multiple VLESS UUIDs with labels (e.g. "iPhone Vasya", "Laptop work").

- Add / Remove / Rename users
- Changes applied instantly to WS, Reality, and Vision configs
- Individual QR code per user
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

The `.txt` file is base64-encoded and contains all connection links (WS+TLS, Reality, and Vision if installed).  
The `.html` page shows each link with a **copy button** and a **QR code on click**.

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
| 12 | Subscription auth (basic auth) |
| 13 | Stream SNI — Reality + Vision on port 443 |

## VLESS + TLS + Vision (item 5)

Direct connections with `xtls-rprx-vision` flow. Separate `xray-vision` service. Requires WS+TLS and Stream SNI to be active.

**How it works:**

```
Client → domain:443 → nginx stream (ssl_preread) → xray-vision:20xxx
                                                         ↓ fallback
                                               nginx stub (shared with WS)
```

- Vision domain must have a **direct DNS A-record** — no Cloudflare proxy (orange cloud must be grey)
- TLS certificate is issued separately for the Vision domain via acme.sh (CF DNS or standalone HTTP-01)
- Internal port is auto-assigned from the free range 20000–20999
- All routing features (WARP, Relay, Psiphon, Tor, Adblock, Privacy) apply to Vision automatically

**Connection link format:**
```
vless://UUID@dir.example.com:443?security=tls&flow=xtls-rprx-vision&type=tcp&sni=dir.example.com&fp=chrome
```

**Vision menu (item 5):**

| Item | Action |
|------|--------|
| 1 | Install Vision |
| 2 | Show connection info |
| 3 | Show QR code |
| 4 | Change UUID |
| 5 | Change domain (re-issues certificate) |
| 6 | Remove Vision |

## Stream SNI

Serves WS, Reality, and Vision all on port 443 via nginx `ssl_preread` SNI routing. Nginx reads the SNI field before the TLS handshake and routes traffic to the correct backend.

The routing map is dynamic — stored in `vwn.conf` as `STREAM_DOMAINS` and regenerated whenever a domain is added or removed:

```nginx
stream {
    map $ssl_preread_server_name $upstream_backend {
        ws.example.com    127.0.0.1:7443;    # nginx → Xray WS
        dir.example.com   127.0.0.1:20001;   # Xray Vision
        default           127.0.0.1:10443;   # Xray Reality
    }
    server {
        listen 443;
        ssl_preread on;
        proxy_pass $upstream_backend;
    }
}
```

Requires `nginx-full` or `nginx-extras` (built with `--with-stream`). The installer offers to install it automatically.

## Adblock (item 21)

Blocks ads and trackers for all users of the VPN without any additional software.

Uses `geosite:category-ads-all` — a built-in category in Xray's `geosite.dat`, updated automatically with every `vwn update`. Applied to WS, Reality, and Vision configs simultaneously.

**Covered lists:** EasyList, EasyPrivacy, AdGuard Base List, Peter Lowe's List, and regional ad lists for CN, RU, JP, KR, IR, TR, UA, DE, FR and others.

## Privacy Mode (item 27)

Prevents anyone with server access from seeing where users connect.

| Layer | Action |
|-------|--------|
| Xray `config.json` | `access: none`, `loglevel: none` |
| Xray `reality.json` | `access: none`, `loglevel: none` |
| Xray `vision.json` | `access: none`, `loglevel: none` |
| Nginx `xray.conf` | `access_log off` |
| systemd (xray, xray-reality, xray-vision) | `StandardOutput=null`, `StandardError=null` |
| `/var/log/xray` | Mounted as **tmpfs** (RAM) — wiped on every reboot |
| Existing logs | Overwritten with `shred` before clearing |

## CPU Guard (item 20)

Sets `CPUWeight=200` and `Nice=-10` for xray, xray-reality, xray-vision, and nginx.  
Sets `CPUWeight=20` for `user.slice` (SSH sessions, background scripts).

## Tunnels (items 6–8)

All tunnels support **Global / Split / OFF** modes. Applied to WS, Reality, and Vision configs simultaneously.

### Relay (item 6)

Supported: `vless://` `vmess://` `trojan://` `socks5://`

### Psiphon (item 7)

Exit country selection: DE, NL, US, GB, FR, AT, CA, SE and others.  
Optional WARP+Psiphon chained mode.

### Tor (item 8)

Exit country via `ExitNodes`. Bridge support: obfs4, snowflake, meek-azure.  
**Recommended: Split mode** — Tor is slower than direct internet.

## WARP (items 9–13)

**Split** (default domains): `openai.com, chatgpt.com, oaistatic.com, oaiusercontent.com, auth0.openai.com`

**Global** — all traffic via WARP. **OFF** — removed from routing. Applied to WS, Reality, and Vision configs.

## SSL Certificates

**Method 1 — Cloudflare DNS API** (recommended): port 80 not needed.  
**Method 2 — Standalone**: temporarily opens port 80.

Auto-renewal via cron every 35 days at 03:00.

Both methods are available for WS SSL (item 3 → 5) and Vision SSL (item 5 → 1 or item 5 → 5).

## Diagnostics (item 30)

| Section | Checks |
|---------|--------|
| System | RAM, disk, swap, clock sync |
| Xray | Config validity, service status, ports |
| Vision | Config validity, xray-vision service, port, SSL, DNS |
| Nginx | Config, service, port 443, SSL expiry, DNS |
| WARP | warp-svc, connection, SOCKS5 response |
| Tunnels | Psiphon / Tor / Relay status |
| Connectivity | Internet, domain reachability |

## Backup & Restore (item 31)

Backups stored in `/root/vwn-backups/` with timestamps. No auto-deletion.

Includes: Xray configs (WS, Reality, Vision), Nginx + SSL certs (including Vision certs), Cloudflare API key, cron tasks, Fail2Ban rules, xray-vision systemd service.

## File Structure

```
/usr/local/lib/vwn/
├── lang.sh       # Localisation (RU/EN)
├── core.sh       # Variables, utilities, status, vwn_conf_*, findFreePort
├── xray.sh       # Xray WS+TLS config
├── nginx.sh      # Nginx, CDN, SSL, Stream SNI (dynamic map), subscriptions
├── reality.sh    # VLESS+Reality
├── vision.sh     # VLESS+TLS+Vision
├── relay.sh      # External outbound
├── psiphon.sh    # Psiphon tunnel
├── tor.sh        # Tor tunnel
├── security.sh   # UFW, BBR, Fail2Ban, SSH, IPv6, CPU Guard
├── logs.sh       # Logs, logrotate, cron
├── backup.sh     # Backup & Restore
├── users.sh      # Multi-user management + HTML subscription
├── diag.sh       # Diagnostics (incl. Vision)
├── privacy.sh    # Privacy mode (all Xray services)
├── adblock.sh    # Adblock (all configs)
└── menu.sh       # Main menu + --auto entry point

/usr/local/etc/xray/
├── config.json              # VLESS+WS config
├── reality.json             # VLESS+Reality config
├── vision.json              # VLESS+TLS+Vision config
├── vwn.conf                 # VWN settings (lang, domain, STREAM_DOMAINS, vision_port…)
├── users.conf               # User list (UUID|label|token)
├── sub/
│   ├── label_token.txt      # base64 links for clients
│   └── label_token.html     # Browser page (QR + copy)
├── warp_domains.txt
├── psiphon.json
├── psiphon_domains.txt
├── tor_domains.txt
├── relay.conf
└── relay_domains.txt

/etc/nginx/cert/
├── cert.pem / cert.key      # WS TLS certificate
└── vision.pem / vision.key  # Vision TLS certificate

/etc/systemd/system/
├── xray.service.d/
│   ├── cpuguard.conf
│   └── no-journal.conf
├── xray-reality.service.d/
│   ├── cpuguard.conf
│   └── no-journal.conf
├── xray-vision.service        # Vision systemd unit
├── xray-vision.service.d/
│   └── no-journal.conf
├── nginx.service.d/
│   └── cpuguard.conf
├── user.slice.d/
│   └── cpuguard.conf
└── var-log-xray.mount

/root/vwn-backups/
└── vwn-backup-YYYY-MM-DD_HH-MM-SS.tar.gz
```

## Troubleshooting

```bash
# Something not working — run diagnostics
vwn  # item 30

# WARP won't connect
systemctl restart warp-svc && sleep 5 && warp-cli connect

# Psiphon logs
tail -50 /var/log/psiphon/psiphon.log

# Reality won't start
xray -test -config /usr/local/etc/xray/reality.json

# Vision won't start
xray -test -config /usr/local/etc/xray/vision.json
journalctl -u xray-vision -n 30 --no-pager

# Vision — check port is listening
ss -tlnp | grep 200

# Stream SNI — check nginx map
grep -A20 "map \$ssl_preread" /etc/nginx/nginx.conf

# Nginx after IPv6 disable
sed -i '/listen \[::\]:443/d' /etc/nginx/conf.d/xray.conf && nginx -t && systemctl reload nginx

# Tor — try bridges (item 8 → 11)
tail -50 /var/log/tor/notices.log

# Subscription not updating
vwn  # item 2 → item 5 (Rebuild all subscription files)

# Adblock — enable/disable
vwn  # item 21

# Privacy Mode — verify status
vwn  # item 27 → item 4 (Show status)

# CPU Guard — check priorities
systemctl show xray.service -p CPUWeight
```

## Removal

```bash
vwn  # item 33
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

# VWN — Панель управления Xray

Автоматический установщик Xray VLESS с поддержкой WebSocket+TLS, Reality, Vision, Cloudflare WARP, CDN, Relay, Psiphon и Tor.

## Быстрая установка

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/HnDK0/VLESS-WebSocket-TLS-Nginx-WARP/main/install.sh)
```

После установки скрипт доступен как команда:
```bash
vwn
```

Обновление модулей (без изменения конфигов):
```bash
vwn update
```

## Автоматическая установка (`--auto`)

Полностью неинтерактивная установка — все параметры передаются как аргументы.

### Минимально (WS+CDN, SSL через HTTP-01)
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/HnDK0/VLESS-WebSocket-TLS-Nginx-WARP/main/install.sh) \
  --auto --domain vpn.example.com
```

### Полная (WS + Reality + Vision, SSL через Cloudflare DNS, BBR, Fail2Ban)
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/HnDK0/VLESS-WebSocket-TLS-Nginx-WARP/main/install.sh) \
  --auto \
  --domain vpn.example.com \
  --stub https://microsoft.com/ \
  --cert-method cf --cf-email me@example.com --cf-key YOUR_CF_KEY \
  --reality --reality-dest www.apple.com:443 --reality-port 8443 \
  --stream \
  --vision --vision-domain dir.example.com --vision-cert-method cf \
  --bbr --fail2ban
```

### Только Reality (без WS, без Nginx, домен не нужен)
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/HnDK0/VLESS-WebSocket-TLS-Nginx-WARP/main/install.sh) \
  --auto --skip-ws \
  --reality --reality-dest microsoft.com:443 --reality-port 8443
```

### Все параметры `--auto`

| Параметр | Умолч. | Описание |
|----------|--------|----------|
| `--domain DOMAIN` | — | CDN-домен для VLESS+WS+TLS. **Обязателен** без `--skip-ws` |
| `--stub URL` | `https://httpbin.org/` | URL сайта-заглушки, проксируемого Nginx |
| `--port PORT` | `16500` | Внутренний порт Xray WS |
| `--lang ru\|en` | `ru` | Язык интерфейса |
| `--reality` | выкл. | Установить VLESS+Reality |
| `--reality-dest HOST:PORT` | `microsoft.com:443` | SNI-назначение Reality |
| `--reality-port PORT` | `8443` | Порт Reality |
| `--cert-method cf\|standalone` | `standalone` | Метод SSL: `cf` = Cloudflare DNS API, `standalone` = HTTP-01 |
| `--cf-email EMAIL` | — | Email Cloudflare (для `--cert-method cf`) |
| `--cf-key KEY` | — | API-ключ Cloudflare (для `--cert-method cf`) |
| `--skip-ws` | выкл. | Пропустить WS (только Reality) |
| `--stream` | выкл. | Активировать Stream SNI — WS + Reality на порту 443 |
| `--vision` | выкл. | Установить VLESS+TLS+Vision (требует WS+TLS + Stream SNI) |
| `--vision-domain DOMAIN` | — | Прямой домен для Vision. **Обязателен** с `--vision`. Без CF-прокси! |
| `--vision-cert-method cf\|standalone` | `standalone` | Метод SSL для домена Vision |
| `--bbr` | выкл. | Включить BBR TCP |
| `--fail2ban` | выкл. | Установить Fail2Ban + WebJail |
| `--no-warp` | выкл. | Не настраивать Cloudflare WARP |

> **Методы SSL:**  
> `standalone` — временно открывает порт 80 для HTTP-01. Домен должен уже указывать на сервер.  
> `cf` — использует Cloudflare DNS API, порт 80 не нужен. Рекомендуется при домене за Cloudflare.

> **Домен Vision** должен иметь **прямую A-запись** на IP сервера. Оранжевое облако Cloudflare должно быть **серым** — Vision использует raw TLS, Cloudflare не может проксировать такой трафик.

## Требования

- Ubuntu 22.04+ / Debian 11+
- Доступ root
- Домен, указывающий на сервер (для WS+TLS и Vision)
- Для Reality — нужен только IP сервера, домен не обязателен

## Возможности

- ✅ **VLESS + WebSocket + TLS** — подключения через Cloudflare CDN
- ✅ **VLESS + Reality** — прямые подключения без CDN (роутер, Clash)
- ✅ **VLESS + TLS + Vision** — прямые подключения с `xtls-rprx-vision`, собственный TLS-сертификат, fallback на nginx-заглушку
- ✅ **Stream SNI** — WS, Reality и Vision на одном порту 443 через SNI-мультиплексирование
- ✅ **Nginx mainline** — реверс-прокси с сайтом-заглушкой
- ✅ **Cloudflare WARP** — маршрутизация по доменам или весь трафик (применяется ко всем конфигам)
- ✅ **Psiphon** — обход блокировок с выбором страны выхода
- ✅ **Tor** — обход блокировок с выбором страны выхода, поддержка мостов (obfs4, snowflake, meek)
- ✅ **Relay** — внешний outbound (VLESS/VMess/Trojan/SOCKS по ссылке)
- ✅ **CF Guard** — блокировка прямого доступа, только IP Cloudflare
- ✅ **Мультипользователь** — несколько UUID с метками, индивидуальные QR и подписки
- ✅ **Подписки** — `.txt` (клиенты) и `.html` (браузер) на пользователя
- ✅ **CPU Guard** — приоритет xray/nginx над фоновыми процессами
- ✅ **Режим приватности** — логи Xray отключены, journald заглушён для всех Xray-сервисов, `/var/log/xray` на tmpfs (RAM)
- ✅ **Блокировка рекламы** — через `geosite:category-ads-all`, применяется ко всем конфигам
- ✅ **Бэкап и восстановление** — ручной бэкап всех конфигов включая Vision
- ✅ **Диагностика** — полная проверка с разбивкой по компонентам включая Vision
- ✅ **Fail2Ban + Web-Jail** — защита от брутфорса и сканеров
- ✅ **BBR, Anti-Ping, IPv6 toggle**
- ✅ **Автоустановка** — через флаги CLI без интерактивных запросов
- ✅ **Интерфейс RU / EN**

## Архитектура

```
Клиент (CDN/мобильный)
    └── Cloudflare CDN → 443/HTTPS → Nginx → VLESS+WS → Xray → outbound

Клиент (роутер/Clash — Reality)
    └── IP:8443/TCP  → VLESS+Reality → Xray → outbound        (по умолчанию)
    └── IP:443/TCP   → stream SNI → VLESS+Reality → Xray      (со Stream SNI)

Клиент (роутер/Clash — Vision)
    └── domain:443/TCP → stream SNI → VLESS+TLS+Vision → Xray → outbound
                               ↓ fallback (не-Vision трафик)
                          nginx-заглушка (общая с WS)

Stream SNI map (порт 443):
    ws.example.com   → 127.0.0.1:7443   (nginx HTTP → Xray WS)
    dir.example.com  → 127.0.0.1:20xxx  (Xray Vision, авто-порт)
    default          → 127.0.0.1:10443  (Xray Reality)

outbound (правила маршрутизации, применяются к WS + Reality + Vision):
    ├── direct  — прямой выход (по умолчанию)
    ├── warp    — Cloudflare WARP (SOCKS5:40000)
    ├── psiphon — Psiphon (SOCKS5:40002)
    ├── tor     — Tor (SOCKS5:40003)
    ├── relay   — внешний сервер (vless/vmess/trojan/socks)
    └── block   — blackhole (geoip:private, реклама через adblock)
```

## Порты

| Порт | Назначение |
|------|-----------|
| 22 | SSH (настраивается) |
| 443 | VLESS+WS+TLS через Nginx (+ Reality + Vision при Stream SNI) |
| 8443 | VLESS+Reality (по умолчанию, внешний, до Stream SNI) |
| 7443¹ | Nginx HTTP (внутренний, режим Stream SNI) |
| 10443¹ | VLESS+Reality (внутренний, режим Stream SNI) |
| 20000–20999¹ | VLESS+Vision (внутренний, автовыбор свободного порта) |
| 40000 | WARP SOCKS5 (локальный) |
| 40002 | Psiphon SOCKS5 (локальный) |
| 40003 | Tor SOCKS5 (локальный) |
| 40004 | Tor Control Port (локальный) |

¹ Внутренние порты при активном Stream SNI.

## Меню

```
================================================================
   VWN — Xray Management Panel  01.01.2026 12:00
================================================================
  ── Протоколы ─────────────────────────────────────────
  WS:      RUNNING,  WARP: ACTIVE | Split
  Reality: RUNNING,  SSL: OK (89d)
  Vision:  RUNNING,  Nginx: RUNNING,  CF Guard: OFF
  CDN:     cdn.example.com
  ── Туннели ───────────────────────────────────────────
  Relay: OFF,  Psiphon: OFF,  Tor: OFF
  ── Безопасность ──────────────────────────────────────
  BBR: ON,  F2B: ON,  Jail: PROTECTED,  IPv6: OFF,  CPU Guard: ON,  Adblock: OFF,  Privacy: OFF
----------------------------------------------------------------
  1.  Установить
  2.  Управление пользователями

  ── Протоколы ─────────────────────────────────────────
  3.  Управление WS + CDN
  4.  Управление VLESS + Reality
  5.  Управление Vision (VLESS+TLS+Vision)

  ── Туннели ───────────────────────────────────────────
  6.  Управление Relay (внешний)
  7.  Управление Psiphon
  8.  Управление Tor

  ── WARP ──────────────────────────────────────────────
  9.  Режим WARP (Global/Split/OFF)
  10. Добавить домен в WARP
  11. Удалить домен из WARP
  12. Редактировать список WARP (Nano)
  13. Проверить IP (реальный vs WARP)

  ── Безопасность ──────────────────────────────────────
  14. Включить BBR
  15. Включить Fail2Ban
  16. Включить Web-Jail
  17. Сменить порт SSH
  18. Управление UFW
  19. Переключить IPv6
  20. CPU Guard (приоритет)
  21. Блокировка рекламы

  ── Логи ──────────────────────────────────────────────
  22. Логи Xray (access)
  23. Логи Xray (error)
  24. Логи Nginx (access)
  25. Логи Nginx (error)
  26. Очистить все логи
  27. Режим приватности (отключить логи)

  ── Сервисы ───────────────────────────────────────────
  28. Перезапустить все сервисы
  29. Обновить Xray-core
  30. Диагностика
  31. Бэкап и восстановление
  32. Сменить язык
  33. Полное удаление

  ── Выход ─────────────────────────────────────────────
  0.  Выход
```

## VLESS + TLS + Vision (пункт 5)

Прямые подключения с потоком `xtls-rprx-vision`. Отдельный сервис `xray-vision`. Требует WS+TLS и активного Stream SNI.

**Как работает:**

```
Клиент → domain:443 → nginx stream (ssl_preread) → xray-vision:20xxx
                                                         ↓ fallback
                                               nginx-заглушка (общая с WS)
```

- Домен Vision должен иметь **прямую A-запись** — без CF-прокси (оранжевое облако должно быть серым)
- TLS-сертификат выпускается отдельно для домена Vision через acme.sh (CF DNS или standalone HTTP-01)
- Внутренний порт автовыбирается из свободных в диапазоне 20000–20999
- Все фичи маршрутизации (WARP, Relay, Psiphon, Tor, Adblock, Privacy) применяются к Vision автоматически

**Формат ссылки подключения:**
```
vless://UUID@dir.example.com:443?security=tls&flow=xtls-rprx-vision&type=tcp&sni=dir.example.com&fp=chrome
```

**Меню Vision (пункт 5):**

| Пункт | Действие |
|-------|----------|
| 1 | Установить Vision |
| 2 | Показать параметры подключения |
| 3 | Показать QR-код |
| 4 | Сменить UUID |
| 5 | Сменить домен (перевыпустит сертификат) |
| 6 | Удалить Vision |

## Stream SNI

Обслуживает WS, Reality и Vision на одном порту 443 через nginx `ssl_preread`. Nginx читает SNI до TLS handshake и маршрутизирует трафик на нужный backend.

Карта маршрутизации динамическая — хранится в `vwn.conf` как `STREAM_DOMAINS` и перегенерируется при добавлении/удалении доменов:

```nginx
stream {
    map $ssl_preread_server_name $upstream_backend {
        ws.example.com    127.0.0.1:7443;    # nginx → Xray WS
        dir.example.com   127.0.0.1:20001;   # Xray Vision
        default           127.0.0.1:10443;   # Xray Reality
    }
    server {
        listen 443;
        ssl_preread on;
        proxy_pass $upstream_backend;
    }
}
```

Требует `nginx-full` или `nginx-extras` (собранный с `--with-stream`). Установщик предлагает поставить автоматически.

## Блокировка рекламы (пункт 21)

Блокирует рекламу и трекеры для всех пользователей VPN без дополнительного ПО.

Использует `geosite:category-ads-all` — встроенную категорию в `geosite.dat` Xray, обновляемую вместе с Xray. Применяется к конфигам WS, Reality и Vision одновременно.

**Покрывает:** EasyList, EasyPrivacy, AdGuard Base List, Peter Lowe's List, региональные списки для CN, RU, JP, KR, IR, TR, UA, DE, FR и других.

## Режим приватности (пункт 27)

Исключает возможность отследить куда подключаются пользователи.

| Слой | Действие |
|------|----------|
| Xray `config.json` | `access: none`, `loglevel: none` |
| Xray `reality.json` | `access: none`, `loglevel: none` |
| Xray `vision.json` | `access: none`, `loglevel: none` |
| Nginx `xray.conf` | `access_log off` |
| systemd (xray, xray-reality, xray-vision) | `StandardOutput=null`, `StandardError=null` |
| `/var/log/xray` | Монтируется как **tmpfs** (RAM) — очищается при каждой перезагрузке |
| Существующие логи | Перезаписываются через `shred` перед очисткой |

## CPU Guard (пункт 20)

Устанавливает `CPUWeight=200` и `Nice=-10` для xray, xray-reality, xray-vision и nginx.  
Устанавливает `CPUWeight=20` для `user.slice` (SSH, фоновые процессы).

## Туннели (пункты 6–8)

Все туннели поддерживают режимы **Global / Split / OFF**. Применяются к конфигам WS, Reality и Vision одновременно.

### Relay (пункт 6)

Поддерживает: `vless://` `vmess://` `trojan://` `socks5://`

### Psiphon (пункт 7)

Выбор страны выхода: DE, NL, US, GB, FR, AT, CA, SE и др.  
Поддерживается режим WARP+Psiphon (цепочка туннелей).

### Tor (пункт 8)

Выбор страны выхода через `ExitNodes`. Поддержка мостов: obfs4, snowflake, meek-azure.  
**Рекомендуется Split режим** — Tor медленнее обычного интернета.

## WARP (пункты 9–13)

**Split** (домены по умолчанию): `openai.com, chatgpt.com, oaistatic.com, oaiusercontent.com, auth0.openai.com`

**Global** — весь трафик через WARP. **OFF** — отключён от роутинга. Применяется к конфигам WS, Reality и Vision.

## SSL-сертификаты

**Метод 1 — Cloudflare DNS API** (рекомендуется): порт 80 не нужен.  
**Метод 2 — Standalone**: временно открывает порт 80.

Автообновление через cron раз в 35 дней в 3:00.

Оба метода доступны для WS (пункт 3 → 5) и для Vision (пункт 5 → 1 или пункт 5 → 5).

## Диагностика (пункт 30)

| Раздел | Проверки |
|--------|----------|
| Система | RAM, диск, swap, часы |
| Xray | Конфиги, сервисы, порты |
| Vision | Конфиг, xray-vision, порт, SSL, DNS |
| Nginx | Конфиг, сервис, SSL, DNS |
| WARP | warp-svc, подключение, SOCKS5 |
| Туннели | Psiphon / Tor / Relay |
| Связность | Интернет, домен |

## Бэкап и восстановление (пункт 31)

Бэкапы в `/root/vwn-backups/` с датой и временем. Автоудаления нет.

Включает: конфиги Xray (WS, Reality, Vision), Nginx + SSL (в т.ч. сертификат Vision), API-ключи Cloudflare, cron, Fail2Ban, systemd-юнит xray-vision.

## Структура файлов

```
/usr/local/lib/vwn/
├── lang.sh       # Локализация (RU/EN)
├── core.sh       # Переменные, утилиты, статусы, vwn_conf_*, findFreePort
├── xray.sh       # Xray WS+TLS конфиг
├── nginx.sh      # Nginx, CDN, SSL, Stream SNI (динамический map), подписки
├── reality.sh    # VLESS+Reality
├── vision.sh     # VLESS+TLS+Vision
├── relay.sh      # Внешний outbound
├── psiphon.sh    # Psiphon туннель
├── tor.sh        # Tor туннель
├── security.sh   # UFW, BBR, Fail2Ban, SSH, IPv6, CPU Guard
├── logs.sh       # Логи, logrotate, cron
├── backup.sh     # Бэкап и восстановление
├── users.sh      # Управление пользователями + HTML подписки
├── diag.sh       # Диагностика (включая Vision)
├── privacy.sh    # Режим приватности (все Xray-сервисы)
├── adblock.sh    # Блокировка рекламы (все конфиги)
└── menu.sh       # Главное меню + точка входа --auto

/usr/local/etc/xray/
├── config.json              # Конфиг VLESS+WS
├── reality.json             # Конфиг VLESS+Reality
├── vision.json              # Конфиг VLESS+TLS+Vision
├── vwn.conf                 # Настройки VWN (язык, домен, STREAM_DOMAINS, vision_port…)
├── users.conf               # Список пользователей (UUID|метка|токен)
├── sub/
│   ├── label_token.txt      # base64 ссылки для клиентов
│   └── label_token.html     # Браузерная страница (QR + копирование)
├── warp_domains.txt
├── psiphon.json
├── psiphon_domains.txt
├── tor_domains.txt
├── relay.conf
└── relay_domains.txt

/etc/nginx/cert/
├── cert.pem / cert.key      # TLS-сертификат WS
└── vision.pem / vision.key  # TLS-сертификат Vision

/etc/systemd/system/
├── xray.service.d/
│   ├── cpuguard.conf
│   └── no-journal.conf
├── xray-reality.service.d/
│   ├── cpuguard.conf
│   └── no-journal.conf
├── xray-vision.service        # Systemd-юнит Vision
├── xray-vision.service.d/
│   └── no-journal.conf
├── nginx.service.d/
│   └── cpuguard.conf
├── user.slice.d/
│   └── cpuguard.conf
└── var-log-xray.mount

/root/vwn-backups/
└── vwn-backup-YYYY-MM-DD_HH-MM-SS.tar.gz
```

## Решение проблем

```bash
# Что-то не работает — запустить диагностику
vwn  # пункт 30

# WARP не подключается
systemctl restart warp-svc && sleep 5 && warp-cli connect

# Логи Psiphon
tail -50 /var/log/psiphon/psiphon.log

# Reality не запускается
xray -test -config /usr/local/etc/xray/reality.json

# Vision не запускается
xray -test -config /usr/local/etc/xray/vision.json
journalctl -u xray-vision -n 30 --no-pager

# Vision — проверить что порт слушается
ss -tlnp | grep 200

# Stream SNI — проверить карту маршрутизации
grep -A20 "map \$ssl_preread" /etc/nginx/nginx.conf

# Nginx после отключения IPv6
sed -i '/listen \[::\]:443/d' /etc/nginx/conf.d/xray.conf && nginx -t && systemctl reload nginx

# Tor — попробовать мосты (пункт 8 → 11)
tail -50 /var/log/tor/notices.log

# Подписка не обновляется
vwn  # пункт 2 → пункт 5 (Пересоздать файлы подписки)

# Блокировка рекламы — включить/выключить
vwn  # пункт 21

# Режим приватности — проверить статус
vwn  # пункт 27 → пункт 4 (Показать статус)

# CPU Guard — проверить приоритеты
systemctl show xray.service -p CPUWeight
```

## Удаление

```bash
vwn  # Пункт 33
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
