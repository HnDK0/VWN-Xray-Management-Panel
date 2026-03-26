#!/bin/bash
# =================================================================
# menu.sh — Главное меню и функция установки
# =================================================================

prepareSoftware() {
    identifyOS
    echo "--- [1/3] $(msg install_deps) ---"
    run_task "Swap-файл"        setupSwap
    run_task "Чистка пакетов"   "if ! pgrep -x dpkg >/dev/null && ! pgrep -x apt >/dev/null; then rm -f /var/lib/dpkg/lock* && dpkg --configure -a 2>/dev/null || true; fi"
    run_task "Обновление репозиториев" "$PACKAGE_MANAGEMENT_UPDATE"

    echo "--- [2/3] $(msg install_deps) ---"
    for p in tar gpg unzip jq nano ufw socat curl qrencode python3; do
        run_task "Установка $p" "installPackage '$p'" || true
    done

    # Критическая задача — Xray
    run_task "Установка Xray-core" installXray
    if [ $? -ne 0 ]; then
        echo -e "${red}$(msg xray_install_fail)${reset}"
        read -rp "$(msg xray_install_retry)" retry
        if [[ "$retry" == "y" ]]; then
            run_task "$(msg xray_install_retry_title)" installXray || { echo "${red}$(msg xray_install_aborted)${reset}"; return 1; }
        else
            echo "${red}$(msg xray_install_aborted)${reset}"
            return 1
        fi
    fi

    run_task "Установка Cloudflare WARP" installWarp
}

_installNginxMainline() {
    local cur_ver cur_minor
    cur_ver=$(nginx -v 2>&1 | grep -oP '\d+\.\d+\.\d+' | head -1)
    cur_minor=$(echo "$cur_ver" | cut -d. -f2)
    if [ -n "$cur_ver" ] && [ "${cur_minor:-0}" -ge 19 ]; then
        echo "info: nginx $cur_ver already sufficient (>= 1.19), skipping."
        return 0
    fi
    echo -e "${cyan}nginx ${cur_ver:-not installed} — installing mainline from nginx.org...${reset}"
    if command -v apt &>/dev/null; then
        installPackage gnupg2 || true
        curl -fsSL https://nginx.org/keys/nginx_signing.key \
            | gpg --dearmor -o /usr/share/keyrings/nginx-archive-keyring.gpg 2>/dev/null
        local codename
        codename=$(lsb_release -cs 2>/dev/null || . /etc/os-release && echo "$VERSION_CODENAME")
        echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/mainline/ubuntu ${codename} nginx" \
            > /etc/apt/sources.list.d/nginx-mainline.list
        printf 'Package: *\nPin: origin nginx.org\nPin-Priority: 900\n' \
            > /etc/apt/preferences.d/99nginx
        apt-get update -qq 2>/dev/null
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
    prepareSoftware || return 1

    # Критическая задача — Nginx
    run_task "Установка Nginx (mainline)" _installNginxMainline
    if [ $? -ne 0 ]; then
        echo -e "${red}$(msg nginx_install_fail)${reset}"
        read -rp "$(msg nginx_install_retry)" retry
        if [[ "$retry" == "y" ]]; then
            run_task "$(msg nginx_install_retry_title)" _installNginxMainline || { echo "${red}$(msg nginx_install_aborted)${reset}"; return 1; }
        else
            echo "${red}$(msg nginx_install_aborted)${reset}"
            return 1
        fi
    fi

    echo "--- [3/3] $(msg menu_sep_sec) ---"
    run_task "Настройка UFW" "ufw allow 22/tcp && ufw allow 443/tcp && ufw allow 443/udp && echo 'y' | ufw enable"
    if [ $? -ne 0 ]; then
        echo -e "${red}$(msg ufw_not_configured)${reset}"
        read -rp "$(msg ufw_continue)" cont_ufw
        if [[ "$cont_ufw" != "y" ]]; then
            echo "${red}$(msg xray_install_aborted)${reset}"
            return 1
        fi
    fi
    run_task "Системные параметры" applySysctl || true
}

