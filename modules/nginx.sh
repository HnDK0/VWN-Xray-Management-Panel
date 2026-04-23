#!/bin/bash
# =================================================================
# nginx.sh — Nginx конфиг, CDN, SSL сертификаты
#
# Режим: base — WS+TLS на 443 (Nginx напрямую с SSL)
# XHTTP inbound слушает локально, nginx проксирует по пути
# =================================================================

VWN_CONFIG_DIR="${VWN_CONFIG_DIR:-/usr/local/lib/vwn/config}"

_getCountryCode() {
    local ip="$1"
    local code
    code=$(curl -s --connect-timeout 5 "http://ip-api.com/line/${ip}?fields=countryCode" | tr -d '[:space:]')
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
            -subj "/CN=localhost"
    fi
}

# ── Режим BASE: WS+TLS на 443 напрямую ──────────────────────────


writeNginxConfigBase() {
    local xrayPort="$1" domain="$2" proxyUrl="$3" wsPath="$4"
    local proxy_host=""
    proxy_host=$(echo "$proxyUrl" | sed 's|https://||;s|http://||;s|/.*||')

    setNginxCert

    # nginx.conf — общая часть
    cp "$VWN_CONFIG_DIR/nginx_main.conf" /etc/nginx/nginx.conf

    # default.conf
    cp "$VWN_CONFIG_DIR/nginx_default.conf" /etc/nginx/conf.d/default.conf

    # Собираем XHTTP location-блок если XHTTP установлен
    local xhttp_location=""
    local xhttp_path xhttp_lport
    xhttp_path=$(vwn_conf_get XHTTP_PATH  || true)
    xhttp_lport=$(vwn_conf_get XHTTP_LPORT || true)
    if [ -n "$xhttp_path" ] && [ -n "$xhttp_lport" ] && [ -f "$xhttpConfigPath" ]; then
        xhttp_location=$(_buildXhttpLocationBlock "$xhttp_path" "$xhttp_lport")
    fi

    # xray.conf — WS server block
    render_config "$VWN_CONFIG_DIR/nginx_base.conf" "$nginxPath" \
        DOMAIN         "$domain"         \
        XRAY_PORT      "$xrayPort"       \
        WS_PATH        "$wsPath"         \
        PROXY_URL      "$proxyUrl"       \
        PROXY_HOST     "$proxy_host"     \
        XHTTP_LOCATION "$xhttp_location"

    vwn_conf_set STUB_URL   "$proxyUrl"
    vwn_conf_set NGINX_MODE "base"
    vwn_conf_set DOMAIN     "$domain"

    setupRealIpRestore
    _writeSubMapConf

    # Восстанавливаем privacy после перезаписи nginx-конфига
    _privacyIsEnabled && _nginxDisableAccessLog || true
}

# ── XHTTP: генератор location-блока ──────────────────────────────
# Использование: _buildXhttpLocationBlock "/path" "local_port"
# Выводит готовый nginx location-блок для подстановки в шаблон.
# Использует proxy_pass (HTTP/1.1 chunked) — не grpc_pass,
# Оптимизировано под режим auto: буферизация полностью отключена.
_buildXhttpLocationBlock() {
    local xhttp_path="$1" xhttp_lport="$2"
    cat << NGINX_EOF
    # xray-xhttp (auto)
    location ${xhttp_path} {
        proxy_pass              http://127.0.0.1:${xhttp_lport};
        proxy_http_version      1.1;

        proxy_set_header        Host \$host;
        proxy_set_header        X-Real-IP \$remote_addr;
        proxy_set_header        X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header        X-Forwarded-Proto \$scheme;

        # Отключаем буферизацию — критично для auto:
        # каждый пакет должен уходить немедленно, без накопления.
        proxy_buffering         off;
        proxy_request_buffering off;
        proxy_cache             off;

        # Без ограничения размера тела — XHTTP гоняет поток данных,
        # client_max_body_size обрежет соединение на больших объёмах.
        client_max_body_size    0;

        proxy_connect_timeout   10s;
        proxy_read_timeout      300s;
        proxy_send_timeout      300s;
        proxy_socket_keepalive  on;

        access_log  off;
        error_log   /dev/null crit;
    }
NGINX_EOF
}

