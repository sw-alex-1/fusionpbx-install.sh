#!/bin/sh

# fusionpbx-ha.sh - FusionPBX HA cluster add-on for ALT Linux (layer 2)
#
# Turns three prepared VMs into a repmgr + witness HA cluster:
#   VM1, VM2 (data)   : FusionPBX + PostgreSQL + repmgrd + haproxy + lsyncd
#   VM3    (witness)  : tiny PostgreSQL (repmgr metadata only) + repmgrd
#
# Layer 1 (the installer in Alt/) is NOT modified: it installs a standalone
# FusionPBX node; this script clusters already installed nodes.
# Full design: Alt/ha/DESIGN.md. Operations manual: Alt/ha/RUNBOOK.md.
#
# Commands:
#   fusionpbx-ha.sh --init --node2 IP --node3 IP [--cluster-name NAME]
#   fusionpbx-ha.sh --join TOKEN            # TOKEN = string or @file
#   fusionpbx-ha.sh --repair [--force-clone]
#   fusionpbx-ha.sh --status
#   fusionpbx-ha.sh --doctor
#   fusionpbx-ha.sh --print-token           # re-print the join token (node 1)
#
# Common flags:
#   --yes        non-interactive (answers all confirmations with yes)
#   --force      ignore the step state file (full pass over installed state)
#   --no-color   no ANSI colors
#   --verbose    shell trace (set -x)
#   --proxy H:P  outbound internet through an HTTP(S) proxy (same semantics
#                as the layer-1 install.sh; cluster traffic goes direct)
#
# Safety properties (DESIGN.md section 7):
#   - every step is idempotent; a failed command is re-run with the SAME
#     arguments and resumes from the failed step
#   - the completion marker (.installed) is written only after a command
#     completes fully
#   - no installation-time SSH between nodes: nodes coordinate themselves
#     by polling cluster state (repmgr metadata / role agents)

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HA_RES_DIR="$SCRIPT_DIR/resources"

# shellcheck disable=SC1091
. "$HA_RES_DIR/ha-lib.sh"

# =============================================================================
# Argument parsing (layer-1 arguments.sh pattern)
# =============================================================================

HA_COMMAND=""
HA_JOIN_TOKEN=""
HA_CONFIG_FILE=""
HA_INIT_NODE2_IP=""
HA_INIT_NODE3_IP=""
HA_CLUSTER_NAME="fpbx-ha"
HA_FORCE_CLONE=false
HA_FORCE_RUN=0
HA_VERBOSE=0
PROXY_SERVER=""

ARGS=$(getopt -n "fusionpbx-ha.sh" \
    -o h \
    -l help,init,join:,config:,repair,status,doctor,print-token,yes,force,no-color,verbose,force-clone,proxy:,node2:,node3:,cluster-name: \
    -- "$@") || { error "failed parsing command line options"; exit 1; }

eval set -- "$ARGS"
while true; do
    case "$1" in
        --init)          HA_COMMAND="init"; shift ;;
        --join)          HA_COMMAND="join"; HA_JOIN_TOKEN="$2"; shift 2 ;;
        --config)        HA_CONFIG_FILE="$2"; shift 2 ;;
        --repair)        HA_COMMAND="repair"; shift ;;
        --status)        HA_COMMAND="status"; shift ;;
        --doctor)        HA_COMMAND="doctor"; shift ;;
        --print-token)   HA_COMMAND="print-token"; shift ;;
        --yes)           HA_AUTO_YES=1; shift ;;
        --force)         HA_FORCE_RUN=1; shift ;;
        --force-clone)   HA_FORCE_CLONE=true; shift ;;
        --no-color)      HA_NO_COLOR=1; shift ;;
        --verbose)       HA_VERBOSE=1; shift ;;
        --proxy)         PROXY_SERVER="$2"; shift 2 ;;
        --node2)         HA_INIT_NODE2_IP="$2"; shift 2 ;;
        --node3)         HA_INIT_NODE3_IP="$2"; shift 2 ;;
        --cluster-name)  HA_CLUSTER_NAME="$2"; shift 2 ;;
        -h|--help)       HA_COMMAND="help"; shift ;;
        --)              shift; break ;;
        *)               break ;;
    esac
done
[ -z "${HA_AUTO_YES:-}" ] && HA_AUTO_YES=0
[ "$HA_FORCE_RUN" = "1" ] && export HA_FORCE=1
[ "$HA_VERBOSE" = "1" ] && set -x

ha_print_help() {
    cat <<'HELP'
fusionpbx-ha.sh - FusionPBX HA cluster add-on for ALT Linux

Usage:
  fusionpbx-ha.sh --init --node2 IP --node3 IP [--cluster-name NAME]
      On the FIRST data node (VM1): accept the standalone FusionPBX
      installation as the cluster primary, print the join token, then wait
      for the witness and the standby to join.

  fusionpbx-ha.sh --join TOKEN
      On VM2/VM3 (or a rebuilt node): join the cluster. The role is picked
      automatically by matching the local IP with the node list inside the
      token. TOKEN is the printed string or @/path/to/file.

  fusionpbx-ha.sh --repair [--force-clone]
      Return a node to the cluster after a failure/rebuild/replacement.
      Uses the local /etc/fusionpbx-ha/cluster.conf; the token is not needed.
      --force-clone: wipe the local PGDATA and re-clone from the primary
      (use when the local data directory is damaged or brand new).

  fusionpbx-ha.sh --status
      Compact live summary (read-only).

  fusionpbx-ha.sh --doctor
      Deep health check with an exit code for monitoring (0 = healthy).

  fusionpbx-ha.sh --print-token
      Re-print the join token (only on node 1, where --init was run).

Common flags:
  --yes            non-interactive; all confirmations answered with yes
  --force          re-run all steps, ignoring the progress state file
  --force-clone    (with --repair) full re-clone of the local database
  --no-color       plain output
  --verbose        shell execution trace (debugging)
  --proxy host:port  outbound internet through an HTTP(S) proxy
                   (same flag and semantics as the layer-1 install.sh)

Files:
  /etc/fusionpbx-ha/cluster.conf    cluster configuration (secrets!)
  /etc/fusionpbx-ha/.installed      completion marker
  /etc/fusionpbx-ha/.installer-state  progress of an unfinished command

Documentation: Alt/ha/DESIGN.md (design), Alt/ha/RUNBOOK.md (operations).
HELP
}

# =============================================================================
# Common checks
# =============================================================================

ha_require_root_and_alt() {
    if [ "${HA_SANDBOX:-0}" = "1" ]; then
        return 0
    fi
    [ "$(id -u)" = "0" ] || die "this script must run as root"
    [ -f /etc/altlinux-release ] || die "this is not an ALT Linux system (/etc/altlinux-release not found)"
}

# soft reachability probe: pg_isready when available, silence otherwise
ha_pg_isready() {
    _hpr_ip="$1"
    if cmd_exists pg_isready; then
        pg_isready -h "$_hpr_ip" -p "$HA_PG_PORT" -t 3 >/dev/null 2>&1
        return $?
    fi
    warn "pg_isready not available - skipping the reachability check for $_hpr_ip"
    return 0
}

ha_port_free() {
    _hpf_port="$1"
    if cmd_exists ss; then
        ss -ltnH 2>/dev/null | awk '{print $4}' | grep -q ":$_hpf_port$" && return 1
        return 0
    fi
    if cmd_exists netstat; then
        netstat -ltn 2>/dev/null | awk '{print $4}' | grep -q ":$_hpf_port$" && return 1
        return 0
    fi
    warn "cannot check whether port $_hpf_port is free (ss/netstat missing)"
    return 0
}

# =============================================================================
# --init : step functions (VM1, primary) - DESIGN.md section 8.1
# =============================================================================

