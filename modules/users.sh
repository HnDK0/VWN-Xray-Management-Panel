#!/bin/bash
# =================================================================
# users.sh — Управление пользователями
# Формат users.conf: UUID|LABEL|TOKEN
# Sub URL: https://<domain>/sub/<label>_<token>.txt
# =================================================================

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

_getCachedFlag() {
    if [ -z "${_VWN_FLAG_CACHE:-}" ]; then
        local ip
        ip=$(getServerIP 2>/dev/null)
        _VWN_FLAG_CACHE=$(_getCountryFlag "$ip" 2>/dev/null || echo "🌐")
        export _VWN_FLAG_CACHE
    fi
    echo "$_VWN_FLAG_CACHE"
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
        jq --argjson c "$clients_x" '
            .inbounds = [.inbounds[] |
                if (.settings.clients != null) then .settings.clients = $c
                else . end]
        ' "$configPath" > "${configPath}.tmp" && mv "${configPath}.tmp" "$configPath"
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
        existing_uuid=$(get_uuid)
    fi
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
    domain=$(get_domain)
    server_ip=$(getServerIP)
    flag=$(_getCachedFlag)

    if [ -f "$configPath" ] && [ -n "$domain" ]; then
        local wp wep name encoded_name connect_host
        wp=$(get_ws_path)
        wep=$(python3 -c "import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1],safe='/'))" "$wp" 2>/dev/null || echo "$wp")
        connect_host=$(getConnectHost 2>/dev/null || echo "$domain")
        [ -z "$connect_host" ] && connect_host="$domain"

        # WS
        name="${flag} VL-WS-CDN | ${label} ${flag}"
        encoded_name=$(python3 -c "import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1]))" "$name" 2>/dev/null || echo "$name")
        lines+="vless://${uuid}@${connect_host}:443?encryption=none&security=tls&sni=${domain}&fp=chrome&type=ws&host=${domain}&path=${wep}#${encoded_name}"$'\n'

        # XHTTP
        local xhttp_path xep xhttp_name xhttp_encoded_name
        xhttp_path=$(get_xhttp_path)
        [ -z "$xhttp_path" ] && xhttp_path="${wp}x"
        xep=$(python3 -c "import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1],safe='/'))" "$xhttp_path" 2>/dev/null || echo "$xhttp_path")
        xhttp_name="${flag} VL-XHTTP-CDN | ${label} ${flag}"
        xhttp_encoded_name=$(python3 -c "import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1]))" "$xhttp_name" 2>/dev/null || echo "$xhttp_name")
        lines+="vless://${uuid}@${connect_host}:443?encryption=none&security=tls&sni=${domain}&fp=chrome&type=xhttp&host=${domain}&path=${xep}&mode=auto#${xhttp_encoded_name}"$'\n'

        # gRPC
        local grpc_service grpc_name grpc_encoded_name
        grpc_service=$(get_grpc_service)
        [ -z "$grpc_service" ] && grpc_service="${wp#/}g"
        grpc_name="${flag} VL-gRPC-CDN | ${label} ${flag}"
        grpc_encoded_name=$(python3 -c "import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1]))" "$grpc_name" 2>/dev/null || echo "$grpc_name")
        lines+="vless://${uuid}@${connect_host}:443?encryption=none&security=tls&sni=${domain}&fp=chrome&type=grpc&serviceName=${grpc_service}&mode=gun#${grpc_encoded_name}"$'\n'
    fi

    if [ -f "$realityConfigPath" ]; then
        local r_uuid r_port r_shortId r_destHost r_pubKey r_name r_encoded_name
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
    rm -f "${SUB_DIR}/${safe}_"*.txt "${SUB_DIR}/${safe}_"*.html
    printf '%s' "$lines" | base64 -w 0 > "${SUB_DIR}/${filename}"
    chmod 644 "${SUB_DIR}/${filename}"

    buildUserHtmlPage "$uuid" "$label" "$token" "$lines" 2>/dev/null || true
}

