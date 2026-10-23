#!/bin/bash
# =============================================================================
# Unit tests for Alt/ha/resources/ha-lib.sh (the fusionpbx-ha core library)
#
# Runs entirely in a sandbox: HA_ETC_DIR / HA_PGDATA_DEFAULT / HA_RRSYNC_*
# point to a temp directory, ssh-keygen and ip are stubbed - nothing touches
# the real /etc. Style: layer-1 scripts/test_guard.sh
# =============================================================================
set -u

REPO="$(cd "$(dirname "$0")/../../.." && pwd)"
LIB="$REPO/Alt/ha/resources/ha-lib.sh"
RES="$REPO/Alt/ha/resources"
CLI="$REPO/Alt/ha/fusionpbx-ha.sh"
WORK=$(mktemp -d /tmp/ha-lib-test.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/fakebin" "$WORK/etc" "$WORK/pgdata" "$WORK/localbin"
echo "16" > "$WORK/pgdata/PG_VERSION"

# stub ssh-keygen: creates the key pair files with fake content
cat > "$WORK/fakebin/ssh-keygen" <<'EOF'
#!/bin/sh
_key=""
while [ $# -gt 0 ]; do
    case "$1" in
        -f) _key="$2"; shift 2 ;;
        *) shift ;;
    esac
done
[ -n "$_key" ] || exit 1
echo "FAKE-PRIVATE-KEY-CONTENT" > "$_key"
echo "ssh-ed25519 AAAAFAKEPUBLICKEY fusionpbx-ha-sync" > "${_key}.pub"
exit 0
EOF

# stub ip: reports the node-1 address (for own_ips / ha_detect_role)
cat > "$WORK/fakebin/ip" <<'EOF'
#!/bin/sh
echo "2: eth0    inet 10.0.0.11/24 brd 10.0.0.255 scope global eth0"
EOF
chmod +x "$WORK/fakebin/ssh-keygen" "$WORK/fakebin/ip"

# stub psql (schema-grant tests): query-aware answers; calls WITHOUT -c/-tAc/-f
# carry the SQL on STDIN (0.3.4: cross-user-safe feeding) - each such call is
# captured to $HA_TEST_CAPTURE for content assertions
# (PSQL_F_RC: failure exit code + stderr line for the stdin calls only)
cat > "$WORK/fakebin/psql" <<'EOF'
#!/bin/sh
_orig="$*"
_q=""; _f=""
while [ $# -gt 0 ]; do
    case "$1" in
        -tAc|-c) _q="$2"; shift 2 ;;
        -f) _f="$2"; shift 2 ;;
        *) shift ;;
    esac
done
if [ -z "$_q" ] && [ -z "$_f" ]; then
    _cap="${HA_TEST_CAPTURE:-}"
    if [ -n "$_cap" ] && [ -d "$_cap" ]; then
        _n=0
        [ -f "$_cap/count" ] && _n=$(cat "$_cap/count" 2>/dev/null)
        _n=$((_n + 1))
        echo "$_n" > "$_cap/count"
        cat > "$_cap/$_n.sql"
        printf '%s\n' "$_orig" > "$_cap/$_n.args"
    fi
    if [ "${PSQL_F_RC:-0}" != "0" ]; then
        echo "psql:<stdin>:7: ERROR:  stub-injected failure" >&2
        exit "${PSQL_F_RC}"
    fi
    exit 0
fi
case "$_q" in
    *pg_is_in_recovery*) echo "${FIX_RECOVERY-f}" ;;
    # 0.3.22: WAL-receiver probe of the repair-rejoin classifier
    # (sender_host; empty = no receiver row)
    *pg_stat_wal_receiver*) echo "${PSQL_WAL_SENDER:-}" ;;
    *pg_extension*) echo "${FIX_EXT:-1}" ;;
    *listen_addresses*) echo "${FIX_LISTEN:-*}" ;;
    *"ALTER SYSTEM SET synchronous_standby_names"*)
        # regression 0.3.9: inject a server-side refusal (stderr must end
        # up quoted in the die message, never swallowed);
        # regression 0.3.10: PSQL_ALTER_SYNC_LOG records the SQL for
        # quoting assertions (the hyphenated name must be double-quoted)
        if [ -n "${PSQL_ALTER_SYNC_LOG:-}" ]; then
            printf '%s\n' "$_q" >> "$PSQL_ALTER_SYNC_LOG"
        fi
        if [ "${PSQL_ALTER_SYNC_RC:-0}" != "0" ]; then
            echo "psql: ERROR:  stub-injected ALTER SYSTEM failure" >&2
            exit "${PSQL_ALTER_SYNC_RC}"
        fi
        exit 0 ;;
    *"SHOW synchronous_standby_names"*)
        # stateful (0.3.17, the preload-stub precedent): once an
        # ALTER SYSTEM SET synchronous_standby_names is logged
        # (PSQL_ALTER_SYNC_LOG), SHOW reports THAT value - the reload
        # applied it; lets ha_clear_stale_sync_names verify its own clear
        if [ -s "${PSQL_ALTER_SYNC_LOG:-/dev/null}" ]; then
            sed -n "s/^ALTER SYSTEM SET synchronous_standby_names = '\(.*\)';$/\1/p" \
                "$PSQL_ALTER_SYNC_LOG" | tail -n 1
        else
            echo "${PSQL_SYNCNAMES:-}"
        fi ;;
    # 0.3.15: repmgrd shared memory preload knobs ('-' not ':-' so a test
    # can inject an EMPTY value - an unset var still gets the healthy
    # default 'repmgr'). Stateful for ha_ensure_repmgr_preload: once an
    # ALTER is logged, SHOW reports the merged value (0.3.16 - the
    # "restart" applied it)
    *"SHOW shared_preload_libraries"*)
        if [ -s "${PSQL_ALTER_PRELOAD_LOG:-/dev/null}" ]; then
            echo "${PSQL_ALTER_VALUE:-repmgr}"
        else
            echo "${PSQL_PRELOAD-repmgr}"
        fi ;;
    *"ALTER SYSTEM SET shared_preload_libraries"*)
        # PSQL_ALTER_PRELOAD_LOG records the SQL for value assertions,
        # PSQL_ALTER_PRELOAD_RC injects a server-side refusal
        if [ -n "${PSQL_ALTER_PRELOAD_LOG:-}" ]; then
            printf '%s\n' "$_q" >> "$PSQL_ALTER_PRELOAD_LOG"
        fi
        if [ "${PSQL_ALTER_PRELOAD_RC:-0}" != "0" ]; then
            echo "psql: ERROR:  stub-injected preload ALTER failure" >&2
            exit "${PSQL_ALTER_PRELOAD_RC}"
        fi
        exit 0 ;;
    *"SELECT application_name FROM pg_stat_replication"*) echo "${PSQL_APPNAME:-}" ;;
    *"SELECT sync_state FROM pg_stat_replication"*) echo "${PSQL_SYNCSTATE:-sync}" ;;
    *"SELECT 1"*) echo 1 ;;
    *) : ;;
esac
exit 0
EOF

# stub runuser: strip "-u user" / "--" and exec (keeps psql in the sandbox)
cat > "$WORK/fakebin/runuser" <<'EOF'
#!/bin/sh
[ "$1" = "-u" ] && shift 2
[ "$1" = "--" ] && shift
exec "$@"
EOF

# stub systemctl: everything succeeds (register prelude reload paths).
# SELECTIVE (0.3.6 cluster-firewall tests): is-active firewalld honors
# FIREWALLD_ACTIVE (default 1 = inactive), is-enabled honors
# SYSTEMCTL_IS_ENABLED_RC (default 0 = enabled) - everything else stays 0
cat > "$WORK/fakebin/systemctl" <<'EOF'
#!/bin/sh
case "$*" in
    *firewalld*) exit "${FIREWALLD_ACTIVE:-1}" ;;
    is-enabled*) exit "${SYSTEMCTL_IS_ENABLED_RC:-0}" ;;
    # 0.3.22: is-active postgresql honors SYSTEMCTL_PG_ACTIVE (default 0 =
    # active) - lets the rejoin-adoption test simulate a PG started by
    # repmgr OUTSIDE systemd (unit inactive while postgres answers)
    is-active*postgresql*) exit "${SYSTEMCTL_PG_ACTIVE:-0}" ;;
    *) exit 0 ;;
esac
EOF

# stub curl (agent-wait tests): AGENT_CURL_FAIL=1 -> every call fails
# (exit 1, no output - like curl without -w output); otherwise the first
# AGENT_FAIL_FIRST calls fail (counted via $AGENT_CALLS_FILE), then
# AGENT_CODE (default 200) is printed - like '-w %{http_code}'
cat > "$WORK/fakebin/curl" <<'EOF'
#!/bin/sh
if [ "${AGENT_CURL_FAIL:-0}" = "1" ]; then
    exit 1
fi
_cf="${AGENT_CALLS_FILE:-}"
if [ -n "$_cf" ]; then
    _n="$(cat "$_cf" 2>/dev/null || echo 0)"
    _n=$((_n + 1))
    echo "$_n" > "$_cf"
    [ "$_n" -le "${AGENT_FAIL_FIRST:-0}" ] && exit 1
fi
printf '%s' "${AGENT_CODE:-200}"
EOF

chmod +x "$WORK/fakebin/psql" "$WORK/fakebin/runuser" "$WORK/fakebin/systemctl" "$WORK/fakebin/curl"

# stub rsync (0.3.23): every call is counted in $RSYNC_CALLS_FILE, its full
# command line appended to $RSYNC_ARGS_FILE; the first RSYNC_FAIL_FIRST
# calls exit 13 printing $RSYNC_OUT on stderr - emulates the peer-side
# rrsync lock refusal relayed over ssh ("errors with program diagnostics")
cat > "$WORK/fakebin/rsync" <<'EOF'
#!/bin/sh
_n=0
if [ -n "${RSYNC_CALLS_FILE:-}" ]; then
    _n="$(cat "$RSYNC_CALLS_FILE" 2>/dev/null || echo 0)"
    _n=$((_n + 1))
    echo "$_n" > "$RSYNC_CALLS_FILE"
fi
[ -n "${RSYNC_ARGS_FILE:-}" ] && printf '%s\n' "$*" >> "$RSYNC_ARGS_FILE"
if [ -n "${RSYNC_CALLS_FILE:-}" ] && [ "$_n" -le "${RSYNC_FAIL_FIRST:-0}" ]; then
    [ -n "${RSYNC_OUT:-}" ] && printf '%s\n' "$RSYNC_OUT" >&2
    exit 13
fi
exit 0
EOF
chmod +x "$WORK/fakebin/rsync"

# stubs sudo + visudo (0.3.24): present so ha_install_sudoers renders its
# drop-in even on hosts without the real sudo; visudo accepts anything
cat > "$WORK/fakebin/sudo" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$WORK/fakebin/visudo" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$WORK/fakebin/sudo" "$WORK/fakebin/visudo"

# stub pg_isready (0.3.6): PG_ISREADY_RC + PG_ISREADY_OUT control the
# verdict; without PG_ISREADY_OUT the stub answers like the real tool
# ("... - accepting connections" / "... - no response")
cat > "$WORK/fakebin/pg_isready" <<'EOF'
#!/bin/sh
if [ "${PG_ISREADY_SILENT:-0}" = "1" ]; then
    exit "${PG_ISREADY_RC:-0}"
fi
if [ -n "${PG_ISREADY_OUT:-}" ]; then
    echo "$PG_ISREADY_OUT"
else
    case "${PG_ISREADY_RC:-0}" in
        0) echo "$* - accepting connections" ;;
        *) echo "$* - no response" ;;
    esac
fi
exit "${PG_ISREADY_RC:-0}"
EOF

# stub iptables (0.3.6): rules live in $IPT_STATE (one normalized spec per
# line), EVERY invocation is appended to $IPT_LOG; -C checks membership,
# -I/-A append. iptables-save (separate stub) dumps the state file -
# that is exactly the surface ha_ensure_cluster_firewall touches
cat > "$WORK/fakebin/iptables" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${IPT_LOG:?}"
case "$1" in
    -C)
        shift
        [ "${1:-}" = "INPUT" ] && shift
        grep -qxF -- "$*" "${IPT_STATE:?}" 2>/dev/null && exit 0
        exit 1
        ;;
    -I|-A)
        shift
        [ "${1:-}" = "INPUT" ] && shift
        case "${1:-}" in
            "" | *[!0-9]*) : ;;
            *) shift ;;
        esac
        printf '%s\n' "$*" >> "${IPT_STATE:?}"
        exit 0
        ;;
    *)  exit 0 ;;
esac
EOF

cat > "$WORK/fakebin/iptables-save" <<'EOF'
#!/bin/sh
cat "${IPT_STATE:?}" 2>/dev/null
exit 0
EOF

chmod +x "$WORK/fakebin/pg_isready" "$WORK/fakebin/iptables" "$WORK/fakebin/iptables-save"

PASS=0
FAIL=0

report() {
    if [ "$2" = "0" ] || [ "$2" = "ok" ]; then
        PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"
    else
        FAIL=$((FAIL + 1)); printf 'FAIL  %s   %s\n' "$1" "${3:-}"
    fi
}

# Run a snippet with the library sourced into the SAME shell (functions and
# variables available to the snippet). Output -> $OUT, exit code -> $?
lib_run() {
    OUT=$( 
        {
            export HA_ETC_DIR="$WORK/etc" \
                   HA_SANDBOX=1 \
                   HA_RES_DIR="$RES" \
                   HA_PGDATA_DEFAULT="$WORK/pgdata" \
                   HA_RRSYNC_GLOB="$WORK/doc/rsync-*/support/rrsync" \
                   HA_RRSYNC_INSTALL_DIR="$WORK/localbin" \
                   HA_NO_COLOR=1 \
                   PATH="$WORK/fakebin:$PATH"
            # shellcheck disable=SC1090
            . "$LIB"
            eval "$1"
        } 2>&1 )
    return $?
}

# ---------------------------------------------------------------------------
echo "== random_password =="
lib_run 'p=$(random_password 24); echo "$p"'
_p="$OUT"
[ "${#_p}" = "24" ] && echo "$_p" | grep -qE '^[A-Za-z0-9]+$'
report "length 24, charset [A-Za-z0-9]" $?

lib_run 'p=$(random_password 32); echo "${#p}"'
[ "$OUT" = "32" ]; report "custom length 32" $?

# ---------------------------------------------------------------------------
echo "== valid_ip =="
lib_run 'valid_ip 10.0.0.11 && echo ok'
[ "$OUT" = "ok" ]; report "10.0.0.11 valid" $?
lib_run 'valid_ip 10.0.0.256 || echo bad'
[ "$OUT" = "bad" ]; report "10.0.0.256 rejected" $?
lib_run 'valid_ip not-an-ip || echo bad'
[ "$OUT" = "bad" ]; report "hostname rejected" $?
lib_run 'valid_ip 999.1.1.1 || echo bad'
[ "$OUT" = "bad" ]; report "999.1.1.1 rejected" $?

