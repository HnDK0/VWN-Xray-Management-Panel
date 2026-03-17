#!/bin/bash
# =================================================================
# nginx.sh — Nginx (заглушка), HAProxy (TLS+роутинг), SSL, CF Guard
# =================================================================

# ============================================================
# Nginx — только заглушка на 127.0.0.1:8080
# ============================================================

writeNginxConfig() {
    local domain="$1"
    local proxyUrl="$2"

    local proxy_host
    proxy_host=$(echo "$proxyUrl" | sed 's|https://||;s|http://||;s|/.*||')

    local server_ip country_code
    server_ip=$(getServerIP 2>/dev/null || curl -s --connect-timeout 5 ifconfig.me)
    country_code=$(_getCountryCode "$server_ip")

    mkdir -p /usr/local/etc/xray/sub

    # Основной nginx.conf
    cat > /etc/nginx/nginx.conf << 'NGINXMAIN'
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

    # sub_map и server конфиг в одном файле
    cat > "$nginxPath" << NGINXEOF
map \$uri \$sub_label {
    ~^/sub/(?<label>[A-Za-z0-9_-]+)_[A-Za-z0-9]+\\.txt\$  "${country_code} VLESS | \$label";
    default                                                    "${country_code} VLESS";
}

server {
    listen 127.0.0.1:8080;
    server_name $domain;

    # root указывает на родительскую папку — файлы лежат в sub/
    root /usr/local/etc/xray;

    # ── HTML подписки ──────────────────────────────────────────────
    # Используем root+try_files вместо alias+regex (alias ломает путь)
    location ~ ^/sub/[A-Za-z0-9_-]+_[A-Za-z0-9]+\\.html\$ {
        types { text/html html; }
        add_header Cache-Control 'no-cache, no-store, must-revalidate';
        try_files \$uri =404;
    }

    # ── TXT подписки ───────────────────────────────────────────────
    location ~ ^/sub/[A-Za-z0-9_-]+_[A-Za-z0-9]+\\.txt\$ {
        types { }
        default_type text/plain;
        add_header Content-Disposition "attachment; filename=\"\${sub_label}.txt\"";
        add_header profile-title "\${sub_label}";
        add_header Cache-Control 'no-cache, no-store, must-revalidate';
        try_files \$uri =404;
    }

    # ── Заглушка ───────────────────────────────────────────────────
    location / {
        proxy_pass $proxyUrl;
        proxy_http_version 1.1;
        proxy_set_header Host $proxy_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_ssl_server_name on;
        proxy_read_timeout 60s;
    }

    access_log off;
    error_log  /var/log/nginx/error.log;
}
NGINXEOF
}

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

# ============================================================
# HAProxy — TLS-терминатор + SNI роутинг для Reality
# ============================================================

