#!/bin/sh

# FusionPBX Alt Linux Installer - Installed-System Guard
#
# Protects an installed and configured FusionPBX system from being destroyed
# by an accidental re-run of the installer.
#
# What a re-run would destroy on a live system (why this guard exists):
#   - resources/postgresql.sh       generates a NEW random database password,
#                                   resets the postgres/fusionpbx/freeswitch
#                                   role passwords, rewrites pg_hba.conf
#   - resources/switch/conf-copy.sh removes the live /etc/freeswitch config
#                                   (dialplans, extensions, SIP profiles)
#                                   and re-deploys the default one
#   - resources/finish.sh           inserts a duplicate domain and a second
#                                   admin user, overwrites /etc/fusionpbx/config.conf
#                                   and the xml_cdr credentials
#   - resources/fusionpbx.sh        runs git pull over a live checkout
#
# Decision order (first match wins):
#   1. --force given .............. bypass with a loud warning
#   2. marker file exists ......... BLOCK (a previous install completed
#                                   successfully: /etc/fusionpbx/.installed)
#   3. state file exists .......... ALLOW (a previous run of THIS installer
#                                   did not complete -> recovery re-run)
#   4. live "configured system" signals (catches systems installed by older
#      installer versions that predate the marker file):
#        a. /etc/fusionpbx/config.conf with real credentials (finish.sh ran)
#        b. local PostgreSQL already contains the FusionPBX schema (v_users)
#      -> BLOCK if found
#   5. otherwise .................. ALLOW (fresh system)
#
# Notes on detection choices:
#   - The existence of /var/www/fusionpbx or /etc/freeswitch.orig alone is
#     NOT a blocking signal: both appear during a normal install long before
#     it finishes, and re-running after a mid-way failure is the documented
#     recovery path (the run_step error message tells the user to re-run).
#   - Every check is best-effort and fault-tolerant: if a check cannot run
#     (for example psql is not installed on a fresh system), it reports
#     "no signal". The guard must NEVER break a normal installation.
#
# This file is self-contained (plain POSIX sh, no dependency on util.sh or
# colors.sh) so it can also be sourced by pre-install.sh. Colors are applied
# only when colors.sh happens to be sourced first (install.sh case).

# =============================================================================
# Paths (overridable via environment for testing)
# =============================================================================
GUARD_CONF_DIR="${GUARD_CONF_DIR:-/etc/fusionpbx}"
GUARD_MARKER_FILE="$GUARD_CONF_DIR/.installed"
GUARD_STATE_FILE="$GUARD_CONF_DIR/.installer-state"

# Database to inspect. When sourced from install.sh this uses the value
# from resources/config.sh; standalone (pre-install.sh) uses the default.
guard_database_name="${database_name:-fusionpbx}"

# =============================================================================
# Output helpers
# ($red/$yellow/$green/$normal are empty unless colors.sh was sourced first)
# =============================================================================
_guard_error() { echo "${red:-}ERROR: $1${normal:-}" >&2; }
_guard_warn()  { echo "${yellow:-}WARNING: $1${normal:-}" >&2; }
_guard_note()  { echo "${yellow:-}$1${normal:-}" >&2; }
_guard_info()  { echo "${green:-}$1${normal:-}"; }

# =============================================================================
# Detection
# =============================================================================

# Returns 0 and sets GUARD_REASON when a fully installed system is detected.
# Cheapest and most definitive checks first.
_guard_installed_system_detected() {

    # 1. Marker file written by guard_install_finished() after a successful
    #    installation (installs made by this installer version)
    if [ -f "$GUARD_MARKER_FILE" ]; then
        GUARD_REASON="installation marker present: $GUARD_MARKER_FILE"
        return 0
    fi

    # 2. Legacy systems installed before the guard existed:
    #    /etc/fusionpbx/config.conf with real database credentials is
    #    written by finish.sh (step 10) near the end of a successful
    #    installation. A file still containing {database_...} placeholders
    #    is an unfinished template and is NOT treated as installed.
    if [ -f "$GUARD_CONF_DIR/config.conf" ] \
        && ! grep -q '{database_' "$GUARD_CONF_DIR/config.conf" 2>/dev/null; then
        GUARD_REASON="configured FusionPBX found: $GUARD_CONF_DIR/config.conf"
        return 0
    fi

    # 3. Legacy systems, plan B: the FusionPBX schema is already loaded into
    #    the local PostgreSQL (table v_users exists in the fusionpbx
    #    database). Best-effort: when PostgreSQL is not installed or not
    #    running this is a fresh/partial system and the check silently
    #    reports "no signal".
    if command -v psql >/dev/null 2>&1 && command -v runuser >/dev/null 2>&1; then
        if runuser -u postgres -- psql -d "$guard_database_name" -tAc \
            "SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='v_users'" \
            2>/dev/null | grep -q '^1$'; then
            GUARD_REASON="FusionPBX database schema found in PostgreSQL (database '$guard_database_name')"
            return 0
        fi
    fi

    return 1
}

# Returns 0 when an INCOMPLETE previous run of this installer is detected
# (progress state file exists, completion marker does not).
_guard_incomplete_run_detected() {
    [ -f "$GUARD_STATE_FILE" ]
}

# =============================================================================
# Messages
# =============================================================================

