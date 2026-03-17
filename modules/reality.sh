#!/bin/bash
# =================================================================
# reality.sh — VLESS + Reality: конфиг, сервис, управление
# Reality слушает на 0.0.0.0:REALITY_INTERNAL_PORT (по умолчанию 8443)
# =================================================================

source "${VWN_LIB}/core.sh"

# Публичный порт xray-reality (слушает на 0.0.0.0, открыт через UFW)
REALITY_INTERNAL_PORT=8443

getRealityStatus() {
    if [ -f "$realityConfigPath" ]; then
        local port dest
        port=$(jq -r '.inbounds[0].port // "—"' "$realityConfigPath" 2>/dev/null)
        dest=$(jq -r '.inbounds[0].streamSettings.realitySettings.dest // "—"' \
            "$realityConfigPath" 2>/dev/null)
        echo "${green}ON ($(msg lbl_port) $port, SNI: $dest)${reset}"
    else
        echo "${red}OFF${reset}"
    fi
}

writeRealityConfig() {
    local dest="$1"          # microsoft.com:443
    local destHost="${dest%%:*}"

    echo -e "${cyan}$(msg reality_keygen)${reset}"
    local keys privKey pubKey shortId new_uuid

    keys=$(/usr/local/bin/xray x25519 2>/dev/null) || {
        echo "${red}$(msg reality_keys_fail)${reset}"; return 1
    }
    privKey=$(echo "$keys" | tr -d '\r' | awk '/Private key:/{print $3}')
    pubKey=$(echo "$keys"  | tr -d '\r' | awk '/Public key:/{print $3}')
    [ -z "$privKey" ] || [ -z "$pubKey" ] && {
        echo "${red}$(msg reality_keys_err)${reset}"; return 1
    }

    shortId=$(cat /proc/sys/kernel/random/uuid | tr -d '-' | cut -c1-16)

    if [ -f "$USERS_FILE" ] && [ -s "$USERS_FILE" ]; then
        new_uuid=$(cut -d'|' -f1 "$USERS_FILE" | head -1)
    fi
    [ -z "$new_uuid" ] && new_uuid=$(cat /proc/sys/kernel/random/uuid)

    mkdir -p /usr/local/etc/xray

    cat > "$realityConfigPath" << EOF
{
    "log": {
        "access": "none",
        "error": "/var/log/xray/reality-error.log",
        "loglevel": "error"
    },
    "dns": {
        "servers": ["tcp+local://1.1.1.1", "tcp+local://1.0.0.1"]
    },
    "inbounds": [{
        "port": ${REALITY_INTERNAL_PORT},
        "listen": "0.0.0.0",
        "protocol": "vless",
        "settings": {
            "clients": [{"id": "$new_uuid", "flow": "xtls-rprx-vision", "email": "default"}],
            "decryption": "none"
        },
        "streamSettings": {
            "network": "tcp",
            "security": "reality",
            "realitySettings": {
                "show": false,
                "dest": "$dest",
                "xver": 0,
                "serverNames": ["$destHost"],
                "privateKey": "$privKey",
                "shortIds": ["$shortId"],
                "maxTimeDiff": 60000
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

    # Сохраняем pubKey в vwn.conf — единственный надёжный источник
    vwn_conf_set REALITY_PUBKEY   "$pubKey"
    vwn_conf_set REALITY_DEST     "$dest"
    vwn_conf_set REALITY_SHORT_ID "$shortId"

    # Оставляем txt для совместимости
    cat > /usr/local/etc/xray/reality_client.txt << EOF
=== Reality параметры для клиента ===
UUID:       $new_uuid
PublicKey:  $pubKey
ShortId:    $shortId
ServerName: $destHost
Port:       443 (через HAProxy)
Flow:       xtls-rprx-vision
EOF

    echo "${green}$(msg reality_config_ok)${reset}"
    cat /usr/local/etc/xray/reality_client.txt
}

get_reality_pubkey() {
    # Основной источник — vwn.conf
    local pk
    pk=$(vwn_conf_get REALITY_PUBKEY)
    if [ -n "$pk" ]; then
        echo "$pk"; return
    fi
    # Fallback — старый txt файл
    grep "PublicKey:" /usr/local/etc/xray/reality_client.txt 2>/dev/null | awk '{print $NF}'
}

setupRealityService() {
    create_xray_user
    setup_xray_logs

    touch /var/log/xray/reality-error.log
    chown xray:xray /var/log/xray/reality-error.log

    fix_xray_service

    cat > /etc/systemd/system/xray-reality.service << 'EOF'
[Unit]
Description=Xray Reality Service
After=network.target nss-lookup.target

[Service]
User=xray
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/reality.json
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable xray-reality
    systemctl restart xray-reality
    echo "${green}$(msg reality_service_ok)${reset}"
}

installReality() {
    echo -e "${cyan}$(msg reality_setup_title)${reset}"
    identifyOS

    echo "--- [1/3] $(msg install_deps) ---"
    run_task "Swap-файл"        setupSwap
    run_task "Чистка пакетов"   "rm -f /var/lib/dpkg/lock* && dpkg --configure -a 2>/dev/null || true"
    run_task "Обновление репозиториев" "$PACKAGE_MANAGEMENT_UPDATE"

    echo "--- [2/3] $(msg install_deps) ---"
    for p in tar gpg unzip jq nano ufw socat curl qrencode python3; do
        run_task "Установка $p" "installPackage '$p'" || true
    done
    if ! command -v xray &>/dev/null; then
        run_task "Установка Xray-core" installXray
    fi
    if ! command -v warp-cli &>/dev/null; then
        run_task "Установка Cloudflare WARP" installWarp
    fi

    echo "--- [3/3] $(msg menu_sep_sec) ---"
    # Reality использует порт 443 через HAProxy — отдельный UFW порт не нужен
    run_task "Настройка UFW" "ufw allow 22/tcp && ufw allow 443/tcp && echo 'y' | ufw enable"
    run_task "Системные параметры" applySysctl
    if ! systemctl is-active --quiet warp-svc 2>/dev/null; then
        run_task "Настройка WARP" configWarp
        run_task "WARP Watchdog" setupWarpWatchdog
    fi
    run_task "Ротация логов" setupLogrotate
    run_task "Автоочистка логов" setupLogClearCron

    local realityPort
    read -rp "$(msg reality_port_prompt)" realityPort
    [ -z "$realityPort" ] && realityPort=8443
    if ! [[ "$realityPort" =~ ^[0-9]+$ ]] || [ "$realityPort" -lt 1024 ] || [ "$realityPort" -gt 65535 ]; then
        echo "${red}$(msg invalid_port)${reset}"; return 1
    fi
    REALITY_INTERNAL_PORT=$realityPort

    echo -e "${cyan}$(msg reality_dest_title)${reset}"
    echo "1) microsoft.com:443"
    echo "2) www.apple.com:443"
    echo "3) www.amazon.com:443"
    echo "$(msg reality_dest_custom)"
    read -rp "Выбор [1]: " dest_choice
    case "${dest_choice:-1}" in
        1) dest="microsoft.com:443" ;;
        2) dest="www.apple.com:443" ;;
        3) dest="www.amazon.com:443" ;;
        4) read -rp "$(msg reality_dest_prompt)" dest
           [ -z "$dest" ] && { echo "${red}$(msg reality_dest_empty)${reset}"; return 1; } ;;
        *) dest="microsoft.com:443" ;;
    esac

    local destHost="${dest%%:*}"

    writeRealityConfig "$dest" || return 1
    setupRealityService || return 1

    # Открываем порт Reality в UFW
    ufw allow "$REALITY_INTERNAL_PORT"/tcp comment 'Xray Reality' 2>/dev/null || true

    # nginx и HAProxy нужны для WS/XHTTP/gRPC — устанавливаем если нет
    if ! command -v nginx &>/dev/null; then
        run_task "Установка Nginx"   "installPackage nginx"
    fi
    if ! command -v haproxy &>/dev/null; then
        run_task "Установка HAProxy" "installPackage haproxy"
    fi

    local stubUrl
    stubUrl=$(vwn_conf_get STUB_URL)
    [ -z "$stubUrl" ] && stubUrl="https://httpbin.org/"

    if [ ! -f "$nginxPath" ]; then
        local stub_domain
        stub_domain=$(get_domain 2>/dev/null || getServerIP)
        writeNginxConfig "$stub_domain" "$stubUrl"
        systemctl enable --now nginx
        systemctl restart nginx
    fi

    # Синхронизируем WARP и Relay домены в новый конфиг
    [ -f "$warpDomainsFile" ] && applyWarpDomains
    [ -f "$relayConfigFile" ] && applyRelayDomains
    [ -f "$psiphonConfigFile" ] && applyPsiphonDomains

    echo -e "\n${green}$(msg reality_installed)${reset}"
    showRealityQR
}