# ---------------------------------------------------------------------------
echo "== confirm (regression 0.3.8: unbound \$2 under set -u) =="
# the real bench: join step 4 died with 'ha-lib.sh: line 121: $2: unbound
# variable' - every call site passes ONE argument; the default-answer
# feature had never been exercised until the first destructive prompt
printf '' | lib_run 'confirm "Type YES:"'
_cf_rc=$?
if [ "$_cf_rc" != 0 ] && ! printf '%s' "$OUT" | grep -q unbound; then _cu=ok; else _cu=bad; fi
report "1-arg call survives set -u; bare Enter declines" "$_cu" "$OUT (rc=$_cf_rc)"

printf 'yes\n' | lib_run 'confirm "Type YES:"'
report "typed yes accepts" $?
printf 'no\n' | lib_run 'confirm "Type YES:"'
[ $? != 0 ]; report "typed no declines" $?
printf '\n' | lib_run 'confirm "Continue?:" y'
report "bare Enter honors the explicit default (y)" $?
lib_run 'HA_AUTO_YES=1 confirm "Type YES:"'
report "--yes auto-accepts" $?
echo "$OUT" | grep -q "assumed YES (--yes)"
report "--yes prints the assumption" $?

# ---------------------------------------------------------------------------
echo "== init node waits (HA_WAIT_NODES, 0.3.8) =="
# source contract: both node waits honor the env override instead of a
# hardcoded 900s (a slow bench exports the variable, not a local edit
# that would collide with git pull)
_w11="$(sed -n '/^init_step_11_wait_witness()/,/^}/p' "$CLI")"
echo "$_w11" | grep -q 'HA_WAIT_NODES:-900'
report "wait witness: HA_WAIT_NODES overrides the 900s default" $?
_w12="$(sed -n '/^init_step_12_wait_standby()/,/^}/p' "$CLI")"
echo "$_w12" | grep -q 'HA_WAIT_NODES:-900'
report "wait standby: HA_WAIT_NODES overrides the 900s default" $?

# ---------------------------------------------------------------------------
echo "== synchronous_standby_names write (regression 0.3.9) =="
# the real bench: init step 13 died 'FATAL: cannot set synchronous_standby_
# names on local' with NO reason quoted (pg_runuser_psql swallows stderr);
# the standby's media seed (join step 9) then died 'Permission denied'
# because authorized_keys (init step 14) had never run
rm -f "$WORK/pgdata/postgresql.auto.conf"

lib_run 'ha_sync_names_write local fpbx-ha-2 && echo wrote'
echo "$OUT" | grep -q '^wrote$' && [ "$(echo "$OUT" | wc -l)" = "1" ]
report "ALTER SYSTEM path: quiet success" "$?" "$OUT"
[ ! -f "$WORK/pgdata/postgresql.auto.conf" ]
report "ALTER SYSTEM path: postgresql.auto.conf untouched" $?

PSQL_ALTER_SYNC_RC=3 PSQL_SYNCNAMES='"fpbx-ha-2"' lib_run 'ha_sync_names_write local fpbx-ha-2 && echo wrote'
echo "$OUT" | grep -q '^wrote$'
report "refused ALTER: direct auto.conf edit succeeds" "$?" "$OUT"
grep -q "^synchronous_standby_names = '\"fpbx-ha-2\"'\$" "$WORK/pgdata/postgresql.auto.conf"
report "refused ALTER: value written to postgresql.auto.conf (GUC form)" $?

PSQL_ALTER_SYNC_RC=3 PSQL_SYNCNAMES='"fpbx-ha-2"' lib_run 'ha_sync_names_write local fpbx-ha-2 && echo wrote'
[ "$(grep -c '^synchronous_standby_names' "$WORK/pgdata/postgresql.auto.conf")" = "1" ]
report "refused ALTER: idempotent - exactly one sync line" $?

PSQL_ALTER_SYNC_RC=3 PSQL_SYNCNAMES="" lib_run 'ha_sync_names_write local "" && echo cleared'
echo "$OUT" | grep -q '^cleared$'
report "refused ALTER: empty value clears the setting" "$?" "$OUT"
! grep -q '^synchronous_standby_names' "$WORK/pgdata/postgresql.auto.conf"
report "refused ALTER: sync line removed from postgresql.auto.conf" $?

PSQL_ALTER_SYNC_RC=3 lib_run 'HA_DB_PASSWORD="pw123"; ha_sync_names_write 10.0.0.12 fpbx-ha-2'
_rc=$?
[ "$_rc" != 0 ] && printf '%s' "$OUT" | grep -q "cannot set synchronous_standby_names on 10.0.0.12" \
    && printf '%s' "$OUT" | grep -q "stub-injected ALTER SYSTEM failure"
report "remote failure: FATAL quotes the real psql error" "$?" "rc=$_rc"

PSQL_ALTER_SYNC_RC=3 PSQL_SYNCNAMES='"fpbx-ha-2"' PSQL_APPNAME="fpbx-ha-2" lib_run '
    HA_NODE_ID=1
    HA_NODE1_NAME="fpbx-ha-1"; HA_NODE1_IP="10.0.0.11"
    HA_NODE2_NAME="fpbx-ha-2"; HA_NODE2_IP="10.0.0.12"
    ha_ensure_sync local && echo ensured
'
echo "$OUT" | grep -q '^ensured$' && echo "$OUT" | grep -q "sync mode: ON on local"
report "ha_ensure_sync: sync ON through the file fallback" "$?" "$(echo "$OUT" | tail -1)"

PSQL_ALTER_SYNC_RC=3 PSQL_SYNCNAMES="" PSQL_APPNAME="" lib_run '
    HA_NODE_ID=1
    HA_NODE2_NAME="fpbx-ha-2"
    ha_ensure_sync local && echo ensured
'
echo "$OUT" | grep -q '^ensured$' && echo "$OUT" | grep -q "sync mode: OFF on local"
report "ha_ensure_sync: async clear through the file fallback" "$?" "$(echo "$OUT" | tail -1)"

# ---------------------------------------------------------------------------
echo "== synchronous_standby_names quoting (regression 0.3.10) =="
# the real bench: ALTER SYSTEM refused the raw hyphenated name with
# "syntax error at or near \"-\"" and the 0.3.9 file fallback left an
# INVALID line in postgresql.auto.conf (the server would refuse to
# RESTART). The parameter has its own grammar: a hyphenated name must be
# double-quoted INSIDE the value ('"fpbx-ha-2"'), while '' and '*' are
# complete values of their own and must never be quoted.

lib_run 'ha_sync_names_gucval fpbx-ha-2'
[ "$OUT" = '"fpbx-ha-2"' ]
report "gucval: hyphenated name is double-quoted" $?

lib_run 'ha_sync_names_gucval fpbx_ha_2'
[ "$OUT" = "fpbx_ha_2" ]
report "gucval: plain identifier passes through" $?

lib_run 'ha_sync_names_gucval "*"'
[ "$OUT" = "*" ]
report "gucval: '*' (any standby, B2) is never quoted" $?

lib_run 'ha_sync_names_gucval ""'
[ -z "$OUT" ]
report "gucval: empty value stays empty (async clear)" $?

rm -f "$WORK/alter.log" "$WORK/pgdata/postgresql.auto.conf"
PSQL_ALTER_SYNC_LOG="$WORK/alter.log" lib_run 'ha_sync_names_write local fpbx-ha-2 && echo wrote'
echo "$OUT" | grep -q '^wrote$' \
    && grep -qF "ALTER SYSTEM SET synchronous_standby_names = '\"fpbx-ha-2\"';" "$WORK/alter.log"
report "ALTER SYSTEM path: the hyphenated name is quoted in the SQL" "$?" "$OUT"

# resume self-heal: the crashed bench left an INVALID unquoted line in
# postgresql.auto.conf - the fixed re-run must leave exactly one VALID line
rm -f "$WORK/pgdata/postgresql.auto.conf"
echo "synchronous_standby_names = 'fpbx-ha-2'" > "$WORK/pgdata/postgresql.auto.conf"
PSQL_ALTER_SYNC_RC=3 PSQL_SYNCNAMES='"fpbx-ha-2"' lib_run 'ha_sync_names_write local fpbx-ha-2 && echo wrote'
echo "$OUT" | grep -q '^wrote$' \
    && [ "$(grep -c '^synchronous_standby_names' "$WORK/pgdata/postgresql.auto.conf")" = "1" ] \
    && grep -q "^synchronous_standby_names = '\"fpbx-ha-2\"'\$" "$WORK/pgdata/postgresql.auto.conf"
report "self-heal: an invalid line left by the crashed run is replaced" "$?" "$OUT"

# '*' must stay literal: '"*"' would be a NAME, not the any-standby wildcard
rm -f "$WORK/pgdata/postgresql.auto.conf"
PSQL_ALTER_SYNC_RC=3 PSQL_SYNCNAMES='*' lib_run 'ha_sync_names_write local "*" && echo wrote'
echo "$OUT" | grep -q '^wrote$' \
    && grep -qxF "synchronous_standby_names = '*'" "$WORK/pgdata/postgresql.auto.conf"
report "B2 fallback: '*' written unquoted (wildcard, not a name)" "$?" "$OUT"

# ---------------------------------------------------------------------------
echo "== stale sync names clear (regression 0.3.17) =="
# the real bench: --init --force over the INSTALLED cluster hung at step 7 -
# the schema-grants 'ALTER SCHEMA' sat in the sync-replication wait forever
# ('canceling wait for synchronous replication ... already committed
# locally' after Ctrl-C). synchronous_standby_names survives steps 1-6 in
# postgresql.auto.conf; the old standby drops once step 4 changes its
# password (the walreceiver reconnect then fails auth) - and every commit
# on the primary freezes. The installer must establish its own
# precondition BEFORE its first write: names set + no streaming standby
# -> clear (step 13 re-enables sync once the new standby streams).

rm -f "$WORK/alter-clear.log"
PSQL_SYNCNAMES='"fpbx-ha-2"' PSQL_APPNAME="" PSQL_ALTER_SYNC_LOG="$WORK/alter-clear.log" lib_run '
    ha_clear_stale_sync_names && echo cleared
'
echo "$OUT" | grep -q '^cleared$' && echo "$OUT" | grep -q "would freeze"
report "stale names + no standby: cleared with an explanation" "$?" "$(echo "$OUT" | tail -1)"
grep -qF "ALTER SYSTEM SET synchronous_standby_names = '';" "$WORK/alter-clear.log"
report "stale names + no standby: ALTER SYSTEM clear issued" $?

: > "$WORK/alter-clear.log"
PSQL_SYNCNAMES="" PSQL_ALTER_SYNC_LOG="$WORK/alter-clear.log" lib_run 'ha_clear_stale_sync_names && echo ok'
echo "$OUT" | grep -q '^ok$' && [ ! -s "$WORK/alter-clear.log" ]
report "clean primary (no names): no-op, nothing written" $?

: > "$WORK/alter-clear.log"
PSQL_SYNCNAMES='"fpbx-ha-2"' PSQL_APPNAME="fpbx-ha-2" PSQL_ALTER_SYNC_LOG="$WORK/alter-clear.log" lib_run 'ha_clear_stale_sync_names && echo ok'
echo "$OUT" | grep -q '^ok$' && [ ! -s "$WORK/alter-clear.log" ]
report "streaming standby alive: no-op (its acks keep commits moving)" $?

: > "$WORK/alter-clear.log"
FIX_RECOVERY=t PSQL_SYNCNAMES='"fpbx-ha-2"' PSQL_ALTER_SYNC_LOG="$WORK/alter-clear.log" lib_run 'ha_clear_stale_sync_names && echo ok'
echo "$OUT" | grep -q '^ok$' && [ ! -s "$WORK/alter-clear.log" ]
report "standby node: no-op (grants arrive via replication)" $?

# step contracts: the guard must precede the first write of every
# database-writing step (a resume enters at any of them with the stale
# names still in place)
_s4="$(sed -n '/^init_step_4_pg_prep()/,/^}/p' "$CLI")"
echo "$_s4" | grep -q 'ha_clear_stale_sync_names'
report "step 4: stale-names guard before the first DB write" $?
_s7="$(sed -n '/^init_step_7_primary_register()/,/^}/p' "$CLI")"
echo "$_s7" | grep -q 'ha_clear_stale_sync_names'
report "step 7: stale-names guard before the register prelude" $?
_g7="$(echo "$_s7" | grep -n 'ha_clear_stale_sync_names' | head -1 | cut -d: -f1)"
_p7="$(echo "$_s7" | grep -n 'ha_register_prelude' | head -1 | cut -d: -f1)"
[ -n "$_g7" ] && [ -n "$_p7" ] && [ "$_g7" -lt "$_p7" ]
report "step 7: guard ordered BEFORE the prelude (the bench hang point)" $?
_s10="$(sed -n '/^init_step_10_repoint_dsn()/,/^}/p' "$CLI")"
echo "$_s10" | grep -q 'ha_clear_stale_sync_names'
report "step 10: stale-names guard before the app repoint" $?

# freeze-proof sessions: every installer psql/repmgr session commits
# locally - a stale sync-standby wait must never block the installer
# itself (belt-and-braces to the step-level clear)
_prg="$(sed -n '/^pg_runuser_psql()/,/^}/p' "$LIB")"
echo "$_prg" | grep -q "PGOPTIONS='-c synchronous_commit=off'"
report "pg_runuser_psql: synchronous_commit=off (installer commits never wait)" $?
_rpc="$(sed -n '/^repmgr_cmd()/,/^}/p' "$LIB")"
echo "$_rpc" | grep -q "PGOPTIONS='-c synchronous_commit=off'"
report "repmgr_cmd: synchronous_commit=off (register never waits)" $?


# CLI source-order contracts: authorized_keys must not wait for step 14
_s12="$(sed -n '/^init_step_12_wait_standby()/,/^}/p' "$CLI")"
_ak12="$(echo "$_s12" | grep -n 'ha_write_authorized_keys' | head -1 | cut -d: -f1)"
_aw12="$(echo "$_s12" | grep -n 'ha_wait ' | head -1 | cut -d: -f1)"
[ -n "$_ak12" ] && [ -n "$_aw12" ] && [ "$_ak12" -lt "$_aw12" ]
report "init step 12: authorized_keys before the standby wait" $?

_s13="$(sed -n '/^init_step_13_sync_on()/,/^}/p' "$CLI")"
_ak13="$(echo "$_s13" | grep -n 'ha_write_authorized_keys' | head -1 | cut -d: -f1)"
# 'ha_ensure_sync local' - NOT the bare 'ha_ensure_sync': since 0.3.11 the
# body also calls ha_ensure_sync_dir, which would shadow the sync-on call
# in a head -1 match
_es13="$(echo "$_s13" | grep -n 'ha_ensure_sync local' | head -1 | cut -d: -f1)"
[ -n "$_ak13" ] && [ -n "$_es13" ] && [ "$_ak13" -lt "$_es13" ]
report "init step 13: authorized_keys self-heal before sync-on" $?

