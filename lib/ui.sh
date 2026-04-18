#!/usr/bin/env bash
# =================================================================
# lib/ui.sh — Интерфейс пользователя
#
# Предоставляет:
#   • Вывод с логированием: info, ok, warn, err, die
#   • Статусные строки:     step(), soft_step(), section()
#   • Интерактивные ввод:   ui_confirm(), ui_input(), ui_menu()
#   • msg() — переводы (fallback до загрузки modules/lang.sh)
#   • run_task() — псевдоним step() для совместимости
# =================================================================

# Зависимости: colors.sh (RED/GREEN/YELLOW/CYAN/RESET), logging.sh

# -----------------------------------------------------------------
# Базовые print-функции с одновременной записью в лог
# -----------------------------------------------------------------
info()  { echo -e "${CYAN}$*${RESET}";   log_info  "$*"; }
ok()    { echo -e "${GREEN}$*${RESET}";  log_ok    "$*"; }
warn()  { echo -e "${YELLOW}$*${RESET}"; log_warn  "$*"; }
err()   { echo -e "${RED}$*${RESET}" >&2; log_error "$*"; }
die()   { err "ОШИБКА: $*"; exit 1; }

# -----------------------------------------------------------------
# step — запускает команду с индикатором [OK] / [FAIL]
# Использование: step "Описание" команда [аргументы...]
# Возвращает: код возврата команды
# -----------------------------------------------------------------
step() {
    local desc="$1"; shift
    printf "  %-50s" "$desc"
    log_info "STEP: $desc → $*"

    local output rc=0
    output=$("$@" 2>&1) || rc=$?

    if (( rc == 0 )); then
        echo -e " ${GREEN}[OK]${RESET}"
        log_ok "  → OK"
    else
        echo -e " ${RED}[FAIL]${RESET}"
        log_error "  → FAIL (rc=${rc}): ${output}"
        return $rc
    fi
}

# -----------------------------------------------------------------
# soft_step — как step, но SKIP вместо FAIL при ошибке (non-fatal)
# -----------------------------------------------------------------
soft_step() {
    local desc="$1"; shift
    printf "  %-50s" "$desc"
    log_info "SOFT: $desc → $*"

    if "$@" &>/dev/null; then
        echo -e " ${GREEN}[OK]${RESET}"
        log_ok "  → OK"
    else
        echo -e " ${YELLOW}[SKIP]${RESET}"
        log_warn "  → SKIP (non-fatal)"
    fi
}

# -----------------------------------------------------------------
# section — визуальный разделитель этапов
# -----------------------------------------------------------------
section() {
    echo ""
    echo -e "${CYAN}━━━ $* ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    log_info "=== SECTION: $* ==="
}

# -----------------------------------------------------------------
# run_task — псевдоним step() для совместимости с modules/menu.sh
# В оригинале: run_task "Описание" команда
# -----------------------------------------------------------------
run_task() {
    local desc="$1"; shift
    # Оригинальный run_task принимал строку и вызывал eval
    # Мы вызываем step напрямую — безопаснее
    if [[ $# -eq 1 ]]; then
        # Передана строка — выполняем через bash -c
        step "$desc" bash -c "$1"
    else
        step "$desc" "$@"
    fi
}

# -----------------------------------------------------------------
# msg() — таблица переводов (fallback до загрузки modules/lang.sh)
# После load_modules() lang.sh переопределяет эту функцию
# -----------------------------------------------------------------
msg() {
    local key="$1"
    shift || true

    # Если modules/lang.sh уже загружен — используем его MSG[]
    if declare -p MSG &>/dev/null 2>&1; then
        echo "${MSG[$key]:-$key}"
        return
    fi

    # Fallback-таблица (английский)
    case "$key" in
        run_as_root)     echo "Run as root!" ;;
        os_unsupported)  echo "Only apt/dnf/yum supported." ;;
        install_deps)    echo "Installing dependencies..." ;;
        install_modules) echo "Downloading modules..." ;;
        install_vwn)     echo "Installing vwn binary..." ;;
        install_title)   echo "VWN — Xray VLESS + WARP + CDN + Reality" ;;
        update_title)    echo "VWN — Updating modules" ;;
        update_done)     echo "Update complete! Version" ;;
        install_done)    echo "Modules installed in" ;;
        install_version) echo "Version" ;;
        launching_menu)  echo "Launching setup menu..." ;;
        auto_start)      echo "Starting unattended installation..." ;;
        auto_done)       echo "Unattended installation complete!" ;;
        run_vwn)         echo "Run: vwn" ;;
        yes_no)          echo "(y/n)" ;;
        press_enter)     echo "Press Enter..." ;;
        choose)          echo "Choice: " ;;
        back)            echo "Back" ;;
        cancel)          echo "Cancelled." ;;
        done)            echo "Done." ;;
        error)           echo "Error" ;;
        invalid)         echo "Invalid input!" ;;
        invalid_port)    echo "Invalid port." ;;
        no_logs)         echo "No logs" ;;
        restarted)       echo "Restarted." ;;
        removed)         echo "Removed." ;;
        saved)           echo "Saved." ;;
        not_found)       echo "Not found." ;;
        swap_creating)   echo "Creating swap file" ;;
        swap_created)    echo "Swap created:" ;;
        swap_fail)       echo "Swap creation failed, continuing..." ;;
        *)               echo "$key" ;;
    esac
}

# -----------------------------------------------------------------
# Шапка/разделитель
# -----------------------------------------------------------------
ui_header() {
    local title="${1:-VWN}"
    clear
    echo -e "${CYAN}════════════════════════════════════════════════════════════════${RESET}"
    echo -e "   ${title}"
    echo -e "${CYAN}════════════════════════════════════════════════════════════════${RESET}"
    echo ""
}

# -----------------------------------------------------------------
# Диалог "Да/Нет" → 0=да, 1=нет
# Использование: ui_confirm "Продолжить?" "y"
# -----------------------------------------------------------------
ui_confirm() {
    local prompt="${1:-Продолжить?}" default="${2:-y}"
    local hint; [[ "$default" == "y" ]] && hint="[Y/n]" || hint="[y/N]"
    local answer
    read -rp "  ${prompt} ${hint}: " answer
    answer="${answer:-$default}"
    [[ "${answer,,}" == "y" || "${answer,,}" == "yes" || "${answer,,}" == "да" ]]
}

# -----------------------------------------------------------------
# Ввод строки с дефолтом
# Использование: ui_input "Домен" "example.com" my_var
# -----------------------------------------------------------------
ui_input() {
    local prompt="$1" default="${2:-}" var_name="$3"
    local hint=""; [[ -n "$default" ]] && hint=" [${default}]"
    local value
    read -rp "  ${prompt}${hint}: " value
    value="${value:-$default}"
    printf -v "$var_name" '%s' "$value"
}

# -----------------------------------------------------------------
# Цветные статус-иконки (для использования в модулях)
# -----------------------------------------------------------------
ui_ok()   { echo -e "  ${GREEN}✓${RESET} $*"; }
ui_warn() { echo -e "  ${YELLOW}⚠${RESET} $*"; }
ui_err()  { echo -e "  ${RED}✗${RESET} $*"; }
ui_info() { echo -e "  ${CYAN}→${RESET} $*"; }

# -----------------------------------------------------------------
# Пауза
# -----------------------------------------------------------------
ui_pause() {
    echo ""
    read -rsp "  Нажмите Enter для продолжения..." _
    echo ""
}