init_step_1_preflight() {
    ha_require_root_and_alt

    [ -n "$HA_INIT_NODE2_IP" ] || die "--init requires --node2 IP (the second data node)"
    [ -n "$HA_INIT_NODE3_IP" ] || die "--init requires --node3 IP (the witness node)"
    valid_ip "$HA_INIT_NODE2_IP" || die "--node2 is not a valid IPv4 address: $HA_INIT_NODE2_IP"
    valid_ip "$HA_INIT_NODE3_IP" || die "--node3 is not a valid IPv4 address: $HA_INIT_NODE3_IP"

    ha_read_layer1_conf \
        || die "layer 1 is not installed on this node (no readable $HA_L1_CONF).
Run the standard installer first (see the repository README), configure the
PBX (domains, extensions, users) - the database of the second node will be
replaced with a clone of THIS one."

    pg_runuser_psql -tAc "SELECT 1" >/dev/null 2>&1 \
        || die "local PostgreSQL is not running or not accessible (runuser psql failed)"
    ha_local_is_primary \
        || die "the local PostgreSQL is in recovery or unreadable - --init needs a healthy standalone primary"

    if ! ha_state_step_is_done 1; then
        ha_port_free "$HA_HAPROXY_PORT" || die "port $HA_HAPROXY_PORT is already in use (haproxy frontend)"
        ha_port_free "$HA_AGENT_PORT" || die "port $HA_AGENT_PORT is already in use (role agent)"
    fi

    if cmd_exists ping; then
        ping -c 1 -W 2 "$HA_INIT_NODE2_IP" >/dev/null 2>&1 || warn "$HA_INIT_NODE2_IP does not answer ping (may be firewalled - continuing)"
        ping -c 1 -W 2 "$HA_INIT_NODE3_IP" >/dev/null 2>&1 || warn "$HA_INIT_NODE3_IP does not answer ping (may be firewalled - continuing)"
    else
        warn "ping not available - skipping the peer reachability check"
    fi

    svc_active sshd 2>/dev/null || warn "sshd is not running - the media sync (lsyncd) requires SSH between the data nodes"
    verbose "  preflight OK: node1=$HA_INIT_NODE1_IP node2=$HA_INIT_NODE2_IP witness=$HA_INIT_NODE3_IP PG=$HA_PG_VERSION"
}

init_step_2_config_gen() {
    if [ -f "$HA_CLUSTER_CONF" ] && [ "${HA_FORCE:-0}" != "1" ]; then
        verbose "  existing $HA_CLUSTER_CONF kept (resume/repair) - the token stays unchanged"
        # shellcheck disable=SC1090
        . "$HA_CLUSTER_CONF"
    elif [ -f "$HA_CLUSTER_CONF" ] && [ "${HA_FORCE:-0}" = "1" ]; then
        warn "--force: generating a NEW cluster.conf (new passwords, new token!)"
        ha_generate_cluster_conf
    else
        ha_generate_cluster_conf
    fi
    ha_write_etc_hosts_block
    ha_apply_no_proxy

    # print the token immediately (DESIGN.md 6.2): the operator walks to
    # VM2/VM3 while this command keeps waiting for them
    _icg_token="$(ha_token_pack)"
    echo ""
    verbose "========================================================================="
    verbose " JOIN TOKEN - enter it on $HA_INIT_NODE2_IP and $HA_INIT_NODE3_IP:"
    verbose "========================================================================="
    echo ""
    echo "$_icg_token"
    echo ""
    verbose "========================================================================="
    verbose " The token equals root access (it carries database passwords and the"
    verbose " sync private key). Store it safely; clear the shell history/clipboard"
    verbose " after use. This command now WAITS for the other nodes to join."
    verbose "========================================================================="
    echo ""
}

init_step_3_packages() {
    pkg_install_required "postgresql${HA_PG_VERSION}-repmgr" haproxy lsyncd \
        python3 python3-module-psycopg2 openssh-clients rsync curl
}

init_step_4_pg_prep() {
    ha_write_pgpass data

    if ! pg_runuser_psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$HA_REPMGR_USER'" | grep -q 1; then
        pg_runuser_psql -c "SET password_encryption = 'md5'; CREATE ROLE $HA_REPMGR_USER REPLICATION LOGIN PASSWORD '$HA_REPMGR_PASSWORD';" \
            || die "cannot create the repmgr role"
        verbose "  role created: $HA_REPMGR_USER (replication)"
    else
        pg_runuser_psql -c "SET password_encryption = 'md5'; ALTER ROLE $HA_REPMGR_USER WITH PASSWORD '$HA_REPMGR_PASSWORD';" >/dev/null \
            || die "cannot update the repmgr role password"
        verbose "  role exists: $HA_REPMGR_USER (password aligned)"
    fi

    if ! pg_runuser_psql -tAc "SELECT 1 FROM pg_database WHERE datname='$HA_REPMGR_DB'" | grep -q 1; then
        pg_runuser_psql -c "CREATE DATABASE $HA_REPMGR_DB OWNER $HA_REPMGR_USER;" \
            || die "cannot create the $HA_REPMGR_DB database"
        verbose "  database created: $HA_REPMGR_DB"
    fi
    pg_runuser_psql -d "$HA_REPMGR_DB" -c "CREATE EXTENSION IF NOT EXISTS repmgr;" >/dev/null \
        || die "cannot create the repmgr extension in $HA_REPMGR_DB"
    verbose "  extension ready: repmgr"

    ha_write_pg_hba data
    systemctl reload "$HA_PG_SERVICE" 2>/dev/null || pg_runuser_psql -c "SELECT pg_reload_conf();" >/dev/null

    if ! pg_psql_superuser 127.0.0.1 -d "$HA_REPMGR_DB" -tAc "SELECT 1" >/dev/null 2>&1; then
        PGPASSWORD="$HA_REPMGR_PASSWORD" psql -h 127.0.0.1 -p "$HA_PG_PORT" -U "$HA_REPMGR_USER" -d "$HA_REPMGR_DB" -tAc "SELECT 1" >/dev/null 2>&1 \
            || warn "cannot connect as $HA_REPMGR_USER via TCP - check pg_hba (the clone on node 2 will fail)"
    fi
}

init_step_5_wal_log_hints() {
    _iwl_current="$(pg_runuser_psql -tAc "SHOW wal_log_hints" | tr -d ' \r')"
    if [ "$_iwl_current" = "on" ]; then
        verbose "  wal_log_hints is already on (pg_rewind support) - skipping the restart"
        return 0
    fi
    verbose "  enabling wal_log_hints (required by pg_rewind when a former"
    verbose "  primary is repaired after a failover) - ONE PostgreSQL restart"
    pg_runuser_psql -c "ALTER SYSTEM SET wal_log_hints = on;" >/dev/null \
        || die "cannot set wal_log_hints"
    systemctl restart "$HA_PG_SERVICE" || die "PostgreSQL restart failed"
    _iwl_try=0
    while [ "$_iwl_try" -lt 30 ]; do
        pg_runuser_psql -tAc "SELECT 1" >/dev/null 2>&1 && break
        sleep 1
        _iwl_try=$((_iwl_try + 1))
    done
    pg_runuser_psql -tAc "SELECT 1" >/dev/null 2>&1 || die "PostgreSQL did not come back after the restart"
    [ "$(pg_runuser_psql -tAc "SHOW wal_log_hints" | tr -d ' \r')" = "on" ] \
        || die "wal_log_hints did not stick - aborting before anything depends on it"
    verbose "  wal_log_hints = on, PostgreSQL is back"
}

init_step_6_repmgr_conf() {
    ha_render_repmgr_conf primary
    ha_install_promote_sh
    verbose "  repmgr configuration written: $HA_REPMGR_CONF (role: primary)"
}

init_step_7_primary_register() {
    _ipr_out="$(repmgr_cmd primary register --force)"
    if [ $? -ne 0 ]; then
        echo "$_ipr_out"
        die "'repmgr primary register' failed (see output above)"
    fi
    echo "$_ipr_out" | grep -q "successfully\|already registered" 2>/dev/null || verbose "  $_ipr_out"
    verbose "  this node is registered as the cluster primary (node 1)"
    svc_enable_start "$HA_REPMGRD_SERVICE"
}

