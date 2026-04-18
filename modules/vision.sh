#!/bin/bash
# =================================================================
# vision.sh — VLESS + TLS + Vision flow (xtls-rprx-vision)
#
# Архитектура:
#   443 (xray-vision напрямую, TLS termination в Xray)
#     ├── Использует ОБЩИЙ сертификат /etc/nginx/cert/cert.pem
#     └── fallback (не-Vision трафик) → 127.0.0.1:7443 (nginx без SSL)
#
# Домен: ОБЩИЙ с WS (из vwn.conf DOMAIN)
# Конфиг:     /usr/local/etc/xray/vision.json
# Сервис:     xray-vision
# =================================================================

VISION_SERVICE="/etc/systemd/system/xray-vision.service"

_ensureVisionLogAccess() {
    mkdir -p /var/log/xray
    touch /var/log/xray/vision-error.log 2>/dev/null || true
    chown -R xray:xray /var/log/xray 2>/dev/null || true
    chmod 750 /var/log/xray 2>/dev/null || true
    chmod 640 /var/log/xray/vision-error.log 2>/dev/null || true
}

# ── Статус ────────────────────────────────────────────────────────

getVisionStatus() {
    if [ ! -f "$visionConfigPath" ]; then
        echo "${red}NOT INSTALLED${reset}"
        return
    fi
    if systemctl is-active --quiet xray-vision 2>/dev/null; then
        local domain
        domain=$(vwn_conf_get DOMAIN 2>/dev/null || true)
        echo "${green}RUNNING${reset} | ${domain:-?}:443 (напрямую)"
    else
        echo "${red}STOPPED${reset}"
    fi
}

# ── Генерация конфига Xray из шаблона ────────────────────────────

writeVisionConfig() {
    local uuid="$1"

    mkdir -p "$(dirname "$visionConfigPath")"
    _ensureVisionLogAccess

    render_config "$VWN_CONFIG_DIR/xray_vision.json" "$visionConfigPath" \
        UUID "$uuid"

    chown xray:xray "$visionConfigPath" 2>/dev/null || true
    chmod 640 "$visionConfigPath" 2>/dev/null || true
    echo "${green}Vision config written: $visionConfigPath${reset}"
}

# ── Systemd сервис ────────────────────────────────────────────────

setupVisionService() {
    cp "$VWN_CONFIG_DIR/xray-vision.service" "$VISION_SERVICE"
    systemctl daemon-reload
    systemctl enable xray-vision
    systemctl restart xray-vision
    sleep 2
    if systemctl is-active --quiet xray-vision; then
        echo "${green}xray-vision service started.${reset}"
    else
        echo "${red}xray-vision failed to start. Check: journalctl -u xray-vision -n 30${reset}"
        return 1
    fi
}

# ── Применение активных фич к vision конфигу ─────────────────────

_visionApplyActiveFeatures() {
    echo -e "${cyan}$(msg vision_apply_features)${reset}"

    # WARP
    if command -v warp-cli &>/dev/null; then
        local warp_raw warp_rule
        warp_raw=$(getWarpStatusRaw 2>/dev/null || echo "OFF")
        if [ "$warp_raw" = "ACTIVE" ] && [ -f "$configPath" ]; then
            warp_rule=$(jq -r '.routing.rules[] | select(.outboundTag=="warp") | if .port == "0-65535" then "Global" elif (.domain | length) > 0 then "Split" else "" end' "$configPath" 2>/dev/null | head -1)
            case "$warp_rule" in
                Global)
                    jq '(.routing.rules[] | select(.outboundTag == "warp")) |= (.port = "0-65535" | del(.domain))' \
                        "$visionConfigPath" > "${visionConfigPath}.tmp" && mv "${visionConfigPath}.tmp" "$visionConfigPath" 2>/dev/null || true
                    ;;
                Split) applyWarpDomains 2>/dev/null || true ;;
            esac
        fi
    fi

    # Relay
    if [ -f "$relayConfigFile" ] && [ -f "$configPath" ]; then
        local relay_rule
        relay_rule=$(jq -r '.routing.rules[] | select(.outboundTag=="relay") | if .port == "0-65535" then "Global" elif (.domain | length) > 0 then "Split" else "" end' "$configPath" 2>/dev/null | head -1)
        case "$relay_rule" in
            Global) toggleRelayGlobal 2>/dev/null || true ;;
            Split)  applyRelayDomains 2>/dev/null || true ;;
        esac
    fi

    # Psiphon
    if [ -f "$psiphonConfigFile" ] && [ -f "$configPath" ]; then
        local psiphon_rule
        psiphon_rule=$(jq -r '.routing.rules[] | select(.outboundTag=="psiphon") | if .port == "0-65535" then "Global" elif (.domain | length) > 0 then "Split" else "" end' "$configPath" 2>/dev/null | head -1)
        case "$psiphon_rule" in
            Global) togglePsiphonGlobal 2>/dev/null || true ;;
            Split)  applyPsiphonDomains 2>/dev/null || true ;;
        esac
    fi

    # Tor
    if command -v tor &>/dev/null && [ -f "$configPath" ]; then
        local tor_rule
        tor_rule=$(jq -r '.routing.rules[] | select(.outboundTag=="tor") | if .port == "0-65535" then "Global" elif (.domain | length) > 0 then "Split" else "" end' "$configPath" 2>/dev/null | head -1)
        case "$tor_rule" in
            Global) toggleTorGlobal 2>/dev/null || true ;;
            Split)  applyTorDomains 2>/dev/null || true ;;
        esac
    fi

    # Adblock
    if _adblockIsEnabled 2>/dev/null; then
        _adblockApplyToConfig "$visionConfigPath" 2>/dev/null || true
    fi

    # Privacy mode
    if _privacyIsEnabled 2>/dev/null; then
        _xrayDisableLog "$visionConfigPath" 2>/dev/null || true
    fi
}