writeHaproxyConfig() {
    local xrayPort="$1"    # WS inbound port (напр. 16500)
    local domain="$2"      # Домен для TLS (ваш домен)
    local wsPath="$3"      # /abc123
    local realityPort="${4:-8443}"  # публичный порт Reality (отдельный)

    local xhttpPort grpcPort xhttpPath grpcService
    xhttpPort=$(( xrayPort + 1 ))
    grpcPort=$(( xrayPort + 2 ))
    xhttpPath="${wsPath}x"
    grpcService="${wsPath#/}g"

    mkdir -p /etc/haproxy/conf.d

    cat > "$haproxyPath" << EOF
# =================================================================
# HAProxy — VWN TLS-терминатор
# Порт 443: WS + XHTTP + gRPC + заглушка (TLS termination)
# Порт ${realityPort}: Reality (отдельный, xray-reality держит TLS сам)
# Автогенерация: $(date '+%Y-%m-%d %H:%M:%S')
# =================================================================

global
    log /dev/log local0
    log /dev/log local1 notice
    maxconn 50000
    ssl-default-bind-options ssl-min-ver TLSv1.2
    ssl-default-bind-ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384
    tune.ssl.default-dh-param 2048

defaults
    option http-server-close
    timeout connect 5s
    timeout client  50s
    timeout server  50s
    timeout tunnel  1h
    timeout client-fin 1s
    timeout server-fin 1s

# ── Порт 443: TLS termination → xray inbound'ы + nginx заглушка ───
frontend https
    bind :::443 v4v6 ssl crt ${haproxyCert} alpn h2,http/1.1
    mode http

    # Восстановление реального IP из Cloudflare
    http-request set-header X-Real-IP %[req.hdr(CF-Connecting-IP)] if { req.hdr(CF-Connecting-IP) -m found }
    http-request set-header X-Real-IP %[src] unless { req.hdr(CF-Connecting-IP) -m found }

    # Роутинг по path
    # Важен порядок: /sub/, gRPC и XHTTP — до WS (ws path является префиксом xhttp/grpc путей)
    acl is_sub   path_beg /sub/
    acl is_grpc  path_beg /${grpcService}
    acl is_xhttp path_beg ${xhttpPath}
    acl is_ws    path_beg ${wsPath}

    use_backend nginx_sub  if is_sub
    use_backend xray_grpc  if is_grpc
    use_backend xray_xhttp if is_xhttp
    use_backend xray_ws    if is_ws
    default_backend nginx_stub

# ── Backends ───────────────────────────────────────────────────────

backend xray_ws
    mode http
    server xray 127.0.0.1:${xrayPort} check

backend xray_xhttp
    mode http
    server xray 127.0.0.1:${xhttpPort} check proto h2

backend xray_grpc
    mode http
    server xray 127.0.0.1:${grpcPort} check proto h2

backend nginx_sub
    mode http
    server nginx 127.0.0.1:8080 check

backend nginx_stub
    mode http
    server nginx 127.0.0.1:8080 check
EOF

    echo "${green}$(msg haproxy_config_ok)${reset}"
}

# Обновить Reality-секцию в HAProxy (не нужна — Reality на отдельном порту)
# Функция оставлена для совместимости, ничего не делает
_haproxyUpdateReality() {
    local realityDest="$1"
    # Reality теперь на отдельном порту, HAProxy не управляет им
    # UFW правило для Reality порта обновляется в reality.sh
    return 0
}


# ============================================================
# SSL сертификаты (acme.sh)
# ============================================================

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

    # Устанавливаем сертификат в HAProxy формате
    # HAProxy нужен один файл: fullchain + key
    mkdir -p "$haproxyCertDir"
    ~/.acme.sh/acme.sh --install-cert -d "$userDomain" \
        --fullchain-file "${haproxyCertDir}/cert.pem" \
        --key-file       "${haproxyCertDir}/cert.key" \
        --reloadcmd      "cat ${haproxyCertDir}/cert.pem ${haproxyCertDir}/cert.key > ${haproxyCert} && chmod 600 ${haproxyCert} && systemctl reload haproxy"

    # Собираем server.pem сразу после установки
    _buildHaproxyCert
    chmod 700 "$haproxyCertDir"
    chmod 600 "${haproxyCertDir}/cert.key" "${haproxyCert}"

    echo "${green}$(msg ssl_success) $userDomain${reset}"
}

# Собирает server.pem из fullchain + key (нужен HAProxy)
_buildHaproxyCert() {
    if [ -f "${haproxyCertDir}/cert.pem" ] && [ -f "${haproxyCertDir}/cert.key" ]; then
        cat "${haproxyCertDir}/cert.pem" "${haproxyCertDir}/cert.key" > "$haproxyCert"
        chmod 600 "$haproxyCert"
    fi
}

# ============================================================
# CF Guard — через HAProxy ACL (только Cloudflare IP)
# ============================================================

# Файл с CF IP для HAProxy
CF_GUARD_FILE="/etc/haproxy/conf.d/cf_guard.cfg"

