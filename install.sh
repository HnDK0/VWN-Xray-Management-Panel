#!/usr/bin/env bash
# =================================================================
# install.sh — VWN Installer v2.0
# VLESS + WebSocket + TLS + Nginx + WARP + CDN + Reality
#
# РЕЖИМЫ:
#   bash install.sh                    — интерактивная установка
#   bash install.sh --update           — обновить модули и шаблоны
#   bash install.sh --auto [ОПЦИИ]     — автоматическая установка
#   bash install.sh --help             — справка
# =================================================================

set -euo pipefail
IFS=$'\n\t'

# -----------------------------------------------------------------
# ПУТИ — единственное место где они объявляются
# -----------------------------------------------------------------
readonly VWN_VERSION="2.0.0"
readonly VWN_LIB="/usr/local/lib/vwn"
readonly VWN_BIN="/usr/local/bin/vwn"
readonly VWN_CONF="/usr/local/etc/xray/vwn.conf"
readonly VWN_CONFIG_DIR="${VWN_LIB}/config"
readonly LOG_FILE="/var/log/vwn_install.log"
readonly LOCK_FILE="/tmp/vwn_install.lock"
readonly GITHUB_RAW="https://raw.githubusercontent.com/HnDK0/VLESS-WebSocket-TLS-Nginx-WARP/main"
readonly MIN_DISK_MB=1536
readonly INSTALL_TIMEOUT=900   # 15 минут

readonly MODULES="lang core xray nginx warp reality relay psiphon tor security logs backup users diag privacy adblock vision xhttp menu"
readonly CONFIGS="nginx_main.conf nginx_base.conf nginx_vision.conf nginx_stream.conf nginx_stream_ws.conf nginx_default.conf sub_map.conf xray_ws.json xray_vision.json xray_reality.json xray_xhttp.json xray-vision.service"

# Временные файлы — автоудаляются через trap
declare -a _TMPFILES=()

# -----------------------------------------------------------------
# ЗАГРУЗКА lib/ — ДО любых других действий
# Все lib/*.sh подключаются здесь и дают функции остальному коду
# -----------------------------------------------------------------
_INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_source_lib() {
    local f="${_INSTALL_DIR}/lib/${1}.sh"
    if [[ -f "$f" ]]; then
        # shellcheck disable=SC1090
        source "$f"
    else
        # lib/ может отсутствовать при первом запуске с GitHub
        # Определяем минимальный fallback встроенно
        true
    fi
}

# Подключаем все части библиотеки
# Порядок важен: colors → logging → ui → checks → system → network
_source_lib "colors"    # цветовые переменные и _init_colors()
_source_lib "logging"   # log_info/ok/warn/error, LOG_FILE
_source_lib "ui"        # step(), section(), msg(), err(), die(), ok(), info(), warn()
_source_lib "checks"    # check_root, check_disk_space, check_internet, check_repo_access
_source_lib "system"    # identifyOS, installPackage, setupSwap, fix_apt_mirrors, applySysctl
_source_lib "network"   # ufw_setup_base, ufw_allow_port, generateRandomPath, setupFail2Ban

# Если lib/ недоступен (первый запуск) — определяем минимальные встроенные функции
# которые lib/ должна была предоставить
_bootstrap_minimal() {
    # Цвета
    if ! declare -F _init_colors &>/dev/null; then
        if [[ -t 1 ]] && command -v tput &>/dev/null; then
            RED=$(tput setaf 1 2>/dev/null || true)$(tput bold 2>/dev/null || true)
            GREEN=$(tput setaf 2 2>/dev/null || true)$(tput bold 2>/dev/null || true)
            YELLOW=$(tput setaf 3 2>/dev/null || true)$(tput bold 2>/dev/null || true)
            CYAN=$(tput setaf 6 2>/dev/null || true)$(tput bold 2>/dev/null || true)
            RESET=$(tput sgr0 2>/dev/null || true)
        else
            RED='' GREEN='' YELLOW='' CYAN='' RESET=''
        fi
    else
        _init_colors
    fi

    # Логирование (если lib/logging.sh недоступна)
    if ! declare -F log_info &>/dev/null; then
        _log_to_file() { echo "[$(date '+%H:%M:%S')] [$1] $2" >> "$LOG_FILE" 2>/dev/null || true; }
        log_info()  { _log_to_file "INFO " "$*"; }
        log_ok()    { _log_to_file "OK   " "$*"; }
        log_warn()  { _log_to_file "WARN " "$*"; }
        log_error() { _log_to_file "ERROR" "$*"; }
    fi

    # UI (если lib/ui.sh недоступна)
    if ! declare -F step &>/dev/null; then
        info()  { echo -e "${CYAN}$*${RESET}";   log_info "$*"; }
        ok()    { echo -e "${GREEN}$*${RESET}";  log_ok   "$*"; }
        warn()  { echo -e "${YELLOW}$*${RESET}"; log_warn "$*"; }
        err()   { echo -e "${RED}$*${RESET}" >&2; log_error "$*"; }
        die()   { err "ОШИБКА: $*"; exit 1; }

        step() {
            local desc="$1"; shift
            printf "  %-50s" "$desc"
            log_info "STEP: $desc"
            local out; out=$("$@" 2>&1) && {
                echo -e " ${GREEN}[OK]${RESET}"; log_ok "  → OK"
            } || {
                local rc=$?; echo -e " ${RED}[FAIL]${RESET}"; log_error "  → FAIL rc=$rc: $out"; return $rc
            }
        }

        soft_step() {
            local desc="$1"; shift
            printf "  %-50s" "$desc"
            "$@" &>/dev/null && echo -e " ${GREEN}[OK]${RESET}" || echo -e " ${YELLOW}[SKIP]${RESET}"
        }

        section() {
            echo ""; echo -e "${CYAN}━━━ $* ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
            log_info "=== SECTION: $* ==="
        }

        msg() { echo "${1:-}"; }
    fi

    # identifyOS (если lib/system.sh недоступна)
    if ! declare -F identifyOS &>/dev/null; then
        identifyOS() {
            if command -v apt &>/dev/null; then
                PACKAGE_MANAGEMENT_UPDATE="apt-get update -qq"
                PACKAGE_MANAGEMENT_INSTALL="apt-get install -y -q"
                OS_FAMILY="debian"
            elif command -v dnf &>/dev/null; then
                PACKAGE_MANAGEMENT_UPDATE="dnf check-update -q || true"
                PACKAGE_MANAGEMENT_INSTALL="dnf install -y"
                OS_FAMILY="rhel"
            elif command -v yum &>/dev/null; then
                PACKAGE_MANAGEMENT_UPDATE="yum check-update -q || true"
                PACKAGE_MANAGEMENT_INSTALL="yum install -y"
                OS_FAMILY="rhel"
            else
                die "Неизвестный пакетный менеджер (нужен apt/dnf/yum)"
            fi
            export PACKAGE_MANAGEMENT_UPDATE PACKAGE_MANAGEMENT_INSTALL OS_FAMILY
        }
    fi
}
_bootstrap_minimal

