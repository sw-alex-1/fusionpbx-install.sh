# План портирования FusionPBX Installer на Alt Linux

## Контекст

На основе анализа репозитория `fusionpbx-install.sh` и ответов на вопросы по Alt Linux,
составлен следующий пошаговый план создания инсталлятора в директории `Alt/`.

### Установленные факты о Alt Linux

| Параметр | Значение |
|----------|----------|
| Пакетный менеджер | `apt-get install -y <pkg>` (APT-RPM) |
| Определение ОС | `lsb_release -a` и `/etc/os-release` работают |
| PHP-FPM | `php8.1-fpm-fcgi`, `php8.2-fpm-fcgi`, `php8.3-fpm-fcgi` |
| PHP-модули | `php8.2-pgsql`, `php8.2-gd` и т.д. по аналогии |
| nginx | есть в репозитории |
| PostgreSQL | `postgresql16-server` (PostgreSQL 16) |
| fail2ban | есть |
| memcached | есть |
| Пользователь nginx | `_nginx:_nginx` |
| haveged | есть |
| ffmpeg, ghostscript, sox | есть |
| init-система | systemd |
| Фаервол | iptables (по умолчанию), nftables доступен, ufw нет |
| PHP-FPM сокет | `/var/run/php8.1-fpm/php8.1-fpm.sock` (для 8.1) |
| sngrep | есть |
| SELinux | нет |
| FreeSWITCH | есть RPM-пакеты: `freeswitch`, `freeswitch-daemon`, `freeswitch-lua`, `libfreeswitch` и др. |
| PG data dir | `/var/lib/pgsql/data/` (БЕЗ номера версии! Не как в CentOS) |
| initdb | Интерактивный! Нужен `sudo -u postgres initdb --auth-local=trust --auth-host=trust` |
| Auth log | `/var/log/auth/secure` |
| Syslog | `/var/log/syslog/messages` |
| journald | systemd-journald по умолчанию, rsyslog для файловых логов |

### За основу берётся debian-инсталлятор

Debian-вариант наиболее полный и актуальный. Из centos-варианта заимствуются:
- Подход к именованию пользователей (`freeswitch:daemon` вместо `www-data:www-data`)
- Создание структуры `sites-available`/`sites-enabled` для nginx
- Инициализация PostgreSQL через `initdb` / `postgresql-setup` вместо `pg_createcluster`

---

## Инкременты

### Инкремент 0: Базовая структура и утилиты

**Цель**: Создать скелет директории `Alt/` с базовыми утилитарными скриптами,
которые не зависят от пакетного менеджера и могут быть протестированы сразу.

**Файлы**:
- `Alt/resources/colors.sh` — перенос из debian без изменений
- `Alt/resources/random.sh` — перенос из debian без изменений
- `Alt/resources/config.sh` — адаптация переменных под Alt Linux
  - `database_version=16` → уточнить (postgresql6-server = PG 16?)
  - `database_repo=system` — оставляем только system (нет apt-репозиториев PostgreSQL)
  - Убрать `os_codename`-зависимые переменные
  - Добавить переменные: `web_user=_nginx`, `web_group=_nginx`, `fs_user=freeswitch`, `fs_group=daemon`
- `Alt/resources/environment.sh` — полная переработка:
  - Замена `lsb_release` на `/etc/os-release` (как основной источник)
  - Убрать зависимость от `apt-get install lsb-release`
  - Определение `os_name=AltLinux`, `os_version`, `os_codename`
  - Логика определения CPU (arm/x86) — переносима, оставить
  - Убрать привязку к Debian-кодовым именам (buster, bullseye и т.д.)
- `Alt/resources/arguments.sh` — перенос из debian с минимальной адаптацией
  - Убрать `--use-php5-package`, `--use-switch-package-unofficial-arm`
  - Оставить актуальные опции

**Критерий приёмки**: Скрипты `colors.sh`, `environment.sh`, `config.sh` выполняются
без ошибок, корректно определяют ОС и CPU на Alt Linux.

---

### Инкремент 1: pre-install и install (точка входа)

**Цель**: Создать точку входа инсталлятора — `install.sh` и `pre-install.sh`.

