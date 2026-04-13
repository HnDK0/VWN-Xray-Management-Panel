#!/bin/bash
# =================================================================
# vision.sh — VLESS + TLS + Vision flow (xtls-rprx-vision)
#
# Архитектура:
#   443 (nginx stream ssl_preread)
#     └── vision-domain → 127.0.0.1:<vision_port> (xray-vision)
#                              ↓ fallback
#                         127.0.0.1:7443 (nginx stub, общая с WS)
#
# Сертификат: /etc/nginx/cert/vision.pem + vision.key
# Конфиг:     /usr/local/etc/xray/vision.json
# Сервис:     xray-vision
# =================================================================

VISION_SERVICE="/etc/systemd/system/xray-vision.service"
VISION_CERT_PEM="/etc/nginx/cert/vision.pem"
VISION_CERT_KEY="/etc/nginx/cert/vision.key"

# ── Статус ────────────────────────────────────────────────────────

getVisionStatus() {
    if [ ! -f "$visionConfigPath" ]; then
        echo "${red}NOT INSTALLED${reset}"
        return
    fi
    if systemctl is-active --quiet xray-vision 2>/dev/null; then
        local domain port
        domain=$(vwn_conf_get VISION_DOMAIN 2>/dev/null || true)
        port=$(vwn_conf_get vision_port 2>/dev/null || true)
        echo "${green}RUNNING${reset} | ${domain:-?}:443 → internal :${port:-?}"
    else
        echo "${red}STOPPED${reset}"
    fi
}

# ── Генерация конфига Xray ────────────────────────────────────────

writeVisionConfig() {
    local uuid="$1"
    local port="$2"
    local domain="$3"
    # nginx WS внутренний порт — fallback идёт туда же
    local nginx_port
    nginx_port=$(vwn_conf_get NGINX_HTTPS_PORT 2>/dev/null || echo "7443")

    mkdir -p "$(dirname "$visionConfigPath")"

    cat > "$visionConfigPath" << EOF
{
    "log": {
        "loglevel": "error",
        "error": "/var/log/xray/vision-error.log"
    },
    "inbounds": [{
        "listen": "127.0.0.1",
        "port": ${port},
        "protocol": "vless",
        "settings": {
            "clients": [{"id": "${uuid}", "flow": "xtls-rprx-vision"}],
            "decryption": "none",
            "fallbacks": [
                {"alpn": "h2",        "dest": ${nginx_port}, "xver": 1},
                {"dest": ${nginx_port}, "xver": 1}
            ]
        },
        "streamSettings": {
            "network": "tcp",
            "security": "tls",
            "tlsSettings": {
                "rejectUnknownSni": true,
                "minVersion": "1.2",
                "alpn": ["h2", "http/1.1"],
                "certificates": [{
                    "certificateFile": "${VISION_CERT_PEM}",
                    "keyFile": "${VISION_CERT_KEY}"
                }]
            }
        },
        "sniffing": {
            "enabled": true,
            "destOverride": ["http", "tls"],
            "routeOnly": true
        }
    }],
    "outbounds": [
        {"tag": "direct", "protocol": "freedom"},
        {"tag": "block",  "protocol": "blackhole"}
    ],
    "routing": {
        "domainStrategy": "AsIs",
        "rules": [
            {"type": "field", "ip": ["geoip:private"], "outboundTag": "block"}
        ]
    }
}
EOF

    # Права для пользователя xray
    chown xray:xray "$visionConfigPath" 2>/dev/null || true
    chmod 640 "$visionConfigPath" 2>/dev/null || true
    echo "${green}Vision config written: $visionConfigPath${reset}"
}

# ── Systemd сервис ────────────────────────────────────────────────

