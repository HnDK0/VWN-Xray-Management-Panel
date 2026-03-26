#!/bin/bash
# =================================================================
# warp.sh — Cloudflare WARP: установка, домены, watchdog
# =================================================================

installWarp() {
    command -v warp-cli &>/dev/null && { echo "info: warp-cli already installed."; return; }
    [ -z "${PACKAGE_MANAGEMENT_INSTALL:-}" ] && identifyOS
    if command -v apt &>/dev/null; then
        curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
            | gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp.gpg
        echo "deb [arch=amd64 signed-by=/usr/share/keyrings/cloudflare-warp.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" \
            | tee /etc/apt/sources.list.d/cloudflare-client.list
    else
        curl -fsSL https://pkg.cloudflareclient.com/cloudflare-warp-ascii.repo \
            | tee /etc/yum.repos.d/cloudflare-warp.repo
    fi
    ${PACKAGE_MANAGEMENT_UPDATE} &>/dev/null
    installPackage "cloudflare-warp"
}

# Обёртка для совместимости: старые версии warp-cli требуют --accept-tos,
# новые (2024+) убрали этот флаг
_warp_cmd() {
    if warp-cli --help 2>&1 | grep -q "accept-tos"; then
        warp-cli --accept-tos "$@"
    else
        warp-cli "$@"
    fi
}

configWarp() {
    systemctl enable --now warp-svc
    sleep 3

    if ! _warp_cmd registration show &>/dev/null; then
        _warp_cmd registration delete &>/dev/null || true
        local attempts=0
        while [ $attempts -lt 3 ]; do
            _warp_cmd registration new && break
            attempts=$((attempts + 1))
            sleep 3
        done
    fi

    _warp_cmd mode proxy
    _warp_cmd set-proxy-port 40000 2>/dev/null || true
    _warp_cmd connect
    sleep 5

    local warp_check
    warp_check=$(curl -s --connect-timeout 8 -x socks5://127.0.0.1:40000 \
        https://www.cloudflare.com/cdn-cgi/trace/ 2>/dev/null | grep 'warp=')
    if [[ "$warp_check" == *"warp=on"* ]] || [[ "$warp_check" == *"warp=plus"* ]]; then
        echo "${green}$(msg warp_connected)${reset}"
    else
        echo "${yellow}$(msg warp_started)${reset}"
    fi
}

applyWarpDomains() {
    [ ! -f "$warpDomainsFile" ] && printf 'openai.com\nchatgpt.com\noaistatic.com\noaiusercontent.com\nauth0.openai.com\n' > "$warpDomainsFile"
    local domains_json
    domains_json=$(domainsToJson "$warpDomainsFile")

    local warp_rule="{\"type\":\"field\",\"domain\":[$domains_json],\"outboundTag\":\"warp\"}"

    for cfg in "$configPath" "$realityConfigPath"; do
        [ -f "$cfg" ] || continue
        local has_rule
        has_rule=$(jq '.routing.rules[] | select(.outboundTag=="warp")' "$cfg" 2>/dev/null)
        if [ -z "$has_rule" ]; then
            # Правила нет — вставляем после block (индекс 0)
            jq --argjson r "$warp_rule" \
                '.routing.rules = [.routing.rules[0]] + [$r] + .routing.rules[1:]' \
                "$cfg" > "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
        else
            # Правило есть — обновляем домены, убираем port
            jq --argjson doms "[$domains_json]" \
                '(.routing.rules[] | select(.outboundTag == "warp")) |= (.domain = $doms | del(.port))' \
                "$cfg" > "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
        fi
    done
    systemctl restart xray 2>/dev/null || true
    systemctl restart xray-reality 2>/dev/null || true
}

toggleWarpMode() {
    echo "$(msg warp_mode_choose)"
    echo "$(msg warp_mode_1)"
    echo "$(msg warp_mode_2)"
    echo "$(msg warp_mode_3)"
    echo "$(msg warp_mode_0)"
    read -rp "$(msg prompt_choice_plain)" warp_mode

    case "$warp_mode" in
        1)
            local warp_global='{"type":"field","port":"0-65535","outboundTag":"warp"}'
            for cfg in "$configPath" "$realityConfigPath"; do
                [ -f "$cfg" ] || continue
                local has_rule
                has_rule=$(jq '.routing.rules[] | select(.outboundTag=="warp")' "$cfg" 2>/dev/null)
                if [ -z "$has_rule" ]; then
                    jq --argjson r "$warp_global" \
                        '.routing.rules = [.routing.rules[0]] + [$r] + .routing.rules[1:]' \
                        "$cfg" > "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
                else
                    jq '(.routing.rules[] | select(.outboundTag == "warp")) |= (.port = "0-65535" | del(.domain))' \
                        "$cfg" > "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
                fi
            done
            echo "${green}$(msg warp_global_ok)${reset}"
            systemctl restart xray 2>/dev/null || true
            systemctl restart xray-reality 2>/dev/null || true
            ;;
        2)
            applyWarpDomains
            echo "${green}$(msg warp_split_ok)${reset}"
            ;;
        3)
            for cfg in "$configPath" "$realityConfigPath"; do
                [ -f "$cfg" ] || continue
                jq 'del(.routing.rules[] | select(.outboundTag == "warp"))' \
                    "$cfg" > "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
            done
            echo "${green}$(msg warp_off_ok)${reset}"
            systemctl restart xray 2>/dev/null || true
            systemctl restart xray-reality 2>/dev/null || true
            ;;
        0) return 0 ;;
        *) echo "${red}$(msg cancel)${reset}" ;;
    esac
}

