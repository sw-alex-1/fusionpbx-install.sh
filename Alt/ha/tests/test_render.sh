#!/bin/bash
# =============================================================================
# Render tests: every template rendered for every role with fixture values,
# then key lines / structure asserted. No root, no system access.
# =============================================================================
set -u

REPO="$(cd "$(dirname "$0")/../../../.." && pwd)"
RES="$REPO/Alt/ha/resources"
WORK=$(mktemp -d /tmp/ha-render-test.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

export HA_SANDBOX=1 HA_RES_DIR="$RES" HA_ETC_DIR="$WORK/etc" HA_NO_COLOR=1
# shellcheck disable=SC1091
. "$RES/ha-lib.sh"

# fixture cluster values (as ha_load_cluster_conf would set them)
HA_CLUSTER_NAME="fpbx-ha"
HA_NODE1_NAME="fpbx-ha-1"; HA_NODE1_IP="10.0.0.11"; HA_NODE1_ROLE="primary"
HA_NODE2_NAME="fpbx-ha-2"; HA_NODE2_IP="10.0.0.12"; HA_NODE2_ROLE="standby"
HA_NODE3_NAME="fpbx-witness"; HA_NODE3_IP="10.0.0.13"; HA_NODE3_ROLE="witness"
HA_PG_VERSION="16"; HA_PG_PORT="5432"
HA_DB_NAME="fusionpbx"; HA_DB_USER="fusionpbx"; HA_DB_PASSWORD="dbpass123"
HA_REPMGR_USER="repmgr"; HA_REPMGR_PASSWORD="reppass456"; HA_REPMGR_DB="repmgr"
HA_HAPROXY_PORT="5433"; HA_AGENT_PORT="8008"
HA_SYNC_DIR="/var/lib/freeswitch/storage"; HA_SYNC_DELAY="5"
HA_SYNC_PUBLIC_KEY="ssh-ed25519 AAAAKEY fusionpbx-ha-sync"
HA_PGDATA_DEFAULT="$WORK/pgdata"

PASS=0
FAIL=0
report() {
    if [ "$2" = "0" ] || [ "$2" = "ok" ]; then
        PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"
    else
        FAIL=$((FAIL + 1)); printf 'FAIL  %s   %s\n' "$1" "${3:-}"
    fi
}

check_line() {  # file, pattern, name
    grep -Eq "$2" "$1"; report "$3" $? "$(grep -En "$2" "$1" | head -1)"
}
check_absent() {  # file, pattern, name
    ! grep -Eq "$2" "$1"; report "$3" $? "$(grep -En "$2" "$1" | head -1)"
}

echo "== repmgr.conf: primary (node 1) =="
HA_NODE_ID=1
HA_REPMGR_CONF="$WORK/repmgr-1.conf"
ha_render_repmgr_conf primary
check_line "$WORK/repmgr-1.conf" '^node_id=1$' "node_id=1"
check_line "$WORK/repmgr-1.conf" "^node_name='?fpbx-ha-1'?$" "node_name"
check_line "$WORK/repmgr-1.conf" "host=10.0.0.11" "conninfo host"
check_line "$WORK/repmgr-1.conf" "user=repmgr dbname=repmgr" "conninfo user+dbname"
# 0.3.33: NO password in conninfo - repmgr prints it verbatim (WARNING ping
# lines, the pg_rewind --source-server DETAIL); the .pgpass authenticates
check_absent "$WORK/repmgr-1.conf" "password=" "conninfo carries no password (secret stays in .pgpass)"
check_line "$WORK/repmgr-1.conf" "^failover=manual$" "failover=manual (never promoted)"
check_line "$WORK/repmgr-1.conf" "data_directory='$WORK/pgdata'" "PGDATA from detection"
check_absent "$WORK/repmgr-1.conf" "^promote_command|application_name" "no standby-only directives"

echo "== repmgr.conf: standby (node 2) =="
HA_NODE_ID=2
HA_REPMGR_CONF="$WORK/repmgr-2.conf"
ha_render_repmgr_conf standby
check_line "$WORK/repmgr-2.conf" '^node_id=2$' "node_id=2"
check_line "$WORK/repmgr-2.conf" '^failover=automatic$' "failover=automatic"
check_line "$WORK/repmgr-2.conf" "application_name=fpbx-ha-2" "conninfo application_name (design 13.3 / B2)"
check_line "$WORK/repmgr-2.conf" "promote_command='/usr/lib/fusionpbx-ha/promote.sh'" "promote_command points to the wrapper"
check_line "$WORK/repmgr-2.conf" "follow_command=" "follow_command present"
check_line "$WORK/repmgr-2.conf" "monitor_interval_secs=5" "monitor_interval_secs=5 (repmgr 5.x name; RTO design)"
check_absent "$WORK/repmgr-2.conf" "^monitoring_interval" "no legacy monitoring_interval key (repmgr 5.x would ignore it)"
check_absent "$WORK/repmgr-2.conf" "^service_promote_command" "no service_promote_command (repmgr smart promote; a reload would NOT promote)"
check_line "$WORK/repmgr-2.conf" "reconnect_attempts=3" "reconnect_attempts=3"

echo "== repmgr.conf: standby variant for a REBUILT node 1 =="
HA_NODE_ID=1
HA_REPMGR_CONF="$WORK/repmgr-1s.conf"
ha_render_repmgr_conf standby
check_line "$WORK/repmgr-1s.conf" "application_name=fpbx-ha-1" "rebuild case: own node name (design 12.2)"
check_line "$WORK/repmgr-1s.conf" '^failover=automatic$' "rebuild case: automatic failover"

echo "== repmgr.conf: witness (node 3) =="
HA_NODE_ID=3
HA_REPMGR_CONF="$WORK/repmgr-3.conf"
ha_render_repmgr_conf witness
check_line "$WORK/repmgr-3.conf" '^node_id=3$' "node_id=3"
check_line "$WORK/repmgr-3.conf" '^failover=manual$' "witness never promotes"
check_absent "$WORK/repmgr-3.conf" "^promote_command" "no promote_command"

echo "== haproxy fragment =="
HA_HAPROXY_CONF_D="$WORK/haproxy.d"
HA_HAPROXY_CONF="$HA_HAPROXY_CONF_D/fusionpbx-ha.cfg"
ha_render_haproxy_conf
_cfg="$HA_HAPROXY_CONF_D/fusionpbx-ha.cfg"
check_line "$_cfg" '^    bind 127.0.0.1:5433$' "bind 127.0.0.1:5433 (localhost only)"
check_line "$_cfg" 'http-check send meth GET uri /primary' "HTTP probe /primary"
check_line "$_cfg" 'check port 8008' "health check port = agent port"
check_line "$_cfg" 'server fpbx-ha-1 10.0.0.11:5432 check' "backend node 1"
check_line "$_cfg" 'server fpbx-ha-2 10.0.0.12:5432 check' "backend node 2"
check_line "$_cfg" 'timeout client 1d' "long-lived SQL: client timeout"
check_line "$_cfg" 'timeout server 1d' "long-lived SQL: server timeout"
check_line "$_cfg" 'timeout connect 3s' "LAN connect timeout (0.3.26)"
check_line "$_cfg" 'rise 2 ' "two consecutive 200s before rotation (0.3.26 anti-flap)"
check_line "$_cfg" 'on-marked-down shutdown-sessions' "sessions to a backend leaving rotation are killed: app gets RST, reconnects to the current primary (0.3.26)"
check_line "$_cfg" '^    mode tcp$' "mode tcp"

echo "== lsyncd configuration =="
HA_LSYNCD_CONF="$WORK/lsyncd.conf.lua"
ha_render_lsyncd_conf 10.0.0.12
# 0.3.13: the hardened rrsync family has two arg mappings; the ALT build is
# CWD-relative (lstrip) and rejects '/' outright ('unsafe arg') - the only
# portable client form is the bare dot, which rrsync skips in validation
# ('arg != .'); the explicit source slash pins the contents-sync semantics
check_line "$HA_LSYNCD_CONF" 'target *= *"root@10.0.0.12:."' "push target = the peer's rrsync tree root (:.)"
check_line "$HA_LSYNCD_CONF" 'source *= *"/var/lib/freeswitch/storage/"' "source carries the contents slash"
check_line "$HA_LSYNCD_CONF" 'delete *= *true' "delete=true (UI deletions propagate)"
check_line "$HA_LSYNCD_CONF" 'delay *= *5' "delay from cluster.conf"
check_line "$HA_LSYNCD_CONF" '/etc/fusionpbx-ha/sync_key' "dedicated sync key"
check_line "$HA_LSYNCD_CONF" 'StrictHostKeyChecking=accept-new' "TOFU known_hosts (design 6.3)"
check_line "$HA_LSYNCD_CONF" 'statusFile *= *"/var/log/lsyncd/lsyncd.status"' "status file (doctor reads it)"
# structural: braces balanced
_o=$(grep -o '{' "$HA_LSYNCD_CONF" | wc -l); _c=$(grep -o '}' "$HA_LSYNCD_CONF" | wc -l)
[ "$_o" = "$_c" ]
report "lua braces balanced ($_o/$_c)" $?
# mirror direction: node 1 pushes to node 2
ha_render_lsyncd_conf 10.0.0.11 > /dev/null
check_line "$HA_LSYNCD_CONF" 'root@10.0.0.11:' "mirror direction rendered"

echo "== promote.sh wrapper =="
HA_PROMOTE_SH="$WORK/promote.sh"
HA_LIB_DIR="$WORK/lib"
ha_install_promote_sh
check_line "$HA_PROMOTE_SH" "postgresql.auto.conf" "clears sync names in postgresql.auto.conf (ALTER SYSTEM is refused during recovery)"
check_line "$HA_PROMOTE_SH" "synchronous_standby_names = ''" "sets synchronous_standby_names to empty"
check_absent "$HA_PROMOTE_SH" "ALTER SYSTEM SET" "no ALTER SYSTEM (impossible on a standby in recovery)"
check_line "$HA_PROMOTE_SH" "pg_reload_conf" "reloads configuration"
check_line "$HA_PROMOTE_SH" "if /usr/bin/repmgr standby promote" "delegates to repmgr promote (exit code preserved)"
sh -n "$HA_PROMOTE_SH"
report "promote.sh passes sh -n" $?
# 0.3.24: post-promote application restart - see the 0.3.24 bench story
# (hard power-off sends no RST; app sockets to the dead peer hang for
# tcp_retries2 ~15-30 minutes)
check_line "$HA_PROMOTE_SH" 'for _psh_svc in' "restarts the local app services"
check_line "$HA_PROMOTE_SH" 'sudo -n systemctl try-restart' "app restart via sudoers, try-restart verb (restart-only)"
check_line "$HA_PROMOTE_SH" 'angie' "app list: angie"
check_line "$HA_PROMOTE_SH" 'freeswitch' "app list: freeswitch"
check_line "$HA_PROMOTE_SH" 'could not restart' "restart failure is a warning, never a failed promote"
if grep -q '@@' "$HA_PROMOTE_SH"; then false; else true; fi
report "promote.sh rendered with no unresolved placeholders" $?
_ps_cl="$(grep -n "synchronous_standby_names = ''" "$HA_PROMOTE_SH" | head -1 | cut -d: -f1)"
_ps_pr="$(grep -n 'repmgr standby promote' "$HA_PROMOTE_SH" | head -1 | cut -d: -f1)"
_ps_rs="$(grep -n 'sudo -n systemctl try-restart' "$HA_PROMOTE_SH" | head -1 | cut -d: -f1)"
[ -n "$_ps_cl" ] && [ -n "$_ps_pr" ] && [ -n "$_ps_rs" ] && [ "$_ps_cl" -lt "$_ps_pr" ] && [ "$_ps_pr" -lt "$_ps_rs" ]
report "promote.sh order: clear sync names -> promote -> restart apps" $?

echo "== role-agent and systemd unit =="
python3 -m py_compile "$RES/role-agent.py"
report "role-agent.py compiles" $?
check_line "$RES/fusionpbx-ha-agent.service" 'ExecStart=/usr/bin/python3 /usr/lib/fusionpbx-ha/role-agent.py' "unit ExecStart"
check_line "$RES/fusionpbx-ha-agent.service" '^Restart=always$' "unit restart policy"
check_line "$RES/role-agent.py" '"/primary"' "agent serves only /primary"
check_line "$RES/role-agent.py" 'pg_is_in_recovery' "checks recovery state"

echo
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