# ---------------------------------------------------------------------------
echo "== media sync dir (regression 0.3.11) =="
# layer 1 never creates /var/lib/freeswitch/storage (it only prepares
# recordings/), and the standby's media seed (join step 9) reads it through
# rrsync on the primary the MOMENT it starts streaming - on the real bench
# it won the race against init step 14 (the only creator): rrsync died
# 'post-realpath open failed (race detected): ... No such file or directory'.
# ha_ensure_sync_dir must create the dir AND give it the FreeSWITCH runtime
# ownership (angie on this port) - a root:root media dir silently breaks
# voicemail/fax/recording writes.
rm -rf "$WORK/media"
lib_run "HA_SYNC_DIR='$WORK/media'; HA_SYNC_DIR_OWNER='root:root'; ha_ensure_sync_dir && echo ensured"
echo "$OUT" | grep -q '^ensured$' && [ -d "$WORK/media" ]
report "ensure sync dir: creates the media dir" "$?" "$OUT"

lib_run "HA_SYNC_DIR='$WORK/media'; HA_SYNC_DIR_OWNER='root:root'; ha_ensure_sync_dir && echo ensured"
echo "$OUT" | grep -q '^ensured$'
report "ensure sync dir: idempotent on an existing dir" "$?" "$OUT"

lib_run "HA_SYNC_DIR='$WORK/media2'; HA_SYNC_DIR_OWNER='no-such-user:no-such-group'; ha_ensure_sync_dir && echo ensured"
echo "$OUT" | grep -q '^ensured$' && echo "$OUT" | grep -q 'cannot chown'
report "ensure sync dir: chown failure is a warn, not fatal" "$?" "$OUT"

# CLI source-order contracts: the media dir must exist on the primary
# BEFORE the standby's seed can pull it - step 6 ensures it ahead of the
# primary register, steps 12/13 self-heal resumes, step 14 and the join
# seed keep it, the surviving-primary repair re-ensures it before lsyncd
_s6="$(sed -n '/^init_step_6_repmgr_conf()/,/^}/p' "$CLI")"
echo "$_s6" | grep -q 'ha_ensure_sync_dir'
report "init step 6: media dir ensured before the primary register" $?
_md12="$(echo "$_s12" | grep -n 'ha_ensure_sync_dir' | head -1 | cut -d: -f1)"
[ -n "$_md12" ] && [ "$_md12" -lt "$_aw12" ]
report "init step 12: media dir self-heal before the standby wait" $?
_md13="$(echo "$_s13" | grep -n 'ha_ensure_sync_dir' | head -1 | cut -d: -f1)"
[ -n "$_md13" ] && [ "$_md13" -lt "$_es13" ]
report "init step 13: media dir self-heal before sync-on" $?
_s14="$(sed -n '/^init_step_14_sync_setup()/,/^}/p' "$CLI")"
echo "$_s14" | grep -q 'ha_ensure_sync_dir'
report "init step 14: media dir ensured (kept)" $?
_j9="$(sed -n '/^join_step_9_seed_media()/,/^}/p' "$CLI")"
_jr9="$(echo "$_j9" | grep -n 'ha_ensure_sync_dir' | head -1 | cut -d: -f1)"
_rs9="$(echo "$_j9" | grep -n 'ha_seed_pull' | head -1 | cut -d: -f1)"
[ -n "$_jr9" ] && [ -n "$_rs9" ] && [ "$_jr9" -lt "$_rs9" ]
report "join step 9: local media dir ensured before the seed pull" $?
_p3="$(sed -n '/^prp_step_3_services()/,/^}/p' "$CLI")"
_pd3="$(echo "$_p3" | grep -n 'ha_ensure_sync_dir' | head -1 | cut -d: -f1)"
_pl3="$(echo "$_p3" | grep -n 'ha_render_lsyncd_conf' | head -1 | cut -d: -f1)"
[ -n "$_pd3" ] && [ -n "$_pl3" ] && [ "$_pd3" -lt "$_pl3" ]
report "repair-primary: media dir ensured before lsyncd" $?

# ---------------------------------------------------------------------------
echo "== media path form over rrsync (regression 0.3.13) =="
# The hardened rrsync family has TWO incompatible client-path mappings:
# newer builds PREPEND the restricted root onto a leading-slash arg, but
# the ALT-shipped snapshot LSTRIPS the slash and serves the rest against
# its CWD (= the restricted root). On the ALT build '/' arrives as '' and
# realpath('') = CWD = the root itself fails the startswith(dir + '/')
# containment check ('unsafe arg: / [\'\', ...]' - the 0.3.13 bench death,
# reproduced live on the stand-lstrip variant); the pre-0.3.12 absolute
# form doubled into $HA_SYNC_DIR/$HA_SYNC_DIR/ and died ENOENT at the
# sender open ('post-realpath open failed'). The ONLY form valid on every
# variant is the bare dot - validated_arg skips it entirely ('arg != .'),
# and '.' resolves to CWD = the peer's restricted tree root. The seed
# pulls ':.', the lsyncd template pushes to ':.', and --doctor REPORTS
# configs that drift from the current template (read-only, 0.3.16).
# 0.3.23: the rsync invocation moved into ha_seed_pull (ha-lib) - the
# form contracts follow it there; the runtime args are asserted in the
# 0.3.23 section via the rsync stub
_sl="$(sed -n '/^ha_seed_pull()/,/^}/p' "$LIB")"
echo "$_sl" | grep -Fq '"root@${_hsp_peer_ip}:."'
report "seed pull: the rrsync tree root as the bare dot (:.) (0.3.13, lib)" $?
if echo "$_sl" | grep -Fq 'peer_ip}:$HA_SYNC_DIR'; then false; else true; fi
report "seed pull: no absolute \$HA_SYNC_DIR remote spec left" $?
if echo "$_sl" | grep -Fq '"root@${_hsp_peer_ip}:/"'; then false; else true; fi
report "seed pull: the 0.3.12 ':/' form is gone (dies on the ALT rrsync)" $?
grep -Fq 'source    = "@@SYNC_DIR@@/"' "$RES/lsyncd.conf.lua.tpl"
report "lsyncd template: source pins the contents slash" $?
grep -Fq 'target    = "root@@@PEER_IP@@:."' "$RES/lsyncd.conf.lua.tpl"
report "lsyncd template: target is the bare dot (:.)" $?
_dc="$(sed -n '/^cmd_doctor()/,/^}/p' "$CLI")"
# 0.3.16: the doctor renders the current template and COMPARES - drift is
# reported, the config is never rewritten and lsyncd is never restarted
_dc_ck="$(echo "$_dc" | grep -n 'lsyncd.conf.lua.tpl' | head -1 | cut -d: -f1)"
_dc_cmp="$(echo "$_dc" | grep -nF 'cmp -s "$_dc_lsyn_new" "$HA_LSYNCD_CONF"' | head -1 | cut -d: -f1)"
[ -n "$_dc_ck" ] && [ -n "$_dc_cmp" ] \
  && ! echo "$_dc" | grep -q 'systemctl restart "$HA_LSYNCD_SERVICE"'
report "doctor: renders the current lsyncd template, compares, never restarts (0.3.16)" $?

# live rrsync semantics (the same hardened wrapper class ALT ships - skip
# when the test host has none): the family has TWO arg mappings - newer
# builds prepend the restricted root, the ALT snapshot LSTRIPS the leading
# slash (CWD-relative), so '/' is VARIANT-DEPENDENT: it passed the 0.3.12
# container test (prepend build) and died on the bench with "unsafe arg:
# / ['', ...]" (lstrip build, reproduced locally on the stand-matching
# master snapshot). The script must rely ONLY on the bare dot, which
# validated_arg skips entirely - assert both live.
_rr_bin="$(command -v rrsync 2>/dev/null || true)"
[ -z "$_rr_bin" ] && [ -x /usr/bin/rrsync ] && _rr_bin=/usr/bin/rrsync
rm -rf "$WORK/rr"; mkdir -p "$WORK/rr/root"
if [ -n "$_rr_bin" ]; then
    _rr_out="$(SSH_ORIGINAL_COMMAND='rsync --server --sender . /var/lib/freeswitch/storage/' \
        "$_rr_bin" "$WORK/rr/root" </dev/null 2>&1)"; _rr_rc=$?
    [ "$_rr_rc" -ne 0 ] && echo "$_rr_out" | grep -q 'post-realpath open failed\|unsafe arg'
    report "rrsync live: the absolute path form never survives validation" "$?" "${_rr_out:-}"
    _rr_out="$(SSH_ORIGINAL_COMMAND='rsync --server --sender -a --delete . .' \
        "$_rr_bin" "$WORK/rr/root" </dev/null 2>&1 | tr -d '\0')"
    if echo "$_rr_out" | grep -q 'post-realpath open failed\|unsafe arg\|does not run rsync'; then false; else true; fi
    report "rrsync live: the bare dot (the 0.3.13 client form) passes validation" "$?" "${_rr_out:-}"
else
    report "rrsync live: the absolute path form never survives validation (skipped: no rrsync on the test host)" 0
    report "rrsync live: the bare dot (the 0.3.13 client form) passes validation (skipped: no rrsync on the test host)" 0
fi

# ---------------------------------------------------------------------------
echo "== authorized_keys convergence (regression 0.3.13) =="
# The bench: the standby's sync-key line was rejected by sshd preauth
# ('invalid key option string') - the peer's pushes died. The writer must
# (a) purge ANY stray line carrying the sync key outside the managed block
# (interrupted write / older version) and (b) re-add exactly one valid
# line with the forced rrsync command, leaving foreign keys untouched.
echo '#!/bin/sh' > "$WORK/localbin/rrsync"; chmod +x "$WORK/localbin/rrsync"
mkdir -p "$WORK/sshdir"
{
    echo 'ssh-rsa AAAAOLDOTHERKEY admin@workstation'
    printf 'from="10.0.0.11",command="/bad unbalanced ssh-ed25519 AAAAFAKEPUBLICKEY fusionpbx-ha-sync\n'
} > "$WORK/sshdir/authorized_keys"
lib_run "HA_SYNC_SSH_DIR='$WORK/sshdir'; HA_SYNC_PUBLIC_KEY='ssh-ed25519 AAAAFAKEPUBLICKEY fusionpbx-ha-sync'; HA_SYNC_DIR='/var/lib/freeswitch/storage'; HA_NODE1_IP='10.0.0.11'; HA_NODE2_IP='10.0.0.12'; ha_write_authorized_keys && echo written"
echo "$OUT" | grep -q '^written$'
report "writer: succeeds with a broken pre-existing sync-key line" "$?" "$OUT"
[ "$(grep -c 'AAAAFAKEPUBLICKEY' "$WORK/sshdir/authorized_keys")" = "1" ]
report "writer: exactly ONE line carries the sync key (stray purged)" $?
grep -q '^from="10.0.0.11,10.0.0.12",command="' "$WORK/sshdir/authorized_keys"
report "writer: fresh line carries the forced rrsync command" $?
grep -q 'AAAAOLDOTHERKEY' "$WORK/sshdir/authorized_keys"
report "writer: foreign admin key untouched" $?
awk '/BEGIN fusionpbx-ha/{f=1} f && /AAAAFAKEPUBLICKEY/{print; exit}' "$WORK/sshdir/authorized_keys" | grep -q '^from='
report "writer: sync-key line lives inside the managed block" $?
lib_run "HA_SYNC_SSH_DIR='$WORK/sshdir'; HA_SYNC_PUBLIC_KEY='ssh-ed25519 AAAAFAKEPUBLICKEY fusionpbx-ha-sync'; HA_SYNC_DIR='/var/lib/freeswitch/storage'; HA_NODE1_IP='10.0.0.11'; HA_NODE2_IP='10.0.0.12'; ha_write_authorized_keys && echo again"
[ "$(grep -c 'AAAAFAKEPUBLICKEY' "$WORK/sshdir/authorized_keys")" = "1" ] && echo "$OUT" | grep -q '^again$'
report "writer: idempotent - re-run keeps exactly one sync-key line" $?

# ---------------------------------------------------------------------------
echo "== shared_preload_libraries: repmgrd runtime prerequisite (regression 0.3.15) =="
# Bench: repmgrd died instantly (exit 1) since the FIRST install with the
# reason only in /var/log/repmgr/repmgrd.log - repmgrd calls
# set/get_local_node_id (repmgr.so shared memory) right after connecting,
# and that area only exists when the library was PRELOADED at server start.
mkdir -p "$WORK/pkglib" "$WORK/emptylib"
touch "$WORK/pkglib/repmgr.so"

lib_run 'ha_repmgr_preload_active && echo yes || echo no'
[ "$OUT" = "yes" ]; report "active: default stub SHOW (repmgr) detects the preload" $?
PSQL_PRELOAD="pg_stat_statements,repmgr" lib_run 'ha_repmgr_preload_active && echo yes || echo no'
[ "$OUT" = "yes" ]; report "active: comma list containing repmgr detected" $?
PSQL_PRELOAD="pg_stat_statements" lib_run 'ha_repmgr_preload_active && echo yes || echo no'
[ "$OUT" = "no" ]; report "active: other libraries only - not active" $?
PSQL_PRELOAD="" lib_run 'ha_repmgr_preload_active && echo yes || echo no'
[ "$OUT" = "no" ]; report "active: empty value - not active" $?

# write: fresh value, ALTER path (server up, primary)
PSQL_PRELOAD="" PSQL_ALTER_PRELOAD_LOG="$WORK/preload-alter.log" \
    HA_PG_PKGLIBDIR="$WORK/pkglib" lib_run 'ha_repmgr_preload_write && echo wrote'
[ "$(tail -1 "$WORK/preload-alter.log")" = "ALTER SYSTEM SET shared_preload_libraries = 'repmgr';" ] \
    && echo "$OUT" | grep -q '^wrote$'
report "write: empty runtime -> ALTER SYSTEM SET ... = 'repmgr'" $? "$OUT"
# write: APPEND to existing libraries (never clobber other packages' entries)
PSQL_PRELOAD="pg_stat_statements" PSQL_ALTER_PRELOAD_LOG="$WORK/preload-alter2.log" \
    HA_PG_PKGLIBDIR="$WORK/pkglib" lib_run 'ha_repmgr_preload_write && echo wrote2'
[ "$(tail -1 "$WORK/preload-alter2.log")" = "ALTER SYSTEM SET shared_preload_libraries = 'pg_stat_statements,repmgr';" ] \
    && echo "$OUT" | grep -q '^wrote2$'