# -----------------------------------------------------------------
# ИНИЦИАЛИЗАЦИЯ ЛОГА
# -----------------------------------------------------------------
_log_init() {
    mkdir -p "$(dirname "$LOG_FILE")"
    {
        echo "================================================================"
        echo "VWN Install Log v${VWN_VERSION} — $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Args: $*"
        echo "================================================================"
    } >> "$LOG_FILE" 2>/dev/null || true
}

# -----------------------------------------------------------------
# CLEANUP / TRAP
# -----------------------------------------------------------------
_cleanup() {
    local rc=${1:-$?}
    stty sane 2>/dev/null || true
    for f in "${_TMPFILES[@]+"${_TMPFILES[@]}"}"; do rm -f "$f" 2>/dev/null || true; done
    rm -f "$LOCK_FILE" 2>/dev/null || true
    find /usr/local/etc/xray /etc/nginx -name "*.tmp" -delete 2>/dev/null || true
    [[ -x "$VWN_BIN" ]] && "$VWN_BIN" close-80 2>/dev/null || true
    if (( rc != 0 )); then
        log_error "Завершено с кодом $rc"
        echo -e "\n${RED}Ошибка (код $rc). Лог: ${LOG_FILE}${RESET}" >&2
    fi
}
trap '_cleanup $?' EXIT
trap 'log_error "Прерван INT";  exit 130' INT
trap 'log_error "Прерван TERM"; exit 143' TERM

mktmp() { local f; f=$(mktemp); _TMPFILES+=("$f"); echo "$f"; }

# -----------------------------------------------------------------
# ЗАЩИТА ОТ ПАРАЛЛЕЛЬНОГО ЗАПУСКА
# -----------------------------------------------------------------
_acquire_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        local pid; pid=$(cat "$LOCK_FILE" 2>/dev/null | tr -cd '0-9')
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            die "Другой экземпляр уже запущен (PID $pid).
Если завис: kill -9 $pid && rm -f $LOCK_FILE"
        fi
        if find "$LOCK_FILE" -mmin +1 2>/dev/null | grep -q .; then
            log_warn "Удаляем зависшую блокировку"
            rm -f "$LOCK_FILE"
        fi
    fi
    echo $$ > "$LOCK_FILE"
    log_info "Lock: PID=$$"
}

# -----------------------------------------------------------------
# PREFLIGHT CHECKS (используют lib/checks.sh или встроенный fallback)
# -----------------------------------------------------------------

_check_root() {
    if declare -F check_root &>/dev/null; then
        check_root
    else
        [[ "$EUID" -eq 0 ]] || die "Запустите от root (sudo bash install.sh)"
        log_ok "Root: OK"
    fi
}

_check_os() {
    identifyOS   # из lib/system.sh или встроенная
    log_ok "OS: $OS_FAMILY"
}

_check_disk() {
    if declare -F check_disk_space &>/dev/null; then
        check_disk_space "$MIN_DISK_MB"
    else
        local free_mb; free_mb=$(df -m / | awk 'NR==2{print $4}')
        (( free_mb >= MIN_DISK_MB )) || die "Мало места: ${free_mb} МБ (нужно ${MIN_DISK_MB})"
        log_ok "Диск: ${free_mb} МБ"
    fi
}

_check_internet() {
    if declare -F check_internet &>/dev/null; then
        check_internet
    else
        curl -fsS --connect-timeout 5 -o /dev/null "https://1.1.1.1" 2>/dev/null \
            || die "Нет доступа к интернету"
        log_ok "Интернет: OK"
    fi
}

_check_repo() {
    if declare -F check_repo_access &>/dev/null; then
        check_repo_access
    else
        curl -fsS --connect-timeout 10 -o /dev/null "${GITHUB_RAW}/install.sh" 2>/dev/null \
            || warn "GitHub не отвечает, продолжаем..."
    fi
}

run_preflight_checks() {
    section "Проверка окружения"
    step "Root-права"           _check_root
    step "Определение ОС"       _check_os
    step "Свободное место"      _check_disk
    step "Интернет"             _check_internet
    soft_step "GitHub-репозиторий" _check_repo
}

# -----------------------------------------------------------------
# БАЗОВЫЕ ЗАВИСИМОСТИ (использует lib/system.sh)
# -----------------------------------------------------------------

