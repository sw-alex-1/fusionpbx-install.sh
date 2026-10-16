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
    *pg_is_in_recovery*) echo "${FIX_RECOVERY:-f}" ;;
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
    *"SHOW synchronous_standby_names"*) echo "${PSQL_SYNCNAMES:-}" ;;
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
_rs9="$(echo "$_j9" | grep -n 'rsync ' | head -1 | cut -d: -f1)"
[ -n "$_jr9" ] && [ -n "$_rs9" ] && [ "$_jr9" -lt "$_rs9" ]
report "join step 9: local media dir ensured before the seed rsync" $?
_p3="$(sed -n '/^prp_step_3_services()/,/^}/p' "$CLI")"
_pd3="$(echo "$_p3" | grep -n 'ha_ensure_sync_dir' | head -1 | cut -d: -f1)"
_pl3="$(echo "$_p3" | grep -n 'ha_render_lsyncd_conf' | head -1 | cut -d: -f1)"
[ -n "$_pd3" ] && [ -n "$_pl3" ] && [ "$_pd3" -lt "$_pl3" ]
report "repair-primary: media dir ensured before lsyncd" $?

# ---------------------------------------------------------------------------
echo "== media path form over rrsync (regression 0.3.12) =="
# The forced rrsync-command on the peer has NO -absolute flag: a client path
# with a leading '/' is served RELATIVE to the restricted root ($HA_SYNC_DIR)
# - rrsync maps the arg onto <root><arg>. The pre-0.3.12 seed spec
# root@peer:$HA_SYNC_DIR/ doubled into $HA_SYNC_DIR/$HA_SYNC_DIR/: realpath
# is non-strict, the doubled path passed the 'unsafe arg' check and the
# sender-side open died ENOENT on every pull ('post-realpath open failed
# (race detected)' - the exact bench death; 0.3.11's step-race was real but
# secondary: that path form could never succeed). The seed must pull ':/' -
# the root of the peer's restricted tree. The lsyncd template carries the
# same fix, and --doctor converges configs rendered by older script
# versions (an initialized node never re-runs init step 14).
echo "$_j9" | grep -Fq '"root@$(ha_peer_ip):/"'
report "join step 9: pulls the rrsync tree root (:/), not an absolute path" $?
if echo "$_j9" | grep -Fq 'ha_peer_ip):$HA_SYNC_DIR'; then false; else true; fi
report "join step 9: no absolute \$HA_SYNC_DIR remote spec left" $?
grep -Fq 'source    = "@@SYNC_DIR@@/"' "$RES/lsyncd.conf.lua.tpl"
report "lsyncd template: source pins the contents slash" $?
grep -Fq 'target    = "root@@@PEER_IP@@:/"' "$RES/lsyncd.conf.lua.tpl"
report "lsyncd template: target is the rrsync tree root (:/)" $?
_dc="$(sed -n '/^cmd_doctor()/,/^}/p' "$CLI")"
_dc_ck="$(echo "$_dc" | grep -n 'lsyncd.conf.lua.tpl' | head -1 | cut -d: -f1)"
_dc_rs="$(echo "$_dc" | grep -n 'systemctl restart "$HA_LSYNCD_SERVICE"' | head -1 | cut -d: -f1)"
[ -n "$_dc_ck" ] && [ -n "$_dc_rs" ] && [ "$_dc_ck" -lt "$_dc_rs" ]
report "doctor: re-renders a stale lsyncd config and restarts the daemon" $?

# live rrsync semantics (the same hardened wrapper class ALT ships - skip
# when the test host has none): the bench's absolute form reproduces the
# exact bench death; '/' passes validation and reaches the server exec
_rr_bin="$(command -v rrsync 2>/dev/null || true)"
[ -z "$_rr_bin" ] && [ -x /usr/bin/rrsync ] && _rr_bin=/usr/bin/rrsync
rm -rf "$WORK/rr"; mkdir -p "$WORK/rr/root"
if [ -n "$_rr_bin" ]; then
    _rr_out="$(SSH_ORIGINAL_COMMAND='rsync --server --sender . /var/lib/freeswitch/storage/' \
        "$_rr_bin" "$WORK/rr/root" </dev/null 2>&1)"; _rr_rc=$?
    [ "$_rr_rc" -ne 0 ] && echo "$_rr_out" | grep -q 'post-realpath open failed'
    report "rrsync live: the absolute path form doubles and dies ENOENT" "$?" "${_rr_out:-}"
    _rr_out="$(SSH_ORIGINAL_COMMAND='rsync --server --sender . /' \
        "$_rr_bin" "$WORK/rr/root" </dev/null 2>&1 | tr -d '\0')"
    if echo "$_rr_out" | grep -q 'post-realpath open failed\|unsafe arg'; then false; else true; fi
    report "rrsync live: '/' (the restricted tree root) passes validation" "$?" "${_rr_out:-}"
else
    report "rrsync live: the absolute path form doubles and dies ENOENT (skipped: no rrsync on the test host)" 0
    report "rrsync live: '/' (the restricted tree root) passes validation (skipped: no rrsync on the test host)" 0
fi

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
echo
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
