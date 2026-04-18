#!/usr/bin/env bash
# =================================================================
# lib/system.sh — Системные функции
#
# Предоставляет:
#   identifyOS()         — определить ОС и задать PACKAGE_MANAGEMENT_*
#   installPackage()     — установить пакет с retry и правильным выводом
#   install_base_packages() — базовые зависимости установщика
#   fix_apt_mirrors()    — автовыбор рабочего APT-зеркала
#   setupSwap()          — создать swap-файл если нужен
#   prepareApt()         — очистить dpkg-блокировки
#
# Зависимости: logging.sh, ui.sh, colors.sh
# =================================================================

# -----------------------------------------------------------------
# Определение ОС — устанавливает PACKAGE_MANAGEMENT_* переменные
# Вызывается из modules/core.sh и install.sh
# -----------------------------------------------------------------
identifyOS() {
    if [[ "$(uname)" != "Linux" ]]; then
        die "Поддерживается только Linux"
    fi

    if command -v apt &>/dev/null; then
        # Используем ключи с таймаутом — оригинальные из core.sh
        PACKAGE_MANAGEMENT_INSTALL='timeout 300 apt-get -y --no-install-recommends \
            -o Dpkg::Lock::Timeout=60 \
            -o Acquire::http::Timeout=30 \
            -o Dpkg::Options::="--force-confdef" \
            -o Dpkg::Options::="--force-confold" \
            install'
        PACKAGE_MANAGEMENT_REMOVE='apt purge -y'
        PACKAGE_MANAGEMENT_UPDATE='timeout 120 apt-get update -o Acquire::http::Timeout=30'
        OS_FAMILY="debian"

    elif command -v dnf &>/dev/null; then
        PACKAGE_MANAGEMENT_INSTALL='timeout 300 dnf -y install --setopt=install_weak_deps=False'
        PACKAGE_MANAGEMENT_REMOVE='dnf remove -y'
        PACKAGE_MANAGEMENT_UPDATE='timeout 120 dnf check-update || true'
        OS_FAMILY="rhel"
        ${PACKAGE_MANAGEMENT_INSTALL} 'epel-release' &>/dev/null || true

    elif command -v yum &>/dev/null; then
        PACKAGE_MANAGEMENT_INSTALL='timeout 300 yum -y install --setopt=install_weak_deps=False'
        PACKAGE_MANAGEMENT_REMOVE='yum remove -y'
        PACKAGE_MANAGEMENT_UPDATE='timeout 120 yum check-update || true'
        OS_FAMILY="rhel"
        ${PACKAGE_MANAGEMENT_INSTALL} 'epel-release' &>/dev/null || true

    else
        die "Не поддерживаемый пакетный менеджер. Нужен apt/dnf/yum"
    fi

    export PACKAGE_MANAGEMENT_INSTALL PACKAGE_MANAGEMENT_REMOVE PACKAGE_MANAGEMENT_UPDATE OS_FAMILY
    log_ok "OS: ${OS_FAMILY}, PKG=$(command -v apt dnf yum 2>/dev/null | head -1)"
}

# -----------------------------------------------------------------
# Установка одного пакета
# Вызов: installPackage <имя_пакета>
# -----------------------------------------------------------------
installPackage() {
    local pkg="$1"
    echo -n "  ${pkg}... "

    # Быстрая проверка — уже установлен?
    if [[ "${OS_FAMILY:-debian}" == "debian" ]]; then
        if dpkg -s "$pkg" &>/dev/null \
            && dpkg -s "$pkg" 2>/dev/null | grep -q "^Status: install ok installed"; then
            echo -e "${GREEN}SKIP${RESET}"
            return 0
        fi
    else
        if command -v "$pkg" &>/dev/null; then
            echo -e "${GREEN}SKIP${RESET}"
            return 0
        fi
    fi

    export DEBIAN_FRONTEND=noninteractive
    if eval "${PACKAGE_MANAGEMENT_INSTALL} '${pkg}'" >/dev/null 2>&1; then
        echo -e "${GREEN}OK${RESET}"
        log_ok "Package installed: $pkg"
        return 0
    fi

    # Retry: чиним apt и пробуем ещё раз
    echo -e "${YELLOW}RETRY${RESET}"
    log_warn "Package install failed first try: $pkg — retrying"
    prepareApt
    eval "${PACKAGE_MANAGEMENT_UPDATE}" >/dev/null 2>&1 || true

    if eval "${PACKAGE_MANAGEMENT_INSTALL} '${pkg}'" >/dev/null 2>&1; then
        echo -e "${GREEN}OK (retry)${RESET}"
        log_ok "Package installed (retry): $pkg"
        return 0
    else
        echo -e "${RED}FAIL${RESET}"
        log_error "Package install FAILED: $pkg"
        return 1
    fi
}

