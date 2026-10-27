#!/bin/sh
# fusionpbx-ha: PostgreSQL boot guard (installed copy - rendered values
# live in the secret-free /etc/fusionpbx-ha/boot-guard.conf).
#
# WHY (DESIGN.md changelog 0.3.27): a hard power-off of the PRIMARY leaves
# no standby.signal in its PGDATA, so on the next boot PostgreSQL comes up
# as a COMPETING primary (the 22.10 bench: the node returned from a power
# cut, both role agents honestly said PRIMARY, split-brain, witness
# metadata diverged, writes on the stale side frozen by a leftover
# synchronous_standby_names). repmgr deliberately never demotes an old
# primary - the only safe gate is BEFORE the postmaster starts.
#
# Installed as 'ExecStartPre=+' for postgresql.service on the DATA nodes
# (the '+' prefix runs it as root: the rendered conf is 644 and the peer
# probe authenticates via the postgres user's .pgpass - repmgr@peer line).
#
# Verdicts:
#   allow (exit 0):
#     - PGDATA missing / standby.signal present (a standby can never write)
#     - /etc/repmgr/repmgr.conf missing  (node not clustered yet - first
#       init pays no probe delay at all)
#     - peer PostgreSQL is in recovery   (a standby is waiting for its
#       primary - us; it reconnects and streams the moment we start)
#     - peer unreachable for the whole retry loop (sole survivor: start,
#       loudly - and the peer's OWN guard stops IT from competing when it
#       returns; a simultaneous boot resolves into t/200 within seconds)
#   block (exit 1 - PostgreSQL stays down until 'fusionpbx-ha.sh --repair'):
#     - peer role agent answers 200 /primary  (a live primary exists)
#     - peer PostgreSQL answers pg_is_in_recovery()=f (agent broken/silent)
#
# Never blocks a promote (no systemd start involved), a standby boot, a
# repair rejoin (repmgr 5.5.0 create_recovery_file() writes standby.signal
# BEFORE the rejoin's systemctl start - repmgr-action-standby.c:8309; and
# since 0.3.33 the repair/auto-rejoin hold this flag across the whole
# 'node rejoin' call anyway, belt over that ordering) or a fresh
# init (no repmgr.conf yet). A blocked boot is SAFE: the local haproxy
# routes the applications to the surviving primary via its agent check.

CONF="${PG_BOOT_GUARD_CONF:-/etc/fusionpbx-ha/boot-guard.conf}"
[ -r "$CONF" ] || exit 0
# shellcheck disable=SC1090
. "$CONF"

# partial/legacy conf must never brick the boot
: "${BG_PEER_IP:=}" "${BG_PGDATA:=/var/lib/pgsql/data}" "${BG_PG_PORT:=5432}"
: "${BG_AGENT_PORT:=8008}" "${BG_ATTEMPTS:=15}" "${BG_SLEEP:=2}"
: "${BG_PG_PASSFILE:=/var/lib/pgsql/.pgpass}" "${BG_REPMGR_USER:=repmgr}"
: "${BG_REPMGR_DB:=repmgr}" "${BG_REPMGR_CONF_PATH:=/etc/repmgr/repmgr.conf}"
: "${BG_REPAIR_FLAG:=/run/fusionpbx-ha/repair-start.flag}"

log() { echo "fusionpbx-ha boot-guard: $*" >&2; }

[ -n "$BG_PEER_IP" ] || exit 0
[ -d "$BG_PGDATA" ] || exit 0
# 0.3.28: an operator-driven repair may legitimately start a stale primary
# FOR A MOMENT - its step-3 classifier needs a RUNNING database to tell an
# 'attached standby' from a 'diverged' node, and the guard used to block
# exactly that start (the 26.10 bench: the repair died 'local PostgreSQL
# does not start' with the guard refusing the repair's OWN systemctl call).
# The repair marks the window with this flag; it lives under /run (tmpfs,
# gone at reboot - every boot is guarded) and is removed the moment the
# start attempt returned.
# 0.3.33: the window was widened - the repair and the auto-rejoin now hold
# the flag across the WHOLE 'repmgr node rejoin' call (its inner
# service_start_command start included), because repmgr discards the
# start's output on failure and a guard refusal there is otherwise
# invisible (the 27.10 bench: 'unable to start server' with nothing else).
[ -f "$BG_REPAIR_FLAG" ] && exit 0
[ -f "$BG_PGDATA/standby.signal" ] && exit 0
[ -f "$BG_REPMGR_CONF_PATH" ] || exit 0    # not a clustered node yet

_i=0
while [ "$_i" -lt "$BG_ATTEMPTS" ]; do
    _i=$((_i + 1))

    # 1) peer role agent: 200 = the peer IS the live primary
    _code="$(curl --noproxy '*' -s -o /dev/null -w '%{http_code}' \
        --max-time 3 "http://$BG_PEER_IP:$BG_AGENT_PORT/primary" 2>/dev/null || true)"
    if [ "$_code" = "200" ]; then
        log "peer $BG_PEER_IP is the current primary (role agent 200) -"
        log "refusing to start a competing primary. Run 'fusionpbx-ha.sh --repair'"
        log "on this node to rejoin it as a standby."
        exit 1
    fi

    # 2) peer PostgreSQL directly (covers a broken or silent agent):
    #    in recovery = a standby waiting for its primary (us) -> ALLOW
    #    not in recovery = a live primary                    -> BLOCK
    _ir="$(PGPASSFILE="$BG_PG_PASSFILE" psql -h "$BG_PEER_IP" -p "$BG_PG_PORT" \
        -U "$BG_REPMGR_USER" -d "$BG_REPMGR_DB" -tAc \
        "SELECT pg_is_in_recovery()" 2>/dev/null | tr -d ' \r' || true)"
    if [ "$_ir" = "t" ]; then
        log "peer $BG_PEER_IP is a standby in recovery - starting as its primary"
        exit 0
    fi
    if [ "$_ir" = "f" ]; then
        log "peer $BG_PEER_IP PostgreSQL is NOT in recovery (it is the primary) -"
        log "refusing to start a competing primary. Run 'fusionpbx-ha.sh --repair'"
        log "on this node to rejoin it as a standby."
        exit 1
    fi

    # neither probe answered: the peer is booting / restarting PostgreSQL -
    # keep waiting, a simultaneous boot resolves into a definitive verdict
    sleep "$BG_SLEEP"
done

log "peer $BG_PEER_IP did not answer within $((BG_ATTEMPTS * BG_SLEEP))s -"
log "starting as the sole node. If the peer is alive but partitioned, stop"
log "PostgreSQL on this node and run 'fusionpbx-ha.sh --repair' instead."
exit 0