# ── Утилиты ──────────────────────────────────────────────────────────────────

_writeSubMapConf() {
    local server_ip country_code
    server_ip=$(getServerIP || curl -s --connect-timeout 5 ifconfig.me)
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
        result=$(curl -fsSL --connect-timeout 10 "https://www.cloudflare.com/ips-$t") || continue
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
    grep -q "auth_basic" "$nginxPath" && auth_active=true
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
    if ! grep -q "auth_basic" "$nginxPath"; then
        sed -i '/location ~ \^\/sub\//,/}/ { /}/i\        auth_basic           "Restricted";\n        auth_basic_user_file /etc/nginx/conf.d/.htpasswd;
}' "$nginxPath" || true
    fi
    nginx -t && systemctl reload nginx
    echo "${green}$(msg sub_auth_enabled): ${cyan}$(vwn_conf_get SUB_AUTH_USER)${reset} / ${cyan}$(vwn_conf_get SUB_AUTH_PASS)${reset}"
}

_subAuthDisable() {
    echo "${yellow}$(msg sub_auth_disable_confirm) $(msg yes_no)${reset}"
    read -r confirm
    [[ "$confirm" != "y" ]] && return
    sed -i '/auth_basic/d' "$nginxPath" || true
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
" "$new_user" "$new_pass")
    if [ -n "$hashed" ]; then
        echo "$hashed" > /etc/nginx/conf.d/.htpasswd
        chmod 640 /etc/nginx/conf.d/.htpasswd
        chown root:www-data /etc/nginx/conf.d/.htpasswd || true
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
        result=$(curl -fsSL --connect-timeout 10 "https://www.cloudflare.com/ips-$t") || continue
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
            sed -i '/cloudflare_ip.*!=.*1/d' "$nginxPath" || true
            nginx -t && systemctl reload nginx
            echo "${green}$(msg cfguard_disabled)${reset}"
        fi
    else
        _fetchCfGuardIPs || return 1
        local wsPath
        wsPath=$(jq -r ".inbounds[0].streamSettings.wsSettings.path" "$configPath")
        if [ -n "$wsPath" ] && [ "$wsPath" != "null" ]; then
            if ! grep -q "cloudflare_ip" "$nginxPath"; then
                sed -i "s/\(\s*location ${wsPath//\//\\/} {)/    if (\$cloudflare_ip != 1) { return 444; }\n\n\1/" "$nginxPath" || true
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
        expire_date=$(openssl x509 -enddate -noout -in /etc/nginx/cert/cert.pem | cut -d= -f2)
        expire_epoch=$(date -d "$expire_date" +%s)
        now_epoch=$(date +%s)
        days_left=$(( (expire_epoch - now_epoch) / 86400 ))
        
        # Домен в сертификате
        domain_in_cert=$(openssl x509 -noout -text -in /etc/nginx/cert/cert.pem | grep -oP '(?<=DNS:)[^,\s]+' | head -1)
        
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
        --ca-file /etc/nginx/cert/chain.pem \
        --reloadcmd "systemctl reload nginx"

    # Даём пользователю xray доступ к cert.key
    chmod 640 /etc/nginx/cert/cert.key
    chown root:xray /etc/nginx/cert/cert.key || true

    echo "${green}$(msg ssl_success) $userDomain${reset}"
}

applyNginxSub() {
    [ ! -f "$nginxPath" ] && return 1
    _writeSubMapConf
    if ! grep -q 'location ~ \^/sub/' "$nginxPath"; then
        sed -i '/location \/ {/i\    location ~ ^/sub/[A-Za-z0-9_-]+_[A-Za-z0-9]+\\.html$ {\n        root /usr/local/etc/xray;\n        try_files $uri =404;\n        types { text/html html; }\n        add_header Cache-Control '\''no-cache, no-store, must-revalidate'\'';\n    }\n\n    location ~ ^/sub/[A-Za-z0-9_-]+_[A-Za-z0-9]+\\.txt$ {\n        root /usr/local/etc/xray;\n        try_files $uri =404;\n        default_type text/plain;\n        add_header Content-Disposition "attachment; filename=\\"$sub_label.txt\\"";\n        add_header profile-title "$sub_label";\n        add_header Cache-Control '\''no-cache, no-store, must-revalidate'\'';\n    }\n' "$nginxPath" || true
    fi
    nginx -t && systemctl reload nginx
}

