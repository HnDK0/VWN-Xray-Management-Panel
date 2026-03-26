#!/usr/bin/env python3
# =================================================================
# web_panel.py — VWN Web Panel Backend
# Запускается от root, слушает только 127.0.0.1:8444
# Требует: Python 3.6+, bcrypt (pip install bcrypt)
# =================================================================

import os, sys, json, hmac, hashlib, time, subprocess, threading, shutil
import urllib.parse, re
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from datetime import datetime

# ── Конфигурация ──────────────────────────────────────────────────
PANEL_CONF    = "/usr/local/etc/xray/panel.conf"
VWN_CONF      = "/usr/local/etc/xray/vwn.conf"
USERS_FILE    = "/usr/local/etc/xray/users.conf"
XRAY_CONFIG   = "/usr/local/etc/xray/config.json"
REALITY_CONF  = "/usr/local/etc/xray/reality.json"
NGINX_CONF    = "/etc/nginx/conf.d/xray.conf"
WARP_DOMAINS  = "/usr/local/etc/xray/warp_domains.txt"
RELAY_DOMAINS = "/usr/local/etc/xray/relay_domains.txt"
PSIPHON_CONF  = "/usr/local/etc/xray/psiphon.json"
TOR_DOMAINS   = "/usr/local/etc/xray/tor_domains.txt"
PANEL_HTML    = "/usr/local/lib/vwn/panel.html"
AUDIT_LOG     = "/var/log/vwn-panel-audit.log"
BACKUP_DIR    = "/root/vwn-backups"
LISTEN_HOST   = "127.0.0.1"
LISTEN_PORT   = 8444
JWT_TTL       = 28800   # 8 часов
RATE_LIMIT    = 5       # попыток логина
RATE_WINDOW   = 900     # за 15 минут

# ── Кэш конфига (читается один раз при старте, обновляется при SIGHUP) ──
_conf_cache: dict = {}
_conf_lock = threading.Lock()

# ── Кэш server_ip (обновляется в фоновом потоке) ──
_server_ip_cache: str = "UNKNOWN"
_server_ip_lock = threading.Lock()
_server_ip_last_update: float = 0

def _load_conf(path: str) -> dict:
    conf = {}
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if "=" in line and not line.startswith("#"):
                    k, _, v = line.partition("=")
                    conf[k.strip()] = v.strip().strip("'\"")
    except FileNotFoundError:
        pass
    return conf

def load_panel_conf(force: bool = False) -> dict:
    global _conf_cache
    with _conf_lock:
        if not _conf_cache or force:
            _conf_cache = _load_conf(PANEL_CONF)
    return _conf_cache

def reload_conf():
    """Вызывается при SIGHUP — сбрасывает кэш."""
    global _conf_cache
    with _conf_lock:
        _conf_cache = {}
    load_panel_conf()

def _fetch_server_ip() -> str:
    """Получает внешний IP адрес сервера."""
    try:
        r = subprocess.run(
            ["bash", "-c", "curl -s --connect-timeout 5 https://api.ipify.org 2>/dev/null || curl -s --connect-timeout 5 https://ipv4.icanhazip.com 2>/dev/null || echo 'UNKNOWN'"],
            capture_output=True, text=True, timeout=10
        )
        return r.stdout.strip() or "UNKNOWN"
    except Exception:
        return "UNKNOWN"

def get_cached_server_ip() -> str:
    """Возвращает кэшированный server_ip."""
    global _server_ip_last_update
    with _server_ip_lock:
        # Обновляем если прошло больше 10 минут или кэш пуст
        if time.time() - _server_ip_last_update > 600 or _server_ip_cache == "UNKNOWN":
            return _server_ip_cache  # Вернём текущий, обновление в фоне
        return _server_ip_cache

def _server_ip_updater():
    """Фоновый поток для обновления server_ip."""
    global _server_ip_cache, _server_ip_last_update
    while True:
        try:
            ip = _fetch_server_ip()
            with _server_ip_lock:
                _server_ip_cache = ip
                _server_ip_last_update = time.time()
        except Exception as e:
            print(f"WARN: server_ip updater error: {e}", flush=True)
        time.sleep(600)  # Обновляем каждые 10 минут

def load_vwn_conf() -> dict:
    return _load_conf(VWN_CONF)

# ── Аудит-лог ────────────────────────────────────────────────────
_audit_lock = threading.Lock()

def audit(ip: str, action: str, result: str = "ok"):
    line = f"{datetime.now().isoformat()} {ip} {action} {result}\n"
    with _audit_lock:
        try:
            with open(AUDIT_LOG, "a") as f:
                f.write(line)
        except Exception:
            pass

# ── Хранилище rate-limit (в памяти) ───────────────────────────────
_login_attempts: dict = {}
_rl_lock = threading.Lock()

# ── Хранилище CSRF токенов (в памяти) ─────────────────────────────
_csrf_tokens: dict = {}  # token -> expiry
_csrf_lock = threading.Lock()

def _generate_csrf() -> str:
    token = hashlib.sha256(os.urandom(32)).hexdigest()
    with _csrf_lock:
        _csrf_tokens[token] = time.time() + JWT_TTL
    return token

def _verify_csrf(token: str) -> bool:
    with _csrf_lock:
        exp = _csrf_tokens.get(token, 0)
        if exp < time.time():
            _csrf_tokens.pop(token, None)
            return False
    return True

def _cleanup_csrf():
    """Удаляет просроченные CSRF токены."""
    now = time.time()
    with _csrf_lock:
        expired = [t for t, exp in _csrf_tokens.items() if exp < now]
        for t in expired:
            del _csrf_tokens[t]

# ── Лимит SSE клиентов ────────────────────────────────────────────
MAX_SSE_CLIENTS = 5
_sse_clients = 0
_sse_lock = threading.Lock()

def check_rate_limit(ip: str) -> bool:
    now = time.time()
    with _rl_lock:
        attempts = [t for t in _login_attempts.get(ip, []) if now - t < RATE_WINDOW]
        _login_attempts[ip] = attempts
        if len(attempts) >= RATE_LIMIT:
            return False
        _login_attempts[ip].append(now)
        return True

# ── JWT ──────────────────────────────────────────────────────────
def _b64url(data: bytes) -> str:
    import base64
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()

def _b64url_decode(s: str) -> bytes:
    import base64
    pad = 4 - len(s) % 4
    if pad != 4:
        s += "=" * pad
    return base64.urlsafe_b64decode(s)