# ── Основная установка ────────────────────────────────────────────

installVision() {
    local auto_mode=false
    [ "${1:-}" = "--auto" ] && auto_mode=true

    if ! $auto_mode; then
        clear
    fi
    echo -e "${cyan}================================================================${reset}"
    echo -e "   $(msg vision_title)"
    echo -e "${cyan}================================================================${reset}"
    echo ""

    # 1. WS+TLS должен быть установлен (нужен Nginx + SSL cert + домен)
    if [ ! -f "$configPath" ] || ! command -v nginx &>/dev/null; then
        echo "${red}$(msg vision_ws_required)${reset}"
        return 1
    fi
    if [ ! -f /etc/nginx/cert/cert.pem ]; then
        echo "${red}SSL сертификат не найден. Сначала установите WS+TLS.${reset}"
        return 1
    fi

    # 2. Stream SNI и Vision несовместимы — отключаем Stream если активен
    if grep -q "ssl_preread on" /etc/nginx/nginx.conf 2>/dev/null; then
        echo "${yellow}Stream SNI активен. Vision не может работать одновременно с Stream.${reset}"
        if $auto_mode; then
            echo -e "${cyan}Автоматически отключаю Stream SNI...${reset}"
            _doDisableStreamSNI || { echo "${red}Stream SNI disable failed.${reset}"; return 1; }
        else
            echo -e "${yellow}Отключить Stream SNI автоматически? $(msg yes_no)${reset}"
            read -r _disable_sni
            if [[ "$_disable_sni" == "y" ]]; then
                _doDisableStreamSNI || { echo "${red}Stream SNI disable failed.${reset}"; return 1; }
            else
                echo "${red}$(msg cancel)${reset}"
                return 1
            fi
        fi
    fi

    # 3. Проверяем что порт 443 свободен
    local _port443_proc
    _port443_proc=$(ss -tlnp 'sport = :443' 2>/dev/null | awk 'NR>1{print $NF}' | grep -v nginx | grep -v xray || true)
    if [ -n "$_port443_proc" ]; then
        echo "${red}Порт 443 занят другим процессом: ${_port443_proc}${reset}"
        echo "${yellow}Освободите порт 443 перед установкой Vision.${reset}"
        return 1
    fi

    # 4. Используем ОБЩИЙ домен из WS
    local vision_domain
    vision_domain=$(vwn_conf_get DOMAIN 2>/dev/null || true)
    if [ -z "$vision_domain" ]; then
        echo "${red}Домен не настроен. Сначала установите WS+TLS.${reset}"
        return 1
    fi
    echo -e "${cyan}Используется домен:${reset} ${green}${vision_domain}${reset}"

    # 5. UUID
    local uuid
    uuid=$(xray uuid 2>/dev/null || python3 -c "import uuid; print(uuid.uuid4())")

    # 6. Конфиг Xray (Vision на 443, fallback на 7443)
    echo -e "${cyan}$(msg vision_installing)${reset}"
    writeVisionConfig "$uuid"

    # 7. Пересобираем Nginx конфиг — Vision режим (Nginx на 7443 без SSL)
    local proxy_url
    proxy_url=$(vwn_conf_get STUB_URL 2>/dev/null || echo "https://www.bing.com/")
    writeNginxConfigVision "$proxy_url" "$vision_domain"

    # 8. Сервис
    setupVisionService || return 1

    # 9. Сохраняем мета-данные
    vwn_conf_set VISION_UUID      "$uuid"

    # 10. Применяем активные фичи
    _visionApplyActiveFeatures

    # 11. Итог
    echo ""
    echo -e "${green}================================================================${reset}"
    echo -e "   $(msg vision_installed)"
    echo -e "${green}================================================================${reset}"
    showVisionInfo
    showVisionQR

    # 12. Перегенерируем подписки
    rebuildAllSubFiles 2>/dev/null || true
}

