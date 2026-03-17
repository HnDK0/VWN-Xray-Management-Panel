#!/bin/bash
# =================================================================
# xray.sh — Конфиг Xray VLESS+WS+XHTTP+gRPC+TLS, параметры, QR-код
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

# Формирует красивое имя конфига: 🇩🇪 VL-WS-CDN | label 🇩🇪
# Аргументы: тип (WS|Reality), label, [ip]
_getConfigName() {
    local type="$1"
    local label="$2"
    local ip="${3:-$(getServerIP)}"
    local flag
    flag=$(_getCountryFlag "$ip")
    case "$type" in
        WS)       echo "${flag} VL-WS-CDN | ${label} ${flag}" ;;
        Reality)  echo "${flag} VL-Reality | ${label} ${flag}" ;;
        *)        echo "${flag} VL-${type} | ${label} ${flag}" ;;
    esac
}

installXray() {
    command -v xray &>/dev/null && { echo "info: xray already installed."; return; }
    bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
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

    # Порты loopback inbound'ов
    local xhttpPort grpcPort xhttpPath grpcService
    xhttpPort=$(( xrayPort + 1 ))
    grpcPort=$(( xrayPort + 2 ))
    xhttpPath="${wsPath}x"
    grpcService="${wsPath#/}g"

    # Убеждаемся что /dev/shm существует (tmpfs в RAM)
    mkdir -p /dev/shm

    cat > "$configPath" << EOF
{
    "log": {
        "access": "none",
        "error": "/var/log/xray/error.log",
        "loglevel": "error"
    },
    "inbounds": [
    {
        "tag": "tls-inbound",
        "port": 443,
        "listen": "0.0.0.0",
        "protocol": "vless",
        "settings": {
            "clients": [{"id": "$new_uuid"}],
            "decryption": "none",
            "fallbacks": [
                {
                    "alpn": "h2",
                    "dest": "/dev/shm/nginx_h2.sock",
                    "xver": 2
                },
                {
                    "dest": "/dev/shm/nginx.sock",
                    "xver": 2
                }
            ]
        },
        "streamSettings": {
            "network": "raw",
            "security": "tls",
            "tlsSettings": {
                "certificates": [
                    {
                        "certificateFile": "/etc/nginx/cert/cert.pem",
                        "keyFile": "/etc/nginx/cert/cert.key"
                    }
                ],
                "alpn": ["h2", "http/1.1"],
                "minVersion": "1.2"
            }
        },
        "sniffing": {"enabled": true, "destOverride": ["http", "tls"], "metadataOnly": false, "routeOnly": true}
    },
    {
        "tag": "ws-inbound",
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
                "acceptProxyProtocol": true,
                "tcpKeepAliveIdle": 100,
                "tcpKeepAliveInterval": 10,
                "tcpKeepAliveRetry": 3
            }
        },
        "sniffing": {"enabled": true, "destOverride": ["http", "tls"], "metadataOnly": false, "routeOnly": true}
    },
    {
        "tag": "xhttp-inbound",
        "port": $xhttpPort,
        "listen": "127.0.0.1",
        "protocol": "vless",
        "settings": {
            "clients": [{"id": "$new_uuid"}],
            "decryption": "none"
        },
        "streamSettings": {
            "network": "xhttp",
            "xhttpSettings": {
                "path": "$xhttpPath",
                "host": "$domain",
                "mode": "stream-one",
                "extra": {
                    "noGRPCHeader": false,
                    "xPaddingBytes": "400-800",
                    "scMaxEachPostBytes": 1500000,
                    "scMinPostsIntervalMs": 20,
                    "scStreamUpServerSecs": "60-240",
                    "xmux": {
                        "maxConcurrency": "3-5",
                        "maxConnections": 0,
                        "cMaxReuseTimes": "1000-3000",
                        "hMaxRequestTimes": "400-700",
                        "hMaxReusableSecs": "1200-1800",
                        "hKeepAlivePeriod": 0
                    }
                }
            },
            "sockopt": {
                "acceptProxyProtocol": true
            }
        },
        "sniffing": {"enabled": true, "destOverride": ["http", "tls"], "metadataOnly": false, "routeOnly": true}
    },
    {
        "tag": "grpc-inbound",
        "port": $grpcPort,
        "listen": "127.0.0.1",
        "protocol": "vless",
        "settings": {
            "clients": [{"id": "$new_uuid"}],
            "decryption": "none"
        },
        "streamSettings": {
            "network": "grpc",
            "grpcSettings": {
                "serviceName": "$grpcService",
                "multiMode": false
            },
            "sockopt": {
                "acceptProxyProtocol": true
            }
        },
        "sniffing": {"enabled": true, "destOverride": ["http", "tls"], "metadataOnly": false, "routeOnly": true}
    }],
    "outbounds": [
        {
            "tag": "free",
            "protocol": "freedom",
            "settings": {"domainStrategy": "UseIPv4"}
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
                "ip": ["geoip:private"],
                "outboundTag": "block"
            },
            {
                "type": "field",
                "domain": [
                    "domain:openai.com",
                    "domain:chatgpt.com",
                    "domain:oaistatic.com",
                    "domain:oaiusercontent.com",
                    "domain:auth0.openai.com"
                ],
                "outboundTag": "warp"
            },
            {
                "type": "field",
                "port": "0-65535",
                "outboundTag": "free"
            }
        ]
    }
}
EOF

    # Сохраняем пути xhttp и grpc в vwn.conf для использования в подписках
    local vwn_conf="/usr/local/etc/xray/vwn.conf"
    sed -i '/^XHTTP_PATH=/d; /^GRPC_SERVICE=/d' "$vwn_conf" 2>/dev/null || true
    echo "XHTTP_PATH=${xhttpPath}" >> "$vwn_conf"
    echo "GRPC_SERVICE=${grpcService}" >> "$vwn_conf"
}

