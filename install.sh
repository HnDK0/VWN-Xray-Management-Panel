#!/usr/bin/env bash
# =================================================================
# install.sh — VWN Installer v2.1
# VLESS + WebSocket + TLS + Nginx + WARP + CDN + Reality
#
# РЕЖИМЫ:
#   bash install.sh                    — интерактивная установка
#   bash install.sh --update           — обновить модули и шаблоны
#   bash install.sh --auto [ОПЦИИ]     — автоматическая установка
#   bash install.sh --help             — справка по --auto
#
# АРХИТЕКТУРА:
#   install.sh         — самодостаточный файл (bootstrap встроен)
#   modules/*.sh       — вся логика VPN-стека (загружаются с GitHub)
#   config/*           — шаблоны конфигурации (загружаются с GitHub)
#
# Запуск:
#   bash install.sh [ОПЦИИ]
#   bash <(curl -fsSL https://raw.githubusercontent.com/HnDK0/VWN-Xray-Management-Panel/main/install.sh) [ОПЦИИ]
# =================================================================

# -----------------------------------------------------------------
# СТРОГИЙ РЕЖИМ
# ВАЖНО: IFS НЕ переопределяется глобально.
# Причина: modules/*.sh написаны для IFS=' ' (пробел-разделитель).
# Глобальный IFS=$'\n\t' сломал бы все space-separated циклы
# в модулях после load_modules().
# -----------------------------------------------------------------
set -euo pipefail

# -----------------------------------------------------------------
# КОНСТАНТЫ УСТАНОВЩИКА
# Правило: readonly только для тех переменных, которые modules/ НЕ трогают.
# modules/lang.sh и modules/core.sh переопределяют:
#   VWN_CONF, VWN_LIB, VWN_VERSION, VWN_CONFIG_DIR
# — поэтому они НЕ readonly здесь.
# -----------------------------------------------------------------
readonly VWN_INSTALLER_VERSION="2.1.0"
readonly VWN_GITHUB_RAW="https://raw.githubusercontent.com/HnDK0/VWN-Xray-Management-Panel/main"
readonly VWN_MIN_DISK_MB=1536
readonly VWN_LOCK_FILE="/tmp/vwn_install.lock"

# Эти переменные нужны до загрузки модулей И используются модулями —
# объявляем как обычные (не readonly), чтобы modules/core.sh и lang.sh
# могли их переопределить без ошибки "readonly variable"
LOG_FILE="/var/log/vwn_install.log"
VWN_LIB="/usr/local/lib/vwn"
VWN_BIN="/usr/local/bin/vwn"
VWN_CONF="/usr/local/etc/xray/vwn.conf"
VWN_CONFIG_DIR="${VWN_LIB}/config"
export LOG_FILE VWN_LIB VWN_BIN VWN_CONF VWN_CONFIG_DIR

# Массивы — правильный способ хранить списки в bash.
# Причина не использовать строки: IFS=$'\n\t' (если бы был) ломает
# итерацию; массивы работают корректно при любом IFS.
VWN_MODULES=(lang core xray nginx warp reality relay psiphon tor security logs backup users diag privacy adblock xhttp menu)
VWN_CONFIGS=(nginx_main.conf nginx_base.conf nginx_default.conf sub_map.conf xray_ws.json xray_reality.json xray_xhttp.json)

# Временные файлы — удаляются через trap
_TMPFILES=()

# =================================================================
# BOOTSTRAP — встроен напрямую (работает и при bash <(curl ...) )
# =================================================================

# ── bootstrap.sh ─────────────────────────────────────────────────
_bootstrap_init_colors() {
    if [[ -t 1 ]] && command -v tput; then
        RED=$(tput setaf 1; tput bold) || RED=''
        GREEN=$(tput setaf 2; tput bold) || GREEN=''
        YELLOW=$(tput setaf 3; tput bold) || YELLOW=''
        CYAN=$(tput setaf 6; tput bold) || CYAN=''
        RESET=$(tput sgr0) || RESET=''
    else
        RED='' GREEN='' YELLOW='' CYAN='' RESET=''
    fi

    # Lowercase-алиасы — для совместимости с modules/*.sh
    # (lang.sh, core.sh, security.sh и др. используют $red/$green/$reset)
    red="$RED"; green="$GREEN"; yellow="$YELLOW"
    cyan="$CYAN"; reset="$RESET"

    export RED GREEN YELLOW CYAN RESET
    export red green yellow cyan reset
}
_bootstrap_init_colors

# -----------------------------------------------------------------
# ЛОГИРОВАНИЕ — единственное место записи в лог
# LOG_FILE передаётся из install.sh как обычная переменная (не readonly)
# -----------------------------------------------------------------
_log() {
    local level="$1"; shift
    local ts; ts=$(date '+%H:%M:%S' || echo '??:??:??')
    printf '[%s] [%-5s] %s\n' "$ts" "$level" "$*" >> "${LOG_FILE:-/var/log/vwn_install.log}" || true
}

log_info()  { _log "INFO " "$@"; }
log_ok()    { _log "OK   " "$@"; }
log_warn()  { _log "WARN " "$@"; }
log_error() { _log "ERROR" "$@"; }

# -----------------------------------------------------------------
# ВЫВОД — с одновременной записью в лог
# -----------------------------------------------------------------
info()  { echo -e "${CYAN}$*${RESET}";   log_info  "$*"; }
ok()    { echo -e "${GREEN}$*${RESET}";  log_ok    "$*"; }
warn()  { echo -e "${YELLOW}$*${RESET}"; log_warn  "$*"; }
err()   { echo -e "${RED}$*${RESET}" >&2; log_error "$*"; }
die()   { err "ОШИБКА: $*"; exit 1; }

# -----------------------------------------------------------------
# STEP — запускает команду с индикатором [OK] / [FAIL]
# Используется только в install.sh. После load_modules() модули
# используют свой run_task() с другим форматом — это ОК, они
# работают в своём контексте (интерактивное меню).
# -----------------------------------------------------------------

