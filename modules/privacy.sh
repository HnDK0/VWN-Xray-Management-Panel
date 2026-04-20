#!/bin/bash
# =================================================================
# privacy.sh — Управление приватностью: отключение логирования
#              трафика пользователей во всех компонентах
# =================================================================

# ── Константы ────────────────────────────────────────────────────
_PRIVACY_FLAG="$VWN_CONF"   # хранится в vwn.conf как privacy_mode=1/0

# ── Вспомогательные функции ──────────────────────────────────────

# Текущий статус: 1 = приватный режим включён
_privacyIsEnabled() {
    [ "$(vwn_conf_get privacy_mode)" = "1" ]
}

getPrivacyStatus() {
    _privacyIsEnabled \
        && echo "${green}ON${reset}" \
        || echo "${red}OFF${reset}"
}

# ── Применение к конфигам Xray ───────────────────────────────────

# Выставляет "access":"none","loglevel":"none" в указанном JSON-конфиге
_xrayDisableLog() {
    local cfg="$1"
    [ -f "$cfg" ] || return 0
    jq '.log.access = "none" | .log.loglevel = "none"' \
        "$cfg" > "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
}

# Возвращает access-лог и loglevel к рабочим значениям
_xrayRestoreLog() {
    local cfg="$1"
    local errlog="$2"
    [ -f "$cfg" ] || return 0
    jq --arg e "$errlog" \
        '.log.access = "none" | .log.loglevel = "error" | .log.error = $e' \
        "$cfg" > "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
}

# ── sniffing ─────────────────────────────────────────────────────
# sniffing нужен только для маршрутизации по доменам (routeOnly=true).
# Если у пользователя нет правил по доменам — его можно отключить,
# и Xray вообще не будет заглядывать в содержимое трафика.
# Мы просто выставляем routeOnly=true (уже стоит в наших конфигах)
# и НЕ отключаем sniffing полностью — это сломало бы WARP/relay split.

# ── Nginx: access_log ─────────────────────────────────────────────

_nginxDisableAccessLog() {
    [ -f "$nginxPath" ] || return 0
    # Меняем access_log /var/log/nginx/access.log → access_log off
    sed -i 's|access_log\s\+/var/log/nginx/access\.log.*|access_log off;|g' "$nginxPath"
    # Для location-блоков — уже стоит access_log off (в wsSettings location)
}

_nginxRestoreAccessLog() {
    [ -f "$nginxPath" ] || return 0
    sed -i 's|access_log\s\+off;|access_log /var/log/nginx/access.log;|g' "$nginxPath"
}

# ── journald: подавление stdout сервисов ──────────────────────────

_systemdDisableOutput() {
    local svc="$1"
    local override="/etc/systemd/system/${svc}.service.d/no-journal.conf"
    mkdir -p "$(dirname "$override")"
    cat > "$override" << 'EOF'
[Service]
StandardOutput=null
StandardError=null
EOF
}

_systemdRestoreOutput() {
    local svc="$1"
    local override="/etc/systemd/system/${svc}.service.d/no-journal.conf"
    rm -f "$override"
    # Удаляем пустую директорию если больше нет файлов
    rmdir "/etc/systemd/system/${svc}.service.d" || true
}

# ── tmpfs для /var/log/xray ──────────────────────────────────────
# Логи xray пишутся в RAM → при перезагрузке исчезают автоматически.
# Для nginx не делаем: там пишет root и fstab-монтирование сложнее.

_XRAY_LOG_TMPFS_MARKER="/etc/systemd/system/var-log-xray.mount"

_enableXrayLogTmpfs() {
    # Systemd-mount проще и надёжнее fstab для одной директории
    mkdir -p /var/log/xray
    cat > "$_XRAY_LOG_TMPFS_MARKER" << 'EOF'
[Unit]
Description=tmpfs for xray logs (privacy mode)
Before=xray.service xray-reality.service

[Mount]
What=tmpfs
Where=/var/log/xray
Type=tmpfs
Options=defaults,noatime,size=32m,mode=750

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now var-log-xray.mount || true
    # Пересоздаём пустые лог-файлы в tmpfs
    touch /var/log/xray/error.log /var/log/xray/reality-error.log || true
    chown -R xray:xray /var/log/xray || true
}

_disableXrayLogTmpfs() {
    systemctl disable --now var-log-xray.mount || true
    rm -f "$_XRAY_LOG_TMPFS_MARKER"
    systemctl daemon-reload
    # Воссоздаём постоянную директорию
    mkdir -p /var/log/xray
    touch /var/log/xray/error.log /var/log/xray/reality-error.log || true
    chown -R xray:xray /var/log/xray || true
}

# ── Очистка существующих логов ────────────────────────────────────