report "write: existing libraries preserved (append, not replace)" $? "$OUT"

# write: ALTER refused on a standby in recovery -> direct auto.conf edit,
# exactly one line, idempotent on re-run
rm -f "$WORK/pgdata/postgresql.auto.conf"
FIX_RECOVERY=t PSQL_PRELOAD="pg_stat_statements" PSQL_ALTER_PRELOAD_RC=3 \
    HA_PG_PKGLIBDIR="$WORK/pkglib" lib_run 'ha_repmgr_preload_write && echo fb1'
[ "$(grep -c '^shared_preload_libraries' "$WORK/pgdata/postgresql.auto.conf")" = "1" ] \
    && [ "$(grep '^shared_preload_libraries' "$WORK/pgdata/postgresql.auto.conf")" = "shared_preload_libraries = 'pg_stat_statements,repmgr'" ] \
    && echo "$OUT" | grep -q '^fb1$'
report "write: standby fallback -> single auto.conf line with the merged value" $? "$OUT"
FIX_RECOVERY=t PSQL_PRELOAD="pg_stat_statements" PSQL_ALTER_PRELOAD_RC=3 \
    HA_PG_PKGLIBDIR="$WORK/pkglib" lib_run 'ha_repmgr_preload_write && echo fb2'
[ "$(grep -c '^shared_preload_libraries' "$WORK/pgdata/postgresql.auto.conf")" = "1" ] \
    && echo "$OUT" | grep -q '^fb2$'
report "write: standby fallback idempotent - re-run keeps ONE line" $? "$OUT"

# write: server not answering (fresh witness pre-first-start) -> auto.conf,
# merging a pre-existing postgresql.conf entry instead of clobbering it
rm -f "$WORK/pgdata/postgresql.auto.conf"
echo "shared_preload_libraries = 'auto_explain'" > "$WORK/pgdata/postgresql.conf"
FIX_RECOVERY="" PSQL_PRELOAD="" PSQL_ALTER_PRELOAD_RC=3 \
    HA_PG_PKGLIBDIR="$WORK/pkglib" lib_run 'ha_repmgr_preload_write && echo down'
[ "$(grep '^shared_preload_libraries' "$WORK/pgdata/postgresql.auto.conf")" = "shared_preload_libraries = 'auto_explain,repmgr'" ] \
    && echo "$OUT" | grep -q '^down$'
report "write: server down -> auto.conf merges the postgresql.conf entry" $? "$OUT"
rm -f "$WORK/pgdata/postgresql.conf"

# write: repmgr.so missing -> refuse to write (a preload of a missing
# library would brick the NEXT server start)
HA_PG_PKGLIBDIR="$WORK/emptylib" lib_run 'ha_repmgr_preload_write; echo rc=$?'
echo "$OUT" | grep -q 'Refusing to write shared_preload_libraries'
report "write: repmgr.so missing -> refuses (restart-safety guard)" $? "$OUT"

# write: live primary refusing ALTER SYSTEM (recovery=f, rc!=0) -> die with
# the psql verdict, no silent file fallback
FIX_RECOVERY=f PSQL_PRELOAD="" PSQL_ALTER_PRELOAD_RC=3 \
    HA_PG_PKGLIBDIR="$WORK/pkglib" lib_run 'ha_repmgr_preload_write; echo rc=$?'
echo "$OUT" | grep -q 'refused on a live primary' && echo "$OUT" | grep -q 'stub-injected preload ALTER failure'
report "write: live primary refusal -> die quoting the real psql error" $? "$OUT"

# ensure (0.3.16 - the only remaining caller is the witness join reuse
# path): missing preload -> write + ONE restart + verify
: > "$WORK/preload-ensure.log"
PSQL_PRELOAD="" PSQL_ALTER_PRELOAD_LOG="$WORK/preload-ensure.log" \
    HA_PG_PKGLIBDIR="$WORK/pkglib" HA_SYSTEMD_DIR="$WORK/systemd" \
    lib_run 'ha_ensure_repmgr_preload && echo ensured'
echo "$OUT" | grep -q '^ensured$' \
  && [ "$(tail -1 "$WORK/preload-ensure.log")" = "ALTER SYSTEM SET shared_preload_libraries = 'repmgr';" ]
report "ensure: missing preload -> write + one restart + verify (witness reuse)" $? "$OUT"
PSQL_PRELOAD="" HA_PG_PKGLIBDIR="$WORK/pkglib" HA_SYSTEMD_DIR="$WORK/systemd" \
    lib_run 'ha_ensure_repmgr_preload; echo rc=$?'
echo "$OUT" | grep -q "does not include 'repmgr' after the restart"
report "ensure: post-restart verification failure is fatal" $? "$OUT"

# pkglibdir override precedence
HA_PG_PKGLIBDIR="$WORK/pkglib" lib_run 'p=$(ha_pg_pkglibdir); [ "$p" = "$WORK/pkglib" ] && echo ok'
[ "$OUT" = "ok" ]; report "pkglibdir: HA_PG_PKGLIBDIR override honored" $?

# drop-in (0.3.15): content-aware write - upgrades the stale 0.3.13 copy
# (no Environment= line) and stays quiet on an identical re-run
rm -rf "$WORK/systemd"
mkdir -p "$WORK/systemd/repmgr.service.d"
printf '# fusionpbx-ha: start repmgrd only after local PostgreSQL (boot race, 0.3.13)\n[Unit]\nAfter=postgresql.service\nWants=postgresql.service\n' \
    > "$WORK/systemd/repmgr.service.d/fusionpbx-ha.conf"
HA_SYSTEMD_DIR="$WORK/systemd" lib_run 'ha_install_repmgr_dropin && echo di1'
grep -q '^Environment=REPMGRD_OPTS=$' "$WORK/systemd/repmgr.service.d/fusionpbx-ha.conf" \
    && grep -q '^After=postgresql.service$' "$WORK/systemd/repmgr.service.d/fusionpbx-ha.conf" \
    && echo "$OUT" | grep -q '^di1$'
report "drop-in: stale 0.3.13 copy upgraded (ordering kept + REPMGRD_OPTS defined)" $? "$OUT"
HA_SYSTEMD_DIR="$WORK/systemd" lib_run 'ha_install_repmgr_dropin && echo di2'
grep -c '^Environment=REPMGRD_OPTS=$' "$WORK/systemd/repmgr.service.d/fusionpbx-ha.conf" | grep -q '^1$' \
    && echo "$OUT" | grep -q '^di2$'
report "drop-in: idempotent - exactly one Environment= line after re-run" $? "$OUT"

# 0.3.15/0.3.16 source contracts: the preload joins the init step-5
# one-restart batch BEFORE the restart decision and is verified after it;
# the witness join writes it (fresh: before the first start; reuse:
# ha_ensure_repmgr_preload after it). 0.3.16: the doctor CHECKS the
# preload but never writes it, quotes the repmgrd LOG FILE (not only the
# journal) when the daemon is down, and stays read-only overall
_i5="$(sed -n '/^init_step_5_wal_log_hints()/,/^}/p' "$CLI")"
echo "$_i5" | grep -q 'ha_repmgr_preload_active' && echo "$_i5" | grep -q 'ha_repmgr_preload_write'
report "init step 5: preload joins the one-restart step (write before restart)" $?
echo "$_i5" | grep -q 'ha_repmgr_preload_active \\' && echo "$_i5" | grep -q "|| die \"shared_preload_libraries does not include"
report "init step 5: preload verified after the restart" $?
_hrp="$(sed -n '/^ha_register_prelude()/,/^}/p' "$LIB")"
if echo "$_hrp" | grep -q 'ha_ensure_repmgr_preload'; then false; else true; fi
report "register prelude: NO preload convergence (0.3.16 - installer-only)" $?
_w4="$(sed -n '/^wit_step_4_initdb_tiny()/,/^}/p' "$CLI")"
echo "$_w4" | grep -q 'ha_repmgr_preload_write' && echo "$_w4" | grep -q 'ha_ensure_repmgr_preload'
report "witness: preload written before the first start + convergence for a reused witness" $?
echo "$_w4" | grep -qF 'ALTER ROLE $HA_REPMGR_USER WITH PASSWORD' \
  && echo "$_w4" | grep -q 'password aligned with the token'
report "witness reuse: repmgr role password aligned with the current token (0.3.16)" $?
_i1="$(sed -n '/^init_step_1_preflight()/,/^}/p' "$CLI")"
echo "$_i1" | grep -qF '[ ! -f "$HA_MARKER_FILE" ]' && echo "$_i1" | grep -q 'ha_port_free'
report "init step 1: port check skipped on a marker re-configure (--init --force over an installed node, 0.3.16)" $?
echo "$_dc" | grep -q 'ha_repmgr_preload_active' && ! echo "$_dc" | grep -q 'ha_repmgr_preload_write'
report "doctor: preload CHECK only - never writes the config (0.3.16)" $?
echo "$_dc" | grep -q 'HA_REPMGRD_LOG'
report "doctor: repmgrd log-file tail quoted on service failure" $?
echo "$_dc" | grep -q "awk '/Startup/{buf=\"\"}"
report "doctor: lsyncd log errors counted from the CURRENT instance only" $?

# 0.3.13/0.3.16 source contracts: the 0.3.12 doctor truncated the lsyncd
# config to zero bytes (a missing '$' made cmp/cat/rm read a literal
# '_dc_lsyn_new' file while the redirect already truncated the real
# config); 0.3.16 removed the doctor's rewrite ENTIRELY - drift is
# REPORTED, the config belongs to the installer/repair flows
if grep -Fq 'cat "$_dc_lsyn_new"' "$CLI" || grep -Fq 'cat "_dc_lsyn_new"' "$CLI"; then false; else true; fi
report "doctor: lsyncd drift reported - no rewrite, no truncation class (0.3.16)" $?
if echo "$_dc" | grep -q 'ha_write_authorized_keys'; then false; else true; fi
report "doctor: authorized_keys verified WITHOUT writing (0.3.16)" $?
if echo "$_dc" | grep -q 'ha_install_repmgr_dropin'; then false; else true; fi
report "doctor: no drop-in installation - moved to the installer (0.3.16)" $?
_dropin_ok=0
for _dfn in init_step_7_primary_register join_step_6_start_register wit_step_7_repmgrd rep_step_4_services prp_step_3_services; do
    sed -n "/^${_dfn}()/,/^}/p" "$CLI" | grep -q 'ha_install_repmgr_dropin' || _dropin_ok=1
done
[ "$_dropin_ok" = "0" ]
report "installer/repair: repmgrd unit drop-in installed before every enable+start" $?
grep -q 'After=$HA_PG_SERVICE.service' "$LIB"
report "drop-in: repmgrd ordered after local postgresql" $?
_cj="$(sed -n '/^cmd_join()/,/^}/p' "$CLI")"
echo "$_cj" | grep -q 'ha_write_authorized_keys' && echo "$_cj" | grep -Fq 'command=join-standby'
report "cmd_join: authorized_keys converged on resume (join-standby state)" $?
_j3="$(sed -n '/^join_step_3_packages()/,/^}/p' "$CLI")"
echo "$_j3" | grep -q 'rsync curl' && echo "$_j3" | grep -q 'ha_write_authorized_keys'
report "join step 3: sync-key line re-rendered once rsync is installed" $?

# ---------------------------------------------------------------------------
echo "== join resume vs cluster generation (regression 0.3.18) =="
# the real bench: node 2 resumed an October state file against a
# re-initialized primary (--init --force REGENERATES all secrets) - step 2
# (unpack) was skipped, so the media seed ran with the OLD sync private
# key and died 'Permission denied (publickey)'. The token IS the identity:
# a state file whose cluster.conf differs from the token's is garbage.

mkdir -p "$WORK/etc"
printf 'HA_CLUSTER_NAME="old-cluster"\nHA_REPMGR_PASSWORD="old-secret"\n' > "$WORK/etc/cluster.conf"
{ echo "# state"; echo "command=join-standby"; echo "step_ok=1 join_step_1_preflight"; } > "$WORK/etc/.installer-state"
printf 'HA_CLUSTER_NAME="fpbx-ha"\nHA_REPMGR_PASSWORD="new-secret"\n' > "$WORK/token.conf"

lib_run "ha_join_state_freshen $WORK/token.conf && echo ok"
echo "$OUT" | grep -q '^ok$' && echo "$OUT" | grep -q "DIFFERENT cluster generation" \
    && [ ! -f "$WORK/etc/.installer-state" ]
report "token differs from the on-disk conf: state discarded" "$?" "$(echo "$OUT" | head -2 | tail -1)"

{ echo "# state"; echo "command=join-standby"; echo "step_ok=1 join_step_1_preflight"; } > "$WORK/etc/.installer-state"
cp "$WORK/token.conf" "$WORK/etc/cluster.conf"
lib_run "ha_join_state_freshen $WORK/token.conf && echo ok"
echo "$OUT" | grep -q '^ok$' && [ -f "$WORK/etc/.installer-state" ] && ! echo "$OUT" | grep -q "DIFFERENT"
report "same token re-run after a crash: state kept (resume)" $?

rm -f "$WORK/etc/.installer-state"
lib_run "ha_join_state_freshen $WORK/token.conf && echo ok"
echo "$OUT" | grep -q '^ok$' && ! echo "$OUT" | grep -q "DIFFERENT"
report "no state file (first join): plain no-op" $?

{ echo "# state"; echo "command=join-standby"; } > "$WORK/etc/.installer-state"
rm -f "$WORK/etc/cluster.conf"
lib_run "ha_join_state_freshen $WORK/token.conf && echo ok"
echo "$OUT" | grep -q '^ok$' && [ ! -f "$WORK/etc/.installer-state" ]
report "state without an on-disk conf: garbage, discarded" $?
echo "$OUT" | grep -q "no cluster to belong to" && ! echo "$OUT" | grep -q "DIFFERENT"
report "missing conf: the real reason stated (wiped node), not 'secrets differ' (0.3.19)" $?

# cmd_join contract: the freshen check runs BEFORE the 0.3.13 resume
# convergence and BEFORE the sequence - a mismatched state must never
# leak into either
_f18="$(echo "$_cj" | grep -n 'ha_join_state_freshen' | head -1 | cut -d: -f1)"
_c13="$(echo "$_cj" | grep -n 'Resume convergence (0.3.13)' | head -1 | cut -d: -f1)"
_seqj="$(echo "$_cj" | grep -n 'ha_run_sequence ' | head -1 | cut -d: -f1)"
[ -n "$_f18" ] && [ -n "$_c13" ] && [ -n "$_seqj" ] && [ "$_f18" -lt "$_c13" ] && [ "$_f18" -lt "$_seqj" ]
report "cmd_join: freshen BEFORE the resume convergence and the sequence" $?

