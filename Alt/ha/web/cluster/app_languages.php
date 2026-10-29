<?php

// Cluster status (fusionpbx-ha web add-on). en-us is the fallback for
// every language; ru-ru is maintained as the second first-class language.

$text['title-cluster']['en-us'] = "Cluster Status";
$text['title-cluster']['ru-ru'] = "Состояние кластера";

$text['description-cluster']['en-us'] = "FusionPBX HA cluster state as collected on this node. Updated automatically every minute; use the Refresh button to collect it instantly; read-only.";
$text['description-cluster']['ru-ru'] = "Состояние HA-кластера FusionPBX по данным сборщика на этой ноде. Обновляется автоматически каждую минуту; кнопка «Обновить» собирает его немедленно; только для просмотра.";

$text['label-cluster_status']['en-us'] = "Cluster";
$text['label-cluster_status']['ru-ru'] = "Кластер";

$text['label-health']['en-us'] = "Health";
$text['label-health']['ru-ru'] = "Здоровье";

$text['label-node']['en-us'] = "Node";
$text['label-node']['ru-ru'] = "Нода";

$text['label-ip']['en-us'] = "Address";
$text['label-ip']['ru-ru'] = "Адрес";

$text['label-kind']['en-us'] = "Kind";
$text['label-kind']['ru-ru'] = "Тип";

$text['label-state']['en-us'] = "State";
$text['label-state']['ru-ru'] = "Состояние";

$text['label-data']['en-us'] = "data";
$text['label-data']['ru-ru'] = "данные";

$text['label-witness']['en-us'] = "witness";
$text['label-witness']['ru-ru'] = "свидетель";

$text['label-replication']['en-us'] = "Replication";
$text['label-replication']['ru-ru'] = "Репликация";

$text['label-mode']['en-us'] = "Mode";
$text['label-mode']['ru-ru'] = "Режим";

$text['label-lag']['en-us'] = "Lag";
$text['label-lag']['ru-ru'] = "Отставание";

$text['label-peer']['en-us'] = "Peer";
$text['label-peer']['ru-ru'] = "Пара";

$text['label-entry-point']['en-us'] = "Entry point (127.0.0.1:5433)";
$text['label-entry-point']['ru-ru'] = "Точка входа (127.0.0.1:5433)";

$text['label-services']['en-us'] = "Services on this node";
$text['label-services']['ru-ru'] = "Сервисы на этой ноде";

$text['label-updated']['en-us'] = "Updated";
$text['label-updated']['ru-ru'] = "Обновлено";

$text['label-this-node']['en-us'] = "This node";
$text['label-this-node']['ru-ru'] = "Эта нода";

$text['label-collector']['en-us'] = "Status collector";
$text['label-collector']['ru-ru'] = "Сборщик статуса";

$text['option-yes']['en-us'] = "OK";
$text['option-yes']['ru-ru'] = "OK";

$text['option-no']['en-us'] = "broken";
$text['option-no']['ru-ru'] = "не работает";

// health verdicts
$text['health-ok']['en-us'] = "OK";
$text['health-ok']['ru-ru'] = "Норма";

$text['health-degraded']['en-us'] = "Degraded";
$text['health-degraded']['ru-ru'] = "Деградация";

$text['health-fail']['en-us'] = "Failure";
$text['health-fail']['ru-ru'] = "Отказ";

// node / witness states
$text['state-primary']['en-us'] = "primary";
$text['state-primary']['ru-ru'] = "первичная";

$text['state-standby']['en-us'] = "standby";
$text['state-standby']['ru-ru'] = "резервная";

$text['state-down']['en-us'] = "down";
$text['state-down']['ru-ru'] = "недоступна";

$text['state-agent-down']['en-us'] = "up, role-agent dead";
$text['state-agent_down']['en-us'] = "up, role-agent dead";
$text['state-agent_down']['ru-ru'] = "работает, агент ролей мёртв";

$text['state-reachable']['en-us'] = "reachable";
$text['state-reachable']['ru-ru'] = "доступен";

$text['state-unreachable']['en-us'] = "unreachable";
$text['state-unreachable']['ru-ru'] = "недоступен";