install_base_deps() {
    section "Установка базовых зависимостей"

    # Чистим apt-локи и выбираем рабочее зеркало
    if declare -F fix_apt_mirrors &>/dev/null; then
        fix_apt_mirrors
    else
        # Встроенный минимальный вариант
        fuser -kk /var/lib/dpkg/lock* 2>/dev/null || true
        rm -f /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend /var/cache/apt/archives/lock 2>/dev/null
        dpkg --configure -a 2>/dev/null || true
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq 2>/dev/null || true
    fi

    if declare -F install_base_packages &>/dev/null; then
        # lib/system.sh предоставляет эту функцию
        install_base_packages
    else
        # Встроенный fallback
        export DEBIAN_FRONTEND=noninteractive
        step "curl jq bash coreutils cron" bash -c "
            set +o pipefail
            apt-get install -y -q \
                -o Dpkg::Lock::Timeout=60 \
                -o Dpkg::Options::='--force-confdef' \
                -o Dpkg::Options::='--force-confold' \
                curl jq bash coreutils cron 2>/dev/null || true
            set -o pipefail
        "
        soft_step "Активация cron" systemctl enable --now cron
    fi
}

# -----------------------------------------------------------------
# ЗАГРУЗКА ФАЙЛОВ С GITHUB
# -----------------------------------------------------------------

_download_file() {
    local url="$1" dest="$2"
    local tmp; tmp=$(mktmp)
    if curl -fsSL --connect-timeout 15 --max-time 30 "$url" -o "$tmp" 2>/dev/null; then
        mv "$tmp" "$dest"
        chmod 644 "$dest"
        return 0
    fi
    rm -f "$tmp"; return 1
}

_file_hash() { md5sum "$1" 2>/dev/null | awk '{print $1}'; }

download_modules() {
    section "Загрузка модулей"
    mkdir -p "$VWN_LIB"
    local updated=0 unchanged=0 failed=0

    for module in $MODULES; do
        local dest="${VWN_LIB}/${module}.sh"
        local old_hash=""; [[ -f "$dest" ]] && old_hash=$(_file_hash "$dest")
        printf "  %-20s" "${module}.sh"
        if _download_file "${GITHUB_RAW}/modules/${module}.sh" "$dest"; then
            local new_hash; new_hash=$(_file_hash "$dest")
            if [[ "$old_hash" == "$new_hash" ]]; then
                echo -e " ${YELLOW}[SAME]${RESET}";    (( unchanged++ )) || true
            else
                local ts; ts=$(stat -c '%y' "$dest" 2>/dev/null | cut -d. -f1)
                echo -e " ${GREEN}[UPDATED]${RESET} ${ts}"; (( updated++ )) || true; log_ok "Module updated: $module"
            fi
        else
            echo -e " ${RED}[FAIL]${RESET}"; log_error "Module FAIL: $module"; (( failed++ )) || true
        fi
    done

    echo -e "\n  Обновлено: ${GREEN}${updated}${RESET}  │  Без изменений: ${YELLOW}${unchanged}${RESET}  │  Ошибок: ${RED}${failed}${RESET}"
    (( failed > 0 )) && warn "Некоторые модули не загружены"
}

download_configs() {
    section "Загрузка шаблонов конфигурации"
    mkdir -p "$VWN_CONFIG_DIR"
    local updated=0 unchanged=0

    for cfg in $CONFIGS; do
        local dest="${VWN_CONFIG_DIR}/${cfg}"
        local old_hash=""; [[ -f "$dest" ]] && old_hash=$(_file_hash "$dest")
        printf "  %-42s" "$cfg"
        if _download_file "${GITHUB_RAW}/config/${cfg}" "$dest"; then
            local new_hash; new_hash=$(_file_hash "$dest")
            if [[ "$old_hash" == "$new_hash" ]]; then
                echo -e " ${YELLOW}[SAME]${RESET}";    (( unchanged++ )) || true
            else
                echo -e " ${GREEN}[UPDATED]${RESET}";  (( updated++ )) || true
            fi
        else
            echo -e " ${RED}[FAIL]${RESET}"; log_warn "Config FAIL: $cfg"
        fi
    done
    echo -e "  Конфиги: ${GREEN}${updated}${RESET} обновлено, ${YELLOW}${unchanged}${RESET} без изменений"
}

install_vwn_binary() {
    section "Установка бинарного файла vwn"
    if _download_file "${GITHUB_RAW}/vwn" "${VWN_BIN}.tmp"; then
        mv "${VWN_BIN}.tmp" "$VWN_BIN"; chmod +x "$VWN_BIN"
        log_ok "vwn binary: GitHub"
    else
        log_warn "GitHub недоступен — генерируем fallback vwn"
        _write_fallback_vwn
    fi
    ok "vwn → ${VWN_BIN}"
}

_write_fallback_vwn() {
    cat > "$VWN_BIN" << 'VWNEOF'
#!/usr/bin/env bash
set -euo pipefail
VWN_LIB="/usr/local/lib/vwn"
case "${1:-}" in
    "open-80")
        ufw status 2>/dev/null | grep -q inactive && exit 0
        ufw allow from any to any port 80 proto tcp comment 'ACME temp' &>/dev/null; exit 0 ;;
    "close-80")
        ufw status 2>/dev/null | grep -q inactive && exit 0
        ufw status numbered 2>/dev/null | grep 'ACME temp' \
            | awk -F'[][]' '{print $2}' | sort -rn \
            | while read -r n; do echo "y" | ufw delete "$n" &>/dev/null; done; exit 0 ;;
    "update")
        bash <(curl -fsSL https://raw.githubusercontent.com/HnDK0/VLESS-WebSocket-TLS-Nginx-WARP/main/install.sh) --update
        exit 0 ;;
esac
for mod in lang core xray nginx warp reality relay psiphon tor security logs backup users diag privacy adblock vision xhttp menu; do
    f="$VWN_LIB/${mod}.sh"
    [[ -f "$f" ]] && source "$f" || { echo "ERROR: module $mod not found"; exit 1; }
done
VWN_CONF="/usr/local/etc/xray/vwn.conf"
if [[ ! -f "$VWN_CONF" ]] || ! grep -q "VWN_LANG=" "$VWN_CONF" 2>/dev/null; then
    selectLang; _initLang
fi
isRoot
menu "$@"
VWNEOF
    chmod +x "$VWN_BIN"
    log_info "Fallback vwn written"
}

