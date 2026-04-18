#!/bin/bash
# =================================================================
# nginx.sh — Nginx конфиг, CDN, SSL сертификаты
#
# Три режима:
#   base   — WS+TLS на 443 (Nginx напрямую с SSL)
#   vision — Vision на 443 (Nginx на 7443 без SSL, fallback)
#   stream — Stream SNI на 443 (nginx.conf со stream{} блоком)
# =================================================================

VWN_CONFIG_DIR="${VWN_CONFIG_DIR:-/usr/local/lib/vwn/config}"

_getCountryCode() {
    local ip="$1"
    local code
    code=$(curl -s --connect-timeout 5 "http://ip-api.com/line/${ip}?fields=countryCode" 2>/dev/null | tr -d '[:space:]')
    if [[ "$code" =~ ^[A-Z]{2}$ ]]; then
        echo "[$code]"
    else
        echo "[??]"
    fi
}

setNginxCert() {
    [ ! -d '/etc/nginx/cert' ] && mkdir -p '/etc/nginx/cert'
    if [ ! -f /etc/nginx/cert/default.crt ]; then
        openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
            -keyout /etc/nginx/cert/default.key \
            -out /etc/nginx/cert/default.crt \
            -subj "/CN=localhost" &>/dev/null
    fi
}

# ── Режим BASE: WS+TLS на 443 напрямую ──────────────────────────


writeNginxConfigBase() {
    local xrayPort="$1" domain="$2" proxyUrl="$3" wsPath="$4"
    local proxy_host
    proxy_host=$(echo "$proxyUrl" | sed 's|https://||;s|http://||;s|/.*||')

    setNginxCert

    # nginx.conf — общая часть
    cp "$VWN_CONFIG_DIR/nginx_main.conf" /etc/nginx/nginx.conf

    # default.conf
    cp "$VWN_CONFIG_DIR/nginx_default.conf" /etc/nginx/conf.d/default.conf

    # xray.conf — WS server block
    render_config "$VWN_CONFIG_DIR/nginx_base.conf" "$nginxPath" \
        DOMAIN "$domain" XRAY_PORT "$xrayPort" WS_PATH "$wsPath" \
        PROXY_URL "$proxyUrl" PROXY_HOST "$proxy_host"

    vwn_conf_set STUB_URL "$proxyUrl"
    vwn_conf_set NGINX_MODE "base"

    setupRealIpRestore
    _writeSubMapConf
}

# ── Режим VISION: Vision на 443, Nginx fallback на 7443 без SSL ──

writeNginxConfigVision() {
    local proxyUrl="$1" visionDomain="$2"
    local proxy_host
    proxy_host=$(echo "$proxyUrl" | sed 's|https://||;s|http://||;s|/.*||')

    setNginxCert

    # nginx.conf — общая часть
    cp "$VWN_CONFIG_DIR/nginx_main.conf" /etc/nginx/nginx.conf

    # xray.conf — Vision fallback server block (HTTP, без SSL!)
    render_config "$VWN_CONFIG_DIR/nginx_vision.conf" "$nginxPath" \
        VISION_DOMAIN "$visionDomain" PROXY_URL "$proxyUrl" PROXY_HOST "$proxy_host"

    vwn_conf_set STUB_URL "$proxyUrl"
    vwn_conf_set NGINX_MODE "vision"

    _writeSubMapConf
}

# ── Режим STREAM SNI: WS + Reality на 443 ───────────────────────

_writeStreamNginxConf() {
    local wsDomain="$1" nginxPort="$2" realityPort="$3"

    # Сохраняем STREAM_DOMAINS
    local stream_domains
    stream_domains=$(vwn_conf_get STREAM_DOMAINS 2>/dev/null || true)
    if [ -z "$stream_domains" ]; then
        stream_domains="${wsDomain}:${nginxPort}"
    elif ! echo "$stream_domains" | grep -q "^${wsDomain}:"; then
        stream_domains="${wsDomain}:${nginxPort},${stream_domains}"
    fi
    vwn_conf_set STREAM_DOMAINS "$stream_domains"
    vwn_conf_set STREAM_DEFAULT "$reality_port"

    # nginx.conf — полный конфиг со stream{} блоком из шаблона
    render_config "$VWN_CONFIG_DIR/nginx_stream.conf" /etc/nginx/nginx.conf \
        WS_DOMAIN "$wsDomain" REALITY_PORT "$realityPort"

    # xray.conf — WS server block для Stream режима (с SSL)
    local proxyUrl wsPath proxy_host
    proxyUrl=$(grep -oP "(?<=proxy_pass )[^;]+" "$nginxPath" 2>/dev/null | grep -v "127.0.0.1" | head -1)
    [ -z "$proxyUrl" ] && proxyUrl=$(vwn_conf_get STUB_URL 2>/dev/null)
    [ -z "$proxyUrl" ] && proxyUrl="https://www.bing.com/"
    proxy_host=$(echo "$proxyUrl" | sed 's|https://||;s|http://||;s|/.*||')
    wsPath=$(jq -r '.inbounds[0].streamSettings.wsSettings.path // ""' "$configPath" 2>/dev/null)

    render_config "$VWN_CONFIG_DIR/nginx_stream_ws.conf" "$nginxPath" \
        WS_DOMAIN "$wsDomain" XRAY_PORT "16500" WS_PATH "$wsPath" \
        PROXY_URL "$proxyUrl" PROXY_HOST "$proxy_host"

    vwn_conf_set NGINX_MODE "stream"
    _writeSubMapConf
}