# Читает xhttp path и grpc serviceName из vwn.conf (сохранены при writeXrayConfig)
_getXhttpPath() {
    local p
    p=$(grep '^XHTTP_PATH=' /usr/local/etc/xray/vwn.conf 2>/dev/null | cut -d= -f2-)
    # Fallback: вывести из wsPath inbound[0] + суффикс 'x'
    if [ -z "$p" ] && [ -f "$configPath" ]; then
        local ws
        ws=$(jq -r '.inbounds[0].streamSettings.wsSettings.path // ""' "$configPath" 2>/dev/null)
        p="${ws}x"
    fi
    echo "$p"
}

_getGrpcService() {
    local s
    s=$(grep '^GRPC_SERVICE=' /usr/local/etc/xray/vwn.conf 2>/dev/null | cut -d= -f2-)
    if [ -z "$s" ] && [ -f "$configPath" ]; then
        local ws
        ws=$(jq -r '.inbounds[0].streamSettings.wsSettings.path // ""' "$configPath" 2>/dev/null)
        s="${ws#/}g"
    fi
    echo "$s"
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
    command -v qrencode &>/dev/null || installPackage "qrencode"
    local has_ws=false has_reality=false

    [ -f "$configPath" ] && has_ws=true
    [ -f "$realityConfigPath" ] && has_reality=true

    if ! $has_ws && ! $has_reality; then
        echo "${red}$(msg xray_not_installed)${reset}"
        return 1
    fi

    if $has_ws; then
        getConfigInfo || return 1
        local url name
        name=$(_getConfigName "WS" "default")
        url=$(getShareUrl "default")

        echo -e "${cyan}================================================================${reset}"
        echo -e "   WS+XHTTP+gRPC — форматы подключения"
        echo -e "${cyan}================================================================${reset}\n"

        echo -e "${cyan}[ 1. URI ссылка (v2rayNG / Hiddify / Nekoray) ]${reset}"
        qrencode -s 1 -m 1 -t ANSIUTF8 "$url" 2>/dev/null || true
        echo -e "\n${green}${url}${reset}\n"

        echo -e "${cyan}[ 2. Clash Meta / Mihomo ]${reset}"
        echo -e "${yellow}- name: ${name}
  type: vless
  server: ${xray_userDomain}
  port: 443
  uuid: ${xray_uuid}
  tls: true
  servername: ${xray_userDomain}
  client-fingerprint: chrome
  network: ws
  ws-opts:
    path: ${xray_path}
    headers:
      Host: ${xray_userDomain}${reset}\n"

        echo -e "${cyan}================================================================${reset}"
    fi

    if $has_reality; then
        echo -e "\n${cyan}=== Vless Reality ===${reset}"
        showRealityQR
    fi
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
    # tls-inbound всегда на 443 — не трогаем
    # Меняем только loopback порты WS/XHTTP/gRPC
    local oldPort
    oldPort=$(jq -r '.inbounds[] | select(.tag=="ws-inbound") | .port' "$configPath" 2>/dev/null)
    [ -z "$oldPort" ] && oldPort=$(jq -r '.inbounds[1].port // 16500' "$configPath" 2>/dev/null)
    read -rp "$(msg enter_new_port) [$oldPort]: " xrayPort
    [ -z "$xrayPort" ] && return
    if ! _validatePort "$xrayPort" &>/dev/null; then
        echo "${red}$(msg invalid_port)${reset}"; return 1
    fi
    local oldXhttp oldGrpc newXhttp newGrpc
    oldXhttp=$(( oldPort + 1 ))
    oldGrpc=$(( oldPort + 2 ))
    newXhttp=$(( xrayPort + 1 ))
    newGrpc=$(( xrayPort + 2 ))

    # Обновляем loopback порты в config.json по тегу (tls-inbound не трогаем)
    jq --argjson ws "$xrayPort" --argjson xh "$newXhttp" --argjson gr "$newGrpc" '
        .inbounds = [.inbounds[] |
            if .tag == "ws-inbound"      then .port = $ws
            elif .tag == "xhttp-inbound" then .port = $xh
            elif .tag == "grpc-inbound"  then .port = $gr
            else . end]
    ' "$configPath" > "${configPath}.tmp" && mv "${configPath}.tmp" "$configPath"

    # Обновляем порты в nginx (proxy_pass на loopback)
    sed -i "s|127.0.0.1:${oldPort}|127.0.0.1:${xrayPort}|g" "$nginxPath"
    sed -i "s|127.0.0.1:${oldXhttp}|127.0.0.1:${newXhttp}|g" "$nginxPath"
    sed -i "s|127.0.0.1:${oldGrpc}|127.0.0.1:${newGrpc}|g" "$nginxPath"
    sed -i "s|grpc://127.0.0.1:${oldGrpc}|grpc://127.0.0.1:${newGrpc}|g" "$nginxPath"

    systemctl restart nginx xray
    echo "${green}$(msg port_changed) $xrayPort (xhttp: $newXhttp, grpc: $newGrpc)${reset}"
}

