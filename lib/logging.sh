#!/usr/bin/env bash
# =================================================================
# lib/logging.sh — Система логирования
#
# Все записи в лог идут только через эти функции.
# Файл: /var/log/vwn_install.log
# Формат: [ЧЧ:ММ:СС] [УРОВЕНЬ] Сообщение
# =================================================================

# LOG_FILE объявлен как readonly в install.sh
# Если вызывается автономно — устанавливаем дефолт
: "${LOG_FILE:=/var/log/vwn_install.log}"

_log() {
    local level="$1"; shift
    local ts; ts=$(date '+%H:%M:%S' 2>/dev/null || echo "??:??:??")
    printf '[%s] [%-5s] %s\n' "$ts" "$level" "$*" >> "$LOG_FILE" 2>/dev/null || true
}

log_info()  { _log "INFO " "$@"; }
log_ok()    { _log "OK   " "$@"; }
log_warn()  { _log "WARN " "$@"; }
log_error() { _log "ERROR" "$@"; }
log_debug() { _log "DEBUG" "$@"; }

# Инициализация лог-файла (заголовок сессии)
log_session_start() {
    mkdir -p "$(dirname "$LOG_FILE")"
    {
        echo "================================================================"
        echo "VWN Install Log — $(date '+%Y-%m-%d %H:%M:%S')"
        echo "PID: $$  |  Args: $*"
        echo "================================================================"
    } >> "$LOG_FILE" 2>/dev/null || true
}
