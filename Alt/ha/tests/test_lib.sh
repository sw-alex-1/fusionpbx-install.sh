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

# stub psql (schema-grant tests): query-aware answers; every -f FILE
# invocation is copied to $HA_TEST_CAPTURE for content assertions
# (PSQL_F_RC: failure exit code for -f calls only)
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
if [ -n "$_f" ]; then
    _cap="${HA_TEST_CAPTURE:-}"
    if [ -n "$_cap" ] && [ -d "$_cap" ]; then
        _n=0
        [ -f "$_cap/count" ] && _n=$(cat "$_cap/count" 2>/dev/null)
        _n=$((_n + 1))
        echo "$_n" > "$_cap/count"
        cp "$_f" "$_cap/$_n.sql"
        printf '%s\n' "$_orig" > "$_cap/$_n.args"
    fi
    [ "${PSQL_F_RC:-0}" != "0" ] && exit "${PSQL_F_RC}"
fi
case "$_q" in
    *pg_is_in_recovery*) echo "${FIX_RECOVERY:-f}" ;;
    *pg_extension*) echo "${FIX_EXT:-1}" ;;
    *listen_addresses*) echo "${FIX_LISTEN:-*}" ;;
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

# stub systemctl: everything succeeds (register prelude reload paths)
cat > "$WORK/fakebin/systemctl" <<'EOF'
#!/bin/sh
exit 0
EOF

chmod +x "$WORK/fakebin/psql" "$WORK/fakebin/runuser" "$WORK/fakebin/systemctl"

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

# the hard block fails -> die, and the message points at the kept SQL file
fixcap_reset
lib_run 'ha_load_cluster_conf >/dev/null; export FIX_RECOVERY=f FIX_EXT=1 PSQL_F_RC=3; ha_fix_repmgr_schema_access' >/dev/null 2>&1
[ $? != 0 ]; report "psql failure is fatal" $?
echo "$OUT" | grep -q "cannot apply the repmgr extension grants"
report "die message names the kept SQL file" $? "$OUT"

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

# ---------------------------------------------------------------------------
echo
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
