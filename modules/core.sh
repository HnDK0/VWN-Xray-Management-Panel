# =================================================================
# core.sh — Общие системные функции, хелперы
# =================================================================

VWN_CONFIG_DIR="/usr/local/lib/vwn/config"

# Безопасно изменяет JSON файл через jq
# Использование: edit_json файл.json jq_filter [аргументы...]
# Делает бэкап, проверяет результат, откатывает при ошибке
edit_json() {
    local file="$1" filter="$2"; shift 2
    [ ! -f "$file" ] && return 1

    local tmp=$(mktemp)
    trap 'rm -f "$tmp"' RETURN

    if jq "$filter" "$@" "$file" > "$tmp"; then
        if jq . "$tmp" &>/dev/null; then
            cat "$tmp" > "$file"
            return 0
        fi
    fi

    echo "WARN: edit_json failed for $file, no changes applied" >&2
    return 1
}

# Безопасно экранирует любую строку для использования в sed замене
# Использование: sed -i "s/ПАТТЕРН/$(sed_escape "$СТРОКА")/" файл
sed_escape() {
    printf '%s\n' "$1" | sed '
        s/[\/&]/\\&/g;
        s/\./\\&/g;
        s/\*/\\&/g;
        s/\^/\\&/g;
        s/\$/\\&/g;
        s/\[/\\&/g;
        s/\]/\\&/g;
        s/(/\\&/g;
        s/)/\\&/g;
    '
}