# Добавляет домен:порт в stream map и перегенерирует nginx.conf.
addDomainToStream() {
    local new_domain="$1" new_port="$2"
    [ -z "$new_domain" ] || [ -z "$new_port" ] && return 1

    local stream_domains reality_port
    stream_domains=$(vwn_conf_get STREAM_DOMAINS 2>/dev/null || true)
    reality_port=$(vwn_conf_get REALITY_INTERNAL_PORT 2>/dev/null || echo "10443")

    # Убираем старую запись для этого домена если есть
    local new_entry="${new_domain}:${new_port}"
    local filtered=""
    IFS=',' read -ra _entries <<< "$stream_domains"
    for _e in "${_entries[@]}"; do
        [ -z "$_e" ] && continue
        local _ed; _ed=$(echo "$_e" | cut -d: -f1)
        [ "$_ed" = "$new_domain" ] && continue
        filtered="${filtered:+${filtered},}${_e}"
    done
    stream_domains="${filtered:+${filtered},}${new_entry}"
    vwn_conf_set STREAM_DOMAINS "$stream_domains"

    local ws_domain nginx_port
    ws_domain=$(jq -r '.inbounds[0].streamSettings.wsSettings.host // empty' "$configPath" 2>/dev/null)
    nginx_port=$(vwn_conf_get NGINX_HTTPS_PORT 2>/dev/null || echo "7443")
    [ -z "$ws_domain" ] && ws_domain=$(vwn_conf_get DOMAIN 2>/dev/null || echo "")

    # Перегенерируем только stream map в nginx.conf
    _writeStreamMap "$ws_domain" "$nginx_port" "$reality_port"
}

# Удаляет домен из stream map и перегенерирует nginx.conf.
removeDomainFromStream() {
    local rem_domain="$1"
    [ -z "$rem_domain" ] && return 1

    local stream_domains reality_port
    stream_domains=$(vwn_conf_get STREAM_DOMAINS 2>/dev/null || true)
    reality_port=$(vwn_conf_get REALITY_INTERNAL_PORT 2>/dev/null || echo "10443")

    local filtered=""
    IFS=',' read -ra _entries <<< "$stream_domains"
    for _e in "${_entries[@]}"; do
        [ -z "$_e" ] && continue
        local _ed; _ed=$(echo "$_e" | cut -d: -f1)
        [ "$_ed" = "$rem_domain" ] && continue
        filtered="${filtered:+${filtered},}${_e}"
    done
    vwn_conf_set STREAM_DOMAINS "$filtered"

    local ws_domain nginx_port
    ws_domain=$(jq -r '.inbounds[0].streamSettings.wsSettings.host // empty' "$configPath" 2>/dev/null)
    nginx_port=$(vwn_conf_get NGINX_HTTPS_PORT 2>/dev/null || echo "7443")
    [ -z "$ws_domain" ] && ws_domain=$(vwn_conf_get DOMAIN 2>/dev/null || echo "")

    _writeStreamMap "$ws_domain" "$nginx_port" "$reality_port"
}

# Внутренняя функция — пишет только stream map блок в nginx.conf
_writeStreamMap() {
    local wsDomain="$1" nginxPort="$2" realityPort="$3"

    local stream_domains
    stream_domains=$(vwn_conf_get STREAM_DOMAINS 2>/dev/null || true)

    # Создаём полный контент nginx.conf заново из шаблона вместо опасной замены регексом
    render_config "$VWN_CONFIG_DIR/nginx_stream.conf" /etc/nginx/nginx.conf \
        WS_DOMAIN "$wsDomain" REALITY_PORT "$realityPort" STREAM_DOMAINS "$stream_domains"
}

