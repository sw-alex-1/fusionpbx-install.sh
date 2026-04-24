# FusionPBX Installer for Alt Linux

Automated installation script for [FusionPBX](https://www.fusionpbx.com) on [Alt Linux](https://www.basealt.ru/en) (ALT Server). Uses native RPM packages from the Alt Linux repository — no source builds except `mod_pgsql`, which is compiled from FreeSWITCH source because the Alt Linux RPM packages do not include it.

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
| **nginx** | From Alt Linux repository |
| **PostgreSQL** | 16 (md5 auth for TCP, trust for local socket) |
| **FreeSWITCH** | RPM packages from Alt Linux repository |
| **mod_pgsql** | Compiled from matching FreeSWITCH source (PostgreSQL 14+ patch applied) |
| **FusionPBX** | 5.5 branch from Git |
| **Fail2ban** | Pre-configured for FusionPBX, FreeSWITCH, nginx, and SSH |
| **iptables** | Pre-configured for SIP, RTP, HTTP, and SSH |
| **Monit** | Process monitoring |
| **sngrep** | SIP call capture tool |

## Installation Steps

The installer runs 11 steps and **stops on any error** with a clear message:

1. System preparation (packages, updates)
2. PHP and PHP-FPM
3. nginx
4. PostgreSQL
5. FusionPBX (Git clone + Composer)
6. FreeSWITCH (RPM + mod_pgsql from source + config)
7. Firewall (iptables)
8. Fail2ban
9. Additional tools (sngrep, monit)
10. Finalization (database schema, admin user, upgrade.php)
11. FreeSWITCH DSN (switch from SQLite to PostgreSQL)

## Alt Linux Specifics

- **APT-RPM**: Package names differ from Debian (e.g., `php8.2-fpm-fcgi` instead of `php8.2-fpm`)
- **User model**: Both nginx and FreeSWITCH run as `_nginx:_nginx` (mirrors Debian's `www-data` approach)
- **PostgreSQL**: Data directory is `/var/lib/pgsql/data/` (no version subdirectory)
- **mod_pgsql**: Not included in Alt Linux FreeSWITCH RPMs — compiled from source with a PostgreSQL 14+ compatibility patch
- **All FreeSWITCH databases use PostgreSQL** instead of SQLite (avoids file-locking issues with the `_nginx` user on Alt Linux)
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

The installer is idempotent — safe to re-run on a partially configured system. Already installed packages are skipped, existing databases and roles are preserved, and configs are backed up before modification.

## Security

Fail2ban is installed and pre-configured. Review `/etc/fail2ban/jail.local` to adjust settings for your environment.

---

# Установщик FusionPBX для Альт Линукс

Автоматизированный скрипт установки [FusionPBX](https://www.fusionpbx.com) на [Альт Линукс](https://www.basealt.ru) (ALT Server). Используются штатные RPM-пакеты из репозитория Альт Линукс — сборка из исходников применяется только для `mod_pgsql`, который отсутствует в RPM-пакетах FreeSWITCH.

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
| **nginx** | Из репозитория Альт Линукс |
| **PostgreSQL** | 16 (md5-аутентификация для TCP, trust для локального сокета) |
| **FreeSWITCH** | RPM-пакеты из репозитория Альт Линукс |
| **mod_pgsql** | Компилируется из исходников FreeSWITCH (с патчем для PostgreSQL 14+) |
| **FusionPBX** | Ветка 5.5 из Git |
| **Fail2ban** | Преднастроен для FusionPBX, FreeSWITCH, nginx и SSH |
| **iptables** | Преднастроен для SIP, RTP, HTTP и SSH |
| **Monit** | Мониторинг процессов |
| **sngrep** | Перехват SIP-вызовов |

## Шаги установки

Установщик выполняет 11 шагов и **останавливается при любой ошибке** с понятным сообщением:

1. Подготовка системы (пакеты, обновления)
2. PHP и PHP-FPM
3. nginx
4. PostgreSQL
5. FusionPBX (Git-клонирование + Composer)
6. FreeSWITCH (RPM + mod_pgsql из исходников + конфигурация)
7. Межсетевой экран (iptables)
8. Fail2ban
9. Дополнительные инструменты (sngrep, monit)
10. Завершение (схема БД, пользователь-администратор, upgrade.php)
11. DSN FreeSWITCH (переключение с SQLite на PostgreSQL)

## Особенности Альт Линукс

- **APT-RPM**: Имена пакетов отличаются от Debian (например, `php8.2-fpm-fcgi` вместо `php8.2-fpm`)
- **Пользователь**: nginx и FreeSWITCH работают от имени `_nginx:_nginx` (аналог `www-data` в Debian)
- **PostgreSQL**: Каталог данных — `/var/lib/pgsql/data/` (без подкаталога версии)
- **mod_pgsql**: Отсутствует в RPM-пакетах FreeSWITCH — компилируется из исходников с патчем совместимости для PostgreSQL 14+
- **Все базы данных FreeSWITCH используют PostgreSQL** вместо SQLite (устраняет проблемы с блокировками файлов от пользователя `_nginx`)
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

Установщик идемпотентен — безопасен для повторного запуска на частично настроенной системе. Уже установленные пакеты пропускаются, существующие базы данных и роли сохраняются, конфигурации резервируются перед изменением.

## Безопасность

Fail2ban устанавливается и преднастраивается автоматически. Проверьте `/etc/fail2ban/jail.local` для настройки под ваши требования.
