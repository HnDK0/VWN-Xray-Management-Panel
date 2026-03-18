#!/bin/bash
# =================================================================
# xray.sh — Конфиг Xray VLESS+XHTTP+gRPC (без TLS — Nginx держит TLS)
# =================================================================

# =================================================================
# Флаг страны по IP
# =================================================================
_getCountryFlag() {
    local ip="$1"
    local code
    code=$(curl -s --connect-timeout 5 "http://ip-api.com/line/${ip}?fields=countryCode" 2>/dev/null | tr -d '[:space:]')
    if [[ "$code" =~ ^[A-Z]{2}$ ]]; then
        python3 -c "
c='${code}'
flag=''.join(chr(0x1F1E6 + ord(ch) - ord('A')) for ch in c)
print(flag)
" 2>/dev/null || echo "🌐"
    else
        echo "🌐"
    fi
}

_getConfigName() {
    local type="$1"
    local label="$2"
    local ip="${3:-$(getServerIP)}"
    local flag
    flag=$(_getCountryFlag "$ip")
    case "$type" in
        Reality)  echo "${flag} VL-Reality | ${label} ${flag}" ;;
        *)        echo "${flag} VL-${type} | ${label} ${flag}" ;;
    esac
}

installXray() {
    command -v xray &>/dev/null && { echo "info: xray already installed."; return; }
    bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    create_xray_user
    fix_xray_service
    setup_xray_logs
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

writeXrayConfig() {
    local basePort="$1"   # базовый порт: xhttp=basePort, grpc=basePort+1
    local basePath="$2"   # базовый path: xhttp=/$basePath, grpc=$basePath\"g\" serviceName
    local domain="$3"
    local new_uuid

    if [ -f "$USERS_FILE" ] && [ -s "$USERS_FILE" ]; then
        new_uuid=$(cut -d'|' -f1 "$USERS_FILE" | head -1)
    fi
    [ -z "$new_uuid" ] && new_uuid=$(cat /proc/sys/kernel/random/uuid)

    mkdir -p /usr/local/etc/xray /var/log/xray

    local xhttpPort grpcPort xhttpPath grpcService
    xhttpPort=$basePort
    grpcPort=$(( basePort + 1 ))
    # xhttpPath без leading slash — nginx добавит в location
    xhttpPath="${basePath#/}"
    grpcService="${basePath#/}g"

    # Сохраняем в vwn.conf — единственный источник правды
    vwn_conf_set VWN_DOMAIN   "$domain"
    vwn_conf_set XHTTP_PATH   "$xhttpPath"
    vwn_conf_set GRPC_SERVICE "$grpcService"

    cat > "$configPath" << EOF
{
    "log": {
        "access": "none",
        "error": "/var/log/xray/error.log",
        "loglevel": "error"
    },
    "dns": {
        "servers": ["tcp+local://1.1.1.1", "tcp+local://1.0.0.1"]
    },
    "inbounds": [
    {
        "tag": "xhttp-inbound",
        "port": $xhttpPort,
        "listen": "127.0.0.1",
        "protocol": "vless",
        "settings": {
            "clients": [{"id": "$new_uuid", "email": "default"}],
            "decryption": "none"
        },
        "streamSettings": {
            "network": "xhttp",
            "security": "none",
            "xhttpSettings": {
                "path": "/$xhttpPath/",
                "host": "$domain",
                "mode": "auto",
                "scStreamUpServerSecs": "20-80"
            }
        }
    },
    {
        "tag": "grpc-inbound",
        "port": $grpcPort,
        "listen": "127.0.0.1",
        "protocol": "vless",
        "settings": {
            "clients": [{"id": "$new_uuid", "email": "default"}],
            "decryption": "none"
        },
        "streamSettings": {
            "network": "grpc",
            "security": "none",
            "grpcSettings": {
                "serviceName": "$grpcService",
                "multiMode": false
            }
        }
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
        "domainStrategy": "IPIfNonMatch",
        "rules": [
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
                "outboundTag": "block",
                "domain": [
                    "geosite:category-ads-all",
                    "domain:pushnotificationws.com",
                    "domain:sunlight-leds.com",
                    "domain:icecyber.org"
                ]
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
    },
    "policy": {
        "levels": {
            "0": {
                "handshake": 2,
                "connIdle": 120
            }
        }
    }
}
EOF
}

# ============================================================
# Геттеры — все читают из vwn.conf
# ============================================================

get_xhttp_path()   { vwn_conf_get XHTTP_PATH; }
get_grpc_service() { vwn_conf_get GRPC_SERVICE; }

get_domain() {
    local d
    d=$(vwn_conf_get VWN_DOMAIN)
    if [ -n "$d" ]; then echo "$d"; return; fi
    # Fallback для старых установок
    jq -r '.inbounds[] | select(.tag=="xhttp-inbound") | .streamSettings.xhttpSettings.path // empty' \
        "$configPath" 2>/dev/null | head -1
}

get_uuid() {
    jq -r '.inbounds[0].settings.clients[0].id' "$configPath" 2>/dev/null | head -1
}

CONNECT_HOST_FILE="/usr/local/etc/xray/connect_host"

getConnectHost() {
    local h
    h=$(cat "$CONNECT_HOST_FILE" 2>/dev/null | tr -d '[:space:]')
    if [ -n "$h" ]; then
        echo "$h"
    else
        get_domain
    fi
}

# ============================================================
# getConfigInfo — заполняет xray_uuid, xray_path, xray_userDomain
# ============================================================

getConfigInfo() {
    if [ ! -f "$configPath" ]; then
        echo "${red}$(msg xray_not_installed)${reset}" >&2
        return 1
    fi
    xray_uuid=$(get_uuid)
    xray_xhttp_path=$(get_xhttp_path)
    xray_grpc_service=$(get_grpc_service)
    xray_xhttp_port=$(jq -r '.inbounds[] | select(.tag=="xhttp-inbound") | .port' "$configPath" 2>/dev/null | head -1)
    xray_grpc_port=$(jq -r '.inbounds[] | select(.tag=="grpc-inbound") | .port' "$configPath" 2>/dev/null | head -1)
    xray_userDomain=$(get_domain)
    [ -z "$xray_userDomain" ] && xray_userDomain=$(getServerIP)
    if [ -z "$xray_uuid" ]; then
        echo "${red}$(msg xray_not_installed)${reset}" >&2
        return 1
    fi
}

getShareUrlXhttp() {
    local label="${1:-default}"
    getConfigInfo || return 1
    local encoded_path name encoded_name
    encoded_path=$(python3 -c "import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe='/'))" \
        "/${xray_xhttp_path}/" 2>/dev/null) || encoded_path="/${xray_xhttp_path}/"
    name=$(_getConfigName "XHTTP" "$label")
    encoded_name=$(python3 -c "import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))" \
        "$name" 2>/dev/null) || encoded_name="$name"
    echo "vless://${xray_uuid}@${xray_userDomain}:443?encryption=none&security=tls&sni=${xray_userDomain}&fp=chrome&type=xhttp&host=${xray_userDomain}&path=${encoded_path}&mode=auto#${encoded_name}"
}

getShareUrlGrpc() {
    local label="${1:-default}"
    getConfigInfo || return 1
    local name encoded_name
    name=$(_getConfigName "gRPC" "$label")
    encoded_name=$(python3 -c "import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))" \
        "$name" 2>/dev/null) || encoded_name="$name"
    echo "vless://${xray_uuid}@${xray_userDomain}:443?encryption=none&security=tls&sni=${xray_userDomain}&fp=chrome&type=grpc&serviceName=${xray_grpc_service}&mode=gun#${encoded_name}"
}

getQrCode() {
    command -v qrencode &>/dev/null || installPackage "qrencode"
    local has_main=false has_reality=false

    [ -f "$configPath" ] && has_main=true
    [ -f "$realityConfigPath" ] && has_reality=true

    if ! $has_main && ! $has_reality; then
        echo "${red}$(msg xray_not_installed)${reset}"
        return 1
    fi

    if $has_main; then
        getConfigInfo || return 1
        local url_xhttp url_grpc

        echo -e "${cyan}================================================================${reset}"
        echo -e "   XHTTP + gRPC — форматы подключения"
        echo -e "${cyan}================================================================${reset}\n"

        # XHTTP
        url_xhttp=$(getShareUrlXhttp "default")
        echo -e "${cyan}[ XHTTP (XHTTP (auto) ]${reset}"
        qrencode -s 1 -m 1 -t ANSIUTF8 "$url_xhttp" 2>/dev/null || true
        echo -e "\n${green}${url_xhttp}${reset}\n"

        # gRPC
        url_grpc=$(getShareUrlGrpc "default")
        echo -e "${cyan}[ gRPC ]${reset}"
        qrencode -s 1 -m 1 -t ANSIUTF8 "$url_grpc" 2>/dev/null || true
        echo -e "\n${green}${url_grpc}${reset}\n"

        echo -e "${cyan}================================================================${reset}"
    fi

    if $has_reality; then
        echo -e "\n${cyan}=== Vless Reality ===${reset}"
        showRealityQR
    fi
}

# ============================================================
# Валидаторы
# ============================================================

_validateDomain() {
    local d="$1"
    d=$(echo "$d" | sed 's|https\?://||' | sed 's|/.*||' | tr -d ' ')
    if [[ ! "$d" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*\.[a-zA-Z]{2,}$ ]]; then
        return 1
    fi
    echo "$d"
}

_validateUrl() {
    local u="$1"
    u=$(echo "$u" | tr -d ' ')
    if [[ ! "$u" =~ ^https://[a-zA-Z0-9] ]]; then
        return 1
    fi
    echo "$u"
}

_validatePort() {
    local p="$1"
    if ! [[ "$p" =~ ^[0-9]+$ ]] || [ "$p" -lt 1024 ] || [ "$p" -gt 65535 ]; then
        return 1
    fi
    echo "$p"
}

# ============================================================
# Изменение UUID
# ============================================================

modifyXrayUUID() {
    if [ -f "$USERS_FILE" ] && [ -s "$USERS_FILE" ]; then
        local tmp
        tmp=$(mktemp)
        while IFS='|' read -r uuid label token; do
            [ -z "$uuid" ] && continue
            local new_uuid
            new_uuid=$(cat /proc/sys/kernel/random/uuid)
            echo "${new_uuid}|${label}|${token}"
        done < "$USERS_FILE" > "$tmp"
        mv "$tmp" "$USERS_FILE"
        _applyUsersToConfigs
        echo "${green}$(msg new_uuid) — все пользователи обновлены${reset}"
        while IFS='|' read -r uuid label token; do
            echo "  $label → $uuid"
        done < "$USERS_FILE"
    else
        local new_uuid
        new_uuid=$(cat /proc/sys/kernel/random/uuid)
        if [ -f "$configPath" ]; then
            jq --arg u "$new_uuid" '
                .inbounds = [.inbounds[] |
                    if (.settings.clients != null) then
                        .settings.clients = [.settings.clients[] | .id = $u]
                    else . end]
            ' "$configPath" > "${configPath}.tmp" && mv "${configPath}.tmp" "$configPath"
        fi
        if [ -f "$realityConfigPath" ]; then
            jq --arg u "$new_uuid" \
                '.inbounds[0].settings.clients[0].id = $u' \
                "$realityConfigPath" > "${realityConfigPath}.tmp" \
                && mv "${realityConfigPath}.tmp" "$realityConfigPath"
        fi
        systemctl restart xray xray-reality 2>/dev/null || true
        echo "${green}$(msg new_uuid): $new_uuid${reset}"
    fi
}

# ============================================================
# Изменение порта — обновляем config.json и nginx конфиг
# ============================================================

modifyXrayPort() {
    local oldXhttpPort
    oldXhttpPort=$(jq -r '.inbounds[] | select(.tag=="xhttp-inbound") | .port' "$configPath" 2>/dev/null)
    [ -z "$oldXhttpPort" ] && oldXhttpPort=16500
    read -rp "$(msg enter_new_port) [$oldXhttpPort]: " xhttpPort
    [ -z "$xhttpPort" ] && return
    if ! _validatePort "$xhttpPort" &>/dev/null; then
        echo "${red}$(msg invalid_port)${reset}"; return 1
    fi
    local newGrpcPort
    newGrpcPort=$(( xhttpPort + 1 ))
    local oldGrpcPort
    oldGrpcPort=$(( oldXhttpPort + 1 ))

    jq --argjson xh "$xhttpPort" --argjson gr "$newGrpcPort" '
        .inbounds = [.inbounds[] |
            if .tag == "xhttp-inbound" then .port = $xh
            elif .tag == "grpc-inbound" then .port = $gr
            else . end]
    ' "$configPath" > "${configPath}.tmp" && mv "${configPath}.tmp" "$configPath"

    # Обновляем nginx конфиг
    local xhttpPath grpcService domain proxyUrl
    xhttpPath=$(get_xhttp_path)
    grpcService=$(get_grpc_service)
    domain=$(get_domain)
    proxyUrl=$(vwn_conf_get STUB_URL)
    [ -z "$proxyUrl" ] && proxyUrl="https://httpbin.org/"
    writeNginxConfig "$domain" "$proxyUrl" "$xhttpPort" "$newGrpcPort" "$xhttpPath" "$grpcService"

    systemctl restart xray
    nginx -t &>/dev/null && systemctl reload nginx
    echo "${green}$(msg port_changed) xhttp:$xhttpPort grpc:$newGrpcPort${reset}"
}

# ============================================================
# Изменение путей XHTTP/gRPC — обновляем config.json и nginx
# ============================================================

modifyPaths() {
    local oldXhttpPath
    oldXhttpPath=$(get_xhttp_path)
    read -rp "$(msg enter_new_path)" newBasePath
    [ -z "$newBasePath" ] && newBasePath=$(generateRandomPath)
    newBasePath=$(echo "$newBasePath" | tr -cd 'A-Za-z0-9/_-')
    newBasePath="${newBasePath#/}"  # без leading slash

    local newGrpcService="${newBasePath}g"

    jq --arg xh "/${newBasePath}/" --arg gs "$newGrpcService" '
        .inbounds = [.inbounds[] |
            if .tag == "xhttp-inbound" then .streamSettings.xhttpSettings.path = $xh
            elif .tag == "grpc-inbound" then .streamSettings.grpcSettings.serviceName = $gs
            else . end]
    ' "$configPath" > "${configPath}.tmp" && mv "${configPath}.tmp" "$configPath"

    vwn_conf_set XHTTP_PATH   "$newBasePath"
    vwn_conf_set GRPC_SERVICE "$newGrpcService"

    # Пересоздаём nginx конфиг
    local xhttpPort grpcPort domain proxyUrl
    xhttpPort=$(jq -r '.inbounds[] | select(.tag=="xhttp-inbound") | .port' "$configPath" 2>/dev/null)
    grpcPort=$(jq -r '.inbounds[] | select(.tag=="grpc-inbound") | .port' "$configPath" 2>/dev/null)
    domain=$(get_domain)
    proxyUrl=$(vwn_conf_get STUB_URL)
    [ -z "$proxyUrl" ] && proxyUrl="https://httpbin.org/"
    writeNginxConfig "$domain" "$proxyUrl" "$xhttpPort" "$grpcPort" "$newBasePath" "$newGrpcService"

    systemctl restart xray
    nginx -t &>/dev/null && systemctl reload nginx
    rebuildAllSubFiles 2>/dev/null || true
    echo "${green}$(msg new_path): XHTTP=/${newBasePath}/  gRPC=$newGrpcService${reset}"
}

# ============================================================
# Изменение URL заглушки — обновляем nginx конфиг
# ============================================================

modifyProxyPassUrl() {
    read -rp "$(msg enter_proxy_url)" newUrl
    [ -z "$newUrl" ] && return
    if ! _validateUrl "$newUrl" &>/dev/null; then
        echo "${red}$(msg invalid) URL. $(msg enter_proxy_url)${reset}"; return 1
    fi
    # URL заглушки хранится в nginx — nginx остаётся для заглушки
    local oldUrl
    oldUrl=$(grep "proxy_pass" "$nginxPath" 2>/dev/null | grep -v "127\.0\.0\.1" | awk '{print $2}' | tr -d ';' | head -1)
    if [ -n "$oldUrl" ]; then
        local oldEsc newEsc
        oldEsc=$(printf '%s\n' "$oldUrl" | sed 's|[&/\]|\\&|g')
        newEsc=$(printf '%s\n' "$newUrl" | sed 's|[&/\]|\\&|g')
        sed -i "s|${oldEsc}|${newEsc}|g" "$nginxPath"
    fi
    # Сохраняем в vwn.conf для справки
    vwn_conf_set STUB_URL "$newUrl"
    systemctl reload nginx
    echo "${green}$(msg proxy_updated)${reset}"
}

# ============================================================
# Изменение домена — обновляем nginx конфиг и vwn.conf
# ============================================================

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

    # Сохраняем новый домен
    vwn_conf_set VWN_DOMAIN "$new_domain"

    # Пересоздаём nginx конфиг с новым доменом
    local xhttpPort grpcPort proxyUrl
    xhttpPort=$(jq -r '.inbounds[] | select(.tag=="xhttp-inbound") | .port' "$configPath" 2>/dev/null)
    grpcPort=$(jq -r '.inbounds[] | select(.tag=="grpc-inbound") | .port' "$configPath" 2>/dev/null)
    proxyUrl=$(vwn_conf_get STUB_URL)
    [ -z "$proxyUrl" ] && proxyUrl="https://httpbin.org/"
    writeNginxConfig "$new_domain" "$proxyUrl" "$xhttpPort" "$grpcPort" \
        "$xray_xhttp_path" "$xray_grpc_service"

    # Перевыпускаем сертификат
    userDomain="$new_domain"
    configCert

    nginx -t &>/dev/null && systemctl reload nginx
    systemctl restart xray
}

# ============================================================
# Изменение CDN-хоста подключения
# ============================================================

modifyConnectHost() {
    local current
    current=$(cat "$CONNECT_HOST_FILE" 2>/dev/null | tr -d '[:space:]')
    if [ -n "$current" ]; then
        echo "$(msg current_domain): ${green}${current}${reset}"
    else
        getConfigInfo || return 1
        echo "$(msg current_domain): ${green}${xray_userDomain}${reset} ($(msg lbl_domain))"
    fi
    echo ""
    echo "$(msg cdn_host_prompt)"
    read -rp "> " new_host
    if [ -z "$new_host" ]; then
        rm -f "$CONNECT_HOST_FILE"
        echo "${green}$(msg cdn_host_reset)${reset}"
    else
        local validated
        if ! validated=$(_validateDomain "$new_host"); then
            echo "${red}$(msg invalid): '$new_host'${reset}"; return 1
        fi
        echo "$validated" > "$CONNECT_HOST_FILE"
        echo "${green}$(msg cdn_host_set): $validated${reset}"
    fi
    rebuildAllSubFiles 2>/dev/null || true
}

# ============================================================
# Обновление Xray core
# ============================================================

updateXrayCore() {
    bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    systemctl restart xray xray-reality 2>/dev/null || true
    echo "${green}$(msg xray_updated)${reset}"
}
