#!/bin/bash
# =============================================================================
# CLI tests for Alt/fusionpbx-ha.sh (moved up from Alt/ha/ in 0.3.34) -
# argument handling, command conflict rules, --status/--doctor/--print-token
# flows. The script runs with HA_SANDBOX=1, a sandbox HA_ETC_DIR and a
# fakebin of systemctl/psql/curl/repmgr stubs; nothing touches the real
# system.
# =============================================================================
set -u

REPO="$(cd "$(dirname "$0")/../../.." && pwd)"
SCRIPT="$REPO/Alt/fusionpbx-ha.sh"   # 0.3.34: moved up from Alt/ha/, resources stay in Alt/ha/
WORK=$(mktemp -d /tmp/ha-cli-test.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
report() {
    if [ "$2" = "0" ] || [ "$2" = "ok" ]; then
        PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"
    else
        FAIL=$((FAIL + 1)); printf 'FAIL  %s   %s\n' "$1" "${3:-}"
    fi
}

# ---------------------------------------------------------------------------
# fakebin: system command stubs
# ---------------------------------------------------------------------------
FB="$WORK/fakebin"
mkdir -p "$FB" "$WORK/etc" "$WORK/pgdata" "$WORK/storage/recordings" \
         "$WORK/lib" "$WORK/haproxy.d" "$WORK/pkglib"
echo "16" > "$WORK/pgdata/PG_VERSION"
: > "$WORK/lsyncd.log"
: > "$WORK/hosts-cli"      # /etc/hosts sandbox for any step that reaches it
touch "$WORK/pkglib/repmgr.so"      # 0.3.15: preload write guard target
: > "$WORK/repmgrd.log"             # 0.3.15: doctor repmgrd log tail target
mkdir -p "$WORK/systemd/repmgr.service.d"   # 0.3.15: drop-in sandbox target

cat > "$FB/systemctl" <<'EOF'
#!/bin/sh
# 0.3.15/0.3.16: selective stub - SYSTEMCTL_INACTIVE (space-separated unit
# list) makes those units report is-active=3, so the doctor's read-only
# FAIL branches (inline journal + repmgrd log tails) become reachable.
# 0.3.35: SYSTEMCTL_NNPRIV answers the 'show -p NoNewPrivileges --value'
# probe (the doctor warns when repmgrd cannot elevate).
if [ "$1" = "show" ] && echo "$*" | grep -q "NoNewPrivileges"; then
    echo "${SYSTEMCTL_NNPRIV:-no}"
    exit 0
fi
_unit=""
for _a in "$@"; do
    case "$_a" in
        is-active|is-enabled|start|stop|restart|reload|reset-failed|enable|disable|daemon-reload|--quiet|-q|--no-pager) ;;
        *) _unit="$_a" ;;
    esac
done
case "$1" in
    is-active)
        case " ${SYSTEMCTL_INACTIVE:-} " in
            *" $_unit "*) exit 3 ;;
        esac
        exit 0 ;;
esac
exit 0
EOF

cat > "$FB/timedatectl" <<'EOF'
#!/bin/sh
case "$1" in
    show) echo "${TIMEDATECTL_VALUE:-yes}" ;;
    *) echo "Time zone: n/a" ;;
esac
EOF

# query-aware psql stub (PSQL_RC != 0: no output, like a real failing psql)
cat > "$FB/psql" <<'EOF'
#!/bin/sh
[ "${PSQL_RC:-0}" != "0" ] && exit "$PSQL_RC"
_sql=""; _h=""
while [ $# -gt 0 ]; do
    case "$1" in
        -c|-tAc) _sql="$2"; shift 2 ;;
        -h) _h="$2"; shift 2 ;;
        *) shift ;;
    esac
done
# 0.3.34: the doctor's quorum probes are the ONLY PGPASSFILE-carrying psql
# calls in the CLI flows - PSQL_QUORUM_FAIL lists IPs whose probe dies like
# a real broken link (auth refused while the server still answers TCP)
if [ -n "${PGPASSFILE:-}" ] && [ -n "${PSQL_QUORUM_FAIL:-}" ] \
        && echo ",$PSQL_QUORUM_FAIL," | grep -q ",$_h,"; then
    echo "psql: error: connection to server at \"$_h\", port 5432 failed: fe_sendauth: no password supplied" >&2
    exit 2
fi
case "$_sql" in
    *pg_is_in_recovery*) echo "${PSQL_RECOVERY:-f}" ;;
    *"count(*) FROM pg_stat_replication"*) echo "${PSQL_STREAMING:-1}" ;;
    *sync_state*) echo "${PSQL_SYNCSTATE:-sync}" ;;
    *synchronous_standby_names*) echo "${PSQL_SYNCNAMES:-}" ;;
    # 0.3.15: repmgrd shared memory preload ('-' not ':-' - an EMPTY value
    # must stay empty so the missing-preload doctor path is testable);
    # 0.3.16: PSQL_ALTER_LOG records every ALTER SYSTEM the doctor issues
    # - the read-only contract asserts it stays EMPTY
    *"SHOW shared_preload_libraries"*) echo "${PSQL_PRELOAD-repmgr}" ;;
    *"ALTER SYSTEM SET shared_preload_libraries"*) echo alter >>"${PSQL_ALTER_LOG:-/dev/null}" 2>/dev/null; exit 0 ;;
    *"count(*) FROM repmgr.nodes"*) echo "${PSQL_NODES:-3}" ;;
    *"SELECT type FROM repmgr.nodes"*) echo "${PSQL_NODE_TYPE:-}" ;;
    *"SELECT 1"*) echo 1 ;;
    *"SELECT 1 FROM pg_roles"*) echo 1 ;;
    *"SELECT 1 FROM pg_database"*) echo 1 ;;
    *"SELECT 1 FROM repmgr.nodes WHERE node_id=3"*) echo "${PSQL_NODE3:-1}" ;;
    *"SELECT 1 FROM pg_stat_replication WHERE application_name"*) echo "${PSQL_APPNAME:-1}" ;;
    *"pg_wal_lsn_diff"*) echo "0" ;;
    *"sender_host"*) echo "  upstream: 10.0.0.11  lag bytes: 0" ;;
    *) : ;;
