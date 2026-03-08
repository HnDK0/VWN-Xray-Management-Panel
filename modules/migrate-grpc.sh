#!/bin/bash
# =================================================================
# migrate-grpc.sh — Одноразовая миграция: добавить gRPC к WS
# Запуск: bash migrate-grpc.sh
# =================================================================

set -e

CONFIG_WS="/usr/local/etc/xray/config.json"
CONFIG_GRPC="/usr/local/etc/xray/config-grpc.json"
NGINX_CONF="/etc/nginx/conf.d/xray.conf"
GRPC_SERVICE_FILE="/etc/systemd/system/xray-grpc.service"
GRPC_PORT=16501

red=$(tput setaf 1 && tput bold)
green=$(tput setaf 2 && tput bold)
cyan=$(tput setaf 6 && tput bold)
reset=$(tput sgr0)

# ── Проверки ──────────────────────────────────────────────────────

[ "$EUID" -ne 0 ] && { echo "${red}Run as root!${reset}"; exit 1; }
[ ! -f "$CONFIG_WS" ] && { echo "${red}WS config not found: $CONFIG_WS${reset}"; exit 1; }
[ ! -f "$NGINX_CONF" ] && { echo "${red}Nginx config not found: $NGINX_CONF${reset}"; exit 1; }
command -v jq &>/dev/null || { echo "${red}jq not found. Run: apt install jq${reset}"; exit 1; }

if [ -f "$CONFIG_GRPC" ]; then
    echo "${red}config-grpc.json already exists. Migration already done.${reset}"
    exit 1
fi

# ── Читаем параметры из WS конфига ───────────────────────────────

UUID=$(jq -r '.inbounds[0].settings.clients[0].id' "$CONFIG_WS")
[ -z "$UUID" ] || [ "$UUID" = "null" ] && { echo "${red}Cannot read UUID from config.json${reset}"; exit 1; }

DOMAIN=$(jq -r '.inbounds[0].streamSettings.wsSettings.host // ""' "$CONFIG_WS" 2>/dev/null)
if [ -z "$DOMAIN" ] || [ "$DOMAIN" = "null" ]; then
    DOMAIN=$(grep -E '^\s*server_name\s+' "$NGINX_CONF" 2>/dev/null | grep -v '_' | awk '{print $2}' | tr -d ';' | head -1)
fi
[ -z "$DOMAIN" ] && { echo "${red}Cannot detect domain${reset}"; exit 1; }

GRPC_SVC=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 12)

echo -e "${cyan}=== gRPC Migration ===${reset}"
echo "  UUID:     $UUID"
echo "  Domain:   $DOMAIN"
echo "  Port:     $GRPC_PORT"
echo "  Service:  $GRPC_SVC"
echo ""

# ── 1. Создаём config-grpc.json ───────────────────────────────────

echo -n "  [1/3] Creating config-grpc.json... "
cat > "$CONFIG_GRPC" << EOF
{
    "log": {
        "access": "none",
        "error": "/var/log/xray/error.log",
        "loglevel": "error"
    },
    "inbounds": [{
        "port": $GRPC_PORT,
        "listen": "127.0.0.1",
        "protocol": "vless",
        "settings": {
            "clients": [{"id": "$UUID"}],
            "decryption": "none"
        },
        "streamSettings": {
            "network": "grpc",
            "grpcSettings": {
                "serviceName": "$GRPC_SVC",
                "multiMode": false,
                "idle_timeout": 60,
                "health_check_timeout": 20,
                "permit_without_stream": false,
                "initial_windows_size": 0
            },
            "sockopt": {
                "tcpKeepAliveIdle": 100,
                "tcpKeepAliveInterval": 10,
                "tcpKeepAliveRetry": 3,
                "tcpFastOpen": true
            }
        },
        "sniffing": {"enabled": false}
    }],
    "outbounds": [
        {
            "tag": "free",
            "protocol": "freedom",
            "settings": {"domainStrategy": "UseIPv4"}
        },
        {
            "tag": "warp",
            "protocol": "socks",
            "settings": {"servers": [{"address": "127.0.0.1", "port": 40000}]}
        },
        {
            "tag": "block",
            "protocol": "blackhole"
        }
    ],
    "routing": {
        "domainStrategy": "IPIfNonMatch",
        "rules": [
            {
                "type": "field",
                "ip": ["geoip:private"],
                "outboundTag": "block"
            },
            {
                "type": "field",
                "domain": [
                    "domain:openai.com",
                    "domain:chatgpt.com",
                    "domain:oaistatic.com",
                    "domain:oaiusercontent.com",
                    "domain:auth0.openai.com"
                ],
                "outboundTag": "warp"
            },
            {
                "type": "field",
                "port": "0-65535",
                "outboundTag": "free"
            }
        ]
    }
}
EOF
echo "${green}OK${reset}"

# ── 2. Создаём xray-grpc.service ─────────────────────────────────

echo -n "  [2/3] Creating xray-grpc.service... "
cat > "$GRPC_SERVICE_FILE" << 'EOF'
[Unit]
Description=Xray VLESS+gRPC Service
After=network.target

[Service]
User=nobody
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config-grpc.json
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable xray-grpc
echo "${green}OK${reset}"

# ── 3. Добавляем location gRPC в nginx ───────────────────────────

echo -n "  [3/3] Adding gRPC location to nginx... "

sed -i "s|    location / {|    location /${GRPC_SVC}/Tun {\n        grpc_pass grpc://127.0.0.1:${GRPC_PORT};\n        grpc_set_header Host \$host;\n        grpc_set_header X-Real-IP \$remote_addr;\n        grpc_read_timeout 3600s;\n        grpc_send_timeout 3600s;\n        grpc_connect_timeout 10s;\n        client_max_body_size 0;\n    }\n\n    location / {|" "$NGINX_CONF"

nginx -t &>/dev/null || { echo "${red}FAIL — nginx config error, check: nginx -t${reset}"; exit 1; }
systemctl reload nginx
echo "${green}OK${reset}"

# ── Готово ────────────────────────────────────────────────────────

echo ""
echo -e "${green}=== Done! ===${reset}"
echo "  config-grpc.json: $CONFIG_GRPC"
echo "  Service:          xray-grpc (enabled, not started)"
echo "  Nginx:            location /${GRPC_SVC}/Tun added"
echo ""
echo "  To switch to gRPC: vwn → 3 → 5 (Switch transport)"
