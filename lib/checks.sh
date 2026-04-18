#!/usr/bin/env bash
# =================================================================
# lib/checks.sh — Проверки окружения и runtime-состояния
#
# Все функции:
#   • Возвращают 0 = OK, ненулевой = FAIL
#   • При критической ошибке вызывают die()
#   • Пишут в лог через log_ok / log_warn / log_error
#
# Зависимости: logging.sh, ui.sh (die, warn)
# =================================================================

# -----------------------------------------------------------------
# Root
# -----------------------------------------------------------------
check_root() {
    [[ "$EUID" -eq 0 ]] || die "Запустите от имени root (sudo bash $0)"
    log_ok "Root: OK (EUID=$EUID)"
}

# Совместимость с modules/core.sh
isRoot() { check_root; }

# -----------------------------------------------------------------
# ОС и пакетный менеджер
# -----------------------------------------------------------------
check_os() {
    local found=false
    for mgr in apt dnf yum; do
        command -v "$mgr" &>/dev/null && found=true && break
    done
    $found || die "Поддерживаются системы с apt / dnf / yum"
    log_ok "OS: пакетный менеджер найден"
}

# -----------------------------------------------------------------
# Минимальное свободное место на /
# Использование: check_disk_space [mb_required]
# -----------------------------------------------------------------
check_disk_space() {
    local required="${1:-1536}"
    local free_mb; free_mb=$(df -m / | awk 'NR==2{print $4}')

    if (( free_mb < required )); then
        die "Недостаточно места: ${free_mb} МБ (нужно ${required} МБ)"
    fi
    log_ok "Диск: ${free_mb} МБ свободно (нужно ≥${required})"
}

# -----------------------------------------------------------------
# Интернет
# -----------------------------------------------------------------
check_internet() {
    local ok=false
    for host in 1.1.1.1 8.8.8.8 github.com; do
        if curl -fsS --connect-timeout 5 --max-time 8 \
                -o /dev/null "https://${host}" 2>/dev/null; then
            ok=true; break
        fi
    done
    $ok || die "Нет доступа к интернету"
    log_ok "Интернет: OK"
}

# -----------------------------------------------------------------
# GitHub репозиторий
# -----------------------------------------------------------------
check_repo_access() {
    local url="${GITHUB_RAW:-https://raw.githubusercontent.com/HnDK0/VLESS-WebSocket-TLS-Nginx-WARP/main}/install.sh"
    if ! curl -fsS --connect-timeout 10 --max-time 15 \
              -o /dev/null "$url" 2>/dev/null; then
        log_warn "GitHub недоступен: $url"
        return 1
    fi
    log_ok "GitHub: OK"
}

# -----------------------------------------------------------------
# Xray установлен
# -----------------------------------------------------------------
check_xray_installed() {
    for _b in /usr/local/bin/xray /usr/bin/xray; do
        [[ -x "$_b" ]] && { log_ok "Xray: $_b"; return 0; }
    done
    log_warn "Xray: не установлен"
    return 1
}

# -----------------------------------------------------------------
# Конфиг Xray валиден
# -----------------------------------------------------------------
check_xray_config() {
    local config="${1:-/usr/local/etc/xray/config.json}"
    [[ -f "$config" ]] || { log_warn "Xray config not found: $config"; return 1; }

    local xray_bin=""
    for _b in /usr/local/bin/xray /usr/bin/xray; do
        [[ -x "$_b" ]] && xray_bin="$_b" && break
    done
    [[ -z "$xray_bin" ]] && { log_warn "xray binary not found"; return 1; }

    if "$xray_bin" -test -c "$config" &>/dev/null; then
        log_ok "Xray config OK: $config"
        return 0
    fi
    log_error "Xray config INVALID: $config"
    return 1
}

# -----------------------------------------------------------------
# Сервис запущен
# -----------------------------------------------------------------
check_service_running() {
    local svc="$1"
    systemctl is-active --quiet "$svc" 2>/dev/null \
        && { log_ok "Service running: $svc"; return 0; } \
        || { log_warn "Service not running: $svc"; return 1; }
}