# Установка VLESS + WebSocket + TLS + Nginx + WARP + CDN
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

    local wsPath
    wsPath=$(generateRandomPath)

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

    # Спрашиваем про Reality
    local install_reality=false
    local realityDest="" realityPort=8443
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
        read -rp "$(msg prompt_choice)" dest_choice
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
            echo "${yellow}$(msg reality_port_fallback)${reset}"
            realityPort=8443
        fi
    fi

    echo -e "\n${green}---${reset}"
    run_task "Создание конфига Xray"   "writeXrayConfig '$xrayPort' '$wsPath' '$userDomain'"
    run_task "Создание конфига Nginx"  "writeNginxConfig '$xrayPort' '$userDomain' '$proxyUrl' '$wsPath'"

    # Запускаем nginx ДО выпуска SSL — acme.sh делает reload по окончании
    systemctl enable --now nginx
    systemctl start nginx 2>/dev/null || true

    run_task "Настройка WARP"          configWarp || true

    # Критическая задача — SSL
    run_task "Выпуск SSL" "userDomain='$userDomain' configCert"
    if [ $? -ne 0 ]; then
        echo -e "${red}$(msg ssl_not_issued)${reset}"
        read -rp "$(msg ssl_continue)" cont_ssl
        if [[ "$cont_ssl" != "y" ]]; then
            echo "${red}$(msg xray_install_aborted)${reset}"
            return 1
        fi
    fi

    run_task "Применение правил WARP"  applyWarpDomains || true
    run_task "Ротация логов"           setupLogrotate || true
    run_task "Автоочистка логов"       setupLogClearCron || true
    run_task "Автообновление SSL"      setupSslCron || true
    run_task "WARP Watchdog"           setupWarpWatchdog || true

    systemctl enable --now xray
    systemctl restart xray nginx

    # Устанавливаем Reality если выбрано
    if $install_reality; then
        echo -e "\n${cyan}--- Reality ---${reset}"
        ufw allow "$realityPort"/tcp comment 'Xray Reality' 2>/dev/null || true
        REALITY_INTERNAL_PORT=$realityPort
        run_task "Конфиг Reality"  "writeRealityConfig '$realityPort' '$realityDest'"
        run_task "Сервис Reality"  setupRealityService
        [ -f "$warpDomainsFile" ] && applyWarpDomains
        [ -f "$relayConfigFile" ]  && applyRelayDomains
    fi

    echo -e "\n${green}$(msg install_complete)${reset}"
    _initUsersFile
    getQrCode
}

# Установка VLESS + Reality + WARP
installRealityOnly() {
    isRoot
    clear
    identifyOS
    echo "${green}$(msg install_type_reality_title)${reset}"
    # Все зависимости, WARP, логи — installReality() сделает сам
    installReality
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
        local xray_tmpfile
        xray_tmpfile=$(mktemp)
        if curl -fsSL --connect-timeout 15 --proto '=https' --tlsv1.2 \
            "https://github.com/XTLS/Xray-install/raw/main/install-release.sh" \
            -o "$xray_tmpfile" 2>/dev/null \
            && head -1 "$xray_tmpfile" | grep -qE '^#!.*(bash|sh)' && ! head -5 "$xray_tmpfile" | grep -qi '<html'; then
            bash "$xray_tmpfile" @ remove || true
        fi
        rm -f "$xray_tmpfile"
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
    local xray_tmpfile2
    xray_tmpfile2=$(mktemp)
    if curl -fsSL --connect-timeout 15 --proto '=https' --tlsv1.2 \
        "https://github.com/XTLS/Xray-install/raw/main/install-release.sh" \
        -o "$xray_tmpfile2" 2>/dev/null \
        && head -1 "$xray_tmpfile2" | grep -qE '^#!.*(bash|sh)' && ! head -5 "$xray_tmpfile2" | grep -qi '<html'; then
        bash "$xray_tmpfile2" @ remove || true
    fi
    rm -f "$xray_tmpfile2"
    rm -rf /etc/nginx /usr/local/etc/xray/config.json \
           /usr/local/etc/xray/sub /usr/local/etc/xray/users.conf \
           /etc/cron.d/acme-renew /etc/cron.d/clear-logs \
           /usr/local/bin/clear-logs.sh /etc/sysctl.d/99-xray.conf
    systemctl daemon-reload
    echo "${green}$(msg remove_done)${reset}"
}

