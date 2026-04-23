#!/bin/sh

# FusionPBX Alt Linux Installer
# Based on the FusionPBX Debian installer, adapted for Alt Linux (APT-RPM)
#
# This script installs FusionPBX and all dependencies on Alt Linux.
# It is safe to re-run on a partially configured system - already installed
# packages will be skipped and existing configs will be backed up before
# modification.
#
# Installation order matches the Debian installer:
#   1. System prep, PHP, nginx, PostgreSQL, FusionPBX, FreeSWITCH
#   2. FreeSWITCH starts with default SQLite config (provides event socket)
#   3. finish.sh: upgrade.php --defaults (event socket available = correct paths)
#   4. dsn.sh: switch FreeSWITCH from SQLite to PostgreSQL
#   5. Final restart of FreeSWITCH with PostgreSQL DSN
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
verbose ""
verbose "=== Step 1/11: System preparation ==="
resources/pre-install.sh

# Step 2: PHP and PHP-FPM
verbose ""
verbose "=== Step 2/11: Installing PHP ==="
resources/php.sh

# Step 3: NGINX web server
verbose ""
verbose "=== Step 3/11: Installing NGINX ==="
resources/nginx.sh

# Step 4: PostgreSQL database
verbose ""
verbose "=== Step 4/11: Installing PostgreSQL ==="
resources/postgresql.sh

# Step 5: FusionPBX application
verbose ""
verbose "=== Step 5/11: Installing FusionPBX ==="
resources/fusionpbx.sh
resources/applications.sh

# Step 6: FreeSWITCH
# This step also STARTS FreeSWITCH (with default SQLite config).
# FreeSWITCH must be running before finish.sh so that upgrade.php --defaults
# can access the event socket and populate switch settings correctly.
# This matches the Debian installer's approach.
verbose ""
verbose "=== Step 6/11: Installing and starting FreeSWITCH ==="
resources/switch.sh

# Step 7: Firewall
verbose ""
verbose "=== Step 7/11: Configuring firewall ==="
resources/iptables.sh

# Step 8: Fail2ban
verbose ""
verbose "=== Step 8/11: Configuring Fail2ban ==="
resources/fail2ban.sh

# Step 9: Additional services (sngrep, monit)
verbose ""
verbose "=== Step 9/11: Additional services ==="
resources/sngrep.sh
resources/monit.sh

# Step 10: Finish (database schema, admin user, upgrade.php)
# FreeSWITCH is already running, so upgrade.php --defaults gets correct
# switch paths from the event socket. This naturally populates:
#   - v_default_settings with correct switch paths
#   - v_music_on_hold from local_stream.conf
#   - v_modules from scanning mod_dir
verbose ""
verbose "=== Step 10/11: Finalizing installation ==="
resources/finish.sh

# Step 11: FreeSWITCH DSN Configuration
# Switches FreeSWITCH from SQLite to PostgreSQL for all databases.
# MUST run AFTER finish.sh because it inserts data into v_vars table
# which is created by upgrade.php --schema in finish.sh.
# After DSN is configured, FreeSWITCH is restarted with PostgreSQL.
verbose ""
verbose "=== Step 11/11: Configuring FreeSWITCH database (PostgreSQL) ==="
resources/switch/dsn.sh

# =============================================================================
# Completion
# =============================================================================

verbose ""
verbose "========================================="
verbose " Installation steps completed."
verbose "========================================="
verbose ""
verbose "All installation steps completed successfully!"
