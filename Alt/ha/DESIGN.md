# Дизайн-документ: `fusionpbx-ha.sh`

| | |
|---|---|
| **Версия** | 0.3.6 (реализация начата — см. §18) |
| **Дата** | 2026-10-15 |
| **Дом** | `Alt/ha/` репозитория `fusionpbx-install.sh`, ветка `alt` |
| **Статус** | Реализация v1 + hotfix 0.3.6 (`fusionpbx-ha.sh` + `resources/` + `tests/`). Стендовая проверка на 3×ALT — в процессе (§15.3): дошли до шага 11 (ожидание witness). |
| **Язык сообщений скрипта** | Английский (как в установщике слоя 1) |

---

## 1. Резюме

`fusionpbx-ha.sh` — надстройка (слой 2) над существующим установщиком
FusionPBX для ALT Linux (слой 1, каталог `Alt/`). Она превращает три
подготовленные виртуальные машины в HA-кластер АТС:

- **VM1, VM2** (data-ноды): FusionPBX (Angie + php-fpm + FreeSWITCH) +
  PostgreSQL + `repmgrd` + `haproxy` + `lsyncd`;
- **VM3** (witness): крошечный PostgreSQL только с метаданными repmgr +
  `repmgrd`. Никакого FusionPBX.

Ключевые свойства решения:

1. **Слой 1 не изменяется.** Установщик по-прежнему ставит одиночную ноду и
   запускается на VM1 и VM2 независимо. Локальная база VM2 при кластеризации
   затирается клоном с VM1 — это осознанно принятое следствие.
2. **Всё из штатных репозиториев ALT** p10/p11: `postgresql16-repmgr`,
   `haproxy`, `lsyncd` (Patroni в ALT отсутствует — см. §2).
3. **Ноль установочного SSH между нодами.** Установочные части скрипта
   координируются через сам кластерный софт: каждая команда просто ждёт
   (poll) появления своего предусловия. SSH используется только рантаймом —
   выделенным ключом для rsync медиа-файлов между data-нодами.
4. **Идемпотентность и resume** — паттерны установщика слоя 1 (маркер
   установленности + файл состояния шагов) переносятся один в один.
5. **Ремонт — штатный режим**: пересобранная нода вводится повторным
   запуском `--join`/`--repair`, без полного пересборка кластера.
6. **Работа за HTTP(S)-прокси** — тем же флагом `--proxy host:port`, что и
   у слоя 1: исходящий интернет (пакеты, обновление скриптов) идёт через
   корпоративный прокси, межнодовый трафик — напрямую (§5.1).

Топология «2+1» и отказные сценарии согласованы ранее; документ фиксирует
их как проектные требования и раскладывает на реализуемые шаги.

## 2. Принципы и границы

### 2.1 Принципы

| # | Принцип | Следствие для реализации |
|---|---------|--------------------------|
| P1 | Слоистость | Установщик слоя 1 — чёрный ящик: только запускается целиком, не парсится и не source'ится |
| P2 | Репозитарная чистота | Только пакеты из ALT p10/p11; проверено по листингам зеркала (см. §13) |
| P3 | Самокоординация | Каждая команда ждёт своё предусловие опросом локально доступного состояния (repmgr-метаданные, `pg_stat_replication`); никакого «дирижёра» |
| P4 | Идемпотентность | Повторный запуск любой команды безопасен; деструктивное — только в `--repair`/затирании PGDATA VM2 с явным подтверждением |
| P5 | Единая точка записи | Оба FusionPBX ходят в БД только через `127.0.0.1:5433` (haproxy → текущая primary). Прямая запись в локальную PG запрещена конструктивно |
| P6 | Синхронная репликация | `synchronous_commit` + `synchronous_standby_names` — главный предохранитель от записи в обе стороны при сетевом разделе |

### 2.2 Границы (что НЕ делает скрипт)

- не устанавливает FusionPBX (слой 1), не управляет виртуальными машинами
  Proxmox и их размещением (проектное правило: VM1/VM2/VM3 — на трёх разных
  хостах, PVE-HA для этих VM не включается);
- не является системой бэкапа (PBS/vzdump + `pg_dump` обязательны поверх);
- не решает «двойной отказ» — при потере двух нод из трёх кластер
  осознанно замораживает запись (защита от split-brain важнее
  доступности); процедура вывода из заморозки — §12.4;
- VIP для SIP/web — опциональный модуль будущего расширения (§17);
  в v1 голосовой ярус active-active (телефоны знают оба сервера).

### 2.3 Почему repmgr, а не Patroni

Проверка по листингам репозиториев ALT (первоисточник, зеркало
mirror.yandex.ru; `packages.altlinux.org` в момент проверки был закрыт
anti-bot-заглушкой и для проверок непригоден):

| Пакет | p10 | p11 | Вывод |
|---|---|---|---|
| `postgresql16-repmgr` | 5.4.1-alt4 | 5.5.0-alt5 | **используем** |
| `haproxy` | 2.8.28 | 3.4.4 | используется |
| `lsyncd` | 2.1.4 | 2.3.1 | используется |
| `python3-module-psycopg2` | 2.9.1 | 2.9.5 | role-agent (§9.2) |
| `etcd` | 3.5.23 | 3.5.32 | не нужен при repmgr |
| `patroni` | нет | нет | **отвергнут** |
| `osync`, `pg_auto_failover` | нет | нет | отвергнуты |

repmgr: (а) есть в репозиториях и привязан к мажору PG (`postgresql16-*` —
наш слой 1 ставит PG16); (б) witness — родная концепция repmgr, ровно наша
схема 2+1; (в) `repmgr primary register` принимает существующий инстанс —
база, созданная слоем 1 на VM1, становится базой кластера без
dump/restore. Patroni остаётся запасным планом через pip (вне репозиториев),
к нему возвращаемся только если репозитарный repmgr упрётся в фундаментальное
ограничение.

## 3. Архитектура

### 3.1 Схема

```
                 телефоны / транки / SBC
                    |              |
              (secondary)      (primary registrar)
                    |              |
        +-----------+--------------+-----------+
        |                active-active         |   голос + веб
        |                                      |
   [ VM1: fpbx-ha-1 ]                [ VM2: fpbx-ha-2 ]
   Angie+php-fpm+FreeSWITCH          Angie+php-fpm+FreeSWITCH
   haproxy :5433(localhost)          haproxy :5433(localhost)
   role-agent :8008                  role-agent :8008
   repmgrd                           repmgrd (failover=automatic)
   PG primary <---- sync repl -----  PG standby
        |                                      |
        +--------------- rsync (SSH, ----------
            lsyncd: только /var/lib/freeswitch/storage
                         |
                  [ VM3: fpbx-witness ]
                  PG (только метаданные repmgr)
                  repmgrd (третий голос)
```

### 3.2 Роли и состав ПО

| Компонент | VM1 | VM2 | VM3 |
|---|---|---|---|
| Слой 1 (FusionPBX standalone) | да | да | **нет** |
| PostgreSQL 16 | primary | standby (sync) | крошечный, метаданные repmgr |
| `repmgrd` (юнит `repmgr.service`) | да (наблюдатель) | да (failover=automatic) | да (наблюдатель) |
| `haproxy` (frontend `127.0.0.1:5433`) | да | да | нет |
| role-agent (`:8008`, §9.2) | да | да | нет |
| `lsyncd` (медиа-дерево → сосед) | да | да | нет |

### 3.3 Порты

| Порт | Кто и зачем | Разрешённые направления |
|---|---|---|
| 5432/tcp | PG: репликация VM1↔VM2, метаданные repmgr со всех нод, проверки haproxy/агента | VM1↔VM2, VM3→VM1, VM1/VM2→VM3 |
| 5433/tcp | haproxy frontend (точка входа приложений) | только 127.0.0.1 на VM1/VM2 |
| 8008/tcp | role-agent: haproxy соседа проверяет «кто primary» | VM1↔VM2 + 127.0.0.1 |
| 22/tcp | rsync медиа-дерева (lsyncd/seed) | только VM1↔VM2, только выделенный ключ (§14.2) |

