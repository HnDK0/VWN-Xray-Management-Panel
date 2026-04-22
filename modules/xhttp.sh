#!/bin/bash
# =================================================================
# xhttp.sh — VLESS + XHTTP Transport (CDN совместимый)
#
# Архитектура:
#   ✅ Независим от других модулей
#   ✅ Xray XHTTP inbound слушает локально на 127.0.0.1:LPORT
#   ✅ Nginx проксирует трафик с пути /xhttp-path на этот inbound
#   ✅ Снаружи — всегда порт 443 через nginx
#   ✅ Полностью совместим со всеми CDN включая Cloudflare
# =================================================================

XHTTP_SERVICE="/etc/systemd/system/xray-xhttp.service"

_ensureXhttpLogAccess() {
    mkdir -p /var/log/xray
    touch /var/log/xray/xhttp-error.log || true
    chown -R xray:xray /var/log/xray || true
    chmod 750 /var/log/xray || true
    chmod 640 /var/log/xray/xhttp-error.log || true
}

# ── Статус ────────────────────────────────────────────────────────

getXhttpStatus() {
    if [ ! -f "$xhttpConfigPath" ]; then
        echo -e "${red}NOT INSTALLED${reset}"
        return
    fi
    if systemctl is-active --quiet xray-xhttp; then
        local domain path
        domain=$(vwn_conf_get DOMAIN || true)
        path=$(vwn_conf_get XHTTP_PATH || echo "/xhttp")
        # Красим всю информационную строку в зеленый
        echo -e "${green}RUNNING | ${domain:-?}:443${path} (CDN mode)${reset}"
    else
        echo -e "${red}STOPPED${reset}"
    fi
}

# ── Генерация конфига Xray ─────────────────────────────────────────

writeXhttpConfig() {
    local uuid="$1" path="$2" domain="$3" lport="$4"

    mkdir -p "$(dirname "$xhttpConfigPath")"
    _ensureXhttpLogAccess

    render_config "$VWN_CONFIG_DIR/xray_xhttp.json" "$xhttpConfigPath" \
        UUID   "$uuid"   \
        PATH   "$path"   \
        PORT   "$lport"

    chown xray:xray "$xhttpConfigPath" || true
    chmod 640 "$xhttpConfigPath" || true
    echo "${green}XHTTP config written: $xhttpConfigPath${reset}"
}

# ── Systemd сервис ────────────────────────────────────────────────

setupXhttpService() {
    cat > "$XHTTP_SERVICE" << 'EOF'
[Unit]
Description=Xray XHTTP Service
After=network.target nss-lookup.target

[Service]
User=xray
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/xhttp.json
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable xray-xhttp
    systemctl restart xray-xhttp
    sleep 2

    if systemctl is-active --quiet xray-xhttp; then
        echo "${green}xray-xhttp service started.${reset}"
    else
        echo "${red}xray-xhttp failed to start. Check: journalctl -u xray-xhttp -n 30${reset}"
        return 1
    fi
}

# ── Применение активных фич ───────────────────────────────────────

_xhttpApplyActiveFeatures() {
    echo -e "${cyan}Applying active features to XHTTP config${reset}"

    # WARP
    if command -v warp-cli > /dev/null 2>&1; then
        local warp_raw warp_rule
        warp_raw=$(getWarpStatusRaw || echo "OFF")
        if [ "$warp_raw" = "ACTIVE" ] && [ -f "$configPath" ]; then
            warp_rule=$(_getTunnelMode "warp")
            case "$warp_rule" in
                Global)
                    jq '(.routing.rules[] | select(.outboundTag == "warp")) |= (.port = "0-65535" | del(.domain))' \
                        "$xhttpConfigPath" > "${xhttpConfigPath}.tmp" && mv "${xhttpConfigPath}.tmp" "$xhttpConfigPath" || true
                    ;;
                Split) applyWarpDomains || true ;;
            esac
        fi
    fi

    # Tor
    if systemctl is-active --quiet tor 2>/dev/null; then
        local tor_rule
        tor_rule=$(_getTunnelMode "tor")
        case "$tor_rule" in
            Global) toggleTorGlobal  || true ;;
            Split)  applyTorDomains  || true ;;
        esac
    fi

    # Psiphon
    if systemctl is-active --quiet psiphon 2>/dev/null; then
        local psiphon_rule
        psiphon_rule=$(_getTunnelMode "psiphon")
        case "$psiphon_rule" in
            Global) togglePsiphonGlobal || true ;;
            Split)  applyPsiphonDomains || true ;;
        esac
    fi

    # Relay
    if [ -f "$relayConfigFile" ] && [ -f "$configPath" ]; then
        local relay_rule
        relay_rule=$(_getTunnelMode "relay")
        case "$relay_rule" in
            Global) toggleRelayGlobal || true ;;
            Split)  applyRelayDomains || true ;;
        esac
    fi

    # Adblock
    if _adblockIsEnabled; then
        _adblockApplyToConfig "$xhttpConfigPath" || true
    fi

    # Privacy mode
    if _privacyIsEnabled; then
        _xrayDisableLog "$xhttpConfigPath" || true
    fi
}

