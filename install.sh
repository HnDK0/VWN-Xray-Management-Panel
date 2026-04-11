#!/bin/bash
# =================================================================
# install.sh — Установщик VWN (Xray VLESS + WARP + CDN + Reality)
#
# Использование:
#   bash install.sh                        — интерактивная установка
#   bash install.sh --update               — обновить модули (конфиги не трогает)
#   bash install.sh --auto [ОПЦИИ]         — полностью автоматическая установка
#
# Опции --auto (все необязательны, есть умолчания):
#   --domain      vpn.example.com          CDN-домен для VLESS+WS+TLS       [обязателен без --skip-ws]
#   --stub        https://example.com/     URL сайта-заглушки               [умолч: https://httpbin.org/]
#   --port        16500                    Внутренний порт Xray WS           [умолч: 16500]
#   --lang        ru|en                    Язык интерфейса                   [умолч: ru]
#   --reality                              Установить Reality параллельно
#   --reality-dest microsoft.com:443       SNI-назначение Reality            [умолч: microsoft.com:443]
#   --reality-port 8443                    Порт Reality                      [умолч: 8443]
#   --cert-method cf|standalone            Метод SSL: cf=Cloudflare DNS,
#                                           standalone=HTTP-01               [умолч: standalone]
#   --cf-email    you@example.com          Email Cloudflare (при --cert-method cf)
#   --cf-key      YOUR_CF_API_KEY          API Key Cloudflare (при --cert-method cf)
#   --skip-ws                              Пропустить установку WS (только Reality)
#   --bbr                                  Включить BBR TCP
#   --fail2ban                             Установить Fail2Ban
#   --no-warp                              Не настраивать Cloudflare WARP
#
# Примеры:
#   # Минимально — WS через Cloudflare CDN, SSL через standalone HTTP:
#   bash install.sh --auto --domain vpn.example.com
#
#   # WS + Reality, SSL через Cloudflare DNS, с BBR и Fail2Ban:
#   bash install.sh --auto \
#     --domain vpn.example.com \
#     --stub https://microsoft.com/ \
#     --cert-method cf --cf-email me@me.com --cf-key AbCd1234 \
#     --reality --reality-dest www.apple.com:443 --reality-port 8443 \
#     --bbr --fail2ban
#
#   # Только Reality без WS:
#   bash install.sh --auto --skip-ws \
#     --reality --reality-dest microsoft.com:443 --reality-port 8443
# =================================================================

set -e

VWN_LIB="/usr/local/lib/vwn"
VWN_BIN="/usr/local/bin/vwn"
GITHUB_RAW="https://raw.githubusercontent.com/HnDK0/VLESS-WebSocket-TLS-Nginx-WARP/main"

# Цвета (с fallback когда tput нет)
_c() { tput "$@" 2>/dev/null || true; }
red=$(_c setaf 1)$(_c bold)
green=$(_c setaf 2)$(_c bold)
yellow=$(_c setaf 3)$(_c bold)
cyan=$(_c setaf 6)$(_c bold)
reset=$(_c sgr0)

MODULES="lang core xray nginx warp reality relay psiphon tor security logs backup users diag privacy adblock menu"

# ── Флаги режима ───────────────────────────────────────────────────
UPDATE_ONLY=false
AUTO_MODE=false

# ── Параметры --auto (умолчания) ──────────────────────────────────
OPT_DOMAIN=""
OPT_STUB="https://httpbin.org/"
OPT_PORT=16500
OPT_LANG="ru"
OPT_REALITY=false
OPT_REALITY_DEST="microsoft.com:443"
OPT_REALITY_PORT=8443
OPT_CERT_METHOD="standalone"
OPT_CF_EMAIL=""
OPT_CF_KEY=""
OPT_SKIP_WS=false
OPT_BBR=false
OPT_FAIL2BAN=false
OPT_NO_WARP=false

