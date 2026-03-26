#!/bin/bash
# =================================================================
# update.sh — Безопасное обновление модулей VWN
# Вызывается через: vwn update  или  web-панель → Settings → Run Update
# НЕ использует curl|bash (антипаттерн безопасности)
# =================================================================

set -e

GITHUB_RAW="https://raw.githubusercontent.com/HnDK0/VWN-Xray-Management-Panel/main"
VWN_LIB="/usr/local/lib/vwn"
MODULES="lang core xray nginx warp reality relay psiphon tor security logs backup users diag panel menu"

red=$(tput setaf 1 2>/dev/null && tput bold 2>/dev/null || printf '\033[1;31m')
green=$(tput setaf 2 2>/dev/null && tput bold 2>/dev/null || printf '\033[1;32m')
cyan=$(tput setaf 6 2>/dev/null && tput bold 2>/dev/null || printf '\033[1;36m')
reset=$(tput sgr0 2>/dev/null || printf '\033[0m')

echo -e "${cyan}================================================================${reset}"
echo -e "   VWN — Updating modules"
echo -e "${cyan}================================================================${reset}"
echo ""

# Скачиваем каждый модуль в tmp, потом атомарно копируем
for module in $MODULES; do
    printf "  Updating %-12s ... " "${module}.sh"
    tmpfile=$(mktemp)
    if curl -fsSL --connect-timeout 15 --proto '=https' --tlsv1.2 \
        "${GITHUB_RAW}/modules/${module}.sh" -o "$tmpfile" 2>/dev/null; then
        # Базовая проверка: файл должен начинаться с #!/bin/bash
        if head -1 "$tmpfile" | grep -q '#!/bin/bash'; then
            chmod 600 "$tmpfile"
            mv -f "$tmpfile" "${VWN_LIB}/${module}.sh"
            echo "${green}OK${reset}"
        else
            rm -f "$tmpfile"
            echo "${red}SKIP (bad content)${reset}"
        fi
    else
        rm -f "$tmpfile"
        echo "${red}FAIL (download error)${reset}"
    fi
done

# Обновляем web_panel.py и panel.html
for fname in web_panel.py panel.html; do
    printf "  Updating %-12s ... " "$fname"
    tmpfile=$(mktemp)
    if curl -fsSL --connect-timeout 15 --proto '=https' --tlsv1.2 \
        "${GITHUB_RAW}/modules/${fname}" -o "$tmpfile" 2>/dev/null; then
        [ "$fname" = "web_panel.py" ] && chmod 700 "$tmpfile" || chmod 600 "$tmpfile"
        mv -f "$tmpfile" "${VWN_LIB}/${fname}"
        echo "${green}OK${reset}"
    else
        rm -f "$tmpfile"
        echo "${red}FAIL${reset}"
    fi
done

echo ""
# Перезапускаем панель если запущена
if systemctl is-active --quiet vwn-panel 2>/dev/null; then
    systemctl kill -s SIGHUP vwn-panel 2>/dev/null || systemctl restart vwn-panel
    echo "${green}Panel config reloaded.${reset}"
fi

# Показываем версию
ver=$(grep 'VWN_VERSION=' "${VWN_LIB}/core.sh" 2>/dev/null | head -1 | grep -oP '"[^"]+"' | tr -d '"')
echo "${green}Update complete. Version: ${ver:-unknown}${reset}"
echo "Run: vwn"
