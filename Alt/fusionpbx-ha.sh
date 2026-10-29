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
#   fusionpbx-ha.sh                            # interactive (terminal only):
#                                             # asks the node role (primary /
#                                             # standby / witness), the role's
#                                             # arguments and the proxy
#   fusionpbx-ha.sh --init --node2 IP --node3 IP [--cluster-name NAME]
#   fusionpbx-ha.sh --join TOKEN            # TOKEN = string or @file
#   fusionpbx-ha.sh --repair [--force-clone]
#   fusionpbx-ha.sh --status
#   fusionpbx-ha.sh --doctor
#   fusionpbx-ha.sh --print-token           # re-print the join token (node 1)
#
# Common flags:
#   --yes        non-interactive (answers all confirmations with yes;
#                also disables the interactive questions)
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
# 0.3.34: the script moved from Alt/ha/ up to Alt/ (next to the layer-1
# pre-install.sh/install.sh - one system, one place); its resources stay in
# Alt/ha/. Two layouts to resolve, and an exported HA_RES_DIR always wins
# (the sandbox tests pin it):
#   flat (deployed / a copied dir): <dir>/fusionpbx-ha.sh + <dir>/resources/
#   repo (0.3.34+):                 Alt/fusionpbx-ha.sh + Alt/ha/resources/
# Alt/resources/ is the LAYER-1 resource dir (no ha-lib.sh inside) - the
# file probe below can never mistake it for ours.
if [ -z "${HA_RES_DIR:-}" ]; then
    if [ -f "$SCRIPT_DIR/resources/ha-lib.sh" ]; then
        HA_RES_DIR="$SCRIPT_DIR/resources"
    else
        HA_RES_DIR="$SCRIPT_DIR/ha/resources"
    fi
fi

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
HA_PICK_ROLE="${HA_PICK_ROLE:-}"             # set by the interactive picker (or
                                    # the environment - automation); the join
                                    # flow cross-checks it against the
                                    # authoritative IP match from the token
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

# --proxy format must be valid before ANY command runs: the layer-1 proxy.sh
# writes apt/git/wget/curl configs unconditionally, and a typo must not get
# that far (DESIGN.md 5.1)
proxy_server_valid \
    || die "--proxy expects host:port (e.g. 192.168.0.1:8080), got: '$PROXY_SERVER'"

# =============================================================================
# Interactive questions (a human behind a terminal)
#
# The UX rule: instead of memorizing flags, a human runs the script bare and
# answers a few questions. Every question has a safe default or re-asks until
# valid; anything already given on the command line is NEVER asked for again
# (CLI wins). Never asks when: stdin is not a terminal (piped / ssh without
# -t / CI - takes the documented defaults and dies on missing arguments,
# exactly as before), --yes (automation), or HA_SANDBOX=1 (the test suite
# depends on 'no arguments -> help, exit 0' with piped stdin).
# =============================================================================

ha_ask() {          # ha_ask "question" [default] - prints the answer
    _haq_q="$1"
    _haq_def="${2:-}"
    # the prompt goes to STDERR: the answer is consumed via command
    # substitution and a prompt on stdout would glue itself to the answer
    if [ -n "$_haq_def" ]; then
        printf '%s [%s]: ' "$_haq_q" "$_haq_def" >&2
    else
        printf '%s: ' "$_haq_q" >&2
    fi
    read -r _haq_ans || { printf '\n' >&2; printf '%s\n' "$_haq_def"; return 0; }
    [ -z "$_haq_ans" ] && _haq_ans="$_haq_def"
    printf '%s\n' "$_haq_ans"
}

ha_interactive_pick() {
    [ -t 0 ] || return 0
    [ "${HA_SANDBOX:-0}" = "1" ] && return 0
    [ "${HA_AUTO_YES:-0}" = "1" ] && return 0

    # a bare run on an already-joined node: the picker would only lead into
    # a refusal - answer the likely intent right away
    if [ -z "$HA_COMMAND" ] && [ -f "$HA_MARKER_FILE" ]; then
        info ""
        info "This node is already part of an HA cluster ($HA_MARKER_FILE)."
        info "Maintenance: --status, --doctor; node problems: --repair;"
        info "the full usage: fusionpbx-ha.sh --help"
        exit 0
    fi

    if [ -z "$HA_COMMAND" ]; then
        info ""
        info "No command given - answer a few questions to set this node up"
        info "(Ctrl-C to abort and see the full usage with --help)."
        info ""
        info "  1) primary - the FIRST data node: --init (asks the node 2 and"
        info "     witness IPs, prints the join token; completes without waiting -"
        info "     the peers join afterwards)"
        info "  2) standby - the SECOND data node: --join (asks the token)"
        info "  3) witness - the witness node: --join (asks the same token)"
        info ""
        case "$(ha_ask "This node's role in the cluster (1/2/3)" "1")" in
            1|primary) HA_COMMAND="init" ;;
            2|standby) HA_COMMAND="join"; HA_PICK_ROLE="data" ;;
            3|witness) HA_COMMAND="join"; HA_PICK_ROLE="witness" ;;
            *) die "unrecognized role answer (expected 1, 2 or 3) - run with --help for the usage" ;;
        esac
    fi

    # fill the arguments the chosen (or given) command is missing
    case "$HA_COMMAND" in
        init)
            while [ -z "$HA_INIT_NODE2_IP" ] || ! valid_ip "$HA_INIT_NODE2_IP"; do
                [ -n "$HA_INIT_NODE2_IP" ] && info "  '$HA_INIT_NODE2_IP' is not a valid IPv4 address"
                HA_INIT_NODE2_IP="$(ha_ask "IP of the SECOND data node (--node2)" "")"
                [ -z "$HA_INIT_NODE2_IP" ] && info "  (required - Ctrl-C to abort)"
            done
            while [ -z "$HA_INIT_NODE3_IP" ] || ! valid_ip "$HA_INIT_NODE3_IP"; do
                [ -n "$HA_INIT_NODE3_IP" ] && info "  '$HA_INIT_NODE3_IP' is not a valid IPv4 address"
                HA_INIT_NODE3_IP="$(ha_ask "IP of the WITNESS node (--node3)" "")"
                [ -z "$HA_INIT_NODE3_IP" ] && info "  (required - Ctrl-C to abort)"
            done
            [ "$HA_INIT_NODE2_IP" != "$HA_INIT_NODE3_IP" ] \
                || die "node 2 and the witness must be different hosts (got: $HA_INIT_NODE2_IP)"
            ;;
        join)
            if [ -z "$HA_JOIN_TOKEN" ] && [ -z "$HA_CONFIG_FILE" ]; then
                HA_JOIN_TOKEN="$(ha_ask "Join token printed by --init on node 1 (string or @file)" "")"
                [ -n "$HA_JOIN_TOKEN" ] || die "a join token is required (--join TOKEN)"
            fi
            ;;
    esac

    # proxy for the commands that install packages; cluster traffic always
    # goes direct (ha_apply_no_proxy, DESIGN.md 5.1)
    case "$HA_COMMAND" in
        init|join|repair)
            if [ -z "$PROXY_SERVER" ]; then
                while :; do
                    _hip_p="$(ha_ask "HTTP proxy for outbound internet, host:port (empty = direct connection)" "")"
                    [ -z "$_hip_p" ] && break
                    PROXY_SERVER="$_hip_p"
                    proxy_server_valid && break
                    info "  not a host:port proxy format: $_hip_p"
                    PROXY_SERVER=""
                done
                [ -n "$PROXY_SERVER" ] \
                    && info "  proxy: $PROXY_SERVER (cluster traffic always goes direct)"
            fi
            ;;
    esac
}
ha_interactive_pick

ha_print_help() {
    cat <<'HELP'
fusionpbx-ha.sh - FusionPBX HA cluster add-on for ALT Linux

Usage:
  fusionpbx-ha.sh --init --node2 IP --node3 IP [--cluster-name NAME]
      On the FIRST data node (VM1): accept the standalone FusionPBX
      installation as the cluster primary and print the join token.
      The command COMPLETES without waiting for the peers (install all
      three servers first): join them afterwards with --join. Synchronous
      replication and media sync arm themselves when node 2 joins.

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

Interactive mode:
  Run the script with NO command on a terminal and it asks:
    - this node's role in the cluster (primary / standby / witness)
    - the arguments the role needs (--node2/--node3 IPs or the join token)
    - an HTTP proxy for outbound internet (empty = direct; cluster traffic
      always goes direct)
  A bare Enter takes the shown default; anything already passed on the
  command line is never asked for again. Without a terminal on stdin
  (piped / ssh / CI), with --yes, or with an already-joined node nothing
  is asked - the bare run prints this help instead.

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

    # the free-port check belongs to a FRESH install only: a re-configure
    # over an installed node (--init --force, marker present) finds
    # 5433/8008 held by THIS cluster's own haproxy/agent - not a conflict
    # (0.3.16; before, the documented maintenance path died at step 1)
    if [ ! -f "$HA_MARKER_FILE" ] && ! ha_state_step_is_done 1; then
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
    elif [ -f "$HA_CLUSTER_CONF" ] && [ "${HA_FORCE:-0}" = "1" ]; then
        warn "--force: generating a NEW cluster.conf (new passwords, new token!)"
        ha_generate_cluster_conf
    else
        ha_generate_cluster_conf
    fi
    # The sequence runner re-sources cluster.conf for the FOLLOWING steps
    # only - THIS step (hosts block, no_proxy, token) needs the node list and
    # the ports right now; on a fresh node they did not exist anywhere before
    # this point (regression 0.3.1)
    # shellcheck disable=SC1090
    . "$HA_CLUSTER_CONF"
    ha_write_etc_hosts_block
    ha_apply_no_proxy

    # print the token immediately (DESIGN.md 6.2): the operator joins
    # VM2/VM3 with it AFTER this command completes (0.3.39: --init does
    # not wait for the peers anymore - install them first, then connect
    # them to the cluster)
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
    verbose " after use. This command does NOT wait for the other nodes: join them"
    verbose " next, each with:  fusionpbx-ha.sh --join <TOKEN>"
    verbose "========================================================================="
    echo ""
}

