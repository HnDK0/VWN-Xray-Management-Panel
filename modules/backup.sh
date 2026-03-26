#!/bin/bash
# =================================================================
# backup.sh — Бэкап и восстановление конфигов VWN
# =================================================================

BACKUP_DIR="/root/vwn-backups"

# Список того что бэкапим
_BACKUP_PATHS=(
    /usr/local/etc/xray
    /etc/nginx/conf.d
    /etc/nginx/cert
    /root/.cloudflare_api
    /etc/cron.d/acme-renew
    /etc/cron.d/clear-logs
    /etc/cron.d/warp-watchdog
    /usr/local/bin/warp-watchdog.sh
    /usr/local/bin/clear-logs.sh
    /etc/sysctl.d/99-xray.conf
    /etc/fail2ban/jail.local
    /etc/fail2ban/filter.d/nginx-probe.conf
    /usr/local/etc/xray/panel.conf
    /etc/systemd/system/vwn-panel.service
)

createBackup() {
    mkdir -p "$BACKUP_DIR"
    local timestamp
    timestamp=$(date '+%Y-%m-%d_%H-%M-%S')
    local archive="${BACKUP_DIR}/vwn-backup-${timestamp}.tar.gz"

    echo -e "${cyan}$(msg backup_creating)...${reset}"

    # Собираем только существующие пути
    local existing_paths=()
    for p in "${_BACKUP_PATHS[@]}"; do
        [ -e "$p" ] && existing_paths+=("$p")
    done

    if [ ${#existing_paths[@]} -eq 0 ]; then
        echo "${red}$(msg backup_nothing)${reset}"
        return 1
    fi

    if tar --ignore-failed-read -czf "$archive" "${existing_paths[@]}" 2>/dev/null; then
        local size
        size=$(du -sh "$archive" | cut -f1)
        echo "${green}$(msg backup_done): $archive ($size)${reset}"
    else
        echo "${red}$(msg backup_fail)${reset}"
        rm -f "$archive"
        return 1
    fi
}

listBackups() {
    if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]; then
        echo "${yellow}$(msg backup_list_empty)${reset}"
        return 1
    fi
    echo -e "${cyan}$(msg backup_list):${reset}"
    echo ""
    local i=1
    while IFS= read -r f; do
        local size date_str
        size=$(du -sh "$f" | cut -f1)
        date_str=$(basename "$f" | sed 's/vwn-backup-//;s/\.tar\.gz//' | tr '_' ' ')
        printf "  ${green}%2d.${reset} %s  [%s]\n" "$i" "$date_str" "$size"
        i=$((i + 1))
    done < <(ls -t "$BACKUP_DIR"/vwn-backup-*.tar.gz 2>/dev/null)
    echo ""
}

restoreBackup() {
    listBackups || return 1

    local files=()
    while IFS= read -r f; do
        files+=("$f")
    done < <(ls -t "$BACKUP_DIR"/vwn-backup-*.tar.gz 2>/dev/null)

    [ ${#files[@]} -eq 0 ] && return 1

    read -rp "$(msg backup_choose_num)" num
    if ! [[ "$num" =~ ^[0-9]+$ ]] || [ "$num" -lt 1 ] || [ "$num" -gt ${#files[@]} ]; then
        echo "${red}$(msg invalid)${reset}"; return 1
    fi

    local archive="${files[$((num - 1))]}"
    echo -e "${yellow}$(msg backup_restore_confirm) $(basename "$archive")? $(msg yes_no)${reset}"
    read -r confirm
    [[ "$confirm" != "y" ]] && { echo "$(msg cancel)"; return 0; }

    echo -e "${cyan}$(msg backup_restoring)...${reset}"

    # Останавливаем сервисы перед восстановлением
    systemctl stop xray xray-reality nginx vwn-panel 2>/dev/null || true

    if tar -xzf "$archive" -C / 2>/dev/null; then
        systemctl daemon-reload
        systemctl restart xray xray-reality nginx vwn-panel 2>/dev/null || true
        echo "${green}$(msg backup_restored)${reset}"
    else
        echo "${red}$(msg backup_restore_fail)${reset}"
        systemctl start xray xray-reality nginx vwn-panel 2>/dev/null || true
        return 1
    fi
}

deleteBackup() {
    listBackups || return 1

    local files=()
    while IFS= read -r f; do
        files+=("$f")
    done < <(ls -t "$BACKUP_DIR"/vwn-backup-*.tar.gz 2>/dev/null)

    [ ${#files[@]} -eq 0 ] && return 1

    read -rp "$(msg backup_choose_num)" num
    if ! [[ "$num" =~ ^[0-9]+$ ]] || [ "$num" -lt 1 ] || [ "$num" -gt ${#files[@]} ]; then
        echo "${red}$(msg invalid)${reset}"; return 1
    fi

    local archive="${files[$((num - 1))]}"
    echo -e "${red}$(msg backup_delete_confirm) $(basename "$archive")? $(msg yes_no)${reset}"
    read -r confirm
    [[ "$confirm" != "y" ]] && { echo "$(msg cancel)"; return 0; }

    rm -f "$archive"
    echo "${green}$(msg removed)${reset}"
}

manageBackup() {
    set +e
    while true; do
        clear
        echo -e "${cyan}$(msg backup_title)${reset}"
        echo ""
        # Показываем сколько бэкапов есть
        local count=0
        [ -d "$BACKUP_DIR" ] && count=$(ls "$BACKUP_DIR"/vwn-backup-*.tar.gz 2>/dev/null | wc -l)
        echo -e "  $(msg backup_dir): ${green}$BACKUP_DIR${reset}"
        echo -e "  $(msg backup_count): ${green}$count${reset}"
        echo ""
        echo -e "${green}1.${reset} $(msg backup_create)"
        echo -e "${green}2.${reset} $(msg backup_list_action)"
        echo -e "${green}3.${reset} $(msg backup_restore_action)"
        echo -e "${green}4.${reset} $(msg backup_delete_action)"
        echo -e "${green}0.${reset} $(msg back)"
        echo ""
        read -rp "$(msg choose)" choice
        case $choice in
            1) createBackup ;;
            2) listBackups ;;
            3) restoreBackup ;;
            4) deleteBackup ;;
            0) break ;;
        esac
        [ "$choice" = "0" ] && continue
        echo -e "\n${cyan}$(msg press_enter)${reset}"
        read -r
    done
}