esac
exit "${PSQL_RC:-0}"
EOF

cat > "$FB/runuser" <<'EOF'
#!/bin/sh
[ "$1" = "-u" ] && shift 2
[ "$1" = "--" ] && shift
exec "$@"
EOF

cat > "$FB/repmgr" <<'EOF'
#!/bin/sh
echo "repmgr: stub cluster show"
echo " Member     ID | Role    | SoP | Upstream  | Location | Priority | Status"
echo " * fpbx-ha-1 1  | primary | 0   |           | default  | 100      | running"
echo "   fpbx-ha-2 2  | standby | 0   | fpbx-ha-1 | default  | 100      | running"
echo "   fpbx-witness 3 | witness| 0   | ?         | default  | n/a      | running"
EOF

# curl stub: per-IP answer map CURL_CODES (IP=code,comma-separated), default 200
cat > "$FB/curl" <<'EOF'
#!/bin/sh
_url=""
while [ $# -gt 0 ]; do
    case "$1" in
        http*) _url="$1" ;;
        *) ;;
    esac
    shift
done
_ip="$(echo "$_url" | sed 's|http://\([0-9.]*\):.*|\1|')"
_code="$(echo ",${CURL_CODES:-}," | grep -o ",$_ip=[0-9]*," | cut -d= -f2 | tr -d ',')"
[ -n "$_code" ] || _code="${CURL_DEFAULT:-200}"
echo "$_code"
EOF

cat > "$FB/ip" <<'EOF'
#!/bin/sh
echo "2: eth0    inet ${FAKE_IP:-10.0.0.11}/24 brd 10.0.0.255 scope global eth0"
EOF

# pg_isready stub (0.3.6): PG_ISREADY_RC + PG_ISREADY_OUT control the
# verdict like test_lib.sh (real tool output is quoted in messages now)
cat > "$FB/pg_isready" <<'EOF'
#!/bin/sh
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

# iptables stubs (0.3.6, defensive): cluster-firewall calls are no-ops in
# CLI flows; -C reports "present" so nothing is ever inserted
 cat > "$FB/iptables" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$FB/iptables-save" <<'EOF'
#!/bin/sh
exit 0
EOF

# stub ssh-keygen: fake key pair, no container dependency (test_lib.sh style)
cat > "$FB/ssh-keygen" <<'EOF'
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

# ss: no listeners (init preflight port checks are always free)
cat > "$FB/ss" <<'EOF'
#!/bin/sh
exit 0
EOF

# ping: everything answers instantly (peer probes in init step 1)
cat > "$FB/ping" <<'EOF'
#!/bin/sh
exit 0
EOF

# rpm: nothing is installed; apt-get: no repository -> step 3 (packages)
# fails FAST and deterministically in the sandbox
cat > "$FB/rpm" <<'EOF'
#!/bin/sh
exit 1
EOF
cat > "$FB/apt-get" <<'EOF'
#!/bin/sh
echo "apt-get: stub - no repository in the test sandbox" >&2
exit 100
EOF

for _fb in systemctl timedatectl psql runuser repmgr curl ip pg_isready ssh-keygen ss ping rpm apt-get iptables iptables-save; do
    chmod +x "$FB/$_fb"
done

# ---------------------------------------------------------------------------
# fixture cluster.conf (valid, node 1 = 10.0.0.11)
# ---------------------------------------------------------------------------
cat > "$WORK/etc/cluster.conf" <<'EOF'
HA_CLUSTER_NAME="fpbx-ha"
HA_NODE1_NAME="fpbx-ha-1"; HA_NODE1_IP="10.0.0.11"; HA_NODE1_ROLE="primary"
HA_NODE2_NAME="fpbx-ha-2"; HA_NODE2_IP="10.0.0.12"; HA_NODE2_ROLE="standby"
HA_NODE3_NAME="fpbx-witness"; HA_NODE3_IP="10.0.0.13"; HA_NODE3_ROLE="witness"
HA_PG_VERSION="16"
HA_PG_PORT="5432"
HA_DB_NAME="fusionpbx"
HA_DB_USER="fusionpbx"
HA_DB_PASSWORD="dbpass123"
HA_REPMGR_USER="repmgr"
HA_REPMGR_PASSWORD="reppass456"
HA_REPMGR_DB="repmgr"
HA_HAPROXY_PORT="5433"
HA_AGENT_PORT="8008"
HA_SYNC_DIR="/nonexistent-should-be-overridden"
HA_SYNC_DELAY="5"
HA_SYNC_PRIVATE_KEY_B64="ZmFrZQ=="
HA_SYNC_PUBLIC_KEY="ssh-ed25519 AAAAKEY fusionpbx-ha-sync"
EOF
sed -i "s|/nonexistent-should-be-overridden|$WORK/storage|" "$WORK/etc/cluster.conf"

