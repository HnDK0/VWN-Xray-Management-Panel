#!/bin/bash
# =================================================================
# reality.sh — VLESS + Reality: конфиг, сервис, управление
# =================================================================

getRealityStatus() {
    if [ -f "$realityConfigPath" ]; then
        local port
        port=$(jq -r '.inbounds[0].port' "$realityConfigPath")
        echo "${green}ON ($(msg reality_port) $port)${reset}"
    else
        echo "${red}OFF${reset}"
    fi
}

writeRealityConfig() {
    local realityPort="$1"
    local dest="$2"
    local destHost="${dest%%:*}"

    echo -e "${cyan}$(msg reality_keygen)${reset}"
    local keys="" privKey="" pubKey="" shortId="" new_uuid=""
    local USERS_FILE="${USERS_FILE:-/usr/local/etc/xray/users.conf}"

    # Находим xray — может быть в нескольких местах
    local xray_bin
    for _b in /usr/local/bin/xray /usr/bin/xray; do
        [ -x "$_b" ] && xray_bin="$_b" && break
    done
    if [ -z "$xray_bin" ]; then
        echo "${red}$(msg reality_keys_fail): xray binary not found${reset}"; return 1
    fi

    keys=$("$xray_bin" x25519 2>&1)
    if [ $? -ne 0 ] || [ -z "$keys" ]; then
        echo "${red}$(msg reality_keys_fail): $keys${reset}"; return 1
    fi

    # Формат 1 (xray < 1.8): "Private key: ..." / "Public key: ..."
    privKey=$(echo "$keys" | tr -d '\r' | awk '/^Private key:/{print $3}')
    pubKey=$(echo  "$keys" | tr -d '\r' | awk '/^Public key:/{print $3}')
    # Формат 2 (xray >= 1.8): "PrivateKey: ..." / "PublicKey: ..."
    [ -z "$privKey" ] && privKey=$(echo "$keys" | tr -d '\r' | awk '/^PrivateKey:/{print $2}')
    [ -z "$pubKey"  ] && pubKey=$(echo  "$keys" | tr -d '\r' | awk '/^PublicKey:/{print $2}')
    # Формат 3 (xray >= 24.x): "Password (PublicKey): ..."
    [ -z "$pubKey"  ] && pubKey=$(echo  "$keys" | tr -d '\r' | awk '/^Password \(PublicKey\):/{print $3}')

    if [ -z "$privKey" ] || [ -z "$pubKey" ]; then
        echo "${red}$(msg reality_keys_err). xray output: $keys${reset}"; return 1
    fi

    shortId=$(cat /proc/sys/kernel/random/uuid | tr -d '-' | cut -c1-16)
    # Если users.conf уже есть — берём UUID первого пользователя
    if [ -f "$USERS_FILE" ] && [ -s "$USERS_FILE" ]; then
        new_uuid=$(cut -d'|' -f1 "$USERS_FILE" | head -1)
    fi
    [ -z "$new_uuid" ] && new_uuid=$(cat /proc/sys/kernel/random/uuid)

    mkdir -p /usr/local/etc/xray

    # Проверка существования шаблона
    if [ ! -f "$VWN_CONFIG_DIR/xray_reality.json" ]; then
        echo "error: xray_reality.json template not found" >&2
        return 1
    fi

    # Автодетект формата шаблона — плейсхолдеры или валидный JSON
    if grep -qE '__UUID__|__PORT__|__PRIVKEY__|__SHORTID__|__DEST__|__HOST__' \
            "$VWN_CONFIG_DIR/xray_reality.json"; then
        render_config "$VWN_CONFIG_DIR/xray_reality.json" "$realityConfigPath" \
            UUID     "$new_uuid" \
            PORT     "$realityPort" \
            PRIVKEY  "$privKey" \
            SHORTID  "$shortId" \
            DEST     "$dest" \
            HOST     "$destHost"
    else
        # Генерируем конфиг из шаблона через jq
        jq \
            --arg port     "$realityPort" \
            --arg dest     "$dest" \
            --arg host     "$destHost" \
            --arg privKey  "$privKey" \
            --arg shortId  "$shortId" \
            --arg uuid     "$new_uuid" \
            '
                .inbounds[0].port = ($port | tonumber)
                | .inbounds[0].streamSettings.realitySettings.dest = $dest
                | .inbounds[0].streamSettings.realitySettings.serverNames[0] = $host
                | .inbounds[0].streamSettings.realitySettings.privateKey = $privKey
                | .inbounds[0].streamSettings.realitySettings.shortIds[0] = $shortId
                | .inbounds[0].settings.clients[0].id = $uuid
            ' "$VWN_CONFIG_DIR/xray_reality.json" > "$realityConfigPath"
    fi

    # Валидация результата
    if ! jq . "$realityConfigPath"; then
        echo "error: writeRealityConfig produced invalid JSON at $realityConfigPath" >&2
        return 1
    fi

    cat > /usr/local/etc/xray/reality_client.txt << EOF
=== Reality параметры для клиента ===
UUID:       $new_uuid
PublicKey:  $pubKey
ShortId:    $shortId
ServerName: $destHost
Port:       $realityPort
Flow:       xtls-rprx-vision
EOF

    # Сохраняем pubKey в vwn.conf — надёжный источник
    vwn_conf_set REALITY_PUBKEY   "$pubKey"
    vwn_conf_set REALITY_DEST     "${destHost}:443"
    vwn_conf_set REALITY_SHORT_ID "$shortId"

    echo "${green}$(msg reality_config_ok)${reset}"
    cat /usr/local/etc/xray/reality_client.txt
}