# =================================================================
# Fallback msg() — работает ДО загрузки lang.sh
# =================================================================
msg() {
    case "$1" in
        run_as_root)     echo "Run as root! / Запустите от root!" ;;
        os_unsupported)  echo "Only apt/dnf/yum systems supported." ;;
        install_deps)    echo "Installing dependencies..." ;;
        install_modules) echo "Downloading modules..." ;;
        install_vwn)     echo "Installing vwn loader..." ;;
        loading)         echo "Loading" ;;
        error)           echo "ERROR" ;;
        module_fail)     echo "Failed to download" ;;
        install_title)   echo "VWN — Xray VLESS + WARP + CDN + Reality" ;;
        update_title)    echo "VWN — Updating modules" ;;
        update_modules)  echo "Updating modules (configs untouched)..." ;;
        update_done)     echo "Update complete! Version" ;;
        install_done)    echo "Modules installed in" ;;
        install_version) echo "Version" ;;
        launching_menu)  echo "Launching setup menu..." ;;
        installed_in)    echo "installed in" ;;
        run_vwn)         echo "Run: vwn" ;;
        auto_start)      echo "Starting unattended installation..." ;;
        auto_domain_req) echo "ERROR: --domain is required (unless --skip-ws)" ;;
        auto_cf_req)     echo "ERROR: --cf-email and --cf-key are required with --cert-method cf" ;;
        auto_done)       echo "Unattended installation complete!" ;;
        auto_params)     echo "Installation parameters" ;;
        *)               echo "$1" ;;
    esac
}

# =================================================================
# Парсинг аргументов
# =================================================================
_parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --update)         UPDATE_ONLY=true ;;
            --auto)           AUTO_MODE=true ;;
            --domain)         OPT_DOMAIN="$2";        shift ;;
            --stub)           OPT_STUB="$2";           shift ;;
            --port)           OPT_PORT="$2";           shift ;;
            --lang)           OPT_LANG="$2";           shift ;;
            --reality)        OPT_REALITY=true ;;
            --reality-dest)   OPT_REALITY_DEST="$2";  shift ;;
            --reality-port)   OPT_REALITY_PORT="$2";  shift ;;
            --cert-method)    OPT_CERT_METHOD="$2";   shift ;;
            --cf-email)       OPT_CF_EMAIL="$2";       shift ;;
            --cf-key)         OPT_CF_KEY="$2";         shift ;;
            --skip-ws)        OPT_SKIP_WS=true ;;
            --bbr)            OPT_BBR=true ;;
            --fail2ban)       OPT_FAIL2BAN=true ;;
            --no-warp)        OPT_NO_WARP=true ;;
            --help|-h)        _show_help; exit 0 ;;
            *) echo "${yellow}Unknown argument: $1${reset}" ;;
        esac
        shift
    done
}