# 0.3.16: deterministic rrsync location + a HEALTHY authorized_keys
# fixture. The doctor verifies the sync-key line READ-ONLY now, so the
# fixture must exist before any --doctor run; HA_RRSYNC_INSTALL_DIR pins
# rrsync discovery (never the real /usr/local/bin or the host's rrsync)
mkdir -p "$WORK/bin" "$WORK/sshdir"
printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/rrsync"
chmod 755 "$WORK/bin/rrsync"
AK_LINE="from=\"10.0.0.11,10.0.0.12\",command=\"$WORK/bin/rrsync $WORK/storage\",no-pty,no-agent-forwarding,no-X11-forwarding,no-port-forwarding ssh-ed25519 AAAAKEY fusionpbx-ha-sync"
{
    echo "# fusionpbx-ha: managed block"
    echo "# BEGIN fusionpbx-ha (managed)"
    printf '%s\n' "$AK_LINE"
    echo "# END fusionpbx-ha (managed)"
} > "$WORK/sshdir/authorized_keys"
chmod 600 "$WORK/sshdir/authorized_keys"

# 0.3.34: the doctor's static .pgpass coverage fixture (the data-role set
# incl. the witness line - ha_write_pgpass format; in the sandbox the file
# lands next to HA_PGDATA_DEFAULT, i.e. $WORK/.pgpass). A pristine copy is
# kept for the tests that strip a line and restore it after
{
    echo "# fusionpbx-ha: managed block"
    echo "10.0.0.11:5432:*:repmgr:reppass456"
    echo "10.0.0.12:5432:*:repmgr:reppass456"
    echo "10.0.0.13:5432:*:repmgr:reppass456"
    echo "10.0.0.11:5432:*:postgres:dbpass123"
    echo "10.0.0.12:5432:*:postgres:dbpass123"
    echo "10.0.0.11:5432:*:fusionpbx:dbpass123"
    echo "10.0.0.12:5432:*:fusionpbx:dbpass123"
} > "$WORK/.pgpass"
chmod 600 "$WORK/.pgpass"
cp "$WORK/.pgpass" "$WORK/.pgpass.pristine"

# 0.3.35: the boot guard + auto-rejoin fixture (the installer flows die at
# the packages step in the sandbox, so the files never appear on their own;
# the doctor's guard-present branch - and the NoNewPrivileges warning inside
# it - must be reachable)
mkdir -p "$WORK/systemd/postgresql.service.d"
printf '#!/bin/sh\nexit 0\n' > "$WORK/lib/pg-boot-guard.sh"
printf '#!/bin/sh\nexit 0\n' > "$WORK/lib/pg-auto-rejoin.sh"
chmod 755 "$WORK/lib/pg-boot-guard.sh" "$WORK/lib/pg-auto-rejoin.sh"
: > "$WORK/etc/boot-guard.conf"
: > "$WORK/systemd/postgresql.service.d/fusionpbx-ha.conf"

# run the real script in the sandbox. Args after the environment file.
ha_cli() {
    (
        export HA_SANDBOX=1
        export HA_NO_COLOR=1
        export HA_ETC_DIR="$WORK/etc"
        export HA_PGDATA_DEFAULT="$WORK/pgdata"
        export HA_RES_DIR="$REPO/Alt/ha/resources"
        export HA_L1_CONF="$WORK/l1.conf"
        export HA_VARS_XML="$WORK/vars.xml"
        export HA_L1_WEB_CONF="$WORK/web-config.conf"
        export HA_LSYNCD_LOG="$WORK/lsyncd.log"
        export HA_REPMGR_CONF="$WORK/repmgr.conf"
        # 0.3.15: repmgrd log tail + the repmgr.so existence guard target
        export HA_REPMGRD_LOG="$WORK/repmgrd.log"
        export HA_PG_PKGLIBDIR="$WORK/pkglib"
        # 0.3.15: the selective systemctl stub makes the doctor self-heal
        # branches reachable - the drop-in writer must stay in the sandbox
        # (never the real /etc/systemd/system, even when tests run as root)
        export HA_SYSTEMD_DIR="$WORK/systemd"
        export HA_LSYNCD_CONF="$WORK/lsyncd.conf.lua"
        export HA_HAPROXY_CONF_D="$WORK/haproxy.d"
        export HA_HAPROXY_CONF="$WORK/haproxy.d/fusionpbx-ha.cfg"
        export HA_LIB_DIR="$WORK/lib"
        export HA_PROMOTE_SH="$WORK/lib/promote.sh"
        export HA_HAPROXY_MAIN="$WORK/haproxy.d/main.cfg"
        export HA_HOSTS_FILE="$WORK/hosts-cli"
        # 0.3.13/0.3.16: authorized_keys are verified read-only - keep the
        # sandbox paths (never the real /root/.ssh, even when tests run as
        # root); the rrsync location is pinned for the same reason
        export HA_SYNC_SSH_DIR="$WORK/sshdir"
        export HA_RRSYNC_INSTALL_DIR="$WORK/bin"
        # cluster-firewall persistence target (0.3.6): sandbox-safe
        export HA_IPTABLES_CONF="$WORK/iptables.rules"
        # default role-agent answers: node1 primary, node2 standby
        export CURL_CODES="${CURL_CODES:-10.0.0.11=200,10.0.0.12=503}"
        export PATH="$FB:$PATH"
        "$SCRIPT" "$@" 2>&1
    )
}

# ---------------------------------------------------------------------------
echo "== help / argument handling =="
ha_cli --help > "$WORK/out.log"
grep -q "Usage:" "$WORK/out.log" && grep -q -- "--print-token" "$WORK/out.log"
report "--help prints usage (exit $? )" $?

ha_cli > "$WORK/out.log"; _rc=$?
[ "$_rc" = "0" ] && grep -q "Usage:" "$WORK/out.log"
report "no arguments -> help, exit 0" "$?"

ha_cli --frobnicate > "$WORK/out.log" 2>&1; _rc=$?
[ "$_rc" != "0" ]
report "unknown option rejected" "$?"