init_step_8_agent() {
    ha_install_agent
}

init_step_9_haproxy() {
    ha_render_haproxy_conf
    haproxy -c -f "$HA_HAPROXY_MAIN" -f "$HA_HAPROXY_CONF_D" >/dev/null 2>&1 \
        || die "haproxy configuration is invalid (haproxy -c failed)"
    svc_enable_start "$HA_HAPROXY_SERVICE"
    verbose "  haproxy frontend: 127.0.0.1:$HA_HAPROXY_PORT -> current primary"
}

init_step_10_repoint_dsn() {
    ha_repoint_dsn
}

init_poll_witness_registered() {
    pg_runuser_psql -d "$HA_REPMGR_DB" -tAc "SELECT 1 FROM repmgr.nodes WHERE node_id=3" 2>/dev/null | grep -q 1
}

init_step_11_wait_witness() {
    ha_wait "witness node registration (run --join on $HA_INIT_NODE3_IP)" 900 init_poll_witness_registered \
        || die "the witness did not join within 15 minutes"
}

init_poll_standby_streaming() {
    pg_runuser_psql -d postgres -tAc \
        "SELECT 1 FROM pg_stat_replication WHERE application_name='$(ha_node_name 2)' AND state='streaming'" \
        2>/dev/null | grep -q 1
}

init_step_12_wait_standby() {
    ha_wait "streaming standby $(ha_node_name 2) (run --join on $HA_INIT_NODE2_IP)" 900 init_poll_standby_streaming \
        || die "the standby did not start streaming within 15 minutes"
}

init_step_13_sync_on() {
    ha_ensure_sync local
}

init_step_14_sync_setup() {
    ha_write_authorized_keys
    mkdir -p "$HA_SYNC_DIR" 2>/dev/null || die "cannot create $HA_SYNC_DIR"
    touch "$HA_KNOWN_HOSTS" && chmod 600 "$HA_KNOWN_HOSTS"
    if cmd_exists ssh-keyscan; then
        ssh-keyscan -t ed25519 "$(ha_node_ip 2)" >> "$HA_KNOWN_HOSTS" 2>/dev/null \
            || warn "ssh-keyscan failed for $(ha_node_ip 2) - first sync will use accept-new (TOFU)"
    fi
    ha_render_lsyncd_conf "$(ha_node_ip 2)"
    svc_enable_start "$HA_LSYNCD_SERVICE"
}

init_step_15_finalize() {
    verbose ""
    verbose "Cluster summary:"
    repmgr_cmd cluster show | sed 's/^/  /'
    verbose ""
    verbose "  entry point for applications: 127.0.0.1:$HA_HAPROXY_PORT (haproxy)"
    verbose "  synchronous replication:      on (RPO = 0 for committed data)"
    verbose "  media sync:                   $HA_SYNC_DIR <-> $(ha_node_ip 2)"
    verbose ""
    verbose "Next: 'fusionpbx-ha.sh --doctor' on all three nodes."
    verbose "Token needed again? 'fusionpbx-ha.sh --print-token' (this node only)."
}

# =============================================================================
# --join : step functions - DESIGN.md sections 8.2 (standby) / 8.3 (witness)
# The role is picked by matching the local IP with the node list in the token
# (a REBUILT node 1 also joins as a standby - DESIGN.md 12.2).
# =============================================================================

join_step_1_preflight() {
    ha_require_root_and_alt
    ha_detect_role || die "this host's IP is not in the cluster node list ($(ha_node_ip 1), $(ha_node_ip 2), $(ha_node_ip 3)).
The token was issued for a different cluster/network."

    if [ "$HA_NODE_ID" = "3" ]; then
        verbose "  this node is the WITNESS (node 3) - layer 1 is not required here"
    else
        ha_read_layer1_conf \
            || die "layer 1 is not installed on this node (no readable $HA_L1_CONF).
Run the standard installer first (see the repository README)."
        _jsp_ver="$(ha_pg_version_major)" \
            || die "no local PostgreSQL cluster found (PG_VERSION missing) - run layer 1 first"
        [ "$_jsp_ver" = "$HA_PG_VERSION" ] \
            || die "PostgreSQL major version mismatch: local $_jsp_ver, cluster $HA_PG_VERSION
The cluster was initialized with PostgreSQL $HA_PG_VERSION."
    fi

    if [ "$HA_NODE_ID" != "3" ]; then
        _jsp_peer="$(ha_peer_ip)"
        if ! ha_pg_isready "$_jsp_peer"; then
            die "the peer data node $_jsp_peer is not reachable on port $HA_PG_PORT
--join needs the running primary - complete --init on it first"
        fi
        _jsp_code="$(ha_agent_code "$_jsp_peer")"
        [ "$_jsp_code" = "200" ] || warn "peer role-agent at $_jsp_peer answers HTTP $_jsp_code (not primary yet?) - continuing, clone will verify"
    fi
    verbose "  preflight OK: node $HA_NODE_ID ($(ha_node_name "$HA_NODE_ID")), joining as $HA_JOIN_ROLE"
}

join_step_2_unpack() {
    mkdir -p "$HA_ETC_DIR"
    chmod "$HA_CONF_DIR_MODE" "$HA_ETC_DIR"
    install -m 600 "$HA_JOIN_TMP_CONF" "$HA_CLUSTER_CONF" || die "cannot write $HA_CLUSTER_CONF"
    if [ "$HA_NODE_ID" != "3" ]; then
        printf '%s' "$HA_SYNC_PRIVATE_KEY_B64" | base64 -d 2>/dev/null | gunzip -c > "$HA_SYNC_KEY" 2>/dev/null \
            || die "cannot unpack the sync private key from the token"
        chmod 600 "$HA_SYNC_KEY"
        rm -f "${HA_SYNC_KEY}.pub" 2>/dev/null
        ha_write_authorized_keys
        ha_write_pgpass data
    else
        ha_write_pgpass witness
    fi
    ha_write_etc_hosts_block
    ha_apply_no_proxy
    verbose "  cluster configuration installed: $HA_CLUSTER_CONF"
}

join_step_3_packages() {
    if [ "$HA_NODE_ID" = "3" ]; then
        pkg_install_required "postgresql${HA_PG_VERSION}-repmgr" "postgresql${HA_PG_VERSION}-server" curl
    else
        pkg_install_required "postgresql${HA_PG_VERSION}-repmgr" haproxy lsyncd \
            python3 python3-module-psycopg2 openssh-clients rsync curl
    fi
}

join_step_4_confirm_and_stop_pg() {
    [ "$HA_NODE_ID" != "3" ] || die "internal error: join_step_4_confirm_and_stop_pg called on the witness"

    echo "" >&2
    echo "${red:-}=========================================================================${normal:-}" >&2
    echo "${red:-} THE LOCAL DATABASE WILL BE REPLACED BY A CLONE OF $(ha_peer_name) ${normal:-}" >&2
    echo "${red:-}=========================================================================${normal:-}" >&2
    echo "" >&2
    echo "The local standalone FusionPBX database and everything configured on THIS" >&2
    echo "node will be WIPED and replaced with a physical copy of $(ha_peer_ip)." >&2
    echo "Media files stay; the cluster configuration comes from the token." >&2
    echo "" >&2
    if ! confirm "Type YES (or run with --yes) to wipe and clone:"; then
        die "aborted by the operator - nothing was changed"
    fi

    svc_stop "$HA_LSYNCD_SERVICE"
    svc_stop "$HA_REPMGRD_SERVICE"
    svc_stop "$HA_PG_SERVICE"
}

join_poll_peer_is_primary() {
    PGPASSWORD="$HA_REPMGR_PASSWORD" psql -h "$(ha_peer_ip)" -p "$HA_PG_PORT" \
        -U "$HA_REPMGR_USER" -d "$HA_REPMGR_DB" -tAc \
        "SELECT 1 FROM repmgr.nodes WHERE type='primary' AND active" 2>/dev/null | grep -q 1
}

