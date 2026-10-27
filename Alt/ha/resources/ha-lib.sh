#!/bin/sh

# fusionpbx-ha.sh - shared function library (sourced by fusionpbx-ha.sh)
#
# Design: Alt/ha/DESIGN.md (v0.2+). Patterns are carried over one-to-one
# from the layer-1 installer (Alt/resources/{colors,util,guard}.sh):
#   - fault-tolerant checks (a check that cannot run = "no signal")
#   - step state file + completion marker (resume / installed protection)
#   - idempotent steps (existing state is not an error)
#
# This file is also sourced by the test suite (tests/*.sh) with
# HA_SANDBOX=1 and overridden paths - keep it free of side effects:
# only function definitions and overridable variable defaults.

# =============================================================================
# Paths and constants (environment-overridable for tests)
# =============================================================================

HA_ETC_DIR="${HA_ETC_DIR:-/etc/fusionpbx-ha}"
HA_CLUSTER_CONF="$HA_ETC_DIR/cluster.conf"
HA_MARKER_FILE="$HA_ETC_DIR/.installed"
HA_STATE_FILE="$HA_ETC_DIR/.installer-state"
HA_SYNC_KEY="$HA_ETC_DIR/sync_key"
HA_KNOWN_HOSTS="$HA_ETC_DIR/known_hosts"
HA_CONF_DIR_MODE="${HA_CONF_DIR_MODE:-700}"

HA_LIB_DIR="${HA_LIB_DIR:-/usr/lib/fusionpbx-ha}"
HA_AGENT_SCRIPT="$HA_LIB_DIR/role-agent.py"
HA_PROMOTE_SH="$HA_LIB_DIR/promote.sh"
HA_AGENT_UNIT_NAME="fusionpbx-ha-agent"
# overridable for the test sandbox (the HA_SUDOERS_DIR pattern)
HA_SYSTEMD_DIR="${HA_SYSTEMD_DIR:-/etc/systemd/system}"
# how long ha_install_agent waits for the agent socket after enable+start
HA_AGENT_WAIT="${HA_AGENT_WAIT:-30}"

HA_REPMGR_CONF="${HA_REPMGR_CONF:-/etc/repmgr/repmgr.conf}"
# repmgrd's own log target (log_file in repmgr.conf; the reason for any
# daemon death lands HERE, never in the journal - 0.3.15)
HA_REPMGRD_LOG="${HA_REPMGRD_LOG:-/var/log/repmgr/repmgrd.log}"
HA_HAPROXY_CONF_D="${HA_HAPROXY_CONF_D:-/etc/haproxy/conf.d}"
HA_HAPROXY_CONF="$HA_HAPROXY_CONF_D/fusionpbx-ha.cfg"
HA_HAPROXY_MAIN="${HA_HAPROXY_MAIN:-/etc/haproxy/haproxy.cfg}"
HA_LSYNCD_CONF="${HA_LSYNCD_CONF:-/etc/lsyncd/lsyncd.conf.lua}"
HA_LSYNCD_LOG="${HA_LSYNCD_LOG:-/var/log/lsyncd/lsyncd.log}"

HA_L1_CONF="${HA_L1_CONF:-/etc/fusionpbx/config.conf}"
HA_L1_WEB_CONF="${HA_L1_WEB_CONF:-/var/www/fusionpbx/resources/config.conf}"
HA_VARS_XML="${HA_VARS_XML:-/etc/freeswitch/vars.xml}"

HA_PGDATA_DEFAULT="${HA_PGDATA_DEFAULT:-/var/lib/pgsql/data}"
HA_PG_SERVICE="${HA_PG_SERVICE:-postgresql}"
HA_REPMGRD_SERVICE="${HA_REPMGRD_SERVICE:-repmgr}"
HA_HAPROXY_SERVICE="${HA_HAPROXY_SERVICE:-haproxy}"
HA_LSYNCD_SERVICE="${HA_LSYNCD_SERVICE:-lsyncd}"
# 0.3.29: the boot-time automatic rejoin unit (see pg-auto-rejoin.sh)
HA_AUTO_REJOIN_UNIT="${HA_AUTO_REJOIN_UNIT:-fusionpbx-ha-auto-rejoin}"

# Cluster value defaults: they carry the FIRST steps of a fresh --init, which
# run BEFORE cluster.conf exists (it is generated in step 2). cluster.conf
# holds the authoritative values - sourcing it overrides these - so they MUST
# mirror ha_generate_cluster_conf exactly (see also the unset-then-source in
# ha_load_cluster_conf, which keeps validation honest).
HA_PG_PORT="${HA_PG_PORT:-5432}"
HA_HAPROXY_PORT="${HA_HAPROXY_PORT:-5433}"
HA_AGENT_PORT="${HA_AGENT_PORT:-8008}"

# /etc/hosts receives a managed block with the cluster node names
# (HA_HOSTS_FILE is overridable so the test suite never touches /etc)
HA_HOSTS_FILE="${HA_HOSTS_FILE:-/etc/hosts}"

# where layer 1 persists the iptables rules (iptables.service loads this
# file on boot); HA_IPTABLES_CONF is overridable for the test sandbox
HA_IPTABLES_CONF="${HA_IPTABLES_CONF:-/etc/sysconfig/iptables}"

# managed-block markers (see ha_block_* below)
HA_BLOCK_BEGIN="# BEGIN fusionpbx-ha (managed)"
HA_BLOCK_END="# END fusionpbx-ha (managed)"

# HA_SANDBOX=1 skips the root and ALT-Linux checks (tests only)
# HA_AUTO_YES=1 answers all confirmations with yes (set by --yes)
# HA_FORCE=1 ignores the step state file (set by --force)
#
# HA_RES_DIR: this script's resources/ directory (templates). Derived from
# the calling script location; tests override it explicitly.
HA_RES_DIR="${HA_RES_DIR:-$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)/resources}"
HA_LAYER1_PROXY_SH="${HA_LAYER1_PROXY_SH:-$HA_RES_DIR/../resources/proxy.sh}"

# =============================================================================
# Output helpers (pattern: layer-1 colors.sh; --no-color supported)
# =============================================================================

normal=""
red=""
green=""
yellow=""
if [ -t 1 ] && [ "${HA_NO_COLOR:-0}" != "1" ]; then
    if [ -n "$(tput colors 2>/dev/null)" ] && [ "$(tput colors 2>/dev/null)" -ge 8 ] 2>/dev/null; then
        normal="$(tput sgr0)"
        red="$(tput setaf 1)"
        green="$(tput setaf 2)"
        yellow="$(tput setaf 3)"
    fi
fi

verbose() { echo "${green}$1${normal}"; }
info()    { echo "$1"; }
warn()    { echo "${yellow}WARNING: $1${normal}" >&2; }
error()   { echo "${red}ERROR: $1${normal}" >&2; }

die() {
    error ""
    error "FATAL: $1"
    error ""
    exit 1
}

cmd_exists() { command -v "$1" >/dev/null 2>&1; }

# Confirm an action; HA_AUTO_YES (--yes) bypasses.
# Usage: confirm "question" [y]  (optional default answer for a bare Enter;
# with NO default a bare Enter declines - every call site is a
# destructive-action prompt, so declining is the safe side. The argument
# must stay optional: an unguarded $2 aborts under set -u, which is exactly
# what happened on the real bench at join step 4 - regression 0.3.8)
confirm() {
    if [ "${HA_AUTO_YES:-0}" = "1" ]; then
        verbose "$1 - assumed YES (--yes)"
        return 0
    fi
    _cf_default="${2:-}"
    printf '%s' "$1 "
    read -r _cf_answer
    case "$_cf_answer" in
        [Yy]|[Yy][Ee][Ss]) return 0 ;;
        "") [ "$_cf_default" = "y" ] && return 0; return 1 ;;
        *) return 1 ;;
    esac
}

# =============================================================================
# Systemd wrappers (tolerant, layer-1 util.sh pattern)
# =============================================================================

svc_active() { systemctl is-active --quiet "$1" 2>/dev/null; }
svc_is_enabled() { systemctl is-enabled --quiet "$1" 2>/dev/null; }

svc_enable_start() {
    _ses_svc="$1"
    systemctl enable "$_ses_svc" >/dev/null 2>&1 || warn "could not enable service: $_ses_svc (may already be enabled)"
    systemctl restart "$_ses_svc" 2>/dev/null || die "failed to start service: $_ses_svc (check: journalctl -u $_ses_svc -n 50)"
    verbose "  service enabled and started: $_ses_svc"
}

svc_stop() {
    _ss_svc="$1"
    if svc_active "$_ss_svc"; then
        systemctl stop "$_ss_svc" || die "failed to stop service: $_ss_svc"
        verbose "  service stopped: $_ss_svc"
    else
        verbose "  service already stopped: $_ss_svc"
    fi
}

# 0.3.13: on the bench repmgrd was dead after a node reboot while
# postgresql was up - a tiny drop-in serializes the start order (turned out
# to be a no-op: the ALT unit already has After=postgresql.service - the
# REAL bench killer was the missing shared_preload_libraries, 0.3.15 - but
# an explicit ordering costs nothing).
# 0.3.15: (a) content-aware write - the old early-return on file-existence
# kept the 0.3.13 copy forever; (b) Environment=REPMGRD_OPTS= defines the
# variable the ALT ExecStart references (${REPMGRD_OPTS}), silencing the
# "Referenced but unset environment variable" warning on every start.
# 0.3.16: installer-owned - called before EVERY repmgrd enable+start
# (init step 7, join step 6, witness step 7, both --repair branches);
# the doctor no longer installs anything.
ha_install_repmgr_dropin() {
    _hrd_unit_dir="${HA_SYSTEMD_DIR}/${HA_REPMGRD_SERVICE}.service.d"
    _hrd_conf="$_hrd_unit_dir/fusionpbx-ha.conf"
    _hrd_tmp="$(mktemp "${TMPDIR:-/tmp}/fpbx-ha-dropin.XXXXXX")"
    cat > "$_hrd_tmp" <<DROPIN
# fusionpbx-ha: repmgrd unit hardening (ordering 0.3.13, env 0.3.15,
# auto-restart 0.3.21: repmgrd is THE failover daemon - the bench sat
# through a primary outage with repmgrd stopped on the standby: nobody
# promoted it, total outage; a dead daemon must never stay dead)
[Unit]
After=$HA_PG_SERVICE.service
Wants=$HA_PG_SERVICE.service
StartLimitIntervalSec=0

[Service]
# the ALT unit references \${REPMGRD_OPTS} in ExecStart but
# /etc/sysconfig/repmgr ships the variable commented out - defining it as
# empty keeps the command line identical and the warning gone
Environment=REPMGRD_OPTS=
# 0.3.21: repmgrd exits if the local database is not reachable within
# reconnect_attempts*reconnect_interval (a boot race with a slow standby
# replay is enough) - bring it back until PostgreSQL answers. An explicit
# 'systemctl stop' (installer/repair flows) is still honored: Restart
# never overrides deliberate stops
Restart=always
RestartSec=10
DROPIN
    if ! mkdir -p "$_hrd_unit_dir" 2>/dev/null; then
        rm -f "$_hrd_tmp"
        warn "cannot create $_hrd_unit_dir - repmgrd keeps its stock unit"
        return 1
    fi
    if [ -f "$_hrd_conf" ] && cmp -s "$_hrd_tmp" "$_hrd_conf"; then
        rm -f "$_hrd_tmp"
        return 0
    fi
    install -m 644 "$_hrd_tmp" "$_hrd_conf" 2>/dev/null || {
        rm -f "$_hrd_tmp"
        warn "cannot write $_hrd_conf - repmgrd keeps its previous drop-in"
        return 1
    }
    rm -f "$_hrd_tmp"
    systemctl daemon-reload 2>/dev/null || true
    verbose "  repmgrd unit drop-in installed: $_hrd_conf (ordering + REPMGRD_OPTS + auto-restart)"
    return 0
}

# 0.3.21: lsyncd gets the same treatment - a silently dead lsyncd means
# quiet media divergence between the nodes. Restart=on-failure (lsyncd
# exits non-zero on failure) + no start-rate limit, so a dead daemon is
# always brought back. Deliberate 'systemctl stop' (repair flows) is
# still honored.
ha_install_lsyncd_dropin() {
    _hld_unit_dir="${HA_SYSTEMD_DIR}/${HA_LSYNCD_SERVICE}.service.d"
    _hld_conf="$_hld_unit_dir/fusionpbx-ha.conf"
    _hld_tmp="$(mktemp "${TMPDIR:-/tmp}/fpbx-ha-dropin.XXXXXX")"
    cat > "$_hld_tmp" <<DROPIN
# fusionpbx-ha: lsyncd unit hardening (auto-restart 0.3.21 - a silently
# dead lsyncd means quiet media divergence between the data nodes)
[Unit]
StartLimitIntervalSec=0

[Service]
Restart=on-failure
RestartSec=10
DROPIN
    if ! mkdir -p "$_hld_unit_dir" 2>/dev/null; then
        rm -f "$_hld_tmp"
        warn "cannot create $_hld_unit_dir - lsyncd keeps its stock unit"
        return 1
    fi
    if [ -f "$_hld_conf" ] && cmp -s "$_hld_tmp" "$_hld_conf"; then
        rm -f "$_hld_tmp"
        return 0
    fi
    install -m 644 "$_hld_tmp" "$_hld_conf" 2>/dev/null || {
        rm -f "$_hld_tmp"
        warn "cannot write $_hld_conf - lsyncd keeps its previous drop-in"
        return 1
    }
    rm -f "$_hld_tmp"
    systemctl daemon-reload 2>/dev/null || true
    verbose "  lsyncd unit drop-in installed: $_hld_conf (auto-restart)"
    return 0
}

# =============================================================================
# Packages (APT-RPM, layer-1 util.sh pattern)
# =============================================================================

pkg_is_installed() {
    rpm -q "$1" >/dev/null 2>&1 && return 0
    rpm -q --whatprovides "$1" >/dev/null 2>&1
}

pkg_install_required() {
    _pir_list=""
    for _pir_pkg in "$@"; do
        if pkg_is_installed "$_pir_pkg"; then
            verbose "  package already installed: $_pir_pkg"
        else
            _pir_list="$_pir_list $_pir_pkg"
        fi
    done
    [ -z "$_pir_list" ] && return 0
    verbose "  installing packages:$_pir_list"
    apt-get update >/dev/null 2>&1 || die "apt-get update failed - check repositories/proxy (see --proxy)"
    # shellcheck disable=SC2086
    apt-get install -y $_pir_list || die "failed to install packages:$_pir_list"
}

# =============================================================================
# Small utilities
# =============================================================================

# random alphanumeric string, length $1 (default 24); charset [A-Za-z0-9]
random_password() {
    _rp_len="${1:-24}"
    _rp_out=""
    while [ "${#_rp_out}" -lt "$_rp_len" ]; do
        _rp_out="$(cat /dev/urandom 2>/dev/null | head -c 64 | base64 2>/dev/null | tr -d '\n' | tr -d '=+/' | tr -cd 'A-Za-z0-9')$_rp_out"
    done
    echo "$_rp_out" | cut -c "1-$_rp_len"
}

valid_ip() {
    echo "$1" | grep -Eq '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$' || return 1
    for _vi_oct in $(echo "$1" | tr '.' ' '); do
        [ "$_vi_oct" -le 255 ] 2>/dev/null || return 1
    done
}

# all local IPv4 addresses (loopback excluded), one per line
own_ips() {
    ip -o -4 addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -v '^127\.' \
        || hostname -I 2>/dev/null | tr ' ' '\n' | grep -v '^$' | grep -v '^127\.'
}

# =============================================================================
# cluster.conf: generation, loading, validation, accessors
# =============================================================================