# ---------------------------------------------------------------------------
echo "== not-configured refusals =="
rm -rf "$WORK/etc-empty"; mkdir -p "$WORK/etc-empty"
(
    export HA_SANDBOX=1 HA_NO_COLOR=1 HA_ETC_DIR="$WORK/etc-empty" HA_RES_DIR="$REPO/Alt/ha/resources" HA_L1_CONF="$WORK/l1.conf"
    export PATH="$FB:$PATH"
    "$SCRIPT" --status
) > "$WORK/out.log" 2>&1; _rc=$?
[ "$_rc" != "0" ] && grep -q "not part of an HA cluster yet" "$WORK/out.log"
report "--status without cluster.conf refuses with hint" "$?" "$(head -1 "$WORK/out.log")"

(
    export HA_SANDBOX=1 HA_NO_COLOR=1 HA_ETC_DIR="$WORK/etc-empty" HA_RES_DIR="$REPO/Alt/ha/resources" HA_L1_CONF="$WORK/l1.conf"
    export PATH="$FB:$PATH"
    "$SCRIPT" --doctor
) > "$WORK/out.log" 2>&1; _rc=$?
[ "$_rc" != "0" ] && grep -q "not part of an HA cluster yet" "$WORK/out.log"
report "--doctor without cluster.conf refuses" "$?"

(
    export HA_SANDBOX=1 HA_NO_COLOR=1 HA_ETC_DIR="$WORK/etc-empty" HA_RES_DIR="$REPO/Alt/ha/resources" HA_L1_CONF="$WORK/l1.conf"
    export PATH="$FB:$PATH"
    "$SCRIPT" --repair
) > "$WORK/out.log" 2>&1; _rc=$?
[ "$_rc" != "0" ] && grep -q -- "--join TOKEN" "$WORK/out.log"
report "--repair without cluster.conf hints --join" "$?"

# ---------------------------------------------------------------------------
echo "== conflict rules (DESIGN.md 5) =="
cp "$WORK/etc/cluster.conf" "$WORK/etc/cluster.conf.bak"
echo "completed_at=now" > "$WORK/etc/.installed"

ha_cli --join SOMETOKEN > "$WORK/out.log" 2>&1; _rc=$?
[ "$_rc" != "0" ] && grep -q "already joined a cluster" "$WORK/out.log" && grep -q -- "--repair" "$WORK/out.log"
report "--join with marker refuses, hints --repair" "$?"

ha_cli --init --node2 10.0.0.12 --node3 10.0.0.13 > "$WORK/out.log" 2>&1; _rc=$?
[ "$_rc" != "0" ] && grep -q "already part of an HA cluster" "$WORK/out.log" && grep -q -- "--init --force" "$WORK/out.log"
report "--init with marker refuses, hints --force" "$?"

rm -f "$WORK/etc/.installed"

ha_cli --init > "$WORK/out.log" 2>&1; _rc=$?
[ "$_rc" != "0" ] && grep -q -- "--init requires --node2" "$WORK/out.log"
report "--init without node args refuses early" "$?"

ha_cli --init --node2 not-an-ip --node3 10.0.0.13 > "$WORK/out.log" 2>&1; _rc=$?
[ "$_rc" != "0" ] && grep -q "not a valid IPv4" "$WORK/out.log"
report "--init with bad IPv4 refuses" "$?"

# ---------------------------------------------------------------------------
echo "== --init preflight: layer 1 required =="
ha_cli --init --node2 10.0.0.12 --node3 10.0.0.13 > "$WORK/out.log" 2>&1; _rc=$?
[ "$_rc" != "0" ] && grep -q "STEP 1/15 (init_step_1_preflight) FAILED" "$WORK/out.log" \
  && grep -q "layer 1 is not installed" "$WORK/out.log" \
  && grep -q "resume from step 1" "$WORK/out.log"
report "--init without layer 1: banner + resume hint" "$?" "$(grep -m1 'layer 1' "$WORK/out.log")"

# re-run must resume, not restart - the state file exists
[ -f "$WORK/etc/.installer-state" ] && grep -q "^command=init$" "$WORK/etc/.installer-state"
report "state file recorded after failed init" $?

# ---------------------------------------------------------------------------
echo "== --init fresh node: steps 1-2 WITHOUT an existing cluster.conf =="
# regression (DESIGN.md changelog 0.3.1): a fresh --init crashed in step 1
# with "HA_HAPROXY_PORT: unbound variable" - the ports live in cluster.conf,
# which is generated in step 2; the same applied to the layer-1 DB
# credentials (read in the step-1 subshell, lost for step 2) and to the node
# list of the hosts block
cat > "$WORK/l1.conf" <<'EOF'
; layer-1 /etc/fusionpbx/config.conf fixture (INI)
[database]
database.0.host = 127.0.0.1
database.0.port = 5432
database.0.name = fusionpbx
database.0.username = fusionpbx
database.0.password = l1pass123
EOF
rm -rf "$WORK/etc-fresh"; mkdir -p "$WORK/etc-fresh"
: > "$WORK/hosts"

ha_init_fresh() {
    (
        export HA_SANDBOX=1 HA_NO_COLOR=1
        export HA_ETC_DIR="$WORK/etc-fresh" HA_RES_DIR="$REPO/Alt/ha/resources"
        export HA_L1_CONF="$WORK/l1.conf" HA_HOSTS_FILE="$WORK/hosts"
        export HA_PGDATA_DEFAULT="$WORK/pgdata"
        export PATH="$FB:$PATH"
        "$SCRIPT" --init --node2 "${1:-10.0.0.12}" --node3 "${2:-10.0.0.13}" --yes
    )
}