# -----------------------------------------------------------------
# Базовые зависимости для работы установщика
# -----------------------------------------------------------------
install_base_packages() {
    export DEBIAN_FRONTEND=noninteractive

    # Одна apt-команда — быстрее чем по одному
    local pkgs=("curl" "jq" "bash" "coreutils" "cron")

    if [[ "${OS_FAMILY:-debian}" == "debian" ]]; then
        set +o pipefail
        yes '' | apt-get install -y -q \
            -o Dpkg::Lock::Timeout=60 \
            -o Dpkg::Options::="--force-confdef" \
            -o Dpkg::Options::="--force-confold" \
            "${pkgs[@]}" 2>/dev/null || true
        set -o pipefail
        systemctl enable --now cron 2>/dev/null || true
    else
        for p in "${pkgs[@]}"; do
            eval "${PACKAGE_MANAGEMENT_INSTALL} '${p}'" >/dev/null 2>&1 || true
        done
        systemctl enable --now crond 2>/dev/null || true
    fi

    log_ok "Base packages installed"
}

# -----------------------------------------------------------------
# Очистка dpkg/apt-блокировок
# Используется: modules/core.sh::prepareApt() + install.sh
# -----------------------------------------------------------------
prepareApt() {
    # Убиваем зависшие apt/dpkg процессы
    killall -9 apt apt-get dpkg dpkg-deb unattended-upgrades 2>/dev/null || true

    # Снимаем блокировки
    fuser -kk /var/lib/dpkg/lock* /var/cache/apt/archives/lock \
               /var/lib/apt/lists/lock* 2>/dev/null || true
    sleep 0.5

    # Удаляем файлы блокировок
    rm -f /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend \
          /var/cache/apt/archives/lock /var/lib/apt/lists/lock*

    # Исправляем состояние dpkg
    export DEBIAN_FRONTEND=noninteractive
    dpkg --configure -a --force-confold --force-confdef 2>/dev/null || true
    log_info "APT locks cleared"
}

# -----------------------------------------------------------------
# Автовыбор рабочего APT-зеркала
# -----------------------------------------------------------------
fix_apt_mirrors() {
    [[ "${OS_FAMILY:-debian}" != "debian" ]] && return 0

    prepareApt

    # Пробуем стандартный репозиторий
    if timeout 30 apt-get \
            -o Acquire::ForceIPv4=true \
            -o Acquire::http::Timeout=15 \
            update -qq 2>/dev/null; then
        log_ok "APT: default mirror OK"
        return 0
    fi

    warn "APT: основной репозиторий не отвечает, пробуем зеркала..."
    log_warn "APT default mirror failed"

    local -a mirrors=(
        "http://ftp.ru.debian.org/debian/"
        "http://mirror.rol.ru/debian/"
        "http://debian.mirohost.net/debian/"
        "http://debian-mirror.ru/debian/"
        "http://ftp.debian.org/debian/"
    )

    cp -a /etc/apt/sources.list /etc/apt/sources.list.vwn_backup 2>/dev/null || true

    for mirror in "${mirrors[@]}"; do
        printf "  Зеркало %-40s" "$mirror"
        log_info "APT: trying mirror $mirror"

        sed -e "s|http://.*debian.org/debian/|${mirror}|g" \
            -e "s|http://security.debian.org/|${mirror}|g" \
            /etc/apt/sources.list > /etc/apt/sources.list.tmp
        mv /etc/apt/sources.list.tmp /etc/apt/sources.list

        prepareApt
        if timeout 30 apt-get \
                -o Acquire::ForceIPv4=true \
                -o Acquire::http::Timeout=15 \
                update -qq 2>/dev/null; then
            echo -e " ${GREEN}[OK]${RESET}"
            log_ok "APT: mirror OK: $mirror"
            return 0
        else
            echo -e " ${RED}[FAIL]${RESET}"
        fi
    done

    # Откат на оригинал
    mv /etc/apt/sources.list.vwn_backup /etc/apt/sources.list 2>/dev/null || true
    prepareApt
    warn "Все зеркала недоступны, используем стандартный"
    log_warn "All APT mirrors failed — reverting"
}