modifyWsPath() {
    local oldPath
    oldPath=$(jq -r ".inbounds[0].streamSettings.wsSettings.path" "$configPath")
    read -rp "$(msg enter_new_path)" wsPath
    [ -z "$wsPath" ] && wsPath=$(generateRandomPath)
    wsPath=$(echo "$wsPath" | tr -cd 'A-Za-z0-9/_-')
    [[ ! "$wsPath" =~ ^/ ]] && wsPath="/$wsPath"

    local oldXhttpPath newXhttpPath oldGrpcService newGrpcService
    oldXhttpPath="${oldPath}x"
    newXhttpPath="${wsPath}x"
    oldGrpcService="${oldPath#/}g"
    newGrpcService="${wsPath#/}g"

    # Обновляем пути в nginx
    local oldPathEsc newPathEsc oldXhttpEsc newXhttpEsc oldGrpcEsc newGrpcEsc
    oldPathEsc=$(printf '%s\n' "$oldPath"        | sed 's|[[\.*^$()+?{|]|\\&|g')
    newPathEsc=$(printf '%s\n' "$wsPath"         | sed 's|[[\.*^$()+?{|]|\\&|g')
    oldXhttpEsc=$(printf '%s\n' "$oldXhttpPath"  | sed 's|[[\.*^$()+?{|]|\\&|g')
    newXhttpEsc=$(printf '%s\n' "$newXhttpPath"  | sed 's|[[\.*^$()+?{|]|\\&|g')
    oldGrpcEsc=$(printf '%s\n' "/$oldGrpcService" | sed 's|[[\.*^$()+?{|]|\\&|g')
    newGrpcEsc=$(printf '%s\n' "/$newGrpcService" | sed 's|[[\.*^$()+?{|]|\\&|g')
    sed -i "s|location ${oldPathEsc} |location ${newPathEsc} |g" "$nginxPath"
    sed -i "s|location ${oldXhttpEsc} |location ${newXhttpEsc} |g" "$nginxPath"
    sed -i "s|location ${oldGrpcEsc} |location ${newGrpcEsc} |g" "$nginxPath"

    # Обновляем пути в config.json по тегу
    jq --arg ws "$wsPath" --arg xh "$newXhttpPath" --arg gs "$newGrpcService" '
        .inbounds = [.inbounds[] |
            if .tag == "ws-inbound"      then .streamSettings.wsSettings.path = $ws
            elif .tag == "xhttp-inbound" then .streamSettings.xhttpSettings.path = $xh
            elif .tag == "grpc-inbound"  then .streamSettings.grpcSettings.serviceName = $gs
            else . end]
    ' "$configPath" > "${configPath}.tmp" && mv "${configPath}.tmp" "$configPath"

    # Сохраняем новые пути в vwn.conf
    local vwn_conf="/usr/local/etc/xray/vwn.conf"
    sed -i '/^XHTTP_PATH=/d; /^GRPC_SERVICE=/d' "$vwn_conf" 2>/dev/null || true
    echo "XHTTP_PATH=${newXhttpPath}" >> "$vwn_conf"
    echo "GRPC_SERVICE=${newGrpcService}" >> "$vwn_conf"

    systemctl restart xray nginx
    # Пересобираем подписки с новыми путями
    rebuildAllSubFiles 2>/dev/null || true
    echo "${green}$(msg new_path): WS=$wsPath  XHTTP=$newXhttpPath  gRPC=$newGrpcService${reset}"
}