# ── Информация и QR ───────────────────────────────────────────────

showVisionInfo() {
    if [ ! -f "$visionConfigPath" ]; then
        echo "${red}$(msg vision_not_installed)${reset}"
        return
    fi

    local domain uuid server_ip
    domain=$(vwn_conf_get DOMAIN 2>/dev/null || true)
    uuid=$(vwn_conf_get VISION_UUID 2>/dev/null || \
        jq -r '.inbounds[0].settings.clients[0].id // ""' "$visionConfigPath" 2>/dev/null)
    server_ip=$(getServerIP)

    echo ""
    echo -e "${cyan}━━━ $(msg vision_qr_title) ━━━${reset}"
    echo ""
    echo -e "  ${cyan}$(msg lbl_domain):${reset}  ${green}${domain:-?}${reset}"
    echo -e "  ${cyan}UUID:${reset}    ${green}${uuid:-?}${reset}"
    echo -e "  ${cyan}$(msg lbl_port):${reset}   ${green}443${reset} (Xray Vision напрямую)"
    echo -e "  ${cyan}Server IP:${reset} ${server_ip}"
    echo -e "  ${cyan}Flow:${reset}    xtls-rprx-vision"
    echo -e "  ${cyan}TLS:${reset}     TLSv1.2 / TLSv1.3"
    echo -e "  ${cyan}Network:${reset} tcp"
    echo -e "  ${cyan}Fallback:${reset} 127.0.0.1:7443 (Nginx WS)"
    echo ""
}

showVisionQR() {
    if [ ! -f "$visionConfigPath" ]; then
        echo "${red}$(msg vision_not_installed)${reset}"
        return
    fi

    local domain uuid
    domain=$(vwn_conf_get DOMAIN 2>/dev/null || true)
    uuid=$(vwn_conf_get VISION_UUID 2>/dev/null || \
        jq -r '.inbounds[0].settings.clients[0].id // ""' "$visionConfigPath" 2>/dev/null)

    [ -z "$domain" ] || [ -z "$uuid" ] && {
        echo "${red}$(msg vision_not_installed)${reset}"; return
    }

    local flag server_ip v_label v_name v_encoded_name modes
    server_ip=$(getServerIP 2>/dev/null || echo "")
    flag=$(_getCountryFlag "$server_ip" 2>/dev/null || echo "🌐")
    modes=$(_getActiveModesSuffix 2>/dev/null || true)
    v_label="default"
    [ -f "$USERS_FILE" ] && v_label=$(cut -d'|' -f2 "$USERS_FILE" | head -1)
    v_name="${flag} VL-Vision | ${v_label} ${flag}${modes}"
    v_encoded_name=$(python3 -c "import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1]))" "$v_name" 2>/dev/null || echo "$v_name")

    local link
    link="vless://${uuid}@${domain}:443?security=tls&flow=xtls-rprx-vision&type=tcp&sni=${domain}&fp=chrome&allowInsecure=0#${v_encoded_name}"

    echo -e "${cyan}$(msg vision_qr_title):${reset}"
    echo ""
    if command -v qrencode &>/dev/null; then
        qrencode -t ANSIUTF8 "$link"
    fi
    echo ""
    echo -e "${green}${link}${reset}"
    echo ""
}

# ── Изменение параметров ──────────────────────────────────────────