setupRealityService() {
    # Создаём пользователя xray если не существует
    id xray || useradd -r -s /sbin/nologin -d /usr/local/etc/xray xray

    # Создаём директорию логов и передаём под пользователя xray
    mkdir -p /var/log/xray
    chown -R xray:xray /var/log/xray
    chmod 750 /var/log/xray

    # Создаём файл лога заранее с нужным владельцем
    touch /var/log/xray/reality-error.log
    chown xray:xray /var/log/xray/reality-error.log

    # Переводим основной xray-сервис тоже на пользователя xray
    # чтобы оба сервиса работали под одним пользователем
    local xray_svc
    for f in /etc/systemd/system/xray.service /usr/lib/systemd/system/xray.service /lib/systemd/system/xray.service; do
        [ -f "$f" ] && xray_svc="$f" && break
    done
    if [ -n "$xray_svc" ]; then
        sed -i 's/User=nobody/User=xray/' "$xray_svc"
        sed -i 's/Group=nogroup/Group=xray/' "$xray_svc"
        systemctl daemon-reload
        systemctl restart xray || true
    fi
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
    run_task "Чистка пакетов"   "rm -f /var/lib/dpkg/lock* && dpkg --configure -a || true"
    run_task "Обновление репозиториев" "$PACKAGE_MANAGEMENT_UPDATE"

    echo "--- [2/3] $(msg install_deps) ---"
    for p in tar gpg unzip jq nano ufw socat curl qrencode python3; do
        run_task "Установка $p" "installPackage '$p'" || true
    done
    if ! command -v xray; then
        run_task "Установка Xray-core" installXray
    fi
    if ! command -v warp-cli; then
        run_task "Установка Cloudflare WARP" installWarp
    fi

    echo "--- [3/3] $(msg menu_sep_sec) ---"
    run_task "Настройка UFW" "ufw allow 22/tcp && echo 'y' | ufw enable"
    run_task "Системные параметры" applySysctl
    if ! systemctl is-active --quiet warp-svc; then
        run_task "Настройка WARP" configWarp
        run_task "WARP Watchdog" setupWarpWatchdog
    fi
    run_task "Ротация логов" setupLogrotate
    run_task "Автоочистка логов" setupLogClearCron

    read -rp "$(msg reality_port_prompt)" realityPort
    [ -z "$realityPort" ] && realityPort=8443
    if ! [[ "$realityPort" =~ ^[0-9]+$ ]] || [ "$realityPort" -lt 1024 ] || [ "$realityPort" -gt 65535 ]; then
        echo "${red}$(msg invalid_port)${reset}"; return 1
    fi

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

    echo -e "${cyan}$(msg reality_open_port) $realityPort $(msg reality_ufw)${reset}"
    ufw allow "$realityPort"/tcp comment 'Xray Reality' || true

    writeRealityConfig "$realityPort" "$dest" || return 1
    setupRealityService || return 1

    vwn_conf_set REALITY_PORT "$realityPort"

    # Синхронизируем WARP и Relay домены в новый конфиг
    [ -f "$warpDomainsFile" ] && applyWarpDomains
    [ -f "$relayConfigFile" ] && applyRelayDomains
    [ -f "$psiphonConfigFile" ] && applyPsiphonDomains

    echo -e "\n${green}$(msg reality_installed)${reset}"
    showRealityQR
}


