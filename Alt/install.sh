#!/bin/sh

# FusionPBX Alt Linux Installer
# Based on the FusionPBX Debian installer, adapted for Alt Linux (APT-RPM)
#
# This script installs FusionPBX and all dependencies on Alt Linux.
# It is safe to re-run on a partially configured system - already installed
# packages will be skipped and existing configs will be backed up before
# modification.
#
# Usage:
#   ./install.sh                              # Default installation
#   ./install.sh --use-switch-source          # Build FreeSWITCH from source
#   ./install.sh --use-switch-master          # Use FreeSWITCH master branch
#   ./install.sh --no-cpu-check               # Skip CPU validation
#   ./install.sh -h                           # Show help

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
verbose "  PostgreSQL:    $database_version ($pg_package)"
verbose "  Web user:      $web_user:$web_group"
verbose "  FS user:       $fs_user:$fs_group"
verbose ""
verbose "Starting installation..."
verbose ""

# =============================================================================
# Installation Steps
# Each step is a separate script that can be independently debugged and re-run.
# Failed steps will print warnings but the installer will continue to allow
# manual intervention. Critical failures use die() to abort.
# =============================================================================

# Step 1: System preparation (update, base packages, cdrom cleanup)
verbose "=== Step 1/10: System preparation ==="
resources/pre-install.sh

# Step 2: PHP and PHP-FPM
verbose "=== Step 2/10: Installing PHP ==="
resources/php.sh

# Step 3: NGINX web server
verbose "=== Step 3/10: Installing NGINX ==="
resources/nginx.sh

# Step 4: PostgreSQL database
verbose "=== Step 4/10: Installing PostgreSQL ==="
resources/postgresql.sh

# Step 5: FusionPBX application
verbose "=== Step 5/10: Installing FusionPBX ==="
resources/fusionpbx.sh

# Step 6: FreeSWITCH
verbose "=== Step 6/10: Installing FreeSWITCH ==="
resources/switch.sh
resources/switch/dsn.sh

# Step 7: Firewall
verbose "=== Step 7/10: Configuring firewall ==="
resources/iptables.sh

# Step 8: Fail2ban
verbose "=== Step 8/10: Configuring Fail2ban ==="
# resources/fail2ban.sh

# Step 9: Additional services (sngrep, monit, snmp)
verbose "=== Step 9/10: Additional services ==="
# resources/sngrep.sh
# resources/monit.sh

# Step 10: Finish (database schema, admin user, service startup)
verbose "=== Step 10/10: Finalizing installation ==="
# resources/finish.sh

# =============================================================================
# Completion
# =============================================================================

verbose ""
verbose "========================================="
verbose " Installation steps completed."
verbose "========================================="
verbose ""
warning "Note: Some steps are not yet implemented."
warning "Completed steps: 1 (pre-install), 2 (PHP), 3 (nginx), 4 (PostgreSQL), 5 (FusionPBX), 6 (FreeSWITCH), 7 (iptables)"
warning "Remaining steps will be activated in subsequent increments."
