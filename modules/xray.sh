#!/bin/bash
# =================================================================
# xray.sh — Конфиг Xray VLESS+WebSocket+TLS, параметры, QR-код
# =================================================================

# =================================================================
# Получение флага страны по IP сервера
# Возвращает emoji флага, например 🇩🇪
# При ошибке возвращает 🌐
# =================================================================
_getCountryFlag() {
    local ip="$1"
    local code
    code=$(curl -s --connect-timeout 5 "http://ip-api.com/line/${ip}?fields=countryCode" | tr -d '[:space:]')
    if [[ "$code" =~ ^[A-Z]{2}$ ]]; then
        # Конвертируем код страны в emoji флаг через региональные индикаторы
        # A=0x1F1E6, поэтому каждая буква = 0x1F1E6 + (ord - ord('A'))
        python3 -c "
c='${code}'
flag=''.join(chr(0x1F1E6 + ord(ch) - ord('A')) for ch in c)
print(flag)
" || echo "🌐"
    else
        echo "🌐"
    fi
}

# Возвращает суффикс активных Global режимов для имени конфига
# Примеры: " 🌐☁️🇩🇪", " 🌐🔱🇳🇱🌉🇺🇸🧅🇫🇷", ""
# Split режимы НЕ отображаются — только Global
_getActiveModesSuffix() {
    local suffix=""
    local has_global=false
    
    # Проверяем WARP Global
    local warp_global=false
    if [ -f "$configPath" ]; then
        local warp_mode
        warp_mode=$(jq -r '.routing.rules[] | select(.outboundTag=="warp") | if .port == "0-65535" then "Global" else "OFF" end' "$configPath" | head -1)
        [ "$warp_mode" = "Global" ] && warp_global=true
    fi
    
    # Проверяем Psiphon Global + страна
    local psiphon_global=false
    local psiphon_country=""
    if [ -f "$configPath" ]; then
        local ps_mode
        ps_mode=$(jq -r '.routing.rules[] | select(.outboundTag=="psiphon") | if .port == "0-65535" then "Global" else "OFF" end' "$configPath" | head -1)
        [ "$ps_mode" = "Global" ] && psiphon_global=true
    fi
    [ "$psiphon_global" = true ] && [ -f "$psiphonConfigFile" ] &&         psiphon_country=$(jq -r '.EgressRegion // ""' "$psiphonConfigFile")
    
    # Проверяем Relay Global + страна (через ip-api на RELAY_HOST)
    local relay_global=false
    local relay_country=""
    if [ -f "$configPath" ]; then
        local relay_mode
        relay_mode=$(jq -r '.routing.rules[] | select(.outboundTag=="relay") | if .port == "0-65535" then "Global" else "OFF" end' "$configPath" | head -1)
        [ "$relay_mode" = "Global" ] && relay_global=true
    fi
    if [ "$relay_global" = true ] && [ -f "$relayConfigFile" ]; then
        local relay_host=""
        relay_host=$(source "$relayConfigFile" && echo "$RELAY_HOST")
        if [ -n "$relay_host" ]; then
            relay_country=$(curl -s --connect-timeout 5 "http://ip-api.com/line/${relay_host}?fields=countryCode" | tr -d '[:space:]')
        fi
    fi
    
    # Проверяем TOR Global + страна
    local tor_global=false
    local tor_country=""
    if [ -f "$configPath" ]; then
        local t_mode
        t_mode=$(jq -r '.routing.rules[] | select(.outboundTag=="tor") | if .port == "0-65535" then "Global" else "OFF" end' "$configPath" | head -1)
        [ "$t_mode" = "Global" ] && tor_global=true
    fi
    [ "$tor_global" = true ] &&         tor_country=$(grep "^ExitNodes" "$TOR_CONFIG" | grep -oP '\{[A-Z]+\}' | tr -d '{}' | head -1)
    
    # Если хоть один Global — добавляем 🌐
    [ "$warp_global" = true ] || [ "$psiphon_global" = true ] || [ "$relay_global" = true ] || [ "$tor_global" = true ] && has_global=true
    [ "$has_global" = true ] && suffix=" 🌐"
    
    # WARP: ☁️ + флаг страны (запрос через WARP socks5)
    if [ "$warp_global" = true ]; then
        local warp_country=""
        warp_country=$(curl -s --connect-timeout 5 --socks5 127.0.0.1:40000 "http://ip-api.com/line/?fields=countryCode" | tr -d '[:space:]')
        if [ -n "$warp_country" ] && [[ "$warp_country" =~ ^[A-Z]{2}$ ]]; then
            local wflag
            wflag=$(python3 -c "c='${warp_country}'; print(''.join(chr(0x1F1E6 + ord(ch) - ord('A')) for ch in c))")
            [ -n "$wflag" ] && suffix="$suffix ☁️$wflag"
        else
            suffix="$suffix ☁️"
        fi
    fi
    
    # Psiphon: 🔱 + флаг страны
    if [ "$psiphon_global" = true ]; then
        if [ -n "$psiphon_country" ] && [[ "$psiphon_country" =~ ^[A-Z]{2}$ ]]; then
            local pflag
            pflag=$(python3 -c "c='${psiphon_country}'; print(''.join(chr(0x1F1E6 + ord(ch) - ord('A')) for ch in c))")
            [ -n "$pflag" ] && suffix="$suffix 🔱$pflag"
        else
            suffix="$suffix 🔱"
        fi
    fi
    
    # Relay: 🌉 + флаг страны
    if [ "$relay_global" = true ]; then
        if [ -n "$relay_country" ] && [[ "$relay_country" =~ ^[A-Z]{2}$ ]]; then
            local rflag
            rflag=$(python3 -c "c='${relay_country}'; print(''.join(chr(0x1F1E6 + ord(ch) - ord('A')) for ch in c))")
            [ -n "$rflag" ] && suffix="$suffix 🌉$rflag"
        else
            suffix="$suffix 🌉"
        fi
    fi
    
    # TOR: 🧅 + флаг страны
    if [ "$tor_global" = true ]; then
        if [ -n "$tor_country" ] && [[ "$tor_country" =~ ^[A-Z]{2}$ ]]; then
            local tflag
            tflag=$(python3 -c "c='${tor_country}'; print(''.join(chr(0x1F1E6 + ord(ch) - ord('A')) for ch in c))")
            [ -n "$tflag" ] && suffix="$suffix 🧅$tflag"
        else
            suffix="$suffix 🧅"
        fi
    fi
    
    # Убираем лишние пробелы
    echo "$suffix" | sed 's/^ *//;s/ *$//;s/  */ /g'
}