manageWs() {
    set +e
    while true; do
        clear
        local s_nginx s_ws s_ssl s_cfguard s_domain s_connect s_warp s_port s_path
        s_nginx=$(getServiceStatus nginx)
        s_ws=$(getServiceStatus xray)
        s_ssl=$(checkCertExpiry)
        s_cfguard=$(getCfGuardStatus)
        s_warp=$(getWarpStatus)
        s_domain=$(jq -r '.inbounds[0].streamSettings.wsSettings.host // .inbounds[0].streamSettings.xhttpSettings.host // "—"' "$configPath" 2>/dev/null)
        s_connect=$(cat "$CONNECT_HOST_FILE" 2>/dev/null | tr -d '[:space:]')
        s_port=$(jq -r '.inbounds[0].port // "—"' "$configPath" 2>/dev/null)
        s_path=$(jq -r '.inbounds[0].streamSettings.wsSettings.path // .inbounds[0].streamSettings.xhttpSettings.path // "—"' "$configPath" 2>/dev/null)
        # Обрезаем длинные значения
        [ ${#s_connect} -gt 35 ] && s_connect="${s_connect:0:32}..."
        [ ${#s_domain} -gt 30 ]  && s_domain="${s_domain:0:27}..."

        echo -e "${cyan}================================================================${reset}"
        echo -e "${cyan}================================================================${reset}"
        printf "   ${red}WebSocket + TLS + Nginx${reset}  %s\n" "$(date +'%d.%m.%Y %H:%M')"
        echo -e "${cyan}----------------------------------------------------------------${reset}"
        echo -e "  $(printf "%-7s" "Nginx:")$s_nginx,  SSL: ${green}$s_ssl_plain${reset},  CF Guard: $s_cfguard"
        echo -e "  $(printf "%-7s" "Xray:")$s_ws,  $(msg lbl_port): ${green}$s_port${reset},  $(msg lbl_path): ${green}$s_path${reset}"
        echo -e "  $(printf "%-7s" "WARP:")$s_warp,  $(msg lbl_domain): ${green}$s_domain${reset}"
        [ -n "$s_connect" ] && echo -e "  $(printf "%-7s" "CDN:")${green}${s_connect}${reset}"
        echo -e "${cyan}----------------------------------------------------------------${reset}"
        echo -e "  ${green}1.${reset}  $(msg menu_port)"
        echo -e "  ${green}2.${reset}  $(msg menu_wspath)"
        echo -e "  ${green}3.${reset}  $(msg menu_domain)"
        echo -e "  ${green}4.${reset}  $(msg menu_cdn_host)"
        echo -e "  ${green}5.${reset}  $(msg menu_ssl)"
        echo -e "  ${green}6.${reset}  $(msg menu_stub)"
        echo -e "  ${green}7.${reset}  $(msg menu_cfguard)"
        echo -e "  ${green}8.${reset}  $(msg menu_cf_update_ip)"
        echo -e "  ${green}9.${reset}  $(msg menu_ssl_cron)"
        echo -e "  ${green}10.${reset} $(msg menu_log_cron)"
        echo -e "  ${green}11.${reset} $(msg menu_uuid)"
        echo -e "${cyan}----------------------------------------------------------------${reset}"
        echo -e "  ${green}12.${reset} $(msg menu_install)"
        echo -e "  ${green}13.${reset} $(msg menu_remove)"
        echo -e "${cyan}----------------------------------------------------------------${reset}"
        echo -e "  ${green}0.${reset}  $(msg back)"
        echo -e "${cyan}================================================================${reset}"
        read -rp "$(msg choose)" choice
        case $choice in
            1)  modifyXrayPort ;;
            2)  modifyWsPath ;;
            3)  modifyDomain ;;
            4)  modifyConnectHost ;;
            5)  getConfigInfo && userDomain="$xray_userDomain" && configCert ;;
            6)  modifyProxyPassUrl ;;
            7)  toggleCfGuard ;;
            8)  setupRealIpRestore && { [ -f /etc/nginx/conf.d/cf_guard.conf ] && _fetchCfGuardIPs; } && nginx -t && systemctl reload nginx ;;
            9)  manageSslCron ;;
            10) manageLogClearCron ;;
            11) modifyXrayUUID ;;
            12) install ;;
            13) removeWs ;;
            0)  break ;;
        esac
        [ "$choice" = "0" ] && continue
        echo -e "\n${cyan}$(msg press_enter)${reset}"
        read -r
    done
}

