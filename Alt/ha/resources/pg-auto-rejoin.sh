#!/bin/sh
# fusionpbx-ha: automatic rejoin of a stale primary at boot (installed
# copy - rendered values live in the secret-free /etc/fusionpbx-ha/
# boot-guard.conf, shared with the boot guard).
#
# WHY (DESIGN.md changelog 0.3.29): the boot guard (0.3.27) leaves a
# hard-crashed primary SAFELY DOWN until a human runs 'fusionpbx-ha.sh
# --repair' - correct for data safety, but a crash+reboot with no
# operator on site (night/weekend) kept the node out of the cluster
# indefinitely: one live data node, no failover protection, no RPO=0.
# This unit closes that loop UNATTENDED for the one scenario that is
# always safe to automate - this node boots, its own PostgreSQL is down,
# and the peer VERIFIABLY is the live primary, on a higher timeline that
# forked from ours a moment ago:
#
#   gates (all must pass, else REFUSE - see the refuses below):
#     peer agent 200 / peer PG not-in-recovery  (a live primary exists)
#     + local PGDATA is a former primary ("in production"), readable
#     + peer_timeline > local_timeline AND the peer's history forked
#       FROM the local timeline (we hold no history the peer lacks)
#     + the fork-point gap is within budget (the crash's last checkpoint
#       is close to the fork point = the writes the peer never received
#       are negligible; a big gap smells like a partition with async
#       writes on our side and MUST go to a human)
#   -> pg_rewind-rejoin as the peer's standby - exactly what the manual
#      repair's diverged branch does ('node rejoin --force-rewind') -
#      then adopt PostgreSQL under systemd, converge repmgrd/lsyncd and
#      re-enable synchronous replication on the peer.
#
# NEVER automatic: a force-clone (an unattended data wipe is
# unacceptable), a promote, a rejoin past a refused gate, anything on a
# witness (role gate) or a standby (standby.signal gate) or a node that
# is not clustered yet (repmgr.conf gate).
#
# Any refusal or failure leaves the SAFE blocked state of 0.3.27:
# PostgreSQL down, this node's haproxy serving its applications from the
# peer's primary, a loud journal entry; the next boot retries, a human
# can always run --repair. One attempt per boot (no Restart=): a rejoin
# that keeps failing must not loop over the data directory.

CONF="${PG_AUTO_REJOIN_CONF:-/etc/fusionpbx-ha/boot-guard.conf}"
[ -r "$CONF" ] || exit 0
# shellcheck disable=SC1090
. "$CONF"

# partial/legacy conf must never break the boot
: "${BG_PEER_IP:=}" "${BG_PGDATA:=/var/lib/pgsql/data}" "${BG_PG_PORT:=5432}"
: "${BG_AGENT_PORT:=8008}" "${BG_PG_PASSFILE:=/var/lib/pgsql/.pgpass}"
: "${BG_REPMGR_USER:=repmgr}" "${BG_REPMGR_DB:=repmgr}"
: "${BG_REPMGR_CONF_PATH:=/etc/repmgr/repmgr.conf}"
: "${BG_NODE_ROLE:=data}" "${BG_NODE_NAME:=}"
: "${BG_PG_SERVICE:=postgresql}" "${BG_REPMGRD_SERVICE:=repmgr}"
: "${BG_LSYNCD_SERVICE:=lsyncd}"
: "${BG_REJOIN_ATTEMPTS:=45}" "${BG_REJOIN_SLEEP:=2}" "${BG_MAX_GAP_MB:=128}"
: "${BG_REPAIR_FLAG:=/run/fusionpbx-ha/repair-start.flag}"
# 0.3.36: the ROOT-START RESCUE waits (see ar_rescue)
: "${BG_RESCUE_ANSWER_TRIES:=60}" "${BG_RESCUE_ANSWER_SLEEP:=1}"
: "${BG_RESCUE_ATTACH_TRIES:=15}" "${BG_RESCUE_ATTACH_SLEEP:=2}"

log()    { echo "fusionpbx-ha auto-rejoin: $*" >&2; }
refuse() {
    log "REFUSING the automatic rejoin: $*"
    log "PostgreSQL stays down (the SAFE state - the applications work via the peer);"
    log "run 'fusionpbx-ha.sh --repair' when convenient."
    exit 1
}