# Печатает строку с выравниванием до col символов, учитывая UTF-8
_print_padded() {
    local text="$1" col="${2:-52}"
    local vis_len
    vis_len=$(python3 -c "
import sys, unicodedata
s = sys.argv[1]
w = sum(2 if unicodedata.east_asian_width(c) in ('W','F') else 1 for c in s)
print(w)
" "$text") || vis_len=${#text}
    printf "  %s" "$text"
    local pad=$(( col - vis_len ))
    [ "$pad" -gt 0 ] && printf '%*s' "$pad" ''
}

step() {
    local desc="$1"; shift
    _print_padded "$desc"
    log_info "STEP: ${desc}"

    local output rc=0
    output=$("$@" 2>&1) || rc=$?

    if (( rc == 0 )); then
        echo -e " ${GREEN}[OK]${RESET}"
        log_ok "  → OK"
    else
        echo -e " ${RED}[FAIL]${RESET}"
        log_error "  → FAIL rc=${rc}: ${output}"
        return $rc
    fi
}

# Non-fatal вариант — SKIP вместо FAIL
soft_step() {
    local desc="$1"; shift
    _print_padded "$desc"
    log_info "SOFT: ${desc}"

    if "$@"; then
        echo -e " ${GREEN}[OK]${RESET}"
        log_ok "  → OK"
    else
        echo -e " ${YELLOW}[SKIP]${RESET}"
        log_warn "  → SKIP (non-fatal)"
    fi
}

# -----------------------------------------------------------------
# SECTION — визуальный разделитель этапов
# -----------------------------------------------------------------
section() {
    echo ""
    echo -e "${CYAN}━━━ $* ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    log_info "=== SECTION: $* ==="
}

# -----------------------------------------------------------------
# MSG — fallback до загрузки modules/lang.sh
# После load_modules() → _initLang() заполняет MSG[] и msg() из
# modules/lang.sh начинает работать нормально.
# ВАЖНО: мы НЕ переопределяем msg() после load_modules — lang.sh
# делает это сам через объявление функции поверх нашей.
# -----------------------------------------------------------------
msg() {
    # Если lang.sh уже загружен и заполнил MSG[] — используем его
    if declare -p MSG 2>&1 && [[ -n "${MSG[${1:-}]+x}" ]]; then
        echo "${MSG[$1]}"
        return
    fi

    # Fallback-таблица (минимум для фазы bootstrap)
    case "${1:-}" in
        run_as_root)      echo "Run as root!" ;;
        os_unsupported)   echo "Only apt/dnf/yum systems supported." ;;
        install_deps)     echo "Installing dependencies..." ;;
        install_modules)  echo "Downloading modules..." ;;
        install_vwn)      echo "Installing vwn binary..." ;;
        install_title)    echo "VWN — Xray VLESS + WARP + CDN + Reality" ;;
        update_title)     echo "VWN — Updating modules" ;;
        update_done)      echo "Update complete! Version" ;;
        install_done)     echo "Modules installed in" ;;
        install_version)  echo "Version" ;;
        launching_menu)   echo "Launching setup menu..." ;;
        module_fail)      echo "Failed to download" ;;
        auto_done)        echo "Unattended installation complete!" ;;
        run_vwn)          echo "Run: vwn" ;;
        yes_no)           echo "(y/n)" ;;
        press_enter)      echo "Press Enter..." ;;
        choose)           echo "Choice: " ;;
        back)             echo "Back" ;;
        cancel)           echo "Cancelled." ;;
        done)             echo "Done." ;;
        error)            echo "Error" ;;
        invalid)          echo "Invalid input!" ;;
        invalid_port)     echo "Invalid port." ;;
        no_logs)          echo "No logs" ;;
        restarted)        echo "Restarted." ;;
        removed)          echo "Removed." ;;
        swap_creating)    echo "Creating swap file" ;;
        swap_created)     echo "Swap created:" ;;
        swap_fail)        echo "Swap creation failed, continuing..." ;;
        installed_in)     echo "installed in" ;;
        *)                echo "${1:-}" ;;
    esac
}

# ── preflight.sh ─────────────────────────────────────────────────
check_root() {
    [[ "$EUID" -eq 0 ]] || die "Запустите от имени root (sudo bash install.sh)"
    log_ok "Root: EUID=$EUID"
}

# -----------------------------------------------------------------
# ОС — определяет PKG_MGR для использования внутри preflight
# НЕ устанавливает PACKAGE_MANAGEMENT_* — это делает modules/core.sh::identifyOS()
# -----------------------------------------------------------------
check_os() {
    if command -v apt; then
        PKG_MGR="apt"
    elif command -v dnf; then
        PKG_MGR="dnf"
    elif command -v yum; then
        PKG_MGR="yum"
    else
        die "Поддерживаются только системы с apt / dnf / yum"
    fi
    export PKG_MGR
    log_ok "OS check: PKG_MGR=$PKG_MGR"
}

# -----------------------------------------------------------------
# Свободное место
# -----------------------------------------------------------------
check_disk_space() {
    local required="${1:-1536}"
    local free_mb; free_mb=$(df -m / | awk 'NR==2{print $4}')
    (( free_mb >= required )) \
        || die "Мало места: ${free_mb} МБ (нужно минимум ${required} МБ)"
    log_ok "Диск: ${free_mb} МБ свободно"
}

# -----------------------------------------------------------------
# Интернет
# -----------------------------------------------------------------
check_internet() {
    local ok=false
    local hosts=(1.1.1.1 8.8.8.8 github.com)
    for h in "${hosts[@]}"; do
        if curl -fsS --connect-timeout 5 --max-time 8 \
                -o /dev/null "https://${h}"; then
            ok=true; break
        fi
    done
    $ok || die "Нет доступа к интернету. Проверьте сетевые настройки."
    log_ok "Интернет: OK"
}

# -----------------------------------------------------------------
# GitHub репозиторий
# -----------------------------------------------------------------
check_repo_access() {
    local url="${VWN_GITHUB_RAW}/install.sh"
    if curl -fsS --connect-timeout 10 --max-time 15 \
            -o /dev/null "$url"; then
        log_ok "GitHub: OK"
        return 0
    fi
    log_warn "GitHub недоступен напрямую: $url"
    return 1
}

# -----------------------------------------------------------------
# Запуск всех проверок перед установкой
# -----------------------------------------------------------------
run_preflight_checks() {
    section "Проверка окружения"
    step     "Root-права"              check_root
    step     "Определение ОС"          check_os
    step     "Свободное место (≥1.5 ГБ)" check_disk_space "$VWN_MIN_DISK_MB"
    step     "Интернет"                check_internet
    soft_step "GitHub-репозиторий"     check_repo_access
}

# ── apt_mirrors.sh ───────────────────────────────────────────────
_bootstrap_kill_apt() {
    killall -9 apt apt-get dpkg dpkg-deb unattended-upgrades || true
    fuser -kk /var/lib/dpkg/lock* /var/cache/apt/archives/lock \
               /var/lib/apt/lists/lock* || true
    sleep 0.5
    rm -f /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend \
          /var/cache/apt/archives/lock /var/lib/apt/lists/lock*
    export DEBIAN_FRONTEND=noninteractive
    dpkg --configure -a --force-confold --force-confdef || true
}

_bootstrap_apt_update() {
    timeout 30 apt-get \
        -o Acquire::ForceIPv4=true \
        -o Acquire::http::Timeout=15 \
        update -qq
}

# -----------------------------------------------------------------
# Основная функция — пробует зеркала по очереди
# Вызывается один раз в начале установки
# -----------------------------------------------------------------
fix_apt_mirrors() {
    # Для не-apt систем — ничего не делаем
    [[ "${PKG_MGR:-apt}" != "apt" ]] && return 0

    _bootstrap_kill_apt

    # Сначала пробуем стандартный репозиторий
    if _bootstrap_apt_update; then
        log_ok "APT: стандартное зеркало OK"
        return 0
    fi

    warn "APT: основной репозиторий не отвечает, пробуем зеркала..."

    local mirrors=(
        "http://ftp.ru.debian.org/debian/"
        "http://mirror.rol.ru/debian/"
        "http://debian.mirohost.net/debian/"
        "http://debian-mirror.ru/debian/"
        "http://ftp.debian.org/debian/"
    )

    cp -a /etc/apt/sources.list /etc/apt/sources.list.vwn_backup || true

    local mirror
    for mirror in "${mirrors[@]}"; do
        printf "  Зеркало %-45s" "$mirror"
        log_info "APT: пробуем $mirror"

        sed -e "s|http://.*debian.org/debian/|${mirror}|g" \
            -e "s|http://security.debian.org/|${mirror}|g" \
            /etc/apt/sources.list > /etc/apt/sources.list.tmp
        mv /etc/apt/sources.list.tmp /etc/apt/sources.list

        _bootstrap_kill_apt
        if _bootstrap_apt_update; then
            echo -e " ${GREEN}[OK]${RESET}"
            log_ok "APT: зеркало OK: $mirror"
            return 0
        else
            echo -e " ${RED}[FAIL]${RESET}"
        fi
    done

    # Откат на оригинал
    mv /etc/apt/sources.list.vwn_backup /etc/apt/sources.list || true
    _bootstrap_kill_apt
    warn "APT: все зеркала недоступны, используем стандартный"
}


