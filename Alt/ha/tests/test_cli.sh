#!/bin/bash
# =============================================================================
# CLI tests for Alt/ha/fusionpbx-ha.sh - argument handling, command conflict
# rules, --status/--doctor/--print-token flows. The script runs with
# HA_SANDBOX=1, a sandbox HA_ETC_DIR and a fakebin of systemctl/psql/curl/
# repmgr stubs; nothing touches the real system.
# =============================================================================
set -u

REPO="$(cd "$(dirname "$0")/../../.." && pwd)"
SCRIPT="$REPO/Alt/ha/fusionpbx-ha.sh"
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
         "$WORK/lib" "$WORK/haproxy.d"
echo "16" > "$WORK/pgdata/PG_VERSION"
: > "$WORK/lsyncd.log"

cat > "$FB/systemctl" <<'EOF'
#!/bin/sh
case "$1" in
    is-active) exit 0 ;;   # everything active
    *) exit 0 ;;
esac
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
_sql=""
while [ $# -gt 0 ]; do
    case "$1" in
        -c|-tAc) _sql="$2"; shift 2 ;;
        *) shift ;;
    esac
done
case "$_sql" in
    *pg_is_in_recovery*) echo "${PSQL_RECOVERY:-f}" ;;
    *"count(*) FROM pg_stat_replication"*) echo "${PSQL_STREAMING:-1}" ;;
    *sync_state*) echo "${PSQL_SYNCSTATE:-sync}" ;;
    *synchronous_standby_names*) echo "${PSQL_SYNCNAMES:-}" ;;
    *"count(*) FROM repmgr.nodes"*) echo "${PSQL_NODES:-3}" ;;
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

cat > "$FB/pg_isready" <<'EOF'
#!/bin/sh
exit "${PG_ISREADY_RC:-0}"
EOF

for _fb in systemctl timedatectl psql runuser repmgr curl ip pg_isready; do
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
        export HA_LSYNCD_CONF="$WORK/lsyncd.conf.lua"
        export HA_HAPROXY_CONF_D="$WORK/haproxy.d"
        export HA_HAPROXY_CONF="$WORK/haproxy.d/fusionpbx-ha.cfg"
        export HA_LIB_DIR="$WORK/lib"
        export HA_PROMOTE_SH="$WORK/lib/promote.sh"
        export HA_HAPROXY_MAIN="$WORK/haproxy.d/main.cfg"
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
PG_ISREADY_RC=2 ha_cli --doctor > "$WORK/out.log" 2>&1; _rc=$?
[ "$_rc" = "0" ] && grep -q "witness 10.0.0.13 unreachable" "$WORK/out.log" \
  && grep -q "automatic failover is DISABLED" "$WORK/out.log"
report "--doctor warns when the witness is unreachable (still healthy)" "$?"

echo "== --doctor: NTP out of sync =="
TIMEDATECTL_VALUE=no ha_cli --doctor > "$WORK/out.log" 2>&1; _rc=$?
[ "$_rc" != "0" ] && grep -q "time is NOT NTP-synchronized" "$WORK/out.log"
report "--doctor fails on NTP drift" "$?"

echo "== --doctor on the witness (reduced check set) =="
FAKE_IP=10.0.0.13 ha_cli --doctor > "$WORK/out.log" 2>&1; _rc=$?
[ "$_rc" = "0" ] && grep -q "service postgresql active" "$WORK/out.log" \
  && ! grep -q "entry point" "$WORK/out.log"
report "--doctor witness: no haproxy/agent checks" "$?"

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
[ "$_rc" != "0" ]
report "--proxy without host:port rejected" "$?"

# ---------------------------------------------------------------------------
echo
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