def jwt_create(secret: str) -> str:
    header  = _b64url(json.dumps({"alg":"HS256","typ":"JWT"}).encode())
    payload = _b64url(json.dumps({"iat": int(time.time()), "exp": int(time.time()) + JWT_TTL}).encode())
    sig = hmac.new(secret.encode(), f"{header}.{payload}".encode(), hashlib.sha256).digest()
    return f"{header}.{payload}.{_b64url(sig)}"

def jwt_verify(token: str, secret: str) -> bool:
    try:
        parts = token.split(".")
        if len(parts) != 3:
            return False
        header, payload, sig = parts
        expected = hmac.new(secret.encode(), f"{header}.{payload}".encode(), hashlib.sha256).digest()
        if not hmac.compare_digest(_b64url(expected), sig):
            return False
        data = json.loads(_b64url_decode(payload))
        return data.get("exp", 0) > time.time()
    except Exception:
        return False

# ── Хэширование паролей (bcrypt с fallback на sha256) ─────────────
def _try_import_bcrypt():
    try:
        import bcrypt
        return bcrypt
    except ImportError:
        return None

def hash_password(password: str) -> str:
    bc = _try_import_bcrypt()
    if not bc:
        raise RuntimeError("bcrypt is required but not installed. Run: pip3 install bcrypt")
    return "bcrypt:" + bc.hashpw(password.encode(), bc.gensalt(rounds=12)).decode()

def verify_password(password: str, stored_hash: str) -> bool:
    if stored_hash.startswith("bcrypt:"):
        bc = _try_import_bcrypt()
        if not bc:
            return False
        try:
            return bc.checkpw(password.encode(), stored_hash[7:].encode())
        except Exception:
            return False
    # sha256 hashes from old versions — reject (re-hash via API)
    return False

# ── Безопасный запуск команд (WHITELIST) ──────────────────────────
# Уровни: "read" — любой аутентиф., "write" — аутентиф., "admin" — аутентиф.
# В текущей реализации все уровни требуют аутентификации.
# Для разделения прав — добавить роли в JWT.

