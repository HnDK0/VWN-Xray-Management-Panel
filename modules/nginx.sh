#!/bin/bash
# =================================================================
# nginx.sh — Nginx: TLS termination + gRPC/XHTTP/подписки/заглушка
# Архитектура:
#   Client:443 → Nginx (TLS, http2 on)
#     ├── /$grpcService   → grpc_pass → xray grpc-inbound (plain)
#     ├── /$xhttpPath/    → grpc_pass → xray xhttp-inbound (stream-one)
#     ├── /sub/           → файлы подписок
#     └── /               → proxy_pass → заглушка
#   Client:$realityPort   → xray-reality (xray держит TLS сам)
# =================================================================

writeNginxConfig() {
    local domain="$1"
    local proxyUrl="$2"
    local xhttpPort="$3"
    local grpcPort="$4"
    local xhttpPath="$5"    # без leading slash
    local grpcService="$6"  # без leading slash

    local proxy_host
    proxy_host=$(echo "$proxyUrl" | sed 's|https://||;s|http://||;s|/.*||')

    local certFile="/etc/nginx/cert/cert.pem"
    local keyFile="/etc/nginx/cert/cert.key"

    local server_ip country_code
    server_ip=$(getServerIP 2>/dev/null || curl -s --connect-timeout 5 ifconfig.me)
    country_code=$(_getCountryCode "$server_ip")

    mkdir -p /usr/local/etc/xray/sub /etc/nginx/cert

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
    server_tokens off;
    gzip on;
    gzip_vary on;
    gzip_types text/plain text/css application/json application/javascript text/xml;
    include /etc/nginx/conf.d/*.conf;
}
NGINXMAIN

    cat > "$nginxPath" << NGINXEOF
map \$uri \$sub_label {
    ~^/sub/(?<label>[A-Za-z0-9_-]+)_[A-Za-z0-9]+\\.txt\$  "${country_code} VLESS | \$label";
    default                                                    "${country_code} VLESS";
}

server {
    listen 80;
    listen [::]:80;
    server_name $domain;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl so_keepalive=on;
    listen [::]:443 ssl so_keepalive=on;
    http2 on;
    server_name $domain;

    ssl_certificate     $certFile;
    ssl_certificate_key $keyFile;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_prefer_server_ciphers off;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    client_header_timeout 1w;
    keepalive_timeout     30m;

    # ── gRPC inbound ───────────────────────────────────────────────
    location /$grpcService {
        if (\$content_type !~ "^application/grpc") {
            return 404;
        }
        client_max_body_size    0;
        client_body_buffer_size 512k;
        client_body_timeout     1w;
        grpc_read_timeout       1w;
        grpc_send_timeout       1w;
        grpc_set_header         X-Real-IP \$remote_addr;
        grpc_set_header         Host \$host;
        grpc_pass               grpc://127.0.0.1:$grpcPort;
    }

    # ── XHTTP inbound (stream-one, trailing slash обязателен) ───────
    location /${xhttpPath}/ {
        client_max_body_size 0;
        client_body_timeout  1w;
        grpc_read_timeout    315s;
        grpc_send_timeout    5m;
        grpc_set_header      X-Real-IP \$remote_addr;
        grpc_set_header      Host \$host;
        grpc_pass            grpc://127.0.0.1:$xhttpPort;
    }

    # ── Подписки ───────────────────────────────────────────────────
    root /usr/local/etc/xray;

    location ~ ^/sub/[A-Za-z0-9_-]+_[A-Za-z0-9]+\\.html\$ {
        types { text/html html; }
        add_header Cache-Control 'no-cache, no-store, must-revalidate';
        try_files \$uri =404;
    }

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
        proxy_pass            $proxyUrl;
        proxy_http_version    1.1;
        proxy_set_header      Host $proxy_host;
        proxy_set_header      X-Real-IP \$remote_addr;
        proxy_set_header      X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_ssl_server_name on;
        proxy_read_timeout    60s;
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
    [[ "$code" =~ ^[A-Z]{2}$ ]] && echo "[$code]" || echo "[??]"
}

# ============================================================
# SSL сертификаты (acme.sh) — сертификат в /etc/nginx/cert/
# ============================================================

openPort80() {
    ufw status | grep -q inactive && return
    ufw allow from any to any port 80 proto tcp comment 'ACME temp'
}

closePort80() {
    ufw status | grep -q inactive && return
    ufw status numbered | grep 'ACME temp' | awk -F"[][]" '{print $2}' | sort -rn | while read -r n; do
        echo "y" | ufw delete "$n" &>/dev/null
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
    [ ! -f ~/.acme.sh/acme.sh ] && { echo "${red}$(msg acme_install_fail)${reset}"; return 1; }

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
            --pre-hook  "/usr/local/bin/vwn open-80" \
            --post-hook "/usr/local/bin/vwn close-80" \
            --force
        closePort80
    fi

    mkdir -p /etc/nginx/cert
    ~/.acme.sh/acme.sh --install-cert -d "$userDomain" \
        --fullchain-file /etc/nginx/cert/cert.pem \
        --key-file       /etc/nginx/cert/cert.key \
        --reloadcmd      "systemctl reload nginx"

    chmod 700 /etc/nginx/cert
    chmod 600 /etc/nginx/cert/cert.key
    echo "${green}$(msg ssl_success) $userDomain${reset}"
}

# ============================================================
# CF Guard — nginx geo блок (только Cloudflare IP)
# ============================================================

CF_GUARD_FILE="/etc/nginx/conf.d/cf_guard.conf"

setupRealIpRestore() {
    echo -e "${cyan}$(msg cf_ips_setup)${reset}"
    mkdir -p /etc/nginx/conf.d

    local tmp
    tmp=$(mktemp) || return 1
    trap 'rm -f "$tmp"' RETURN

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
    echo "real_ip_header CF-Connecting-IP;" >> "$tmp"
    echo "real_ip_recursive on;" >> "$tmp"

    mv -f "$tmp" /etc/nginx/conf.d/real_ip.conf
    nginx -t &>/dev/null && systemctl reload nginx
    echo "${green}$(msg cf_ips_ok)${reset}"
}

toggleCfGuard() {
    if [ -f "$CF_GUARD_FILE" ]; then
        echo -e "${yellow}$(msg cfguard_disable_confirm) $(msg yes_no)${reset}"
        read -r confirm
        [[ "$confirm" == "y" ]] || return
        rm -f "$CF_GUARD_FILE"
        nginx -t &>/dev/null && systemctl reload nginx
        echo "${green}$(msg cfguard_disabled)${reset}"
    else
        setupRealIpRestore || return 1

        local cf_ips_v4 cf_ips_v6
        cf_ips_v4=$(curl -fsSL --connect-timeout 10 https://www.cloudflare.com/ips-v4 2>/dev/null)
        cf_ips_v6=$(curl -fsSL --connect-timeout 10 https://www.cloudflare.com/ips-v6 2>/dev/null)
        [ -z "$cf_ips_v4" ] && { echo "${red}$(msg cf_ips_fail)${reset}"; return 1; }

        {
            echo "# CF Guard — allow only Cloudflare IPs"
            echo "# Auto-generated: $(date '+%Y-%m-%d %H:%M:%S')"
            echo "geo \$cloudflare_ip {"
            echo "    default 0;"
            while IFS= read -r ip; do [ -n "$ip" ] && echo "    $ip 1;"; done <<< "$cf_ips_v4"
            while IFS= read -r ip; do [ -n "$ip" ] && echo "    $ip 1;"; done <<< "$cf_ips_v6"
            echo "}"
        } > "$CF_GUARD_FILE"

        nginx -t &>/dev/null \
            && { systemctl reload nginx; echo "${green}$(msg cfguard_enabled)${reset}"; } \
            || { rm -f "$CF_GUARD_FILE"; echo "${red}$(msg nginx_syntax_err)${reset}"; return 1; }
    fi
}

getCfGuardStatus() {
    [ -f "$CF_GUARD_FILE" ] && echo "${green}ON${reset}" || echo "${red}OFF${reset}"
}

applyNginxSub() {
    [ ! -f "$nginxPath" ] && return 1
    nginx -t &>/dev/null && systemctl reload nginx || true
}
