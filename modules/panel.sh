#!/bin/bash
# =================================================================
# panel.sh — Установка и управление веб-панелью VWN
# =================================================================

PANEL_CONF="/usr/local/etc/xray/panel.conf"
PANEL_PY="/usr/local/lib/vwn/web_panel.py"
PANEL_HTML="/usr/local/lib/vwn/panel.html"
PANEL_PORT=8444

# ── Генерация секрета ─────────────────────────────────────────────
_panel_gen_secret() {
    python3 -c "import secrets; print(secrets.token_hex(32))" 2>/dev/null \
        || cat /dev/urandom | tr -dc 'a-f0-9' | head -c 64
}

# ── Хэш пароля ────────────────────────────────────────────────────
# ИСПРАВЛЕНО: пароль передаётся через stdin, не через аргумент командной строки
# (иначе виден в `ps aux`)
_panel_hash_password() {
    local password="$1"
    printf '%s' "$password" | python3 -c "
import sys, os

password = sys.stdin.read()

try:
    import bcrypt
    h = bcrypt.hashpw(password.encode(), bcrypt.gensalt(rounds=12)).decode()
    print('bcrypt:' + h)
except ImportError:
    print('ERROR: bcrypt is required. Run: pip3 install bcrypt')
    sys.exit(1)
"
}

# ── Добавление location в nginx ───────────────────────────────────
_panel_add_nginx_location() {
    local port="$1" panel_path="$2"
    [ ! -f "$nginxPath" ] && return 1

    # Удаляем все старые location'ы панели (включая /panel/ и случайные пути)
    python3 - "$nginxPath" << 'PYEOF'
import sys, re
path = sys.argv[1]
with open(path) as f:
    c = f.read()
# Удаляем location'ы панели по маркеру proxy_pass на 127.0.0.1:8444
c = re.sub(r'\n\s*location\s+[^\{]*\{\s*\n\s*proxy_pass\s+http://127\.0\.0\.1:8444.*?\}\n?', '\n', c, flags=re.DOTALL)
with open(path, 'w') as f:
    f.write(c)
PYEOF

    # Добавляем новый перед последней закрывающей скобкой
    python3 - "$nginxPath" "$port" "$panel_path" << 'PYEOF'
import sys, re
path, port, panel_path = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f:
    c = f.read()
block = f"""
    location {panel_path}/ {{
        proxy_pass http://127.0.0.1:{port}/;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 300s;
        proxy_buffering off;
        add_header X-Frame-Options DENY always;
        add_header X-Content-Type-Options nosniff always;
        add_header Cache-Control 'no-store, no-cache' always;
    }}
"""
c = re.sub(r'(\n\})\s*$', block + r'\1', c, count=1)
with open(path, 'w') as f:
    f.write(c)
PYEOF
}