# -----------------------------------------------------------------
# Swap — создаём если RAM мало и swap отсутствует
# -----------------------------------------------------------------
setupSwap() {
    local swap_total; swap_total=$(free -m | awk '/^Swap:/{print $2}')
    if (( ${swap_total:-0} > 256 )); then
        log_info "Swap already exists (${swap_total}MB)"
        return 0
    fi

    local ram_mb swap_mb
    ram_mb=$(free -m | awk '/^Mem:/{print $2}')
    if   (( ram_mb <= 512  )); then swap_mb=1024
    elif (( ram_mb <= 1024 )); then swap_mb=1024
    elif (( ram_mb <= 2048 )); then swap_mb=2048
    else swap_mb=1024
    fi

    info "Создание swap ${swap_mb}MB..."
    log_info "Creating swap: ${swap_mb}MB (RAM=${ram_mb}MB)"

    local swapfile="/swapfile"
    if fallocate -l "${swap_mb}M" "$swapfile" 2>/dev/null \
        || dd if=/dev/zero of="$swapfile" bs=1M count="$swap_mb" status=none 2>/dev/null; then
        chmod 600 "$swapfile"
        mkswap "$swapfile" &>/dev/null
        swapon "$swapfile" 2>/dev/null || true
        grep -q "$swapfile" /etc/fstab || echo "$swapfile none swap sw 0 0" >> /etc/fstab
        sysctl -w vm.swappiness=10 &>/dev/null || true
        grep -q "vm.swappiness" /etc/sysctl.conf || echo "vm.swappiness=10" >> /etc/sysctl.conf
        log_ok "Swap created: ${swap_mb}MB"
    else
        warn "Не удалось создать swap, продолжаем..."
        log_warn "Swap creation failed"
    fi
}

# -----------------------------------------------------------------
# Nginx mainline (из modules/menu.sh — переносим в lib)
# -----------------------------------------------------------------
_installNginxMainline() {
    local cur_ver cur_minor
    cur_ver=$(nginx -v 2>&1 | grep -oP '\d+\.\d+\.\d+' | head -1)
    cur_minor=$(echo "${cur_ver:-0.0.0}" | cut -d. -f2)

    if [[ -n "$cur_ver" ]] && (( cur_minor >= 19 )); then
        log_info "nginx $cur_ver already sufficient (>=1.19)"
        return 0
    fi

    info "nginx ${cur_ver:-не установлен} → ставим mainline из nginx.org..."
    log_info "Installing nginx mainline"

    if command -v apt &>/dev/null; then
        installPackage gnupg2 || true
        curl -fsSL https://nginx.org/keys/nginx_signing.key \
            | gpg --dearmor -o /usr/share/keyrings/nginx-archive-keyring.gpg 2>/dev/null

        local codename
        codename=$(. /etc/os-release 2>/dev/null && echo "${VERSION_CODENAME:-focal}")

        echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] \
http://nginx.org/packages/mainline/ubuntu ${codename} nginx" \
            > /etc/apt/sources.list.d/nginx-mainline.list

        printf 'Package: *\nPin: origin nginx.org\nPin-Priority: 900\n' \
            > /etc/apt/preferences.d/99nginx

        apt-get update -qq 2>/dev/null
        apt-get remove -y nginx nginx-common nginx-core 2>/dev/null || true
        apt-get install -y nginx
    else
        cat > /etc/yum.repos.d/nginx-mainline.repo << 'YUMEOF'
[nginx-mainline]
name=nginx mainline repo
baseurl=http://nginx.org/packages/mainline/centos/$releasever/$basearch/
gpgcheck=1
enabled=1
gpgkey=https://nginx.org/keys/nginx_signing.key
module_hotfixes=true
YUMEOF
        eval "${PACKAGE_MANAGEMENT_INSTALL} nginx"
    fi

    local new_ver; new_ver=$(nginx -v 2>&1 | grep -oP '\d+\.\d+\.\d+' | head -1)
    ok "nginx установлен: ${new_ver}"
    log_ok "nginx mainline: $new_ver"
}