# Рендерит шаблон конфиг с подстановкой переменных
# render_config шаблон.json выходной.json
render_config() {
    local template="$1" output="$2"; shift 2
    local content
    content=$(cat "$template")
    while [ $# -ge 2 ]; do
        content="${content//__${1}__/$2}"
        shift 2
    done
    echo "$content" > "$output"
}

rebuildAllConfigs() {
    echo -e "${cyan}Rebuilding ALL configs...${reset}"
    echo ""

    [ -f "$configPath" ] && {
        rebuildXrayConfigs true
        echo ""
    }

    [ -f "$realityConfigPath" ] && {
        rebuildRealityConfigs true
        echo ""
    }

    [ -f "$visionConfigPath" ] && {
        rebuildVisionConfigs true
        echo ""
    }

    echo -e "${cyan}Rebuilding subscription files...${reset}"
    rebuildAllSubFiles 2>/dev/null || true

    echo "${green}All configs rebuilt successfully.${reset}"
}

VWN_VERSION="3.1"
VWN_LIB="/usr/local/lib/vwn"

# Цвета
red=$(tput setaf 1)$(tput bold)
green=$(tput setaf 2)$(tput bold)
yellow=$(tput setaf 3)$(tput bold)
cyan=$(tput setaf 6)$(tput bold)
reset=$(tput sgr0)

# Пути конфигов
configPath='/usr/local/etc/xray/config.json'
realityConfigPath='/usr/local/etc/xray/reality.json'
nginxPath='/etc/nginx/conf.d/xray.conf'
cf_key_file="/root/.cloudflare_api"
visionConfigPath='/usr/local/etc/xray/vision.json'
warpDomainsFile='/usr/local/etc/xray/warp_domains.txt'
relayDomainsFile='/usr/local/etc/xray/relay_domains.txt'
relayConfigFile='/usr/local/etc/xray/relay.conf'
psiphonDomainsFile='/usr/local/etc/xray/psiphon_domains.txt'

# ── Системный DNS — предотвращает утечку через DNS хостера ─────────
setupSystemDNS() {
    # ✅ Защита от повторного запуска
    if [ -f "/usr/local/etc/xray/.dns_configured" ]; then
        return 0
    fi

    # Используем Quad9 + Google DNS вместо DNS хостера
    local dns_servers="9.9.9.9 8.8.8.8"
    local resolv_conf="/etc/resolv.conf"

    if systemctl is-active --quiet systemd-resolved; then
        echo "info: setting DNS via systemd-resolved..."
        
        # ✅ ЕДИНСТВЕННЫЙ ПРАВИЛЬНЫЙ СПОСОБ: отключаем DNS из DHCP
        mkdir -p /etc/systemd/resolved.conf.d
        cat > /etc/systemd/resolved.conf.d/99-vwn-dns.conf << DNSCONF
[Resolve]
DNS=9.9.9.9 8.8.8.8
FallbackDNS=1.1.1.1
Domains=~.
DNSSEC=no
Cache=yes
DNSOverTLS=no
DNSCONF

        systemctl restart systemd-resolved 2>/dev/null || true
        
        echo "✅ system DNS set successfully, DHCP DNS blocked"
        return 0
    fi

    # Только если systemd-resolved НЕ установлен и не работает
    echo "info: no systemd-resolved, writing direct resolv.conf"
    
    chattr -i "$resolv_conf" 2>/dev/null
    
    # ✅ Полностью перезаписываем но НЕ ТРОГАЕМ СИМЛИНК
    cat > "$resolv_conf" << RESOLVEOF
# VWN DNS: утечка через DNS хостера заблокирована
nameserver 9.9.9.9
nameserver 8.8.8.8
options edns0 trust-ad timeout:1 attempts:1
RESOLVEOF

    chmod 644 "$resolv_conf"
    
    echo "✅ resolv.conf overwritten successfully"
    
    # ✅ Маркируем что уже сделано - больше никогда не запустимся автоматически
    mkdir -p /usr/local/etc/xray
    touch "/usr/local/etc/xray/.dns_configured"
}

unlockSystemDNS() {
    chattr -i /etc/resolv.conf 2>/dev/null || true
}
psiphonConfigFile='/usr/local/etc/xray/psiphon.json'
psiphonBin='/usr/local/bin/psiphon-tunnel-core'
torDomainsFile='/usr/local/etc/xray/tor_domains.txt'
TOR_CONFIG="/etc/tor/torrc"

VWN_CONF='/usr/local/etc/xray/vwn.conf'
USERS_FILE="/usr/local/etc/xray/users.conf"
export USERS_FILE

# ============================================================
# УТИЛИТЫ: vwn.conf get/set
# ============================================================

vwn_conf_get() {
    local key="$1"
    grep "^${key}=" "$VWN_CONF" 2>/dev/null | cut -d= -f2-
}

vwn_conf_set() {
    local key="$1" val="$2"
    mkdir -p "$(dirname "$VWN_CONF")"
    touch "$VWN_CONF"
    if grep -q "^${key}=" "$VWN_CONF" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${val}|" "$VWN_CONF"
    else
        echo "${key}=${val}" >> "$VWN_CONF"
    fi
}

vwn_conf_del() {
    local key="$1"
    sed -i "/^${key}=/d" "$VWN_CONF" 2>/dev/null || true
}

# ============================================================
# УТИЛИТЫ: xray пользователь, логи, сервис
# ============================================================

create_xray_user() {
    if ! id xray &>/dev/null; then
        useradd -r -s /sbin/nologin -d /usr/local/etc/xray xray
        echo "info: user xray created."
    fi
}

setup_xray_logs() {
    mkdir -p /var/log/xray
    chown -R xray:xray /var/log/xray 2>/dev/null || true
    chmod 750 /var/log/xray
    touch /var/log/xray/error.log /var/log/xray/access.log
    chown xray:xray /var/log/xray/*.log 2>/dev/null || true
}

fix_xray_service() {
    local svc
    for f in /etc/systemd/system/xray.service /usr/lib/systemd/system/xray.service /lib/systemd/system/xray.service; do
        [ -f "$f" ] && svc="$f" && break
    done
    if [ -n "$svc" ]; then
        sed -i 's/User=nobody/User=xray/' "$svc"
        if ! grep -q "CapabilityBoundingSet" "$svc"; then
            sed -i '/\[Service\]/a CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE\nAmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE' "$svc"
        fi
        systemctl daemon-reload
    fi
}

view_log() {
    local file="$1" service="$2"
    if [ -f "$file" ]; then
        tail -n 50 "$file"
    else
        if [ -n "$service" ]; then
            journalctl -u "$service" -n 50 --no-pager 2>/dev/null || echo "$(msg no_logs)"
        else
            echo "$(msg no_logs)"
        fi
    fi
}

# ============================================================
# СИСТЕМА
# ============================================================

isRoot() {
    if [[ "$EUID" -ne 0 ]]; then
        echo "${red}$(msg run_as_root)${reset}"
        exit 1
    fi
}

prepareApt() {
    # Убиваем все зависшие процессы пакетного менеджера
    killall -9 apt apt-get dpkg dpkg-deb unattended-upgrades 2>/dev/null || true
    
    # Принудительно снимаем блокировки файлов
    fuser -kk /var/lib/dpkg/lock* /var/cache/apt/archives/lock /var/lib/apt/lists/lock* 2>/dev/null || true
    sleep 0.5
    
    # Удаляем файлы блокировок
    rm -f /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend /var/cache/apt/archives/lock /var/lib/apt/lists/lock*
    
    # Исправляем сломанное состояние dpkg
    export DEBIAN_FRONTEND=noninteractive
    dpkg --configure -a --force-confold --force-confdef 2>/dev/null || true
}

identifyOS() {
    if [[ "$(uname)" != 'Linux' ]]; then
        echo "error: This operating system is not supported."
        exit 1
    fi
    if command -v apt &>/dev/null; then
        PACKAGE_MANAGEMENT_INSTALL='timeout 300 apt-get -y --no-install-recommends -o Dpkg::Lock::Timeout=60 -o Acquire::http::Timeout=30 -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" install'
        PACKAGE_MANAGEMENT_REMOVE='apt purge -y'
        PACKAGE_MANAGEMENT_UPDATE='timeout 120 apt-get update -o Acquire::http::Timeout=30'
    elif command -v dnf &>/dev/null; then
        PACKAGE_MANAGEMENT_INSTALL='timeout 300 dnf -y install --setopt=install_weak_deps=False'
        PACKAGE_MANAGEMENT_REMOVE='dnf remove -y'
        PACKAGE_MANAGEMENT_UPDATE='timeout 120 dnf update'
        ${PACKAGE_MANAGEMENT_INSTALL} 'epel-release' &>/dev/null
    elif command -v yum &>/dev/null; then
        PACKAGE_MANAGEMENT_INSTALL='timeout 300 yum -y install --setopt=install_weak_deps=False'
        PACKAGE_MANAGEMENT_REMOVE='yum remove -y'
        PACKAGE_MANAGEMENT_UPDATE='timeout 120 yum update'
        ${PACKAGE_MANAGEMENT_INSTALL} 'epel-release' &>/dev/null
    else
        echo "error: Package manager not supported."
        exit 1
    fi
}

installPackage() {
    local pkg="$1"

    echo -n "  ${pkg}... "

    # Пропускаем уже установленные пакеты без вызова apt
    if dpkg -s "$pkg" &>/dev/null && dpkg -s "$pkg" 2>/dev/null | grep -q "^Status: install ok installed"; then
        echo "${green}SKIP${reset}"
        return 0
    fi

    export DEBIAN_FRONTEND=noninteractive
    # Используем PACKAGE_MANAGEMENT_INSTALL напрямую — он уже содержит timeout 300
    if ${PACKAGE_MANAGEMENT_INSTALL} "$pkg" >/dev/null 2>&1; then
        echo "${green}OK${reset}"
        return 0
    fi

    # При ошибке — чиним apt и пробуем ещё раз
    echo "${yellow}RETRY${reset}"
    prepareApt
    ${PACKAGE_MANAGEMENT_UPDATE} >/dev/null 2>&1 || true

    if ${PACKAGE_MANAGEMENT_INSTALL} "$pkg" >/dev/null 2>&1; then
        echo "${green}OK (retry)${reset}"
        return 0
    else
        echo "${red}FAIL${reset}"
        return 1
    fi
}

uninstallPackage() {
    ${PACKAGE_MANAGEMENT_REMOVE} "$1" && echo "info: $1 uninstalled."
}

run_task() {
    local m="$1"; shift
    echo -e "\n${yellow}>>> $m${reset}"
    if eval "$@"; then
        echo -e "[${green} DONE ${reset}] $m"
    else
        echo -e "[${red} FAIL ${reset}] $m"
        return 1
    fi
}

setupAlias() {
    ln -sf "$VWN_LIB/../bin/vwn" /usr/local/bin/vwn 2>/dev/null || true
}

# Загрузка всех модулей системы
loadAllModules() {
    local modules=(lang core xray nginx warp reality relay psiphon tor security logs backup users diag privacy adblock vision xhttp menu)
    
    for module in "${modules[@]}"; do
        if [ -f "$VWN_LIB/${module}.sh" ]; then
            # shellcheck source=/dev/null
            source "$VWN_LIB/${module}.sh"
        else
            echo "ERROR: Module ${module}.sh not found in $VWN_LIB"
            echo "Reinstall: bash <(curl -fsSL https://raw.githubusercontent.com/HnDK0/VLESS-WebSocket-TLS-Nginx-WARP/main/install.sh)"
            exit 1
        fi
    done
}

setupSwap() {
    # Если swap уже есть — не трогаем
    local swap_total
    swap_total=$(free -m | awk '/^Swap:/{print $2}')
    if [ "${swap_total:-0}" -gt 256 ]; then
        echo "info: Swap already exists (${swap_total}MB), skipping."
        return 0
    fi

    # Определяем размер swap в зависимости от RAM
    local ram_mb swap_mb
    ram_mb=$(free -m | awk '/^Mem:/{print $2}')
    if   [ "$ram_mb" -le 512 ];  then swap_mb=1024
    elif [ "$ram_mb" -le 1024 ]; then swap_mb=1024
    elif [ "$ram_mb" -le 2048 ]; then swap_mb=2048
    else swap_mb=1024
    fi

    echo -e "${cyan}$(msg swap_creating) ${swap_mb}MB...${reset}"

    # Создаём swap-файл
    local swapfile="/swapfile"

    if fallocate -l "${swap_mb}M" "$swapfile" 2>/dev/null || \
       dd if=/dev/zero of="$swapfile" bs=1M count="$swap_mb" status=none; then
        chmod 600 "$swapfile"
        mkswap "$swapfile" &>/dev/null
        swapon "$swapfile" || true
        # Прописываем в fstab чтобы swap выжил после перезагрузки
        if ! grep -q "$swapfile" /etc/fstab; then
            echo "$swapfile none swap sw 0 0" >> /etc/fstab
        fi
        # Настраиваем swappiness — не злоупотреблять swap
        sysctl -w vm.swappiness=10 &>/dev/null
        grep -q "vm.swappiness" /etc/sysctl.conf || echo "vm.swappiness=10" >> /etc/sysctl.conf
        echo "${green}$(msg swap_created) ${swap_mb}MB${reset}"
    else
        echo "${yellow}$(msg swap_fail)${reset}"
    fi
}

findFreePort() {
    local start="${1:-20000}" end="${2:-20999}"
    local port
    for port in $(seq "$start" "$end"); do
        if ! ss -tlnp 2>/dev/null | grep -q ":${port} "; then
            echo "$port"
            return 0
        fi
    done
    return 1  # не нашли свободный порт
}

generateRandomPath() {
    local hex
    hex=$(openssl rand -hex 16)
    echo "/v2/api/${hex}"
}

# ============================================================
# СЕТЬ
# ============================================================

getServerIP() {
    local urls=(
        "https://api.ipify.org"
        "https://ipv4.icanhazip.com"
        "https://checkip.amazonaws.com"
    )

    local tmpdir
    tmpdir=$(mktemp -d)
    local pids=()

    local i
    for i in "${!urls[@]}"; do
        (curl -s --max-time 3 "${urls[$i]}" > "$tmpdir/$i" 2>/dev/null) &
        pids+=($!)
    done

    # trap устанавливаем после заполнения pids
    trap 'rm -rf "$tmpdir"; kill "${pids[@]}" 2>/dev/null' RETURN INT TERM

    local attempts=0
    while [ $attempts -lt 15 ]; do
        for f in "$tmpdir"/*; do
            [ -s "$f" ] || continue
            local ip
            ip=$(cat "$f" 2>/dev/null | tr -d '[:space:]')
            if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && ! [[ "$ip" =~ ^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.) ]]; then
                kill "${pids[@]}" 2>/dev/null || true
                echo "$ip"
                return 0
            fi
        done
        sleep 0.2
        attempts=$((attempts + 1))
    done

    # Fallback: локальный маршрут
    kill "${pids[@]}" 2>/dev/null || true
    local ip
    ip=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')
    echo "${ip:-UNKNOWN}"
}

# ============================================================
# СТАТУС СЕРВИСОВ
# ============================================================

getServiceStatus() {
    if systemctl is-active --quiet "$1" 2>/dev/null; then
        echo "${green}RUNNING${reset}"
    else
        echo "${red}STOPPED${reset}"
    fi
}

# Определяем режим туннеля по конфигу Xray
_getTunnelMode() {
    local tag="$1"
    local mode=""
    if [ -f "$configPath" ]; then
        mode=$(jq -r --arg t "$tag" \
            '.routing.rules[] | select(.outboundTag==$t) |
             if .port == "0-65535" then "Global"
             elif (.domain | length) > 0 then "Split"
             else "OFF" end' \
            "$configPath" 2>/dev/null | head -1)
    fi
    echo "${mode:-OFF}"
}

getWarpStatusRaw() {
    if command -v warp-cli &>/dev/null; then
        local out
        out=$(warp-cli --accept-tos status 2>/dev/null || warp-cli status 2>/dev/null)
        echo "$out" | grep -q "Connected" && echo "ACTIVE" || echo "OFF"
    else
        echo "NOT_INSTALLED"
    fi
}

getWarpStatus() {
    local raw
    raw=$(getWarpStatusRaw)
    if [ "$raw" = "NOT_INSTALLED" ]; then
        echo "${red}NOT INSTALLED${reset}"; return
    fi
    if [ "$raw" != "ACTIVE" ]; then
        echo "${red}OFF${reset}"; return
    fi
    local mode
    mode=$(_getTunnelMode "warp")
    case "$mode" in
        Global) echo "${green}ACTIVE | $(msg mode_global)${reset}" ;;
        Split)  echo "${green}ACTIVE | $(msg mode_split)${reset}" ;;
        *)      echo "${yellow}ACTIVE | $(msg mode_off)${reset}" ;;
    esac
}

getBbrStatus() {
    sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q "bbr" \
        && echo "${green}ON${reset}" || echo "${red}OFF${reset}"
}

getF2BStatus() {
    systemctl is-active --quiet fail2ban 2>/dev/null \
        && echo "${green}ON${reset}" || echo "${red}OFF${reset}"
}

getWebJailStatus() {
    if [ -f /etc/fail2ban/filter.d/nginx-probe.conf ]; then
        fail2ban-client status nginx-probe &>/dev/null \
            && echo "${green}PROTECTED${reset}" || echo "${yellow}OFF${reset}"
    else
        echo "${red}NO${reset}"
    fi
}

getCfGuardStatus() {
    [ -f /etc/nginx/conf.d/cf_guard.conf ] \
        && echo "${green}ON${reset}" || echo "${red}OFF${reset}"
}

checkCertExpiry() {
    if [ -f /etc/nginx/cert/cert.pem ]; then
        local expire_date expire_epoch now_epoch days_left
        expire_date=$(openssl x509 -enddate -noout -in /etc/nginx/cert/cert.pem | cut -d= -f2)
        expire_epoch=$(date -d "$expire_date" +%s)
        now_epoch=$(date +%s)
        days_left=$(( (expire_epoch - now_epoch) / 86400 ))
        if   [ "$days_left" -le 0  ]; then echo "${red}EXPIRED!${reset}"
        elif [ "$days_left" -lt 15 ]; then echo "${red}${days_left}d${reset}"
        else echo "${green}OK (${days_left}d)${reset}"; fi
    else
        echo "${red}MISSING${reset}"
    fi
}

# ============================================================
# УТИЛИТА: выравнивание текста по ширине колонки
# Использование: _pad "строка" ширина
# Корректно работает со строками содержащими ANSI escape коды
# ============================================================
_pad() {
    local v="$1" w="$2" vis
    vis=$(printf '%s' "$v" | sed 's/\x1b\[[0-9;]*[mABCDJKHf]//g; s/\x1b(B//g')
    printf "%s%*s" "$v" $((w - ${#vis})) ""
}

# ============================================================
# УТИЛИТА: конвертация файла доменов в JSON-массив для Xray
# Убирает префикс domain:, ведущую точку, конвертирует IDN
# ============================================================
domainsToJson() {
    local file="$1"
    [ ! -f "$file" ] && echo "" && return
    local result=""
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line#domain:}"
        line="${line#.}"
        line=$(echo "$line" | tr -d '[:space:]')
        [ -z "$line" ] && continue
        if echo "$line" | grep -qP '[^\x00-\x7F]' 2>/dev/null; then
            line=$(L="$line" python3 -c "import os,encodings.idna; parts=os.environ['L'].split('.'); print('.'.join(encodings.idna.ToASCII(p).decode() for p in parts))" 2>/dev/null || echo "$line")
        fi
        [ -n "$result" ] && result="$result,"
        result="$result\"domain:$line\""
    done < "$file"
    echo "$result"
}