# Формирует красивое имя конфига: 🇩🇪 VL-WS | label 🇩🇪 🌐🧅
# Аргументы: тип (WS|Reality), label, [ip]
_getConfigName() {
    local type="$1"
    local label="$2"
    local ip="${3:-$(getServerIP)}"
    local flag
    flag=$(_getCountryFlag "$ip")
    local modes
    modes=$(_getActiveModesSuffix)
    case "$type" in
        WS)       echo "${flag} VL-WS | ${label} ${flag}${modes}" ;;
        Reality)  echo "${flag} VL-Reality | ${label} ${flag}${modes}" ;;
        *)        echo "${flag} VL-${type} | ${label} ${flag}${modes}" ;;
    esac
}

installXray() {
    command -v xray && { echo "info: xray already installed."; return; }

    # Предварительно ставим unzip — официальный скрипт Xray требует его для распаковки
    installPackage "unzip" || true

    # Запускаем официальный установщик
    local install_ok=false
    if bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install 2>&1; then
        command -v xray && install_ok=true
    fi

    # Восстанавливаем терминал — официальный скрипт Xray ломает tty (убирает переносы строк)
    stty sane || true

    if ! $install_ok; then
        echo "${yellow}Official Xray installer failed, trying direct download...${reset}"
        _installXrayDirect || { echo "${red}Xray installation failed.${reset}"; return 1; }
    fi

    create_xray_user
    fix_xray_service
    setup_xray_logs
    _ensureXrayService
}

