#!/bin/bash
# =================================================================
# install.sh — Установщик VWN (Xray VLESS + WARP + CDN + Reality)
#
# Использование:
#   bash install.sh                        — интерактивная установка
#   bash install.sh --update               — обновить модули и шаблоны конфигов
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
#   --ssh-port    22222                    Сменить порт SSH                  [умолч: не менять]
#   --ipv6                                 Включить IPv6                     [умолч: выключен]
#   --cpu-guard                            Включить CPU Guard                [умолч: выключен]
#   --bbr                                  Включить BBR TCP
#   --fail2ban                             Установить Fail2Ban
#   --jail                                 Включить WebJail (nginx-probe)
#   --adblock                              Включить Adblock
#   --privacy                              Включить Privacy Mode
#   --psiphon                              Установить Psiphon
#   --psiphon-country DE                   Страна Psiphon (DE, NL, US...)
#   --psiphon-warp                         Psiphon через WARP
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

set -eo pipefail

LOCK_FILE="/tmp/vwn.lock"

# Цвета нужны до любых сообщений об ошибках
_c() { tput "$@" 2>/dev/null || true; }
red=$(_c setaf 1)$(_c bold)
green=$(_c setaf 2)$(_c bold)
yellow=$(_c setaf 3)$(_c bold)
cyan=$(_c setaf 6)$(_c bold)
reset=$(_c sgr0)

# Очистка блокировок dpkg в самом начале
fuser -kk /var/lib/dpkg/lock* 2>/dev/null || true
sleep 1
rm -f /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend /var/cache/apt/archives/lock
dpkg --configure -a 2>/dev/null || true

# Проверка свободного места
FREE_SPACE=$(df -m / | awk 'NR==2 {print $4}')
if [ "$FREE_SPACE" -lt 1536 ]; then
    echo "${red}ОШИБКА: Недостаточно свободного места на диске${reset}"
    echo "Требуется минимум 1.5ГБ свободно, доступно: ${FREE_SPACE}МБ"
    exit 1
fi

# Защита от параллельного запуска (работает на ВСЕХ дистрибутивах)
[ -z "$VWN_INSTALL_PARENT" ] && {
    if [ -f "$LOCK_FILE" ]; then
        PID=$(cat "$LOCK_FILE" 2>/dev/null | tr -cd '0-9')
        if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
            echo ""
            echo "${red}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${reset}"
            echo "${red}ОШИБКА: Другой экземпляр скрипта уже запущен${reset}"
            echo "${red}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${reset}"
            echo ""
            echo "PID запущенного процесса: ${yellow}$PID${reset}"
            echo ""
            echo "Если ты уверен что он завис — убей его командой:"
            echo "  ${green}kill -9 $PID; rm -f /tmp/vwn.lock${reset}"
            echo ""
            exit 1
        fi
    fi

    # Защита от зависших блокировок старше 1 минуты
    if [ -f "$LOCK_FILE" ]; then
        if test "$(find "$LOCK_FILE" -mmin +1)"; then
            echo "info: удалена зависшая блокировка старше 1 минуты"
            rm -f "$LOCK_FILE"
        fi
    fi

    echo $$ > "$LOCK_FILE"
}

# Общий таймаут на всю установку 15 минут
[ -z "$VWN_INSTALL_PARENT" ] && {
    export VWN_INSTALL_PARENT=1
    timeout --foreground 900 bash "$0" "$@"
    exit $?
}

