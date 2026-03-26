#!/bin/bash
# =================================================================
# users.sh — Управление пользователями
# Формат users.conf: UUID|LABEL|TOKEN
# Sub URL: https://<domain>/sub/<label>_<token>.txt
# =================================================================

USERS_FILE="/usr/local/etc/xray/users.conf"
SUB_DIR="/usr/local/etc/xray/sub"

# ── Утилиты ───────────────────────────────────────────────────────

_usersCount() { [ -f "$USERS_FILE" ] && grep -c '.' "$USERS_FILE" 2>/dev/null || echo 0; }
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
        ip=$(getServerIP 2>/dev/null)
        _VWN_FLAG_CACHE=$(_getCountryFlag "$ip" 2>/dev/null || echo "🌐")
        export _VWN_FLAG_CACHE
    fi
    echo "$_VWN_FLAG_CACHE"
}

# Домен из wsSettings.host (с fallback на xhttpSettings для обратной совместимости)
_getDomain() {
    local d=""
    [ -f "$configPath" ] && \
        d=$(jq -r '.inbounds[0].streamSettings.wsSettings.host // .inbounds[0].streamSettings.xhttpSettings.host // ""' "$configPath" 2>/dev/null)
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

    systemctl restart xray 2>/dev/null || true
    systemctl restart xray-reality 2>/dev/null || true
}

# ── Инициализация ─────────────────────────────────────────────────

_initUsersFile() {
    [ -f "$USERS_FILE" ] && return 0
    mkdir -p "$(dirname "$USERS_FILE")"

    local existing_uuid=""
    if [ -f "$configPath" ]; then
        existing_uuid=$(jq -r '.inbounds[0].settings.clients[0].id // ""' "$configPath" 2>/dev/null)
    fi
    # Если в WS нет UUID — берём из Reality
    if [ -z "$existing_uuid" ] || [ "$existing_uuid" = "null" ]; then
        if [ -f "$realityConfigPath" ]; then
            existing_uuid=$(jq -r '.inbounds[0].settings.clients[0].id // ""' "$realityConfigPath" 2>/dev/null)
        fi
    fi

    if [ -n "$existing_uuid" ] && [ "$existing_uuid" != "null" ]; then
        local token
        token=$(_genToken)
        echo "${existing_uuid}|default|${token}" > "$USERS_FILE"
        echo "${green}$(msg users_migrated): $existing_uuid${reset}"
        # Синхронизируем UUID в оба конфига
        _applyUsersToConfigs 2>/dev/null || true
        buildUserSubFile "$existing_uuid" "default" "$token" 2>/dev/null || true
    fi
}

# ── Subscription ──────────────────────────────────────────────────

