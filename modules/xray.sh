#!/bin/bash
# =================================================================
# xray.sh — Конфиг Xray VLESS+WebSocket+TLS, параметры, QR-код
# =================================================================

# =================================================================
# Получение флага страны по IP сервера
# Возвращает emoji флага, например 🇩🇪
# При ошибке возвращает 🌐
# =================================================================
_getCountryFlag() {
    local ip="$1"
    local code
    code=$(curl -s --connect-timeout 5 "http://ip-api.com/line/${ip}?fields=countryCode" 2>/dev/null | tr -d '[:space:]')
    if [[ "$code" =~ ^[A-Z]{2}$ ]]; then
        # Конвертируем код страны в emoji флаг через региональные индикаторы
        # A=0x1F1E6, поэтому каждая буква = 0x1F1E6 + (ord - ord('A'))
        python3 -c "
c='${code}'
flag=''.join(chr(0x1F1E6 + ord(ch) - ord('A')) for ch in c)
print(flag)
" 2>/dev/null || echo "🌐"
    else
        echo "🌐"
    fi
}

# Возвращает суффикс активных Global режимов для имени конфига
# Примеры: " 🌐☁️🇩🇪", " 🌐🔱🇳🇱🌉🇺🇸🧅🇫🇷", ""
# Split режимы НЕ отображаются — только Global
_getActiveModesSuffix() {
    local suffix=""
    local has_global=false
    
    # Проверяем WARP Global
    local warp_global=false
    if [ -f "$configPath" ]; then
        local warp_mode
        warp_mode=$(jq -r '.routing.rules[] | select(.outboundTag=="warp") | if .port == "0-65535" then "Global" else "OFF" end' "$configPath" 2>/dev/null | head -1)
        [ "$warp_mode" = "Global" ] && warp_global=true
    fi
    
    # Проверяем Psiphon Global + страна
    local psiphon_global=false
    local psiphon_country=""
    if [ -f "$configPath" ]; then
        local ps_mode
        ps_mode=$(jq -r '.routing.rules[] | select(.outboundTag=="psiphon") | if .port == "0-65535" then "Global" else "OFF" end' "$configPath" 2>/dev/null | head -1)
        [ "$ps_mode" = "Global" ] && psiphon_global=true
    fi
    [ "$psiphon_global" = true ] && [ -f "$psiphonConfigFile" ] &&         psiphon_country=$(jq -r '.EgressRegion // ""' "$psiphonConfigFile" 2>/dev/null)
    
    # Проверяем Relay Global + страна (через ip-api на RELAY_HOST)
    local relay_global=false
    local relay_country=""
    if [ -f "$configPath" ]; then
        local relay_mode
        relay_mode=$(jq -r '.routing.rules[] | select(.outboundTag=="relay") | if .port == "0-65535" then "Global" else "OFF" end' "$configPath" 2>/dev/null | head -1)
        [ "$relay_mode" = "Global" ] && relay_global=true
    fi
    if [ "$relay_global" = true ] && [ -f "$relayConfigFile" ]; then
        local relay_host=""
        relay_host=$(source "$relayConfigFile" 2>/dev/null && echo "$RELAY_HOST")
        if [ -n "$relay_host" ]; then
            relay_country=$(curl -s --connect-timeout 5 "http://ip-api.com/line/${relay_host}?fields=countryCode" 2>/dev/null | tr -d '[:space:]')
        fi
    fi
    
    # Проверяем TOR Global + страна
    local tor_global=false
    local tor_country=""
    if [ -f "$configPath" ]; then
        local t_mode
        t_mode=$(jq -r '.routing.rules[] | select(.outboundTag=="tor") | if .port == "0-65535" then "Global" else "OFF" end' "$configPath" 2>/dev/null | head -1)
        [ "$t_mode" = "Global" ] && tor_global=true
    fi
    [ "$tor_global" = true ] &&         tor_country=$(grep "^ExitNodes" "$TOR_CONFIG" 2>/dev/null | grep -oP '\{[A-Z]+\}' | tr -d '{}' | head -1)
    
    # Если хоть один Global — добавляем 🌐
    [ "$warp_global" = true ] || [ "$psiphon_global" = true ] || [ "$relay_global" = true ] || [ "$tor_global" = true ] && has_global=true
    [ "$has_global" = true ] && suffix=" 🌐"
    
    # WARP: ☁️ + флаг страны (запрос через WARP socks5)
    if [ "$warp_global" = true ]; then
        local warp_country=""
        warp_country=$(curl -s --connect-timeout 5 --socks5 127.0.0.1:40000 "http://ip-api.com/line/?fields=countryCode" 2>/dev/null | tr -d '[:space:]')
        if [ -n "$warp_country" ] && [[ "$warp_country" =~ ^[A-Z]{2}$ ]]; then
            local wflag
            wflag=$(python3 -c "c='${warp_country}'; print(''.join(chr(0x1F1E6 + ord(ch) - ord('A')) for ch in c))" 2>/dev/null)
            [ -n "$wflag" ] && suffix="$suffix ☁️$wflag"
        else
            suffix="$suffix ☁️"
        fi
    fi
    
    # Psiphon: 🔱 + флаг страны
    if [ "$psiphon_global" = true ]; then
        if [ -n "$psiphon_country" ] && [[ "$psiphon_country" =~ ^[A-Z]{2}$ ]]; then
            local pflag
            pflag=$(python3 -c "c='${psiphon_country}'; print(''.join(chr(0x1F1E6 + ord(ch) - ord('A')) for ch in c))" 2>/dev/null)
            [ -n "$pflag" ] && suffix="$suffix 🔱$pflag"
        else
            suffix="$suffix 🔱"
        fi
    fi
    
    # Relay: 🌉 + флаг страны
    if [ "$relay_global" = true ]; then
        if [ -n "$relay_country" ] && [[ "$relay_country" =~ ^[A-Z]{2}$ ]]; then
            local rflag
            rflag=$(python3 -c "c='${relay_country}'; print(''.join(chr(0x1F1E6 + ord(ch) - ord('A')) for ch in c))" 2>/dev/null)
            [ -n "$rflag" ] && suffix="$suffix 🌉$rflag"
        else
            suffix="$suffix 🌉"
        fi
    fi
    
    # TOR: 🧅 + флаг страны
    if [ "$tor_global" = true ]; then
        if [ -n "$tor_country" ] && [[ "$tor_country" =~ ^[A-Z]{2}$ ]]; then
            local tflag
            tflag=$(python3 -c "c='${tor_country}'; print(''.join(chr(0x1F1E6 + ord(ch) - ord('A')) for ch in c))" 2>/dev/null)
            [ -n "$tflag" ] && suffix="$suffix 🧅$tflag"
        else
            suffix="$suffix 🧅"
        fi
    fi
    
    # Убираем лишние пробелы
    echo "$suffix" | sed 's/^ *//;s/ *$//;s/  */ /g'
}