setupStreamSNI() {
    local nginx_port="${1:-7443}"
    local reality_port="${2:-10443}"
    local _stream_was_active=false

    # ── Предварительные проверки ─────────────────────────────────────────────

    # 1. nginx установлен и доступен
    if ! command -v nginx &>/dev/null; then
        echo "${red}$(msg stream_sni_no_nginx)${reset}"
        return 1
    fi

    # 2. nginx запущен
    if ! systemctl is-active --quiet nginx 2>/dev/null; then
        echo "${yellow}$(msg stream_sni_nginx_stopped)${reset}"
        echo "${yellow}$(msg stream_sni_nginx_start_hint)${reset}"
        return 1
    fi

    # 3. WS конфиг существует (установка WS должна быть выполнена)
    if [ ! -f "$configPath" ]; then
        echo "${red}$(msg stream_sni_no_ws_config)${reset}"
        return 1
    fi

    # 4. SSL сертификат существует
    if [ ! -f /etc/nginx/cert/cert.pem ] || [ ! -f /etc/nginx/cert/cert.key ]; then
        echo "${red}$(msg stream_sni_no_ssl)${reset}"
        echo "${yellow}$(msg stream_sni_ssl_hint)${reset}"
        return 1
    fi

    # 5. Reality конфиг существует
    if [ ! -f "$realityConfigPath" ]; then
        echo "${red}$(msg stream_sni_no_reality)${reset}"
        return 1
    fi

    # 5.5. Vision НЕ совместим со Stream SNI
    if systemctl is-active --quiet xray-vision 2>/dev/null; then
        echo "${red}ERROR: Vision не поддерживает работу через Stream SNI.${reset}"
        echo "${yellow}Vision работает напрямую на порту 443 и не может быть маршрутизирован через Stream.${reset}"
        echo "${yellow}Варианты:${reset}"
        echo "${yellow}  1. Удалить Vision (manageVision → Remove), затем включить Stream SNI${reset}"
        echo "${yellow}  2. Не использовать Stream SNI — Reality будет на своём порту (напр. 8443)${reset}"
        return 1
    fi

    # 6. nginx собран с модулем stream
    if ! nginx -V 2>&1 | grep -q "with-stream"; then
        echo "${red}$(msg stream_module_missing)${reset}"
        echo "${yellow}$(msg stream_module_hint)${reset}"
        if command -v apt &>/dev/null; then
            echo "${cyan}$(msg stream_module_autoinstall)${reset}"
            read -rp "$(msg yes_no) " _ans
            if [[ "$_ans" == "y" ]]; then
                apt-get install -y nginx-full 2>/dev/null && echo "${green}nginx-full installed${reset}" || { echo "${red}$(msg stream_module_install_fail)${reset}"; return 1; }
                if ! nginx -V 2>&1 | grep -q "with-stream"; then
                    echo "${red}$(msg stream_module_missing)${reset}"
                    return 1
                fi
            else
                return 1
            fi
        else
            return 1
        fi
    fi

    # 7. Порты не заняты другими процессами
    for _p in "$nginx_port" "$reality_port"; do
        local _proc
        _proc=$(ss -tlnp "sport = :${_p}" 2>/dev/null | awk 'NR>1{print $NF}' | grep -v nginx | grep -v xray || true)
        if [ -n "$_proc" ]; then
            echo "${yellow}$(msg stream_sni_port_busy): ${_p} — ${_proc}${reset}"
        fi
    done

    # 8. Stream SNI уже активен?
    if grep -q "ssl_preread on" /etc/nginx/nginx.conf 2>/dev/null; then
        _stream_was_active=true
        echo "${yellow}$(msg stream_sni_already_active)${reset}"
        local cur_np cur_rp
        cur_np=$(vwn_conf_get NGINX_HTTPS_PORT)
        cur_rp=$(vwn_conf_get REALITY_INTERNAL_PORT)
        echo "  nginx   → 127.0.0.1:${cur_np:-?}"
        echo "  reality → 127.0.0.1:${cur_rp:-?}"
        echo ""
        read -rp "$(msg stream_sni_reconfigure) $(msg yes_no) " _reconf
        [[ "$_reconf" != "y" ]] && return 0
    fi

    # ── Читаем домен ─────────────────────────────────────────────────────────
    local domain
    domain=$(vwn_conf_get DOMAIN)
    if [ -z "$domain" ]; then
        domain=$(jq -r '.inbounds[0].streamSettings.wsSettings.host // empty' "$configPath" 2>/dev/null)
    fi
    if [ -z "$domain" ]; then
        echo "${red}$(msg stream_sni_no_domain)${reset}"
        return 1
    fi

    echo -e "${cyan}$(msg stream_sni_setup): ${domain}${reset}"
    echo -e "  nginx   → 127.0.0.1:${nginx_port}"
    echo -e "  reality → 127.0.0.1:${reality_port}"

    # Save the original external Reality port for disable rollback
    if [ -f "$realityConfigPath" ] && ! $_stream_was_active; then
        local reality_orig_port
        reality_orig_port=$(vwn_conf_get REALITY_PORT 2>/dev/null || true)
        if ! [[ "$reality_orig_port" =~ ^[0-9]+$ ]]; then
            reality_orig_port=$(jq -r '.inbounds[0].port // empty' "$realityConfigPath" 2>/dev/null)
        fi
        if [[ "$reality_orig_port" =~ ^[0-9]+$ ]]; then
            vwn_conf_set REALITY_ORIG_PORT "$reality_orig_port"
        fi
    fi

    vwn_conf_set NGINX_HTTPS_PORT      "$nginx_port"
    vwn_conf_set REALITY_INTERNAL_PORT "$reality_port"

    # Пишем nginx.conf со stream-блоком из шаблона
    _writeStreamNginxConf "$domain" "$nginx_port" "$reality_port"

    # Переключаем Reality на 127.0.0.1:reality_port
    if [ -f "$realityConfigPath" ]; then
        local tmp
        tmp=$(mktemp)
        jq --argjson p "$reality_port" \
           '.inbounds[0].port = $p | .inbounds[0].listen = "127.0.0.1"' \
           "$realityConfigPath" > "$tmp" && mv "$tmp" "$realityConfigPath"
        chown xray:xray "$realityConfigPath" 2>/dev/null || true
        chmod 640 "$realityConfigPath" 2>/dev/null || true
        echo "${green}$(msg reality_port_updated): 127.0.0.1:${reality_port}${reset}"
        systemctl restart xray-reality 2>/dev/null || true
    fi

    # UFW
    ufw allow 443/tcp comment 'HTTPS+Reality SNI' &>/dev/null || true
    ufw allow 443/udp comment 'HTTPS+Reality SNI' &>/dev/null || true

    nginx -t || { echo "${red}$(msg nginx_syntax_err)${reset}"; return 1; }
    systemctl stop nginx
    sleep 1
    systemctl start nginx

    local i=0
    while [ $i -lt 15 ]; do
        ss -tlnp 2>/dev/null | grep -q ":443" && break
        sleep 1
        i=$((i+1))
    done
    if ! ss -tlnp 2>/dev/null | grep -q ":443"; then
        echo "${red}$(msg stream_sni_port_fail)${reset}"
        echo "${yellow}$(msg stream_sni_port_fail_hint)${reset}"
        journalctl -u nginx -n 10 --no-pager 2>/dev/null || true
        return 1
    fi

    echo "${green}$(msg stream_sni_done)${reset}"
    rebuildAllSubFiles 2>/dev/null || true
}

