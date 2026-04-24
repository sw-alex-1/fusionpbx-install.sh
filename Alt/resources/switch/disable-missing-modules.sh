#!/bin/sh

# FusionPBX Alt Linux Installer - Disable Missing FreeSWITCH Modules
# The FusionPBX-provided FreeSWITCH configuration enables many modules
# that don't exist in the Alt Linux RPM packages. This script comments
# out those modules to prevent CRIT errors on startup.
#
# It checks TWO configuration files:
#   - pre_load_modules.conf.xml (loaded first — contains mod_pgsql)
#   - modules.conf.xml (loaded second — contains all other modules)
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
. "$SCRIPT_DIR/../config.sh"
. "$SCRIPT_DIR/../colors.sh"
. "$SCRIPT_DIR/../util.sh"

_fs_conf="/etc/freeswitch"
_modules_dir="/usr/lib64/freeswitch"

# =============================================================================
# Function: check_and_disable_missing_modules
# Reads a modules config file and comments out modules whose .so files
# don't exist in _modules_dir.
# =============================================================================
check_and_disable_missing_modules() {
    _conf_file="$1"
    _label="$2"

    if [ ! -f "$_conf_file" ]; then
        verbose "  $_label not found at $_conf_file (skipping)"
        return
    fi

    verbose "  Checking $_label..."

    _file_missing=0
    _file_disabled=0

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
            _file_missing=$((_file_missing + 1))

            # Check if it's already commented out
            if echo "$_line" | grep -q '<!--.*<load'; then
                verbose "    $_mod_name: missing (already commented out)"
            else
                # Comment out the line
                sed -i "$_conf_file" -e "s|<load module=\"$_mod_name\"/>|<!-- <load module=\"$_mod_name\"/> -->|g"
                sed -i "$_conf_file" -e "s|<load module=\"$_mod_name\" />|<!-- <load module=\"$_mod_name\" /> -->|g"
                verbose "    $_mod_name: DISABLED (.so not found at $_so_path)"
                _file_disabled=$((_file_disabled + 1))
            fi
        fi
    done < "$_conf_file"

    if [ "$_file_disabled" -gt 0 ]; then
        verbose "    $_label: disabled $_file_disabled missing modules"
    elif [ "$_file_missing" -eq 0 ]; then
        verbose "    $_label: all configured modules are available"
    fi
}

# =============================================================================
# Main: check both module configuration files
# =============================================================================

verbose "Checking for missing FreeSWITCH modules..."

# Check pre_load_modules.conf.xml first (contains mod_pgsql and other
# pre-load modules — these must be loaded before modules.conf.xml)
check_and_disable_missing_modules \
    "$_fs_conf/autoload_configs/pre_load_modules.conf.xml" \
    "pre_load_modules.conf.xml"

# Check modules.conf.xml (the main module list)
check_and_disable_missing_modules \
    "$_fs_conf/autoload_configs/modules.conf.xml" \
    "modules.conf.xml"

verbose ""