modifyVisionUUID() {
    if [ ! -f "$visionConfigPath" ]; then
        echo "${red}$(msg vision_not_installed)${reset}"; return
    fi
    local new_uuid
    new_uuid=$(xray uuid 2>/dev/null || python3 -c "import uuid; print(uuid.uuid4())")
    jq --arg u "$new_uuid" \
        '.inbounds[0].settings.clients[0].id = $u' \
        "$visionConfigPath" > "${visionConfigPath}.tmp" \
        && mv "${visionConfigPath}.tmp" "$visionConfigPath"
    vwn_conf_set VISION_UUID "$new_uuid"
    systemctl restart xray-vision 2>/dev/null || true
    echo "${green}$(msg vision_uuid_changed)${reset}"
    echo "  New UUID: ${green}${new_uuid}${reset}"
}

# ── Смена домена (общего) с перевыпуском сертификата ─────────────
modifyVisionDomain() {
    if [ ! -f "$visionConfigPath" ]; then
        echo "${red}$(msg vision_not_installed)${reset}"
        return 1
    fi

    local current_domain
    current_domain=$(vwn_conf_get DOMAIN 2>/dev/null || true)
    echo -e "${cyan}Текущий домен:${reset} ${green}${current_domain:-?}${reset}"
    read -rp "$(msg enter_new_domain): " new_domain
    [ -z "$new_domain" ] && return

    if ! _validateDomain "$new_domain" &>/dev/null; then
        echo "${red}$(msg invalid): '$new_domain'${reset}"
        return 1
    fi

    # 1. Обновляем домен в vwn.conf
    vwn_conf_set DOMAIN "$new_domain"

    # 2. Перевыпускаем SSL сертификат (общий для WS и Vision)
    echo -e "${cyan}Перевыпуск SSL сертификата для домена ${new_domain}...${reset}"
    userDomain="$new_domain"
    configCert || { echo "${red}Ошибка выпуска сертификата${reset}"; return 1; }

    # 3. Обновляем WS config.json (если установлен)
    if [ -f "$configPath" ]; then
        jq ".inbounds[0].streamSettings.wsSettings.host = \"$new_domain\"" \
            "$configPath" > "${configPath}.tmp" && mv "${configPath}.tmp" "$configPath"
        echo "${green}WS config обновлён.${reset}"
    fi

    # 4. Обновляем Vision config.json
    local vision_uuid
    vision_uuid=$(vwn_conf_get VISION_UUID 2>/dev/null || \
        jq -r '.inbounds[0].settings.clients[0].id // ""' "$visionConfigPath" 2>/dev/null)
    if [ -n "$vision_uuid" ]; then
        writeVisionConfig "$vision_uuid"
        echo "${green}Vision config обновлён.${reset}"
    fi

    # 5. Пересобираем nginx в режиме Vision
    local proxy_url
    proxy_url=$(vwn_conf_get STUB_URL 2>/dev/null || echo "https://www.bing.com/")
    writeNginxConfigVision "$proxy_url" "$new_domain"
    echo "${green}Nginx config (Vision mode) обновлён.${reset}"

    # 6. Перезапускаем сервисы
    systemctl restart nginx xray xray-vision 2>/dev/null || true
    if ! systemctl is-active --quiet xray-vision; then
        echo "${red}xray-vision не запустился. Проверьте journalctl -u xray-vision${reset}"
        return 1
    fi

    # 7. Обновляем подписки
    rebuildAllSubFiles 2>/dev/null || true

    echo "${green}Домен успешно изменён на ${new_domain}${reset}"
}

# ── Удаление ──────────────────────────────────────────────────────

removeVision() {
    echo -e "${red}$(msg vision_remove_confirm) $(msg yes_no)${reset}"
    read -r confirm
    [[ "$confirm" != "y" ]] && { echo "$(msg cancel)"; return; }

    echo -e "${cyan}Removing Vision...${reset}"

    systemctl stop xray-vision 2>/dev/null || true
    systemctl disable xray-vision 2>/dev/null || true
    rm -f "$VISION_SERVICE"
    systemctl daemon-reload

    rm -f "$visionConfigPath"

    vwn_conf_del VISION_UUID

    # Пересобираем Nginx — вернёт на base режим (Nginx на 443)
    local ws_domain ws_port proxy_url ws_path
    ws_domain=$(vwn_conf_get DOMAIN 2>/dev/null || true)
    ws_port=$(jq -r '.inbounds[0].port // empty' "$configPath" 2>/dev/null)
    proxy_url=$(grep -oP "(?<=proxy_pass )[^;]+" "$nginxPath" 2>/dev/null | tail -1)
    ws_path=$(jq -r '.inbounds[0].streamSettings.wsSettings.path // ""' "$configPath" 2>/dev/null)
    writeNginxConfigBase "$ws_port" "$ws_domain" "$proxy_url" "$ws_path"

    nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || true

    echo "${green}$(msg vision_removed)${reset}"
}