buildUserSubFile() {
    local uuid="$1" label="$2" token="$3"
    mkdir -p "$SUB_DIR"
    applyNginxSub 2>/dev/null || true

    local domain lines="" server_ip flag
    domain=$(_getDomain)
    server_ip=$(getServerIP)
    flag=$(_getCountryFlag "$server_ip")

    if [ -f "$configPath" ] && [ -n "$domain" ]; then
        local wp wep name encoded_name connect_host
        wp=$(jq -r '.inbounds[0].streamSettings.wsSettings.path // .inbounds[0].streamSettings.xhttpSettings.path // ""' "$configPath" 2>/dev/null)
        wep=$(python3 -c "import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1],safe='/'))" "$wp" 2>/dev/null || echo "$wp")
        connect_host=$(getConnectHost 2>/dev/null || echo "$domain")
        [ -z "$connect_host" ] && connect_host="$domain"
        name="${flag} VL-WS-CDN | ${label} ${flag}"
        encoded_name=$(python3 -c "import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1]))" "$name" 2>/dev/null || echo "$name")
        lines+="vless://${uuid}@${connect_host}:443?encryption=none&security=tls&sni=${domain}&fp=chrome&type=ws&host=${domain}&path=${wep}#${encoded_name}"$'\n'
    fi

    if [ -f "$realityConfigPath" ]; then
        local r_uuid r_port r_shortId r_destHost r_pubKey r_name r_encoded_name
        # Ищем UUID этого пользователя в clients reality конфига
        # Если не найден (старая установка без мульти-юзеров) — берём первого
        r_uuid=$(jq -r --arg u "$uuid" \
            '.inbounds[0].settings.clients[] | select(.id==$u) | .id' \
            "$realityConfigPath" 2>/dev/null | head -1)
        [ -z "$r_uuid" ] && \
            r_uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$realityConfigPath" 2>/dev/null)
        r_port=$(jq -r '.inbounds[0].port' "$realityConfigPath" 2>/dev/null)
        r_shortId=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$realityConfigPath" 2>/dev/null)
        r_destHost=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$realityConfigPath" 2>/dev/null)
        r_pubKey=$(vwn_conf_get REALITY_PUBKEY 2>/dev/null)
        [ -z "$r_pubKey" ] && r_pubKey=$(grep "PublicKey:" /usr/local/etc/xray/reality_client.txt 2>/dev/null | awk '{print $NF}')
        r_name="${flag} VL-Reality | ${label} ${flag}"
        r_encoded_name=$(python3 -c "import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1]))" "$r_name" 2>/dev/null || echo "$r_name")
        lines+="vless://${r_uuid}@${server_ip}:${r_port}?encryption=none&security=reality&sni=${r_destHost}&fp=chrome&pbk=${r_pubKey}&sid=${r_shortId}&type=tcp&flow=xtls-rprx-vision#${r_encoded_name}"$'\n'
    fi

    local filename safe
    safe=$(_safeLabel "$label")
    filename=$(_subFilename "$label" "$token")
    # Удаляем старые файлы этого label (любой токен) перед записью нового
    rm -f "${SUB_DIR}/${safe}_"*.txt "${SUB_DIR}/${safe}_"*.html
    printf '%s' "$lines" | base64 -w 0 > "${SUB_DIR}/${filename}"
    chmod 600 "${SUB_DIR}/${filename}"
    buildUserHtmlPage "$uuid" "$label" "$token" "$lines" 2>/dev/null || true
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
        print(f'- name: \"{name}\"')
        print(f'  type: vless')
        print(f'  server: {host}')
        print(f'  port: {port}')
        print(f'  uuid: {uuid}')
        print(f'  tls: true')
        print(f'  servername: {sni}')
        print(f'  client-fingerprint: chrome')
        print(f'  network: ws')
        print(f'  ws-opts:')
        print(f'    path: {path}')
        print(f'    headers:')
        print(f'      Host: {ws_host}')
    elif security == 'reality':
        sni = params.get('sni', '')
        pbk = params.get('pbk', '')
        sid = params.get('sid', '')
        print(f'- name: \"{name}\"')
        print(f'  type: vless')
        print(f'  server: {host}')
        print(f'  port: {port}')
        print(f'  uuid: {uuid}')
        print(f'  tls: true')
        print(f'  servername: {sni}')
        print(f'  client-fingerprint: chrome')
        print(f'  reality-opts:')
        print(f'    public-key: {pbk}')
        print(f'    short-id: {sid}')
        print(f'  flow: xtls-rprx-vision')
except Exception as e:
    pass
" "$url" 2>/dev/null
}