_show_help() {
    cat << 'HELPEOF'

VWN — Installer  (Xray VLESS + WARP + CDN + Reality)
=====================================================

MODES:
  bash install.sh                        Interactive install (default)
  bash install.sh --update               Update modules only (keep configs)
  bash install.sh --auto [OPTIONS]       Fully unattended install

OPTIONS for --auto:
  --domain      DOMAIN       CDN domain for VLESS+WS+TLS  [required unless --skip-ws]
  --stub        URL          Fake-site proxy URL           [default: https://httpbin.org/]
  --port        PORT         Internal Xray WS port         [default: 16500]
  --lang        ru|en        UI language                   [default: ru]
  --reality                  Also install Reality
  --reality-dest HOST:PORT   Reality SNI target            [default: microsoft.com:443]
  --reality-port PORT        Reality listen port           [default: 8443]
  --cert-method cf|standalone SSL method                  [default: standalone]
  --cf-email    EMAIL        Cloudflare email (for cf method)
  --cf-key      KEY          Cloudflare API key (for cf method)
  --skip-ws                  Skip WS install (Reality only)
  --bbr                      Enable BBR TCP congestion control
  --fail2ban                 Install Fail2Ban + WebJail
  --no-warp                  Skip Cloudflare WARP setup

EXAMPLES:
  # Simple: WS+CDN, standalone SSL
  bash install.sh --auto --domain vpn.example.com

  # Full: WS + Reality, Cloudflare DNS SSL, BBR, Fail2Ban
  bash install.sh --auto \
    --domain vpn.example.com \
    --stub https://microsoft.com/ \
    --cert-method cf --cf-email me@me.com --cf-key AbCd1234 \
    --reality --reality-dest www.apple.com:443 --reality-port 8443 \
    --bbr --fail2ban

  # Reality only (no WS, no Nginx/SSL needed)
  bash install.sh --auto --skip-ws \
    --reality --reality-dest microsoft.com:443 --reality-port 8443

HELPEOF
}

# =================================================================
# Валидация параметров --auto
# =================================================================
_validate_auto_params() {
    if ! $OPT_SKIP_WS && [ -z "$OPT_DOMAIN" ]; then
        echo "${red}$(msg auto_domain_req)${reset}"
        echo "Use --domain yourdomain.com or add --skip-ws for Reality-only mode"
        exit 1
    fi

    if [ "$OPT_CERT_METHOD" = "cf" ]; then
        if [ -z "$OPT_CF_EMAIL" ] || [ -z "$OPT_CF_KEY" ]; then
            echo "${red}$(msg auto_cf_req)${reset}"
            exit 1
        fi
    fi

    if ! [[ "$OPT_PORT" =~ ^[0-9]+$ ]] || [ "$OPT_PORT" -lt 443 ] || [ "$OPT_PORT" -gt 65535 ]; then
        echo "${red}Invalid --port: $OPT_PORT (must be 1024-65535)${reset}"
        exit 1
    fi

    if ! [[ "$OPT_REALITY_PORT" =~ ^[0-9]+$ ]] || [ "$OPT_REALITY_PORT" -lt 443 ] || [ "$OPT_REALITY_PORT" -gt 65535 ]; then
        echo "${red}Invalid --reality-port: $OPT_REALITY_PORT (must be 443-65535)${reset}"
        exit 1
    fi

    if [ "$OPT_CERT_METHOD" != "cf" ] && [ "$OPT_CERT_METHOD" != "standalone" ]; then
        echo "${red}Invalid --cert-method: $OPT_CERT_METHOD (must be cf or standalone)${reset}"
        exit 1
    fi
}

_print_auto_params() {
    echo -e "${cyan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${reset}"
    echo -e "   $(msg auto_params):"
    echo -e "${cyan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${reset}"
    $OPT_SKIP_WS  && echo -e "  Mode        : ${yellow}Reality only (WS skipped)${reset}" \
                  || echo -e "  Mode        : ${green}WS+TLS+CDN${OPT_REALITY:+ + Reality}${reset}"
    [ -n "$OPT_DOMAIN" ]   && echo -e "  Domain      : ${green}$OPT_DOMAIN${reset}"
    $OPT_SKIP_WS           || echo -e "  Stub URL    : $OPT_STUB"
    $OPT_SKIP_WS           || echo -e "  Xray port   : $OPT_PORT"
    $OPT_SKIP_WS           || echo -e "  SSL method  : $OPT_CERT_METHOD"
    $OPT_REALITY           && echo -e "  Reality     : ${green}$OPT_REALITY_DEST  port=$OPT_REALITY_PORT${reset}"
    $OPT_BBR               && echo -e "  BBR         : ${green}enabled${reset}"
    $OPT_FAIL2BAN          && echo -e "  Fail2Ban    : ${green}enabled${reset}"
    $OPT_NO_WARP           && echo -e "  WARP        : ${yellow}skipped${reset}"
    echo -e "  Language    : $OPT_LANG"
    echo -e "${cyan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${reset}"
    echo ""
}

# =================================================================
# Общие функции
# =================================================================
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "${red}$(msg run_as_root)${reset}"
        exit 1
    fi
}

check_os() {
    if ! command -v apt &>/dev/null && ! command -v dnf &>/dev/null && ! command -v yum &>/dev/null; then
        echo "${red}$(msg os_unsupported)${reset}"
        exit 1
    fi
}

install_deps() {
    echo -e "${cyan}$(msg install_deps)${reset}"
    if command -v apt &>/dev/null; then
        apt-get update -qq
        apt-get install -y --no-install-recommends curl jq bash coreutils cron 2>/dev/null || true
        systemctl enable --now cron 2>/dev/null || true
    elif command -v dnf &>/dev/null; then
        dnf install -y curl jq bash cronie 2>/dev/null || true
        systemctl enable --now crond 2>/dev/null || true
    elif command -v yum &>/dev/null; then
        yum install -y curl jq bash cronie 2>/dev/null || true
        systemctl enable --now crond 2>/dev/null || true
    fi
}

download_modules() {
    echo -e "${cyan}$(msg install_modules)${reset}"
    mkdir -p "$VWN_LIB"

    for module in $MODULES; do
        echo -n "  $(msg loading) ${module}.sh... "
        if curl -fsSL --connect-timeout 15 \
            "${GITHUB_RAW}/modules/${module}.sh" \
            -o "${VWN_LIB}/${module}.sh" 2>/dev/null; then
            echo "${green}OK${reset}"
        else
            echo "${red}$(msg error)${reset}"
            echo "$(msg module_fail) ${module}.sh"
            return 1
        fi
        chmod 644 "${VWN_LIB}/${module}.sh"
    done
}

