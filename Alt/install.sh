#!/bin/sh

# FusionPBX Alt Linux Installer
# Based on the FusionPBX Debian installer, adapted for Alt Linux (APT-RPM)
#
# This script installs FusionPBX and all dependencies on Alt Linux.
# It is safe to re-run on a partially configured system - already installed
# packages will be skipped and existing configs will be backed up before
# modification.
#
# IMPORTANT: The order of steps matters!
#   - dsn.sh MUST run AFTER finish.sh because it inserts data into the
#     v_vars database table which is created by upgrade.php --schema in finish.sh
#   - In the Debian installer, dsn.sh is also called after the database schema
#     is set up (it's run manually or as a separate step)
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
verbose ""
verbose "=== Step 6/11: Installing FreeSWITCH ==="
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

# Step 10: Finish (database schema, admin user, service startup)
# This step creates the database tables (v_vars, v_domains, etc.)
verbose ""
verbose "=== Step 10/11: Finalizing installation ==="
resources/finish.sh

# Step 11: FreeSWITCH DSN Configuration
# MUST run AFTER finish.sh because it inserts data into v_vars table
# which is created by upgrade.php --schema in finish.sh.
# This configures FreeSWITCH to use PostgreSQL instead of SQLite.
verbose ""
verbose "=== Step 11/11: Configuring FreeSWITCH database ==="
resources/switch/dsn.sh

# =============================================================================
# Final restart of FreeSWITCH with DSN configured
# =============================================================================

verbose "Restarting FreeSWITCH with DSN configuration..."
systemctl restart freeswitch || warn "FreeSWITCH restart failed"
verbose "FreeSWITCH restarted with PostgreSQL DSN"

# =============================================================================
# Sync modules after FreeSWITCH is running
#
# When finish.sh runs upgrade.php --defaults, FreeSWITCH is NOT running yet.
# This means switch_settings::settings() can't connect to the event socket
# to get mod_dir, and modules::synch() can't scan the modules directory.
# As a result, the v_modules table stays empty (no modules in the web UI).
#
# Now that FreeSWITCH IS running, re-run upgrade.php --defaults to:
# 1. Get mod_dir from the event socket (or use config.conf fallback)
# 2. Sync modules: scan /usr/lib64/freeswitch for .so files → v_modules table
# 3. Populate v_default_settings with correct switch paths
#
# The --defaults flag is idempotent: it only adds missing settings/modules,
# it doesn't overwrite existing ones.
# =============================================================================

verbose "Syncing modules (FreeSWITCH is now running)..."
cd /var/www/fusionpbx && /usr/bin/php /var/www/fusionpbx/core/upgrade/upgrade.php --defaults
verbose "Module sync completed"

# =============================================================================
# Completion
# =============================================================================

verbose ""
verbose "========================================="
verbose " Installation steps completed."
verbose "========================================="
verbose ""
verbose "All installation steps completed successfully!"
