#!/bin/sh

# FusionPBX Alt Linux Installer - Disable Missing FreeSWITCH Modules
# The FusionPBX-provided FreeSWITCH configuration enables many modules
# in modules.conf.xml that don't exist in the Alt Linux RPM packages.
# This script comments out those modules to prevent CRIT errors on startup.
#
# Modules not available in Alt Linux freeswitch-daemon package:
#   - mod_say_* (all language-specific say modules except en/ru if bundled)
#   - mod_local_stream (may not be in the RPM)
#   - mod_flite (TTS, rarely packaged)
#   - mod_shout (MP3 streaming, requires libshout)
#   - mod_memcache (requires libmemcached)
#   - mod_verto (WebRTC, may not be in RPM)
#   - mod_sms (may not be in RPM)
#
# NOTE: mod_pgsql is built from source by source-mod-pgsql.sh (which runs
# BEFORE this script), so it should NOT be disabled. If mod_pgsql.so is
# missing, the build script failed and should be investigated.
#
# This script is idempotent: commenting out already-commented lines is safe.

# Determine script directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Includes
. ../config.sh
. ../colors.sh
. ../util.sh

_fs_conf="/etc/freeswitch"
_modules_conf="$_fs_conf/autoload_configs/modules.conf.xml"

if [ ! -f "$_modules_conf" ]; then
    warn "modules.conf.xml not found at $_modules_conf (skipping module disable)"
    exit 0
fi

verbose "Checking for missing FreeSWITCH modules..."

# List of modules that are commonly NOT available in Alt Linux RPM packages.
# We check each one: if the .so file doesn't exist, comment it out.
_modules_dir="/usr/lib64/freeswitch"

_missing_count=0
_disabled_count=0

# Read all load module lines from modules.conf.xml
while IFS= read -r _line; do
    # Extract module name from <load module="mod_xxx"/> lines
    _mod_name=$(echo "$_line" | sed -n 's/.*<load module="\([^"]*\)".*/\1/p')
    if [ -z "$_mod_name" ]; then
        continue
    fi

    # Check if the .so file exists
    _so_path="$_modules_dir/$_mod_name.so"
    if [ ! -f "$_so_path" ]; then
        # Module not found - comment it out
        _missing_count=$((_missing_count + 1))

        # Check if it's already commented out
        if echo "$_line" | grep -q '<!--.*<load'; then
            verbose "  $_mod_name: missing (already commented out)"
        else
            # Comment out the line
            sed -i "$_modules_conf" -e "s|<load module=\"$_mod_name\"/>|<!-- <load module=\"$_mod_name\"/> -->|g"
            sed -i "$_modules_conf" -e "s|<load module=\"$_mod_name\" />|<!-- <load module=\"$_mod_name\" /> -->|g"
            verbose "  $_mod_name: DISABLED (.so not found at $_so_path)"
            _disabled_count=$((_disabled_count + 1))
        fi
    fi
done < "$_modules_conf"

if [ "$_missing_count" -gt 0 ]; then
    verbose ""
    verbose "  Missing modules: $_missing_count (disabled: $_disabled_count)"
    verbose "  These modules are not available in the Alt Linux FreeSWITCH RPM packages."
    verbose "  The system will work without them, but some features may be unavailable."
else
    verbose "  All configured modules are available"
fi

verbose ""
