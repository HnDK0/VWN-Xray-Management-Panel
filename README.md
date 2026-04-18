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

Quick commands:
```bash
vwn status     # Full diagnostics
vwn backup     # Create backup
vwn restore    # Restore from backup
vwn qr         # Show subscription QR
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

### Full stack (all security features + Psiphon + SSH port change)
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/HnDK0/VLESS-WebSocket-TLS-Nginx-WARP/main/install.sh) \
  --auto \
  --domain vpn.example.com \
  --ssh-port 22222 \
  --cpu-guard --ipv6 --fail2ban --jail --adblock --privacy \
  --psiphon --psiphon-country DE \
  --reality --bbr
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
| `--ssh-port PORT` | — | Change SSH port (1–65535). Applied **before** Fail2Ban |
| `--stream` | off | Activate Stream SNI — serve WS + Reality on port 443 via SNI multiplexing |
| `--vision` | off | Install VLESS+TLS+Vision (requires WS+TLS + Stream SNI) |
| `--vision-domain DOMAIN` | — | Direct domain for Vision. **Required** with `--vision`. No Cloudflare proxy! |
| `--vision-cert-method cf\|standalone` | `standalone` | SSL method for the Vision domain |
| `--ipv6` | off | Enable IPv6 system-wide |
| `--cpu-guard` | off | Enable CPU Guard (priority for xray/nginx) |
| `--bbr` | off | Enable BBR TCP congestion control |
| `--fail2ban` | off | Install Fail2Ban |
| `--jail` | off | Enable WebJail (nginx-probe, requires `--fail2ban`) |
| `--adblock` | off | Enable Adblock (geosite:category-ads-all) |
| `--privacy` | off | Enable Privacy Mode (no traffic logs) |
| `--psiphon` | off | Install Psiphon proxy |
| `--psiphon-country CODE` | `DE` | Psiphon exit country (DE, NL, US, GB, FR, AT, CA, SE) |
| `--psiphon-warp` | off | Route Psiphon through WARP (requires WARP) |
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

- ✅ **VLESS + WebSocket + TLS** — connections via Cloudflare CDN (port 443)
- ✅ **VLESS + Reality** — direct connections without CDN (router, Clash), installed together with WS or standalone
- ✅ **VLESS + TLS + Vision** — direct connections with `xtls-rprx-vision` flow, own TLS cert, fallback to nginx stub
- ✅ **Stream SNI** — serve WS, Reality, and Vision all on port 443 via SNI multiplexing, no extra ports exposed
- ✅ **Nginx mainline** — reverse proxy with a stub/decoy site, auto-installs from nginx.org (>= 1.19)
- ✅ **Cloudflare WARP** — route selected domains or all traffic (applied to all configs: WS, Reality, Vision)
- ✅ **Psiphon** — censorship bypass with exit country selection, supports plain and WARP+Psiphon chained mode
- ✅ **Tor** — censorship bypass with exit country selection, bridge support (obfs4, snowflake, meek-azure), circuit renewal
- ✅ **Relay** — external outbound (VLESS/VMess/Trojan/SOCKS5 via link)
- ✅ **CF Guard** — blocks direct access, only Cloudflare IPs allowed
- ✅ **Multi-user** — multiple UUIDs with labels, individual QR codes and subscription URLs
- ✅ **Subscription pages** — per-user `.txt` (clients), `.html` (browser with QR + copy buttons + Clash YAML + "Copy all" for multiple VLESS links)
- ✅ **Subscription auth** — `/sub/` pages protected by HTTP basic auth
- ✅ **CPU Guard** — prioritises xray/nginx over background processes, prevents host throttling
- ✅ **Privacy Mode** — Xray access logs off, Nginx access_log off, journald suppressed for all Xray services, `/var/log/xray` on tmpfs (RAM), existing logs shredded
- ✅ **Adblock** — blocks ads and trackers via built-in `geosite:category-ads-all` (EasyList, EasyPrivacy, AdGuard, regional lists); applied to all configs
- ✅ **Backup & Restore** — manual backup/restore/delete of all configs including Vision
- ✅ **Diagnostics** — full system check with per-component breakdown including Vision
- ✅ **Fail2Ban + Web-Jail** — brute-force and scanner protection
- ✅ **BBR** — TCP acceleration
- ✅ **Anti-Ping** — ICMP disabled
- ✅ **IPv6 toggle** — enable/disable system-wide IPv6
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
vwn status           # Run full diagnostics
vwn backup           # Create backup
vwn restore          # Restore from backup
vwn qr               # Show subscription QR code
vwn open-80          # Open port 80 (for ACME)
vwn close-80         # Close port 80 (after ACME)
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
  6.  Manage WARP
  7.  Manage Relay (external)
  8.  Manage Psiphon
  9.  Manage Tor

  ── Security ───────────────────────────────────────────
  10. Enable BBR
  11. Enable Fail2Ban
  12. Enable Web-Jail
  13. Change SSH port
  14. Manage UFW
  15. Toggle IPv6
  16. CPU Guard (priority)
  17. Adblock (block ads)

  ── Logs ───────────────────────────────────────────────
  18. Xray logs (access)
  19. Xray logs (error)
  20. Nginx logs (access)
  21. Nginx logs (error)
  22. Clear all logs
  23. Privacy mode (disable logging)

  ── Services ───────────────────────────────────────────
  24. Restart all services
  25. Update Xray-core
  26. Rebuild all configs
  27. Diagnostics
  28. Backup & Restore
  29. Change language
  30. Full removal
  31. Manage Stream SNI

  ── Exit ───────────────────────────────────────────────
  0.  Exit
```