init_step_3_packages() {
    pkg_install_required "postgresql${HA_PG_VERSION}-repmgr" haproxy lsyncd sudo \
        python3 python3-module-psycopg2 openssh-clients rsync curl
}

init_step_4_pg_prep() {
    # The FIRST installer write to the database. A synchronous_standby_names
    # left by the previous cluster (re-install / --force over an installed
    # node) freezes every commit the moment its standby is gone - the old
    # walreceiver drops right after the password alignment below / the
    # step 5 restart. Clear it BEFORE writing (regression 0.3.17); step 13
    # re-enables sync once the new standby streams. No-op on a clean node.
    ha_clear_stale_sync_names
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
    # the extension is created by the postgres superuser, so the schema
    # belongs to postgres - hand it to the repmgr role together with the
    # DML grants, otherwise 'repmgr primary register' (step 7) dies with
    # "permission denied for schema repmgr" (regression 0.3.3)
    ha_fix_repmgr_schema_access
    verbose "  extension ready: repmgr"

    ha_write_pg_hba data
    systemctl reload "$HA_PG_SERVICE" 2>/dev/null || pg_runuser_psql -c "SELECT pg_reload_conf();" >/dev/null

    # the register path as a whole: the repmgr ROLE must be able to READ
    # the metadata schema over TCP - this catches both pg_hba gaps and
    # missing schema grants (a plain "SELECT 1" passed while register
    # still died - regression 0.3.3)
    PGPASSWORD="$HA_REPMGR_PASSWORD" psql -h 127.0.0.1 -p "$HA_PG_PORT" -U "$HA_REPMGR_USER" -d "$HA_REPMGR_DB" -tAc "SELECT 1 FROM repmgr.nodes LIMIT 1" >/dev/null 2>&1 \
        || warn "cannot read repmgr.nodes as $HA_REPMGR_USER on 127.0.0.1:$HA_PG_PORT (pg_hba or schema grants) - 'repmgr primary register' will fail"
}

init_step_5_wal_log_hints() {
    # PostgreSQL becomes network-reachable in this step (listen_addresses)
    # - open the cluster firewall ports at the same time, otherwise no
    # peer can ever connect: layer 1 whitelists INPUT without 5432/8008
    # (regression 0.3.6)
    ha_ensure_cluster_firewall
    _iwl_need_restart=0

    if [ "$(pg_runuser_psql -tAc "SHOW wal_log_hints" | tr -d ' \r')" = "on" ]; then
        verbose "  wal_log_hints is already on (pg_rewind support)"
    else
        verbose "  enabling wal_log_hints (required by pg_rewind when a former"
        verbose "  primary is repaired after a failover)"
        pg_runuser_psql -c "ALTER SYSTEM SET wal_log_hints = on;" >/dev/null \
            || die "cannot set wal_log_hints"
        _iwl_need_restart=1
    fi

    # listen_addresses joins the same restart: repmgr, the peer haproxy and
    # the witness connect to THIS node's IP, but layer 1 leaves PostgreSQL
    # loopback-only (regression 0.3.2)
    if ha_pg_listen_ok; then
        verbose "  listen_addresses already serves $(ha_node_ip "$HA_NODE_ID")"
    else
        verbose "  setting listen_addresses = '*' (repmgr + haproxy need the node IP)"
        pg_runuser_psql -c "ALTER SYSTEM SET listen_addresses = '*';" >/dev/null \
            || die "cannot set listen_addresses"
        _iwl_need_restart=1
    fi

    # repmgrd's shared memory module joins the SAME restart (regression
    # 0.3.15): repmgrd calls set/get_local_node_id right after connecting
    # and dies with exit 1 ('unable to write to shared memory', reason only
    # in /var/log/repmgr/repmgrd.log) when the library was not preloaded at
    # server start. The clone inherits the line, the witness gets it in its
    # own step 4; step 7 starts repmgrd right after this restart
    if ha_repmgr_preload_active; then
        verbose "  shared_preload_libraries already includes repmgr (repmgrd-ready)"
    else
        ha_repmgr_preload_write
        verbose "  enabling shared_preload_libraries = 'repmgr' (repmgrd shared memory)"
        _iwl_need_restart=1
    fi

    if [ "$_iwl_need_restart" = "0" ]; then
        verbose "  nothing to apply - no PostgreSQL restart"
        return 0
    fi
    verbose "  - ONE PostgreSQL restart for the settings above"
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
    ha_pg_listen_ok || die "listen_addresses did not take effect"
    ha_repmgr_preload_active \
        || die "shared_preload_libraries does not include 'repmgr' after the restart - check the PostgreSQL log"
    verbose "  wal_log_hints = on, listen_addresses = '*', repmgr preloaded, PostgreSQL is back"
}

init_step_6_repmgr_conf() {
    ha_render_repmgr_conf primary
    ha_install_promote_sh
    ha_install_sudoers
    ha_install_pg_boot_guard
    # the standby's media seed (join step 9) pulls $HA_SYNC_DIR over rrsync
    # the moment it starts streaming - LONG before init reaches the media
    # sync setup (step 14) that used to be the dir's only creator: on the
    # real bench the seed won the race and rrsync died 'post-realpath open
    # failed (race detected): ... No such file or directory'. Ensured HERE
    # so it exists before the primary register (step 7) - no standby can
    # seed earlier than it can clone (regression 0.3.11).
    ha_ensure_sync_dir
    verbose "  repmgr configuration written: $HA_REPMGR_CONF (role: primary)"
}

init_step_7_primary_register() {
    # The bench hang (regression 0.3.17): with a stale
    # synchronous_standby_names and the old standby already gone, the
    # schema grants below sat on 'ALTER SCHEMA' forever ('canceling wait
    # for synchronous replication' in the Ctrl-C trace). A resume also
    # enters HERE with steps 1-6 skipped - the guard must precede the
    # first write of the step.
    ha_clear_stale_sync_names
    # Self-healing for runs resumed from a state file written by an older
    # script version (pg_hba set / listen_addresses / repmgr.conf keys)
    ha_register_prelude primary
    _ipr_out="$(repmgr_cmd primary register --force)"
    if [ $? -ne 0 ]; then
        echo "$_ipr_out"
        die "'repmgr primary register' failed (see output above)"
    fi
    ha_scrub_conninfo_secrets   # 0.3.33: keep password= out of the records
                                # from the very first registration
    echo "$_ipr_out" | grep -q "successfully\|already registered" 2>/dev/null || verbose "  $_ipr_out"
    verbose "  this node is registered as the cluster primary (node 1)"
    # 0.3.16: the repmgrd unit drop-in (ordering + REPMGRD_OPTS) is
    # installer-owned - installed before every repmgrd enable+start
    ha_install_repmgr_dropin
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
    # The applications are repointed to THIS primary right below - their
    # writes must not freeze on a stale sync-standby wait while the new
    # standby has not joined yet (it joins AFTER this command completes
    # since 0.3.39; regression 0.3.17)
    ha_clear_stale_sync_names
    ha_repoint_dsn
}

init_poll_witness_registered() {
    pg_runuser_psql -d "$HA_REPMGR_DB" -tAc "SELECT 1 FROM repmgr.nodes WHERE node_id=3" 2>/dev/null | grep -q 1
}

init_step_11_witness_status() {
    # self-heal for runs resumed from an older state file: the firewall
    # rules were only added to step 5 by 0.3.6, a resume from step 11
    # would never re-run it (regression 0.3.6)
    ha_ensure_cluster_firewall
    # 0.3.39: --init does NOT wait for the peers anymore. The old ha_wait
    # here (and in step 12) put a 900s timer on the operator's peer
    # installation (HA_WAIT_NODES, 0.3.8) - impossible to meet when the
    # peers were still being installed, and the timeout killed an
    # otherwise healthy bootstrap. The documented flow is now "install
    # all three servers first, then connect them to the cluster": this
    # command completes alone, the peers join afterwards with --join, and
    # nothing on this node depends on WHEN they do (the witness registers
    # against this primary whenever it arrives; sync mode is armed by the
    # standby's own join step 11). A node that is not yet the complete
    # cluster primary right after the install is the accepted price.
    if init_poll_witness_registered; then
        verbose "  witness $(ha_node_name 3) is registered in the cluster"
    else
        verbose "  witness not joined yet - run --join on $HA_INIT_NODE3_IP afterwards"
    fi
}

init_poll_standby_streaming() {
    pg_runuser_psql -d postgres -tAc \
        "SELECT 1 FROM pg_stat_replication WHERE application_name='$(ha_node_name 2)' AND state='streaming'" \
        2>/dev/null | grep -q 1
}