COMMANDS: dict = {
    # Статус (read)
    "status_xray":        ("systemctl is-active xray 2>/dev/null; systemctl is-active xray-reality 2>/dev/null", "read"),
    "status_nginx":       ("systemctl is-active nginx 2>/dev/null", "read"),
    "status_warp":        ("warp-cli --accept-tos status 2>/dev/null || warp-cli status 2>/dev/null || echo 'NOT_INSTALLED'", "read"),
    "status_psiphon":     ("systemctl is-active psiphon 2>/dev/null || echo inactive", "read"),
    "status_tor":         ("systemctl is-active tor 2>/dev/null || echo inactive", "read"),
    "status_fail2ban":    ("systemctl is-active fail2ban 2>/dev/null || echo inactive", "read"),

    # Управление сервисами (write) — используем shell=False где возможно
    "restart_xray":       (["systemctl", "restart", "xray"], "write"),
    "restart_xray_reality": (["systemctl", "restart", "xray-reality"], "write"),
    "restart_nginx":      (["systemctl", "restart", "nginx"], "write"),
    "reload_nginx":       (["bash", "-c", "nginx -t && systemctl reload nginx"], "write"),
    "restart_warp":       (["bash", "-c", "systemctl restart warp-svc 2>/dev/null && sleep 3 && warp-cli connect 2>/dev/null || true"], "write"),
    "restart_psiphon":    (["systemctl", "restart", "psiphon"], "write"),
    "restart_tor":        (["systemctl", "restart", "tor"], "write"),
    "restart_fail2ban":   (["systemctl", "restart", "fail2ban"], "write"),

    # Диагностика (read)
    "nginx_test":         (["nginx", "-t"], "read"),
    "xray_test":          (f"xray -test -config {XRAY_CONFIG} 2>&1", "read"),
    "cert_check":         ("openssl x509 -enddate -noout -in /etc/nginx/cert/cert.pem 2>/dev/null || echo 'NO_CERT'", "read"),
    "cert_renew":         (["/root/.acme.sh/acme.sh", "--cron", "--home", "/root/.acme.sh"], "write"),
    "warp_ip":            ("curl -s --connect-timeout 8 -x socks5://127.0.0.1:40000 https://api.ipify.org 2>/dev/null || echo 'ERROR'", "read"),
    "server_ip":          ("curl -s --connect-timeout 5 https://api.ipify.org 2>/dev/null || curl -s --connect-timeout 5 https://ipv4.icanhazip.com 2>/dev/null || echo 'UNKNOWN'", "read"),

    # Логи (read)
    "log_xray":           ("tail -n 100 /var/log/xray/error.log 2>/dev/null || journalctl -u xray -n 100 --no-pager 2>/dev/null || echo 'No logs'", "read"),
    "log_xray_access":    ("tail -n 100 /var/log/xray/access.log 2>/dev/null || echo 'No logs'", "read"),
    "log_nginx":          ("tail -n 100 /var/log/nginx/error.log 2>/dev/null || echo 'No logs'", "read"),
    "log_nginx_access":   ("tail -n 100 /var/log/nginx/access.log 2>/dev/null || echo 'No logs'", "read"),
    "log_psiphon":        ("tail -n 100 /var/log/psiphon/psiphon.log 2>/dev/null || echo 'No logs'", "read"),
    "log_warp":           ("journalctl -u warp-svc -n 100 --no-pager 2>/dev/null || echo 'No logs'", "read"),
    "clear_logs":         ("/usr/local/bin/clear-logs.sh 2>/dev/null || true && echo 'Logs cleared'", "write"),

    # Backup (write)
    "backup_list":        (f"ls -t {BACKUP_DIR}/vwn-backup-*.tar.gz 2>/dev/null | head -20 || echo 'NO_BACKUPS'", "read"),
    "backup_create":      (f"mkdir -p {BACKUP_DIR} && tar -czf {BACKUP_DIR}/vwn-backup-$(date +%Y-%m-%d_%H-%M-%S).tar.gz /usr/local/etc/xray /etc/nginx/conf.d /etc/nginx/cert 2>/dev/null && echo 'OK' || echo 'FAIL'", "write"),

    # Система (read)
    "sysinfo":            ("echo \"RAM=$(free -m | awk '/^Mem:/{print $2}') FREE=$(free -m | awk '/^Mem:/{print $7}') DISK=$(df -m / | awk 'NR==2{print $4}') UPTIME=$(uptime -p 2>/dev/null | sed 's/up //')\"", "read"),
    "bbr_status":         ("sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -c bbr || echo 0", "read"),
    "enable_bbr":         ("echo 'net.ipv4.tcp_congestion_control=bbr' >> /etc/sysctl.conf; echo 'net.core.default_qdisc=fq' >> /etc/sysctl.conf; sysctl -p && echo 'BBR enabled'", "write"),
    "ufw_status":         (["ufw", "status"], "read"),

    # Warp domains (write)
    "warp_domains_list":  (f"cat {WARP_DOMAINS} 2>/dev/null || echo ''", "read"),
    "warp_mode_global":   (["bash", "-c", 'source /usr/local/lib/vwn/core.sh; source /usr/local/lib/vwn/lang.sh; source /usr/local/lib/vwn/warp.sh; toggleWarpMode <<< 1'], "write"),
    "warp_mode_split":    (["bash", "-c", 'source /usr/local/lib/vwn/core.sh; source /usr/local/lib/vwn/lang.sh; source /usr/local/lib/vwn/warp.sh; toggleWarpMode <<< 2'], "write"),
    "warp_mode_off":      (["bash", "-c", 'source /usr/local/lib/vwn/core.sh; source /usr/local/lib/vwn/lang.sh; source /usr/local/lib/vwn/warp.sh; toggleWarpMode <<< 3'], "write"),

    # Обновление (admin)
    "vwn_update":         (["bash", "/usr/local/lib/vwn/update.sh"], "admin"),

    # ── Psiphon ──────────────────────────────────────────────────
    "psiphon_install":    (["bash", "-c", 'source /usr/local/lib/vwn/core.sh 2>/dev/null; source /usr/local/lib/vwn/lang.sh 2>/dev/null; source /usr/local/lib/vwn/psiphon.sh 2>/dev/null; installPsiphon'], "admin"),
    "psiphon_restart":    (["systemctl", "restart", "psiphon"], "write"),
    "psiphon_remove":     (["bash", "-c", 'source /usr/local/lib/vwn/core.sh 2>/dev/null; source /usr/local/lib/vwn/lang.sh 2>/dev/null; source /usr/local/lib/vwn/psiphon.sh 2>/dev/null; echo "y" | removePsiphon'], "admin"),
    "psiphon_logs":       ("tail -n 100 /var/log/psiphon/psiphon.log 2>/dev/null || journalctl -u psiphon -n 100 --no-pager 2>/dev/null || echo 'No logs'", "read"),
    "psiphon_mode_global":(["bash", "-c", 'source /usr/local/lib/vwn/core.sh 2>/dev/null; source /usr/local/lib/vwn/lang.sh 2>/dev/null; source /usr/local/lib/vwn/psiphon.sh 2>/dev/null; applyPsiphonOutbound 2>/dev/null; togglePsiphonGlobal'], "write"),
    "psiphon_mode_split": (["bash", "-c", 'source /usr/local/lib/vwn/core.sh 2>/dev/null; source /usr/local/lib/vwn/lang.sh 2>/dev/null; source /usr/local/lib/vwn/psiphon.sh 2>/dev/null; applyPsiphonDomains'], "write"),
    "psiphon_mode_off":   (["bash", "-c", 'source /usr/local/lib/vwn/core.sh 2>/dev/null; source /usr/local/lib/vwn/lang.sh 2>/dev/null; source /usr/local/lib/vwn/psiphon.sh 2>/dev/null; removePsiphonFromConfigs'], "write"),
    "psiphon_check":      (["bash", "-c", 'source /usr/local/lib/vwn/core.sh 2>/dev/null; source /usr/local/lib/vwn/lang.sh 2>/dev/null; source /usr/local/lib/vwn/psiphon.sh 2>/dev/null; checkPsiphonIP'], "read"),
    "psiphon_country_de": (["bash", "-c", 'source /usr/local/lib/vwn/core.sh 2>/dev/null; source /usr/local/lib/vwn/lang.sh 2>/dev/null; source /usr/local/lib/vwn/psiphon.sh 2>/dev/null; jq ".EgressRegion = \"DE\"" /usr/local/etc/xray/psiphon.json > /tmp/ps.json && mv /tmp/ps.json /usr/local/etc/xray/psiphon.json && systemctl restart psiphon && echo "Country set to DE"'], "write"),
    "psiphon_country_nl": (["bash", "-c", 'source /usr/local/lib/vwn/core.sh 2>/dev/null; source /usr/local/lib/vwn/lang.sh 2>/dev/null; source /usr/local/lib/vwn/psiphon.sh 2>/dev/null; jq ".EgressRegion = \"NL\"" /usr/local/etc/xray/psiphon.json > /tmp/ps.json && mv /tmp/ps.json /usr/local/etc/xray/psiphon.json && systemctl restart psiphon && echo "Country set to NL"'], "write"),
    "psiphon_country_us": (["bash", "-c", 'source /usr/local/lib/vwn/core.sh 2>/dev/null; source /usr/local/lib/vwn/lang.sh 2>/dev/null; source /usr/local/lib/vwn/psiphon.sh 2>/dev/null; jq ".EgressRegion = \"US\"" /usr/local/etc/xray/psiphon.json > /tmp/ps.json && mv /tmp/ps.json /usr/local/etc/xray/psiphon.json && systemctl restart psiphon && echo "Country set to US"'], "write"),
    "psiphon_country_gb": (["bash", "-c", 'source /usr/local/lib/vwn/core.sh 2>/dev/null; source /usr/local/lib/vwn/lang.sh 2>/dev/null; source /usr/local/lib/vwn/psiphon.sh 2>/dev/null; jq ".EgressRegion = \"GB\"" /usr/local/etc/xray/psiphon.json > /tmp/ps.json && mv /tmp/ps.json /usr/local/etc/xray/psiphon.json && systemctl restart psiphon && echo "Country set to GB"'], "write"),
    "psiphon_country_fr": (["bash", "-c", 'source /usr/local/lib/vwn/core.sh 2>/dev/null; source /usr/local/lib/vwn/lang.sh 2>/dev/null; source /usr/local/lib/vwn/psiphon.sh 2>/dev/null; jq ".EgressRegion = \"FR\"" /usr/local/etc/xray/psiphon.json > /tmp/ps.json && mv /tmp/ps.json /usr/local/etc/xray/psiphon.json && systemctl restart psiphon && echo "Country set to FR"'], "write"),
    "psiphon_country_auto":(["bash", "-c", 'source /usr/local/lib/vwn/core.sh 2>/dev/null; source /usr/local/lib/vwn/lang.sh 2>/dev/null; source /usr/local/lib/vwn/psiphon.sh 2>/dev/null; jq ".EgressRegion = \"\"" /usr/local/etc/xray/psiphon.json > /tmp/ps.json && mv /tmp/ps.json /usr/local/etc/xray/psiphon.json && systemctl restart psiphon && echo "Country set to auto"'], "write"),

    # ── Tor ──────────────────────────────────────────────────────
    "tor_restart":        (["systemctl", "restart", "tor"], "write"),
    "tor_remove":         (["bash", "-c", 'systemctl stop tor 2>/dev/null; systemctl disable tor 2>/dev/null; rm -f /usr/local/etc/xray/tor_domains.txt; source /usr/local/lib/vwn/core.sh 2>/dev/null; source /usr/local/lib/vwn/lang.sh 2>/dev/null; source /usr/local/lib/vwn/tor.sh 2>/dev/null; removeTorFromConfigs 2>/dev/null || true; echo "Tor removed"'], "admin"),

    # ── Reality ──────────────────────────────────────────────────
    "reality_restart":    (["systemctl", "restart", "xray-reality"], "write"),
    "reality_remove":     (["bash", "-c", 'systemctl stop xray-reality 2>/dev/null; systemctl disable xray-reality 2>/dev/null; rm -f /etc/systemd/system/xray-reality.service /usr/local/etc/xray/reality.json; systemctl daemon-reload; echo "Reality removed"'], "admin"),

    # ── Security ──────────────────────────────────────────────────
    "bbr_enable":         (["bash", "-c", 'source /usr/local/lib/vwn/core.sh 2>/dev/null; source /usr/local/lib/vwn/lang.sh 2>/dev/null; source /usr/local/lib/vwn/security.sh 2>/dev/null; enableBBR'], "write"),
    "f2b_setup":          (["bash", "-c", 'source /usr/local/lib/vwn/core.sh 2>/dev/null; source /usr/local/lib/vwn/lang.sh 2>/dev/null; source /usr/local/lib/vwn/security.sh 2>/dev/null; setupFail2Ban'], "write"),
    "webjail_setup":      (["bash", "-c", 'source /usr/local/lib/vwn/core.sh 2>/dev/null; source /usr/local/lib/vwn/lang.sh 2>/dev/null; source /usr/local/lib/vwn/security.sh 2>/dev/null; setupWebJail'], "write"),
    "ipv6_toggle":        (["bash", "-c", 'source /usr/local/lib/vwn/core.sh 2>/dev/null; source /usr/local/lib/vwn/lang.sh 2>/dev/null; source /usr/local/lib/vwn/security.sh 2>/dev/null; toggleIPv6'], "write"),
    "cpuguard_setup":     (["bash", "-c", 'source /usr/local/lib/vwn/core.sh 2>/dev/null; source /usr/local/lib/vwn/lang.sh 2>/dev/null; source /usr/local/lib/vwn/security.sh 2>/dev/null; setupCpuGuard'], "write"),
    "cpuguard_remove":    (["bash", "-c", 'source /usr/local/lib/vwn/core.sh 2>/dev/null; source /usr/local/lib/vwn/lang.sh 2>/dev/null; source /usr/local/lib/vwn/security.sh 2>/dev/null; echo "y" | removeCpuGuard'], "write"),
    "ufw_status":         ("ufw status verbose 2>/dev/null || echo 'UFW inactive'", "read"),
    "ssh_port_get":       ("grep -E '^Port ' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1 || echo '22'", "read"),
    "ipv6_status":        ("sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo '0'", "read"),

    # ── Users advanced ──────────────────────────────────────────
    "users_rebuild_sub":  (["bash", "-c", 'source /usr/local/lib/vwn/core.sh 2>/dev/null; source /usr/local/lib/vwn/lang.sh 2>/dev/null; source /usr/local/lib/vwn/users.sh 2>/dev/null; rebuildAllSubFiles'], "write"),

    # ── Services ─────────────────────────────────────────────────
    "restart_all":        (["bash", "-c", 'systemctl restart xray xray-reality nginx warp-svc psiphon tor 2>/dev/null; echo "All services restarted"'], "write"),

    # ── WARP watchdog ────────────────────────────────────────────
    "warp_watchdog_setup":(["bash", "-c", 'source /usr/local/lib/vwn/core.sh 2>/dev/null; source /usr/local/lib/vwn/lang.sh 2>/dev/null; source /usr/local/lib/vwn/warp.sh 2>/dev/null; setupWarpWatchdog'], "write"),

    # ── Xray change with value ──────────────────────────────────
    "xray_set_port":      ("/usr/local/lib/vwn/xray.sh set_port", "write"),
    "xray_set_path":      ("/usr/local/lib/vwn/xray.sh set_path", "write"),
    "xray_set_domain":    ("/usr/local/lib/vwn/xray.sh set_domain", "write"),
    "xray_set_cdn":       ("/usr/local/lib/vwn/xray.sh set_cdn", "write"),
    "xray_set_uuid":      ("/usr/local/lib/vwn/xray.sh set_uuid", "write"),

    # VLESS config (read)
    "xray_config_get":    (f"cat {XRAY_CONFIG} 2>/dev/null || echo '{{}}'", "read"),
    "xray_change_port":   ("/usr/local/lib/vwn/xray.sh change_port", "write"),
    "xray_change_path":   ("/usr/local/lib/vwn/xray.sh change_path", "write"),
    "xray_change_domain": ("/usr/local/lib/vwn/xray.sh change_domain", "write"),
    "xray_change_uuid":   ("/usr/local/lib/vwn/xray.sh change_uuid", "write"),
    "xray_change_cdn":    ("/usr/local/lib/vwn/xray.sh change_cdn", "write"),

    # Reality (read)
    "reality_config_get": (f"cat {REALITY_CONF} 2>/dev/null || echo '{{}}'", "read"),

    # ── Relay modes ──────────────────────────────────────────────
    "relay_mode_global":  (["bash", "-c", 'source /usr/local/lib/vwn/core.sh 2>/dev/null; source /usr/local/lib/vwn/lang.sh 2>/dev/null; source /usr/local/lib/vwn/relay.sh 2>/dev/null; toggleRelayGlobal'], "write"),
    "relay_mode_split":   (["bash", "-c", 'source /usr/local/lib/vwn/core.sh 2>/dev/null; source /usr/local/lib/vwn/lang.sh 2>/dev/null; source /usr/local/lib/vwn/relay.sh 2>/dev/null; applyRelayDomains'], "write"),
    "relay_mode_off":     (["bash", "-c", 'source /usr/local/lib/vwn/core.sh 2>/dev/null; source /usr/local/lib/vwn/lang.sh 2>/dev/null; source /usr/local/lib/vwn/relay.sh 2>/dev/null; removeRelayFromConfigs'], "write"),
    "relay_check":        (["bash", "-c", 'source /usr/local/lib/vwn/core.sh 2>/dev/null; source /usr/local/lib/vwn/lang.sh 2>/dev/null; source /usr/local/lib/vwn/relay.sh 2>/dev/null; checkRelayIP'], "read"),

    # ── Psiphon domains list ─────────────────────────────────────
    "psiphon_domains_list": (f"cat {PSIPHON_DOMAINS} 2>/dev/null || echo ''", "read"),
}