_getPublicIP() {
    local ip
    ip=$(getServerIP)
    if [[ "$ip" =~ ^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.) ]] || [ "$ip" = "UNKNOWN" ]; then
        echo -e "${yellow}$(msg reality_ip_private): $ip${reset}" >&2
        read -rp "$(msg reality_ip_prompt)" manual_ip
        [ -n "$manual_ip" ] && ip="$manual_ip"
    fi
    echo "$ip"
}

showRealityInfo() {
    [ ! -f "$realityConfigPath" ] && { echo "${red}$(msg reality_not_installed)${reset}"; return 1; }

    local uuid port shortId destHost pubKey serverIP
    uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$realityConfigPath")
    port=$(jq -r '.inbounds[0].port' "$realityConfigPath")
    shortId=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$realityConfigPath")
    destHost=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$realityConfigPath")
    pubKey=$(get_reality_pubkey)
    serverIP=$(_getPublicIP)

    echo "--------------------------------------------------"
    echo "UUID:        $uuid"
    echo "IP:          $serverIP"
    echo "$(msg lbl_port): $port"
    echo "PublicKey:   $pubKey"
    echo "ShortId:     $shortId"
    echo "ServerName:  $destHost"
    echo "Flow:        xtls-rprx-vision"
    echo "--------------------------------------------------"
    local url="vless://${uuid}@${serverIP}:${port}?encryption=none&security=reality&sni=${destHost}&fp=chrome&pbk=${pubKey}&sid=${shortId}&type=tcp&flow=xtls-rprx-vision#Reality-${serverIP}"
    echo -e "${green}$url${reset}"
    echo "--------------------------------------------------"
}

