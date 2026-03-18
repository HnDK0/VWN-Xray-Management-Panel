#!/bin/bash
# =================================================================
# core.sh — Общие переменные, утилиты, статус-функции
# =================================================================

VWN_VERSION="4.0"
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
VWN_CONF='/usr/local/etc/xray/vwn.conf'
cf_key_file="/root/.cloudflare_api"
warpDomainsFile='/usr/local/etc/xray/warp_domains.txt'
relayDomainsFile='/usr/local/etc/xray/relay_domains.txt'
relayConfigFile='/usr/local/etc/xray/relay.conf'
psiphonDomainsFile='/usr/local/etc/xray/psiphon_domains.txt'
psiphonConfigFile='/usr/local/etc/xray/psiphon.json'
psiphonBin='/usr/local/bin/psiphon-tunnel-core'
torDomainsFile='/usr/local/etc/xray/tor_domains.txt'

# HAProxy убран — nginx держит TLS напрямую
# Путь к сертификату
nginxCertDir='/etc/nginx/cert'
nginxCert='/etc/nginx/cert/cert.pem'
nginxCertKey='/etc/nginx/cert/cert.key'

# nginx конфиг
nginxPath='/etc/nginx/conf.d/xray.conf'

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
# СИСТЕМА
# ============================================================

isRoot() {
    if [[ "$EUID" -ne 0 ]]; then
        echo "${red}$(msg run_as_root)${reset}"
        exit 1
    fi
}

identifyOS() {
    if [[ "$(uname)" != 'Linux' ]]; then
        echo "error: This operating system is not supported."
        exit 1
    fi
    if command -v apt &>/dev/null; then
        PACKAGE_MANAGEMENT_INSTALL='apt -y --no-install-recommends install'
        PACKAGE_MANAGEMENT_REMOVE='apt purge -y'
        PACKAGE_MANAGEMENT_UPDATE='apt update'
    elif command -v dnf &>/dev/null; then
        PACKAGE_MANAGEMENT_INSTALL='dnf -y install'
        PACKAGE_MANAGEMENT_REMOVE='dnf remove -y'
        PACKAGE_MANAGEMENT_UPDATE='dnf update'
    elif command -v yum &>/dev/null; then
        PACKAGE_MANAGEMENT_INSTALL='yum -y install'
        PACKAGE_MANAGEMENT_REMOVE='yum remove -y'
        PACKAGE_MANAGEMENT_UPDATE='yum update'
        ${PACKAGE_MANAGEMENT_INSTALL} 'epel-release' &>/dev/null
    else
        echo "error: Package manager not supported."
        exit 1
    fi
}

