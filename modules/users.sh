#!/bin/bash
# =================================================================
# users.sh — Управление пользователями
# Формат users.conf: UUID|LABEL|TOKEN
# Sub URL: https://<domain>/sub/<label>_<token>.txt
# =================================================================

USERS_FILE="/usr/local/etc/xray/users.conf"
SUB_DIR="/usr/local/etc/xray/sub"

# ── Утилиты ───────────────────────────────────────────────────────

_usersCount() { [ -f "$USERS_FILE" ] && grep -c '.' "$USERS_FILE" || echo 0; }
_uuidByLine()  { sed -n "${1}p" "$USERS_FILE" | cut -d'|' -f1; }
_labelByLine() { sed -n "${1}p" "$USERS_FILE" | cut -d'|' -f2; }
_tokenByLine() { sed -n "${1}p" "$USERS_FILE" | cut -d'|' -f3; }
_genToken()    { head /dev/urandom | tr -dc A-Za-z0-9 | head -c 24; }
_safeLabel()   { echo "$1" | tr -cd 'A-Za-z0-9_-'; }
_subFilename() {
    local label="$1" token="$2"
    local safe
    safe=$(_safeLabel "$label")
    echo "${safe}_${token}.txt"
}

# Получает флаг страны (с кэшем в переменной окружения)
_getCachedFlag() {
    if [ -z "${_VWN_FLAG_CACHE:-}" ]; then
        local ip
        ip=$(getServerIP)
        _VWN_FLAG_CACHE=$(_getCountryFlag "$ip" || echo "🌐")
        export _VWN_FLAG_CACHE
    fi
    echo "$_VWN_FLAG_CACHE"
}

# Домен из wsSettings.host (с fallback на xhttpSettings для обратной совместимости)
_getDomain() {
    local d=""
    [ -f "$configPath" ] && \
        d=$(jq -r '.inbounds[0].streamSettings.wsSettings.host // .inbounds[0].streamSettings.xhttpSettings.host // ""' "$configPath")
    echo "$d"
}

# ── Применить users.conf в оба конфига Xray ───────────────────────

_applyUsersToConfigs() {
    [ ! -f "$USERS_FILE" ] && return 0

    local clients_r="[" clients_x="[" first_r=true first_x=true
    while IFS='|' read -r uuid label token; do
        [ -z "$uuid" ] && continue
        $first_r || clients_r+=","
        clients_r+="{\"id\":\"${uuid}\",\"flow\":\"xtls-rprx-vision\",\"email\":\"${label}\"}"
        first_r=false
        $first_x || clients_x+=","
        clients_x+="{\"id\":\"${uuid}\",\"email\":\"${label}\"}"
        first_x=false
    done < "$USERS_FILE"
    clients_r+="]"; clients_x+="]"

    if [ -f "$configPath" ]; then
        jq --argjson c "$clients_x" '.inbounds[0].settings.clients = $c' \
            "$configPath" > "${configPath}.tmp" && mv "${configPath}.tmp" "$configPath"
    fi
    if [ -f "$realityConfigPath" ]; then
        jq --argjson c "$clients_r" '.inbounds[0].settings.clients = $c' \
            "$realityConfigPath" > "${realityConfigPath}.tmp" && mv "${realityConfigPath}.tmp" "$realityConfigPath"
    fi
    if [ -f "$xhttpConfigPath" ]; then
        jq --argjson c "$clients_x" '.inbounds[0].settings.clients = $c' \
            "$xhttpConfigPath" > "${xhttpConfigPath}.tmp" && mv "${xhttpConfigPath}.tmp" "$xhttpConfigPath"
    fi

    systemctl restart xray || true
    systemctl restart xray-reality || true
    systemctl restart xray-xhttp || true
}

# ── Инициализация ─────────────────────────────────────────────────

_initUsersFile() {
    [ -f "$USERS_FILE" ] && return 0
    mkdir -p "$(dirname "$USERS_FILE")"

    local existing_uuid=""
    if [ -f "$configPath" ]; then
        existing_uuid=$(jq -r '.inbounds[0].settings.clients[0].id // ""' "$configPath")
    fi
    # Если в WS нет UUID — берём из Reality
    if [ -z "$existing_uuid" ] || [ "$existing_uuid" = "null" ]; then
        if [ -f "$realityConfigPath" ]; then
            existing_uuid=$(jq -r '.inbounds[0].settings.clients[0].id // ""' "$realityConfigPath")
        fi
    fi

    if [ -n "$existing_uuid" ] && [ "$existing_uuid" != "null" ]; then
        local token
        token=$(_genToken)
        echo "${existing_uuid}|default|${token}" > "$USERS_FILE"
        echo "${green}$(msg users_migrated): $existing_uuid${reset}"
        # Синхронизируем UUID в оба конфига
        _applyUsersToConfigs || true
        buildUserSubFile "$existing_uuid" "default" "$token" || true
    fi
}