install_vwn_binary() {
    echo -e "${cyan}$(msg install_vwn)${reset}"
    curl -fsSL --connect-timeout 15 \
        "${GITHUB_RAW}/vwn" \
        -o "$VWN_BIN" 2>/dev/null || {
        # Fallback: создаём загрузчик локально
        cat > "$VWN_BIN" << 'VWNEOF'
#!/bin/bash
VWN_LIB="/usr/local/lib/vwn"
case "${1:-}" in
    "open-80")
        ufw status | grep -q inactive && exit 0
        ufw allow from any to any port 80 proto tcp comment 'ACME temp' &>/dev/null; exit 0 ;;
    "close-80")
        ufw status | grep -q inactive && exit 0
        ufw status numbered | grep 'ACME temp' | awk -F"[][]" '{print $2}' | sort -rn | while read -r n; do
            echo "y" | ufw delete "$n" &>/dev/null; done; exit 0 ;;
    "update")
        bash <(curl -fsSL https://raw.githubusercontent.com/HnDK0/VLESS-WebSocket-TLS-Nginx-WARP/main/install.sh) --update
        exit 0 ;;
esac
for module in lang core xray nginx warp reality relay psiphon tor security logs backup users diag privacy adblock menu; do
    [ -f "$VWN_LIB/${module}.sh" ] && source "$VWN_LIB/${module}.sh" || { echo "ERROR: module $module not found"; exit 1; }
done
VWN_CONF="/usr/local/etc/xray/vwn.conf"
if [ ! -f "$VWN_CONF" ] || ! grep -q "VWN_LANG=" "$VWN_CONF" 2>/dev/null; then
    selectLang
    _initLang
fi
isRoot
menu "$@"
VWNEOF
    }
    chmod +x "$VWN_BIN"
    echo "${green}vwn $(msg installed_in) $VWN_BIN${reset}"
}

show_version() {
    local ver
    ver=$(grep 'VWN_VERSION=' "$VWN_LIB/core.sh" 2>/dev/null | head -1 | grep -oP '"[^"]+"' | tr -d '"')
    echo "${ver:-unknown}"
}

_load_modules() {
    for module in $MODULES; do
        local f="$VWN_LIB/${module}.sh"
        if [ -f "$f" ]; then
            # shellcheck disable=SC1090
            source "$f"
        else
            echo "${red}ERROR: module $module not found at $f${reset}"
            exit 1
        fi
    done
}

# =================================================================
# Неинтерактивная установка SSL
# =================================================================
_auto_ssl() {
    local domain="$1"

    # Ставим socat если нет
    installPackage "socat" &>/dev/null || true

    # Устанавливаем acme.sh если нет
    if [ ! -f ~/.acme.sh/acme.sh ]; then
        curl -fsSL https://get.acme.sh | sh -s email="acme@${domain}" --no-profile
    fi

    if [ ! -f ~/.acme.sh/acme.sh ]; then
        echo "${red}acme.sh install failed${reset}"; return 1
    fi

    ~/.acme.sh/acme.sh --upgrade --auto-upgrade &>/dev/null || true
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt &>/dev/null || true

    mkdir -p /etc/nginx/cert

    if [ "$OPT_CERT_METHOD" = "cf" ]; then
        # DNS-01 через Cloudflare API — не требует открытого 80 порта
        printf "export CF_Email='%s'\nexport CF_Key='%s'\n" "$OPT_CF_EMAIL" "$OPT_CF_KEY" \
            > /root/.cloudflare_api
        chmod 600 /root/.cloudflare_api

        export CF_Email="$OPT_CF_EMAIL"
        export CF_Key="$OPT_CF_KEY"

        ~/.acme.sh/acme.sh --issue --dns dns_cf -d "$domain" --force
    else
        # HTTP-01 standalone — на время выпуска открываем порт 80
        ufw allow 80/tcp comment 'ACME temp' &>/dev/null || true
        ~/.acme.sh/acme.sh --issue --standalone -d "$domain" \
            --pre-hook  "/usr/local/bin/vwn open-80" \
            --post-hook "/usr/local/bin/vwn close-80" \
            --force
        # Убираем временное правило 80
        ufw status numbered 2>/dev/null | grep 'ACME temp' \
            | awk -F"[][]" '{print $2}' | sort -rn | while read -r n; do
            echo "y" | ufw delete "$n" &>/dev/null || true
        done
    fi

    ~/.acme.sh/acme.sh --install-cert -d "$domain" \
        --key-file       /etc/nginx/cert/cert.key \
        --fullchain-file /etc/nginx/cert/cert.pem \
        --reloadcmd      "systemctl reload nginx 2>/dev/null || true"

    echo "${green}SSL issued for $domain${reset}"
}