# Прямая загрузка бинаря Xray с GitHub Releases — fallback при недоступности официального установщика
_installXrayDirect() {
    local ARCH ARCH_TAG
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)  ARCH_TAG="64" ;;
        aarch64) ARCH_TAG="arm64-v8a" ;;
        armv7l)  ARCH_TAG="arm32-v7a" ;;
        *)       echo "${red}Unsupported arch: $ARCH${reset}"; return 1 ;;
    esac

    # Получаем последний тег версии
    local version
    version=$(curl -fsSL --connect-timeout 15 \
        "https://api.github.com/repos/XTLS/Xray-core/releases/latest" \
        | grep '"tag_name"' | head -1 | grep -oE 'v[0-9]+\.[0-9.]+')
    [ -z "$version" ] && version="v24.12.31"

    local tmpdir
    tmpdir=$(mktemp -d)
    # shellcheck disable=SC2064
    trap "rm -rf '$tmpdir'" RETURN

    local zip_url="https://github.com/XTLS/Xray-core/releases/download/${version}/Xray-linux-${ARCH_TAG}.zip"
    echo "info: Downloading Xray ${version} (${ARCH_TAG})..."

    if curl -fsSL --connect-timeout 30 --retry 2 "$zip_url" -o "$tmpdir/xray.zip"; then
        # Распаковываем: сначала unzip, потом python3 как fallback
        if command -v unzip; then
            unzip -q -o "$tmpdir/xray.zip" xray -d "$tmpdir/" || \
            unzip -q -o "$tmpdir/xray.zip" -d "$tmpdir/" || true
        else
            python3 -c "
import zipfile, sys
with zipfile.ZipFile(sys.argv[1]) as z:
    z.extractall(sys.argv[2])
" "$tmpdir/xray.zip" "$tmpdir/" || true
        fi
    fi

    local xray_bin="$tmpdir/xray"
    if [ ! -f "$xray_bin" ] || [ ! -s "$xray_bin" ]; then
        echo "${red}Direct download failed: could not extract xray binary${reset}"
        return 1
    fi

    install -m 755 "$xray_bin" /usr/local/bin/xray
    echo "${green}Xray ${version} installed to /usr/local/bin/xray${reset}"

    # Скачиваем geo-базы
    mkdir -p /usr/local/share/xray
    for dat in geoip.dat geosite.dat; do
        curl -fsSL --connect-timeout 15 \
            "https://github.com/v2fly/geoip/releases/latest/download/${dat}" \
            -o "/usr/local/share/xray/${dat}" || true
    done
    return 0
}

# Создаёт xray.service если официальный установщик его не создал
_ensureXrayService() {
    local svc_found=false
    for f in /etc/systemd/system/xray.service /usr/lib/systemd/system/xray.service /lib/systemd/system/xray.service; do
        [ -f "$f" ] && svc_found=true && break
    done

    if ! $svc_found; then
        echo "info: Creating xray.service manually..."
        cat > /etc/systemd/system/xray.service << 'EOF'
[Unit]
Description=Xray Service
Documentation=https://github.com/xtls
After=network.target nss-lookup.target

[Service]
User=xray
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartPreventExitStatus=23
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        echo "info: xray.service created."
    fi

    # Убеждаемся что директория конфига существует
    mkdir -p /usr/local/etc/xray
}

writeXrayConfig() {
    local xrayPort="$1"
    local wsPath="$2"
    local domain="$3"
    local new_uuid=""
    local USERS_FILE="${USERS_FILE:-/usr/local/etc/xray/users.conf}"

    # Если users.conf уже есть — берём UUID первого пользователя
    if [ -f "$USERS_FILE" ] && [ -s "$USERS_FILE" ]; then
        new_uuid=$(cut -d'|' -f1 "$USERS_FILE" | head -1)
    fi
    [ -z "$new_uuid" ] && new_uuid=$(cat /proc/sys/kernel/random/uuid)

    mkdir -p /usr/local/etc/xray /var/log/xray

    # Проверка существования шаблона
    if [ ! -f "$VWN_CONFIG_DIR/xray_ws.json" ]; then
        echo "error: xray_ws.json template not found" >&2
        return 1
    fi

    # Автодетект формата шаблона:
    # Если шаблон содержит плейсхолдеры __UUID__ / __PORT__ — используем render_config (текстовая замена).
    # Если шаблон — валидный JSON с числовыми значениями — используем jq.
    if grep -qE '__UUID__|__PORT__|__PATH__|__DOMAIN__' "$VWN_CONFIG_DIR/xray_ws.json"; then
        render_config "$VWN_CONFIG_DIR/xray_ws.json" "$configPath" \
            UUID    "$new_uuid" \
            PORT    "$xrayPort" \
            PATH    "$wsPath" \
            DOMAIN  "$domain"
    else
        jq \
            --arg port   "$xrayPort" \
            --arg path   "$wsPath" \
            --arg domain "$domain" \
            --arg uuid   "$new_uuid" \
            '
                .inbounds[0].port = ($port | tonumber)
                | .inbounds[0].streamSettings.wsSettings.path = $path
                | .inbounds[0].streamSettings.wsSettings.host = $domain
                | .inbounds[0].settings.clients[0].id = $uuid
            ' "$VWN_CONFIG_DIR/xray_ws.json" > "$configPath"
    fi

    # Валидация результата
    if ! jq . "$configPath"; then
        echo "error: writeXrayConfig produced invalid JSON at $configPath" >&2
        cat "$configPath" >&2
        return 1
    fi
}