_guard_print_blocked() {
    _gp_reason="$1"

    echo "" >&2
    echo "${red:-}=========================================================================${normal:-}" >&2
    echo "${red:-} INSTALLATION REFUSED - INSTALLED SYSTEM PROTECTION${normal:-}" >&2
    echo "${red:-}=========================================================================${normal:-}" >&2
    echo "" >&2
    _guard_error "FusionPBX appears to be ALREADY INSTALLED on this system."
    _guard_error ""
    _guard_error "Detected: $_gp_reason"
    echo "" >&2
    _guard_error "Re-running the installer would DESTROY the existing configuration:"
    _guard_error "  - PostgreSQL: new random passwords for postgres/fusionpbx/freeswitch"
    _guard_error "  - FreeSWITCH: /etc/freeswitch removed and replaced with defaults"
    _guard_error "  - Database:   duplicate domain and a second admin user added"
    _guard_error "  - Web:        /etc/fusionpbx/config.conf overwritten"
    echo "" >&2
    _guard_error "To UPDATE an installed FusionPBX use the supported ways instead:"
    _guard_error "  - Web interface: Advanced -> Upgrade"
    _guard_error "  - or: cd /var/www/fusionpbx && git pull  (then Advanced -> Upgrade)"
    echo "" >&2
    _guard_error "To RE-INSTALL from scratch on purpose (DATA LOSS!):"
    _guard_error "  ./install.sh --force"
    echo "" >&2
    _guard_error "System state files:"
    _guard_error "  $GUARD_MARKER_FILE   (present after a successful install)"
    _guard_error "  $GUARD_CONF_DIR/config.conf"
    echo "" >&2
    echo "${red:-}=========================================================================${normal:-}" >&2

    exit 1
}

_guard_print_force_warning() {
    echo "" >&2
    _guard_warn "========================================================================="
    _guard_warn " --force IS SET - INSTALLED-SYSTEM PROTECTION IS DISABLED"
    _guard_warn "========================================================================="
    _guard_warn "This run may DESTROY an existing FusionPBX configuration:"
    _guard_warn "  - reset PostgreSQL passwords (new random password)"
    _guard_warn "  - remove and re-deploy /etc/freeswitch"
    _guard_warn "  - add duplicate domain and admin user to the database"
    _guard_warn "  - overwrite /etc/fusionpbx/config.conf"
    echo "" >&2
    _guard_warn "Continuing in 5 seconds... (Ctrl+C to abort)"
    echo "" >&2
    sleep 5
}

_guard_print_recovery() {
    echo "" >&2
    _guard_note "NOTE: a previous installation attempt did not complete."
    _guard_note "Progress recorded in $GUARD_STATE_FILE:"
    grep '^step_ok=' "$GUARD_STATE_FILE" 2>/dev/null | sed 's/^step_ok=/  - /' >&2
    _guard_note "Re-running after a failed step is the documented recovery path -"
    _guard_note "already completed work will be skipped."
    echo "" >&2
}

# =============================================================================
# Main entry point
# =============================================================================
# Called by install.sh (after arguments.sh) and by pre-install.sh.
# Exits with code 1 when an installed system is detected and --force is
# not given. Never modifies anything by itself.

guard_check_installed() {

    # 1. Explicit bypass (--force)
    if [ "${FORCE_INSTALL:-false}" = "true" ]; then
        _guard_print_force_warning
        return 0
    fi

    # 2. Fully installed system -> block (exits 1 inside)
    if _guard_installed_system_detected; then
        _guard_print_blocked "$GUARD_REASON"
    fi

    # 3. Incomplete previous run of this installer -> recovery mode
    if _guard_incomplete_run_detected; then
        _guard_print_recovery
        return 0
    fi

    # 4. Fresh system
    return 0
}

# =============================================================================
# State recording (called from install.sh)
# =============================================================================

# Called once when a new installation starts. Creates the progress state
# file so that a failed run is recognized as "incomplete" (recovery) rather
# than "installed" (blocked) on the next start.
guard_install_started() {
    if mkdir -p "$GUARD_CONF_DIR" 2>/dev/null; then
        {
            echo "# FusionPBX installer progress state (auto-generated, do not edit)"
            echo "# Removed automatically when the installation completes;"
            echo "# the completion marker is $GUARD_MARKER_FILE"
            echo "started=$(date '+%Y-%m-%d %H:%M:%S')"
        } 2>/dev/null > "$GUARD_STATE_FILE" \
            || _guard_warn "Could not write installer state file $GUARD_STATE_FILE"
    else
        _guard_warn "Could not create $GUARD_CONF_DIR (installer progress will not be recorded)"
    fi
}

# Called after each successfully completed installation step.
# Never fails the step: write errors are silently ignored.
guard_record_step() {
    _grs_id="$1"
    _grs_desc="$2"
    echo "step_ok=${_grs_id} ${_grs_desc}" 2>/dev/null >> "$GUARD_STATE_FILE" || true
}

# Called once after the installation has completed successfully.
# Writes the completion marker and removes the progress state file.
guard_install_finished() {
    _gif_commit=""
    if command -v git >/dev/null 2>&1 && [ -n "${SCRIPT_DIR:-}" ]; then
        _gif_commit=$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null)
    fi
    {
        echo "# FusionPBX installation marker (auto-generated, do not edit)"
        echo "# The installer refuses to re-run while this file exists."
        echo "# Remove it or use --force only if you fully understand the"
        echo "# consequences (see resources/guard.sh)."
        echo "installed_at=$(date '+%Y-%m-%d %H:%M:%S')"
        echo "system_branch=${system_branch:-unknown}"
        echo "switch_branch=${switch_branch:-unknown}"
        echo "php_version=${php_version:-unknown}"
        echo "database_version=${database_version:-unknown}"
        echo "installer_commit=${_gif_commit:-unknown}"
    } 2>/dev/null > "$GUARD_MARKER_FILE" \
        || _guard_warn "Could not write installation marker $GUARD_MARKER_FILE"
    rm -f "$GUARD_STATE_FILE" 2>/dev/null
}