# HA_CLUSTER_NAME, HA_INIT_NODE2_IP/HA_INIT_NODE3_IP come from --init args.
ha_generate_cluster_conf() {
    _hgc_repmgr_pw="$(random_password 24)"

    if ! ssh-keygen -t ed25519 -f "$HA_SYNC_KEY" -N '' -C 'fusionpbx-ha-sync' -q 2>/dev/null; then
        if [ ! -f "$HA_SYNC_KEY" ]; then
            die "ssh-keygen failed (openssh-server missing?) - cannot generate the sync key pair"
        fi
        warn "sync key pair already exists at $HA_SYNC_KEY - reusing it"
    fi
    _hgc_pub="$(cat "${HA_SYNC_KEY}.pub" 2>/dev/null || echo '')"
    [ -n "$_hgc_pub" ] || die "cannot read ${HA_SYNC_KEY}.pub"
    _hgc_priv_b64="$(gzip -c "$HA_SYNC_KEY" | base64 -w0 2>/dev/null | tr -d '\n')"
    [ -n "$_hgc_priv_b64" ] || die "cannot pack the sync private key (gzip/base64)"

    mkdir -p "$HA_ETC_DIR"
    chmod "$HA_CONF_DIR_MODE" "$HA_ETC_DIR"

    cat > "$HA_CLUSTER_CONF" <<EOF
# /etc/fusionpbx-ha/cluster.conf - generated by fusionpbx-ha.sh --init
# Managed file: local edits are overwritten by --init --force.
# Shell-sourceable INI; passwords use [A-Za-z0-9] only (no quoting needed).
HA_CLUSTER_NAME="$HA_CLUSTER_NAME"
HA_NODE1_NAME="fpbx-ha-1"; HA_NODE1_IP="$HA_INIT_NODE1_IP"; HA_NODE1_ROLE="primary"
HA_NODE2_NAME="fpbx-ha-2"; HA_NODE2_IP="$HA_INIT_NODE2_IP"; HA_NODE2_ROLE="standby"
HA_NODE3_NAME="fpbx-witness"; HA_NODE3_IP="$HA_INIT_NODE3_IP"; HA_NODE3_ROLE="witness"

HA_PG_VERSION="$HA_PG_VERSION"
HA_PG_PORT="5432"
HA_DB_NAME="$HA_L1_DB_NAME"
HA_DB_USER="$HA_L1_DB_USER"
HA_DB_PASSWORD="$HA_L1_DB_PASSWORD"
HA_REPMGR_USER="repmgr"
HA_REPMGR_PASSWORD="$_hgc_repmgr_pw"
HA_REPMGR_DB="repmgr"
HA_HAPROXY_PORT="5433"
HA_AGENT_PORT="8008"
HA_SYNC_DIR="/var/lib/freeswitch/storage"
HA_SYNC_DELAY="5"
HA_SYNC_PRIVATE_KEY_B64="$_hgc_priv_b64"
HA_SYNC_PUBLIC_KEY="$_hgc_pub"
EOF
    chmod 600 "$HA_CLUSTER_CONF"
    verbose "  cluster configuration written: $HA_CLUSTER_CONF"
}

# Load + validate cluster.conf. Dies on structural problems.
ha_load_cluster_conf() {
    [ -f "$HA_CLUSTER_CONF" ] || die "cluster configuration not found: $HA_CLUSTER_CONF
This node is not part of an HA cluster yet.
  - first node (VM1):  fusionpbx-ha.sh --init --node2 IP --node3 IP
  - other nodes:       fusionpbx-ha.sh --join TOKEN
  - status/diagnosis require an initialized node"

    # Validation must see ONLY what cluster.conf itself provides: a truncated
    # file has to fail even when an inherited default (the port constants
    # above) or a stale value from a previously sourced conf would mask the
    # hole - so drop every variable the file is expected to set, then source.
    unset HA_CLUSTER_NAME HA_PG_VERSION HA_PG_PORT HA_DB_NAME HA_DB_USER \
          HA_DB_PASSWORD HA_REPMGR_USER HA_REPMGR_PASSWORD HA_REPMGR_DB \
          HA_HAPROXY_PORT HA_AGENT_PORT HA_SYNC_DIR HA_SYNC_DELAY \
          HA_SYNC_PRIVATE_KEY_B64 HA_SYNC_PUBLIC_KEY \
          HA_NODE1_NAME HA_NODE1_IP HA_NODE1_ROLE \
          HA_NODE2_NAME HA_NODE2_IP HA_NODE2_ROLE \
          HA_NODE3_NAME HA_NODE3_IP HA_NODE3_ROLE

    # shellcheck disable=SC1090
    . "$HA_CLUSTER_CONF"

    _hlc_missing=""
    for _hlc_var in HA_CLUSTER_NAME HA_PG_VERSION HA_PG_PORT HA_DB_NAME HA_DB_USER \
                    HA_DB_PASSWORD HA_REPMGR_USER HA_REPMGR_PASSWORD HA_REPMGR_DB \
                    HA_HAPROXY_PORT HA_AGENT_PORT HA_SYNC_DIR HA_SYNC_DELAY \
                    HA_SYNC_PRIVATE_KEY_B64 HA_SYNC_PUBLIC_KEY; do
        # ${var:-} inside eval: never trips "unbound variable" (set -u)
        eval "_hlc_val=\${$_hlc_var:-}"
        [ -n "$_hlc_val" ] || _hlc_missing="$_hlc_missing $_hlc_var"
    done
    [ -n "$_hlc_missing" ] && die "cluster.conf misses variables:$_hlc_missing - re-issue the token on the init node (--print-token) or re-run --init"

    for _hlc_i in 1 2 3; do
        eval "_hlc_val=\$HA_NODE${_hlc_i}_IP"
        [ -n "$_hlc_val" ] || die "cluster.conf misses HA_NODE${_hlc_i}_IP"
        valid_ip "$_hlc_val" || die "cluster.conf: HA_NODE${_hlc_i}_IP is not a valid IPv4: $_hlc_val"
    done

    [ "$(ha_node_ip 1)" = "$(ha_node_ip 2)" ] && die "cluster.conf: node1 and node2 have the same IP"
    [ "$(ha_node_ip 1)" = "$(ha_node_ip 3)" ] && die "cluster.conf: node1 and node3 have the same IP"
    [ "$(ha_node_ip 2)" = "$(ha_node_ip 3)" ] && die "cluster.conf: node2 and node3 have the same IP"

    case "$HA_DB_PASSWORD$HA_REPMGR_PASSWORD" in
        *[!A-Za-z0-9]*) die "cluster.conf: passwords must match [A-Za-z0-9] (INI/SQL/pgpass safety rule)" ;;
    esac
    case "$HA_SYNC_DIR" in
        /*) ;;
        *) die "cluster.conf: HA_SYNC_DIR must be an absolute path" ;;
    esac
    return 0
}

# accessors: ha_node_ip N / ha_node_name N / ha_node_role N
# (empty output for unset values - safe under set -u)
ha_node_ip()   { eval "echo \"\${HA_NODE${1}_IP:-}\""; }
ha_node_name() { eval "echo \"\${HA_NODE${1}_NAME:-}\""; }
ha_node_role() { eval "echo \"\${HA_NODE${1}_ROLE:-}\""; }

# Sets HA_NODE_ID (1|2|3) and HA_ROLE by matching local addresses.
ha_detect_role() {
    _hdr_ips="$(own_ips)"
    [ -n "$_hdr_ips" ] || die "cannot determine local IP addresses (ip -o -4 addr)"
    HA_NODE_ID=""
    HA_ROLE=""
    for _hdr_i in 1 2 3; do
        if echo "$_hdr_ips" | grep -qx "$(ha_node_ip "$_hdr_i")"; then
            HA_NODE_ID="$_hdr_i"
            HA_ROLE="$(ha_node_role "$_hdr_i")"
            break
        fi
    done
    [ -n "$HA_NODE_ID" ] || return 1
    return 0
}

# peer data node id (1<->2); only valid on data nodes
ha_peer_id() { if [ "$HA_NODE_ID" = "1" ]; then echo 2; else echo 1; fi; }
ha_peer_ip() { ha_node_ip "$(ha_peer_id)"; }
ha_peer_name() { ha_node_name "$(ha_peer_id)"; }

# =============================================================================
# Token: TOKEN = base64( gzip( cluster.conf ) ) - one printable line
# =============================================================================

ha_token_pack() {
    gzip -c "$HA_CLUSTER_CONF" | base64 -w0 2>/dev/null | tr -d '\n'
}

# ha_token_unpack TOKEN_OR_ATFILE DEST
ha_token_unpack() {
    _htu_token="$1"
    _htu_dest="$2"
    case "$_htu_token" in
        @*) _htu_token="$(cat "${_htu_token#@}")" || die "cannot read token file ${1#@}" ;;
    esac
    [ -n "$_htu_token" ] || die "empty token"
    printf '%s' "$_htu_token" | base64 -d 2>/dev/null | gunzip -c 2>/dev/null > "$_htu_dest" \
        || die "invalid token (base64/gzip decode failed) - re-copy it from the init node"
    [ -s "$_htu_dest" ] || die "invalid token (unpacked to an empty file)"
}

# =============================================================================
# Step state machine (pattern: layer-1 guard.sh; DESIGN.md section 7)
#   .installer-state: command=<alias> + step_ok=<n> <fn> lines
#   .installed:       written only after the command completes fully
# =============================================================================

ha_state_begin() {
    _hsb_alias="$1"
    mkdir -p "$HA_ETC_DIR" 2>/dev/null || true
    if [ -f "$HA_STATE_FILE" ] && grep -q "^command=$_hsb_alias$" "$HA_STATE_FILE" 2>/dev/null; then
        verbose "NOTE: a previous '$_hsb_alias' run did not complete - resuming from the state file"
        verbose "  completed steps: $(grep -c '^step_ok=' "$HA_STATE_FILE" 2>/dev/null)"
    else
        {
            echo "# fusionpbx-ha progress state (auto-generated, do not edit)"
            echo "# removed automatically when the command completes"
            echo "command=$_hsb_alias"
            echo "started=$(date '+%Y-%m-%d %H:%M:%S')"
        } > "$HA_STATE_FILE" 2>/dev/null || warn "cannot write state file $HA_STATE_FILE (resume will not work)"
    fi
}

ha_state_step_is_done() {
    grep -q "^step_ok=$1 " "$HA_STATE_FILE" 2>/dev/null
}

ha_state_step_done() {
    echo "step_ok=$1 $2" >> "$HA_STATE_FILE" 2>/dev/null || true
}

ha_state_finish() {
    _hsf_alias="$1"
    _hsf_role="${HA_ROLE:-unknown}"
    {
        echo "# fusionpbx-ha completion marker (auto-generated, do not edit)"
        echo "# fusionpbx-ha.sh --join refuses to run while this file exists;"
        echo "# use --repair for maintenance re-runs."
        echo "completed_at=$(date '+%Y-%m-%d %H:%M:%S')"
        echo "command=$_hsf_alias"
        echo "cluster=${HA_CLUSTER_NAME:-unknown}"
        echo "node_id=${HA_NODE_ID:-?} role=$_hsf_role"
    } > "$HA_MARKER_FILE" 2>/dev/null || warn "cannot write marker $HA_MARKER_FILE"
    rm -f "$HA_STATE_FILE" 2>/dev/null
}

# -----------------------------------------------------------------------------
# Join resume vs. cluster generation (regression 0.3.18). A state file left
# by an earlier join attempt is only valid for THE SAME cluster secrets:
# '--init --force' on the primary REGENERATES them (new repmgr password,
# new sync key, new token), and a resume from such a state file would run
# every step against the OLD cluster.conf - step 2 (unpack) is skipped, so
# the new token is never applied. The real bench: node 2 resumed an
# October state file against a re-initialized primary and its media seed
# died with 'Permission denied (publickey)' - the OLD sync private key no
# longer matched the primary's re-generated authorized_keys. The token
# being joined IS the cluster identity: when its cluster.conf differs from
# the on-disk one (or the on-disk one is gone while a state file claims
# completed steps), the state file describes a cluster that no longer
# exists - discard it, and the join re-runs from step 1 (wipe + re-clone,
# exactly the documented re-install path). Tolerant by design: never
# fails (a die here would block the recovery the operator is walking
# INTO), and no-op without a state file (the normal first join).
# -----------------------------------------------------------------------------
ha_join_state_freshen() {
    _hjsf_conf="$1"    # the freshly unpacked token's cluster.conf
    [ -f "$HA_STATE_FILE" ] || return 0
    if [ -f "$HA_CLUSTER_CONF" ] && cmp -s "$_hjsf_conf" "$HA_CLUSTER_CONF" 2>/dev/null; then
        return 0
    fi
    if [ -f "$HA_CLUSTER_CONF" ]; then
        warn "the saved join state belongs to a DIFFERENT cluster generation"
        warn "  (the token's secrets differ from $HA_CLUSTER_CONF) -"
    else
        # 0.3.19: the state was written by an attempt that died BEFORE step 2
        # unpacked the token (or /etc/fusionpbx-ha was wiped afterwards) -
        # there is no cluster.conf to resume against. cmp of a missing file
        # reads as 'differs', which printed a misleading 'secrets differ'.
        warn "the saved join state has no cluster to belong to"
        warn "  ($HA_CLUSTER_CONF is missing - wiped or rebuilt node?) -"
    fi
    warn "  discarding it and re-joining from step 1 (local DB wiped + re-cloned)"
    rm -f "$HA_STATE_FILE" 2>/dev/null || true
    return 0
}

# Execute a sequence of step functions with resume support.
# Usage: ha_run_sequence <alias> <fn1> <fn2> ...
#
# Each step runs in a SUBSHELL: a die() inside a step exits only the subshell,
# and this runner prints the failure banner with the resume instructions
# (DESIGN.md 7). The price of the subshell is that variables set inside a
# step do not propagate back - therefore after every step the runner
# re-sources cluster.conf (a step may have written it), and callers must
# pre-compute cross-step variables (node id, addresses, PG version) BEFORE
# calling the runner.
ha_run_sequence() {
    _hrs_alias="$1"
    shift
    _hrs_total="$#"
    _hrs_n=0
    ha_state_begin "$_hrs_alias"
    for _hrs_fn in "$@"; do
        _hrs_n=$((_hrs_n + 1))
        if [ "${HA_FORCE:-0}" != "1" ] && ha_state_step_is_done "$_hrs_n"; then
            verbose ""
            verbose "=== step $_hrs_n/$_hrs_total: $_hrs_fn - already done, skipping"
            [ -f "$HA_CLUSTER_CONF" ] && . "$HA_CLUSTER_CONF" 2>/dev/null
            continue
        fi
        verbose ""
        verbose "=== step $_hrs_n/$_hrs_total: $_hrs_fn ==="
        if ( "$_hrs_fn" ); then
            :
        else
            error ""
            error "========================================="
            error " STEP $_hrs_n/$_hrs_total ($_hrs_fn) FAILED"
            error "========================================="
            error ""
            error "What to do:"
            error "  1. Read the messages above carefully"
            error "  2. Fix the problem (network, packages, peer node)"
            error "  3. Re-run the SAME command - completed steps are"
            error "     skipped automatically (resume from step $_hrs_n)"
            error ""
            exit 1
        fi
        [ -f "$HA_CLUSTER_CONF" ] && . "$HA_CLUSTER_CONF" 2>/dev/null
        ha_state_step_done "$_hrs_n" "$_hrs_fn"
    done
    ha_state_finish "$_hrs_alias"
}

# =============================================================================
# Managed blocks: idempotent marked sections inside existing config files
# (used for /etc/hosts, authorized_keys, pg_hba.conf)
# =============================================================================

ha_block_set() {
    _hbs_file="$1"
    _hbs_content="$2"
    [ -f "$_hbs_file" ] || die "ha_block_set: file not found: $_hbs_file"
    # drop any previous managed block (marker strings contain no regex metacharacters)
    sed -i "\|^${HA_BLOCK_BEGIN}$|,\|^${HA_BLOCK_END}$|d" "$_hbs_file" 2>/dev/null
    # drop the stray "written-by" comment line, if present
    sed -i '/^# fusionpbx-ha: managed block$/d' "$_hbs_file" 2>/dev/null
    {
        echo "# fusionpbx-ha: managed block"
        echo "$HA_BLOCK_BEGIN"
        printf '%s\n' "$_hbs_content"
        echo "$HA_BLOCK_END"
    } >> "$_hbs_file"
}

ha_block_present() {
    [ -f "$1" ] && grep -qF "$HA_BLOCK_BEGIN" "$1" 2>/dev/null
}

# =============================================================================
# Template rendering: replace @@PLACEHOLDER@@ tokens (sed with | delimiter;
# safe: all values are validated [A-Za-z0-9._/=+: -] by conf validation)
# Usage: ha_render <template> <dest> VAR=value [VAR=value...]
# =============================================================================

ha_render() {
    _hr_tpl="$1"
    _hr_dest="$2"
    shift 2
    [ -f "$_hr_tpl" ] || die "template not found: $_hr_tpl"
    _hr_tmp="${_hr_dest}.ha-tmp"
    mkdir -p "$(dirname "$_hr_dest")" 2>/dev/null || die "cannot create $(dirname "$_hr_dest")"
    cp "$_hr_tpl" "$_hr_tmp" || die "cannot copy template $_hr_tpl"
    for _hr_kv in "$@"; do
        _hr_k="${_hr_kv%%=*}"
        _hr_v="${_hr_kv#*=}"
        sed -i "s|@@${_hr_k}@@|${_hr_v}|g" "$_hr_tmp" || die "render failed for placeholder $_hr_k"
    done
    if grep -q '@@' "$_hr_tmp"; then
        _hr_left="$(grep -o '@@[A-Z0-9_]*@@' "$_hr_tmp" | sort -u | tr '\n' ' ')"
        rm -f "$_hr_tmp"
        die "template $_hr_tpl has unresolved placeholders: $_hr_left"
    fi
    mv "$_hr_tmp" "$_hr_dest" || die "cannot write $_hr_dest"
}

# =============================================================================
# rrsync: restricted rsync wrapper for the sync key forced command.
# ALT ships rrsync inside /usr/share/doc/rsync-*/support/ (version-locked
# path, python3) - copying it to /usr/local/bin keeps authorized_keys stable
# across rsync package updates.
# =============================================================================

ha_install_rrsync() {
    _hir_glob="${HA_RRSYNC_GLOB:-/usr/share/doc/rsync-*/support/rrsync}"
    _hir_dest="${HA_RRSYNC_INSTALL_DIR:-/usr/local/bin}/rrsync"
    if [ -x "$_hir_dest" ]; then
        echo "$_hir_dest"
        return 0
    fi
    if cmd_exists rrsync; then
        command -v rrsync
        return 0
    fi
    for _hir in $_hir_glob; do
        if [ -f "$_hir" ]; then
            mkdir -p "$(dirname "$_hir_dest")" 2>/dev/null
            install -m 0755 "$_hir" "$_hir_dest" 2>/dev/null \
                && { verbose "  rrsync installed: $_hir_dest (from $_hir)"; echo "$_hir_dest"; return 0; }
        fi
    done
    return 1
}

# =============================================================================
# Layer-1 integration: read /etc/fusionpbx/config.conf (INI, "key = value")
# Sets HA_L1_DB_NAME / HA_L1_DB_USER / HA_L1_DB_PASSWORD.
# =============================================================================

ha_read_layer1_conf() {
    [ -f "$HA_L1_CONF" ] || return 1
    HA_L1_DB_NAME="$(awk -F' *= *' '/^database\.0\.name/ {print $2; exit}' "$HA_L1_CONF" | tr -d ' \r')"
    HA_L1_DB_USER="$(awk -F' *= *' '/^database\.0\.username/ {print $2; exit}' "$HA_L1_CONF" | tr -d ' \r')"
    HA_L1_DB_PASSWORD="$(awk -F' *= *' '/^database\.0\.password/ {print $2; exit}' "$HA_L1_CONF" | tr -d ' \r')"
    [ -n "$HA_L1_DB_NAME" ] && [ -n "$HA_L1_DB_USER" ] && [ -n "$HA_L1_DB_PASSWORD" ] || return 1
    case "$HA_L1_DB_PASSWORD" in
        *[!A-Za-z0-9]*)
            die "layer-1 config.conf: database.0.password contains characters outside [A-Za-z0-9]
(the installer validates this rule - check $HA_L1_CONF)" ;;
    esac
    return 0
}