ha_init_fresh > "$WORK/out.log" 2>&1
# step 3 (packages) is EXPECTED to fail in the sandbox (stubbed apt-get);
# the regression under test is that steps 1-2 complete cleanly before it
grep -q "STEP 3/15 (init_step_3_packages) FAILED" "$WORK/out.log" \
  && ! grep -Eqi 'unbound|не заданы' "$WORK/out.log"
report "fresh --init: steps 1-2 pass, no unbound variable" "$?" "$(grep -m1 -Ei 'unbound|не заданы' "$WORK/out.log")"

[ -f "$WORK/etc-fresh/cluster.conf" ] \
  && grep -q '^HA_HAPROXY_PORT="5433"$' "$WORK/etc-fresh/cluster.conf" \
  && grep -q '^HA_AGENT_PORT="8008"$' "$WORK/etc-fresh/cluster.conf" \
  && grep -q 'HA_NODE2_IP="10.0.0.12";' "$WORK/etc-fresh/cluster.conf" \
  && grep -q '^HA_DB_PASSWORD="l1pass123"$' "$WORK/etc-fresh/cluster.conf"
report "cluster.conf generated with ports, nodes and layer-1 credentials" $?

grep -q "BEGIN fusionpbx-ha (managed)" "$WORK/hosts" \
  && grep -q "^10.0.0.11 fpbx-ha-1$" "$WORK/hosts" \
  && grep -q "^10.0.0.12 fpbx-ha-2$" "$WORK/hosts" \
  && grep -q "^10.0.0.13 fpbx-witness$" "$WORK/hosts"
report "/etc/hosts managed block written with all three nodes" $?

_tok1="$(grep -E '^[A-Za-z0-9+/=]{100,}$' "$WORK/out.log" | head -1)"
[ -n "$_tok1" ]
report "join token printed during --init" "$?" "${_tok1:0:16}..."
printf '%s' "$_tok1" | base64 -d 2>/dev/null | gunzip -c > "$WORK/unpacked.conf" 2>/dev/null
cmp -s "$WORK/unpacked.conf" "$WORK/etc-fresh/cluster.conf"
report "printed token unpacks to the generated cluster.conf" $?

echo "== --init resume: completed steps are skipped =="
ha_init_fresh > "$WORK/out.log" 2>&1
grep -q "resuming from the state file" "$WORK/out.log" \
  && [ "$(grep -c "already done, skipping" "$WORK/out.log")" = "2" ] \
  && grep -q "STEP 3/15 (init_step_3_packages) FAILED" "$WORK/out.log" \
  && ! grep -q "STEP 1/15" "$WORK/out.log" \
  && ! grep -q "STEP 2/15" "$WORK/out.log"
report "resume: steps 1-2 skipped, fails at 3 only" "$?"

echo "== --init resume with different --node2: cluster.conf wins =="
rm -f "$WORK/etc-fresh/.installer-state"
ha_init_fresh 10.0.0.99 > "$WORK/out.log" 2>&1
grep -q "the cluster.conf values win" "$WORK/out.log" \
  && grep -q "existing $WORK/etc-fresh/cluster.conf kept" "$WORK/out.log" \
  && ! grep -q "STEP 1/15" "$WORK/out.log" && ! grep -q "STEP 2/15" "$WORK/out.log"
report "--node2 mismatch: warning + existing conf kept, steps 1-2 fine" "$?"
_tok2="$(grep -E '^[A-Za-z0-9+/=]{100,}$' "$WORK/out.log" | head -1)"
[ "$_tok1" = "$_tok2" ]
report "token unchanged on resume (no re-generation)" "$?"
! grep -q "^10.0.0.99 " "$WORK/hosts"
report "hosts block not polluted with the rejected address" "$?"

# ---------------------------------------------------------------------------
echo "== --status (healthy fixture) =="
ha_cli --status > "$WORK/out.log" 2>&1; _rc=$?
[ "$_rc" = "0" ] \
  && grep -q "=== Node ===" "$WORK/out.log" \
  && grep -q "fpbx-ha-1 (10.0.0.11)" "$WORK/out.log" \
  && grep -q "role: primary" "$WORK/out.log" \
  && grep -q "=== Replication ===" "$WORK/out.log" \
  && grep -q "OK: connects and reaches the PRIMARY" "$WORK/out.log" \
  && grep -q "10.0.0.11: PRIMARY" "$WORK/out.log" \
  && grep -q "10.0.0.12: standby/down" "$WORK/out.log"
report "--status shows role/replication/entry point/agents" "$?" "$(head -3 "$WORK/out.log")"

echo "== --status on the witness node =="
FAKE_IP=10.0.0.13 ha_cli --status > "$WORK/out.log" 2>&1; _rc=$?
[ "$_rc" = "0" ] && grep -q "fpbx-witness (10.0.0.13)" "$WORK/out.log"
report "--status identifies the witness role" "$?"

echo "== --status when PostgreSQL is down =="
PSQL_RC=2 ha_cli --status > "$WORK/out.log" 2>&1; _rc=$?
[ "$_rc" = "0" ] && grep -q "local PostgreSQL is not reachable" "$WORK/out.log"
report "--status tolerates a down database (read-only)" "$?"

# ---------------------------------------------------------------------------
echo "== --doctor =="
ha_cli --doctor > "$WORK/out.log" 2>&1; _rc=$?
[ "$_rc" = "0" ] \
  && grep -q "time is NTP-synchronized" "$WORK/out.log" \
  && grep -q "local PostgreSQL is up (primary)" "$WORK/out.log" \
  && grep -q "synchronous replication active" "$WORK/out.log" \
  && grep -q "repmgr sees all 3 nodes active" "$WORK/out.log" \
  && grep -qF "quorum link to fpbx-witness (10.0.0.13): authenticated as repmgr" "$WORK/out.log" \
  && grep -qF ".pgpass covers every cluster node" "$WORK/out.log" \
  && grep -q "routes to the primary" "$WORK/out.log" \
  && grep -q "Doctor result: healthy" "$WORK/out.log"
