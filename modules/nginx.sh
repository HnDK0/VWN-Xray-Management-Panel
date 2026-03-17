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
    local domain="$2"
    local proxyUrl="$3"
    local wsPath="$4"

    local proxy_host
    proxy_host=$(echo "$proxyUrl" | sed 's|https://||;s|http://||;s|/.*||')

    # Создаём /dev/shm для unix sockets (tmpfs в RAM, пересоздаётся при перезагрузке)
    mkdir -p /dev/shm

    local xhttpPort grpcPort xhttpPath grpcService
    xhttpPort=$(( xrayPort + 1 ))
    grpcPort=$(( xrayPort + 2 ))
    xhttpPath="${wsPath}x"
    grpcService="${wsPath#/}g"

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

    # HTTP/2 keepalive — для gRPC через nginx_h2.sock
    http2_recv_timeout 300s;
    http2_idle_timeout 300s;

    server_tokens off;
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types text/plain text/css text/xml application/json application/javascript application/xml+rss;
    include /etc/nginx/conf.d/*.conf;
}
NGINXMAIN

    # default.conf — отклоняем прямые TCP подключения на 80 (xray держит 443)
    cat > /etc/nginx/conf.d/default.conf << 'DEFAULTCONF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    return 444;
}
DEFAULTCONF

    # Основной конфиг: два server блока на unix sockets
    # nginx.sock     — HTTP/1.1 — для WS и XHTTP (от xray fallback default)
    # nginx_h2.sock  — HTTP/2   — для gRPC       (от xray fallback alpn=h2)
    # TLS терминирует xray, поэтому здесь нет ssl директив
    # Реальный IP клиента восстанавливается через proxy_protocol (xver=2 в fallback)
    cat > "$nginxPath" << EOF
# ── HTTP/1.1 socket — WS + XHTTP ──────────────────────────────────
server {
    listen unix:/dev/shm/nginx.sock proxy_protocol;
    server_name $domain;

    set_real_ip_from unix:;
    real_ip_header proxy_protocol;

    proxy_buffering off;
    proxy_cache off;
    proxy_buffer_size 4k;

    # ── WebSocket ──────────────────────────────────────────────────
    location $wsPath {
        proxy_pass http://127.0.0.1:$xrayPort;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_connect_timeout 10s;
        proxy_request_buffering off;
        proxy_socket_keepalive on;
    }

    # ── XHTTP ──────────────────────────────────────────────────────
    location $xhttpPath {
        proxy_pass http://127.0.0.1:$xhttpPort;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_pass_header Content-Type;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_connect_timeout 10s;
        proxy_request_buffering off;
        proxy_buffering off;
        client_body_buffer_size 1m;
        client_body_timeout 1h;
        client_max_body_size 0;
    }

    # ── Подписки ───────────────────────────────────────────────────
    location ~ ^/sub/.*\\.html\$ {
        alias /usr/local/etc/xray/sub/;
        types { text/html html; }
        add_header Cache-Control 'no-cache, no-store, must-revalidate';
    }

    location /sub/ {
        alias /usr/local/etc/xray/sub/;
        types { text/plain txt; }
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
        proxy_ssl_server_name on;
        proxy_read_timeout 60s;
    }

    access_log /var/log/nginx/access.log;
    error_log  /var/log/nginx/error.log;
}

# ── HTTP/2 socket — gRPC ───────────────────────────────────────────
server {
    listen unix:/dev/shm/nginx_h2.sock http2 proxy_protocol;
    server_name $domain;

    set_real_ip_from unix:;
    real_ip_header proxy_protocol;

    # ── gRPC ───────────────────────────────────────────────────────
    location /$grpcService {
        grpc_pass grpc://127.0.0.1:$grpcPort;
        grpc_read_timeout 1h;
        grpc_send_timeout 1h;
        grpc_socket_keepalive on;
        grpc_set_header Host \$host;
        grpc_set_header X-Real-IP \$remote_addr;
        grpc_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }

    # ── Заглушка (браузер с h2) ────────────────────────────────────
    location / {
        proxy_pass $proxyUrl;
        proxy_http_version 1.1;
        proxy_set_header Host $proxy_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_ssl_server_name on;
        proxy_read_timeout 60s;
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
    # Real IP восстанавливается через proxy_protocol (xver=2) от xray fallback.
    # setupRealIpRestore здесь не нужен — nginx не на TCP порту.
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
        local wsPath xhttpPath grpcService
        wsPath=$(jq -r '.inbounds[] | select(.tag=="ws-inbound") | .streamSettings.wsSettings.path // empty' "$configPath" 2>/dev/null | head -1)
        [ -z "$wsPath" ] && wsPath=$(jq -r '.inbounds[0].streamSettings.wsSettings.path // ""' "$configPath" 2>/dev/null)
        xhttpPath=$(grep '^XHTTP_PATH=' /usr/local/etc/xray/vwn.conf 2>/dev/null | cut -d= -f2-)
        grpcService=$(grep '^GRPC_SERVICE=' /usr/local/etc/xray/vwn.conf 2>/dev/null | cut -d= -f2-)
        if [ -n "$wsPath" ] && [ "$wsPath" != "null" ]; then
            if ! grep -q "cloudflare_ip" "$nginxPath" 2>/dev/null; then
                python3 - "$nginxPath" "$wsPath" "$xhttpPath" "$grpcService" << 'PYEOF'
import sys, re
path, wspath, xhttppath, grpcsvc = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
with open(path, 'r') as f: content = f.read()
cf_check = '    if ($cloudflare_ip != 1) { return 444; }\n\n'
for loc in filter(None, [wspath, xhttppath, '/' + grpcsvc if grpcsvc else None]):
    pattern = r'(\s+location ' + re.escape(loc) + r'\s*\{)'
    content = re.sub(pattern, cf_check + r'\1', content, count=1)
with open(path, 'w') as f: f.write(content)
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
        --reloadcmd "systemctl restart xray"

    echo "${green}$(msg ssl_success) $userDomain${reset}"
}

# Добавляет location /sub/ в первый server блок (nginx.sock — HTTP/1.1) если ещё нет
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

    # Добавляем /sub/ locations если ещё нет (для старых конфигов)
    if ! grep -q 'location /sub/' "$nginxPath"; then
        python3 - "$nginxPath" << 'PYEOF'
import sys, re
path = sys.argv[1]
with open(path) as f: c = f.read()
# HTML location (без Content-Disposition)
html_block = (
    "\n    location ~ ^/sub/.*\\.html$ {\n"
    "        alias /usr/local/etc/xray/sub/;\n"
    "        types { text/html html; }\n"
    "        add_header Cache-Control 'no-cache, no-store, must-revalidate';\n"
    "    }\n"
)
# TXT location (со скачиванием)
txt_block = (
    "\n    location /sub/ {\n"
    "        alias /usr/local/etc/xray/sub/;\n"
    "        types { text/plain txt; }\n"
    "        default_type text/plain;\n"
    '        add_header Content-Disposition "attachment; filename=\\"$sub_label.txt\\"";\n'
    '        add_header profile-title "$sub_label";\n'
    "        add_header Cache-Control 'no-cache, no-store, must-revalidate';\n"
    "    }\n"
)
# Вставляем перед location / в первом server блоке
c = re.sub(r'(\n    location / \{)', html_block + txt_block + r'\1', c, count=1)
with open(path, 'w') as f: f.write(c)
PYEOF
    fi

    nginx -t && systemctl reload nginx
}