# =============================================================================
# PostgreSQL helpers
# =============================================================================

# actual PGDATA (layer-1 detection order: /etc/sysconfig/postgresql, default)
ha_pg_data_dir() {
    _hpgd_dir="$(grep -E '^PGDATA=' /etc/sysconfig/postgresql 2>/dev/null | head -1 | cut -d= -f2 | tr -d '"' | tr -d "'")"
    [ -n "$_hpgd_dir" ] || _hpgd_dir="$HA_PGDATA_DEFAULT"
    echo "$_hpgd_dir"
}

# installed cluster major version (PG_VERSION inside PGDATA)
ha_pg_version_major() {
    _hpv_dir="$(ha_pg_data_dir)"
    [ -r "$_hpv_dir/PG_VERSION" ] || return 1
    cat "$_hpv_dir/PG_VERSION" 2>/dev/null | tr -d ' \r'
}

# psql as the postgres system user (local socket, peer auth).
# synchronous_commit=off (regression 0.3.17): installer/repair SQL sessions
# must never WAIT for a sync standby - a stale synchronous_standby_names
# left by the previous cluster (re-install over an installed system, resume
# after its standby dropped) would otherwise freeze every write transaction
# while the new standby does not exist yet (it joins only at init step 12).
# Reads are unaffected; ALTER SYSTEM / pg_reload_conf bypass the WAL commit
# path, so the option is inert for them.
pg_runuser_psql() {
    PGOPTIONS='-c synchronous_commit=off' runuser -u postgres -- psql "$@" 2>/dev/null
}

# psql over TCP with the fusionpbx application credentials
pg_psql_app() {
    _hpa_host="$1"; shift
    PGPASSWORD="$HA_DB_PASSWORD" psql -h "$_hpa_host" -U "$HA_DB_USER" -d "$HA_DB_NAME" "$@" 2>/dev/null
}

# psql over TCP as the postgres superuser (remote ALTER SYSTEM for sync
# management; layer-1 sets the postgres password = database password)
pg_psql_superuser() {
    _hps_host="$1"; shift
    if [ "$_hps_host" = "local" ]; then
        pg_runuser_psql "$@"
    else
        PGPASSWORD="$HA_DB_PASSWORD" psql -h "$_hps_host" -p "$HA_PG_PORT" -U postgres "$@" 2>/dev/null
    fi
}

# 0 = local PG is primary, 1 = standby, 2 = not reachable
ha_local_role_code() {
    _hlrc="$(pg_runuser_psql -tAc "SELECT pg_is_in_recovery()" 2>/dev/null | tr -d ' \r')"
    case "$_hlrc" in
        f) return 0 ;;
        t) return 1 ;;
        *) return 2 ;;
    esac
}

ha_local_is_primary() { ha_local_role_code; [ $? -eq 0 ]; }

# Wait for the local PostgreSQL to answer a trivial query (up to 60 x 1s).
# Used by the repair flow around rejoin/clone, where PostgreSQL is bounced
# and must be back before the next step touches it.
ha_pg_wait_answer() {
    _hpwa_try=0
    while [ "$_hpwa_try" -lt 60 ]; do
        pg_runuser_psql -tAc "SELECT 1" >/dev/null 2>&1 && return 0
        sleep 1
        _hpwa_try=$((_hpwa_try + 1))
    done
    return 1
}

# 0.3.28: the repair's step-3 classifier (ha_rejoin_plan) needs the local
# database RUNNING, i.e. the repair may have to START a stale primary for
# a moment - and the 0.3.27 boot guard refuses exactly that start while
# the peer is the live primary (the 26.10 bench: the repair died 'local
# PostgreSQL does not start', the node stuck out of the cluster while its
# peer was perfectly healthy). An operator-driven repair owns the node's
# role transitions for its duration, so the start is marked for the guard
# with a /run (tmpfs) flag that never survives a reboot and is removed the
# moment the start attempt returned. The same helper neutralizes the two
# boot-time leftovers first: the restart loop scheduled by the guard's
# blocks (it would fight the rejoin's stop) and the start-rate-limit poison
# (every blocked attempt counted as a failed start - the next
# 'systemctl start' would die 'Start request repeated too quickly' even
# when the guard would allow it).
ha_pg_start_for_classification() {
    systemctl stop "$HA_PG_SERVICE" >/dev/null 2>&1 || true
    systemctl reset-failed "$HA_PG_SERVICE" >/dev/null 2>&1 || true
    _hpsc_flag="${HA_REPAIR_START_FLAG:-/run/fusionpbx-ha/repair-start.flag}"
    mkdir -p "$(dirname "$_hpsc_flag")" 2>/dev/null || true
    : > "$_hpsc_flag" 2>/dev/null
    if ! systemctl start "$HA_PG_SERVICE"; then
        rm -f "$_hpsc_flag" 2>/dev/null
        return 1
    fi
    rm -f "$_hpsc_flag" 2>/dev/null
    return 0
}

# 0.3.28: start the local PostgreSQL under systemd when the boot guard
# would ALLOW it anyway (standby.signal is present after a clone/rejoin) -
# only the rate-limit poison from boot-time guard blocks must be cleared.
ha_pg_start_tracked() {
    systemctl reset-failed "$HA_PG_SERVICE" >/dev/null 2>&1 || true
    systemctl start "$HA_PG_SERVICE"
}

# 0.3.33: the guard flag window for the WHOLE 'repmgr node rejoin' call.
# repmgr's service_start_command start happens INSIDE the rejoin
# (repmgr-action-standby.c: do_standby_follow_internal() ->
# create_recovery_file() -> systemctl start), and create_recovery_file()
# DOES write standby.signal before that start (repmgr 5.5.0,
# repmgr-action-standby.c:8309 - so the guard allows the rejoin start
# even without the flag), but the window costs nothing and covers any
# path where the signal file is not yet there (a failed rewind, a
# repmgr version that orders things differently). The same 0.3.28
# rationale, extended one call further: an operator-driven repair owns
# the node's role transitions for its duration. /run (tmpfs) - a crash
# cannot leave the guard blinded across a reboot.
ha_repair_start_window_open() {
    _hrso_flag="${HA_REPAIR_START_FLAG:-/run/fusionpbx-ha/repair-start.flag}"
    mkdir -p "$(dirname "$_hrso_flag")" 2>/dev/null || true
    : > "$_hrso_flag" 2>/dev/null || true
}

ha_repair_start_window_close() {
    _hrsc_flag="${HA_REPAIR_START_FLAG:-/run/fusionpbx-ha/repair-start.flag}"
    rm -f "$_hrsc_flag" 2>/dev/null || true
}

# 0.3.33: prove the exact privilege path repmgr's service_start_command
# needs BEFORE the rejoin runs into it. 'sudo -n systemctl show' is one
# read-only shot that exercises sudo + the sudoers drop-in + NOPASSWD +
# no-requiretty + the systemctl binary as user postgres (the verb is in
# the FUSIONPBX_HA_PGCTL alias precisely for this probe - 'show' cannot
# change state and succeeds for an existing unit). repmgr discards the
# captured child output when the command FAILS (only "unable to start
# server" is printed), so a broken sudo path inside the rejoin is
# otherwise invisible; this preflight turns it into an actionable die.
ha_preflight_repmgr_service_commands() {
    cmd_exists sudo || return 0
    runuser -u postgres -- sudo -n systemctl show "$HA_PG_SERVICE" >/dev/null 2>&1
    [ $? -eq 0 ] && return 0
    die "repmgr cannot control PostgreSQL as user postgres:
'sudo -n systemctl show $HA_PG_SERVICE' (run as postgres) failed - the
rejoin's 'systemctl start' (repmgr.conf service_start_command) would die
the same way, with the reason swallowed by repmgr.
Check, in this order:
  1. visudo -c  (sudoers syntax)
  2. /etc/sudoers.d/fusionpbx-ha exists and contains the PGCTL alias
  3. 'Defaults requiretty' in /etc/sudoers (must NOT apply to postgres:
     add 'Defaults!postgres !requiretty')
  4. manual proof: runuser -u postgres -- sudo -n systemctl show $HA_PG_SERVICE"
}

# 0.3.33: repmgr's local_command() discards the captured child output
# when the command FAILS (repmgr-action-standby.c:3553-3559: only
# "unable to start server" is printed - the systemctl stderr, a guard
# refusal and PostgreSQL's own startup FATAL all vanish). The 27.10
# bench: the diverged rejoin died exactly so, 'unable to start server'
# with nothing else, while the journal held the whole story. Collect
# the two sources the node actually has, right now, while fresh - and
# scrub password= from anything printed, belt over the 0.3.33
# passwordless conninfo.
ha_rejoin_failure_forensics() {
    warn "  collecting the rejoin failure forensics (repmgr will not show them):"
    echo "    --- journal: $HA_PG_SERVICE, last 40 lines:" >&2
    journalctl -u "$HA_PG_SERVICE" --since '-20 min' --no-pager 2>/dev/null \
        | tail -n 40 | sed -e 's/^/      /' -e 's/password=[^ ]*/password=***/g' >&2
    _hrff_log="$(ls -t "$(ha_pg_data_dir)/log/"postgresql-*.log 2>/dev/null | head -n 1)"
    if [ -n "$_hrff_log" ]; then
        echo "    --- PostgreSQL log tail ($_hrff_log):" >&2
        tail -n 30 "$_hrff_log" 2>/dev/null \
            | sed -e 's/^/      /' -e 's/password=[^ ]*/password=***/g' >&2
    else
        echo "    --- no $(ha_pg_data_dir)/log/postgresql-*.log found" >&2
    fi
    if [ -f "$(ha_pg_data_dir)/standby.signal" ]; then
        echo "    standby.signal present - PostgreSQL starts in recovery mode" >&2
    else
        echo "    standby.signal MISSING - a start would come up as a read-write primary" >&2
    fi
}

# 0.3.22: classify the LOCAL node for the repair rejoin. repmgr 5.5 refuses
# 'node rejoin' on a running database ("database is still running in state
# 'in archive recovery'" / "cannot be executed on a running node") - the
# bench repair died exactly there on a perfectly HEALTHY standby that only
# needed its services restarted. 'attached' is returned ONLY when the local
# database is in recovery AND its WAL receiver is connected to the given
# peer (= the current primary, verified by the repair preflight) AND the
# peer actually counts us as a replicating standby (0.3.31): such a node
# must not be stopped/rewound at all. Anything else - a running stale
# primary from before a failover, a standby on a dead or wrong upstream, a
# database without a receiver, and the 26.10 zombie below - is 'diverged'
# and needs the rejoin.
# Pure string logic (testable): the caller collects the psql output.
#
# 0.3.31 forensics: a receiver CONNECTED to the peer proved nothing. The
# 26.10 bench: the stale primary's auto-rejoin pg_rewind failed (missing
# EXECUTE grants, see ha_fix_repmgr_schema_access) - but the rejoin
# attempt had already recreated standby.signal, so the boot's own
# postgresql start brought the node up as a "standby" that had replayed
# its OWN timeline-4 WAL past the fork point where the peer promoted to
# timeline 5. That continuation WAL exists nowhere in the cluster: the
# receiver connected, the peer's walsender sat in 'startup' forever,
# replay never advanced, sync never re-engaged ("no streaming standby")
# - while this classifier kept saying 'attached' (receiver connected) and
# every --repair skipped the rejoin. The verdict now needs the PEER's
# word for it: attached = the peer reports our application_name with
# state='streaming', OR replay is visibly advancing (a healthy catchup -
# the peer shows 'catchup'/'startup' for minutes after a long downtime).
ha_rejoin_plan_classify() {
    _hrpc_in_recovery="$1"      # pg_is_in_recovery(): t / f / '' (unreachable)
    _hrpc_sender="$2"           # pg_stat_wal_receiver.sender_host ('' = none)
    _hrpc_peer_ip="$3"
    _hrpc_peer_streaming="$4"   # yes / no / unknown (the peer probe failed)
    _hrpc_replay_advancing="$5" # yes / no (two pg_last_wal_replay_lsn samples)
    if [ "$_hrpc_in_recovery" = "t" ] && [ "$_hrpc_sender" = "$_hrpc_peer_ip" ]; then
        # probe verdict unknown (transient failure): keep the 0.3.22
        # local-only verdict - the repair preflight just proved the peer
        # alive, and an interrupted rejoin on a healthy standby costs
        # more than a retry on the next --repair
        if [ "$_hrpc_peer_streaming" != "no" ]; then
            echo "attached"
            return 0
        fi
        # the peer answered and does NOT see us streaming: attached only
        # while replay still advances (catchup in progress); frozen = the
        # diverged-WAL zombie above - only a pg_rewind rejoin fixes it
        if [ "$_hrpc_replay_advancing" = "yes" ]; then
            echo "attached"
        else
            echo "diverged"
        fi
        return 0
    fi
    echo "diverged"
}