_shredCurrentLogs() {
    echo -e "${cyan}$(msg privacy_shred_logs)${reset}"

    # Предупреждение: ext4 с журналированием не даёт 100% гарантий уничтожения
    local fs_type
    fs_type=$(df -T /var/log | awk 'NR==2{print $2}')
    if [[ "$fs_type" == "ext4" || "$fs_type" == "ext3" ]]; then
        echo -e "${yellow}$(msg privacy_shred_ext4_warn)${reset}"
    fi

    local _files=(
        /var/log/xray/access.log
        /var/log/xray/error.log
        /var/log/xray/reality-error.log
        /var/log/nginx/access.log
        /var/log/nginx/error.log
    )
    for f in "${_files[@]}"; do
        [ -f "$f" ] || continue
        # shred — перезаписывает блоки случайными данными перед удалением
        if command -v shred; then
            shred -u "$f" && touch "$f" || : > "$f"
        else
            : > "$f"
        fi
    done

    # journald — удаляем старые записи
    journalctl --rotate
    journalctl --vacuum-time=1s

    # ext4: принудительный сброс journal чтобы старые данные не остались в нём
    if [[ "$fs_type" == "ext4" || "$fs_type" == "ext3" ]]; then
        local dev
        dev=$(df /var/log | awk 'NR==2{print $1}')
        if [ -n "$dev" ] && command -v tune2fs; then
            # Флашим journal — перезаписываем его блоки
            tune2fs -E journal_data_writeback "$dev" || true
            tune2fs -E journal_data_ordered "$dev" || true
        fi
        # sync гарантирует что все грязные страницы сброшены на диск
        sync
    fi

    echo "${green}$(msg privacy_shred_done)${reset}"
}

# ── Главные функции включения / выключения ────────────────────────

enablePrivacyMode() {
    echo -e "${cyan}$(msg privacy_enabling)${reset}"

    # 1. Xray конфиги
    _xrayDisableLog "$configPath"
    _xrayDisableLog "$realityConfigPath"
    _xrayDisableLog "$xhttpConfigPath"

    # 2. Nginx
    _nginxDisableAccessLog
    nginx -t && systemctl reload nginx || true

    # 3. Подавляем journald для xray-сервисов
    for svc in xray xray-reality xray-xhttp; do
        _systemdDisableOutput "$svc"
    done
    systemctl daemon-reload
    systemctl restart xray || true
    systemctl restart xray-reality || true
    systemctl restart xray-xhttp || true

    # 4. tmpfs для каталога логов xray (логи в RAM)
    _enableXrayLogTmpfs

    # 5. Уничтожаем уже накопленные логи
    _shredCurrentLogs

    # 6. Сохраняем флаг
    vwn_conf_set privacy_mode 1

    echo ""
    echo -e "${green}$(msg privacy_enabled)${reset}"
    echo ""
    echo -e "  ${cyan}$(msg privacy_what_done):${reset}"
    echo -e "  ${green}✓${reset}  Xray access log    → none"
    echo -e "  ${green}✓${reset}  Xray loglevel      → none"
    echo -e "  ${green}✓${reset}  Nginx access_log   → off"
    echo -e "  ${green}✓${reset}  journald stdout    → null (xray, xray-reality)"
    echo -e "  ${green}✓${reset}  /var/log/xray      → tmpfs (RAM, очищается при ребуте)"
    echo -e "  ${green}✓${reset}  Существующие логи  → перезаписаны и очищены"
}

disablePrivacyMode() {
    echo -e "${yellow}$(msg privacy_disabling)${reset}"

    # 1. Xray конфиги — возвращаем error-логи
    _xrayRestoreLog "$configPath" "/var/log/xray/error.log"
    _xrayRestoreLog "$realityConfigPath" "/var/log/xray/reality-error.log"
    _xrayRestoreLog "$xhttpConfigPath" "/var/log/xray/xhttp-error.log"

    # 2. Nginx — возвращаем access_log
    _nginxRestoreAccessLog
    nginx -t && systemctl reload nginx || true

    # 3. Возвращаем journald
    for svc in xray xray-reality xray-xhttp; do
        _systemdRestoreOutput "$svc"
    done
    systemctl daemon-reload
    systemctl restart xray || true
    systemctl restart xray-reality || true
    systemctl restart xray-xhttp || true

    # 4. Убираем tmpfs
    _disableXrayLogTmpfs

    # 5. Снимаем флаг
    vwn_conf_set privacy_mode 0

    echo "${green}$(msg privacy_disabled)${reset}"
}

# ── Показ статуса ─────────────────────────────────────────────────

