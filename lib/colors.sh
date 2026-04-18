#!/usr/bin/env bash
# =================================================================
# lib/colors.sh — Цветовые переменные и инициализация tput
#
# SOURCE'd из install.sh в самом начале.
# Экспортирует: RED GREEN YELLOW CYAN RESET
# Предоставляет: _init_colors()
# =================================================================

_init_colors() {
    if [[ -t 1 ]] && command -v tput &>/dev/null; then
        RED=$(    tput setaf 1 2>/dev/null || printf '')$(tput bold 2>/dev/null || printf '')
        GREEN=$(  tput setaf 2 2>/dev/null || printf '')$(tput bold 2>/dev/null || printf '')
        YELLOW=$( tput setaf 3 2>/dev/null || printf '')$(tput bold 2>/dev/null || printf '')
        CYAN=$(   tput setaf 6 2>/dev/null || printf '')$(tput bold 2>/dev/null || printf '')
        RESET=$(  tput sgr0    2>/dev/null || printf '')
    else
        RED='' GREEN='' YELLOW='' CYAN='' RESET=''
    fi
    export RED GREEN YELLOW CYAN RESET
}

# Немедленная инициализация при source
_init_colors

# Совместимость с оригинальными modules/*.sh:
# они используют строчные имена переменных red/green/yellow/cyan/reset
red="$RED"
green="$GREEN"
yellow="$YELLOW"
cyan="$CYAN"
reset="$RESET"
export red green yellow cyan reset