modifyProxyPassUrl() {
    read -rp "$(msg enter_proxy_url)" newUrl
    [ -z "$newUrl" ] && return
    if ! _validateUrl "$newUrl" &>/dev/null; then
        echo "${red}$(msg invalid) URL. $(msg enter_proxy_url)${reset}"; return 1
    fi
    local oldUrl
    oldUrl=$(grep "proxy_pass" "$nginxPath" | grep -v "127.0.0.1" | awk '{print $2}' | tr -d ';' | head -1)
    local oldUrlEscaped newUrlEscaped
    oldUrlEscaped=$(printf '%s\n' "$oldUrl" | sed 's|[[\.*^$()+?{|]|\\&|g')
    newUrlEscaped=$(printf '%s\n' "$newUrl" | sed 's|[[\.*^$()+?{|]|\\&|g')
    sed -i "s|${oldUrlEscaped}|${newUrlEscaped}|g" "$nginxPath"
    systemctl reload nginx
    echo "${green}$(msg proxy_updated)${reset}"
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
    # Обновляем server_name в nginx
    sed -i "s/server_name ${xray_userDomain};/server_name ${new_domain};/" "$nginxPath"
    # Обновляем домен в xray: tls serverNames, ws host, xhttp host
    jq --arg d "$new_domain" '
        .inbounds = [.inbounds[] |
            if .tag == "tls-inbound" then
                .streamSettings.tlsSettings.serverName = $d
            elif .tag == "ws-inbound" then
                .streamSettings.wsSettings.host = $d
            elif .tag == "xhttp-inbound" then
                .streamSettings.xhttpSettings.host = $d
            else . end]
    ' "$configPath" > "${configPath}.tmp" && mv "${configPath}.tmp" "$configPath"
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