# -----------------------------------------------------------------
# ИНИЦИАЛИЗАЦИЯ ЛОГА
# -----------------------------------------------------------------
_log_init() {
    mkdir -p "$(dirname "$LOG_FILE")"
    {
        printf '=%.0s' {1..64}; echo ""
        echo "VWN Install Log v${VWN_INSTALLER_VERSION} — $(date '+%Y-%m-%d %H:%M:%S')"
        echo "PID: $$  Args: $*"
        printf '=%.0s' {1..64}; echo ""
    } >> "$LOG_FILE" || true
}

# -----------------------------------------------------------------
# CLEANUP — гарантированная очистка при любом выходе
# -----------------------------------------------------------------
_cleanup() {
    local rc=${1:-$?}
    stty sane || true

    local f
    for f in "${_TMPFILES[@]+"${_TMPFILES[@]}"}"; do
        rm -f "$f" || true
    done

    rm -f "$VWN_LOCK_FILE" || true

    # Удаляем tmp-конфиги если были созданы
    find /usr/local/etc/xray /etc/nginx -name "*.tmp" -delete || true

    # Закрываем 80-й порт если был открыт для ACME
    [[ -x "$VWN_BIN" ]] && "$VWN_BIN" close-80 || true

    if (( rc != 0 )); then
        log_error "Установщик завершился с кодом $rc"
        echo "" >&2
        err "Установщик завершился с ошибкой (код $rc)."
        echo -e "  Лог: ${YELLOW}${LOG_FILE}${RESET}" >&2
    fi
}

trap '_cleanup $?' EXIT
trap 'log_error "Прерван сигналом INT"; exit 130' INT

# Создать временный файл с авто-удалением
_mktmp() {
    local f; f=$(mktemp)
    _TMPFILES+=("$f")
    echo "$f"
}

# -----------------------------------------------------------------
# ЗАЩИТА ОТ ПАРАЛЛЕЛЬНОГО ЗАПУСКА
# -----------------------------------------------------------------
_acquire_lock() {
    if [[ -f "$VWN_LOCK_FILE" ]]; then
        local pid; pid=$(cat "$VWN_LOCK_FILE" | tr -cd '0-9')

        if [[ -n "$pid" ]] && kill -0 "$pid"; then
            die "Другой экземпляр установщика уже запущен (PID $pid).
Если процесс завис: kill -9 $pid && rm -f $VWN_LOCK_FILE"
        fi

        # Зависшая блокировка старше 1 минуты
        if find "$VWN_LOCK_FILE" -mmin +1 | grep -q .; then
            log_warn "Удаляем зависшую блокировку (>1 мин)"
            rm -f "$VWN_LOCK_FILE"
        fi
    fi

    echo $$ > "$VWN_LOCK_FILE"
    log_info "Lock: PID=$$"
}

# -----------------------------------------------------------------
# ЗАГРУЗКА МОДУЛЕЙ В ТЕКУЩИЙ ПРОЦЕСС
# После этого вызова доступны все функции modules/*.sh:
# installXray, configWarp, writeXrayConfig, enableBBR, menu() и т.д.
#
# ВАЖНО: modules/core.sh переопределяет msg, run_task, isRoot,
# identifyOS, installPackage, prepareApt, getServerIP и др.
# Это ОЖИДАЕМО — модули содержат "правильные" версии этих функций
# с полной логикой. Bootstrap встроен напрямую в install.sh.
# -----------------------------------------------------------------
load_modules() {
    log_info "Загрузка модулей..."

    local module
    for module in "${VWN_MODULES[@]}"; do
        local f="${VWN_LIB}/${module}.sh"
        if [[ -f "$f" ]]; then
            # shellcheck disable=SC1090
            source "$f"
        else
            die "Модуль не найден: $f
Переустановите: bash <(curl -fsSL ${VWN_GITHUB_RAW}/install.sh)"
        fi
    done

    log_ok "Все модули загружены (${#VWN_MODULES[@]} шт.)"
}

# -----------------------------------------------------------------
# ЗАГРУЗКА ФАЙЛОВ С GITHUB — атомарная (tmp → mv)
# -----------------------------------------------------------------
_download_file() {
    local url="$1" dest="$2"
    local tmp; tmp=$(_mktmp)

    if curl -fsSL --connect-timeout 15 --max-time 30 \
            "$url" -o "$tmp"; then
        mv "$tmp" "$dest"
        chmod 644 "$dest"
        return 0
    fi
    rm -f "$tmp"
    return 1
}

_file_hash() {
    md5sum "$1" | awk '{print $1}'
}

# -----------------------------------------------------------------
# СКАЧИВАНИЕ МОДУЛЕЙ
# -----------------------------------------------------------------
download_modules() {
    section "Загрузка модулей"
    mkdir -p "$VWN_LIB"

    local updated=0 unchanged=0 failed=0
    local module

    for module in "${VWN_MODULES[@]}"; do
        local dest="${VWN_LIB}/${module}.sh"
        local old_hash=""
        [[ -f "$dest" ]] && old_hash=$(_file_hash "$dest")

        printf "  %-22s" "${module}.sh"

        if _download_file "${VWN_GITHUB_RAW}/modules/${module}.sh" "$dest"; then
            local new_hash; new_hash=$(_file_hash "$dest")
            if [[ "$old_hash" == "$new_hash" ]]; then
                echo -e " ${YELLOW}[SAME]${RESET}"
                (( unchanged++ )) || true
            else
                local ts; ts=$(stat -c '%y' "$dest" | cut -d. -f1)
                echo -e " ${GREEN}[UPDATED]${RESET} ${ts}"
                log_ok "Модуль обновлён: $module"
                (( updated++ )) || true
            fi
        else
            echo -e " ${RED}[FAIL]${RESET}"
            log_error "Ошибка загрузки модуля: $module"
            (( failed++ )) || true
        fi
    done

    echo ""
    echo -e "  Обновлено: ${GREEN}${updated}${RESET}  │  Без изменений: ${YELLOW}${unchanged}${RESET}  │  Ошибок: ${RED}${failed}${RESET}"

    if (( failed > 0 )); then
        warn "Некоторые модули не загружены. Проверьте подключение к GitHub."
    fi
}