### Status indicators

| Status | Meaning |
|--------|---------|
| `ACTIVE \| Global` | All traffic routed through tunnel |
| `ACTIVE \| Split` | Only domains from the list routed through tunnel |
| `route OFF` | Service running but not in routing |
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
https://your-domain.com/sub/label_token.html  ← browser page with QR codes + copy buttons + Clash YAML
```

The `.txt` file is base64-encoded and contains all connection links (WS+TLS, Reality, and Vision if installed).
The `.html` page shows each link with a **copy button** and a **QR code on click**, plus a **Clash Meta / Mihomo YAML** block.  
If there is more than one VLESS link, an extra **Copy all** button is shown.

Subscription pages can be protected with HTTP basic auth (WS menu → item 12).

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
| 13 | Rebuild WS configs |
| 14 | Install (choose WS or Reality) |
| 15 | Remove WS |

## VLESS + Reality (item 4)

Direct connections without CDN, hidden behind a real website (Reality protocol).

| Item | Action |
|------|--------|
| 1 | Install Reality |
| 2 | Show QR code |
| 3 | Show connection info |
| 4 | Change UUID |
| 5 | Change port |
| 6 | Change destination site |
| 7 | Restart xray-reality |
| 8 | Show logs |
| 9 | Remove Reality |
| 10 | Rebuild Reality configs |

Reality mask sites: `microsoft.com:443`, `www.apple.com:443`, `www.amazon.com:443`, or custom.

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
- Fallback traffic is served by a dedicated nginx server block with the Vision TLS cert
- All routing features (WARP, Relay, Psiphon, Tor, Adblock, Privacy) apply to Vision automatically

**Connection link format:**
```
vless://UUID@dir.example.com:443?security=tls&flow=xtls-rprx-vision&type=tcp&sni=dir.example.com&fp=chrome&allowInsecure=0
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
| 7 | Rebuild Vision configs |

## Stream SNI (item 31)

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

Before enabling Stream SNI, the script runs 7 preliminary checks: nginx installed/running, WS/Reality configs exist, SSL cert present, stream module available, ports free.

## Adblock (item 17)

Blocks ads and trackers for all users of the VPN without any additional software.

Uses `geosite:category-ads-all` — a built-in category in Xray's `geosite.dat`, updated automatically with every `vwn update`. Applied to WS, Reality, and Vision configs simultaneously.

**Covered lists:** EasyList, EasyPrivacy, AdGuard Base List, Peter Lowe's List, and regional ad lists for CN, RU, JP, KR, IR, TR, UA, DE, FR and others.

## Privacy Mode (item 23)

Prevents anyone with server access from seeing where users connect.

| Layer | Action |
|-------|--------|
| Xray `config.json` | `access: none`, `loglevel: none` |
| Xray `reality.json` | `access: none`, `loglevel: none` |
| Xray `vision.json` | `access: none`, `loglevel: none` |
| Nginx `xray.conf` | `access_log off` |
| systemd (xray, xray-reality, xray-vision) | `StandardOutput=null`, `StandardError=null` |
| `/var/log/xray` | Mounted as **tmpfs** (RAM) — wiped on every reboot |
| Existing logs | Overwritten with `shred` before clearing (with ext4 journal warning) |

## CPU Guard (item 16)

Sets `CPUWeight=200` and `Nice=-10` for xray, xray-reality, xray-vision, and nginx.
Sets `CPUWeight=20` for `user.slice` (SSH sessions, background scripts).

## 🛡️ DNS Leak Prevention

If a DNS test shows your server's DNS, it means the client (phone/PC) is not resolving domains locally.

**What to do:**
In your application's DNS settings, change **Domain Strategy** to `UseIP`, `IPv4_only`, or `IPIfNonMatch`.

**Important:**
After changing this setting, make sure the application has working DNS servers configured.
This forces the client to send a ready-made IP to the server, completely hiding the system DNS servers.

## Tunnels (items 6–9)

All tunnels support **Global / Split / OFF** modes. Applied to WS, Reality, and Vision configs simultaneously.

### Relay (item 6)

Supported: `vless://` `vmess://` `trojan://` `socks5://`

- Configure by pasting the connection link
- Global mode — all traffic through relay
- Split mode — only domains from the list
- IP check through relay (temporary xray instance for non-SOCKS protocols)

### Psiphon (item 7)

- Exit country selection: DE, NL, US, GB, FR, AT, CA, SE, CH, FI
- Optional WARP+Psiphon chained mode (Psiphon through WARP SOCKS5)
- Tunnel mode switch: plain ↔ warp
- IP check through Psiphon SOCKS5

### Tor (item 8)

- Exit country via `ExitNodes`: DE, NL, US, GB, FR, SE, CH, FI
- Bridge support: obfs4, snowflake, meek-azure
- Circuit renewal via `SIGNAL NEWNYM`
- Auto-upgrade to official torproject.org repository (0.4.8+)
- **Recommended: Split mode** — Tor is slower than direct internet

## WARP (item 6)

**Split** (default domains): `openai.com, chatgpt.com, oaistatic.com, oaiusercontent.com, auth0.openai.com`