# Формирует красивое имя конфига: 🇩🇪 VL-WS | label 🇩🇪 🌐🧅
# Аргументы: тип (WS|Reality), label, [ip]
_getConfigName() {
    local type="$1"
    local label="$2"
    local ip="${3:-$(getServerIP)}"
    local flag
    flag=$(_getCountryFlag "$ip")
    local modes
    modes=$(_getActiveModesSuffix)
    case "$type" in
        WS)       echo "${flag} VL-WS | ${label} ${flag}${modes}" ;;
        Reality)  echo "${flag} VL-Reality | ${label} ${flag}${modes}" ;;
        *)        echo "${flag} VL-${type} | ${label} ${flag}${modes}" ;;
    esac
}

installXray() {
    command -v xray &>/dev/null && { echo "info: xray already installed."; return; }
    bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    create_xray_user
    fix_xray_service
    setup_xray_logs
}

writeXrayConfig() {
    local xrayPort="$1"
    local wsPath="$2"
    local domain="$3"
    local new_uuid
    local USERS_FILE="${USERS_FILE:-/usr/local/etc/xray/users.conf}"
    # Если users.conf уже есть — берём UUID первого пользователя
    if [ -f "$USERS_FILE" ] && [ -s "$USERS_FILE" ]; then
        new_uuid=$(cut -d'|' -f1 "$USERS_FILE" | head -1)
    fi
    [ -z "$new_uuid" ] && new_uuid=$(cat /proc/sys/kernel/random/uuid)
    mkdir -p /usr/local/etc/xray /var/log/xray

    cat > "$configPath" << EOF
{
    "log": {
        "access": "none",
        "error": "/var/log/xray/error.log",
        "loglevel": "error"
    },
    "dns": {
        "servers": [ "127.0.0.1" ]
    },
    "inbounds": [{
        "port": $xrayPort,
        "listen": "127.0.0.1",
        "protocol": "vless",
        "settings": {
            "clients": [{"id": "$new_uuid"}],
            "decryption": "none"
        },
        "streamSettings": {
            "network": "ws",
            "wsSettings": {
                "path": "$wsPath",
                "host": "$domain",
                "heartbeatPeriod": 30
            },
            "sockopt": {
                "tcpKeepAliveIdle": 100,
                "tcpKeepAliveInterval": 10,
                "tcpKeepAliveRetry": 3
            }
        },
        "sniffing": {"enabled": true, "destOverride": ["http", "tls"], "metadataOnly": false, "routeOnly": true}
    }],
    "outbounds": [
        {
            "tag": "free",
            "protocol": "freedom",
            "settings": {"domainStrategy": "AsIs"}
        },
        {
            "tag": "warp",
            "protocol": "socks",
            "settings": {"servers": [{"address": "127.0.0.1", "port": 40000}]}
        },
        {
            "tag": "block",
            "protocol": "blackhole"
        }
    ],
    "routing": {
        "domainStrategy": "AsIs",
        "rules": [
            {
                "type": "field",
                "port": 53,
                "outboundTag": "block"
            },
            {
                "type": "field",
                "ip": ["geoip:private"],
                "outboundTag": "block"
            },
            {
                "type": "field",
                "port": "25, 587, 465, 2525",
                "network": "tcp",
                "outboundTag": "block"
            },
            {
                "type": "field",
                "protocol": ["bittorrent"],
                "outboundTag": "block"
            },
            {
                "type": "field",
                "port": "0-65535",
                "outboundTag": "free"
            }
        ]
    },
    "policy": {
        "levels": {
            "0": {
                "handshake": 4,
                "connIdle": 300,
                "uplinkOnly": 2,
                "downlinkOnly": 5
            }
        }
    }
}
EOF
}