showRealityQR() {
    [ ! -f "$realityConfigPath" ] && { echo "${red}$(msg reality_not_installed)${reset}"; return 1; }

    local uuid port shortId destHost pubKey serverIP
    uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$realityConfigPath")
    port=$(jq -r '.inbounds[0].port' "$realityConfigPath")
    shortId=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$realityConfigPath")
    destHost=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$realityConfigPath")
    pubKey=$(get_reality_pubkey)
    serverIP=$(_getPublicIP)

    local url="vless://${uuid}@${serverIP}:${port}?encryption=none&security=reality&sni=${destHost}&fp=chrome&pbk=${pubKey}&sid=${shortId}&type=tcp&flow=xtls-rprx-vision#Reality-${serverIP}"
    command -v qrencode &>/dev/null || installPackage "qrencode"
    qrencode -s 1 -m 1 -t ANSIUTF8 "$url"
    echo -e "\n${green}$url${reset}\n"
}

modifyRealityUUID() {
    modifyXrayUUID
}

modifyRealityPort() {
    [ ! -f "$realityConfigPath" ] && { echo "${red}$(msg reality_not_installed)${reset}"; return 1; }
    local oldPort
    oldPort=$(jq -r '.inbounds[0].port' "$realityConfigPath" 2>/dev/null)
    read -rp "$(msg lbl_port) [$oldPort]: " newPort
    [ -z "$newPort" ] && return
    if ! [[ "$newPort" =~ ^[0-9]+$ ]] || [ "$newPort" -lt 1024 ] || [ "$newPort" -gt 65535 ]; then
        echo "${red}$(msg invalid_port)${reset}"; return 1
    fi
    # UFW: открываем новый, закрываем старый
    ufw allow "$newPort"/tcp comment 'Xray Reality' 2>/dev/null || true
    ufw delete allow "$oldPort"/tcp 2>/dev/null || true
    jq ".inbounds[0].port = $newPort" \
        "$realityConfigPath" > "${realityConfigPath}.tmp" \
        && mv "${realityConfigPath}.tmp" "$realityConfigPath"
    systemctl restart xray-reality
    echo "${green}$(msg reality_port_changed) $newPort${reset}"
}