# ── Основная установка ────────────────────────────────────────────

installXhttp() {
    local auto_mode=false
    [ "${1:-}" = "--auto" ] && auto_mode=true

    clear
    echo -e "${cyan}================================================================${reset}"
    echo -e "   XHTTP Transport (CDN Compatible)"
    echo -e "${cyan}================================================================${reset}"
    echo ""

    # Проверяем что базовая WS установка есть (nginx держит 443)
    if [ ! -f "$configPath" ]; then
        echo "${red}Сначала выполните базовую установку WS.${reset}"
        return 1
    fi

    local xhttp_domain xhttp_uuid xhttp_path xhttp_lport

    xhttp_domain=$(vwn_conf_get DOMAIN || true)
    if [ -z "$xhttp_domain" ]; then
        echo "${red}Домен не найден. Выполните базовую установку.${reset}"
        return 1
    fi

    # Берём UUID из основного WS конфига чтобы все транспорты использовали один UUID
    # (пользователи хранятся в users.conf с UUID из WS конфига)
    xhttp_uuid=""
    if [ -f "$configPath" ]; then
        xhttp_uuid=$(jq -r '.inbounds[0].settings.clients[0].id // ""' "$configPath" 2>/dev/null || true)
    fi
    # Если WS конфига нет или UUID пуст — генерируем новый
    if [ -z "$xhttp_uuid" ] || [ "$xhttp_uuid" = "null" ]; then
        xhttp_uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null \
            || uuidgen 2>/dev/null \
            || python3 -c "import uuid; print(uuid.uuid4())")
    fi

    # Генерируем уникальный путь
    xhttp_path="/api/v2/$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 12 | head -n 1)"

    # Выбираем свободный локальный порт для inbound
    xhttp_lport=$(findFreePort 45000 45999)
    if [ -z "$xhttp_lport" ]; then
        echo "${red}Не удалось найти свободный локальный порт (45000-45999).${reset}"
        return 1
    fi

    echo -e "${cyan}Домен:${reset}       ${green}${xhttp_domain}${reset}"
    echo -e "${cyan}Путь:${reset}        ${green}${xhttp_path}${reset}"
    echo -e "${cyan}Лок. порт:${reset}   ${green}${xhttp_lport}${reset}"
    echo ""

    # Конфиг Xray
    echo -e "${cyan}Запись XHTTP конфигурации...${reset}"
    writeXhttpConfig "$xhttp_uuid" "$xhttp_path" "$xhttp_domain" "$xhttp_lport"

    # Сохраняем мета-данные до обновления nginx — чтобы writeNginxConfigBase видел XHTTP_PATH/LPORT
    vwn_conf_set XHTTP_ENABLED "true"
    vwn_conf_set XHTTP_UUID    "$xhttp_uuid"
    vwn_conf_set XHTTP_PATH    "$xhttp_path"
    vwn_conf_set XHTTP_LPORT   "$xhttp_lport"

    # Пересобираем nginx конфиг — writeNginxConfigBase сам подставит XHTTP location через плейсхолдер
    echo -e "${cyan}Обновление nginx конфига...${reset}"
    local xray_port ws_path proxy_url
    xray_port=$(jq -r '.inbounds[0].port' "$configPath" 2>/dev/null || true)
    ws_path=$(jq -r '.inbounds[0].streamSettings.wsSettings.path' "$configPath" 2>/dev/null || true)
    proxy_url=$(vwn_conf_get STUB_URL || true)
    writeNginxConfigBase "$xray_port" "$xhttp_domain" "$proxy_url" "$ws_path" || {
        echo "${red}Ошибка обновления nginx конфига. Откат...${reset}"
        vwn_conf_del XHTTP_ENABLED
        vwn_conf_del XHTTP_UUID
        vwn_conf_del XHTTP_PATH
        vwn_conf_del XHTTP_LPORT
        return 1
    }
    nginx -t && systemctl reload nginx || {
        echo "${red}nginx не принял конфиг. Откат...${reset}"
        vwn_conf_del XHTTP_ENABLED
        vwn_conf_del XHTTP_UUID
        vwn_conf_del XHTTP_PATH
        vwn_conf_del XHTTP_LPORT
        writeNginxConfigBase "$xray_port" "$xhttp_domain" "$proxy_url" "$ws_path" || true
        nginx -t && systemctl reload nginx || true
        return 1
    }

    # Сервис
    setupXhttpService || return 1

    # Применяем активные фичи
    _xhttpApplyActiveFeatures

    # Итог
    echo ""
    echo -e "${green}================================================================${reset}"
    echo -e "   XHTTP успешно установлен"
    echo -e "${green}================================================================${reset}"
    showXhttpInfo

    # Перегенерируем подписки
    rebuildAllSubFiles || true
}

