#!/bin/bash
# =================================================================
# menu.sh — Главное меню и функция установки
# =================================================================

prepareSoftware() {
    identifyOS
    echo "--- [1/3] $(msg install_deps) ---"
    run_task "Swap-файл"        setupSwap
    run_task "Чистка пакетов"   "rm -f /var/lib/dpkg/lock* && dpkg --configure -a 2>/dev/null || true"
    run_task "Обновление репозиториев" "$PACKAGE_MANAGEMENT_UPDATE"

    echo "--- [2/3] $(msg install_deps) ---"
    for p in tar gpg unzip jq nano ufw socat curl qrencode python3; do
        run_task "Установка $p" "installPackage '$p'" || true
    done
    run_task "Установка Xray-core"       installXray
    run_task "Установка Cloudflare WARP" installWarp
}

_installNginxMainline() {
    # Нам нужен nginx >= 1.19.4 для grpc_buffering и >= 1.15.6 для grpc_socket_keepalive
    # Системный nginx на Ubuntu 20.04 = 1.18.0 — не подходит
    # Устанавливаем из официального репозитория nginx.org (mainline)
    local cur_ver
    cur_ver=$(nginx -v 2>&1 | grep -oP '\d+\.\d+\.\d+' | head -1)
    local cur_minor
    cur_minor=$(echo "$cur_ver" | cut -d. -f2)

    # Если уже >= 1.19 — достаточно
    if [ -n "$cur_ver" ] && [ "${cur_minor:-0}" -ge 19 ]; then
        echo "info: nginx $cur_ver already sufficient (>= 1.19.4), skipping."
        return 0
    fi

    echo -e "${cyan}nginx $cur_ver too old, installing mainline from nginx.org...${reset}"

    if command -v apt &>/dev/null; then
        # Добавляем официальный nginx репо
        installPackage gnupg2 || true
        curl -fsSL https://nginx.org/keys/nginx_signing.key \
            | gpg --dearmor -o /usr/share/keyrings/nginx-archive-keyring.gpg 2>/dev/null
        local codename
        codename=$(lsb_release -cs 2>/dev/null || . /etc/os-release && echo "$VERSION_CODENAME")
        echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] \
http://nginx.org/packages/mainline/ubuntu ${codename} nginx" \
            > /etc/apt/sources.list.d/nginx-mainline.list
        # Pinning — предпочитаем nginx.org над системным
        printf 'Package: *\nPin: origin nginx.org\nPin-Priority: 900\n' \
            > /etc/apt/preferences.d/99nginx
        apt-get update -qq 2>/dev/null
        # Удаляем старый nginx если есть
        apt-get remove -y nginx nginx-common nginx-core 2>/dev/null || true
        apt-get install -y nginx
    elif command -v dnf &>/dev/null || command -v yum &>/dev/null; then
        cat > /etc/yum.repos.d/nginx-mainline.repo << 'YUMEOF'
[nginx-mainline]
name=nginx mainline repo
baseurl=http://nginx.org/packages/mainline/centos/$releasever/$basearch/
gpgcheck=1
enabled=1
gpgkey=https://nginx.org/keys/nginx_signing.key
module_hotfixes=true
YUMEOF
        ${PACKAGE_MANAGEMENT_INSTALL} nginx
    fi

    local new_ver
    new_ver=$(nginx -v 2>&1 | grep -oP '\d+\.\d+\.\d+' | head -1)
    echo "${green}nginx installed: $new_ver${reset}"
}

prepareSoftwareWs() {
    prepareSoftware
    run_task "Установка Nginx (mainline)" _installNginxMainline

    echo "--- [3/3] $(msg menu_sep_sec) ---"
    run_task "Настройка UFW" "ufw allow 22/tcp && ufw allow 443/tcp && echo 'y' | ufw enable"
    run_task "Системные параметры" applySysctl
}


installRealityOnly() {
    isRoot
    clear
    identifyOS
    echo "${green}$(msg install_type_reality_title)${reset}"
    installReality
}