report "--doctor healthy cluster -> exit 0" "$?" "$(grep -c FAIL "$WORK/out.log") failures shown"

echo "== --doctor: frozen writes detection (changelog 0.3) =="
PSQL_STREAMING=0 PSQL_SYNCNAMES="fpbx-ha-2" ha_cli --doctor > "$WORK/out.log" 2>&1; _rc=$?
[ "$_rc" != "0" ] && grep -q "WRITES ARE FROZEN" "$WORK/out.log" && grep -q -- "--repair" "$WORK/out.log"
report "--doctor detects frozen sync (no standby, stale names) -> exit 1" "$?"

echo "== --doctor: async mode (standby gone, names cleared) =="
PSQL_STREAMING=0 PSQL_SYNCNAMES="" ha_cli --doctor > "$WORK/out.log" 2>&1; _rc=$?
[ "$_rc" = "0" ] && grep -q "async mode" "$WORK/out.log"
report "--doctor accepts cleared async mode (warns)" "$?"

echo "== --doctor: witness down =="
# 0.3.34: the witness probe must die like a real down link (PSQL_QUORUM_FAIL)
# before pg_isready classifies it - the psql stub answers SELECT 1 otherwise
PSQL_QUORUM_FAIL="10.0.0.13" PG_ISREADY_RC=2 ha_cli --doctor > "$WORK/out.log" 2>&1; _rc=$?
[ "$_rc" = "0" ] && grep -q "witness 10.0.0.13 unreachable" "$WORK/out.log" \
  && grep -q "automatic failover is DISABLED" "$WORK/out.log"
report "--doctor warns when the witness is unreachable (still healthy)" "$?"

echo "== --doctor: witness verdict quoted (0.3.6) =="
PSQL_QUORUM_FAIL="10.0.0.13" PG_ISREADY_RC=2 PG_ISREADY_OUT="10.0.0.13:5432 - no response" ha_cli --doctor > "$WORK/out.log" 2>&1; _rc=$?
[ "$_rc" = "0" ] \
  && grep -q "unreachable - 10.0.0.13:5432 - no response" "$WORK/out.log"
report "--doctor quotes the pg_isready verdict (firewall vs down)" "$?" "$(grep -m1 'unreachable' "$WORK/out.log")"

echo "== --doctor: witness rejects the repmgr login (0.3.34: the 27.10 outage) =="
# TCP up (pg_isready passes), auth broken: the exact shape that kept the
# standby degraded through a whole primary outage - the pre-0.3.34 doctor
# called this "witness is reachable"
PSQL_QUORUM_FAIL="10.0.0.13" ha_cli --doctor > "$WORK/out.log" 2>&1; _rc=$?
[ "$_rc" = "1" ] \
  && grep -qF "quorum link to fpbx-witness (10.0.0.13): server reachable but the repmgr login FAILED" "$WORK/out.log" \
  && grep -q "fe_sendauth" "$WORK/out.log" \
  && grep -q "qualified majority" "$WORK/out.log" \
  && grep -q -- "--repair" "$WORK/out.log"
report "--doctor FAILS on a reachable-but-rejecting witness (auth, not TCP)" "$?" "$(grep -m1 'quorum link to fpbx-witness' "$WORK/out.log")"

echo "== --doctor: .pgpass without the witness line (0.3.34) =="
# the static coverage check: the file exists but lost the line that broke
# the 27.10 election - caught even while everything else is healthy
grep -v '^10\.0\.0\.13:5432:' "$WORK/.pgpass" > "$WORK/.pgpass.stripped" \
    && mv "$WORK/.pgpass.stripped" "$WORK/.pgpass"
ha_cli --doctor > "$WORK/out.log" 2>&1; _rc=$?
[ "$_rc" = "1" ] && grep -qF ".pgpass lacks the line(s) for: repmgr@fpbx-witness" "$WORK/out.log" \
  && grep -q "never modifies configurations" "$WORK/out.log"
report "--doctor FAILS on a .pgpass without the witness line" "$?" "$(grep -m1 '.pgpass lacks' "$WORK/out.log")"
cp "$WORK/.pgpass.pristine" "$WORK/.pgpass"

echo "== --doctor: .pgpass missing entirely (0.3.34) =="
mv "$WORK/.pgpass" "$WORK/.pgpass.away"
ha_cli --doctor > "$WORK/out.log" 2>&1; _rc=$?
[ "$_rc" = "1" ] && grep -qF ".pgpass missing:" "$WORK/out.log" \
  && grep -q "cannot authenticate to ANY node" "$WORK/out.log"
report "--doctor FAILS on a missing .pgpass" "$?"
mv "$WORK/.pgpass.away" "$WORK/.pgpass"

echo "== --doctor: metadata record says PRIMARY but the server runs as a STANDBY (0.3.35: the 27.10 return) =="
# the auto-rejoin's rejoin failed after repmgr had started the server:
# PostgreSQL up as a standby, the record still 'primary', repmgrd refusing
# to start - the targeted verdict names the fix command
PSQL_RECOVERY=t PSQL_NODE_TYPE=primary ha_cli --doctor > "$WORK/out.log" 2>&1; _rc=$?
[ "$_rc" = "1" ] \
  && grep -qF "the metadata record says this node is PRIMARY but the local server runs as a STANDBY" "$WORK/out.log" \
  && grep -q "node is registered as a primary but running as a" "$WORK/out.log" \
  && grep -q -- "--repair" "$WORK/out.log" \
  && grep -q "never modifies configurations" "$WORK/out.log"
