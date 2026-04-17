#!/bin/bash
# =================================================================
# security.sh — UFW, BBR, Fail2Ban, WebJail, SSH
# =================================================================

# Автоматически определяет доступный бэкенд фаервола для Fail2Ban
# Возвращает подходящий banaction: nftables-multiport / iptables-multiport
detectFirewallBackend() {
    # Сначала проверяем nftables (современный стандарт)
    if command -v nft &>/dev/null && nft list tables 2>/dev/null | grep -q '^inet '; then
        echo "nftables-multiport"
        return
    fi
    
    # Фоллбек на iptables если он доступен
    if command -v iptables &>/dev/null; then
        echo "iptables-multiport"
        return
    fi
    
    # Если ничего не найдено — пусть fail2ban сам решает по умолчанию
    echo ""
}

changeSshPort() {
    read -rp "$(msg ssh_new_port)" new_ssh_port
    if ! [[ "$new_ssh_port" =~ ^[0-9]+$ ]] || [ "$new_ssh_port" -lt 1 ] || [ "$new_ssh_port" -gt 65535 ]; then
        echo "${red}$(msg invalid_port)${reset}"; return 1
    fi

    # Проверяем что порт свободен
    if ss -tlnp 2>/dev/null | grep -q ":${new_ssh_port} "; then
        echo "${red}ERROR: Port $new_ssh_port is already in use!${reset}"
        return 1
    fi

    local old_ssh_port
    old_ssh_port=$(grep -E "^Port " /etc/ssh/sshd_config | awk '{print $2}' | head -1)
    old_ssh_port="${old_ssh_port:-22}"

    ufw allow "$new_ssh_port"/tcp comment 'SSH'
    sed -i "s/^#\?Port [0-9]*/Port $new_ssh_port/" /etc/ssh/sshd_config
    systemctl restart sshd 2>/dev/null || systemctl restart ssh
    
    # Проверяем что sshd запустился успешно
    sleep 2
    if ! systemctl is-active --quiet sshd 2>/dev/null && ! systemctl is-active --quiet ssh 2>/dev/null; then
        echo "${red}ERROR: sshd failed to start on new port! Rolling back...${reset}"
        # Откат на старый порт
        sed -i "s/^#\?Port [0-9]*/Port $old_ssh_port/" /etc/ssh/sshd_config
        systemctl restart sshd 2>/dev/null || systemctl restart ssh
        # Закрываем новый порт в фаерволе
        ufw delete allow "$new_ssh_port"/tcp &>/dev/null
        echo "${yellow}Rolled back to old port $old_ssh_port${reset}"
        return 1
    fi

    echo "${green}$(msg ssh_changed) $new_ssh_port.${reset}"
    echo "${yellow}$(msg ssh_close_old)${reset}"

    # Если fail2ban установлен — обновляем порт в [sshd] секции
    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        echo -e "${cyan}$(msg ssh_f2b_update)${reset}"

        # Проверяем доступность бэкенда фаервола
        if ! command -v iptables &>/dev/null && ! command -v nft &>/dev/null; then
            echo "${yellow}WARNING: No firewall backend found, fail2ban may not work properly${reset}"
        fi

        # Определяем backend и logpath как в setupFail2Ban
        local sshd_backend sshd_logpath
        if [ -f /var/log/auth.log ]; then
            sshd_backend="auto"
            sshd_logpath="logpath  = /var/log/auth.log"
        else
            sshd_backend="systemd"
            sshd_logpath=""
        fi

        # Получаем Cloudflare IP для whitelist
        local cf_ips=""
        if command -v curl &>/dev/null; then
            cf_ips=$(curl -fsSL --connect-timeout 5 "https://www.cloudflare.com/ips-v4" 2>/dev/null | tr '\n' ' ' | sed 's/  */ /g')
        fi

        # Определяем актуальный бэкенд
        local ban_action
        ban_action=$(detectFirewallBackend)

        # Перезаписываем jail.local с сохранением [nginx-probe] если есть
        python3 - "$new_ssh_port" "$sshd_backend" "$sshd_logpath" "$cf_ips" "$ban_action" << 'PEOF'
import sys, re

new_port    = sys.argv[1]
backend     = sys.argv[2]
logpath_str = sys.argv[3]
cf_ips      = sys.argv[4]
ban_action  = sys.argv[5]

jail_path = "/etc/fail2ban/jail.local"
try:
    with open(jail_path) as f:
        content = f.read()
except FileNotFoundError:
    sys.exit(0)

logpath_line = ("\n" + logpath_str) if logpath_str else ""

# Новая [sshd] секция с iptables backend
new_sshd = (
    "[sshd]\n"
    "enabled  = true\n"
    "port     = " + new_port + "\n"
    "filter   = sshd\n"
    "backend  = " + backend +
    logpath_line + "\n"
    "maxretry = 3\n"
    "bantime  = 24h"
)

# Заменяем [DEFAULT] секцию — добавляем banaction и ignoreip
default_replacement = (
    "[DEFAULT]\n"
    "# Автоматически определённый бэкенд фаервола\n"
    "banaction = " + ban_action + "\n"
    "bantime  = 2h\n"
    "findtime = 10m\n"
    "maxretry = 5\n"
    "\n"
    "# Whitelist: localhost + Cloudflare IPs (не банить CDN трафик)\n"
    "ignoreip = 127.0.0.1/8 ::1 " + cf_ips + "\n"
)
content = re.sub(
    r'\[DEFAULT\].*?(?=\n\[)',
    default_replacement,
    content,
    flags=re.DOTALL
)

# Заменяем секцию [sshd] целиком — от заголовка до следующей секции или конца файла
content = re.sub(
    r'\[sshd\].*?(?=\n\[|\Z)',
    new_sshd,
    content,
    flags=re.DOTALL
)

with open(jail_path, "w") as f:
    f.write(content)
PEOF

        systemctl restart fail2ban
        echo "${green}$(msg ssh_f2b_updated)${reset}"
    fi
}

