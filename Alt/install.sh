#!/bin/sh

# FusionPBX Alt Linux Installer
# Based on the FusionPBX Debian installer, adapted for Alt Linux (APT-RPM)
#
# This script installs FusionPBX and all dependencies on Alt Linux.
# It is safe to re-run on a partially configured system - already installed
# packages will be skipped and existing configs will be backed up before
# modification.

# Determine the script directory (robust against symlinks and unusual paths)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Move to script directory so all relative paths work
cd "$SCRIPT_DIR"

# Includes - order matters: config first, then utilities, then environment
. ./resources/config.sh
. ./resources/colors.sh
. ./resources/util.sh
. ./resources/environment.sh
. ./resources/arguments.sh

# Skip CPU check if requested
if [ "$CPU_CHECK" = "false" ]; then
    verbose "CPU check skipped (--no-cpu-check)"
fi

# Banner
verbose "========================================="
verbose " FusionPBX Installer for Alt Linux"
verbose "========================================="
verbose ""
verbose "  OS:           $os_name $os_version"
verbose "  Architecture:  $cpu_architecture ($cpu_name, ${os_mode}-bit)"
verbose "  PHP:           $php_version"
verbose "  FreeSWITCH:    $switch_branch ($([ "$switch_package" = "true" ] && echo "RPM package" || echo "source build"))"
verbose "  PostgreSQL:    slot $database_version"
verbose "  Web user:      $web_user:$web_group"
verbose "  FS user:       $fs_user:$fs_group"
verbose ""

# =============================================================================
# Installation Steps
# Each step is a separate script that can be independently debugged and re-run.
# Steps will be implemented in subsequent increments.
# =============================================================================

# --- Increment 1: pre-install (system update, base packages) ---
# resources/pre-install.sh

# --- Increment 2: PHP ---
# resources/php.sh

# --- Increment 3: nginx ---
# resources/nginx.sh

# --- Increment 4: PostgreSQL ---
# resources/postgresql.sh

# --- Increment 5: FusionPBX ---
# resources/fusionpbx.sh

# --- Increment 6: FreeSWITCH ---
# resources/switch.sh

# --- Increment 7: Firewall ---
# resources/iptables.sh

# --- Increment 8: Fail2ban ---
# resources/fail2ban.sh

# --- Increment 9: Additional services ---
# resources/sngrep.sh
# resources/monit.sh

# --- Increment 10: Finish (database schema, users, services) ---
# resources/finish.sh

# --- Increment 11: LetsEncrypt (optional, run separately) ---
# resources/letsencrypt.sh

verbose ""
warning "Installer skeleton is ready."
warning "Installation steps will be activated in subsequent increments."
