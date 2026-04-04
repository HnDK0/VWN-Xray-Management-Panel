#!/bin/bash
# =================================================================
# adblock.sh — Блокировка рекламы через geosite:category-ads-all
#
# Использует встроенный geosite.dat из xray-core.
# Никаких внешних зависимостей — список обновляется вместе с xray.
# Категория category-ads-all агрегирует:
#   EasyList, EasyPrivacy, AdGuard, Peter Lowe's list и др.
# =================================================================

# Правило которое вставляем в routing
_ADBLOCK_RULE='{"type":"field","domain":["geosite:category-ads-all"],"outboundTag":"block"}'

# ── Статус ────────────────────────────────────────────────────────

getAdblockStatus() {
    local enabled=false
    for cfg in "$configPath" "$realityConfigPath"; do
        [ -f "$cfg" ] || continue
        if jq -e '.routing.rules[] | select(.outboundTag=="block") | .domain // [] | map(select(. == "geosite:category-ads-all")) | length > 0' \
            "$cfg" &>/dev/null 2>&1; then
            enabled=true
            break
        fi
    done
    $enabled && echo "${green}ON${reset}" || echo "${red}OFF${reset}"
}

_adblockIsEnabled() {
    [ -f "$configPath" ] || return 1
    jq -e '.routing.rules[] | select(.outboundTag=="block") | .domain // [] | map(select(. == "geosite:category-ads-all")) | length > 0' \
        "$configPath" &>/dev/null 2>&1
}

# ── Применение / удаление ─────────────────────────────────────────

_adblockApplyToConfig() {
    local cfg="$1"
    [ -f "$cfg" ] || return 0

    # Проверяем — уже есть?
    local already
    already=$(jq -r '
        .routing.rules[] |
        select(.outboundTag=="block") |
        .domain // [] |
        map(select(. == "geosite:category-ads-all")) |
        length' "$cfg" 2>/dev/null | head -1)
    [ "${already:-0}" -gt 0 ] && return 0

    # Ищем существующее block-правило с domain (если есть — добавляем туда)
    local has_block_domain
    has_block_domain=$(jq -r '
        .routing.rules[] |
        select(.outboundTag=="block" and (.domain != null)) |
        .outboundTag' "$cfg" 2>/dev/null | head -1)

    if [ -n "$has_block_domain" ]; then
        # Добавляем geosite в существующий domain-список block-правила
        jq '(.routing.rules[] | select(.outboundTag=="block" and (.domain != null))) |=
            .domain += ["geosite:category-ads-all"]' \
            "$cfg" > "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
    else
        # Вставляем новое правило сразу после первого block-правила (geoip:private)
        jq --argjson r "$_ADBLOCK_RULE" '
            .routing.rules = [.routing.rules[0], $r] + .routing.rules[1:]' \
            "$cfg" > "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
    fi
}

_adblockRemoveFromConfig() {
    local cfg="$1"
    [ -f "$cfg" ] || return 0

    # Удаляем geosite:category-ads-all из всех domain-массивов block-правил
    jq '(.routing.rules[] | select(.outboundTag=="block") | .domain) //= map(select(. != "geosite:category-ads-all"))' \
        "$cfg" > "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"

    # Если у block-правила domain стал пустым массивом — удаляем поле domain
    jq '(.routing.rules[] | select(.outboundTag=="block" and (.domain | length == 0))) |= del(.domain)' \
        "$cfg" > "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
}

# ── Включение / выключение ────────────────────────────────────────

enableAdblock() {
    echo -e "${cyan}$(msg adblock_enabling)${reset}"

    local applied=0
    for cfg in "$configPath" "$realityConfigPath"; do
        [ -f "$cfg" ] || continue
        _adblockApplyToConfig "$cfg"
        applied=$((applied + 1))
    done

    if [ "$applied" -eq 0 ]; then
        echo "${red}$(msg adblock_no_configs)${reset}"
        return 1
    fi

    systemctl restart xray 2>/dev/null || true
    systemctl restart xray-reality 2>/dev/null || true

    vwn_conf_set adblock_enabled 1
    echo "${green}$(msg adblock_enabled)${reset}"
    echo ""
    echo -e "  ${green}✓${reset}  geosite:category-ads-all → block (blackhole)"
    echo -e "  ${cyan}$(msg adblock_note)${reset}"
}

disableAdblock() {
    echo -e "${yellow}$(msg adblock_disabling)${reset}"

    for cfg in "$configPath" "$realityConfigPath"; do
        _adblockRemoveFromConfig "$cfg"
    done

    systemctl restart xray 2>/dev/null || true
    systemctl restart xray-reality 2>/dev/null || true

    vwn_conf_set adblock_enabled 0
    echo "${green}$(msg adblock_disabled)${reset}"
}

toggleAdblock() {
    if _adblockIsEnabled; then
        echo -e "${yellow}$(msg adblock_disable_confirm) $(msg yes_no)${reset}"
        read -r confirm
        [[ "$confirm" == "y" ]] && disableAdblock
    else
        enableAdblock
    fi
}

# ── Статус с деталями ─────────────────────────────────────────────

showAdblockStatus() {
    echo ""
    echo -e "${cyan}$(msg adblock_status_title)${reset}"
    echo ""

    for cfg in "$configPath" "$realityConfigPath"; do
        [ -f "$cfg" ] || continue
        local label
        [[ "$cfg" == *reality* ]] && label="Reality" || label="WS"

        local found
        found=$(jq -r '
            .routing.rules[] |
            select(.outboundTag=="block") |
            .domain // [] |
            map(select(. == "geosite:category-ads-all")) |
            length' "$cfg" 2>/dev/null | head -1)

        if [ "${found:-0}" -gt 0 ]; then
            echo -e "  ${green}✓${reset}  Xray $label: geosite:category-ads-all → block"
        else
            echo -e "  ${red}✗${reset}  Xray $label: $(msg adblock_not_active)"
        fi
    done

    echo ""
    echo -e "  ${cyan}$(msg adblock_covers):${reset}"
    echo -e "  EasyList, EasyPrivacy, AdGuard Base, Peter Lowe's List"
    echo -e "  + regional ad lists (CN, RU, JP, KR, IR, TR, UA, DE, FR...)"
    echo ""
}

# ── Меню ──────────────────────────────────────────────────────────

manageAdblock() {
    set +e
    while true; do
        clear
        echo -e "${cyan}================================================================${reset}"
        printf "   ${red}$(msg adblock_title)${reset}  %s\n" "$(date +'%d.%m.%Y %H:%M')"
        echo -e "${cyan}----------------------------------------------------------------${reset}"
        showAdblockStatus
        echo -e "${green}1.${reset} $(msg adblock_enable)"
        echo -e "${green}2.${reset} $(msg adblock_disable)"
        echo -e "${green}3.${reset} $(msg adblock_status)"
        echo -e "${green}0.${reset} $(msg back)"
        echo -e "${cyan}================================================================${reset}"
        read -rp "$(msg choose)" choice
        case $choice in
            1) enableAdblock ;;
            2) disableAdblock ;;
            3) showAdblockStatus ;;
            0) break ;;
        esac
        [ "$choice" = "0" ] && continue
        echo -e "\n${cyan}$(msg press_enter)${reset}"
        read -r
    done
}
