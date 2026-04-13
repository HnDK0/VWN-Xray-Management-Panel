#!/bin/bash
# =================================================================
# nginx.sh — Nginx конфиг, CDN, SSL сертификаты
# =================================================================

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

writeNginxConfig() {
    local xrayPort="$1"
    # Внутренний порт nginx HTTPS (7443 когда stream SNI активен, иначе 443)
    local nginx_https_port="${NGINX_HTTPS_PORT:-443}"
    local domain="$2"
    local proxyUrl="$3"

    # Запоминаем ДО перезаписи — был ли активен stream SNI
    local _stream_sni_was_active=false
    local _sni_np _sni_rp _sni_domain
    if grep -q "ssl_preread on" /etc/nginx/nginx.conf 2>/dev/null; then
        _stream_sni_was_active=true
        _sni_np=$(vwn_conf_get NGINX_HTTPS_PORT)
        _sni_rp=$(vwn_conf_get REALITY_INTERNAL_PORT)
        _sni_domain=$(jq -r '.inbounds[0].streamSettings.wsSettings.host // ""' "$configPath" 2>/dev/null)
    fi
    local wsPath="$4"

    local proxy_host
    proxy_host=$(echo "$proxyUrl" | sed 's|https://||;s|http://||;s|/.*||')

    setNginxCert

    cat > /etc/nginx/nginx.conf << NGINXMAIN
user www-data;
worker_processes auto;
worker_rlimit_nofile 65535;
error_log /var/log/nginx/error.log warn;
pid /run/nginx.pid;

events {
    worker_connections 4096;
    multi_accept on;
    use epoll;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;

    # Keepalive — чуть больше чем у Cloudflare (70s), чтобы не рвать соединения
    keepalive_timeout 75s;
    keepalive_requests 10000;

    server_tokens off;
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types text/plain text/css text/xml application/json application/javascript application/xml+rss;
    include /etc/nginx/conf.d/*.conf;
}
NGINXMAIN

    cat > /etc/nginx/conf.d/default.conf << DEFAULTCONF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    return 301 https://\$host\$request_uri;
}

server {
    # Fallback: дропаем всё без совпадения с доменом
    listen ${nginx_https_port} ssl default_server;
    ssl_certificate     /etc/nginx/cert/default.crt;
    ssl_certificate_key /etc/nginx/cert/default.key;
    server_name _;
    return 444;
}
DEFAULTCONF

    cat > "$nginxPath" << EOF
server {
    # Слушает на внутреннем порту — снаружи через stream на 443
    listen ${nginx_https_port} ssl;
    server_name $domain;

    ssl_certificate     /etc/nginx/cert/cert.pem;
    ssl_certificate_key /etc/nginx/cert/cert.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 10m;

    location $wsPath {
        proxy_pass http://127.0.0.1:${xrayPort};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_connect_timeout 10s;
        proxy_request_buffering off;
        proxy_socket_keepalive on;
        access_log             off;
        error_log              /dev/null crit;
    }

    location ~ ^/sub/[A-Za-z0-9_-]+_[A-Za-z0-9]+\.html$ {
        root /usr/local/etc/xray;
        try_files \$uri =404;
        types { text/html html; }
        add_header Cache-Control 'no-cache, no-store, must-revalidate';
    }

    location ~ ^/sub/[A-Za-z0-9_-]+_[A-Za-z0-9]+\.txt$ {
        root /usr/local/etc/xray;
        try_files \$uri =404;
        default_type text/plain;
        add_header Content-Disposition "attachment; filename=\"\$sub_label.txt\"";
        add_header profile-title "\$sub_label";
        add_header Cache-Control 'no-cache, no-store, must-revalidate';
    }

    location / {
        proxy_pass $proxyUrl;
        proxy_http_version 1.1;
        proxy_set_header Host $proxy_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_ssl_server_name on;
        proxy_read_timeout 60s;

        # Скрываем fingerprint-заголовки фейкового сайта
        proxy_hide_header X-Powered-By;
        proxy_hide_header Via;
        proxy_hide_header X-Cache;
        proxy_hide_header Content-Security-Policy;
        proxy_hide_header X-Runtime;
        proxy_hide_header Server;
    }

    access_log /var/log/nginx/access.log;
    error_log  /var/log/nginx/error.log;
}
EOF

    # Генерируем map-блок для имён подписок
    local server_ip country_code
    server_ip=$(getServerIP 2>/dev/null || curl -s --connect-timeout 5 ifconfig.me)
    country_code=$(_getCountryCode "$server_ip")
    cat > /etc/nginx/conf.d/sub_map.conf << MAPEOF
map \$uri \$sub_label {
    ~^/sub/(?<label>[A-Za-z0-9_-]+)_[A-Za-z0-9]+\\.txt\$  "${country_code} VLESS | \$label";
    default                                                    "${country_code} VLESS";
}
MAPEOF
    # Восстанавливаем реальный IP — всегда нужно при Cloudflare
    setupRealIpRestore

    # Если stream SNI был активен до вызова writeNginxConfig — восстанавливаем stream-блок,
    # потому что writeNginxConfig перезаписала nginx.conf только с http{} блоком
    if $_stream_sni_was_active && [ -n "$_sni_np" ] && [ -n "$_sni_rp" ] && [ -n "$_sni_domain" ]; then
        _writeStreamNginxConf "$_sni_domain" "$_sni_np" "$_sni_rp"
    fi
}

# Восстановление реального IP клиента из CF-Connecting-IP.
# Вызывается автоматически при writeNginxConfig.
# nginx.conf уже содержит include conf.d/*.conf — отдельный include не нужен.
setupRealIpRestore() {
    echo -e "${cyan}$(msg cf_ips_setup)${reset}"
    local tmp
    tmp=$(mktemp) || return 1
    trap 'rm -f "$tmp"' RETURN

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

    [ "$ok" -eq 0 ] && { echo "${red}$(msg cf_ips_fail)${reset}"; return 1; }

    printf 'real_ip_header CF-Connecting-IP;\nreal_ip_recursive on;\n' >> "$tmp"

    mkdir -p /etc/nginx/conf.d
    mv -f "$tmp" /etc/nginx/conf.d/real_ip_restore.conf
    echo "${green}$(msg cf_ips_ok)${reset}"
}

# CF Guard — блокировка прямого доступа, только Cloudflare IP.
# Включается вручную через меню (пункт 3→7).
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
                python3 - "$nginxPath" "$wsPath" << 'PYEOF'
import sys, re
path, wspath = sys.argv[1], sys.argv[2]
with open(path, 'r') as f: content = f.read()
cf_check = '    if ($cloudflare_ip != 1) { return 444; }\n\n'
pattern = r'(\s+location ' + re.escape(wspath) + r'\s*\{)'
new_content = re.sub(pattern, cf_check + r'\1', content, count=1)
with open(path, 'w') as f: f.write(new_content)
PYEOF
            fi
        fi
        nginx -t || { echo "${red}$(msg nginx_syntax_err)${reset}"; nginx -t; return 1; }
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

    echo -e "\n${cyan}$(msg ssl_method)${reset}"
    echo "$(msg ssl_method_1)"
    echo "$(msg ssl_method_2)"
    read -rp "$(msg ssl_your_choice)" cert_method

    installPackage "socat" || true


    if [ ! -f ~/.acme.sh/acme.sh ]; then
        curl -fsSL https://get.acme.sh | sh -s email="acme@${userDomain}"
    fi

    # Проверяем что acme.sh установился
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
        export CF_Email CF_Key
        ~/.acme.sh/acme.sh --issue --dns dns_cf -d "$userDomain" --force
    else
        openPort80
        ~/.acme.sh/acme.sh --issue --standalone -d "$userDomain" \
            --pre-hook "/usr/local/bin/vwn open-80" \
            --post-hook "/usr/local/bin/vwn close-80" \
            --force
        closePort80
    fi

    mkdir -p /etc/nginx/cert
    ~/.acme.sh/acme.sh --install-cert -d "$userDomain" \
        --key-file /etc/nginx/cert/cert.key \
        --fullchain-file /etc/nginx/cert/cert.pem \
        --reloadcmd "systemctl reload nginx"

    echo "${green}$(msg ssl_success) $userDomain${reset}"
}

# Добавляет location /sub/ и обновляет sub_map.conf с флагом страны
applyNginxSub() {
    [ ! -f "$nginxPath" ] && return 1

    # Обновляем/создаём sub_map.conf с актуальным кодом страны
    local server_ip country_code
    server_ip=$(getServerIP 2>/dev/null || curl -s --connect-timeout 5 ifconfig.me)
    country_code=$(_getCountryCode "$server_ip")
    cat > /etc/nginx/conf.d/sub_map.conf << MAPEOF
map \$uri \$sub_label {
    ~^/sub/(?<label>[A-Za-z0-9_-]+)_[A-Za-z0-9]+\\.txt\$  "${country_code} VLESS | \$label";
    default                                                    "${country_code} VLESS";
}
MAPEOF

    # Добавляем location /sub/ в xray.conf если его ещё нет
    if ! grep -q 'location ~ \^/sub/' "$nginxPath"; then
        python3 - "$nginxPath" << 'PYEOF'
import sys, re
path = sys.argv[1]
with open(path) as f: c = f.read()
block = (
    "\n    location ~ ^/sub/[A-Za-z0-9_-]+_[A-Za-z0-9]+\\.html$ {\n"
    "        root /usr/local/etc/xray;\n"
    "        try_files $uri =404;\n"
    "        types { text/html html; }\n"
    "        add_header Cache-Control 'no-cache, no-store, must-revalidate';\n"
    "    }\n"
    "\n    location ~ ^/sub/[A-Za-z0-9_-]+_[A-Za-z0-9]+\\.txt$ {\n"
    "        root /usr/local/etc/xray;\n"
    "        try_files $uri =404;\n"
    "        default_type text/plain;\n"
    '        add_header Content-Disposition "attachment; filename=\\"$sub_label.txt\\"";\n'
    '        add_header profile-title "$sub_label";\n'
    "        add_header Cache-Control 'no-cache, no-store, must-revalidate';\n"
    "    }\n"
)
c = re.sub(r'(\n    location / \{)', block + r'\1', c, count=1)
with open(path, 'w') as f: f.write(c)
PYEOF
    fi

    nginx -t && systemctl reload nginx
}
# ============================================================
# BASIC AUTH — защита /sub/ подписок паролем
# ============================================================

# Управление basic auth на /sub/ — вызывается из меню manageWs().
manageSubAuth() {
    echo ""
    echo "${cyan}=== $(msg sub_auth_manage) ===${reset}"

    # Текущий статус — есть ли auth_basic в конфиге
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

# Включает basic auth: создаёт .htpasswd и добавляет директивы в nginx конфиг
_subAuthEnable() {
    _subAuthSetCredentials || return 1

    if ! grep -q "auth_basic" "$nginxPath" 2>/dev/null; then
        python3 - "$nginxPath" << 'AUTHPYEOF'
import sys, re
path = sys.argv[1]
with open(path) as f: c = f.read()
auth = (
    '        auth_basic           "Restricted";\n'
    '        auth_basic_user_file /etc/nginx/conf.d/.htpasswd;\n'
)
c = re.sub(
    r'(location ~ \^/sub/[^\n]+\n(?:(?!location|\}).+\n)*)\s*\}',
    lambda m: m.group(1) + auth + '    }',
    c
)
with open(path, 'w') as f: f.write(c)
AUTHPYEOF
    fi

    nginx -t && systemctl reload nginx
    echo "${green}$(msg sub_auth_enabled): ${cyan}$(vwn_conf_get SUB_AUTH_USER)${reset} / ${cyan}$(vwn_conf_get SUB_AUTH_PASS)${reset}"
    echo "${yellow}$(msg sub_auth_note)${reset}"
}

# Отключает basic auth: убирает директивы из nginx конфига и удаляет .htpasswd
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

# Запрашивает логин/пароль и записывает .htpasswd
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
    elif command -v htpasswd &>/dev/null; then
        htpasswd -cb /etc/nginx/conf.d/.htpasswd "$new_user" "$new_pass"
    else
        installPackage "apache2-utils" &>/dev/null || true
        htpasswd -cb /etc/nginx/conf.d/.htpasswd "$new_user" "$new_pass" || return 1
    fi

    vwn_conf_set SUB_AUTH_USER "$new_user"
    vwn_conf_set SUB_AUTH_PASS "$new_pass"
    echo "${green}$(msg sub_auth_updated): ${cyan}${new_user}${reset} / ${cyan}${new_pass}${reset}"
}


# ============================================================
# STREAM SNI — Reality + Nginx оба на порту 443
# ============================================================

# Включает SNI-мультиплексирование.
# nginx переезжает на внутренний порт, Reality — тоже на внутренний порт,
# снаружи всё слушается на 443 через stream-блок nginx.
#
# Использование: setupStreamSNI [nginx_port] [reality_port]
# По умолчанию:  setupStreamSNI 7443 10443
# Записывает /etc/nginx/nginx.conf со stream{}-блоком для SNI.
# Вызывается только из setupStreamSNI().
_writeStreamNginxConf() {
    local domain="$1"
    local nginx_port="$2"
    local reality_port="$3"

    cat > /etc/nginx/nginx.conf << NGINXSTREAM
user www-data;
worker_processes auto;
worker_rlimit_nofile 65535;
error_log /var/log/nginx/error.log warn;
pid /run/nginx.pid;

events {
    worker_connections 4096;
    multi_accept on;
    use epoll;
}

# ── Stream: SNI-маршрутизация на порту 443 ──────────────────────────────────
# Ваш домен (${domain}) → nginx HTTP (${nginx_port})
# Всё остальное (SNI чужих сайтов для Reality) → xray-reality (${reality_port})
stream {
    map \$ssl_preread_server_name \$upstream_backend {
        ${domain}   127.0.0.1:${nginx_port};
        default     127.0.0.1:${reality_port};
    }
    server {
        listen 443;
        listen [::]:443;
        ssl_preread on;
        proxy_pass \$upstream_backend;
        proxy_connect_timeout 10s;
        proxy_timeout         3600s;
    }
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 75s;
    keepalive_requests 10000;
    server_tokens off;
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types text/plain text/css text/xml application/json application/javascript application/xml+rss;
    include /etc/nginx/conf.d/*.conf;
}
NGINXSTREAM
}

setupStreamSNI() {
    local nginx_port="${1:-7443}"
    local reality_port="${2:-10443}"

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

    # 4. SSL сертификат существует (нужен для nginx HTTPS на внутреннем порту)
    if [ ! -f /etc/nginx/cert/cert.pem ] || [ ! -f /etc/nginx/cert/cert.key ]; then
        echo "${red}$(msg stream_sni_no_ssl)${reset}"
        echo "${yellow}$(msg stream_sni_ssl_hint)${reset}"
        return 1
    fi

    # 5. Reality конфиг существует (иначе смысла нет)
    if [ ! -f "$realityConfigPath" ]; then
        echo "${red}$(msg stream_sni_no_reality)${reset}"
        return 1
    fi

    # 6. nginx собран с модулем stream
    if ! nginx -V 2>&1 | grep -q "with-stream"; then
        echo "${red}$(msg stream_module_missing)${reset}"
        echo "${yellow}$(msg stream_module_hint)${reset}"
        # Предлагаем автоустановку nginx-full (только apt)
        if command -v apt &>/dev/null; then
            echo "${cyan}$(msg stream_module_autoinstall)${reset}"
            read -rp "$(msg yes_no) " _ans
            if [[ "$_ans" == "y" ]]; then
                apt-get install -y nginx-full 2>/dev/null                     && echo "${green}nginx-full installed${reset}"                     || { echo "${red}$(msg stream_module_install_fail)${reset}"; return 1; }
                # Повторная проверка
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

    # 7. Порты не заняты другими процессами (кроме nginx/xray)
    for _p in "$nginx_port" "$reality_port"; do
        local _proc
        _proc=$(ss -tlnp "sport = :${_p}" 2>/dev/null | awk 'NR>1{print $NF}' | grep -v nginx | grep -v xray || true)
        if [ -n "$_proc" ]; then
            echo "${yellow}$(msg stream_sni_port_busy): ${_p} — ${_proc}${reset}"
        fi
    done

    # 8. Stream SNI уже активен?
    if grep -q "ssl_preread on" /etc/nginx/nginx.conf 2>/dev/null; then
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

    vwn_conf_set NGINX_HTTPS_PORT      "$nginx_port"
    vwn_conf_set REALITY_INTERNAL_PORT "$reality_port"

    # Перегенерируем xray.conf (http server) на новый внутренний порт — ДО записи stream-блока
    local xray_port proxy_url ws_path
    xray_port=$(jq -r '.inbounds[0].port // empty' "$configPath" 2>/dev/null)
    proxy_url=$(grep -oP "(?<=proxy_pass )[^;]+" "$nginxPath" 2>/dev/null | tail -1)
    ws_path=$(jq -r '.inbounds[0].streamSettings.wsSettings.path // empty' "$configPath" 2>/dev/null)

    NGINX_HTTPS_PORT="$nginx_port" \
        writeNginxConfig "$xray_port" "$domain" "$proxy_url" "$ws_path"

    # Пишем nginx.conf со stream-блоком — ПОСЛЕ writeNginxConfig, иначе stream затрётся
    _writeStreamNginxConf "$domain" "$nginx_port" "$reality_port"

    # Переключаем Reality на 127.0.0.1:reality_port
    if [ -f "$realityConfigPath" ]; then
        local tmp
        tmp=$(mktemp)
        jq --argjson p "$reality_port" \
           '.inbounds[0].port = $p | .inbounds[0].listen = "127.0.0.1"' \
           "$realityConfigPath" > "$tmp" && mv "$tmp" "$realityConfigPath"
        # Восстанавливаем владельца — xray-reality сервис работает под пользователем xray
        chown xray:xray "$realityConfigPath" 2>/dev/null || true
        chmod 640 "$realityConfigPath" 2>/dev/null || true
        echo "${green}$(msg reality_port_updated): 127.0.0.1:${reality_port}${reset}"
        systemctl restart xray-reality 2>/dev/null || true
    fi

    # UFW: 443 уже открыт при стандартной установке, но убеждаемся
    ufw allow 443/tcp comment 'HTTPS+Reality SNI' &>/dev/null || true
    ufw allow 443/udp comment 'HTTPS+Reality SNI' &>/dev/null || true

    nginx -t || { echo "${red}$(msg nginx_syntax_err)${reset}"; return 1; }
    # stop+start обязателен: reuseport требует полного освобождения сокета
    systemctl stop nginx
    sleep 1
    systemctl start nginx

    # Ждём пока nginx поднимет порт (до 15 секунд)
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

    # Перегенерируем подписки: Reality теперь снаружи на 443
    rebuildAllSubFiles 2>/dev/null || true
}

# Отключает stream SNI — возвращает nginx на прямой listen 443.
# Внутренняя функция — выполняет откат без подтверждения
# Вызывается из disableStreamSNI (интерактив) и removeReality (автомат)
_doDisableStreamSNI() {
    local domain xray_port proxy_url ws_path
    domain=$(vwn_conf_get DOMAIN)
    xray_port=$(jq -r '.inbounds[0].port // empty' "$configPath" 2>/dev/null)
    proxy_url=$(grep -o 'proxy_pass [^;]*' "$nginxPath" 2>/dev/null | tail -1 | awk '{print $2}')
    ws_path=$(jq -r '.inbounds[0].streamSettings.wsSettings.path // empty' "$configPath" 2>/dev/null)

    NGINX_HTTPS_PORT=443 \
        writeNginxConfig "$xray_port" "$domain" "$proxy_url" "$ws_path"

    vwn_conf_del NGINX_HTTPS_PORT
    vwn_conf_del REALITY_INTERNAL_PORT

    # Возвращаем Reality на 0.0.0.0 и его оригинальный порт
    # При setupStreamSNI Reality был переведён на 127.0.0.1:internal_port
    if [ -f "$realityConfigPath" ]; then
        local reality_orig_port
        reality_orig_port=$(jq -r '.inbounds[0].port' "$realityConfigPath" 2>/dev/null)
        jq '.inbounds[0].listen = "0.0.0.0"' \
            "$realityConfigPath" > "${realityConfigPath}.tmp" \
            && mv "${realityConfigPath}.tmp" "$realityConfigPath"
        systemctl restart xray-reality 2>/dev/null || true
    fi

    nginx -t && systemctl reload nginx
    echo "${green}$(msg stream_sni_disabled)${reset}"

    # Перегенерируем подписки: Reality снова на своём прямом порту
    rebuildAllSubFiles 2>/dev/null || true
}

disableStreamSNI() {
    echo "${yellow}$(msg stream_sni_disable_confirm) $(msg yes_no)${reset}"
    read -r confirm
    [[ "$confirm" != "y" ]] && return
    _doDisableStreamSNI
}