# ── Subscription ──────────────────────────────────────────────────

buildUserSubFile() {
    local uuid="$1" label="$2" token="$3"
    mkdir -p "$SUB_DIR"
    applyNginxSub || true

    local domain lines="" server_ip flag
    domain=$(_getDomain)
    server_ip=$(getServerIP)
    flag=$(_getCountryFlag "$server_ip")

    if [ -f "$configPath" ] && [ -n "$domain" ]; then
        local wp wep name encoded_name connect_host
        wp=$(jq -r '.inbounds[0].streamSettings.wsSettings.path // .inbounds[0].streamSettings.xhttpSettings.path // ""' "$configPath")
        wep=$(python3 -c "import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1],safe='/'))" "$wp" || echo "$wp")
        connect_host=$(getConnectHost || echo "$domain")
        [ -z "$connect_host" ] && connect_host="$domain"
        name=$(_getConfigName "WS" "$label" "$server_ip")
        encoded_name=$(python3 -c "import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1]))" "$name" || echo "$name")
        lines+="vless://${uuid}@${connect_host}:443?encryption=none&security=tls&sni=${domain}&fp=chrome&alpn=http%2F1.1&type=ws&host=${domain}&path=${wep}#${encoded_name}"$'\n'
    fi

    if [ -f "$realityConfigPath" ]; then
        local r_uuid r_port r_shortId r_destHost r_pubKey r_name r_encoded_name
        # Ищем UUID этого пользователя в clients reality конфига
        # Если не найден (старая установка без мульти-юзеров) — берём первого
        r_uuid=$(jq -r --arg u "$uuid" \
            '.inbounds[0].settings.clients[] | select(.id==$u) | .id' \
            "$realityConfigPath" | head -1)
        [ -z "$r_uuid" ] && \
            r_uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$realityConfigPath")
        r_port=$(jq -r '.inbounds[0].port' "$realityConfigPath")
        r_shortId=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$realityConfigPath")
        r_destHost=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$realityConfigPath")
        r_pubKey=$(vwn_conf_get REALITY_PUBKEY)
        [ -z "$r_pubKey" ] && r_pubKey=$(grep "PublicKey:" /usr/local/etc/xray/reality_client.txt | awk '{print $NF}')
        r_name=$(_getConfigName "Reality" "$label" "$server_ip")
        r_encoded_name=$(python3 -c "import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1]))" "$r_name" || echo "$r_name")
        lines+="vless://${r_uuid}@${server_ip}:${r_port}?encryption=none&security=reality&sni=${r_destHost}&fp=chrome&pbk=${r_pubKey}&sid=${r_shortId}&type=tcp&flow=xtls-rprx-vision#${r_encoded_name}"$'\n'
    fi

    if [ -f "$xhttpConfigPath" ]; then
        local x_domain x_path x_enc_path x_name x_encoded_name
        x_domain=$(vwn_conf_get DOMAIN || true)
        x_path=$(vwn_conf_get XHTTP_PATH || true)
        # UUID пользователя одинаков для всех транспортов (WS, XHTTP, Reality)
        # connect_host — CDN-адрес подключения (может отличаться от домена)
        if [ -n "$x_domain" ] && [ -n "$uuid" ] && [ -n "$x_path" ]; then
            x_enc_path=$(python3 -c "import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1],safe='/'))" "$x_path" || echo "$x_path")
            x_name=$(_getConfigName "XHTTP" "$label" "$server_ip")
            x_encoded_name=$(python3 -c "import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1]))" "$x_name" || echo "$x_name")
            lines+="vless://${uuid}@${connect_host}:443?security=tls&type=xhttp&path=${x_enc_path}&mode=packet-up&alpn=http%2F1.1&host=${x_domain}&sni=${x_domain}&fp=chrome&allowInsecure=0#${x_encoded_name}"$'\n'
        fi
    fi

    local filename safe
    safe=$(_safeLabel "$label")
    filename=$(_subFilename "$label" "$token")
    # Удаляем старые файлы этого label (любой токен) перед записью нового
    rm -f "${SUB_DIR}/${safe}_"*.txt "${SUB_DIR}/${safe}_"*.html
    printf '%s' "$lines" | base64 -w 0 > "${SUB_DIR}/${filename}"
    chmod 644 "${SUB_DIR}/${filename}"
    buildUserHtmlPage "$uuid" "$label" "$token" "$lines" || true
}

