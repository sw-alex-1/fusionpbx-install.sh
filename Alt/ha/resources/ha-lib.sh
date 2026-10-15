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

# psql as the postgres system user (local socket, peer auth)
pg_runuser_psql() {
    runuser -u postgres -- psql "$@" 2>/dev/null
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
# PostgreSQL service (repmgr node rejoin / clone edge paths).
Cmnd_Alias FUSIONPBX_HA_PGCTL = /usr/bin/systemctl start postgresql, \
    /usr/bin/systemctl stop postgresql, /usr/bin/systemctl restart postgresql, \
    /usr/bin/systemctl reload postgresql, /usr/bin/systemctl status postgresql
postgres ALL=(root) NOPASSWD: FUSIONPBX_HA_PGCTL
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
    # same per-user-TMPDIR reason as the hard block above
    _hfsa_opt="$(mktemp "${TMPDIR:-/tmp}/fpbx-ha-schema-opt.XXXXXX")"
    cat >"$_hfsa_opt" <<HAFIX
GRANT pg_monitor TO $HA_REPMGR_USER;
GRANT EXECUTE ON FUNCTION pg_catalog.pg_read_file(text, bigint, bigint) TO $HA_REPMGR_USER;
GRANT EXECUTE ON FUNCTION pg_catalog.pg_read_binary_file(text) TO $HA_REPMGR_USER;
GRANT EXECUTE ON FUNCTION pg_catalog.pg_read_binary_file(text, bigint, bigint) TO $HA_REPMGR_USER;
GRANT EXECUTE ON FUNCTION pg_catalog.pg_stat_file(text) TO $HA_REPMGR_USER;
GRANT EXECUTE ON FUNCTION pg_catalog.pg_stat_file(text, boolean) TO $HA_REPMGR_USER;
GRANT EXECUTE ON FUNCTION pg_catalog.pg_ls_waldir() TO $HA_REPMGR_USER;
GRANT EXECUTE ON FUNCTION pg_catalog.pg_ls_archivepg_wal() TO $HA_REPMGR_USER;
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
        *)       ha_write_pgpass data; ha_write_pg_hba data; ha_install_sudoers; ha_install_promote_sh ;;
    esac
    systemctl reload "$HA_PG_SERVICE" 2>/dev/null \
        || pg_runuser_psql -c "SELECT pg_reload_conf();" >/dev/null 2>&1 || true
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

repmgr_cmd() {
    runuser -u postgres -- repmgr -f "$HA_REPMGR_CONF" "$@" 2>&1
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

ha_write_authorized_keys() {
    _hak_sshdir=/root/.ssh
    mkdir -p "$_hak_sshdir"
    chmod 700 "$_hak_sshdir" 2>/dev/null || true
    touch "$_hak_sshdir/authorized_keys"
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
    install -m 0755 "$HA_RES_DIR/promote.sh.tpl" "$HA_PROMOTE_SH" \
        || die "cannot install promote.sh"
    verbose "  promote wrapper installed: $HA_PROMOTE_SH"
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
# ha_sync_names_write <host> <value-or-empty> - the ONLY writer for
# synchronous_standby_names (regression 0.3.9):
#   1. ALTER SYSTEM (server-side, clean);
#   2. when the server refuses it - a DIRECT postgresql.auto.conf edit +
#      reload for host=local (root restores the ownership; the standby
#      branch of ha_ensure_pg_listen uses the same file-edit precedent);
#   3. a remote host has no shared FS - die, QUOTING the captured psql
#      stderr (the 0.3.4 lesson: a hard-fail path must never swallow the
#      reason - the real bench died with a bare 'cannot set ... on local').
#
# ha_ensure_sync <primary-host|local>:
#   - a streaming standby exists  -> synchronous_standby_names='<standby
#     node name>' (fallback '*' when the name does not match - see design
#     open question B2), verify sync_state=sync
#   - no streaming standby        -> synchronous_standby_names='' (async:
#     writes continue; DESIGN.md 11.1 "async until the standby returns")
# =============================================================================

ha_sync_names_write() {
    _hsw_host="$1"
    _hsw_value="$2"
    _hsw_what="set"
    [ -n "$_hsw_value" ] || _hsw_what="clear"
    _hsw_err="$(mktemp "${TMPDIR:-/tmp}/fpbx-ha-syncnames.XXXXXX")"

    # 1. primary path: ALTER SYSTEM, stderr captured (never swallowed)
    if [ "$_hsw_host" = "local" ]; then
        runuser -u postgres -- psql -c \
            "ALTER SYSTEM SET synchronous_standby_names = '${_hsw_value}';" \
            >/dev/null 2>"$_hsw_err"
        _hsw_rc=$?
    else
        PGPASSWORD="$HA_DB_PASSWORD" psql -h "$_hsw_host" -p "$HA_PG_PORT" \
            -U postgres -c \
            "ALTER SYSTEM SET synchronous_standby_names = '${_hsw_value}';" \
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
    [ -n "$_hsw_value" ] && echo "synchronous_standby_names = '${_hsw_value}'" >> "$_hsw_auto"
    pg_runuser_psql -c "SELECT pg_reload_conf();" >/dev/null 2>&1 || true

    # the reload is asynchronous: confirm SHOW reflects the new value
    _hsw_try=0
    while [ "$_hsw_try" -lt 5 ]; do
        _hsw_cur="$(pg_runuser_psql -tAc "SHOW synchronous_standby_names" 2>/dev/null | tr -d ' \r')"
        if [ "$_hsw_cur" = "$_hsw_value" ]; then
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

    _hes_target="$(ha_peer_name)"
    if ! echo "$_hes_names" | grep -qx "$_hes_target"; then
        warn "streaming standby name is '$_hes_names' (expected '$_hes_target') - using '*' (design question B2 fallback)"
        _hes_target="*"
    fi
    ha_sync_names_write "$_hes_host" "$_hes_target"

    # verify: sync_state must become 'sync'
    _hes_try=0
    while [ "$_hes_try" -lt 8 ]; do
        _hes_state="$(pg_psql_superuser "$_hes_host" -tAc \
            "SELECT sync_state FROM pg_stat_replication WHERE state='streaming'" | tr -d ' \r')"
        if [ "$_hes_state" = "sync" ]; then
            verbose "  sync mode: ON on $_hes_host (synchronous_standby_names='$_hes_target')"
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