setupVisionService() {
    cat > "$VISION_SERVICE" << 'EOF'
[Unit]
Description=Xray Vision (VLESS+TLS+Vision)
After=network.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
User=xray
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/vision.json
Restart=on-failure
RestartSec=5s
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
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

# ── SSL сертификат ────────────────────────────────────────────────
# По аналогии с configCert из nginx.sh, но для vision домена.
# Сохраняет в /etc/nginx/cert/vision.pem + vision.key

_getVisionCert() {
    local domain="$1"
    local method="$2"   # cf | standalone

    mkdir -p /etc/nginx/cert

    # Убеждаемся что acme.sh установлен
    if [ ! -f /root/.acme.sh/acme.sh ]; then
        echo -e "${cyan}Installing acme.sh...${reset}"
        curl -fsSL https://get.acme.sh | sh -s email=admin@"$domain" 2>/dev/null || {
            echo "${red}Failed to install acme.sh${reset}"; return 1
        }
    fi

    local acme="/root/.acme.sh/acme.sh"

    if [ "$method" = "cf" ]; then
        # Cloudflare DNS метод
        local cf_email cf_key
        cf_email=$(grep "^CF_Email=" "$cf_key_file" 2>/dev/null | cut -d= -f2-)
        cf_key=$(grep "^CF_Key=" "$cf_key_file" 2>/dev/null | cut -d= -f2-)
        if [ -z "$cf_email" ] || [ -z "$cf_key" ]; then
            echo "${red}Cloudflare credentials not found. Run WS SSL setup first or set CF keys.${reset}"
            return 1
        fi
        export CF_Email="$cf_email"
        export CF_Key="$cf_key"
        echo -e "${cyan}Issuing Vision SSL via Cloudflare DNS for $domain ...${reset}"
        "$acme" --issue --dns dns_cf -d "$domain" \
            --key-file   "$VISION_CERT_KEY" \
            --cert-file  "$VISION_CERT_PEM" \
            --reloadcmd  "systemctl reload nginx 2>/dev/null || true; systemctl restart xray-vision 2>/dev/null || true" \
            --force 2>/dev/null || {
            echo "${red}$(msg vision_cert_fail)${reset}"; return 1
        }
    else
        # Standalone HTTP-01
        echo -e "${cyan}$(msg vision_cert_method): standalone${reset}"
        # Временно открываем порт 80
        ufw allow 80/tcp &>/dev/null || true
        # Останавливаем nginx если слушает 80
        local nginx_was_running=false
        systemctl is-active --quiet nginx 2>/dev/null && nginx_was_running=true
        $nginx_was_running && systemctl stop nginx

        echo -e "${cyan}Issuing Vision SSL via HTTP-01 for $domain ...${reset}"
        "$acme" --issue --standalone -d "$domain" \
            --key-file   "$VISION_CERT_KEY" \
            --cert-file  "$VISION_CERT_PEM" \
            --reloadcmd  "systemctl reload nginx 2>/dev/null || true; systemctl restart xray-vision 2>/dev/null || true" \
            --force 2>/dev/null
        local acme_exit=$?

        $nginx_was_running && systemctl start nginx
        ufw delete allow 80/tcp &>/dev/null || true

        [ $acme_exit -ne 0 ] && { echo "${red}$(msg vision_cert_fail)${reset}"; return 1; }
    fi

    # Права на сертификат для xray
    chown xray:xray "$VISION_CERT_PEM" "$VISION_CERT_KEY" 2>/dev/null || true
    chmod 640 "$VISION_CERT_PEM" "$VISION_CERT_KEY" 2>/dev/null || true
    echo "${green}$(msg vision_cert_ok)${reset}"
}

# ── Применение активных фич к vision конфигу ─────────────────────
# Вызывается после writeVisionConfig чтобы подхватить WARP/Relay/etc.