# Отключает stream SNI
_doDisableStreamSNI() {
    local domain xray_port proxy_url ws_path reality_restore_port
    domain=$(vwn_conf_get DOMAIN)
    xray_port=$(jq -r '.inbounds[0].port // empty' "$configPath" 2>/dev/null)
    proxy_url=$(grep -o 'proxy_pass [^;]*' "$nginxPath" 2>/dev/null | tail -1 | awk '{print $2}')
    ws_path=$(jq -r '.inbounds[0].streamSettings.wsSettings.path // empty' "$configPath" 2>/dev/null)

    # ── 1. Определяем порт восстановления Reality ────────────────────────────
    # Приоритет: REALITY_ORIG_PORT > REALITY_PORT > reality.json > 8443
    reality_restore_port=$(vwn_conf_get REALITY_ORIG_PORT 2>/dev/null || true)
    if ! [[ "$reality_restore_port" =~ ^[0-9]+$ ]]; then
        reality_restore_port=$(vwn_conf_get REALITY_PORT 2>/dev/null || true)
    fi
    if ! [[ "$reality_restore_port" =~ ^[0-9]+$ ]]; then
        reality_restore_port=$(jq -r '.inbounds[0].port // empty' "$realityConfigPath" 2>/dev/null)
    fi
    if ! [[ "$reality_restore_port" =~ ^[0-9]+$ ]]; then
        reality_restore_port=8443
    fi

    # ── 2. Восстанавливаем nginx без stream блока (base режим) ───────────────
    writeNginxConfigBase "$xray_port" "$domain" "$proxy_url" "$ws_path"

    # ── 3. Чистим vwn.conf от stream параметров ──────────────────────────────
    vwn_conf_del NGINX_HTTPS_PORT
    vwn_conf_del REALITY_INTERNAL_PORT
    vwn_conf_del REALITY_ORIG_PORT
    vwn_conf_del STREAM_DOMAINS
    vwn_conf_del STREAM_DEFAULT

    # ── 4. Возвращаем Reality на 0.0.0.0 и его оригинальный порт ─────────────
    if [ -f "$realityConfigPath" ]; then
        jq --argjson p "$reality_restore_port" '.inbounds[0].listen = "0.0.0.0" | .inbounds[0].port = $p' \
            "$realityConfigPath" > "${realityConfigPath}.tmp" \
            && mv "${realityConfigPath}.tmp" "$realityConfigPath"
        chown xray:xray "$realityConfigPath" 2>/dev/null || true
        chmod 640 "$realityConfigPath" 2>/dev/null || true
        systemctl restart xray-reality 2>/dev/null || true
        echo -e "${green}Reality возвращён на порт $reality_restore_port.${reset}"
    fi

    # ── 5. UFW ───────────────────────────────────────────────────────────────
    if [[ "$reality_restore_port" =~ ^[0-9]+$ ]]; then
        ufw allow "$reality_restore_port"/tcp comment 'Xray Reality' &>/dev/null || true
        ufw status numbered 2>/dev/null | grep 'HTTPS+Reality SNI' \
            | awk -F"[][]" '{print $2}' | sort -rn | while read -r n; do
            echo "y" | ufw delete "$n" &>/dev/null || true
        done
        echo -e "${green}UFW обновлён: порт $reality_restore_port открыт.${reset}"
    fi

    # ── 6. Обновляем reality_client.txt ──────────────────────────────────────
    if [ -f /usr/local/etc/xray/reality_client.txt ]; then
        sed -i "s/^Port:.*/Port:       $reality_restore_port/" /usr/local/etc/xray/reality_client.txt
    fi

    # ── 7. Перезагружаем nginx ───────────────────────────────────────────────
    nginx -t && systemctl reload nginx
    echo "${green}$(msg stream_sni_disabled)${reset}"

    # ── 8. Перегенерируем подписки ───────────────────────────────────────────
    rebuildAllSubFiles 2>/dev/null || true
}