report "--doctor FAILS on record=primary + local=standby with the fix command (0.3.35)" "$?" "$(grep -m1 'metadata record' "$WORK/out.log")"

echo "== --doctor: record says STANDBY but the server is a PRIMARY (0.3.35) =="
# a failover window or a stale record - a WARNING, the doctor stays green
PSQL_RECOVERY=f PSQL_NODE_TYPE=standby ha_cli --doctor > "$WORK/out.log" 2>&1; _rc=$?
[ "$_rc" = "0" ] \
  && grep -qF "the metadata record says STANDBY but the local server is a PRIMARY" "$WORK/out.log"
report "--doctor WARNs on record=standby + local=primary (stays green) (0.3.35)" "$?"

echo "== --doctor: repmgrd cannot elevate (NoNewPrivileges, 0.3.35) =="
# the 27.10 13:57 promote: every sudo from the daemon died instantly - the
# post-promote app restart is dead while the rules are perfectly fine
SYSTEMCTL_NNPRIV=yes ha_cli --doctor > "$WORK/out.log" 2>&1; _rc=$?
[ "$_rc" = "0" ] \
  && grep -qF "repmgr.service resolves NoNewPrivileges=yes" "$WORK/out.log" \
  && grep -q "post-promote app restart dies silently" "$WORK/out.log"
report "--doctor WARNs when repmgrd cannot elevate (NoNewPrivileges=yes) (0.3.35)" "$?"

echo "== --doctor: NTP out of sync =="
TIMEDATECTL_VALUE=no ha_cli --doctor > "$WORK/out.log" 2>&1; _rc=$?
[ "$_rc" != "0" ] && grep -q "time is NOT NTP-synchronized" "$WORK/out.log"
report "--doctor fails on NTP drift" "$?"

echo "== --doctor on the witness (reduced check set) =="
FAKE_IP=10.0.0.13 ha_cli --doctor > "$WORK/out.log" 2>&1; _rc=$?
[ "$_rc" = "0" ] && grep -q "service postgresql active" "$WORK/out.log" \
  && grep -qF "quorum link to fpbx-ha-1 (10.0.0.11): authenticated as repmgr" "$WORK/out.log" \
  && ! grep -q "entry point" "$WORK/out.log"
report "--doctor witness: no haproxy/agent checks, quorum probes still run" "$?"

# ---------------------------------------------------------------------------
echo "== --doctor: repmgr shared memory preload (regression 0.3.15) =="
# Bench: repmgrd died instantly (exit 1, journal silent) since the first
# install - shared_preload_libraries lacked 'repmgr'. 0.3.16: the doctor is
# READ-ONLY diagnostics - it must FAIL with the role-specific fix hint and
# must NOT issue a single ALTER SYSTEM (the config is installer-owned)
: > "$WORK/alter.log"
PSQL_PRELOAD="" PSQL_ALTER_LOG="$WORK/alter.log" ha_cli --doctor > "$WORK/out.log" 2>&1; _rc=$?
[ "$_rc" != "0" ] && grep -q "repmgrd cannot run" "$WORK/out.log" \
  && grep -q -- "--init --force" "$WORK/out.log" \
  && grep -q "never modifies configurations" "$WORK/out.log" \
  && [ ! -s "$WORK/alter.log" ]
report "--doctor: missing preload -> FAIL + fix hint, NO config write" "$?" "$(grep -m1 'shared_preload_libraries' "$WORK/out.log")"

echo "== --doctor: missing preload - role-specific hints =="
PSQL_PRELOAD="" FAKE_IP=10.0.0.12 ha_cli --doctor > "$WORK/out.log" 2>&1; _rc=$?
[ "$_rc" != "0" ] && grep -q -- "--repair --force-clone" "$WORK/out.log"
report "--doctor: standby node gets the re-clone hint" "$?"
PSQL_PRELOAD="" FAKE_IP=10.0.0.13 ha_cli --doctor > "$WORK/out.log" 2>&1; _rc=$?
[ "$_rc" != "0" ] && grep -q -- "--repair (witness" "$WORK/out.log"
report "--doctor: witness node gets the repair hint" "$?"

echo "== --doctor: healthy preload line =="
ha_cli --doctor > "$WORK/out.log" 2>&1; _rc=$?
[ "$_rc" = "0" ] && grep -q "shared_preload_libraries includes repmgr" "$WORK/out.log"
report "--doctor: preloaded node shows the repmgrd-ready OK line" "$?"

echo "== --doctor: repmgrd log tail quoted on service failure (0.3.15/0.3.16) =="
# repmgrd writes its die reason to log_file, NOT to the journal - when the
# service is inactive the doctor quotes journal AND log-file tails inline
# (read-only: no start attempt is made)
printf '[2026-10-19 12:49:51] [ERROR] unable to write to shared memory\n[2026-10-19 12:49:51] [HINT] ensure "shared_preload_libraries" includes "repmgr"\n' > "$WORK/repmgrd.log"
SYSTEMCTL_INACTIVE="repmgr" ha_cli --doctor > "$WORK/out.log" 2>&1; _rc=$?
[ "$_rc" != "0" ] && grep -q "service repmgr NOT active" "$WORK/out.log" \
  && grep -q "repmgrd log tail" "$WORK/out.log" \
  && grep -q "unable to write to shared memory" "$WORK/out.log"
report "--doctor: inactive repmgrd -> FAIL + journal and log-file tails inline" "$?" "$(grep -m1 'repmgrd log tail' "$WORK/out.log")"
: > "$WORK/repmgrd.log"