# Конвертирует vless:// URL в Clash YAML блок
_vless_to_clash() {
    local url="$1"
    python3 -c "
import sys, urllib.parse
url = sys.argv[1]
try:
    without_scheme = url[len('vless://'):]
    at = without_scheme.index('@')
    uuid = without_scheme[:at]
    rest = without_scheme[at+1:]
    hash_pos = rest.find('#')
    name = urllib.parse.unquote(rest[hash_pos+1:]) if hash_pos >= 0 else ''
    rest = rest[:hash_pos] if hash_pos >= 0 else rest
    q = rest.find('?')
    hostport = rest[:q] if q >= 0 else rest
    params_str = rest[q+1:] if q >= 0 else ''
    host, port = hostport.rsplit(':', 1) if ':' in hostport else (hostport, '443')
    params = dict(urllib.parse.parse_qsl(params_str))
    net = params.get('type', 'tcp')
    security = params.get('security', 'none')
    if net == 'ws':
        path = urllib.parse.unquote(params.get('path', '/'))
        sni = params.get('sni', host)
        ws_host = params.get('host', sni)
        print(f'  - name: \"{name}\"')
        print(f'    type: vless')
        print(f'    server: {host}')
        print(f'    port: {port}')
        print(f'    uuid: {uuid}')
        print(f'    tls: true')
        print(f'    servername: {sni}')
        print(f'    client-fingerprint: chrome')
        print(f'    network: ws')
        print(f'    ws-opts:')
        print(f'      path: {path}')
        print(f'      headers:')
        print(f'        Host: {ws_host}')
    elif net == 'xhttp':
        path = urllib.parse.unquote(params.get('path', '/'))
        sni = params.get('sni', host)
        xhost = params.get('host', sni)
        mode = params.get('mode', 'packet-up')
        print(f'  - name: \"{name}\"')
        print(f'    type: vless')
        print(f'    server: {host}')
        print(f'    port: {port}')
        print(f'    uuid: {uuid}')
        print(f'    tls: true')
        print(f'    servername: {sni}')
        print(f'    client-fingerprint: chrome')
        print(f'    network: xhttp')
        print(f'    alpn:')
        print(f'      - http/1.1')
        print(f'    xhttp-opts:')
        print(f'      path: {path}')
        print(f'      mode: {mode}')
        print(f'      host: \"{xhost}\"')
    elif security == 'reality':
        sni = params.get('sni', '')
        pbk = params.get('pbk', '')
        sid = params.get('sid', '')
        print(f'  - name: \"{name}\"')
        print(f'    type: vless')
        print(f'    server: {host}')
        print(f'    port: {port}')
        print(f'    uuid: {uuid}')
        print(f'    tls: true')
        print(f'    servername: {sni}')
        print(f'    client-fingerprint: chrome')
        print(f'    reality-opts:')
        print(f'      public-key: {pbk}')
        print(f'      short-id: {sid}')
        print(f'    flow: xtls-rprx-vision')
    elif security == 'tls' and params.get('flow', '') == 'xtls-rprx-vision':
        sni = params.get('sni', host)
        print(f'  - name: \"{name}\"')
        print(f'    type: vless')
        print(f'    server: {host}')
        print(f'    port: {port}')
        print(f'    uuid: {uuid}')
        print(f'    tls: true')
        print(f'    servername: {sni}')
        print(f'    client-fingerprint: chrome')
        print(f'    network: tcp')
        print(f'    flow: xtls-rprx-vision')
except Exception as e:
    pass
" "$url"
}