### 3.4 Траектория SQL-запроса

```
FusionPBX / FreeSWITCH (VMx)
   → 127.0.0.1:5433 (haproxy, mode tcp)
      → health: GET /primary на role-agent :8008 обеих data-нод
      → бэкенд, вернувший 200 (текущая primary)
```

## 4. Предусловия

### 4.1 Обязательные

1. Три VM на **трёх разных хостах Proxmox**; PVE-HA для этих VM выключен
   (placement — руками, см. §2.2).
2. Статические IP; разрешение имён — через `/etc/hosts` на всех трёх нодах
   (скрипт вносит записи сам по данным cluster.conf).
3. Синхронизация времени (NTP/chrony) на всех нодах — `--doctor` проверяет.
4. VM1 и VM2: слой 1 отработал полностью (валидный `/etc/fusionpbx/config.conf`,
   живая локальная БД `fusionpbx`, FreeSWITCH запущен). Вся настройка АТС
   (домены, пользователи, расширения) делается на VM1 до `--init` — база VM2
   будет затёрта.
5. Один и тот же мажор PostgreSQL на всех нодах (слой 1 ставит PG16;
   `--init` фиксирует мажор в cluster.conf, `--join` сверяет).
6. Свободные порты 5433 и 8008 на VM1/VM2; 5432 свободен на VM3.
7. Исходящий интернет может отсутствовать — допускается работа только через
   корпоративный HTTP(S)-прокси, как у слоя 1: флаг `--proxy` (§5.1).
   Межнодовый трафик (репликация, метаданные, rsync, haproxy-проверки) идёт
   напрямую и в прокси не заворачивается.

### 4.2 Рекомендуемые

- отдельный маленький диск/LV под WAL не обязателен: нагрузка АТС
  (CDR-записи) далека от WAL-интерсива;
- witness: 1 vCPU, 512MB–1GB RAM, ≥10GB диска.

## 5. CLI-спецификация

```
fusionpbx-ha.sh --init [--node2 IP] [--node3 IP] [--cluster-name NAME] [--yes]
fusionpbx-ha.sh --join TOKEN            # TOKEN — base64-строка, или @файл
fusionpbx-ha.sh --config FILE ...       # альтернатива токену: файл cluster.conf
fusionpbx-ha.sh --repair [--yes] [--force-clone]
fusionpbx-ha.sh --status
fusionpbx-ha.sh --doctor
fusionpbx-ha.sh --print-token           # повторно показать токен (только VM1)

Общие флаги:
  --yes        неинтерактивный режим (ansible-совместимость; все подтверждения — да)
  --force      переконфигурировать поверх установленного состояния
  --no-color   без ANSI-цветов
  --verbose    подробный вывод (как в установщике слоя 1)
  --proxy H:P  исходящий интернет — через HTTP(S)-прокси; тот же флаг и та же
               семантика, что у install.sh слоя 1 (подробнее §5.1)
```

Семантика по командам:

| Команда | Нода | Назначение |
|---|---|---|
| `--init` | VM1 | Принять существующий standalone-FusionPBX как primary: repmgr-регистрация, haproxy, агент, репойнт DSN, печать токена, ожидание witness+standby, включение sync-режима |
| `--join` | VM2, VM3 | Вступить в кластер по токену: роль определяется сопоставлением собственного IP со списком нод в токене |
| `--repair` | любая | Вернуть пересобранную/упавшую ноду в кластер (§12). Работает по локальному `/etc/fusionpbx-ha/cluster.conf`, токен не нужен |
| `--status` | любая | Только чтение: роль, repmgr-кластер, haproxy, лаг, sync-режим, lsyncd, сервисы |
| `--doctor` | любая | Глубокая диагностика: NTP, pg_hba, порты, агент, ошибки lsyncd, WAL, права каталогов |

Правила конфликтов: `--join` на ноде с маркером установленности → отказ с
подсказкой `--repair`; `--repair` без маркера → отказ с подсказкой `--join`;
`--init` на не-VM1 (нет слоя 1) → отказ.

### 5.1 Работа за HTTP(S)-прокси (`--proxy`)

Семантика — как у слоя 1 (`install.sh --proxy host:port`): исходящего
интернета напрямую может не быть, весь трафик к репозиториям идёт через
корпоративный прокси. Применим к любой команде HA-скрипта.

**Механизм — переиспользование `Alt/resources/proxy.sh` слоя 1** (не копия,
а тот же файл — поведение гарантированно идентично, включая запись
персистентных конфигураций APT/git/wget/curl):

```sh
# fusionpbx-ha.sh, после парсинга аргументов (verbose/warn/cmd_exists уже
# определены — паттерны слоя 1 переносились, §7):
if [ -n "$PROXY_SERVER" ]; then
    . "$SCRIPT_DIR/../resources/proxy.sh"
fi
# Как только известны адреса нод (у --init — из аргументов, у --join/--repair/
# --status — из cluster.conf), до первого curl:
export no_proxy="${no_proxy:+${no_proxy},}$HA_NODE1_IP,$HA_NODE2_IP,$HA_NODE3_IP,$HA_NODE1_NAME,$HA_NODE2_NAME,$HA_NODE3_NAME"
export NO_PROXY="$no_proxy"
```

`proxy.sh` настраивает env-переменные (http_proxy/https_proxy, оба
регистра), APT (`/etc/apt/apt.conf` + `apt.conf.d/99proxy`), git
(`http.proxy`, `sslVerify=false` для корпоративных MITM-прокси),
`/etc/wgetrc`, `/root/.curlrc` и проверку связности (best-effort).
Настройки APT и git персистентны: повторный `--proxy` на той же ноде не
обязателен (но безвреден — конфигурация идемпотентна). Если
`../resources/proxy.sh` отсутствует (скрипт скопирован без репо) — warning
и минимальный fallback только на env-переменные.

**Разграничение трафика:**

| Трафик HA-слоя | Через прокси |
|---|---|
| `apt-get install` (шаги `packages`; на VM3 — единственный потребитель исходящего трафика) | да |
| `git clone/pull` репозиториев (обновление скриптов) | да |
| Репликация PG (5432), метаданные repmgr, `standby clone` | нет — прямой TCP, http-прокси неприменим |
| rsync/lsyncd (SSH 22, выделенный sync-ключ) | нет |
| haproxy → role-agent (8008), haproxy → PG (5432) | нет — собственные TCP-соединения haproxy |
| curl-проверки `--status`/`--doctor` к role-agent | **никогда** |

Последняя строка — обязательное правило, а не перестраховка: `proxy.sh`
пишет `--proxy` в `/root/.curlrc`, и любой curl без `--noproxy` уйдёт в
корпоративный прокси, для которого `10.0.0.x:8008` — чужой адрес.
Поэтому **все внутренние HTTP-обращения HA-скрипта** (проверки role-agent,
smoke-тест UI) выполняются только как `curl --noproxy '*'`. Кластерные
демоны (repmgrd, haproxy, lsyncd, postgresql) http-прокси не используют
конструктивно — утечка `http_proxy` в их окружение безопасна.

Прокси — аргумент запуска, а не состояние кластера: в cluster.conf не
пишется и по токену не распространяется.

## 6. Конфигурация и токен

### 6.1 `cluster.conf`

Shell-sourceable INI (стиль слоя 1), живёт в `/etc/fusionpbx-ha/cluster.conf`
(режим 600, владелец root). Генерируется на `--init`, копируется токеном.