enableBBR() {
    if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q "bbr"; then
        echo "${yellow}$(msg bbr_active)${reset}"; return
    fi
    grep -q "tcp_congestion_control=bbr" /etc/sysctl.conf || echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    grep -q "default_qdisc=fq" /etc/sysctl.conf || echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    sysctl -p
    echo "${green}$(msg bbr_enabled)${reset}"
}

setupFail2Ban() {
    echo -e "${cyan}$(msg f2b_setup)${reset}"
    [ -z "${PACKAGE_MANAGEMENT_INSTALL:-}" ] && identifyOS

    # Определяем доступный бэкенд фаервола
    local ban_action
    ban_action=$(detectFirewallBackend)

    ${PACKAGE_MANAGEMENT_INSTALL} "fail2ban" &>/dev/null

    local ssh_port
    ssh_port=$(grep -E "^Port " /etc/ssh/sshd_config | awk '{print $2}' | head -1)
    ssh_port="${ssh_port:-22}"

    # Определяем backend: если auth.log существует — auto, иначе systemd (Ubuntu 22.04+)
    local sshd_backend sshd_logpath
    if [ -f /var/log/auth.log ]; then
        sshd_backend="auto"
        sshd_logpath="logpath  = /var/log/auth.log"
    else
        sshd_backend="systemd"
        sshd_logpath=""
    fi

    # Получаем Cloudflare IP для whitelist (чтобы не банить CDN трафик)
    local cf_ips=""
    if command -v curl &>/dev/null; then
        cf_ips=$(curl -fsSL --connect-timeout 5 "https://www.cloudflare.com/ips-v4" 2>/dev/null | tr '\n' ' ' | sed 's/  */ /g')
    fi

    cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
# Автоматически определённый бэкенд фаервола
banaction = ${ban_action}
bantime  = 2h
findtime = 10m
maxretry = 5

# Whitelist: localhost + Cloudflare IPs (не банить CDN трафик)
ignoreip = 127.0.0.1/8 ::1 ${cf_ips}

[sshd]
enabled  = true
port     = $ssh_port
filter   = sshd
backend  = $sshd_backend
$sshd_logpath
maxretry = 3
bantime  = 24h
EOF

    # Проверяем что fail2ban запустился
    systemctl restart fail2ban 2>/dev/null
    local attempts=0
    while [ $attempts -lt 5 ]; do
        if systemctl is-active --quiet fail2ban 2>/dev/null; then
            break
        fi
        sleep 1
        attempts=$((attempts + 1))
    done

    if ! systemctl is-active --quiet fail2ban 2>/dev/null; then
        echo "${red}fail2ban failed to start. Check logs: journalctl -u fail2ban -n 30${reset}"
        return 1
    fi

    systemctl enable fail2ban 2>/dev/null
    echo "${green}$(msg f2b_ok) $ssh_port).${reset}"
}