# Возвращает публичный IP — если автоопределение дало приватный/неизвестный адрес,
# спрашивает у пользователя
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
    shortId=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$realityConfigPath")
    destHost=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$realityConfigPath")
    serverIP=$(_getPublicIP)
    pubKey=$(vwn_conf_get REALITY_PUBKEY)
    [ -z "$pubKey" ] && pubKey=$(grep "PublicKey:" /usr/local/etc/xray/reality_client.txt | awk '{print $2}')

    port=$(jq -r '.inbounds[0].port' "$realityConfigPath")

    echo "UUID:        $uuid"
    echo "IP:          $serverIP"
    echo "$(msg reality_port): $port"
    echo "PublicKey:   $pubKey"
    echo "ShortId:     $shortId"
    echo "ServerName:  $destHost"
    echo "Flow:        xtls-rprx-vision"
    echo "--------------------------------------------------"
    local r_label r_name r_encoded_name
    r_label="default"
    [ -f "$USERS_FILE" ] && r_label=$(cut -d'|' -f2 "$USERS_FILE" | head -1)
    r_name=$(_getConfigName "Reality" "$r_label" "$serverIP")
    r_encoded_name=$(python3 -c "import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1]))" "$r_name" || echo "$r_name")
    local url="vless://${uuid}@${serverIP}:${port}?encryption=none&security=reality&sni=${destHost}&fp=chrome&pbk=${pubKey}&sid=${shortId}&type=tcp&flow=xtls-rprx-vision#${r_encoded_name}"
    echo -e "${green}$url${reset}"
    echo "--------------------------------------------------"
}

showRealityQR() {
    [ ! -f "$realityConfigPath" ] && { echo "${red}$(msg reality_not_installed)${reset}"; return 1; }

    local uuid port shortId destHost pubKey serverIP
    uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$realityConfigPath")
    shortId=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$realityConfigPath")
    destHost=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$realityConfigPath")
    pubKey=$(vwn_conf_get REALITY_PUBKEY)
    [ -z "$pubKey" ] && pubKey=$(grep "PublicKey:" /usr/local/etc/xray/reality_client.txt | awk '{print $2}')
    serverIP=$(_getPublicIP)

    port=$(jq -r '.inbounds[0].port' "$realityConfigPath")

    local r_label r_name r_encoded_name
    r_label="default"
    [ -f "$USERS_FILE" ] && r_label=$(cut -d'|' -f2 "$USERS_FILE" | head -1)
    r_name=$(_getConfigName "Reality" "$r_label" "$serverIP")
    r_encoded_name=$(python3 -c "import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1]))" "$r_name" || echo "$r_name")
    local url="vless://${uuid}@${serverIP}:${port}?encryption=none&security=reality&sni=${destHost}&fp=chrome&pbk=${pubKey}&sid=${shortId}&type=tcp&flow=xtls-rprx-vision#${r_encoded_name}"
    command -v qrencode || installPackage "qrencode"
    qrencode -s 1 -m 1 -t ANSIUTF8 "$url"
    echo -e "\n${green}$url${reset}\n"
}

modifyRealityUUID() {
    # UUID управляется централизованно через users.conf
    # Используем общую функцию которая обновляет оба конфига
    modifyXrayUUID
}

