#!/bin/sh

# FusionPBX Alt Linux Installer
# Based on the FusionPBX Debian installer, adapted for Alt Linux (APT-RPM)
#
# This script installs FusionPBX and all dependencies on Alt Linux.
# It is safe to re-run on a partially configured system - already installed
# packages will be skipped and existing configs will be backed up before
# modification. Re-running after a failed step is the documented recovery
# path: the installer detects an incomplete previous run via the progress
# state file (/etc/fusionpbx/.installer-state, see resources/guard.sh).
#
# INSTALLED-SYSTEM PROTECTION: the installer REFUSES to run when FusionPBX
# is already installed and configured on this system, because a re-run
# would destroy the existing configuration (reset database passwords,
# replace /etc/freeswitch with defaults, add duplicate domain/admin
# records). Use --force to bypass the protection for a conscious
# re-installation. See resources/guard.sh for the detection logic.
#
# ERROR HANDLING: The installer STOPS on critical errors. Each step is
# executed via run_step() which checks the exit code. If a step fails,
# the installer aborts with a clear error message explaining what went
# wrong and which step to re-run after fixing the issue.
#
# Installation order matches the Debian installer:
#   1. System prep, PHP, Angie, PostgreSQL, FusionPBX, FreeSWITCH
#   2. FreeSWITCH starts with default SQLite config (provides event socket)
#   3. finish.sh: upgrade.php --defaults (event socket available = correct paths)
#   4. dsn.sh: switch FreeSWITCH from SQLite to PostgreSQL
#   5. Final restart of FreeSWITCH with PostgreSQL DSN
#
# Usage:
#   ./install.sh                              # Default installation
#                                             # On a terminal the installer first asks a
#                                             # few questions (interactive mode; Enter
#                                             # accepts each default): proxy, domain,
#                                             # admin password. Without a terminal on
#                                             # stdin it runs fully unattended.
#   ./install.sh --use-switch-source          # Build FreeSWITCH from source
#   ./install.sh --use-switch-master          # Use FreeSWITCH master branch
#   ./install.sh --with-ioncube               # Also install the ionCube Loader
#                                             # (only for commercial encoded add-ons)
#   ./install.sh --no-cpu-check               # Skip CPU validation
#   ./install.sh --proxy 192.168.0.1:8080     # Use HTTP proxy
#   ./install.sh --force                      # DANGER: run even if FusionPBX
#                                             # is already installed (destroys
#                                             # existing configuration)
#   ./install.sh -h                           # Show help

# Determine the script directory (robust against symlinks and unusual paths)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Move to script directory so all relative paths work
cd "$SCRIPT_DIR"

# Includes - order matters: config first, then utilities, then environment
. "$SCRIPT_DIR/resources/config.sh"
. "$SCRIPT_DIR/resources/colors.sh"
. "$SCRIPT_DIR/resources/util.sh"
. "$SCRIPT_DIR/resources/environment.sh"
. "$SCRIPT_DIR/resources/arguments.sh"

# =============================================================================
# Error tracking — counts failed steps for final summary
# =============================================================================

_INSTALL_FAILED_STEPS=""
_INSTALL_CURRENT_STEP=""

# =============================================================================
# run_step — execute an installation step with error checking
#
# Usage: run_step <step_number> <description> <script_path> [script_args...]
#
# If the script exits with non-zero code, the installer ABORTS immediately.
# This prevents cascading failures where a later step depends on an
# earlier step that silently failed.
#
# The user is told exactly which step failed and how to re-run it after
# fixing the issue.
# =============================================================================