getConfigInfo() {
    if [ ! -f "$configPath" ]; then
        echo "${red}$(msg xray_not_installed)${reset}" >&2
        return 1
    fi
    xray_uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$configPath")
    # Поддержка и ws и xhttp (обратная совместимость)
    xray_path=$(jq -r '.inbounds[0].streamSettings.wsSettings.path // .inbounds[0].streamSettings.xhttpSettings.path' "$configPath")
    xray_port=$(jq -r '.inbounds[0].port' "$configPath")
    xray_userDomain=$(jq -r '.inbounds[0].streamSettings.wsSettings.host // .inbounds[0].streamSettings.xhttpSettings.host // ""' "$configPath")
    if [ -z "$xray_userDomain" ] || [ "$xray_userDomain" = "null" ]; then
        xray_userDomain=$(grep -E '^\s*server_name\s+' "$nginxPath" \
            | grep -v 'proxy_ssl' \
            | grep -v 'server_name\s*_;' \
            | awk '{print $2}' | tr -d ';' | grep -v '^_$' | head -1)
    fi
    [ -z "$xray_userDomain" ] && xray_userDomain=$(getServerIP)

    if [ -z "$xray_uuid" ] || [ "$xray_uuid" = "null" ]; then
        echo "${red}$(msg xray_not_installed)${reset}" >&2
        return 1
    fi
}

getShareUrl() {
    local label="${1:-default}"
    getConfigInfo || return 1
    local encoded_path name
    encoded_path=$(python3 -c \
        "import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe='/'))" \
        "$xray_path") || encoded_path="$xray_path"
    name=$(_getConfigName "WS" "$label")
    # URL-кодируем имя для фрагмента (#)
    local encoded_name
    encoded_name=$(python3 -c \
        "import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))" \
        "$name") || encoded_name="$name"
    echo "vless://${xray_uuid}@${xray_userDomain}:443?encryption=none&security=tls&sni=${xray_userDomain}&fp=chrome&type=ws&host=${xray_userDomain}&path=${encoded_path}#${encoded_name}"
}

# JSON конфиг для ручного импорта (v2rayNG Custom config, Nekoray и др.)
_getWsJsonConfig() {
    local uuid="$1" domain="$2" path="$3"
    cat << JSONEOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "port": 10808, "listen": "127.0.0.1", "protocol": "socks",
    "settings": {"auth": "noauth", "udp": true}
  }],
  "outbounds": [
    {
      "tag": "proxy", "protocol": "vless",
      "settings": {
        "vnext": [{"address": "${domain}", "port": 443,
          "users": [{"id": "${uuid}", "encryption": "none"}]}]
      },
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "tlsSettings": {
          "serverName": "${domain}",
          "fingerprint": "chrome",
          "alpn": ["http/1.1"]
        },
        "wsSettings": {
          "path": "${path}",
          "headers": {"Host": "${domain}"}
        }
      }
    },
    {"tag": "direct", "protocol": "freedom"},
    {"tag": "block",  "protocol": "blackhole"}
  ],
  "routing": {"rules": [{"type": "field", "ip": ["geoip:private"], "outboundTag": "direct"}]}
}
JSONEOF
}