# ---------------------------------------------------------------------------
echo "== standby join without a local database (regression 0.3.19) =="
# the real bench (0.3.18 follow-up): node 2's join died mid-step-5 (the
# PGDATA wipe happened, the re-clone did not), then /etc/fusionpbx-ha was
# deleted by accident. The 0.3.18 freshen did its job (state discarded,
# fresh join from step 1) - and step 1 killed the recovery with 'no local
# PostgreSQL cluster found (PG_VERSION missing) - run layer 1 first'
# while layer 1 was fine. A standby NEVER needs a local database: step 5
# clones it. Preflight must only reject a REAL version conflict - and
# the primary keeps its strict check (its local DB becomes the cluster).

_j1="$(sed -n '/^join_step_1_preflight()/,/^}/p' "$CLI")"
if echo "$_j1" | grep -qF 'no local PostgreSQL cluster found'; then false; else true; fi
report "join step 1: an empty/missing data directory is no longer fatal" $?
echo "$_j1" | grep -qF 'the local database will be cloned from the primary at step 5'
report "join step 1: the wiped node is told the DB is re-cloned (not 'run layer 1')" $?
echo "$_j1" | grep -qF 'PostgreSQL major version mismatch'
report "join step 1: a real major-version conflict still dies" $?
echo "$_j1" | grep -qF 'layer 1 is not installed on this node'
report "join step 1: the layer-1 requirement itself is untouched" $?
echo "$_j1" | grep -q 'if _jsp_ver="$(ha_pg_version_major)"'
report "join step 1: version still checked when a local cluster exists" $?
_ci="$(sed -n '/^cmd_init()/,/^}/p' "$CLI")"
echo "$_ci" | grep -qF 'cannot determine the local PostgreSQL major version'
report "init: the primary still requires its own database (strict check kept)" $?

# ---------------------------------------------------------------------------
echo "== sync target name / witness diagnostics (regression 0.3.20) =="
# the real bench: node 2's join step 11 called ha_ensure_sync FOR the
# primary and expected the PRIMARY's own name ('fpbx-ha-1') as the
# streaming standby - never matched, fell back to '*' with a scary
# warning, and overwrote the precise '"fpbx-ha-2"' the primary's init
# step 13 had written. The expected standby is the PEER OF THE TARGET
# HOST (the node that streams from it), not the peer of the caller.

PSQL_SYNCNAMES='"fpbx-ha-2"' PSQL_APPNAME="fpbx-ha-2" lib_run '
    HA_NODE_ID=2
    HA_NODE1_NAME="fpbx-ha-1"; HA_NODE1_IP="10.0.0.11"
    HA_NODE2_NAME="fpbx-ha-2"; HA_NODE2_IP="10.0.0.12"
    HA_DB_PASSWORD="pw123"
    ha_ensure_sync 10.0.0.11 && echo ensured
'
echo "$OUT" | grep -q '^ensured$' && echo "$OUT" | grep -q "sync mode: ON on 10.0.0.11" \
    && echo "$OUT" | grep -qF "synchronous_standby_names='\"fpbx-ha-2\"'" \
    && ! echo "$OUT" | grep -q "using '\*'"
report "ha_ensure_sync from the standby: its OWN name, no '*' fallback (0.3.20)" "$?" "$(echo "$OUT" | head -3)"

PSQL_SYNCNAMES='"fpbx-ha-2"' PSQL_APPNAME="fpbx-ha-2" lib_run '
    HA_NODE_ID=1
    HA_NODE1_NAME="fpbx-ha-1"; HA_NODE1_IP="10.0.0.11"
    HA_NODE2_NAME="fpbx-ha-2"; HA_NODE2_IP="10.0.0.12"
    ha_ensure_sync local && echo ensured
'
echo "$OUT" | grep -q '^ensured$' && echo "$OUT" | grep -q "sync mode: ON on local" \
    && ! echo "$OUT" | grep -q "using '\*'"
report "ha_ensure_sync on the primary: unchanged (peer of local = node 2)" "$?" "$(echo "$OUT" | head -3)"

PSQL_SYNCNAMES='*' PSQL_APPNAME="some-foreign-name" lib_run '
    HA_NODE_ID=2
    HA_NODE1_NAME="fpbx-ha-1"; HA_NODE1_IP="10.0.0.11"
    HA_NODE2_NAME="fpbx-ha-2"; HA_NODE2_IP="10.0.0.12"
    HA_DB_PASSWORD="pw123"
    ha_ensure_sync 10.0.0.11 && echo ensured
'
echo "$OUT" | grep -q '^ensured$' && echo "$OUT" | grep -q "falling back to ASYNC" \
    && echo "$OUT" | grep -q "sync mode: OFF on 10.0.0.11" \
    && ! echo "$OUT" | grep -q "using '\*'"
report "ha_ensure_sync: foreign standby name -> ASYNC fallback, never '*' (0.3.27)" "$?" "$(echo "$OUT" | head -3)"

_dc20="$(sed -n '/^cmd_doctor()/,/^}/p' "$CLI")"
echo "$_dc20" | grep -qF 'witness: replication state lives on the data nodes' \
    && echo "$_dc20" | grep -qF 'witness metadata database' \
    && echo "$_dc20" | grep -qF 'async mode (no standby streaming)'
report "doctor: witness sync check -> honest no-local-standbys line (0.3.20)" $?

_dcst="$(sed -n '/^cmd_status()/,/^}/p' "$CLI")"
echo "$_dcst" | grep -qF 'witness runs no haproxy' \
    && echo "$_dcst" | grep -qF 'witness: no local replication'
report "status: witness-aware entry point + replication sections (0.3.20)" $?

# ---------------------------------------------------------------------------
echo "== failover daemon must never stay dead (regression 0.3.21) =="
# the real bench: a hard-off primary was survived by a standby whose
# repmgrd had been STOPPED (an interrupted --repair stops repmgrd/lsyncd
# at step 2 and restarts them at step 4) - nobody promoted the standby,
# haproxy honestly refused to route to it (agent 503), total outage until
# the primary returned. repmgrd is THE failover daemon: a dead one must
# always come back (Restart=always, no start-rate limit). An explicit
# 'systemctl stop' (installer flows) is still honored by design.

rm -rf "$WORK/systemd"
HA_SYSTEMD_DIR="$WORK/systemd" lib_run 'ha_install_repmgr_dropin && echo di'
echo "$OUT" | grep -q '^di$' \
    && grep -q '^Restart=always$' "$WORK/systemd/repmgr.service.d/fusionpbx-ha.conf" \
    && grep -q '^RestartSec=10$' "$WORK/systemd/repmgr.service.d/fusionpbx-ha.conf" \
    && grep -q '^StartLimitIntervalSec=0$' "$WORK/systemd/repmgr.service.d/fusionpbx-ha.conf"
report "repmgrd drop-in: Restart=always + no rate limit (0.3.21)" $? "$(echo "$OUT" | tail -1)"

HA_SYSTEMD_DIR="$WORK/systemd" lib_run 'ha_install_lsyncd_dropin && echo dl'
echo "$OUT" | grep -q '^dl$' \
    && grep -q '^Restart=on-failure$' "$WORK/systemd/lsyncd.service.d/fusionpbx-ha.conf" \
    && grep -q '^StartLimitIntervalSec=0$' "$WORK/systemd/lsyncd.service.d/fusionpbx-ha.conf"
report "lsyncd drop-in: Restart=on-failure + no rate limit (0.3.21)" $? "$(echo "$OUT" | tail -1)"

_lsd_ok=0
for _lsfn in init_step_14_sync_setup join_step_10_lsyncd_start rep_step_6_lsyncd prp_step_3_services; do
    sed -n "/^${_lsfn}()/,/^}/p" "$CLI" | grep -q 'ha_install_lsyncd_dropin' || _lsd_ok=1
done
[ "$_lsd_ok" = "0" ]
report "installer/repair: lsyncd drop-in installed before every enable+start" $?

_r2="$(sed -n '/^rep_step_2_stop_services()/,/^}/p' "$CLI")"
echo "$_r2" | grep -qF 'NOT be promoted automatically if the peer dies'
report "repair step 2: the stopped-failover state is announced loudly (0.3.21)" $?

echo "$_dc20" | grep -qF 'AUTOMATIC FAILOVER WILL NOT HAPPEN'
report "doctor: inactive repmgr screams that failover is dead (0.3.21)" $?

# ---------------------------------------------------------------------------
echo "== repair rejoin on a running database (regression 0.3.22) =="
# the real bench: node 2 was a perfectly HEALTHY standby (streaming from
# the primary) and --repair died at step 3 - repmgr 5.5 refuses
# 'node rejoin' on a RUNNING node ("database is still running in state
# 'in archive recovery' / cannot be executed on a running node"), and the
# interrupted repair left repmgrd+lsyncd stopped (the 0.3.21 crash window
# became real again). The repair must classify the local node FIRST: an
# attached standby keeps its replication running (no rejoin at all, only
# the metadata record is refreshed); only a diverged node is stopped and
# rewound - and afterwards adopted back under systemd, because 'node
# rejoin' may (re)start PostgreSQL itself via pg_ctl, outside systemd.

lib_run '
    ha_rejoin_plan_classify t 10.0.0.11 10.0.0.11
    ha_rejoin_plan_classify t 10.0.0.12 10.0.0.11
    ha_rejoin_plan_classify t "" 10.0.0.11
    ha_rejoin_plan_classify f 10.0.0.11 10.0.0.11
    ha_rejoin_plan_classify "" "" 10.0.0.11