removeFail2Ban() {
    echo -e "${red}$(msg f2b_remove_confirm) $(msg yes_no)${reset}"
    read -r confirm
    [[ "$confirm" != "y" ]] && { echo "$(msg cancel)"; return 0; }

    echo -e "${cyan}Removing Fail2Ban...${reset}"

    # Останавливаем сервис
    systemctl stop fail2ban 2>/dev/null || true
    systemctl disable fail2ban 2>/dev/null || true

    # Очищаем правила fail2ban из всех доступных бэкендов
    if command -v iptables &>/dev/null; then
        echo "  Clearing iptables f2b rules..."
        for chain in $(iptables -L -n 2>/dev/null | grep "f2b" | awk '{print $2}' | sort -u); do
            iptables -F "$chain" 2>/dev/null || true
            iptables -X "$chain" 2>/dev/null || true
        done
    fi

    # Очищаем nftables правила если они есть
    if command -v nft &>/dev/null; then
        echo "  Clearing nftables f2b rules..."
        nft list ruleset 2>/dev/null | grep -q 'f2b-' && nft flush ruleset inet f2b 2>/dev/null || true
    fi

    # Удаляем конфиги
    rm -f /etc/fail2ban/jail.local
    rm -f /etc/fail2ban/filter.d/nginx-probe.conf
    rm -f /etc/fail2ban/jail.local.d/protect.conf 2>/dev/null || true
    rm -rf /var/lib/fail2ban 2>/dev/null || true
    rm -f /var/run/fail2ban/fail2ban.sock 2>/dev/null || true

    # Удаляем пакет
    if command -v apt &>/dev/null; then
        apt purge -y fail2ban &>/dev/null || true
        apt autoremove -y &>/dev/null || true
    elif command -v dnf &>/dev/null; then
        dnf remove -y fail2ban &>/dev/null || true
    elif command -v yum &>/dev/null; then
        yum remove -y fail2ban &>/dev/null || true
    fi

    echo "${green}$(msg f2b_removed)${reset}"
}

reinstallFail2Ban() {
    echo -e "${cyan}Reinstalling Fail2Ban...${reset}"

    # Сначала удаляем текущую версию
    systemctl stop fail2ban 2>/dev/null || true
    systemctl disable fail2ban 2>/dev/null || true

    # Очищаем конфиги
    rm -f /etc/fail2ban/jail.local
    rm -f /etc/fail2ban/filter.d/nginx-probe.conf
    rm -rf /var/lib/fail2ban 2>/dev/null || true

    # Очищаем правила fail2ban из всех доступных бэкендов
    if command -v iptables &>/dev/null; then
        for chain in $(iptables -L -n 2>/dev/null | grep "f2b" | awk '{print $2}' | sort -u); do
            iptables -F "$chain" 2>/dev/null || true
            iptables -X "$chain" 2>/dev/null || true
        done
    fi

    # Очищаем nftables правила если они есть
    if command -v nft &>/dev/null; then
        nft list ruleset 2>/dev/null | grep -q 'f2b-' && nft flush ruleset inet f2b 2>/dev/null || true
    fi

    # Пересоздаём с нуля
    setupFail2Ban
    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        echo "${green}$(msg f2b_reinstalled)${reset}"
    else
        echo "${red}Fail2Ban reinstallation failed. Check: journalctl -u fail2ban -n 30${reset}"
        return 1
    fi
}