run_step() {
    _rs_step_num="$1"
    _rs_desc="$2"
    _rs_script="$3"
    shift 3
    # Remaining args are passed to the script

    _INSTALL_CURRENT_STEP="$_rs_step_num"

    verbose ""
    verbose "=== Step $_rs_step_num: $_rs_desc ==="

    if [ ! -f "$_rs_script" ]; then
        error ""
        error "========================================="
        error " INSTALLATION ABORTED"
        error "========================================="
        error ""
        error "Step $_rs_step_num ($_rs_desc) FAILED:"
        error "  Script not found: $_rs_script"
        error ""
        error "This is a bug in the installer. Please report it."
        error ""
        exit 1
    fi

    # Run the step script
    # Capture the exit code — this is the critical check
    "$_rs_script" "$@"
    _rs_exit_code=$?

    if [ $_rs_exit_code -ne 0 ]; then
        _INSTALL_FAILED_STEPS="$_INSTALL_FAILED_STEPS $_rs_step_num"

        error ""
        error "========================================="
        error " INSTALLATION ABORTED"
        error "========================================="
        error ""
        error "Step $_rs_step_num ($_rs_desc) FAILED with exit code $_rs_exit_code."
        error ""
        error "The installer cannot continue because this step is required"
        error "for subsequent steps to work correctly."
        error ""
        error "What to do:"
        error "  1. Read the error messages above carefully"
        error "  2. Fix the problem (missing package, network issue, etc.)"
        error "  3. Re-run the installer — it will skip already completed steps"
        error "     (if it refuses to re-run because the system looks fully"
        error "      installed, add --force — see resources/guard.sh)"
        error ""
        error "To re-run just this step for debugging:"
        error "  cd $SCRIPT_DIR && $_rs_script"
        error ""

        exit 1
    fi

    verbose "Step $_rs_step_num completed successfully."

    # Record progress for the installed-system guard (recovery detection).
    # Must never fail the step - guard_record_step ignores write errors.
    guard_record_step "$_rs_step_num" "$_rs_desc"
}

# =============================================================================
# Installed-system protection
#
# Refuses to run when FusionPBX is already installed and configured on this
# system: a re-run would reset database passwords, replace /etc/freeswitch
# with defaults, and add duplicate domain/admin records to the database.
# A previous run of THIS installer that did not complete is detected via
# the progress state file and re-running is allowed (recovery).
# --force bypasses the protection. Detection logic: resources/guard.sh.
# =============================================================================

. "$SCRIPT_DIR/resources/guard.sh"
guard_check_installed

# =============================================================================
# Interactive questions (terminal only)
#
# resources/interactive.sh - asked BEFORE the proxy configuration (a answered
# proxy must reach every network operation) and AFTER the installed-system
# guard (no questions on a system where the installer will refuse anyway).
# Rules: every question has a safe default; CLI flags are never re-asked;
# without a terminal on stdin (piped / ssh / CI) zero questions are asked.
# The answers are exported - the step scripts run as child processes and
# re-source config.sh, whose ${var:-default} defaults keep them.
# =============================================================================

. "$SCRIPT_DIR/resources/interactive.sh"
interactive_install_questions

# =============================================================================
# Skip CPU check if requested
# =============================================================================

if [ "$CPU_CHECK" = "false" ]; then
    verbose "CPU check skipped (--no-cpu-check)"
fi

# =============================================================================
# Configure proxy (MUST run before any network operations)
# =============================================================================

. "$SCRIPT_DIR/resources/proxy.sh"

# =============================================================================
# Banner
# =============================================================================

verbose "========================================="
verbose " FusionPBX Installer for Alt Linux"
verbose "========================================="
verbose ""
verbose "  OS:           $os_name $os_version"
verbose "  Architecture:  $cpu_architecture ($cpu_name, ${os_mode}-bit)"
verbose "  PHP:           $php_version"
verbose "  FreeSWITCH:    $switch_branch ($([ "$switch_package" = "true" ] && echo "RPM package" || echo "source build"))"
verbose "  PostgreSQL:    $database_version ($pg_package)"
verbose "  Web user:      $web_user:$web_group"
verbose "  FS user:       $fs_user:$fs_group"
if [ "$domain_name" != "ip_address" ] && [ "$domain_name" != "hostname" ]; then
    verbose "  Domain:        $domain_name"
else
    verbose "  Domain:        this node's IP address (the default)"