def run_command(action: str, ip: str = "-") -> dict:
    if action not in COMMANDS:
        return {"ok": False, "output": "Unknown action"}
    cmd, level = COMMANDS[action]
    try:
        if isinstance(cmd, list):
            # shell=False — безопаснее для фиксированных команд
            result = subprocess.run(
                cmd, capture_output=True, text=True,
                timeout=60, env={**os.environ, "TERM": "xterm"}
            )
        else:
            result = subprocess.run(
                cmd, shell=True, capture_output=True, text=True,
                timeout=60, env={**os.environ, "TERM": "xterm"}
            )
        out = (result.stdout + result.stderr).strip()
        if level in ("write", "admin"):
            audit(ip, f"cmd:{action}", "ok" if result.returncode == 0 else f"rc={result.returncode}")
        return {"ok": True, "output": out}
    except subprocess.TimeoutExpired:
        return {"ok": False, "output": "Timeout"}
    except Exception as e:
        return {"ok": False, "output": str(e)}

# ── Чтение / запись файлов (только разрешённые пути) ──────────────
EDITABLE_FILES = {
    "xray_config":    XRAY_CONFIG,
    "reality_config": REALITY_CONF,
    "nginx_config":   NGINX_CONF,
    "warp_domains":   WARP_DOMAINS,
    "relay_domains":  RELAY_DOMAINS,
    "tor_domains":    TOR_DOMAINS,
    "vwn_conf":       VWN_CONF,
    "users":          USERS_FILE,
}