# =================================================================
# Неинтерактивная установка WS+TLS+CDN
# =================================================================
_auto_install_ws() {
    echo -e "\n${cyan}━━━ WS + TLS + Nginx + CDN ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${reset}"

    # Firewall
    ufw allow 22/tcp   comment 'SSH'   &>/dev/null || true
    ufw allow 443/tcp  comment 'HTTPS' &>/dev/null || true
    ufw allow 443/udp  comment 'HTTPS' &>/dev/null || true
    echo "y" | ufw enable &>/dev/null || true

    # Sysctl
    applySysctl

    # Генерируем WS path
    local wsPath
    wsPath=$(generateRandomPath)

    echo -e "${cyan}[1/6] Xray config...${reset}"
    writeXrayConfig "$OPT_PORT" "$wsPath" "$OPT_DOMAIN"

    echo -e "${cyan}[2/6] Nginx config...${reset}"
    writeNginxConfig "$OPT_PORT" "$OPT_DOMAIN" "$OPT_STUB" "$wsPath"
    systemctl enable --now nginx 2>/dev/null || true
    systemctl start nginx 2>/dev/null || true

    if ! $OPT_NO_WARP; then
        echo -e "${cyan}[3/6] WARP...${reset}"
        configWarp || echo "${yellow}WARP setup failed (non-fatal)${reset}"
    else
        echo -e "${yellow}[3/6] WARP skipped (--no-warp)${reset}"
    fi

    echo -e "${cyan}[4/6] SSL certificate ($OPT_CERT_METHOD)...${reset}"
    set +e
    _auto_ssl "$OPT_DOMAIN"
    _ssl_exit=$?
    set -e
    [ $_ssl_exit -ne 0 ] && echo -e "${yellow}SSL failed (exit $_ssl_exit) — skipping, run: vwn → SSL later${reset}"

    echo -e "${cyan}[5/6] WARP domains + cron...${reset}"
    if ! $OPT_NO_WARP; then
        applyWarpDomains || true
    fi
    setupLogrotate
    setupLogClearCron
    setupSslCron

    echo -e "${cyan}[6/6] Starting Xray...${reset}"
    systemctl enable --now xray
    systemctl restart xray nginx

    echo -e "${green}WS+TLS done.${reset}"
}

# =================================================================
# Неинтерактивная установка Reality
# =================================================================
_auto_install_reality() {
    echo -e "\n${cyan}━━━ Reality ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${reset}"

    ufw allow "$OPT_REALITY_PORT"/tcp comment 'Xray Reality' &>/dev/null || true

    writeRealityConfig "$OPT_REALITY_PORT" "$OPT_REALITY_DEST"
    setupRealityService

    if ! $OPT_NO_WARP && [ -f "$warpDomainsFile" ]; then
        applyWarpDomains || true
    fi

    echo -e "${green}Reality done. Port: $OPT_REALITY_PORT  SNI: $OPT_REALITY_DEST${reset}"
}