rebuildFail2BanConfigs() {
    echo -e "${cyan}Rebuilding Fail2Ban configs (keep bans)...${reset}"

    # Сохраняем текущий banaction если есть
    local old_banaction
    old_banaction=$(grep -E '^banaction\s*=' /etc/fail2ban/jail.local 2>/dev/null | awk '{print $3}' | head -1)

    # Сохраняем SSH порт
    local ssh_port
    ssh_port=$(grep -E "^Port " /etc/ssh/sshd_config | awk '{print $2}' | head -1)
    ssh_port="${ssh_port:-22}"

    # Определяем backend
    local sshd_backend sshd_logpath
    if [ -f /var/log/auth.log ]; then
        sshd_backend="auto"
        sshd_logpath="logpath  = /var/log/auth.log"
    else
        sshd_backend="systemd"
        sshd_logpath=""
    fi

    # Получаем Cloudflare IP
    local cf_ips=""
    if command -v curl &>/dev/null; then
        cf_ips=$(curl -fsSL --connect-timeout 5 "https://www.cloudflare.com/ips-v4" 2>/dev/null | tr '\n' ' ' | sed 's/  */ /g')
    fi

    # Используем сохранённый banaction или определяем автоматически
    local ban_action="${old_banaction:-$(detectFirewallBackend)}"

    cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
# Автоматически определённый бэкенд фаервола
banaction = ${ban_action}
bantime  = 2h
findtime = 10m
maxretry = 5

# Whitelist: localhost + Cloudflare IPs (не банить CDN трафик)
ignoreip = 127.0.0.1/8 ::1 ${cf_ips}

[sshd]
enabled  = true
port     = $ssh_port
filter   = sshd
backend  = $sshd_backend
$sshd_logpath
maxretry = 3
bantime  = 24h
EOF

    # Восстанавливаем nginx-probe если был фильтр
    if [ -f /etc/fail2ban/filter.d/nginx-probe.conf ]; then
        cat >> /etc/fail2ban/jail.local << 'EOF'

[nginx-probe]
enabled  = true
port     = http,https
filter   = nginx-probe
logpath  = /var/log/nginx/access.log
maxretry = 15
findtime = 5m
bantime  = 24h
EOF
    fi

    systemctl restart fail2ban 2>/dev/null
    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        echo "${green}Fail2Ban configs rebuilt.${reset}"
    else
        echo "${red}Failed to restart fail2ban. Check: journalctl -u fail2ban -n 30${reset}"
        return 1
    fi
}

removeWebJail() {
    echo -e "${yellow}$(msg webjail_remove_confirm) $(msg yes_no)${reset}"
    read -r confirm
    [[ "$confirm" != "y" ]] && { echo "$(msg cancel)"; return 0; }

    echo -e "${cyan}Removing Web-Jail (nginx-probe)...${reset}"

    # Убираем nginx-probe из jail.local
    if [ -f /etc/fail2ban/jail.local ]; then
        sed -i '/^\[nginx-probe\]/,/^$/d' /etc/fail2ban/jail.local 2>/dev/null || true
    fi

    # Удаляем фильтр
    rm -f /etc/fail2ban/filter.d/nginx-probe.conf

    # Перезапускаем fail2ban если он работает
    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        systemctl restart fail2ban 2>/dev/null || true
    fi

    echo "${green}$(msg webjail_removed)${reset}"
}

rebuildWebJailConfigs() {
    echo -e "${cyan}Rebuilding Web-Jail configs (keep bans)...${reset}"

    # Пересоздаём фильтр
    cat > /etc/fail2ban/filter.d/nginx-probe.conf << 'EOF'
[Definition]
# Ловим только явные попытки сканирования уязвимостей
failregex = ^<HOST> -.*"(GET|POST|HEAD)\s+.*(wp-login\.php|wp-admin|wp-content|wp-includes|xmlrpc\.php|\.env(\.bak|\.old)?|\.git(/|\.)|config\.(php|js|json|yml)|setup\.(cgi|php)|admin\.php|administrator|\.bashrc|\.ssh|phpmyadmin|pma|myadmin)\s.*"\s(400|403|404|405)\s\d+\s.*$
            ^<HOST> -.*"(GET|POST|HEAD)\s+/.*(\.php\.bak|\.php\.old|\.php\.save|\.sql|\.tar\.gz|\.zip|\.rar|\.mdb|\.db)\s.*"\s(400|403|404)\s\d+\s.*$
ignoreregex = ^<HOST> -.*"(GET|POST)\s+/(favicon\.ico|robots\.txt|sitemap\.xml|apple-touch-icon.*)\s.*"
EOF

    # Обновляем jail.local — заменяем или добавляем секцию [nginx-probe]
    if [ -f /etc/fail2ban/jail.local ]; then
        if grep -q '^\[nginx-probe\]' /etc/fail2ban/jail.local; then
            # Заменяем существующую секцию
            python3 -c "
import re
with open('/etc/fail2ban/jail.local') as f:
    content = f.read()
new_section = '''[nginx-probe]
enabled  = true
port     = http,https
filter   = nginx-probe
logpath  = /var/log/nginx/access.log
# Важно: 15 попыток за 5 минут — только агрессивные сканеры попадают под бан
maxretry = 15
findtime = 5m
bantime  = 24h'''
content = re.sub(r'\[nginx-probe\].*?(?=\n\[|\Z)', new_section, content, flags=re.DOTALL)
with open('/etc/fail2ban/jail.local', 'w') as f:
    f.write(content)
"
        else
            # Добавляем секцию
            cat >> /etc/fail2ban/jail.local << 'EOF'

[nginx-probe]
enabled  = true
port     = http,https
filter   = nginx-probe
logpath  = /var/log/nginx/access.log
# Важно: 15 попыток за 5 минут — только агрессивные сканеры попадают под бан
maxretry = 15
findtime = 5m
bantime  = 24h
EOF
        fi
    fi

    # Перезапускаем fail2ban
    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        fail2ban-client reload &>/dev/null
        if fail2ban-client status nginx-probe &>/dev/null; then
            echo "${green}Web-Jail configs rebuilt and jail active.${reset}"
        else
            echo "${yellow}Configs rebuilt, but jail not active. Restart fail2ban manually.${reset}"
        fi
    else
        echo "${yellow}Configs rebuilt, but fail2ban not running.${reset}"
    fi
}

