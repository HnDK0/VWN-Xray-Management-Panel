#!/bin/bash
# =================================================================
# security.sh — UFW, BBR, Fail2Ban, WebJail, SSH
# =================================================================

changeSshPort() {
    read -rp "$(msg ssh_new_port)" new_ssh_port
    if ! [[ "$new_ssh_port" =~ ^[0-9]+$ ]] || [ "$new_ssh_port" -lt 1 ] || [ "$new_ssh_port" -gt 65535 ]; then
        echo "${red}$(msg invalid_port)${reset}"; return 1
    fi
    cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak.$(date +%s)"
    ufw allow "$new_ssh_port"/tcp comment 'SSH'
    sed -i "s/^#\?Port [0-9]*/Port $new_ssh_port/" /etc/ssh/sshd_config
    systemctl restart sshd 2>/dev/null || systemctl restart ssh
    echo "${green}$(msg ssh_changed) $new_ssh_port.${reset}"
    echo "${yellow}$(msg ssh_close_old)${reset}"
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

    cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime  = 2h
findtime = 10m
maxretry = 5

[sshd]
enabled  = true
port     = $ssh_port
filter   = sshd
backend  = $sshd_backend
$sshd_logpath
maxretry = 3
bantime  = 24h
EOF
    systemctl restart fail2ban && systemctl enable fail2ban
    echo "${green}$(msg f2b_ok) $ssh_port).${reset}"
}

setupWebJail() {
    echo -e "${cyan}$(msg webjail_setup)${reset}"
    [ ! -f /etc/fail2ban/jail.local ] && setupFail2Ban

    cat > /etc/fail2ban/filter.d/nginx-probe.conf << 'EOF'
[Definition]
failregex = ^<HOST> - .* "(GET|POST|HEAD) .*(\.php|wp-login|admin|\.env|\.git|config\.js|setup\.cgi|xmlrpc).*" (400|403|404|405) \d+
ignoreregex = ^<HOST> - .* "(GET|POST) /favicon.ico.*"
EOF

    if ! grep -q "\[nginx-probe\]" /etc/fail2ban/jail.local; then
        cat >> /etc/fail2ban/jail.local << 'EOF'

[nginx-probe]
enabled  = true
port     = http,https
filter   = nginx-probe
logpath  = /var/log/nginx/access.log
maxretry = 5
bantime  = 24h
EOF
    fi
    systemctl restart fail2ban
    echo "${green}$(msg webjail_ok)${reset}"
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
        # ИСПРАВЛЕНО: проверяем что у сервера есть IPv4 адрес перед отключением IPv6
        local has_ipv4
        has_ipv4=$(ip -4 addr show scope global 2>/dev/null | grep -c inet || echo 0)
        if [ "${has_ipv4:-0}" -eq 0 ]; then
            echo "${red}Warning: no IPv4 address detected — keeping IPv6 enabled to avoid losing connectivity.${reset}"
            return 1
        fi
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
    # Проверяем что у сервера есть IPv4 адрес перед отключением IPv6
    local has_ipv4
    has_ipv4=$(ip -4 addr show scope global 2>/dev/null | grep -c inet || echo 0)
    
    cat > /etc/sysctl.d/99-xray.conf << SYSCTL
net.ipv4.icmp_echo_ignore_all = 1
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
# TCP keepalive — держит WS соединения живыми через NAT мобильных операторов
net.ipv4.tcp_keepalive_time = 120
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 3
SYSCTL

    if [ "${has_ipv4:-0}" -gt 0 ]; then
        cat >> /etc/sysctl.d/99-xray.conf << 'SYSCTL'
# IPv6 disabled (server has IPv4)
net.ipv6.icmp.echo_ignore_all = 1
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
SYSCTL
    else
        echo "${yellow}Warning: no IPv4 address detected — keeping IPv6 enabled.${reset}"
    fi

    sysctl --system &>/dev/null
    sysctl -p /etc/sysctl.d/99-xray.conf &>/dev/null
    echo "${green}$(msg sysctl_ok)${reset}"
}