getConfigInfo() {
    if [ ! -f "$configPath" ]; then
        echo "${red}$(msg xray_not_installed)${reset}" >&2
        return 1
    fi
    xray_uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$configPath" 2>/dev/null)
    # Поддержка и ws и xhttp (обратная совместимость)
    xray_path=$(jq -r '.inbounds[0].streamSettings.wsSettings.path // .inbounds[0].streamSettings.xhttpSettings.path' "$configPath" 2>/dev/null)
    xray_port=$(jq -r '.inbounds[0].port' "$configPath" 2>/dev/null)
    xray_userDomain=$(jq -r '.inbounds[0].streamSettings.wsSettings.host // .inbounds[0].streamSettings.xhttpSettings.host // ""' "$configPath" 2>/dev/null)
    if [ -z "$xray_userDomain" ] || [ "$xray_userDomain" = "null" ]; then
        xray_userDomain=$(grep -E '^\s*server_name\s+' "$nginxPath" 2>/dev/null \
            | grep -v 'proxy_ssl' \
            | grep -v 'server_name\s*_;' \
            | awk '{print $2}' | tr -d ';' | grep -v '^_$' | head -1)
    fi
    [ -z "$xray_userDomain" ] && xray_userDomain=$(getServerIP)

    if [ -z "$xray_uuid" ] || [ "$xray_uuid" = "null" ]; then
        echo "${red}$(msg xray_not_installed)${reset}" >&2
        return 1
    fi
}