# -----------------------------------------------------------------
# СКАЧИВАНИЕ ШАБЛОНОВ КОНФИГУРАЦИИ
# -----------------------------------------------------------------
download_configs() {
    section "Загрузка шаблонов конфигурации"
    mkdir -p "$VWN_CONFIG_DIR"

    local updated=0 unchanged=0
    local cfg

    for cfg in "${VWN_CONFIGS[@]}"; do
        local dest="${VWN_CONFIG_DIR}/${cfg}"
        local old_hash=""
        [[ -f "$dest" ]] && old_hash=$(_file_hash "$dest")

        printf "  %-44s" "$cfg"

        if _download_file "${VWN_GITHUB_RAW}/config/${cfg}" "$dest"; then
            local new_hash; new_hash=$(_file_hash "$dest")
            if [[ "$old_hash" == "$new_hash" ]]; then
                echo -e " ${YELLOW}[SAME]${RESET}"
                (( unchanged++ )) || true
            else
                echo -e " ${GREEN}[UPDATED]${RESET}"
                (( updated++ )) || true
            fi
        else
            echo -e " ${RED}[FAIL]${RESET}"
            log_warn "Ошибка загрузки конфига: $cfg"
        fi
    done

    echo -e "  Конфиги: ${GREEN}${updated}${RESET} обновлено, ${YELLOW}${unchanged}${RESET} без изменений"
}

# -----------------------------------------------------------------
# УСТАНОВКА БИНАРНОГО ФАЙЛА VWN
# -----------------------------------------------------------------
install_vwn_binary() {
    section "Установка загрузчика vwn"

    if _download_file "${VWN_GITHUB_RAW}/vwn" "${VWN_BIN}.tmp"; then
        mv "${VWN_BIN}.tmp" "$VWN_BIN"
        chmod +x "$VWN_BIN"
        log_ok "vwn: загружен с GitHub"
    else
        log_warn "GitHub недоступен — генерируем fallback vwn"
        _write_fallback_vwn
    fi

    ok "vwn установлен → ${VWN_BIN}"
}

_write_fallback_vwn() {
    # Fallback-загрузчик: используется если GitHub недоступен
    cat > "$VWN_BIN" << 'VWNEOF'
#!/usr/bin/env bash
VWN_LIB="/usr/local/lib/vwn"
case "${1:-}" in
    "open-80")
        ufw status | grep -q inactive && exit 0
        ufw allow from any to any port 80 proto tcp comment 'ACME temp'
        exit 0 ;;
    "close-80")
        ufw status | grep -q inactive && exit 0
        ufw status numbered | grep 'ACME temp' \
            | awk -F'[][]' '{print $2}' | sort -rn \
            | while read -r n; do echo "y" | ufw delete "$n"; done
        exit 0 ;;
    "update")
        bash <(curl -fsSL https://raw.githubusercontent.com/HnDK0/VWN-Xray-Management-Panel/main/install.sh) --update
        exit 0 ;;
esac
for mod in lang core xray nginx warp reality relay psiphon tor security logs backup users diag privacy adblock xhttp menu; do
    f="$VWN_LIB/${mod}.sh"
    [[ -f "$f" ]] && source "$f" || { echo "ERROR: module $mod not found"; exit 1; }
done
VWN_CONF="/usr/local/etc/xray/vwn.conf"
if [[ ! -f "$VWN_CONF" ]] || ! grep -q "VWN_LANG=" "$VWN_CONF"; then
    selectLang; _initLang
fi
isRoot
menu "$@"
VWNEOF
    chmod +x "$VWN_BIN"
    log_info "Fallback vwn создан"
}

# -----------------------------------------------------------------
# ВЕРСИЯ
# -----------------------------------------------------------------
show_version() {
    grep 'VWN_VERSION=' "${VWN_LIB}/core.sh" \
        | head -1 | grep -oP '"[^"]+"' | tr -d '"' \
        || echo "unknown"
}

# -----------------------------------------------------------------
# БАЗОВЫЕ ЗАВИСИМОСТИ — только то что нужно для работы установщика
# (curl, jq, bash, cron).
# НЕ используем installPackage из modules/ — он ещё не загружен.
# -----------------------------------------------------------------
install_base_deps() {
    section "Установка базовых зависимостей"

    # Выбираем рабочее зеркало (только для apt)
    fix_apt_mirrors

    export DEBIAN_FRONTEND=noninteractive

    if [[ "${PKG_MGR:-apt}" == "apt" ]]; then
        step "curl jq bash coreutils cron" bash -c "
            set +o pipefail
            yes '' | apt-get install -y -q \
                -o Dpkg::Lock::Timeout=60 \
                -o Dpkg::Options::='--force-confdef' \
                -o Dpkg::Options::='--force-confold' \
                curl jq bash coreutils cron || true
            set -o pipefail
        "
        soft_step "Активация cron" systemctl enable --now cron
    elif [[ "${PKG_MGR:-}" == "dnf" ]]; then
        step "curl jq bash cronie" bash -c "dnf install -y curl jq bash cronie"
        soft_step "Активация crond" systemctl enable --now crond
    elif [[ "${PKG_MGR:-}" == "yum" ]]; then
        step "curl jq bash cronie" bash -c "yum install -y curl jq bash cronie"
        soft_step "Активация crond" systemctl enable --now crond
    fi

    # Фиксированная версия jq поверх системной
    _install_jq
}

_install_jq() {
    local ver="1.7.1"
    local url="https://github.com/jqlang/jq/releases/download/jq-${ver}/jq-linux-amd64"
    local bin="/usr/local/bin/jq"

    local cur; cur=$(jq --version | grep -oP '[\d.]+' | head -1 || true)
    if [[ "$cur" == "$ver" ]]; then
        log_info "jq ${ver} уже установлен"
        return 0
    fi

    local tmp; tmp=$(_mktmp)
    if curl -fsSL --connect-timeout 15 "$url" -o "$tmp"; then
        install -m 755 "$tmp" "$bin"
        log_ok "jq ${ver} установлен"
    else
        log_warn "jq download failed, используем системную версию"
    fi
}

# -----------------------------------------------------------------
# ПАРАМЕТРЫ КОМАНДНОЙ СТРОКИ
# -----------------------------------------------------------------
_UPDATE_ONLY=false
_AUTO_MODE=false

# Параметры --auto (умолчания)
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
OPT_SSH_PORT=""
OPT_JAIL=false
OPT_IPV6=false
OPT_CPU_GUARD=false
OPT_ADBLOCK=false
OPT_PRIVACY=false
OPT_PSIPHON=false
OPT_PSIPHON_COUNTRY=""
OPT_PSIPHON_WARP=false
OPT_XHTTP=true        # XHTTP устанавливается вместе с WS по умолчанию
OPT_SKIP_XHTTP=false  # --skip-xhttp отключает установку XHTTP

_parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --update)          _UPDATE_ONLY=true ;;
            --auto)            _AUTO_MODE=true ;;
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
            --xhttp)           OPT_XHTTP=true; OPT_SKIP_XHTTP=false ;;
            --skip-xhttp)      OPT_SKIP_XHTTP=true; OPT_XHTTP=false ;;
            --help|-h)         _show_help; exit 0 ;;
            *)                 warn "Неизвестный аргумент: $1" ;;
        esac
        shift
    done
}