def read_file(name: str) -> dict:
    path = EDITABLE_FILES.get(name)
    if not path:
        return {"ok": False, "content": "Unknown file"}
    try:
        with open(path) as f:
            return {"ok": True, "content": f.read()}
    except FileNotFoundError:
        return {"ok": True, "content": ""}
    except Exception as e:
        return {"ok": False, "content": str(e)}

def write_file(name: str, content: str, ip: str = "-") -> dict:
    path = EDITABLE_FILES.get(name)
    if not path:
        return {"ok": False, "msg": "Unknown file"}
    if name in ("xray_config", "reality_config"):
        try:
            json.loads(content)
        except json.JSONDecodeError as e:
            return {"ok": False, "msg": f"Invalid JSON: {e}"}
    if os.path.exists(path):
        try:
            shutil.copy2(path, path + ".bak")
        except Exception:
            pass
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(content)
        audit(ip, f"write_file:{name}", "ok")
        return {"ok": True, "msg": "Saved"}
    except Exception as e:
        return {"ok": False, "msg": str(e)}

# ── Управление пользователями ─────────────────────────────────────
def get_users() -> list:
    users = []
    try:
        with open(USERS_FILE) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#"):
                    parts = line.split("|")
                    if len(parts) >= 2:
                        users.append({
                            "uuid":    parts[0],
                            "name":    parts[1],
                            "token":   parts[2] if len(parts) > 2 else "",
                        })
    except FileNotFoundError:
        pass
    return users

def add_user(name: str, uuid_str: str = "", ip: str = "-") -> dict:
    import uuid as uuid_mod
    if not re.match(r'^[a-zA-Z0-9_\-]{1,32}$', name):
        return {"ok": False, "msg": "Invalid name (a-z, 0-9, _, - only, max 32)"}
    if uuid_str:
        try:
            uuid_mod.UUID(uuid_str)
        except ValueError:
            return {"ok": False, "msg": "Invalid UUID format"}
    else:
        r = subprocess.run(["cat", "/proc/sys/kernel/random/uuid"], capture_output=True, text=True)
        uuid_str = r.stdout.strip()
    users = get_users()
    if any(u["name"] == name for u in users):
        return {"ok": False, "msg": "User already exists"}
    try:
        token = subprocess.run(
            ["bash", "-c", 'head /dev/urandom | tr -dc A-Za-z0-9 | head -c 24'],
            capture_output=True, text=True
        ).stdout.strip()
        with open(USERS_FILE, "a") as f:
            f.write(f"{uuid_str}|{name}|{token}\n")
        # ИСПРАВЛЕНО: используем список вместо shell=True
        subprocess.run(
            ["bash", "-c", 'source /usr/local/lib/vwn/core.sh 2>/dev/null; '
             'source /usr/local/lib/vwn/lang.sh 2>/dev/null; '
             'source /usr/local/lib/vwn/users.sh 2>/dev/null; '
             '_applyUsersToConfigs 2>/dev/null || true'],
            timeout=15
        )
        audit(ip, f"add_user:{name}", "ok")
        return {"ok": True, "uuid": uuid_str}
    except Exception as e:
        return {"ok": False, "msg": str(e)}