installWsTls() {
    isRoot
    clear
    identifyOS
    echo "${green}$(msg install_type_ws_title)${reset}"
    prepareSoftwareWs

    echo -e "\n${green}--- $(msg install_version) ---${reset}"

    # Домен
    local userDomain validated_domain
    while true; do
        read -rp "$(msg enter_domain_vpn)" userDomain
        userDomain=$(echo "$userDomain" | tr -d ' ')
        if [ -z "$userDomain" ]; then
            echo "${red}$(msg domain_required)${reset}"; continue
        fi
        if ! validated_domain=$(_validateDomain "$userDomain"); then
            echo "${red}$(msg invalid): '$userDomain' — $(msg enter_domain)${reset}"; continue
        fi
        userDomain="$validated_domain"
        break
    done

    # Порт Xray
    local xrayPort
    while true; do
        read -rp "$(msg enter_xray_port)" xrayPort
        [ -z "$xrayPort" ] && xrayPort=16500
        if ! _validatePort "$xrayPort" &>/dev/null; then
            echo "${red}$(msg invalid_port) (1024-65535)${reset}"; continue
        fi
        break
    done

    local wsBasePath
    wsBasePath=$(generateRandomPath)
    wsBasePath="${wsBasePath#/}"  # без leading slash

    # URL заглушки
    local proxyUrl validated_url
    while true; do
        read -rp "$(msg enter_stub_url)" proxyUrl
        [ -z "$proxyUrl" ] && proxyUrl='https://httpbin.org/'
        if ! validated_url=$(_validateUrl "$proxyUrl"); then
            echo "${red}$(msg invalid) URL — https:// $(msg enter_stub_url)${reset}"; continue
        fi
        proxyUrl="$validated_url"
        break
    done

    local grpcService="${wsBasePath}g"
    local grpcPort=$(( xrayPort + 1 ))

    # Спрашиваем про Reality
    local install_reality=false
    local realityDest=""
    local realityPort=8443
    echo ""
    echo -e "${cyan}$(msg install_reality_prompt)${reset}"
    echo -e "${green}1.${reset} $(msg install_reality_yes)"
    echo -e "${green}2.${reset} $(msg install_reality_no)"
    read -rp "$(msg choose)" reality_choice
    if [ "${reality_choice:-1}" = "1" ]; then
        install_reality=true
        echo -e "${cyan}$(msg reality_dest_title)${reset}"
        echo "1) microsoft.com:443"
        echo "2) www.apple.com:443"
        echo "3) www.amazon.com:443"
        echo "$(msg reality_dest_custom)"
        read -rp "Выбор [1]: " dest_choice
        case "${dest_choice:-1}" in
            1) realityDest="microsoft.com:443" ;;
            2) realityDest="www.apple.com:443" ;;
            3) realityDest="www.amazon.com:443" ;;
            4) read -rp "$(msg reality_dest_prompt)" realityDest
               [ -z "$realityDest" ] && realityDest="microsoft.com:443" ;;
            *) realityDest="microsoft.com:443" ;;
        esac
        read -rp "$(msg reality_port_prompt)" realityPort
        [ -z "$realityPort" ] && realityPort=8443
        if ! [[ "$realityPort" =~ ^[0-9]+$ ]] || [ "$realityPort" -lt 1024 ] || [ "$realityPort" -gt 65535 ]; then
            echo "${yellow}$(msg invalid_port) — использую 8443${reset}"
            realityPort=8443
        fi
    fi

    vwn_conf_set STUB_URL "$proxyUrl"

    echo -e "\n${green}---${reset}"
    run_task "Создание конфига Xray"       "writeXrayConfig '$xrayPort' '$wsBasePath' '$userDomain'"
    run_task "Настройка WARP"              configWarp
    run_task "Выпуск SSL"                  "userDomain='$userDomain' configCert"
    run_task "Создание конфига Nginx"      "writeNginxConfig '$userDomain' '$proxyUrl' '$xrayPort' '$grpcPort' '$wsBasePath' '$grpcService'"
    run_task "Восстановление реального IP" setupRealIpRestore
    run_task "Применение правил WARP"      applyWarpDomains
    run_task "Ротация логов"               setupLogrotate
    run_task "Автоочистка логов"           setupLogClearCron
    run_task "Автообновление SSL"          setupSslCron
    run_task "WARP Watchdog"               setupWarpWatchdog

    systemctl enable --now nginx
    systemctl restart nginx
    systemctl enable --now xray
    systemctl restart xray

    # Устанавливаем Reality если выбрано
    if $install_reality; then
        echo -e "\n${cyan}--- Reality ---${reset}"
        # Открываем UFW порт ДО запуска сервиса
        ufw allow "$realityPort"/tcp comment 'Xray Reality' 2>/dev/null || true
        REALITY_INTERNAL_PORT=$realityPort
        run_task "Конфиг Reality"   "writeRealityConfig '$realityDest'"
        run_task "Сервис Reality"   setupRealityService
        [ -f "$warpDomainsFile" ] && applyWarpDomains
        [ -f "$relayConfigFile" ]  && applyRelayDomains
    fi

    echo -e "\n${green}$(msg install_complete)${reset}"
    _initUsersFile
    showUserQR
}