modifyRealityDest() {
    [ ! -f "$realityConfigPath" ] && { echo "${red}$(msg reality_not_installed)${reset}"; return 1; }
    local oldDest
    oldDest=$(jq -r '.inbounds[0].streamSettings.realitySettings.dest' "$realityConfigPath")
    echo "$(msg reality_current_dest): $oldDest"
    echo "1) microsoft.com:443"
    echo "2) www.apple.com:443"
    echo "3) www.amazon.com:443"
    echo "$(msg reality_dest_custom)"
    read -rp "Выбор: " choice
    case "$choice" in
        1) newDest="microsoft.com:443" ;;
        2) newDest="www.apple.com:443" ;;
        3) newDest="www.amazon.com:443" ;;
        4) read -rp "Введите dest (host:port): " newDest ;;
        *) return ;;
    esac
    local newHost="${newDest%%:*}"
    jq ".inbounds[0].streamSettings.realitySettings.dest = \"$newDest\" |
        .inbounds[0].streamSettings.realitySettings.serverNames = [\"$newHost\"]" \
        "$realityConfigPath" > "${realityConfigPath}.tmp" \
        && mv "${realityConfigPath}.tmp" "$realityConfigPath"

    # Обновляем SNI в HAProxy
    _haproxyUpdateReality "$newHost"

    # Обновляем vwn.conf
    vwn_conf_set REALITY_DEST "$newDest"

    systemctl restart xray-reality
    echo "${green}$(msg reality_dest_changed) $newDest${reset}"
}

removeReality() {
    echo -e "${red}$(msg reality_remove_confirm) $(msg yes_no)${reset}"
    read -r confirm
    if [[ "$confirm" == "y" ]]; then
        # Закрываем UFW порт Reality
        local old_port
        old_port=$(jq -r '.inbounds[0].port // empty' "$realityConfigPath" 2>/dev/null)
        [ -n "$old_port" ] && ufw delete allow "$old_port"/tcp 2>/dev/null || true

        systemctl stop xray-reality 2>/dev/null || true
        systemctl disable xray-reality 2>/dev/null || true
        rm -f /etc/systemd/system/xray-reality.service
        rm -f "$realityConfigPath" /usr/local/etc/xray/reality_client.txt
        systemctl daemon-reload

        # Убираем из vwn.conf
        vwn_conf_del REALITY_PUBKEY
        vwn_conf_del REALITY_DEST
        vwn_conf_del REALITY_SHORT_ID

        echo "${green}$(msg removed)${reset}"
    fi
}

manageReality() {
    set +e
    while true; do
        clear
        local s_reality s_warp s_port s_dest
        s_reality=$(getServiceStatus xray-reality)
        s_warp=$(getWarpStatus)
        s_port=$(jq -r '.inbounds[0].port // "—"' "$realityConfigPath" 2>/dev/null)
        s_dest=$(jq -r '.inbounds[0].streamSettings.realitySettings.dest // "—"' \
            "$realityConfigPath" 2>/dev/null)
        echo -e "${cyan}================================================================${reset}"
        printf "   ${red}VLESS + Reality${reset}  %s\n" "$(date +'%d.%m.%Y %H:%M')"
        echo -e "${cyan}----------------------------------------------------------------${reset}"
        echo -e "  $(printf "%-6s" "Xray:")$s_reality"
        echo -e "  $(printf "%-6s" "Port:")${green}$s_port${reset}"
        echo -e "  $(printf "%-6s" "Dest:")${green}$s_dest${reset}"
        echo -e "  $(printf "%-6s" "WARP:")$s_warp"
        echo -e "${cyan}----------------------------------------------------------------${reset}"
        echo ""
        echo -e "${green}1.${reset} $(msg reality_install)"
        echo -e "${green}2.${reset} $(msg reality_qr)"
        echo -e "${green}3.${reset} $(msg reality_info)"
        echo -e "${green}4.${reset} $(msg reality_uuid)"
        echo -e "${green}5.${reset} $(msg reality_port)"
        echo -e "${green}6.${reset} $(msg reality_dest)"
        echo -e "${green}7.${reset} $(msg reality_restart)"
        echo -e "${green}8.${reset} $(msg reality_logs)"
        echo -e "${green}9.${reset} $(msg reality_remove)"
        echo -e "${green}0.${reset} $(msg back)"
        echo ""
        read -rp "$(msg choose)" choice
        case $choice in
            1) installReality ;;
            2) showRealityQR ;;
            3) showRealityInfo ;;
            4) modifyRealityUUID ;;
            5) modifyRealityPort ;;
            6) modifyRealityDest ;;
            7) systemctl restart xray-reality && echo "${green}$(msg restarted)${reset}" ;;
            8) view_log "/var/log/xray/reality-error.log" "xray-reality" ;;
            9) removeReality ;;
            0) break ;;
        esac
        [ "${choice}" = "0" ] && continue
        echo -e "\n${cyan}$(msg press_enter)${reset}"
        read -r
    done
}