installPackage() {
    local pkg="$1"
    if ${PACKAGE_MANAGEMENT_INSTALL} "$pkg" &>/dev/null; then
        echo "info: $pkg installed."
    else
        echo "warn: Fixing dependencies for $pkg..."
        dpkg --configure -a 2>/dev/null || true
        ${PACKAGE_MANAGEMENT_UPDATE} &>/dev/null || true
        if ${PACKAGE_MANAGEMENT_INSTALL} "$pkg"; then
            echo "info: $pkg installed after fix."
        else
            echo "${red}error: Installation of $pkg failed.${reset}"
            return 1
        fi
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

setupSwap() {
    local swap_total
    swap_total=$(free -m | awk '/^Swap:/{print $2}')
    if [ "${swap_total:-0}" -gt 256 ]; then
        echo "info: Swap already exists (${swap_total}MB), skipping."
        return 0
    fi

    local ram_mb swap_mb
    ram_mb=$(free -m | awk '/^Mem:/{print $2}')
    if   [ "$ram_mb" -le 512 ];  then swap_mb=1024
    elif [ "$ram_mb" -le 1024 ]; then swap_mb=1024
    elif [ "$ram_mb" -le 2048 ]; then swap_mb=2048
    else swap_mb=1024
    fi

    echo -e "${cyan}$(msg swap_creating) ${swap_mb}MB...${reset}"

    local swapfile="/swapfile"
    if fallocate -l "${swap_mb}M" "$swapfile" 2>/dev/null || \
       dd if=/dev/zero of="$swapfile" bs=1M count="$swap_mb" status=none; then
        chmod 600 "$swapfile"
        mkswap "$swapfile" &>/dev/null
        swapon "$swapfile"
        if ! grep -q "$swapfile" /etc/fstab; then
            echo "$swapfile none swap sw 0 0" >> /etc/fstab
        fi
        sysctl -w vm.swappiness=10 &>/dev/null
        grep -q "vm.swappiness" /etc/sysctl.conf || echo "vm.swappiness=10" >> /etc/sysctl.conf
        echo "${green}$(msg swap_created) ${swap_mb}MB${reset}"
    else
        echo "${yellow}$(msg swap_fail)${reset}"
    fi
}

generateRandomPath() {
    echo "/$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 12)"
}

# ============================================================
# СЕТЬ
# ============================================================

getServerIP() {
    local ip
    for url in \
        "https://api.ipify.org" \
        "https://ipv4.icanhazip.com" \
        "https://checkip.amazonaws.com" \
        "https://api4.my-ip.io/ip" \
        "https://ipv4.wtfismyip.com/text"; do
        ip=$(curl -s --connect-timeout 5 "$url" 2>/dev/null | tr -d '[:space:]')
        if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            if ! [[ "$ip" =~ ^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.) ]]; then
                echo "$ip"; return
            fi
        fi
    done
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
        out=$(warp-cli --accept-tos status 2>/dev/null)
        if echo "$out" | grep -qi "connected"; then
            echo "ACTIVE"
            return
        fi
        if curl -s --connect-timeout 2 -x socks5://127.0.0.1:40000 https://api.ipify.org &>/dev/null; then
            echo "ACTIVE"
            return
        fi
        echo "OFF"
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
    local cert_file="/etc/nginx/cert/cert.pem"
    if [ -f "$cert_file" ]; then
        local expire_date expire_epoch now_epoch days_left
        expire_date=$(openssl x509 -enddate -noout -in "$cert_file" | cut -d= -f2)
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
# ============================================================
_pad() {
    local v="$1" w="$2" vis
    vis=$(printf '%s' "$v" | sed 's/\x1b\[[0-9;]*[mABCDJKHf]//g; s/\x1b(B//g')
    printf "%s%*s" "$v" $((w - ${#vis})) ""
}

# ============================================================
# УТИЛИТА: конвертация файла доменов в JSON-массив для Xray
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
            if command -v python3 &>/dev/null; then
                line=$(python3 -c "import encodings.idna; parts='$line'.split('.'); print('.'.join(encodings.idna.ToASCII(p).decode() for p in parts))" 2>/dev/null || echo "$line")
            fi
        fi
        [ -n "$result" ] && result="$result,"
        result="$result\"domain:$line\""
    done < "$file"
    echo "$result"
}

# ============================================================
# УТИЛИТЫ: создание пользователя Xray и настройка логов
# ============================================================

create_xray_user() {
    # xray больше не читает TLS-сертификаты напрямую,
    # поэтому группа ssl-cert не нужна
    if ! id xray &>/dev/null; then
        useradd -r -s /sbin/nologin -d /usr/local/etc/xray xray
        echo "info: user xray created."
    fi
}

setup_xray_logs() {
    mkdir -p /var/log/xray
    chown -R xray:xray /var/log/xray
    chmod 750 /var/log/xray
    touch /var/log/xray/error.log /var/log/xray/access.log
    chown xray:xray /var/log/xray/*.log
}

# ============================================================
# УТИЛИТА: унифицированный просмотр логов
# ============================================================
view_log() {
    local file="$1"
    local service="$2"
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