getShareUrl() {
    local label="${1:-default}"
    getConfigInfo || return 1
    local encoded_path name
    encoded_path=$(python3 -c \
        "import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe='/'))" \
        "$xray_path" 2>/dev/null) || encoded_path="$xray_path"
    name=$(_getConfigName "WS" "$label")
    # URL-кодируем имя для фрагмента (#)
    local encoded_name
    encoded_name=$(python3 -c \
        "import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))" \
        "$name" 2>/dev/null) || encoded_name="$name"
    echo "vless://${xray_uuid}@${xray_userDomain}:443?encryption=none&security=tls&sni=${xray_userDomain}&fp=chrome&type=ws&host=${xray_userDomain}&path=${encoded_path}#${encoded_name}"
}

# JSON конфиг для ручного импорта (v2rayNG Custom config, Nekoray и др.)
_getWsJsonConfig() {
    local uuid="$1" domain="$2" path="$3"
    cat << JSONEOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "port": 10808, "listen": "127.0.0.1", "protocol": "socks",
    "settings": {"auth": "noauth", "udp": true}
  }],
  "outbounds": [
    {
      "tag": "proxy", "protocol": "vless",
      "settings": {
        "vnext": [{"address": "${domain}", "port": 443,
          "users": [{"id": "${uuid}", "encryption": "none"}]}]
      },
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "tlsSettings": {
          "serverName": "${domain}",
          "fingerprint": "chrome",
          "alpn": ["http/1.1"]
        },
        "wsSettings": {
          "path": "${path}",
          "headers": {"Host": "${domain}"}
        }
      }
    },
    {"tag": "direct", "protocol": "freedom"},
    {"tag": "block",  "protocol": "blackhole"}
  ],
  "routing": {"rules": [{"type": "field", "ip": ["geoip:private"], "outboundTag": "direct"}]}
}
JSONEOF
}

getQrCode() {
    # Всё показывается через HTML страницу подписки.
    # В терминале — только ссылка подписки и HTML.
    # Используется при установке (первый показ QR).
    _initUsersFile 2>/dev/null || true

    local domain uuid label token sub_url html_url safe
    domain=$(getConnectHost 2>/dev/null)
    [ -z "$domain" ] && domain=$(_getDomain 2>/dev/null)
    [ -z "$domain" ] && domain=$(getServerIP)

    # Берём первого пользователя
    if [ -f "$USERS_FILE" ] && [ -s "$USERS_FILE" ]; then
        uuid=$(cut -d'|' -f1 "$USERS_FILE" | head -1)
        label=$(cut -d'|' -f2 "$USERS_FILE" | head -1)
        token=$(cut -d'|' -f3 "$USERS_FILE" | head -1)
    fi

    if [ -z "$uuid" ]; then
        getConfigInfo || return 1
        uuid="$xray_uuid"
        label="default"
        token=""
    fi

    safe=$(echo "$label" | tr -cd 'A-Za-z0-9_-')

    if [ -n "$token" ]; then
        sub_url="https://${domain}/sub/${safe}_${token}.txt"
        html_url="https://${domain}/sub/${safe}_${token}.html"
    fi

    command -v qrencode &>/dev/null || installPackage "qrencode"

    echo -e "${cyan}================================================================${reset}"
    echo -e "   VWN — готово к подключению"
    echo -e "${cyan}================================================================${reset}"
    echo ""

    if [ -n "$sub_url" ]; then
        echo -e "${cyan}[ Subscription URL ]${reset}"
        qrencode -s 3 -m 2 -t ANSIUTF8 "$sub_url" 2>/dev/null || true
        echo -e "\n${green}${sub_url}${reset}"
        echo -e "${yellow}v2rayNG: + → Subscription group → URL${reset}"
        echo ""
    fi

    if [ -n "$html_url" ]; then
        echo -e "${cyan}[ HTML — все конфиги, QR, Clash ]${reset}"
        echo -e "${green}${html_url}${reset}"
    fi

    echo -e "${cyan}================================================================${reset}"
}