# -----------------------------------------------------------------
# ЗАГРУЗКА МОДУЛЕЙ В ТЕКУЩИЙ ПРОЦЕСС
# -----------------------------------------------------------------

load_modules() {
    log_info "Loading modules into current process..."
    for module in $MODULES; do
        local f="${VWN_LIB}/${module}.sh"
        if [[ -f "$f" ]]; then
            # shellcheck disable=SC1090
            source "$f"
        else
            die "Модуль не найден: $f\nПереустановите: bash install.sh"
        fi
    done
    log_ok "All modules loaded"
}

show_version() {
    grep 'VWN_VERSION=' "${VWN_LIB}/core.sh" 2>/dev/null \
        | head -1 | grep -oP '"[^"]+"' | tr -d '"' \
        || echo "unknown"
}

# -----------------------------------------------------------------
# ПАРАМЕТРЫ КОМАНДНОЙ СТРОКИ
# -----------------------------------------------------------------

UPDATE_ONLY=false
AUTO_MODE=false

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
OPT_SSH_PORT=""
OPT_JAIL=false
OPT_IPV6=false
OPT_CPU_GUARD=false
OPT_ADBLOCK=false
OPT_PRIVACY=false
OPT_PSIPHON=false
OPT_PSIPHON_COUNTRY=""
OPT_PSIPHON_WARP=false

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --update)          UPDATE_ONLY=true ;;
            --auto)            AUTO_MODE=true ;;
            --domain)          OPT_DOMAIN="${2:?'--domain требует значение'}";          shift ;;
            --stub)            OPT_STUB="${2:?'--stub требует значение'}";              shift ;;
            --port)            OPT_PORT="${2:?'--port требует значение'}";              shift ;;
            --lang)            OPT_LANG="${2:?'--lang требует значение'}";              shift ;;
            --reality)         OPT_REALITY=true ;;
            --reality-dest)    OPT_REALITY_DEST="${2:?'--reality-dest требует значение'}"; shift ;;
            --reality-port)    OPT_REALITY_PORT="${2:?'--reality-port требует значение'}"; shift ;;
            --cert-method)     OPT_CERT_METHOD="${2:?'--cert-method требует значение'}"; shift ;;
            --cf-email)        OPT_CF_EMAIL="${2:?'--cf-email требует значение'}";     shift ;;
            --cf-key)          OPT_CF_KEY="${2:?'--cf-key требует значение'}";         shift ;;
            --skip-ws)         OPT_SKIP_WS=true ;;
            --bbr)             OPT_BBR=true ;;
            --fail2ban)        OPT_FAIL2BAN=true ;;
            --no-warp)         OPT_NO_WARP=true ;;
            --stream)          OPT_STREAM=true ;;
            --vision)          OPT_VISION=true ;;
            --ssh-port)        OPT_SSH_PORT="${2:?'--ssh-port требует значение'}";     shift ;;
            --jail)            OPT_JAIL=true ;;
            --ipv6)            OPT_IPV6=true ;;
            --no-ipv6)         OPT_IPV6=false ;;
            --cpu-guard)       OPT_CPU_GUARD=true ;;
            --adblock)         OPT_ADBLOCK=true ;;
            --privacy)         OPT_PRIVACY=true ;;
            --psiphon)         OPT_PSIPHON=true ;;
            --psiphon-country) OPT_PSIPHON_COUNTRY="${2:?'--psiphon-country требует значение'}"; shift ;;
            --psiphon-warp)    OPT_PSIPHON_WARP=true ;;
            --help|-h)         _show_help; exit 0 ;;
            *)                 warn "Неизвестный аргумент: $1" ;;
        esac
        shift
    done
}

_show_help() {
    cat << 'HELPEOF'

VWN Installer v2.0  (VLESS + WARP + CDN + Reality)
===================================================

РЕЖИМЫ:
  bash install.sh                         Интерактивная установка
  bash install.sh --update                Обновить модули и шаблоны
  bash install.sh --auto [ОПЦИИ]          Автоматическая установка
  bash install.sh --help                  Эта справка

ОПЦИИ (--auto):
  --domain      ДОМЕН        CDN-домен VLESS+WS+TLS     [обязателен]
  --stub        URL          URL сайта-заглушки          [httpbin.org]
  --port        ПОРТ         Внутренний порт Xray        [16500]
  --lang        ru|en        Язык                        [ru]
  --reality                  Установить Reality
  --reality-dest ХОСТ:ПОРТ   SNI для Reality             [microsoft.com:443]
  --reality-port ПОРТ        Порт Reality                [8443]
  --cert-method cf|standalone Метод SSL                  [standalone]
  --cf-email    EMAIL        Email Cloudflare
  --cf-key      КЛЮЧ         API Key Cloudflare
  --skip-ws                  Пропустить WS (только Reality)
  --ssh-port    ПОРТ         Сменить порт SSH
  --ipv6                     Включить IPv6
  --cpu-guard                CPU Guard
  --bbr                      TCP BBR
  --fail2ban                 Fail2Ban
  --jail                     WebJail (требует --fail2ban)
  --adblock                  Блокировка рекламы
  --privacy                  Режим приватности
  --psiphon                  Psiphon
  --psiphon-country КОД      Страна Psiphon (DE, NL, US...)
  --psiphon-warp             Psiphon через WARP
  --no-warp                  Без WARP
  --stream                   Stream SNI
  --vision                   Vision (прямо на 443)

ПРИМЕРЫ:
  bash install.sh --auto --domain vpn.example.com

  bash install.sh --auto \
    --domain vpn.example.com \
    --cert-method cf --cf-email me@me.com --cf-key AbCd1234 \
    --reality --bbr --fail2ban

ЛОГИ: /var/log/vwn_install.log
HELPEOF
}