buildUserHtmlPage() {
    local uuid="$1" label="$2" token="$3" lines="$4"
    local domain safe htmlfile sub_url
    domain=$(_getDomain)
    [ -z "$domain" ] && return 0
    safe=$(_safeLabel "$label")
    htmlfile="${SUB_DIR}/${safe}_${token}.html"
    sub_url="https://${domain}/sub/${safe}_${token}.txt"

    local configs=()
    while IFS= read -r line; do
        [ -n "$line" ] && configs+=("$line")
    done <<< "$lines"

    # Clash YAML — собираем из всех конфигов
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
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:monospace;background:#0f0f0f;color:#d0d0d0;padding:16px;max-width:700px;margin:0 auto}
h2{color:#6c7086;font-size:11px;font-weight:700;text-transform:uppercase;letter-spacing:.08em;margin:20px 0 8px}
.card{background:#1a1a1a;border:1px solid #2a2a2a;border-radius:8px;padding:12px;margin-bottom:10px}
.proto{display:inline-block;padding:3px 10px;border-radius:4px;font-size:11px;font-weight:700;margin-bottom:8px}
.ws{background:#253025;color:#a6e3a1}
.reality{background:#302520;color:#fab387}
.sub{background:#252540;color:#89dceb}
.clash{background:#2a2040;color:#cba6f7}
.url{font-size:11px;word-break:break-all;color:#cdd6f4;line-height:1.5;margin-bottom:8px;padding:6px;background:#111;border-radius:4px;white-space:pre-wrap}
.actions{display:flex;gap:8px;flex-wrap:wrap;align-items:center}
.btn{background:#313244;color:#cdd6f4;border:none;padding:6px 14px;border-radius:4px;cursor:pointer;font-size:11px}
.btn:hover{background:#45475a}
.qr-btn{background:#1e3a5f;color:#89b4fa}
.qr-btn:hover{background:#264a6f}
.qr-wrap{display:none;margin-top:10px;text-align:center}
.qr-wrap.open{display:block}
.qr-inner{display:inline-block;background:#fff;padding:8px;border-radius:6px}
</style>
</head>
<body>
HTMLEOF

    # Заголовок с именем пользователя
    echo "<h1 style='color:#89b4fa;font-size:15px;margin-bottom:16px;padding-bottom:8px;border-bottom:1px solid #2a2a2a'>📡 ${label}</h1>" >> "$htmlfile"

    local i=0
    for cfg in "${configs[@]}"; do
        local proto_label="VLESS" proto_class=""
        echo "$cfg" | grep -q "type=ws"            && proto_label="WS+TLS"  && proto_class="ws"
        echo "$cfg" | grep -q "security=reality"   && proto_label="Reality" && proto_class="reality"
        cat >> "$htmlfile" << CARDEOF
<div class="card">
  <span class="proto ${proto_class}">${proto_label}</span>
  <div class="url" id="u${i}">${cfg}</div>
  <div class="actions">
    <button class="btn" onclick="cp('u${i}',this)">📋 Копировать</button>
    <button class="btn qr-btn" onclick="tqr(${i})">QR-код</button>
  </div>
  <div class="qr-wrap" id="qr${i}"><div class="qr-inner" id="qrc${i}"></div></div>
</div>
CARDEOF
        i=$((i+1))
    done

    # Clash блок
    if [ -n "$clash_yaml" ]; then
        cat >> "$htmlfile" << CLASHEOF
<h2>Clash Meta / Mihomo</h2>
<div class="card">
  <span class="proto clash">Clash</span>
  <div class="url" id="uclash">${clash_yaml}</div>
  <div class="actions">
    <button class="btn" onclick="cp('uclash',this)">📋 Копировать</button>
  </div>
</div>
CLASHEOF
    fi

    # Subscription
    cat >> "$htmlfile" << SUBEOF
<h2>Subscription URL</h2>
<div class="card">
  <span class="proto sub">SUB</span>
  <div class="url" id="usub">${sub_url}</div>
  <div class="actions">
    <button class="btn" onclick="cp('usub',this)">📋 Копировать</button>
    <button class="btn qr-btn" onclick="tqr('sub')">QR-код</button>
  </div>
  <div class="qr-wrap" id="qrsub"><div class="qr-inner" id="qrcsub"></div></div>
</div>
<p style="margin-top:16px;font-size:10px;color:#45475a;text-align:center">v2rayNG / Hiddify: + → Subscription group → URL</p>
<script>
var Q={};
function cp(id,btn){
  navigator.clipboard.writeText(document.getElementById(id).textContent.trim()).then(function(){
    var o=btn.textContent;btn.textContent='✓ Скопировано';
    setTimeout(function(){btn.textContent=o;},1500);
  });
}
function tqr(id){
  var w=document.getElementById('qr'+id);
  var open=w.classList.toggle('open');
  if(open&&!Q[id]){
    var el=document.getElementById(id==='sub'?'usub':'u'+id);
    // Simple inline QR generator (no external CDN)
    var qr=generateQR(el.textContent.trim());
    document.getElementById('qrc'+id).innerHTML=qr;
    Q[id]=true;
  }
}
// Minimal QR code generator (inline, no external dependencies)
function generateQR(text){
  // Simple placeholder - shows text in a styled box with XSS protection
  var el=document.createElement('div');
  el.style.cssText='background:#fff;padding:12px;border-radius:6px;font-family:monospace;font-size:10px;word-break:break-all;max-width:200px;text-align:center;color:#000';
  el.textContent=text;
  return el.outerHTML;
}
</script></body></html>
SUBEOF
    chmod 600 "$htmlfile"
}


rebuildAllSubFiles() {
    [ ! -f "$USERS_FILE" ] && return 0
    applyNginxSub 2>/dev/null || true
    local count=0
    while IFS='|' read -r uuid label token; do
        [ -z "$uuid" ] && continue
        buildUserSubFile "$uuid" "$label" "$token" && count=$((count+1))
    done < "$USERS_FILE"
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
    buildUserSubFile "$uuid" "$label" "$token" 2>/dev/null || true
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
    buildUserSubFile "$uuid" "$new_label" "$token" 2>/dev/null || true
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
    buildUserSubFile "$uuid" "$label" "$token" 2>/dev/null || true

    local sub_url safe html_url
    sub_url=$(getSubUrl "$label" "$token")
    safe=$(_safeLabel "$label")
    html_url="https://${domain}/sub/${safe}_${token}.html"

    command -v qrencode &>/dev/null || installPackage "qrencode"

    echo -e "${cyan}================================================================${reset}"
    echo -e "   $(_getCachedFlag) ${label}"
    echo -e "${cyan}================================================================${reset}"
    echo ""
    if [ -n "$sub_url" ]; then
        echo -e "${cyan}[ Subscription URL ]${reset}"
        qrencode -s 1 -m 1 -t ANSIUTF8 "$sub_url" 2>/dev/null || true
        echo -e "\n${green}${sub_url}${reset}"
        echo -e "${yellow}v2rayNG: + → Subscription group → URL${reset}"
    fi
    echo ""
    echo -e "${cyan}[ $(msg users_html_hint) ]${reset}"
    echo -e "${green}${html_url}${reset}"
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