init_step_12_standby_status() {
    # same self-heal as step 11 (regression 0.3.6)
    ha_ensure_cluster_firewall
    # resume self-heal (regression 0.3.11): a resume from an old state file
    # skips step 6 - the media dir must exist before the standby starts
    # streaming (its join step 9 seeds from it immediately)
    ha_ensure_sync_dir
    # the standby's join step 9 (media seed) SSHes into THIS node with the
    # sync key - authorized_keys cannot wait for step 14: on the real bench
    # step 13 crashed, 14 never ran and the seed died with 'Permission
    # denied' (regression 0.3.9). Idempotent. With the waits gone (0.3.39)
    # the standby may join any time AFTER this command completes - both
    # self-heals must already be in place by then.
    ha_write_authorized_keys
    # 0.3.39: no ha_wait here either - the standby's join itself performs
    # the convergence that the old wait guarded (join step 11 calls
    # ha_ensure_sync FOR THIS primary the moment the standby streams).
    if init_poll_standby_streaming; then
        verbose "  standby $(ha_node_name 2) is streaming from this primary"
    else
        verbose "  standby not streaming yet - run --join on $HA_INIT_NODE2_IP afterwards;"
        verbose "  its join arms synchronous replication on this primary automatically"
    fi
}

init_step_13_sync_on() {
    # resume self-heal (regression 0.3.9): a bench resume entered here with
    # steps 1-12 done and authorized_keys still unwritten (step 14 business)
    # while the standby's media seed was already failing - re-apply it first
    ha_write_authorized_keys
    # resume self-heal (regression 0.3.11): same for the media dir itself -
    # the standby's seed rsync reads it through rrsync on THIS node
    ha_ensure_sync_dir
    ha_ensure_sync local
}

