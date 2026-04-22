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
# Wait for FreeSWITCH to fully start
# FreeSWITCH needs time to initialize and listen on the event socket.
# Without this wait, upgrade.php --defaults might not be able to connect.
# =============================================================================

verbose "Waiting for FreeSWITCH to fully initialize..."
_sleep_count=0
while [ $_sleep_count -lt 30 ]; do
    if /usr/bin/php -r "
        \$sock = @stream_socket_client('tcp://127.0.0.1:8021', \$errno, \$errstr, 2);
        if (\$sock) { fclose(\$sock); echo 'OK'; }
    " 2>/dev/null | grep -q "OK"; then
        verbose "  FreeSWITCH event socket is ready"
        break
    fi
    sleep 1
    _sleep_count=$((_sleep_count + 1))
done
if [ $_sleep_count -ge 30 ]; then
    warn "FreeSWITCH event socket not ready after 30s (may cause issues with switch settings)"
fi

# =============================================================================
# Sync modules and fix switch default settings after FreeSWITCH is running
#
# CRITICAL PROBLEM: When finish.sh runs upgrade.php --defaults the FIRST time,
# FreeSWITCH is NOT running. The switch_settings::settings() method connects
# to the event socket to get switch paths (mod_dir, db_dir, sounds_dir, etc.).
# When the event socket is unavailable, ALL path values are EMPTY STRINGS.
# These empty values get INSERTED into v_default_settings.
#
# On the SECOND run (now, with FreeSWITCH running), upgrade.php --defaults
# only ADDS MISSING settings — it does NOT update existing ones. So the empty
# values from the first run PERSIST in the database!
#
# This was identified as the root cause of:
#   - Empty module list in the web UI
#   - mod_local_stream failing to load ("Module load routine returned an error")
#   - Wrong/empty paths in Advanced → Default Settings → Switch
#
# Reference: https://www.pbxforums.com/threads/error-loading-mod_local_stream-so.5251/
#
# FIX: Delete all switch default settings before the second run of
# upgrade.php --defaults, so they can be recreated with CORRECT values
# from the event socket.
#
# Additionally, we now use PostgreSQL for ALL FreeSWITCH databases (core,
# fifo, callcenter) instead of SQLite, because SQLite's file locking does
# not work correctly with FreeSWITCH on Alt Linux, causing "attempt to write
# a readonly database" errors.
# =============================================================================

# Delete switch default settings that were created with empty values
# dsn.sh already does this, but we do it again here as a safety measure
# (in case dsn.sh was skipped or run at a different time)
verbose "Deleting stale switch default settings..."
. ./resources/config.sh
if [ -f "/tmp/fusionpbx_db_credentials" ]; then
    . /tmp/fusionpbx_db_credentials
fi
export PGPASSWORD=$database_password
runuser -u postgres -- psql -d "$database_name" -c \
    "DELETE FROM v_default_settings WHERE default_setting_category = 'switch';" 2>/dev/null \
    || verbose "  switch default settings deletion skipped"
unset PGPASSWORD
verbose "  Switch default settings cleared (will be recreated with correct values)"

# Re-run upgrade.php --defaults with FreeSWITCH running
# This will:
# 1. Get correct switch paths from the event socket (mod_dir, db_dir, etc.)
# 2. Insert them into v_default_settings (since we just deleted the old ones)
# 3. Sync modules: scan /usr/lib64/freeswitch for .so files → v_modules table
verbose "Syncing modules and switch settings (FreeSWITCH is now running)..."
cd /var/www/fusionpbx && /usr/bin/php /var/www/fusionpbx/core/upgrade/upgrade.php --defaults
verbose "Module sync completed"

# =============================================================================
# Clear FusionPBX cache
# Stale cache can contain XML generated with wrong switch paths.
# After fixing v_default_settings, we must clear the cache so that
# new XML is generated with the correct paths.
# =============================================================================

verbose "Clearing FusionPBX cache..."
if [ -d "/var/cache/fusionpbx" ]; then
    rm -rf /var/cache/fusionpbx/*
    verbose "  FusionPBX cache cleared"
fi

# =============================================================================
# Restart FreeSWITCH one final time
# This ensures FreeSWITCH picks up the corrected XML configuration from
# FusionPBX's XML handler (which now uses the correct switch paths).
# =============================================================================

verbose "Restarting FreeSWITCH with corrected configuration..."
systemctl restart freeswitch || warn "FreeSWITCH restart failed"
verbose "FreeSWITCH restarted with corrected switch settings"

# =============================================================================
# Completion
# =============================================================================

verbose ""
verbose "========================================="
verbose " Installation steps completed."
verbose "========================================="
verbose ""
verbose "All installation steps completed successfully!"