install() {
    isRoot
    clear
    echo -e "${cyan}================================================================${reset}"
    echo -e "   $(msg install_type_title)"
    echo -e "${cyan}================================================================${reset}"
    echo ""
    echo -e "\t${green}$(msg install_type_1)${reset}"
    echo -e "\t${green}$(msg install_type_2)${reset}"
    echo ""
    read -rp "$(msg choose)" install_type_choice
    case "${install_type_choice:-1}" in
        1) installWsTls ;;
        2) installRealityOnly ;;
        *) echo "${red}$(msg invalid)${reset}"; return 1 ;;
    esac
}


fullRemove() {
    echo -e "${red}$(msg remove_confirm) $(msg yes_no)${reset}"
    read -r confirm
    if [[ "$confirm" == "y" ]]; then
        systemctl stop nginx xray xray-reality warp-svc psiphon tor 2>/dev/null || true
        warp-cli disconnect 2>/dev/null || true
        [ -z "${PACKAGE_MANAGEMENT_REMOVE:-}" ] && identifyOS
        uninstallPackage 'nginx*' || true
        uninstallPackage 'cloudflare-warp' || true
        bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove || true
        systemctl disable xray-reality psiphon 2>/dev/null || true
        rm -f /etc/systemd/system/xray-reality.service
        rm -f /etc/systemd/system/psiphon.service
        rm -f "$torDomainsFile"
        rm -f "$psiphonBin"
        rm -rf /etc/nginx /usr/local/etc/xray /root/.cloudflare_api \
               /var/lib/psiphon /var/log/psiphon \
               /etc/cron.d/acme-renew /etc/cron.d/clear-logs /etc/cron.d/warp-watchdog \
               /usr/local/bin/warp-watchdog.sh /usr/local/bin/clear-logs.sh \
               /etc/sysctl.d/99-xray.conf
        systemctl daemon-reload
        echo "${green}$(msg remove_done)${reset}"
    fi
}

removeWs() {
    echo -e "${red}$(msg remove_confirm) $(msg yes_no)${reset}"
    read -r confirm
    [[ "$confirm" != "y" ]] && return 0
    systemctl stop nginx xray 2>/dev/null || true
    systemctl disable nginx xray 2>/dev/null || true
    [ -z "${PACKAGE_MANAGEMENT_REMOVE:-}" ] && identifyOS
    uninstallPackage 'nginx*' || true
    bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove || true
    rm -rf /etc/nginx /usr/local/etc/xray/config.json \
           /usr/local/etc/xray/sub /usr/local/etc/xray/users.conf \
           /etc/cron.d/acme-renew /etc/cron.d/clear-logs \
           /usr/local/bin/clear-logs.sh /etc/sysctl.d/99-xray.conf
    systemctl daemon-reload
    echo "${green}$(msg remove_done)${reset}"
}

_portSt() {
    local port="$1"
    if ss -tlnp 2>/dev/null | grep -q ":${port}"; then
        echo -e "${green}● LISTEN${reset}"
    else
        echo -e "${red}○ DOWN  ${reset}"
    fi
}