def del_user(name: str, ip: str = "-") -> dict:
    if not re.match(r'^[a-zA-Z0-9_\-]{1,32}$', name):
        return {"ok": False, "msg": "Invalid name"}
    try:
        users = get_users()
        new_users = [u for u in users if u["name"] != name]
        if len(new_users) == len(users):
            return {"ok": False, "msg": "User not found"}
        with open(USERS_FILE, "w") as f:
            for u in new_users:
                f.write(f"{u['uuid']}|{u['name']}|{u['token']}\n")
        subprocess.run(
            ["bash", "-c", 'source /usr/local/lib/vwn/core.sh 2>/dev/null; '
             'source /usr/local/lib/vwn/lang.sh 2>/dev/null; '
             'source /usr/local/lib/vwn/users.sh 2>/dev/null; '
             '_applyUsersToConfigs 2>/dev/null || true'],
            timeout=15
        )
        audit(ip, f"del_user:{name}", "ok")
        return {"ok": True}
    except Exception as e:
        return {"ok": False, "msg": str(e)}

# ── Управление доменами (warp/relay/tor) ──────────────────────────
DOMAIN_FILES = {
    "warp":  WARP_DOMAINS,
    "relay": RELAY_DOMAINS,
    "tor":   TOR_DOMAINS,
}
PSIPHON_DOMAINS = "/usr/local/etc/xray/psiphon_domains.txt"

APPLY_COMMANDS = {
    "warp":     ["bash", "-c", 'source /usr/local/lib/vwn/core.sh 2>/dev/null; source /usr/local/lib/vwn/lang.sh 2>/dev/null; source /usr/local/lib/vwn/warp.sh 2>/dev/null; applyWarpDomains 2>/dev/null || true'],
    "relay":    ["bash", "-c", 'source /usr/local/lib/vwn/core.sh 2>/dev/null; source /usr/local/lib/vwn/lang.sh 2>/dev/null; source /usr/local/lib/vwn/relay.sh 2>/dev/null; applyRelayDomains 2>/dev/null || true'],
    "tor":      ["bash", "-c", 'source /usr/local/lib/vwn/core.sh 2>/dev/null; source /usr/local/lib/vwn/lang.sh 2>/dev/null; source /usr/local/lib/vwn/tor.sh 2>/dev/null; applyTorDomains 2>/dev/null || true'],
    "psiphon":  ["bash", "-c", 'source /usr/local/lib/vwn/core.sh 2>/dev/null; source /usr/local/lib/vwn/lang.sh 2>/dev/null; source /usr/local/lib/vwn/psiphon.sh 2>/dev/null; applyPsiphonDomains 2>/dev/null || true'],
}

def add_domain(list_name: str, domain: str, ip: str = "-") -> dict:
    path = DOMAIN_FILES.get(list_name)
    if not path:
        return {"ok": False, "msg": "Unknown list"}
    domain = domain.strip().lower().lstrip(".")
    if not re.match(r'^[a-z0-9.\-]+$', domain):
        return {"ok": False, "msg": "Invalid domain"}
    try:
        existing = set()
        if os.path.exists(path):
            with open(path) as f:
                existing = {l.strip() for l in f if l.strip()}
        if domain in existing:
            return {"ok": False, "msg": "Already exists"}
        existing.add(domain)
        with open(path, "w") as f:
            f.write("\n".join(sorted(existing)) + "\n")
        cmd = APPLY_COMMANDS.get(list_name)
        if cmd:
            subprocess.run(cmd, timeout=15)
        audit(ip, f"add_domain:{list_name}:{domain}", "ok")
        return {"ok": True}
    except Exception as e:
        return {"ok": False, "msg": str(e)}

def del_domain(list_name: str, domain: str, ip: str = "-") -> dict:
    path = DOMAIN_FILES.get(list_name)
    if not path:
        return {"ok": False, "msg": "Unknown list"}
    domain = domain.strip()
    try:
        if not os.path.exists(path):
            return {"ok": False, "msg": "List is empty"}
        with open(path) as f:
            lines = [l.strip() for l in f if l.strip() and l.strip() != domain]
        with open(path, "w") as f:
            f.write("\n".join(lines) + "\n")
        cmd = APPLY_COMMANDS.get(list_name)
        if cmd:
            subprocess.run(cmd, timeout=15)
        audit(ip, f"del_domain:{list_name}:{domain}", "ok")
        return {"ok": True}
    except Exception as e:
        return {"ok": False, "msg": str(e)}

# ── Смена пароля через API ────────────────────────────────────────
def change_password(new_password: str, ip: str = "-") -> dict:
    if len(new_password) < 8:
        return {"ok": False, "msg": "Password too short (min 8 chars)"}
    new_hash = hash_password(new_password)
    try:
        conf = _load_conf(PANEL_CONF)
        conf["PANEL_PASS_HASH"] = new_hash
        with open(PANEL_CONF, "w") as f:
            for k, v in conf.items():
                f.write(f"{k}={v}\n")
        os.chmod(PANEL_CONF, 0o600)
        reload_conf()
        audit(ip, "change_password", "ok")
        return {"ok": True, "msg": "Password changed"}
    except Exception as e:
        return {"ok": False, "msg": str(e)}

# ── Скачивание бэкапа ─────────────────────────────────────────────
def stream_backup(filename: str):
    """Возвращает (path, size) если файл существует и безопасен."""
    # Санитизация имени файла — только буквы, цифры, дефис, подчёркивание, точка
    if not re.match(r'^vwn-backup-[\d_-]+\.tar\.gz$', filename):
        return None
    path = os.path.join(BACKUP_DIR, filename)
    if not os.path.realpath(path).startswith(BACKUP_DIR):
        return None  # path traversal
    if not os.path.isfile(path):
        return None
    return path