$text['state-up']['en-us'] = "up";
$text['state-up']['ru-ru'] = "работает";

// replication modes
$text['mode-sync']['en-us'] = "synchronous";
$text['mode-sync']['ru-ru'] = "синхронная";

$text['mode-async']['en-us'] = "asynchronous";
$text['mode-async']['ru-ru'] = "асинхронная";

$text['mode-streaming']['en-us'] = "streaming";
$text['mode-streaming']['ru-ru'] = "потоковая";

$text['mode-none']['en-us'] = "not connected";
$text['mode-none']['ru-ru'] = "нет соединения";

$text['mode-unknown']['en-us'] = "unknown";
$text['mode-unknown']['ru-ru'] = "неизвестно";

// snapshot problems (red banner)
$text['message-stale']['en-us'] = "Status data is STALE: the collector has not updated the snapshot for over %minutes% minutes. Trust the CLI, not this page.";
$text['message-stale']['ru-ru'] = "Данные УСТАРЕЛИ: сборщик не обновлял снимок более %minutes% мин. Верьте консоли, а не этой странице.";

$text['message-missing']['en-us'] = "No status snapshot on this node yet (%file%). It is written by the status cron every few minutes; run 'fusionpbx-ha.sh --status --json' as root to check the collector.";
$text['message-missing']['ru-ru'] = "На этой ноде ещё нет снимка состояния (%file%). Его пишет статусный cron каждые несколько минут; проверьте сборщик командой 'fusionpbx-ha.sh --status --json' от root.";

$text['message-unreadable']['en-us'] = "The status snapshot cannot be read (%file%).";
$text['message-unreadable']['ru-ru'] = "Не удалось прочитать снимок состояния (%file%).";

$text['message-invalid']['en-us'] = "The status snapshot is not valid JSON (%file%) - re-generated automatically on the next collector run.";
$text['message-invalid']['ru-ru'] = "Снимок состояния не является корректным JSON (%file%) - будет перезаписан при следующем запуске сборщика.";

$text['message-standby-rows']['en-us'] = "The cluster menu/widget registration rows are not visible on this standby yet (replication lag or the primary ran an older installer). Re-run the install command on the primary if this persists.";
$text['message-standby-rows']['ru-ru'] = "Строки регистрации меню/виджета кластера ещё не видны на этой резервной ноде (лаг репликации или на первичной работал старый установщик). Если не исчезнет - повторите команду установки на первичной ноде.";

// 0.3.41: the instant refresh (the pinned sudoers verb)
$text['label-refresh']['en-us'] = "Refresh now";
$text['label-refresh']['ru-ru'] = "Обновить сейчас";

$text['message-refresh-ok']['en-us'] = "The status snapshot has been collected - the data below is current.";
$text['message-refresh-ok']['ru-ru'] = "Снимок состояния собран - данные ниже актуальны.";

$text['message-refresh-fail']['en-us'] = "The status collector FAILED (a probe is hanging or the lock is busy). The data below may be outdated - check the collector log: /var/lib/fusionpbx-ha/status-collector.log";
$text['message-refresh-fail']['ru-ru'] = "Сборщик статуса НЕ СПРАВИЛСЯ (зависший пробник или занятая блокировка). Данные ниже могут быть устаревшими - журнал: /var/lib/fusionpbx-ha/status-collector.log";

$text['message-refresh-unavailable']['en-us'] = "Instant refresh is unavailable on this node: the status collector is not deployed (re-run this node's install command to install it).";
$text['message-refresh-unavailable']['ru-ru'] = "Мгновенное обновление на этой ноде недоступно: сборщик статуса не развёрнут (повторите команду установки этой ноды, чтобы поставить его).";

// the CLI-first policy (footer of the page and the widget)
$text['hint-cli']['en-us'] = "This view is read-only by design. Diagnostics: fusionpbx-ha.sh --doctor; repair: fusionpbx-ha.sh --repair (see RUNBOOK.md).";
$text['hint-cli']['ru-ru'] = "Этот экран по дизайну только для просмотра. Диагностика: fusionpbx-ha.sh --doctor; ремонт: fusionpbx-ha.sh --repair (см. RUNBOOK.md).";

?>