# Public alias for _manageSubAuth — called from menu.sh
manageSubAuth() { _manageSubAuth "$@"; }
# Установка nginx stable 1.30+ с nginx.org
# Стратегия: сначала пробуем apt (nginx.org repo), если там < 1.30 — собираем из исходников.
# Системный nginx из Ubuntu-репо никогда не используется.
_installNginxStable() {
    local NGINX_TARGET_VER="1.30.0"
    local NGINX_SRC_URL="https://nginx.org/download/nginx-${NGINX_TARGET_VER}.tar.gz"

    local cur_ver cur_minor cur_patch
    cur_ver=$(nginx -v 2>&1 | grep -oP '\d+\.\d+\.\d+' | head -1)
    cur_minor=$(echo "$cur_ver" | cut -d. -f2)
    cur_patch=$(echo "$cur_ver" | cut -d. -f3)
    # Проверяем: уже установлен >= 1.30.0?
    if [ -n "$cur_ver" ]; then
        if [ "${cur_minor:-0}" -gt 30 ] || \
           { [ "${cur_minor:-0}" -eq 30 ] && [ "${cur_patch:-0}" -ge 0 ]; }; then
            echo "info: nginx $cur_ver already sufficient (>= 1.30.0), skipping."
            return 0
        fi
    fi

    echo -e "${cyan}nginx ${cur_ver:-not installed} — installing stable 1.30+ from nginx.org...${reset}"

    # ── Шаг 1: пробуем apt из официального репо nginx.org ────────────────────
    if command -v apt-get > /dev/null 2>&1; then
        installPackage gnupg2 || true
        rm -f /usr/share/keyrings/nginx-archive-keyring.gpg
        curl -fsSL https://nginx.org/keys/nginx_signing.key \
            | gpg --dearmor -o /usr/share/keyrings/nginx-archive-keyring.gpg
        local codename
        codename=$(lsb_release -cs 2>/dev/null || (. /etc/os-release && echo "${VERSION_CODENAME:-}"))
        echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] https://nginx.org/packages/ubuntu ${codename} nginx" \
            > /etc/apt/sources.list.d/nginx-stable.list
        printf 'Package: *\nPin: origin nginx.org\nPin: release o=nginx\nPin-Priority: 900\n' \
            > /etc/apt/preferences.d/99nginx
        local _update_out
        _update_out=$(apt-get update 2>&1)
        if echo "$_update_out" | grep -q "nginx.org.*Release.*does not have"; then
            echo -e "${yellow}nginx.org repo недоступен для ${codename}, переходим к сборке из исходников...${reset}"
        else
            apt-get remove -y nginx nginx-common nginx-core 2>/dev/null || true
            local _apt_rc=0
            apt-get install -y nginx || _apt_rc=$?
            if [ "$_apt_rc" -eq 0 ]; then
                local apt_ver apt_minor
                apt_ver=$(nginx -v 2>&1 | grep -oP '\d+\.\d+\.\d+' | head -1)
                apt_minor=$(echo "$apt_ver" | cut -d. -f2)
                if [ "${apt_minor:-0}" -ge 30 ]; then
                    echo -e "${green}nginx $apt_ver установлен через apt из nginx.org.${reset}"
                    return 0
                fi
                echo -e "${yellow}apt дал nginx $apt_ver (< 1.30.0) — собираем из исходников...${reset}"
                apt-get remove -y nginx nginx-common nginx-core 2>/dev/null || true
            else
                echo -e "${yellow}apt install завершился с ошибкой (rc=${_apt_rc}) — собираем из исходников...${reset}"
                apt-get remove -y nginx nginx-common nginx-core 2>/dev/null || true
            fi
        fi
    elif command -v dnf > /dev/null 2>&1 || command -v yum > /dev/null 2>&1; then
        cat > /etc/yum.repos.d/nginx-stable.repo << 'YUMEOF'