# Глобальная очистка при любом выходе
cleanup() {
    # Восстановление терминала при любом выходе — исправляет сломанный вывод после официального скрипта Xray
    stty sane 2>/dev/null || true

    rm -f "$LOCK_FILE"
    find /usr/local/etc/xray /etc/nginx -name "*.tmp" -delete 2>/dev/null
    # Вызываем vwn только если он уже установлен
    [ -x "$VWN_BIN" ] && "$VWN_BIN" close-80 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP ERR

VWN_LIB="/usr/local/lib/vwn"
VWN_BIN="/usr/local/bin/vwn"

# Определяем реальный путь скрипта для любого способа запуска
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GITHUB_RAW="https://raw.githubusercontent.com/HnDK0/VLESS-WebSocket-TLS-Nginx-WARP/main"

# ✅ Автоматический фикс apt зеркал если основной тупит
fix_apt_mirrors() {
    command -v apt &>/dev/null || return 0

    # Проверяем работает ли стандартный репозиторий
    if apt update -qq 2>/dev/null; then
        return 0
    fi

    echo -e "${yellow}⚠️  Основной репозиторий не отвечает, пробуем резервные зеркала...${reset}"

    # Бэкап оригинала
    cp -a /etc/apt/sources.list /etc/apt/sources.list.vwn_backup 2>/dev/null

    local mirrors=(
        "http://ftp.ru.debian.org/debian/"
        "http://mirror.rol.ru/debian/"
        "http://debian.mirohost.net/debian/"
        "http://debian-mirror.ru/debian/"
        "http://ftp.debian.org/debian/"
    )

    for mirror in "${mirrors[@]}"; do
        echo -n "  пробуем $mirror... "

        # Подменяем временно основной и security репозитории
        sed -e "s|http://.*debian.org/debian/|$mirror|g" \
            -e "s|http://security.debian.org/|${mirror}|g" \
            /etc/apt/sources.list > /etc/apt/sources.list.tmp
        mv /etc/apt/sources.list.tmp /etc/apt/sources.list

        # Отключаем ip6 при обновлении на проблемных хостерах
        if apt -o Acquire::ForceIPv4=true update -qq 2>/dev/null; then
            echo -e "${green}OK${reset}"
            return 0
        else
            echo -e "${red}FAIL${reset}"
        fi
    done

    # Если все упали — возвращаем как было
    mv /etc/apt/sources.list.vwn_backup /etc/apt/sources.list 2>/dev/null
    echo -e "${red}Все зеркала недоступны, оставляем стандартный${reset}"
}

MODULES="lang core xray nginx warp reality relay psiphon tor security logs backup users diag privacy adblock vision xhttp menu"
VWN_CONFIG="/usr/local/lib/vwn/config"

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
OPT_VISION=false
OPT_STREAM=false

# ── Новые опциональные компоненты ──
OPT_SSH_PORT=""
OPT_JAIL=false
OPT_IPV6=false
OPT_CPU_GUARD=false
OPT_ADBLOCK=false
OPT_PRIVACY=false
OPT_PSIPHON=false
OPT_PSIPHON_COUNTRY=""
OPT_PSIPHON_WARP=false

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
            --stream)         OPT_STREAM=true ;;
            --vision)         OPT_VISION=true ;;
            --ssh-port)       OPT_SSH_PORT="$2";            shift ;;
            --jail)           OPT_JAIL=true ;;
            --ipv6)           OPT_IPV6=true ;;
            --no-ipv6)        OPT_IPV6=false ;;
            --cpu-guard)      OPT_CPU_GUARD=true ;;
            --adblock)        OPT_ADBLOCK=true ;;
            --privacy)        OPT_PRIVACY=true ;;
            --psiphon)        OPT_PSIPHON=true ;;
            --psiphon-country) OPT_PSIPHON_COUNTRY="$2";    shift ;;
            --psiphon-warp)   OPT_PSIPHON_WARP=true ;;
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
  bash install.sh --update               Update modules and config templates
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
  --ssh-port    PORT         Change SSH port (1-65535)
  --ipv6                     Enable IPv6 (default: disabled)
  --cpu-guard                Enable CPU Guard (priority for xray/nginx)
  --bbr                      Enable BBR TCP congestion control
  --fail2ban                 Install Fail2Ban
  --jail                     Enable WebJail (nginx-probe, requires --fail2ban)
  --adblock                  Enable Adblock (geosite:category-ads-all)
  --privacy                  Enable Privacy Mode (no traffic logs)
  --psiphon                  Install Psiphon proxy
  --psiphon-country CODE     Psiphon exit country (DE, NL, US, GB, FR, etc.)
  --psiphon-warp             Route Psiphon through WARP
  --no-warp                  Skip Cloudflare WARP setup
  --stream                   Activate Stream SNI (mutually exclusive with --vision)
  --vision                   Install Vision (VLESS+TLS+Vision, direct on 443)