'
[ "$OUT" = "attached
diverged
diverged
diverged
diverged" ]
report "ha_rejoin_plan_classify: truth table - attached ONLY in recovery + peer (0.3.22)" $?

FIX_RECOVERY=t PSQL_WAL_SENDER=10.0.0.11 lib_run 'ha_rejoin_plan 10.0.0.11'
[ "$OUT" = "attached" ]
report "ha_rejoin_plan: standby streaming from the peer -> attached" $?

FIX_RECOVERY=t PSQL_WAL_SENDER=10.0.0.99 lib_run 'ha_rejoin_plan 10.0.0.11'
[ "$OUT" = "diverged" ]
report "ha_rejoin_plan: streaming from a wrong host -> diverged (rewind)" $?

FIX_RECOVERY=t PSQL_WAL_SENDER= lib_run 'ha_rejoin_plan 10.0.0.11'
[ "$OUT" = "diverged" ]
report "ha_rejoin_plan: no WAL receiver -> diverged (rewind)" $?

FIX_RECOVERY=f PSQL_WAL_SENDER=10.0.0.11 lib_run 'ha_rejoin_plan 10.0.0.11'
[ "$OUT" = "diverged" ]
report "ha_rejoin_plan: running as a stale primary -> diverged (rewind)" $?

_r3c="$(sed -n '/^rep_step_3_rejoin_or_clone()/,/^}/p' "$CLI")"
echo "$_r3c" | grep -q 'ha_rejoin_plan ' \
    && echo "$_r3c" | grep -qF 'rejoin not needed, replication left running'
report "repair step 3: an attached standby skips the rejoin entirely" $?

_r3c_div="$(printf '%s\n' "$_r3c" | sed -n '/local database diverged/,/pg_rewind applied/p')"
_r3c_stop="$(printf '%s\n' "$_r3c_div" | grep -n 'svc_stop "\$HA_PG_SERVICE"' | head -n 1 | cut -d: -f1)"
_r3c_rejoin="$(printf '%s\n' "$_r3c_div" | grep -n 'node rejoin --force-rewind' | head -n 1 | cut -d: -f1)"
[ -n "$_r3c_stop" ] && [ -n "$_r3c_rejoin" ] && [ "$_r3c_stop" -lt "$_r3c_rejoin" ]
report "repair step 3: a diverged node is stopped BEFORE 'node rejoin' (0.3.22)" $?

# the real bench 22.10 (old primary returning after the first successful
# failover): 'node rejoin --force-rewind -h <peer>' connected as the OS user
# (postgres) to the peer's 'postgres' database - repmgr builds that connection
# from CLI options only and, unlike 'witness register', does not backfill
# user/dbname from repmgr.conf; the .pgpass postgres entry let the wrong
# connection authenticate, then get_primary_node_id() died on the missing
# repmgr.nodes relation. The rejoin must carry the same explicit identity
# the clone command has always used (-U repmgr -d repmgr).
printf '%s\n' "$_r3c_div" | grep -qF 'node rejoin --force-rewind -h "$(ha_peer_ip)" -U "$HA_REPMGR_USER" -d "$HA_REPMGR_DB"'
report "repair step 3: 'node rejoin' carries -U/-d (repmgr DB, not libpq defaults) (0.3.25)" $?

echo "$_r3c" | grep -q 'ha_pg_adopt_after_rejoin'
report "repair step 3: systemd re-adoption after the rejoin (pg_ctl-started PG)" $?

echo "$_r3c" | grep -qF 'automatic failover returns at step 4'
report "repair step 3 (resume): re-announces that repmgrd is still stopped" $?

# 'node rejoin' started PostgreSQL via pg_ctl: postgres ANSWERS on the
# socket but the unit is inactive -> moved back under systemd
SYSTEMCTL_PG_ACTIVE=3 lib_run '
    HA_PG_SERVICE=postgresql
    ha_pg_adopt_after_rejoin && echo adopted
'
echo "$OUT" | grep -q '^adopted$' && echo "$OUT" | grep -qF 'outside systemd'
report "ha_pg_adopt_after_rejoin: pg_ctl-started PG moved back under systemd" $?

_cj22="$(sed -n '/^cmd_join()/,/^}/p' "$CLI")"
echo "$_cj22" | grep -q 'ha_install_repmgr_dropin' \
    && echo "$_cj22" | grep -q 'ha_install_lsyncd_dropin'
report "join: unit drop-ins converged outside the resumable sequence (0.3.22)" $?

_cr22="$(sed -n '/^cmd_repair()/,/^}/p' "$CLI")"
echo "$_cr22" | grep -q 'ha_install_repmgr_dropin' \
    && echo "$_cr22" | grep -q 'ha_install_lsyncd_dropin'
report "repair: unit drop-ins converged outside the resumable sequence (0.3.22)" $?

# ---------------------------------------------------------------------------
echo "== media seed vs the rrsync directory lock (regression 0.3.23) =="
# the real bench: the 0.3.22 repair on the standby died at step 5 -
# 'rrsync error: Another instance of rrsync is already accessing this
# directory' (rsync exit 13). Upstream rsync 3.2.7's rrsync takes an
# exclusive NON-BLOCKING flock ON THE SYNC DIRECTORY ITSELF: any other
# LIVE instance for that directory blocks every new one until its
# process dies - a hung leftover of an interrupted sync session (the
# outage-day chaos: hard power-off, killed lsyncd mid-push) holds the
# lock indefinitely. The bench's NEXT repair run seeded fine - the
# holder died in between (sshd reaped it). The pull now retries (the
# lock dies WITH its process), names the lock conflict when it sees
# one, and the die message explains the kill-the-holder remedy; the
# doctor warns about a long-lived rrsync instance on the local node.

rm -f "$WORK/rsync.calls" "$WORK/rsync.args"
RSYNC_CALLS_FILE="$WORK/rsync.calls" RSYNC_ARGS_FILE="$WORK/rsync.args" \
RSYNC_FAIL_FIRST=2 RSYNC_OUT="rsync: error (transient)" HA_SEED_RETRY_SLEEP=0 \
HA_SYNC_KEY="$WORK/k" HA_KNOWN_HOSTS="$WORK/kh" HA_SYNC_DIR="/var/lib/freeswitch/storage" \
lib_run 'ha_seed_pull 10.0.0.11 && echo seeded'
echo "$OUT" | grep -q '^seeded$' && [ "$(cat "$WORK/rsync.calls")" = "3" ] \
    && echo "$OUT" | grep -qF 'seed succeeded on attempt 3/5'
report "ha_seed_pull: rides out a transient failure (3rd attempt wins) (0.3.23)" $? "$(echo "$OUT" | tail -1)"

grep -qF -- '-a --delete' "$WORK/rsync.args" \
    && grep -qF 'root@10.0.0.11:.' "$WORK/rsync.args"
report "ha_seed_pull: archive+delete pull of the bare-dot tree root (runtime form)" $?

rm -f "$WORK/rsync.calls"
RSYNC_CALLS_FILE="$WORK/rsync.calls" HA_SEED_ATTEMPTS=2 HA_SEED_RETRY_SLEEP=0 \
RSYNC_FAIL_FIRST=99 \
RSYNC_OUT="/usr/local/bin/rrsync error: Another instance of rrsync is already accessing this directory." \
HA_SYNC_KEY="$WORK/k" HA_KNOWN_HOSTS="$WORK/kh" HA_SYNC_DIR="/var/lib/freeswitch/storage" \
lib_run 'ha_seed_pull 10.0.0.11'
_rc23=$?
[ "$_rc23" != "0" ] && echo "$OUT" | grep -qF 'media seed failed after 2 attempts' \
    && echo "$OUT" | grep -qF 'locked by another rrsync instance (attempt 1/2)' \
    && echo "$OUT" | grep -qF 'ps ax | grep rrsync'
report "ha_seed_pull: exhaustion dies with the hung-instance remedy" "$?"

rm -f "$WORK/rsync.calls"
RSYNC_CALLS_FILE="$WORK/rsync.calls" HA_SYNC_KEY="$WORK/k" HA_KNOWN_HOSTS="$WORK/kh" \
HA_SYNC_DIR="/var/lib/freeswitch/storage" lib_run 'ha_seed_pull 10.0.0.11 && echo seeded'
echo "$OUT" | grep -q '^seeded$' && [ "$(cat "$WORK/rsync.calls")" = "1" ] \
    && ! echo "$OUT" | grep -q 'attempt'
report "ha_seed_pull: a healthy pull succeeds silently on the first try" $?

echo "$_dc" | grep -qF 'no hung rrsync instance (media sync lock free)' \
    && echo "$_dc" | grep -qF "Another instance of rrsync"
report "doctor: a long-lived rrsync instance warns as a media-sync blocker (0.3.23)" $?

# ---------------------------------------------------------------------------
echo "== the failover is not over until the apps are back (regression 0.3.24) =="
# the bench failover test: promote in ~30s end to end (repmgrd consensus
# with the witness, promote.sh cleared the sync names, agent 200, haproxy
# routing, entry point OK with the APP credentials) - and the applications
# still hung: a hard power-off sends no TCP RST, so php-fpm workers and
# FreeSWITCH sat on sockets to the dead peer retransmitting for
# tcp_retries2 (~15-30 minutes) - an endless web-UI spinner and phones
# stuck in 'sip: auth'. promote.sh now restarts the local apps AFTER a
# successful promote (try-restart via sudoers, restart-only verbs,
# tolerant when sudo is absent).

rm -rf "$WORK/lib" "$WORK/sudoers"
HA_LIB_DIR="$WORK/lib" HA_SUDOERS_DIR="$WORK/sudoers" lib_run 'ha_install_promote_sh'
[ -x "$WORK/lib/promote.sh" ] && grep -qF 'sudo -n systemctl try-restart' "$WORK/lib/promote.sh" \
    && grep -q 'for _psh_svc in' "$WORK/lib/promote.sh" \
    && grep -qF 'angie' "$WORK/lib/promote.sh" && grep -qF 'freeswitch' "$WORK/lib/promote.sh" \
    && ! grep -q '@@' "$WORK/lib/promote.sh"
report "ha_install_promote_sh: renders executable, app list resolved (0.3.24)" $? "$(cat "$WORK/lib/promote.sh" 2>/dev/null | head -c 80)"

HA_SUDOERS_DIR="$WORK/sudoers" lib_run 'ha_install_sudoers'
[ -f "$WORK/sudoers/fusionpbx-ha" ] && grep -q 'FUSIONPBX_HA_APPS' "$WORK/sudoers/fusionpbx-ha" \
    && grep -qF '/usr/bin/systemctl try-restart php*-fpm' "$WORK/sudoers/fusionpbx-ha" \
    && grep -qF '/usr/bin/systemctl try-restart angie' "$WORK/sudoers/fusionpbx-ha" \
    && grep -qF '/usr/bin/systemctl try-restart freeswitch' "$WORK/sudoers/fusionpbx-ha" \
    && grep -q 'postgres ALL=(root) NOPASSWD: FUSIONPBX_HA_PGCTL, FUSIONPBX_HA_APPS' "$WORK/sudoers/fusionpbx-ha"
report "sudoers: restart-only app verbs for the promote wrapper (0.3.24)" $?

_ps24="$(cat "$RES/promote.sh.tpl")"
echo "$_ps24" | grep -qF 'if /usr/bin/repmgr standby promote' \
    && echo "$_ps24" | grep -qF 'exit 0' && echo "$_ps24" | grep -qF 'exit 1'
report "promote.sh: promote exit code propagates (no silent success on failure)" $?

# 0.3.14/0.3.16: the doctor quotes the journal tail INLINE when a service
# is down; 0.3.16 removed the start attempt / reset-failed / config
# convergence entirely (read-only diagnostics - configurations belong to
# the installer/repair flows)
echo "$_dc" | grep -Fq 'journalctl -u "$_dc_svc" -n 15'
report "doctor: an inactive service quotes the journal tail inline" $?
if echo "$_dc" | grep -Eq 'systemctl (start|restart|reset-failed|enable) '; then false; else true; fi
report "doctor: NO service start/restart/reset-failed - read-only (0.3.16)" $?

# ---------------------------------------------------------------------------
echo "== cluster.conf generation + loading =="
lib_run '
    HA_CLUSTER_NAME="t-cluster"
    HA_INIT_NODE1_IP="10.0.0.11"; HA_INIT_NODE2_IP="10.0.0.12"; HA_INIT_NODE3_IP="10.0.0.13"
    HA_PG_VERSION="16"
    HA_L1_DB_NAME="fusionpbx"; HA_L1_DB_USER="fusionpbx"; HA_L1_DB_PASSWORD="secretpw123"
    ha_generate_cluster_conf && echo generated
'
echo "$OUT" | grep -q "^generated$" && [ -f "$WORK/etc/cluster.conf" ]
report "cluster.conf generated" $? "$OUT"
[ "$(stat -c %a "$WORK/etc/cluster.conf")" = "600" ]
report "cluster.conf mode 600" $?
grep -q '^HA_SYNC_PUBLIC_KEY="ssh-ed25519 AAAAFAKEPUBLICKEY fusionpbx-ha-sync"$' "$WORK/etc/cluster.conf"
report "sync public key embedded" $?

lib_run 'ha_load_cluster_conf && echo "$HA_CLUSTER_NAME/$HA_PG_VERSION/$HA_REPMGR_USER"'
echo "$OUT" | grep -q "t-cluster/16/repmgr"
report "cluster.conf loads back" $? "$OUT"

bad_conf() {  # name, sed-script
    cp "$WORK/etc/cluster.conf" "$WORK/etc-bad.conf"
    sed -i "$2" "$WORK/etc-bad.conf"
    lib_run 'HA_CLUSTER_CONF="$WORK/etc-bad.conf"; ha_load_cluster_conf' >/dev/null 2>&1
    [ $? != 0 ]; report "$1 rejected" $?
}
bad_conf "missing variable"        's/^HA_HAPROXY_PORT=.*//'
bad_conf "duplicate node IPs"      's/HA_NODE2_IP="10.0.0.12"/HA_NODE2_IP="10.0.0.13"/'
bad_conf "password special chars"  's/^HA_DB_PASSWORD="[^"]*"/HA_DB_PASSWORD="bad pass!"/'
bad_conf "relative HA_SYNC_DIR"    's|^HA_SYNC_DIR=.*|HA_SYNC_DIR="relative/path"|'
bad_conf "non-IPv4 node address"   's/HA_NODE3_IP="10.0.0.13"/HA_NODE3_IP="witness.local"/'

# ---------------------------------------------------------------------------
echo "== token pack/unpack =="
lib_run 'ha_token_pack'
_tok="$OUT"
[ -n "$_tok" ] && [ "$(printf '%s' "$_tok" | wc -l)" = "0" ]
report "token is one non-empty line" $? "${_tok:0:20}..."

lib_run "ha_token_unpack '$_tok' "\$WORK/unpacked.conf" && cmp -s "\$WORK/unpacked.conf" "\$WORK/etc/cluster.conf" && echo roundtrip"
[ "$OUT" = "roundtrip" ]; report "token roundtrip is byte-identical" $?

printf '%s' "$_tok" > "$WORK/token.txt"
lib_run 'ha_token_unpack "@$WORK/token.txt" "$WORK/unpacked2.conf" && cmp -s "$WORK/unpacked2.conf" "$WORK/etc/cluster.conf" && echo fileok'
[ "$OUT" = "fileok" ]; report "@file token form" $?

lib_run 'ha_token_unpack "garbage!!!" "$WORK/x.conf"' >/dev/null 2>&1
[ $? != 0 ]; report "garbage token rejected" $?

# ---------------------------------------------------------------------------
echo "== role detection (stubbed ip: 10.0.0.11) =="
lib_run 'ha_load_cluster_conf; ha_detect_role && echo "$HA_NODE_ID:$HA_ROLE"'
echo "$OUT" | grep -q "1:primary"
report "node 1 detected as primary" $? "$OUT"

lib_run 'ha_load_cluster_conf; ha_detect_role; ha_peer_ip'
[ "$OUT" = "10.0.0.12" ]; report "peer of node 1 is node 2" $?

lib_run 'ha_load_cluster_conf; ha_detect_role; ha_peer_name'
[ "$OUT" = "fpbx-ha-2" ]; report "peer name" $?

# ---------------------------------------------------------------------------
echo "== state machine =="
lib_run 'rm -f "$HA_STATE_FILE" "$HA_MARKER_FILE"; ha_state_begin init; ha_state_step_done 1 one; ha_state_step_done 2 two; ha_state_step_is_done 1 && echo yes'
[ "$OUT" = "yes" ]; report "step recorded and detected" $?

lib_run 'ha_state_step_is_done 3 || echo no'
[ "$OUT" = "no" ]; report "unrecorded step not detected" $?

lib_run 'ha_state_begin join-standby; grep -q "^command=join-standby$" "$HA_STATE_FILE" && echo reset'
[ "$OUT" = "reset" ]; report "different command resets state" $?

lib_run 'ha_state_begin init >/dev/null; ha_state_step_done 1 one; ha_state_finish init; [ -f "$HA_MARKER_FILE" ] && [ ! -f "$HA_STATE_FILE" ] && echo finished'
[ "$OUT" = "finished" ]; report "finish writes marker, removes state" $?

# ---------------------------------------------------------------------------
echo "== ha_run_sequence: subshell, resume, banner =="
cat > "$WORK/steps.sh" <<'EOF'
step_a() { echo "A-ran"; }
step_b() { echo "B-ran"; }
step_c() { echo "C-ran"; }
EOF

lib_run 'rm -f "$HA_STATE_FILE" "$HA_MARKER_FILE"; . "$WORK/steps.sh"; ha_run_sequence t1 step_a step_b'
_seq1="$OUT"
echo "$_seq1" | grep -q "A-ran" && echo "$_seq1" | grep -q "B-ran" && [ -f "$WORK/etc/.installed" ]
report "sequence runs all steps, writes marker" $? "$_seq1"

lib_run 'rm -f "$HA_MARKER_FILE"; . "$WORK/steps.sh"; step_fail() { echo boom >&2; die "intentional"; }; ha_run_sequence t2 step_a step_fail step_b'
_rc=$?; _seq2="$OUT"
[ "$_rc" != 0 ] && echo "$_seq2" | grep -q "STEP 2/3 (step_fail) FAILED" && echo "$_seq2" | grep -q "resume from step 2"
report "failure prints banner + resume hint, exit != 0" "$?" "rc=$_rc $(echo "$_seq2" | head -3)"

lib_run '. "$WORK/steps.sh"; ha_run_sequence t2 step_a step_b step_c'
_seq3="$OUT"
echo "$_seq3" | grep -q "step_a - already done, skipping" && echo "$_seq3" | grep -q "B-ran"
report "resume skips completed step" $?

# cross-step variable propagation via cluster.conf re-source
lib_run 'rm -f "$HA_STATE_FILE" "$HA_MARKER_FILE"; step_write() { echo "HA_TESTVAR=\"fromconf\"" >> "$HA_CLUSTER_CONF"; }; step_read() { [ "$HA_TESTVAR" = "fromconf" ] && echo propagated; }; ha_run_sequence t3 step_write step_read'
echo "$OUT" | grep -q "propagated"
report "step-written conf values propagate to next step" $? "$OUT"

# ---------------------------------------------------------------------------
echo "== managed blocks =="
printf 'existing line\n' > "$WORK/hosts"
lib_run 'ha_block_set "$WORK/hosts" "10.0.0.99 testnode"'
grep -q "10.0.0.99 testnode" "$WORK/hosts" && grep -q "existing line" "$WORK/hosts"
report "block appended, content kept" $?

lib_run 'ha_block_set "$WORK/hosts" "10.0.0.98 othernode"'
[ "$(grep -c "10.0.0.99" "$WORK/hosts")" = "0" ] && grep -q "10.0.0.98 othernode" "$WORK/hosts"
report "re-set replaces the old block (idempotent)" $?

lib_run 'ha_block_present "$WORK/hosts" && echo yes'
[ "$OUT" = "yes" ]; report "block_present detects" $?

# ---------------------------------------------------------------------------
echo "== ha_render =="
lib_run 'ha_render "$RES/haproxy.cfg.tpl" "$WORK/out.cfg" HAPROXY_PORT=5433 AGENT_PORT=8008 NODE1_NAME=n1 NODE1_IP=10.0.0.11 NODE2_NAME=n2 NODE2_IP=10.0.0.12 && echo rendered'
[ "$OUT" = "rendered" ] && [ -f "$WORK/out.cfg" ]
report "render succeeds" $? "$OUT"

lib_run 'ha_render "$RES/haproxy.cfg.tpl" "$WORK/out2.cfg" HAPROXY_PORT=5433' >/dev/null 2>&1
[ $? != 0 ]; report "unresolved placeholders are fatal" $?

# ---------------------------------------------------------------------------
echo "== rrsync handling =="
# NOTE: this test container ships /usr/bin/rrsync itself, so the PATH branch
# may answer before the doc-glob branch. Both outcomes are valid; assert the
# contract: a usable path or a clean fallback.
lib_run 'ha_install_rrsync || echo none'
[ -n "$OUT" ] && [ "$OUT" != "ERROR: FATAL: *" ]
report "returns a usable path or a clean fallback" $? "$OUT"

mkdir -p "$WORK/doc/rsync-3.2.7/support"
echo '#!/usr/bin/env python3' > "$WORK/doc/rsync-3.2.7/support/rrsync"
lib_run 'ha_install_rrsync'
case "$OUT" in
    "$WORK/localbin/rrsync") [ -x "$WORK/localbin/rrsync" ]; _rr=ok ;;
    /usr/bin/rrsync|/usr/local/bin/rrsync) _rr=ok ;;   # PATH variant won
    *) _rr="unexpected: $OUT" ;;