# -----------------------------------------------------------------
# ВАЛИДАЦИЯ ПАРАМЕТРОВ --auto
# -----------------------------------------------------------------

_validate_port() {
    local val="$1" min="$2" max="$3" name="$4"
    [[ "$val" =~ ^[0-9]+$ ]] && (( val >= min && val <= max )) \
        || die "${name}: '${val}' не в диапазоне ${min}-${max}"
}

validate_auto_params() {
    ! $OPT_SKIP_WS && [[ -z "$OPT_DOMAIN" ]] \
        && die "--domain обязателен (или --skip-ws для режима только-Reality)"

    [[ "$OPT_CERT_METHOD" == "cf" ]] && {
        [[ -z "$OPT_CF_EMAIL" ]] && die "--cf-email обязателен при --cert-method cf"
        [[ -z "$OPT_CF_KEY" ]]   && die "--cf-key обязателен при --cert-method cf"
    }

    $OPT_VISION && $OPT_SKIP_WS && die "--vision несовместим с --skip-ws"
    $OPT_VISION && $OPT_STREAM  && die "--vision и --stream взаимоисключающие"

    [[ "$OPT_CERT_METHOD" != "cf" && "$OPT_CERT_METHOD" != "standalone" ]] \
        && die "--cert-method должен быть 'cf' или 'standalone'"

    _validate_port "$OPT_PORT"         1024  65535 "--port"
    _validate_port "$OPT_REALITY_PORT"  443  65535 "--reality-port"
    [[ -n "$OPT_SSH_PORT" ]] && _validate_port "$OPT_SSH_PORT" 1 65535 "--ssh-port"

    if $OPT_PSIPHON && [[ -n "$OPT_PSIPHON_COUNTRY" ]]; then
        [[ "$OPT_PSIPHON_COUNTRY" =~ ^[A-Za-z]{2}$ ]] \
            || die "--psiphon-country: 2-буквенный код (DE, NL, US...)"
        OPT_PSIPHON_COUNTRY="${OPT_PSIPHON_COUNTRY^^}"
    fi

    $OPT_PSIPHON_WARP && $OPT_NO_WARP \
        && die "--psiphon-warp несовместим с --no-warp"

    log_ok "Параметры validated"
}

# -----------------------------------------------------------------
# ОТОБРАЖЕНИЕ ПАРАМЕТРОВ --auto (использует lib/ui.sh)
# -----------------------------------------------------------------

print_auto_params() {
    local mode=""
    $OPT_SKIP_WS && mode="Reality only" || mode="WS+TLS+CDN"
    $OPT_REALITY  && mode+=" + Reality"
    $OPT_VISION   && mode+=" + Vision"
    $OPT_STREAM && ! $OPT_VISION && mode+=" + Stream SNI"

    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "   Параметры установки:"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"

    _p() { printf "  ${CYAN}%-14s${RESET}: ${GREEN}%s${RESET}\n" "$1" "$2"; }

    _p "Режим"       "$mode"
    [[ -n "$OPT_DOMAIN" ]]        && _p "Домен"          "$OPT_DOMAIN"
    ! $OPT_SKIP_WS                && _p "Stub URL"        "$OPT_STUB"
    ! $OPT_SKIP_WS                && _p "Xray port"       "$OPT_PORT"
    ! $OPT_SKIP_WS                && _p "SSL метод"       "$OPT_CERT_METHOD"
    $OPT_REALITY                  && _p "Reality"         "$OPT_REALITY_DEST  port=$OPT_REALITY_PORT"
    $OPT_VISION                   && _p "Vision"          "$OPT_DOMAIN"
    $OPT_STREAM && ! $OPT_VISION  && _p "Stream SNI"      "enabled"
    [[ -n "$OPT_SSH_PORT" ]]      && _p "SSH порт"        "$OPT_SSH_PORT"
    $OPT_IPV6                     && _p "IPv6"            "enabled"
    $OPT_CPU_GUARD                && _p "CPU Guard"       "enabled"
    $OPT_FAIL2BAN                 && _p "Fail2Ban"        "enabled"
    $OPT_JAIL                     && _p "WebJail"         "enabled"
    $OPT_ADBLOCK                  && _p "Adblock"         "enabled"
    $OPT_PRIVACY                  && _p "Privacy"         "enabled"
    $OPT_PSIPHON                  && _p "Psiphon"         "enabled${OPT_PSIPHON_COUNTRY:+ ($OPT_PSIPHON_COUNTRY)}${OPT_PSIPHON_WARP:+ +WARP}"
    $OPT_BBR                      && _p "BBR"             "enabled"
    $OPT_NO_WARP                  && _p "WARP"            "SKIPPED"
    _p "Язык"        "$OPT_LANG"

    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""
}

# -----------------------------------------------------------------
# УСТАНОВКА КОМПОНЕНТОВ (вызывают функции из загруженных modules/)
# -----------------------------------------------------------------