_visionApplyActiveFeatures() {
    echo -e "${cyan}$(msg vision_apply_features)${reset}"

    # WARP
    if [ -f "$warpDomainsFile" ] && command -v warp-cli &>/dev/null; then
        local warp_raw
        warp_raw=$(getWarpStatusRaw 2>/dev/null || echo "OFF")
        if [ "$warp_raw" = "ACTIVE" ]; then
            applyWarpDomains 2>/dev/null || true
        fi
    fi

    # Relay
    if [ -f "$relayConfigFile" ]; then
        applyRelayToConfigs 2>/dev/null || true
        applyRelayDomains 2>/dev/null || true
    fi

    # Psiphon
    if [ -f "$psiphonConfigFile" ] && [ -f "$psiphonDomainsFile" ]; then
        applyPsiphonDomains 2>/dev/null || true
    fi

    # Tor
    if command -v tor &>/dev/null && [ -f "$torDomainsFile" ]; then
        applyTorDomains 2>/dev/null || true
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

    clear
    echo -e "${cyan}================================================================${reset}"
    echo -e "   $(msg vision_title)"
    echo -e "${cyan}================================================================${reset}"
    echo ""

    # 1. WS+TLS должен быть установлен
    if [ ! -f "$configPath" ] || ! command -v nginx &>/dev/null; then
        echo "${red}$(msg vision_ws_required)${reset}"
        return 1
    fi
    if [ ! -f /etc/nginx/cert/cert.pem ]; then
        echo "${red}$(msg vision_ws_required) (SSL missing)${reset}"
        return 1
    fi

    # 2. Stream SNI должен быть активен
    if ! grep -q "ssl_preread on" /etc/nginx/nginx.conf 2>/dev/null; then
        echo "${yellow}$(msg vision_stream_required)${reset}"
        if $auto_mode; then
            echo -e "${cyan}Auto-activating Stream SNI...${reset}"
            setupStreamSNI 7443 10443 || { echo "${red}Stream SNI failed.${reset}"; return 1; }
        else
            echo -e "${yellow}$(msg vision_stream_activate) $(msg yes_no)${reset}"
            read -r _sni_ans
            if [[ "$_sni_ans" == "y" ]]; then
                setupStreamSNI 7443 10443 || { echo "${red}Stream SNI activation failed.${reset}"; return 1; }
            else
                echo "${red}$(msg cancel)${reset}"
                return 1
            fi
        fi
    fi

    # 3. Домен для Vision
    local vision_domain
    if $auto_mode && [ -n "${VISION_AUTO_DOMAIN:-}" ]; then
        vision_domain="$VISION_AUTO_DOMAIN"
    else
        echo -e "${yellow}$(msg vision_domain_note)${reset}"
        echo ""
        while true; do
            read -rp "$(msg vision_domain_prompt)" vision_domain
            vision_domain=$(echo "$vision_domain" | tr -d ' ')
            [ -z "$vision_domain" ] && { echo "${red}$(msg invalid)${reset}"; continue; }
            break
        done
    fi

    # 4. Метод SSL
    local cert_method
    if $auto_mode && [ -n "${VISION_AUTO_CERT_METHOD:-}" ]; then
        cert_method="$VISION_AUTO_CERT_METHOD"
    else
        echo ""
        echo -e "${cyan}$(msg vision_cert_method)${reset}"
        echo -e "${green}1.${reset} $(msg ssl_method_1)"
        echo -e "${green}2.${reset} $(msg ssl_method_2)"
        read -rp "$(msg ssl_your_choice)" _cert_choice
        case "${_cert_choice:-2}" in
            1) cert_method="cf" ;;
            *) cert_method="standalone" ;;
        esac
    fi

    # При CF методе — нужны ключи, проверяем/запрашиваем
    if [ "$cert_method" = "cf" ]; then
        local cf_email cf_key
        cf_email=$(grep "^CF_Email=" "$cf_key_file" 2>/dev/null | cut -d= -f2-)
        cf_key=$(grep "^CF_Key=" "$cf_key_file" 2>/dev/null | cut -d= -f2-)
        if [ -z "$cf_email" ] || [ -z "$cf_key" ]; then
            if $auto_mode; then
                cf_email="${VISION_AUTO_CF_EMAIL:-}"
                cf_key="${VISION_AUTO_CF_KEY:-}"
            else
                read -rp "$(msg ssl_cf_email)" cf_email
                read -rp "$(msg ssl_cf_key)" cf_key
            fi
            if [ -n "$cf_email" ] && [ -n "$cf_key" ]; then
                mkdir -p "$(dirname "$cf_key_file")"
                { echo "CF_Email=${cf_email}"; echo "CF_Key=${cf_key}"; } > "$cf_key_file"
                chmod 600 "$cf_key_file"
            fi
        fi
    fi

    # 5. Находим свободный порт
    echo ""
    echo -e "${cyan}$(msg vision_installing)${reset}"
    local vision_port
    vision_port=$(findFreePort 20000 20999) || {
        echo "${red}$(msg vision_no_free_port)${reset}"
        return 1
    }
    echo -e "  Internal port: ${green}${vision_port}${reset}"

    # 6. UUID
    local uuid
    uuid=$(xray uuid 2>/dev/null || python3 -c "import uuid; print(uuid.uuid4())")

    # 7. SSL сертификат
    echo ""
    _getVisionCert "$vision_domain" "$cert_method" || return 1

    # 8. Конфиг Xray
    writeVisionConfig "$uuid" "$vision_port" "$vision_domain"

    # 9. Сервис
    setupVisionService || return 1

    # 10. Добавляем домен в stream map
    addDomainToStream "$vision_domain" "$vision_port"
    nginx -t && systemctl reload nginx || {
        echo "${red}$(msg nginx_syntax_err)${reset}"; return 1
    }

    # 11. Сохраняем мета-данные
    vwn_conf_set VISION_DOMAIN    "$vision_domain"
    vwn_conf_set VISION_UUID      "$uuid"
    vwn_conf_set vision_port      "$vision_port"

    # 12. Применяем активные фичи (WARP, Relay, Adblock, Privacy...)
    _visionApplyActiveFeatures

    # 13. Итог
    echo ""
    echo -e "${green}================================================================${reset}"
    echo -e "   $(msg vision_installed)"
    echo -e "${green}================================================================${reset}"
    showVisionInfo
    showVisionQR
}