setupWebJail() {
    echo -e "${cyan}$(msg webjail_setup)${reset}"

    # Если jail.local ещё нет — создаём сначала
    if [ ! -f /etc/fail2ban/jail.local ]; then
        setupFail2Ban || return 1
    fi

    # Улучшенный фильтр — более точный regex, меньше ложных срабатываний
    cat > /etc/fail2ban/filter.d/nginx-probe.conf << 'EOF'
[Definition]
# Ловим только явные попытки сканирования уязвимостей
# — точные совпадения для CMS (.php, wp-*, xmlrpc)
# — конфигурационные файлы (.env, .git, config.*)
# — админ панели (admin.php, setup.cgi)
failregex = ^<HOST> -.*"(GET|POST|HEAD)\s+.*(wp-login\.php|wp-admin|wp-content|wp-includes|xmlrpc\.php|\.env(\.bak|\.old)?|\.git(/|\.)|config\.(php|js|json|yml)|setup\.(cgi|php)|admin\.php|administrator|\.bashrc|\.ssh|phpmyadmin|pma|myadmin)\s.*"\s(400|403|404|405)\s\d+\s.*$
            ^<HOST> -.*"(GET|POST|HEAD)\s+/.*(\.php\.bak|\.php\.old|\.php\.save|\.sql|\.tar\.gz|\.zip|\.rar|\.mdb|\.db)\s.*"\s(400|403|404)\s\d+\s.*$
# Исключаем легитимные запросы
ignoreregex = ^<HOST> -.*"(GET|POST)\s+/(favicon\.ico|robots\.txt|sitemap\.xml|apple-touch-icon.*)\s.*"
EOF

    # Добавляем nginx-probe jail если ещё нет
    # УВЕЛИЧЕНО: maxretry=15 (было 5), findtime=5m — не банить за случайные 404
    if ! grep -q "\[nginx-probe\]" /etc/fail2ban/jail.local 2>/dev/null; then
        cat >> /etc/fail2ban/jail.local << 'EOF'

[nginx-probe]
enabled  = true
port     = http,https
filter   = nginx-probe
logpath  = /var/log/nginx/access.log
# Важно: 15 попыток за 5 минут — только агрессивные сканеры попадают под бан
# При Stream SNI легитимный трафик (неизвестные SNI → default backend) не банится
maxretry = 15
findtime = 5m
bantime  = 24h
EOF
    fi

    # Перезапускаем fail2ban
    systemctl restart fail2ban 2>/dev/null

    # Проверяем что fail2ban поднялся
    local attempts=0
    while [ $attempts -lt 5 ]; do
        if fail2ban-client ping &>/dev/null; then
            break
        fi
        sleep 1
        attempts=$((attempts + 1))
    done

    if ! fail2ban-client ping &>/dev/null; then
        echo "${red}$(msg webjail_f2b_fail)${reset}"
        # Откат — убираем nginx-probe чтобы не сломать f2b совсем
        sed -i '/^\[nginx-probe\]/,/^bantime/d' /etc/fail2ban/jail.local 2>/dev/null || true
        systemctl restart fail2ban
        return 1
    fi

    # Проверяем что nginx-probe jail активен
    if ! fail2ban-client status nginx-probe &>/dev/null; then
        echo "${red}$(msg webjail_jail_fail)${reset}"
        return 1
    fi

    # Показываем статистику
    local jail_status
    jail_status=$(fail2ban-client status nginx-probe 2>/dev/null | grep "Currently banned" || echo "")
    if [ -n "$jail_status" ]; then
        echo -e "${green}$(msg webjail_ok)${reset}"
        echo "  $jail_status"
    else
        echo "${green}$(msg webjail_ok)${reset}"
    fi
}