_auto_ssl() {
    local domain="$1"
    log_info "SSL: domain=$domain method=$OPT_CERT_METHOD"

    # Функции из modules/nginx.sh
    soft_step "socat"        installPackage socat

    if [[ ! -f ~/.acme.sh/acme.sh ]]; then
        step "acme.sh установка" bash -c "
            curl -fsSL https://get.acme.sh | sh -s email='acme@${domain}' --no-profile
        "
    fi
    [[ -f ~/.acme.sh/acme.sh ]] || die "acme.sh не установлен"

    soft_step "acme.sh upgrade"  ~/.acme.sh/acme.sh --upgrade --auto-upgrade
    soft_step "acme.sh CA"       ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
    mkdir -p /etc/nginx/cert

    if [[ "$OPT_CERT_METHOD" == "cf" ]]; then
        printf 'export CF_Email=%q\nexport CF_Key=%q\n' "$OPT_CF_EMAIL" "$OPT_CF_KEY" \
            > /root/.cloudflare_api
        chmod 600 /root/.cloudflare_api
        export CF_Email="$OPT_CF_EMAIL" CF_Key="$OPT_CF_KEY"
        step "SSL (Cloudflare DNS-01)" \
            ~/.acme.sh/acme.sh --issue --dns dns_cf -d "$domain" --force
    else
        # HTTP-01: открываем 80 через vwn binary
        soft_step "UFW: 80 для ACME" ufw allow 80/tcp comment 'ACME temp'
        step "SSL (HTTP-01 standalone)" \
            ~/.acme.sh/acme.sh --issue --standalone -d "$domain" \
                --pre-hook  "$VWN_BIN open-80" \
                --post-hook "$VWN_BIN close-80" \
                --force
        ufw status numbered 2>/dev/null | grep 'ACME temp' \
            | awk -F'[][]' '{print $2}' | sort -rn \
            | while read -r n; do echo "y" | ufw delete "$n" &>/dev/null || true; done
    fi

    step "Установка сертификата" \
        ~/.acme.sh/acme.sh --install-cert -d "$domain" \
            --key-file       /etc/nginx/cert/cert.key \
            --fullchain-file /etc/nginx/cert/cert.pem \
            --reloadcmd      "systemctl restart nginx 2>/dev/null || true"

    ok "SSL для $domain получен"
}

_auto_install_ws() {
    section "WS + TLS + Nginx + CDN"

    # UFW (использует lib/network.sh или модуль security.sh)
    step "UFW: SSH + HTTPS" bash -c "
        ufw allow 22/tcp   comment 'SSH'   &>/dev/null || true
        ufw allow 443/tcp  comment 'HTTPS' &>/dev/null || true
        ufw allow 443/udp  comment 'HTTPS' &>/dev/null || true
        echo 'y' | ufw enable &>/dev/null  || true
    "

    # Из modules/security.sh (загружены через load_modules)
    step "Sysctl оптимизация"   applySysctl
    step "Системный DNS"        setupSystemDNS

    local ws_path; ws_path=$(generateRandomPath)   # из modules/core.sh
    log_info "WS path: $ws_path"

    step "Xray конфиг"          writeXrayConfig "$OPT_PORT" "$ws_path" "$OPT_DOMAIN"
    mkdir -p /usr/local/etc/xray
    echo "$OPT_DOMAIN" > /usr/local/etc/xray/connect_host

    step "Nginx конфиг (base)"  writeNginxConfigBase "$OPT_PORT" "$OPT_DOMAIN" "$OPT_STUB" "$ws_path"
    soft_step "Nginx enable"    systemctl enable nginx

    if ! $OPT_NO_WARP; then
        soft_step "WARP настройка"  configWarp
    else
        info "WARP пропущен (--no-warp)"
    fi

    step "SSL ($OPT_CERT_METHOD)" _auto_ssl "$OPT_DOMAIN"

    soft_step "WARP домены"     applyWarpDomains
    soft_step "Log rotate"      setupLogrotate
    soft_step "Log cron"        setupLogClearCron
    soft_step "SSL cron"        setupSslCron

    step "Xray enable"          systemctl enable xray
    soft_step "Xray restart"    systemctl restart xray
    step "Nginx restart"        systemctl restart nginx

    ok "WS+TLS установлен"
}

_auto_install_reality() {
    section "Reality"

    # Убеждаемся что xray есть
    local xray_bin=""
    for _b in /usr/local/bin/xray /usr/bin/xray; do
        [[ -x "$_b" ]] && xray_bin="$_b" && break
    done
    [[ -z "$xray_bin" ]] && step "Установка Xray" installXray

    soft_step "UFW: Reality порт" ufw allow "$OPT_REALITY_PORT"/tcp comment 'Xray Reality'
    step "Reality конфиг"       writeRealityConfig "$OPT_REALITY_PORT" "$OPT_REALITY_DEST"
    step "Reality сервис"       setupRealityService

    if ! $OPT_NO_WARP && [[ -f "${warpDomainsFile:-/usr/local/etc/xray/warp_domains.txt}" ]]; then
        soft_step "WARP домены" applyWarpDomains
    fi

    ok "Reality: порт=$OPT_REALITY_PORT  SNI=$OPT_REALITY_DEST"
}

_auto_install_vision() {
    section "Vision"
    # Конфликт со Stream SNI — отключаем
    if grep -q "ssl_preread on" /etc/nginx/nginx.conf 2>/dev/null; then
        info "Stream SNI активен — отключаем (несовместим с Vision)..."
        step "Отключение Stream SNI" _doDisableStreamSNI
    fi
    step "Vision" installVision --auto
    ok "Vision: домен=$OPT_DOMAIN"
}