# Collector half of the classifier: reads the local PostgreSQL state, asks
# the PEER whether it sees us streaming, samples replay advancement when
# the answer is 'not yet', and hands it all to ha_rejoin_plan_classify.
# The database must be RUNNING and answering (the repair flow guarantees
# that before calling).
ha_rejoin_plan() {
    _hrp_peer_ip="$1"
    _hrp_in_recovery="$(pg_runuser_psql -tAc "SELECT pg_is_in_recovery()" 2>/dev/null | tr -d ' \r')"
    _hrp_sender="$(pg_runuser_psql -tAc "SELECT sender_host FROM pg_stat_wal_receiver" 2>/dev/null | head -n 1 | tr -d ' \r')"
    _hrp_peer_streaming="unknown"
    _hrp_replay_advancing="no"
    if [ "$_hrp_in_recovery" = "t" ] && [ "$_hrp_sender" = "$_hrp_peer_ip" ]; then
        # 0.3.31: ask the current primary whether WE are a streaming
        # standby of it (the repair preflight just proved it alive). A
        # non-zero rc = the probe itself failed -> 'unknown', the
        # local-only verdict stands.
        if _hrp_probe="$(pg_psql_superuser "$_hrp_peer_ip" -tAc \
                "SELECT 1 FROM pg_stat_replication WHERE application_name='$(ha_node_name "${HA_NODE_ID:-1}")' AND state='streaming'")"; then
            _hrp_peer_streaming="no"
            echo "$_hrp_probe" | grep -q 1 && _hrp_peer_streaming="yes"
        fi
        if [ "$_hrp_peer_streaming" = "no" ]; then
            # not (yet) streaming: healthy catchup or the stuck zombie?
            # sample the replay LSN - advancement = a catchup in progress
            _hrp_lsn1="$(pg_runuser_psql -tAc "SELECT pg_last_wal_replay_lsn()" 2>/dev/null | tr -d ' \r')"
            sleep "${HA_REJOIN_ADVANCE_SLEEP:-4}"
            _hrp_lsn2="$(pg_runuser_psql -tAc "SELECT pg_last_wal_replay_lsn()" 2>/dev/null | tr -d ' \r')"
            if [ -n "$_hrp_lsn1" ] && [ -n "$_hrp_lsn2" ] && [ "$_hrp_lsn1" != "$_hrp_lsn2" ]; then
                _hrp_replay_advancing="yes"
            fi
        fi
    fi
    ha_rejoin_plan_classify "${_hrp_in_recovery:-?}" "${_hrp_sender:-}" "$_hrp_peer_ip" \
        "$_hrp_peer_streaming" "$_hrp_replay_advancing"
}

# 0.3.22: 'repmgr node rejoin' may (re)start PostgreSQL itself via pg_ctl,
# i.e. OUTSIDE systemd - the service would sit 'inactive' while postgres
# runs, every later doctor run would fail the 'service postgresql active'
# check and a future 'systemctl start postgresql' would fight the orphan.
# Bring the node back under systemd management: if repmgr started it, stop
# it via pg_ctl (as the postgres user) and start it via systemctl; if it
# did not come up at all, a plain systemctl start is enough.
ha_pg_adopt_after_rejoin() {
    if ! pg_runuser_psql -tAc "SELECT 1" >/dev/null 2>&1; then
        ha_pg_start_tracked \
            || die "PostgreSQL did not start after the rejoin - re-run with --force-clone"
        ha_pg_wait_answer \
            || die "PostgreSQL is not answering after the rejoin - re-run with --force-clone"
        return 0
    fi
    if ! svc_active "$HA_PG_SERVICE"; then
        verbose "  PostgreSQL was started outside systemd (by repmgr) - moving it back under systemd"
        runuser -u postgres -- pg_ctl -D "$(ha_pg_data_dir)" stop -m fast -w -t 300 >/dev/null 2>&1
        ha_pg_start_tracked \
            || die "PostgreSQL did not start under systemd after the rejoin - re-run with --force-clone"
        ha_pg_wait_answer \
            || die "PostgreSQL is not answering after the rejoin - re-run with --force-clone"
    fi
}

# -----------------------------------------------------------------------------
# listen_addresses (regression 0.3.2): layer 1 leaves PostgreSQL loopback-only
# ('localhost'), but the cluster needs the node IP - repmgr register/repmgrd
# conninfo, the PEER haproxy backend (it connects to the node IPs, not to
# 127.0.0.1), the witness and the failover consensus all arrive via the node
# IP. '*' is safe: the pg_hba managed block above gates every connection.
# -----------------------------------------------------------------------------

# 0 = listen_addresses already serves this node's cluster IP
ha_pg_listen_ok() {
    _hplo_cur="$(pg_runuser_psql -tAc "SHOW listen_addresses" 2>/dev/null | tr -d ' \r')"
    [ "$_hplo_cur" = "*" ] && return 0
    echo ",$_hplo_cur," | grep -q ",$(ha_node_ip "${HA_NODE_ID:-1}"),"
}

# Ensure it; idempotent, restarts PostgreSQL ONCE only when a change is needed.
ha_ensure_pg_listen() {
    ha_pg_listen_ok && return 0
    verbose "  PostgreSQL listens on '$(pg_runuser_psql -tAc "SHOW listen_addresses" 2>/dev/null | tr -d ' \r')' only -"
    verbose "  the cluster reaches this node via $(ha_node_ip "${HA_NODE_ID:-1}"):$HA_PG_PORT (repmgr, peer haproxy, witness)"
    if pg_runuser_psql -tAc "SELECT pg_is_in_recovery()" 2>/dev/null | grep -q t; then
        # ALTER SYSTEM is refused during recovery - edit postgresql.auto.conf
        # directly instead (the standby file-writes are fine, it is not read-only)
        _hepl_auto="$(ha_pg_data_dir)/postgresql.auto.conf"
        touch "$_hepl_auto" 2>/dev/null || die "cannot write $_hepl_auto"
        chown postgres:postgres "$_hepl_auto" 2>/dev/null || true
        sed -i '/^[[:space:]]*listen_addresses[[:space:]]*=/d' "$_hepl_auto" 2>/dev/null
        echo "listen_addresses = '*'" >> "$_hepl_auto"
    else
        pg_runuser_psql -c "ALTER SYSTEM SET listen_addresses = '*';" >/dev/null \
            || die "cannot set listen_addresses"
    fi
    verbose "  listen_addresses = '*' - ONE PostgreSQL restart"
    systemctl restart "$HA_PG_SERVICE" || die "PostgreSQL restart failed"
    _hepl_try=0
    while [ "$_hepl_try" -lt 30 ]; do
        pg_runuser_psql -tAc "SELECT 1" >/dev/null 2>&1 && break
        sleep 1
        _hepl_try=$((_hepl_try + 1))
    done
    pg_runuser_psql -tAc "SELECT 1" >/dev/null 2>&1 || die "PostgreSQL did not come back after the listen_addresses restart"
    ha_pg_listen_ok || die "listen_addresses = '*' did not take effect"
    verbose "  PostgreSQL now accepts connections on $(ha_node_ip "${HA_NODE_ID:-1}"):$HA_PG_PORT"
}

# -----------------------------------------------------------------------------
# shared_preload_libraries = 'repmgr' (regression 0.3.15)
#
# repmgrd ALWAYS writes its node id into the shared memory area provided by
# the repmgr.so server module right after connecting (the SQL wrappers
# set_local_node_id()/get_local_node_id() live in the extension, the
# implementation in repmgr.so only works when the library was PRELOADED at
# server start - the memory area does not exist on demand). Without the
# preload repmgrd dies INSTANTLY with exit code 1 and the reason only in
# log_file ('unable to write to shared memory', hint: 'ensure
# "shared_preload_libraries" includes "repmgr"').
#
# Verified against the ALT RPM postgresql16-repmgr 5.5.0-alt5 binary and
# repmgrd 5.5.0 main(): every other startup failure is either pre-notice
# (config parse / log open - no 'redirecting logging output' line in the
# journal) or exit code 6 (one connection attempt, NO retry at startup).
# The bench signature - redirect NOTICE printed, PostgreSQL up, instant
# status=1/FAILURE, journal otherwise silent - matches this check and
# nothing else. Everything else in the stack (repmgr CLI, replication,
# haproxy, role-agent) works WITHOUT the preload; only repmgrd dies, so
# the cluster looked healthy while automatic failover was silently absent
# since the very first install.
# -----------------------------------------------------------------------------

# 0 = the postmaster already runs with repmgr preloaded (runtime view)
ha_repmgr_preload_active() {
    _hrpa_cur="$(pg_runuser_psql -tAc "SHOW shared_preload_libraries" 2>/dev/null | tr -d ' \r')"
    echo ",$_hrpa_cur," | grep -q ",repmgr,"
}

# Server module directory. repmgr.so MUST be proven to exist before the
# GUC is ever written: preloading a missing library makes the NEXT server
# start die ('could not access file ... repmgr.so') - that would turn a
# repair into an outage (HA_PG_PKGLIBDIR: test-sandbox override).
ha_pg_pkglibdir() {
    if [ -n "${HA_PG_PKGLIBDIR:-}" ]; then printf '%s\n' "$HA_PG_PKGLIBDIR"; return 0; fi
    if command -v pg_config >/dev/null 2>&1; then
        _hgpd="$(pg_config --pkglibdir 2>/dev/null)"
        [ -n "$_hgpd" ] && { printf '%s\n' "$_hgpd"; return 0; }
    fi
    printf '%s\n' /usr/lib64/pgsql    # ALT postgresql16 layout fallback
}

# Write shared_preload_libraries = '<current>,repmgr' (APPEND - never
# drop entries other packages set). Idempotent callers check
# ha_repmgr_preload_active first; a second write just replaces the GUC with
# the same composed value. Dies when repmgr.so cannot be proven present.
ha_repmgr_preload_write() {
    _hrpw_dir="$(ha_pg_pkglibdir)"
    [ -f "$_hrpw_dir/repmgr.so" ] \
        || die "repmgr.so not found in $_hrpw_dir - is the repmgr package installed?
Refusing to write shared_preload_libraries: PostgreSQL would then refuse to
start at the next restart (an outage instead of a repair)."

    _hrpw_cur="$(pg_runuser_psql -tAc "SHOW shared_preload_libraries" 2>/dev/null | tr -d ' \r')"
    # server down / never started yet: compose from postgresql.conf so a
    # pre-existing entry there is not silently clobbered by the auto.conf
    # line (auto.conf wins the merge)
    if [ -z "$_hrpw_cur" ] && [ -f "$(ha_pg_data_dir)/postgresql.conf" ]; then
        _hrpw_cur="$(grep -E '^[[:space:]]*shared_preload_libraries[[:space:]]*=' "$(ha_pg_data_dir)/postgresql.conf" 2>/dev/null \
            | tail -1 | cut -d= -f2- | tr -d " '\"" )"
    fi
    _hrpw_val="repmgr"
    [ -n "$_hrpw_cur" ] && _hrpw_val="${_hrpw_cur},repmgr"

    _hrpw_err="$(mktemp "${TMPDIR:-/tmp}/fpbx-ha-preload.XXXXXX")"
    # runuser DIRECTLY (not pg_runuser_psql): the helper swallows stderr
    # internally (2>/dev/null) and the refusal reason must be captured for
    # the die path - the 0.3.4 swallowed-error class, ha_sync_names_write
    # made the same call
    runuser -u postgres -- psql -c "ALTER SYSTEM SET shared_preload_libraries = '${_hrpw_val}';" \
        >/dev/null 2>"$_hrpw_err"
    if [ $? -eq 0 ]; then
        rm -f "$_hrpw_err"
        verbose "  shared_preload_libraries = '${_hrpw_val}' written (activates at the next PostgreSQL start)"
        return 0
    fi

    # ALTER SYSTEM refused. Legitimate when the server is in recovery (a
    # standby: ALTER SYSTEM is not allowed there) or not answering at all
    # (pre-first-start, e.g. the fresh witness right after initdb) - in
    # both cases postgresql.auto.conf is written directly (the standby
    # file-writes are fine, same pattern as listen_addresses). A LIVE
    # primary refusing ALTER SYSTEM is unexpected: die with the real
    # psql verdict instead of papering over it.
    _hrpw_rec="$(pg_runuser_psql -tAc "SELECT pg_is_in_recovery()" 2>/dev/null | tr -d ' \r')"
    case "$_hrpw_rec" in
        t|"") ;;   # standby in recovery | server not answering
        *) _hrpw_why="$(tail -n 8 "$_hrpw_err" | sed 's/^/  /')"
           rm -f "$_hrpw_err"
           die "ALTER SYSTEM SET shared_preload_libraries was refused on a live primary:
$_hrpw_why" ;;
    esac
    rm -f "$_hrpw_err"

    warn "ALTER SYSTEM was refused - writing postgresql.auto.conf directly"
    _hrpw_auto="$(ha_pg_data_dir)/postgresql.auto.conf"
    touch "$_hrpw_auto" 2>/dev/null \
        || die "cannot write $_hrpw_auto (shared_preload_libraries not set - repmgrd cannot run)"
    chown postgres:postgres "$_hrpw_auto" 2>/dev/null || true
    sed -i '/^[[:space:]]*shared_preload_libraries[[:space:]]*=/d' "$_hrpw_auto" 2>/dev/null
    echo "shared_preload_libraries = '${_hrpw_val}'" >> "$_hrpw_auto"
    verbose "  shared_preload_libraries = '${_hrpw_val}' written to $_hrpw_auto (activates at the next PostgreSQL start)"
    return 0
}

# Full convergence: write when missing, ONE restart, verify. 0.3.16: the
# only caller is the witness join step 4 (the REUSE path - an interrupted
# join resuming with the database already running; the fresh path writes
# the preload before the first start, the standby inherits it from the
# clone, the primary gets it in init step 5). Never called from the doctor
# or the register prelude - configurations belong to the installer.
ha_ensure_repmgr_preload() {
    ha_repmgr_preload_active \
        && { verbose "  repmgr shared library is preloaded (repmgrd-ready)"; return 0; }
    verbose "  shared_preload_libraries lacks 'repmgr' - repmgrd cannot run without"
    verbose "  its shared memory module (dies: 'unable to write to shared memory')"
    ha_repmgr_preload_write
    verbose "  - ONE PostgreSQL restart to activate the preload"
    systemctl restart "$HA_PG_SERVICE" || die "PostgreSQL restart failed (shared_preload_libraries)"
    _herp_try=0
    while [ "$_herp_try" -lt 30 ]; do
        pg_runuser_psql -tAc "SELECT 1" >/dev/null 2>&1 && break
        sleep 1
        _herp_try=$((_herp_try + 1))
    done
    pg_runuser_psql -tAc "SELECT 1" >/dev/null 2>&1 || die "PostgreSQL did not come back after the preload restart"
    ha_repmgr_preload_active || die "shared_preload_libraries does not include 'repmgr' after the restart - check the PostgreSQL log"
    verbose "  repmgr shared library preloaded (repmgrd-ready)"
    return 0
}

# -----------------------------------------------------------------------------
# sudoers drop-in: repmgr.service runs as User=postgres, but the service_*_command
# lines in repmgr.conf need systemctl (root). Tight NOPASSWD allowlist for the
# PostgreSQL service only (DESIGN.md 13.2; the repmgr RPM may ship its own
# /etc/sudoers.d/repmgr - ours is a belt-and-braces duplicate, they coexist).
# -----------------------------------------------------------------------------
ha_install_sudoers() {
    _hisd_dir="${HA_SUDOERS_DIR:-/etc/sudoers.d}"
    if ! cmd_exists sudo; then
        verbose "  sudo not found - skipping the sudoers drop-in (repmgr service commands stay dormant)"
        return 0
    fi
    mkdir -p "$_hisd_dir" 2>/dev/null || { warn "cannot create $_hisd_dir - repmgr service commands stay dormant"; return 0; }
    _hisd_file="$_hisd_dir/fusionpbx-ha"
    cat > "$_hisd_file" <<'EOSUDO'
# fusionpbx-ha: managed file - repmgrd (User=postgres) controls the local
# PostgreSQL service (repmgr node rejoin / clone edge paths) and, after a
# successful promote (0.3.24), drops the local applications' dead sockets
# to the failed peer (restart-only verbs - no start/stop privilege).
Cmnd_Alias FUSIONPBX_HA_PGCTL = /usr/bin/systemctl start postgresql, \
    /usr/bin/systemctl stop postgresql, /usr/bin/systemctl restart postgresql, \
    /usr/bin/systemctl reload postgresql, /usr/bin/systemctl status postgresql, \
    /usr/bin/systemctl show postgresql
Cmnd_Alias FUSIONPBX_HA_APPS = /usr/bin/systemctl try-restart php*-fpm, \
    /usr/bin/systemctl try-restart angie, \
    /usr/bin/systemctl try-restart freeswitch
postgres ALL=(root) NOPASSWD: FUSIONPBX_HA_PGCTL, FUSIONPBX_HA_APPS
EOSUDO
    chmod 440 "$_hisd_file" 2>/dev/null || true
    if cmd_exists visudo; then
        if ! visudo -c -f "$_hisd_file" >/dev/null 2>&1; then
            rm -f "$_hisd_file"
            warn "sudoers drop-in failed validation (visudo) - removed; repmgr service commands stay dormant"
            return 0
        fi
    fi
    verbose "  sudoers drop-in installed: $_hisd_file (repmgrd may control postgresql)"
}