checkWarpStatus() {
    echo "--------------------------------------------------"
    local real_ip warp_ip
    real_ip=$(getServerIP)
    warp_ip=$(curl -s --connect-timeout 5 -x socks5://127.0.0.1:40000 https://api.ipify.org 2>/dev/null | tr -d '[:space:]' || echo "Error/Offline")
    echo "$(msg warp_real_ip) : $real_ip"
    echo "$(msg warp_ip) : $warp_ip"
    echo "--------------------------------------------------"
}

addDomainToWarpProxy() {
    read -rp "$(msg warp_domain_add)" domain
    [ -z "$domain" ] && return
    # Убираем ведущую точку и префикс domain: при сохранении
    domain=$(echo "$domain" | sed 's/^domain://;s/^\.//')
    [ -z "$domain" ] && return
    [ ! -f "$warpDomainsFile" ] && touch "$warpDomainsFile"
    if ! grep -q "^${domain}$" "$warpDomainsFile"; then
        echo "$domain" >> "$warpDomainsFile"
        sort -u "$warpDomainsFile" -o "$warpDomainsFile"
        applyWarpDomains
        echo "${green}$(msg warp_domain_added)${reset}"
    else
        echo "${yellow}$(msg warp_domain_exists)${reset}"
    fi
}

deleteDomainFromWarpProxy() {
    if [ ! -f "$warpDomainsFile" ]; then echo "$(msg warp_list_empty)"; return; fi
    echo "$(msg current) WARP:"
    nl "$warpDomainsFile"
    read -rp "$(msg warp_domain_del)" num
    if [[ "$num" =~ ^[0-9]+$ ]]; then
        sed -i "${num}d" "$warpDomainsFile"
        applyWarpDomains
        echo "${green}$(msg warp_domain_removed)${reset}"
    fi
}

setupWarpWatchdog() {
    cat > /usr/local/bin/warp-watchdog.sh << 'WDOG'
#!/bin/bash
CHECK_URL="https://www.cloudflare.com/cdn-cgi/trace/"
PROXY="socks5://127.0.0.1:40000"
MAX_LATENCY=8
LOG_TAG="warp-watchdog"
LOCKFILE="/tmp/warp-watchdog.lock"

if [ -f "$LOCKFILE" ]; then
    lock_pid=$(cat "$LOCKFILE" 2>/dev/null)
    if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
        exit 0
    fi
    rm -f "$LOCKFILE"
fi
echo $$ > "$LOCKFILE"
trap 'rm -f "$LOCKFILE"' EXIT

_wc() {
    if warp-cli --help 2>&1 | grep -q "accept-tos"; then
        warp-cli --accept-tos "$@"
    else
        warp-cli "$@"
    fi
}

command -v warp-cli &>/dev/null || exit 0

if ! systemctl is-active --quiet warp-svc 2>/dev/null; then
    logger -t "$LOG_TAG" "warp-svc not running, starting..."
    systemctl start warp-svc
    sleep 5
    _wc connect 2>/dev/null
    exit 0
fi

if ! ss -tlnp 2>/dev/null | grep -q ':40000'; then
    logger -t "$LOG_TAG" "port 40000 not listening, reconnecting..."
    _wc disconnect 2>/dev/null
    sleep 2
    _wc connect 2>/dev/null
    sleep 5
fi

result=$(curl -s --connect-timeout "$MAX_LATENCY" -x "$PROXY" "$CHECK_URL" 2>/dev/null)
if echo "$result" | grep -q "warp=on\|warp=plus"; then exit 0; fi

logger -t "$LOG_TAG" "first check failed, retrying in 20s..."
sleep 20

result=$(curl -s --connect-timeout "$MAX_LATENCY" -x "$PROXY" "$CHECK_URL" 2>/dev/null)
if echo "$result" | grep -q "warp=on\|warp=plus"; then
    logger -t "$LOG_TAG" "WARP recovered on retry."
    exit 0
fi

logger -t "$LOG_TAG" "WARP down — reconnecting (soft)..."
_wc disconnect 2>/dev/null
sleep 3
_wc connect 2>/dev/null
sleep 8

result=$(curl -s --connect-timeout "$MAX_LATENCY" -x "$PROXY" "$CHECK_URL" 2>/dev/null)
if echo "$result" | grep -q "warp=on\|warp=plus"; then
    logger -t "$LOG_TAG" "WARP restored after soft reconnect."
    exit 0
fi

logger -t "$LOG_TAG" "WARP still down — restarting warp-svc (hard)..."
systemctl restart warp-svc
sleep 10
_wc connect 2>/dev/null
WDOG

    chmod +x /usr/local/bin/warp-watchdog.sh

    cat > /etc/cron.d/warp-watchdog << 'EOF'
# Проверка WARP каждые 5 минут
*/5 * * * * root /usr/local/bin/warp-watchdog.sh
EOF
    chmod 600 /etc/cron.d/warp-watchdog
    echo "${green}$(msg warp_watchdog_ok)${reset}"
}