manageUFW() {
    while true; do
        clear
        echo -e "${cyan}$(msg ufw_title)${reset}"
        echo ""
        ufw status verbose 2>/dev/null || echo "$(msg ufw_inactive)"
        echo ""
        echo -e "${green}1.${reset} $(msg ufw_open_port)"
        echo -e "${green}2.${reset} $(msg ufw_close_port)"
        echo -e "${green}3.${reset} $(msg ufw_enable)"
        echo -e "${green}4.${reset} $(msg ufw_disable)"
        echo -e "${green}5.${reset} $(msg ufw_reset)"
        echo -e "${green}0.${reset} $(msg back)"
        read -rp "$(msg choose)" choice
        case $choice in
            1)
                read -rp "$(msg ufw_port_prompt)" port
                read -rp "$(msg ufw_proto_prompt)" proto
                [ "$proto" = "any" ] && proto=""
                [ -n "$port" ] && ufw allow "${port}${proto:+/}${proto}" && echo "${green}$(msg ufw_port_opened) $port${reset}"
                read -r ;;
            2)
                read -rp "$(msg ufw_close_prompt)" port
                [ -n "$port" ] && ufw delete allow "$port" && echo "${green}$(msg ufw_port_closed) $port${reset}"
                read -r ;;
            3) echo "y" | ufw enable && echo "${green}$(msg ufw_enabled)${reset}"; read -r ;;
            4) ufw disable && echo "${green}$(msg ufw_disabled)${reset}"; read -r ;;
            5)
                echo -e "${red}$(msg ufw_reset_confirm) $(msg yes_no)${reset}"
                read -r confirm
                [[ "$confirm" == "y" ]] && ufw --force reset && echo "${green}$(msg ufw_reset_ok)${reset}"
                read -r ;;
            0) break ;;
        esac
    done
}

getIPv6Status() {
    local val
    val=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)
    [ "$val" = "1" ] && echo "${red}OFF${reset}" || echo "${green}ON${reset}"
}

toggleIPv6() {
    local current
    current=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)
    if [ "$current" = "1" ]; then
        sysctl -w net.ipv6.conf.all.disable_ipv6=0 &>/dev/null
        sysctl -w net.ipv6.conf.default.disable_ipv6=0 &>/dev/null
        sysctl -w net.ipv6.conf.lo.disable_ipv6=0 &>/dev/null
        sysctl -w net.ipv6.icmp.echo_ignore_all=0 &>/dev/null
        sed -i '/disable_ipv6/d' /etc/sysctl.d/99-xray.conf 2>/dev/null || true
        sed -i '/ipv6.*icmp.*ignore/d' /etc/sysctl.d/99-xray.conf 2>/dev/null || true
        echo "${green}$(msg ipv6_enabled)${reset}"
    else
        sysctl -w net.ipv6.conf.all.disable_ipv6=1 &>/dev/null
        sysctl -w net.ipv6.conf.default.disable_ipv6=1 &>/dev/null
        sysctl -w net.ipv6.conf.lo.disable_ipv6=1 &>/dev/null
        sysctl -w net.ipv6.icmp.echo_ignore_all=1 &>/dev/null
        if ! grep -q "disable_ipv6" /etc/sysctl.d/99-xray.conf 2>/dev/null; then
            cat >> /etc/sysctl.d/99-xray.conf << 'SYSCTL'
# IPv6
net.ipv6.icmp.echo_ignore_all = 1
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
SYSCTL
        fi
        echo "${red}$(msg ipv6_disabled)${reset}"
    fi
}

getCpuGuardStatus() {
    # Проверяем что приоритеты выставлены
    local xray_weight
    xray_weight=$(systemctl show xray.service -p CPUWeight 2>/dev/null | cut -d= -f2)
    if [ "${xray_weight:-}" = "200" ]; then
        echo "${green}ON${reset}"
    else
        echo "${red}OFF${reset}"
    fi
}