# ── Пересоздание конфигов без переустановки ──────────────────────

rebuildVisionConfigs() {
    local skip_sub="${1:-false}"
    if [ ! -f "$visionConfigPath" ]; then
        echo "${red}$(msg vision_not_installed)${reset}"; return 1
    fi

    local vision_uuid
    vision_uuid=$(vwn_conf_get VISION_UUID 2>/dev/null || \
        jq -r '.inbounds[0].settings.clients[0].id // ""' "$visionConfigPath" 2>/dev/null)

    if [ -z "$vision_uuid" ]; then
        echo "${red}$(msg vision_not_installed) (missing params in vwn.conf)${reset}"; return 1
    fi

    echo -e "${cyan}Rebuilding Vision configs...${reset}"

    echo -e "  ${cyan}[1/3] vision.json...${reset}"
    writeVisionConfig "$vision_uuid"

    echo -e "  ${cyan}[2/3] nginx.conf...${reset}"
    local domain proxy_url
    domain=$(vwn_conf_get DOMAIN 2>/dev/null || true)
    proxy_url=$(vwn_conf_get STUB_URL 2>/dev/null || echo "https://www.bing.com/")
    writeNginxConfigVision "$proxy_url" "$domain"

    echo -e "  ${cyan}[3/3] Restarting services...${reset}"
    nginx -t && systemctl reload nginx || {
        echo "${red}$(msg nginx_syntax_err)${reset}"; return 1
    }
    systemctl restart xray-vision 2>/dev/null || true
    if ! systemctl is-active --quiet xray-vision 2>/dev/null; then
        echo "${red}xray-vision failed to start after rebuild.${reset}"
        journalctl -u xray-vision -n 30 --no-pager 2>/dev/null || true
        return 1
    fi

    $skip_sub || rebuildAllSubFiles 2>/dev/null || true

    echo "${green}Done. Vision configs rebuilt.${reset}"
}

# ── Меню ──────────────────────────────────────────────────────────

manageVision() {
    set +e
    while true; do
        clear
        echo -e "${cyan}================================================================${reset}"
        printf "   ${red}$(msg vision_title)${reset}  %s\n" "$(date +'%d.%m.%Y %H:%M')"
        echo -e "${cyan}----------------------------------------------------------------${reset}"
        echo -e "  $(msg status): $(getVisionStatus)"
        if [ -f "$visionConfigPath" ]; then
            local _dom _uuid
            _dom=$(vwn_conf_get DOMAIN 2>/dev/null || true)
            _uuid=$(vwn_conf_get VISION_UUID 2>/dev/null || true)
            echo -e "  $(msg lbl_domain): ${green}${_dom:-?}${reset}"
            echo -e "  UUID:   ${green}${_uuid:-?}${reset}"
            echo -e "  $(msg lbl_port):   443 (напрямую)"
        fi
        echo -e "${cyan}----------------------------------------------------------------${reset}"
        echo ""
        echo -e "${green}1.${reset} $(msg vision_install)"
        echo -e "${green}2.${reset} $(msg vision_info)"
        echo -e "${green}3.${reset} $(msg vision_qr)"
        echo -e "${green}4.${reset} $(msg vision_modify_uuid)"
        echo -e "${green}5.${reset} $(msg vision_remove)"
        echo -e "${green}6.${reset} $(msg menu_rebuild_vision)"
        echo -e "${green}7.${reset} Change domain (re-issue certificate)"
        echo -e "${green}0.${reset} $(msg back)"
        echo ""
        read -rp "$(msg choose)" choice
        case $choice in
            1) installVision ;;
            2) showVisionInfo ;;
            3) showVisionQR ;;
            4) modifyVisionUUID ;;
            5) removeVision ;;
            6) rebuildVisionConfigs ;;
            7) modifyVisionDomain ;;
            0) break ;;
        esac
        [ "$choice" = "0" ] && continue
        echo -e "\n${cyan}$(msg press_enter)${reset}"
        read -r
    done
}