# ── Информация и QR ───────────────────────────────────────────────

showVisionInfo() {
    if [ ! -f "$visionConfigPath" ]; then
        echo "${red}$(msg vision_not_installed)${reset}"
        return
    fi

    local domain uuid port server_ip
    domain=$(vwn_conf_get VISION_DOMAIN 2>/dev/null || true)
    uuid=$(vwn_conf_get VISION_UUID 2>/dev/null || \
        jq -r '.inbounds[0].settings.clients[0].id // ""' "$visionConfigPath" 2>/dev/null)
    port=$(vwn_conf_get vision_port 2>/dev/null || \
        jq -r '.inbounds[0].port // ""' "$visionConfigPath" 2>/dev/null)
    server_ip=$(getServerIP)

    echo ""
    echo -e "${cyan}━━━ $(msg vision_qr_title) ━━━${reset}"
    echo ""
    echo -e "  ${cyan}$(msg lbl_domain):${reset}  ${green}${domain:-?}${reset}"
    echo -e "  ${cyan}UUID:${reset}    ${green}${uuid:-?}${reset}"
    echo -e "  ${cyan}$(msg lbl_port):${reset}   ${green}443${reset} (external, stream SNI)"
    echo -e "  ${cyan}Internal:${reset} 127.0.0.1:${port:-?}"
    echo -e "  ${cyan}Server IP:${reset} ${server_ip}"
    echo -e "  ${cyan}Flow:${reset}    xtls-rprx-vision"
    echo -e "  ${cyan}TLS:${reset}     TLSv1.2 / TLSv1.3"
    echo -e "  ${cyan}Network:${reset} tcp"
    echo -e "  ${cyan}Fallback:${reset} $(msg vision_fallback_info)"
    echo ""
}

showVisionQR() {
    if [ ! -f "$visionConfigPath" ]; then
        echo "${red}$(msg vision_not_installed)${reset}"
        return
    fi

    local domain uuid
    domain=$(vwn_conf_get VISION_DOMAIN 2>/dev/null || true)
    uuid=$(vwn_conf_get VISION_UUID 2>/dev/null || \
        jq -r '.inbounds[0].settings.clients[0].id // ""' "$visionConfigPath" 2>/dev/null)

    [ -z "$domain" ] || [ -z "$uuid" ] && {
        echo "${red}$(msg vision_not_installed)${reset}"; return
    }

    # vless://UUID@domain:443?security=tls&flow=xtls-rprx-vision&type=tcp&sni=domain#Vision
    local link
    link="vless://${uuid}@${domain}:443?security=tls&flow=xtls-rprx-vision&type=tcp&sni=${domain}&fp=chrome&allowInsecure=0#Vision-${domain}"

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

modifyVisionDomain() {
    if [ ! -f "$visionConfigPath" ]; then
        echo "${red}$(msg vision_not_installed)${reset}"; return
    fi

    local old_domain new_domain
    old_domain=$(vwn_conf_get VISION_DOMAIN 2>/dev/null || true)

    echo -e "${yellow}$(msg vision_domain_note)${reset}"
    read -rp "$(msg vision_domain_prompt)" new_domain
    new_domain=$(echo "$new_domain" | tr -d ' ')
    [ -z "$new_domain" ] && { echo "${red}$(msg invalid)${reset}"; return; }

    # Метод SSL
    echo -e "${cyan}$(msg vision_cert_method)${reset}"
    echo -e "${green}1.${reset} $(msg ssl_method_1)"
    echo -e "${green}2.${reset} $(msg ssl_method_2)"
    read -rp "$(msg ssl_your_choice)" _cert_choice
    local cert_method
    case "${_cert_choice:-2}" in
        1) cert_method="cf" ;;
        *) cert_method="standalone" ;;
    esac

    # Новый сертификат
    _getVisionCert "$new_domain" "$cert_method" || return 1

    # Убираем старый домен из stream map
    [ -n "$old_domain" ] && removeDomainFromStream "$old_domain"

    # Добавляем новый
    local vision_port
    vision_port=$(vwn_conf_get vision_port 2>/dev/null || \
        jq -r '.inbounds[0].port // "20001"' "$visionConfigPath" 2>/dev/null)
    addDomainToStream "$new_domain" "$vision_port"

    vwn_conf_set VISION_DOMAIN "$new_domain"

    nginx -t && systemctl reload nginx
    systemctl restart xray-vision 2>/dev/null || true

    echo "${green}$(msg vision_domain_changed): ${new_domain}${reset}"
}