**Файлы**:
- `Alt/pre-install.sh`:
  - Обновление пакетов: `apt-get update && apt-get upgrade -y`
  - Установка базовых утилит: `git`, `wget`, `ca-certificates`, `nano`, `net-tools`, `unzip`, `dialog`
  - **Уточнить у пользователя**: полный список имён пакетов для базовых утилит
  - Удаление cdrom из sources.list (если актуально для Alt)
  - Отключение visual mode vim
- `Alt/install.sh`:
  - Подключение `config.sh`, `colors.sh`, `environment.sh`
  - Обновление пакетов
  - Последовательный вызов дочерних скриптов (пока заглушек)

**Критерий приёмки**: `install.sh` запускается, корректно обновляет пакеты,
устанавливает базовые утилиты, не падает на Alt Linux.

---

### Инкремент 2: PHP

**Цель**: Установка и настройка PHP-FPM.

**Файлы**:
- `Alt/resources/php.sh`:
  - **Не нужны** сторонние репозитории (sury.org) — в Alt есть PHP 8.1–8.3
  - Установка: `apt-get install -y php${php_version} php${php_version}-fpm-fcgi php${php_version}-pgsql php${php_version}-gd php${php_version}-curl php${php_version}-imap php${php_version}-xml php${php_version}-mbstring php${php_version}-ldap php${php_version}-snmp php${php_version}-sqlite3 php${php_version}-odbc`
  - **Уточнить у пользователя**: точные имена пакетов php-модулей (inotify, dev и др.)
  - Настройка `php.ini`: путь `/etc/php/${php_version}/fpm/php.ini` — **уточнить у пользователя**
  - Параметры: `post_max_size = 80M`, `upload_max_filesize = 80M`, `max_input_vars = 8000`
  - Перезапуск: `systemctl restart php${php_version}-fpm`
  - **Уточнить у пользователя**: имя systemd-сервиса для php-fpm (`php8.2-fpm`?)
  - Оптимизация: убрать дублирование кода через переменные (исправление бага #1 из анализа)
- `Alt/resources/ioncube.sh`:
  - Скачать ioncube loader
  - **Уточнить у пользователя**: путь к extension_dir PHP в Alt Linux
  - Создать ini-файл в правильном каталоге конфигурации
  - **Уточнить у пользователя**: где лежат conf.d для PHP-FPM в Alt?

**Критерий приёмки**: PHP-FPM установлен, сконфигурирован, отвечает на запросы.

---

### Инкремент 3: nginx

**Цель**: Установка и настройка nginx + интеграция с PHP-FPM.

**Файлы**:
- `Alt/resources/nginx/fusionpbx` — конфиг сервера:
  - Обновить путь к сокету PHP-FPM: `unix:/var/run/php${php_version}-fpm/php${php_version}-fpm.sock`
  - Обновить SSL-протоколы (убрать TLSv1 и TLSv1.1 — исправление бага #6)
  - Добавить `http2` директиву (современный синтаксис)
- `Alt/resources/nginx.sh`:
  - `apt-get install -y nginx`
  - Создать `sites-available` / `sites-enabled` (как в CentOS)
  - Обновить основной `nginx.conf` для включения `sites-enabled`
  - Скопировать конфиг fusionpbx, обновить путь к сокету через `sed`
  - Настроить SSL-сертификат (self-signed или snakeoil)
  - **Уточнить у пользователя**: есть ли в Alt пакет `ssl-cert` (snakeoil сертификаты)?
  - Пользователь/группа: `_nginx:_nginx`
  - Удалить default-сайт
  - Перезапуск: `systemctl restart nginx`

**Критерий приёмки**: nginx установлен, fusionpbx-сайт доступен по HTTP/HTTPS,
PHP-FPM корректно обрабатывает запросы.

---

### Инкремент 4: PostgreSQL

**Цель**: Установка и настройка PostgreSQL.

**Файлы**:
- `Alt/resources/postgresql.sh`:
  - Установка: `apt-get install -y sudo postgresql16-server`
  - **Инициализация кластера**: `sudo -u postgres initdb --auth-local=trust --auth-host=trust -D /var/lib/pgsql/data` (интерактивный initdb через init script запрашивает пароль — используем прямой initdb без пароля!)
  - Сервис: `postgresql.service` (без номера версии, не как в CentOS)
  - Настройка `pg_hba.conf`: после initdb с trust — переключаем host-подключения на md5, local оставляем trust
  - Путь к данным: `/var/lib/pgsql/data/` (БЕЗ номера версии! Не `/var/lib/pgsql/16/data/`)
  - Динамическое определение PGDATA (поиск PG_VERSION в нескольких путях)
  - `systemctl enable postgresql`, `systemctl restart postgresql`
  - Создание БД и пользователей через `sudo -u postgres psql`
  - Генерация пароля: `dd if=/dev/urandom bs=1 count=20 2>/dev/null | base64`
- `Alt/resources/postgresql/pg_hba.conf` — адаптация
- `Alt/resources/postgresql/postgresql.conf` — перенос из debian

**Критерий приёмки**: PostgreSQL запущен, БД `fusionpbx` создана,
пользователь `fusionpbx` может подключиться.

---

### Инкремент 5: FusionPBX

**Цель**: Загрузка и установка FusionPBX из Git.

**Файлы**:
- `Alt/resources/fusionpbx.sh`:
  - Установка зависимостей: `git`, `vim`, `ghostscript`, `ffmpeg`, `sox`, `haveged`, `at` и др.
  - **Уточнить у пользователя**: имена пакетов `libtiff-tools`, `qrencode`, `dbus`, `ssl-cert` в Alt
  - `git clone` нужной ветки FusionPBX
  - Создание `/var/cache/fusionpbx`
  - `chown -R _nginx:_nginx /var/www/fusionpbx /var/cache/fusionpbx`
  - **Уточнить у пользователя**: следует ли использовать `_nginx:_nginx` или `freeswitch:daemon` для владельца файлов?
- `Alt/resources/fusionpbx/config.conf` — перенос из debian без изменений

**Критерий приёмки**: FusionPBX скачан, файлы имеют корректные права.

---

### Инкремент 6: FreeSWITCH

**Цель**: Установка FreeSWITCH из RPM-пакетов.

**Файлы**:
- `Alt/resources/switch.sh` — диспетчер установки (только RPM, нет source build)
- `Alt/resources/switch/package-release.sh`:
  - Установка FreeSWITCH из RPM: `apt-get install -y freeswitch-daemon libfreeswitch freeswitch-lua`
  - Дополнительные пакеты: `freeswitch-av`, `freeswitch-imagick`
  - Языки: `freeswitch-lang-en`, `freeswitch-lang-ru`
  - Звуки: `freeswitch-sounds-en-us-callie-{8000,16000,32000}`, `freeswitch-sounds-ru-ru-elena-{8000,16000,32000}`, `freeswitch-sounds-music-{8000,16000,32000}`
  - Защита музыки on hold: удалить пакеты звуков музыки, файлы сохранены
  - Установка memcached
- `Alt/resources/switch/conf-copy.sh` — копирование FusionPBX-конфигов FreeSWITCH
- `Alt/resources/switch/package-permissions.sh`:
  - `chown -R _pbx:_pbx` для всех директорий FreeSWITCH
- `Alt/resources/switch/package-systemd.sh`:
  - Деплой кастомного systemd unit с `USER=_pbx`, `GROUP=_pbx`, `After=postgresql.service`
  - Сервис не запускается до finish.sh
- `Alt/resources/switch/dsn.sh` — настройка DSN для подключения к PostgreSQL
- `Alt/resources/switch/source/freeswitch.service.package` — systemd unit file
- `Alt/resources/switch/source/etc.default.freeswitch.package` — /etc/default/freeswitch

**Критерий приёмки**: FreeSWITCH установлен, systemd unit сконфигурирован,
DSN настроен, сервис готов к запуску через finish.sh.

---

### Инкремент 7: Фаервол (iptables)

**Цель**: Настройка фаервола на базе iptables.

**Файлы**:
- `Alt/resources/iptables.sh`:
  - Убрана вся логика `ufw` (нет в Alt Linux)
  - Убран `update-alternatives` (нет iptables-legacy/nftables разделения)
  - Убраны `debconf-set-selections` и `iptables-persistent` (Debian-specific)
  - Правила: SSH, HTTP/HTTPS, SIP, RTP, WebSocket, OpenVPN, ICMP
  - DSCP QoS-маркировка: RTP → EF (46), SIP → AF31 (26)
  - Анти-сканер: 7 паттернов (friendly-scanner, sipcli, VaxSIPUserAgent и др.)
  - **Сохранение правил**: `iptables-save > /etc/sysconfig/iptables`
  - **Сервис**: `systemctl enable --now iptables` — ТОЛЬКО ПОСЛЕ сохранения правил!
  - Порядок: применить правила → сохранить в файл → включить сервис

**Критерий приёмки**: Правила iptables применены, сохранены в /etc/sysconfig/iptables,
сервис iptables включён, правила загружаются после перезагрузки.

---

### Инкремент 8: Fail2ban

**Цель**: Настройка fail2ban для защиты FusionPBX.

**Файлы**:
- `Alt/resources/fail2ban.sh`:
  - `apt-get install -y fail2ban rsyslog`
  - Копирование фильтров из `fail2ban/` — без изменений (regex не зависят от ОС)
  - Перезапуск: `systemctl restart fail2ban`
- `Alt/resources/fail2ban/jail.local`:
  - Обновить действие: `iptables-allports` — работает с iptables, оставить
  - Проверить пути к логам: `/var/log/auth.log` — **уточнить у пользователя**: путь к логу SSH в Alt
  - `/var/log/freeswitch/freeswitch.log` — проверить корректность
  - `/var/log/nginx/access*.log` — проверить корректность
  - `/var/log/syslog` — **уточнить у пользователя**: есть ли syslog в Alt или другой путь?
- `Alt/resources/fail2ban/*.conf` — перенос фильтров без изменений

**Критерий приёмки**: fail2ban запущен, банит после неудачных попыток входа.

---

### Инкремент 9: Дополнительные сервисы (sngrep, memcached, snmpd, monit, backup)

**Цель**: Установка вспомогательных сервисов.

**Файлы**:
- `Alt/resources/sngrep.sh`:
  - Просто `apt-get install -y sngrep` (есть в репозитории)
- `Alt/resources/monit.sh`:
  - `apt-get install -y monit`
  - Копирование конфига — адаптировать путь к PID-файлу FreeSWITCH
- `Alt/resources/backup/fusionpbx-backup` — перенос из debian, адаптация путей
- `Alt/resources/backup/fusionpbx-maintenance` — перенос из debian
- Настройка SNMP:
  - `apt-get install -y snmpd`
  - Базовый конфиг: `rocommunity public`
  - Перезапуск сервиса

**Критерий приёмки**: sngrep, memcached, snmpd, monit установлены и работают.

---

### Инкремент 10: Finish (финализация установки)

**Цель**: Создание БД-схемы, пользователей, настройка сервисов.

**Файлы**:
- `Alt/resources/finish.sh`:
  - Генерация пароля БД
  - Обновление пароля PostgreSQL
  - Копирование `config.conf` с подстановкой значений
  - Выполнение `upgrade.php --schema`
  - Определение домена (IP-адрес или hostname)
  - Создание домена, пользователя, группы в БД
  - Настройка xml_cdr
  - Выполнение `upgrade.php --defaults` и `--permissions`
  - Установка cron: `apt-get install -y cron`
  - Настройка прав: `chown -R _nginx:_nginx /var/run/fusionpbx`
  - **Исправление бага #5**: создать `tmpfiles.d` конфиг для `/var/run/fusionpbx`
  - Перезапуск nginx + freeswitch
  - Вывод приветственного сообщения с учётными данными

**Критерий приёмки**: Установка полностью завершена, вход в веб-интерфейс
FusionPBX работает с указанными учётными данными.

---

### Инкремент 11: LetsEncrypt (опционально)

**Цель**: Настройка SSL-сертификатов от Let's Encrypt.

**Файлы**:
- `Alt/resources/letsencrypt.sh`:
  - Использование `dehydrated` (как в debian)
  - `apt-get install -y curl`
  - Логика работы с dehydrated переносима
  - Обновление конфига nginx
  - Настройка TLS для FreeSWITCH

**Критерий приёмки**: Let's Encrypt сертификат получен, nginx и FreeSWITCH
используют его для TLS.

---

### Инкремент 12: Оптимизация и рефакторинг

**Цель**: Применить исправления багов и оптимизации из анализа.

**Задачи**:
1. Устранить дублирование кода (php.sh, nginx.sh, ioncube.sh) — использовать
   переменные вместо повторяющихся if-блоков
2. Добавить обработку ошибок (`set -e` или функции проверки)
3. Исправить путь к `extension_dir` PHP — определять динамически через `php -i`
4. Убрать хардкод путей к PHP extension dir в ioncube.sh
5. Использовать `.pgpass` или `PGPASSWORD` для безопасной передачи паролей
6. Исправить `hostname -I` — всегда брать первый IP: `hostname -I | cut -d' ' -f1`
7. Добавить shebang `#!/bin/sh` во все скрипты
8. Использовать `SCRIPT_DIR` вместо `cd "$(dirname "$0")"`
9. Обновить TLS-настройки nginx (убрать TLSv1, TLSv1.1)
10. Добавить проверки: установлен ли пакет перед его настройкой

**Критерий приёмки**: Код чистый, без дублирования, с обработкой ошибок.

---

## Открытые вопросы (уточнять у пользователя по мере необходимости)

| # | Вопрос | Статус | Ответ |
|---|--------|--------|-------|
| 1 | Точные имена базовых пакетов | **Решён** | Имена совпадают с Debian (wget, nano, git и т.д.), gpg доступен без отдельного пакета |
| 2 | Имя systemd-сервиса для PHP-FPM | **Решён** | `php8.2-fpm.service` |
| 3 | Путь к `php.ini` и `conf.d` для PHP-FPM | **Решён** | `/etc/php/8.2/fpm-fcgi/php.ini`, нет `conf.d` (добавляем в php.ini напрямую) |
| 4 | Путь к PHP `extension_dir` | **Решён** | `/usr/lib64/php/8.x.x/extensions` (определяется динамически через `php -i`) |
| 5 | Есть ли пакет `ssl-cert` | **Решён** | Нет, генерируем self-signed сертификат через openssl |
| 6 | Версия PostgreSQL и имя пакета | **Решён** | `postgresql16-server` (PostgreSQL 16) |
| 7 | Как инициализировать кластер PG | **Решён** | `/etc/rc.d/init.d/postgresql initdb` (systemctl не работает!) |
| 8 | Путь к `pg_hba.conf` и данным PG | **Решён** | `/var/lib/pgsql/16/data/pg_hba.conf` |
| 9 | Имена пакетов `libtiff-tools`, `qrencode`, `dbus`, `ssl-cert` в Alt | **Решён** | Не все доступны — скрипты используют fallback с предупреждением при отсутствии |
| 10 | Полный список freeswitch-* пакетов в Alt Linux | **Решён** | freeswitch-daemon (ядро+модули), freeswitch-lua, freeswitch-av, freeswitch-imagick, freeswitch-lang-*, freeswitch-sounds-* (en,ru,music), libfreeswitch, freeswitch-webui. Нет отдельных freeswitch-mod-* пакетов! |
| 11 | От какого пользователя работает FreeSWITCH в RPM-пакете? | **Решён** | `_pbx:_pbx` (Alt Linux default) |
| 12 | Имена dev-пакетов для сборки FreeSWITCH из исходников | **Решён** | Не требуется — только RPM пакеты |
| 13 | Как сохранять правила iptables при перезагрузке в Alt Linux | **Решён** | `iptables-save > /etc/sysconfig/iptables` (автозагрузка при старте). Сервис `iptables.service` — `systemctl enable --now iptables` ПОСЛЕ сохранения правил (иначе ошибка при пустом файле) |
| 14 | Путь к логу SSH в Alt Linux | **Решён** | `/var/log/auth/secure` (аналог `/var/log/auth.log` в Debian) |
| 15 | Путь к syslog в Alt Linux | **Решён** | `/var/log/syslog/messages` (аналог `/var/log/syslog` в Debian). Также Alt Linux использует systemd-journald по умолчанию — rsyslog нужен для файловых логов |

---

## Порядок работы

1. Реализовывать инкременты последовательно: 0 → 1 → 2 → ... → 12
2. Перед каждым инкрементом — задавать уточняющие вопросы пользователю
3. После каждого инкремента — тестировать на Alt Linux
4. Каждый инкремент — отдельный коммит в ветку `alt`
5. Результат каждого инкремента — рабочий, тестируемый код