disableStreamSNI() {
    echo "${yellow}$(msg stream_sni_disable_confirm) $(msg yes_no)${reset}"
    read -r confirm
    [[ "$confirm" != "y" ]] && return
    _doDisableStreamSNI
}

# ── Утилиты ──────────────────────────────────────────────────────────────────

_writeSubMapConf() {
    local server_ip country_code
    server_ip=$(getServerIP 2>/dev/null || curl -s --connect-timeout 5 ifconfig.me)
    country_code=$(_getCountryCode "$server_ip")
    render_config "$VWN_CONFIG_DIR/sub_map.conf" /etc/nginx/conf.d/sub_map.conf \
        COUNTRY "$country_code"
}

setupRealIpRestore() {
    echo -e "${cyan}$(msg cf_ips_setup)${reset}"
    local tmp
    tmp=$(mktemp) || return 0

    printf '# Cloudflare real IP restore — auto-generated\n' > "$tmp"

    local ok=0
    for t in v4 v6; do
        local result
        result=$(curl -fsSL --connect-timeout 10 "https://www.cloudflare.com/ips-$t" 2>/dev/null) || continue
        while IFS= read -r ip; do
            [ -z "$ip" ] && continue
            echo "set_real_ip_from $ip;" >> "$tmp"
            ok=1
        done < <(echo "$result" | grep -E '^[0-9a-fA-F:.]+(/[0-9]+)?$')
    done

    if [ "$ok" -eq 0 ]; then
        echo "${yellow}Warning: Could not fetch Cloudflare IPs, skipping real_ip_restore${reset}"
        rm -f "$tmp"
        return 0
    fi

    printf 'real_ip_header CF-Connecting-IP;\nreal_ip_recursive on;\n' >> "$tmp"

    mkdir -p /etc/nginx/conf.d
    mv -f "$tmp" /etc/nginx/conf.d/real_ip_restore.conf
    echo "${green}$(msg cf_ips_ok)${reset}"
}

_manageSubAuth() {
    echo ""
    echo "${cyan}=== $(msg sub_auth_manage) ===${reset}"
    local auth_active=false
    grep -q "auth_basic" "$nginxPath" 2>/dev/null && auth_active=true
    local cur_user cur_pass
    cur_user=$(vwn_conf_get SUB_AUTH_USER)
    cur_pass=$(vwn_conf_get SUB_AUTH_PASS)
    if $auth_active; then
        echo "$(msg sub_auth_status): ${green}$(msg sub_auth_on)${reset}"
        [ -n "$cur_user" ] && echo "$(msg sub_auth_current): ${green}${cur_user}${reset} / ${green}${cur_pass}${reset}"
    else
        echo "$(msg sub_auth_status): ${red}$(msg sub_auth_off)${reset}"
    fi
    echo "${yellow}$(msg sub_auth_warn)${reset}"
    echo ""
    if $auth_active; then
        echo -e "  ${green}1.${reset} $(msg sub_auth_change_pass)"
        echo -e "  ${green}2.${reset} $(msg sub_auth_disable)"
        echo -e "  ${green}0.${reset} $(msg back)"
        read -rp "$(msg choose) " sa_choice
        case "$sa_choice" in
            1) _subAuthSetCredentials && nginx -t && systemctl reload nginx ;;
            2) _subAuthDisable ;;
            0) return ;;
            *) echo "${red}$(msg invalid)${reset}" ;;
        esac
    else
        echo -e "  ${green}1.${reset} $(msg sub_auth_enable)"
        echo -e "  ${green}0.${reset} $(msg back)"
        read -rp "$(msg choose) " sa_choice
        case "$sa_choice" in
            1) _subAuthEnable ;;
            0) return ;;
            *) echo "${red}$(msg invalid)${reset}" ;;
        esac
    fi
}