# ── Удаление ──────────────────────────────────────────────────────

removeVision() {
    echo -e "${red}$(msg vision_remove_confirm) $(msg yes_no)${reset}"
    read -r confirm
    [[ "$confirm" != "y" ]] && { echo "$(msg cancel)"; return; }

    echo -e "${cyan}Removing Vision...${reset}"

    # Убираем домен из stream map
    local vision_domain
    vision_domain=$(vwn_conf_get VISION_DOMAIN 2>/dev/null || true)
    [ -n "$vision_domain" ] && removeDomainFromStream "$vision_domain"

    # Останавливаем и удаляем сервис
    systemctl stop xray-vision 2>/dev/null || true
    systemctl disable xray-vision 2>/dev/null || true
    rm -f "$VISION_SERVICE"
    systemctl daemon-reload

    # Удаляем конфиг и сертификаты
    rm -f "$visionConfigPath" "$VISION_CERT_PEM" "$VISION_CERT_KEY"

    # Удаляем acme.sh домен
    if [ -f /root/.acme.sh/acme.sh ] && [ -n "$vision_domain" ]; then
        /root/.acme.sh/acme.sh --remove -d "$vision_domain" &>/dev/null || true
    fi

    # Чистим vwn.conf
    vwn_conf_del VISION_DOMAIN
    vwn_conf_del VISION_UUID
    vwn_conf_del vision_port

    # Перезагружаем nginx
    nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || true

    echo "${green}$(msg vision_removed)${reset}"
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
            local _dom _uuid _port
            _dom=$(vwn_conf_get VISION_DOMAIN 2>/dev/null || true)
            _uuid=$(vwn_conf_get VISION_UUID 2>/dev/null || true)
            _port=$(vwn_conf_get vision_port 2>/dev/null || true)
            echo -e "  $(msg lbl_domain): ${green}${_dom:-?}${reset}"
            echo -e "  UUID:   ${green}${_uuid:-?}${reset}"
            echo -e "  $(msg lbl_port):   443 → internal ${_port:-?}"
        fi
        echo -e "${cyan}----------------------------------------------------------------${reset}"
        echo ""
        echo -e "${green}1.${reset} $(msg vision_install)"
        echo -e "${green}2.${reset} $(msg vision_info)"
        echo -e "${green}3.${reset} $(msg vision_qr)"
        echo -e "${green}4.${reset} $(msg vision_modify_uuid)"
        echo -e "${green}5.${reset} $(msg vision_modify_domain)"
        echo -e "${green}6.${reset} $(msg vision_remove)"
        echo -e "${green}0.${reset} $(msg back)"
        echo ""
        read -rp "$(msg choose)" choice
        case $choice in
            1) installVision ;;
            2) showVisionInfo ;;
            3) showVisionQR ;;
            4) modifyVisionUUID ;;
            5) modifyVisionDomain ;;
            6) removeVision ;;
            0) break ;;
        esac
        [ "$choice" = "0" ] && continue
        echo -e "\n${cyan}$(msg press_enter)${reset}"
        read -r
    done
}