modifyRealityPort() {
    [ ! -f "$realityConfigPath" ] && { echo "${red}$(msg reality_not_installed)${reset}"; return 1; }

    local oldPort
    oldPort=$(jq '.inbounds[0].port' "$realityConfigPath")
    read -rp "$(msg reality_port) [$oldPort]: " newPort
    [ -z "$newPort" ] && return
    if ! [[ "$newPort" =~ ^[0-9]+$ ]] || [ "$newPort" -lt 1024 ] || [ "$newPort" -gt 65535 ]; then
        echo "${red}$(msg invalid_port)${reset}"; return 1
    fi
    ufw allow "$newPort"/tcp comment 'Xray Reality' || true
    ufw delete allow "$oldPort"/tcp || true
    jq ".inbounds[0].port = $newPort" \
        "$realityConfigPath" > "${realityConfigPath}.tmp" && mv "${realityConfigPath}.tmp" "$realityConfigPath"
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
        "$realityConfigPath" > "${realityConfigPath}.tmp" && mv "${realityConfigPath}.tmp" "$realityConfigPath"
    systemctl restart xray-reality
    echo "${green}$(msg reality_dest_changed) $newDest${reset}"
    rebuildAllSubFiles || true
}

removeReality() {
    echo -e "${red}$(msg reality_remove_confirm) $(msg yes_no)${reset}"
    read -r confirm
    if [[ "$confirm" == "y" ]]; then
        systemctl stop xray-reality || true
        systemctl disable xray-reality || true
        rm -f /etc/systemd/system/xray-reality.service
        rm -f "$realityConfigPath" /usr/local/etc/xray/reality_client.txt
        systemctl daemon-reload
        echo "${green}$(msg removed)${reset}"
        rebuildAllSubFiles || true
    fi
}

rebuildRealityConfigs() {
    local skip_sub="${1:-false}"
    if [ ! -f "$realityConfigPath" ]; then
        echo "${red}$(msg reality_not_installed)${reset}"; return 1;
    fi

    local realityPort dest
    realityPort=$(jq -r '.inbounds[0].port // ""' "$realityConfigPath")
    dest=$(jq -r '.inbounds[0].streamSettings.realitySettings.dest // ""' "$realityConfigPath")

    # ❗ НИКОГДА НЕ ГЕНЕРИРУЕМ НОВЫЕ КЛЮЧИ!
    # Все ключи остаются нетронутыми, мы только перезаписываем шаблон

    if [ -z "$realityPort" ] || [ -z "$dest" ]; then
        echo "${red}$(msg reality_not_installed) (missing params)${reset}"; return 1;
    fi

    echo -e "${cyan}Rebuilding Reality configs...${reset}"

    echo -e "  ${cyan}[1/2] reality.json...${reset}"
    writeRealityConfig "$realityPort" "$dest"

    echo -e "  ${cyan}[2/2] Applying active features...${reset}"
    [ -f "$warpDomainsFile" ] && applyWarpDomains || true
    [ -f "$relayConfigFile" ] && applyRelayDomains || true
    [ -f "$psiphonConfigFile" ] && applyPsiphonDomains || true
    [ -f "$torConfigFile" ] && applyTorDomains || true
    _adblockIsEnabled && _adblockApplyToConfig "$realityConfigPath" || true
    _privacyIsEnabled && _xrayDisableLog "$realityConfigPath" || true

    systemctl restart xray-reality || true

    $skip_sub || rebuildAllSubFiles || true

    echo "${green}Done. Reality configs rebuilt.${reset}"
}

manageReality() {
    set +e
    while true; do
        clear
        local s_reality s_warp s_port s_dest
        s_reality=$(getServiceStatus xray-reality)
        s_warp=$(getWarpStatus)
        s_port=$(jq -r '.inbounds[0].port // "—"' "$realityConfigPath")
        s_dest=$(jq -r '.inbounds[0].streamSettings.realitySettings.dest // "—"' "$realityConfigPath")
        echo -e "${cyan}================================================================${reset}"
        printf "   ${red}VLESS + Reality${reset}  %s\n" "$(date +'%d.%m.%Y %H:%M')"
        echo -e "${cyan}----------------------------------------------------------------${reset}"
        echo -e "  $(printf "%-6s" "Xray:")$s_reality,  $(msg lbl_port): ${green}$s_port${reset},  $(msg lbl_dest): ${green}$s_dest${reset}"
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
        echo -e "${green}10.${reset} $(msg menu_rebuild_reality)"
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
            8) journalctl -u xray-reality -n 50 --no-pager
               echo "---"
               tail -n 30 /var/log/xray/reality-error.log || true ;;
            9) removeReality ;;
            10) rebuildRealityConfigs ;;
            0) break ;;
        esac
        [ "${choice}" = "0" ] && continue
        echo -e "\n${cyan}$(msg press_enter)${reset}"
        read -r
    done
}