setupCpuGuard() {
    echo -e "${cyan}$(msg cpuguard_setup)${reset}"

    # Высокий приоритет для основных сервисов
    for svc in xray.service xray-reality.service nginx.service; do
        systemctl set-property "$svc" CPUWeight=200 2>/dev/null || true
    done

    # Низкий приоритет для интерактивных сессий (SSH, случайные процессы)
    systemctl set-property user.slice CPUWeight=20 2>/dev/null || true

    # Персистентность — записываем в юниты чтобы пережило перезагрузку
    for svc in xray xray-reality nginx; do
        local drop_in="/etc/systemd/system/${svc}.service.d"
        mkdir -p "$drop_in"
        cat > "${drop_in}/cpuguard.conf" << 'EOF'
[Service]
CPUWeight=200
Nice=-10
EOF
    done

    # user.slice drop-in
    mkdir -p /etc/systemd/system/user.slice.d
    cat > /etc/systemd/system/user.slice.d/cpuguard.conf << 'EOF'
[Slice]
CPUWeight=20
EOF

    systemctl daemon-reload

    echo "${green}$(msg cpuguard_ok)${reset}"
    echo ""
    echo -e "  xray:    ${green}CPUWeight=200, Nice=-10${reset}"
    echo -e "  nginx:   ${green}CPUWeight=200, Nice=-10${reset}"
    echo -e "  user.slice: ${yellow}CPUWeight=20${reset} (SSH сессии, посторонние процессы)"
}

removeCpuGuard() {
    echo -e "${yellow}$(msg cpuguard_remove_confirm) $(msg yes_no)${reset}"
    read -r confirm
    [[ "$confirm" != "y" ]] && { echo "$(msg cancel)"; return 0; }

    for svc in xray xray-reality nginx; do
        rm -f "/etc/systemd/system/${svc}.service.d/cpuguard.conf"
        rmdir "/etc/systemd/system/${svc}.service.d" 2>/dev/null || true
    done
    rm -f /etc/systemd/system/user.slice.d/cpuguard.conf
    rmdir /etc/systemd/system/user.slice.d 2>/dev/null || true

    systemctl daemon-reload
    # Сбрасываем живые значения
    systemctl set-property user.slice CPUWeight=100 2>/dev/null || true
    for svc in xray.service xray-reality.service nginx.service; do
        systemctl set-property "$svc" CPUWeight=100 2>/dev/null || true
    done

    echo "${green}$(msg removed)${reset}"
}

applySysctl() {
    cat > /etc/sysctl.d/99-xray.conf << 'SYSCTL'
net.ipv4.icmp_echo_ignore_all = 1
net.ipv6.icmp.echo_ignore_all = 1
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
# TCP keepalive — держит WS соединения живыми через NAT мобильных операторов
net.ipv4.tcp_keepalive_time = 120
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 3
SYSCTL
    sysctl --system &>/dev/null
    sysctl -p /etc/sysctl.d/99-xray.conf &>/dev/null
    echo "${green}$(msg sysctl_ok)${reset}"
}

# ── Подменю Fail2Ban ──────────────────────────────────────────────

manageFail2Ban() {
    set +e
    while true; do
        clear
        local s_f2b s_banaction s_ignoreip
        s_f2b=$(getF2BStatus)

        # Получаем banaction из конфига
        s_banaction=$(grep -E '^banaction\s*=' /etc/fail2ban/jail.local 2>/dev/null | awk '{print $3}' | head -1)
        [ -z "$s_banaction" ] && s_banaction="default (may be nftables)"

        # Получаем ignoreip
        s_ignoreip=$(grep -E '^ignoreip\s*=' /etc/fail2ban/jail.local 2>/dev/null | cut -d= -f2- | head -1 | cut -c1-50)
        [ -z "$s_ignoreip" ] && s_ignoreip="not set"

        echo -e "${cyan}================================================================${reset}"
        printf "   ${red}$(msg f2b_manage_title)${reset}  %s\n" "$(date +'%d.%m.%Y %H:%M')"
        echo -e "${cyan}----------------------------------------------------------------${reset}"
        echo -e "  $(printf '%-12s' 'Status:')$s_f2b"
        echo -e "  $(printf '%-12s' 'banaction:') ${green}${s_banaction}${reset}"
        echo -e "  $(printf '%-12s' 'ignoreip:')  ${green}${s_ignoreip}...${reset}"
        echo -e "${cyan}----------------------------------------------------------------${reset}"
        echo ""
        echo -e "  ${green}1.${reset} $(msg f2b_setup)"
        echo -e "  ${green}2.${reset} $(msg f2b_reinstall)"
        echo -e "  ${green}3.${reset} $(msg f2b_remove)"
        echo -e "  ${green}4.${reset} $(msg f2b_rebuild)"
        echo -e "  ${green}5.${reset} $(msg f2b_show_status)"
        echo -e "  ${green}6.${reset} $(msg f2b_show_banned)"
        echo -e "  ${green}7.${reset} $(msg f2b_show_logs)"
        echo -e "  ${green}0.${reset} $(msg back)"
        echo ""
        read -rp "$(msg choose)" choice
        case $choice in
            1) setupFail2Ban ;;
            2) reinstallFail2Ban ;;
            3) removeFail2Ban ;;
            4) rebuildFail2BanConfigs ;;
            5) fail2ban-client status && fail2ban-client status sshd 2>/dev/null || true ;;
            6) fail2ban-client status sshd 2>/dev/null | grep "Banned IP" || echo "No banned IPs" ;;
            7) journalctl -u fail2ban -n 50 --no-pager ;;
            0) break ;;
            *) echo -e "${red}$(msg invalid)${reset}" ;;
        esac
        [ "$choice" = "0" ] && continue
        echo -e "\n${cyan}$(msg press_enter)${reset}"
        read -r
    done
}