_auto_change_ssh_port() {
    local new_port="$1"
    local old_port; old_port=$(grep -E "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1)
    old_port="${old_port:-22}"
    info "SSH: $old_port → $new_port"
    soft_step "UFW: новый SSH порт"  ufw allow "$new_port"/tcp comment 'SSH'
    step "sshd_config"               sed -i "s/^#\?Port [0-9]*/Port $new_port/" /etc/ssh/sshd_config
    step "Перезапуск sshd"           bash -c "systemctl restart sshd 2>/dev/null || systemctl restart ssh"
    # Если fail2ban работает — обновляем порт (используем функцию из modules/security.sh)
    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        # changeSshPort из security.sh обновляет fail2ban
        soft_step "Fail2Ban: обновление SSH" bash -c "
            sed -i 's/^port\s*=.*/port     = $new_port/' /etc/fail2ban/jail.local 2>/dev/null || true
            systemctl restart fail2ban
        "
    fi
    ok "SSH порт изменён на $new_port"
}

_auto_install_psiphon() {
    section "Psiphon"
    local country="${OPT_PSIPHON_COUNTRY:-DE}"
    local tunnel_mode="plain"

    step "Psiphon бинарь" installPsiphonBinary

    if $OPT_PSIPHON_WARP \
        && systemctl is-active --quiet warp-svc 2>/dev/null \
        && ss -tlnp 2>/dev/null | grep -q ':40000'; then
        tunnel_mode="warp"
    fi

    step "Psiphon конфиг" writePsiphonConfig "$country" "$tunnel_mode"
    step "Psiphon сервис" setupPsiphonService
    soft_step "Psiphon outbound" applyPsiphonOutbound

    if [[ -f "${psiphonDomainsFile:-}" && -s "${psiphonDomainsFile}" ]]; then
        soft_step "Psiphon домены" applyPsiphonDomains
    fi

    ok "Psiphon: страна=$country, режим=$tunnel_mode"
}

_auto_toggle_ipv6() {
    local current; current=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo "0")
    if [[ "$current" == "1" ]]; then
        # Используем toggleIPv6 из modules/security.sh
        step "Включение IPv6" toggleIPv6
    else
        info "IPv6 уже включён, пропускаем"
    fi
}

# -----------------------------------------------------------------
# ГЛАВНАЯ ФУНКЦИЯ АВТО-РЕЖИМА
# -----------------------------------------------------------------

run_auto() {
    echo -e "${CYAN}════════════════════════════════════════════════════════════════${RESET}"
    echo -e "   VWN — Автоматическая установка"
    echo -e "${CYAN}════════════════════════════════════════════════════════════════${RESET}"

    validate_auto_params
    print_auto_params
    load_modules   # подключаем modules/*.sh

    # Сохраняем язык через vwn_conf_set из modules/core.sh
    mkdir -p "$(dirname "$VWN_CONF")"
    vwn_conf_set "VWN_LANG" "$OPT_LANG"
    _initLang

    # ── Системные пакеты ──────────────────────────────────────────
    section "Системные пакеты"
    identifyOS
    prepareApt   # из modules/core.sh
    soft_step "Swap"  setupSwap

    export DEBIAN_FRONTEND=noninteractive
    info "Обновление списков пакетов..."
    timeout 60 bash -c "${PACKAGE_MANAGEMENT_UPDATE}" >/dev/null 2>&1 || true

    for pkg in tar gpg unzip jq nano ufw socat curl qrencode python3; do
        soft_step "Установка $pkg"  installPackage "$pkg"
    done

    step "Xray-core"  installXray

    if ! $OPT_NO_WARP; then
        soft_step "Cloudflare WARP"  installWarp
    fi

    if ! $OPT_SKIP_WS; then
        soft_step "Nginx mainline"  _installNginxMainline \
            || soft_step "Nginx (fallback)"  installPackage nginx
    fi

    # ── WS ────────────────────────────────────────────────────────
    if ! $OPT_SKIP_WS; then
        set +e
        _auto_install_ws; local _ws_rc=$?
        set -e
        (( _ws_rc != 0 )) && warn "WS завершился с ошибкой (rc=$_ws_rc), продолжаем..."
    else
        info "WS пропущен (--skip-ws)"
        soft_step "UFW SSH" bash -c "ufw allow 22/tcp comment 'SSH' &>/dev/null && echo 'y' | ufw enable &>/dev/null"
        soft_step "Sysctl"  applySysctl
        ! $OPT_NO_WARP && soft_step "WARP" configWarp
    fi

    # ── Reality ───────────────────────────────────────────────────
    $OPT_REALITY && _auto_install_reality

    # ── Stream SNI ────────────────────────────────────────────────
    if $OPT_STREAM && ! $OPT_VISION; then
        section "Stream SNI"
        soft_step "Stream SNI" setupStreamSNI 7443 10443
    fi

    # ── Vision ────────────────────────────────────────────────────
    if $OPT_VISION; then
        set +e; _auto_install_vision; local _v_rc=$?; set -e
        (( _v_rc != 0 )) && warn "Vision завершился с ошибкой, продолжаем..."
    fi

    # ── Опциональные компоненты (порядок важен!) ──────────────────

    # 1. SSH порт (до fail2ban)
    [[ -n "$OPT_SSH_PORT" ]] && _auto_change_ssh_port "$OPT_SSH_PORT"

    # 2. IPv6
    if $OPT_IPV6; then
        section "IPv6"
        _auto_toggle_ipv6
    fi

    # 3. CPU Guard — из modules/security.sh
    if $OPT_CPU_GUARD; then
        section "CPU Guard"
        step "CPU Guard" setupCpuGuard
    fi

    # 4. Fail2Ban — из modules/security.sh
    if $OPT_FAIL2BAN; then
        section "Fail2Ban"
        step "Fail2Ban" setupFail2Ban
    fi

    # 5. WebJail (требует fail2ban) — из modules/security.sh
    if $OPT_JAIL; then
        section "WebJail"
        if ! $OPT_FAIL2BAN; then
            warn "--jail требует Fail2Ban, устанавливаем..."
            step "Fail2Ban (для jail)" setupFail2Ban
        fi
        step "WebJail" setupWebJail
    fi

    # 6. Adblock — из modules/adblock.sh
    if $OPT_ADBLOCK; then
        section "Adblock"
        step "Adblock" enableAdblock
    fi

    # 7. Privacy — из modules/privacy.sh
    if $OPT_PRIVACY; then
        section "Privacy Mode"
        step "Privacy Mode" enablePrivacyMode
    fi

    # 8. Psiphon — из modules/psiphon.sh
    $OPT_PSIPHON && _auto_install_psiphon

    # 9. BBR (последним) — из modules/security.sh
    if $OPT_BBR; then
        section "BBR TCP"
        step "BBR" enableBBR
    fi

    _print_summary
}