manageWs() {
    set +e
    while true; do
        clear
        local s_nginx s_ws s_ssl s_domain s_connect s_warp
        local s_xhttp_port s_grpc_port
        local s_xhttp_path s_grpc_svc

        s_nginx=$(getServiceStatus nginx)
        s_ws=$(getServiceStatus xray)
        s_ssl=$(checkCertExpiry)
        s_warp=$(getWarpStatus)

        s_domain=$(get_domain)
        s_connect=$(cat "$CONNECT_HOST_FILE" 2>/dev/null | tr -d '[:space:]')
        [ ${#s_connect} -gt 40 ] && s_connect="${s_connect:0:37}..."
        [ ${#s_domain}  -gt 35 ] && s_domain="${s_domain:0:32}..."

        if [ -f "$configPath" ]; then
            s_xhttp_port=$(jq -r '.inbounds[] | select(.tag=="xhttp-inbound") | .port' "$configPath" 2>/dev/null | head -1)
            s_grpc_port=$(jq -r '.inbounds[] | select(.tag=="grpc-inbound") | .port' "$configPath" 2>/dev/null | head -1)
        fi
        s_xhttp_path=$(get_xhttp_path)
        s_grpc_svc=$(get_grpc_service)

        echo -e "${cyan}================================================================${reset}"
        printf "   ${red}$(msg menu_ws_title)${reset}  %s\n" "$(date +'%d.%m.%Y %H:%M')"
        echo -e "${cyan}================================================================${reset}"
        echo -e "  Nginx: $s_nginx,  SSL: $s_ssl"
        echo -e "  WARP:  $s_warp"
        [ -n "$s_connect" ] && echo -e "  CDN:   ${green}${s_connect}${reset}"
        echo -e "${cyan}----------------------------------------------------------------${reset}"
        if [ -f "$configPath" ]; then
            local s_ws_c
            s_ws_c=$(_pval "$s_ws" 7)
            echo -e "  XHTTP: $s_ws_c $(_portSt "$s_xhttp_port") ${green}${s_xhttp_path:-—}${reset}  :${s_xhttp_port:-—}"
            echo -e "  gRPC:  $s_ws_c $(_portSt "$s_grpc_port") ${green}${s_grpc_svc:-—}${reset}  :${s_grpc_port:-—}"
            echo -e "  $(msg lbl_domain): ${green}${s_domain}${reset}"
        else
            echo -e "  XHTTP: ${red}NOT INSTALLED${reset}"
            echo -e "  gRPC:  ${red}NOT INSTALLED${reset}"
        fi
        echo -e "${cyan}================================================================${reset}"
        echo -e "  ${cyan}$(msg menu_sep_config)${reset}"
        echo -e "  ${green}1.${reset}  $(msg menu_port)"
        echo -e "  ${green}2.${reset}  $(msg menu_wspath)"
        echo -e "  ${green}3.${reset}  $(msg menu_domain)"
        echo -e "  ${green}4.${reset}  $(msg menu_cdn_host)"
        echo -e "  ${green}5.${reset}  $(msg menu_stub)"
        echo -e "  ${green}6.${reset}  $(msg menu_uuid)"
        echo -e "  ${cyan}$(msg menu_sep_sec)${reset}"
        echo -e "  ${green}7.${reset}  $(msg menu_ssl)"
        echo -e "  ${green}8.${reset}  $(msg menu_ssl_cron)"
        echo -e "  ${cyan}$(msg menu_sep_logs)${reset}"
        echo -e "  ${green}9.${reset}  $(msg menu_log_cron)"
        echo -e "  ${green}10.${reset} $(msg menu_xray_acc)"
        echo -e "  ${green}11.${reset} $(msg menu_xray_err)"
        echo -e "  ${green}12.${reset} $(msg menu_nginx_acc)"
        echo -e "  ${green}13.${reset} $(msg menu_nginx_err)"
        echo -e "  ${cyan}$(msg menu_sep_svc)${reset}"
        echo -e "  ${green}14.${reset} $(msg menu_restart)"
        echo -e "  ${green}15.${reset} $(msg menu_install)"
        echo -e "  ${green}16.${reset} $(msg menu_remove)"
        echo -e "${cyan}----------------------------------------------------------------${reset}"
        echo -e "  ${green}0.${reset}  $(msg back)"
        echo -e "${cyan}================================================================${reset}"
        read -rp "$(msg choose)" choice
        case $choice in
            1)  modifyXrayPort ;;
            2)  modifyPaths ;;
            3)  modifyDomain ;;
            4)  modifyConnectHost ;;
            5)  modifyProxyPassUrl ;;
            6)  modifyXrayUUID ;;
            7)  getConfigInfo && userDomain="$xray_userDomain" && configCert ;;
            8)  manageSslCron ;;
            9)  manageLogClearCron ;;
            10) view_log "/var/log/xray/access.log" "xray" ;;
            11) view_log "/var/log/xray/error.log" "xray" ;;
            12) view_log "/var/log/nginx/access.log" "nginx" ;;
            13) view_log "/var/log/nginx/error.log" "nginx" ;;
            14) systemctl restart nginx && systemctl restart xray && echo "${green}$(msg restarted)${reset}" ;;
            15) install ;;
            16) removeWs ;;
            0)  break ;;
        esac
        [ "$choice" = "0" ] && continue
        echo -e "\n${cyan}$(msg press_enter)${reset}"
        read -r
    done
}