# Валидация домена: только hostname без протокола и пути
_validateDomain() {
    local d="$1"
    d=$(echo "$d" | sed 's|https\?://||' | sed 's|/.*||' | tr -d ' ')
    if [[ ! "$d" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*\.[a-zA-Z]{2,}$ ]]; then
        return 1
    fi
    echo "$d"
}

# Валидация URL: должен начинаться с https://
_validateUrl() {
    local u="$1"
    u=$(echo "$u" | tr -d ' ')
    if [[ ! "$u" =~ ^https://[a-zA-Z0-9] ]]; then
        return 1
    fi
    echo "$u"
}

# Валидация порта: 1024-65535
_validatePort() {
    local p="$1"
    if ! [[ "$p" =~ ^[0-9]+$ ]] || [ "$p" -lt 1024 ] || [ "$p" -gt 65535 ]; then
        return 1
    fi
    echo "$p"
}

modifyXrayUUID() {
    if [ -f "$USERS_FILE" ] && [ -s "$USERS_FILE" ]; then
        # Генерируем новый UUID для каждого пользователя
        local tmp
        tmp=$(mktemp)
        while IFS='|' read -r uuid label token; do
            [ -z "$uuid" ] && continue
            local new_uuid
            new_uuid=$(cat /proc/sys/kernel/random/uuid)
            echo "${new_uuid}|${label}|${token}"
        done < "$USERS_FILE" > "$tmp"
        mv "$tmp" "$USERS_FILE"
        # Синхронизируем оба конфига
        _applyUsersToConfigs
        echo "${green}$(msg new_uuid) — все пользователи обновлены${reset}"
        cat "$USERS_FILE" | while IFS='|' read -r uuid label token; do
            echo "  $label → $uuid"
        done
    else
        # Нет users.conf — меняем только в конфигах напрямую
        local new_uuid
        new_uuid=$(cat /proc/sys/kernel/random/uuid)
        [ -f "$configPath" ] && jq ".inbounds[0].settings.clients[0].id = \"$new_uuid\"" \
            "$configPath" > "${configPath}.tmp" && mv "${configPath}.tmp" "$configPath"
        [ -f "$realityConfigPath" ] && jq ".inbounds[0].settings.clients[0].id = \"$new_uuid\"" \
            "$realityConfigPath" > "${realityConfigPath}.tmp" && mv "${realityConfigPath}.tmp" "$realityConfigPath"
        systemctl restart xray xray-reality 2>/dev/null || true
        echo "${green}$(msg new_uuid): $new_uuid${reset}"
    fi
}

modifyXrayPort() {
    local oldPort
    oldPort=$(jq ".inbounds[0].port" "$configPath")
    read -rp "$(msg enter_new_port) [$oldPort]: " xrayPort
    [ -z "$xrayPort" ] && return
    if ! _validatePort "$xrayPort" &>/dev/null; then
        echo "${red}$(msg invalid_port)${reset}"; return 1
    fi
    jq ".inbounds[0].port = $xrayPort" \
        "$configPath" > "${configPath}.tmp" && mv "${configPath}.tmp" "$configPath"
    sed -i "s|127.0.0.1:${oldPort}|127.0.0.1:${xrayPort}|g" "$nginxPath"
    systemctl restart xray nginx
    echo "${green}$(msg port_changed) $xrayPort${reset}"
    rebuildAllSubFiles 2>/dev/null || true
}

modifyWsPath() {
    local oldPath
    oldPath=$(jq -r ".inbounds[0].streamSettings.wsSettings.path" "$configPath")
    read -rp "$(msg enter_new_path)" wsPath
    [ -z "$wsPath" ] && wsPath=$(generateRandomPath)
    wsPath=$(echo "$wsPath" | tr -cd 'A-Za-z0-9/_-')
    [[ ! "$wsPath" =~ ^/ ]] && wsPath="/$wsPath"

    local oldPathEscaped newPathEscaped
    oldPathEscaped=$(printf '%s\n' "$oldPath" | sed 's|[[\.*^$()+?{|]|\\&|g')
    newPathEscaped=$(printf '%s\n' "$wsPath" | sed 's|[[\.*^$()+?{|]|\\&|g')
    sed -i "s|location ${oldPathEscaped}|location ${newPathEscaped}|g" "$nginxPath"

    jq ".inbounds[0].streamSettings.wsSettings.path = \"$wsPath\"" \
        "$configPath" > "${configPath}.tmp" && mv "${configPath}.tmp" "$configPath"
    systemctl restart xray nginx
    echo "${green}$(msg new_path): $wsPath${reset}"
    rebuildAllSubFiles 2>/dev/null || true
}

modifyProxyPassUrl() {
    read -rp "$(msg enter_proxy_url)" newUrl
    [ -z "$newUrl" ] && return
    if ! _validateUrl "$newUrl" &>/dev/null; then
        echo "${red}$(msg invalid) URL. $(msg enter_proxy_url)${reset}"; return 1
    fi

    # Вычисляем новый host из URL
    local newHost
    newHost=$(echo "$newUrl" | sed 's|https://||;s|http://||;s|/.*||')

    # Меняем proxy_pass
    local oldUrl
    oldUrl=$(grep "proxy_pass" "$nginxPath" | grep -v "127.0.0.1" | awk '{print $2}' | tr -d ';' | head -1)
    local oldUrlEscaped newUrlEscaped
    oldUrlEscaped=$(printf '%s\n' "$oldUrl" | sed 's|[[\.*^$()+?{|]|\\&|g')
    newUrlEscaped=$(printf '%s\n' "$newUrl" | sed 's|[[\.*^$()+?{|]|\\&|g')
    sed -i "s|${oldUrlEscaped}|${newUrlEscaped}|g" "$nginxPath"

    # Меняем proxy_set_header Host — старый host берём из текущего конфига
    local oldHost
    oldHost=$(grep "proxy_set_header Host" "$nginxPath" | grep -v '\$host' | awk '{print $3}' | tr -d ';' | head -1)
    if [ -n "$oldHost" ] && [ -n "$newHost" ]; then
        local oldHostEscaped newHostEscaped
        oldHostEscaped=$(printf '%s\n' "$oldHost" | sed 's|[\[\].*^$()+?{|]|\\&|g')
        newHostEscaped=$(printf '%s\n' "$newHost" | sed 's|[\[\].*^$()+?{|]|\\&|g')
        # sed с \s* чтобы не зависеть от количества пробелов/табов перед директивой
        sed -i "s|\(proxy_set_header Host\)[[:space:]]\+${oldHostEscaped};|\1 ${newHostEscaped};|g" "$nginxPath"
    fi

    nginx -t && systemctl reload nginx || { echo "${red}$(msg nginx_syntax_err)${reset}"; return 1; }
    echo "${green}$(msg proxy_updated): $newUrl (Host: $newHost)${reset}"
}

modifyDomain() {
    getConfigInfo || return 1
    echo "$(msg current_domain): $xray_userDomain"
    read -rp "$(msg enter_new_domain)" new_domain
    [ -z "$new_domain" ] && return
    local validated
    if ! validated=$(_validateDomain "$new_domain"); then
        echo "${red}$(msg invalid): '$new_domain'${reset}"; return 1
    fi
    new_domain="$validated"
    sed -i "s/server_name ${xray_userDomain};/server_name ${new_domain};/" "$nginxPath"
    jq ".inbounds[0].streamSettings.wsSettings.host = \"$new_domain\"" \
        "$configPath" > "${configPath}.tmp" && mv "${configPath}.tmp" "$configPath"
    userDomain="$new_domain"
    configCert
    systemctl restart nginx xray
}

CONNECT_HOST_FILE="/usr/local/etc/xray/connect_host"

getConnectHost() {
    local h
    h=$(cat "$CONNECT_HOST_FILE" 2>/dev/null | tr -d '[:space:]')
    if [ -n "$h" ]; then
        echo "$h"
    else
        # Fallback на основной домен
        jq -r '.inbounds[0].streamSettings.wsSettings.host // ""' "$configPath" 2>/dev/null
    fi
}

modifyConnectHost() {
    local current
    current=$(cat "$CONNECT_HOST_FILE" 2>/dev/null | tr -d '[:space:]')
    if [ -n "$current" ]; then
        echo "Текущий адрес подключения: ${green}${current}${reset}"
    else
        getConfigInfo || return 1
        echo "Текущий адрес подключения: ${green}${xray_userDomain}${reset} (основной домен)"
    fi
    echo ""
    echo "Введите CDN домен для подключения (Enter = сбросить на основной домен):"
    read -rp "> " new_host
    if [ -z "$new_host" ]; then
        rm -f "$CONNECT_HOST_FILE"
        echo "${green}Адрес подключения сброшен на основной домен${reset}"
    else
        local validated
        if ! validated=$(_validateDomain "$new_host"); then
            echo "${red}$(msg invalid): '$new_host'${reset}"; return 1
        fi
        echo "$validated" > "$CONNECT_HOST_FILE"
        echo "${green}Адрес подключения: $validated${reset}"
    fi
    # Пересоздаём подписки с новым адресом
    rebuildAllSubFiles 2>/dev/null || true
}

updateXrayCore() {
    bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    systemctl restart xray xray-reality 2>/dev/null || true
    echo "${green}$(msg xray_updated)${reset}"
}

rebuildXrayConfigs() {
    local skip_sub="${1:-false}"
    if [ ! -f "$configPath" ]; then
        echo "${red}$(msg xray_not_installed)${reset}"; return 1;
    fi

    local xrayPort wsPath domain
    xrayPort=$(jq -r '.inbounds[0].port // ""' "$configPath" 2>/dev/null)
    wsPath=$(jq -r '.inbounds[0].streamSettings.wsSettings.path // ""' "$configPath" 2>/dev/null)
    domain=$(jq -r '.inbounds[0].streamSettings.wsSettings.host // ""' "$configPath" 2>/dev/null)

    if [ -z "$xrayPort" ] || [ -z "$wsPath" ] || [ -z "$domain" ]; then
        echo "${red}$(msg xray_not_installed) (missing params)${reset}"; return 1;
    fi

    echo -e "${cyan}Rebuilding WebSocket configs...${reset}"

    echo -e "  ${cyan}[1/3] config.json...${reset}"
    writeXrayConfig "$xrayPort" "$wsPath" "$domain"

    echo -e "  ${cyan}[2/3] Applying active features...${reset}"
    [ -f "$warpDomainsFile" ] && applyWarpDomains 2>/dev/null || true
    [ -f "$relayConfigFile" ] && applyRelayDomains 2>/dev/null || true
    [ -f "$psiphonConfigFile" ] && applyPsiphonDomains 2>/dev/null || true
    [ -f "$torConfigFile" ] && applyTorDomains 2>/dev/null || true
    _adblockIsEnabled && _adblockApplyToConfig "$configPath" 2>/dev/null || true
    _privacyIsEnabled && _xrayDisableLog "$configPath" 2>/dev/null || true

    echo -e "  ${cyan}[3/3] Restarting services...${reset}"
    nginx -t && systemctl reload nginx || {
        echo "${red}$(msg nginx_syntax_err)${reset}"; return 1;
    }
    systemctl restart xray 2>/dev/null || true

    $skip_sub || rebuildAllSubFiles 2>/dev/null || true

    echo "${green}Done. WebSocket configs rebuilt.${reset}"
}