# nothing-to-do verdicts are SILENT: a healthy node must not pay log noise
[ "$BG_NODE_ROLE" = "data" ] || exit 0
[ -n "$BG_PEER_IP" ] || exit 0
[ -d "$BG_PGDATA" ] || exit 0
[ -f "$BG_PGDATA/standby.signal" ] && exit 0   # a standby boots unconditionally
[ -f "$BG_REPMGR_CONF_PATH" ] || exit 0         # not a clustered node yet

# peer psql as the postgres superuser (root reads the 600 .pgpass - the
# same pattern the boot guard uses for its repmgr@peer probe)
ar_peer_psql() {
    PGPASSFILE="$BG_PG_PASSFILE" psql -h "$BG_PEER_IP" -p "$BG_PG_PORT" \
        -U postgres -d postgres -tAc "$1" 2>/dev/null | tr -d ' \r'
}

# local psql over the unix socket (peer auth as postgres, no password)
ar_local_psql() {
    runuser -u postgres -- psql -tAc "$1" 2>/dev/null | tr -d ' \r'
}

# 0.3.36: an UP/DOWN probe that returns psql's OWN exit code. ar_local_psql
# pipes through tr - the pipeline's exit code is tr's (ALWAYS 0), so a
# DOWN server answers 'up' through it (the rescue's start branch would
# never fire, the triage would call a stopped server 'up'). psql without
# the pipe: connection refused = non-zero = honestly DOWN.
ar_local_pg_up() {
    runuser -u postgres -- psql -tAc "SELECT 1" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# 1) the peer verdict (retried: a simultaneous boot may take the peer's
#    own guard loop ~30s to resolve its own start)
# ---------------------------------------------------------------------------
_ar_go=0
_i=0
while [ "$_i" -lt "$BG_REJOIN_ATTEMPTS" ]; do
    _i=$((_i + 1))
    _code="$(curl --noproxy '*' -s -o /dev/null -w '%{http_code}' \
        --max-time 3 "http://$BG_PEER_IP:$BG_AGENT_PORT/primary" 2>/dev/null || true)"
    if [ "$_code" = "200" ]; then
        _ar_go=1
        break
    fi
    _ir="$(PGPASSFILE="$BG_PG_PASSFILE" psql -h "$BG_PEER_IP" -p "$BG_PG_PORT" \
        -U "$BG_REPMGR_USER" -d "$BG_REPMGR_DB" -tAc \
        "SELECT pg_is_in_recovery()" 2>/dev/null | tr -d ' \r' || true)"
    if [ "$_ir" = "t" ]; then
        # the peer is a standby waiting for its primary - us; the guard
        # allows our start (0.3.27 verdict table)
        exit 0
    fi
    if [ "$_ir" = "f" ]; then
        _ar_go=1
        break
    fi
    # neither answered: the peer is booting / partitioned - keep waiting
    sleep "$BG_REJOIN_SLEEP"
done
[ "$_ar_go" = "1" ] || exit 0
# sole-survivor case is NOT ours to decide: the GUARD's own retry loop
# (15x2s) allows the start when the peer never answers

log "peer $BG_PEER_IP is the live primary - this node is a stale primary, rejoining unattended"

# ---------------------------------------------------------------------------
# 2) local gates
# ---------------------------------------------------------------------------
_ar_ctl="$(LC_ALL=C runuser -u postgres -- pg_controldata -D "$BG_PGDATA" 2>/dev/null || true)"
[ -n "$_ar_ctl" ] \
    || refuse "pg_controldata cannot read $BG_PGDATA (damaged cluster / no PG_VERSION) - manual --repair --force-clone territory"
echo "$_ar_ctl" | grep -q '^Database cluster state: *in production$' \
    || refuse "cluster state is not 'in production' ($(echo "$_ar_ctl" | grep '^Database cluster state:' | sed 's/.*: *//')) - not a former primary, a human must classify it"

_ar_tl_local="$(echo "$_ar_ctl" | grep "^Latest checkpoint's TimeLineID:" | tail -1 | sed 's/.*: *//')"
_ar_local_lsn="$(echo "$_ar_ctl" | grep '^Latest checkpoint location:' | tail -1 | sed 's/.*: *//')"

_ar_tl_peer="$(ar_peer_psql 'SELECT timeline_id FROM pg_control_checkpoint()')"
[ -n "$_ar_tl_peer" ] || refuse "cannot read the peer's checkpoint (timeline)"
_ar_hist="$(ar_peer_psql "SELECT pg_read_file('pg_wal/$(printf '%08X' "$_ar_tl_peer").history')")"
[ -n "$_ar_hist" ] || refuse "the peer's timeline history is unreadable - cannot prove it forked from us"
_ar_line="$(echo "$_ar_hist" | tail -1)"
_ar_parent="$(echo "$_ar_line" | cut -f1)"
_ar_fork="$(echo "$_ar_line" | cut -f2)"
[ "$_ar_parent" = "$_ar_tl_local" ] && [ "$_ar_tl_peer" -gt "$_ar_tl_local" ] 2>/dev/null \
    || refuse "timeline mismatch: local $_ar_tl_local, peer $_ar_tl_peer forked from '$_ar_parent' - this node may hold WAL the peer never had"

# LSN arithmetic (POSIX sh, 64-bit; no command substitution inside
# $(( )) - that is a bashism dash rejects)
ar_lsn_num() {
    _alsn_hi="$(echo "$1" | cut -d/ -f1)"
    _alsn_lo="$(echo "$1" | cut -d/ -f2)"
    echo $(( 0x$_alsn_hi * 4294967296 + 0x$_alsn_lo ))
}
_ar_local_num="$(ar_lsn_num "$_ar_local_lsn")"
# the WAL directory is a better estimate of the true write end than the
# last checkpoint (checkpoint_timeout lag); preallocated segments add a
# little slop - the budget absorbs it
_ar_lastseg="$(ls "$BG_PGDATA/pg_wal" 2>/dev/null | grep -E '^[0-9A-F]{24}$' | sort | tail -1)"
if [ -n "$_ar_lastseg" ]; then
    _ar_seg_log="$(echo "$_ar_lastseg" | cut -c9-16)"
    _ar_seg_seg="$(echo "$_ar_lastseg" | cut -c17-24)"
    _ar_seg_end=$(( ( 0x$_ar_seg_log * 256 + 0x$_ar_seg_seg ) * 16777216 ))
    [ "$_ar_seg_end" -gt "$_ar_local_num" ] && _ar_local_num="$_ar_seg_end"
fi
_ar_fork_num="$(ar_lsn_num "$_ar_fork")"
_ar_gap_kb=$(( ( _ar_local_num - _ar_fork_num ) / 1024 ))
if [ "$_ar_gap_kb" -gt $(( BG_MAX_GAP_MB * 1024 )) ]; then
    refuse "the fork-point gap is ~$((_ar_gap_kb / 1024)) MB (budget ${BG_MAX_GAP_MB} MB) - possible unreplicated writes (a partition with async writes?), a human must decide"
fi
log "gates passed: timelines $_ar_tl_local -> $_ar_tl_peer (fork $_ar_fork), gap ~${_ar_gap_kb} KB (budget ${BG_MAX_GAP_MB} MB)"

# ---------------------------------------------------------------------------
# 3) the rejoin (the manual repair's diverged branch, minus the human)
# ---------------------------------------------------------------------------
# quiet the boot-time restart loop and its rate-limit poison first (the
# same neutralization as ha_pg_start_for_classification, 0.3.28)
systemctl stop "$BG_PG_SERVICE" >/dev/null 2>&1 || true
systemctl reset-failed "$BG_PG_SERVICE" >/dev/null 2>&1 || true

# 0.3.36: the sudo self-heal, INLINED from ha_sudo_heal (this unit is a
# standalone POSIX sh script - it cannot source ha-lib). The 27.10
# forensics: on BOTH data nodes the postgres user could not EXECUTE sudo
# at all ('runuser: невозможно выполнить sudo: Отказано в доступе' =
# EACCES - the ALT 'control sudo' restriction or a mode drift on the
# binary), which made the rejoin's inner 'sudo systemctl start
# postgresql' die with ONLY 'unable to start server' (repmgr swallows
# the reason). Heal it BEFORE the rejoin pays for it:
#   - the ALT 'control' facility to 'public' (survives package updates),
#   - chmod 4755 (setuid root, executable by every user) on every sudo
#     binary found - WHAT postgres may run stays bounded by the sudoers
#     NOPASSWD verbs.
ar_sudo_ok() { runuser -u postgres -- sudo -n -l >/dev/null 2>&1; }
if command -v sudo >/dev/null 2>&1 && command -v id >/dev/null 2>&1 \
        && id postgres >/dev/null 2>&1 && ! ar_sudo_ok; then
    log "sudo AS THE POSTGRES USER FAILED - repmgr's inner 'sudo systemctl start postgresql' dies 'unable to start server' (the reason is swallowed by repmgr); healing"
    if command -v control >/dev/null 2>&1 && control sudo >/dev/null 2>&1; then
        control sudo public >/dev/null 2>&1 \
            && log "ALT control: the sudo facility set to 'public' (was: $(control sudo 2>/dev/null))"
    fi
    for _ar_sbin in $(command -v sudo) /usr/bin/sudo /usr/sbin/sudo /sbin/sudo /bin/sudo /usr/local/bin/sudo; do
        [ -n "$_ar_sbin" ] && [ -f "$_ar_sbin" ] || continue
        _ar_smode="$(stat -c %a "$_ar_sbin" 2>/dev/null || true)"
        [ -n "$_ar_smode" ] || continue
        if [ "$_ar_smode" != "4755" ]; then
            chown root:root "$_ar_sbin" 2>/dev/null || true
            chmod 4755 "$_ar_sbin" 2>/dev/null || true
            log "healed: $_ar_sbin mode $_ar_smode -> 4755 (setuid root; sudoers still bounds what postgres may run)"
        fi
    done
    if ar_sudo_ok; then
        log "sudo as the postgres user: HEALED"
    else
        log "WARNING: the heal did not help - the ROOT-START RESCUE below is the fallback; run 'fusionpbx-ha.sh --repair'"
    fi
fi

ar_rejoin() {
    # TMPDIR=/tmp (0.3.30): the unit's systemd context has no PAM, but a
    # MANUAL run of this script from a root SSH session inherits
    # pam_mktemp's private /tmp/.private/root (0700) - repmgr (as
    # postgres) then fails mkstemp inside it with "unable to open
    # temporary file" and the rejoin dies before pg_rewind even runs
    # (see repmgr_cmd in ha-lib.sh)
    #
    # 0.3.33: the guard flag covers the WHOLE rejoin call - its
    # 'systemctl start' (service_start_command) happens INSIDE repmgr,
    # right after repmgr 5.5.0's create_recovery_file() writes
    # standby.signal (repmgr-action-standby.c:8309 - so the guard's own
    # standby check lets the start through anyway); the window costs
    # nothing and covers any path where the signal file is not (yet)
    # there. /run (tmpfs): a crash cannot leave the guard blinded.
    # printf, not ': >' - a redirection failure on the POSIX special
    # builtin ':' is FATAL for the subshell in dash-family shells (killed
    # ar_rejoin before repmgr ever ran when the flag path was unwritable)
    mkdir -p "$(dirname "$BG_REPAIR_FLAG")" 2>/dev/null || true
    printf '' > "$BG_REPAIR_FLAG" 2>/dev/null || true
    TMPDIR=/tmp runuser -u postgres -- repmgr -f "$BG_REPMGR_CONF_PATH" \
        node rejoin --force-rewind -h "$BG_PEER_IP" \
        -U "$BG_REPMGR_USER" -d "$BG_REPMGR_DB" 2>&1
    _arrc=$?
    rm -f "$BG_REPAIR_FLAG" 2>/dev/null || true
    return "$_arrc"
}

# 0.3.36: the ROOT-START RESCUE (inlined from ha_rejoin_rescue). A
# 'node rejoin' can die AFTER its data work is complete - the 27.10
# 14:0x bench: pg_rewind done, standby.signal + primary_conninfo
# written, then the inner 'sudo systemctl start' failed (the exec-level
# sudo breakage) and the NODE REJOIN failed with the record unrefreshed
# -> the zombie standby (repmgr.service's Wants=postgresql pulled a
# start 8s later, the WAL receiver never attached, repmgrd crash-looped
# on the stale 'primary' record). THIS UNIT RUNS AS ROOT: finish the
# start ourselves and prove the result by the WAL receiver.
#   rc 0 = the server answers AND its WAL receiver is attached to the
#          peer (the caller then refreshes the record - ar_register)
ar_rescue() {
    if ! ar_local_pg_up; then
        # no standby.signal = the rejoin died before its data work - a
        # root start would boot the STALE PRIMARY the boot guard exists
        # to stop (never rescue without the marker)
        [ -f "$BG_PGDATA/standby.signal" ] || return 1
        log "rescue: the rejoin's data work is done (standby.signal present) but its inner"
        log "rescue: start failed - starting PostgreSQL as root (this unit)"
        systemctl reset-failed "$BG_PG_SERVICE" >/dev/null 2>&1 || true
        systemctl start "$BG_PG_SERVICE" \
            || { log "rescue: PostgreSQL did not start"; return 1; }
        _i=0
        while [ "$_i" -lt "$BG_RESCUE_ANSWER_TRIES" ]; do
            ar_local_pg_up && break
            sleep "$BG_RESCUE_ANSWER_SLEEP"
            _i=$((_i + 1))
        done
        ar_local_pg_up \
            || { log "rescue: PostgreSQL is not answering"; return 1; }
    fi
    _i=0
    while [ "$_i" -lt "$BG_RESCUE_ATTACH_TRIES" ]; do
        [ "$(ar_local_psql "SELECT sender_host FROM pg_stat_wal_receiver")" = "$BG_PEER_IP" ] && return 0
        sleep "$BG_RESCUE_ATTACH_SLEEP"
        _i=$((_i + 1))
    done
    log "rescue: the WAL receiver never attached to $BG_PEER_IP (the zombie-standby shape)"
    return 1
}

# 0.3.36: a rescued rejoin never reached repmgr's own registration -
# the peer's record still says 'primary' and repmgrd would crash-loop
# on it ('node is registered as a primary but running as a standby').
# 'standby register --force' on an ATTACHED standby is a metadata write
# on the peer - it does not interrupt the replication (exactly the
# manual repair's 'attached' path).
ar_register() {
    _ar_upid="$(ar_peer_psql "SELECT node_id FROM repmgr.nodes WHERE type='primary'")"
    if [ -n "$_ar_upid" ]; then
        TMPDIR=/tmp runuser -u postgres -- repmgr -f "$BG_REPMGR_CONF_PATH" \
            standby register --upstream-node-id="$_ar_upid" --force 2>&1 \
            || { log "RESCUED, BUT THE REGISTER FAILED - run 'fusionpbx-ha.sh --repair' (the attached path finishes it)"; exit 1; }
    else
        TMPDIR=/tmp runuser -u postgres -- repmgr -f "$BG_REPMGR_CONF_PATH" \
            standby register --force 2>&1 \
            || { log "RESCUED, BUT THE REGISTER FAILED - run 'fusionpbx-ha.sh --repair' (the attached path finishes it)"; exit 1; }
    fi
    log "record refreshed: this node is a standby of $BG_PEER_IP (standby register --force)"
}

log "rejoining as a standby of $BG_PEER_IP (pg_rewind; this can take minutes)"
_ar_out="$(ar_rejoin)"
_ar_rc=$?
echo "$_ar_out" >&2
_ar_rescued=0
if [ "$_ar_rc" -ne 0 ]; then
    # 0.3.30 closed the "unable to open temporary file" case (that was
    # repmgr's own local_command mkstemp inside a pam_mktemp-poisoned
    # TMPDIR - pg_rewind never even ran). What fails now is a REAL
    # pg_rewind failure: capture the verbose standalone rewind while the
    # state is still reproducible - the journal gets the debug repmgr
    # never shows
    # 0.3.31: pg_rewind has no '-v' option - the old debug capture died
    # "invalid option -- v" and captured nothing (26.10: the journal held
    # no rewind detail at all); --debug alone prints the real trace
    log "rejoin failed (output above) - capturing 'pg_rewind --debug' for the journal"
    runuser -u postgres -- pg_rewind -D "$BG_PGDATA" \
        --source-server="host=$BG_PEER_IP port=$BG_PG_PORT user=$BG_REPMGR_USER dbname=$BG_REPMGR_DB" \
        --debug 2>&1 || true
    # 0.3.36: THE ROOT-START RESCUE comes BEFORE the retry - the 27.10
    # shape was a start-step failure (sudo) over COMPLETE data work, and
    # re-running pg_rewind over a finished rewind only deepened the
    # WAL-limbo (the second pass ran over the already-rewound pg_control
    # and the node ended up requesting a timeline-6 WAL position that
    # never existed). Rescue first; the rejoin retry stays for REAL
    # rewind failures (pg_rewind is re-runnable).
    if ar_rescue; then
        _ar_rescued=1
        log "rescue: PostgreSQL is up and attached to the peer - the rejoin's data work is complete"
    else
        log "retrying the rejoin once (pg_rewind is re-runnable)"
        # 0.3.33: the first attempt may have crash-looped PostgreSQL against
        # a poisoned data dir and tripped systemd's start-rate limiter - clear
        # it, or the retry's inner 'systemctl start' is refused with
        # "Start request repeated too quickly" before postgres even runs
        systemctl reset-failed "$BG_PG_SERVICE" >/dev/null 2>&1 || true
        _ar_out="$(ar_rejoin)"
        _ar_rc=$?
        echo "$_ar_out" >&2
        if [ "$_ar_rc" -ne 0 ]; then
            if ar_rescue; then
                _ar_rescued=1
                log "rescue: PostgreSQL is up and attached to the peer - the rejoin's data work is complete"
            else
                log "REJOIN FAILED"
                # 0.3.33: repmgr swallows the failed start's output (only "unable
                # to start server"); the journal holds the real reason - keep the
                # last 40 lines next to the pg_rewind --debug capture above
                journalctl -u "$BG_PG_SERVICE" --no-pager -n 40 2>/dev/null \
                    | sed -e 's/^/  /' -e 's/password=[^ ]*/password=***/g' >&2 || true
                # 0.3.35: the rejoin may have failed AFTER repmgr had already
                # started the server (the 27.10 14:0x boot: pg_rewind done,
                # PostgreSQL up as a standby on the new timeline - but the WAL
                # receiver never attached, the metadata record still said
                # 'primary', repmgrd crash-looped 'node is registered as a primary
                # but running as a standby', and the startup process kept
                # replaying the node's OWN divergent WAL tail onto the rewound
                # files). "PostgreSQL stays down" was a lie for this path. Tell
                # the two leftovers apart by the WAL receiver (0.3.36: the
                # up/down verdict now uses ar_local_pg_up - psql's own exit
                # code, not the tr-masked pipeline that called every server
                # 'up'):
                if ar_local_pg_up; then
                    if [ "$(ar_local_psql "SELECT sender_host FROM pg_stat_wal_receiver")" = "$BG_PEER_IP" ]; then
                        log "PostgreSQL IS up and streaming from the peer (catchup) - the rejoin"
                        log "failed at a later stage (the metadata record may be stale). Do NOT"
                        log "reboot it: run 'fusionpbx-ha.sh --repair' - the attached path"
                        log "refreshes the record without interrupting the replication."
                    else
                        log "PostgreSQL is up but NOT attached to the peer (the zombie standby:"
                        log "stale 'primary' record, no streaming, own-divergent-WAL replay) -"
                        log "stopping it: the SAFE state (the applications work via the peer)"
                        systemctl stop "$BG_PG_SERVICE" >/dev/null 2>&1 || true
                        systemctl stop "$BG_REPMGRD_SERVICE" >/dev/null 2>&1 || true
                        log "PostgreSQL and repmgrd stopped; run 'fusionpbx-ha.sh --repair'"
                        log "(the next boot retries the rejoin automatically)"
                    fi
                else
                    log "PostgreSQL stays down (the SAFE state); run 'fusionpbx-ha.sh --repair'"
                fi
                exit 1
            fi
        fi
    fi
fi

# 0.3.36: refresh the record after ANY rescued path - a failed rejoin
# never reaches repmgr's own registration, and repmgrd refuses to start
# on the stale 'primary' record ('node is registered as a primary but
# running as a standby'). A successful rejoin (rc=0) registered itself.
if [ "$_ar_rescued" = "1" ]; then
    ar_register
fi

# ---------------------------------------------------------------------------
# 4) adopt under systemd (repmgr may have started PostgreSQL via pg_ctl,
#    outside systemd - mirrors the manual repair's ha_pg_adopt_after_rejoin)
# ---------------------------------------------------------------------------
if ! ar_local_psql "SELECT 1" >/dev/null 2>&1; then
    systemctl reset-failed "$BG_PG_SERVICE" >/dev/null 2>&1 || true
    systemctl start "$BG_PG_SERVICE" \
        || { log "PostgreSQL did not start after the rejoin; run --repair"; exit 1; }
else
    if [ "$(systemctl is-active "$BG_PG_SERVICE" 2>/dev/null)" != "active" ]; then
        log "PostgreSQL was started outside systemd (by repmgr) - moving it back under systemd"
        runuser -u postgres -- pg_ctl -D "$BG_PGDATA" stop -m fast -w -t 300 >/dev/null 2>&1
        systemctl reset-failed "$BG_PG_SERVICE" >/dev/null 2>&1 || true
        systemctl start "$BG_PG_SERVICE" \
            || { log "PostgreSQL did not start under systemd; run --repair"; exit 1; }
    fi
fi
_ar_try=0
while [ "$_ar_try" -lt 60 ]; do
    ar_local_psql "SELECT 1" >/dev/null 2>&1 && break
    sleep 1
    _ar_try=$((_ar_try + 1))
done
[ "$_ar_try" -lt 60 ] || { log "PostgreSQL is not answering after the rejoin; run --repair"; exit 1; }

_ir="$(ar_local_psql "SELECT pg_is_in_recovery()")"
if [ "$_ir" != "t" ]; then
    # must never happen after a successful rejoin - if it does, return to
    # the safe state immediately instead of running a rogue primary
    log "local PostgreSQL is NOT in recovery after the rejoin - stopping it and refusing"
    systemctl stop "$BG_PG_SERVICE" >/dev/null 2>&1 || true
    exit 1
fi

# converge the daemons (their boot instances were restart-looping while
# the local database was down)
systemctl restart "$BG_REPMGRD_SERVICE" >/dev/null 2>&1 || true
systemctl restart "$BG_LSYNCD_SERVICE" >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# 5) synchronous replication back ON (the same verify-then-set order as
#    ha_ensure_sync: setting the name before we stream would freeze every
#    commit on the peer - the very disease 0.3.26/0.3.27 fought)
# ---------------------------------------------------------------------------
if [ -n "$BG_NODE_NAME" ]; then
    _ar_streaming=""
    _ar_try=0
    while [ "$_ar_try" -lt 15 ]; do
        _ar_streaming="$(ar_peer_psql "SELECT state FROM pg_stat_replication WHERE application_name='$BG_NODE_NAME'")"
        [ "$_ar_streaming" = "streaming" ] && break
        sleep 2
        _ar_try=$((_ar_try + 1))
    done
    if [ "$_ar_streaming" = "streaming" ]; then
        ar_peer_psql "ALTER SYSTEM SET synchronous_standby_names TO '\"$BG_NODE_NAME\"'" >/dev/null
        ar_peer_psql "SELECT pg_reload_conf()" >/dev/null
        _ar_sync=""
        _ar_try=0
        while [ "$_ar_try" -lt 8 ]; do
            _ar_sync="$(ar_peer_psql "SELECT sync_state FROM pg_stat_replication WHERE application_name='$BG_NODE_NAME' AND state='streaming'")"
            [ "$_ar_sync" = "sync" ] && break
            sleep 2
            _ar_try=$((_ar_try + 1))
        done
        if [ "$_ar_sync" = "sync" ]; then
            log "synchronous replication re-enabled on the peer (RPO = 0)"
        else
            log "WARNING: sync_state is '$_ar_sync' on the peer - the node is back but RPO > 0; run --doctor on the peer"
        fi
    else
        log "WARNING: this node is not visible as a streaming standby on the peer yet (application_name='$BG_NODE_NAME') - the node is back, run --doctor on the peer"
    fi
else
    log "WARNING: BG_NODE_NAME is unknown - synchronous mode not re-enabled; run --repair"
fi

log "AUTO-REJOIN COMPLETE: $BG_NODE_NAME is a standby of $BG_PEER_IP (timeline $_ar_tl_peer)"

# 0.3.41: refresh the web status snapshot AT ONCE - the rejoined node's
# widget must flip to standby/streaming immediately, not at the next cron
# tick (the PEER's snapshot updates at its own tick - there is no root SSH
# between the nodes by design, and the sync re-enable above already told
# the peer everything). Runs as root (this unit) with no sudo needed.
if [ -n "${BG_STATUS_SCRIPT:-}" ] && [ -x "$BG_STATUS_SCRIPT" ]; then
    "$BG_STATUS_SCRIPT" --write-status >/dev/null 2>&1 \
        || log "WARNING: could not refresh the web status snapshot - the cron will"
fi
exit 0