# -----------------------------------------------------------------------------
# 0.3.27: PostgreSQL boot guard (see resources/pg-boot-guard.sh for the
# verdict table). A hard-power-cut PRIMARY has no standby.signal and would
# boot as a COMPETING primary (the 22.10 bench split-brain); repmgr never
# demotes an old primary, so the only safe gate is ExecStartPre - the guard
# blocks the start while the peer's primary is alive and the blocked node's
# haproxy keeps serving the applications from the surviving primary.
# 0.3.29: the same installer places the AUTOMATIC REJOIN - a oneshot unit
# running at every data-node boot; when the guard's own inputs say "stale
# primary, peer verifiably primary, clean single-failover topology, small
# fork gap" it rejoins via pg_rewind unattended (resources/pg-auto-rejoin.sh
# for the verdict/gate table; NEVER force-clones or promotes).
# Managed files: the two scripts (/usr/lib), the rendered SECRET-FREE conf
# (/etc/fusionpbx-ha, 644 - both run as root and must never need cluster.conf,
# which is 600 root-only), the postgresql.service drop-in and the
# fusionpbx-ha-auto-rejoin unit. Data nodes only; inert until repmgr.conf
# exists, and a standby (standby.signal) always boots unconditionally.
# -----------------------------------------------------------------------------
ha_install_pg_boot_guard() {
    _hibg_dir="${HA_BOOT_GUARD_DIR:-$HA_LIB_DIR}"
    _hibg_dst="$_hibg_dir/pg-boot-guard.sh"
    if [ -f "$HA_RES_DIR/pg-boot-guard.sh" ]; then
        install -D -m 0755 "$HA_RES_DIR/pg-boot-guard.sh" "$_hibg_dst" 2>/dev/null \
            || { warn "cannot install $_hibg_dst - this node boots unguarded"; return 1; }
    elif [ ! -x "$_hibg_dst" ]; then
        warn "pg-boot-guard.sh source missing - this node boots unguarded"
        return 1
    fi
    if [ "$HA_NODE_ID" = "1" ]; then
        _hibg_peer="$(ha_node_ip 2)"
    else
        _hibg_peer="$(ha_node_ip 1)"
    fi
    _hibg_nodename="$(ha_node_name "${HA_NODE_ID:-1}")"
    : "${_hibg_nodename:=fpbx-ha-1}"
    _hibg_conf="$HA_ETC_DIR/boot-guard.conf"
    _hibg_tmp="$(mktemp "${TMPDIR:-/tmp}/fpbx-ha-guard.XXXXXX")"
    sed -e "s|@@PEER_IP@@|$_hibg_peer|g" \
        -e "s|@@PGDATA@@|$(ha_pg_data_dir)|g" \
        -e "s|@@PG_PORT@@|$HA_PG_PORT|g" \
        -e "s|@@AGENT_PORT@@|$HA_AGENT_PORT|g" \
        -e "s|@@ATTEMPTS@@|${HA_BOOT_GUARD_ATTEMPTS:-15}|g" \
        -e "s|@@SLEEP@@|${HA_BOOT_GUARD_SLEEP:-2}|g" \
        -e "s|@@REPMGR_USER@@|$HA_REPMGR_USER|g" \
        -e "s|@@REPMGR_DB@@|$HA_REPMGR_DB|g" \
        -e "s|@@REPMGR_CONF@@|$HA_REPMGR_CONF|g" \
        -e "s|@@NODE_NAME@@|$_hibg_nodename|g" \
        -e "s|@@PG_SERVICE@@|$HA_PG_SERVICE|g" \
        -e "s|@@REPMGRD_SERVICE@@|$HA_REPMGRD_SERVICE|g" \
        -e "s|@@LSYNCD_SERVICE@@|$HA_LSYNCD_SERVICE|g" \
        -e "s|@@REJOIN_ATTEMPTS@@|${HA_AUTO_REJOIN_ATTEMPTS:-45}|g" \
        -e "s|@@REJOIN_SLEEP@@|${HA_AUTO_REJOIN_SLEEP:-2}|g" \
        -e "s|@@MAX_GAP_MB@@|${HA_AUTO_REJOIN_MAX_GAP_MB:-128}|g" \
        "$HA_RES_DIR/boot-guard.conf.tpl" > "$_hibg_tmp" || { rm -f "$_hibg_tmp"; return 1; }
    if ! cmp -s "$_hibg_tmp" "$_hibg_conf" 2>/dev/null; then
        install -m 0644 "$_hibg_tmp" "$_hibg_conf" 2>/dev/null \
            || { rm -f "$_hibg_tmp"; warn "cannot write $_hibg_conf - this node boots unguarded"; return 1; }
        verbose "  boot guard config written: $_hibg_conf (peer: $_hibg_peer)"
    fi
    rm -f "$_hibg_tmp"

    _hibg_unit_dir="${HA_SYSTEMD_DIR}/${HA_PG_SERVICE}.service.d"
    _hibg_unit_conf="$_hibg_unit_dir/fusionpbx-ha.conf"
    _hibg_unit_tmp="$(mktemp "${TMPDIR:-/tmp}/fpbx-ha-dropin.XXXXXX")"
    cat > "$_hibg_unit_tmp" <<DROPIN
# fusionpbx-ha: PostgreSQL boot guard (0.3.27) - a hard-power-cut PRIMARY
# has no standby.signal and would boot as a competing primary; ExecStartPre
# refuses the start while the peer's primary is alive (runs as root via the
# '+' prefix; rendered secret-free config: /etc/fusionpbx-ha/boot-guard.conf).
[Service]
ExecStartPre=+/usr/lib/fusionpbx-ha/pg-boot-guard.sh
DROPIN
    if ! mkdir -p "$_hibg_unit_dir" 2>/dev/null; then
        rm -f "$_hibg_unit_tmp"
        warn "cannot create $_hibg_unit_dir - this node boots unguarded"
        return 1
    fi
    if [ -f "$_hibg_unit_conf" ] && cmp -s "$_hibg_unit_tmp" "$_hibg_unit_conf"; then
        rm -f "$_hibg_unit_tmp"
        verbose "  boot guard drop-in up to date: $_hibg_unit_conf"
    else
        install -m 644 "$_hibg_unit_tmp" "$_hibg_unit_conf" 2>/dev/null || {
            rm -f "$_hibg_unit_tmp"
            warn "cannot write $_hibg_unit_conf - this node boots unguarded"
            return 1
        }
        rm -f "$_hibg_unit_tmp"
        verbose "  boot guard drop-in installed: $_hibg_unit_conf (crashed primary cannot boot as a competing primary)"
    fi

    # 0.3.29: the automatic rejoin - script + unit + enable (never start:
    # it is a boot-time unit; on the CURRENT uptime the manual --repair
    # owns the flow)
    _hibg_ar_dst="$_hibg_dir/pg-auto-rejoin.sh"
    if [ -f "$HA_RES_DIR/pg-auto-rejoin.sh" ]; then
        install -D -m 0755 "$HA_RES_DIR/pg-auto-rejoin.sh" "$_hibg_ar_dst" 2>/dev/null \
            || warn "cannot install $_hibg_ar_dst - automatic rejoin unavailable"
    elif [ ! -x "$_hibg_ar_dst" ]; then
        warn "pg-auto-rejoin.sh source missing - automatic rejoin unavailable"
    fi
    _hibg_ar_unit="$HA_SYSTEMD_DIR/$HA_AUTO_REJOIN_UNIT.service"
    if [ -f "$HA_RES_DIR/fusionpbx-ha-auto-rejoin.service" ]; then
        _hibg_ar_tmp="$(mktemp "${TMPDIR:-/tmp}/fpbx-ha-arunit.XXXXXX")"
        cat > "$_hibg_ar_tmp" <<ARUNIT
# fusionpbx-ha: managed by fusionpbx-ha.sh (local changes will be overwritten)
$(cat "$HA_RES_DIR/fusionpbx-ha-auto-rejoin.service")
ARUNIT
        if [ -f "$_hibg_ar_unit" ] && cmp -s "$_hibg_ar_tmp" "$_hibg_ar_unit"; then
            rm -f "$_hibg_ar_tmp"
            verbose "  auto-rejoin unit up to date: $_hibg_ar_unit"
        else
            install -m 644 "$_hibg_ar_tmp" "$_hibg_ar_unit" 2>/dev/null || {
                rm -f "$_hibg_ar_tmp"
                warn "cannot write $_hibg_ar_unit - automatic rejoin unavailable"
                return 1
            }
            rm -f "$_hibg_ar_tmp"
            verbose "  auto-rejoin unit installed: $_hibg_ar_unit"
        fi
    fi
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable "$HA_AUTO_REJOIN_UNIT" >/dev/null 2>&1 \
        || warn "could not enable $HA_AUTO_REJOIN_UNIT - no boot-time automatic rejoin"
    return 0
}

# -----------------------------------------------------------------------------
# repmgr extension schema access (regression 0.3.3, stand feedback: 'init'
# step 7 dies with "permission denied for schema repmgr" / "нет доступа к
# схеме repmgr"). CREATE EXTENSION runs as the postgres SUPERUSER (local
# socket, peer auth), so the schema and every object the extension created
# belong to postgres. The repmgr role is a non-superuser BY DESIGN -> it
# cannot even USE the schema, and the first metadata query of any
# '* register' aborts. Fix, applied as superuser:
#   - the schema + the extension objects are handed to the repmgr role
#     (as if the role had created the extension itself)
#   - DML grants for the existing objects + ALTER DEFAULT PRIVILEGES for
#     objects a future 'ALTER EXTENSION UPDATE' may add (it runs as postgres)
#   - best-effort role grants for non-superuser operation elsewhere:
#       * pg_monitor - repmgrd polls pg_stat_replication on the primary
#       * EXECUTE on the pg_rewind file functions - '--repair' runs
#         pg_rewind as the repmgr role; these GRANTs are the documented
#         PostgreSQL 13+ non-superuser recipe
# Idempotent. Skipped on a standby (its metadata DB is a streaming copy of
# the primary's: the grants arrive via replication, and ALTERs are refused
# during recovery) and on a database without the extension yet.
# -----------------------------------------------------------------------------
ha_fix_repmgr_schema_access() {
    if [ "$(pg_runuser_psql -tAc "SELECT pg_is_in_recovery()" | tr -d ' \r')" = "t" ]; then
        verbose "  standby local DB - repmgr schema grants arrive via replication (nothing to do)"
        return 0
    fi
    if ! pg_runuser_psql -d "$HA_REPMGR_DB" -tAc "SELECT 1 FROM pg_extension WHERE extname='repmgr'" | grep -q 1; then
        return 0    # no extension in this database yet - nothing to fix
    fi

    # NOTE: unquoted heredoc on purpose - $HA_REPMGR_USER must expand (it
    # is a fixed alphanumeric constant), the DO dollar-tags are escaped
    _hfsa_sql="$(mktemp "${TMPDIR:-/tmp}/fpbx-ha-schema.XXXXXX")"
    cat >"$_hfsa_sql" <<HAFIX
-- fusionpbx-ha: repmgr extension ownership + grants (idempotent)
-- freeze-proofing (regression 0.3.17): never wait for a sync standby here -
-- the real bench hung on this very 'ALTER SCHEMA' with a stale
-- synchronous_standby_names from the previous cluster; the grants commit
-- locally and replicate as normal WAL traffic (belt-and-braces: the
-- step-level ha_clear_stale_sync_names runs before this block)
SET synchronous_commit = off;
ALTER SCHEMA repmgr OWNER TO $HA_REPMGR_USER;
GRANT USAGE, CREATE ON SCHEMA repmgr TO $HA_REPMGR_USER;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA repmgr TO $HA_REPMGR_USER;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA repmgr TO $HA_REPMGR_USER;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA repmgr TO $HA_REPMGR_USER;
ALTER DEFAULT PRIVILEGES IN SCHEMA repmgr GRANT ALL PRIVILEGES ON TABLES TO $HA_REPMGR_USER;
ALTER DEFAULT PRIVILEGES IN SCHEMA repmgr GRANT ALL PRIVILEGES ON SEQUENCES TO $HA_REPMGR_USER;
ALTER DEFAULT PRIVILEGES IN SCHEMA repmgr GRANT EXECUTE ON FUNCTIONS TO $HA_REPMGR_USER;
-- transfer the objects the extension already created (postgres -> repmgr);
-- per-object tolerance: the GRANTs above already cover DML, ownership is
-- belt-and-braces for the DDL paths
DO \$hfx\$
DECLARE r RECORD;
BEGIN
    FOR r IN
        SELECT c.relname, c.relkind
          FROM pg_class c
          JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = 'repmgr'
           AND c.relkind IN ('r', 'p', 'v', 'm', 'S')
    LOOP
        BEGIN
            IF r.relkind = 'S' THEN
                EXECUTE format('ALTER SEQUENCE repmgr.%I OWNER TO %I', r.relname, '$HA_REPMGR_USER');
            ELSE
                EXECUTE format('ALTER TABLE repmgr.%I OWNER TO %I', r.relname, '$HA_REPMGR_USER');
            END IF;
        EXCEPTION WHEN OTHERS THEN
            NULL;
        END;
    END LOOP;
END
\$hfx\$;
HAFIX
    # Feed the SQL via STDIN, never via '-f': on ALT the root session TMPDIR
    # is per-user private (pam_mktemp: /tmp/.private/root, mode 0700), and
    # psql runs as the postgres user - it cannot traverse root's private
    # directory, so '-f $TMPDIR_FILE' dies with 'Permission denied'
    # (regression 0.3.4). The redirect is opened by THIS root shell; psql
    # merely inherits the already-open file descriptor.
    # stderr is captured (NOT swallowed by pg_runuser_psql) so the FATAL
    # message quotes the actual psql error.
    _hfsa_err="$(mktemp "${TMPDIR:-/tmp}/fpbx-ha-schema-err.XXXXXX")"
    if ! runuser -u postgres -- psql -d "$HA_REPMGR_DB" -v ON_ERROR_STOP=1 \
            <"$_hfsa_sql" >"$_hfsa_err" 2>&1; then
        die "cannot apply the repmgr extension grants in $HA_REPMGR_DB
psql reported:
$(tail -n 8 "$_hfsa_err" | sed 's/^/  /')
The generated SQL is kept at $_hfsa_sql - inspect the error with:
  runuser -u postgres -- psql -d $HA_REPMGR_DB -v ON_ERROR_STOP=1 < $_hfsa_sql"
    fi
    rm -f "$_hfsa_sql" "$_hfsa_err"

    # best-effort role grants: silent on purpose (a changed signature in a
    # future PostgreSQL major must not block a registration); stdin for the
    # same per-user-TMPDIR reason as the hard block above.
    #
    # 0.3.31 forensics: the fixed-signature list never included pg_ls_dir -
    # and pg_rewind's very first step against the source server (building
    # the file list) died "permission denied for function pg_ls_dir" the
    # first time pg_rewind ever really executed (26.10 bench: 0.3.30 had
    # just fixed the TMPDIR wrapper failure that had been masking it; both
    # the boot auto-rejoin and the manual --repair failed on the grants).
    # Fixed-signature GRANTs are also fragile across PostgreSQL majors, so
    # the DO block below grants EVERY pg_catalog overload of the file
    # access functions pg_rewind/repmgr use, whatever the server major is.
    _hfsa_opt="$(mktemp "${TMPDIR:-/tmp}/fpbx-ha-schema-opt.XXXXXX")"
    cat >"$_hfsa_opt" <<HAFIX
-- freeze-proofing (regression 0.3.17): same as the hard block above - a
-- stale sync-standby wait must never block the installer (this block's
-- stderr is discarded, a hang here would be completely silent)
SET synchronous_commit = off;
GRANT pg_monitor TO $HA_REPMGR_USER;
-- non-superuser pg_rewind (the documented PG13+ recipe): the file list
-- comes from pg_ls_dir + pg_stat_file, block data via pg_read_binary_file,
-- the timeline history via pg_read_file. One DO block, every overload -
-- a missing EXECUTE only surfaces when a rejoin actually needs rewind,
-- which is exactly the worst possible moment (26.10).
DO \$hfw\$
DECLARE r RECORD;
BEGIN
    FOR r IN
        SELECT p.oid::regprocedure AS fn
          FROM pg_catalog.pg_proc p
         WHERE p.pronamespace = 'pg_catalog'::regnamespace
           AND p.proname IN ('pg_ls_dir',
                             'pg_stat_file',
                             'pg_read_file',
                             'pg_read_binary_file',
                             'pg_ls_waldir',
                             'pg_ls_archive_statusdir')
    LOOP
        BEGIN
            EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO $HA_REPMGR_USER', r.fn);
        EXCEPTION WHEN OTHERS THEN
            NULL;
        END;
    END LOOP;
END
\$hfw\$;
HAFIX
    pg_runuser_psql -d "$HA_REPMGR_DB" <"$_hfsa_opt" >/dev/null || true
    rm -f "$_hfsa_opt"

    verbose "  repmgr extension schema: ownership + grants handed to the $HA_REPMGR_USER role"
    verbose "  repmgr role: pg_monitor + pg_rewind EXECUTE grants (non-superuser operation)"
}