# ── Dashboard ─────────────────────────────────────────────────────
def get_dashboard() -> dict:
    def svc(name):
        try:
            r = subprocess.run(["systemctl", "is-active", name],
                               capture_output=True, text=True, timeout=5)
            return r.stdout.strip() == "active"
        except Exception:
            return False

    try:
        mem = open("/proc/meminfo").read()
        total = int(re.search(r'MemTotal:\s+(\d+)', mem).group(1)) // 1024
        avail = int(re.search(r'MemAvailable:\s+(\d+)', mem).group(1)) // 1024
    except Exception:
        total = avail = 0

    try:
        st = os.statvfs("/")
        disk_total = st.f_blocks * st.f_frsize // 1024 // 1024
        disk_free  = st.f_bavail * st.f_frsize // 1024 // 1024
    except Exception:
        disk_total = disk_free = 0

    try:
        with open("/proc/uptime") as f:
            secs = int(float(f.read().split()[0]))
        uptime = f"{secs//86400}d {(secs%86400)//3600}h {(secs%3600)//60}m"
    except Exception:
        uptime = "?"

    cert_days = -1
    try:
        r = subprocess.run(
            ["openssl", "x509", "-enddate", "-noout", "-in", "/etc/nginx/cert/cert.pem"],
            capture_output=True, text=True, timeout=5)
        if "notAfter=" in r.stdout:
            date_str = r.stdout.strip().replace("notAfter=", "")
            exp = subprocess.run(
                ["date", "-d", date_str, "+%s"],
                capture_output=True, text=True, timeout=5)
            if exp.stdout.strip().isdigit():
                cert_days = (int(exp.stdout.strip()) - int(time.time())) // 86400
    except Exception:
        pass

    # Используем кэшированный server_ip вместо блокирующего curl
    server_ip = get_cached_server_ip()

    users = get_users()

    warp_r = subprocess.run(
        ["warp-cli", "status"],
        capture_output=True, text=True, timeout=5)
    warp_connected = "Connected" in warp_r.stdout

    # Домен из nginx конфига
    domain = ""
    try:
        with open(NGINX_CONF) as f:
            for line in f:
                m = re.match(r'\s*server_name\s+(\S+)', line)
                if m and m.group(1) != "_":
                    domain = m.group(1).rstrip(";")
                    break
    except Exception:
        pass

    # Путь к панели из конфига
    panel_path = ""
    try:
        conf = load_panel_conf()
        panel_path = conf.get("PANEL_PATH", "")
    except Exception:
        pass

    # Список бэкапов
    backups = []
    try:
        files = sorted(
            [f for f in os.listdir(BACKUP_DIR) if f.startswith("vwn-backup-") and f.endswith(".tar.gz")],
            reverse=True
        )[:10]
        for f in files:
            fp = os.path.join(BACKUP_DIR, f)
            backups.append({"name": f, "size": os.path.getsize(fp)})
    except Exception:
        pass

    return {
        "ok": True,
        "services": {
            "xray":         svc("xray"),
            "xray_reality": svc("xray-reality"),
            "nginx":        svc("nginx"),
            "warp":         warp_connected,
            "psiphon":      svc("psiphon"),
            "tor":          svc("tor"),
            "fail2ban":     svc("fail2ban"),
        },
        "ram":       {"total": total, "avail": avail},
        "disk":      {"total": disk_total, "free": disk_free},
        "uptime":    uptime,
        "cert_days": cert_days,
        "server_ip": server_ip.strip(),
        "domain":    domain,
        "panel_path": panel_path,
        "users":     users,
        "backups":   backups,
    }