getQrCode() {
    # Всё показывается через HTML страницу подписки.
    # В терминале — только ссылка подписки и HTML.
    # Используется при установке (первый показ QR).
    _initUsersFile || true

    local domain uuid label token sub_url html_url safe
    domain=$(getConnectHost)
    [ -z "$domain" ] && domain=$(_getDomain)
    [ -z "$domain" ] && domain=$(getServerIP)

    # Берём первого пользователя
    if [ -f "$USERS_FILE" ] && [ -s "$USERS_FILE" ]; then
        uuid=$(cut -d'|' -f1 "$USERS_FILE" | head -1)
        label=$(cut -d'|' -f2 "$USERS_FILE" | head -1)
        token=$(cut -d'|' -f3 "$USERS_FILE" | head -1)
    fi

    if [ -z "$uuid" ]; then
        getConfigInfo || return 1
        uuid="$xray_uuid"
        label="default"
        token=""
    fi

    safe=$(echo "$label" | tr -cd 'A-Za-z0-9_-')

    if [ -n "$token" ]; then
        sub_url="https://${domain}/sub/${safe}_${token}.txt"
        html_url="https://${domain}/sub/${safe}_${token}.html"
    fi

    command -v qrencode || installPackage "qrencode"

    echo -e "${cyan}================================================================${reset}"
    echo -e "   VWN — готово к подключению"
    echo -e "${cyan}================================================================${reset}"
    echo ""

    if [ -n "$sub_url" ]; then
        echo -e "${cyan}[ Subscription URL ]${reset}"
        qrencode -s 3 -m 2 -t ANSIUTF8 "$sub_url" || true
        echo -e "\n${green}${sub_url}${reset}"
        echo -e "${yellow}v2rayNG: + → Subscription group → URL${reset}"
        echo ""
    fi

    if [ -n "$html_url" ]; then
        echo -e "${cyan}[ HTML — все конфиги, QR, Clash ]${reset}"
        echo -e "${green}${html_url}${reset}"
    fi

    echo -e "${cyan}================================================================${reset}"
}

# Валидация домена: только hostname без протокола и пути
_validateDomain() {
    local d="$1"
    d=$(echo "$d" | sed 's|https\?://||' | sed 's|/.*||' | tr -d ' ')
    if [[ ! "$d" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*\.[a-zA-Z]{2,}$ ]]; then
        return 1
    fi
    echo "$d"
}

