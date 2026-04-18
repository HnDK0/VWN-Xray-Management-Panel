# VWN — Рефакторинг v2.0

**VLESS + WebSocket + TLS + Nginx + WARP + CDN + Reality**

---

## Структура проекта

```
install.sh              Главный установщик (оркестратор)
lib/
  colors.sh             Цветовые переменные (RED/GREEN/YELLOW/CYAN/RESET)
  logging.sh            Система логирования (log_info/ok/warn/error)
  ui.sh                 UI-слой (step, soft_step, section, msg, run_task)
  checks.sh             Все check-функции (диск, SSL, домен, сервисы)
  system.sh             ОС, пакеты, swap, apt, Nginx mainline
  network.sh            UFW, порты, generateRandomPath, getServerIP
modules/                Оригинальные модули (логика VPN-стека)
config/                 Шаблоны конфигурации
vwn                     Бинарный загрузчик системы управления
```

---

## Что изменилось относительно v1

### Надёжность

| Проблема v1 | Решение v2 |
|------------|-----------|
| `set -eo pipefail` | `set -euo pipefail` + `IFS=$'\n\t'` |
| Нет лога | `/var/log/vwn_install.log` — каждое действие с меткой времени |
| Точечные проверки | 5 preflight-функций: root, ОС, диск, интернет, GitHub |
| `trap cleanup EXIT` | `trap '_cleanup $?' EXIT INT TERM` — код возврата передаётся |
| Вручную удалять tmpfiles | `mktmp()` + массив `_TMPFILES[]` — авто-очистка |
| `timeout 900 bash "$0"` | Через `VWN_INSTALL_PARENT` — без двойного вложения |

### Модульность — lib/ реально используется

**Каждый файл в `lib/` source-ится в `install.sh` немедленно** и предоставляет функции:

```bash
# В install.sh:
_source_lib "colors"   # → RED/GREEN/YELLOW/CYAN/RESET + _init_colors()
_source_lib "logging"  # → log_info/ok/warn/error/debug()
_source_lib "ui"       # → step(), soft_step(), section(), msg(), run_task()
_source_lib "checks"   # → check_root/disk/internet/repo/xray/ssl()
_source_lib "system"   # → identifyOS(), installPackage(), prepareApt(), fix_apt_mirrors()
_source_lib "network"  # → ufw_allow_port(), generateRandomPath(), getServerIP()
```

**Принцип разделения:**
- `lib/` — **инфраструктура установщика** (как что-то делать)
- `modules/` — **логика VPN-стека** (что именно делать)
- `install.sh` — **оркестратор** (в каком порядке вызывать)

**Взаимодействие:**
- `lib/system.sh::identifyOS()` и `installPackage()` вызываются в `install.sh`
- `lib/system.sh::prepareApt()` экспортируется в `modules/core.sh` (совместимость)
- `lib/ui.sh::step()` / `run_task()` → используется в `install.sh` для каждого этапа
- `lib/ui.sh::msg()` → fallback до загрузки `modules/lang.sh`
- `lib/network.sh::generateRandomPath()` → вызывается в `_auto_install_ws()`
- `lib/network.sh::getServerIP()` → совместимость с `modules/xray.sh`
- `lib/checks.sh::check_*()` → `run_preflight_checks()` в `install.sh`

### Оптимизация

| Было | Стало |
|------|-------|
| `tput` при каждом echo | `_init_colors()` один раз → экспорт переменных |
| Повторный `apt-get update` | Один раз в `fix_apt_mirrors()` |
| Прямая запись файлов | Атомарно: tmp + mv |
| `kill -9` без проверки | `killall -9` + `fuser -kk` + проверка через `lsof` |
| `$RANDOM` для путей | `/dev/urandom` → `openssl rand` → fallback |
| `eval` везде | Прямые вызовы через `"$@"` |
| `echo $$ > lockfile` без проверки | Проверка PID + обнаружение зависших блокировок |

### UX — визуальная ясность

```
━━━ Системные пакеты ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  curl jq bash coreutils cron               [OK]
  Активация cron                            [OK]
  jq (фиксированная версия)                [OK]

━━━ Проверка окружения ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Root-права                                [OK]
  Определение ОС                            [OK]
  Свободное место                           [OK]
  Интернет                                  [OK]
  GitHub-репозиторий                        [SKIP]   ← soft_step: non-fatal
```

**Лог** — каждая строка содержит временну́ю метку и уровень:
```
[10:23:41] [INFO ] STEP: UFW: SSH + HTTPS → bash -c ...
[10:23:42] [OK   ]   → OK
[10:23:45] [WARN ] APT: основной репозиторий не отвечает
[10:23:48] [OK   ] APT: mirror OK: http://ftp.ru.debian.org/debian/
[10:24:10] [OK   ] SSL cert OK: expires in 89 days
```

---

## Совместимость с оригинальными modules/

`lib/` **не заменяет** `modules/` — они работают совместно:

1. `install.sh` source-ит `lib/*.sh` — получает инфраструктуру
2. `install.sh` загружает `modules/*.sh` через `load_modules()` — получает бизнес-логику
3. `modules/core.sh` экспортирует: `identifyOS`, `installPackage`, `prepareApt` — все они перекрываются версиями из `lib/system.sh`, которые совместимы по интерфейсу

**Экспортированные псевдонимы для совместимости:**
- `lib/colors.sh` → экспортирует `red/green/yellow/cyan/reset` (строчные) для `modules/*.sh`
- `lib/ui.sh::run_task()` → обёртка над `step()` для `modules/menu.sh`
- `lib/ui.sh::msg()` → fallback-таблица до `modules/lang.sh::_initLang()`
- `lib/network.sh::openPort80/closePort80` → псевдонимы для `modules/nginx.sh`
- `lib/checks.sh::isRoot()` → псевдоним `check_root()` для `modules/core.sh`

---

## Использование

```bash
# Интерактивная установка
bash install.sh

# Обновление модулей
bash install.sh --update

# Автоматическая (минимум)
bash install.sh --auto --domain vpn.example.com

# Автоматическая (полный стек)
bash install.sh --auto \
  --domain vpn.example.com \
  --cert-method cf --cf-email me@me.com --cf-key AbCd1234 \
  --reality --reality-dest apple.com:443 --reality-port 8443 \
  --ssh-port 22222 --ipv6 --cpu-guard \
  --fail2ban --jail --adblock --privacy \
  --psiphon --psiphon-country DE \
  --bbr

# Reality без WS
bash install.sh --auto --skip-ws \
  --reality --reality-dest microsoft.com:443

# Справка
bash install.sh --help
```

---

## Лог

```
/var/log/vwn_install.log
```