esac
report "doc-path fallback works when PATH has no rrsync" "$_rr" "$OUT"

lib_run 'ha_install_rrsync'
[ -n "$OUT" ] && [ "$OUT" != "none" ]
report "result is stable across calls" $?

# ---------------------------------------------------------------------------
echo "== layer-1 config.conf reader =="
cat > "$WORK/l1.conf" <<'EOF'
; comment
database.0.type = pgsql
database.0.host = 127.0.0.1
database.0.port = 5432
database.0.name = fusionpbx
database.0.username = fusionpbx
database.0.password = goodpass123
EOF
lib_run 'HA_L1_CONF="$WORK/l1.conf"; ha_read_layer1_conf && echo "$HA_L1_DB_USER/$HA_L1_DB_PASSWORD"'
[ "$OUT" = "fusionpbx/goodpass123" ]; report "parses name/user/password" $? "$OUT"

sed -i 's/^database.0.password = .*/database.0.password = bad pass!/' "$WORK/l1.conf"
lib_run 'HA_L1_CONF="$WORK/l1.conf"; ha_read_layer1_conf' >/dev/null 2>&1
[ $? != 0 ]; report "layer-1 password charset validated" $?

# ---------------------------------------------------------------------------
echo "== ha_fix_repmgr_schema_access (regression 0.3.3) =="
# the extension is created by the postgres SUPERUSER, so the schema belongs
# to postgres; the repmgr role needs ownership + grants for any '* register'
export HA_TEST_CAPTURE="$WORK/captured"
fixcap_reset() { rm -rf "$HA_TEST_CAPTURE"; mkdir -p "$HA_TEST_CAPTURE"; }

# primary with the extension: two SQL files (hard grants + best-effort)
fixcap_reset
lib_run 'ha_load_cluster_conf >/dev/null; export FIX_RECOVERY=f FIX_EXT=1; ha_fix_repmgr_schema_access'
report "primary: exits 0" $? "$OUT"
[ -s "$HA_TEST_CAPTURE/1.sql" ] && [ -s "$HA_TEST_CAPTURE/2.sql" ]
report "primary: both SQL files generated" $?
grep -q "ALTER SCHEMA repmgr OWNER TO repmgr;" "$HA_TEST_CAPTURE/1.sql" 2>/dev/null &&
grep -q "GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA repmgr TO repmgr;" "$HA_TEST_CAPTURE/1.sql" &&
grep -q "ALTER DEFAULT PRIVILEGES IN SCHEMA repmgr GRANT ALL PRIVILEGES ON TABLES TO repmgr;" "$HA_TEST_CAPTURE/1.sql"
report "primary: schema ownership + DML grants + default privileges" $?
grep -q "ALTER SEQUENCE repmgr.%I OWNER TO %I" "$HA_TEST_CAPTURE/1.sql" 2>/dev/null &&
grep -q "ALTER TABLE repmgr.%I OWNER TO %I" "$HA_TEST_CAPTURE/1.sql" &&
grep -q "EXCEPTION WHEN OTHERS THEN" "$HA_TEST_CAPTURE/1.sql"
report "primary: per-object ownership transfer (tolerant DO block)" $?
grep -qF 'DO $hfx$' "$HA_TEST_CAPTURE/1.sql" 2>/dev/null &&
grep -qF '$hfx$;' "$HA_TEST_CAPTURE/1.sql" 2>/dev/null
report "primary: DO dollar-tags survive the heredoc" $?
grep -q "GRANT pg_monitor TO repmgr;" "$HA_TEST_CAPTURE/2.sql" 2>/dev/null &&
grep -q "pg_catalog.pg_ls_archivepg_wal" "$HA_TEST_CAPTURE/2.sql" &&
grep -q "pg_catalog.pg_read_binary_file(text, bigint, bigint)" "$HA_TEST_CAPTURE/2.sql"
report "primary: pg_monitor + pg_rewind EXECUTE grants" $?
grep -qF '$HA_' "$HA_TEST_CAPTURE/1.sql" 2>/dev/null && _e=found || _e=ok
grep -qF '$HA_' "$HA_TEST_CAPTURE/2.sql" 2>/dev/null && _e=found
report "primary: no unexpanded shell variables in the SQL" "$_e"
grep -q "ON_ERROR_STOP" "$HA_TEST_CAPTURE/1.args" 2>/dev/null
report "primary: hard block runs with ON_ERROR_STOP" $?
grep -q "ON_ERROR_STOP" "$HA_TEST_CAPTURE/2.args" 2>/dev/null && _o=bad || _o=ok
report "primary: best-effort block without ON_ERROR_STOP" "$_o"
# 0.3.4 regression contract: psql (running as postgres) must never be handed
# a '-f $TMPDIR_FILE' - on ALT the root TMPDIR is per-user private (mode 0700)
if grep -q ' -f ' "$HA_TEST_CAPTURE/1.args" "$HA_TEST_CAPTURE/2.args" 2>/dev/null; then _sf=bad; else _sf=ok; fi
report "primary: SQL fed via stdin, never -f (ALT per-user /tmp)" "$_sf"
# 0.3.17 regression contract: both blocks open with a local-commit guard -
# a stale sync-standby wait must never block (or, for the best-effort
# block, SILENTLY block) the schema grants
grep -q '^SET synchronous_commit = off;$' "$HA_TEST_CAPTURE/1.sql" 2>/dev/null &&
grep -q '^SET synchronous_commit = off;$' "$HA_TEST_CAPTURE/2.sql" 2>/dev/null
report "primary: both SQL blocks commit locally (stale sync-standby proof, 0.3.17)" $?
echo "$OUT" | grep -q "ownership + grants handed"
report "primary: verbose summary" $?

# standby: the local DB is a streaming copy of the primary - no-op skip
fixcap_reset
lib_run 'ha_load_cluster_conf >/dev/null; export FIX_RECOVERY=t FIX_EXT=1; ha_fix_repmgr_schema_access'
report "standby: exits 0 (skip)" $? "$OUT"
[ ! -e "$HA_TEST_CAPTURE/count" ]
report "standby: no SQL generated" $?
echo "$OUT" | grep -q "via replication"
report "standby: skip message" $?

# database without the extension yet: silent no-op
fixcap_reset
lib_run 'ha_load_cluster_conf >/dev/null; export FIX_RECOVERY=f FIX_EXT=0; ha_fix_repmgr_schema_access'
report "no-extension: exits 0 (skip)" $? "$OUT"
[ ! -e "$HA_TEST_CAPTURE/count" ] && ! echo "$OUT" | grep -q "ownership + grants"
report "no-extension: silent no-op" $?

# the hard block fails -> die; the message quotes the real psql error (stderr
# is no longer swallowed) and the inspect hint stays runnable as postgres
fixcap_reset
lib_run 'ha_load_cluster_conf >/dev/null; export FIX_RECOVERY=f FIX_EXT=1 PSQL_F_RC=3; ha_fix_repmgr_schema_access' >/dev/null 2>&1
[ $? != 0 ]; report "psql failure is fatal" $?
echo "$OUT" | grep -q "cannot apply the repmgr extension grants"
report "die message names the kept SQL file" $? "$OUT"
echo "$OUT" | grep -q "stub-injected failure"
report "die message quotes the actual psql error (stderr visible)" $? "$OUT"
echo "$OUT" | grep -q "ON_ERROR_STOP=1 < " && ! echo "$OUT" | grep -q ' -f '
report "inspect hint feeds stdin - runnable as postgres (0.3.4)" $?
_kept="$(echo "$OUT" | sed -n 's/.*kept at \([^ ]*\) -.*/\1/p')"
[ -n "$_kept" ] && [ -f "$_kept" ]
report "failed run keeps the generated SQL for inspection" $?

# the register prelude must run the fix BEFORE anything else - this is the
# wiring that unblocks a resume from a state file written by an old version
fixcap_reset
: > "$WORK/pgdata/pg_hba.conf"
mkdir -p "$WORK/lib" "$WORK/sudoers"
lib_run 'ha_load_cluster_conf >/dev/null; ha_detect_role >/dev/null;
    HA_REPMGR_CONF="$WORK/etc/repmgr.conf" HA_LIB_DIR="$WORK/lib" HA_PROMOTE_SH="$WORK/lib/promote.sh" HA_SUDOERS_DIR="$WORK/sudoers"
    ha_register_prelude primary'
report "prelude: exits 0" $? "$OUT"
[ -s "$HA_TEST_CAPTURE/1.sql" ] && grep -q "ALTER SCHEMA repmgr OWNER TO repmgr;" "$HA_TEST_CAPTURE/1.sql" 2>/dev/null
report "prelude: schema fix executed (register self-heal)" $?

# the prelude must also re-apply .pgpass before every register (0.3.7) -
# on the witness it is the ONLY writer (the unpack step no longer writes
# it: postgresql-server is not installed there yet); a file deleted by
# hand also comes back on the next register/repair
[ -s "$WORK/.pgpass" ] && grep -q "fusionpbx-ha: managed block" "$WORK/.pgpass"
report "prelude: .pgpass re-applied (register self-heal, 0.3.7)" $?
grep -q '^10.0.0.11:5432:\*:postgres:' "$WORK/.pgpass" && grep -q '^10.0.0.12:5432:\*:fusionpbx:' "$WORK/.pgpass"
report "prelude: .pgpass carries the data-role lines" $?
[ "$(stat -c %a "$WORK/.pgpass")" = "600" ]
report "prelude: .pgpass mode 600" $?

# ---------------------------------------------------------------------------
echo "== .pgpass (regression 0.3.7: witness join died at step 2) =="
# the real bench: 'FATAL: cannot write /var/lib/pgsql/.pgpass' in
# wit_step_2_unpack - the witness has no layer 1, postgresql-server is
# installed only by step 3, so the directory did not exist yet

# witness role: repmgr lines only - no postgres/app credentials
rm -f "$WORK/.pgpass"
lib_run 'ha_load_cluster_conf >/dev/null; ha_write_pgpass witness >/dev/null; echo ok'
[ "$OUT" = "ok" ]; report "witness role: write exits 0" $? "$OUT"
grep -q ':repmgr:' "$WORK/.pgpass"
report "witness role: repmgr lines present" $?
if grep -qE ':(postgres|fusionpbx):' "$WORK/.pgpass"; then _pw=bad; else _pw=ok; fi
report "witness role: NO postgres/app credentials" "$_pw"

# the home directory does not exist yet (no postgresql-server): a die that
# names the cause, not bash's bare redirect error from the real bench
rm -f "$WORK/.pgpass"
lib_run 'ha_load_cluster_conf >/dev/null; HA_PGDATA_DEFAULT="$WORK/no-pg/yet" ha_write_pgpass witness' >/dev/null 2>&1
[ $? != 0 ]; report "missing home dir: fatal" $?
echo "$OUT" | grep -q "postgresql-server is not installed yet"
report "missing home dir: die names the cause" $? "$OUT"
[ ! -e "$WORK/no-pg" ]
report "missing home dir: nothing created on the way" $?

# ordering contract on the CLI source: the witness unpack step must not
# write .pgpass (the packages step comes later); the register prelude must
_wit2="$(sed -n '/^wit_step_2_unpack()/,/^}/p' "$CLI")"
if echo "$_wit2" | grep -q 'ha_write_pgpass'; then _pw2=bad; else _pw2=ok; fi
report "wit unpack step: no .pgpass write before the packages step" "$_pw2"
_j2="$(sed -n '/^join_step_2_unpack()/,/^}/p' "$CLI")"
echo "$_j2" | grep -q 'ha_write_pgpass data'
report "standby unpack step: .pgpass still written (layer 1 present)" $?
_pl="$(sed -n '/^ha_register_prelude()/,/^}/p' "$LIB")"
echo "$_pl" | grep -q 'ha_write_pgpass witness'
report "register prelude: witness .pgpass written" $?
echo "$_pl" | grep -q 'ha_write_pgpass data'
report "register prelude: data-node .pgpass written" $?

# ---------------------------------------------------------------------------
echo "== role-agent install/wait (regression 0.3.5) =="
# failing curl -> exactly ONE '000' (the old '|| echo 000' printed two:
# '000\n000' -> '000000' in the step-8 FATAL message on the real bench)
lib_run 'export AGENT_CURL_FAIL=1; c=$(ha_agent_code 127.0.0.1); echo "[$c]"'
[ "$OUT" = "[000]" ]; report "agent probe: single 000 on unreachable (no 000000)" $? "$OUT"

lib_run 'c=$(ha_agent_code 127.0.0.1); echo "[$c]"'
[ "$OUT" = "[200]" ]; report "agent probe: HTTP code passthrough" $? "$OUT"

# the socket appears LATE (2 failed polls) - the installer must WAIT,
# not die on the first probe (the Type=simple race)
mkdir -p "$WORK/systemd" "$WORK/agentlib"
rm -f "$WORK/agent.calls"
lib_run 'export AGENT_CALLS_FILE="$WORK/agent.calls" AGENT_FAIL_FIRST=2
    HA_LIB_DIR="$WORK/agentlib" HA_AGENT_SCRIPT="$WORK/agentlib/role-agent.py"
    HA_SYSTEMD_DIR="$WORK/systemd" HA_AGENT_WAIT=15
    ha_install_agent'