buildUserHtmlPage() {
    local uuid="$1" label="$2" token="$3" lines="$4"
    local domain safe htmlfile sub_url
    domain=$(get_domain)
    [ -z "$domain" ] && return 0
    safe=$(_safeLabel "$label")
    htmlfile="${SUB_DIR}/${safe}_${token}.html"
    sub_url="https://${domain}/sub/${safe}_${token}.txt"

    local configs=()
    while IFS= read -r line; do
        [ -n "$line" ] && configs+=("$line")
    done <<< "$lines"

    cat > "$htmlfile" << HTMLEOF
<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex,nofollow">
<title>VWN — ${label}</title>
<script src="https://cdnjs.cloudflare.com/ajax/libs/qrcodejs/1.0.0/qrcode.min.js"></script>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:monospace;background:#0f0f0f;color:#d0d0d0;padding:12px;max-width:860px;margin:0 auto}
h2{color:#89b4fa;font-size:14px;margin:18px 0 8px;border-top:1px solid #222;padding-top:12px}
h2:first-of-type{border-top:none;margin-top:0}
.row{background:#1a1a1a;border:1px solid #2a2a2a;border-radius:6px;padding:6px 8px;display:flex;flex-wrap:wrap;align-items:center;gap:6px;margin-bottom:6px}
.lbl{background:#252540;color:#89b4fa;padding:4px 8px;border-radius:4px;font-size:11px;font-weight:700;white-space:nowrap;min-width:120px;text-align:center}
.lbl.sub{background:#254025;color:#a6e3a1}
.cfg{flex:1;white-space:nowrap;overflow-x:auto;padding:6px 8px;background:#111;border-radius:4px;color:#a6e3a1;font-size:11px;scrollbar-width:none}
.cfg::-webkit-scrollbar{display:none}
.btn{border:1px solid #444;padding:5px 10px;border-radius:4px;cursor:pointer;font-size:11px;font-weight:700;background:#222;color:#ccc;white-space:nowrap}
.btn:hover{background:#89b4fa;color:#111;border-color:#89b4fa}
.btn.qr{color:#89b4fa;border-color:#89b4fa}
.btn.qr:hover{background:#89b4fa;color:#111}
.modal{display:none;position:fixed;inset:0;background:rgba(0,0,0,.85);z-index:99;justify-content:center;align-items:center}
.modal.open{display:flex}
.mbox{background:#1a1a1a;border:1px solid #89b4fa;border-radius:10px;padding:20px;text-align:center}
#qrcode{background:#fff;padding:8px;border-radius:6px;margin-bottom:10px}
.cls{background:#c31e1e;color:#fff;border:none;padding:7px 18px;border-radius:4px;cursor:pointer;font-size:12px}
@media(max-width:580px){.lbl{min-width:100%;margin-bottom:2px}.cfg{min-width:100%}}
</style>
</head>
<body>
<h2>Subscription URL</h2>
<div class="row">
  <div class="lbl sub">Subscription</div>
  <div class="cfg" id="c0">${sub_url}</div>
  <button class="btn" onclick="cp('c0',this)">Copy</button>
  <button class="btn qr" onclick="qr('c0')">QR</button>
</div>
<h2>Конфиги</h2>
HTMLEOF

    local i=1
    for cfg in "${configs[@]}"; do
        local cname
        cname=$(python3 -c "import sys,urllib.parse; u=sys.argv[1]; print(urllib.parse.unquote(u.split('#')[-1]) if '#' in u else u[:30])" "$cfg" 2>/dev/null || echo "Config $i")
        cat >> "$htmlfile" << HTMLEOF
<div class="row">
  <div class="lbl">${cname}</div>
  <div class="cfg" id="c${i}">${cfg}</div>
  <button class="btn" onclick="cp('c${i}',this)">Copy</button>
  <button class="btn qr" onclick="qr('c${i}')">QR</button>
</div>
HTMLEOF
        i=$(( i + 1 ))
    done

    cat >> "$htmlfile" << 'HTMLEOF'
<div id="modal" class="modal" onclick="if(event.target===this)closeQr()">
  <div class="mbox"><div id="qrcode"></div><button class="cls" onclick="closeQr()">Close</button></div>
</div>
<script>
function cp(id,btn){
  navigator.clipboard.writeText(document.getElementById(id).innerText)
    .then(()=>{var t=btn.innerText;btn.innerText='OK';btn.style.background='#a6e3a1';btn.style.color='#111';
      setTimeout(()=>{btn.innerText=t;btn.style.background='';btn.style.color=''},1500)})
    .catch(()=>{var r=document.createRange();r.selectNode(document.getElementById(id));window.getSelection().removeAllRanges();window.getSelection().addRange(r);document.execCommand('copy')});
}
function qr(id){
  var txt=document.getElementById(id).innerText;
  var box=document.getElementById('qrcode');
  box.innerHTML='';
  new QRCode(box,{text:txt,width:256,height:256,colorDark:'#000',colorLight:'#fff',correctLevel:QRCode.CorrectLevel.L});
  document.getElementById('modal').classList.add('open');
}
function closeQr(){document.getElementById('modal').classList.remove('open')}
</script>
</body></html>
HTMLEOF
    chmod 644 "$htmlfile"
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
    domain=$(get_domain)
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
    rm -f "${SUB_DIR}/${safe}_"*.txt
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
    rm -f "${SUB_DIR}/${old_safe}_"*.txt
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

    command -v qrencode &>/dev/null || installPackage "qrencode"

    local domain
    domain=$(get_domain)

    # WebSocket
    if [ -f "$configPath" ] && [ -n "$domain" ]; then
        local wp wep url_ws server_ip flag name encoded_name connect_host
        wp=$(get_ws_path)
        wep=$(python3 -c "import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1],safe='/'))" "$wp" 2>/dev/null || echo "$wp")
        server_ip=$(getServerIP)
        flag=$(_getCachedFlag)
        connect_host=$(getConnectHost 2>/dev/null || echo "$domain")
        [ -z "$connect_host" ] && connect_host="$domain"
        name="${flag} VL-WS-CDN | ${label} ${flag}"
        encoded_name=$(python3 -c "import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1]))" "$name" 2>/dev/null || echo "$name")
        url_ws="vless://${uuid}@${connect_host}:443?encryption=none&security=tls&sni=${domain}&fp=chrome&type=ws&host=${domain}&path=${wep}#${encoded_name}"

        echo -e "${cyan}================================================================${reset}"
        echo -e "   ${name}"
        echo -e "${cyan}================================================================${reset}\n"

        echo -e "${cyan}[ 1. URI ссылка (v2rayNG / Hiddify / Nekoray) ]${reset}"
        qrencode -s 1 -m 1 -t ANSIUTF8 "$url_ws" 2>/dev/null || true
        echo -e "\n${green}${url_ws}${reset}\n"

        echo -e "${cyan}[ 2. Clash Meta / Mihomo ]${reset}"
        echo -e "${yellow}- name: ${name}
  type: vless
  server: ${connect_host}
  port: 443
  uuid: ${uuid}
  tls: true
  servername: ${domain}
  client-fingerprint: chrome
  network: ws
  ws-opts:
    path: ${wp}
    headers:
      Host: ${domain}${reset}\n"

        echo -e "${cyan}================================================================${reset}"

        # XHTTP
        local xhttp_path xep url_xhttp xhttp_name xhttp_encoded
        xhttp_path=$(get_xhttp_path)
        [ -z "$xhttp_path" ] && xhttp_path="${wp}x"
        xep=$(python3 -c "import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1],safe='/'))" "$xhttp_path" 2>/dev/null || echo "$xhttp_path")
        xhttp_name="${flag} VL-XHTTP-CDN | ${label} ${flag}"
        xhttp_encoded=$(python3 -c "import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1]))" "$xhttp_name" 2>/dev/null || echo "$xhttp_name")
        url_xhttp="vless://${uuid}@${connect_host}:443?encryption=none&security=tls&sni=${domain}&fp=chrome&type=xhttp&host=${domain}&path=${xep}&mode=auto#${xhttp_encoded}"
        echo -e "\n${cyan}=== ${xhttp_name} ===${reset}"
        qrencode -s 1 -m 1 -t ANSIUTF8 "$url_xhttp" 2>/dev/null || true
        echo -e "\n${green}${url_xhttp}${reset}\n"

        # gRPC
        local grpc_service url_grpc grpc_name grpc_encoded
        grpc_service=$(get_grpc_service)
        [ -z "$grpc_service" ] && grpc_service="${wp#/}g"
        grpc_name="${flag} VL-gRPC-CDN | ${label} ${flag}"
        grpc_encoded=$(python3 -c "import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1]))" "$grpc_name" 2>/dev/null || echo "$grpc_name")
        url_grpc="vless://${uuid}@${connect_host}:443?encryption=none&security=tls&sni=${domain}&fp=chrome&type=grpc&serviceName=${grpc_service}&mode=gun#${grpc_encoded}"
        echo -e "${cyan}=== ${grpc_name} ===${reset}"
        qrencode -s 1 -m 1 -t ANSIUTF8 "$url_grpc" 2>/dev/null || true
        echo -e "\n${green}${url_grpc}${reset}\n"
    fi

    # Reality
    if [ -f "$realityConfigPath" ]; then
        local r_uuid r_port r_shortId r_destHost r_pubKey r_serverIP r_flag r_name r_encoded_name url_reality
        r_uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$realityConfigPath" 2>/dev/null)
        r_port=$(jq -r '.inbounds[0].port' "$realityConfigPath" 2>/dev/null)
        r_shortId=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$realityConfigPath" 2>/dev/null)
        r_destHost=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$realityConfigPath" 2>/dev/null)
        r_pubKey=$(vwn_conf_get REALITY_PUBKEY 2>/dev/null)
        [ -z "$r_pubKey" ] && r_pubKey=$(grep "PublicKey:" /usr/local/etc/xray/reality_client.txt 2>/dev/null | awk '{print $NF}')
        r_serverIP=$(getServerIP)
        r_flag=$(_getCachedFlag)
        r_name="${r_flag} VL-Reality | ${label} ${r_flag}"
        r_encoded_name=$(python3 -c "import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1]))" "$r_name" 2>/dev/null || echo "$r_name")
        url_reality="vless://${r_uuid}@${r_serverIP}:${r_port}?encryption=none&security=reality&sni=${r_destHost}&fp=chrome&pbk=${r_pubKey}&sid=${r_shortId}&type=tcp&flow=xtls-rprx-vision#${r_encoded_name}"

        echo -e "\n${cyan}=== ${r_name} ===${reset}"
        qrencode -s 1 -m 1 -t ANSIUTF8 "$url_reality" 2>/dev/null || true
        echo -e "\n${green}${url_reality}${reset}\n"
    fi

    # Subscription URL + HTML-страница
    buildUserSubFile "$uuid" "$label" "$token" 2>/dev/null || true
    local sub_url safe html_url
    sub_url=$(getSubUrl "$label" "$token")
    safe=$(_safeLabel "$label")
    html_url="https://${domain}/sub/${safe}_${token}.html"
    if [ -n "$sub_url" ]; then
        echo -e "${cyan}[ Subscription URL — для клиентов (v2rayNG, Hiddify...) ]${reset}"
        qrencode -s 1 -m 1 -t ANSIUTF8 "$sub_url" 2>/dev/null || true
        echo -e "\n${green}${sub_url}${reset}"
        echo -e "${yellow}v2rayNG: + → Subscription group → URL${reset}"
        echo ""
        echo -e "${cyan}[ $(msg users_html_hint) ]${reset}"
        echo -e "${green}${html_url}${reset}"
    fi

    echo -e "\n${cyan}================================================================${reset}"
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