join_step_5_clone() {
    ha_wait "the primary ($(ha_peer_name)) to be registered" 600 join_poll_peer_is_primary \
        || die "the peer never became a registered primary - is --init complete on it?"

    _jsc_pgdata="$(ha_pg_data_dir)"
    if [ -n "$(ls -A "$_jsc_pgdata" 2>/dev/null)" ]; then
        rm -rf "${_jsc_pgdata:?}"/* "${_jsc_pgdata:?}"/.[!.]* "${_jsc_pgdata:?}"/..?* 2>/dev/null
        verbose "  local PGDATA wiped: $_jsc_pgdata"
    fi
    _jsc_out="$(repmgr_cmd standby clone -h "$(ha_peer_ip)" -U "$HA_REPMGR_USER" -d "$HA_REPMGR_DB")"
    if [ $? -ne 0 ]; then
        echo "$_jsc_out"
        die "standby clone from $(ha_peer_ip) failed (see output above)"
    fi
    echo "$_jsc_out" | grep -q "cloning\|done\|successfully" 2>/dev/null || verbose "  $_jsc_out"
    verbose "  base backup complete: local node is now a physical copy of $(ha_peer_name)"
}

join_step_6_start_register() {
    systemctl start "$HA_PG_SERVICE" || die "PostgreSQL did not start after the clone"
    _jsr_try=0
    while [ "$_jsr_try" -lt 60 ]; do
        pg_runuser_psql -tAc "SELECT 1" >/dev/null 2>&1 && break
        sleep 1
        _jsr_try=$((_jsr_try + 1))
    done
    pg_runuser_psql -tAc "SELECT 1" >/dev/null 2>&1 || die "PostgreSQL is not answering after the clone"

    _jsr_recovery="$(pg_runuser_psql -tAc "SELECT pg_is_in_recovery()" | tr -d ' \r')"
    [ "$_jsr_recovery" = "t" ] || die "the cloned PostgreSQL did not come up in recovery mode - refusing to continue"

    _jsr_out="$(repmgr_cmd standby register --upstream-node-id="$(ha_peer_id)" --force)"
    if [ $? -ne 0 ]; then
        echo "$_jsr_out"
        die "'repmgr standby register' failed (see output above)"
    fi
    verbose "  registered as a standby of node $(ha_peer_id) ($(ha_peer_name))"
    svc_enable_start "$HA_REPMGRD_SERVICE"
}

join_step_7_agent_haproxy() {
    ha_install_agent
    ha_render_haproxy_conf
    haproxy -c -f "$HA_HAPROXY_MAIN" -f "$HA_HAPROXY_CONF_D" >/dev/null 2>&1 \
        || die "haproxy configuration is invalid (haproxy -c failed)"
    svc_enable_start "$HA_HAPROXY_SERVICE"
}

join_step_8_repoint_dsn() {
    ha_repoint_dsn
}

join_step_9_seed_media() {
    mkdir -p "$HA_SYNC_DIR" 2>/dev/null || die "cannot create $HA_SYNC_DIR"
    verbose "  pulling the media tree from $(ha_peer_name) (seed BEFORE the sync"
    verbose "  daemon starts - protects the peer copy from being wiped by an"
    verbose "  empty local tree; DESIGN.md 10.2)"
    rsync -a --delete \
        -e "ssh -i $HA_SYNC_KEY -o UserKnownHostsFile=$HA_KNOWN_HOSTS -o StrictHostKeyChecking=accept-new -o BatchMode=yes" \
        "root@$(ha_peer_ip):$HA_SYNC_DIR/" "$HA_SYNC_DIR/" \
        || die "media seed failed - check sshd on $(ha_peer_ip) and the sync key
(hint: systemctl status sshd on $(ha_peer_ip))"
    verbose "  media tree seeded: $HA_SYNC_DIR"
}

join_step_10_lsyncd_start() {
    ha_render_lsyncd_conf "$(ha_peer_ip)"
    svc_enable_start "$HA_LSYNCD_SERVICE"
}

join_step_11_finalize() {
    ha_ensure_sync "$(ha_peer_ip)"
    verbose ""
    verbose "Node summary:"
    repmgr_cmd cluster show | sed 's/^/  /'
    verbose ""
    verbose "  the primary now runs synchronous replication to this node (RPO = 0)"
    verbose "Next: 'fusionpbx-ha.sh --doctor' on this node."
}

# -----------------------------------------------------------------------------
# --join witness (VM3): DESIGN.md 8.3 - no layer 1, no haproxy/lsyncd/agent
# -----------------------------------------------------------------------------

wit_step_1_preflight() {
    ha_require_root_and_alt
    ha_detect_role || die "this host's IP is not in the cluster node list"
    [ "$HA_NODE_ID" = "3" ] || die "internal error: witness steps on a data node"
    _jsp_up=""
    for _wit_ip in "$(ha_node_ip 1)" "$(ha_node_ip 2)"; do
        if ha_pg_isready "$_wit_ip"; then _jsp_up="$_wit_ip"; break; fi
    done
    [ -n "$_jsp_up" ] || die "neither $(ha_node_ip 1) nor $(ha_node_ip 2) is reachable on $HA_PG_PORT - a data node must be running"
    verbose "  preflight OK: joining as WITNESS (node 3)"
}

wit_step_2_unpack() {
    mkdir -p "$HA_ETC_DIR"
    chmod "$HA_CONF_DIR_MODE" "$HA_ETC_DIR"
    install -m 600 "$HA_JOIN_TMP_CONF" "$HA_CLUSTER_CONF" || die "cannot write $HA_CLUSTER_CONF"
    ha_write_pgpass witness
    ha_write_etc_hosts_block
    ha_apply_no_proxy
}

wit_step_3_packages() {
    pkg_install_required "postgresql${HA_PG_VERSION}-repmgr" "postgresql${HA_PG_VERSION}-server"
}

wit_step_4_initdb_tiny() {
    _wit_pgdata="$(ha_pg_data_dir)"
    if pg_runuser_psql -d "$HA_REPMGR_DB" -tAc "SELECT 1" >/dev/null 2>&1 \
        && pg_runuser_psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$HA_REPMGR_USER'" 2>/dev/null | grep -q 1; then
        verbose "  witness PostgreSQL already initialized - reusing it"
    else
        if [ -n "$(ls -A "$_wit_pgdata" 2>/dev/null)" ]; then
            echo "The witness holds a non-empty $_wit_pgdata without a usable repmgr" >&2
            echo "setup. It contains no user data - it will be WIPED." >&2
            confirm "Type YES (or --yes) to wipe it:" || die "aborted by the operator"
            svc_stop "$HA_PG_SERVICE"
            rm -rf "${_wit_pgdata:?}"/* "${_wit_pgdata:?}"/.[!.]* "${_wit_pgdata:?}"/..?* 2>/dev/null
        fi
        if [ ! -f "$_wit_pgdata/PG_VERSION" ]; then
            mkdir -p "$_wit_pgdata"
            chown postgres:postgres "$_wit_pgdata" 2>/dev/null || true
            chmod 700 "$_wit_pgdata"
            runuser -u postgres -- initdb -D "$_wit_pgdata" --data-checksums >/dev/null 2>&1 \
                || die "initdb failed on the witness"
            verbose "  witness PostgreSQL initialized ($_wit_pgdata, checksums on)"
        fi
        svc_enable_start "$HA_PG_SERVICE"
        pg_runuser_psql -c "SET password_encryption = 'md5'; ALTER ROLE postgres WITH PASSWORD '$HA_DB_PASSWORD';" >/dev/null
        _wit_try=0
        while [ "$_wit_try" -lt 30 ]; do
            pg_runuser_psql -tAc "SELECT 1" >/dev/null 2>&1 && break
            sleep 1
            _wit_try=$((_wit_try + 1))
        done
    fi

    pg_runuser_psql -tAc "SELECT 1" >/dev/null 2>&1 \
        || svc_enable_start "$HA_PG_SERVICE"

    if ! pg_runuser_psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$HA_REPMGR_USER'" | grep -q 1; then
        pg_runuser_psql -c "SET password_encryption = 'md5'; CREATE ROLE $HA_REPMGR_USER LOGIN PASSWORD '$HA_REPMGR_PASSWORD';" \
            || die "cannot create the repmgr role on the witness"
    fi
    if ! pg_runuser_psql -tAc "SELECT 1 FROM pg_database WHERE datname='$HA_REPMGR_DB'" | grep -q 1; then
        pg_runuser_psql -c "CREATE DATABASE $HA_REPMGR_DB OWNER $HA_REPMGR_USER;" \
            || die "cannot create the $HA_REPMGR_DB database on the witness"
    fi
    pg_runuser_psql -d "$HA_REPMGR_DB" -c "CREATE EXTENSION IF NOT EXISTS repmgr;" >/dev/null \
        || die "cannot create the repmgr extension"
    ha_write_pg_hba witness
    systemctl reload "$HA_PG_SERVICE" 2>/dev/null || pg_runuser_psql -c "SELECT pg_reload_conf();" >/dev/null
    verbose "  witness metadata database ready: $HA_REPMGR_DB"
}

wit_step_5_repmgr_conf() {
    HA_NODE_ID=3
    ha_render_repmgr_conf witness
    verbose "  repmgr configuration written (role: witness, failover=manual - never promoted)"
}

wit_find_primary_ip() {
    if [ "$(ha_agent_code "$(ha_node_ip 1)")" = "200" ]; then
        ha_node_ip 1
    elif [ "$(ha_agent_code "$(ha_node_ip 2)")" = "200" ]; then
        ha_node_ip 2
    else
        echo ""
    fi
}

wit_step_6_witness_register() {
    _wfr_ip="$(wit_find_primary_ip)"
    [ -n "$_wfr_ip" ] || die "no primary found ($(ha_node_ip 1) and $(ha_node_ip 2) role-agents do not answer 200)
The witness registers against a running primary - complete --init on the primary first."
    _wfr_out="$(repmgr_cmd witness register -h "$_wfr_ip" --force)"
    if [ $? -ne 0 ]; then
        echo "$_wfr_out"
        die "'repmgr witness register' against $_wfr_ip failed (see output above)"
    fi
    verbose "  witness registered against the primary $_wfr_ip"
}

wit_step_7_repmgrd() {
    svc_enable_start "$HA_REPMGRD_SERVICE"
}

wit_step_8_finalize() {
    verbose ""
    verbose "Witness node summary:"
    repmgr_cmd cluster show | sed 's/^/  /'
    verbose ""
    verbose "This node stores NO user data - it only votes during failover."
    verbose "Next: 'fusionpbx-ha.sh --doctor' on all three nodes."
}

# =============================================================================
# --repair : DESIGN.md section 8.4 / 12
# Branch is selected from the CURRENT cluster state (who is primary now).
# =============================================================================

rep_step_1_preflight() {
    ha_require_root_and_alt
    ha_detect_role || die "this host's IP is not in the cluster node list"
    verbose "  node $HA_NODE_ID ($(ha_node_name "$HA_NODE_ID")), role from config: $HA_ROLE"
    if [ "$HA_NODE_ID" != "3" ]; then
        _rp1_peer="$(ha_peer_ip)"
        _rp1_code="$(ha_agent_code "$_rp1_peer")"
        if [ "$_rp1_code" = "200" ]; then
            verbose "  peer $_rp1_peer is the current primary - this node will rejoin as standby"
        else
            die "the peer data node $_rp1_peer is not a reachable primary (agent code: $_rp1_code).
Cases:
  - the PEER is down and THIS node is the primary: re-run --repair here
    after the peer has stopped (it will be detected automatically);
  - both data nodes are down (double failure): bring back ANY one node
    first, then run --repair on it (RUNBOOK.md section 6);
  - no quorum at all: follow the break-glass procedure (DESIGN.md 12.4)."
        fi
    fi
}

rep_step_2_stop_services() {
    svc_stop "$HA_LSYNCD_SERVICE"
    svc_stop "$HA_REPMGRD_SERVICE"
}

rep_step_3_rejoin_or_clone() {
    _r3c_pgdata="$(ha_pg_data_dir)"
    if [ "$HA_FORCE_CLONE" = "true" ] || [ ! -f "$_r3c_pgdata/PG_VERSION" ]; then
        _r3c_mode="clone"
    else
        _r3c_mode="rejoin"
    fi
    verbose "  repair mode: $_r3c_mode (PGDATA $( [ "$_r3c_mode" = "clone" ] && echo 'wiped' || echo 'reused' ))"

    if [ "$_r3c_mode" = "clone" ]; then
        echo "The local database directory will be WIPED and re-cloned from $(ha_peer_name)." >&2
        confirm "Type YES (or --yes) to continue:" || die "aborted by the operator"
        svc_stop "$HA_PG_SERVICE"
        if [ -n "$(ls -A "$_r3c_pgdata" 2>/dev/null)" ]; then
            rm -rf "${_r3c_pgdata:?}"/* "${_r3c_pgdata:?}"/.[!.]* "${_r3c_pgdata:?}"/..?* 2>/dev/null
        fi
        ha_wait "the primary ($(ha_peer_name)) to be registered" 600 join_poll_peer_is_primary \
            || die "the peer is not a registered primary"
        _r3c_out="$(repmgr_cmd standby clone -h "$(ha_peer_ip)" -U "$HA_REPMGR_USER" -d "$HA_REPMGR_DB")"
        if [ $? -ne 0 ]; then
            echo "$_r3c_out"
            die "standby clone failed (see output above)"
        fi
        systemctl start "$HA_PG_SERVICE" || die "PostgreSQL did not start after the clone"
        _r3c_out="$(repmgr_cmd standby register --upstream-node-id="$(ha_peer_id)" --force)"
        if [ $? -ne 0 ]; then
            echo "$_r3c_out"
            die "'repmgr standby register' failed (see output above)"
        fi
        verbose "  re-cloned and registered as a standby of $(ha_peer_name)"
    else
        if ! svc_active "$HA_PG_SERVICE"; then
            systemctl start "$HA_PG_SERVICE" || die "local PostgreSQL does not start - re-run with --force-clone"
            _r3c_try=0
            while [ "$_r3c_try" -lt 60 ]; do
                pg_runuser_psql -tAc "SELECT 1" >/dev/null 2>&1 && break
                sleep 1
                _r3c_try=$((_r3c_try + 1))
            done
        fi
        pg_runuser_psql -tAc "SELECT 1" >/dev/null 2>&1 \
            || die "local PostgreSQL is not answering - re-run with --force-clone"
        _r3c_out="$(repmgr_cmd node rejoin --force-rewind -h "$(ha_peer_ip)")"
        if [ $? -ne 0 ]; then
            echo "$_r3c_out"
            die "node rejoin failed (see output above).
If the local PGDATA is damaged beyond rewind, re-run with: --repair --force-clone"
        fi
        verbose "  rejoined as a standby of $(ha_peer_name) (pg_rewind applied)"
    fi
}

rep_step_4_services() {
    ha_render_repmgr_conf standby
    ha_install_promote_sh
    ha_install_agent
    ha_render_haproxy_conf
    haproxy -c -f "$HA_HAPROXY_MAIN" -f "$HA_HAPROXY_CONF_D" >/dev/null 2>&1 \
        || die "haproxy configuration is invalid"
    svc_enable_start "$HA_HAPROXY_SERVICE"
    svc_enable_start "$HA_REPMGRD_SERVICE"
    ha_repoint_dsn
}

rep_step_5_seed_media() {
    join_step_9_seed_media
}

rep_step_6_lsyncd() {
    ha_render_lsyncd_conf "$(ha_peer_ip)"
    svc_enable_start "$HA_LSYNCD_SERVICE"
}

rep_step_7_ensure_sync() {
    ha_ensure_sync "$(ha_peer_ip)"
}

rep_step_8_finalize() {
    verbose ""
    verbose "Repair complete. Node summary:"
    repmgr_cmd cluster show | sed 's/^/  /'
    verbose ""
    verbose "Next: 'fusionpbx-ha.sh --doctor' on this node, then on the primary."
}

# -----------------------------------------------------------------------------
# --repair on the SURVIVING PRIMARY (peer down): degrade gracefully instead
# of freezing - DESIGN.md 11.1 "records of new calls - asynchronously until
# the standby returns" (implemented as ensure-sync, see changelog 0.3)
# -----------------------------------------------------------------------------

prp_step_1_preflight() {
    ha_require_root_and_alt
    ha_detect_role || die "this host's IP is not in the cluster node list"
    ha_local_is_primary || die "this node is not the primary - use the regular --repair flow"
    _prp_code="$(ha_agent_code "$(ha_peer_ip)")"
    [ "$_prp_code" = "200" ] && die "the peer $(ha_peer_ip) is ALSO a primary - two primaries detected, do not continue"
    verbose "  this node is the surviving primary; peer is down (agent: $_prp_code)"
}

prp_step_2_degrade() {
    verbose "  degrading to async writes until the standby returns"
    ha_ensure_sync local
}

prp_step_3_services() {
    ha_render_repmgr_conf primary
    ha_install_promote_sh
    ha_install_agent
    ha_render_haproxy_conf
    haproxy -c -f "$HA_HAPROXY_MAIN" -f "$HA_HAPROXY_CONF_D" >/dev/null 2>&1 \
        || die "haproxy configuration is invalid"
    svc_enable_start "$HA_HAPROXY_SERVICE"
    svc_enable_start "$HA_REPMGRD_SERVICE"
    ha_render_lsyncd_conf "$(ha_peer_ip)"
    svc_enable_start "$HA_LSYNCD_SERVICE"
    verbose "  all services re-verified"
}

prp_step_4_finalize() {
    verbose ""
    verbose "This node serves the cluster alone (async, no failover protection)."
    verbose "When the peer VM is repaired/rebuilt, run on IT:"
    verbose "  fusionpbx-ha.sh --repair        (disk kept)"
    verbose "  fusionpbx-ha.sh --repair --force-clone   (rebuilt from scratch)"
    verbose "It will rejoin as a standby and sync mode turns back on."
}

# =============================================================================
# --status : compact read-only summary (works in degraded states)
# =============================================================================

cmd_status() {
    ha_detect_role || die "this host's IP is not in the cluster node list"
    verbose ""
    verbose "=== Node ==="
    verbose "  name:        $(ha_node_name "$HA_NODE_ID") ($(ha_node_ip "$HA_NODE_ID"))  role: $HA_ROLE"
    verbose "  time:        $(date '+%Y-%m-%d %H:%M:%S %Z')"

    verbose ""
    verbose "=== Cluster (repmgr) ==="
    if repmgr_cmd cluster show > "$HA_ETC_DIR/.cluster-show.tmp" 2>&1; then
        sed 's/^/  /' "$HA_ETC_DIR/.cluster-show.tmp"
    else
        warn "repmgr cluster show failed (PostgreSQL/repmgrd down or node not registered?)"
        sed 's/^/  /' "$HA_ETC_DIR/.cluster-show.tmp" 2>/dev/null
    fi
    rm -f "$HA_ETC_DIR/.cluster-show.tmp"

    verbose ""
    verbose "=== Replication ==="
    _st_rc=0; ha_local_role_code; _st_rc=$?
    case "$_st_rc" in
        0)
            pg_runuser_psql -d postgres -c \
                "SELECT application_name AS standby, state, sync_state, pg_wal_lsn_diff(pg_current_wal_lsn(), write_lsn) AS write_lag_bytes FROM pg_stat_replication;" \
                | sed 's/^/  /'
            ;;
        1)
            verbose "  standby (in recovery); receiving:"
            pg_runuser_psql -d postgres -tAc \
                "SELECT '  upstream: '||COALESCE(sender_host,'?')||'  lag bytes: '||COALESCE(pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn()),0)" \
                2>/dev/null | sed 's/^/  /'
            ;;
        *) warn "local PostgreSQL is not reachable" ;;
    esac

    verbose ""
    verbose "=== Entry point 127.0.0.1:$HA_HAPROXY_PORT ==="
    _st_probe="$(pg_psql_app 127.0.0.1 -p "$HA_HAPROXY_PORT" -tAc "SELECT pg_is_in_recovery()" 2>/dev/null | tr -d ' \r')"
    if [ "$_st_probe" = "f" ]; then
        verbose "  OK: connects and reaches the PRIMARY"
    elif [ "$_st_probe" = "t" ]; then
        warn "entry point reaches a STANDBY - haproxy health checks stale?"
    else
        warn "cannot query through 127.0.0.1:$HA_HAPROXY_PORT (haproxy down / no primary)"
    fi

    verbose ""
    verbose "=== Role agents ==="
    for _st_ip in "$(ha_node_ip 1)" "$(ha_node_ip 2)"; do
        _st_code="$(ha_agent_code "$_st_ip")"
        case "$_st_code" in
            200) verbose "  $_st_ip: PRIMARY" ;;
            503) verbose "  $_st_ip: standby/down" ;;
            *)   warn "$_st_ip: unreachable ($_st_code)" ;;
        esac
    done

    verbose ""
    verbose "=== Services ==="
    for _st_svc in "$HA_PG_SERVICE" "$HA_REPMGRD_SERVICE" "$HA_HAPROXY_SERVICE" "$HA_AGENT_UNIT_NAME" "$HA_LSYNCD_SERVICE" angie freeswitch sshd; do
        if svc_active "$_st_svc" 2>/dev/null; then
            verbose "  $_st_svc: active"
        else
            # the witness legitimately runs a reduced set
            if [ "$HA_NODE_ID" = "3" ] && [ "$_st_svc" != "$HA_PG_SERVICE" ] && [ "$_st_svc" != "$HA_REPMGRD_SERVICE" ]; then
                continue
            fi
            warn "  $_st_svc: NOT active"
        fi
    done
    verbose ""
}

# =============================================================================
# --doctor : deep check list; exit 0 = healthy, 1 = failures (for monitoring)
# =============================================================================

DOCTOR_FAIL=0
DOCTOR_WARN=0

_dr_ok()   { verbose "  [OK]    $1"; }
_dr_warn() { warn "  [WARN]  $1"; DOCTOR_WARN=$((DOCTOR_WARN + 1)); }
_dr_fail() { error "  [FAIL]  $1"; DOCTOR_FAIL=$((DOCTOR_FAIL + 1)); }

cmd_doctor() {
    ha_detect_role || die "this host's IP is not in the cluster node list"
    verbose ""
    verbose "=== fusionpbx-ha doctor: node $(ha_node_name "$HA_NODE_ID") ($(ha_node_ip "$HA_NODE_ID")) ==="

    # 1. NTP
    _dc_ntp=""
    if cmd_exists timedatectl; then
        _dc_ntp="$(timedatectl show -p NTPSynchronized --value 2>/dev/null)"
    fi
    case "$_dc_ntp" in
        yes) _dr_ok "time is NTP-synchronized" ;;
        no)  _dr_fail "time is NOT NTP-synchronized (failover consensus needs correct clocks)" ;;
        *)   _dr_warn "NTP state unknown (timedatectl unavailable)" ;;
    esac

    # 2. local PostgreSQL
    _dc_rc=0; ha_local_role_code; _dc_rc=$?
    case "$_dc_rc" in
        0) _dr_ok "local PostgreSQL is up (primary)" ;;
        1) _dr_ok "local PostgreSQL is up (standby)" ;;
        *) _dr_fail "local PostgreSQL is DOWN or unreachable" ;;
    esac

    if [ "$_dc_rc" != "2" ]; then
        # 3. frozen-sync detection (primary without a streaming standby but
        # with sync names configured = writes are STALLED)
        if [ "$_dc_rc" = "0" ]; then
            _dc_streaming="$(pg_runuser_psql -d postgres -tAc "SELECT count(*) FROM pg_stat_replication WHERE state='streaming'" | tr -d ' \r')"
            _dc_syncnames="$(pg_runuser_psql -tAc "SHOW synchronous_standby_names" | tr -d ' \r')"
            if [ "${_dc_streaming:-0}" -ge 1 ] 2>/dev/null; then
                _dc_syncstate="$(pg_runuser_psql -d postgres -tAc "SELECT sync_state FROM pg_stat_replication WHERE state='streaming'" | head -1 | tr -d ' \r')"
                if [ "$_dc_syncstate" = "sync" ]; then
                    _dr_ok "synchronous replication active (RPO = 0)"
                else
                    _dr_fail "standby streams but sync_state='$_dc_syncstate' - run --repair on the standby node"
                fi
            elif [ -n "$_dc_syncnames" ] && [ "$_dc_syncnames" != "(disabled)" ]; then
                _dr_fail "WRITES ARE FROZEN: synchronous_standby_names='$_dc_syncnames' but no standby is streaming
Fix: fusionpbx-ha.sh --repair  (degrades to async) or restore the standby"
            else
                _dr_warn "async mode (no standby streaming) - restore the peer: RUNBOOK.md section 3a/5"
            fi
        fi

        # 4. repmgr sees the whole cluster (data nodes only)
        if [ "$HA_NODE_ID" != "3" ] && [ "$_dc_rc" = "0" ]; then
            _dc_nodes="$(pg_runuser_psql -d "$HA_REPMGR_DB" -tAc "SELECT count(*) FROM repmgr.nodes WHERE active" 2>/dev/null | tr -d ' \r')"
            case "${_dc_nodes:-x}" in
                3) _dr_ok "repmgr sees all 3 nodes active" ;;
                2) _dr_warn "repmgr sees 2/3 active nodes - a node is down (repair it: RUNBOOK.md 5)" ;;
                *) _dr_fail "repmgr sees ${_dc_nodes:-?}/3 active nodes - check the other nodes" ;;
            esac
        fi
    fi

    # 5. entry point (data nodes)
    if [ "$HA_NODE_ID" != "3" ]; then
        _dc_probe="$(pg_psql_app 127.0.0.1 -p "$HA_HAPROXY_PORT" -tAc "SELECT pg_is_in_recovery()" 2>/dev/null | tr -d ' \r')"
        if [ "$_dc_probe" = "f" ]; then
            _dr_ok "entry point 127.0.0.1:$HA_HAPROXY_PORT routes to the primary"
        else
            _dr_fail "entry point 127.0.0.1:$HA_HAPROXY_PORT does not reach the primary (probe: '$_dc_probe')
Check: systemctl status haproxy $HA_AGENT_UNIT_NAME"
        fi

        # 6. role agents of both data nodes
        for _dc_ip in "$(ha_node_ip 1)" "$(ha_node_ip 2)"; do
            _dc_code="$(ha_agent_code "$_dc_ip")"
            case "$_dc_code" in
                200|503) _dr_ok "role-agent $_dc_ip answers ($_dc_code)" ;;
                *) _dr_fail "role-agent $_dc_ip unreachable ($_dc_code)" ;;
            esac
        done
    fi

    # 7. services
    if [ "$HA_NODE_ID" = "3" ]; then
        _dc_set="$HA_PG_SERVICE $HA_REPMGRD_SERVICE"
    else
        _dc_set="$HA_PG_SERVICE $HA_REPMGRD_SERVICE $HA_HAPROXY_SERVICE $HA_AGENT_UNIT_NAME $HA_LSYNCD_SERVICE sshd"
    fi
    for _dc_svc in $_dc_set; do
        if svc_active "$_dc_svc" 2>/dev/null; then
            _dr_ok "service $_dc_svc active"
        else
            _dr_fail "service $_dc_svc NOT active"
        fi
    done

    # 8. lsyncd (data nodes): service + log errors
    if [ "$HA_NODE_ID" != "3" ]; then
        if svc_active "$HA_LSYNCD_SERVICE" 2>/dev/null; then
            if [ -f "$HA_LSYNCD_LOG" ] && tail -n 100 "$HA_LSYNCD_LOG" 2>/dev/null | grep -qi 'error\|fail'; then
                _dr_warn "lsyncd log contains recent errors: $HA_LSYNCD_LOG"
            else
                _dr_ok "lsyncd log clean"
            fi
            [ -f "$HA_SYNC_DIR" ] || [ -d "$HA_SYNC_DIR" ] || _dr_fail "sync dir missing: $HA_SYNC_DIR"
        fi
        if cmd_exists sshd; then :; else _dr_warn "cannot verify sshd command"; fi
        # inotify budget for large recording trees (design question B7)
        if sysctl -n fs.inotify.max_user_watches >/dev/null 2>&1; then
            _dc_watches="$(sysctl -n fs.inotify.max_user_watches 2>/dev/null)"
            _dc_files="$(find "$HA_SYNC_DIR" -type d 2>/dev/null | wc -l)"
            if [ "${_dc_files:-0}" -gt 0 ] && [ "$_dc_watches" -lt $((_dc_files * 2)) ] 2>/dev/null; then
                _dr_warn "inotify watches ($_dc_watches) may be low for ${_dc_files} directories (sysctl fs.inotify.max_user_watches)"
            else
                _dr_ok "inotify budget sufficient (${_dc_files} directories watched)"
            fi
        fi
    fi

    # 9. disk space (PGDATA + sync dir)
    for _dc_dir in "$(ha_pg_data_dir)" "$HA_SYNC_DIR"; do
        [ -d "$_dc_dir" ] || continue
        _dc_free="$(df -P "$_dc_dir" 2>/dev/null | awk 'NR==2 {gsub("%","",$5); print 100-$5}')"
        case "${_dc_free:-x}" in
            ''|x) _dr_warn "cannot check free space on $_dc_dir" ;;
            *) if [ "$_dc_free" -lt 5 ]; then
                   _dr_fail "only ${_dc_free}% free on $_dc_dir"
               elif [ "$_dc_free" -lt 20 ]; then
                   _dr_warn "only ${_dc_free}% free on $_dc_dir"
               else
                   _dr_ok "${_dc_free}% free on $_dc_dir"
               fi ;;
        esac
    done

    # 10. witness reachability (from data nodes)
    if [ "$HA_NODE_ID" != "3" ]; then
        if ha_pg_isready "$(ha_node_ip 3)"; then
            _dr_ok "witness $(ha_node_ip 3) is reachable"
        else
            _dr_warn "witness $(ha_node_ip 3) unreachable - automatic failover is DISABLED until it returns (RUNBOOK.md 4)"
        fi
    fi

    verbose ""
    if [ "$DOCTOR_FAIL" -gt 0 ]; then
        error "Doctor result: $DOCTOR_FAIL failure(s), $DOCTOR_WARN warning(s)"
        exit 1
    fi
    verbose "Doctor result: healthy ($DOCTOR_WARN warning(s))"
    exit 0
}

# =============================================================================
# --print-token : re-print the join token (node 1 only - DESIGN.md 6.2)
# =============================================================================

cmd_print_token() {
    ha_detect_role || die "this host's IP is not in the cluster node list"
    if [ "$HA_NODE_ID" != "1" ]; then
        die "the token is printed on node 1 only (where --init was run; DESIGN.md 6.2)"
    fi
    _cpt_token="$(ha_token_pack)"
    echo ""
    echo "$_cpt_token"
    echo ""
    verbose "Treat this line as a root password (it carries database secrets)."
}

# =============================================================================
# Command dispatch
# =============================================================================

cmd_init() {
    if [ -f "$HA_MARKER_FILE" ] && [ "${HA_FORCE:-0}" != "1" ]; then
        die "this node is already part of an HA cluster ($HA_MARKER_FILE exists).
  - maintenance/re-configure:  fusionpbx-ha.sh --init --force
  - node problems:              fusionpbx-ha.sh --repair
  - status:                     fusionpbx-ha.sh --status"
    fi
    ha_apply_proxy

    # Cross-step state: steps run in subshells, so everything later steps
    # need is computed here, in the parent (see ha_run_sequence).
    [ -n "$HA_INIT_NODE2_IP" ] || die "--init requires --node2 IP (the second data node)"
    [ -n "$HA_INIT_NODE3_IP" ] || die "--init requires --node3 IP (the witness node)"
    valid_ip "$HA_INIT_NODE2_IP" || die "--node2 is not a valid IPv4 address: $HA_INIT_NODE2_IP"
    valid_ip "$HA_INIT_NODE3_IP" || die "--node3 is not a valid IPv4 address: $HA_INIT_NODE3_IP"
    [ "$HA_INIT_NODE2_IP" != "$HA_INIT_NODE3_IP" ] || die "--node2 and --node3 must be different hosts"

    HA_NODE_ID=1
    HA_PG_VERSION="$(ha_pg_version_major)" \
        || die "cannot determine the local PostgreSQL major version (PG_VERSION not found)"

    # node 1 address: a local address that is neither node2 nor node3
    HA_INIT_NODE1_IP=""
    _isp_multi=0
    for _isp_ip in $(own_ips); do
        if [ "$_isp_ip" != "$HA_INIT_NODE2_IP" ] && [ "$_isp_ip" != "$HA_INIT_NODE3_IP" ]; then
            if [ -n "$HA_INIT_NODE1_IP" ]; then _isp_multi=1; else HA_INIT_NODE1_IP="$_isp_ip"; fi
        fi
    done
    [ -n "$HA_INIT_NODE1_IP" ] || die "cannot determine this node's cluster IP (ip -o -4 addr shows no address outside node2/node3)"
    [ "$_isp_multi" = "0" ] || warn "multiple local addresses found - using $HA_INIT_NODE1_IP as the node 1 address"

    ha_run_sequence "init" \
        init_step_1_preflight \
        init_step_2_config_gen \
        init_step_3_packages \
        init_step_4_pg_prep \
        init_step_5_wal_log_hints \
        init_step_6_repmgr_conf \
        init_step_7_primary_register \
        init_step_8_agent \
        init_step_9_haproxy \
        init_step_10_repoint_dsn \
        init_step_11_wait_witness \
        init_step_12_wait_standby \
        init_step_13_sync_on \
        init_step_14_sync_setup \
        init_step_15_finalize
    verbose ""
    verbose "=== Cluster initialization completed successfully ==="
}

cmd_join() {
    if [ -f "$HA_MARKER_FILE" ]; then
        die "this node already joined a cluster ($HA_MARKER_FILE exists).
Maintenance of a joined node is done with: fusionpbx-ha.sh --repair"
    fi

    # unpack the token into a temporary cluster.conf, validate, detect role
    HA_JOIN_TMP_CONF="$(mktemp "${TMPDIR:-/tmp}/fpbx-ha-join.XXXXXX")"
    # the temp file carries secrets - remove it on ANY exit path
    trap 'rm -f "$HA_JOIN_TMP_CONF" 2>/dev/null' INT TERM EXIT
    if [ -n "$HA_CONFIG_FILE" ]; then
        [ -f "$HA_CONFIG_FILE" ] || die "--config file not found: $HA_CONFIG_FILE"
        install -m 600 "$HA_CONFIG_FILE" "$HA_JOIN_TMP_CONF"
    else
        [ -n "$HA_JOIN_TOKEN" ] || die "--join requires a TOKEN (or use --config FILE)"
        ha_token_unpack "$HA_JOIN_TOKEN" "$HA_JOIN_TMP_CONF"
    fi

    HA_CLUSTER_CONF="$HA_JOIN_TMP_CONF"
    ha_load_cluster_conf
    ha_detect_role || die "this host's IP is not in the cluster node list - the token belongs to another cluster/network"
    HA_CLUSTER_CONF="$HA_ETC_DIR/cluster.conf"   # from here on: the real path
    HA_JOIN_ROLE="standby"
    [ "$HA_NODE_ID" = "3" ] && HA_JOIN_ROLE="witness"
    ha_apply_proxy

    if [ "$HA_NODE_ID" = "3" ]; then
        ha_run_sequence "join-witness" \
            wit_step_1_preflight \
            wit_step_2_unpack \
            wit_step_3_packages \
            wit_step_4_initdb_tiny \
            wit_step_5_repmgr_conf \
            wit_step_6_witness_register \
            wit_step_7_repmgrd \
            wit_step_8_finalize
    else
        ha_run_sequence "join-standby" \
            join_step_1_preflight \
            join_step_2_unpack \
            join_step_3_packages \
            join_step_4_confirm_and_stop_pg \
            join_step_5_clone \
            join_step_6_start_register \
            join_step_7_agent_haproxy \
            join_step_8_repoint_dsn \
            join_step_9_seed_media \
            join_step_10_lsyncd_start \
            join_step_11_finalize
    fi
    rm -f "$HA_JOIN_TMP_CONF"
    trap - INT TERM EXIT
    verbose ""
    verbose "=== Node joined the cluster successfully ==="
}

cmd_repair() {
    [ -f "$HA_CLUSTER_CONF" ] || die "no cluster configuration ($HA_CLUSTER_CONF).
A rebuilt node joins with: fusionpbx-ha.sh --join TOKEN
(or restore cluster.conf from a backup and re-run --repair)"
    [ -f "$HA_MARKER_FILE" ] || warn "no completion marker found - assuming a rebuilt node with a restored cluster.conf (DESIGN.md 12.1)"
    ha_load_cluster_conf
    ha_detect_role || die "this host's IP is not in the cluster node list"
    ha_apply_proxy
    ha_apply_no_proxy

    if [ "$HA_NODE_ID" = "3" ]; then
        ha_run_sequence "repair-witness" \
            wit_step_1_preflight \
            wit_step_4_initdb_tiny \
            wit_step_5_repmgr_conf \
            wit_step_6_witness_register \
            wit_step_7_repmgrd \
            wit_step_8_finalize
    else
        # choose the branch: peer primary (rejoin) vs surviving primary (degrade)
        _cmr_peer="$(ha_agent_code "$(ha_peer_ip)")"
        _cmr_local_rc=0; ha_local_role_code; _cmr_local_rc=$?
        if [ "$_cmr_peer" = "200" ]; then
            ha_run_sequence "repair-standby" \
                rep_step_1_preflight \
                rep_step_2_stop_services \
                rep_step_3_rejoin_or_clone \
                rep_step_4_services \
                rep_step_5_seed_media \
                rep_step_6_lsyncd \
                rep_step_7_ensure_sync \
                rep_step_8_finalize
        elif [ "$_cmr_local_rc" = "0" ]; then
            ha_run_sequence "repair-primary" \
                prp_step_1_preflight \
                prp_step_2_degrade \
                prp_step_3_services \
                prp_step_4_finalize
        else
            error "neither data node is a reachable primary:"
            error "  peer agent:  $(ha_agent_code "$(ha_peer_ip)")"
            error "  local role:  $([ "$_cmr_local_rc" = "1" ] && echo standby || echo down)"
            die "double failure / partition suspected - follow RUNBOOK.md section 6 (do NOT promote by hand while the peer's state is unknown)"
        fi
    fi
    verbose ""
    verbose "=== Repair completed successfully ==="
}

# =============================================================================
# main
# =============================================================================

case "$HA_COMMAND" in
    help)    ha_print_help; exit 0 ;;
    init)    cmd_init ;;
    join)    cmd_join ;;
    repair)  cmd_repair ;;
    status)  ha_load_cluster_conf; cmd_status ;;
    doctor)  ha_load_cluster_conf; cmd_doctor ;;
    print-token) ha_load_cluster_conf; cmd_print_token ;;
    *)       ha_print_help; [ -z "$HA_COMMAND" ] && exit 0 || exit 1 ;;
esac