# =================================================================
# Основная функция --auto
# =================================================================
_run_auto() {
    echo -e "${cyan}================================================================${reset}"
    echo -e "   VWN — Unattended Installation"
    echo -e "${cyan}================================================================${reset}"
    echo -e "   $(msg auto_start)"
    echo ""

    _validate_auto_params
    _print_auto_params

    # Загружаем и инициализируем модули
    _load_modules

    # Выставляем язык в vwn.conf без интерактива
    mkdir -p "$(dirname "$VWN_CONF")"
    vwn_conf_set "VWN_LANG" "$OPT_LANG"
    _initLang

    # Системные пакеты + swap
    echo -e "${cyan}━━━ System packages ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${reset}"
    identifyOS
    setupSwap
    rm -f /var/lib/dpkg/lock* 2>/dev/null && dpkg --configure -a 2>/dev/null || true
    eval "$PACKAGE_MANAGEMENT_UPDATE" &>/dev/null || true
    for p in tar gpg unzip jq nano ufw socat curl qrencode python3; do
        installPackage "$p" &>/dev/null || true
    done
    installXray
    if ! $OPT_NO_WARP; then
        installWarp || echo "${yellow}WARP install failed (non-fatal)${reset}"
    fi

    # Nginx — нужен только если WS
    if ! $OPT_SKIP_WS; then
        _installNginxMainline 2>/dev/null || installPackage nginx
    fi

    # WS установка — изолируем от set -e чтобы reality запустился в любом случае
    if ! $OPT_SKIP_WS; then
        set +e
        _auto_install_ws
        _ws_exit=$?
        set -e
        [ $_ws_exit -ne 0 ] && echo -e "${red}WS install failed (exit $_ws_exit), continuing to next steps...${reset}"
    else
        echo -e "${yellow}WS skipped (--skip-ws)${reset}"
        # Минимальный firewall
        ufw allow 22/tcp comment 'SSH' &>/dev/null || true
        echo "y" | ufw enable &>/dev/null || true
        applySysctl
        if ! $OPT_NO_WARP; then
            configWarp || echo "${yellow}WARP setup failed (non-fatal)${reset}"
        fi
    fi

    # Reality установка
    if $OPT_REALITY; then
        _auto_install_reality
    fi

    # Опциональные компоненты
    if $OPT_BBR; then
        echo -e "${cyan}━━━ BBR ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${reset}"
        enableBBR
    fi

    if $OPT_FAIL2BAN; then
        echo -e "${cyan}━━━ Fail2Ban ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${reset}"
        setupFail2Ban
        setupWebJail
    fi

    # Итоговая сводка
    echo ""
    echo -e "${green}================================================================${reset}"
    echo -e "   $(msg auto_done)"
    echo -e "${green}================================================================${reset}"
    echo ""

    if ! $OPT_SKIP_WS; then
        echo -e "  ${cyan}VLESS WS+TLS:${reset}"
        echo -e "    Domain  : ${green}$OPT_DOMAIN${reset}"
        echo -e "    Port    : 443 (CDN) → internal $OPT_PORT"
        echo -e "    Stub    : $OPT_STUB"
    fi

    if $OPT_REALITY; then
        echo -e "  ${cyan}Reality:${reset}"
        echo -e "    Port   : ${green}$OPT_REALITY_PORT${reset}"
        echo -e "    SNI    : ${green}$OPT_REALITY_DEST${reset}"
    fi

    echo ""
    echo -e "  ${cyan}Run ${green}vwn${reset}${cyan} to open the management panel${reset}"
    echo -e "  ${cyan}Run ${green}vwn --help${reset}${cyan} for CLI options${reset}"
    echo -e "${green}================================================================${reset}"
    echo ""

    # Показываем QR / subscription URL
    getQrCode 2>/dev/null || true
}

# =================================================================
# main
# =================================================================
main() {
    _parse_args "$@"
    check_root
    check_os

    echo -e "${cyan}================================================================${reset}"
    if $UPDATE_ONLY; then
        echo -e "   $(msg update_title)"
    elif $AUTO_MODE; then
        echo -e "   $(msg install_title) — Auto mode"
    else
        echo -e "   $(msg install_title)"
    fi
    echo -e "${cyan}================================================================${reset}"
    echo ""

    install_deps

    if $UPDATE_ONLY; then
        echo -e "${cyan}$(msg update_modules)${reset}"
        download_modules || exit 1
        [ -f "$VWN_LIB/lang.sh" ] && { source "$VWN_LIB/lang.sh"; _initLang; }
        install_vwn_binary
        echo -e "\n${green}$(msg update_done): $(show_version)${reset}"
        echo "$(msg run_vwn)"

    elif $AUTO_MODE; then
        download_modules || exit 1
        install_vwn_binary
        _run_auto

    else
        # ── Стандартная интерактивная установка (оригинальный путь) ──
        download_modules || exit 1
        if [ -f "$VWN_LIB/lang.sh" ]; then
            source "$VWN_LIB/lang.sh"
            selectLang
            _initLang
        fi
        install_vwn_binary

        echo -e "\n${green}================================================================${reset}"
        echo -e "   $(msg install_done) $VWN_LIB"
        echo -e "   $(msg install_version): $(show_version)"
        echo -e "${green}================================================================${reset}"
        echo ""
        echo -e "$(msg launching_menu)\n"
        sleep 1
        exec "$VWN_BIN"
    fi
}

main "$@"