[nginx-stable]
name=nginx stable repo
baseurl=https://nginx.org/packages/centos/$releasever/$basearch/
gpgcheck=1
enabled=1
gpgkey=https://nginx.org/keys/nginx_signing.key
module_hotfixes=true
YUMEOF
        local _yum_rc=0
        ${PACKAGE_MANAGEMENT_INSTALL} nginx || _yum_rc=$?
        if [ "$_yum_rc" -eq 0 ]; then
            local apt_ver apt_minor
            apt_ver=$(nginx -v 2>&1 | grep -oP '\d+\.\d+\.\d+' | head -1)
            apt_minor=$(echo "$apt_ver" | cut -d. -f2)
            if [ "${apt_minor:-0}" -ge 30 ]; then
                echo -e "${green}nginx $apt_ver установлен через пакетный менеджер.${reset}"
                return 0
            fi
        fi
    fi

    # ── Шаг 2: сборка из исходников nginx-1.30.0 ─────────────────────────────
    echo -e "${cyan}Сборка nginx ${NGINX_TARGET_VER} из исходников...${reset}"

    # Зависимости для сборки
    apt-get install -y --no-install-recommends \
        build-essential libpcre2-dev zlib1g-dev libssl-dev libgd-dev \
        libxslt1-dev libgeoip-dev libperl-dev || true

    local build_dir
    build_dir=$(mktemp -d)
    curl -fsSL "$NGINX_SRC_URL" | tar -xz -C "$build_dir" --strip-components=1

    (
        cd "$build_dir"
        ./configure \
            --prefix=/etc/nginx \
            --sbin-path=/usr/sbin/nginx \
            --modules-path=/usr/lib/nginx/modules \
            --conf-path=/etc/nginx/nginx.conf \
            --error-log-path=/var/log/nginx/error.log \
            --http-log-path=/var/log/nginx/access.log \
            --pid-path=/run/nginx.pid \
            --lock-path=/run/nginx.lock \
            --http-client-body-temp-path=/var/cache/nginx/client_temp \
            --http-proxy-temp-path=/var/cache/nginx/proxy_temp \
            --http-fastcgi-temp-path=/var/cache/nginx/fastcgi_temp \
            --http-uwsgi-temp-path=/var/cache/nginx/uwsgi_temp \
            --http-scgi-temp-path=/var/cache/nginx/scgi_temp \
            --user=www-data \
            --group=www-data \
            --with-compat \
            --with-threads \
            --with-http_ssl_module \
            --with-http_v2_module \
            --with-http_realip_module \
            --with-http_addition_module \
            --with-http_xslt_module=dynamic \
            --with-http_image_filter_module=dynamic \
            --with-http_geoip_module=dynamic \
            --with-http_sub_module \
            --with-http_dav_module \
            --with-http_gunzip_module \
            --with-http_gzip_static_module \
            --with-http_auth_request_module \
            --with-http_random_index_module \
            --with-http_secure_link_module \
            --with-http_slice_module \
            --with-http_stub_status_module \
            --with-http_perl_module=dynamic \
            --with-mail=dynamic \
            --with-mail_ssl_module \
            --with-stream \
            --with-stream_ssl_module \
            --with-stream_realip_module \
            --with-stream_geoip_module=dynamic \
            --with-stream_ssl_preread_module \
            --with-pcre-jit \
            --with-http_grpc_module
        make -j"$(nproc)"
        make install
    )

    rm -rf "$build_dir"

    # Создаём нужные директории
    mkdir -p /var/cache/nginx/client_temp \
             /var/cache/nginx/proxy_temp \
             /var/cache/nginx/fastcgi_temp \
             /var/cache/nginx/uwsgi_temp \
             /var/cache/nginx/scgi_temp
    chown -R www-data:www-data /var/cache/nginx || true

    # Финальная проверка
    local new_ver new_minor
    new_ver=$(nginx -v 2>&1 | grep -oP '\d+\.\d+\.\d+' | head -1)
    new_minor=$(echo "$new_ver" | cut -d. -f2)
    if [ -z "$new_ver" ]; then
        echo -e "${red}ОШИБКА: nginx не найден после сборки.${reset}" >&2
        return 1
    fi
    if [ "${new_minor:-0}" -lt 30 ]; then
        echo -e "${red}ОШИБКА: собрана версия $new_ver (< 1.30.0).${reset}" >&2
        return 1
    fi
    echo -e "${green}nginx $new_ver собран и установлен из исходников.${reset}"
    return 0
}