_subAuthEnable() {
    _subAuthSetCredentials || return 1
    if ! grep -q "auth_basic" "$nginxPath" 2>/dev/null; then
        sed -i '/location ~ \^\/sub\//,/}/ { /}/i\        auth_basic           "Restricted";\n        auth_basic_user_file /etc/nginx/conf.d/.htpasswd;
}' "$nginxPath" 2>/dev/null || true
    fi
    nginx -t && systemctl reload nginx
    echo "${green}$(msg sub_auth_enabled): ${cyan}$(vwn_conf_get SUB_AUTH_USER)${reset} / ${cyan}$(vwn_conf_get SUB_AUTH_PASS)${reset}"
}

_subAuthDisable() {
    echo "${yellow}$(msg sub_auth_disable_confirm) $(msg yes_no)${reset}"
    read -r confirm
    [[ "$confirm" != "y" ]] && return
    sed -i '/auth_basic/d' "$nginxPath" 2>/dev/null || true
    rm -f /etc/nginx/conf.d/.htpasswd
    vwn_conf_del SUB_AUTH_USER
    vwn_conf_del SUB_AUTH_PASS
    nginx -t && systemctl reload nginx
    echo "${green}$(msg sub_auth_disabled)${reset}"
}

_subAuthSetCredentials() {
    local cur_user
    cur_user=$(vwn_conf_get SUB_AUTH_USER)
    read -rp "$(msg sub_auth_new_user) [${cur_user:-vwn}]: " new_user
    new_user="${new_user:-${cur_user:-vwn}}"
    read -rp "$(msg sub_auth_new_pass) ($(msg leave_empty_random)): " new_pass
    [ -z "$new_pass" ] && new_pass=$(openssl rand -base64 12 | tr -d '+/=' | head -c 16)
    local hashed
    hashed=$(python3 -c "
import crypt, sys
u, p = sys.argv[1], sys.argv[2]
print(u + ':' + crypt.crypt(p, crypt.mksalt(crypt.METHOD_SHA512)))
" "$new_user" "$new_pass" 2>/dev/null)
    if [ -n "$hashed" ]; then
        echo "$hashed" > /etc/nginx/conf.d/.htpasswd
        chmod 640 /etc/nginx/conf.d/.htpasswd
        chown root:www-data /etc/nginx/conf.d/.htpasswd 2>/dev/null || true
    fi
    vwn_conf_set SUB_AUTH_USER "$new_user"
    vwn_conf_set SUB_AUTH_PASS "$new_pass"
    echo "${green}$(msg sub_auth_updated): ${cyan}${new_user}${reset} / ${cyan}${new_pass}${reset}"
}

_fetchCfGuardIPs() {
    local tmp
    tmp=$(mktemp) || return 1
    printf '# CF Guard — allow only Cloudflare IPs — auto-generated\ngeo $realip_remote_addr $cloudflare_ip {\n    default 0;\n' > "$tmp"
    local ok=0
    for t in v4 v6; do
        local result
        result=$(curl -fsSL --connect-timeout 10 "https://www.cloudflare.com/ips-$t" 2>/dev/null) || continue
        while IFS= read -r ip; do
            [ -z "$ip" ] && continue
            echo "    $ip 1;" >> "$tmp"
            ok=1
        done < <(echo "$result" | grep -E '^[0-9a-fA-F:.]+(/[0-9]+)?$')
    done
    [ "$ok" -eq 0 ] && { rm -f "$tmp"; echo "${red}$(msg cf_ips_fail)${reset}"; return 1; }
    echo "}" >> "$tmp"
    mkdir -p /etc/nginx/conf.d
    mv -f "$tmp" /etc/nginx/conf.d/cf_guard.conf
    echo "${green}$(msg cf_ips_ok)${reset}"
}

toggleCfGuard() {
    if [ -f /etc/nginx/conf.d/cf_guard.conf ]; then
        echo -e "${yellow}$(msg cfguard_disable_confirm) $(msg yes_no)${reset}"
        read -r confirm
        if [[ "$confirm" == "y" ]]; then
            rm -f /etc/nginx/conf.d/cf_guard.conf
            sed -i '/cloudflare_ip.*!=.*1/d' "$nginxPath" 2>/dev/null || true
            nginx -t && systemctl reload nginx
            echo "${green}$(msg cfguard_disabled)${reset}"
        fi
    else
        _fetchCfGuardIPs || return 1
        local wsPath
        wsPath=$(jq -r ".inbounds[0].streamSettings.wsSettings.path" "$configPath" 2>/dev/null)
        if [ -n "$wsPath" ] && [ "$wsPath" != "null" ]; then
            if ! grep -q "cloudflare_ip" "$nginxPath" 2>/dev/null; then
                sed -i "s/\(\s*location ${wsPath//\//\\/} {)/    if (\$cloudflare_ip != 1) { return 444; }\n\n\1/" "$nginxPath" 2>/dev/null || true
            fi
        fi
        nginx -t || { echo "${red}$(msg nginx_syntax_err)${reset}"; return 1; }
        systemctl reload nginx
        echo "${green}$(msg cfguard_enabled)${reset}"
    fi
}

openPort80() {
    ufw status | grep -q inactive && return
    ufw allow from any to any port 80 proto tcp comment 'ACME temp'
}

closePort80() {
    ufw status | grep -q inactive && return
    ufw status numbered | grep 'ACME temp' | awk -F"[][]" '{print $2}' | sort -rn | while read -r n; do
        echo "y" | ufw delete "$n"
    done
}

configCert() {
    if [[ -z "${userDomain:-}" ]]; then
        read -rp "$(msg ssl_enter_domain)" userDomain
    fi
    [ -z "$userDomain" ] && { echo "${red}$(msg ssl_domain_empty)${reset}"; return 1; }
    
    # ✅ Проверка существующего сертификата
    if [ -f /etc/nginx/cert/cert.pem ]; then
        local expire_date expire_epoch now_epoch days_left domain_in_cert
        
        # Срок действия
        expire_date=$(openssl x509 -enddate -noout -in /etc/nginx/cert/cert.pem 2>/dev/null | cut -d= -f2)
        expire_epoch=$(date -d "$expire_date" +%s 2>/dev/null)
        now_epoch=$(date +%s)
        days_left=$(( (expire_epoch - now_epoch) / 86400 ))
        
        # Домен в сертификате
        domain_in_cert=$(openssl x509 -noout -text -in /etc/nginx/cert/cert.pem 2>/dev/null | grep -oP '(?<=DNS:)[^,\s]+' | head -1)
        
        # Если сертификат валиден и для нужного домена
        if [ -n "$expire_epoch" ] && [ "$days_left" -gt 15 ] && [ "$domain_in_cert" = "$userDomain" ]; then
            echo -e "${green}✅ $(msg diag_ssl_ok)${reset}"
            echo -e "  Домен: ${cyan}$userDomain${reset}"
            echo -e "  Осталось дней действия: ${green}$days_left${reset}"
            echo ""
            read -rp "$(msg ssl_reissue_confirm) $(msg yes_no) " reissue
            [[ "$reissue" != "y" ]] && { echo "$(msg cancel)"; return 0; }
        fi
    fi
    
    echo -e "\n${cyan}$(msg ssl_method)${reset}"
    echo "$(msg ssl_method_1)"
    echo "$(msg ssl_method_2)"
    read -rp "$(msg ssl_your_choice)" cert_method
    installPackage "socat" || true
    if [ ! -f ~/.acme.sh/acme.sh ]; then
        curl -fsSL https://get.acme.sh | sh -s email="acme@${userDomain}"
    fi
    if [ ! -f ~/.acme.sh/acme.sh ]; then
        echo "${red}$(msg acme_install_fail)${reset}"; return 1
    fi
    ~/.acme.sh/acme.sh --upgrade --auto-upgrade
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
    if [ "$cert_method" == "1" ]; then
        [ -f "$cf_key_file" ] && source "$cf_key_file"
        if [[ -z "${CF_Email:-}" || -z "${CF_Key:-}" ]]; then
            read -rp "$(msg ssl_cf_email)" CF_Email
            read -rp "$(msg ssl_cf_key)" CF_Key
            printf "export CF_Email='%s'\nexport CF_Key='%s'\n" "$CF_Email" "$CF_Key" > "$cf_key_file"
            chmod 600 "$cf_key_file"
        fi
        # Передаем ключи только локально в окружение запуска процесса acme.sh, не оставляем в среде скрипта
        CF_Email="$CF_Email" CF_Key="$CF_Key" ~/.acme.sh/acme.sh --issue --dns dns_cf -d "$userDomain"
    else
        openPort80
        ~/.acme.sh/acme.sh --issue --standalone -d "$userDomain" \
            --pre-hook "/usr/local/bin/vwn open-80" \
            --post-hook "/usr/local/bin/vwn close-80"
        closePort80
    fi
    mkdir -p /etc/nginx/cert
    ~/.acme.sh/acme.sh --install-cert -d "$userDomain" \
        --key-file /etc/nginx/cert/cert.key \
        --fullchain-file /etc/nginx/cert/cert.pem \
        --reloadcmd "systemctl reload nginx"
    echo "${green}$(msg ssl_success) $userDomain${reset}"
}

applyNginxSub() {
    [ ! -f "$nginxPath" ] && return 1
    _writeSubMapConf
    if ! grep -q 'location ~ \^/sub/' "$nginxPath"; then
        sed -i '/location \/ {/i\    location ~ ^/sub/[A-Za-z0-9_-]+_[A-Za-z0-9]+\\.html$ {\n        root /usr/local/etc/xray;\n        try_files $uri =404;\n        types { text/html html; }\n        add_header Cache-Control '\''no-cache, no-store, must-revalidate'\'';\n    }\n\n    location ~ ^/sub/[A-Za-z0-9_-]+_[A-Za-z0-9]+\\.txt$ {\n        root /usr/local/etc/xray;\n        try_files $uri =404;\n        default_type text/plain;\n        add_header Content-Disposition "attachment; filename=\\"$sub_label.txt\\"";\n        add_header profile-title "$sub_label";\n        add_header Cache-Control '\''no-cache, no-store, must-revalidate'\'';\n    }\n' "$nginxPath" 2>/dev/null || true
    fi
    nginx -t && systemctl reload nginx
}

