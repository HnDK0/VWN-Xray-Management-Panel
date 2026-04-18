#!/usr/bin/env bash
# =================================================================
# lib/network.sh — Сетевые утилиты
#
# Предоставляет:
#   ufw_allow_port()        — открыть порт в UFW
#   ufw_delete_comment()    — удалить правила по комментарию
#   ufw_open_80/close_80()  — для ACME-верификации
#   generateRandomPath()    — безопасный случайный WS-путь
#   port_is_free()          — проверить что порт не занят
#   findFreePort()          — найти свободный порт в диапазоне
#
# Зависимости: logging.sh
# =================================================================

# -----------------------------------------------------------------
# UFW: открыть порт
# Использование: ufw_allow_port 443 tcp "HTTPS"
# -----------------------------------------------------------------
ufw_allow_port() {
    local port="$1" proto="${2:-tcp}" comment="${3:-VWN}"
    ufw allow "${port}/${proto}" comment "$comment" &>/dev/null || true
    log_info "UFW: allow ${port}/${proto} ($comment)"
}

# -----------------------------------------------------------------
# UFW: удалить все правила с заданным комментарием
# -----------------------------------------------------------------
ufw_delete_comment() {
    local comment="$1"
    ufw status numbered 2>/dev/null \
        | grep "$comment" \
        | awk -F'[][]' '{print $2}' \
        | sort -rn \
        | while read -r n; do
            echo 'y' | ufw delete "$n" &>/dev/null || true
          done
    log_info "UFW: deleted rules with comment='$comment'"
}

# -----------------------------------------------------------------
# UFW: временно открыть 80 для ACME (вызывается из vwn open-80)
# -----------------------------------------------------------------
ufw_open_80() {
    ufw status 2>/dev/null | grep -q inactive && return 0
    ufw allow from any to any port 80 proto tcp comment 'ACME temp' &>/dev/null
    log_info "UFW: opened 80 for ACME"
}

ufw_close_80() {
    ufw status 2>/dev/null | grep -q inactive && return 0
    ufw_delete_comment 'ACME temp'
    log_info "UFW: closed 80"
}

# Псевдонимы для совместимости с modules/nginx.sh
openPort80()  { ufw_open_80; }
closePort80() { ufw_close_80; }

# -----------------------------------------------------------------
# Проверка свободности порта
# -----------------------------------------------------------------
port_is_free() {
    local port="$1"
    ! ss -tlnp 2>/dev/null | grep -q ":${port} "
}

# -----------------------------------------------------------------
# Поиск первого свободного порта в диапазоне
# Использование: findFreePort [start] [end]
# Вывод: номер порта или пустая строка при неудаче
# -----------------------------------------------------------------
findFreePort() {
    local start="${1:-20000}" end="${2:-20999}"
    local port
    for port in $(seq "$start" "$end"); do
        if port_is_free "$port"; then
            echo "$port"
            return 0
        fi
    done
    log_warn "No free port found in range $start-$end"
    return 1
}

# -----------------------------------------------------------------
# Генерация случайного WS-пути (криптобезопасно)
# Возвращает: /v2/api/<16-hex-chars>   — совместимо с оригиналом
# -----------------------------------------------------------------
generateRandomPath() {
    local hex
    # Используем openssl если есть, иначе /dev/urandom
    if command -v openssl &>/dev/null; then
        hex=$(openssl rand -hex 16)
    elif [[ -r /dev/urandom ]]; then
        hex=$(cat /dev/urandom | tr -dc 'a-f0-9' | head -c 32)
    else
        # Последний fallback через $RANDOM
        hex=$(printf '%04x%04x%04x%04x' $RANDOM $RANDOM $RANDOM $RANDOM)
    fi
    echo "/v2/api/${hex}"
}

# -----------------------------------------------------------------
# Получение публичного IP сервера (параллельные запросы)
# Возвращает первый ответ из нескольких источников
# -----------------------------------------------------------------
getServerIP() {
    local -a urls=(
        "https://api.ipify.org"
        "https://ipv4.icanhazip.com"
        "https://checkip.amazonaws.com"
    )

    local tmpdir; tmpdir=$(mktemp -d)
    # shellcheck disable=SC2064
    trap "rm -rf '${tmpdir}'" RETURN INT TERM

    local pids=()
    local i
    for i in "${!urls[@]}"; do
        (curl -s --max-time 5 "${urls[$i]}" > "${tmpdir}/$i" 2>/dev/null) &
        pids+=($!)
    done

    local attempts=0
    while (( attempts < 25 )); do
        for f in "${tmpdir}"/*; do
            [[ -s "$f" ]] || continue
            local ip; ip=$(cat "$f" 2>/dev/null | tr -d '[:space:]')
            if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] \
                && ! [[ "$ip" =~ ^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.) ]]; then
                kill "${pids[@]}" 2>/dev/null || true
                echo "$ip"
                return 0
            fi
        done
        sleep 0.2
        (( attempts++ )) || true
    done

    kill "${pids[@]}" 2>/dev/null || true

    # Fallback: локальный маршрут
    local ip; ip=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')
    echo "${ip:-UNKNOWN}"
}