**Global** — all traffic via WARP. **OFF** — removed from routing. Applied to WS, Reality, and Vision configs.

WARP auto-connects with retry logic (up to 3 attempts). Compatible with both old (`--accept-tos`) and new warp-cli versions.

## SSL Certificates

**Method 1 — Cloudflare DNS API** (recommended): port 80 not needed.
**Method 2 — Standalone**: temporarily opens port 80.

Auto-renewal via cron every 35 days at 03:00 (with pre/post hooks for opening/closing port 80).

Both methods are available for WS SSL (item 3 → 5) and Vision SSL (item 5 → 1 or item 5 → 5).

## Diagnostics (item 27)

| Section | Checks |
|---------|--------|
| System | RAM, disk, swap, clock sync |
| Xray | Config validity, service status, ports |
| Vision | Config validity, xray-vision service, port, SSL, DNS |
| Nginx | Config, service, port 443, SSL expiry, DNS |
| WARP | warp-svc, connection, SOCKS5 response |
| Tunnels | Psiphon / Tor / Relay status |
| Connectivity | Internet, domain reachability |

Each section runs independently and reports OK/FAIL with detailed output.

## Backup & Restore (item 28)

Backups stored in `/root/vwn-backups/` with timestamps. No auto-deletion.

Includes: Xray configs (WS, Reality, Vision), Nginx + SSL certs (including Vision certs), Cloudflare API key, cron tasks, Fail2Ban rules, xray-vision systemd service, sysctl settings.

Backup management: create, list, restore, delete.

## File Structure

```
/usr/local/lib/vwn/
├── lang.sh       # Localisation (RU/EN)
├── core.sh       # Variables, utilities, status, vwn_conf_*, findFreePort, rebuildAllConfigs
├── xray.sh       # Xray WS+TLS config, QR, URL generation
├── nginx.sh      # Nginx, CDN, SSL, Stream SNI (dynamic map), subscriptions, basic auth
├── reality.sh    # VLESS+Reality
├── vision.sh     # VLESS+TLS+Vision
├── warp.sh       # Cloudflare WARP install, registration, domains
├── relay.sh      # External outbound (VLESS/VMess/Trojan/SOCKS5)
├── psiphon.sh    # Psiphon tunnel
├── tor.sh        # Tor tunnel + bridges
├── security.sh   # UFW, BBR, Fail2Ban, SSH, IPv6, CPU Guard
├── logs.sh       # Logs, logrotate, cron (SSL + log clear)
├── backup.sh     # Backup & Restore
├── users.sh      # Multi-user management + HTML/TXT subscription pages + Clash YAML
├── diag.sh       # Diagnostics (incl. Vision)
├── privacy.sh    # Privacy mode (all Xray services)
├── adblock.sh    # Adblock (all configs)
└── menu.sh       # Main menu + install + removal

/usr/local/etc/xray/
├── config.json              # VLESS+WS config
├── reality.json             # VLESS+Reality config
├── vision.json              # VLESS+TLS+Vision config
├── vwn.conf                 # VWN settings (lang, domain, STREAM_DOMAINS, vision_port…)
├── users.conf               # User list (UUID|label|token)
├── connect_host             # CDN connect address (override default domain)
├── sub/
│   ├── label_token.txt      # base64 links for clients
│   └── label_token.html     # Browser page (QR + copy + Clash YAML)
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

> **Ping won't show VLESS issues.** Ping is ICMP, VLESS runs over TCP/HTTPS. ICMP may be blocked (Anti-Ping) while VLESS works fine. Test connectivity through your client (v2rayNG, Hiddify, Nekoray).

### 🔴 Connection timeouts (most common issue)

**Symptom:** client hangs on "Connecting...", then timeout. You run `journalctl -f -u xray` — **empty, nothing shows up**.

**Reason:** the request may **never reach Xray**. Connection chain:

```
Client → Cloudflare → Nginx (port 443) → Xray WS (port 16500) → outbound
Client → IP:8443 → Xray Reality → outbound
Client → domain:443 → Stream SNI → Xray Vision → outbound
```

If the break is at the first link — Xray logs will be empty. You need to look **at the link where the break happens**.

---

#### Step 1. Find where the break is (30 seconds)

```bash
# Monitor ALL logs at once:
tail -f /var/log/nginx/access.log /var/log/nginx/error.log /var/log/xray/access.log /var/log/xray/error.log 2>/dev/null

# In ONE window journalctl (all services):
journalctl -f -u xray -u xray-reality -u xray-vision -u nginx --no-pager
```

Now **try connecting from your client** to VLESS. Watch where a record appears:

| Where the record appears | Where the break | What to do |
|---------------------|-----------|------------|
| **Nginx access.log** — record exists, Xray logs empty | Between Nginx and Xray | Nginx not proxying to Xray. Check `proxy_pass` in `/etc/nginx/conf.d/xray.conf` |
| **Nginx access.log** — NO record | Before Nginx (network/CF Guard) | See Step 2 below |
| **Nginx error.log** — error exists | Nginx can't handle | Read the error in error.log |
| **Xray access.log** — `accepted` record | Everything works, outbound issue | See Step 3 |
| **Xray error.log** — error exists | Xray accepted but can't process | Read the error |
| **Everywhere empty** | Request not reaching server | See Step 2 |

---

#### Step 2. Request not reaching the server

```bash
# Check 1: domain resolves?
dig +short your-domain.com