# -----------------------------------------------------------------------------
# Self-healing preamble for every '*register' step (DESIGN.md 7: a re-run of
# the SAME command must fix AND continue). Steps 4/6 may already be recorded
# as completed by an OLDER script version, so the register steps re-apply:
#   - the repmgr extension schema access (older versions left the schema
#     owned by postgres - regression 0.3.3)
#   - the pg_hba managed block (older versions wrote an incomplete set)
#   - listen_addresses (older versions never set it)
#   - repmgr.conf when it differs from the current template (legacy keys)
#   - the sudoers drop-in and promote.sh (data nodes only)
#   - the .pgpass (older versions wrote the witness copy in the unpack step,
#     BEFORE postgresql-server was installed - regression 0.3.7)
# Everything here is idempotent and a no-op on a healthy current-version node.
# -----------------------------------------------------------------------------
ha_register_prelude() {
    _hrp_role="$1"    # primary | standby | witness
    # the metadata DB must be usable by the repmgr role BEFORE any register:
    # without this the very first metadata query aborts with
    # "permission denied for schema repmgr" (regression 0.3.3)
    ha_fix_repmgr_schema_access
    case "$_hrp_role" in
        witness) ha_write_pgpass witness; ha_write_pg_hba witness ;;
        *)       ha_write_pgpass data; ha_write_pg_hba data; ha_install_sudoers; ha_install_promote_sh; ha_install_pg_boot_guard ;;
    esac
    systemctl reload "$HA_PG_SERVICE" 2>/dev/null \
        || pg_runuser_psql -c "SELECT pg_reload_conf();" >/dev/null 2>&1 || true
    # 0.3.16: NO repmgr preload convergence here. The prelude serves the
    # resume contract of the CURRENT version; the preload has exactly one
    # installer write point per role (init step 5 / witness join step 4 /
    # the standby clone) - nodes installed by an older version re-run
    # their install command instead of being silently repaired here.
    ha_ensure_pg_listen

    _hrp_tmp="$(mktemp "${TMPDIR:-/tmp}/fpbx-ha-repmgr.XXXXXX")"
    ( HA_REPMGR_CONF="$_hrp_tmp" ha_render_repmgr_conf "$_hrp_role" ) >/dev/null 2>&1 || true
    if [ -s "$_hrp_tmp" ]; then
        if ! cmp -s "$_hrp_tmp" "$HA_REPMGR_CONF" 2>/dev/null; then
            install -m 0640 "$_hrp_tmp" "$HA_REPMGR_CONF" || { rm -f "$_hrp_tmp"; die "cannot update $HA_REPMGR_CONF"; }
            chown root:postgres "$HA_REPMGR_CONF" 2>/dev/null || true
            verbose "  $HA_REPMGR_CONF re-rendered (on-disk copy was written by an older script version)"
        fi
    else
        warn "could not render a reference repmgr.conf - keeping the on-disk copy"
    fi
    rm -f "$_hrp_tmp"
}

# .pgpass for the postgres system user (repmgr + superuser + app credentials
# on the data nodes; repmgr only on the witness).
#
# The file lives next to PGDATA (the postgres system user's home) - taken
# from ha_pg_data_dir(), never hardcoded, so the sandbox tests resolve the
# same way as production. MUST be called only AFTER postgresql-server is
# installed: the witness has no layer 1 and /var/lib/pgsql appears only
# with the packages step, so writing .pgpass any earlier dies with an
# actionable message instead of bash's bare 'No such file or directory'
# (regression 0.3.7: the witness join used to write it in the unpack step).
ha_write_pgpass() {
    _hpw_dir="$(dirname "$(ha_pg_data_dir)")"
    _hpw_dir="${_hpw_dir%/}"
    _hpw_file="$_hpw_dir/.pgpass"
    _hpw_role="${1:-data}"       # data | witness
    [ -d "$_hpw_dir" ] || die "$_hpw_dir does not exist - postgresql-server is not installed yet.
The .pgpass can only be written after the packages step (regression 0.3.7:
the witness join used to write it in the unpack step, before the packages)."
    {
        echo "# fusionpbx-ha: managed block"
        if [ "$_hpw_role" = "witness" ]; then
            echo "$(ha_node_ip 1):$HA_PG_PORT:*:$HA_REPMGR_USER:$HA_REPMGR_PASSWORD"
            echo "$(ha_node_ip 2):$HA_PG_PORT:*:$HA_REPMGR_USER:$HA_REPMGR_PASSWORD"
        else
            echo "$(ha_node_ip 1):$HA_PG_PORT:*:$HA_REPMGR_USER:$HA_REPMGR_PASSWORD"
            echo "$(ha_node_ip 2):$HA_PG_PORT:*:$HA_REPMGR_USER:$HA_REPMGR_PASSWORD"
            echo "$(ha_node_ip 1):$HA_PG_PORT:*:postgres:$HA_DB_PASSWORD"
            echo "$(ha_node_ip 2):$HA_PG_PORT:*:postgres:$HA_DB_PASSWORD"
            echo "$(ha_node_ip 1):$HA_PG_PORT:*:$HA_DB_USER:$HA_DB_PASSWORD"
            echo "$(ha_node_ip 2):$HA_PG_PORT:*:$HA_DB_USER:$HA_DB_PASSWORD"
        fi
    } > "$_hpw_file" 2>/dev/null || die "cannot write $_hpw_file"
    chown postgres:postgres "$_hpw_file" 2>/dev/null || true
    chmod 600 "$_hpw_file"
    verbose "  .pgpass written: $_hpw_file (role: $_hpw_role)"
}

# pg_hba.conf managed block (DESIGN.md 14.3 + postgres-user lines for remote
# synchronous_standby_names management). Idempotent via managed markers.
#
# The block must be SYMMETRIC for node 1 and node 2: pg_hba.conf lives inside
# PGDATA, so the standby's clone inherits node 1's file verbatim - and after
# a failover the roles swap (a repaired node 1 streams from node 2, node 1's
# repmgrd registers through its own IP). Self-access lines (the node's own IP)
# are required because 'repmgr primary register', repmgrd (conninfo carries
# the node IP) and the local haproxy all connect to the node IP, not to
# 127.0.0.1 - the source address of such loopback-via-IP connections is the
# node IP itself (regression 0.3.2).
ha_write_pg_hba() {
    _hph_hba="$(ha_pg_data_dir)/pg_hba.conf"
    [ -f "$_hph_hba" ] || die "pg_hba.conf not found at $_hph_hba (is PostgreSQL initialized?)"
    _hph_role="${1:-data}"
    if [ "$_hph_role" = "witness" ]; then
        _hph_content="host repmgr  repmgr  $(ha_node_ip 1)/32  md5
host repmgr  repmgr  $(ha_node_ip 2)/32  md5
host repmgr  repmgr  $(ha_node_ip 3)/32  md5"
    else
        _hph_content="host repmgr       repmgr     $(ha_node_ip 1)/32  md5
host repmgr       repmgr     $(ha_node_ip 2)/32  md5
host repmgr       repmgr     $(ha_node_ip 3)/32  md5
host replication  repmgr     $(ha_node_ip 1)/32  md5
host replication  repmgr     $(ha_node_ip 2)/32  md5
host fusionpbx    fusionpbx  $(ha_node_ip 1)/32  md5
host fusionpbx    fusionpbx  $(ha_node_ip 2)/32  md5
host postgres     postgres   $(ha_node_ip 1)/32  md5
host postgres     postgres   $(ha_node_ip 2)/32  md5"
    fi
    ha_block_set "$_hph_hba" "$_hph_content"
    chmod 640 "$_hph_hba" 2>/dev/null || true
    chown postgres:postgres "$_hph_hba" 2>/dev/null || true
    verbose "  pg_hba.conf: managed block updated (role: $_hph_role)"
}

# =============================================================================
# repmgr helpers
# =============================================================================

# synchronous_commit=off (regression 0.3.17): '* register' writes cluster
# metadata on the primary (possibly over TCP from the witness/standby join
# flow while the primary still waits for its own standby) - the same
# freeze-proofing as pg_runuser_psql
#
# TMPDIR=/tmp (0.3.30): a root PAM session on ALT gets a PRIVATE per-user
# tmpdir (pam_mktemp: /tmp/.private/root, 0700 - the 0.3.4 precedent), and
# runuser (no -l) keeps the environment - so repmgr, already running as
# postgres, inherited root's TMPDIR. Its local_command() helper (repmgr 5.5
# sysutils.c) captures child stderr via mkstemp("$TMPDIR/repmgr_command.
# XXXXXX"), which fails EACCES inside root's 0700 directory, and repmgr
# reports only "unable to open temporary file" - 'node rejoin
# --force-rewind' died BEFORE pg_rewind was ever executed (22.10 and 26.10,
# both times a manual --repair over SSH; the output capture was empty -
# hence the bare "ERROR:" lines with no text). Force the world-writable
# /tmp: every local_command consumer inside one repmgr process (pg_rewind,
# the rejoin's own pg_ctl restarts) then works under any login policy.
# The systemd-started units see no PAM and were never affected.
repmgr_cmd() {
    TMPDIR=/tmp PGOPTIONS='-c synchronous_commit=off' \
        runuser -u postgres -- repmgr -f "$HA_REPMGR_CONF" "$@" 2>&1
}

# 0.3.33: strip password= from the repmgr metadata (repmgr.nodes.conninfo
# and repmgr.events.details). repmgr prints node conninfo verbatim (the
# WARNING "unable to ping ..." lines, and the "pg_rewind command is ..."
# DETAIL is built from the PEER's node record), so every record registered
# by an older version carries the plaintext password into the console,
# repmgrd.log and the journal. The rendered conninfo is passwordless since
# 0.3.33 (see repmgr.conf.tpl), but the DB records outlive config
# re-renders - and the metadata DB is REPLICATED, so one write on the
# primary heals every node's copy (the witness re-copies them on its next
# register --force). The local UPDATE silently no-ops on a standby
# (read-only) and the peer UPDATE silently no-ops when the peer is down:
# between the two, whichever node is the primary gets cleaned. Idempotent;
# called after every register/rejoin/repair convergence point.
ha_scrub_conninfo_secrets() {
    _hsc_sql_nodes="UPDATE repmgr.nodes SET conninfo = regexp_replace(conninfo, '[[:space:]]*password=[^[:space:]]*', '', 'g') WHERE conninfo LIKE '%password=%'"
    _hsc_sql_events="UPDATE repmgr.events SET details = regexp_replace(details, 'password=[^[:space:]]*', 'password=***', 'g') WHERE details LIKE '%password=%'"
    pg_runuser_psql -d "$HA_REPMGR_DB" -c "$_hsc_sql_nodes" >/dev/null 2>&1 || true
    pg_runuser_psql -d "$HA_REPMGR_DB" -c "$_hsc_sql_events" >/dev/null 2>&1 || true
    pg_psql_superuser "$(ha_peer_ip)" -d "$HA_REPMGR_DB" -c "$_hsc_sql_nodes" >/dev/null 2>&1 || true
    pg_psql_superuser "$(ha_peer_ip)" -d "$HA_REPMGR_DB" -c "$_hsc_sql_events" >/dev/null 2>&1 || true
}

# soft cross-node reachability probe: pg_isready when available, silence
# otherwise. On failure HA_PG_ISREADY_MSG carries the tool verdict
# ("no response" vs "rejecting connections") so the die-messages can tell
# a firewall drop from a starting/shutting-down server (regression 0.3.6)
ha_pg_isready() {
    _hpr_ip="$1"
    HA_PG_ISREADY_MSG=""
    if cmd_exists pg_isready; then
        _hpr_out="$(pg_isready -h "$_hpr_ip" -p "$HA_PG_PORT" -t 3 2>&1)"
        _hpr_rc=$?
        if [ "$_hpr_rc" = "0" ]; then
            return 0
        fi
        HA_PG_ISREADY_MSG="${_hpr_out:-pg_isready exited with code $_hpr_rc}"
        return "$_hpr_rc"
    fi
    warn "pg_isready not available - skipping the reachability check for $_hpr_ip"
    return 0
}

# role-agent probe: 200 = node is primary, 503 = standby/down, 000 = unreachable
ha_agent_code() {
    _hac_ip="$1"
    _hac_code="$(curl --noproxy '*' -s -o /dev/null -w '%{http_code}' --max-time 3 \
        "http://${_hac_ip}:${HA_AGENT_PORT}/primary" 2>/dev/null)"
    # '-w %{http_code}' already prints 000 when curl fails; the old
    # '|| echo 000' appended a SECOND one (000\n000 -> '000000' in messages)
    [ -n "$_hac_code" ] || _hac_code=000
    echo "$_hac_code"
}

# =============================================================================
# Rendered config writers (thin wrappers used by the step functions)
# =============================================================================

ha_write_etc_hosts_block() {
    [ -f "$HA_HOSTS_FILE" ] || die "$HA_HOSTS_FILE not found"
    _heh_content="$(ha_node_ip 1) $(ha_node_name 1)
$(ha_node_ip 2) $(ha_node_name 2)
$(ha_node_ip 3) $(ha_node_name 3)"
    ha_block_set "$HA_HOSTS_FILE" "$_heh_content"
    verbose "  $HA_HOSTS_FILE: cluster names added"
}

# Media sync dir (regression 0.3.11): layer 1 never creates
# /var/lib/freeswitch/storage (it only prepares recordings/), so this
# script is its only creator - and the standby's media seed (join step 9)
# reads it through rrsync on the primary the MOMENT it starts streaming,
# which on the real bench raced ahead of init step 14 (the old creator):
# rrsync died 'post-realpath open failed (race detected): ... No such file
# or directory' (the hardened ALT rrsync refuses a missing sender dir).
# Ensure it EARLY (init step 6, before the primary register - no standby
# can seed before it can clone) and at every consumer. Also sets the
# FreeSWITCH runtime ownership (angie on this ALT port - layer-1
# config.sh fs_user; overridable via HA_SYNC_DIR_OWNER): a root:root
# media dir would silently break voicemail/fax/recording writes.
ha_ensure_sync_dir() {
    mkdir -p "$HA_SYNC_DIR" 2>/dev/null || die "cannot create $HA_SYNC_DIR"
    chown "${HA_SYNC_DIR_OWNER:-angie:angie}" "$HA_SYNC_DIR" 2>/dev/null \
        || warn "cannot chown $HA_SYNC_DIR to ${HA_SYNC_DIR_OWNER:-angie:angie} - set HA_SYNC_DIR_OWNER if this port uses a different FreeSWITCH user"
}

# 0.3.23: the standby media-seed pull, WITH RETRIES. The peer-side rrsync
# (upstream rsync 3.2.7 'lock_or_die') takes an EXCLUSIVE NON-BLOCKING
# flock ON THE SYNC DIRECTORY ITSELF - any other LIVE rrsync instance for
# that directory (a hung leftover of an interrupted sync session: node
# crashes/reboots mid-transfer, killed lsyncd with its ssh session stuck)
# makes the new instance die 'Another instance of rrsync is already
# accessing this directory' and rsync exits 13. The flock is held by the
# PROCESS, not by a lock file: it dies with its owner - retries ride out
# transient holders (sshd eventually reaps its hung child - exactly how
# the bench recovered between two repair runs), and the die message
# points at a hung one. The rrsync '-no-lock' flag exists but is
# deliberately NOT used: the lock also protects the mirror from
# overlapping writers.
# The remote spec stays the BARE DOT - the only client form valid on
# every hardened rrsync variant ('.' = CWD = the peer's restricted tree
# root; ':/' dies 'unsafe arg' on the ALT build, the absolute form
# doubles into a nested dir and dies ENOENT - the 0.3.11/0.3.12/0.3.13
# bench deaths, DESIGN.md 6.3).
ha_seed_pull() {
    _hsp_peer_ip="$1"
    _hsp_attempts="${HA_SEED_ATTEMPTS:-5}"
    _hsp_sleep="${HA_SEED_RETRY_SLEEP:-15}"
    _hsp_n=0
    while [ "$_hsp_n" -lt "$_hsp_attempts" ]; do
        _hsp_n=$((_hsp_n + 1))
        _hsp_out="$(rsync -a --delete \
            -e "ssh -i $HA_SYNC_KEY -o UserKnownHostsFile=$HA_KNOWN_HOSTS -o StrictHostKeyChecking=accept-new -o BatchMode=yes" \
            "root@${_hsp_peer_ip}:." "$HA_SYNC_DIR/" 2>&1)"
        if [ $? -eq 0 ]; then
            if [ "$_hsp_n" -gt 1 ]; then
                verbose "  seed succeeded on attempt $_hsp_n/$_hsp_attempts"
            fi
            return 0
        fi
        [ -n "$_hsp_out" ] && echo "$_hsp_out"
        if printf '%s\n' "$_hsp_out" | grep -q 'Another instance of rrsync'; then
            warn "the peer's media directory is locked by another rrsync instance (attempt $_hsp_n/$_hsp_attempts)"
            if [ "$_hsp_n" -lt "$_hsp_attempts" ]; then
                verbose "  a hung rrsync process on $_hsp_peer_ip may be holding the lock - the lock dies with the process"
            fi
        fi
        if [ "$_hsp_n" -lt "$_hsp_attempts" ]; then
            verbose "  retrying in ${_hsp_sleep}s ..."
            sleep "$_hsp_sleep"
        fi
    done
    die "media seed failed after $_hsp_attempts attempts - the pull needs sshd up on $_hsp_peer_ip, the sync
key in root's authorized_keys there (rrsync-restricted root: $HA_SYNC_DIR),
that dir existing on the peer and no other rrsync instance holding its lock
(hint: 'fusionpbx-ha.sh --doctor' on $_hsp_peer_ip diagnoses the peer; on
'Another instance of rrsync' a hung rrsync process on $_hsp_peer_ip holds the
lock - 'ps ax | grep rrsync' there shows it, kill the stale instance and the
lock dies with it; if the key is rejected: journalctl -u sshd -n 20 on
$_hsp_peer_ip shows 'invalid key option string' - re-run that node's join
command to re-render the sync-key line)"
}

