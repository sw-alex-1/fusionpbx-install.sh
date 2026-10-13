# Alt/ha — HA add-on for FusionPBX on ALT Linux (repmgr + witness)

**Status: design phase.** No runnable code here yet — this directory currently
hosts the approved-track design for `fusionpbx-ha.sh`. Implementation starts
after the design is reviewed.

## What this is

A separate entry point (layer 2) that turns three prepared VMs into a
FusionPBX HA cluster:

```
Proxmox host1: VM1 = [ FusionPBX + PostgreSQL primary  + repmgrd + haproxy + lsyncd ]
Proxmox host2: VM2 = [ FusionPBX + PostgreSQL standby  + repmgrd + haproxy + lsyncd ]
Proxmox host3: VM3 = [ witness: tiny PostgreSQL (repmgr metadata only) + repmgrd ]
```

It does **not** replace or modify the installer in `Alt/` (layer 1). Layer 1
installs a standalone FusionPBX node; `fusionpbx-ha.sh` clusters already
installed nodes. All packages come from stock ALT repositories (p10/p11):
`postgresql16-repmgr`, `haproxy`, `lsyncd` (verified against repository
listings; Patroni is **not** packaged in ALT — see DESIGN.md §2 for the
stack rationale).

## Contents

| File | Purpose |
|------|---------|
| `DESIGN.md` | Design document for `fusionpbx-ha.sh` — architecture, CLI, state machine, step sequences, failover/repair analysis, test plan. Review target: **v0.1** |
| `fusionpbx-ha.sh` | *(planned)* Layer-2 installer: `--init`, `--join`, `--repair`, `--status`, `--doctor` |
| `resources/` | *(planned)* Config templates: repmgr, haproxy, lsyncd, role-agent, systemd units |
| `tests/` | *(planned)* Sandbox tests, same style as `Alt/resources/../scripts/test_guard.sh` |

## Русский раздел

**Статус: этап проектирования.** Исполняемого кода пока нет — здесь находится
дизайн-документ `fusionpbx-ha.sh` (версия 0.1, на согласование). Реализация
начинается после утверждения дизайна.

Это надстройка (слой 2) над существующим установщиком: установщик из `Alt/`
(слой 1) не изменяется и по-прежнему ставит одиночную ноду FusionPBX;
`fusionpbx-ha.sh` превращает три подготовленные виртуалки
(2 data-ноды + 1 witness) в HA-кластер на `repmgr` + witness с синхронной
репликацией, haproxy-маршрутизацией к текущей primary и lsyncd-синхронизацией
медиа-файлов. Все пакеты — из штатных репозиториев ALT p10/p11.