echo "== --doctor: lsyncd errors from a DEAD instance ignored (0.3.15) =="
# Bench: ssh Permission denied during the boot race at 12:49:48 kept the
# doctor amber forever (tail -100) although the self-heal restart fixed it
# seconds later - only errors AFTER the last '--- Startup ---' count
{
  echo "12:49:44 Normal: --- Startup ---"
  echo "12:49:48 Error: Temporary or permanent failure on startup, Terminating"
  echo "12:49:48 Normal: --- Startup ---"
  echo "12:49:49 Normal: Finished (list)"
} > "$WORK/lsyncd.log"
ha_cli --doctor > "$WORK/out.log" 2>&1; _rc=$?
[ "$_rc" = "0" ] && grep -q "lsyncd log clean (current instance)" "$WORK/out.log" \
  && ! grep -q "lsyncd log contains errors" "$WORK/out.log"
report "--doctor: stale pre-restart lsyncd errors no longer warn" "$?"
{
  echo "12:49:48 Normal: --- Startup ---"
  echo "13:05:11 Error: Temporary or permanent failure, Terminating"
} > "$WORK/lsyncd.log"
ha_cli --doctor > "$WORK/out.log" 2>&1; _rc=$?
# lsyncd log errors are a WARNING, not a failure: the doctor stays green
# (exit 0) but must count and surface the error line
[ "$_rc" = "0" ] && grep -q "errors from the running instance" "$WORK/out.log"
report "--doctor: fresh lsyncd errors (current instance) still warn" "$?"
: > "$WORK/lsyncd.log"
: > "$WORK/repmgrd.log"

echo "== --doctor: lsyncd config drift -> FAIL, config NOT rewritten (0.3.16) =="
# the config belongs to the installer/repair flows: the doctor reports the
# drift and leaves the file byte-identical (the 0.3.12 doctor truncated it
# to zero bytes while trying to help)
printf 'settings = {}\n' > "$WORK/lsyncd.conf.lua"
_lsyn_sum="$(md5sum "$WORK/lsyncd.conf.lua" 2>/dev/null | awk '{print $1}')"
ha_cli --doctor > "$WORK/out.log" 2>&1; _rc=$?
[ "$_rc" != "0" ] && grep -q "lsyncd config DIFFERS from the current template" "$WORK/out.log" \
  && [ "$(md5sum "$WORK/lsyncd.conf.lua" 2>/dev/null | awk '{print $1}')" = "$_lsyn_sum" ] \
  && [ ! -e "$WORK/etc/.lsyncd.conf.doctor" ]
report "--doctor: drifted lsyncd config -> FAIL, file byte-identical after the run" "$?"
rm -f "$WORK/lsyncd.conf.lua"

echo "== --doctor: authorized_keys verified read-only (0.3.16) =="
if [ "$(id -u)" = "0" ]; then
    printf 'garbage\n' > "$WORK/sshdir/authorized_keys"
    _ak_sum="$(md5sum "$WORK/sshdir/authorized_keys" 2>/dev/null | awk '{print $1}')"
    ha_cli --doctor > "$WORK/out.log" 2>&1; _rc=$?
    [ "$_rc" != "0" ] && grep -q "sync-key line missing or stale" "$WORK/out.log" \
      && [ "$(md5sum "$WORK/sshdir/authorized_keys" 2>/dev/null | awk '{print $1}')" = "_ak_sum" ]
    report "--doctor: stale authorized_keys -> FAIL, file byte-identical after the run" "$?"
    # restore the healthy fixture and assert the read-only OK verdict
    {
        echo "# fusionpbx-ha: managed block"
        echo "# BEGIN fusionpbx-ha (managed)"
        printf '%s\n' "$AK_LINE"
        echo "# END fusionpbx-ha (managed)"
    } > "$WORK/sshdir/authorized_keys"
    ha_cli --doctor > "$WORK/out.log" 2>&1; _rc=$?
    [ "$_rc" = "0" ] && grep -q "sync-key line matches the current pattern" "$WORK/out.log"
    report "--doctor: healthy sync-key line -> OK (read-only verification)" "$?"
else
    report "--doctor: authorized_keys read-only checks (skipped: not root)" 0
fi

# ---------------------------------------------------------------------------
echo "== --print-token =="
ha_cli --print-token > "$WORK/out.log" 2>&1; _rc=$?
_tok="$(grep -vE '^(WARNING|ERROR|$)' "$WORK/out.log" | grep -E '^[A-Za-z0-9+/=]+$' | head -1)"
[ "$_rc" = "0" ] && [ -n "$_tok" ]
report "--print-token on node 1 prints the token" "$?" "${_tok:0:16}..."

printf '%s' "$_tok" | base64 -d 2>/dev/null | gunzip -c > "$WORK/unpacked.conf" 2>/dev/null
cmp -s "$WORK/unpacked.conf" "$WORK/etc/cluster.conf"
report "token unpacks to the exact cluster.conf" $?

FAKE_IP=10.0.0.12 ha_cli --print-token > "$WORK/out.log" 2>&1; _rc=$?
[ "$_rc" != "0" ] && grep -q "node 1 only" "$WORK/out.log"
report "--print-token refused on other nodes" "$?"

# ---------------------------------------------------------------------------
echo "== proxy flag plumbing (no proxy in sandbox) =="
ha_cli --doctor --proxy 192.0.2.1:8080 > "$WORK/out.log" 2>&1; _rc=$?
[ "$_rc" = "0" ]
report "--proxy accepted alongside a read-only command" "$?"

ha_cli --init --node2 10.0.0.12 --node3 10.0.0.13 --proxy bad-format > "$WORK/out.log" 2>&1; _rc=$?
[ "$_rc" != "0" ] && grep -q -- "--proxy expects host:port" "$WORK/out.log"
report "--proxy without host:port rejected before any step runs" "$?"

# ---------------------------------------------------------------------------
echo
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