menu() {
    set +e
    # Первичная очистка экрана
    clear
    while true; do
        local s_nginx s_ws s_reality s_warp s_ssl s_bbr s_f2b s_jail s_cfguard s_relay s_psiphon s_tor s_connect
        clear
        s_nginx=$(getServiceStatus nginx)
        s_ws=$(getServiceStatus xray)
        s_reality=$(getServiceStatus xray-reality)
        s_warp=$(getWarpStatus)
        s_ssl=$(checkCertExpiry)
        s_bbr=$(getBbrStatus)
        s_f2b=$(getF2BStatus)
        s_jail=$(getWebJailStatus)
        s_cfguard=$(getCfGuardStatus)
        s_relay=$(getRelayStatus)
        s_psiphon=$(getPsiphonStatus)
        s_tor=$(getTorStatus)
        s_panel=$(getPanelStatus 2>/dev/null || echo "${red}STOPPED${reset}")
        s_connect=$(cat "$CONNECT_HOST_FILE" 2>/dev/null | tr -d '[:space:]')
        [ ${#s_connect} -gt 35 ] && s_connect="${s_connect:0:32}..."
        # Чистые версии (без ANSI) для printf %-Ns выравнивания
        _strip() { printf '%s' "$1" | sed 's/\x1b\[[0-9;]*[mABCDJKHf]//g; s/\x1b(B//g'; }
        _pval() {
            local val="$1" w="$2" clean
            clean=$(_strip "$val")
            printf "%s%*s" "$val" $((w - ${#clean})) ""
        }
        s_ws_c=$(_pval "$s_ws" 7)
        s_reality_c=$(_pval "$s_reality" 7)
        s_nginx_c=$(_pval "$s_nginx" 7)
        # Чистые значения для правой колонки и туннелей (без ANSI — printf %-Ns не считает escape)
        _plain() { printf '%s' "$1" | sed 's/\x1b\[[0-9;]*[mABCDJKHf]//g; s/\x1b(B//g'; }
        s_warp_plain=$(_plain "$s_warp")
        s_ssl_plain=$(_plain "$s_ssl")
        s_cfguard_plain=$(_plain "$s_cfguard")
        s_relay_plain=$(_plain "$s_relay")
        s_psiphon_plain=$(_plain "$s_psiphon")
        s_tor_plain=$(_plain "$s_tor")
        s_bbr_plain=$(_plain "$s_bbr")
        s_f2b_plain=$(_plain "$s_f2b")
        s_jail_plain=$(_plain "$s_jail")

        echo -e "${cyan}================================================================${reset}"
        printf "   ${red}VWN — Xray Management Panel${reset}  %s\n" "$(date +'%d.%m.%Y %H:%M')"
        echo -e "${cyan}================================================================${reset}"
        echo -e "  ${cyan}── $(msg menu_sep_proto_short) ──────────────────────────────────────────${reset}"
        echo -e "  $(printf "%-9s" "WS:")$s_ws_c,  WARP: $s_warp"
        echo -e "  $(printf "%-9s" "Reality:")$s_reality_c,  SSL: $s_ssl"
        echo -e "  $(printf "%-9s" "Nginx:")$s_nginx_c,  CF Guard: $s_cfguard"
        [ -n "$s_connect" ] && echo -e "  CDN: ${green}${s_connect}${reset}"
        echo -e "  ${cyan}── $(msg menu_sep_tun_short) ───────────────────────────────────────────${reset}"
        echo -e "  Relay: $s_relay,  Psiphon: $s_psiphon,  Tor: $s_tor"
        echo -e "  ${cyan}── Panel ──────────────────────────────────────────${reset}"
        echo -e "  Panel: $s_panel"
        echo -e "  ${cyan}── $(msg menu_sep_sec_short) ────────────────────────────────────────────${reset}"
        echo -e "  BBR: $s_bbr,  F2B: $s_f2b,  Jail: $s_jail,  IPv6: $(getIPv6Status),  CPU Guard: $(getCpuGuardStatus)"
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
        echo -e "  ${green}20.${reset} $(msg menu_cpuguard)"
        echo -e "  $(msg menu_sep_logs)"
        echo -e "  ${green}21.${reset} $(msg menu_xray_acc)"
        echo -e "  ${green}22.${reset} $(msg menu_xray_err)"
        echo -e "  ${green}23.${reset} $(msg menu_nginx_acc)"
        echo -e "  ${green}24.${reset} $(msg menu_nginx_err)"
        echo -e "  ${green}25.${reset} $(msg menu_clear_logs)"
        echo -e "  $(msg menu_sep_svc)"
        echo -e "  ${green}26.${reset} $(msg menu_restart)"
        echo -e "  ${green}27.${reset} $(msg menu_update_xray)"
        echo -e "  ${green}28.${reset} $(msg menu_diag)"
        echo -e "  ${green}29.${reset} $(msg menu_backup)"
        echo -e "  ${green}30.${reset} $(msg menu_lang)"
        echo -e "  ${green}31.${reset} $(msg menu_panel)"
        echo -e "  ${green}32.${reset} $(msg menu_remove)"
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
            20) setupCpuGuard ;;
            21) tail -n 80 /var/log/xray/access.log 2>/dev/null || echo "$(msg no_logs)" ;;
            22) tail -n 80 /var/log/xray/error.log 2>/dev/null || echo "$(msg no_logs)" ;;
            23) tail -n 80 /var/log/nginx/access.log 2>/dev/null || echo "$(msg no_logs)" ;;
            24) tail -n 80 /var/log/nginx/error.log 2>/dev/null || echo "$(msg no_logs)" ;;
            25) clearLogs ;;
            26) systemctl restart xray xray-reality nginx warp-svc psiphon tor 2>/dev/null || true
                echo "${green}$(msg all_services_restarted)${reset}" ;;
            27) updateXrayCore ;;
            28) manageDiag ;;
            29) manageBackup ;;
            30) selectLang; _initLang ;;
            31) managePanel ;;
            32) fullRemove ;;
            0)  exit 0 ;;
            *)  echo -e "${red}$(msg invalid)${reset}"; sleep 1 ;;
        esac
        echo -e "\n${cyan}$(msg press_enter)${reset}"
        read -r
    done
}