ha_write_authorized_keys() {
    _hak_sshdir="${HA_SYNC_SSH_DIR:-/root/.ssh}"
    mkdir -p "$_hak_sshdir"
    chmod 700 "$_hak_sshdir" 2>/dev/null || true
    touch "$_hak_sshdir/authorized_keys"
    # Purge ANY line outside the managed block that carries the sync key
    # (0.3.13): a line left by an older script version or an interrupted
    # write can be unparseable for sshd - the peer's rsync/lsyncd pushes
    # are then rejected preauth ('invalid key option string' in its sshd
    # log). The key blob is unique to this cluster; the fresh line is
    # re-added below inside the managed block.
    _hak_keyblob="$(printf '%s' "$HA_SYNC_PUBLIC_KEY" | awk '{print $2}')"
    [ -n "$_hak_keyblob" ] \
        && sed -i "\|${_hak_keyblob}|d" "$_hak_sshdir/authorized_keys" 2>/dev/null
    _hak_rrsync="$(ha_install_rrsync)"
    if [ -n "$_hak_rrsync" ]; then
        _hak_restrict="from=\"$(ha_node_ip 1),$(ha_node_ip 2)\",command=\"$_hak_rrsync $HA_SYNC_DIR\",no-pty,no-agent-forwarding,no-X11-forwarding,no-port-forwarding"
    else
        warn "rrsync not found - sync key restricted by source IP only (no forced command)"
        _hak_restrict="from=\"$(ha_node_ip 1),$(ha_node_ip 2)\",no-pty,no-agent-forwarding,no-X11-forwarding,no-port-forwarding"
    fi
    _hak_content="$_hak_restrict $HA_SYNC_PUBLIC_KEY"
    ha_block_set "$_hak_sshdir/authorized_keys" "$_hak_content"
    chmod 600 "$_hak_sshdir/authorized_keys"
    verbose "  authorized_keys: sync key installed (rrsync: ${_hak_rrsync:-none})"
}

ha_render_repmgr_conf() {
    _hrc_role="$1"    # primary | standby | witness
    _hrc_promote=""
    _hrc_follow=""
    _hrc_conninfo_extra=""
    _hrc_failover="manual"
    if [ "$_hrc_role" = "standby" ]; then
        _hrc_failover="automatic"
        _hrc_conninfo_extra=" application_name=$(ha_node_name "$HA_NODE_ID")"
        _hrc_promote="promote_command='$HA_PROMOTE_SH'"
        _hrc_follow="follow_command='/usr/bin/repmgr standby follow -f $HA_REPMGR_CONF --upstream-node-id=%n'"
    fi
    ha_render "$HA_RES_DIR/repmgr.conf.tpl" "$HA_REPMGR_CONF" \
        "NODE_ID=$HA_NODE_ID" \
        "NODE_NAME=$(ha_node_name "$HA_NODE_ID")" \
        "NODE_IP=$(ha_node_ip "$HA_NODE_ID")" \
        "PG_PORT=$HA_PG_PORT" \
        "REPMGR_USER=$HA_REPMGR_USER" \
        "REPMGR_DB=$HA_REPMGR_DB" \
        "REPMGR_PASSWORD=$HA_REPMGR_PASSWORD" \
        "CONNINFO_EXTRA=$_hrc_conninfo_extra" \
        "PGDATA=$(ha_pg_data_dir)" \
        "FAILOVER_MODE=$_hrc_failover" \
        "PROMOTE_LINE=$_hrc_promote" \
        "FOLLOW_LINE=$_hrc_follow"
    chown root:postgres "$HA_REPMGR_CONF" 2>/dev/null || true
    chmod 640 "$HA_REPMGR_CONF"
}

ha_render_haproxy_conf() {
    mkdir -p "$HA_HAPROXY_CONF_D" 2>/dev/null || die "cannot create $HA_HAPROXY_CONF_D"
    ha_render "$HA_RES_DIR/haproxy.cfg.tpl" "$HA_HAPROXY_CONF" \
        "HAPROXY_PORT=$HA_HAPROXY_PORT" \
        "AGENT_PORT=$HA_AGENT_PORT" \
        "NODE1_NAME=$(ha_node_name 1)" \
        "NODE1_IP=$(ha_node_ip 1)" \
        "NODE2_NAME=$(ha_node_name 2)" \
        "NODE2_IP=$(ha_node_ip 2)"
    verbose "  haproxy fragment written: $HA_HAPROXY_CONF"
}

ha_render_lsyncd_conf() {
    _hlc_peer_ip="$1"
    ha_render "$HA_RES_DIR/lsyncd.conf.lua.tpl" "$HA_LSYNCD_CONF" \
        "SYNC_DIR=$HA_SYNC_DIR" \
        "SYNC_DELAY=$HA_SYNC_DELAY" \
        "PEER_IP=$_hlc_peer_ip"
    verbose "  lsyncd configuration written: $HA_LSYNCD_CONF (peer: $_hlc_peer_ip)"
}

# 0 = the local role-agent answers (200 primary / 503 standby)
ha_agent_ready() {
    case "$(ha_agent_code 127.0.0.1)" in
        200|503) return 0 ;;
    esac
    return 1
}

ha_install_agent() {
    mkdir -p "$HA_LIB_DIR" 2>/dev/null || die "cannot create $HA_LIB_DIR"
    install -m 0755 "$HA_RES_DIR/role-agent.py" "$HA_AGENT_SCRIPT" || die "cannot install role-agent.py"
    install -m 0755 "$HA_RES_DIR/fusionpbx-ha-agent.service" \
        "$HA_SYSTEMD_DIR/${HA_AGENT_UNIT_NAME}.service" \
        || die "cannot install the agent systemd unit"
    systemctl daemon-reload 2>/dev/null || true
    svc_enable_start "$HA_AGENT_UNIT_NAME"
    # The unit is Type=simple: systemd counts it started the moment python3
    # is exec'd, but the socket appears only after the interpreter imports
    # its modules - a second or two on a modest VM. The single immediate
    # probe lost that race on the real bench (regression 0.3.5); wait for
    # the socket instead (fast 1s polls, HA_AGENT_WAIT overrides).
    if ! ha_wait "the role-agent socket on 127.0.0.1:$HA_AGENT_PORT" \
            "$HA_AGENT_WAIT" ha_agent_ready 1; then
        die "role-agent is not answering on 127.0.0.1:$HA_AGENT_PORT (code: $(ha_agent_code 127.0.0.1))
inspect the unit:  systemctl status $HA_AGENT_UNIT_NAME -n 30 --no-pager"
    fi
    verbose "  role-agent is answering (HTTP $(ha_agent_code 127.0.0.1))"
}

ha_install_promote_sh() {
    mkdir -p "$HA_LIB_DIR" 2>/dev/null
    # 0.3.24: after a successful promote the wrapper restarts the local
    # applications - their sockets to the hard-powered-off peer die
    # WITHOUT TCP RST and hang retransmitting for tcp_retries2 (~15-30
    # minutes; the bench failover: promote OK in 30s, but an endless
    # web-UI spinner and 'sip: auth' phones until the apps were
    # restarted). Render the concrete service list - the php-fpm unit
    # name is port-specific (detected the same way ha_repoint_dsn does).
    _hips_apps="angie freeswitch"
    _hips_php="$(ha_detect_php_fpm)"
    [ -n "$_hips_php" ] && _hips_apps="$_hips_php $_hips_apps"
    ha_render "$HA_RES_DIR/promote.sh.tpl" "$HA_PROMOTE_SH" \
        "APP_SERVICES=$_hips_apps"
    chmod 0755 "$HA_PROMOTE_SH" 2>/dev/null || true
    verbose "  promote wrapper installed: $HA_PROMOTE_SH (post-promote app restart: $_hips_apps)"
}

# =============================================================================
# DSN repointing: switch FusionPBX + FreeSWITCH to 127.0.0.1:<haproxy port>
# =============================================================================