# Check 2: port 443 accessible from outside?
curl -vI https://your-domain.com/  # from EXTERNAL IP (not from server!)

# Check 3: CF Guard blocking?
# If Nginx access.log has no records — CF Guard may have blocked before Xray
# Check:
grep -A5 "CF Guard" /etc/nginx/conf.d/xray.conf
# If CF Guard ON — add your IP to whitelist: vwn → 3 → 7

# Check 4: Nginx running at all?
nginx -t && systemctl status nginx

# Check 5: port 443 listening?
ss -tlnp | grep :443
```

---

#### Step 3. Request reached Xray but connection fails

```bash
# Enable DEBUG logs (disabled by default):
for f in /usr/local/etc/xray/*.json; do
    sed -i 's/"loglevel": ".*"/"loglevel": "debug"/' "$f"
    sed -i 's/"access": ".*"/"access": "\/var\/log\/xray\/access.log"/' "$f"
done

# Remove systemd stub (no-journal) so journalctl works:
for svc in xray xray-reality xray-vision; do
    rm -f /etc/systemd/system/${svc}.service.d/no-journal.conf 2>/dev/null
done

systemctl daemon-reload
systemctl restart xray xray-reality xray-vision

# Now watch logs:
journalctl -f -u xray -u xray-reality -u xray-vision --no-pager

# Typical errors in logs:
# "invalid user ID"         → wrong UUID in client
# "failed to validate host" → WS path mismatch
# "tls: bad certificate"    → SSL cert doesn't match domain
# "failed to listen"        → Xray didn't start on port
# "outbound tag not found"  → routing config broken

# After debugging — disable logs back:
vwn → item 26 (Rebuild all configs)
```

---

#### Step 4. Quick problem table

| Symptom | Where to look | Command | Fix |
|---------|-------------|---------|-----|
| **Timeout WS, all logs empty** | Before Nginx | `curl -vI https://your-domain.com/` | Check DNS, CF Guard, firewall |
| **Timeout WS, Nginx access.log has record** | Nginx → Xray | `grep proxy_pass /etc/nginx/conf.d/xray.conf` | Check proxy_pass points to correct Xray port |
| **Timeout WS, Nginx error.log has record** | Nginx error | `tail -20 /var/log/nginx/error.log` | Read the error |
| **Timeout Reality, logs empty** | Before Xray Reality | `ss -tlnp \| grep 8443` | Port not listening → `systemctl restart xray-reality` |
| **Timeout Reality, Xray error.log has record** | Xray error | `journalctl -f -u xray-reality` | Read the error |
| **Timeout Vision, logs empty** | Before Xray Vision | `ss -tlnp \| grep 200` | Port not listening → `systemctl restart xray-vision` |
| **Connection works, no internet** | Outbound | `grep -A5 "outbounds" /usr/local/etc/xray/*.json` | outbound down (WARP/Psiphon/Tor crashed) |
| **All timeouts** | Xray config | `xray -test -config /usr/local/etc/xray/config.json` | Config broken → vwn → 30 |

---

### 🚀 Automatic diagnostics

```bash
# Full diagnostics of all components
vwn status

# Update modules before diagnostics
vwn update
```

## Removal

```bash
vwn  # item 34
```

Backups in `/root/vwn-backups/` are not removed automatically.

## Dependencies

- [Xray-core](https://github.com/XTLS/Xray-core)
- [Cloudflare WARP](https://1.1.1.1/)
- [Psiphon tunnel core](https://github.com/Psiphon-Labs/psiphon-tunnel-core-binaries)
- [acme.sh](https://github.com/acmesh-official/acme.sh)
- nginx (mainline from nginx.org), jq, ufw, tor, obfs4proxy, qrencode

## Version

Current: **3.1**

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

Быстрые команды:
```bash
vwn status     # Полная диагностика
vwn backup     # Создать бэкап
vwn restore    # Восстановить из бэкапа
vwn qr         # Показать QR-код подписки
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

### Полный стек (все функции безопасности + Psiphon + смена порта SSH)
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/HnDK0/VLESS-WebSocket-TLS-Nginx-WARP/main/install.sh) \
  --auto \
  --domain vpn.example.com \
  --ssh-port 22222 \
  --cpu-guard --ipv6 --fail2ban --jail --adblock --privacy \
  --psiphon --psiphon-country DE \
  --reality --bbr
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
| `--ssh-port PORT` | — | Сменить порт SSH (1–65535). Применяется **до** Fail2Ban |
| `--stream` | выкл. | Активировать Stream SNI — WS + Reality на порту 443 |
| `--vision` | выкл. | Установить VLESS+TLS+Vision (требует WS+TLS + Stream SNI) |
| `--vision-domain DOMAIN` | — | Прямой домен для Vision. **Обязателен** с `--vision`. Без CF-прокси! |
| `--vision-cert-method cf\|standalone` | `standalone` | Метод SSL для домена Vision |
| `--ipv6` | выкл. | Включить IPv6 |
| `--cpu-guard` | выкл. | Включить CPU Guard (приоритет xray/nginx) |
| `--bbr` | выкл. | Включить BBR TCP |
| `--fail2ban` | выкл. | Установить Fail2Ban |
| `--jail` | выкл. | Включить WebJail (требует `--fail2ban`) |
| `--adblock` | выкл. | Включить блокировку рекламы |
| `--privacy` | выкл. | Включить режим приватности (без логов трафика) |
| `--psiphon` | выкл. | Установить Psiphon |
| `--psiphon-country CODE` | `DE` | Страна выхода Psiphon (DE, NL, US, GB, FR, AT, CA, SE) |
| `--psiphon-warp` | выкл. | Направить Psiphon через WARP (требует WARP) |
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

- ✅ **VLESS + WebSocket + TLS** — подключения через Cloudflare CDN (порт 443)
- ✅ **VLESS + Reality** — прямые подключения без CDN (роутер, Clash), устанавливается вместе с WS или отдельно
- ✅ **VLESS + TLS + Vision** — прямые подключения с `xtls-rprx-vision`, собственный TLS-сертификат, fallback на nginx-заглушку
- ✅ **Stream SNI** — WS, Reality и Vision на одном порту 443 через SNI-мультиплексирование
- ✅ **Nginx mainline** — реверс-прокси с сайтом-заглушкой, автоустановка с nginx.org (>= 1.19)
- ✅ **Cloudflare WARP** — маршрутизация по доменам или весь трафик (применяется ко всем конфигам)
- ✅ **Psiphon** — обход блокировок с выбором страны выхода, режимы plain и WARP+Psiphon
- ✅ **Tor** — обход блокировок с выбором страны выхода, поддержка мостов (obfs4, snowflake, meek), обновление цепи
- ✅ **Relay** — внешний outbound (VLESS/VMess/Trojan/SOCKS5 по ссылке)
- ✅ **CF Guard** — блокировка прямого доступа, только IP Cloudflare
- ✅ **Мультипользователь** — несколько UUID с метками, индивидуальные QR и подписки
- ✅ **Подписки** — `.txt` (клиенты), `.html` (браузер с QR + кнопки копирования + Clash YAML + кнопка «Скопировать все» при нескольких VLESS)
- ✅ **Auth подписок** — страницы `/sub/` защищены HTTP basic auth
- ✅ **CPU Guard** — приоритет xray/nginx над фоновыми процессами
- ✅ **Режим приватности** — логи Xray отключены, journald заглушён, `/var/log/xray` на tmpfs (RAM), логи уничтожены через shred
- ✅ **Блокировка рекламы** — через `geosite:category-ads-all`, применяется ко всем конфигам
- ✅ **Бэкап и восстановление** — ручной бэкап/восстановление/удаление всех конфигов включая Vision
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

## Команды CLI

```bash
vwn                  # Открыть интерактивное меню
vwn update           # Обновить модули (без изменения конфигов)
vwn status           # Запустить полную диагностику
vwn backup           # Создать бэкап
vwn restore          # Восстановить из бэкапа
vwn qr               # Показать QR-код подписки
vwn open-80          # Открыть порт 80 (для ACME)
vwn close-80         # Закрыть порт 80 (после ACME)
```

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
  6.  Управление WARP
  7.  Управление Relay (внешний)
  8.  Управление Psiphon
  9.  Управление Tor

  ── Безопасность ─────────────────────────────────────────
  10. Включить BBR
  11. Включить Fail2Ban
  12. Включить Web-Jail
  13. Сменить порт SSH
  14. Управление UFW
  15. Переключить IPv6
  16. CPU Guard (приоритет)
  17. Блокировка рекламы

  ── Логи ────────────────────────────────────────────────
  18. Логи Xray (access)
  19. Логи Xray (error)
  20. Логи Nginx (access)
  21. Логи Nginx (error)
  22. Очистить все логи
  23. Режим приватности (отключить логи)

  ── Сервисы ──────────────────────────────────────────────
  24. Перезапустить все сервисы
  25. Обновить Xray-core
  26. Пересоздать все конфиги
  27. Диагностика
  28. Бэкап и восстановление
  29. Сменить язык
  30. Полное удаление
  31. Управление Stream SNI

  ── Выход ─────────────────────────────────────────────
  0.  Выход
```

## Индикаторы статусов

| Статус | Значение |
|--------|----------|
| `ACTIVE \| Global` | Весь трафик идёт через туннель |
| `ACTIVE \| Split` | Только домены из списка идут через туннель |
| `route OFF` | Сервис запущен, но не в маршрутизации |
| `OFF` | Сервис не запущен |
| `CPU Guard: ON` | xray/nginx имеют приоритет над фоновыми процессами |
| `Adblock: ON` | Реклама и трекеры заблокированы |
| `Privacy: ON` | Логирование отключено, логи в RAM |

## Мультипользователь (пункт 2)

Несколько UUID VLESS с метками (например «iPhone Васи», «Ноутбук работа»).

- Добавление / Удаление / Переименование пользователей
- Изменения применяются мгновенно к конфигам WS, Reality и Vision
- Индивидуальный QR-код для каждого
- Индивидуальный URL подписки для каждого
- Нельзя удалить последнего пользователя
- Пользователи хранятся в `/usr/local/etc/xray/users.conf` (формат: `UUID|метка|токен`)

При первом открытии существующий UUID автоматически импортируется как пользователь `default`.

## URL подписки

Каждый пользователь получает две персональные страницы:

```
https://your-domain.com/sub/label_token.txt   ← клиенты (v2rayNG, Hiddify, Nekoray…)
https://your-domain.com/sub/label_token.html  ← браузер с QR-кодами + кнопки копирования + Clash YAML
```

Файл `.txt` закодирован в base64 и содержит все ссылки подключения (WS+TLS, Reality и Vision если установлен).
Страница `.html` показывает каждую ссылку с **кнопкой копирования** и **QR-кодом по клику**, плюс **Clash Meta / Mihomo YAML** блок.  
Если VLESS-ссылок больше одной, дополнительно показывается кнопка **«Скопировать все»**.

Страницы подписок можно защитить HTTP basic auth (меню WS → пункт 12).

## Управление WS + CDN (пункт 3)

| Пункт | Действие |
|-------|----------|
| 1 | Сменить порт Xray |
| 2 | Сменить путь WS |
| 3 | Сменить домен |
| 4 | Адрес подключения (CDN-домен) |
| 5 | Перевыпустить SSL-сертификат |
| 6 | Сменить сайт-заглушку |
| 7 | CF Guard — доступ только через Cloudflare |
| 8 | Обновить IP Cloudflare |
| 9 | Управление автообновлением SSL |
| 10 | Управление автоочисткой логов |
| 11 | Сменить UUID |
| 12 | Auth подписок (basic auth) |
| 13 | Пересоздать конфиги WS |
| 14 | Установить (выбор WS или Reality) |
| 15 | Удалить WS |

## VLESS + Reality (пункт 4)

Прямые подключения без CDN, скрытые за реальным сайтом (протокол Reality).

| Пункт | Действие |
|-------|----------|
| 1 | Установить Reality |
| 2 | Показать QR-код |
| 3 | Показать параметры подключения |
| 4 | Сменить UUID |
| 5 | Сменить порт |
| 6 | Сменить сайт-маску |
| 7 | Перезапустить xray-reality |
| 8 | Показать логи |
| 9 | Удалить Reality |
| 10 | Пересоздать конфиги Reality |

Сайты-маски Reality: `microsoft.com:443`, `www.apple.com:443`, `www.amazon.com:443`, или произвольный.

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
- Fallback-трафик обрабатывается выделенным серверным блоком nginx с TLS-сертификатом Vision
- Все функции маршрутизации (WARP, Relay, Psiphon, Tor, Adblock, Privacy) применяются к Vision автоматически

**Формат ссылки подключения:**
```
vless://UUID@dir.example.com:443?security=tls&flow=xtls-rprx-vision&type=tcp&sni=dir.example.com&fp=chrome&allowInsecure=0
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
| 7 | Пересоздать конфиги Vision |

## Stream SNI (пункт 31)

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

Перед включением Stream SNI скрипт проводит 7 предварительных проверок: nginx установлен/запущен, есть конфиги WS/Reality, SSL-сертификат, модуль stream, порты свободны.

## Блокировка рекламы (пункт 17)

Блокирует рекламу и трекеры для всех пользователей VPN без дополнительного ПО.

Использует `geosite:category-ads-all` — встроенную категорию в `geosite.dat` Xray, обновляемую вместе с Xray. Применяется к конфигам WS, Reality и Vision одновременно.

**Покрывает:** EasyList, EasyPrivacy, AdGuard Base List, Peter Lowe's List, региональные списки для CN, RU, JP, KR, IR, TR, UA, DE, FR и других.

## Режим приватности (пункт 23)

Исключает возможность отследить куда подключаются пользователи.

| Слой | Действие |
|------|----------|
| Xray `config.json` | `access: none`, `loglevel: none` |
| Xray `reality.json` | `access: none`, `loglevel: none` |
| Xray `vision.json` | `access: none`, `loglevel: none` |
| Nginx `xray.conf` | `access_log off` |
| systemd (xray, xray-reality, xray-vision) | `StandardOutput=null`, `StandardError=null` |
| `/var/log/xray` | Монтируется как **tmpfs** (RAM) — очищается при каждой перезагрузке |
| Существующие логи | Перезаписываются через `shred` перед очисткой (с предупреждением для ext4) |

## CPU Guard (пункт 16)

Устанавливает `CPUWeight=200` и `Nice=-10` для xray, xray-reality, xray-vision и nginx.
Устанавливает `CPUWeight=20` для `user.slice` (SSH, фоновые процессы).

## 🛡️ Устранение утечки DNS

Если тест показывает DNS вашего сервера, значит клиент (телефон/ПК) не резолвит домены сам.

**Что сделать:**
В настройках DNS вашего приложения измените **Доменную стратегию** на `UseIP`, `IPv4_only` или `IPIfNonMatch`.

**Важно:**
После смены настройки убедитесь, что в приложении прописаны рабочие DNS.
Это заставит клиент присылать на сервер готовый IP, полностью скрывая системные DNS сервера.

## Туннели (пункты 6–9)

Все туннели поддерживают режимы **Global / Split / OFF**. Применяются к конфигам WS, Reality и Vision одновременно.

### Relay (пункт 6)

Поддерживает: `vless://` `vmess://` `trojan://` `socks5://`

- Настройка через вставку ссылки подключения
- Global — весь трафик через relay
- Split — только домены из списка
- Проверка IP через relay (временный xray для не-SOCKS протоколов)

### Psiphon (пункт 7)

- Выбор страны выхода: DE, NL, US, GB, FR, AT, CA, SE, CH, FI
- Режим WARP+Psiphon (цепочка туннелей — Psiphon через WARP SOCKS5)
- Переключение режима туннеля: plain ↔ warp
- Проверка IP через Psiphon SOCKS5

### Tor (пункт 8)

- Выбор страны выхода через `ExitNodes`: DE, NL, US, GB, FR, SE, CH, FI
- Поддержка мостов: obfs4, snowflake, meek-azure
- Обновление цепи через `SIGNAL NEWNYM`
- Автообновление до официального репозитория torproject.org (0.4.8+)
- **Рекомендуется Split режим** — Tor медленнее обычного интернета

## WARP (пункт 6)

**Split** (домены по умолчанию): `openai.com, chatgpt.com, oaistatic.com, oaiusercontent.com, auth0.openai.com`

**Global** — весь трафик через WARP. **OFF** — отключён от роутинга. Применяется к конфигам WS, Reality и Vision.

WARP автоматически переподключается с логикой повтора (до 3 попыток). Совместим со старыми (`--accept-tos`) и новыми версиями warp-cli.

## SSL-сертификаты

**Метод 1 — Cloudflare DNS API** (рекомендуется): порт 80 не нужен.
**Метод 2 — Standalone**: временно открывает порт 80.

Автообновление через cron раз в 35 дней в 3:00 (с pre/post hook для открытия/закрытия порта 80).

Оба метода доступны для WS (пункт 3 → 5) и для Vision (пункт 5 → 1 или пункт 5 → 5).

## Диагностика (пункт 27)

| Раздел | Проверки |
|--------|----------|
| Система | RAM, диск, swap, синхронизация времени |
| Xray | Конфиги, сервисы, порты |
| Vision | Конфиг, xray-vision, порт, SSL, DNS |
| Nginx | Конфиг, сервис, порт 443, SSL, DNS |
| WARP | warp-svc, подключение, SOCKS5 |
| Туннели | Psiphon / Tor / Relay |
| Связность | Интернет, доступность домена |

Каждый раздел проверяется независимо и выводит OK/FAIL с подробным описанием.

## Бэкап и восстановление (пункт 28)

Бэкапы в `/root/vwn-backups/` с датой и временем. Автоудаления нет.

Включает: конфиги Xray (WS, Reality, Vision), Nginx + SSL (в т.ч. сертификат Vision), API-ключи Cloudflare, cron, Fail2Ban, systemd-юнит xray-vision, настройки sysctl.

Управление бэкапами: создание, просмотр, восстановление, удаление.

## Структура файлов

```
/usr/local/lib/vwn/
├── lang.sh       # Локализация (RU/EN)
├── core.sh       # Переменные, утилиты, статусы, vwn_conf_*, findFreePort, rebuildAllConfigs
├── xray.sh       # Xray WS+TLS конфиг, QR, генерация URL
├── nginx.sh      # Nginx, CDN, SSL, Stream SNI (динамический map), подписки, basic auth
├── reality.sh    # VLESS+Reality
├── vision.sh     # VLESS+TLS+Vision
├── warp.sh       # Cloudflare WARP: установка, регистрация, домены
├── relay.sh      # Внешний outbound (VLESS/VMess/Trojan/SOCKS5)
├── psiphon.sh    # Psiphon туннель
├── tor.sh        # Tor туннель + мосты
├── security.sh   # UFW, BBR, Fail2Ban, SSH, IPv6, CPU Guard
├── logs.sh       # Логи, logrotate, cron (SSL + очистка логов)
├── backup.sh     # Бэкап и восстановление
├── users.sh      # Управление пользователями + HTML/TXT подписки + Clash YAML
├── diag.sh       # Диагностика (включая Vision)
├── privacy.sh    # Режим приватности (все Xray-сервисы)
├── adblock.sh    # Блокировка рекламы (все конфиги)
└── menu.sh       # Главное меню + установка + удаление

/usr/local/etc/xray/
├── config.json              # Конфиг VLESS+WS
├── reality.json             # Конфиг VLESS+Reality
├── vision.json              # Конфиг VLESS+TLS+Vision
├── vwn.conf                 # Настройки VWN (язык, домен, STREAM_DOMAINS, vision_port…)
├── users.conf               # Список пользователей (UUID|метка|токен)
├── connect_host             # Адрес подключения (переопределение основного домена)
├── sub/
│   ├── label_token.txt      # base64 ссылки для клиентов
│   └── label_token.html     # Браузерная страница (QR + копирование + Clash YAML)
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

> **Ping не покажет проблему с VLESS.** Ping — это ICMP, VLESS идёт через TCP/HTTPS. ICMP может быть заблокирован (Anti-Ping), а VLESS при этом работать. Проверяй подключение через клиент (v2rayNG, Hiddify, Nekoray).

### 🔴 Таймауты подключений (самая частая проблема)

**Симптом:** клиент зависает на "Connecting...", потом timeout. Запускаешь `journalctl -f -u xray` — **пусто, ничего не пишет**.

**Причина:** запрос может **не доходить до Xray**. Цепочка подключения:

```
Клиент → Cloudflare → Nginx (порт 443) → Xray WS (порт 16500) → outbound
Клиент → IP:8443 → Xray Reality → outbound
Клиент → domain:443 → Stream SNI → Xray Vision → outbound
```

Если обрыв на первом звене — в логах Xray будет пусто. Нужно смотреть **на том звене где обрыв**.

---

#### Шаг 1. Определи где обрыв (30 секунд)

```bash
# Запусти МОНИТОР ВСЕХ логов сразу:
tail -f /var/log/nginx/access.log /var/log/nginx/error.log /var/log/xray/access.log /var/log/xray/error.log 2>/dev/null

# В ОДНОМ окне journalctl (все сервисы):
journalctl -f -u xray -u xray-reality -u xray-vision -u nginx --no-pager
```

Теперь **с клиента попробуй подключиться** к VLESS. Смотри где появилась запись:

| Где появилась запись | Где обрыв | Что делать |
|---------------------|-----------|------------|
| **Nginx access.log** — запись есть, Xray логи пустые | Между Nginx и Xray | Nginx не проксирует в Xray. Проверь `proxy_pass` в `/etc/nginx/conf.d/xray.conf` |
| **Nginx access.log** — записи НЕТ | До Nginx (сеть/CF Guard) | Смотри Шаг 2 ниже |
| **Nginx error.log** — есть ошибка | Nginx не может обработать | Читай ошибку в error.log |
| **Xray access.log** — запись `accepted` | Всё работает, проблема в outbound | Смотри Шаг 3 |
| **Xray error.log** — есть ошибка | Xray принял но не может обработать | Читай ошибку |
| **Везде пусто** | Запрос не доходит до сервера | Смотри Шаг 2 |

---

#### Шаг 2. Запрос не доходит до сервера

```bash
# Проверь 1: домен резолвится?
dig +short your-domain.com

# Проверь 2: порт 443 доступен снаружи?
curl -vI https://your-domain.com/  # с ВНЕШНЕГО IP (не с сервера!)

# Проверь 3: CF Guard блокирует?
# Если в Nginx access.log нет записей — возможно CF Guard отсек до Xray
# Проверь:
grep -A5 "CF Guard" /etc/nginx/conf.d/xray.conf
# Если CF Guard ON — добавь свой IP в whitelist: vwn → 3 → 7

# Проверь 4: Nginx вообще работает?
nginx -t && systemctl status nginx

# Проверь 5: порт 443 слушается?
ss -tlnp | grep :443
```

---

#### Шаг 3. Запрос дошёл до Xray но подключение не работает

```bash
# Включи ДЕБАГ логи (по умолчанию они отключены):
for f in /usr/local/etc/xray/*.json; do
    sed -i 's/"loglevel": ".*"/"loglevel": "debug"/' "$f"
    sed -i 's/"access": ".*"/"access": "\/var\/log\/xray\/access.log"/' "$f"
done

# Убери заглушку systemd (no-journal) чтобы journalctl работал:
for svc in xray xray-reality xray-vision; do
    rm -f /etc/systemd/system/${svc}.service.d/no-journal.conf 2>/dev/null
done

systemctl daemon-reload
systemctl restart xray xray-reality xray-vision

# Теперь смотри логи:
journalctl -f -u xray -u xray-reality -u xray-vision --no-pager

# Типичные ошибки в логах:
# "invalid user ID"         → неверный UUID в клиенте
# "failed to validate host" → WS path не совпадает
# "tls: bad certificate"    → SSL сертификат не совпадает с доменом
# "failed to listen"        → Xray не запустился на порту
# "outbound tag not found"  → конфиг роутинга сломан

# После отладки — выключить логи обратно:
vwn → пункт 26 (Пересоздать все конфиги)
```

---

#### Шаг 4. Быстрая таблица проблем

| Симптом | Где смотреть | Команда | Решение |
|---------|-------------|---------|---------|
| **Timeout WS, логи пустые везде** | До Nginx | `curl -vI https://your-domain.com/` | Проверь DNS, CF Guard, firewall |
| **Timeout WS, Nginx access.log есть** | Nginx → Xray | `grep proxy_pass /etc/nginx/conf.d/xray.conf` | Проверь что proxy_pass указывает на правильный порт Xray |
| **Timeout WS, Nginx error.log есть** | Nginx ошибка | `tail -20 /var/log/nginx/error.log` | Читай ошибку |
| **Timeout Reality, логи пустые** | До Xray Reality | `ss -tlnp \| grep 8443` | Порт не слушается → `systemctl restart xray-reality` |
| **Timeout Reality, Xray error.log есть** | Xray ошибка | `journalctl -f -u xray-reality` | Читай ошибку |
| **Timeout Vision, логи пустые** | До Xray Vision | `ss -tlnp \| grep 200` | Порт не слушается → `systemctl restart xray-vision` |
| **Подключение есть, интернет нет** | Outbound | `grep -A5 "outbounds" /usr/local/etc/xray/*.json` | outbound не работает (WARP/Psiphon/Tor упал) |
| **Все таймауты** | Xray конфиг | `xray -test -config /usr/local/etc/xray/config.json` | Конфиг сломан → vwn → 30 |

---

### 🚀 Автоматическая диагностика

```bash
# Полная проверка всех компонентов
vwn status

# Обновить модули перед диагностикой
vwn update
```

## Удаление

```bash
vwn  # Пункт 34
```

Бэкапы в `/root/vwn-backups/` автоматически не удаляются.

## Зависимости

- [Xray-core](https://github.com/XTLS/Xray-core)
- [Cloudflare WARP](https://1.1.1.1/)
- [Psiphon tunnel core](https://github.com/Psiphon-Labs/psiphon-tunnel-core-binaries)
- [acme.sh](https://github.com/acmesh-official/acme.sh)
- nginx (mainline с nginx.org), jq, ufw, tor, obfs4proxy, qrencode

## Версия

Текущая: **3.1**

## Лицензия

MIT License

</details>