setupRealIpRestore() {
    # В HAProxy real IP восстанавливается через http-request set-header
    # который уже прописан в writeHaproxyConfig.
    # Эта функция обновляет список CF IP в отдельном файле для CF Guard.
    echo -e "${cyan}$(msg cf_ips_setup)${reset}"
    mkdir -p /etc/haproxy/conf.d

    local tmp
    tmp=$(mktemp) || return 1
    trap 'rm -f "$tmp"' RETURN

    local ok=0
    for t in v4 v6; do
        local result
        result=$(curl -fsSL --connect-timeout 10 "https://www.cloudflare.com/ips-$t" 2>/dev/null) || continue
        while IFS= read -r ip; do
            [ -z "$ip" ] && continue
            echo "$ip" >> "$tmp"
            ok=1
        done < <(echo "$result" | grep -E '^[0-9a-fA-F:.]+(/[0-9]+)?$')
    done

    [ "$ok" -eq 0 ] && { echo "${red}$(msg cf_ips_fail)${reset}"; return 1; }

    # Сохраняем список IP для использования в CF Guard
    mv -f "$tmp" /etc/haproxy/cf_ips.txt
    echo "${green}$(msg cf_ips_ok)${reset}"
}

toggleCfGuard() {
    if [ -f "$CF_GUARD_FILE" ]; then
        echo -e "${yellow}$(msg cfguard_disable_confirm) $(msg yes_no)${reset}"
        read -r confirm
        if [[ "$confirm" == "y" ]]; then
            rm -f "$CF_GUARD_FILE"
            # Убираем ACL правило из haproxy.cfg
            if [ -f "$haproxyPath" ]; then
                sed -i '/# CF Guard: блокируем не-Cloudflare IP/d' "$haproxyPath"
                sed -i '/acl cf_guard src -f \/etc\/haproxy\/cf_ips\.txt/d' "$haproxyPath"
                sed -i '/http-request deny if !cf_guard/d' "$haproxyPath"
            fi
            haproxy -c -f "$haproxyPath" &>/dev/null && systemctl reload haproxy
            echo "${green}$(msg cfguard_disabled)${reset}"
        fi
    else
        # Обновляем список IP и создаём ACL файл
        setupRealIpRestore || return 1

        if [ ! -f /etc/haproxy/cf_ips.txt ]; then
            echo "${red}$(msg cf_ips_fail)${reset}"; return 1
        fi

        # Генерируем HAProxy ACL конфиг для CF Guard
        # Встраивается через include в основной конфиг
        {
            echo "# CF Guard — allow only Cloudflare IPs"
            echo "# Auto-generated: $(date '+%Y-%m-%d %H:%M:%S')"
        } > "$CF_GUARD_FILE"

        # Добавляем правило в frontend https если его нет
        if [ -f "$haproxyPath" ] && ! grep -q "cf_guard" "$haproxyPath"; then
            # Вставляем после строки bind :::443
            local cf_rule="    # CF Guard: блокируем не-Cloudflare IP\n    acl cf_guard src -f /etc/haproxy/cf_ips.txt\n    http-request deny if !cf_guard"
            sed -i "/bind :::443/a\\${cf_rule}" "$haproxyPath"
        fi

        haproxy -c -f "$haproxyPath" &>/dev/null \
            && { systemctl reload haproxy; echo "${green}$(msg cfguard_enabled)${reset}"; } \
            || { echo "${red}$(msg nginx_syntax_err)${reset}"; return 1; }
    fi
}

# ============================================================
# applyNginxSub — nginx конфиг теперь статический,
# /sub/ location прописан в writeNginxConfig изначально.
# Функция оставлена для совместимости, делает только reload.
# ============================================================

applyNginxSub() {
    # sub_map теперь встроен в writeNginxConfig — отдельный файл не нужен.
    # Просто проверяем и перезапускаем nginx.
    [ ! -f "$nginxPath" ] && return 1
    nginx -t &>/dev/null && systemctl reload nginx || true
}