buildUserHtmlPage() {
    local uuid="$1" label="$2" token="$3" lines="$4"
    local domain safe htmlfile sub_url
    local btn_copy_text btn_copy_all_text btn_copied_text btn_qr_text
    domain=$(_getDomain)
    [ -z "$domain" ] && return 0
    btn_copy_text=$(msg btn_copy)
    btn_copy_all_text=$(msg btn_copy_all)
    btn_copied_text=$(msg btn_copied)
    btn_qr_text=$(msg btn_qr)
    safe=$(_safeLabel "$label")
    htmlfile="${SUB_DIR}/${safe}_${token}.html"
    sub_url="https://${domain}/sub/${safe}_${token}.txt"

    local configs=()
    while IFS= read -r line; do
        [ -n "$line" ] && configs+=("$line")
    done <<< "$lines"

    # Clash YAML
    local clash_yaml=""
    for cfg in "${configs[@]}"; do
        local block
        block=$(_vless_to_clash "$cfg")
        [ -n "$block" ] && clash_yaml="${clash_yaml}${block}"$'\n\n'
    done
    clash_yaml="${clash_yaml%$'\n\n'}"

    cat > "$htmlfile" << 'HTMLEOF'
<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex,nofollow">
<title>VPN Config</title>
<style>
  @import url('https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;600;700&display=swap');
  :root {
    --bg: #0c0c10; --surface: #13131a; --border: #1e1e2e; --text: #cdd6f4;
    --muted: #6c7086; --green: #a6e3a1; --blue: #89b4fa; --sky: #89dceb;
    --peach: #fab387; --mauve: #cba6f7; --yellow: #f9e2af;
  }
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: 'JetBrains Mono', monospace; background: var(--bg); color: var(--text); min-height: 100vh; padding: 0 0 60px; }
  .header { background: var(--surface); border-bottom: 1px solid var(--border); padding: 18px 20px 14px; display: flex; align-items: center; gap: 12px; position: sticky; top: 0; z-index: 10; }
  .header-icon { font-size: 22px; line-height: 1; }
  .header-label { font-size: 15px; font-weight: 700; color: var(--blue); letter-spacing: .04em; }
  .header-badge { margin-left: auto; font-size: 10px; background: var(--border); color: var(--muted); padding: 3px 8px; border-radius: 20px; letter-spacing: .05em; }
  .tabs { display: flex; gap: 2px; padding: 12px 16px 0; border-bottom: 1px solid var(--border); overflow-x: auto; scrollbar-width: none; }
  .tabs::-webkit-scrollbar { display: none; }
  .tab { padding: 8px 14px; font-size: 11px; font-weight: 600; font-family: inherit; color: var(--muted); background: none; border: none; border-bottom: 2px solid transparent; cursor: pointer; white-space: nowrap; letter-spacing: .04em; transition: color .15s, border-color .15s; text-transform: uppercase; }
  .tab:hover { color: var(--text); }
  .tab.active { color: var(--blue); border-bottom-color: var(--blue); }
  .panel { display: none; padding: 16px; }
  .panel.active { display: block; }
  .section-title { font-size: 10px; font-weight: 700; color: var(--muted); text-transform: uppercase; letter-spacing: .1em; margin: 20px 0 8px; }
  .section-title:first-child { margin-top: 0; }
  .card { background: var(--surface); border: 1px solid var(--border); border-radius: 10px; padding: 12px 14px; margin-bottom: 10px; }
  .card-header { display: flex; align-items: center; gap: 8px; margin-bottom: 10px; }
  .badge { display: inline-block; padding: 3px 9px; border-radius: 5px; font-size: 10px; font-weight: 700; letter-spacing: .06em; text-transform: uppercase; flex-shrink: 0; }
  .badge-ws      { background: #1a2e1a; color: var(--green); }
  .badge-reality { background: #2e1f14; color: var(--peach); }
  .badge-xhttp   { background: #1a1f3a; color: var(--blue); }
  .badge-clash   { background: #221a38; color: var(--mauve); }
  .badge-all     { background: #252025; color: var(--yellow); }
  .badge-sub     { background: #14253a; color: var(--sky); }
  .card-name { font-size: 11px; color: var(--muted); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .url-box { font-size: 10.5px; line-height: 1.6; color: var(--text); background: var(--bg); border: 1px solid var(--border); border-radius: 6px; padding: 9px 10px; word-break: break-all; white-space: pre-wrap; margin-bottom: 10px; max-height: 120px; overflow-y: auto; scrollbar-width: thin; scrollbar-color: var(--border) transparent; cursor: text; user-select: all; }
  .url-box.tall { max-height: 220px; }
  .url-box::-webkit-scrollbar { width: 4px; }
  .url-box::-webkit-scrollbar-thumb { background: var(--border); border-radius: 2px; }
  .actions { display: flex; gap: 8px; flex-wrap: wrap; align-items: center; }
  .btn { background: var(--border); color: var(--text); border: none; padding: 7px 13px; border-radius: 6px; cursor: pointer; font-size: 11px; font-family: inherit; font-weight: 600; transition: background .15s, transform .1s; letter-spacing: .03em; }
  .btn:hover { background: #2a2a3e; }
  .btn:active { transform: scale(.97); }
  .btn.success { background: #1a2e1a; color: var(--green); }
  .btn-qr { background: #1a253a; color: var(--blue); }
  .btn-qr:hover { background: #1f2d47; }
  .qr-wrap { display: none; margin-top: 12px; text-align: center; }
  .qr-wrap.open { display: block; }
  .qr-inner { display: inline-block; background: #fff; padding: 10px; border-radius: 8px; }
  .sub-hero { background: linear-gradient(135deg, #13131a 0%, #1a1a2e 100%); border: 1px solid #2a2a4a; border-radius: 12px; padding: 16px; margin-bottom: 14px; }
  .sub-hero .url-box { font-size: 11px; max-height: none; margin-bottom: 12px; border-color: #2a2a4a; color: var(--sky); }
  .app-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; margin-top: 6px; }
  @media (max-width: 420px) { .app-grid { grid-template-columns: 1fr; } }
  .app-card { background: var(--surface); border: 1px solid var(--border); border-radius: 10px; padding: 12px; }
  .app-name { font-size: 12px; font-weight: 700; color: var(--blue); margin-bottom: 4px; }
  .app-platform { font-size: 10px; color: var(--muted); margin-bottom: 8px; }
  .app-note { font-size: 10px; color: var(--yellow); background: #2a2510; border: 1px solid #3a3010; border-radius: 5px; padding: 5px 8px; margin-bottom: 8px; line-height: 1.5; }
  .app-steps { font-size: 10.5px; color: var(--text); line-height: 1.7; list-style: none; padding: 0; }
  .app-steps li::before { content: attr(data-n) ". "; color: var(--mauve); font-weight: 700; }
</style>
</head>
<body>
HTMLEOF

    # ── Dynamic content ──────────────────────────────────────────

    local cards_html="" all_lines_text="" vless_count=0 card_idx=0

    for cfg in "${configs[@]}"; do
        local proto_label="VLESS" badge_cls="" disp_name=""

        if echo "$cfg" | grep -q "type=ws"; then
            proto_label="WS+TLS"; badge_cls="ws"
        elif echo "$cfg" | grep -q "security=reality"; then
            proto_label="Reality"; badge_cls="reality"
        elif echo "$cfg" | grep -q "type=xhttp"; then
            proto_label="XHTTP"; badge_cls="xhttp"
        fi

        # Имя конфига из фрагмента URL
        disp_name=$(python3 -c "
import sys, urllib.parse
url = sys.argv[1]
h = url.find('#')
print(urllib.parse.unquote(url[h+1:]) if h >= 0 else '')
" "$cfg" || echo "")

        cards_html+="<div class=\"card\">"
        cards_html+="<div class=\"card-header\">"
        cards_html+="<span class=\"badge badge-${badge_cls}\">${proto_label}</span>"
        [ -n "$disp_name" ] && cards_html+="<span class=\"card-name\">${disp_name}</span>"
        cards_html+="</div>"
        cards_html+="<div class=\"url-box\" id=\"cfg${card_idx}\">${cfg}</div>"
        cards_html+="<div class=\"actions\">"
        cards_html+="<button class=\"btn\" onclick=\"cp('cfg${card_idx}',this)\">📋 ${btn_copy_text}</button>"
        cards_html+="<button class=\"btn btn-qr\" onclick=\"tqr(${card_idx})\">⬛ ${btn_qr_text}</button>"
        cards_html+="</div>"
        cards_html+="<div class=\"qr-wrap\" id=\"qr${card_idx}\"><div class=\"qr-inner\" id=\"qrc${card_idx}\"></div></div>"
        cards_html+="</div>"

        all_lines_text="${all_lines_text}${cfg}"$'\n'
        vless_count=$((vless_count + 1))
        card_idx=$((card_idx + 1))
    done

    # Блок «Все конфиги»
    local copy_all_card=""
    if [ "$vless_count" -gt 1 ]; then
        local all_escaped
        all_escaped=$(printf '%s' "${all_lines_text}" | sed 's/</\&lt;/g; s/>/\&gt;/g')
        copy_all_card="<div class=\"section-title\">Все конфиги</div>"
        copy_all_card+="<div class=\"card\">"
        copy_all_card+="<div class=\"card-header\"><span class=\"badge badge-all\">ALL · ${vless_count}</span></div>"
        copy_all_card+="<div class=\"url-box tall\" id=\"cfgall\">${all_escaped}</div>"
        copy_all_card+="<div class=\"actions\">"
        copy_all_card+="<button class=\"btn\" onclick=\"cp('cfgall',this)\">📋 ${btn_copy_all_text}</button>"
        copy_all_card+="</div></div>"
    fi

    # Блок Clash
    local clash_card=""
    if [ -n "$clash_yaml" ]; then
        local clash_escaped
        clash_escaped=$(printf '%s' "$clash_yaml" | sed 's/</\&lt;/g; s/>/\&gt;/g')
        clash_card="<div class=\"section-title\">Clash Meta / Mihomo</div>"
        clash_card+="<div class=\"card\">"
        clash_card+="<div class=\"card-header\"><span class=\"badge badge-clash\">Clash</span></div>"
        clash_card+="<div class=\"url-box tall\" id=\"cfgclash\">${clash_escaped}</div>"
        clash_card+="<div class=\"actions\">"
        clash_card+="<button class=\"btn\" onclick=\"cp('cfgclash',this)\">📋 ${btn_copy_text}</button>"
        clash_card+="</div></div>"
    fi

    local sub_escaped
    sub_escaped=$(printf '%s' "$sub_url" | sed 's/</\&lt;/g; s/>/\&gt;/g')

    cat >> "$htmlfile" << DYNEOF
<div class="header">
  <span class="header-icon">📡</span>
  <span class="header-label">${label}</span>
  <span class="header-badge">VPN CONFIG</span>
</div>

<div class="tabs">
  <button class="tab active" onclick="switchTab('configs',this)">Конфиги</button>
  <button class="tab" onclick="switchTab('subscription',this)">Подписка</button>
  <button class="tab" onclick="switchTab('apps',this)">Приложения</button>
</div>

<div id="tab-configs" class="panel active">
  <div class="section-title">Протоколы</div>
  ${cards_html}
  ${copy_all_card}
  ${clash_card}
</div>

<div id="tab-subscription" class="panel">
  <div class="section-title">Ссылка на подписку</div>
  <div class="sub-hero">
    <div class="url-box" id="cfgsub" style="max-height:none">${sub_escaped}</div>
    <div class="actions">
      <button class="btn" onclick="cp('cfgsub',this)">📋 ${btn_copy_text}</button>
      <button class="btn btn-qr" onclick="tqr('sub')">⬛ ${btn_qr_text}</button>
    </div>
    <div class="qr-wrap" id="qrsub"><div class="qr-inner" id="qrcsub"></div></div>
  </div>
  <p style="font-size:10px;color:var(--muted);margin-top:8px">
    Ссылка обновляется автоматически. Добавьте её в приложение один раз — конфиги будут обновляться сами.
  </p>
</div>

<div id="tab-apps" class="panel">
  <div class="section-title">Как подключиться</div>
  <div class="app-grid">

    <div class="app-card">
      <div class="app-name">v2rayNG</div>
      <div class="app-platform">Android</div>
      <ul class="app-steps">
        <li data-n="1">Открыть v2rayNG</li>
        <li data-n="2">Нажать «+» → «Подписка»</li>
        <li data-n="3">Вставить Subscription URL</li>
        <li data-n="4">Обновить группу</li>
        <li data-n="5">Выбрать сервер → Подключиться</li>
      </ul>
    </div>

    <div class="app-card">
      <div class="app-name">Hiddify</div>
      <div class="app-platform">Android / iOS / Desktop</div>
      <ul class="app-steps">
        <li data-n="1">Открыть Hiddify</li>
        <li data-n="2">«+» → «Добавить по ссылке»</li>
        <li data-n="3">Вставить Subscription URL</li>
        <li data-n="4">Нажать «Подключиться»</li>
      </ul>
    </div>

    <div class="app-card">
      <div class="app-name">Streisand</div>
      <div class="app-platform">iOS</div>
      <ul class="app-steps">
        <li data-n="1">Открыть Streisand</li>
        <li data-n="2">«+» → «URL»</li>
        <li data-n="3">Вставить Subscription URL</li>
        <li data-n="4">Импортировать и подключиться</li>
      </ul>
    </div>

    <div class="app-card">
      <div class="app-name">Clash Meta / Mihomo</div>
      <div class="app-platform">Windows / macOS / Linux / Android</div>
      <div class="app-note">⚠ XHTTP: требуется версия ≥ v1.19.23 (апрель 2026). Обновите ядро если версия старше.</div>
      <ul class="app-steps">
        <li data-n="1">Открыть вкладку «Конфиги»</li>
        <li data-n="2">Скопировать блок Clash</li>
        <li data-n="3">Вставить в config.yaml в раздел proxies:</li>
        <li data-n="4">Перезапустить Clash</li>
      </ul>
    </div>

  </div>
</div>

<script src="https://cdnjs.cloudflare.com/ajax/libs/qrcodejs/1.0.0/qrcode.min.js"></script>
<script>
var Q = {};
function switchTab(name, btn) {
  document.querySelectorAll('.panel').forEach(function(p){ p.classList.remove('active'); });
  document.querySelectorAll('.tab').forEach(function(t){ t.classList.remove('active'); });
  document.getElementById('tab-' + name).classList.add('active');
  btn.classList.add('active');
}
function cp(id, btn) {
  var el = document.getElementById(id);
  var text = el.innerText.trim();
  navigator.clipboard.writeText(text).then(function() {
    var orig = btn.textContent;
    btn.textContent = '✓ ${btn_copied_text}';
    btn.classList.add('success');
    setTimeout(function() { btn.textContent = orig; btn.classList.remove('success'); }, 1500);
  }).catch(function() {
    var range = document.createRange();
    range.selectNodeContents(el);
    var sel = window.getSelection();
    sel.removeAllRanges();
    sel.addRange(range);
  });
}
function tqr(id) {
  var w = document.getElementById('qr' + id);
  var open = w.classList.toggle('open');
  if (open && !Q[id]) {
    var srcId = (id === 'sub') ? 'cfgsub' : 'cfg' + id;
    var text = document.getElementById(srcId).innerText.trim();
    new QRCode(document.getElementById('qrc' + id), { text: text, width: 200, height: 200, correctLevel: QRCode.CorrectLevel.M });
    Q[id] = true;
  }
}
</script>
</body>
</html>
DYNEOF
    chmod 644 "$htmlfile"
}


rebuildAllSubFiles() {
    local skip_restart="${1:-false}"
    [ ! -f "$USERS_FILE" ] && return 0
    applyNginxSub || true
    local count=0
    while IFS='|' read -r uuid label token; do
        [ -z "$uuid" ] && continue
        buildUserSubFile "$uuid" "$label" "$token" && count=$((count+1))
    done < "$USERS_FILE"

    # Перезапускаем сервисы ОДИН раз в самом конце а не на каждого пользователя
    [ "$skip_restart" != "true" ] && systemctl try-restart xray xray-reality xray-xhttp || true

    echo "${green}$(msg done) ($count)${reset}"
}

getSubUrl() {
    local label="$1" token="$2"
    local domain
    domain=$(_getDomain)
    [ -z "$domain" ] && { echo ""; return 1; }
    echo "https://${domain}/sub/$(_subFilename "$label" "$token")"
}

# ── Список ────────────────────────────────────────────────────────

showUsersList() {
    _initUsersFile
    local count
    count=$(_usersCount)
    if [ "$count" -eq 0 ]; then
        echo "${yellow}$(msg users_empty)${reset}"; return 1
    fi
    echo -e "${cyan}$(msg users_list) ($count):${reset}\n"
    local i=1
    while IFS='|' read -r uuid label token; do
        [ -z "$uuid" ] && continue
        printf "  ${green}%2d.${reset} %-20s  %s\n" "$i" "$label" "$uuid"
        i=$((i+1))
    done < "$USERS_FILE"
    echo ""
}

# ── CRUD ──────────────────────────────────────────────────────────

addUser() {
    _initUsersFile
    read -rp "$(msg users_label_prompt)" label
    [ -z "$label" ] && label="user$(( $(_usersCount) + 1 ))"
    label=$(echo "$label" | tr -d '|')
    local uuid token
    uuid=$(cat /proc/sys/kernel/random/uuid)
    token=$(_genToken)
    echo "${uuid}|${label}|${token}" >> "$USERS_FILE"
    _applyUsersToConfigs
    buildUserSubFile "$uuid" "$label" "$token" || true
    echo "${green}$(msg users_added): $label ($uuid)${reset}"
}

deleteUser() {
    _initUsersFile
    local count
    count=$(_usersCount)
    [ "$count" -eq 0 ] && { echo "${yellow}$(msg users_empty)${reset}"; return; }
    [ "$count" -eq 1 ] && { echo "${red}$(msg users_last_warn)${reset}"; return; }
    showUsersList
    read -rp "$(msg users_del_prompt)" num
    if ! [[ "$num" =~ ^[0-9]+$ ]] || [ "$num" -lt 1 ] || [ "$num" -gt "$count" ]; then
        echo "${red}$(msg invalid)${reset}"; return 1
    fi
    local label token safe
    label=$(_labelByLine "$num")
    token=$(_tokenByLine "$num")
    safe=$(_safeLabel "$label")
    echo -e "${red}$(msg users_del_confirm) '$label'? $(msg yes_no)${reset}"
    read -r confirm
    [[ "$confirm" != "y" ]] && { echo "$(msg cancel)"; return 0; }
    rm -f "${SUB_DIR}/${safe}_"*.txt "${SUB_DIR}/${safe}_"*.html
    sed -i "${num}d" "$USERS_FILE"
    _applyUsersToConfigs
    echo "${green}$(msg removed): $label${reset}"
}

renameUser() {
    _initUsersFile
    local count
    count=$(_usersCount)
    [ "$count" -eq 0 ] && { echo "${yellow}$(msg users_empty)${reset}"; return; }
    showUsersList
    read -rp "$(msg users_rename_prompt)" num
    if ! [[ "$num" =~ ^[0-9]+$ ]] || [ "$num" -lt 1 ] || [ "$num" -gt "$count" ]; then
        echo "${red}$(msg invalid)${reset}"; return 1
    fi
    local uuid old_label token old_safe
    uuid=$(_uuidByLine "$num")
    old_label=$(_labelByLine "$num")
    token=$(_tokenByLine "$num")
    old_safe=$(_safeLabel "$old_label")
    read -rp "$(msg users_new_label) [$old_label]: " new_label
    [ -z "$new_label" ] && return
    new_label=$(echo "$new_label" | tr -d '|')
    rm -f "${SUB_DIR}/${old_safe}_"*.txt "${SUB_DIR}/${old_safe}_"*.html
    sed -i "${num}s/.*/${uuid}|${new_label}|${token}/" "$USERS_FILE"
    _applyUsersToConfigs
    buildUserSubFile "$uuid" "$new_label" "$token" || true
    echo "${green}$(msg saved): $old_label → $new_label${reset}"
}

# ── QR + Subscription ─────────────────────────────────────────────

showUserQR() {
    _initUsersFile
    local count
    count=$(_usersCount)
    [ "$count" -eq 0 ] && { echo "${yellow}$(msg users_empty)${reset}"; return; }
    showUsersList
    read -rp "$(msg users_qr_prompt)" num
    if ! [[ "$num" =~ ^[0-9]+$ ]] || [ "$num" -lt 1 ] || [ "$num" -gt "$count" ]; then
        echo "${red}$(msg invalid)${reset}"; return 1
    fi

    local uuid label token
    uuid=$(_uuidByLine "$num")
    label=$(_labelByLine "$num")
    token=$(_tokenByLine "$num")

    local domain
    domain=$(_getDomain)

    # Пересоздаём файлы подписки (txt + html)
    buildUserSubFile "$uuid" "$label" "$token" || true

    local sub_url safe html_url
    sub_url=$(getSubUrl "$label" "$token")
    safe=$(_safeLabel "$label")
    html_url="https://${domain}/sub/${safe}_${token}.html"

    command -v qrencode || installPackage "qrencode"

    echo -e "${cyan}================================================================${reset}"
    echo -e "   $(_getCachedFlag) ${label}"
    echo -e "${cyan}================================================================${reset}"
    echo ""
    if [ -n "$sub_url" ]; then
        echo -e "${cyan}[ Subscription URL ]${reset}"
        qrencode -s 3 -m 2 -t ANSIUTF8 "$sub_url" || true
        echo -e "\n${green}${sub_url}${reset}"
        echo -e "${yellow}v2rayNG: + → Subscription group → URL${reset}"
        # Дополнительная ссылка по IP (когда домен ещё не проброшен через CDN)
        local server_ip
        server_ip=$(getServerIP)
        if [ -n "$server_ip" ] && [ "$server_ip" != "$domain" ]; then
            local ip_url ip_html_url
            ip_url="https://${server_ip}/sub/$(_subFilename "$label" "$token")"
            ip_html_url="https://${server_ip}/sub/${safe}_${token}.html"
            echo -e ""
            echo -e "${cyan}[ Subscription URL (by IP) ]${reset}"
            echo -e "${green}${ip_url}${reset}"
            echo -e "${yellow}v2rayNG: + → Subscription group → URL${reset}"
        fi
    fi
    echo ""
    echo -e "${cyan}[ $(msg users_html_hint) ]${reset}"
    echo -e "${green}${html_url}${reset}"
    if [ -n "$server_ip" ] && [ "$server_ip" != "$domain" ]; then
        echo -e "${green}${ip_html_url}${reset} ${yellow}(IP)${reset}"
    fi
    echo -e "${cyan}================================================================${reset}"
}


# ── Меню ──────────────────────────────────────────────────────────

manageUsers() {
    set +e
    _initUsersFile
    while true; do
        clear
        echo -e "${cyan}$(msg users_title)${reset}\n"
        showUsersList
        echo -e "${green}1.${reset} $(msg users_add)"
        echo -e "${green}2.${reset} $(msg users_del)"
        echo -e "${green}3.${reset} QR + Subscription URL"
        echo -e "${green}4.${reset} $(msg users_rename)"
        echo -e "${green}5.${reset} $(msg menu_sub)"
        echo ""
        echo -e "${green}0.${reset} $(msg back)"
        echo ""
        read -rp "$(msg choose)" choice
        case $choice in
            1) addUser ;;
            2) deleteUser ;;
            3) showUserQR ;;
            4) renameUser ;;
            5) rebuildAllSubFiles ;;
            0) break ;;
        esac
        [ "$choice" = "0" ] && continue
        echo -e "\n${cyan}$(msg press_enter)${reset}"
        read -r
    done
}