menu() {
    set +e
    clear
    while true; do
        local s_nginx s_ws s_reality s_warp s_ssl s_bbr s_f2b s_jail s_relay s_psiphon s_tor s_connect
        clear
        s_nginx=$(getServiceStatus nginx)
        s_ws=$(getServiceStatus xray)
        s_reality=$(getServiceStatus xray-reality)
        s_warp=$(getWarpStatus)
        s_ssl=$(checkCertExpiry)
        s_bbr=$(getBbrStatus)
        s_f2b=$(getF2BStatus)
        s_jail=$(getWebJailStatus)
        s_relay=$(getRelayStatus)
        s_psiphon=$(getPsiphonStatus)
        s_tor=$(getTorStatus)
        s_connect=$(cat "$CONNECT_HOST_FILE" 2>/dev/null | tr -d '[:space:]')
        [ ${#s_connect} -gt 35 ] && s_connect="${s_connect:0:32}..."
        _strip() { printf '%s' "$1" | sed 's/\[[0-9;]*[mABCDJKHf]//g; s/(B//g'; }
        _pval() {
            local val="$1" w="$2" clean
            clean=$(_strip "$val")
            printf "%s%*s" "$val" $((w - ${#clean})) ""
        }
        s_ws_c=$(_pval "$s_ws" 7)
        s_reality_c=$(_pval "$s_reality" 7)
        s_nginx_c=$(_pval "$s_nginx" 7)

        echo -e "${cyan}================================================================${reset}"
        printf "   ${red}VWN — Xray Management Panel${reset}  %s\n" "$(date +'%d.%m.%Y %H:%M')"
        echo -e "${cyan}================================================================${reset}"
        echo -e "  ${cyan}── $(msg menu_sep_proto_short) ──────────────────────────────────────────${reset}"
        _pst() { [ -n "$1" ] && ss -tlnp 2>/dev/null | grep -q ":${1}" && echo "${green}●${reset}" || echo "${red}○${reset}"; }
        if [ -f "$configPath" ]; then
            local _xhttp_port _grpc_port
            _xhttp_port=$(jq -r '.inbounds[] | select(.tag=="xhttp-inbound") | .port' "$configPath" 2>/dev/null | head -1)
            _grpc_port=$(jq -r '.inbounds[] | select(.tag=="grpc-inbound") | .port' "$configPath" 2>/dev/null | head -1)
            echo -e "  XHTTP:  $s_ws_c $(_pst "$_xhttp_port") ${green}$(get_xhttp_path)${reset}  :${_xhttp_port}"
            echo -e "  gRPC:   $s_ws_c $(_pst "$_grpc_port") ${green}$(get_grpc_service)${reset}  :${_grpc_port}"
        else
            echo -e "  XHTTP:  ${red}NOT INSTALLED${reset}"
            echo -e "  gRPC:   ${red}NOT INSTALLED${reset}"
        fi
        if [ -f "$realityConfigPath" ]; then
            local _r_port _r_dest
            _r_port=$(jq -r '.inbounds[0].port' "$realityConfigPath" 2>/dev/null)
            _r_dest=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0] // "—"' "$realityConfigPath" 2>/dev/null)
            echo -e "  Reality: $s_reality_c $(_pst "$_r_port") ${green}${_r_dest}${reset}  :${_r_port}"
        else
            echo -e "  Reality: ${red}NOT INSTALLED${reset}"
        fi
        echo -e "  Nginx:  $s_nginx_c,  SSL: $s_ssl"
        echo -e "  WARP:   $s_warp"
        [ -n "$s_connect" ] && echo -e "  CDN:    ${green}${s_connect}${reset}"
        echo -e "  ${cyan}── $(msg menu_sep_tun_short) ───────────────────────────────────────────${reset}"
        echo -e "  Relay: $s_relay,  Psiphon: $s_psiphon,  Tor: $s_tor"
        echo -e "  ${cyan}── $(msg menu_sep_sec_short) ────────────────────────────────────────────${reset}"
        echo -e "  BBR: $s_bbr,  F2B: $s_f2b,  Jail: $s_jail,  IPv6: $(getIPv6Status)"
        echo -e "${cyan}----------------------------------------------------------------${reset}"

        echo -e "  ${green}1.${reset}  $(msg menu_install)"
        echo -e "  ${green}2.${reset}  $(msg menu_users)"
        echo -e "  $(msg menu_sep_proto)"
        echo -e "  ${green}3.${reset}  $(msg menu_ws)"
        echo -e "  ${green}4.${reset}  $(msg menu_reality)"
        echo -e "  $(msg menu_sep_tun)"
        echo -e "  ${green}5.${reset}  $(msg menu_relay)"
        echo -e "  ${green}6.${reset}  $(msg menu_psiphon)"
        echo -e "  ${green}7.${reset}  $(msg menu_tor)"
        echo -e "  $(msg menu_sep_warp)"
        echo -e "  ${green}8.${reset}  $(msg menu_warp_mode)"
        echo -e "  ${green}9.${reset}  $(msg menu_warp_add)"
        echo -e "  ${green}10.${reset} $(msg menu_warp_del)"
        echo -e "  ${green}11.${reset} $(msg menu_warp_edit)"
        echo -e "  ${green}12.${reset} $(msg menu_warp_check)"
        echo -e "  ${green}13.${reset} $(msg menu_watchdog)"
        echo -e "  $(msg menu_sep_sec)"
        echo -e "  ${green}14.${reset} $(msg menu_bbr)"
        echo -e "  ${green}15.${reset} $(msg menu_f2b)"
        echo -e "  ${green}16.${reset} $(msg menu_jail)"
        echo -e "  ${green}17.${reset} $(msg menu_ssh)"
        echo -e "  ${green}18.${reset} $(msg menu_ufw)"
        echo -e "  ${green}19.${reset} $(msg menu_ipv6)"
        echo -e "  $(msg menu_sep_logs)"
        echo -e "  ${green}20.${reset} $(msg menu_xray_acc)"
        echo -e "  ${green}21.${reset} $(msg menu_xray_err)"
        echo -e "  ${green}22.${reset} $(msg menu_nginx_acc)"
        echo -e "  ${green}23.${reset} $(msg menu_nginx_err)"
        echo -e "  ${green}24.${reset} $(msg menu_clear_logs)"
        echo -e "  $(msg menu_sep_svc)"
        echo -e "  ${green}25.${reset} $(msg menu_restart)"
        echo -e "  ${green}26.${reset} $(msg menu_update_xray)"
        echo -e "  ${green}27.${reset} $(msg menu_diag)"
        echo -e "  ${green}28.${reset} $(msg menu_backup)"
        echo -e "  ${green}29.${reset} $(msg menu_lang)"
        echo -e "  ${green}30.${reset} $(msg menu_remove)"
        echo -e "  $(msg menu_sep_exit)"
        echo -e "  ${green}0.${reset}  $(msg menu_exit)"
        echo -e "${cyan}----------------------------------------------------------------${reset}"

        read -rp "$(msg choose)" num
        case $num in
            1)  install ;;
            2)  manageUsers ;;
            3)  manageWs ;;
            4)  manageReality ;;
            5)  manageRelay ;;
            6)  managePsiphon ;;
            7)  manageTor ;;
            8)  toggleWarpMode ;;
            9)  addDomainToWarpProxy ;;
            10) deleteDomainFromWarpProxy ;;
            11) nano "$warpDomainsFile" && applyWarpDomains ;;
            12) checkWarpStatus ;;
            13) setupWarpWatchdog ;;
            14) enableBBR ;;
            15) setupFail2Ban ;;
            16) setupWebJail ;;
            17) changeSshPort ;;
            18) manageUFW ;;
            19) toggleIPv6 ;;
            20) view_log "/var/log/xray/access.log" "xray" ;;
            21) view_log "/var/log/xray/error.log" "xray" ;;
            22) view_log "/var/log/nginx/access.log" "nginx" ;;
            23) view_log "/var/log/nginx/error.log" "nginx" ;;
            24) clearLogs ;;
            25) systemctl restart nginx 2>/dev/null || true; systemctl restart xray xray-reality warp-svc psiphon tor 2>/dev/null || true
                echo "${green}$(msg all_services_restarted)${reset}" ;;
            26) updateXrayCore ;;
            27) manageDiag ;;
            28) manageBackup ;;
            29) selectLang; _initLang ;;
            30) fullRemove ;;
            0)  exit 0 ;;
            *)  echo -e "${red}$(msg invalid)${reset}"; sleep 1 ;;
        esac
        echo -e "\n${cyan}$(msg press_enter)${reset}"
        read -r
    done
}