# ── HTTP Handler ──────────────────────────────────────────────────
class PanelHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def _ip(self) -> str:
        # За nginx reverse proxy реальный IP в X-Real-IP
        # Доверяем заголовку только если подключение с localhost
        if self.client_address[0] in ("127.0.0.1", "::1"):
            real_ip = self.headers.get("X-Real-IP", "").strip()
            # Базовая валидация: только IPv4/IPv6 без лишних символов
            if real_ip and re.match(r'^[0-9a-fA-F.:]+$', real_ip):
                return real_ip
        return self.client_address[0]

    def _send_json(self, data: dict, code: int = 200):
        body = json.dumps(data).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _send_html(self, code: int = 200):
        try:
            with open(PANEL_HTML, "rb") as f:
                body = f.read()
        except FileNotFoundError:
            body = b"<h1>panel.html not found</h1>"
        # Generate nonce for CSP
        nonce = hashlib.sha256(os.urandom(16)).hexdigest()[:16]
        # Inject nonce into script tags
        body_str = body.decode('utf-8', errors='replace')
        body_str = body_str.replace('<script>', f'<script nonce="{nonce}">')
        body = body_str.encode('utf-8')
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Security-Policy",
            f"default-src 'self'; connect-src 'self'; script-src 'nonce-{nonce}'; "
            "style-src 'unsafe-inline'; "
            "font-src 'self'; img-src 'self' data:;")
        self.end_headers()
        self.wfile.write(body)

    def _check_origin(self) -> bool:
        origin = self.headers.get("Origin", "")
        if not origin:
            return True  # Не CORS запрос
        host = self.headers.get("Host", "")
        return origin.endswith(host)

    def _get_token(self) -> str:
        auth = self.headers.get("Authorization", "")
        if auth.startswith("Bearer "):
            return auth[7:]
        xtoken = self.headers.get("X-Panel-Token", "")
        if xtoken:
            return xtoken
        # SSE (EventSource) не может отправлять заголовки — читаем из query
        qs = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        return qs.get("token", [""])[0]

    def _auth(self) -> bool:
        conf = load_panel_conf()
        secret = conf.get("PANEL_SECRET", "")
        if not secret:
            return False
        return jwt_verify(self._get_token(), secret)

    def _read_body(self) -> dict:
        length = int(self.headers.get("Content-Length", 0))
        if length > 1048576:  # 1 MB лимит
            return {}
        raw = self.rfile.read(length)
        try:
            return json.loads(raw)
        except Exception:
            return {}

    def do_GET(self):
        path = self.path.split("?")[0]

        if path in ("/", "/panel", "/panel/"):
            self._send_html()
            return

        if path == "/api/stream":
            if not self._auth():
                self._send_json({"error": "Unauthorized"}, 401)
                return
            self._stream_status()
            return

        # Скачивание бэкапа
        if path.startswith("/api/backup/download/"):
            if not self._auth():
                self._send_json({"error": "Unauthorized"}, 401)
                return
            filename = path[len("/api/backup/download/"):]
            file_path = stream_backup(filename)
            if not file_path:
                self._send_json({"error": "Not found"}, 404)
                return
            size = os.path.getsize(file_path)
            self.send_response(200)
            self.send_header("Content-Type", "application/gzip")
            self.send_header("Content-Disposition", f'attachment; filename="{filename}"')
            self.send_header("Content-Length", str(size))
            self.end_headers()
            with open(file_path, "rb") as f:
                shutil.copyfileobj(f, self.wfile)
            audit(self._ip(), f"download_backup:{filename}", "ok")
            return

        print(f"GET {path} — Not found", flush=True)
        self._send_json({"error": "Not found"}, 404)

    def do_POST(self):
        path = self.path.split("?")[0]

        if path == "/api/login":
            self._handle_login()
            return

        if not self._check_origin():
            print(f"POST {path} — Forbidden (origin) from {self._ip()}", flush=True)
            self._send_json({"error": "Forbidden (origin)"}, 403)
            return

        if not self._auth():
            print(f"POST {path} — Unauthorized from {self._ip()}", flush=True)
            self._send_json({"error": "Unauthorized"}, 401)
            return

        body = self._read_body()
        ip = self._ip()

        if path == "/api/cmd":
            action = body.get("action", "")
            if action in COMMANDS:
                _, level = COMMANDS[action]
                if level in ("write", "admin"):
                    # CSRF проверка для write/admin команд
                    csrf = self.headers.get("X-CSRF-Token", "")
                    if not _verify_csrf(csrf):
                        self._send_json({"error": "CSRF invalid"}, 403)
                        return
                    # Rate-limit для write/admin
                    if not check_rate_limit(ip):
                        audit(ip, f"cmd:{action}", "rate_limited")
                        self._send_json({"error": "Rate limited"}, 429)
                        return
                    if level == "admin":
                        conf = load_panel_conf()
                        if conf.get("PANEL_ADMIN_ONLY", "") == "1":
                            self._send_json({"error": "Admin only"}, 403)
                            return
            result = run_command(action, ip)
            self._send_json(result)

        elif path == "/api/file/read":
            self._send_json(read_file(body.get("name", "")))

        elif path == "/api/file/write":
            self._send_json(write_file(body.get("name", ""), body.get("content", ""), ip))

        elif path == "/api/users":
            self._send_json({"ok": True, "users": get_users()})

        elif path == "/api/users/add":
            name = body.get("name", "").strip()
            uuid_s = body.get("uuid", "").strip()
            self._send_json(add_user(name, uuid_s, ip))

        elif path == "/api/users/del":
            name = body.get("name", "").strip()
            self._send_json(del_user(name, ip))

        elif path == "/api/domain/add":
            self._send_json(add_domain(body.get("list", ""), body.get("domain", ""), ip))

        elif path == "/api/domain/del":
            self._send_json(del_domain(body.get("list", ""), body.get("domain", ""), ip))

        elif path == "/api/panel/passwd":
            new_pw = body.get("password", "")
            self._send_json(change_password(new_pw, ip))

        elif path == "/api/sysinfo":
            self._send_json(self._get_sysinfo())

        elif path == "/api/dashboard":
            self._send_json(get_dashboard())

        else:
            print(f"POST {path} — Not found", flush=True)
            self._send_json({"error": "Not found"}, 404)

    def _handle_login(self):
        ip = self._ip()
        if not check_rate_limit(ip):
            audit(ip, "login", "rate_limited")
            self._send_json({"error": "Too many attempts. Try in 15 minutes."}, 429)
            return
        body = self._read_body()
        password = body.get("password", "")
        conf = load_panel_conf()
        stored = conf.get("PANEL_PASS_HASH", "")
        secret  = conf.get("PANEL_SECRET", "")
        if not stored or not secret:
            self._send_json({"error": "Panel not configured"}, 500)
            return
        if not verify_password(password, stored):
            audit(ip, "login", "wrong_password")
            self._send_json({"error": "Wrong password"}, 401)
            return
        token = jwt_create(secret)
        csrf = _generate_csrf()
        audit(ip, "login", "ok")
        self._send_json({"ok": True, "token": token, "csrf": csrf, "ttl": JWT_TTL})

    def _get_sysinfo(self) -> dict:
        r = run_command("sysinfo")
        info = {}
        for part in r.get("output", "").split():
            if "=" in part:
                k, v = part.split("=", 1)
                info[k] = v
        return {"ok": True, **info}

    def _stream_status(self):
        """SSE endpoint — шлёт dashboard каждые 10 секунд."""
        global _sse_clients
        with _sse_lock:
            if _sse_clients >= MAX_SSE_CLIENTS:
                self._send_json({"error": "Too many SSE clients"}, 429)
                return
            _sse_clients += 1
        try:
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "keep-alive")
            self.end_headers()
            while True:
                data = get_dashboard()
                msg = f"data: {json.dumps(data)}\n\n"
                self.wfile.write(msg.encode())
                self.wfile.flush()
                time.sleep(10)
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            with _sse_lock:
                _sse_clients -= 1

# ── Установка bcrypt если доступен pip ───────────────────────────
def _ensure_bcrypt():
    bc = _try_import_bcrypt()
    if bc:
        return True
    print("INFO: bcrypt not found, trying to install...", flush=True)
    r = subprocess.run(
        [sys.executable, "-m", "pip", "install", "bcrypt", "--break-system-packages", "-q"],
        capture_output=True
    )
    if r.returncode == 0:
        print("INFO: bcrypt installed.", flush=True)
        return True
    print("WARN: bcrypt unavailable, using SHA-256 fallback (less secure).", flush=True)
    return False

# ── SIGHUP handler ────────────────────────────────────────────────
def _setup_sighup():
    import signal
    def _handler(signum, frame):
        reload_conf()
        print("INFO: config reloaded.", flush=True)
    signal.signal(signal.SIGHUP, _handler)

# ── Запуск ────────────────────────────────────────────────────────
def main():
    if os.geteuid() != 0:
        print("ERROR: web_panel.py must run as root", file=sys.stderr)
        sys.exit(1)

    conf = load_panel_conf()
    if not conf.get("PANEL_PASS_HASH"):
        print("ERROR: PANEL_PASS_HASH not set in panel.conf", file=sys.stderr)
        print("Run: vwn → Web Panel → Install", file=sys.stderr)
        sys.exit(1)

    _ensure_bcrypt()
    _setup_sighup()

    # Инициализируем кэш конфига
    load_panel_conf(force=True)

    # Запускаем фоновый поток для обновления server_ip
    ip_thread = threading.Thread(target=_server_ip_updater, daemon=True)
    ip_thread.start()

    # Первоначальное получение server_ip
    global _server_ip_cache, _server_ip_last_update
    with _server_ip_lock:
        _server_ip_cache = _fetch_server_ip()
        _server_ip_last_update = time.time()
    print(f"INFO: server_ip = {_server_ip_cache}", flush=True)

    port = int(conf.get("PANEL_PORT", LISTEN_PORT))
    server = ThreadingHTTPServer((LISTEN_HOST, port), PanelHandler)
    print(f"VWN Panel listening on {LISTEN_HOST}:{port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass

if __name__ == "__main__":
    main()