# -----------------------------------------------------------------
# Порт свободен / занят
# -----------------------------------------------------------------
check_port_free() {
    local port="$1"
    if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
        log_warn "Port $port is in use"
        return 1
    fi
    log_ok "Port $port is free"
    return 0
}

check_port_in_use() {
    local port="$1"
    ss -tlnp 2>/dev/null | grep -q ":${port} " \
        && { log_ok "Port $port is listening"; return 0; } \
        || { log_warn "Port $port not listening"; return 1; }
}

# -----------------------------------------------------------------
# SSL сертификат существует и не просрочен
# -----------------------------------------------------------------
check_ssl_cert() {
    local cert="${1:-/etc/nginx/cert/cert.pem}"
    [[ -f "$cert" ]] || { log_warn "SSL cert not found: $cert"; return 1; }

    local expiry
    expiry=$(openssl x509 -enddate -noout -in "$cert" 2>/dev/null | sed 's/notAfter=//')
    [[ -z "$expiry" ]] && { log_warn "Cannot read cert expiry"; return 1; }

    local expiry_epoch now_epoch
    expiry_epoch=$(date -d "$expiry" +%s 2>/dev/null \
        || date -j -f "%b %d %T %Y %Z" "$expiry" +%s 2>/dev/null)
    now_epoch=$(date +%s)

    local days_left=$(( (expiry_epoch - now_epoch) / 86400 ))

    if (( days_left < 7 )); then
        log_warn "SSL cert expires in ${days_left} days!"
        return 1
    fi
    log_ok "SSL cert OK: expires in ${days_left} days"
    return 0
}

# -----------------------------------------------------------------
# Домен указывает на наш IP
# -----------------------------------------------------------------
check_domain_points_to_us() {
    local domain="$1"
    local server_ip resolved_ip

    server_ip=$(curl -fsS --connect-timeout 5 "https://api.ipify.org" 2>/dev/null \
              || curl -fsS --connect-timeout 5 "https://ifconfig.me" 2>/dev/null \
              || hostname -I 2>/dev/null | awk '{print $1}')

    resolved_ip=$(getent hosts "$domain" 2>/dev/null | awk '{print $1}' | head -1 \
               || host "$domain" 2>/dev/null | grep "has address" | awk '{print $4}' | head -1)

    if [[ -z "$resolved_ip" ]]; then
        log_warn "Domain $domain does not resolve"
        return 1
    fi

    if [[ "$server_ip" != "$resolved_ip" ]]; then
        log_warn "Domain $domain → $resolved_ip (server=$server_ip)"
        return 1
    fi

    log_ok "Domain $domain → $resolved_ip (matches)"
    return 0
}

# -----------------------------------------------------------------
# Полная диагностика — вызывается из modules/diag.sh
# Здесь агрегируются все check-функции в читаемый отчёт
# -----------------------------------------------------------------
run_diagnostics_table() {
    echo ""
    echo -e "${CYAN}━━━ Диагностика VWN ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""

    _chk() {
        local label="$1" ok_msg="$2" fail_msg="$3"; shift 3
        if "$@" 2>/dev/null; then
            printf "  %-32s ${GREEN}%s${RESET}\n" "$label" "$ok_msg"
        else
            printf "  %-32s ${RED}%s${RESET}\n" "$label" "$fail_msg"
        fi
    }

    _chk "Xray установлен"         "ДА"      "НЕТ"      check_xray_installed
    _chk "Xray запущен"            "ДА"      "НЕТ"      check_service_running xray
    _chk "Nginx запущен"           "ДА"      "НЕТ"      check_service_running nginx
    _chk "WARP запущен"            "ДА"      "НЕТ/SKIP" check_service_running warp-svc
    _chk "Fail2Ban запущен"        "ДА"      "НЕТ/SKIP" check_service_running fail2ban
    _chk "SSL сертификат"          "OK"      "ИСТЁК/НЕТ" check_ssl_cert
    _chk "Порт 443 (HTTPS)"        "СЛУШАЕТ" "НЕТ"      check_port_in_use 443
    _chk "Интернет"                "OK"      "НЕТ"      check_internet

    echo -e "${CYAN}────────────────────────────────────────────────────────────────${RESET}"
    echo ""
}