init_step_14_sync_setup() {
    ha_write_authorized_keys
    ha_ensure_sync_dir
    touch "$HA_KNOWN_HOSTS" && chmod 600 "$HA_KNOWN_HOSTS"
    if cmd_exists ssh-keyscan; then
        ssh-keyscan -t ed25519 "$(ha_node_ip 2)" >> "$HA_KNOWN_HOSTS" 2>/dev/null \
            || warn "ssh-keyscan failed for $(ha_node_ip 2) - first sync will use accept-new (TOFU)"
    fi
    ha_render_lsyncd_conf "$(ha_node_ip 2)"
    ha_install_lsyncd_dropin
    svc_enable_start "$HA_LSYNCD_SERVICE"
    # 0.3.39: before the standby joins, lsyncd cannot reach its target and
    # logs rsync connection failures - expected bootstrap noise, not an
    # error. The standby's join step 9 seeds the WHOLE media tree (pull
    # from this node), which closes the gap; lsyncd converges on the next
    # local change afterwards.
    init_poll_standby_streaming || warn "lsyncd starts now, but $(ha_node_name 2) is not streaming yet:
  media sync engages when it joins (rsync failures in the lsyncd log until
  then are expected; the standby's join seeds the media tree and closes the gap)"
}

init_step_15_finalize() {
    verbose ""
    verbose "Cluster summary:"
    repmgr_cmd cluster show | sed 's/^/  /'
    verbose ""
    verbose "  entry point for applications: 127.0.0.1:$HA_HAPROXY_PORT (haproxy)"
    if init_poll_standby_streaming; then
        verbose "  synchronous replication:      on (RPO = 0 for committed data)"
        verbose "  media sync:                   $HA_SYNC_DIR <-> $(ha_node_ip 2)"
        verbose ""
        verbose "Next: 'fusionpbx-ha.sh --doctor' on all three nodes."
        verbose "Token needed again? 'fusionpbx-ha.sh --print-token' (this node only)."
    else
        # 0.3.39: the peers were not required to be here - the bootstrap is
        # still a SUCCESS, the cluster completes itself when they join.
        verbose "  synchronous replication:      pending - arms AUTOMATICALLY when"
        verbose "                                $(ha_node_name 2) joins (currently async - writes work)"
        verbose "  media sync:                   pending - engages when $(ha_node_name 2) joins"
        verbose ""
        verbose "Bootstrap on this node is DONE - the primary runs alone for now (async,"
        verbose "no failover protection until the peers join). Next, join the peers:"
        verbose "  on $HA_INIT_NODE2_IP:  fusionpbx-ha.sh --join <TOKEN>   (standby)"
        verbose "  on $HA_INIT_NODE3_IP:  fusionpbx-ha.sh --join <TOKEN>   (witness)"
        verbose "The token was printed above; 'fusionpbx-ha.sh --print-token' re-prints it"
        verbose "(this node only). Until the peers join, --doctor on THIS node reports"
        verbose "the missing nodes - that is expected during bootstrap."
    fi
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
        # Regression 0.3.19: a standby does not NEED a local database -
        # step 5 wipes whatever is here and clones the primary. PG_VERSION
        # is absent on a wiped/rebuilt node or after a join that died between
        # the step-5 wipe and the re-clone; demanding it here dead-ended
        # exactly that recovery: the fresh re-join after the 0.3.18 state
        # discard died with a misleading 'run layer 1 first' while layer 1
        # was fine (and --force did not help - step 1 dies regardless of
        # the state file). Layer 1 is proven by $HA_L1_CONF above; the
        # server packages of the cluster's major are installed by step 3.
        # Only a REAL conflict of an EXISTING local cluster is fatal.
        if _jsp_ver="$(ha_pg_version_major)"; then
            [ "$_jsp_ver" = "$HA_PG_VERSION" ] \
                || die "PostgreSQL major version mismatch: local $_jsp_ver, cluster $HA_PG_VERSION
The cluster was initialized with PostgreSQL $HA_PG_VERSION."
        else
            verbose "  no local data directory ($(ha_pg_data_dir)) -"
            verbose "  the local database will be cloned from the primary at step 5"
        fi
    fi

    if [ "$HA_NODE_ID" != "3" ]; then
        _jsp_peer="$(ha_peer_ip)"
        # the local INPUT rules for the peers: after the join the primary's
        # haproxy checks THIS node's agent (8008) and both backends on 5432
        # (the peer's own rules are its --init's job)
        ha_ensure_cluster_firewall
        if ! ha_pg_isready "$_jsp_peer"; then
            die "the peer data node $_jsp_peer is not reachable on port $HA_PG_PORT
probe verdict: ${HA_PG_ISREADY_MSG:-pg_isready failed without a message}
--join needs the running primary:
  1. complete --init on the primary first - it opens the cluster firewall
     rules (22/$HA_PG_PORT/$HA_AGENT_PORT from the cluster nodes; layer 1
     whitelists INPUT WITHOUT the cluster ports, regression 0.3.6)
  2. re-run this SAME command - completed steps are skipped automatically
manual check on the peer:  iptables -L INPUT -n | grep -E '($HA_PG_PORT|$HA_AGENT_PORT)'"
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
        # repmgr.conf + promote.sh MUST exist BEFORE join_step_5_clone: it
        # runs 'repmgr standby clone' which reads the configuration file
        # (regression 0.3.2 - the clone failed without these)
        ha_render_repmgr_conf standby
        ha_install_promote_sh
        ha_install_sudoers
        ha_install_pg_boot_guard
        verbose "  repmgr configuration written: $HA_REPMGR_CONF (role: standby)"
    else
        # defensive branch - the dispatcher routes node 3 to the wit_* steps;
        # NO .pgpass here: the witness has no layer 1, /var/lib/pgsql appears
        # only after step 3 installs postgresql-server; the register prelude
        # writes it (regression 0.3.7)
        :
    fi
    ha_write_etc_hosts_block
    ha_apply_no_proxy
    verbose "  cluster configuration installed: $HA_CLUSTER_CONF"
}

join_step_3_packages() {
    if [ "$HA_NODE_ID" = "3" ]; then
        pkg_install_required "postgresql${HA_PG_VERSION}-repmgr" "postgresql${HA_PG_VERSION}-server" curl
    else
        pkg_install_required "postgresql${HA_PG_VERSION}-repmgr" haproxy lsyncd sudo \
            python3 python3-module-psycopg2 openssh-clients rsync curl
        # 0.3.13: step 2 wrote the sync-key line BEFORE rsync existed on
        # this node - without rrsync it carries no forced command at all.
        # Re-render now that the package (and its rrsync helper) is in
        # place. Idempotent; on resume this step is skipped and the
        # cmd_join prelude does the convergence instead.
        ha_write_authorized_keys
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

    # self-healing preamble (idempotent; the clone normally inherits a
    # correct pg_hba/listen_addresses from the primary)
    ha_register_prelude standby

    _jsr_out="$(repmgr_cmd standby register --upstream-node-id="$(ha_peer_id)" --force)"
    if [ $? -ne 0 ]; then
        echo "$_jsr_out"
        die "'repmgr standby register' failed (see output above)"
    fi
    ha_scrub_conninfo_secrets   # 0.3.33: the fresh record is clean (passwordless
                                # conninfo); this also strips the PEER's legacy
                                # record - the peer is the writable primary
    verbose "  registered as a standby of node $(ha_peer_id) ($(ha_peer_name))"
    # 0.3.16: the repmgrd unit drop-in (ordering + REPMGRD_OPTS) is
    # installer-owned - installed before every repmgrd enable+start
    ha_install_repmgr_dropin
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
    ha_ensure_sync_dir
    verbose "  pulling the media tree from $(ha_peer_name) (seed BEFORE the sync"
    verbose "  daemon starts - protects the peer copy from being wiped by an"
    verbose "  empty local tree; DESIGN.md 10.2)"
    # the pull itself (why the remote spec is the bare dot + the 0.3.23
    # rrsync-lock retries) lives in ha-lib: ha_seed_pull
    ha_seed_pull "$(ha_peer_ip)"
    verbose "  media tree seeded: $HA_SYNC_DIR"
}

join_step_10_lsyncd_start() {
    ha_render_lsyncd_conf "$(ha_peer_ip)"
    ha_install_lsyncd_dropin
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
    ha_ensure_cluster_firewall
    for _wit_ip in "$(ha_node_ip 1)" "$(ha_node_ip 2)"; do
        if ha_pg_isready "$_wit_ip"; then _jsp_up="$_wit_ip"; break; fi
    done
    [ -n "$_jsp_up" ] || die "neither $(ha_node_ip 1) nor $(ha_node_ip 2) is reachable on $HA_PG_PORT - a data node must be running
probe verdict: ${HA_PG_ISREADY_MSG:-pg_isready failed without a message}
complete --init on the primary data node first - it opens the cluster
firewall rules (22/$HA_PG_PORT/$HA_AGENT_PORT from the cluster nodes;
layer 1 whitelists INPUT WITHOUT the cluster ports, regression 0.3.6)
manual check on the data node:  iptables -L INPUT -n | grep -E '($HA_PG_PORT|$HA_AGENT_PORT)'"
    verbose "  preflight OK: joining as WITNESS (node 3)"
}

wit_step_2_unpack() {
    mkdir -p "$HA_ETC_DIR"
    chmod "$HA_CONF_DIR_MODE" "$HA_ETC_DIR"
    install -m 600 "$HA_JOIN_TMP_CONF" "$HA_CLUSTER_CONF" || die "cannot write $HA_CLUSTER_CONF"
    # NO .pgpass here: the witness has no layer 1, /var/lib/pgsql appears
    # only after step 3 installs postgresql-server; the register prelude
    # (step 6) writes it (regression 0.3.7)
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
        # the preload must be IN THE CONFIG before the first start - the
        # witness repmgrd (step 7) dies without it (regression 0.3.15);
        # ALTER SYSTEM cannot work on a server that is not running yet,
        # so the write helper falls back to postgresql.auto.conf
        ha_repmgr_preload_write
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

    # A REUSED witness (an interrupted join resumes here with the database
    # already answering) must be able to run repmgrd in step 7 - that is
    # the join contract for BOTH paths: the fresh path above wrote the
    # preload before the first start, the reuse path converges it after
    # the start (write + ONE restart + verify, 0.3.15; kept in 0.3.16 -
    # this is the only preload write point the witness has)
    ha_ensure_repmgr_preload

    # the witness's own repmgrd (conninfo host = THIS IP) and the failover
    # consensus of the data nodes both connect to the witness node IP
    ha_ensure_pg_listen

    if ! pg_runuser_psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$HA_REPMGR_USER'" | grep -q 1; then
        pg_runuser_psql -c "SET password_encryption = 'md5'; CREATE ROLE $HA_REPMGR_USER LOGIN PASSWORD '$HA_REPMGR_PASSWORD';" \
            || die "cannot create the repmgr role on the witness"
    else
        # 0.3.16: a REUSED witness keeps the role from its previous join -
        # align the password with the CURRENT token (the witness repmgrd
        # connects to this local database with it; --init --force on the
        # primary regenerates the secrets, the reuse path must converge)
        pg_runuser_psql -c "SET password_encryption = 'md5'; ALTER ROLE $HA_REPMGR_USER WITH PASSWORD '$HA_REPMGR_PASSWORD';" >/dev/null \
            || die "cannot update the repmgr role password on the witness"
        verbose "  role exists: $HA_REPMGR_USER (password aligned with the token)"
    fi
    if ! pg_runuser_psql -tAc "SELECT 1 FROM pg_database WHERE datname='$HA_REPMGR_DB'" | grep -q 1; then
        pg_runuser_psql -c "CREATE DATABASE $HA_REPMGR_DB OWNER $HA_REPMGR_USER;" \
            || die "cannot create the $HA_REPMGR_DB database on the witness"
    fi
    pg_runuser_psql -d "$HA_REPMGR_DB" -c "CREATE EXTENSION IF NOT EXISTS repmgr;" >/dev/null \
        || die "cannot create the repmgr extension"
    # the witness's own repmgrd DMLs its LOCAL metadata DB during failover
    # elections - it needs the same schema grants as the data nodes
    ha_fix_repmgr_schema_access
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
    # self-healing preamble (idempotent)
    ha_register_prelude witness
    _wfr_ip="$(wit_find_primary_ip)"
    [ -n "$_wfr_ip" ] || die "no primary found ($(ha_node_ip 1) and $(ha_node_ip 2) role-agents do not answer 200)
The witness registers against a running primary - complete --init on the primary first."
    _wfr_out="$(repmgr_cmd witness register -h "$_wfr_ip" --force)"
    if [ $? -ne 0 ]; then
        echo "$_wfr_out"
        die "'repmgr witness register' against $_wfr_ip failed (see output above)"
    fi
    ha_scrub_conninfo_secrets   # 0.3.34: the register --force re-copied
                                # repmgr.nodes from the (scrubbed) primary;
                                # this cleans the witness's OWN local
                                # repmgr.events rows, which may still carry
                                # password= from registrations done by
                                # pre-0.3.33 versions
    verbose "  witness registered against the primary $_wfr_ip"
}

wit_step_7_repmgrd() {
    # 0.3.16: the repmgrd unit drop-in (ordering + REPMGRD_OPTS) is
    # installer-owned - installed before every repmgrd enable+start
    ha_install_repmgr_dropin
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
    # 0.3.21: crash-window honesty (bench: a repair that died between
    # this step and rep_step_4 left repmgrd stopped - the next primary
    # outage had NOBODY to promote the standby, total outage). An
    # interrupted repair must be re-run before this node can fail over.
    warn "repmgrd and lsyncd are now STOPPED - until this repair"
    warn "completes (re-run the same command to resume), this node will"
    warn "NOT be promoted automatically if the peer dies"
}

rep_step_3_rejoin_or_clone() {
    # 0.3.22: a RESUMED repair skips step 2 - and with it the loud warning
    # that the failover daemon is down. If this run begins with repmgrd
    # still stopped, say so again (it restarts at step 4).
    if ha_state_step_is_done 2 && ! svc_active "$HA_REPMGRD_SERVICE"; then
        warn "repmgrd is still stopped (repair step 2) - automatic failover returns at step 4"
    fi
    # repmgr.conf + promote.sh first: 'repmgr standby clone/register' and
    # 'repmgr node rejoin' below all read the configuration file, which may
    # be missing on a rebuilt node with a restored cluster.conf (12.1)
    ha_render_repmgr_conf standby
    ha_install_promote_sh
    ha_install_sudoers
    ha_install_pg_boot_guard
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
        # 0.3.28: standby.signal is written by the clone - the guard
        # allows this start; only clear the boot-time rate-limit poison
        ha_pg_start_tracked || die "PostgreSQL did not start after the clone"
        _r3c_out="$(repmgr_cmd standby register --upstream-node-id="$(ha_peer_id)" --force)"
        if [ $? -ne 0 ]; then
            echo "$_r3c_out"
            die "'repmgr standby register' failed (see output above)"
        fi
        verbose "  re-cloned and registered as a standby of $(ha_peer_name)"
    else
        # 0.3.22: repmgr 5.5 REFUSES 'node rejoin' on a running database
        # ("database is still running in state 'in archive recovery'" /
        # "cannot be executed on a running node") - the bench repair died
        # right here on a perfectly HEALTHY standby that only needed its
        # services restarted. Classify the local node FIRST:
        #   - attached standby of the current primary: no rejoin at all,
        #     only the metadata record is refreshed (register --force) -
        #     the replication keeps streaming through the repair;
        #   - anything else (a stale primary from before a failover, a
        #     standby on a dead/wrong upstream): STOP PostgreSQL, rejoin
        #     with pg_rewind, then make sure systemd tracks it again
        #     (repmgr may have (re)started it via pg_ctl).
        # 0.3.32: a local database that CANNOT START cannot be an
        # attached standby either - the 27.10 morning boot of the 26.10
        # zombie: after the failed pg_rewind rejoin (missing grants,
        # fixed in 0.3.31) the node carried standby.signal with its last
        # checkpoint PAST the peer's fork point, and PostgreSQL 16
        # refuses to boot such a standby AT ALL ("no branching of the
        # requested timeline 5 in the server's history: last checkpoint
        # 0/D251590 on timeline 4, but it forked at 0/D251518") - the
        # classification start died and the repair kept advising
        # --force-clone for an INTACT database whose cure is a rewind,
        # not a wipe. A failed classification start now simply means
        # "diverged": skip the classifier and go straight to the rejoin
        # (the node is already stopped; repmgr's rejoin owns the rewind
        # and the start) - and if THAT fails, the die below still points
        # at --force-clone for genuinely broken data directories.
        _r3c_plan="diverged"
        if svc_active "$HA_PG_SERVICE"; then
            pg_runuser_psql -tAc "SELECT 1" >/dev/null 2>&1 \
                || die "local PostgreSQL is active but not answering (check the PostgreSQL log) - re-run with --force-clone if the data directory is damaged"
            _r3c_plan="$(ha_rejoin_plan "$(ha_peer_ip)")"
        else
            # 0.3.28: the classifier needs a RUNNING database, i.e. this
            # start may briefly boot a stale primary - the boot guard
            # must let the REPAIR's own start through (see
            # ha_pg_start_for_classification; the 26.10 bench died here
            # with the guard blocking the repair itself)
            if ha_pg_start_for_classification && ha_pg_wait_answer \
                && pg_runuser_psql -tAc "SELECT 1" >/dev/null 2>&1; then
                _r3c_plan="$(ha_rejoin_plan "$(ha_peer_ip)")"
            else
                verbose "  local PostgreSQL does not start or answer - it cannot be an"
                verbose "  attached standby (the 26.10 state: a checkpoint past the peer's"
                verbose "  fork point refuses to boot until pg_rewind) -"
                verbose "  treating the node as diverged and going straight to the rejoin"
            fi
        fi
        if [ "$_r3c_plan" = "attached" ]; then
            _r3c_out="$(repmgr_cmd standby register --upstream-node-id="$(ha_peer_id)" --force)"
            if [ $? -ne 0 ]; then
                echo "$_r3c_out"
                die "'repmgr standby register' failed (see output above)"
            fi
            verbose "  already a healthy standby of $(ha_peer_name) - rejoin not needed, replication left running"
        else
            # 0.3.36: the sudo heal + preflight BEFORE the stop - the 27.10
            # 16:36 bench: the preflight ran AFTER svc_stop and died on the
            # exec-level sudo breakage (EACCES for postgres on the sudo
            # binary itself - ALT's 'control sudo' restriction / a mode
            # drift), leaving PostgreSQL DOWN for nothing. The heal runs
            # first now, and a still-broken sudo is only a WARN: the
            # ROOT-START RESCUE below (ha_rejoin_rescue) completes a rejoin
            # whose inner 'sudo systemctl start' dies.
            ha_preflight_repmgr_service_commands
            verbose "  local database diverged from $(ha_peer_name) - stopping it for the rejoin (pg_rewind)"
            svc_stop "$HA_PG_SERVICE"
            # 0.3.25: repmgr builds the 'node rejoin' upstream connection from
            # the COMMAND LINE ONLY (repmgr-client.c: initialize_conninfo_params
            # (&source_conninfo, false) - no defaults, unlike 'witness register',
            # which backfills user+dbname from repmgr.conf). With a bare
            # '-h <peer>' libpq fell back to the OS user (postgres) and its
            # default database (also postgres) - the .pgpass postgres entry
            # even let md5 auth pass, so repmgr queried repmgr.nodes in the
            # peer's 'postgres' database and died:
            #   ERROR: get_primary_node_id(): unable to execute query
            #   ERROR: отношение "repmgr.nodes" не существует
            #   HINT: check the provided database connection string is for a
            #         "repmgr" database
            # (first real exercise of the diverged branch: the bench repairs
            # of 0.3.22/0.3.23 all took the 'attached' path). Give the rejoin
            # the same explicit identity the clone command has always used.
            #
            # 0.3.33: the 27.10 rejoin reached the START for the first time
            # ever - pg_rewind succeeded ("0 files copied" - a ~240-byte
            # fork gap), repmgr wrote standby.signal + primary_conninfo
            # and called 'sudo systemctl start postgresql' ... which failed
            # with NOTHING: repmgr discards the captured child output when
            # the command fails (repmgr-action-standby.c:3553). Belt and
            # braces, verified against repmgr 5.5.0 sources:
            #   a) 'systemctl reset-failed' first: the classifier's own
            #      start attempt (this same run, on the un-rewound zombie)
            #      crash-looped PostgreSQL and systemd's start-rate limiter
            #      then refuses further starts with "Start request repeated
            #      too quickly" - the exact shape of "unable to start
            #      server" with a perfectly rewound data directory;
            #   b) the guard flag covers the WHOLE rejoin call (repmgr's
            #      systemctl start happens INSIDE it; see
            #      ha_repair_start_window_open);
            #   c) the ROOT-START RESCUE (0.3.36, ha_rejoin_rescue): the
            #      rejoin can die AFTER its data work (rewind, signal,
            #      conninfo) - the repair runs as ROOT, so IT starts
            #      PostgreSQL, proves the WAL receiver attached to the peer
            #      and finishes the registration. Between the attempts: the
            #      27.10 shape was a start-step failure over COMPLETE data
            #      work, and re-running pg_rewind over a finished rewind
            #      only deepened the WAL-limbo; the retry stays for REAL
            #      rewind failures (pg_rewind is re-runnable).
            _r3c_rescued=0
            systemctl reset-failed "$HA_PG_SERVICE" >/dev/null 2>&1 || true
            ha_repair_start_window_open
            _r3c_out="$(repmgr_cmd node rejoin --force-rewind -h "$(ha_peer_ip)" -U "$HA_REPMGR_USER" -d "$HA_REPMGR_DB")"
            _r3c_rc=$?
            ha_repair_start_window_close
            if [ "$_r3c_rc" -ne 0 ]; then
                echo "$_r3c_out"
                ha_rejoin_failure_forensics
                if ha_rejoin_rescue "$(ha_peer_ip)"; then
                    _r3c_rescued=1
                else
                    # retry once: pg_rewind is re-runnable, and the first
                    # attempt may have died on a REAL rewind failure or a
                    # transient peer hiccup (the auto-rejoin does the same)
                    systemctl reset-failed "$HA_PG_SERVICE" >/dev/null 2>&1 || true
                    ha_repair_start_window_open
                    _r3c_out="$(repmgr_cmd node rejoin --force-rewind -h "$(ha_peer_ip)" -U "$HA_REPMGR_USER" -d "$HA_REPMGR_DB")"
                    _r3c_rc=$?
                    ha_repair_start_window_close
                    if [ "$_r3c_rc" -ne 0 ]; then
                        echo "$_r3c_out"
                        ha_rejoin_failure_forensics
                        if ha_rejoin_rescue "$(ha_peer_ip)"; then
                            _r3c_rescued=1
                        else
                            # 0.3.35: a rejoin that failed AFTER repmgr started
                            # the server leaves a ZOMBIE standby (the 27.10 14:0x
                            # boot: up on the new timeline, WAL receiver never
                            # attached, the metadata record still 'primary' ->
                            # repmgrd crash-loops and the startup process replays
                            # the node's OWN divergent WAL tail onto the rewound
                            # files). Attached = keep it streaming (the catchup is
                            # valuable; a re-run of --repair finishes the
                            # registration via the attached path); up but detached
                            # = STOP (the documented SAFE state - the boot guard
                            # admits the next repair's classification start).
                            if pg_runuser_psql -tAc "SELECT 1" >/dev/null 2>&1; then
                                if [ "$(pg_runuser_psql -tAc "SELECT sender_host FROM pg_stat_wal_receiver" | tr -d ' \r')" = "$(ha_peer_ip)" ]; then
                                    verbose "  the rejoin reported a failure twice, but the node IS up and"
                                    verbose "  streaming (catchup) - re-run --repair to finish the"
                                    verbose "  registration (the attached path does not interrupt it)"
                                else
                                    verbose "  PostgreSQL is up but NOT attached - stopping it (the safe"
                                    verbose "  state: a zombie standby replays its own divergent WAL onto"
                                    verbose "  the rewound files and repmgrd crash-loops on the stale record)"
                                    svc_stop "$HA_PG_SERVICE"
                                fi
                            fi
                            die "node rejoin failed twice (see the forensics above).
If the local PGDATA is damaged beyond rewind, re-run with: --repair --force-clone"
                        fi
                    fi
                fi
            fi
            if [ "$_r3c_rescued" = "1" ]; then
                # 0.3.36: the rescued rejoin never reached repmgr's own
                # registration - refresh the record (a metadata write on the
                # peer; the attached standby keeps streaming through it)
                _r3c_out="$(repmgr_cmd standby register --upstream-node-id="$(ha_peer_id)" --force)"
                if [ $? -ne 0 ]; then
                    echo "$_r3c_out"
                    die "'standby register' failed after the rescued start - the node IS streaming;
re-run the SAME command (the attached path finishes the registration)"
                fi
                verbose "  rejoin RESCUED: repmgr's inner start had failed - PostgreSQL was started"
                verbose "  by this repair, verified attached to $(ha_peer_name), the record refreshed"
            fi
            ha_pg_adopt_after_rejoin
            ha_scrub_conninfo_secrets   # 0.3.33: the peer's node record still
                                        # carries password= (registered by an
                                        # older version) - strip it everywhere
            verbose "  rejoined as a standby of $(ha_peer_name) (pg_rewind applied)"
        fi
    fi
}

rep_step_4_services() {
    # self-healing preamble: refresh pg_hba, listen_addresses, sudoers and
    # re-render repmgr.conf if the on-disk copy differs from the template
    ha_register_prelude standby
    ha_scrub_conninfo_secrets   # 0.3.33: strip password= from the metadata
                                # (covers the attached branch and re-runs;
                                # idempotent, heals both nodes' records)
    ha_render_repmgr_conf standby
    ha_install_promote_sh
    ha_install_agent
    ha_render_haproxy_conf
    haproxy -c -f "$HA_HAPROXY_MAIN" -f "$HA_HAPROXY_CONF_D" >/dev/null 2>&1 \
        || die "haproxy configuration is invalid"
    svc_enable_start "$HA_HAPROXY_SERVICE"
    ha_install_repmgr_dropin   # 0.3.16: installer-owned unit drop-in
    svc_enable_start "$HA_REPMGRD_SERVICE"
    ha_repoint_dsn
}

rep_step_5_seed_media() {
    join_step_9_seed_media
}

rep_step_6_lsyncd() {
    ha_render_lsyncd_conf "$(ha_peer_ip)"
    ha_install_lsyncd_dropin
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
    # self-healing preamble on the surviving primary (idempotent)
    ha_register_prelude primary
    ha_scrub_conninfo_secrets   # 0.3.33: the primary owns the writable copy
                                # of the metadata - strip password= here
    ha_render_repmgr_conf primary
    ha_install_promote_sh
    ha_install_agent
    ha_render_haproxy_conf
    haproxy -c -f "$HA_HAPROXY_MAIN" -f "$HA_HAPROXY_CONF_D" >/dev/null 2>&1 \
        || die "haproxy configuration is invalid"
    svc_enable_start "$HA_HAPROXY_SERVICE"
    ha_install_repmgr_dropin   # 0.3.16: installer-owned unit drop-in
    svc_enable_start "$HA_REPMGRD_SERVICE"
    # a rebuilt primary may have lost the media tree - lsyncd cannot watch
    # a missing dir (regression 0.3.11)
    ha_ensure_sync_dir
    ha_render_lsyncd_conf "$(ha_peer_ip)"
    ha_install_lsyncd_dropin
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
    if [ "$HA_NODE_ID" = "3" ]; then
        # 0.3.20: the witness metadata database never has streaming
        # standbys - the old output printed an empty "(0 rows)" table as
        # if something was missing
        verbose "  witness: no local replication (metadata only - the data nodes hold the stream)"
    else
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
                "SELECT '  upstream: '||COALESCE(sender_host,'?')||'  lag bytes: '||COALESCE(pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn()),0) FROM pg_stat_wal_receiver" \
                2>/dev/null | sed 's/^/  /'
            ;;
        *) warn "local PostgreSQL is not reachable" ;;
    esac
    fi

    verbose ""
    verbose "=== Entry point 127.0.0.1:$HA_HAPROXY_PORT ==="
    if [ "$HA_NODE_ID" = "3" ]; then
        # 0.3.20: the witness runs no haproxy by design - the old probe
        # printed "cannot query ... (haproxy down / no primary)" as if
        # the node was broken
        verbose "  witness runs no haproxy - use a data node address (node 1 / node 2)"
    else
    _st_probe="$(pg_psql_app 127.0.0.1 -p "$HA_HAPROXY_PORT" -tAc "SELECT pg_is_in_recovery()" 2>/dev/null | tr -d ' \r')"
    if [ "$_st_probe" = "f" ]; then
        verbose "  OK: connects and reaches the PRIMARY"
    elif [ "$_st_probe" = "t" ]; then
        warn "entry point reaches a STANDBY - haproxy health checks stale?"
    else
        warn "cannot query through 127.0.0.1:$HA_HAPROXY_PORT (haproxy down / no primary)"
    fi
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
        0) if [ "$HA_NODE_ID" = "3" ]; then
               # 0.3.20: the witness runs a standalone metadata database -
               # labelling it "(primary)" invited confusion with the data
               # node roles (the bench asked "why is my witness a primary?")
               _dr_ok "local PostgreSQL is up (witness metadata database)"
           else
               _dr_ok "local PostgreSQL is up (primary)"
           fi ;;
        1) _dr_ok "local PostgreSQL is up (standby)" ;;
        *) _dr_fail "local PostgreSQL is DOWN or unreachable" ;;
    esac

    if [ "$_dc_rc" != "2" ]; then
        # 2b. repmgrd shared memory preload (regression 0.3.15): without
        # shared_preload_libraries='repmgr' repmgrd dies at startup with
        # exit 1 and the reason ONLY in $HA_REPMGRD_LOG ('unable to write
        # to shared memory') - the journal carries nothing but the log
        # redirect notice. The setting is INSTALLER-owned: init step 5
        # writes it on the primary, the witness join writes it in step 4,
        # a standby inherits it from the clone. A node missing it was
        # installed by an older script version (or lost the line).
        # 0.3.16: the doctor is read-only diagnostics - it reports and
        # names the fix command, it never touches the configuration
        if ha_repmgr_preload_active; then
            _dr_ok "shared_preload_libraries includes repmgr (repmgrd-ready)"
        else
            case "$HA_NODE_ID" in
                1) _dc_pre_fix="fusionpbx-ha.sh --init --force (same --node2/--node3 as before)" ;;
                2) _dc_pre_fix="fusionpbx-ha.sh --repair --force-clone (re-clone inherits the setting)" ;;
                *) _dc_pre_fix="fusionpbx-ha.sh --repair (witness join step converges it)" ;;
            esac
            _dr_fail "repmgrd cannot run: shared_preload_libraries lacks 'repmgr'
       (dies instantly: 'unable to write to shared memory', reason only in $HA_REPMGRD_LOG)
       The installer always writes this setting - this node predates that
       installer version or lost the line. Fix on this node:
       $_dc_pre_fix
       (the doctor never modifies configurations)"
        fi

        # 3. frozen-sync detection (primary without a streaming standby but
        # with sync names configured = writes are STALLED)
        # 0.3.20: data nodes only - on the witness this check ran against
        # its LOCAL metadata database (a standalone primary that never has
        # streaming standbys) and printed a false "async mode - restore
        # the peer" alarm on a perfectly healthy cluster
        if [ "$HA_NODE_ID" = "3" ]; then
            _dr_ok "witness: replication state lives on the data nodes (no local standbys by design)"
        elif [ "$_dc_rc" = "0" ]; then
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

        # 4d. the metadata record vs the LOCAL role (0.3.35): the 27.10
        # return of a crashed primary - the auto-rejoin's rejoin failed
        # AFTER repmgr had started the server: PostgreSQL came up a
        # standby on the new timeline, but the record still said 'primary'
        # and repmgrd crash-looped ('node is registered as a primary but
        # running as a standby'). A targeted verdict beats the generic
        # 'service repmgr NOT active' journal tail. The local copy of the
        # metadata is queryable on a read-only standby, so the check works
        # in exactly the broken state it must describe.
        if [ "$HA_NODE_ID" != "3" ]; then
            _dcd_type="$(pg_runuser_psql -d "$HA_REPMGR_DB" -tAc \
                "SELECT type FROM repmgr.nodes WHERE node_id=$HA_NODE_ID" 2>/dev/null | tr -d ' \r')"
            if [ -n "$_dcd_type" ]; then
                if [ "$_dcd_type" = "primary" ] && [ "$_dc_rc" = "1" ]; then
                    _dr_fail "the metadata record says this node is PRIMARY but the local server runs as a STANDBY
      (the return of a crashed primary whose rejoin did not complete - repmgrd
      refuses to start: 'node is registered as a primary but running as a
      standby'). Fix: fusionpbx-ha.sh --repair  (it re-classifies, rejoins if
      diverged, refreshes the record and starts repmgrd)
      (the doctor never modifies configurations)"
                elif [ "$_dcd_type" = "standby" ] && [ "$_dc_rc" = "0" ]; then
                    _dr_warn "the metadata record says STANDBY but the local server is a PRIMARY (a failover window or a stale record) - if it persists: fusionpbx-ha.sh --repair"
                fi
            fi
        fi
    fi

    # 4b. failover quorum links (0.3.34): the 27.10 outage - the standby
    # detected the primary's death correctly, then its consensus probe to
    # the witness died "fe_sendauth: no password supplied" (0.3.33 had
    # removed the password from the metadata conninfo records and made the
    # postgres user's .pgpass the only password carrier - but the data-role
    # .pgpass never had a witness line) -> "unable to reach a qualified
    # majority of nodes" -> degraded monitoring instead of promotion: the
    # cluster stayed down for the whole primary outage. pg_isready alone
    # kept saying "witness is reachable" that day - TCP was up, only AUTH
    # was broken. The probe must authenticate exactly the way repmgrd does
    # during an election: psql as the repmgr user through the postgres
    # system user's .pgpass. Runs on every role (the witness's own repmgrd
    # connects to its own IP the same way, 0.3.2); a node that is merely
    # DOWN keeps its old semantics (the witness: a warning - RUNBOOK.md 4).
    _dcq_passfile="$(ha_pgpass_file)"
    for _dcq_id in 1 2 3; do
        _dcq_ip="$(ha_node_ip "$_dcq_id")"
        _dcq_name="$(ha_node_name "$_dcq_id")"
        _dcq_out="$(PGCONNECT_TIMEOUT=5 PGPASSFILE="$_dcq_passfile" psql -w \
            -h "$_dcq_ip" -p "$HA_PG_PORT" -U "$HA_REPMGR_USER" -d "$HA_REPMGR_DB" \
            -tAc "SELECT 1" 2>&1 | tr -d ' \r')"
        if [ "$_dcq_out" = "1" ]; then
            _dr_ok "quorum link to $_dcq_name ($_dcq_ip): authenticated as $HA_REPMGR_USER"
            continue
        fi
        if ha_pg_isready "$_dcq_ip"; then
            _dr_fail "quorum link to $_dcq_name ($_dcq_ip): server reachable but the $HA_REPMGR_USER login FAILED
      ($_dcq_out) - with this link broken an automatic failover CANNOT
      reach a qualified majority (the 27.10 outage shape: the witness
      rejected the login, the standby degraded instead of promoting).
      Fix: update the scripts (RUNBOOK.md 7), then 'fusionpbx-ha.sh
      --repair' on THIS node and on $_dcq_name"
        elif [ "$_dcq_id" = "3" ] && [ "$HA_NODE_ID" != "3" ]; then
            _dr_warn "witness $(ha_node_ip 3) unreachable${HA_PG_ISREADY_MSG:+ - $HA_PG_ISREADY_MSG} - automatic failover is DISABLED until it returns (RUNBOOK.md 4)"
        else
            _dr_fail "quorum link to $_dcq_name ($_dcq_ip) unreachable${HA_PG_ISREADY_MSG:+ - $HA_PG_ISREADY_MSG} - node down? (RUNBOOK.md 3/4)"
        fi
    done

    # 4c. .pgpass coverage, statically (0.3.34): the companion of 4b that
    # also works while the peer is down - a line lost to an older script
    # version or a manual edit is caught BEFORE it can break an election.
    # repmgr line for EVERY node (self included); on the data nodes also
    # the postgres lines for the peer pair (pg_rewind, sync-name mgmt).
    _dcp_file="$(ha_pgpass_file)"
    if [ ! -f "$_dcp_file" ]; then
        _dr_fail ".pgpass missing: $_dcp_file - repmgr cannot authenticate to ANY node
      Fix: 'fusionpbx-ha.sh --repair' on this node (the doctor never modifies configurations)"
    else
        _dcp_miss=""
        for _dcp_id in 1 2 3; do
            grep -q "^$(ha_node_ip "$_dcp_id"):$HA_PG_PORT:\*:$HA_REPMGR_USER:" "$_dcp_file" 2>/dev/null \
                || _dcp_miss="$_dcp_miss repmgr@$(ha_node_name "$_dcp_id")"
        done
        if [ "$HA_NODE_ID" != "3" ]; then
            for _dcp_id in 1 2; do
                grep -q "^$(ha_node_ip "$_dcp_id"):$HA_PG_PORT:\*:postgres:" "$_dcp_file" 2>/dev/null \
                    || _dcp_miss="$_dcp_miss postgres@$(ha_node_name "$_dcp_id")"
            done
        fi
        if [ -n "$_dcp_miss" ]; then
            _dr_fail ".pgpass lacks the line(s) for:$_dcp_miss
      (since 0.3.33 the .pgpass is the ONLY password carrier - a missing
      line breaks the failover quorum: the 27.10 outage). Fix:
      'fusionpbx-ha.sh --repair' on this node (the doctor never modifies configurations)"
        else
            _dr_ok ".pgpass covers every cluster node (quorum credentials complete)"
        fi
        # libpq silently IGNORES a .pgpass with a permissive mode - the
        # quorum probes above would fail with no visible reason (0.3.34)
        if cmd_exists stat; then
            [ "$(stat -c %a "$_dcp_file" 2>/dev/null)" = "600" ] \
                || _dr_warn ".pgpass mode is not 600 - libpq refuses to read it ('fusionpbx-ha.sh --repair' rewrites it)"
        fi
    fi

    # 4e. sudo for the postgres user (0.3.36, data nodes only): the 27.10
    # forensics - on BOTH data nodes every postgres->sudo call died at the
    # EXEC level ('runuser: невозможно выполнить sudo: Отказано в доступе'
    # = EACCES; the ALT 'control sudo' restriction or a mode drift on the
    # binary) while root kept working. That silently killed: the
    # auto-rejoin's inner service_start_command start (repmgr printed only
    # 'unable to start server'), ALL post-promote app restarts (13:57) and
    # the repair preflight. repmgr's design (the service_*_command paths,
    # the promote wrapper) NEEDS this elevation path. Runs even while
    # PostgreSQL is down - exactly the 27.10 shape.
    # Root only (the probe runs as postgres via runuser; a non-root doctor
    # cannot see the truth and must not guess) - HA_SANDBOX exempts the
    # test harness, where the runuser/sudo/id stubs play the roles.
    if [ "$HA_NODE_ID" != "3" ] && { [ "${HA_SANDBOX:-0}" = "1" ] || [ "$(id -u 2>/dev/null)" = "0" ]; }; then
        _dce_rc=0; ha_sudo_probe || _dce_rc=$?
        case "$_dce_rc" in
            0) _dr_ok "sudo works for the postgres user (repmgr service commands + the post-promote app restart)" ;;
            2) _dr_warn "sudo not installed / no postgres user yet - repmgr service commands stay dormant" ;;
            *) _dr_fail "sudo FAILS for the postgres user - every postgres->sudo path dies with the reason
      swallowed: the rejoin's inner 'systemctl start' (only 'unable to start
      server' is printed), ALL post-promote app restarts, the repair
      preflight (the 27.10 bench).
      Fix: 'fusionpbx-ha.sh --repair' on this node (it self-heals: ALT
      'control sudo public' / chmod 4755 on the sudo binary), or manually:
        control sudo public; chmod 4755 \$(command -v sudo)
      (the doctor never modifies configurations)" ;;
        esac
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

    # 6b. boot guard (0.3.27, data nodes only): files present = a hard-
    # crashed primary cannot boot as a competing primary. Reported
    # regardless of the local PG state: a BLOCKED boot is exactly the
    # state where this check must say so (the journal carries the verdict;
    # haproxy on this node keeps serving the applications from the peer).
    if [ "$HA_NODE_ID" != "3" ]; then
        if [ -f "${HA_SYSTEMD_DIR}/${HA_PG_SERVICE}.service.d/fusionpbx-ha.conf" ] \
            && [ -x "${HA_LIB_DIR}/pg-boot-guard.sh" ] \
            && [ -f "${HA_ETC_DIR}/boot-guard.conf" ]; then
            # 0.3.29: the automatic rejoin unit must be enabled too -
            # otherwise a crashed primary stays down until a human notices
            if [ -x "${HA_LIB_DIR}/pg-auto-rejoin.sh" ] \
                && svc_is_enabled "$HA_AUTO_REJOIN_UNIT"; then
                _dr_ok "PostgreSQL boot guard installed + automatic rejoin enabled (a crashed primary returns unattended)"
            else
                _dr_warn "boot guard installed but the AUTOMATIC REJOIN is not enabled - a crashed primary stays down until a manual --repair (re-run this node's install command)"
            fi
            # 0.3.35: repmgrd must be able to ELEVATE - a stock-unit
            # NoNewPrivileges=yes (the 27.10 13:57 promote: every sudo from
            # the daemon died instantly and silently, the promoted node's
            # apps hung on dead-peer sockets) breaks the post-promote app
            # restart and every service_*_command. The drop-in sets 'no';
            # this verifies the MERGED property.
            _dc_nnp="$(systemctl show "$HA_REPMGRD_SERVICE" -p NoNewPrivileges --value 2>/dev/null | tr -d ' \r')"
            if [ "$_dc_nnp" = "yes" ]; then
                _dr_warn "repmgr.service resolves NoNewPrivileges=yes - sudo from repmgrd cannot elevate: the post-promote app restart dies silently (apps hang ~15-30 min after a failover). Re-run this node's install command (the drop-in fixes it)"
            fi
        else
            _dr_warn "PostgreSQL boot guard NOT installed - a hard-crashed primary will boot as a competing primary (re-run this node's install command)"
        fi
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
            # 0.3.16: read-only diagnostics - no start attempt, no
            # reset-failed, no config convergence, no drop-in installs:
            # configurations belong to the installer/repair flows. The
            # reason must be visible in the SAME run: journal tail inline,
            # and for repmgrd ALSO the log_file tail - after the
            # 'redirecting logging output' notice everything repmgrd says
            # goes to $HA_REPMGRD_LOG, the journal stays silent (0.3.15)
            # 0.3.21: for repmgrd the consequence must be unmistakable -
            # the bench sat through a primary outage with repmgrd stopped
            # (nobody promoted the standby, total outage)
            if [ "$_dc_svc" = "$HA_REPMGRD_SERVICE" ]; then
                _dr_fail "service repmgr NOT active: AUTOMATIC FAILOVER WILL NOT HAPPEN - journal tail:"
            else
                _dr_fail "service $_dc_svc NOT active - journal tail:"
            fi
            journalctl -u "$_dc_svc" -n 15 --no-pager 2>/dev/null | sed 's/^/       /' || true
            if [ "$_dc_svc" = "$HA_REPMGRD_SERVICE" ] && [ -s "$HA_REPMGRD_LOG" ]; then
                error "       repmgrd log tail ($HA_REPMGRD_LOG):"
                tail -n 15 "$HA_REPMGRD_LOG" 2>/dev/null | sed 's/^/       /' || true
            fi
        fi
    done

    # 8. lsyncd (data nodes): service + log errors
    if [ "$HA_NODE_ID" != "3" ]; then
        if svc_active "$HA_LSYNCD_SERVICE" 2>/dev/null; then
            # 0.3.15: only the CURRENT instance counts - errors before the
            # last '--- Startup ---' marker belong to a dead instance (the
            # 0.3.14 self-heal restarts lsyncd, and tail -100 kept stale
            # boot-race errors amber forever: bench ssh Permission denied
            # at 12:49:48, clean ever since)
            if [ -f "$HA_LSYNCD_LOG" ] && tail -n 100 "$HA_LSYNCD_LOG" 2>/dev/null \
                    | awk '/Startup/{buf=""} {buf=buf $0 "\n"} END{printf "%s", buf}' \
                    | grep -qi 'error\|fail'; then
                _dr_warn "lsyncd log contains errors from the running instance: $HA_LSYNCD_LOG"
            else
                _dr_ok "lsyncd log clean (current instance)"
            fi
            [ -f "$HA_SYNC_DIR" ] || [ -d "$HA_SYNC_DIR" ] || _dr_fail "sync dir missing: $HA_SYNC_DIR"
        fi

        # 8b. lsyncd config conformance (data nodes): a config rendered by
        # an OLDER script version can be silently wrong for the current
        # template (0.3.12: the pre-0.3.12 absolute target mirrored the
        # tree into a NESTED dir on the peer). 0.3.16: read-only - report
        # the drift and the fix command; the config belongs to the
        # installer/repair flows, the doctor never modifies it
        if [ -f "$HA_LSYNCD_CONF" ]; then
            _dc_lsyn_new="$HA_ETC_DIR/.lsyncd.conf.doctor"
            ha_render "$HA_RES_DIR/lsyncd.conf.lua.tpl" "$_dc_lsyn_new" \
                "SYNC_DIR=$HA_SYNC_DIR" "SYNC_DELAY=$HA_SYNC_DELAY" "PEER_IP=$(ha_peer_ip)"
            if cmp -s "$_dc_lsyn_new" "$HA_LSYNCD_CONF"; then
                _dr_ok "lsyncd config matches the current template"
            else
                _dr_fail "lsyncd config DIFFERS from the current template
       (an older script version may mirror the media tree into a wrong place
       on the peer - the 0.3.12 class). Re-render it on this node:
       fusionpbx-ha.sh --repair
       (the doctor never modifies configurations)"
            fi
            rm -f "$_dc_lsyn_new"
        fi

        # 8c. authorized_keys conformance (data nodes): the sync-key line is
        # written by the INSTALLER (join steps 2-3 / init steps 12-14). A
        # line left by an older script version, an interrupted write or a
        # pre-rrsync write makes the peer's sshd reject the rsync/lsyncd
        # pushes outright ('invalid key option string' in its sshd log).
        # 0.3.16: read-only verification - the expected line is rebuilt
        # the same way the writer builds it, and stray duplicate lines with
        # the same key blob are counted; nothing is ever written. Root
        # only - a doctor run by a mere mortal cannot read /root/.ssh.
        if [ -n "${HA_SYNC_PUBLIC_KEY:-}" ] && [ "$(id -u)" = "0" ]; then
            _dc_ak_file="${HA_SYNC_SSH_DIR:-/root/.ssh}/authorized_keys"
            _dc_ak_rrsync="${HA_RRSYNC_INSTALL_DIR:-/usr/local/bin}/rrsync"
            [ -x "$_dc_ak_rrsync" ] || { cmd_exists rrsync && _dc_ak_rrsync="$(command -v rrsync)"; }
            if [ ! -x "$_dc_ak_rrsync" ]; then
                _dr_warn "authorized_keys: cannot verify - rrsync not found (the installer copies it)"
            elif [ ! -f "$_dc_ak_file" ]; then
                _dr_fail "authorized_keys missing: $_dc_ak_file - the peer's pushes are rejected preauth"
            else
                _dc_ak_blob="$(printf '%s' "$HA_SYNC_PUBLIC_KEY" | awk '{print $2}')"
                _dc_ak_expect="from=\"$(ha_node_ip 1),$(ha_node_ip 2)\",command=\"$_dc_ak_rrsync $HA_SYNC_DIR\",no-pty,no-agent-forwarding,no-X11-forwarding,no-port-forwarding $HA_SYNC_PUBLIC_KEY"
                _dc_ak_n="$(grep -cF -- "$_dc_ak_blob" "$_dc_ak_file" 2>/dev/null || true)"
                if grep -qF -- "$_dc_ak_expect" "$_dc_ak_file" 2>/dev/null \
                        && [ "${_dc_ak_n:-0}" = "1" ]; then
                    _dr_ok "authorized_keys: sync-key line matches the current pattern"
                elif [ "${_dc_ak_n:-0}" -gt 1 ] 2>/dev/null; then
                    _dr_fail "authorized_keys: $_dc_ak_n copies of the sync key (stray stale lines)
       sshd may refuse the file line outright ('invalid key option string') and
       the peer's pushes die preauth. Re-run this node's join command:
       rm $HA_MARKER_FILE && fusionpbx-ha.sh --join TOKEN
       (the doctor never modifies configurations)"
                else
                    _dr_fail "authorized_keys: sync-key line missing or stale - the peer's pushes
       are rejected preauth. Re-run this node's join command:
       rm $HA_MARKER_FILE && fusionpbx-ha.sh --join TOKEN
       (the doctor never modifies configurations)"
                fi
            fi
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

        # 8d. hung rrsync instance (0.3.23): upstream rsync 3.2.7's rrsync
        # takes an EXCLUSIVE NON-BLOCKING flock on the sync directory itself
        # - every media transfer to/from this node (the peer's lsyncd
        # pushes, a repairing node's seed pull) dies 'Another instance of
        # rrsync is already accessing this directory' while any other LIVE
        # instance holds it, and a HUNG leftover of an interrupted sync
        # session (crashes/reboots mid-transfer) holds the lock until its
        # process dies. Transfers are seconds-lived; one older than 10
        # minutes and idle is almost certainly hung.
        _dc_rrsync_old="$(ps -eo etimes,args 2>/dev/null | awk -v d="$HA_SYNC_DIR" \
            '$0 ~ /[r]rsync/ && index($0, d) > 0 && $1 > 600 {print $1; exit}')"
        if [ -n "$_dc_rrsync_old" ]; then
            _dr_warn "an rrsync instance has been alive for ${_dc_rrsync_old}s (normally seconds)
       if no large media transfer is running right now, it is hung: every
       media sync to/from this node fails with 'Another instance of rrsync'
       until it is killed (the flock dies with the process)"
        else
            _dr_ok "no hung rrsync instance (media sync lock free)"
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

    # 10. witness reachability - REMOVED in 0.3.34: a TCP-only probe kept
    # saying "witness is reachable" while the repmgr login was broken (the
    # 27.10 outage) - check 4b authenticates as the repmgr user and says
    # both the truth and the fix command

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

    # More cross-step state for the step subshells (DESIGN.md 7):
    # (a) step 2 bakes the layer-1 database credentials into cluster.conf,
    #     and a subshell cannot hand them back - read config.conf HERE
    #     (step 1 re-validates layer 1 and reports inside its own banner)
    ha_read_layer1_conf || true
    # (b) a previous --init may have already written cluster.conf (resume):
    #     load it BEFORE the sequence so step 1 uses the authoritative
    #     values instead of the built-in defaults. Without --force the node
    #     set can no longer change - the token was already handed out
    if [ -f "$HA_CLUSTER_CONF" ]; then
        ha_load_cluster_conf
        if [ "${HA_FORCE:-0}" != "1" ]; then
            if [ "$HA_INIT_NODE2_IP" != "$HA_NODE2_IP" ] || [ "$HA_INIT_NODE3_IP" != "$HA_NODE3_IP" ]; then
                warn "--node2/--node3 differ from the existing cluster.conf - the cluster.conf values win"
                warn "  node2: $HA_NODE2_IP   witness: $HA_NODE3_IP (the token was issued for these)"
            fi
            HA_INIT_NODE2_IP="$HA_NODE2_IP"
            HA_INIT_NODE3_IP="$HA_NODE3_IP"
        fi
    fi

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
        init_step_11_witness_status \
        init_step_12_standby_status \
        init_step_13_sync_on \
        init_step_14_sync_setup \
        init_step_15_finalize
    verbose ""
    # 0.3.39: with no peer waits the command can complete while the peers
    # are not joined yet - say which of the two endings this was
    if init_poll_standby_streaming && init_poll_witness_registered; then
        verbose "=== Cluster initialization completed successfully ==="
    else
        verbose "=== Node bootstrap completed - join the peers next (see the summary above) ==="
    fi
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

    # Interactive picker cross-check: the human's role answer (if any) is
    # verified against the authoritative IP match from the token - a wrong
    # answer dies HERE with a clear reason instead of confusing failures
    # somewhere deep in the join flow.
    if [ -n "${HA_PICK_ROLE:-}" ]; then
        if [ "$HA_PICK_ROLE" = "witness" ] && [ "$HA_NODE_ID" != "3" ]; then
            die "the token identifies this host as a DATA node (node $HA_NODE_ID), not the witness - check the token or the role answer"
        fi
        if [ "$HA_PICK_ROLE" = "data" ] && [ "$HA_NODE_ID" = "3" ]; then
            die "the token identifies this host as the WITNESS (node 3), not a data node - check the token or the role answer"
        fi
    fi
    HA_CLUSTER_CONF="$HA_ETC_DIR/cluster.conf"   # from here on: the real path
    HA_JOIN_ROLE="standby"
    [ "$HA_NODE_ID" = "3" ] && HA_JOIN_ROLE="witness"
    ha_apply_proxy

    # Regression 0.3.18: a join state file is only valid for the SAME
    # cluster secrets. '--init --force' on the primary regenerates them,
    # and resuming against the OLD cluster.conf (step 2 unpack skipped)
    # sent the bench to the media seed with the OLD sync private key ->
    # 'Permission denied (publickey)'. The token IS the identity: a
    # mismatched state file is discarded and the join re-runs from step 1.
    ha_join_state_freshen "$HA_JOIN_TMP_CONF"

    # Resume convergence (0.3.13): a join-standby state file means an
    # earlier attempt ran - possibly with an older script whose sync-key
    # line sshd now refuses to parse ('invalid key option string' in the
    # peer's sshd log - its pushes die preauth), or written before step 3
    # installed rrsync (no forced command at all). Step 2 is skipped on
    # resume, so converge the line HERE (idempotent: managed block +
    # stray-line purge inside ha_write_authorized_keys).
    if [ "$HA_NODE_ID" != "3" ] && [ -f "$HA_STATE_FILE" ] \
        && grep -q '^command=join-standby$' "$HA_STATE_FILE" 2>/dev/null; then
        ha_write_authorized_keys
    fi

    # 0.3.22: unit drop-ins are installer-owned but live OUTSIDE the
    # resumable step sequence - a join resumed past its service step
    # (state file written by an older script) would keep the PREVIOUS
    # drop-in content forever (the bench: a standby that never received
    # Restart=always sat through a primary outage with repmgrd dead after
    # a boot race). Converge them here on every join run - both installers
    # are content-aware and idempotent; a daemon-reload never starts or
    # stops anything.
    ha_install_repmgr_dropin
    [ "$HA_NODE_ID" != "3" ] && ha_install_lsyncd_dropin

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
    # a rebuilt node may have re-run layer 1: its iptables.sh FLUSHES all
    # rules and re-applies the whitelist WITHOUT the cluster ports
    # (regression 0.3.6)
    ha_ensure_cluster_firewall

    # 0.3.22: same convergence as cmd_join - a repair RESUMED past its
    # service step (steps 4/6 done by an older script) must not leave a
    # stale unit drop-in behind: the failover daemon's Restart=always is
    # exactly what a boot-race kill relies on to come back.
    ha_install_repmgr_dropin
    [ "$HA_NODE_ID" != "3" ] && ha_install_lsyncd_dropin

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