ha_repoint_dsn() {
    # 1. /etc/fusionpbx/config.conf: rewrite the database.0/1 lines from
    #    cluster.conf (on a joined standby the LOCAL layer-1 credentials are
    #    stale - the cluster ones came with the token).
    [ -f "$HA_L1_CONF" ] || die "$HA_L1_CONF not found (layer 1 not installed?)"
    cp -a "$HA_L1_CONF" "${HA_L1_CONF}.pre-ha.bak" 2>/dev/null || true
    sed -i \
        -e "s|^database\.0\.host *=.*|database.0.host = 127.0.0.1|" \
        -e "s|^database\.0\.port *=.*|database.0.port = $HA_HAPROXY_PORT|" \
        -e "s|^database\.0\.name *=.*|database.0.name = $HA_DB_NAME|" \
        -e "s|^database\.0\.username *=.*|database.0.username = $HA_DB_USER|" \
        -e "s|^database\.0\.password *=.*|database.0.password = $HA_DB_PASSWORD|" \
        -e "s|^database\.1\.host *=.*|database.1.host = 127.0.0.1|" \
        -e "s|^database\.1\.port *=.*|database.1.port = $HA_HAPROXY_PORT|" \
        -e "s|^database\.1\.name *=.*|database.1.name = $HA_DB_NAME|" \
        -e "s|^database\.1\.username *=.*|database.1.username = $HA_DB_USER|" \
        -e "s|^database\.1\.password *=.*|database.1.password = $HA_DB_PASSWORD|" \
        "$HA_L1_CONF" || die "cannot rewrite $HA_L1_CONF"
    verbose "  $HA_L1_CONF: applications now use 127.0.0.1:$HA_HAPROXY_PORT"

    # 2. web copy (finish.sh keeps it in sync with /etc - preserve that)
    if [ -d "$(dirname "$HA_L1_WEB_CONF")" ]; then
        cp "$HA_L1_CONF" "$HA_L1_WEB_CONF" 2>/dev/null \
            && verbose "  web copy synced: $HA_L1_WEB_CONF"
    fi

    # 3. FreeSWITCH vars.xml DSN lines
    _hrd_dsn="pgsql://hostaddr=127.0.0.1 port=$HA_HAPROXY_PORT dbname=$HA_DB_NAME user=$HA_DB_USER password=$HA_DB_PASSWORD options="
    if [ -f "$HA_VARS_XML" ]; then
        if grep -q 'data="dsn_system=' "$HA_VARS_XML" 2>/dev/null; then
            sed -i \
                -e "s|data=\"dsn_system=[^\"]*|data=\"dsn_system=$_hrd_dsn|" \
                -e "s|data=\"dsn=[^\"]*|data=\"dsn=$_hrd_dsn|" \
                -e "s|data=\"dsn_callcenter=[^\"]*|data=\"dsn_callcenter=$_hrd_dsn|" \
                "$HA_VARS_XML" || die "cannot rewrite DSN lines in $HA_VARS_XML"
        else
            {
                echo ""
                echo "<!-- DSN -->"
                echo "<X-PRE-PROCESS cmd=\"set\" data=\"dsn_system=$_hrd_dsn\" />"
                echo "<X-PRE-PROCESS cmd=\"set\" data=\"dsn=$_hrd_dsn\" />"
                echo "<X-PRE-PROCESS cmd=\"set\" data=\"dsn_callcenter=$_hrd_dsn\" />"
            } >> "$HA_VARS_XML"
        fi
        verbose "  $HA_VARS_XML: DSN lines repointed"
    else
        warn "$HA_VARS_XML not found - FreeSWITCH DSN left unchanged"
    fi

    # 4. v_vars in the database (only writable on the primary; a joined
    #    standby already carries correct values from the clone)
    if ha_local_is_primary; then
        pg_runuser_psql -d "$HA_DB_NAME" -c \
            "UPDATE v_vars SET var_value='$_hrd_dsn' WHERE var_name IN ('dsn_system','dsn','dsn_callcenter');" \
            >/dev/null 2>&1 \
            && verbose "  v_vars: DSN variables updated" \
            || warn "v_vars DSN update failed (table missing?)"
    else
        verbose "  v_vars: skipped (standby - values arrive with the clone)"
    fi

    # 5. cache flush
    rm -rf /var/cache/fusionpbx/* 2>/dev/null || true

    # 6. restart the consumers
    _hrd_php="$(ha_detect_php_fpm)"
    [ -n "$_hrd_php" ] && systemctl restart "$_hrd_php" 2>/dev/null \
        && verbose "  restarted: $_hrd_php"
    systemctl restart angie 2>/dev/null && verbose "  restarted: angie"
    if svc_active freeswitch 2>/dev/null || [ -d /etc/freeswitch ]; then
        systemctl restart freeswitch 2>/dev/null && verbose "  restarted: freeswitch"
    fi

    # 7. smoke test through the shared entry point
    _hrd_try=0
    while [ "$_hrd_try" -lt 5 ]; do
        if [ "$(pg_psql_app 127.0.0.1 -p "$HA_HAPROXY_PORT" -tAc "SELECT 1" 2>/dev/null | tr -d ' \r')" = "1" ]; then
            verbose "  smoke test OK: SELECT 1 via 127.0.0.1:$HA_HAPROXY_PORT"
            return 0
        fi
        _hrd_try=$((_hrd_try + 1))
        sleep 2
    done
    die "smoke test failed: cannot query the database via 127.0.0.1:$HA_HAPROXY_PORT
Check: systemctl status haproxy $HA_AGENT_UNIT_NAME; journalctl -u haproxy -n 30"
}

ha_detect_php_fpm() {
    for _hdp in /usr/lib/systemd/system/php*-fpm.service /etc/systemd/system/php*-fpm.service; do
        [ -f "$_hdp" ] && { basename "$_hdp" .service; return 0; }
    done
    echo ""
}

# =============================================================================
# Synchronous replication management (DESIGN.md changelog 0.3)
#
# ha_sync_names_gucval <raw-name> - raw standby names ('fpbx-ha-2') are NOT
#   valid synchronous_standby_names values (regression 0.3.10): the
#   parameter has its own grammar where an unquoted identifier must not
#   contain '-' (the real bench: ALTER SYSTEM refused it with "syntax
#   error at or near \"-\""), and the 0.3.9 direct-edit fallback then left
#   an INVALID line in postgresql.auto.conf - the server would have
#   refused to RESTART. A hyphenated name must be double-quoted INSIDE the
#   value: '"fpbx-ha-2"'. Plain identifiers, '' (async clear) and '*'
#   (any standby - the historical B2 wildcard; nothing has produced it
#   since 0.3.27, the primitive keeps passing it through untouched).
#
# ha_sync_names_write <host> <value-or-empty> - the ONLY writer for
# synchronous_standby_names (regression 0.3.9):
#   1. ALTER SYSTEM (server-side, clean);
#   2. when the server refuses it - a DIRECT postgresql.auto.conf edit +
#      reload for host=local (root restores the ownership; the standby
#      branch of ha_ensure_pg_listen uses the same file-edit precedent);
#   3. a remote host has no shared FS - die, QUOTING the captured psql
#      stderr (the 0.3.4 lesson: a hard-fail path must never swallow the
#      reason - the real bench died with a bare 'cannot set ... on local').
# All three paths carry the GUC form produced by ha_sync_names_gucval.
#
# ha_ensure_sync <primary-host|local>:
#   - a streaming standby exists  -> synchronous_standby_names='<standby
#     node name>' (double-quoted by ha_sync_names_gucval when it contains
#     '-'), verify sync_state=sync; a NAME MISMATCH falls back to ASYNC
#     ('' - 0.3.27, design question B2 resolved: the old '*' wildcard
#     froze every commit the moment that oddly-named standby
#     disconnected - '' can never freeze a commit)
#   - no streaming standby        -> synchronous_standby_names='' (async:
#     writes continue; DESIGN.md 11.1 "async until the standby returns")
# =============================================================================

# Raw standby name -> GUC-safe synchronous_standby_names value (0.3.10):
# the parameter grammar does not accept unquoted hyphens, so 'fpbx-ha-2'
# must become "fpbx-ha-2" (double quotes INSIDE the value). '' and '*' are
# complete values of their own - quoting them would change the meaning
# ('"*"' would be a NAME, not the any-standby wildcard).
ha_sync_names_gucval() {
    _hsg_raw="$1"
    case "$_hsg_raw" in
        ''|'*') printf '%s\n' "$_hsg_raw"; return 0 ;;
    esac
    if printf '%s\n' "$_hsg_raw" | grep -Eq '^[A-Za-z_][A-Za-z0-9_]*$'; then
        printf '%s\n' "$_hsg_raw"
    else
        printf '"%s"\n' "$_hsg_raw"
    fi
}

ha_sync_names_write() {
    _hsw_host="$1"
    _hsw_value="$2"
    _hsw_what="set"
    [ -n "$_hsw_value" ] || _hsw_what="clear"
    # the GUC grammar form (regression 0.3.10): fpbx-ha-2 -> "fpbx-ha-2"
    _hsw_gucval="$(ha_sync_names_gucval "$_hsw_value")"
    _hsw_err="$(mktemp "${TMPDIR:-/tmp}/fpbx-ha-syncnames.XXXXXX")"

    # 1. primary path: ALTER SYSTEM, stderr captured (never swallowed)
    if [ "$_hsw_host" = "local" ]; then
        runuser -u postgres -- psql -c \
            "ALTER SYSTEM SET synchronous_standby_names = '${_hsw_gucval}';" \
            >/dev/null 2>"$_hsw_err"
        _hsw_rc=$?
    else
        PGPASSWORD="$HA_DB_PASSWORD" psql -h "$_hsw_host" -p "$HA_PG_PORT" \
            -U postgres -c \
            "ALTER SYSTEM SET synchronous_standby_names = '${_hsw_gucval}';" \
            >/dev/null 2>"$_hsw_err"
        _hsw_rc=$?
    fi
    if [ "$_hsw_rc" -eq 0 ]; then
        rm -f "$_hsw_err"
        pg_psql_superuser "$_hsw_host" -c "SELECT pg_reload_conf();" >/dev/null 2>&1 || true
        return 0
    fi

    # 2. the server refused ALTER SYSTEM: write the file directly (local
    #    only - a remote host has no shared filesystem with us)
    if [ "$_hsw_host" != "local" ]; then
        die "cannot $_hsw_what synchronous_standby_names on $_hsw_host
psql reported:
$(tail -n 8 "$_hsw_err" | sed 's/^/  /')"
    fi
    warn "ALTER SYSTEM was refused - writing postgresql.auto.conf directly"
    _hsw_auto="$(ha_pg_data_dir)/postgresql.auto.conf"
    if ! touch "$_hsw_auto" 2>/dev/null; then
        die "cannot $_hsw_what synchronous_standby_names on local: ALTER SYSTEM was refused and $_hsw_auto is not writable
ALTER SYSTEM reported:
$(tail -n 8 "$_hsw_err" | sed 's/^/  /')"
    fi
    chown postgres:postgres "$_hsw_auto" 2>/dev/null || true
    chmod 600 "$_hsw_auto" 2>/dev/null || true
    sed -i '/^[[:space:]]*synchronous_standby_names[[:space:]]*=/d' "$_hsw_auto" 2>/dev/null
    [ -n "$_hsw_value" ] && echo "synchronous_standby_names = '${_hsw_gucval}'" >> "$_hsw_auto"
    pg_runuser_psql -c "SELECT pg_reload_conf();" >/dev/null 2>&1 || true

    # the reload is asynchronous: confirm SHOW reflects the new value
    _hsw_try=0
    while [ "$_hsw_try" -lt 5 ]; do
        _hsw_cur="$(pg_runuser_psql -tAc "SHOW synchronous_standby_names" 2>/dev/null | tr -d ' \r')"
        if [ "$_hsw_cur" = "$_hsw_gucval" ]; then
            rm -f "$_hsw_err"
            return 0
        fi
        _hsw_try=$((_hsw_try + 1))
        sleep 1
    done
    die "cannot $_hsw_what synchronous_standby_names on local: the direct postgresql.auto.conf edit did not take effect
The file: $_hsw_auto
ALTER SYSTEM reported:
$(tail -n 8 "$_hsw_err" | sed 's/^/  /')
Hint: runuser -u postgres -- psql -c 'SHOW synchronous_standby_names'; check the PostgreSQL log"
}

# ha_clear_stale_sync_names (regression 0.3.17): the installer's own
# precondition before its FIRST database write (init steps 4, 7, 10).
# A synchronous_standby_names left over from a PREVIOUS cluster survives
# steps 1-6 in postgresql.auto.conf (nothing clears it before step 13!),
# and the moment its standby is gone - the old walreceiver holds the
# connection until step 4 changes the repmgr role password and step 5
# restarts PostgreSQL; the reconnect then fails auth with the OLD password
# - EVERY commit on the primary freezes forever waiting for a sync standby
# that will never come back (the new one joins only at step 12). The real
# bench hung exactly here: the schema-grants psql of step 7 sat on
# 'ALTER SCHEMA', and the Ctrl-C trace showed 'canceling wait for
# synchronous replication ... The transaction has already committed
# locally'. Same policy as ha_ensure_sync (DESIGN.md 11.1 "async until the
# standby returns") applied BEFORE the installer writes instead of after
# them; step 13 re-enables sync once the new standby streams.
# No-op on a clean node (names empty), whenever a standby IS streaming
# (its acks keep every commit moving) and on a standby / unreachable PG
# (the caller's own writes produce their own, clearer, error).
ha_clear_stale_sync_names() {
    [ "$(pg_runuser_psql -tAc "SELECT pg_is_in_recovery()" | tr -d ' \r')" = "t" ] && return 0
    _hcssn_cur="$(pg_runuser_psql -tAc "SHOW synchronous_standby_names" | tr -d ' \r')"
    [ -n "$_hcssn_cur" ] || return 0
    if [ -n "$(pg_runuser_psql -tAc \
        "SELECT application_name FROM pg_stat_replication WHERE state='streaming'" \
        | tr -d ' \r' | grep -v '^$')" ]; then
        return 0    # a live standby keeps acking sync commits - writes flow
    fi
    verbose "  stale synchronous_standby_names='$_hcssn_cur' with no streaming standby -"
    verbose "  every commit on this primary would freeze (a leftover from the previous"
    verbose "  cluster); clearing it for the install - step 13 re-enables sync once the"
    verbose "  new standby streams"
    ha_sync_names_write local ""
    # the reload is asynchronous: the clear MUST take effect before the
    # step's writes start, otherwise they freeze on the stale value
    _hcssn_try=0
    while [ "$_hcssn_try" -lt 5 ]; do
        [ -z "$(pg_runuser_psql -tAc "SHOW synchronous_standby_names" | tr -d ' \r')" ] && return 0
        _hcssn_try=$((_hcssn_try + 1))
        sleep 1
    done
    die "cannot clear the stale synchronous_standby_names (still set after the reload)
Hint: runuser -u postgres -- psql -c 'SHOW synchronous_standby_names'; check the PostgreSQL log"
}

ha_ensure_sync() {
    _hes_host="$1"
    _hes_names="$(pg_psql_superuser "$_hes_host" -tAc \
        "SELECT application_name FROM pg_stat_replication WHERE state='streaming'" \
        | tr -d ' \r' | grep -v '^$')"
    if [ -z "$_hes_names" ]; then
        ha_sync_names_write "$_hes_host" ""
        verbose "  sync mode: OFF on $_hes_host (no streaming standby - async until it returns)"
        return 0
    fi

    # Regression 0.3.20: the expected sync standby is the PEER OF THE TARGET
    # HOST, not the peer of the LOCAL node. The standby join calls this FOR
    # the primary (local=node2, target=node1) and used to expect node 1's
    # own name as the streaming standby - it never matched, always fell
    # back to '*' (design question B2) with a confusing warning, and
    # overwrote the precise name the primary's init step 13 had written.
    if [ "$_hes_host" = "local" ] || [ "$_hes_host" = "$(ha_node_ip 1)" ]; then
        _hes_target="$(ha_node_name 2)"
    else
        _hes_target="$(ha_node_name 1)"
    fi
    if ! echo "$_hes_names" | grep -qx "$_hes_target"; then
        # 0.3.27 (design question B2 resolved): fall back to ASYNC, never to
        # '*' - with '*' every commit waits for a sync standby, so the moment
        # that oddly-named standby disconnects, ALL writes on the primary
        # freeze (the 22.10 bench 13:54 boot: a stale primary came up with a
        # leftover synchronous_standby_names='*' and no streaming standby -
        # WRITES FROZEN). '' is the already-documented policy (11.1: async
        # until the standby returns) and can never freeze a commit.
        warn "streaming standby name is '$_hes_names' (expected '$_hes_target') -"
        warn "falling back to ASYNC (writes continue; the exact name matters only for RPO=0)"
        ha_sync_names_write "$_hes_host" ""
        verbose "  sync mode: OFF on $_hes_host (standby name mismatch - async fallback, 0.3.27)"
        return 0
    fi
    ha_sync_names_write "$_hes_host" "$_hes_target"

    # verify: sync_state must become 'sync'
    _hes_try=0
    while [ "$_hes_try" -lt 8 ]; do
        _hes_state="$(pg_psql_superuser "$_hes_host" -tAc \
            "SELECT sync_state FROM pg_stat_replication WHERE state='streaming'" | tr -d ' \r')"
        if [ "$_hes_state" = "sync" ]; then
            verbose "  sync mode: ON on $_hes_host (synchronous_standby_names='$(ha_sync_names_gucval "$_hes_target")')"
            return 0
        fi
        _hes_try=$((_hes_try + 1))
        sleep 2
    done
    die "synchronous replication did not engage on $_hes_host (sync_state='$_hes_state')
Hint: check the standby conninfo application_name (design question B2)"
}

# =============================================================================
# Proxy support (DESIGN.md 5.1): reuse the layer-1 proxy.sh, then keep
# cluster-internal traffic away from the proxy.
# =============================================================================

# --proxy format check (host:port, layer-1 convention). MUST run before
# ha_apply_proxy: the layer-1 proxy.sh writes apt/git/wget/curl configs
# unconditionally, so a typo in --proxy must not get that far.
proxy_server_valid() {
    [ -n "$PROXY_SERVER" ] || return 0
    echo "$PROXY_SERVER" | grep -Eq '^[A-Za-z0-9._-]+:[0-9]{1,5}$' || return 1
    _psv_port="${PROXY_SERVER##*:}"
    [ "$_psv_port" -le 65535 ] 2>/dev/null
}

ha_apply_proxy() {
    [ -n "$PROXY_SERVER" ] || return 0
    if [ -f "$HA_LAYER1_PROXY_SH" ]; then
        # shellcheck disable=SC1090
        . "$HA_LAYER1_PROXY_SH"
    else
        warn "layer-1 proxy.sh not found ($HA_LAYER1_PROXY_SH) - using environment variables only"
        _hap_url="http://$PROXY_SERVER"
        export http_proxy="$_hap_url" https_proxy="$_hap_url" HTTP_PROXY="$_hap_url" HTTPS_PROXY="$_hap_url"
    fi
    # cluster addresses must never go through the proxy; call as soon as the
    # node addresses are known (--init: right after this; join/repair: after
    # cluster.conf is loaded)
}

ha_apply_no_proxy() {
    [ -n "$PROXY_SERVER" ] || return 0
    _hanp_extra="$(ha_node_ip 1),$(ha_node_ip 2),$(ha_node_ip 3),$(ha_node_name 1),$(ha_node_name 2),$(ha_node_name 3)"
    export no_proxy="${no_proxy:+$no_proxy,}$_hanp_extra"
    export NO_PROXY="$no_proxy"
    verbose "  proxy bypass list extended with cluster addresses"
}

# =============================================================================
# Cluster firewall (DESIGN.md 14.4/14.6)
# =============================================================================

# Layer 1 whitelists INPUT WITHOUT the cluster ports (iptables.sh: policy
# DROP, only 22/80/443/7443/SIP/RTP/1194 allowed). PostgreSQL 5432 and the
# role-agent 8008 are therefore unreachable from the other nodes, while
# repmgr, the peer haproxy (its backends check BOTH data nodes on 5432 +
# the agent on 8008), the witness and the --join preflight all need exactly
# those cross-node connections. On the bench the very first one (--join
# preflight) died with "the peer data node ... is not reachable on port
# 5432" while the server socket was listening fine - packets were dropped
# by the peer's firewall (regression 0.3.6). The HA layer opens its ports
# for the CLUSTER PEER ADDRESSES ONLY:
#   22    - media sync (lsyncd) SSH between the data nodes
#   5432  - PostgreSQL/repmgr: streaming, witness, metadata, pg_rewind
#   8008  - role-agent health checks of haproxy (both data nodes)
# Idempotent (iptables -C before every insert), safe to re-run at any
# point: on a node without a firewall (a bare witness) the rules are
# no-ops. Inserted at INPUT position 1 the rules stay ahead of any DROP
# rule a sysadmin or fail2ban may add later. Persistence follows layer 1
# (iptables-save > /etc/sysconfig/iptables) but ONLY on nodes where the
# iptables service (or its rules file) exists - a bare witness loads
# nothing from there, its default INPUT policy is ACCEPT anyway.
ha_ensure_cluster_firewall() {
    if ! cmd_exists iptables; then
        warn "iptables not available - skipping the cluster firewall rules
make sure the peers can reach ports 22/$HA_PG_PORT/$HA_AGENT_PORT on this node"
        return 0
    fi
    if svc_active firewalld; then
        warn "firewalld is active - the HA layer manages plain iptables only
open 22/$HA_PG_PORT/$HA_AGENT_PORT for the cluster peers in firewalld manually"
        return 0
    fi
    _hefw_added=0
    for _hefw_i in 1 2 3; do
        _hefw_ip="$(ha_node_ip "$_hefw_i")"
        [ -n "$_hefw_ip" ] || continue
        # own addresses need no INPUT rules (loopback traffic is open)
        if own_ips 2>/dev/null | grep -qxF "$_hefw_ip"; then
            continue
        fi
        for _hefw_port in 22 "$HA_PG_PORT" "$HA_AGENT_PORT"; do
            iptables -C INPUT -s "$_hefw_ip" -p tcp --dport "$_hefw_port" -j ACCEPT >/dev/null 2>&1 \
                && continue
            if ! iptables -I INPUT 1 -s "$_hefw_ip" -p tcp --dport "$_hefw_port" -j ACCEPT >/dev/null 2>&1; then
                warn "cannot add the iptables rule for $_hefw_ip:$_hefw_port - continuing"
                continue
            fi
            _hefw_added=$((_hefw_added + 1))
        done
    done
    if [ "$_hefw_added" -gt 0 ]; then
        verbose "  cluster firewall: $_hefw_added iptables rule(s) added (22/$HA_PG_PORT/$HA_AGENT_PORT from the peer nodes)"
    else
        verbose "  cluster firewall: peer rules already present (no changes)"
    fi
    if svc_is_enabled iptables || [ -f "$HA_IPTABLES_CONF" ]; then
        if iptables-save > "$HA_IPTABLES_CONF" 2>/dev/null; then
            verbose "  iptables rules persisted to $HA_IPTABLES_CONF"
        else
            warn "cannot persist the iptables rules to $HA_IPTABLES_CONF - after a reboot re-run --repair"
        fi
    fi
}

# =============================================================================
# Generic wait helper (self-coordination, DESIGN.md principle P3)
#   ha_wait <description> <timeout_seconds> <poll-function>
# The poll function returns 0 when the precondition is met.
# =============================================================================

ha_wait() {
    _hw_desc="$1"
    _hw_timeout="$2"
    _hw_fn="$3"
    _hw_step="${4:-10}"
    _hw_elapsed=0
    verbose "  waiting for $_hw_desc (timeout: ${_hw_timeout}s, poll: ${_hw_step}s)..."
    while [ "$_hw_elapsed" -lt "$_hw_timeout" ]; do
        if "$_hw_fn"; then
            verbose "  OK: $_hw_desc"
            return 0
        fi
        printf '    waiting... %ss / %ss\r' "$_hw_elapsed" "$_hw_timeout" >&2
        sleep "$_hw_step"
        _hw_elapsed=$((_hw_elapsed + _hw_step))
    done
    echo "" >&2
    error "TIMEOUT waiting for $_hw_desc after ${_hw_timeout}s"
    return 1
}
