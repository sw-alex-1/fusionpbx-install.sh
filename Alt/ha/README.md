# Alt/ha — HA add-on for FusionPBX on ALT Linux (repmgr + witness)

**Status: implemented (v1), pending lab validation.** `fusionpbx-ha.sh`
is complete and covered by a sandbox test suite (`tests/run-all.sh`,
120 checks). The next gate is the 3-node ALT stand (DESIGN.md section 15.3)
before production use.

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

Behind an HTTP(S) proxy? Everything works with the same `--proxy host:port`
flag as the layer-1 `install.sh` — cluster-internal traffic always goes
direct (DESIGN.md §5.1, RUNBOOK.md §8).

## Quick start (planned CLI)

| # | Where | Command | What it does |
|---|-------|---------|--------------|
| 1 | VM1, VM2 | layer 1: `./pre-install.sh && ./install.sh` | installs a standalone FusionPBX node (layer 1 unchanged) |
| 2 | VM1 | `./fusionpbx-ha.sh --init --node2 IP --node3 IP` | declares VM1's database the cluster primary, repoints apps to `127.0.0.1:5433`, prints the join **token**, then waits for the other nodes |
| 3 | VM2, VM3 | `./fusionpbx-ha.sh --join TOKEN` | joins the cluster; role picked automatically by own IP (VM2 → standby — its local DB is replaced by a clone from VM1; VM3 → witness) |
| 4 | any node | `./fusionpbx-ha.sh --doctor` | full health check, non-zero exit for monitoring; strictly read-only — it reports drift and names the fix command, it never modifies configs or services (0.3.16) |

Day-2 operations — node failure, repair of a rebuilt node, cluster freeze
after a double failure, branch upgrade, proxy-only networks — step by step
in **RUNBOOK.md** (written for "it's been months, nobody remembers anything").

## Contents

| File | Purpose |
|------|---------|
| `fusionpbx-ha.sh` | Layer-2 installer: `--init`, `--join`, `--repair`, `--status`, `--doctor`, `--print-token` |
| `resources/ha-lib.sh` | Core library: state machine, token, cluster.conf, rendering, PG/sync helpers (sourced; also used by tests) |
| `resources/` | Templates & units: `repmgr.conf.tpl`, `haproxy.cfg.tpl`, `lsyncd.conf.lua.tpl`, `promote.sh.tpl`, `role-agent.py`, `fusionpbx-ha-agent.service` |
| `tests/` | Sandbox test suite (`run-all.sh`): lib/render/CLI/agent, layer-1 `test_guard.sh` style |
| `DESIGN.md` | Design document — architecture, CLI, step sequences, failover/repair analysis. **v0.3** |
| `RUNBOOK.md` | Operational manual (RU) — deploy, health checks, single/double failure, repair, upgrade, proxy. Self-sufficient per scenario |

## Русский раздел

**Статус: реализовано (v1), ожидает стендовой проверки.** `fusionpbx-ha.sh`
готов и покрыт песочным тестовым набором (`tests/run-all.sh`, 120 проверок);
следующие ворота — стенд 3×ALT (DESIGN.md §15.3) перед продуктивом.

Это надстройка (слой 2) над установщиком: слой 1 (`Alt/`) не изменяется и
по-прежнему ставит одиночную ноду; `fusionpbx-ha.sh` превращает три
подготовленные VM (2 data-ноды + 1 witness) в HA-кластер на repmgr + witness:
синхронная репликация (RPO = 0), автоматический failover (~30–45 c) с кворумом
через witness, haproxy-маршрутизация к текущей primary и lsyncd-синк
медиа-файлов. Все пакеты — из штатных репозиториев ALT p10/p11.

Краткий план команд — в таблице Quick start выше; детали реализации и
обоснования — в [DESIGN.md](DESIGN.md) (v0.3), рабочая инструкция на все
остальные случаи (упала нода, кластер заморожен, ремонт пересобранной ноды,
обновление ветки) — в [RUNBOOK.md](RUNBOOK.md): каждый сценарий самодостаточен
и написан для ситуации «прошло много времени, никто ничего не помнит». Работа
за корпоративным HTTP(S)-прокси — тем же флагом `--proxy host:port`, что и в
слое 1; межнодовый трафик идёт напрямую (DESIGN.md §5.1). Тесты:
`Alt/ha/tests/run-all.sh` (без root, ничего не трогает в системе).
