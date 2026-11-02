# FusionPBX Installer for Alt Linux

Automated installation script for [FusionPBX](https://www.fusionpbx.com) on [Alt Linux](https://www.basealt.ru/en) (ALT Server). Uses native RPM packages from the Alt Linux repository — no source builds except `mod_pgsql`, which is compiled from FreeSWITCH source because the Alt Linux RPM packages do not include it.

The repository contains two layers: **`Alt/install.sh`** — the base installer for a standalone node, and **`Alt/fusionpbx-ha.sh`** — an optional HA cluster add-on (repmgr + witness) that connects three already installed nodes into a cluster. The full script map is in [Repository Layout](#repository-layout) below.

## Requirements

- Alt Linux Server (p10+ or Sisyphus), minimal install recommended
- Root access
- Internet connectivity (or an HTTP proxy)

## Quick Install

```sh
apt-get install -y git
cd /usr/src && git clone -b alt https://github.com/sw-alex-1/fusionpbx-install.sh.git
cd /usr/src/fusionpbx-install.sh/Alt && ./install.sh
```

## Options

| Option | Description |
|--------|-------------|
| `--proxy host:port` | Route all network requests through an HTTP proxy |
| `--no-cpu-check` | Skip CPU validation (for testing in VMs) |
| `--force` | Bypass the installed-system protection. **DANGER:** re-running on an installed system destroys its configuration |

### Examples

```sh
# Install behind a proxy
./install.sh --proxy 192.168.0.1:8080

# Skip CPU check for a small VM
./install.sh --no-cpu-check
```

## What Gets Installed

| Component | Details |
|-----------|---------|
| **PHP** | 8.2 (FCGI + FPM) |
| **Angie** | Web server (advanced nginx fork) from the official Angie repository |
| **PostgreSQL** | 16 (md5 auth for TCP, trust for local socket) |
| **FreeSWITCH** | RPM packages from Alt Linux repository |
| **mod_pgsql** | Compiled from matching FreeSWITCH source (PostgreSQL 14+ patch applied) |
| **FusionPBX** | 5.6 branch from Git (single point of entry) |
| **Fail2ban** | Pre-configured for FusionPBX, FreeSWITCH, Angie, and SSH |
| **iptables** | Pre-configured for SIP, RTP, HTTP, and SSH |
| **Monit** | Process monitoring |
| **sngrep** | SIP call capture tool |

## Installation Steps

The installer runs 11 steps and **stops on any error** with a clear message:

1. System preparation (packages, updates)
2. PHP and PHP-FPM
3. Angie web server (from the official Angie repository)
4. PostgreSQL
5. FusionPBX (Git clone + Composer)
6. FreeSWITCH (RPM + mod_pgsql from source + config)
7. Firewall (iptables)
8. Fail2ban
9. Additional tools (sngrep, monit)
10. Finalization (database schema, admin user, upgrade.php)
11. FreeSWITCH DSN (switch from SQLite to PostgreSQL)

## Repository Layout

Two independent entry points, one shared resource tree:

- **`Alt/install.sh`** (layer 1) — installs a standalone FusionPBX node.
- **`Alt/fusionpbx-ha.sh`** (layer 2) — the HA add-on: turns three prepared nodes into a repmgr + witness cluster. Usage: [Alt/ha/README.md](Alt/ha/README.md).

### Top level (`Alt/`)

| Script | Purpose |
|--------|---------|
| `pre-install.sh` | Bootstrap on a fresh system: `dist-upgrade`, installs git, clones this repo |
| `install.sh` | The installer itself: 11 steps, stops on the first error, resumable after a failure |
| `fusionpbx-ha.sh` | HA cluster CLI: `--init` / `--join TOKEN` / `--status` / `--doctor` / `--repair`; without flags — interactive mode |
| `plan.md` | Historical porting plan (the nginx → Angie transition notes) |

### Layer 1 libraries (`Alt/resources/`, sourced by `install.sh`)

| Script | Purpose |
|--------|---------|
| `config.sh` | Central configuration: versions, paths, passwords, feature flags — edit before running |
| `arguments.sh` | CLI argument parsing |
| `environment.sh` | OS / architecture detection (ALT check) |
| `colors.sh` | `verbose` / `warn` / `error` output helpers |
| `util.sh` | Shared helpers: `die`, idempotent package install, systemd wrappers, wait loops |
| `guard.sh` | Installed-system protection: `.installed` marker + `.installer-state` progress |
| `interactive.sh` | Terminal questions (proxy, domain, admin password); asks nothing when non-interactive |
| `proxy.sh` | Configures the HTTP proxy for apt / git / wget / curl (sourced before any network operation) |
| `random.sh` | Random string generator |

### Layer 1 steps (executed by `install.sh` in order)

| Script | Step | Purpose |
|--------|------|---------|
| `pre-install.sh` | 1 | System preparation (update, base packages) |
| `php.sh` | 2 | PHP 8.2 (FCGI + FPM) |
| `angie.sh` | 3 | Angie web server: vhost, self-signed SSL |
| `postgresql.sh` | 4 | PostgreSQL 16: role, database, `pg_hba` |
| `fusionpbx.sh` | 5a | FusionPBX: git clone, composer, `/etc/fusionpbx/config.conf` |
| `applications.sh` | 5b | Optional apps (transcribe, speech, edit, sip_trunks, …) |
| `switch.sh` | 6 | FreeSWITCH dispatcher (calls the `switch/` scripts below) |
| `iptables.sh` | 7 | Firewall (SIP, RTP, HTTP, SSH) |
| `fail2ban.sh` | 8 | Fail2ban with FusionPBX / FreeSWITCH / Angie jails |
| `sngrep.sh` | 9a | sngrep (SIP capture) |
| `monit.sh` | 9b | Monit process monitor |
| `finish.sh` | 10 | DB schema, admin user, `upgrade.php`, domain, websocket port, backup cron, hardened websockets unit |
| `switch/dsn.sh` | 11 | FreeSWITCH: SQLite → PostgreSQL for all switch databases |

### FreeSWITCH sub-scripts (`Alt/resources/switch/`)

| Script | Purpose |
|--------|---------|
| `package-release.sh` | FreeSWITCH RPM installation |
| `conf-copy.sh` | Deploys the FusionPBX FreeSWITCH config to `/etc/freeswitch` |
| `source-mod-pgsql.sh` | Builds `mod_pgsql` from matching FreeSWITCH source (absent from ALT RPMs) |
| `disable-missing-modules.sh` | Comments out modules missing from the RPM set |
| `package-permissions.sh` | FreeSWITCH directory ownership (`angie`) |
| `package-systemd.sh` | FreeSWITCH systemd service setup |
| `music-on-hold.sh` | Verifies `v_music_on_hold` was populated and inserts fallback defaults via SQL (called from `finish.sh`) |

### Standalone utilities (`Alt/resources/`)

| Script | Purpose |
|--------|---------|
| `websockets.sh` | Installs the hardened `websockets.service`: waits for PostgreSQL before start, so the websocket router cannot silently fall back to port 8080 (the 502 fix). Called by `finish.sh`; safe to re-run |
| `fix-services.sh` | Post-update repair: replaces `www-data` with `angie` in service templates / units / cron **and** re-installs the hardened websockets unit. Run it after every FusionPBX upgrade |
| `letsencrypt.sh` | Optional: Let's Encrypt certificates via dehydrated (interactive) |

### Supporting assets (not scripts)

`resources/angie/fusionpbx` (vhost), `resources/fusionpbx/config.conf` (template), `resources/fail2ban/*` (jails + filters), `resources/monit/*` (monit config + `shell.sh` — the FreeSWITCH start wrapper), `resources/backup/*` (daily cron scripts installed by `finish.sh`: database backup + maintenance), `resources/switch/source/*` (stock systemd unit + the `mod_pgsql` patch), `resources/websockets/websockets.service` (the hardened unit).

### Layer 2 — HA add-on (`Alt/ha/`)

Documentation: [README](Alt/ha/README.md) (usage) · [RUNBOOK](Alt/ha/RUNBOOK.md) (operations, failover drills) · [DESIGN](Alt/ha/DESIGN.md) (architecture). Short map:

| Path | Purpose |
|------|---------|
| `resources/ha-lib.sh` | The shared function library (steps, probes, config rendering) |
| `resources/role-agent.py` | Tiny HTTP service on :8008 answering "am I the primary" for haproxy |
| `resources/pg-boot-guard.sh` | Boot guard: holds PostgreSQL until the cluster role is certain (no competing primary) |
| `resources/pg-auto-rejoin.sh` | Automatic rejoin of a stale primary at boot |
| `resources/*.tpl`, `*.service` | Rendered configs: haproxy frontend `127.0.0.1:5433`, repmgr, lsyncd, the promote wrapper, unit files |
| `web/cluster/` | Web status add-on: the Status → Cluster page + dashboard widget |
| `tests/` | Sandbox test suite: `run-all.sh` + `test_lib.sh`, `test_cli.sh`, `test_layer1.sh`, `test_render.sh`, `test_agent.sh` (520 checks) |

## Alt Linux Specifics

- **APT-RPM**: Package names differ from Debian (e.g., `php8.2-fpm-fcgi` instead of `php8.2-fpm`)
- **Web server**: Angie instead of nginx — installed from the official Angie repository (`download.angie.software`), configuration is nginx-compatible (supported: Alt 11, Alt 10, Alt SP 10, Alt SP 8)
- **User model**: Angie, PHP-FPM, and FreeSWITCH all run as `angie:angie` (mirrors Debian's `www-data` approach)
- **PostgreSQL**: Data directory is `/var/lib/pgsql/data/` (no version subdirectory)
- **mod_pgsql**: Not included in Alt Linux FreeSWITCH RPMs — compiled from source with a PostgreSQL 14+ compatibility patch
- **All FreeSWITCH databases use PostgreSQL** instead of SQLite (avoids file-locking issues with the `angie` user on Alt Linux)
- **Virtual packages**: The installer correctly handles APT package resolution (e.g., `php8.2-xml` → `php8.2-libs`)
- **Password encryption**: Forces `md5` for PostgreSQL user passwords to ensure compatibility with `pg_hba.conf` auth settings across all PG versions

## Configuration

Edit `resources/config.sh` before running to customize:

```sh
domain_name=ip_address       # hostname, ip_address, or custom domain
system_username=admin        # admin login username
system_password=random       # random or custom password
database_password=random     # random or custom DB password
php_version=8.2              # PHP version
```

## Proxy Support

The installer works fully behind an HTTP proxy. Proxy is configured for:

- Shell environment variables (`http_proxy`, `https_proxy`)
- APT (`/etc/apt/apt.conf`)
- Git (`~/.gitconfig`)
- wget (`/etc/wgetrc`)
- curl (`~/.curlrc`)
- Composer

## Re-running

The installer is protected against accidental re-runs on a live system:

- **After a failed step** — safe to re-run. The installer detects the incomplete previous attempt (progress state in `/etc/fusionpbx/.installer-state`) and resumes, skipping work that is already done.
- **On an installed system** — the installer **refuses to run**. After a successful install, the marker `/etc/fusionpbx/.installed` is created; systems installed by older installer versions are detected by their configured `config.conf` and database schema. A re-run would reset database passwords, replace `/etc/freeswitch` with defaults, and add duplicate domain/admin records. To update FusionPBX use *Advanced → Upgrade* in the web interface instead.
- **`--force`** — bypasses this protection for a conscious re-installation (destroys the existing configuration).

## Security

Fail2ban is installed and pre-configured. Review `/etc/fail2ban/jail.local` to adjust settings for your environment.

---

# Установщик FusionPBX для Альт Линукс

Автоматизированный скрипт установки [FusionPBX](https://www.fusionpbx.com) на [Альт Линукс](https://www.basealt.ru) (ALT Server). Используются штатные RPM-пакеты из репозитория Альт Линукс — сборка из исходников применяется только для `mod_pgsql`, который отсутствует в RPM-пакетах FreeSWITCH.

Репозиторий содержит два слоя: **`Alt/install.sh`** — базовый установщик одиночного узла и **`Alt/fusionpbx-ha.sh`** — опциональное HA-расширение (repmgr + witness), собирающее три установленных узла в кластер. Полная карта скриптов — в разделе [«Структура репозитория»](#структура-репозитория) ниже.

## Требования

- Альт Сервер (p10+ или Сизиф), рекомендуется минимальная установка
- Права root
- Доступ в интернет (или HTTP-прокси)

## Быстрая установка

```sh
apt-get install -y git
cd /usr/src && git clone -b alt https://github.com/sw-alex-1/fusionpbx-install.sh.git
cd /usr/src/fusionpbx-install.sh/Alt && ./install.sh
```

## Параметры

| Параметр | Описание |
|----------|----------|
| `--proxy хост:порт` | Направить все сетевые запросы через HTTP-прокси |
| `--no-cpu-check` | Пропустить проверку CPU (для тестирования в ВМ) |
| `--force` | Обойти защиту от повторного запуска. **ОПАСНО:** повторный запуск на установленной системе уничтожает её настройки |

### Примеры

```sh
# Установка через прокси
./install.sh --proxy 192.168.0.1:8080

# Пропустить проверку CPU для небольшой ВМ
./install.sh --no-cpu-check
```

## Что устанавливается

| Компонент | Подробности |
|-----------|-------------|
| **PHP** | 8.2 (FCGI + FPM) |
| **Angie** | Веб-сервер (продвинутый форк nginx) из официального репозитория Angie |
| **PostgreSQL** | 16 (md5-аутентификация для TCP, trust для локального сокета) |
| **FreeSWITCH** | RPM-пакеты из репозитория Альт Линукс |
| **mod_pgsql** | Компилируется из исходников FreeSWITCH (с патчем для PostgreSQL 14+) |
| **FusionPBX** | Ветка 5.6 из Git (single point of entry) |
| **Fail2ban** | Преднастроен для FusionPBX, FreeSWITCH, Angie и SSH |
| **iptables** | Преднастроен для SIP, RTP, HTTP и SSH |
| **Monit** | Мониторинг процессов |
| **sngrep** | Перехват SIP-вызовов |

## Шаги установки

Установщик выполняет 11 шагов и **останавливается при любой ошибке** с понятным сообщением:

1. Подготовка системы (пакеты, обновления)
2. PHP и PHP-FPM
3. Веб-сервер Angie (из официального репозитория Angie)
4. PostgreSQL
5. FusionPBX (Git-клонирование + Composer)
6. FreeSWITCH (RPM + mod_pgsql из исходников + конфигурация)
7. Межсетевой экран (iptables)
8. Fail2ban
9. Дополнительные инструменты (sngrep, monit)
10. Завершение (схема БД, пользователь-администратор, upgrade.php)
11. DSN FreeSWITCH (переключение с SQLite на PostgreSQL)

## Структура репозитория

Два независимых входа, одно общее дерево ресурсов:

- **`Alt/install.sh`** (слой 1) — устанавливает одиночный узел FusionPBX.
- **`Alt/fusionpbx-ha.sh`** (слой 2) — HA-расширение: собирает три подготовленных узла в кластер repmgr + witness. Использование — [Alt/ha/README.md](Alt/ha/README.md).

### Верхний уровень (`Alt/`)

| Скрипт | Назначение |
|--------|------------|
| `pre-install.sh` | Загрузочный скрипт на чистой системе: `dist-upgrade`, установка git, клонирование репозитория |
| `install.sh` | Сам установщик: 11 шагов, остановка на первой ошибке, возобновление после сбоя |
| `fusionpbx-ha.sh` | CLI HA-кластера: `--init` / `--join ТОКЕН` / `--status` / `--doctor` / `--repair`; без флагов — интерактивный режим |
| `plan.md` | Исторический план портирования (заметки перехода nginx → Angie) |

### Библиотеки слоя 1 (`Alt/resources/`, подключаются `install.sh`)

| Скрипт | Назначение |
|--------|------------|
| `config.sh` | Центральная конфигурация: версии, пути, пароли, флаги — правится перед запуском |
| `arguments.sh` | Разбор аргументов командной строки |
| `environment.sh` | Определение ОС и архитектуры (проверка ALT) |
| `colors.sh` | Функции вывода `verbose` / `warn` / `error` |
| `util.sh` | Общие помощники: `die`, идемпотентная установка пакетов, обёртки systemd, циклы ожидания |
| `guard.sh` | Защита установленной системы: маркер `.installed` + прогресс `.installer-state` |
| `interactive.sh` | Вопросы в терминале (прокси, домен, пароль администратора); без терминала вопросов нет |
| `proxy.sh` | Настройка HTTP-прокси для apt / git / wget / curl (подключается до сетевых операций) |
| `random.sh` | Генератор случайных строк |

### Шаги слоя 1 (выполняются `install.sh` по порядку)

| Скрипт | Шаг | Назначение |
|--------|-----|------------|
| `pre-install.sh` | 1 | Подготовка системы (обновление, базовые пакеты) |
| `php.sh` | 2 | PHP 8.2 (FCGI + FPM) |
| `angie.sh` | 3 | Веб-сервер Angie: vhost, самоподписанный SSL |
| `postgresql.sh` | 4 | PostgreSQL 16: роль, база, `pg_hba` |
| `fusionpbx.sh` | 5a | FusionPBX: клонирование из Git, composer, `/etc/fusionpbx/config.conf` |
| `applications.sh` | 5b | Необязательные приложения (transcribe, speech, edit, sip_trunks, …) |
| `switch.sh` | 6 | Диспетчер FreeSWITCH (вызывает скрипты из `switch/`) |
| `iptables.sh` | 7 | Межсетевой экран (SIP, RTP, HTTP, SSH) |
| `fail2ban.sh` | 8 | Fail2ban с джейлами FusionPBX / FreeSWITCH / Angie |
| `sngrep.sh` | 9a | sngrep (просмотр SIP-диалогов) |
| `monit.sh` | 9b | Монитор процессов Monit |
| `finish.sh` | 10 | Схема БД, администратор, `upgrade.php`, домен, порт вебсокетов, cron резервного копирования, закалённый websockets-юнит |
| `switch/dsn.sh` | 11 | FreeSWITCH: переход с SQLite на PostgreSQL во всех БД коммутатора |

### Подскрипты FreeSWITCH (`Alt/resources/switch/`)

| Скрипт | Назначение |
|--------|------------|
| `package-release.sh` | Установка FreeSWITCH из RPM |
| `conf-copy.sh` | Развёртывание конфигурации FusionPBX для FreeSWITCH в `/etc/freeswitch` |
| `source-mod-pgsql.sh` | Сборка `mod_pgsql` из исходников FreeSWITCH (отсутствует в RPM Альт) |
| `disable-missing-modules.sh` | Отключение модулей, отсутствующих в RPM-наборе |
| `package-permissions.sh` | Права на каталоги FreeSWITCH (`angie`) |
| `package-systemd.sh` | Настройка systemd-сервиса FreeSWITCH |
| `music-on-hold.sh` | Проверяет заполненность `v_music_on_hold` и вставляет запасные записи через SQL (вызывается из `finish.sh`) |

### Автономные утилиты (`Alt/resources/`)

| Скрипт | Назначение |
|--------|------------|
| `websockets.sh` | Устанавливает закалённый `websockets.service`: ждёт готовности PostgreSQL перед стартом, чтобы роутер вебсокетов не откатывался молча на порт 8080 (фикс 502). Вызывается из `finish.sh`; безопасен при повторном запуске |
| `fix-services.sh` | Починка после обновлений: заменяет `www-data` на `angie` в шаблонах сервисов / юнитах / cron **и** переустанавливает закалённый websockets-юнит. Запускать после каждого обновления FusionPBX |
| `letsencrypt.sh` | Необязательно: сертификаты Let's Encrypt через dehydrated (интерактивно) |

### Вспомогательные файлы (не скрипты)

`resources/angie/fusionpbx` (vhost), `resources/fusionpbx/config.conf` (шаблон), `resources/fail2ban/*` (джейлы и фильтры), `resources/monit/*` (конфиг monit + `shell.sh` — обёртка запуска FreeSWITCH), `resources/backup/*` (ежедневные cron-скрипты, ставятся `finish.sh`: резервное копирование и обслуживание БД), `resources/switch/source/*` (штатный systemd-юнит + патч `mod_pgsql`), `resources/websockets/websockets.service` (закалённый юнит).

### Слой 2 — HA-расширение (`Alt/ha/`)

Документация: [README](Alt/ha/README.md) (использование) · [RUNBOOK](Alt/ha/RUNBOOK.md) (эксплуатация, тренировка failover) · [DESIGN](Alt/ha/DESIGN.md) (архитектура). Кратко:

| Путь | Назначение |
|------|------------|
| `resources/ha-lib.sh` | Общая библиотека функций (шаги, пробы, рендеринг конфигов) |
| `resources/role-agent.py` | Мини-HTTP-сервис на :8008, отвечающий haproxy «я — primary?» |
| `resources/pg-boot-guard.sh` | Бут-гард: не даёт PostgreSQL стартовать до выяснения роли (защита от второй primary) |
| `resources/pg-auto-rejoin.sh` | Автоматический возврат устаревшей primary при загрузке |
| `resources/*.tpl`, `*.service` | Рендерящиеся конфиги: haproxy-фронтенд `127.0.0.1:5433`, repmgr, lsyncd, обёртка promote, юниты |
| `web/cluster/` | Веб-статус: страница Status → Cluster + виджет дашборда |
| `tests/` | Песочница тестов: `run-all.sh` + `test_lib.sh`, `test_cli.sh`, `test_layer1.sh`, `test_render.sh`, `test_agent.sh` (520 проверок) |

## Особенности Альт Линукс

- **APT-RPM**: Имена пакетов отличаются от Debian (например, `php8.2-fpm-fcgi` вместо `php8.2-fpm`)
- **Веб-сервер**: Angie вместо nginx — устанавливается из официального репозитория Angie (`download.angie.software`), конфигурация совместима с nginx (поддерживаются: Альт 11, Альт 10, Альт СП 10, Альт СП 8)
- **Пользователь**: Angie, PHP-FPM и FreeSWITCH работают от имени `angie:angie` (аналог `www-data` в Debian)
- **PostgreSQL**: Каталог данных — `/var/lib/pgsql/data/` (без подкаталога версии)
- **mod_pgsql**: Отсутствует в RPM-пакетах FreeSWITCH — компилируется из исходников с патчем совместимости для PostgreSQL 14+
- **Все базы данных FreeSWITCH используют PostgreSQL** вместо SQLite (устраняет проблемы с блокировками файлов от пользователя `angie`)
- **Виртуальные пакеты**: Корректно обрабатывается разрешение виртуальных пакетов APT (например, `php8.2-xml` → `php8.2-libs`)
- **Шифрование паролей**: Принудительно используется `md5` для паролей PostgreSQL, чтобы обеспечить совместимость с аутентификацией `pg_hba.conf` во всех версиях PG

## Конфигурация

Перед запуском отредактируйте `resources/config.sh`:

```sh
domain_name=ip_address       # имя хоста, IP-адрес или пользовательский домен
system_username=admin        # имя пользователя-администратора
system_password=random       # случайный или заданный пароль
database_password=random     # случайный или заданный пароль БД
php_version=8.2              # версия PHP
```

## Поддержка прокси

Установщик полностью работает через HTTP-прокси. Прокси настраивается для:

- Переменных окружения (`http_proxy`, `https_proxy`)
- APT (`/etc/apt/apt.conf`)
- Git (`~/.gitconfig`)
- wget (`/etc/wgetrc`)
- curl (`~/.curlrc`)
- Composer

## Повторный запуск

Установщик защищён от случайного повторного запуска на боевой системе:

- **После сбоя на одном из шагов** — повторный запуск безопасен. Установщик распознаёт незавершённую предыдущую попытку (файл прогресса `/etc/fusionpbx/.installer-state`) и продолжает установку, пропуская уже выполненное.
- **На установленной системе** — установщик **отказывается запускаться**. После успешной установки создаётся маркер `/etc/fusionpbx/.installed`; системы, установленные старыми версиями установщика, распознаются по настроенному `config.conf` и схеме базы данных. Повторный запуск сбросил бы пароли БД, заменил `/etc/freeswitch` дефолтным конфигом и добавил бы дубликаты домена и администратора. Для обновления FusionPBX используйте *Advanced → Upgrade* в веб-интерфейсе.
- **`--force`** — обход защиты для осознанной переустановки (уничтожает текущие настройки).

## Безопасность

Fail2ban устанавливается и преднастраивается автоматически. Проверьте `/etc/fail2ban/jail.local` для настройки под ваши требования.
