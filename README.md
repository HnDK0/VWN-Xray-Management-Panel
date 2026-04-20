# VWN — Xray Management Panel

> **Bash-панель управления** для развёртывания и администрирования VPN-стека на базе **Xray-core** с поддержкой VLESS + WebSocket/TLS, VLESS Reality, XHTTP, Cloudflare WARP, Tor, Psiphon и внешних relay-серверов.

---

## Содержание

- [Обзор](#обзор)
- [Архитектура](#архитектура)
- [Требования](#требования)
- [Быстрая установка](#быстрая-установка)
- [Режимы установки](#режимы-установки)
- [Функциональность](#функциональность)
- [Структура проекта](#структура-проекта)
- [Конфигурационные файлы](#конфигурационные-файлы)
- [CLI-команды (vwn)](#cli-команды-vwn)
- [Модули](#модули)
- [Известные проблемы](#известные-проблемы)
- [Переменные окружения](#переменные-окружения)

---

## Обзор

VWN — интерактивная bash-панель для управления VPN-сервером. Устанавливается одной командой, управляется через текстовое меню или CLI.

**Протоколы и транспорты:**
- `VLESS + WebSocket + TLS + Nginx + CDN` (режим WS)
- `VLESS + XHTTP` (HTTP/2 chunked transport, CDN-совместимый) — устанавливается вместе с WS по умолчанию
- `VLESS + Reality` (TLS без домена, имитация легального трафика)

**Туннели исходящего трафика:**
- Cloudflare WARP (WireGuard)
- Psiphon (обход блокировок, страны: DE, NL, US, GB и др.)
- Tor (анонимность, поддержка мостов)
- Relay (VLESS/VMess/Trojan/SOCKS внешний outbound)

---

## Архитектура

```
install.sh              ← bootstrap + загрузчик модулей (self-contained)
modules/
  lang.sh               ← локализация RU/EN
  core.sh               ← утилиты, OS-detection, конфиг-хранилище
  xray.sh               ← установка и конфиг Xray-core (WS)
  nginx.sh              ← Nginx, SSL, CF Guard, sub-auth
  warp.sh               ← Cloudflare WARP
  reality.sh            ← VLESS Reality (отдельный xray-reality.service)
  xhttp.sh              ← XHTTP transport (отдельный xray-xhttp.service)
  relay.sh              ← внешний outbound-прокси
  psiphon.sh            ← Psiphon туннель
  tor.sh                ← Tor туннель
  security.sh           ← SSH, BBR, Fail2Ban, UFW, WebJail, CPU Guard
  users.sh              ← управление пользователями, подписки, QR
  logs.sh               ← ротация логов, SSL-крон, крон очистки
  backup.sh             ← резервное копирование/восстановление
  diag.sh               ← полная диагностика стека
  privacy.sh            ← режим приватности (tmpfs-логи, зачистка)
  adblock.sh            ← блокировка рекламы на уровне Xray routing
  menu.sh               ← главное меню и функции установки
config/
  nginx_base.conf       ← шаблон Nginx (WS режим, direct TLS)
  nginx_main.conf       ← основной nginx.conf
  nginx_default.conf    ← default vhost
  sub_map.conf          ← map для подписочных URL
  xray_ws.json          ← шаблон конфига Xray WS
  xray_reality.json     ← шаблон конфига Xray Reality
  xray_xhttp.json       ← шаблон конфига Xray XHTTP
vwn                     ← бинарный загрузчик (устанавливается в /usr/local/bin/vwn)
```

**Принцип работы:** `install.sh` содержит bootstrap-код встроенно (работает через `bash <(curl ...)`). Модули скачиваются с GitHub в `/usr/local/lib/vwn/` и подключаются через `source`. Конфиги генерируются из шаблонов с заменой плейсхолдеров (`render_config`).

---

## Требования

| Компонент | Требование |
|-----------|-----------|
| ОС | Ubuntu 20.04+ / Debian 11+ / CentOS 8+ / Fedora (apt или dnf/yum) |
| Права | root |
| RAM | минимум 512 MB (рекомендуется 1 GB+) |
| Диск | минимум 1536 MB свободного места |
| Архитектура | x86_64 |
| Nginx | >= 1.25.1 (mainline, с поддержкой `http2 on` + ALPN) |
| Интернет | обязателен (скачивает Xray, WARP, acme.sh) |
| Домен | обязателен для WS+TLS режима (должен смотреть на IP сервера) |

**Устанавливаемые зависимости:** `tar`, `gpg`, `unzip`, `jq`, `nano`, `ufw`, `socat`, `curl`, `qrencode`, `python3`, `nginx` (mainline), `xray-core`, `cloudflare-warp`.

---

## Быстрая установка

### Интерактивная (рекомендуется)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/HnDK0/VWN-Xray-Management-Panel/main/install.sh)
```

### Обновление модулей

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/HnDK0/VWN-Xray-Management-Panel/main/install.sh) --update
# или после установки:
vwn update
```

---

## Режимы установки

### 1. Интерактивный режим

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/HnDK0/VWN-Xray-Management-Panel/main/install.sh)
```

При запуске предлагается выбор:
- **Вариант 1 — WS+TLS+CDN:** VLESS + WebSocket + TLS + Nginx + WARP + CDN (XHTTP устанавливается автоматически)
- **Вариант 2 — Reality only:** VLESS + Reality + WARP

Мастер последовательно запрашивает домен, URL заглушки, метод SSL и опциональную установку Reality поверх WS.

### 2. Автоматический режим (`--auto`)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/HnDK0/VWN-Xray-Management-Panel/main/install.sh) \
  --auto \
  [ОПЦИИ]
```

#### Полный список параметров `--auto`

| Параметр | По умолчанию | Описание |
|----------|-------------|---------|
| `--domain ДОМЕН` | — (обязателен) | CDN-домен для VLESS+WS+TLS |
| `--stub URL` | `https://httpbin.org/` | URL сайта-заглушки (фейковый сайт) |
| `--lang ru\|en` | `ru` | Язык интерфейса |
| `--reality` | — | Установить Reality дополнительно к WS |
| `--reality-dest HOST:PORT` | `microsoft.com:443` | SNI-назначение для Reality |
| `--reality-port ПОРТ` | `8443` | Внешний порт Reality |
| `--cert-method standalone\|cf` | `standalone` | Метод выпуска SSL |
| `--cf-email EMAIL` | — | Email Cloudflare (при `--cert-method cf`) |
| `--cf-key KEY` | — | Global API Key Cloudflare |
| `--skip-ws` | — | Пропустить WS, установить только Reality |
| `--xhttp` | — | Явно включить XHTTP (включён по умолчанию с WS) |
| `--skip-xhttp` | — | Не устанавливать XHTTP транспорт |
| `--bbr` | — | Включить BBR TCP congestion control |
| `--fail2ban` | — | Установить и настроить Fail2Ban |
| `--jail` | — | WebJail nginx-probe (требует `--fail2ban`) |
| `--ssh-port ПОРТ` | — | Сменить порт SSH |
| `--ipv6` | — | Включить IPv6 |
| `--cpu-guard` | — | CPU Guard (cgroups-приоритет для xray/nginx) |
| `--adblock` | — | Блокировка рекламы (geosite:category-ads-all) |
| `--privacy` | — | Privacy Mode (без логов трафика, tmpfs) |
| `--psiphon` | — | Установить Psiphon |
| `--psiphon-country КОД` | — | Страна выхода Psiphon (DE, NL, US, GB…) |
| `--psiphon-warp` | — | Psiphon через WARP |
| `--no-warp` | — | Не настраивать Cloudflare WARP |

> **Внутренний порт Xray** назначается автоматически (случайный свободный). Задавать его вручную не нужно — на схему подключения клиентов он не влияет.

---

### Примеры

#### Минимально — только WS+TLS+CDN

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/HnDK0/VWN-Xray-Management-Panel/main/install.sh) \
  --auto \
  --domain vpn.example.com
```

#### WS + XHTTP с кастомной заглушкой и BBR

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/HnDK0/VWN-Xray-Management-Panel/main/install.sh) \
  --auto \
  --domain vpn.example.com \
  --stub https://www.openstreetmap.org/ \
  --bbr
```

> XHTTP устанавливается вместе с WS автоматически — флаг `--xhttp` можно не указывать явно.

#### Только WS, без XHTTP

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/HnDK0/VWN-Xray-Management-Panel/main/install.sh) \
  --auto \
  --domain vpn.example.com \
  --skip-xhttp
```

#### Только Reality (без WS / Nginx / SSL / XHTTP)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/HnDK0/VWN-Xray-Management-Panel/main/install.sh) \
  --auto \
  --skip-ws \
  --reality --reality-dest microsoft.com:443 --reality-port 8443
```

#### WS + XHTTP + Reality, SSL через Cloudflare DNS

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/HnDK0/VWN-Xray-Management-Panel/main/install.sh) \
  --auto \
  --domain vpn.example.com \
  --cert-method cf --cf-email me@example.com --cf-key AbCd1234567890 \
  --reality --reality-dest apple.com:443 \
  --bbr --fail2ban
```

#### WS + Psiphon с выбором страны, смена порта SSH, adblock

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/HnDK0/VWN-Xray-Management-Panel/main/install.sh) \
  --auto \
  --domain vpn.example.com \
  --psiphon --psiphon-country NL \
  --ssh-port 2222 \
  --bbr --adblock
```

#### Полная установка — все компоненты

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/HnDK0/VWN-Xray-Management-Panel/main/install.sh) \
  --auto \
  --domain vpn.example.com \
  --cert-method cf --cf-email me@example.com --cf-key AbCd1234567890 \
  --reality --reality-dest apple.com:443 \
  --psiphon --psiphon-country DE \
  --ssh-port 2222 \
  --bbr --fail2ban --jail \
  --adblock --privacy --cpu-guard
```

---

## Функциональность

### Главное меню (30 пунктов)

```
1.  Установка VPN
2.  Управление пользователями
── Протоколы ──────────────────────
3.  WS + TLS + Nginx (WebSocket режим)
4.  Reality
5.  XHTTP
── Туннели ────────────────────────
6.  WARP (Cloudflare)
7.  Relay (внешний прокси)
8.  Psiphon
9.  Tor
── Безопасность ───────────────────
10. BBR (TCP оптимизация)
11. Fail2Ban
12. Web Jail (rate-limit нарушителей)
13. Смена порта SSH
14. UFW (файервол)
15. Управление IPv6
16. CPU Guard
17. Блокировка рекламы (Adblock)
── Логи ───────────────────────────
18. Лог Xray (access)
19. Лог Xray (error)
20. Лог Nginx (access)
21. Лог Nginx (error)
22. Очистить логи
23. Режим приватности
── Сервисы ────────────────────────
24. Перезапуск всех сервисов
25. Обновить Xray-core
26. Перестроить все конфиги
27. Диагностика
28. Резервное копирование
29. Язык интерфейса (RU/EN)
30. Полное удаление
```

### WS-меню (управление WebSocket)

```
1.  Изменить порт Xray
2.  Изменить WebSocket путь
3.  Изменить домен
4.  Изменить CDN-хост подключения
5.  Выпустить/обновить SSL
6.  Изменить URL заглушки
7.  CF Guard (блокировать не-CF IP)
8.  Обновить IP-диапазоны Cloudflare
9.  Крон автообновления SSL
10. Крон автоочистки логов
11. Изменить UUID
12. Sub-аутентификация (Basic Auth для /sub/)
13. Перестроить конфиги WS
```

---

## Структура проекта

```
VWN-Xray-Management-Panel/
├── install.sh              # Главный установщик (1390+ строк)
├── vwn                     # Загрузчик + CLI-точка входа
├── .gitignore
├── config/
│   ├── nginx_base.conf     # Nginx: WS+TLS шаблон
│   ├── nginx_main.conf     # Nginx: главный конфиг
│   ├── nginx_default.conf  # Nginx: default vhost
│   ├── sub_map.conf        # Nginx: map для подписок
│   ├── xray_ws.json        # Xray: шаблон WS
│   ├── xray_reality.json   # Xray: шаблон Reality
│   └── xray_xhttp.json     # Xray: шаблон XHTTP
└── modules/
    ├── lang.sh             # Локализация (~107 KB, 800+ строк)
    ├── core.sh             # Ядро утилит (~19 KB)
    ├── xray.sh             # Xray-core (~27 KB)
    ├── nginx.sh            # Nginx (~15 KB)
    ├── warp.sh             # WARP (~14 KB)
    ├── reality.sh          # Reality (~20 KB)
    ├── xhttp.sh            # XHTTP (~15 KB)
    ├── relay.sh            # Relay (~15 KB)
    ├── psiphon.sh          # Psiphon (~20 KB)
    ├── tor.sh              # Tor (~27 KB)
    ├── security.sh         # Безопасность (~30 KB)
    ├── users.sh            # Пользователи (~26 KB)
    ├── logs.sh             # Логи (~5 KB)
    ├── backup.sh           # Бэкапы (~5 KB)
    ├── diag.sh             # Диагностика (~18 KB)
    ├── privacy.sh          # Приватность (~15 KB)
    ├── adblock.sh          # Adblock (~7 KB)
    └── menu.sh             # Меню (~22 KB)
```

---

## Конфигурационные файлы

### Пути после установки

| Файл | Назначение |
|------|-----------|
| `/usr/local/etc/xray/config.json` | Основной конфиг Xray (WS) |
| `/usr/local/etc/xray/xray-reality.json` | Конфиг Reality |
| `/usr/local/etc/xray/xhttp.json` | Конфиг XHTTP |
| `/usr/local/etc/xray/users.conf` | База пользователей (UUID\|label\|token) |
| `/usr/local/etc/xray/vwn.conf` | Настройки панели (язык и т.д.) |
| `/usr/local/etc/xray/connect_host` | CDN-хост для подписок |
| `/usr/local/etc/xray/sub/` | Файлы подписок (HTML + TXT) |
| `/usr/local/lib/vwn/` | Модули панели |
| `/usr/local/bin/vwn` | CLI-бинарь |
| `/etc/nginx/conf.d/` | Конфиги Nginx |
| `/etc/nginx/cert/` | SSL-сертификаты |
| `/var/log/vwn_install.log` | Лог установки |
| `/var/log/xray/access.log` | Лог доступа Xray |
| `/var/log/xray/error.log` | Лог ошибок Xray |

### Плейсхолдеры в шаблонах

| Плейсхолдер | Назначение |
|------------|-----------|
| `__PORT__` | Внутренний порт Xray (назначается автоматически) |
| `__UUID__` | UUID пользователя |
| `__PATH__` | WebSocket / XHTTP путь |
| `__DOMAIN__` | Домен сервера |
| `__PROXY_URL__` | URL сайта-заглушки |
| `__PROXY_HOST__` | Host заглушки (извлекается из URL) |
| `__WS_PATH__` | WS-путь для location в Nginx |
| `__XRAY_PORT__` | Порт для proxy_pass в Nginx |

---

## CLI-команды (vwn)

```bash
vwn                  # Открыть интерактивное меню
vwn status           # Полная диагностика стека
vwn qr               # Показать QR-код подключения
vwn backup           # Создать резервную копию
vwn restore          # Восстановить из резервной копии
vwn update           # Обновить модули и шаблоны с GitHub
vwn open-80          # Открыть порт 80 в UFW (хук для acme.sh)
vwn close-80         # Закрыть порт 80 в UFW (хук для acme.sh)
```

---

## Модули

### `core.sh` — Ядро системы

| Функция | Описание |
|---------|---------|
| `edit_json` | Безопасное редактирование JSON через jq |
| `render_config` | Подстановка плейсхолдеров в шаблоны |
| `rebuildAllConfigs` | Перестройка всех конфигов из шаблонов |
| `setupSystemDNS` | Настройка DNS (предотвращение DNS-утечек) |
| `vwn_conf_get/set/del` | CRUD для `/usr/local/etc/xray/vwn.conf` |
| `run_task` | Выполнение задачи с индикатором OK/FAIL |
| `setupSwap` | Создание swap-файла при нехватке RAM |
| `findFreePort` | Поиск свободного TCP-порта |
| `generateRandomPath` | Генерация случайного WS-пути |
| `getServerIP` | Определение внешнего IP сервера |
| `getServiceStatus` | Статус systemd-сервиса |
| `getWarpStatus` | Статус WARP (Global/Split/OFF) |
| `getBbrStatus` | Статус BBR |
| `getF2BStatus` | Статус Fail2Ban |
| `getWebJailStatus` | Статус Web Jail |
| `getCfGuardStatus` | Статус Cloudflare Guard |
| `checkCertExpiry` | Проверка срока SSL-сертификата |
| `loadAllModules` | Загрузка всех модулей из VWN_LIB |

### `xray.sh` — Управление Xray-core

| Функция | Описание |
|---------|---------|
| `installXray` | Установка Xray-core (официальный скрипт XTLS) |
| `writeXrayConfig` | Запись конфига WS с подстановкой параметров |
| `getConfigInfo` | Чтение параметров из текущего конфига |
| `getShareUrl` | Генерация VLESS ссылки подключения |
| `getQrCode` | Отображение QR-кода (через `qrencode`) |
| `modifyXrayUUID` | Замена UUID в конфиге |
| `modifyXrayPort` | Смена внутреннего порта Xray |
| `modifyWsPath` | Смена WS-пути |
| `modifyProxyPassUrl` | Смена URL заглушки |
| `modifyDomain` | Смена домена |
| `modifyConnectHost` | Смена CDN-хоста для подписок |
| `updateXrayCore` | Обновление Xray-core до latest |
| `rebuildXrayConfigs` | Перестройка конфигов Xray |
| `_validateDomain` | Валидация доменного имени |
| `_validateUrl` | Валидация URL |
| `_validatePort` | Валидация номера порта |

### `nginx.sh` — Nginx и SSL

| Функция | Описание |
|---------|---------|
| `writeNginxConfigBase` | Запись конфига Nginx для WS+TLS |
| `setNginxCert` | Указание путей к сертификатам |
| `configCert` | Выпуск SSL (acme.sh, standalone или CF DNS) |
| `_injectXhttpLocation` | Добавление XHTTP location в Nginx |
| `_removeXhttpLocation` | Удаление XHTTP location |
| `setupRealIpRestore` | Настройка real_ip из Cloudflare IP-диапазонов |
| `manageSubAuth` | Управление Basic Auth для /sub/ (публичная обёртка) |
| `_subAuthEnable` | Включение Basic Auth |
| `_subAuthDisable` | Отключение Basic Auth |
| `_subAuthSetCredentials` | Смена логина/пароля |
| `_fetchCfGuardIPs` | Загрузка актуальных IP-диапазонов Cloudflare |
| `toggleCfGuard` | Включение/выключение CF Guard |
| `applyNginxSub` | Применение настроек подписок в Nginx |

### `warp.sh` — Cloudflare WARP

| Функция | Описание |
|---------|---------|
| `installWarp` | Установка cloudflare-warp |
| `configWarp` | Первоначальная настройка WARP |
| `applyWarpDomains` | Применение split-routing по доменам |
| `toggleWarpMode` | Переключение Global/Split режима |
| `checkWarpStatus` | Проверка IP через WARP |
| `addDomainToWarpProxy` | Добавление домена в WARP split |
| `deleteDomainFromWarpProxy` | Удаление домена из WARP split |

### `reality.sh` — VLESS Reality

| Функция | Описание |
|---------|---------|
| `writeRealityConfig` | Запись конфига Reality |
| `setupRealityService` | Создание systemd-сервиса `xray-reality` |
| `installReality` | Полная установка Reality |
| `showRealityInfo` | Параметры подключения |
| `showRealityQR` | QR-код Reality |
| `modifyRealityUUID` | Смена UUID |
| `modifyRealityPort` | Смена порта |
| `modifyRealityDest` | Смена SNI-назначения |
| `removeReality` | Удаление Reality |
| `rebuildRealityConfigs` | Перестройка конфигов |

### `xhttp.sh` — XHTTP Transport

| Функция | Описание |
|---------|---------|
| `getXhttpStatus` | Статус XHTTP для меню |
| `writeXhttpConfig` | Запись конфига XHTTP |
| `setupXhttpService` | Создание systemd-сервиса `xray-xhttp` |
| `installXhttp` | Полная установка XHTTP (поддерживает флаг `--auto`) |
| `showXhttpInfo` | Параметры подключения |
| `showXhttpQR` | QR-код XHTTP |
| `removeXhttp` | Удаление XHTTP |
| `rebuildXhttpConfigs` | Перестройка конфигов |

### `users.sh` — Управление пользователями

| Функция | Описание |
|---------|---------|
| `addUser` | Добавление пользователя (UUID + метка) |
| `deleteUser` | Удаление пользователя |
| `renameUser` | Переименование |
| `showUsersList` | Список пользователей |
| `showUserQR` | QR-код пользователя |
| `buildUserSubFile` | Генерация файлов подписок (TXT + HTML + Clash YAML) |
| `buildUserHtmlPage` | HTML-страница с QR, ссылками и Clash-конфигом |
| `rebuildAllSubFiles` | Перегенерация подписок всех пользователей |
| `getSubUrl` | URL подписки пользователя |
| `_vless_to_clash` | Конвертация VLESS-ссылки в Clash YAML |
| `_applyUsersToConfigs` | Применение пользователей во все Xray-конфиги |

**Форматы подписок:** VLESS URI, Clash YAML (Meta), HTML-страница с QR-кодом и кнопками копирования.

### `security.sh` — Безопасность

| Функция | Описание |
|---------|---------|
| `changeSshPort` | Смена порта SSH + обновление UFW |
| `enableBBR` | Включение BBR TCP congestion control |
| `setupWebJail` | Настройка Nginx rate-limit Jail |
| `removeWebJail` | Удаление Web Jail |
| `manageUFW` | Управление UFW |
| `getIPv6Status` | Статус IPv6 |
| `toggleIPv6` | Включение/выключение IPv6 |
| `setupCpuGuard` | Защита от CPU-исчерпания (cgroups) |
| `applySysctl` | Оптимизация сетевых параметров ядра |
| `manageFail2Ban` | Управление Fail2Ban |
| `manageWebJail` | Управление Web Jail |

### `tor.sh` — Tor

| Функция | Описание |
|---------|---------|
| `installTor` | Установка Tor |
| `applyTorOutbound` | Добавление Tor как outbound в Xray |
| `toggleTorGlobal` | Переключение Global/Split режима |
| `checkTorIP` | Проверка IP через Tor |
| `renewTorCircuit` | Обновление Tor-цепочки |
| `changeTorCountry` | Смена страны выхода |
| `addTorBridges` | Добавление мостов (Tor bridges) |
| `removeTorBridges` | Удаление мостов |
| `removeTor` | Полное удаление Tor |

### `psiphon.sh` — Psiphon

| Функция | Описание |
|---------|---------|
| `installPsiphonBinary` | Загрузка Psiphon бинаря |
| `setupPsiphonService` | Systemd-сервис Psiphon |
| `applyPsiphonOutbound` | Добавление Psiphon как outbound |
| `togglePsiphonGlobal` | Переключение Global/Split режима |
| `checkPsiphonIP` | Проверка IP через Psiphon |
| `changeCountry` | Смена страны (DE, NL, US, GB…) |
| `switchPsiphonTunnelMode` | Режим туннеля (plain/warp) |
| `removePsiphon` | Удаление Psiphon |

### `relay.sh` — Внешний Relay

| Функция | Описание |
|---------|---------|
| `parseRelayUrl` | Парсинг VLESS/VMess/Trojan/SOCKS URL |
| `buildRelayOutbound` | Сборка outbound-блока для Xray |
| `applyRelayToConfigs` | Применение relay во все конфиги |
| `toggleRelayGlobal` | Переключение Global/Split режима |
| `checkRelayIP` | Проверка IP через relay |
| `removeRelayFromConfigs` | Удаление relay из конфигов |

**Поддерживаемые протоколы:** VLESS+Reality, VLESS+WS, VMess+WS, Trojan, SOCKS5.

### `privacy.sh` — Режим приватности

| Функция | Описание |
|---------|---------|
| `enablePrivacyMode` | Включение: отключить логи, tmpfs, shred |
| `disablePrivacyMode` | Отключение режима приватности |
| `showPrivacyStatus` | Статус всех компонентов приватности |
| `_enableXrayLogTmpfs` | Перенос логов Xray в RAM (tmpfs) |
| `_shredCurrentLogs` | Безопасное затирание логов через `shred` |

### `adblock.sh`, `backup.sh`, `diag.sh`, `logs.sh`

| Функция | Описание |
|---------|---------|
| `enableAdblock` / `disableAdblock` | Блокировка рекламы через geosite в Xray routing |
| `createBackup` / `restoreBackup` | Создание и восстановление .tar.gz бэкапа конфигов |
| `runFullDiag` | Полная диагностика: система, Xray, Nginx, WARP, туннели, SSL |
| `setupLogrotate` / `clearLogs` | Ротация и очистка логов |
| `setupSslCron` / `setupLogClearCron` | Крон-задачи для SSL и очистки |

---

## Известные проблемы

### 🟡 `IFS` не переопределяется глобально

Архитектурное решение: `IFS` намеренно оставлен дефолтным, так как модули рассчитаны на `IFS=' '`. Требует аккуратности при расширении модулей.

---

### 🟢 Зависимость от GitHub при `--update`

Все модули и конфиги скачиваются заново с GitHub raw. Локального кэша нет — при недоступности репозитория обновление упадёт.

---

## Переменные окружения

| Переменная | По умолчанию | Описание |
|-----------|-------------|---------|
| `LOG_FILE` | `/var/log/vwn_install.log` | Файл лога установки |
| `VWN_LIB` | `/usr/local/lib/vwn` | Директория модулей |
| `VWN_BIN` | `/usr/local/bin/vwn` | Путь к CLI-бинарю |
| `VWN_CONF` | `/usr/local/etc/xray/vwn.conf` | Файл настроек панели |
| `VWN_CONFIG_DIR` | `${VWN_LIB}/config` | Директория конфигов |
| `VWN_LANG` | `ru` | Язык интерфейса |
| `VWN_INSTALLER_VERSION` | `2.1.0` | Версия установщика |
| `VWN_GITHUB_RAW` | `https://raw.githubusercontent.com/…` | База URL для загрузки |
| `VWN_MIN_DISK_MB` | `1536` | Минимум свободного места (MB) |
| `RED`, `GREEN`, `YELLOW`, `CYAN`, `RESET` | ANSI-коды | Цвета терминала |
| `red`, `green`, `yellow`, `cyan`, `reset` | то же | Алиасы lowercase для модулей |

---

## Полное удаление

```bash
vwn  # → пункт 30 "Полное удаление"
```

Или вручную:

```bash
systemctl stop nginx xray xray-reality xray-xhttp warp-svc psiphon tor
warp-cli disconnect
apt remove -y nginx* cloudflare-warp
bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove
rm -rf /etc/nginx /usr/local/etc/xray /usr/local/lib/vwn /usr/local/bin/vwn \
       /etc/systemd/system/xray-reality.service \
       /etc/systemd/system/psiphon.service \
       /root/.cloudflare_api /var/lib/psiphon \
       /etc/cron.d/acme-renew /etc/cron.d/clear-logs \
       /etc/sysctl.d/99-xray.conf
systemctl daemon-reload
```

---

## Лицензия

Репозиторий: [HnDK0/VWN-Xray-Management-Panel](https://github.com/HnDK0/VWN-Xray-Management-Panel)