# Валидация URL: должен начинаться с https://
_validateUrl() {
    local u="$1"
    u=$(echo "$u" | tr -d ' ')
    if [[ ! "$u" =~ ^https://[a-zA-Z0-9] ]]; then
        return 1
    fi
    echo "$u"
}

# Валидация порта: 1024-65535
_validatePort() {
    local p="$1"
    if ! [[ "$p" =~ ^[0-9]+$ ]] || [ "$p" -lt 1024 ] || [ "$p" -gt 65535 ]; then
        return 1
    fi
    echo "$p"
}

modifyXrayUUID() {
    if [ -f "$USERS_FILE" ] && [ -s "$USERS_FILE" ]; then
        # Генерируем новый UUID для каждого пользователя
        local tmp
        tmp=$(mktemp)
        while IFS='|' read -r uuid label token; do
            [ -z "$uuid" ] && continue
            local new_uuid
            new_uuid=$(cat /proc/sys/kernel/random/uuid)
            echo "${new_uuid}|${label}|${token}"
        done < "$USERS_FILE" > "$tmp"
        mv "$tmp" "$USERS_FILE"
        # Синхронизируем оба конфига
        _applyUsersToConfigs
        echo "${green}$(msg new_uuid) — все пользователи обновлены${reset}"
        cat "$USERS_FILE" | while IFS='|' read -r uuid label token; do
            echo "  $label → $uuid"
        done
    else
        # Нет users.conf — меняем только в конфигах напрямую
        local new_uuid
        new_uuid=$(cat /proc/sys/kernel/random/uuid)
        [ -f "$configPath" ] && edit_json "$configPath" ".inbounds[0].settings.clients[0].id = \"$new_uuid\""
        [ -f "$realityConfigPath" ] && edit_json "$realityConfigPath" ".inbounds[0].settings.clients[0].id = \"$new_uuid\""
        systemctl restart xray xray-reality || true
        echo "${green}$(msg new_uuid): $new_uuid${reset}"
    fi
}

modifyXrayPort() {
    local oldPort
    oldPort=$(jq ".inbounds[0].port" "$configPath")
    read -rp "$(msg enter_new_port) [$oldPort]: " xrayPort
    [ -z "$xrayPort" ] && return
    if ! _validatePort "$xrayPort"; then
        echo "${red}$(msg invalid_port)${reset}"; return 1
    fi
    edit_json "$configPath" ".inbounds[0].port = $xrayPort"
    sed -i "s|127.0.0.1:${oldPort}|127.0.0.1:${xrayPort}|g" "$nginxPath"
    systemctl restart xray nginx
    echo "${green}$(msg port_changed) $xrayPort${reset}"
    rebuildAllSubFiles || true
}

modifyWsPath() {
    local oldPath
    oldPath=$(jq -r ".inbounds[0].streamSettings.wsSettings.path" "$configPath")
    read -rp "$(msg enter_new_path)" wsPath
    [ -z "$wsPath" ] && wsPath=$(generateRandomPath)
    wsPath=$(echo "$wsPath" | tr -cd 'A-Za-z0-9/_-')
    [[ ! "$wsPath" =~ ^/ ]] && wsPath="/$wsPath"

    local oldPathEscaped newPathEscaped
    oldPathEscaped=$(printf '%s\n' "$oldPath" | sed 's|[[\.*^$()+?{|]|\\&|g')
    newPathEscaped=$(printf '%s\n' "$wsPath" | sed 's|[[\.*^$()+?{|]|\\&|g')
    sed -i "s|location ${oldPathEscaped}|location ${newPathEscaped}|g" "$nginxPath"

    jq ".inbounds[0].streamSettings.wsSettings.path = \"$wsPath\"" \
        "$configPath" > "${configPath}.tmp" && mv "${configPath}.tmp" "$configPath"
    systemctl restart xray nginx
    echo "${green}$(msg new_path): $wsPath${reset}"
    rebuildAllSubFiles || true
}

modifyProxyPassUrl() {
    read -rp "$(msg enter_proxy_url)" newUrl
    [ -z "$newUrl" ] && return
    if ! _validateUrl "$newUrl"; then
        echo "${red}$(msg invalid) URL. $(msg enter_proxy_url)${reset}"; return 1
    fi

    # Вычисляем новый host из URL
    local newHost
    newHost=$(echo "$newUrl" | sed 's|https://||;s|http://||;s|/.*||')

    # Меняем proxy_pass
    local oldUrl
    oldUrl=$(grep "proxy_pass" "$nginxPath" | grep -v "127.0.0.1" | awk '{print $2}' | tr -d ';' | head -1)
    local oldUrlEscaped newUrlEscaped
    oldUrlEscaped=$(printf '%s\n' "$oldUrl" | sed 's|[[\.*^$()+?{|]|\\&|g')
    newUrlEscaped=$(printf '%s\n' "$newUrl" | sed 's|[[\.*^$()+?{|]|\\&|g')
    sed -i "s|${oldUrlEscaped}|${newUrlEscaped}|g" "$nginxPath"

    # Меняем proxy_set_header Host — старый host берём из текущего конфига
    local oldHost
    oldHost=$(grep "proxy_set_header Host" "$nginxPath" | grep -v '\$host' | awk '{print $3}' | tr -d ';' | head -1)
    if [ -n "$oldHost" ] && [ -n "$newHost" ]; then
        local oldHostEscaped newHostEscaped
        oldHostEscaped=$(printf '%s\n' "$oldHost" | sed 's|[\[\].*^$()+?{|]|\\&|g')
        newHostEscaped=$(printf '%s\n' "$newHost" | sed 's|[\[\].*^$()+?{|]|\\&|g')
        # sed с \s* чтобы не зависеть от количества пробелов/табов перед директивой
        sed -i "s|\(proxy_set_header Host\)[[:space:]]\+${oldHostEscaped};|\1 ${newHostEscaped};|g" "$nginxPath"
    fi

    nginx -t && systemctl reload nginx || { echo "${red}$(msg nginx_syntax_err)${reset}"; return 1; }
    echo "${green}$(msg proxy_updated): $newUrl (Host: $newHost)${reset}"
}

modifyDomain() {
    getConfigInfo || return 1
    echo "$(msg current_domain): $xray_userDomain"
    read -rp "$(msg enter_new_domain)" new_domain
    [ -z "$new_domain" ] && return
    local validated
    if ! validated=$(_validateDomain "$new_domain"); then
        echo "${red}$(msg invalid): '$new_domain'${reset}"; return 1
    fi
    new_domain="$validated"
    sed -i "s/server_name ${xray_userDomain};/server_name ${new_domain};/" "$nginxPath"
    jq ".inbounds[0].streamSettings.wsSettings.host = \"$new_domain\"" \
        "$configPath" > "${configPath}.tmp" && mv "${configPath}.tmp" "$configPath"
    userDomain="$new_domain"
    configCert

    systemctl restart nginx xray
}

CONNECT_HOST_FILE="/usr/local/etc/xray/connect_host"

getConnectHost() {
    local h
    h=$(cat "$CONNECT_HOST_FILE" | tr -d '[:space:]')
    if [ -n "$h" ]; then
        echo "$h"
    else
        # Fallback на основной домен
        jq -r '.inbounds[0].streamSettings.wsSettings.host // ""' "$configPath"
    fi
}

modifyConnectHost() {
    local current
    current=$(cat "$CONNECT_HOST_FILE" | tr -d '[:space:]')
    if [ -n "$current" ]; then
        echo "Текущий адрес подключения: ${green}${current}${reset}"
    else
        getConfigInfo || return 1
        echo "Текущий адрес подключения: ${green}${xray_userDomain}${reset} (основной домен)"
    fi
    echo ""
    echo "Введите CDN домен для подключения (Enter = сбросить на основной домен):"
    read -rp "> " new_host
    if [ -z "$new_host" ]; then
        rm -f "$CONNECT_HOST_FILE"
        echo "${green}Адрес подключения сброшен на основной домен${reset}"
    else
        local validated
        if ! validated=$(_validateDomain "$new_host"); then
            echo "${red}$(msg invalid): '$new_host'${reset}"; return 1
        fi
        echo "$validated" > "$CONNECT_HOST_FILE"
        echo "${green}Адрес подключения: $validated${reset}"
    fi
    # Пересоздаём подписки с новым адресом
    rebuildAllSubFiles || true
}

updateXrayCore() {
    bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    systemctl restart xray xray-reality || true
    echo "${green}$(msg xray_updated)${reset}"
}

rebuildXrayConfigs() {
    local skip_sub="${1:-false}"
    if [ ! -f "$configPath" ]; then
        echo "${red}$(msg xray_not_installed)${reset}"; return 1;
    fi

    local xrayPort wsPath domain
    xrayPort=$(jq -r '.inbounds[0].port // ""' "$configPath")
    wsPath=$(jq -r '.inbounds[0].streamSettings.wsSettings.path // ""' "$configPath")
    domain=$(jq -r '.inbounds[0].streamSettings.wsSettings.host // ""' "$configPath")

    if [ -z "$xrayPort" ] || [ -z "$wsPath" ] || [ -z "$domain" ]; then
        echo "${red}$(msg xray_not_installed) (missing params)${reset}"; return 1;
    fi

    echo -e "${cyan}Rebuilding WebSocket configs...${reset}"

    echo -e "  ${cyan}[1/3] config.json...${reset}"
    writeXrayConfig "$xrayPort" "$wsPath" "$domain"

    echo -e "  ${cyan}[2/3] Applying active features...${reset}"
    [ -f "$warpDomainsFile" ] && applyWarpDomains || true
    [ -f "$relayConfigFile" ] && applyRelayDomains || true
    [ -f "$psiphonConfigFile" ] && applyPsiphonDomains || true
    [ -f "$torConfigFile" ] && applyTorDomains || true
    _adblockIsEnabled && _adblockApplyToConfig "$configPath" || true
    _privacyIsEnabled && _xrayDisableLog "$configPath" || true

    echo -e "  ${cyan}[3/3] Restarting services...${reset}"
    nginx -t && systemctl reload nginx || {
        echo "${red}$(msg nginx_syntax_err)${reset}"; return 1;
    }
    systemctl restart xray || true

    $skip_sub || rebuildAllSubFiles || true

    echo "${green}Done. WebSocket configs rebuilt.${reset}"
}