# ── Systemd unit ──────────────────────────────────────────────────
_panel_write_service() {
    local port="$1"
    cat > /etc/systemd/system/vwn-panel.service << EOF
[Unit]
Description=VWN Web Panel
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 $PANEL_PY
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
NoNewPrivileges=yes
# Ограничиваем доступные адреса — панель только для localhost
IPAddressDeny=any
IPAddressAllow=127.0.0.0/8
IPAddressAllow=::1
# Дополнительная изоляция
ProtectSystem=strict
ReadWritePaths=/usr/local/etc/xray /root/vwn-backups /var/log
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

# ── Генерация случайного пути ─────────────────────────────────────
_panel_gen_path() {
    local t1 t2
    t1=$(cat /dev/urandom | tr -dc 'a-f0-9' | head -c 32)
    t2=$(cat /dev/urandom | tr -dc 'a-f0-9' | head -c 32)
    echo "/${t1}/${t2}"
}

# ── Основная установка панели ─────────────────────────────────────
installPanel() {
    echo -e "${cyan}$(msg panel_installing)${reset}"

    local secret pass_hash port="$PANEL_PORT" panel_path
    if [ -f "$PANEL_CONF" ]; then
        secret=$(grep "^PANEL_SECRET=" "$PANEL_CONF" | cut -d= -f2-)
        pass_hash=$(grep "^PANEL_PASS_HASH=" "$PANEL_CONF" | cut -d= -f2-)
        port=$(grep "^PANEL_PORT=" "$PANEL_CONF" | cut -d= -f2- || echo "$PANEL_PORT")
        panel_path=$(grep "^PANEL_PATH=" "$PANEL_CONF" | cut -d= -f2-)
    fi

    [ -z "$secret" ] && secret=$(_panel_gen_secret)
    [ -z "$panel_path" ] && panel_path=$(_panel_gen_path)

    if [ -z "$pass_hash" ]; then
        echo ""
        echo "  1) Ввести пароль вручную"
        echo "  2) Сгенерировать автоматически"
        read -rp "$(msg choose) [1]: " pw_choice
        case "${pw_choice:-1}" in
            2)
                local password
                password=$(cat /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 16)
                echo ""
                echo -e "  ${yellow}Сгенерированный пароль: ${green}${password}${reset}"
                echo -e "  ${yellow}Сохраните его!${reset}"
                echo ""
                pass_hash=$(_panel_hash_password "$password")
                unset password
                ;;
            *)
                local password password2
                while true; do
                    read -rsp "$(msg panel_enter_password): " password; echo
                    [ ${#password} -lt 8 ] && { echo "${red}$(msg panel_pass_short)${reset}"; continue; }
                    read -rsp "$(msg panel_confirm_password): " password2; echo
                    [ "$password" = "$password2" ] && break
                    echo "${red}$(msg panel_pass_mismatch)${reset}"
                done
                pass_hash=$(_panel_hash_password "$password")
                unset password password2
                ;;
        esac
    fi

    mkdir -p "$(dirname "$PANEL_CONF")"
    cat > "$PANEL_CONF" << EOF
PANEL_SECRET=${secret}
PANEL_PASS_HASH=${pass_hash}
PANEL_PORT=${port}
PANEL_PATH=${panel_path}
EOF
    chmod 600 "$PANEL_CONF"

    # Скачиваем файлы если нужно
    local need_download=false
    [ ! -f "$PANEL_PY" ]   && need_download=true
    [ ! -f "$PANEL_HTML" ] && need_download=true

    if $need_download; then
        echo -e "${cyan}$(msg panel_downloading)${reset}"
        for fname in web_panel.py panel.html; do
            local dest
            [ "$fname" = "web_panel.py" ] && dest="$PANEL_PY" || dest="$PANEL_HTML"
            if [ ! -f "$dest" ]; then
                curl -fsSL --connect-timeout 15 \
                    "${GITHUB_RAW}/modules/${fname}" -o "$dest" 2>/dev/null \
                    && echo "  ${fname}: ${green}OK${reset}" \
                    || echo "  ${fname}: ${red}FAIL${reset}"
            else
                echo "  ${fname}: ${green}already present${reset}"
            fi
        done
        chmod 700 "$PANEL_PY"
    fi

    # Устанавливаем bcrypt если доступен pip
    echo -e "${cyan}Installing bcrypt (secure password hashing)...${reset}"
    if python3 -m pip install bcrypt --break-system-packages -q 2>/dev/null; then
        echo "  bcrypt: ${green}OK${reset}"
    else
        # Fallback: системный пакет
        ${PACKAGE_MANAGEMENT_INSTALL:-apt -y install} python3-bcrypt 2>/dev/null || true
        echo "  bcrypt: ${yellow}fallback to system package${reset}"
    fi

    # Добавляем location в nginx
    if [ -f "$nginxPath" ]; then
        echo -e "${cyan}$(msg panel_nginx_setup)${reset}"
        _panel_add_nginx_location "$port" "$panel_path"
        if nginx -t &>/dev/null; then
            systemctl reload nginx
            echo "  nginx: ${green}OK${reset}"
        else
            echo "  nginx: ${red}FAIL — конфиг не изменён${reset}"
            nginx -t
        fi
    else
        echo "${yellow}$(msg panel_nginx_later)${reset}"
    fi

    # Systemd
    _panel_write_service "$port"
    systemctl enable vwn-panel
    systemctl restart vwn-panel

    sleep 1
    if systemctl is-active --quiet vwn-panel; then
        echo -e "\n${green}================================================================${reset}"
        echo -e "   $(msg panel_installed)"
        local domain
        domain=$(grep -E '^\s*server_name\s+' "$nginxPath" 2>/dev/null | grep -v '_' | awk '{print $2}' | tr -d ';' | head -1)
        if [ -n "$domain" ]; then
            echo -e "   URL: ${green}https://${domain}${panel_path}/${reset}"
        else
            echo -e "   $(msg panel_url_later)"
        fi
        # Читаем PANEL_PATH из конфига для отображения
        local saved_path
        saved_path=$(grep "^PANEL_PATH=" "$PANEL_CONF" 2>/dev/null | cut -d= -f2-)
        if [ -n "$saved_path" ]; then
            echo -e "   Path: ${green}${saved_path}/${reset}"
        fi
        echo -e "${green}================================================================${reset}"
    else
        echo "${red}$(msg panel_start_fail)${reset}"
        journalctl -u vwn-panel -n 20 --no-pager
    fi
}

# ── Basic Auth (.htpasswd) ────────────────────────────────────────
enablePanelBasicAuth() {
    local panel_path
    panel_path=$(grep "^PANEL_PATH=" "$PANEL_CONF" 2>/dev/null | cut -d= -f2-)
    [ -z "$panel_path" ] && { echo "${red}Panel not configured.${reset}"; return 1; }

    local user="admin"
    local passwd
    read -rsp "$(msg panel_enter_password): " passwd; echo
    [ ${#passwd} -lt 8 ] && { echo "${red}Min 8 chars${reset}"; return 1; }

    local hash
    hash=$(openssl passwd -apr1 "$passwd")
    echo "${user}:${hash}" > /etc/nginx/.panel_htpasswd
    chmod 600 /etc/nginx/.panel_htpasswd
    unset passwd

    python3 - "$nginxPath" "$panel_path" << 'PYEOF'
import sys, re
path, panel_path = sys.argv[1], sys.argv[2]
with open(path) as f: c = f.read()
auth_block = '        auth_basic "VWN Panel";\n        auth_basic_user_file /etc/nginx/.panel_htpasswd;\n'
c = re.sub(r'(location ' + re.escape(panel_path) + r'/\s*\{)', r'\1\n' + auth_block, c, count=1)
with open(path, 'w') as f: f.write(c)
PYEOF

    nginx -t && systemctl reload nginx
    echo "${green}Basic Auth enabled for ${panel_path}/${reset}"
}

disablePanelBasicAuth() {
    python3 - "$nginxPath" << 'PYEOF'
import sys, re
path = sys.argv[1]
with open(path) as f: c = f.read()
c = re.sub(r'\s*auth_basic[^\n]*\n\s*auth_basic_user_file[^\n]*\n', '\n', c)
with open(path, 'w') as f: f.write(c)
PYEOF
    nginx -t && systemctl reload nginx
    rm -f /etc/nginx/.panel_htpasswd
    echo "${green}Basic Auth disabled${reset}"
}

getPanelAuthStatus() {
    [ -f /etc/nginx/.panel_htpasswd ] \
        && echo "${green}Basic Auth ON${reset}" \
        || echo "${red}Basic Auth OFF${reset}"
}

# ── Смена пароля ──────────────────────────────────────────────────
panelChangePassword() {
    [ ! -f "$PANEL_CONF" ] && { echo "${red}$(msg panel_not_installed)${reset}"; return 1; }

    local password password2
    while true; do
        read -rsp "$(msg panel_enter_password): " password; echo
        [ ${#password} -lt 8 ] && { echo "${red}$(msg panel_pass_short)${reset}"; continue; }
        read -rsp "$(msg panel_confirm_password): " password2; echo
        [ "$password" = "$password2" ] && break
        echo "${red}$(msg panel_pass_mismatch)${reset}"
    done

    local pass_hash
    pass_hash=$(_panel_hash_password "$password")
    unset password password2

    # Безопасная замена через python3
    python3 - "$PANEL_CONF" "$pass_hash" << 'PYEOF'
import sys
path, new_hash = sys.argv[1], sys.argv[2]
with open(path) as f:
    lines = f.readlines()
with open(path, 'w') as f:
    for line in lines:
        if line.startswith('PANEL_PASS_HASH='):
            f.write(f'PANEL_PASS_HASH={new_hash}\n')
        else:
            f.write(line)
PYEOF

    # Сигнал на перечитывание конфига без перезапуска
    systemctl kill -s SIGHUP vwn-panel 2>/dev/null || systemctl restart vwn-panel
    echo "${green}$(msg panel_pass_changed)${reset}"
}

# ── Статус панели ─────────────────────────────────────────────────
getPanelStatus() {
    if systemctl is-active --quiet vwn-panel 2>/dev/null; then
        local domain saved_path
        domain=$(grep -E '^\s*server_name\s+' "$nginxPath" 2>/dev/null | grep -v '_' | awk '{print $2}' | tr -d ';' | head -1)
        saved_path=$(grep "^PANEL_PATH=" "$PANEL_CONF" 2>/dev/null | cut -d= -f2-)
        if [ -n "$domain" ] && [ -n "$saved_path" ]; then
            echo "${green}RUNNING — https://${domain}${saved_path}/${reset}"
        elif [ -n "$domain" ]; then
            echo "${green}RUNNING — https://${domain}/panel/${reset}"
        else
            echo "${green}RUNNING${reset}"
        fi
    else
        echo "${red}STOPPED${reset}"
    fi
}

# ── Удаление панели ───────────────────────────────────────────────
removePanel() {
    echo -e "${red}$(msg panel_remove_confirm) $(msg yes_no)${reset}"
    read -r confirm
    [[ "$confirm" != "y" ]] && { echo "$(msg cancel)"; return 0; }

    systemctl stop vwn-panel 2>/dev/null || true
    systemctl disable vwn-panel 2>/dev/null || true
    rm -f /etc/systemd/system/vwn-panel.service
    systemctl daemon-reload

    # Удаляем location панели по маркеру proxy_pass на 127.0.0.1:8444
    if [ -f "$nginxPath" ]; then
        python3 - "$nginxPath" << 'PYEOF'
import sys, re
path = sys.argv[1]
with open(path) as f:
    c = f.read()
c = re.sub(r'\n\s*location\s+[^\{]*\{\s*\n\s*proxy_pass\s+http://127\.0\.0\.1:8444.*?\}\n?', '\n', c, flags=re.DOTALL)
with open(path, 'w') as f:
    f.write(c)
PYEOF
        nginx -t && systemctl reload nginx
    fi

    echo "${green}$(msg removed)${reset}"
    # Конфиг с паролем оставляем — при переустановке не нужно вводить снова
}

# ── Меню управления панелью ───────────────────────────────────────
managePanel() {
    set +e
    while true; do
        clear
        echo -e "${cyan}$(msg panel_menu_title)${reset}"
        echo -e "  $(msg status): $(getPanelStatus)"
        echo ""
        echo -e "${green}1.${reset} $(msg panel_open)"
        echo -e "${green}2.${reset} $(msg panel_change_pass)"
        echo -e "${green}3.${reset} $(msg panel_restart)"
        echo -e "${green}4.${reset} $(msg panel_view_log)"
        echo -e "  Auth: $(getPanelAuthStatus)"
        echo ""
        echo -e "${green}5.${reset} $(msg panel_reinstall)"
        echo -e "${green}6.${reset} $(msg panel_remove)"
        echo -e "${green}7.${reset} Enable Basic Auth (.htpasswd)"
        echo -e "${green}8.${reset} Disable Basic Auth"
        echo -e "${green}0.${reset} $(msg back)"
        echo ""
        read -rp "$(msg choose)" choice
        case $choice in
            1)
                local domain saved_path
                domain=$(grep -E '^\s*server_name\s+' "$nginxPath" 2>/dev/null | grep -v '_' | awk '{print $2}' | tr -d ';' | head -1)
                saved_path=$(grep "^PANEL_PATH=" "$PANEL_CONF" 2>/dev/null | cut -d= -f2-)
                if [ -n "$domain" ] && [ -n "$saved_path" ]; then
                    echo "${green}https://${domain}${saved_path}/${reset}"
                elif [ -n "$domain" ]; then
                    echo "${green}https://${domain}/panel/${reset}"
                else
                    echo "${yellow}$(msg panel_url_later)${reset}"
                fi
                ;;
            2) panelChangePassword ;;
            3) systemctl restart vwn-panel && echo "${green}OK${reset}" ;;
            4) journalctl -u vwn-panel -n 50 --no-pager ;;
            5) installPanel ;;
            6) removePanel ;;
            7) enablePanelBasicAuth ;;
            8) disablePanelBasicAuth ;;
            0) break ;;
        esac
        [ "$choice" = "0" ] && continue
        echo -e "\n${cyan}$(msg press_enter)${reset}"
        read -r
    done
}
