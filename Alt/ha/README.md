# Alt/ha — HA add-on for FusionPBX on ALT Linux (repmgr + witness)

**Status: implemented (v1), pending lab validation.** `fusionpbx-ha.sh`
is complete and covered by a sandbox test suite (`tests/run-all.sh`,
520 checks). The next gate is the 3-node ALT stand (DESIGN.md section 15.3)
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

The flow is "install all three servers first, then connect them to the
cluster" (0.3.39): prepare every VM before the HA bootstrap starts —
`--init` completes on its own and never waits for the peers.

| # | Where | Command | What it does |
|---|-------|---------|--------------|
| 1 | VM1, VM2 | layer 1: `./pre-install.sh && ./install.sh` | installs a standalone FusionPBX node on BOTH data nodes (VM3/witness needs only the OS, no layer 1) |
| 2 | VM1 | `./fusionpbx-ha.sh --init --node2 IP --node3 IP` | declares VM1's database the cluster primary, repoints apps to `127.0.0.1:5433`, prints the join **token** and COMPLETES (no waiting; sync replication and media sync arm themselves automatically when VM2 joins) |
| 3 | VM2, VM3 | `./fusionpbx-ha.sh --join TOKEN` | joins the cluster; role picked automatically by own IP (VM2 → standby — its local DB is replaced by a clone from VM1; the destructive confirmation is asked UP FRONT, before any step runs; VM3 → witness, no local data touched) |
| 4 | any node | `./fusionpbx-ha.sh --doctor` | full health check, non-zero exit for monitoring; strictly read-only — it reports drift and names the fix command, it never modifies configs or services (0.3.16). Run it AFTER both peers joined: before that, doctor on the primary honestly reports the missing nodes (expected during bootstrap) |

After step 2/3 the data nodes also get the **web status add-on** (0.3.40,
DESIGN.md §19): a read-only **Status → Cluster** page and a dashboard
widget in the FusionPBX UI. A cron job refreshes
`/var/lib/fusionpbx-ha/status.json` **every minute** (0.3.41 — was 5);
the collector also fires instantly after a failover / auto-rejoin, and the
**Refresh now** button on the page/widget re-runs it on demand (a pinned
sudoers verb, one command — nothing else is exposed to the web user).
The page/widget render the file and run no probes — when the collector
dies the data ages out (threshold 180s) and the UI turns red (visible
by design). Repairs stay in the CLI (`--doctor` / `--repair`). The menu
item and the widget appear after the next web login.

**Interactive mode (0.3.37):** on a terminal you can skip the flags entirely —
a bare `./fusionpbx-ha.sh` asks the node role (primary / standby / witness),
the role's arguments (node IPs or the join token) and the outbound proxy;
the layer-1 `install.sh` asks the same way (proxy, domain, admin password).
Every question has a safe default, CLI flags are never re-asked, and without
a terminal on stdin (piped / ssh / CI) zero questions are asked — both
installers stay fully automatable.

Day-2 operations — node failure, repair of a rebuilt node, cluster freeze
after a double failure, branch upgrade, proxy-only networks — step by step
in **RUNBOOK.md** (written for "it's been months, nobody remembers anything").

## Contents

**Layout (0.3.34):** the entry script lives one level up — `Alt/fusionpbx-ha.sh`,
next to the layer-1 `pre-install.sh`/`install.sh` (one system, one place).
Everything it ships (templates, units, tests, docs) stays here in `Alt/ha/`.
The script resolves both layouts itself, and a deployed flat copy
(`/root/ha/{fusionpbx-ha.sh,resources/}`) keeps working unchanged.

| File | Purpose |
|------|---------|
| `../fusionpbx-ha.sh` | Layer-2 installer (`Alt/fusionpbx-ha.sh`): `--init`, `--join`, `--repair`, `--status [--json]`, `--write-status` (the collector: the cron, the refresh button and the post-failover hooks all call it), `--doctor`, `--print-token` |
| `resources/ha-lib.sh` | Core library: state machine, token, cluster.conf, rendering, PG/sync helpers, the web status add-on installer (sourced; also used by tests) |
| `resources/` | Templates & units: `repmgr.conf.tpl`, `haproxy.cfg.tpl`, `lsyncd.conf.lua.tpl`, `promote.sh.tpl`, `role-agent.py`, `fusionpbx-ha-agent.service` |
| `web/cluster/` | The FusionPBX app installed onto the data nodes (0.3.40): Status → Cluster page + dashboard widget, both reading the cron-maintained status snapshot; the Refresh-now button (0.3.41) re-runs the collector via the pinned sudoers verb |
| `tests/` | Sandbox test suite (`run-all.sh`): lib/render/CLI/agent, layer-1 `test_guard.sh` style |
| `DESIGN.md` | Design document — architecture, CLI, step sequences, failover/repair analysis, §19 web status. **v0.3** |
| `RUNBOOK.md` | Operational manual (RU) — deploy, health checks, single/double failure, repair, upgrade, proxy. Self-sufficient per scenario |

## Русский раздел

**Статус: реализовано (v1), ожидает стендовой проверки.** `fusionpbx-ha.sh`
готов и покрыт песочным тестовым набором (`tests/run-all.sh`, 520 проверок);
следующие ворота — стенд 3×ALT (DESIGN.md §15.3) перед продуктивом.

Это надстройка (слой 2) над установщиком: слой 1 (`Alt/`) не изменяется и
по-прежнему ставит одиночную ноду; `fusionpbx-ha.sh` превращает три
подготовленные VM (2 data-ноды + 1 witness) в HA-кластер на repmgr + witness:
синхронная репликация (RPO = 0), автоматический failover (~30–45 c) с кворумом
через witness, haproxy-маршрутизация к текущей primary и lsyncd-синк
медиа-файлов. Все пакеты — из штатных репозиториев ALT p10/p11.

Краткий план команд — в таблице Quick start выше; детали реализации и
обоснования — в [DESIGN.md](DESIGN.md) (v0.3, веб-статус — §19), рабочая
инструкция на все остальные случаи (упала нода, кластер заморожен, ремонт
пересобранной ноды, обновление ветки) — в [RUNBOOK.md](RUNBOOK.md): каждый
сценарий самодостаточен и написан для ситуации «прошло много времени, никто
ничего не помнит». Работа за корпоративным HTTP(S)-прокси — тем же флагом
`--proxy host:port`, что и в слое 1; межнодовый трафик идёт напрямую
(DESIGN.md §5.1). Тесты: `Alt/ha/tests/run-all.sh` (без root, ничего не
трогает в системе).