```sh
# /etc/fusionpbx-ha/cluster.conf — генерируется fusionpbx-ha.sh --init
HA_CLUSTER_NAME="fpbx-ha"
HA_NODE1_NAME="fpbx-ha-1"; HA_NODE1_IP="10.0.0.11"; HA_NODE1_ROLE="primary"
HA_NODE2_NAME="fpbx-ha-2"; HA_NODE2_IP="10.0.0.12"; HA_NODE2_ROLE="standby"
HA_NODE3_NAME="fpbx-witness"; HA_NODE3_IP="10.0.0.13"; HA_NODE3_ROLE="witness"

HA_PG_VERSION="16"                  # зафиксирован при --init (мажор слоя 1)
HA_PG_PORT="5432"
HA_DB_NAME="fusionpbx"              # читается из config.conf слоя 1
HA_DB_USER="fusionpbx"
HA_DB_PASSWORD="..."                # из config.conf слоя 1 (уже существует)
HA_REPMGR_USER="repmgr"
HA_REPMGR_PASSWORD="..."            # генерируется (A-Za-z0-9, 24 симв.)
HA_REPMGR_DB="repmgr"
HA_HAPROXY_PORT="5433"
HA_AGENT_PORT="8008"
HA_SYNC_DIR="/var/lib/freeswitch/storage"
HA_SYNC_DELAY="5"                   # секунды; write-once файлы — можно коротко
HA_SYNC_PRIVATE_KEY_B64="..."       # base64 PEM приватного ключа sync-ключа
HA_SYNC_PUBLIC_KEY="ssh-ed25519 AAAA... fusionpbx-ha-sync"
```

Пароли — только `[A-Za-z0-9]` (то же правило, что в слое 1: пароль попадает в
INI/SQL/`.pgpass` без квотирования). Приватный ключ хранится одной строкой
base64, чтобы файл оставался source-able.

### 6.2 Токен

```
TOKEN = base64( gzip( cluster.conf ) )     # одна печатная строка
```

- печатается командой `--init` сразу после генерации cluster.conf (не ждёт
  завершения установки) и повторно — `--print-token`;
- принимается `--join TOKEN` или `--join @файл` (для ansible);
  `--config FILE` — прямой путь к файлу, минуя токен;
- **содержит секреты** (пароль БД, пароль repmgr, приватный sync-ключ):
  обращаться как с root-паролем; после ввода строка из истории shell
  вычищается подсказкой (`history -d` не делаем — просто предупреждение).

### 6.3 Sync-ключ (SSH для rsync)

- при `--init` генерируется выделенная пара ed25519
  (`/etc/fusionpbx-ha/sync_key`, 600); **одна пара на кластер** — она едет
  в токене и кладётся на обе data-ноды (двунаправленный rsync одной парой);
- `authorized_keys` (root) на обеих data-нодах:

```
from="10.0.0.11,10.0.0.12",command="/usr/bin/rrsync /var/lib/freeswitch/storage",\
no-pty,no-agent-forwarding,no-X11-forwarding,no-port-forwarding \
ssh-ed25519 AAAA... fusionpbx-ha-sync
```

- если `rrsync` в составе rsmgr-независимого пакета rsync в ALT не найден
  (проверить путь — §16), деградация: `from=` без `command=` (ограничение
  только по IP; допустимо, т.к. ключ всё равно единственного назначения);
- known_hosts: первое подключение с `StrictHostKeyChecking=accept-new`
  (TOFU в пределах management-сети; отпечатки равны доверию к токену).

## 7. Состояния, идемпотентность, resume

Маркеры — прямое повторение паттернов `guard.sh` слоя 1:

| Файл | Значение |
|---|---|
| `/etc/fusionpbx-ha/.installed` | ставится **только** после полного успеха команды |
| `/etc/fusionpbx-ha/.installer-state` | последний завершённый шаг (номер) текущей команды |
| `/etc/fusionpbx-ha/cluster.conf` | конфигурация кластера (persist; нужна `--repair`) |

Правила:

- каждая команда = список шагов `ha_step<N>_<name>`; завершённый шаг
  дописывается в `.installer-state`; повторный запуск продолжает с места
  обрыва;
- каждый шаг обязан быть идемпотентным сам по себе (существующее
  состояние ≠ ошибка): пакет уже стоит — ок; юзер создан — ок; конфиг
  совпадает — ок;
- точка ожидания (WAIT) — тоже шаг: он опрашивает предусловие с таймаутом;
  при таймауте команда завершается ненулевым кодом с инструкцией
  «повторите ту же команду — продолжит с этого шага»;
- `--force` игнорирует `.installer-state` (полный проход поверх), но никогда
  не трогает данные PG и медиа-дерево без `--repair`;
- сообщения об ошибках обязаны содержать: что проверяли, что нашли, каким
  шагом исправлять (стиль слоя 1).

## 8. Последовательности шагов

Формат: `шаг [WAIT: предусловие]`. Точки WAIT — механизм самокоординации
(P3): ноды не дёргают друг друга, каждая ждёт своей очереди по состоянию,
которое видит локально.

Все исходящие интернет-шаги (`packages`, `git`) при заданном `--proxy` идут
через корпоративный прокси (§5.1); проверки внутренних предусловий
(`VM1:5432 достижим` и т.п.) выполняются всегда напрямую.

### 8.1 `--init` (VM1, primary)

| # | Шаг | Детали |
|---|-----|--------|
| 1 | preflight | root; ALT; слой 1 установлен (`config.conf` валиден, psql SELECT по кредам БД `fusionpbx` проходит); PG16; `--node2/--node3` заданы и пингуются (мягкая проверка); 5433/8008 свободны |
| 2 | config-gen | читает креды БД из `/etc/fusionpbx/config.conf`; генерирует пароль repmgr + sync-ключ; пишет cluster.conf (600); **печатает токен и подсказку «введите его на VM2 и VM3»** |
| 3 | packages | `postgresql16-repmgr`, `haproxy`, `lsyncd` |
| 4 | pg-prep | `CREATE ROLE repmgr REPLICATION LOGIN PASSWORD ...`; `CREATE DATABASE repmgr OWNER repmgr`; `CREATE EXTENSION repmgr`; **гранты схемы расширения роли repmgr** (`ha_fix_repmgr_schema_access` — расширение ставит postgres-суперпользователь, поэтому без передачи владения/грантов роль не имеет даже `USAGE` на схему, 0.3.3; SQL подаётся psql через stdin — приватный per-user `/tmp` root на ALT недоступен пользователю postgres, 0.3.4); pg_hba: записи для VM2/VM3 (метаданные, репликация, БД fusionpbx с обеих data-нод — точный список §14.3); smoke: чтение `repmgr.nodes` от роли repmgr по TCP; `.pgpass` для postgres; reload |
| 5 | wal-log-hints + listen | `ALTER SYSTEM SET wal_log_hints = on` (нужен для `pg_rewind` при ремонте бывшей primary; наследуется клоном VM2) **и** `ALTER SYSTEM SET listen_addresses = '*'` (слой 1 оставляет PG только на localhost, а repmgr/haproxy-пир/witness ходят на IP ноды) — **один** общий рестарт `postgresql.service`; шаг 7 повторяет проверку идемпотентно (resume со старых версий) |
| 6 | repmgr-conf | `/etc/repmgr/repmgr.conf` ноды 1 (§13.3) |
| 7 | primary-register | самовосстанавливающая прелюдия (гранты схемы repmgr, перезапись pg_hba-блока, listen_addresses, перерендер repmgr.conf при отличии от шаблона, sudoers — для resume с state-файла старой версии) → `repmgr primary register` (+`--force` при повторах) |
| 8 | agent | role-agent: скрипт + systemd-юнит (§9.2), enable+start; ожидание сокета до HA_AGENT_WAIT=30с с опросом раз в 1с (Type=simple — сокет появляется спустя секунды после «старта», 0.3.5) |
| 9 | haproxy | конфиг (§9.1), enable+start |
| 10 | repoint-DSN | `config.conf` → `127.0.0.1:5433`; DSN FreeSWITCH (`vars.xml`/настройки из БД) → `127.0.0.1:5433`; перезапуск angie, php-fpm, freeswitch; smoke-тест: логин в UI проходит через 5433 |
| 11 | **WAIT witness** | опрос `repmgr cluster show`/таблицы `repmgr.nodes` до появления ноды 3 (таймаут 15 мин) |
| 12 | **WAIT standby** | опрос `pg_stat_replication` до `application_name = fpbx-ha-2` в состоянии streaming (таймаут 15 мин) |
| 13 | sync-on | `ALTER SYSTEM SET synchronous_standby_names = 'fpbx-ha-2'`; reload; проверка `pg_stat_replication.sync_state = sync` |
| 14 | lsyncd-start | конфиг VM1 (§10), enable+start (медиа-дерево VM1 — эталон) |
| 15 | finalize | маркер `.installed`; итоговая сводка: `repmgr cluster show`, роли, токен ещё раз |