report "install: waits through a slow agent start (2 failed polls)" $? "$OUT"
echo "$OUT" | grep -q "role-agent is answering (HTTP 200)"
report "install: success message with the HTTP code" $?
[ -f "$WORK/systemd/fusionpbx-ha-agent.service" ]
report "install: unit written to HA_SYSTEMD_DIR (sandbox-safe)" $?
_nc="$(cat "$WORK/agent.calls" 2>/dev/null)"
[ -n "$_nc" ] && [ "$_nc" -ge 3 ]
report "install: retried until the socket appeared" $? "calls: ${_nc:-none}"

# the agent never answers -> die, with a single 000 and a working hint
rm -f "$WORK/agent.calls"
lib_run 'export AGENT_CALLS_FILE="$WORK/agent.calls" AGENT_FAIL_FIRST=999
    HA_LIB_DIR="$WORK/agentlib" HA_AGENT_SCRIPT="$WORK/agentlib/role-agent.py"
    HA_SYSTEMD_DIR="$WORK/systemd" HA_AGENT_WAIT=2
    ha_install_agent' >/dev/null 2>&1
[ $? != 0 ]; report "install: agent never answering is fatal" $?
echo "$OUT" | grep -q "not answering on 127.0.0.1:8008 (code: 000)"
report "install: die shows a single 000 code" $? "$OUT"
echo "$OUT" | grep -q "systemctl status fusionpbx-ha-agent"
report "install: die hints systemctl status" $? "$OUT"

# ---------------------------------------------------------------------------
echo "== pg_isready probe verdict (regression 0.3.6) =="
# the join preflight died with a bare "not reachable on port 5432" while
# the real pg_isready verdict ("no response" = firewall drop vs
# "rejecting connections" = server alive but starting/shutting down) was
# discarded (>/dev/null 2>&1)

lib_run 'ha_pg_isready 10.0.0.12 && echo "ok:${HA_PG_ISREADY_MSG:-empty}"'
echo "$OUT" | grep -q "^ok:empty$"
report "probe: success leaves no verdict" $? "$OUT"

lib_run 'export PG_ISREADY_RC=2 PG_ISREADY_OUT="10.0.0.12:5432 - no response"
    ha_pg_isready 10.0.0.12; echo "rc=$? msg=$HA_PG_ISREADY_MSG"'
echo "$OUT" | grep -q "^rc=2 msg=10.0.0.12:5432 - no response$"
report "probe: firewall-drop verdict carried out" $? "$OUT"

lib_run 'export PG_ISREADY_RC=1 PG_ISREADY_OUT="10.0.0.12:5432 - rejecting connections"
    ha_pg_isready 10.0.0.12; echo "rc=$? msg=$HA_PG_ISREADY_MSG"'
echo "$OUT" | grep -q "^rc=1 msg=.*rejecting connections$"
report "probe: rejecting-server verdict carried out" $? "$OUT"

lib_run 'export PG_ISREADY_RC=2 PG_ISREADY_SILENT=1
    ha_pg_isready 10.0.0.12; echo "rc=$? msg=$HA_PG_ISREADY_MSG"'
echo "$OUT" | grep -q "^rc=2 msg=pg_isready exited with code 2$"
report "probe: empty verdict falls back to the exit code" $? "$OUT"

mv "$WORK/fakebin/pg_isready" "$WORK/pg_isready.hidden"
lib_run 'ha_pg_isready 10.0.0.12; echo "rc=$? msg=${HA_PG_ISREADY_MSG:-empty}"'
echo "$OUT" | grep -q "^rc=0 msg=empty$" && echo "$OUT" | grep -q "pg_isready not available"
report "probe: missing tool warns and passes (soft check)" $? "$OUT"
mv "$WORK/pg_isready.hidden" "$WORK/fakebin/pg_isready"

# ---------------------------------------------------------------------------
echo "== cluster firewall (regression 0.3.6) =="
# layer 1 whitelists INPUT WITHOUT the cluster ports -> the HA layer must
# open 22/5432/8008 for the PEER addresses only (own address skipped);
# cluster.conf fixture from the section above: self 10.0.0.11, peers
# 10.0.0.12 (standby) and 10.0.0.13 (witness); own ip-stub reports .11

mkdir -p "$WORK/fw"
: > "$WORK/fw/state"; : > "$WORK/fw/log"

fw_run() {
    lib_run "export IPT_STATE='$WORK/fw/state' IPT_LOG='$WORK/fw/log' HA_IPTABLES_CONF='$WORK/fw/iptables.conf'
        ha_load_cluster_conf >/dev/null
        $1"
}

fw_run 'ha_ensure_cluster_firewall; echo "rc=$?"'
echo "$OUT" | grep -q "^rc=0$"
report "fw: exits 0 on a data node" $? "$OUT"

[ "$(grep -c -- '^-I INPUT' "$WORK/fw/log")" = "6" ]
report "fw: exactly 6 peer rules (2 peers x 22/5432/8008)" $?
grep -qxF -- "-I INPUT 1 -s 10.0.0.12 -p tcp --dport 5432 -j ACCEPT" "$WORK/fw/log"
report "fw: standby peer rule on the PostgreSQL port" $?
grep -qxF -- "-I INPUT 1 -s 10.0.0.13 -p tcp --dport 8008 -j ACCEPT" "$WORK/fw/log"
report "fw: witness peer rule on the agent port" $?
! grep -q -- "-s 10.0.0.11 " "$WORK/fw/log"
report "fw: no rule for the own address" $?
grep -q -- "-s 10.0.0.12 -p tcp --dport 5432 -j ACCEPT" "$WORK/fw/iptables.conf" 2>/dev/null
report "fw: rules persisted the layer-1 way (iptables-save)" $?
echo "$OUT" | grep -q "6 iptables rule(s) added"
report "fw: reports the number of added rules" $? "$OUT"

# re-run: every -C hits -> no further inserts, no duplicates
fw_run 'ha_ensure_cluster_firewall; echo "rc=$?"'
[ "$(grep -c -- '^-I INPUT' "$WORK/fw/log")" = "6" ] && echo "$OUT" | grep -q "^rc=0$"
report "fw: idempotent - re-run inserts nothing" $?
echo "$OUT" | grep -q "peer rules already present"
report "fw: re-run reports 'already present'" $? "$OUT"

# no iptables service and no rules file -> no orphan file is written
# (a bare witness loads nothing from /etc/sysconfig/iptables)
rm -f "$WORK/fw/iptables.conf"
lib_run "export IPT_STATE='$WORK/fw/state' IPT_LOG='$WORK/fw/log' SYSTEMCTL_IS_ENABLED_RC=1
    ha_load_cluster_conf >/dev/null
    ha_ensure_cluster_firewall; echo rc=\$?"
[ ! -f "$WORK/fw/iptables.conf" ] && echo "$OUT" | grep -q "^rc=0$"
report "fw: no iptables service -> no orphan rules file" $? "$OUT"

# firewalld active -> the HA layer does not fight it, warns instead
lib_run "export IPT_STATE='$WORK/fw/state' IPT_LOG='$WORK/fw/log' FIREWALLD_ACTIVE=0
    ha_load_cluster_conf >/dev/null
    ha_ensure_cluster_firewall; echo rc=\$?"
echo "$OUT" | grep -q "firewalld is active" && echo "$OUT" | grep -q "^rc=0$"
report "fw: firewalld active -> warn and skip" $? "$OUT"

# no iptables binary at all -> soft skip, never fatal
mv "$WORK/fakebin/iptables" "$WORK/iptables.hidden"
lib_run "ha_load_cluster_conf >/dev/null; ha_ensure_cluster_firewall; echo rc=\$?"
echo "$OUT" | grep -q "iptables not available" && echo "$OUT" | grep -q "^rc=0$"
report "fw: missing iptables -> warn, not fatal" $? "$OUT"
mv "$WORK/iptables.hidden" "$WORK/fakebin/iptables"

# ---------------------------------------------------------------------------
echo "== pg boot guard (0.3.27) =="

# standalone script behavior: stubbed curl/psql + a rendered-style conf
mkdir -p "$WORK/guardbin" "$WORK/guarddata" "$WORK/guardetc"
cat > "$WORK/guardbin/curl" <<'EOF'
#!/bin/sh
printf '%s' "${GUARD_CURL_CODE:-000}"
EOF
cat > "$WORK/guardbin/psql" <<'EOF'
#!/bin/sh
for _a in "$@"; do
    case "$_a" in
        *pg_is_in_recovery*)
            if [ "${GUARD_PG_STATE:-down}" = "down" ]; then
                echo "psql: error: connection refused" >&2
                exit 2
            fi
            printf '%s' "${GUARD_PG_STATE}"
            exit 0 ;;
    esac
done
exit 0
EOF
chmod +x "$WORK/guardbin/curl" "$WORK/guardbin/psql"

GUARD_CONF="$WORK/guardetc/boot-guard.conf"
cat > "$GUARD_CONF" <<EOF
BG_PEER_IP="10.0.0.12"
BG_PGDATA="$WORK/guarddata"
BG_PG_PORT="5432"
BG_AGENT_PORT="8008"
BG_ATTEMPTS="2"
BG_SLEEP="0"
BG_PG_PASSFILE="/nonexistent"
BG_REPMGR_USER="repmgr"
BG_REPMGR_DB="repmgr"
BG_REPMGR_CONF_PATH="$WORK/guardetc/repmgr.conf"
EOF
: > "$WORK/guardetc/repmgr.conf"

guard_run() {
    OUT=$(PG_BOOT_GUARD_CONF="$GUARD_CONF" PATH="$WORK/guardbin:$PATH" \
        sh "$RES/pg-boot-guard.sh" 2>&1)
    return $?
}

# a standby boot is always unconditional (a standby can never write)
touch "$WORK/guarddata/standby.signal"
guard_run
if [ $? -eq 0 ] && [ -z "$OUT" ]; then _g=0; else _g=1; fi
report "guard: standby.signal -> silent allow" "$_g" "$OUT"
rm -f "$WORK/guarddata/standby.signal"

# an unclustered node (fresh init: no repmgr.conf yet) probes nothing
rm -f "$WORK/guardetc/repmgr.conf"
guard_run
if [ $? -eq 0 ] && [ -z "$OUT" ]; then _g=0; else _g=1; fi
report "guard: no repmgr.conf -> silent allow (first init pays no probe delay)" "$_g" "$OUT"
: > "$WORK/guardetc/repmgr.conf"

# peer role agent 200 = a live primary exists -> BLOCK + repair hint
GUARD_CURL_CODE=200 GUARD_PG_STATE=down guard_run; _g_rc=$?
if [ "$_g_rc" = "1" ] && echo "$OUT" | grep -q "refusing to start a competing primary" \
    && echo "$OUT" | grep -q -- "--repair"; then _g=0; else _g=1; fi
report "guard: peer agent 200 -> BLOCK (a crashed primary cannot return as primary)" "$_g" "$OUT"

# agent silent but the peer's PostgreSQL answers 'not in recovery' -> BLOCK
GUARD_CURL_CODE=000 GUARD_PG_STATE=f guard_run; _g_rc=$?
if [ "$_g_rc" = "1" ] && echo "$OUT" | grep -q "refusing to start a competing primary"; then _g=0; else _g=1; fi
report "guard: peer PG not-in-recovery (agent broken/silent) -> BLOCK" "$_g" "$OUT"

# peer PostgreSQL in recovery = a standby waiting for its primary -> ALLOW
GUARD_CURL_CODE=000 GUARD_PG_STATE=t guard_run
if [ $? -eq 0 ] && echo "$OUT" | grep -q "standby in recovery - starting as its primary"; then _g=0; else _g=1; fi
report "guard: peer standby in recovery -> ALLOW as its primary" "$_g" "$OUT"

# peer entirely unreachable for the whole loop -> sole-survivor ALLOW
GUARD_CURL_CODE=000 GUARD_PG_STATE=down guard_run
if [ $? -eq 0 ] && echo "$OUT" | grep -q "starting as the sole node"; then _g=0; else _g=1; fi
report "guard: peer unreachable -> sole survivor ALLOW with the partition warning" "$_g" "$OUT"

# a missing conf must never brick the boot
OUT=$(PG_BOOT_GUARD_CONF="/nonexistent-guard.conf" sh "$RES/pg-boot-guard.sh" 2>&1)
if [ $? -eq 0 ] && [ -z "$OUT" ]; then _g=0; else _g=1; fi
report "guard: missing conf -> silent allow (never bricks the boot)" "$_g" "$OUT"

# installer: script + rendered secret-free conf + unit drop-in
HA_LIB_DIR="$WORK/lib" HA_SYSTEMD_DIR="$WORK/systemd" lib_run '
    HA_NODE_ID=1
    HA_NODE1_IP="10.0.0.11"; HA_NODE2_IP="10.0.0.12"
    HA_PG_PORT="5432"; HA_AGENT_PORT="8008"
    HA_REPMGR_USER="repmgr"; HA_REPMGR_DB="repmgr"
    HA_REPMGR_CONF="$WORK/etc/repmgr.conf"
    ha_install_pg_boot_guard >/dev/null && echo rc0
'
_g_files=1
if [ -x "$WORK/lib/pg-boot-guard.sh" ] \
    && grep -q '^BG_PEER_IP="10.0.0.12"$' "$WORK/etc/boot-guard.conf" \
    && ! grep -q 'PASSWORD' "$WORK/etc/boot-guard.conf" \
    && grep -q '^ExecStartPre=+/usr/lib/fusionpbx-ha/pg-boot-guard.sh$' \
        "$WORK/systemd/${HA_PG_SERVICE:-postgresql}.service.d/fusionpbx-ha.conf" \
    && echo "$OUT" | grep -q '^rc0$'; then _g_files=0; fi
report "guard install: script + secret-free rendered conf (peer of node 1 = node 2) + ExecStartPre=+ drop-in" "$_g_files" "$OUT"

HA_LIB_DIR="$WORK/lib" HA_SYSTEMD_DIR="$WORK/systemd" lib_run '
    HA_NODE_ID=1
    HA_NODE1_IP="10.0.0.11"; HA_NODE2_IP="10.0.0.12"
    HA_PG_PORT="5432"; HA_AGENT_PORT="8008"
    HA_REPMGR_USER="repmgr"; HA_REPMGR_DB="repmgr"
    HA_REPMGR_CONF="$WORK/etc/repmgr.conf"
    ha_install_pg_boot_guard
'
echo "$OUT" | grep -q "boot guard drop-in up to date"
report "guard install: idempotent (no churn on a healthy node)" "$?" "$(echo "$OUT" | head -2)"

# doctor contract: the guard presence is reported on the data nodes
_dc27="$(sed -n '/^cmd_doctor()/,/^}/p' "$CLI")"
echo "$_dc27" | grep -qF 'PostgreSQL boot guard installed' \
    && echo "$_dc27" | grep -qF 'will boot as a competing primary'
report "doctor: boot guard presence check (0.3.27)" $?

# ---------------------------------------------------------------------------
echo
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