_show_help() {
    cat << 'HELPEOF'

VWN Installer v2.1  (Xray VLESS + WARP + CDN + Reality)
=========================================================

РЕЖИМЫ:
  bash <(curl -fsSL https://raw.githubusercontent.com/HnDK0/VWN-Xray-Management-Panel/main/install.sh)
                                          Интерактивная установка
  bash <(curl -fsSL ...install.sh) --update
                                          Обновить модули и шаблоны
  bash <(curl -fsSL ...install.sh) --auto [ОПЦИИ]
                                          Автоматическая установка

ОПЦИИ (--auto):
  --domain      ДОМЕН        CDN-домен для VLESS+WS+TLS  [обязателен]
  --stub        URL          URL сайта-заглушки           [httpbin.org]
  --lang        ru|en        Язык интерфейса              [ru]
  --reality                  Установить Reality (доп. к WS)
  --reality-dest ХОСТ:ПОРТ   SNI для Reality              [microsoft.com:443]
  --reality-port ПОРТ        Порт Reality                 [8443]
  --cert-method cf|standalone Метод получения SSL         [standalone]
  --cf-email    EMAIL        Email Cloudflare (для cf)
  --cf-key      КЛЮЧ         API Key Cloudflare (для cf)
  --skip-ws                  Пропустить WS (только Reality)
  --xhttp                    Явно включить XHTTP (по умолчанию вкл)
  --skip-xhttp               Не устанавливать XHTTP транспорт
  --ssh-port    ПОРТ         Сменить порт SSH (1-65535)
  --ipv6                     Включить IPv6
  --cpu-guard                CPU Guard (приоритет xray/nginx)
  --bbr                      TCP BBR congestion control
  --fail2ban                 Установить Fail2Ban
  --jail                     WebJail nginx-probe (требует --fail2ban)
  --adblock                  Блокировка рекламы (geosite)
  --privacy                  Privacy Mode (без логов трафика)
  --psiphon                  Установить Psiphon
  --psiphon-country КОД      Страна выхода Psiphon (DE, NL, US, GB...)
  --psiphon-warp             Psiphon через WARP
  --no-warp                  Не настраивать Cloudflare WARP

ПРИМЕРЫ:
  # Минимально — только WS+TLS+CDN, SSL через HTTP-challenge:
  bash <(curl -fsSL https://raw.githubusercontent.com/HnDK0/VWN-Xray-Management-Panel/main/install.sh) \
    --auto \
    --domain vpn.example.com

  # WS + XHTTP + Reality, SSL через Cloudflare DNS, BBR, Fail2Ban:
  bash <(curl -fsSL https://raw.githubusercontent.com/HnDK0/VWN-Xray-Management-Panel/main/install.sh) \
    --auto \
    --domain vpn.example.com \
    --cert-method cf --cf-email me@me.com --cf-key AbCd1234 \
    --reality --reality-dest apple.com:443 \
    --bbr --fail2ban

  # WS + XHTTP, без Reality, со сменой порта SSH и Psiphon (DE):
  bash <(curl -fsSL https://raw.githubusercontent.com/HnDK0/VWN-Xray-Management-Panel/main/install.sh) \
    --auto \
    --domain vpn.example.com \
    --ssh-port 2222 \
    --psiphon --psiphon-country DE \
    --bbr --adblock

  # Только WS+TLS, без XHTTP (минимальная установка):
  bash <(curl -fsSL https://raw.githubusercontent.com/HnDK0/VWN-Xray-Management-Panel/main/install.sh) \
    --auto \
    --domain vpn.example.com \
    --skip-xhttp

  # Только Reality (без WS/Nginx/SSL/XHTTP):
  bash <(curl -fsSL https://raw.githubusercontent.com/HnDK0/VWN-Xray-Management-Panel/main/install.sh) \
    --auto \
    --skip-ws \
    --reality --reality-dest microsoft.com:443 --reality-port 8443

  # Полная установка — всё включено:
  bash <(curl -fsSL https://raw.githubusercontent.com/HnDK0/VWN-Xray-Management-Panel/main/install.sh) \
    --auto \
    --domain vpn.example.com \
    --cert-method cf --cf-email me@me.com --cf-key AbCd1234 \
    --reality --reality-dest apple.com:443 \
    --psiphon --psiphon-country NL \
    --ssh-port 2222 \
    --bbr --fail2ban --jail \
    --adblock --privacy --cpu-guard

ЛОГИ: /var/log/vwn_install.log
HELPEOF
}

# -----------------------------------------------------------------
# ВАЛИДАЦИЯ ПАРАМЕТРОВ --auto
# -----------------------------------------------------------------
_validate_auto_params() {
    ! $OPT_SKIP_WS && [[ -z "$OPT_DOMAIN" ]] \
        && die "--domain обязателен (или --skip-ws для режима только-Reality)"

    [[ "$OPT_CERT_METHOD" == "cf" ]] && {
        [[ -z "$OPT_CF_EMAIL" ]] && die "--cf-email обязателен при --cert-method cf"
        [[ -z "$OPT_CF_KEY"   ]] && die "--cf-key обязателен при --cert-method cf"
    }

    [[ "$OPT_CERT_METHOD" != "cf" && "$OPT_CERT_METHOD" != "standalone" ]] \
        && die "--cert-method: допустимо 'cf' или 'standalone'"

    _check_port_range "$OPT_PORT"         1024  65535 "--port"
    _check_port_range "$OPT_REALITY_PORT"  443  65535 "--reality-port"
    [[ -n "$OPT_SSH_PORT" ]] && _check_port_range "$OPT_SSH_PORT" 1 65535 "--ssh-port"

    if $OPT_PSIPHON && [[ -n "$OPT_PSIPHON_COUNTRY" ]]; then
        [[ "$OPT_PSIPHON_COUNTRY" =~ ^[A-Za-z]{2}$ ]] \
            || die "--psiphon-country: укажите 2-буквенный код страны (DE, NL, US...)"
        OPT_PSIPHON_COUNTRY="${OPT_PSIPHON_COUNTRY^^}"
    fi

    $OPT_PSIPHON_WARP && $OPT_NO_WARP \
        && die "--psiphon-warp несовместим с --no-warp"

    log_ok "Параметры --auto: OK"
}

_check_port_range() {
    local val="$1" min="$2" max="$3" name="$4"
    [[ "$val" =~ ^[0-9]+$ ]] && (( val >= min && val <= max )) \
        || die "${name}: значение '${val}' вне допустимого диапазона ${min}-${max}"
}

# -----------------------------------------------------------------
# ПЕЧАТЬ ПАРАМЕТРОВ --auto
# -----------------------------------------------------------------
_print_auto_params() {
    local mode=""
    $OPT_SKIP_WS && mode="Reality only (WS пропущен)" || mode="WS+TLS+CDN"
    $OPT_REALITY && mode+=" + Reality"

    echo ""
    echo -e "${CYAN}$(printf '─%.0s' {1..64})${RESET}"
    echo -e "   Параметры установки:"
    echo -e "${CYAN}$(printf '─%.0s' {1..64})${RESET}"

    # Вспомогательная функция — фиксированный разделитель, без printf-выравнивания
    # (printf %-Ns не работает с кириллицей — считает байты, а не символы)
    _print_param() { echo -e "  ${CYAN}${1}${RESET}: ${GREEN}${2}${RESET}"; }

    _print_param "Режим"      "$mode"
    [[ -n "$OPT_DOMAIN" ]]         && _print_param "Домен"      "$OPT_DOMAIN"
    ! $OPT_SKIP_WS                 && _print_param "Stub URL"    "$OPT_STUB"
    ! $OPT_SKIP_WS                 && _print_param "SSL метод"   "$OPT_CERT_METHOD"
    ! $OPT_SKIP_WS && ! $OPT_SKIP_XHTTP && _print_param "XHTTP"  "включён"
    ! $OPT_SKIP_WS && $OPT_SKIP_XHTTP   && _print_param "XHTTP"  "пропущен (--skip-xhttp)"
    $OPT_REALITY                   && _print_param "Reality"     "${OPT_REALITY_DEST}  порт=${OPT_REALITY_PORT}"
    [[ -n "$OPT_SSH_PORT" ]]       && _print_param "SSH порт"   "$OPT_SSH_PORT"
    $OPT_IPV6                      && _print_param "IPv6"        "включён"
    $OPT_CPU_GUARD                 && _print_param "CPU Guard"   "включён"
    $OPT_FAIL2BAN                  && _print_param "Fail2Ban"    "включён"
    $OPT_JAIL                      && _print_param "WebJail"     "включён"
    $OPT_ADBLOCK                   && _print_param "Adblock"     "включён"
    $OPT_PRIVACY                   && _print_param "Privacy"     "включён"
    $OPT_PSIPHON                   && _print_param "Psiphon"     "включён${OPT_PSIPHON_COUNTRY:+ (${OPT_PSIPHON_COUNTRY})}${OPT_PSIPHON_WARP:+ +WARP}"
    $OPT_BBR                       && _print_param "BBR"         "включён"
    $OPT_NO_WARP                   && _print_param "WARP"        "ПРОПУЩЕН"
    _print_param "Язык"       "$OPT_LANG"

    echo -e "${CYAN}$(printf '─%.0s' {1..64})${RESET}"
    echo ""

    unset -f _print_param
}

# -----------------------------------------------------------------
# КОМПОНЕНТЫ АВТОУСТАНОВКИ
# Все вызовы идут к функциям из modules/*.sh (загружены через load_modules)
# -----------------------------------------------------------------

_auto_ssl() {
    local domain="$1"
    log_info "SSL: domain=${domain} method=${OPT_CERT_METHOD}"

    # installPackage — из modules/core.sh (уже загружен через load_modules)
    soft_step "socat" installPackage socat

    if [[ ! -f ~/.acme.sh/acme.sh ]]; then
        step "Установка acme.sh" bash -c "
            curl -fsSL https://get.acme.sh | sh -s email='acme@${domain}' --no-profile
        "
    fi
    [[ -f ~/.acme.sh/acme.sh ]] || die "acme.sh не установлен — проверьте подключение"

    soft_step "acme.sh upgrade"  ~/.acme.sh/acme.sh --upgrade --auto-upgrade
    soft_step "acme.sh set CA"   ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

    mkdir -p /etc/nginx/cert

    if [[ "$OPT_CERT_METHOD" == "cf" ]]; then
        printf 'export CF_Email=%q\nexport CF_Key=%q\n' \
               "$OPT_CF_EMAIL" "$OPT_CF_KEY" > /root/.cloudflare_api
        chmod 600 /root/.cloudflare_api
        export CF_Email="$OPT_CF_EMAIL" CF_Key="$OPT_CF_KEY"
        step "SSL (Cloudflare DNS-01)" \
            ~/.acme.sh/acme.sh --issue --dns dns_cf -d "$domain" --force
    else
        # HTTP-01: vwn open-80 / close-80 управляют портом
        soft_step "UFW: открыть 80 (ACME)" ufw allow 80/tcp comment 'ACME temp'
        step "SSL (HTTP-01 standalone)" \
            ~/.acme.sh/acme.sh --issue --standalone -d "$domain" \
                --pre-hook  "$VWN_BIN open-80" \
                --post-hook "$VWN_BIN close-80" \
                --force
        # Убираем временное правило
        ufw status numbered \
            | awk '/ACME temp/{gsub(/[][]/,""); print $1}' \
            | sort -rn \
            | while read -r n; do echo "y" | ufw delete "$n" || true; done
    fi

    step "Установка сертификата" \
        ~/.acme.sh/acme.sh --install-cert -d "$domain" \
            --key-file       /etc/nginx/cert/cert.key \
            --fullchain-file /etc/nginx/cert/cert.pem \
            --ca-file        /etc/nginx/cert/chain.pem \
            --reloadcmd      "systemctl restart nginx || true"

    # Даём пользователю xray доступ к cert.key
    chmod 640 /etc/nginx/cert/cert.key
    chown root:xray /etc/nginx/cert/cert.key || true

    ok "SSL для ${domain} получен"
}

_auto_install_ws() {
    section "WS + TLS + Nginx + CDN"

    # UFW
    step "UFW: SSH + HTTPS" bash -c "
        ufw allow 22/tcp   comment 'SSH'   || true
        ufw allow 443/tcp  comment 'HTTPS' || true
        ufw allow 443/udp  comment 'HTTPS' || true
        echo 'y' | ufw enable  || true
    "

    # applySysctl, setupSystemDNS — из modules/security.sh и modules/core.sh
    step "Sysctl оптимизация" applySysctl
    step "Системный DNS"      setupSystemDNS

    # generateRandomPath — из modules/core.sh
    local ws_path; ws_path=$(generateRandomPath)
    log_info "WS path: ${ws_path}"

    # writeXrayConfig — из modules/xray.sh
    step "Xray конфиг (WS)"      writeXrayConfig "$OPT_PORT" "$ws_path" "$OPT_DOMAIN"
    mkdir -p /usr/local/etc/xray
    echo "$OPT_DOMAIN" > /usr/local/etc/xray/connect_host

    # Инициализируем users.conf сразу после writeXrayConfig — чтобы UUID был
    # единым для всех компонентов (Reality, XHTTP) с самого начала установки
    _initUsersFile || true

    # writeNginxConfigBase — из modules/nginx.sh
    step "Nginx конфиг (base)"   writeNginxConfigBase "$OPT_PORT" "$OPT_DOMAIN" "$OPT_STUB" "$ws_path"
    soft_step "Nginx enable"     systemctl enable nginx
    soft_step "Nginx resilience" bash -c '
        mkdir -p /etc/systemd/system/nginx.service.d
        cat > /etc/systemd/system/nginx.service.d/resilience.conf << EOF
[Service]
Restart=on-failure
RestartSec=3
EOF
        systemctl daemon-reload'

    if ! $OPT_NO_WARP; then
        # configWarp — из modules/warp.sh
        soft_step "WARP настройка"   configWarp
    else
        info "WARP пропущен (--no-warp)"
    fi

    step "SSL (${OPT_CERT_METHOD})"  _auto_ssl "$OPT_DOMAIN"

    # applyWarpDomains, setupLogrotate, setupLogClearCron, setupSslCron — из modules/
    soft_step "WARP домены"      applyWarpDomains
    soft_step "Log rotate"       setupLogrotate
    soft_step "Log cron"         setupLogClearCron
    soft_step "SSL cron"         setupSslCron

    step  "Xray enable"          systemctl enable xray
    soft_step "Xray restart"     systemctl restart xray
    step  "Nginx restart"        systemctl restart nginx

    ok "WS+TLS установлен"
}

_auto_install_xhttp() {
    section "XHTTP (CDN транспорт)"
    # installXhttp — из modules/xhttp.sh
    installXhttp --auto
    ok "XHTTP установлен"
}

_auto_install_reality() {
    section "Reality"

    # Убеждаемся что xray доступен (installXray — из modules/xray.sh)
    local xray_bin=""
    local b
    for b in /usr/local/bin/xray /usr/bin/xray; do
        [[ -x "$b" ]] && xray_bin="$b" && break
    done
    [[ -z "$xray_bin" ]] && step "Xray-core" installXray

    soft_step "UFW: Reality порт" \
        ufw allow "${OPT_REALITY_PORT}/tcp" comment 'Xray Reality'

    # writeRealityConfig, setupRealityService — из modules/reality.sh
    step "Reality конфиг"  writeRealityConfig "$OPT_REALITY_PORT" "$OPT_REALITY_DEST"
    step "Reality сервис"  setupRealityService

    if ! $OPT_NO_WARP \
        && [[ -f "${warpDomainsFile:-/usr/local/etc/xray/warp_domains.txt}" ]]; then
        soft_step "WARP домены" applyWarpDomains
    fi

    ok "Reality: порт=${OPT_REALITY_PORT}  SNI=${OPT_REALITY_DEST}"
}

_auto_change_ssh_port() {
    local new_port="$1"
    local old_port
    old_port=$(grep -E "^Port " /etc/ssh/sshd_config \
               | awk '{print $2}' | head -1 || true)
    old_port="${old_port:-22}"

    info "SSH: ${old_port} → ${new_port}"
    log_info "SSH port change: ${old_port} → ${new_port}"

    soft_step "UFW: новый SSH порт" ufw allow "${new_port}/tcp" comment 'SSH'
    step "sshd_config" \
        bash -c "grep -qE '^#?Port ' /etc/ssh/sshd_config \
            && sed -i \"s/^#\\?Port [0-9]*/Port ${new_port}/\" /etc/ssh/sshd_config \
            || echo \"Port ${new_port}\" >> /etc/ssh/sshd_config"
    step "Перезапуск sshd" \
        bash -c "systemctl restart sshd || systemctl restart ssh"

    # Обновляем Fail2Ban если запущен (changeSshPort из modules/security.sh
    # обновляет fail2ban изнутри, но мы уже поменяли порт напрямую,
    # поэтому только обновляем jail.local)
    if systemctl is-active --quiet fail2ban; then
        soft_step "Fail2Ban: обновление SSH порта" bash -c "
            sed -i 's/^port\s*=.*/port     = ${new_port}/' /etc/fail2ban/jail.local || true
            systemctl restart fail2ban || true
        "
    fi

    ok "SSH порт изменён на ${new_port}"
}

_auto_install_psiphon() {
    section "Psiphon"
    local country="${OPT_PSIPHON_COUNTRY:-DE}"
    local tunnel_mode="plain"

    # installPsiphonBinary, writePsiphonConfig, setupPsiphonService,
    # applyPsiphonOutbound, applyPsiphonDomains — из modules/psiphon.sh
    step "Psiphon бинарь" installPsiphonBinary

    if $OPT_PSIPHON_WARP \
        && systemctl is-active --quiet warp-svc \
        && ss -tlnp | grep -q ':40000'; then
        tunnel_mode="warp"
    fi

    step "Psiphon конфиг" writePsiphonConfig "$country" "$tunnel_mode"
    step "Psiphon сервис" setupPsiphonService
    soft_step "Psiphon → Xray outbound" applyPsiphonOutbound

    if [[ -f "${psiphonDomainsFile:-}" && -s "${psiphonDomainsFile}" ]]; then
        soft_step "Psiphon домены" applyPsiphonDomains
    fi

    ok "Psiphon: страна=${country}, туннель=${tunnel_mode}"
}

_auto_toggle_ipv6_on() {
    local cur; cur=$(sysctl -n net.ipv6.conf.all.disable_ipv6 || echo "0")
    if [[ "$cur" == "1" ]]; then
        # toggleIPv6 — из modules/security.sh
        step "Включение IPv6" toggleIPv6
    else
        info "IPv6 уже включён, пропускаем"
    fi
}

# -----------------------------------------------------------------
# ГЛАВНАЯ ФУНКЦИЯ АВТОМАТИЧЕСКОЙ УСТАНОВКИ
# Порядок: validate → print → load_modules → systemные пакеты →
#          WS → Reality → Vision → опциональные
# -----------------------------------------------------------------
_run_auto() {
    echo -e "${CYAN}$(printf '═%.0s' {1..64})${RESET}"
    echo -e "   VWN — Автоматическая установка"
    echo -e "${CYAN}$(printf '═%.0s' {1..64})${RESET}"

    _validate_auto_params
    _print_auto_params

    # ── Загружаем modules/*.sh ────────────────────────────────────
    # После этого доступны: installXray, configWarp, writeXrayConfig,
    # applySysctl, setupFail2Ban, enableBBR, identifyOS и т.д.
    # modules/core.sh переопределит msg, run_task, identifyOS,
    # installPackage и др. — это корректно.
    load_modules

    # Инициализируем язык (из modules/lang.sh + modules/core.sh)
    vwn_conf_set "VWN_LANG" "$OPT_LANG"
    _initLang

    # ── Системные пакеты ──────────────────────────────────────────
    section "Системные пакеты"

    # identifyOS и installPackage теперь из modules/core.sh
    identifyOS
    prepareApt
    soft_step "Swap" setupSwap

    export DEBIAN_FRONTEND=noninteractive
    info "Обновление списков пакетов..."
    eval "${PACKAGE_MANAGEMENT_UPDATE}" || true

    # Ставим все базовые пакеты одной командой — man-db триггер срабатывает один раз
    local base_pkgs=(tar gpg unzip jq nano ufw socat curl qrencode python3)
    info "Установка базовых пакетов: ${base_pkgs[*]}"
    apt-get -y --no-install-recommends \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" \
        install "${base_pkgs[@]}" || true

    step "Xray-core" installXray

    if ! $OPT_NO_WARP; then
        soft_step "Cloudflare WARP" installWarp
    fi

    if ! $OPT_SKIP_WS; then
        # _installNginxMainline из modules/menu.sh
        soft_step "Nginx mainline" _installNginxMainline \
            || soft_step "Nginx (fallback)" installPackage nginx
    fi

    # ── WS ────────────────────────────────────────────────────────
    if ! $OPT_SKIP_WS; then
        set +e
        _auto_install_ws
        local _ws_rc=$?
        set -e
        if [ "$_ws_rc" -ne 0 ]; then
            warn "WS установка завершилась с ошибкой (rc=${_ws_rc}), продолжаем..."
            log_warn "WS install rc=${_ws_rc}"
        fi
    else
        info "WS пропущен (--skip-ws)"
        soft_step "UFW: SSH" \
            bash -c "ufw allow 22/tcp comment 'SSH' && echo 'y' | ufw enable"
        soft_step "Sysctl"   applySysctl
        ! $OPT_NO_WARP && soft_step "WARP" configWarp
    fi

    # ── Reality ───────────────────────────────────────────────────
    $OPT_REALITY && _auto_install_reality

    # ── XHTTP ────────────────────────────────────────────────────
    # Устанавливается вместе с WS если не передан --skip-xhttp
    if ! $OPT_SKIP_WS && ! $OPT_SKIP_XHTTP && [ ! -f "$xhttpConfigPath" ]; then
        set +e
        _auto_install_xhttp
        local _xhttp_rc=$?
        set -e
        if [ "$_xhttp_rc" -ne 0 ]; then
            warn "XHTTP установка завершилась с ошибкой (rc=${_xhttp_rc}), продолжаем..."
            log_warn "XHTTP install rc=${_xhttp_rc}"
        fi
    elif $OPT_SKIP_XHTTP; then
        info "XHTTP пропущен (--skip-xhttp)"
    fi

    # ── Vision ────────────────────────────────────────────────────

    # ── Опциональные компоненты (порядок важен!) ──────────────────

    # 1. SSH порт — до Fail2Ban, чтобы f2b знал правильный порт
    [[ -n "$OPT_SSH_PORT" ]] && _auto_change_ssh_port "$OPT_SSH_PORT"

    # 2. IPv6
    if $OPT_IPV6; then
        section "IPv6"
        _auto_toggle_ipv6_on
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

    # 5. WebJail (требует Fail2Ban) — из modules/security.sh
    if $OPT_JAIL; then
        section "WebJail"
        if ! $OPT_FAIL2BAN; then
            warn "--jail требует Fail2Ban, устанавливаем..."
            step "Fail2Ban (авто)" setupFail2Ban
        fi
        step "WebJail (nginx-probe)" setupWebJail
    fi

    # 6. Adblock — из modules/adblock.sh
    if $OPT_ADBLOCK; then
        section "Adblock"
        step "Adblock" enableAdblock
    fi

    # 7. Privacy Mode — из modules/privacy.sh
    if $OPT_PRIVACY; then
        section "Privacy Mode"
        step "Privacy Mode" enablePrivacyMode
    fi

    # 8. Psiphon
    $OPT_PSIPHON && _auto_install_psiphon

    # 9. BBR — последним (меняет sysctl) — из modules/security.sh
    if $OPT_BBR; then
        section "BBR TCP"
        step "BBR" enableBBR
    fi

    _print_summary
}

_print_summary() {
    echo ""
    echo -e "${GREEN}$(printf '═%.0s' {1..64})${RESET}"
    echo -e "   Установка завершена!"
    echo -e "${GREEN}$(printf '═%.0s' {1..64})${RESET}"
    echo ""

    _sum() { printf "  ${CYAN}%-12s${RESET}: ${GREEN}%s${RESET}\n" "$1" "$2"; }

    ! $OPT_SKIP_WS && {
        _sum "WS+TLS" "домен=${OPT_DOMAIN}"
    }
    ! $OPT_SKIP_WS && ! $OPT_SKIP_XHTTP && _sum "XHTTP"     "установлен (CDN транспорт)"
    $OPT_REALITY  && _sum "Reality"   "порт=${OPT_REALITY_PORT}, SNI=${OPT_REALITY_DEST}"
    [[ -n "$OPT_SSH_PORT" ]] && _sum "SSH"      "порт=${OPT_SSH_PORT}"
    $OPT_IPV6      && _sum "IPv6"      "включён"
    $OPT_CPU_GUARD && _sum "CPU Guard" "включён"
    $OPT_FAIL2BAN  && _sum "Fail2Ban"  "включён"
    $OPT_JAIL      && _sum "WebJail"   "включён"
    $OPT_ADBLOCK   && _sum "Adblock"   "включён"
    $OPT_PRIVACY   && _sum "Privacy"   "включён"
    $OPT_PSIPHON   && _sum "Psiphon"   "${OPT_PSIPHON_COUNTRY:-DE}${OPT_PSIPHON_WARP:+ +WARP}"
    $OPT_BBR       && _sum "BBR"       "включён"

    echo ""
    echo -e "  ${CYAN}Управление:${RESET} ${GREEN}vwn${RESET}"
    echo -e "  ${CYAN}Лог:${RESET} ${YELLOW}${LOG_FILE}${RESET}"
    echo -e "${GREEN}$(printf '═%.0s' {1..64})${RESET}"
    echo ""

    unset -f _sum

    # Генерируем QR и subscription — из modules/xray.sh, modules/users.sh
    # _initUsersFile уже вызвана в начале установки (после writeXrayConfig)
    set +e
    rebuildAllSubFiles || true
    getQrCode          || true
    set -e

    log_ok "Установка завершена"
}

# -----------------------------------------------------------------
# ТОЧКА ВХОДА
# -----------------------------------------------------------------
main() {
    _log_init "$@"
    log_info "VWN Installer v${VWN_INSTALLER_VERSION} started"

    _parse_args "$@"

    # Защита от параллельного запуска (только при первом вызове)
    [[ -z "${VWN_INSTALL_PARENT:-}" ]] && _acquire_lock

    # Порядок: сначала root+OS (нужны для всего остального),
    # потом preflight (диск/интернет), потом зависимости
    check_root
    check_os

    # Шапка
    echo ""
    echo -e "${CYAN}$(printf '═%.0s' {1..64})${RESET}"
    if   $_UPDATE_ONLY; then
        echo -e "   VWN — Обновление модулей и шаблонов"
    elif $_AUTO_MODE; then
        echo -e "   VWN v${VWN_INSTALLER_VERSION} — Автоматическая установка"
    else
        echo -e "   VWN v${VWN_INSTALLER_VERSION} — VLESS + WARP + CDN + Reality"
    fi
    echo -e "${CYAN}$(printf '═%.0s' {1..64})${RESET}"
    echo ""

    # Базовые зависимости — нужны для curl (скачивание модулей)
    install_base_deps

    # Полные preflight-проверки (диск, интернет, GitHub)
    run_preflight_checks

    if $_UPDATE_ONLY; then
        # ── Режим обновления ───────────────────────────────────
        info "Обновление модулей (конфиги не затрагиваются)..."
        download_modules
        download_configs

        # Подключаем lang.sh для перевода (только его, не всё)
        if [[ -f "${VWN_LIB}/lang.sh" ]]; then
            # shellcheck disable=SC1090
            source "${VWN_LIB}/lang.sh"
            _initLang
        fi

        install_vwn_binary

        echo ""
        ok "Обновление завершено. Версия: $(show_version)"
        echo -e "  Запустите ${GREEN}vwn${RESET} для управления"

    elif $_AUTO_MODE; then
        # ── Автоматический режим ───────────────────────────────
        download_modules
        download_configs
        install_vwn_binary
        _run_auto

    else
        # ── Интерактивный режим ────────────────────────────────
        download_modules
        download_configs

        # Выбор языка (из modules/lang.sh)
        if [[ -f "${VWN_LIB}/lang.sh" ]]; then
            # shellcheck disable=SC1090
            source "${VWN_LIB}/lang.sh"
            selectLang
            _initLang
        fi

        install_vwn_binary
        load_modules

        echo ""
        ok "$(printf '═%.0s' {1..64})"
        ok "   Модули установлены → ${VWN_LIB}"
        ok "   Версия: $(show_version)"
        ok "$(printf '═%.0s' {1..64})"
        echo ""

        info "$(msg launching_menu)"
        sleep 1
        exec "$VWN_BIN"
    fi
}

main "$@"