# ── Подменю Web-Jail ──────────────────────────────────────────────

manageWebJail() {
    set +e
    while true; do
        clear
        local s_jail s_maxretry s_banned
        s_jail=$(getWebJailStatus)

        # Получаем maxretry из конфига
        s_maxretry=$(grep -A10 '\[nginx-probe\]' /etc/fail2ban/jail.local 2>/dev/null | grep 'maxretry' | awk '{print $3}' | head -1)
        [ -z "$s_maxretry" ] && s_maxretry="N/A"

        # Количество забаненных IP
        s_banned=$(fail2ban-client status nginx-probe 2>/dev/null | grep "Currently banned" | awk '{print $NF}' || echo "0")

        echo -e "${cyan}================================================================${reset}"
        printf "   ${red}$(msg webjail_manage_title)${reset}  %s\n" "$(date +'%d.%m.%Y %H:%M')"
        echo -e "${cyan}----------------------------------------------------------------${reset}"
        echo -e "  $(printf '%-12s' 'Status:')$s_jail"
        echo -e "  $(printf '%-12s' 'maxretry:')  ${green}${s_maxretry}${reset}"
        echo -e "  $(printf '%-12s' 'Banned:')    ${green}${s_banned:-0} IPs${reset}"
        echo -e "${cyan}----------------------------------------------------------------${reset}"
        echo ""
        echo -e "  ${green}1.${reset} $(msg webjail_setup)"
        echo -e "  ${green}2.${reset} $(msg webjail_remove)"
        echo -e "  ${green}3.${reset} $(msg webjail_rebuild)"
        echo -e "  ${green}4.${reset} $(msg webjail_show_status)"
        echo -e "  ${green}5.${reset} $(msg webjail_show_banned)"
        echo -e "  ${green}6.${reset} $(msg webjail_show_filter)"
        echo -e "  ${green}7.${reset} $(msg webjail_test_filter)"
        echo -e "  ${green}0.${reset} $(msg back)"
        echo ""
        read -rp "$(msg choose)" choice
        case $choice in
            1) setupWebJail ;;
            2) removeWebJail ;;
            3) rebuildWebJailConfigs ;;
            4) fail2ban-client status nginx-probe 2>/dev/null || echo "Web-Jail not active" ;;
            5) fail2ban-client status nginx-probe 2>/dev/null | grep "Banned IP" || echo "No banned IPs" ;;
            6) cat /etc/fail2ban/filter.d/nginx-probe.conf 2>/dev/null || echo "Filter not found" ;;
            7)
                echo -e "${cyan}$(msg webjail_test_filter)${reset}"
                if [ -f /var/log/nginx/access.log ]; then
                    fail2ban-regex /var/log/nginx/access.log /etc/fail2ban/filter.d/nginx-probe.conf 2>/dev/null | tail -10
                else
                    echo "No access log found"
                fi
                ;;
            0) break ;;
            *) echo -e "${red}$(msg invalid)${reset}" ;;
        esac
        [ "$choice" = "0" ] && continue
        echo -e "\n${cyan}$(msg press_enter)${reset}"
        read -r
    done
}