manageStreamSNI() {
    set +e
    while true; do
        clear
        local s_stream s_np s_rp s_domain
        if grep -q "ssl_preread on" /etc/nginx/nginx.conf 2>/dev/null; then
            s_stream="${green}ON${reset}"
        else
            s_stream="${red}OFF${reset}"
        fi
        s_np=$(vwn_conf_get NGINX_HTTPS_PORT 2>/dev/null || echo "7443")
        s_rp=$(vwn_conf_get REALITY_INTERNAL_PORT 2>/dev/null || jq -r '.inbounds[0].port // "10443"' "$realityConfigPath" 2>/dev/null)
        s_domain=$(vwn_conf_get DOMAIN 2>/dev/null || echo "")
        [ -z "$s_domain" ] && s_domain=$(jq -r '.inbounds[0].streamSettings.wsSettings.host // "—"' "$configPath" 2>/dev/null)

        echo -e "${cyan}================================================================${reset}"
        printf "   ${red}Stream SNI${reset}  %s\n" "$(date +'%d.%m.%Y %H:%M')"
        echo -e "${cyan}----------------------------------------------------------------${reset}"
        echo -e "  Status: $s_stream"
        echo -e "  Domain: ${green}${s_domain:-—}${reset}"
        echo -e "  nginx internal:   ${green}${s_np}${reset}"
        echo -e "  reality internal: ${green}${s_rp}${reset}"
        echo -e "${cyan}----------------------------------------------------------------${reset}"
        echo -e "  ${green}1.${reset} $(msg menu_stream_sni)"
        echo -e "  ${green}2.${reset} $(msg menu_stream_sni_disable)"
        echo -e "  ${green}3.${reset} $(msg stream_sni_reconfigure)"
        echo -e "  ${green}0.${reset} $(msg back)"
        echo -e "${cyan}================================================================${reset}"

        read -rp "$(msg choose)" _sni_choice
        case "$_sni_choice" in
            1) setupStreamSNI ;;
            2) disableStreamSNI ;;
            3)
                local new_np new_rp
                read -rp "Nginx internal port [${s_np}]: " new_np
                read -rp "Reality internal port [${s_rp}]: " new_rp
                [ -z "$new_np" ] && new_np="$s_np"
                [ -z "$new_rp" ] && new_rp="$s_rp"
                if ! [[ "$new_np" =~ ^[0-9]+$ ]] || [ "$new_np" -lt 1 ] || [ "$new_np" -gt 65535 ]; then
                    echo "${red}$(msg invalid_port)${reset}"
                elif ! [[ "$new_rp" =~ ^[0-9]+$ ]] || [ "$new_rp" -lt 1 ] || [ "$new_rp" -gt 65535 ]; then
                    echo "${red}$(msg invalid_port)${reset}"
                else
                    setupStreamSNI "$new_np" "$new_rp"
                fi
                ;;
            0) break ;;
            *) echo -e "${red}$(msg invalid)${reset}" ;;
        esac
        [ "$_sni_choice" = "0" ] && continue
        echo -e "\n${cyan}$(msg press_enter)${reset}"
        read -r
    done
}