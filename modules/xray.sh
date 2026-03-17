#!/bin/bash
# =================================================================
# xray.sh — Конфиг Xray VLESS+WS+XHTTP+gRPC (без TLS — HAProxy держит TLS)
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
        WS)       echo "${flag} VL-WS-CDN | ${label} ${flag}" ;;
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
    local xrayPort="$1"
    local wsPath="$2"
    local domain="$3"
    local new_uuid

    if [ -f "$USERS_FILE" ] && [ -s "$USERS_FILE" ]; then
        new_uuid=$(cut -d'|' -f1 "$USERS_FILE" | head -1)
    fi
    [ -z "$new_uuid" ] && new_uuid=$(cat /proc/sys/kernel/random/uuid)

    mkdir -p /usr/local/etc/xray /var/log/xray

    local xhttpPort grpcPort xhttpPath grpcService
    xhttpPort=$(( xrayPort + 1 ))
    grpcPort=$(( xrayPort + 2 ))
    xhttpPath="${wsPath}x"
    grpcService="${wsPath#/}g"

    # Сохраняем домен и пути в vwn.conf — единственный источник правды
    vwn_conf_set VWN_DOMAIN   "$domain"
    vwn_conf_set WS_PATH      "$wsPath"
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
        "tag": "ws-inbound",
        "port": $xrayPort,
        "listen": "127.0.0.1",
        "protocol": "vless",
        "settings": {
            "clients": [{"id": "$new_uuid", "email": "default"}],
            "decryption": "none"
        },
        "streamSettings": {
            "network": "ws",
            "security": "none",
            "wsSettings": {
                "path": "$wsPath",
                "host": "$domain"
            },
            "sockopt": {
                "tcpKeepAliveIdle": 100,
                "tcpKeepAliveInterval": 10,
                "tcpKeepAliveRetry": 3
            }
        }
    },
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
                "path": "$xhttpPath",
                "mode": "auto",
                "extra": {
                    "xPaddingBytes": "400-800"
                }
            },
            "sockopt": {
                "tcpKeepAliveIdle": 100,
                "tcpKeepAliveInterval": 10,
                "tcpKeepAliveRetry": 3
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
            },
            "sockopt": {
                "tcpKeepAliveIdle": 100,
                "tcpKeepAliveInterval": 10,
                "tcpKeepAliveRetry": 3
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

get_ws_path()      { vwn_conf_get WS_PATH; }
get_xhttp_path()   { vwn_conf_get XHTTP_PATH; }
get_grpc_service() { vwn_conf_get GRPC_SERVICE; }

get_domain() {
    # Основной источник — vwn.conf
    local d
    d=$(vwn_conf_get VWN_DOMAIN)
    if [ -n "$d" ]; then
        echo "$d"; return
    fi
    # Fallback для старых установок — читаем из config.json
    jq -r '.inbounds[] | select(.tag=="ws-inbound") | .streamSettings.wsSettings.host // empty' \
        "$configPath" 2>/dev/null | head -1
}

get_uuid() {
    jq -r '.inbounds[] | select(.tag=="ws-inbound") | .settings.clients[0].id' \
        "$configPath" 2>/dev/null | head -1
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
    xray_path=$(get_ws_path)
    xray_port=$(jq -r '.inbounds[] | select(.tag=="ws-inbound") | .port' "$configPath" 2>/dev/null | head -1)
    xray_userDomain=$(get_domain)
    [ -z "$xray_userDomain" ] && xray_userDomain=$(getServerIP)
    if [ -z "$xray_uuid" ]; then
        echo "${red}$(msg xray_not_installed)${reset}" >&2
        return 1
    fi
}

getShareUrl() {
    local label="${1:-default}"
    getConfigInfo || return 1
    local encoded_path name encoded_name
    encoded_path=$(python3 -c "import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe='/'))" \
        "$xray_path" 2>/dev/null) || encoded_path="$xray_path"
    name=$(_getConfigName "WS" "$label")
    encoded_name=$(python3 -c "import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))" \
        "$name" 2>/dev/null) || encoded_name="$name"
    echo "vless://${xray_uuid}@${xray_userDomain}:443?encryption=none&security=tls&sni=${xray_userDomain}&fp=chrome&type=ws&host=${xray_userDomain}&path=${encoded_path}#${encoded_name}"
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
# Изменение порта Xray — обновляем config.json и haproxy.cfg
# ============================================================

modifyXrayPort() {
    local oldPort
    oldPort=$(jq -r '.inbounds[] | select(.tag=="ws-inbound") | .port' "$configPath" 2>/dev/null)
    [ -z "$oldPort" ] && oldPort=16500
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

    # Обновляем config.json
    jq --argjson ws "$xrayPort" --argjson xh "$newXhttp" --argjson gr "$newGrpc" '
        .inbounds = [.inbounds[] |
            if .tag == "ws-inbound"      then .port = $ws
            elif .tag == "xhttp-inbound" then .port = $xh
            elif .tag == "grpc-inbound"  then .port = $gr
            else . end]
    ' "$configPath" > "${configPath}.tmp" && mv "${configPath}.tmp" "$configPath"

    # Обновляем haproxy.cfg — заменяем порты в backend server строках
    if [ -f "$haproxyPath" ]; then
        sed -i \
            "s|127\.0\.0\.1:${oldPort}\b|127.0.0.1:${xrayPort}|g;
             s|127\.0\.0\.1:${oldXhttp}\b|127.0.0.1:${newXhttp}|g;
             s|127\.0\.0\.1:${oldGrpc}\b|127.0.0.1:${newGrpc}|g" \
            "$haproxyPath"
        haproxy -c -f "$haproxyPath" &>/dev/null && systemctl reload haproxy || systemctl restart haproxy
    fi

    systemctl restart xray
    echo "${green}$(msg port_changed) $xrayPort (xhttp: $newXhttp, grpc: $newGrpc)${reset}"
}

# ============================================================
# Изменение путей WS/XHTTP/gRPC — обновляем config.json и haproxy.cfg
# ============================================================

modifyWsPath() {
    local oldPath
    oldPath=$(get_ws_path)
    read -rp "$(msg enter_new_path)" wsPath
    [ -z "$wsPath" ] && wsPath=$(generateRandomPath)
    wsPath=$(echo "$wsPath" | tr -cd 'A-Za-z0-9/_-')
    [[ ! "$wsPath" =~ ^/ ]] && wsPath="/$wsPath"

    local newXhttpPath newGrpcService
    newXhttpPath="${wsPath}x"
    newGrpcService="${wsPath#/}g"

    # Обновляем config.json
    jq --arg ws "$wsPath" --arg xh "$newXhttpPath" --arg gs "$newGrpcService" '
        .inbounds = [.inbounds[] |
            if .tag == "ws-inbound"      then .streamSettings.wsSettings.path = $ws
            elif .tag == "xhttp-inbound" then .streamSettings.xhttpSettings.path = $xh
            elif .tag == "grpc-inbound"  then .streamSettings.grpcSettings.serviceName = $gs
            else . end]
    ' "$configPath" > "${configPath}.tmp" && mv "${configPath}.tmp" "$configPath"

    # Обновляем haproxy.cfg — ACL path_beg
    if [ -f "$haproxyPath" ]; then
        local oldXhttpPath oldGrpcService
        oldXhttpPath=$(get_xhttp_path)
        oldGrpcService=$(get_grpc_service)

        local oldEsc newEsc oldXEsc newXEsc oldGEsc newGEsc
        oldEsc=$(printf '%s' "$oldPath"        | sed 's|[&/\]|\\&|g')
        newEsc=$(printf '%s' "$wsPath"         | sed 's|[&/\]|\\&|g')
        oldXEsc=$(printf '%s' "$oldXhttpPath"  | sed 's|[&/\]|\\&|g')
        newXEsc=$(printf '%s' "$newXhttpPath"  | sed 's|[&/\]|\\&|g')
        oldGEsc=$(printf '%s' "/$oldGrpcService" | sed 's|[&/\]|\\&|g')
        newGEsc=$(printf '%s' "/$newGrpcService" | sed 's|[&/\]|\\&|g')

        sed -i \
            "s|path_beg ${oldEsc}$|path_beg ${newEsc}|g;
             s|path_beg ${oldXEsc}$|path_beg ${newXEsc}|g;
             s|path_beg ${oldGEsc}$|path_beg ${newGEsc}|g" \
            "$haproxyPath"
        haproxy -c -f "$haproxyPath" &>/dev/null && systemctl reload haproxy || systemctl restart haproxy
    fi

    # Сохраняем новые пути в vwn.conf
    vwn_conf_set WS_PATH      "$wsPath"
    vwn_conf_set XHTTP_PATH   "$newXhttpPath"
    vwn_conf_set GRPC_SERVICE "$newGrpcService"

    systemctl restart xray
    rebuildAllSubFiles 2>/dev/null || true
    echo "${green}$(msg new_path): WS=$wsPath  XHTTP=$newXhttpPath  gRPC=$newGrpcService${reset}"
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
# Изменение домена — обновляем config.json, haproxy.cfg, vwn.conf
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

    # Обновляем config.json — host в ws/xhttp inbound
    jq --arg d "$new_domain" '
        .inbounds = [.inbounds[] |
            if .tag == "ws-inbound"      then .streamSettings.wsSettings.host = $d
            elif .tag == "xhttp-inbound" then .streamSettings.xhttpSettings.host = $d
            else . end]
    ' "$configPath" > "${configPath}.tmp" && mv "${configPath}.tmp" "$configPath"

    # Обновляем haproxy.cfg — в новой архитектуре HAProxy делает TLS termination
    # по сертификату haproxyCert. При смене домена сертификат перевыпускается ниже
    # через configCert, после чего haproxy перезапускается автоматически.
    # Дополнительных изменений в haproxy.cfg не требуется.

    # Обновляем nginx server_name (для заглушки)
    if [ -f "$nginxPath" ]; then
        sed -i "s/server_name ${xray_userDomain};/server_name ${new_domain};/" "$nginxPath"
        systemctl reload nginx
    fi

    # Сохраняем новый домен
    vwn_conf_set VWN_DOMAIN "$new_domain"

    # Перевыпускаем сертификат
    userDomain="$new_domain"
    configCert
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