fi
if [ "$system_password" != "random" ]; then
    verbose "  Admin user:    $system_username (password: set interactively)"
else
    verbose "  Admin user:    $system_username (password: random, shown at the end)"
fi
verbose "  ionCube:       $install_ioncube"
if [ -n "$PROXY_SERVER" ]; then
    verbose "  Proxy:         $PROXY_SERVER"
fi
verbose ""
verbose "Starting installation..."
verbose ""

# =============================================================================
# Record installation start
# Creates the progress state file so that a failed run is recognized as
# "incomplete" (recovery) instead of "installed" (blocked) on the next start.
# =============================================================================

guard_install_started

# =============================================================================
# Installation Steps
#
# Each step is executed via run_step() which checks the exit code.
# If a step fails, the installer ABORTS immediately with a clear
# error message. This prevents cascading failures.
#
# Steps marked as (optional) may use warn() for non-critical failures
# inside the script but will still abort if the script itself exits
# with a non-zero code.
# =============================================================================

# Step 1: System preparation (update, base packages, cdrom cleanup)
run_step "1/11" "System preparation" "$SCRIPT_DIR/resources/pre-install.sh"

# Step 2: PHP and PHP-FPM
run_step "2/11" "Installing PHP" "$SCRIPT_DIR/resources/php.sh"

# Step 3: Angie web server (advanced nginx fork)
run_step "3/11" "Installing Angie" "$SCRIPT_DIR/resources/angie.sh"

# Step 4: PostgreSQL database
run_step "4/11" "Installing PostgreSQL" "$SCRIPT_DIR/resources/postgresql.sh"

# Step 5: FusionPBX application
run_step "5a/11" "Installing FusionPBX" "$SCRIPT_DIR/resources/fusionpbx.sh"
run_step "5b/11" "Installing FusionPBX applications" "$SCRIPT_DIR/resources/applications.sh"

# Step 6: FreeSWITCH
# This step also STARTS FreeSWITCH (with default SQLite config).
# FreeSWITCH must be running before finish.sh so that upgrade.php --defaults
# can access the event socket and populate switch settings correctly.
run_step "6/11" "Installing and starting FreeSWITCH" "$SCRIPT_DIR/resources/switch.sh"

# Step 7: Firewall
run_step "7/11" "Configuring firewall" "$SCRIPT_DIR/resources/iptables.sh"

# Step 8: Fail2ban
run_step "8/11" "Configuring Fail2ban" "$SCRIPT_DIR/resources/fail2ban.sh"

# Step 9: Additional services (sngrep, monit)
run_step "9a/11" "Installing sngrep" "$SCRIPT_DIR/resources/sngrep.sh"
run_step "9b/11" "Installing monit" "$SCRIPT_DIR/resources/monit.sh"

# Step 10: Finish (database schema, admin user, upgrade.php)
# FreeSWITCH is already running, so upgrade.php --defaults gets correct
# switch paths from the event socket.
run_step "10/11" "Finalizing installation" "$SCRIPT_DIR/resources/finish.sh"

# Step 11: FreeSWITCH DSN Configuration
# Switches FreeSWITCH from SQLite to PostgreSQL for all databases.
# MUST run AFTER finish.sh because it inserts data into v_vars table
# which is created by upgrade.php --schema in finish.sh.
run_step "11/11" "Configuring FreeSWITCH database (PostgreSQL)" "$SCRIPT_DIR/resources/switch/dsn.sh"

# =============================================================================
# Completion
# =============================================================================

verbose ""
verbose "========================================="
verbose " Installation completed successfully!"
verbose "========================================="
verbose ""
verbose "All 11 installation steps completed without errors."
verbose ""

# =============================================================================
# Installed-system guard: mark this system as installed
# From now on the installer refuses to re-run here (protection against
# destroying a live system). --force bypasses; see resources/guard.sh.
# =============================================================================

guard_install_finished
verbose "System marked as installed: $GUARD_MARKER_FILE"
verbose "The installer will refuse to re-run on this system from now on."
verbose ""