_print_summary() {
    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════════════════${RESET}"
    echo -e "   Установка завершена!"
    echo -e "${GREEN}════════════════════════════════════════════════════════════════${RESET}"
    echo ""

    ! $OPT_SKIP_WS && {
        echo -e "  ${CYAN}VLESS WS+TLS:${RESET}"
        echo -e "    Домен  : ${GREEN}$OPT_DOMAIN${RESET}"
        echo -e "    Порт   : 443 (CDN) → $OPT_PORT (Xray)"
    }
    $OPT_REALITY  && echo -e "  ${CYAN}Reality:${RESET}  порт=${GREEN}$OPT_REALITY_PORT${RESET}  SNI=${GREEN}$OPT_REALITY_DEST${RESET}"
    $OPT_VISION   && echo -e "  ${CYAN}Vision:${RESET}   домен=${GREEN}$OPT_DOMAIN${RESET}  443 (direct)"
    [[ -n "$OPT_SSH_PORT" ]] && echo -e "  ${CYAN}SSH:${RESET}      порт=${GREEN}$OPT_SSH_PORT${RESET}"
    $OPT_IPV6      && echo -e "  ${CYAN}IPv6:${RESET}     ${GREEN}enabled${RESET}"
    $OPT_CPU_GUARD && echo -e "  ${CYAN}CPU Guard:${RESET} ${GREEN}enabled${RESET}"
    $OPT_FAIL2BAN  && echo -e "  ${CYAN}Fail2Ban:${RESET} ${GREEN}enabled${RESET}"
    $OPT_JAIL      && echo -e "  ${CYAN}WebJail:${RESET}  ${GREEN}enabled${RESET}"
    $OPT_ADBLOCK   && echo -e "  ${CYAN}Adblock:${RESET}  ${GREEN}enabled${RESET}"
    $OPT_PRIVACY   && echo -e "  ${CYAN}Privacy:${RESET}  ${GREEN}enabled${RESET}"
    $OPT_PSIPHON   && echo -e "  ${CYAN}Psiphon:${RESET}  ${GREEN}${OPT_PSIPHON_COUNTRY:-DE}${RESET}"
    $OPT_BBR       && echo -e "  ${CYAN}BBR:${RESET}      ${GREEN}enabled${RESET}"

    echo ""
    echo -e "  ${CYAN}Управление: ${GREEN}vwn${RESET}"
    echo -e "  ${CYAN}Лог: ${YELLOW}${LOG_FILE}${RESET}"
    echo -e "${GREEN}════════════════════════════════════════════════════════════════${RESET}"
    echo ""

    # Показываем QR — из modules/xray.sh и modules/users.sh
    soft_step "Генерация подписки" bash -c "
        _initUsersFile 2>/dev/null || true
        rebuildAllSubFiles 2>/dev/null || true
        getQrCode 2>/dev/null || true
    "
    log_ok "Installation complete"
}

# -----------------------------------------------------------------
# ОСНОВНОЙ КОД
# -----------------------------------------------------------------

main() {
    _log_init "$@"
    log_info "VWN Installer v${VWN_VERSION} started"

    parse_args "$@"

    # Защита от параллельного запуска
    [[ -z "${VWN_INSTALL_PARENT:-}" ]] && _acquire_lock

    # Запускаем себя под таймаутом (только при первом вызове)
    if [[ -z "${VWN_INSTALL_PARENT:-}" ]]; then
        export VWN_INSTALL_PARENT=1
        timeout --foreground "$INSTALL_TIMEOUT" bash "$0" "$@"
        exit $?
    fi

    # ── Отсюда — под таймаутом ────────────────────────────────────

    _check_root
    _check_os

    echo ""
    echo -e "${CYAN}════════════════════════════════════════════════════════════════${RESET}"
    if   $UPDATE_ONLY; then echo -e "   VWN — Обновление модулей"
    elif $AUTO_MODE;   then echo -e "   VWN — Автоматическая установка"
    else                    echo -e "   VWN v${VWN_VERSION} — VLESS + WARP + CDN + Reality"
    fi
    echo -e "${CYAN}════════════════════════════════════════════════════════════════${RESET}"
    echo ""

    install_base_deps   # использует lib/system.sh

    if $UPDATE_ONLY; then
        # ── Режим обновления ───────────────────────────────────
        info "Обновление модулей (конфиги не затрагиваются)..."
        download_modules
        download_configs
        [[ -f "${VWN_LIB}/lang.sh" ]] && { source "${VWN_LIB}/lang.sh"; _initLang; }
        install_vwn_binary
        echo ""; ok "Обновление завершено. Версия: $(show_version)"
        echo -e "  Запустите ${GREEN}vwn${RESET}"

    elif $AUTO_MODE; then
        # ── Автоматический режим ───────────────────────────────
        run_preflight_checks
        download_modules
        download_configs
        install_vwn_binary
        run_auto

    else
        # ── Интерактивный режим ────────────────────────────────
        run_preflight_checks
        download_modules
        download_configs

        if [[ -f "${VWN_LIB}/lang.sh" ]]; then
            source "${VWN_LIB}/lang.sh"
            selectLang
            _initLang
        fi

        install_vwn_binary
        load_modules

        echo ""
        ok "════════════════════════════════════════════════════════════════"
        ok "   Модули установлены → ${VWN_LIB}"
        ok "   Версия: $(show_version)"
        ok "════════════════════════════════════════════════════════════════"
        echo ""
        info "Запуск меню управления..."
        sleep 1
        exec "$VWN_BIN"
    fi
}

main "$@"