Шаги 11–12 — точка «оператор идёт вводить токен на VM2/VM3»: VM1 стоит на
WAIT и продолжится сама, как только сосед зарегистрируется. Если оператор не
успел — ненулевой выход с подсказкой перезапустить команду (resume с шага 11).

### 8.2 `--join` (VM2, standby)

| # | Шаг | Детали |
|---|-----|--------|
| 1 | preflight | root; ALT; слой 1 установлен; **мажор PG = HA_PG_VERSION**; токен распакован; собственный IP найден среди нод → роль `standby`; маркер отсутствует (иначе → `--repair`); VM1:5432 достижим |
| 2 | unpack | cluster.conf (600) + приватный sync-ключ (600); authorized_keys с ограничениями (§6.3); `/etc/hosts` — записи всех нод; **repmgr.conf (standby) + promote.sh + sudoers — до клона: `repmgr standby clone` читает конфиг** |
| 3 | packages | `postgresql16-repmgr`, `haproxy`, `lsyncd` |
| 4 | stop-local-pg | стоп `postgresql.service`; **громкое предупреждение: локальная БД fusionpbx будет заменена клоном с VM1** (интерактивное подтверждение / `--yes`) |
| 5 | clone | `rm -rf /var/lib/pgsql/data/*` → `repmgr standby clone -h VM1 ...` (pg_basebackup; **WAIT: VM1 зарегистрирована как primary**, таймаут 10 мин) |
| 6 | start+register | старт `postgresql.service` (поднимется в recovery) → идемпотентная прелюдия (pg_hba/listen/re-render; гранты схемы на standby — no-op: метаданная БД — стриминговая копия primary) → `repmgr standby register --upstream-node-id=1`; в conninfo — `application_name=fpbx-ha-2` (для `synchronous_standby_names` с VM1, §16-в2) |
| 7 | agent + haproxy | те же конфиги, что на VM1 (идентичны на всех data-нодах) |
| 8 | repoint-DSN | как шаг 10 у `--init`; перезапуск сервисов; smoke-тест |
| 9 | seed-media | rsync **от VM1 к себе** (pull): `rsync -a --delete -e "ssh -i sync_key" VM1:$HA_SYNC_DIR/ $HA_SYNC_DIR/` — локальная копия становится зеркальной до первого старта lsyncd (§10.2, ловушка `--delete`) |
| 10 | lsyncd-start | конфиг VM2 (push → VM1, `delete=true`), enable+start |
| 11 | finalize | маркер; сводка (`repmgr cluster show` уже видит 2/3) |

### 8.3 `--join` (VM3, witness)

| # | Шаг | Детали |
|---|-----|--------|
| 1 | preflight | root; ALT; **слой 1 НЕ требуется**; мажор PG совпадает; VM1:5432 достижим; маркер отсутствует |
| 2 | unpack | cluster.conf (600), `/etc/hosts` |
| 3 | packages | `postgresql16-repmgr` + `postgresql16-server` (без haproxy/lsyncd) |
| 4 | initdb-tiny | отдельный кластер PG **только под метаданные**: `initdb --data-checksums`, старт; локальные `repmgr`-юзер/база; pg_hba: `repmgr` с VM1 и VM2 (standby читает метаданные witness при консенсусе failover — §11.3) |
| 5 | repmgr-conf | `/etc/repmgr/repmgr.conf` ноды 3, `failover='manual'` (witness никогда не промоутится) |
| 6 | witness-register | **WAIT: VM1 primary жива** → `repmgr witness register -h VM1` |
| 7 | repmgrd | enable+start `repmgr.service` |
| 8 | finalize | маркер; сводка |

### 8.4 `--repair` (любая нода)

Входное условие: `/etc/fusionpbx-ha/cluster.conf` присутствует локально
(токен не нужен). Роль — из cluster.conf по IP.

| Нода | Последовательность |
|------|--------------------|
| data (VM1 или VM2) | стоп lsyncd → стоп repmgrd → стоп PG → **ветка A** (PGDATA цела, нода была primary): `repmgr node rejoin --force-rewind` (pg_rewind; wal_log_hints включён шагом 5 у `--init`) → standby; **ветка B** (PGDATA мусор/с нуля, флаг `--force-clone` или диагностика): wipe → `repmgr standby clone` → register `--force`; далее: agent+haproxy идемпотентно, **seed-media (pull, §10.2) до старта lsyncd**, lsyncd start, маркер |
| witness (VM3) | initdb-tiny идемпотентно → `repmgr witness register --force` → repmgrd |