EXAMPLES:
  # Simple: WS+CDN, standalone SSL
  bash install.sh --auto --domain vpn.example.com

  # Full: WS + Reality, Cloudflare DNS SSL, BBR, Fail2Ban, Jail, Adblock
  bash install.sh --auto \
    --domain vpn.example.com \
    --stub https://microsoft.com/ \
    --cert-method cf --cf-email me@me.com --cf-key AbCd1234 \
    --reality --reality-dest www.apple.com:443 --reality-port 8443 \
    --bbr --fail2ban --jail --adblock

  # Reality only (no WS, no Nginx/SSL needed)
  bash install.sh --auto --skip-ws \
    --reality --reality-dest microsoft.com:443 --reality-port 8443

  # Full stack: WS + Reality + Psiphon + all security features
  bash install.sh --auto \
    --domain vpn.example.com \
    --ssh-port 22222 \
    --cpu-guard --ipv6 --fail2ban --jail --adblock --privacy \
    --psiphon --psiphon-country DE \
    --reality --bbr

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

    if $OPT_VISION; then
        if $OPT_SKIP_WS; then
            echo "${red}ERROR: --vision requires WS+TLS (cannot use --skip-ws with --vision)${reset}"
            exit 1
        fi
        # Vision и Stream SNI несовместимы
        if $OPT_STREAM; then
            echo "${red}ERROR: --vision and --stream are mutually exclusive${reset}"
            exit 1
        fi
    fi

    if ! [[ "$OPT_PORT" =~ ^[0-9]+$ ]] || [ "$OPT_PORT" -lt 1024 ] || [ "$OPT_PORT" -gt 65535 ]; then
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

    # Валидация SSH порта
    if [ -n "$OPT_SSH_PORT" ]; then
        if ! [[ "$OPT_SSH_PORT" =~ ^[0-9]+$ ]] || [ "$OPT_SSH_PORT" -lt 1 ] || [ "$OPT_SSH_PORT" -gt 65535 ]; then
            echo "${red}Invalid --ssh-port: $OPT_SSH_PORT (must be 1-65535)${reset}"
            exit 1
        fi
    fi

    # Валидация страны Psiphon (2-буквенный код)
    if $OPT_PSIPHON && [ -n "$OPT_PSIPHON_COUNTRY" ]; then
        if ! [[ "$OPT_PSIPHON_COUNTRY" =~ ^[A-Z]{2}$ ]] && ! [[ "$OPT_PSIPHON_COUNTRY" =~ ^[a-z]{2}$ ]]; then
            echo "${red}Invalid --psiphon-country: $OPT_PSIPHON_COUNTRY (must be 2-letter country code, e.g. DE, NL, US)${reset}"
            exit 1
        fi
    fi

    # Psiphon WARP требует WARP
    if $OPT_PSIPHON_WARP && $OPT_NO_WARP; then
        echo "${red}ERROR: --psiphon-warp requires WARP (cannot use --no-warp)${reset}"
        exit 1
    fi
}