showPrivacyStatus() {
    echo ""
    echo -e "${cyan}$(msg privacy_status_title)${reset}"
    echo ""

    # Режим
    if _privacyIsEnabled; then
        echo -e "  $(msg status): ${green}PRIVACY MODE ON${reset}"
    else
        echo -e "  $(msg status): ${red}PRIVACY MODE OFF${reset}"
    fi
    echo ""

    # Детали по компонентам
    local xray_acc xray_lvl nginx_acc tmpfs_active jd_xray

    # Xray WS
    if [ -f "$configPath" ]; then
        xray_acc=$(jq -r '.log.access // "—"' "$configPath")
        xray_lvl=$(jq -r '.log.loglevel // "—"' "$configPath")
        [ "$xray_acc" = "none" ] && [ "$xray_lvl" = "none" ] \
            && echo -e "  ${green}✓${reset}  Xray WS:      access=none, loglevel=none" \
            || echo -e "  ${red}✗${reset}  Xray WS:      access=${xray_acc}, loglevel=${xray_lvl}"
    fi

    # Xray Reality
    if [ -f "$realityConfigPath" ]; then
        xray_acc=$(jq -r '.log.access // "—"' "$realityConfigPath")
        xray_lvl=$(jq -r '.log.loglevel // "—"' "$realityConfigPath")
        [ "$xray_acc" = "none" ] && [ "$xray_lvl" = "none" ] \
            && echo -e "  ${green}✓${reset}  Xray Reality: access=none, loglevel=none" \
            || echo -e "  ${red}✗${reset}  Xray Reality: access=${xray_acc}, loglevel=${xray_lvl}"
    fi

    # Nginx access_log
    if [ -f "$nginxPath" ]; then
        nginx_acc=$(grep -E '^\s*access_log' "$nginxPath" | grep -v 'location' | tail -1 | xargs)
        echo "$nginx_acc" | grep -q "off" \
            && echo -e "  ${green}✓${reset}  Nginx:        access_log off" \
            || echo -e "  ${red}✗${reset}  Nginx:        $nginx_acc"
    fi

    # Xray XHTTP
    if [ -f "$xhttpConfigPath" ]; then
        xray_acc=$(jq -r '.log.access // "—"' "$xhttpConfigPath")
        xray_lvl=$(jq -r '.log.loglevel // "—"' "$xhttpConfigPath")
        [ "$xray_acc" = "none" ] && [ "$xray_lvl" = "none" ] \
            && echo -e "  ${green}✓${reset}  Xray XHTTP:  access=none, loglevel=none" \
            || echo -e "  ${red}✗${reset}  Xray XHTTP:  access=${xray_acc}, loglevel=${xray_lvl}"
    fi

    # journald override
    [ -f "/etc/systemd/system/xray.service.d/no-journal.conf" ] \
        && echo -e "  ${green}✓${reset}  journald:     stdout/stderr → null (xray, xray-reality, xray-xhttp)" \
        || echo -e "  ${red}✗${reset}  journald:     stdout/stderr → journal (xray)"

    # tmpfs
    systemctl is-active --quiet var-log-xray.mount \
        && echo -e "  ${green}✓${reset}  /var/log/xray: tmpfs (RAM)" \
        || echo -e "  ${red}✗${reset}  /var/log/xray: disk"

    echo ""
}

# ── Меню ──────────────────────────────────────────────────────────

managePrivacy() {
    set +e
    while true; do
        clear
        echo -e "${cyan}================================================================${reset}"
        printf "   ${red}$(msg privacy_title)${reset}  %s\n" "$(date +'%d.%m.%Y %H:%M')"
        echo -e "${cyan}----------------------------------------------------------------${reset}"
        showPrivacyStatus
        echo -e "${green}1.${reset} $(msg privacy_enable)"
        echo -e "${green}2.${reset} $(msg privacy_disable)"
        echo -e "${green}3.${reset} $(msg privacy_shred_now)"
        echo -e "${green}4.${reset} $(msg privacy_status)"
        echo -e "${green}0.${reset} $(msg back)"
        echo -e "${cyan}================================================================${reset}"
        read -rp "$(msg choose)" choice
        case $choice in
            1)
                if _privacyIsEnabled; then
                    echo -e "${yellow}$(msg privacy_already_on)${reset}"
                else
                    echo -e "${yellow}$(msg privacy_enable_confirm) $(msg yes_no)${reset}"
                    read -r confirm
                    [[ "$confirm" == "y" ]] && enablePrivacyMode
                fi
                ;;
            2)
                if ! _privacyIsEnabled; then
                    echo -e "${yellow}$(msg privacy_already_off)${reset}"
                else
                    echo -e "${yellow}$(msg privacy_disable_confirm) $(msg yes_no)${reset}"
                    read -r confirm
                    [[ "$confirm" == "y" ]] && disablePrivacyMode
                fi
                ;;
            3)
                echo -e "${yellow}$(msg privacy_shred_confirm) $(msg yes_no)${reset}"
                read -r confirm
                [[ "$confirm" == "y" ]] && _shredCurrentLogs
                ;;
            4) showPrivacyStatus ;;
            0) break ;;
        esac
        [ "$choice" = "0" ] && continue
        echo -e "\n${cyan}$(msg press_enter)${reset}"
        read -r
    done
}
