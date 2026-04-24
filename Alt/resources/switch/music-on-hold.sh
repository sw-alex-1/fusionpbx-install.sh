#!/bin/sh

# FusionPBX Alt Linux Installer - Music on Hold Verification
# Verifies that v_music_on_hold was populated correctly by app_defaults.
# Falls back to direct SQL inserts if the table is still empty.
#
# Normally, this script is NOT needed because FreeSWITCH starts BEFORE
# finish.sh (matching the Debian installer's approach). When FreeSWITCH
# is running, upgrade.php --defaults can access the event socket and
# app_defaults correctly populates v_music_on_hold.
#
# This script exists as a safety net for:
#   1. Re-runs where FreeSWITCH might not be running
#   2. Edge cases where app_defaults didn't populate the table
#   3. Verification that the installation is correct

# Determine script directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Includes
. "$SCRIPT_DIR/../config.sh"
. "$SCRIPT_DIR/../colors.sh"
. "$SCRIPT_DIR/../util.sh"
. "$SCRIPT_DIR/../environment.sh"

# =============================================================================
# Read database credentials
# =============================================================================

if [ -f "/tmp/fusionpbx_db_credentials" ]; then
    . /tmp/fusionpbx_db_credentials
else
    if [ "$database_password" = "random" ] || [ -z "$database_password" ]; then
        die "Database password not available. Run postgresql.sh first."
    fi
fi

export PGPASSWORD=$database_password

# =============================================================================
# Check v_music_on_hold
# =============================================================================

verbose "Verifying v_music_on_hold table..."

_moh_count=$(runuser -u postgres -- psql -d "$database_name" -tAc \
    "SELECT count(*) FROM v_music_on_hold;" 2>/dev/null)

if [ -n "$_moh_count" ] && [ "$_moh_count" -gt 0 ] 2>/dev/null; then
    verbose "  v_music_on_hold has $_moh_count rows (OK - app_defaults populated it)"
    unset PGPASSWORD
    exit 0
fi

# Table is empty — fall back to direct SQL inserts
verbose "  v_music_on_hold is empty (app_defaults did not populate it)"
verbose "  Inserting default music on hold entries via SQL..."

# Get the domain UUID
_domain_uuid=$(runuser -u postgres -- psql -d "$database_name" -tAc \
    "SELECT domain_uuid FROM v_domains LIMIT 1;" 2>/dev/null)

# Get sounds_dir
_sounds_dir="/usr/share/freeswitch/sounds"

# Insert default entries (matching FusionPBX's bundled local_stream.conf)
# Use resolved paths instead of $${sounds_dir} which gets mangled by shell
for _rate in 8000 16000 32000 48000; do
    _moh_uuid=$(/usr/bin/php /var/www/fusionpbx/resources/uuid.php 2>/dev/null || cat /proc/sys/kernel/random/uuid)
    _moh_path="${_sounds_dir}/music/default/${_rate}"

    if [ -n "$_domain_uuid" ]; then
        runuser -u postgres -- psql -d "$database_name" -c \
            "INSERT INTO v_music_on_hold (music_on_hold_uuid, domain_uuid, music_on_hold_name, music_on_hold_rate, music_on_hold_shuffle, music_on_hold_timer_name, music_on_hold_path)
             VALUES ('$_moh_uuid', '$_domain_uuid', 'default', '$_rate', 'true', 'soft', '$_moh_path');" 2>/dev/null
    else
        runuser -u postgres -- psql -d "$database_name" -c \
            "INSERT INTO v_music_on_hold (music_on_hold_uuid, music_on_hold_name, music_on_hold_rate, music_on_hold_shuffle, music_on_hold_timer_name, music_on_hold_path)
             VALUES ('$_moh_uuid', 'default', '$_rate', 'true', 'soft', '$_moh_path');" 2>/dev/null
    fi

    verbose "  Inserted: default/$_rate"
done

# Verify
_moh_count=$(runuser -u postgres -- psql -d "$database_name" -tAc \
    "SELECT count(*) FROM v_music_on_hold;" 2>/dev/null)
verbose "  v_music_on_hold now has $_moh_count rows"

# Clear cache so XML handler regenerates
if [ -d "/var/cache/fusionpbx" ]; then
    rm -rf /var/cache/fusionpbx/*
    verbose "  FusionPBX cache cleared"
fi

unset PGPASSWORD