_print_auto_params() {
    echo -e "${cyan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${reset}"
    echo -e "   $(msg auto_params):"
    echo -e "${cyan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${reset}"
    # Строка Mode — перечисляем все активные компоненты
    local _mode=""
    $OPT_SKIP_WS  && _mode="Reality only (WS skipped)" || _mode="WS+TLS+CDN"
    $OPT_REALITY  && _mode="${_mode} + Reality"
    $OPT_VISION   && _mode="${_mode} + Vision"
    $OPT_STREAM && ! $OPT_VISION && _mode="${_mode} + Stream SNI"
    $OPT_SKIP_WS  && echo -e "  Mode        : ${yellow}${_mode}${reset}"                   || echo -e "  Mode        : ${green}${_mode}${reset}"
    [ -n "$OPT_DOMAIN" ]        && echo -e "  Domain      : ${green}$OPT_DOMAIN${reset}"
    $OPT_SKIP_WS                || echo -e "  Stub URL    : $OPT_STUB"
    $OPT_SKIP_WS                || echo -e "  Xray port   : $OPT_PORT"
    $OPT_SKIP_WS                || echo -e "  SSL method  : $OPT_CERT_METHOD"
    $OPT_REALITY                && echo -e "  Reality     : ${green}$OPT_REALITY_DEST  port=$OPT_REALITY_PORT${reset}"
    $OPT_VISION                 && echo -e "  Vision      : ${green}$OPT_DOMAIN${reset}"
    $OPT_STREAM && ! $OPT_VISION && echo -e "  Stream SNI  : ${green}enabled${reset}"
    [ -n "$OPT_SSH_PORT" ]      && echo -e "  SSH port    : ${green}$OPT_SSH_PORT${reset}"
    $OPT_IPV6                   && echo -e "  IPv6        : ${green}enabled${reset}"
    $OPT_CPU_GUARD              && echo -e "  CPU Guard   : ${green}enabled${reset}"
    $OPT_FAIL2BAN               && echo -e "  Fail2Ban    : ${green}enabled${reset}"
    $OPT_JAIL                   && echo -e "  Jail        : ${green}enabled${reset}"
    $OPT_ADBLOCK                && echo -e "  Adblock     : ${green}enabled${reset}"
    $OPT_PRIVACY                && echo -e "  Privacy     : ${green}enabled${reset}"
    $OPT_PSIPHON                && echo -e "  Psiphon     : ${green}enabled${reset}${OPT_PSIPHON_COUNTRY:+ (country=$OPT_PSIPHON_COUNTRY)}${OPT_PSIPHON_WARP:+ [WARP]}"
    $OPT_BBR                    && echo -e "  BBR         : ${green}enabled${reset}"
    $OPT_NO_WARP                && echo -e "  WARP        : ${yellow}skipped${reset}"
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

_installJq() {
    local JQ_VERSION="1.7.1"
    local JQ_URL="https://github.com/jqlang/jq/releases/download/jq-${JQ_VERSION}/jq-linux-amd64"
    local JQ_BIN="/usr/local/bin/jq"

    # Проверяем текущую версию
    local current_version
    current_version=$(jq --version 2>/dev/null | grep -oP '[\d.]+' | head -1)
    if [ "$current_version" = "$JQ_VERSION" ]; then
        echo "info: jq ${JQ_VERSION} already installed, skipping."
        return 0
    fi

    echo -n "  installing jq ${JQ_VERSION}... "
    if curl -fsSL --connect-timeout 15 "$JQ_URL" -o "$JQ_BIN" 2>/dev/null; then
        chmod +x "$JQ_BIN"
        echo "${green}OK${reset}"
    else
        echo "${red}FAIL (will use system jq)${reset}"
    fi
}

# Fallback prepareApt — работает до загрузки модулей
prepareApt() {
    fuser -kk /var/lib/dpkg/lock* 2>/dev/null || true
    sleep 0.5
    rm -f /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend /var/cache/apt/archives/lock 2>/dev/null
    dpkg --configure -a 2>/dev/null || true
}

install_deps() {
    echo -e "${cyan}$(msg install_deps)${reset}"
    
    prepareApt
    fix_apt_mirrors
    
    if command -v apt &>/dev/null; then
        apt update -qq 2>/dev/null || true
        # jq из репозитория — fallback если скачать не удастся
        yes '' | apt install -y curl jq bash coreutils cron 2>/dev/null || true
        systemctl enable --now cron 2>/dev/null || true
    elif command -v dnf &>/dev/null; then
        yes '' | dnf install -y curl jq bash cronie 2>/dev/null || true
        systemctl enable --now crond 2>/dev/null || true
    elif command -v yum &>/dev/null; then
        yes '' | yum install -y curl jq bash cronie 2>/dev/null || true
        systemctl enable --now crond 2>/dev/null || true
    fi
    # Устанавливаем фиксированную версию jq поверх системной
    _installJq
}

download_modules() {
    echo -e "${cyan}$(msg install_modules)${reset}"
    mkdir -p "$VWN_LIB"

    local updated=0 unchanged=0 failed=0

    for module in $MODULES; do
        local mod_file="${VWN_LIB}/${module}.sh"
        local old_hash="" new_hash=""

        # Сохраняем хеш старого файла (если есть)
        [ -f "$mod_file" ] && old_hash=$(md5sum "$mod_file" 2>/dev/null | awk '{print $1}')

    echo -n "  ${module}.sh... "
    if curl -fsSL --connect-timeout 15 \
        "${GITHUB_RAW}/modules/${module}.sh" \
        -o "${mod_file}.tmp" 2>/dev/null; then
        mv "${mod_file}.tmp" "${mod_file}"

            new_hash=$(md5sum "$mod_file" 2>/dev/null | awk '{print $1}')
            chmod 644 "$mod_file"

            if [ "$old_hash" = "$new_hash" ]; then
                echo -e "${yellow}SAME${reset}"
                unchanged=$((unchanged + 1))
            else
                local mod_date
                mod_date=$(stat -c '%y' "$mod_file" 2>/dev/null | cut -d. -f1)
                echo -e "${green}UPDATED${reset} (${mod_date})"
                updated=$((updated + 1))
            fi
        else
            echo -e "${red}FAIL${reset}"
            echo "    $(msg module_fail) ${module}.sh"
            failed=$((failed + 1))
        fi
    done

    # Итог
    echo ""
    echo -e "${cyan}────────────────────────────────────────────────────────${reset}"
    echo -e "  Updated: ${green}${updated}${reset}  |  Same: ${yellow}${unchanged}${reset}  |  Failed: ${red}${failed}${reset}"
    echo -e "${cyan}────────────────────────────────────────────────────────${reset}"

    # Копируем шаблоны конфигов
    echo -e "\n${cyan}Downloading config templates...${reset}"
    mkdir -p "$VWN_CONFIG"
    local cfg_updated=0 cfg_unchanged=0
    for cfg in nginx_main.conf nginx_base.conf nginx_vision.conf nginx_stream.conf nginx_stream_ws.conf nginx_default.conf sub_map.conf xray_ws.json xray_vision.json xray_reality.json xray_xhttp.json xray-vision.service; do
        local cfg_file="${VWN_CONFIG}/${cfg}"
        local old_hash="" new_hash=""
        [ -f "$cfg_file" ] && old_hash=$(md5sum "$cfg_file" 2>/dev/null | awk '{print $1}')
        echo -n "  ${cfg}... "
        if curl -fsSL --connect-timeout 15 \
            "${GITHUB_RAW}/config/${cfg}" \
            -o "${cfg_file}.tmp" 2>/dev/null; then
            mv "${cfg_file}.tmp" "${cfg_file}"
            new_hash=$(md5sum "$cfg_file" 2>/dev/null | awk '{print $1}')
            chmod 644 "$cfg_file"
            if [ "$old_hash" = "$new_hash" ]; then
                echo -e "${yellow}SAME${reset}"; cfg_unchanged=$((cfg_unchanged + 1))
            else
                echo -e "${green}UPDATED${reset}"; cfg_updated=$((cfg_updated + 1))
            fi
        else
            echo -e "${red}FAIL${reset}"
        fi
    done
    echo -e "  Configs: ${green}${cfg_updated}${reset} updated, ${yellow}${cfg_unchanged}${reset} same"
}

install_vwn_binary() {
    echo -e "${cyan}$(msg install_vwn)${reset}"
    curl -fsSL --connect-timeout 15 \
        "${GITHUB_RAW}/vwn" \
        -o "${VWN_BIN}.tmp" 2>/dev/null && mv "${VWN_BIN}.tmp" "${VWN_BIN}" || {
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
for module in lang core xray nginx warp reality relay psiphon tor security logs backup users diag privacy adblock vision xhttp menu; do
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
            > /root/.cloudflare_api.tmp
        chmod 600 /root/.cloudflare_api.tmp
        mv /root/.cloudflare_api.tmp /root/.cloudflare_api

        export CF_Email="$OPT_CF_EMAIL"
        export CF_Key="$OPT_CF_KEY"

        ~/.acme.sh/acme.sh --issue --dns dns_cf -d "$domain" --force >/dev/null 2>&1
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
        --reloadcmd      "systemctl restart nginx 2>/dev/null || true"

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

    # Системный DNS — предотвращает утечку через DNS хостера
    setupSystemDNS

    # Генерируем WS path
    local wsPath
    wsPath=$(generateRandomPath)

    echo -e "${cyan}[1/6] Xray config...${reset}"
    writeXrayConfig "$OPT_PORT" "$wsPath" "$OPT_DOMAIN"
    # Записываем домен как адрес подключения — иначе подписки генерируются по IP
    mkdir -p /usr/local/etc/xray
    echo "$OPT_DOMAIN" > /usr/local/etc/xray/connect_host

    echo -e "${cyan}[2/6] Nginx config...${reset}"
    writeNginxConfigBase "$OPT_PORT" "$OPT_DOMAIN" "$OPT_STUB" "$wsPath"
    systemctl enable nginx 2>/dev/null || true

    if ! $OPT_NO_WARP; then
        echo -e "${cyan}[3/6] WARP...${reset}"
        configWarp || echo "${yellow}WARP setup failed (non-fatal)${reset}"
    else
        echo -e "${yellow}[3/6] WARP skipped (--no-warp)${reset}"
    fi

    echo -e "${cyan}[4/6] SSL certificate ($OPT_CERT_METHOD)...${reset}"
    local _ssl_exit=0
    _auto_ssl "$OPT_DOMAIN" || _ssl_exit=$?
    if [ $_ssl_exit -ne 0 ]; then
        echo -e "${red}SSL failed (exit $_ssl_exit)${reset}"
        if $AUTO_MODE; then
            echo -e "${red}Unattended mode: SSL is required. Aborting.${reset}"
            echo -e "${yellow}Fix DNS/firewall and re-run with the same flags.${reset}"
            exit 1
        else
            echo -e "${yellow}Continue without SSL? nginx will start with a self-signed cert (subscriptions will not work). $(msg yes_no)${reset}"
            read -r _ssl_continue
            if [[ "$_ssl_continue" != "y" ]]; then
                echo -e "${red}Aborting. Fix SSL and re-run.${reset}"
                exit 1
            fi
            systemctl start nginx 2>/dev/null || true
        fi
    fi

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

    if ! $OPT_NO_WARP && [ -f "${warpDomainsFile:-/usr/local/etc/xray/warp_domains.txt}" ]; then
        applyWarpDomains || true
    fi

    echo -e "${green}Reality done. Port: $OPT_REALITY_PORT  SNI: $OPT_REALITY_DEST${reset}"
}

# =================================================================
# Неинтерактивная установка Vision
# =================================================================
_auto_install_vision() {
    echo -e "\n${cyan}━━━ Vision ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${reset}"

    # Если Stream SNI активен — отключаем автоматически (Vision несовместим с Stream)
    if grep -q "ssl_preread on" /etc/nginx/nginx.conf 2>/dev/null; then
        echo -e "${yellow}Stream SNI active — disabling for Vision (incompatible)...${reset}"
        _doDisableStreamSNI || {
            echo "${red}ERROR: Stream SNI disable failed. Vision cannot be installed.${reset}"
            return 1
        }
    fi

    echo -e "${cyan}Installing Vision for domain: $OPT_DOMAIN${reset}"
    echo -e "${cyan}Using existing WS certificate${reset}"

    # Вызываем installVision
    installVision --auto || {
        echo "${red}Vision installation failed.${reset}"
        return 1
    }

    echo -e "${green}Vision done. Domain: $OPT_DOMAIN${reset}"
}

# =================================================================
# Helper-функции для неинтерактивной установки
# =================================================================

# Неинтерактивная смена SSH порта
_auto_change_ssh_port() {
    local new_port="$1"
    local old_port
    old_port=$(grep -E "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1)
    old_port="${old_port:-22}"

    echo -e "${cyan}Changing SSH port: $old_port → $new_port${reset}"
    ufw allow "$new_port"/tcp comment 'SSH' &>/dev/null || true
    sed -i "s/^#\?Port [0-9]*/Port $new_port/" /etc/ssh/sshd_config
    systemctl restart sshd 2>/dev/null || systemctl restart ssh
    echo "${green}SSH port changed to $new_port.${reset}"

    # Обновляем fail2ban если установлен
    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        echo -e "${cyan}Updating Fail2Ban SSH port...${reset}"
        local sshd_backend sshd_logpath
        if [ -f /var/log/auth.log ]; then
            sshd_backend="auto"
            sshd_logpath="logpath  = /var/log/auth.log"
        else
            sshd_backend="systemd"
            sshd_logpath=""
        fi
        local cf_ips=""
        if command -v curl &>/dev/null; then
            cf_ips=$(curl -fsSL --connect-timeout 5 "https://www.cloudflare.com/ips-v4" 2>/dev/null | tr '\n' ' ' | sed 's/  */ /g')
        fi
        python3 - "$new_port" "$sshd_backend" "$sshd_logpath" "$cf_ips" << 'PEOF'
import sys, re
new_port    = sys.argv[1]
backend     = sys.argv[2]
logpath_str = sys.argv[3]
cf_ips      = sys.argv[4]
jail_path = "/etc/fail2ban/jail.local"
try:
    with open(jail_path) as f:
        content = f.read()
except FileNotFoundError:
    sys.exit(0)
logpath_line = ("\n" + logpath_str) if logpath_str else ""
new_sshd = (
    "[sshd]\n"
    "enabled  = true\n"
    "port     = " + new_port + "\n"
    "filter   = sshd\n"
    "backend  = " + backend +
    logpath_line + "\n"
    "maxretry = 3\n"
    "bantime  = 24h"
)
default_replacement = (
    "[DEFAULT]\n"
    "banaction = iptables-multiport\n"
    "bantime  = 2h\n"
    "findtime = 10m\n"
    "maxretry = 5\n"
    "ignoreip = 127.0.0.1/8 ::1 " + cf_ips + "\n"
)
content = re.sub(r'\[DEFAULT\].*?(?=\n\[)', default_replacement, content, flags=re.DOTALL)
content = re.sub(r'\[sshd\].*?(?=\n\[|\Z)', new_sshd, content, flags=re.DOTALL)
with open(jail_path, "w") as f:
    f.write(content)
PEOF
        systemctl restart fail2ban
        echo "${green}Fail2Ban updated SSH port.${reset}"
    fi
}

# Неинтерактивная установка Psiphon
_auto_install_psiphon() {
    local country="${1:-DE}"
    local warp_mode="${2:-false}"  # true/false

    echo -e "${cyan}━━━ Psiphon ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${reset}"

    # Скачиваем бинарь
    installPsiphonBinary || return 1

    local tunnel_mode="plain"
    if $warp_mode; then
        if ! systemctl is-active --quiet warp-svc 2>/dev/null || ! ss -tlnp 2>/dev/null | grep -q ':40000'; then
            echo "${yellow}WARP not running, using plain mode for Psiphon${reset}"
        else
            tunnel_mode="warp"
        fi
    fi

    # Записываем конфиг
    writePsiphonConfig "$country" "$tunnel_mode"
    setupPsiphonService

    # Добавляем в Xray конфиги
    applyPsiphonOutbound
    # Пустой список доменов = rule удалён (пользователь добавит позже)
    if [ -f "$psiphonDomainsFile" ] && [ -s "$psiphonDomainsFile" ]; then
        applyPsiphonDomains
    fi

    echo -e "${green}Psiphon installed. Country: $country, Mode: $tunnel_mode${reset}"
}

# Неинтерактивное включение IPv6
_auto_toggle_ipv6() {
    local current
    current=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)
    if [ "$current" = "1" ]; then
        echo -e "${cyan}Enabling IPv6...${reset}"
        sysctl -w net.ipv6.conf.all.disable_ipv6=0 &>/dev/null
        sysctl -w net.ipv6.conf.default.disable_ipv6=0 &>/dev/null
        sysctl -w net.ipv6.conf.lo.disable_ipv6=0 &>/dev/null
        sysctl -w net.ipv6.icmp.echo_ignore_all=0 &>/dev/null
        sed -i '/disable_ipv6/d' /etc/sysctl.d/99-xray.conf 2>/dev/null || true
        sed -i '/ipv6.*icmp.*ignore/d' /etc/sysctl.d/99-xray.conf 2>/dev/null || true
        echo "${green}IPv6 enabled.${reset}"
    else
        echo -e "${yellow}IPv6 already enabled, skipping.${reset}"
    fi
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
    
    # ✅ Убиваем все процессы apt ПЕРЕД созданием свопа!
    fuser -kk /var/lib/dpkg/lock* 2>/dev/null || true
    rm -f /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend /var/cache/apt/archives/lock 2>/dev/null
    pkill -9 apt apt-get dpkg 2>/dev/null || true
    sleep 1
    
    setupSwap
    
    rm -f /var/lib/dpkg/lock* 2>/dev/null && dpkg --configure -a 2>/dev/null || true
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

    # Stream SNI — если явно указан и Vision не перекрывает (Vision активирует сам)
    if $OPT_STREAM && ! $OPT_VISION; then
        echo -e "\n${cyan}━━━ Stream SNI ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${reset}"
        setupStreamSNI 7443 10443 || echo "${yellow}Stream SNI failed (non-fatal)${reset}"
    fi

    # Vision установка
    if $OPT_VISION; then
        set +e
        _auto_install_vision
        _vision_exit=$?
        set -e
        [ $_vision_exit -ne 0 ] && echo -e "${red}Vision install failed (exit $_vision_exit), continuing...${reset}"
    fi

    # Опциональные компоненты — порядок важен!
    # 1. Смена SSH порта (перед Fail2Ban чтобы f2b знал правильный порт)
    if [ -n "$OPT_SSH_PORT" ]; then
        echo -e "${cyan}━━━ SSH Port ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${reset}"
        _auto_change_ssh_port "$OPT_SSH_PORT"
    fi

    # 2. IPv6
    if $OPT_IPV6; then
        echo -e "${cyan}━━━ IPv6 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${reset}"
        _auto_toggle_ipv6
    fi

    # 3. CPU Guard
    if $OPT_CPU_GUARD; then
        echo -e "${cyan}━━━ CPU Guard ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${reset}"
        setupCpuGuard
    fi

    # 4. Fail2Ban
    if $OPT_FAIL2BAN; then
        echo -e "${cyan}━━━ Fail2Ban ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${reset}"
        setupFail2Ban
    fi

    # 5. WebJail (требует Fail2Ban)
    if $OPT_JAIL; then
        if ! $OPT_FAIL2BAN; then
            echo "${yellow}WARNING: --jail requires --fail2ban, installing Fail2Ban first${reset}"
            setupFail2Ban
        fi
        echo -e "${cyan}━━━ WebJail ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${reset}"
        setupWebJail
    fi

    # 6. Adblock
    if $OPT_ADBLOCK; then
        echo -e "${cyan}━━━ Adblock ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${reset}"
        enableAdblock
    fi

    # 7. Privacy Mode
    if $OPT_PRIVACY; then
        echo -e "${cyan}━━━ Privacy Mode ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${reset}"
        enablePrivacyMode
    fi

    # 8. Psiphon
    if $OPT_PSIPHON; then
        local ps_country
        ps_country="${OPT_PSIPHON_COUNTRY:-DE}"
        _auto_install_psiphon "$ps_country" "$OPT_PSIPHON_WARP"
    fi

    # 9. BBR
    if $OPT_BBR; then
        echo -e "${cyan}━━━ BBR ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${reset}"
        enableBBR
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

    if $OPT_VISION; then
        echo -e "  ${cyan}Vision:${reset}"
        echo -e "    Domain : ${green}$OPT_DOMAIN${reset}"
        echo -e "    Port   : ${green}443 (direct)${reset}"
    fi

    if [ -n "$OPT_SSH_PORT" ]; then
        echo -e "  ${cyan}SSH Port:${reset} ${green}$OPT_SSH_PORT${reset}"
    fi

    if $OPT_IPV6; then
        echo -e "  ${cyan}IPv6:${reset} ${green}enabled${reset}"
    fi

    if $OPT_CPU_GUARD; then
        echo -e "  ${cyan}CPU Guard:${reset} ${green}enabled${reset}"
    fi

    if $OPT_JAIL; then
        echo -e "  ${cyan}WebJail:${reset} ${green}enabled${reset}"
    fi

    if $OPT_ADBLOCK; then
        echo -e "  ${cyan}Adblock:${reset} ${green}enabled${reset}"
    fi

    if $OPT_PRIVACY; then
        echo -e "  ${cyan}Privacy:${reset} ${green}enabled${reset}"
    fi

    if $OPT_PSIPHON; then
        local ps_country
        ps_country="${OPT_PSIPHON_COUNTRY:-DE}"
        local ps_mode
        ps_mode="$($OPT_PSIPHON_WARP && echo 'WARP+' || echo '')Psiphon"
        echo -e "  ${cyan}Psiphon:${reset} ${green}$ps_mode ($ps_country)${reset}"
    fi

    echo ""
    echo -e "  ${cyan}Run ${green}vwn${reset}${cyan} to open the management panel${reset}"
    echo -e "  ${cyan}Run ${green}vwn --help${reset}${cyan} for CLI options${reset}"
    echo -e "${green}================================================================${reset}"
    echo ""

    # Показываем QR / subscription URL
    _initUsersFile
    rebuildAllSubFiles 2>/dev/null || true
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

        _load_modules

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