# ── Информация ────────────────────────────────────────────────────

showXhttpInfo() {
    if [ ! -f "$xhttpConfigPath" ]; then
        echo "${red}XHTTP не установлен${reset}"
        return
    fi

    local domain uuid path lport
    domain=$(vwn_conf_get DOMAIN     || true)
    uuid=$(vwn_conf_get XHTTP_UUID   || true)
    path=$(vwn_conf_get XHTTP_PATH   || echo "/xhttp")
    lport=$(vwn_conf_get XHTTP_LPORT || echo "?")

    echo ""
    echo -e "${cyan}━━━ XHTTP (CDN транспорт) ━━━${reset}"
    echo ""
    echo -e "  ${cyan}Домен:${reset}      ${green}${domain:-?}${reset}"
    echo -e "  ${cyan}UUID:${reset}       ${green}${uuid:-?}${reset}"
    echo -e "  ${cyan}Порт:${reset}       ${green}443${reset} (nginx → 127.0.0.1:${lport})"
    echo -e "  ${cyan}Путь:${reset}       ${green}${path}${reset}"
    echo -e "  ${cyan}Транспорт:${reset}  VLESS + XHTTP"
    echo -e "  ${cyan}Статус:${reset}     $(getXhttpStatus)"
    echo ""
    echo -e " ✅ Полностью совместимо со всеми CDN"
    echo -e " ✅ Работает независимо от других модулей"
    echo ""
}

showXhttpQR() {
    if [ ! -f "$xhttpConfigPath" ]; then
        echo "${red}XHTTP не установлен${reset}"
        return
    fi

    local domain uuid path
    domain=$(vwn_conf_get DOMAIN   || true)
    uuid=$(vwn_conf_get XHTTP_UUID || true)
    path=$(vwn_conf_get XHTTP_PATH || echo "/xhttp")

    [ -z "$domain" ] || [ -z "$uuid" ] && {
        echo "${red}Данные XHTTP не найдены. Переустановите XHTTP.${reset}"; return
    }

    local flag server_ip v_label v_name v_encoded_name modes path_encoded
    server_ip=$(getServerIP || echo "")
    flag=$(_getCountryFlag "$server_ip" || echo "🌐")
    modes=$(_getActiveModesSuffix || true)
    v_label="default"
    [ -f "$USERS_FILE" ] && v_label=$(cut -d'|' -f2 "$USERS_FILE" | head -1)
    v_name="${flag} VL-XHTTP | ${v_label} ${flag}${modes}"
    v_encoded_name=$(python3 -c "import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1]))" "$v_name" || echo "$v_name")
    path_encoded=$(python3 -c "import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe='/'))" "$path" || echo "$path")

    local link
    link="vless://${uuid}@${domain}:443?security=tls&type=xhttp&path=${path_encoded}&mode=stream-up&alpn=h2&host=${domain}&sni=${domain}&fp=chrome&allowInsecure=0#${v_encoded_name}"

    echo -e "${cyan}XHTTP ссылка:${reset}"
    echo ""
    if command -v qrencode > /dev/null 2>&1; then
        qrencode -t ANSIUTF8 "$link"
    fi
    echo ""
    echo -e "${green}${link}${reset}"
    echo ""
}

# ── Удаление ──────────────────────────────────────────────────────

removeXhttp() {
    echo -e "${red}Удалить XHTTP? $(msg yes_no)${reset}"
    read -r confirm
    [[ "$confirm" != "y" ]] && { echo "$(msg cancel)"; return; }

    echo -e "${cyan}Удаление XHTTP...${reset}"

    systemctl stop xray-xhttp || true
    systemctl disable xray-xhttp || true
    rm -f "$XHTTP_SERVICE"
    systemctl daemon-reload

    rm -f "$xhttpConfigPath"

    # Сначала удаляем данные XHTTP из vwn.conf — тогда writeNginxConfigBase
    # подставит пустую строку вместо __XHTTP_LOCATION__ и location исчезнет
    vwn_conf_del XHTTP_ENABLED
    vwn_conf_del XHTTP_UUID
    vwn_conf_del XHTTP_PATH
    vwn_conf_del XHTTP_LPORT

    # Пересобираем nginx конфиг без XHTTP location
    local xray_port ws_path domain proxy_url
    xray_port=$(jq -r '.inbounds[0].port' "$configPath" 2>/dev/null || true)
    ws_path=$(jq -r '.inbounds[0].streamSettings.wsSettings.path' "$configPath" 2>/dev/null || true)
    domain=$(vwn_conf_get DOMAIN   || true)
    proxy_url=$(vwn_conf_get STUB_URL || true)
    if [ -n "$xray_port" ] && [ -n "$domain" ]; then
        writeNginxConfigBase "$xray_port" "$domain" "$proxy_url" "$ws_path" || true
    fi
    nginx -t && systemctl reload nginx || true

    # Перегенерируем подписки
    rebuildAllSubFiles || true

    echo "${green}XHTTP удалён${reset}"
}