Особый случай — ремонт бывшей primary при живой новой primary: ветка A
равно применима (`rejoin --force-rewind` вернёт её standby'ем).

### 8.5 `--status` / `--doctor`

Только чтение, без состояний/маркеров. `--status` — компактная сводка;
`--doctor` — полный чек-лист с кодом выхода (для мониторинга):

- нода: роль (repmgr), IP, время, NTP-синхронизация;
- кластер: `repmgr cluster show` (все ноды видны?), события последних 24ч;
- репликация: streaming? лаг байт/секунд, `sync_state` (sync/async);
- точка входа: `127.0.0.1:5433` коннектится и ведёт **к primary**;
- role-agent обоих бэкендов: код ответа (curl с `--noproxy '*'`, §5.1);
- lsyncd: сервис жив, ошибок в логе нет, последняя синхронизация;
- носители: место на дисках, права на `$HA_SYNC_DIR`;
- pg_hba: ожидаемые записи присутствуют.

## 9. Роутинг к primary: haproxy + role-agent

### 9.1 haproxy (конфиг идентичен на VM1 и VM2)

```
listen postgres_primary
    bind 127.0.0.1:5433
    mode tcp
    option httpchk
    http-check send meth GET uri /primary
    default-server inter 3s fall 2 rise 1 check port 8008
    server fpbx-ha-1 10.0.0.11:5432 check
    server fpbx-ha-2 10.0.0.12:5432 check
```

Проверка — HTTP `GET /primary` на агенте (порт 8008) каждой data-ноды;
бэкенд попадает в ротацию только если его локальная PG — primary.
failover: агент новой primary отвечает 200, старой — 503 → оба haproxy
переключаются за `inter×fall` ≈ 6–9 c.

### 9.2 role-agent (python3 + psycopg2, ~40 строк)

```python
# /usr/lib/fusionpbx-ha/role-agent.py (референс)
# 200 = локальная PG является primary, 503 = standby/недоступна
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        code = 503
        if self.path == "/primary":
            try:
                c = psycopg2.connect(host="127.0.0.1", port=5432,
                                     dbname=CONF.db_name, user=CONF.db_user,
                                     password=CONF.db_password, connect_timeout=3)
                cur = c.cursor(); cur.execute("SELECT pg_is_in_recovery()")
                code = 503 if cur.fetchone()[0] else 200
                c.close()
            except Exception:
                code = 503
        self.send_response(code); self.end_headers()
```

systemd-юнит `fusionpbx-ha-agent.service`: простой однопоточный
`http.server` на `0.0.0.0:8008` (нужен соседскому haproxy), креды — из
`/etc/fusionpbx-ha/cluster.conf` (парсится тем же скриптом). Отдельный
малый сервис вместо таймаутных pgsql-проверок в haproxy: отличает
primary/standby за один HTTP-запрос и не зависит от PG-аутентификации
сессий haproxy.

## 10. Синхронизация медиа-файлов

### 10.1 Периметр

Синхронизируется **только** `/var/lib/freeswitch/storage` (записи
разговоров, voicemail, факсы). Имена файлов содержат UUID вызова →
write-once, без коллизий; каждая запись рождается ровно на одной ноде →
встречные потоки не конфликтуют.

**Не синхронизируются**: `/etc/freeswitch` (конфиг генерируется из БД),
`/var/www/fusionpbx` (меняется только апгрейдом — там свой порядок, §17),
логи, `/run`.

### 10.2 Конфигурация lsyncd (VM2; на VM1 — зеркально)

```lua
settings { logfile = "/var/log/lsyncd/lsyncd.log",
           statusFile = "/var/log/lsyncd/lsyncd.status",
           statusInterval = 20, inotifyMode = "CloseWrite" }
sync { default.rsync,
       source = "/var/lib/freeswitch/storage",
       target = "root@10.0.0.11:/var/lib/freeswitch/storage",
       delay = 5, maxProcesses = 1,
       rsync = { archive = true, compress = true, _extra = { "--delete" },
                 rsh = "ssh -i /etc/fusionpbx-ha/sync_key -o StrictHostKeyChecking=accept-new" } }
```

Две ловушки закрываются процедурно:

1. **Seed-before-sync** (ловушка `--delete`): rsync с `--delete` от пустой
   (пересобранной) ноды сотрёт копию соседа. Поэтому в `--join`/`--repair`
   медиа-дерево сначала **вытягивается** с соседа (pull с `--delete` —
   удаления на этом шаге затрагивают только локальные устаревшие файлы, это
   безопасно), и лишь затем стартует lsyncd.
2. **Распространение удалений из UI**: оператор удалил запись на той ноде,
   что обработала запрос; `--delete` в обе стороны доводит удаление до
   соседа. Единственный опасный порядок — старт с пустого локального
   дерева, закрыт п.1.

## 11. Отказные сценарии, RTO/RPO

### 11.1 Матрица

| Событие | Что происходит | RTO |
|---|---|---|
| Падение VM2 (standby) | Сервис не прерывается: VM1 продолжает обслуживать. Авто-восстановления нет — ремонт VM2 по §8.4. Запись переходит в async: `--repair` на пережившей primary снимает `synchronous_standby_names` (см. «ensure-sync», §18-0.3) | 0 (голос/веб); записи новых звонков — async до возврата standby |
| Падение VM1 (primary) | repmgrd VM2 + witness фиксируют недоступность primary (консенсус) → promote VM2; агенты переключают haproxy; звонки на VM1 рвутся, телефоны перерегистрируются на VM2 | ≈ 30–45 c: детект (monitor_interval_secs 5 c × reconnect 3×5 c) + promote (~5 c) + haproxy (6–9 c) |
| Сетевой раздел VM1 \| VM2 (VM3 достижима обеими) | witness достижим только с одной стороны → консенсус возможен только там; на изолированной стороне: **sync-репликация блокирует коммиты** (нет sync-standby) — расщепление записи исключено | недоступность части клиентов до склейки |
| Падение VM3 (witness) | Кластер полностью работоспособен; авто-failover невозможен (нет третьего голоса) — деградация до ремонта | 0; ремонт — `--repair` на VM3 |
| Двойной отказ | Запись замораживается по дизайну (см. §12.4) | до ремонта |

### 11.2 RPO

Синхронный коммит: подтверждённые транзакции есть на обеих копиях →
**RPO = 0** для закоммиченных данных. Незакоммиченные на момент отказа
транзакции (микросекунды окна) теряются — для АТС несущественно.

### 11.3 Консенсус failover (роль witness)

repmgrd standby при потере связи с primary опрашивает witness: если и
witness подтверждает недоступность primary, выполняется promote. Witness
не хранит пользовательских данных и никогда не промоутится — его единственная
функция — третий голос, исключающий промоушен при «primary жива, но плохо
связана с VM2». При недоступности witness авто-failover не выполняется
(консервативная деградация — осознанное решение: отказ двух нод уже за
рамками SLA одного отказа).

## 12. Ремонт — сценарии и гарантии

### 12.1 Standby (VM2) потеряна безвозвратно

Пересоздать VM → слой 1 → `fusionpbx-ha.sh --join <токен>` (или `--repair`,
если cluster.conf спасён из бэкапа). Всегда `--force-clone`-семантика:
локальная база пустая/мусорная → клон с primary. Медиа — seed с VM1.

### 12.2 Primary (VM1) потеряна

Авто-failover уже повысил VM2 (см. §11.1). Пересоздать VM1 → слой 1 →
`--join`. Кластер видит двух кандидатов в primary? Нет: `repmgr standby
register` вводит VM1 как standby к действующей primary (VM2); далее
штатный `repmgr switchover` при желании вернуть роль.

### 12.3 Witness (VM3) потеряна

Пересоздать → `--join` (preflight witness-ветки не требует слоя 1). Пока
witness отсутствует, кластер работает, но авто-failover отключён — чинить
быстро, `--doctor` об этом напоминает.

### 12.4 Двойной отказ: заморозка и вывод из неё

При двух потерянных нодах из трёх запись останавливается: это правильное
поведение (продолжать писать мог бы только кластер без защиты от
split-brain). Штатный вывод из заморозки — ремонт любой одной ноды (§12.1–
12.3): кворум (2/3) восстанавливается, frozen-primary/standby
доводятся `rejoin`/`register`. Аварийный ручной промоушен последней
выжившей (мимо repmgr, `pg_ctl promote` при остановленных repmgrd) —
документируется как break-glass: допустим только при полной уверенности,
что остальные ноды никогда не вернутся со старыми данными, и с
последующей пересборкой кластера с нуля.

## 13. ALT-специфика (проверенные факты)

Источники: листинги p10/p11 зеркала mirror.yandex.ru (2026-10-13) и разбор
payload RPM `postgresql16-repmgr-5.5.0-alt5` (p11, x86_64).

### 13.1 Слой 1 (из установщика)

- пакет `postgresql16-server`; PGDATA `/var/lib/pgsql/data` (без номера
  версии в пути); сервис `postgresql.service` (безверсионный);
- мажор PG = 16 (`database_version=16` в `config.sh` слоя 1).

### 13.2 Пакет `postgresql16-repmgr` (факты из RPM)

| Элемент | Путь |
|---|---|
| конфиг | `/etc/repmgr/repmgr.conf` (каталог, не Debian-путь `/etc/repmgr.conf`) |
| бинари | `/usr/bin/repmgr`, `/usr/bin/repmgrd` |
| юнит демона | `/usr/lib/systemd/system/repmgr.service` — `ExecStart=/usr/bin/repmgrd -f ${REPMGR_CONF} --daemonize=false --no-pid-file`; `User=postgres`; `After=network.target postgresql.service` |
| env | `/etc/sysconfig/repmgr`: `REPMGR_CONF`, `REPMGRD_OPTS` |
| sudoers | `/etc/sudoers.d/repmgr` в составе RPM; инсталлер дополнительно пишет свой проверенный `visudo -c` дроп-ин `/etc/sudoers.d/fusionpbx-ha` (postgres → NOPASSWD только `systemctl start/stop/restart/reload/status postgresql`) — управление PG из repmgrd работает из коробки |
| extension | `/usr/share/pgsql/extension/repmgr*`, `/usr/lib64/pgsql/repmgr.so` |
| логи | `/var/log/repmgr` (tmpfiles.d) |

### 13.3 Референсные repmgr.conf (минимум)

```ini
# VM1 (primary)
node_id=1
node_name=fpbx-ha-1
conninfo='host=10.0.0.11 user=repmgr dbname=repmgr password=... connect_timeout=5'
data_directory='/var/lib/pgsql/data'
pg_bindir='/usr/bin'
failover='manual'                 # primary не промоутится
monitor_interval_secs=5           # имя repmgr 5.x; monitoring_interval игнорируется с WARN
reconnect_attempts=3
reconnect_interval=5
service_start_command='sudo systemctl start postgresql'
service_stop_command='sudo systemctl stop postgresql'
service_restart_command='sudo systemctl restart postgresql'
log_file='/var/log/repmgr/repmgrd.log'
```

```ini
# VM2 (standby) — отличия
node_id=2
node_name=fpbx-ha-2
conninfo='host=10.0.0.12 user=repmgr dbname=repmgr password=... application_name=fpbx-ha-2'
failover='automatic'
promote_command='/usr/bin/repmgr standby promote -f /etc/repmgr/repmgr.conf'
follow_command='/usr/bin/repmgr standby follow -f /etc/repmgr/repmgr.conf --upstream-node-id=%n'
priority=100
```

```ini
# VM3 (witness) — отличия
node_id=3
node_name=fpbx-witness
conninfo='host=10.0.0.13 user=repmgr dbname=repmgr password=...'
failover='manual'
```

`application_name` в conninfo нужен, чтобы `synchronous_standby_names`
на primary можно было задать именем (`fpbx-ha-2`), а не маской.

### 13.4 Версии

p11: repmgr 5.5.0-alt5 (PG13–17), haproxy 3.4.4, lsyncd 2.3.1, psycopg2
2.9.5; p10: repmgr 5.4.1-alt4, haproxy 2.8.28, lsyncd 2.1.4, psycopg2 2.9.1.
Синтаксис haproxy-конфига из §9.1 сверить под 2.8 (p10) при реализации.

## 14. Безопасность

1. **Токен** = root-эквивалент (пароль БД, repmgr, приватный sync-ключ).
   Печать — только по команде; совет «стирайте из истории буфера обмена».
2. **Sync-ключ**: ed25519, только для rsync медиа-дерева; `from=` по IP
   data-нод; `command=rrsync` (если доступен); параметры
   `no-pty,no-agent-forwarding,no-X11-forwarding,no-port-forwarding`.
3. **pg_hba** (минимальный набор; метод — как в слое 1). Блок **симметричен** для VM1/VM2: pg_hba живёт в PGDATA и клонируется, а после failover роли меняются местами. Строки «само-доступа» (собственный IP ноды) обязательны: `repmgr primary register`, repmgrd (conninfo с IP ноды) и локальный haproxy подключаются на IP ноды, и source-адрес таких соединений — тоже IP ноды.

```
# на VM1 (primary; клонируется на VM2 автоматически)
host repmgr      repmgr     10.0.0.11/32  md5   # метаданные: VM1 к себе (register, repmgrd)
host repmgr      repmgr     10.0.0.12/32  md5   # метаданные: VM2
host repmgr      repmgr     10.0.0.13/32  md5   # метаданные: VM3 (witness)
host replication repmgr     10.0.0.11/32  md5   # репликация: поток к восстановленной VM1
host replication repmgr     10.0.0.12/32  md5   # репликация: поток к VM2
host fusionpbx   fusionpbx  10.0.0.11/32  md5   # haproxy VM1 → бэкенды (оба IP)
host fusionpbx   fusionpbx  10.0.0.12/32  md5
host postgres    postgres   10.0.0.11/32  md5   # pg_rewind / управление sync-именами
host postgres    postgres   10.0.0.12/32  md5
```

```
# на VM3 (witness)
host repmgr      repmgr     10.0.0.11/32  md5   # repmgrd VM1 читает witness
host repmgr      repmgr     10.0.0.12/32  md5   # консенсус failover из VM2
host repmgr      repmgr     10.0.0.13/32  md5   # witness к себе (conninfo с собственным IP)
```

4. **role-agent** отвечает без аутентификации только `/primary` → 200/503,
   больше ничего не отдаёт и не принимает; listening на кластерном
   интерфейсе (доступен data-нодам), в firewall — только от них.
5. Права: cluster.conf и sync_key — 600/root; `/etc/fusionpbx-ha/` — 700.
6. Сеть: кластерный трафик (5432/8008/22-sync) — в management-сегменте,
   недоступном с клиентских сетей.

## 15. План тестирования

1. **Статика**: `sh -n`; shellcheck (если поставлен в CI); тесты
   аргументов/конфликтов команд по образцу `test_arguments.sh` слоя 1.
2. **Песочница state-machine** (по образцу `test_guard.sh`): шаги с
   заглушками `systemctl/psql/repmgr/rsync/ssh`; проверяются: resume,
   идемпотентность, отказы на середине, ветки `--repair`, seed-before-sync
   (порядок вызовов rsync/lsyncd — мок-лог).
3. **Стенд 3×LXC/VM (ALT p11)**, сценарии по порядку:
   - полный цикл `--init` → `--join` witness → `--join` standby; проверка:
     `repmgr cluster show` 3/3, sync_state=sync, `127.0.0.1:5433` → primary,
     звонок записан, файл записи читается с обеих нод;
   - пауза/стоп VM2: кластер жив; возврат `--repair`;
   - жёсткий стоп VM1 (kill -9 postgres + poweroff): авто-promote VM2 ≤45 c,
     новые звонки пишутся; возврат VM1 как standby (`rejoin --force-rewind`);
   - партиция VM1|VM2 (iptables DROP): изолированная primary перестаёт
     принимать коммиты (sync), дубль primary не возникает;
   - перезагрузка всех трёх нод в разнобой: кластер сходится сам;
   - двойной отказ → предсказуемая заморозка → ремонт одной ноды;
   - `--doctor` до/после каждого сценария.
4. **Приёмка**: прогон сценария «плановое выключение хоста Proxmox»
   целиком (не только VM).

## 16. Открытые вопросы (проверить при реализации)

| # | Вопрос | Как закрывается |
|---|--------|-----------------|
| ~~В1~~ | точный путь `rrsync` в пакете rsync ALT | **Закрыт (RPM rsync-3.2.7-alt7):** `/usr/share/doc/rsync-3.2.7/support/rrsync` (python3, версионный путь). Реализация копирует его в `/usr/local/bin/rrsync` — стабильный путь в `authorized_keys` переживёт обновление rsync; если не найден нигде — деградация `from=` без `command=` |
| В2 | пробрасывает ли repmgr 5.5 `application_name` из conninfo в primary_conninfo | conninfo standby содержит `application_name=<имя ноды>`; если фактическое имя walreceiver'а не совпало — `ha_ensure_sync` автоматически переключается на `'*'` (любой streaming standby; в кластере из 2 data-нод эквивалентно). Финальная проверка — стенд §15.3 |
| ~~В3~~ | layout haproxy в ALT и синтаксис http-проверки для 2.8 | **Закрыт (RPM haproxy-3.4.6-alt1):** юнит грузит ОБА — `-f /etc/haproxy/haproxy.cfg -f /etc/haproxy/conf.d` (`CFGDIR`); наш фрагмент кладётся в `conf.d/fusionpbx-ha.cfg`, пакетный конфиг не трогается. `http-check send meth GET uri /primary` валиден для 2.2+ (покрывает p10 2.8.28) |
| ~~В4~~ | тянет ли `postgresql16-repmgr` `postgresql16-server` (для VM3) | **Закрыт конструктивно:** witness ставит оба пакета явно (`postgresql16-repmgr` + `postgresql${HA_PG_VERSION}-server`) — поведение не зависит от метазависимостей |
| В5 | поведение repmgrd при старте, если PG ещё не поднята (boot-race VM2) — ждёт ли бесконечно | стенд: перезагрузка в разнобой (сценарий 15.3) |
| В6 | сохранение `--delete`-семантики lsyncd 2.1.4 (p10) против 2.3.1 (p11) | стенд на p10 либо фиксация минимальной версии p11 |
| В7 | параметры lsyncd для больших каталогов записей (inotify-лимиты) | `sysctl fs.inotify.max_user_watches` в `--doctor` |

## 17. Будущие расширения (вне v1)

- **VIP-модуль** (keepalived, `track_script` по role-agent) — если появится
  парк конечных точек, не умеющих два сервера;
- **третья PG-реплика на VM3** (без FusionPBX) — устранение окна работы
  «на последней копии» после первого отказа; добавляется без переделок
  (`repmgr standby register` на VM3);
- **процедура апгрейда** (minor-версии PG и FusionPBX: switchover →
  апгрейд пассивной ноды → switchover обратно; web-дерево — rsync в паузе);
- **ansible-обёртка**: playbook, вызывающий fusionpbx-ha.sh с `--config`
  (интерфейс для этого заложен в v1);
- интеграция сводки `--doctor` в существующий мониторинг установщика.

## 18. История изменений

| Версия | Дата | Изменения |
|---|---|---|
| 0.1 | 2026-10-13 | Первый полный черновик (согласование) |
| 0.2 | 2026-10-13 | §5.1: работа за HTTP(S)-прокси — `--proxy`, переиспользование `proxy.sh` слоя 1, дополнение `no_proxy` адресами кластера, правило `curl --noproxy '*'` для внутренних проверок (ловушка `/root/.curlrc`). Состав документации: `README.md` (краткий quick start) + `RUNBOOK.md` (рабочая инструкция «для холодной памяти»: развёртывание, здоровье, отказы, ремонт, обновление ветки, прокси) |
| 0.3 | 2026-10-13 | **Реализация v1** (`fusionpbx-ha.sh`, `resources/`, `tests/` — 120 проверок). Найдены и исправлены два проектных дефекта: **(а) заморозка после failover** — `synchronous_standby_names` хранится в `postgresql.auto.conf` и клонируется на standby; повышенная нода ждала бы sync-standby со старым именем и блокировала все коммиты → `promote_command` заменён на обёртку `/usr/lib/fusionpbx-ha/promote.sh`, очищающую sync-имена перед promote; **(б) «async до возврата standby»** — с заданными sync-именами и умершим standby коммиты блокируются (а не «асинхронно», как читался §11.1) → введена функция `ha_ensure_sync` (включает sync-имена при наличии streaming-standby, снимает при отсутствии; вызывается из `--init`/`--join`/`--repair`) + детект заморозки в `--doctor`. Прочее: haproxy-фрагмент дополнен `timeout client/server 1d` (дефолтные 1m убивали долгоживущие SQL-сессии); в pg_hba data-нод добавлены строки `postgres` для удалённого управления sync-именами; В1/В3/В4 закрыты разбором RPM; rrsync копируется в `/usr/local/bin`; шаги исполняются в subshell (баннер resume), межшаговое состояние передаётся через повторный source cluster.conf |
| 0.3.1 | 2026-10-14 | **Hotfix: свежий `--init` падал на шаге 1** (`HA_HAPROXY_PORT: unbound variable` — первый найденный стендом дефект, §15.3). Общий корень: значения живут в `cluster.conf`, а первые шаги `--init` исполняются до его появления. Исправлены три проявления: **(а)** шаг 1 проверял занятость портов 5433/8008 → в `ha-lib.sh` добавлены встроенные дефолты `HA_PG_PORT`/`HA_HAPROXY_PORT`/`HA_AGENT_PORT` (зеркалят генератор, перекрываются source'ом cluster.conf); **(б)** шаг 2 вписывал в `cluster.conf` учётные данные БД слоя 1, но они читались в subshell шага 1 и терялись → `cmd_init` читает `config.conf` в родительском процессе; **(в)** hosts-блок и `no_proxy` шага 2 требовали список нод из ещё не подключённого `cluster.conf` → шаг 2 сам source'ит его после генерации. Заодно: resume `--init` загружает существующий `cluster.conf` до старта последовательности (его значения авторитетны; без `--force` изменение `--node2`/`--node3` игнорируется с предупреждением — токен уже выдан); `ha_load_cluster_conf` сначала сбрасывает проверяемые переменные (дефолты/устаревшие значения не должны маскировать обрезанный `cluster.conf`); `--proxy` валидируется по формату host:port ДО запуска команд (`proxy.sh` слоя 1 пишет конфиги apt/git/wget/curl безусловно — опечатка не должна до них добираться); `/etc/hosts` вынесен в переопределяемый `HA_HOSTS_FILE` (для песочницы тестов). Тесты: +9 (свежий `--init` без `cluster.conf`: шаги 1–2, токен, resume, приоритет `cluster.conf` при изменённом `--node2`) — итого 129 |
| 0.3.2 | 2026-10-14 | **Hotfix: `--init` падал на шаге 7** (реальный стенд fpbx1/2/3, `Connection refused` на `192.168.1.236:5432` — PG слушал только 127.0.0.1). Найдено и исправлено пять дефектов одного класса «код писался без стенда»: **(а) listen_addresses** — слой 1 оставляет PG loopback-only, а repmgr/haproxy-пир/witness ходят на IP ноды → шаг 5 теперь ставит `wal_log_hints` **и** `listen_addresses='*'` одним рестартом, идемпотентная проверка добавлена в прелюдию регистраций (для resume); **(б) pg_hba без само-доступа** — в блоке не было `host repmgr repmgr <свой IP>` (register/repmgrd/haproxy подключаются на IP ноды) и не было симметричной `host replication` для восстановления VM1 → блок переписан симметрично (§14.3); **(в) `--join` не рендерил repmgr.conf** — `repmgr standby clone` падает без конфига → рендер + promote.sh + sudoers перенесены в unpack-шаг (до клона); **(г) `monitoring_interval`** — несуществующий в repmgr 5.x параметр (молча менял RTO) → `monitor_interval_secs=5`; **(д) promote-обёртка не работала бы** — `ALTER SYSTEM` запрещён на standby в recovery (очистка sync-имён тихо проваливалась бы → заморозка записей после failover), а `service_promote_command='systemctl reload'` не промоутит → обёртка переписана на правку `postgresql.auto.conf`+SIGHUP (паттерн из документации repmgr), `service_promote_command` удалён (smart promote через `pg_promote()`). Прочее: sudoers-дроп-ин `/etc/sudoers.d/fusionpbx-ha` (NOPASSWD только для `systemctl … postgresql`, проверка `visudo -c` — закрывает давний зазор §13.2); `sudo` добавлен в пакеты; самовосстанавливающая прелюдия `ha_register_prelude()` перед каждой регистрацией (перезапись pg_hba, listen, re-render repmgr.conf при отличии от шаблона, sudoers, promote.sh — resume со state-файла старой версии чинится сам); `ha_ensure_pg_listen` умеет standby-ветку (правка файла вместо ALTER SYSTEM). Тесты: обновлены +5 проверок (monitor_interval_secs, отсутствие legacy-ключей, promote.sh без ALTER SYSTEM) |
| 0.3.3 | 2026-10-14 | **Hotfix: `--init` падал на шаге 7** (реальный стенд fpbx1/2/3, `repmgr primary register` обрывался на первом же метаданном запросе: `permission denied for schema repmgr` / «нет доступа к схеме repmgr»). Корень: `CREATE EXTENSION repmgr` выполняется от суперпользователя `postgres` (локальный сокет, peer auth) → схема `repmgr` и все её объекты принадлежат `postgres`, а роль `repmgr` (non-superuser по дизайну §14) не имеет даже `USAGE` на схему. Исправление: новая `ha_fix_repmgr_schema_access()` — передача владения схемой и объектами расширения роли `repmgr` (`ALTER SCHEMA OWNER` + пообъектная передача DO-блоком с пообъектной толерантностью) + DML-гранты + `ALTER DEFAULT PRIVILEGES` (на случай объектов, которые будущий `ALTER EXTENSION UPDATE` добавит от postgres) + best-effort гранты для non-superuser-операции: `pg_monitor` (repmgrd опрашивает `pg_stat_replication` на primary) и `EXECUTE` на файловые функции `pg_rewind` (документированный рецепт PG13+; `--repair` запускает pg_rewind от роли repmgr). Вызовы: init-шаг 4 (после CREATE EXTENSION), witness-флоу (локальная метаданная БД witness сама участвует в выборах при failover) и **прелюдия регистраций** — self-heal для resume со state-файлов старых версий (шаги 1–6 уже отмечены выполненными, повторный запуск продолжается с шага 7 и сам выдаёт права). На standby фикса — no-op: метаданная БД есть стриминговая копия primary (гранты приходят репликацией, ALTER в recovery запрещён). Прочее: smoke-проверка шага 4 теперь читает `repmgr.nodes` от роли `repmgr` по TCP — прежняя `SELECT 1` проходила при полностью сломанном доступе к схеме (ровно тот класс молчаливых пропусков). Тесты: +19 (стабы psql/runuser/systemctl в песочнице test_lib: ветки primary/standby/без-расширения/отказ-pSQL, содержимое обоих SQL-файлов, выживание dollar-tags в heredoc, ON_ERROR_STOP только на жёстком блоке, вызов фикса из прелюдии) — итого 152 |
| 0.3.4 | 2026-10-15 | **Hotfix: FATAL «cannot apply the repmgr extension grants»** (реальный стенд fpbx1/2/3, resume `--init` на шаге 7; тот же блок в чистом флоу упал бы и на шаге 4). Корень: PAM-сессия root на ALT получает **приватный per-user TMPDIR** (`pam_mktemp`: `/tmp/.private/root`, режим 0700); фикc 0.3.3 писал SQL-файл туда и запускал его как `psql -f` от пользователя `postgres` — тот не может пройти по чужому каталогу 0700 → psql завершался «Permission denied», а обёртка `pg_runuser_psql` глушила stderr (`2>/dev/null`), поэтому в выводе был только FATAL без причины. Исправление: SQL подаётся psql **через stdin** — файл открывает сам root-шелл, psql наследует готовый дескриптор (не зависит от политики `/tmp`: per-user, PrivateTmp, anything); stderr жёсткого блока больше не глушится — при отказе FATAL цитирует сам текст ошибки psql и даёт рабочую команду повторa (`< файл`, не `-f`); файлы фикса остаются 0600 root (postgres их больше не открывает). Лучший блок тоже переведён на stdin. Чистая переустановка не требовалась и не помогла бы — дефект воспроизводился и на свежем `--init`. Тесты: psql-стаб песочницы захватывает SQL из stdin; +4 проверки (stdin вместо `-f` — контракт для обоих SQL-блоков, причина отказа psql в сообщении die, рабочая stdin-форма inspect-подсказки, сохранение SQL-файла при отказе) — итого 156 |
| 0.3.5 | 2026-10-15 | **Hotfix: `--init` падал на шаге 8** (реальный стенд fpbx1/2/3: `role-agent is not answering on 127.0.0.1:8008 (code: 000000)` при том, что агент слушал порт — ss показывал LISTEN python3 на 0.0.0.0:8008). Две причины: **(а) гонка запуска** — юнит Type=simple, systemd помечает его запущенным в момент execve python3, а сокет появляется только после импорта модулей (секунда-две на скромной VM); код же пробовал сокет ровно один раз сразу после `systemctl restart` и умирал → шаг 8 (и все повторные вызовы в join/witness/repair-флоу) ждут сокет: `ha_wait … 1` до HA_AGENT_WAIT=30с (переопределяемая), при таймауте die подсказывает `systemctl status`; **(б) двойной код 000** — `-w '%{http_code}'` уже печатает 000 при отказе curl, а хвостовой `|| echo 000` добавлял второй («000\n000» → в сообщении «code: 000000») → ha_agent_code возвращает ровно один код. Прочее: ha_wait получил опциональный 4-й аргумент (шаг опроса, дефолт 10с — поведение существующих вызовов не меняется); путь установки юнита вынесен в переопределяемый HA_SYSTEMD_DIR (паттерн HA_SUDOERS_DIR для песочницы тестов). Тесты: +9 (curl-стаб с счетчиком вызовов: одиночный 000, ждёт медленный старт агента (2 неудачных опроса), сообщение успеха, юнит в песочнице, «поллинговал, а не пробовал один раз», таймаут-fatal с одиночным 000 и подсказкой systemctl) — итого 165 |
| 0.3.6 | 2026-10-15 | **Hotfix: `--join` падал на preflight — «the peer data node … is not reachable on port 5432»** (реальный стенд fpbx1/2/3, инсталлер ждёт на шаге 11; `ss` на primary при этом показывал LISTEN 0.0.0.0:5432). Корень: слой 1 (`resources/iptables.sh`) закрывает INPUT политикой DROP и открывает только 22/80/443/7443/5060–5091/RTP/1194 — **без кластерных портов**; §14.6 проектировался в предположении «кластерный трафик в management-сегменте», а реальный стенд держит все три ноды в одном LAN — пакеты fpbx2/fpbx3→fpbx1:5432 молча дропались файрволом primary, при этом все шаги 1–10 (`--init`) локальны и этого не замечали: первое в жизни кластера cross-node подключение — ровно тот preflight, на котором всё и встало. Исправление: новая `ha_ensure_cluster_firewall()` (ha-lib.sh) — идемпотентно (`iptables -C` перед каждым insert, позиция 1 — впереди любых DROP-правил) открывает 22/5432/8008 **только для адресов кластерных пиров** (собственный адрес пропускается), персистентность — как в слое 1 (`iptables-save > /etc/sysconfig/iptables`), но только на нодах с сервисом iptables/файлом правил (голый witness ничего оттуда не грузит — файл-сирота не создаётся); firewalld не воюется — warn и пропуск; отсутствующий iptables — мягкий пропуск. Вызовы: init-шаг 5 (там же, где PG становится сетевым), **шаги 11/12 — self-heal для resume со state-файлов старых версий** (текущий стенд: шаги 1–10 уже выполнены, повторный запуск продолжает с 11 и сам открывает порты), preflight обоих join-флоу (локальные INPUT для проверок haproxy/репликации) и `--repair` (перезапуск слоя 1 на перестроенной ноде flush'ит все правила). Прочее: `ha_pg_isready` (перенесена в ha-lib.sh рядом с ha_agent_code) больше не выбрасывает вердикт инструмента — при отказе `HA_PG_ISREADY_MSG` несёт «no response» (драп файрвола) vs «rejecting connections» (сервер жив, стартует/останавливается), die-сообщения join/witness-preflight цитируют его + подсказку с ручной проверкой, warn в `--doctor` тоже. Тесты: +18 (стабы iptables/iptables-save/pg_isready с вердиктами и веткой FIREWALLD/IS_ENABLED у systemctl; вердикты пробы, 6 правил для 2 пиров без правила для себя, персистентность layer-1-образом, идемпотентность повторного запуска, отсутствие файла-сироты, firewalld-skip, отсутствующий iptables, вердикт в doctor-warn) — итого 183 |