# ── Пересоздание конфигов ─────────────────────────────────────────

rebuildXhttpConfigs() {
    local silent="${1:-}"
    if [ ! -f "$xhttpConfigPath" ]; then
        [ "$silent" != "--silent" ] && echo "${red}XHTTP не установлен${reset}"
        return 1
    fi

    local xhttp_uuid xhttp_path xhttp_domain xhttp_lport
    # Берём UUID из WS конфига (единый UUID для всех транспортов)
    xhttp_uuid=""
    if [ -f "$configPath" ]; then
        xhttp_uuid=$(jq -r '.inbounds[0].settings.clients[0].id // ""' "$configPath" 2>/dev/null || true)
    fi
    # Fallback: берём из vwn.conf если WS конфига нет
    if [ -z "$xhttp_uuid" ] || [ "$xhttp_uuid" = "null" ]; then
        xhttp_uuid=$(vwn_conf_get XHTTP_UUID || true)
    fi
    xhttp_path=$(vwn_conf_get XHTTP_PATH  || echo "/xhttp")
    xhttp_domain=$(vwn_conf_get DOMAIN    || true)
    xhttp_lport=$(vwn_conf_get XHTTP_LPORT || true)

    echo -e "${cyan}Rebuilding XHTTP configs...${reset}"

    writeXhttpConfig "$xhttp_uuid" "$xhttp_path" "$xhttp_domain" "$xhttp_lport"
    _xhttpApplyActiveFeatures

    # Пересобираем nginx чтобы обновить location с актуальным path/port
    local xray_port ws_path proxy_url
    xray_port=$(jq -r '.inbounds[0].port' "$configPath" 2>/dev/null || true)
    ws_path=$(jq -r '.inbounds[0].streamSettings.wsSettings.path' "$configPath" 2>/dev/null || true)
    proxy_url=$(vwn_conf_get STUB_URL || true)
    if [ -n "$xray_port" ] && [ -n "$xhttp_domain" ]; then
        writeNginxConfigBase "$xray_port" "$xhttp_domain" "$proxy_url" "$ws_path" || true
        nginx -t && systemctl reload nginx || true
    fi

    systemctl restart xray-xhttp || true

    echo "${green}XHTTP конфиги пересозданы${reset}"

    # Перегенерируем подписки только если вызвано напрямую, а не из rebuildAllConfigs
    [ "$silent" != "--silent" ] && rebuildAllSubFiles || true
}

# ── Меню ──────────────────────────────────────────────────────────

manageXhttp() {
    set +e
    while true; do
        clear
        echo -e "${cyan}================================================================${reset}"
        printf "   ${cyan}XHTTP (CDN транспорт)${reset}  %s\n" "$(date +'%d.%m.%Y %H:%M')"
        echo -e "${cyan}----------------------------------------------------------------${reset}"
        echo -e "  Статус: $(getXhttpStatus)"
        if [ -f "$xhttpConfigPath" ]; then
            local _dom _path
            _dom=$(vwn_conf_get DOMAIN    || true)
            _path=$(vwn_conf_get XHTTP_PATH || echo "/xhttp")
            echo -e "  Домен: ${green}${_dom:-?}${reset}"
            echo -e "  Путь:  ${green}${_path}${reset}"
        fi
        echo -e "${cyan}----------------------------------------------------------------${reset}"
        echo ""
        echo -e "${green}1.${reset} Установить XHTTP"
        echo -e "${green}2.${reset} Показать информацию"
        echo -e "${green}3.${reset} Показать QR код"
        echo -e "${green}4.${reset} Пересоздать конфиги"
        echo -e "${green}5.${reset} Удалить XHTTP"
        echo -e "${green}0.${reset} $(msg back)"
        echo ""
        read -rp "$(msg choose)" choice
        case $choice in
            1) installXhttp ;;
            2) showXhttpInfo ;;
            3) showXhttpQR ;;
            4) rebuildXhttpConfigs ;;
            5) removeXhttp ;;
            0) break ;;
        esac
        [ "$choice" = "0" ] && continue
        echo -e "\n${cyan}$(msg press_enter)${reset}"
        read -r
    done
}
