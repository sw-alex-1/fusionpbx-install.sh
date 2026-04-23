#!/bin/sh

# FusionPBX Alt Linux Installer - Music on Hold Configuration
# Populates v_music_on_hold table with default entries so that
# mod_local_stream can load successfully.
#
# Background:
#   On Debian, the app_defaults mechanism in FusionPBX populates
#   v_music_on_hold by reading FreeSWITCH's local_stream.conf XML.
#   However, on Alt Linux this fails because:
#     1. When upgrade.php --defaults first runs, FreeSWITCH is not running
#     2. The switch settings in v_default_settings are empty
#     3. $settings->get('switch','conf') returns empty
#     4. The entire music_on_hold app_defaults block is skipped
#     5. Even after re-running upgrade.php --defaults with FS running,
#        the mechanism may not work due to settings caching or ordering issues
#
#   Without v_music_on_hold entries, the FusionPBX XML handler generates
#   an empty <configuration> with no <directory> elements for local_stream.
#   mod_local_stream then calls launch_streams(NULL), finds nothing to
#   launch, and returns SWITCH_STATUS_GENERR (CRIT error).
#
# This script:
#   1. Creates symlink /usr/local/etc/fusionpbx -> /etc/fusionpbx
#      (FusionPBX Lua scripts hardcode /usr/local/etc/fusionpbx as fallback)
#   2. Ensures the switch.conf default setting exists with correct value
#   3. Re-runs upgrade.php --defaults so app_defaults can use the setting
#   4. If v_music_on_hold is STILL empty, inserts default entries via SQL
#   5. Clears FusionPBX cache so XML handler regenerates configuration

# Determine script directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Includes
. ../config.sh
. ../colors.sh
. ../util.sh
. ../environment.sh

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
# 1. Create symlink for FusionPBX Lua scripts
# FusionPBX's Lua scripts look for config.conf at:
#   /usr/local/etc/fusionpbx/config.conf (hardcoded fallback path)
# But on Alt Linux, config.conf is at:
#   /etc/fusionpbx/config.conf
# Creating a symlink ensures the Lua scripts can find the config.
# =============================================================================

verbose "Creating config.conf path symlink for Lua scripts..."

_local_etc_fpbx="/usr/local/etc/fusionpbx"
_etc_fpbx="/etc/fusionpbx"

if [ -f "$_etc_fpbx/config.conf" ]; then
    if [ ! -e "$_local_etc_fpbx" ]; then
        mkdir -p /usr/local/etc
        ln -s "$_etc_fpbx" "$_local_etc_fpbx"
        verbose "  Symlink created: $_local_etc_fpbx -> $_etc_fpbx"
    elif [ -L "$_local_etc_fpbx" ]; then
        _target=$(readlink "$_local_etc_fpbx")
        if [ "$_target" = "$_etc_fpbx" ]; then
            verbose "  Symlink already exists: $_local_etc_fpbx -> $_etc_fpbx"
        else
            warn "  Symlink exists but points to $_target (expected $_etc_fpbx)"
            warn "  Replacing symlink..."
            rm -f "$_local_etc_fpbx"
            ln -s "$_etc_fpbx" "$_local_etc_fpbx"
            verbose "  Symlink updated: $_local_etc_fpbx -> $_etc_fpbx"
        fi
    elif [ -d "$_local_etc_fpbx" ]; then
        # Directory exists but is not a symlink — copy config if missing
        if [ ! -f "$_local_etc_fpbx/config.conf" ]; then
            cp "$_etc_fpbx/config.conf" "$_local_etc_fpbx/config.conf"
            verbose "  Copied config.conf to $_local_etc_fpbx"
        else
            verbose "  config.conf exists at $_local_etc_fpbx (keeping existing)"
        fi
    fi
else
    warn "  config.conf not found at $_etc_fpbx (skipping symlink creation)"
fi

# =============================================================================
# 2. Ensure switch.conf default setting exists in v_default_settings
# The app/music_on_hold/app_defaults.php checks $settings->get('switch','conf')
# which reads from v_default_settings. If the value is empty, the entire
# music_on_hold block is skipped.
#
# On Alt Linux, when upgrade.php first runs without FreeSWITCH running,
# the switch settings get empty values. We need to ensure they have
# correct values before the music_on_hold app_defaults runs.
# =============================================================================

verbose "Ensuring switch default settings have correct values..."

_switch_conf_value="/etc/freeswitch"
_switch_sounds_value="/usr/share/freeswitch/sounds"

# Check current values
_switch_conf_current=$(runuser -u postgres -- psql -d "$database_name" -tAc \
    "SELECT default_setting_value FROM v_default_settings
     WHERE default_setting_category = 'switch' AND default_setting_subcategory = 'conf';" 2>/dev/null)

if [ -z "$_switch_conf_current" ] || [ "$_switch_conf_current" = "" ]; then
    # Value is empty or doesn't exist — update it
    verbose "  switch.conf is empty, updating to $_switch_conf_value"

    # First try UPDATE (if the row exists but has empty value)
    _updated=$(runuser -u postgres -- psql -d "$database_name" -tAc \
        "UPDATE v_default_settings SET default_setting_value = '$_switch_conf_value'
         WHERE default_setting_category = 'switch' AND default_setting_subcategory = 'conf'
         RETURNING default_setting_uuid;" 2>/dev/null)

    if [ -z "$_updated" ]; then
        # Row doesn't exist — INSERT it
        _setting_uuid=$(/usr/bin/php /var/www/fusionpbx/resources/uuid.php 2>/dev/null || uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)
        runuser -u postgres -- psql -d "$database_name" -c \
            "INSERT INTO v_default_settings (default_setting_uuid, default_setting_category, default_setting_subcategory, default_setting_name, default_setting_value, default_setting_enabled)
             VALUES ('$_setting_uuid', 'switch', 'conf', 'dir', '$_switch_conf_value', 'true');" 2>/dev/null
        verbose "  INSERTED switch.conf = $_switch_conf_value"
    else
        verbose "  UPDATED switch.conf = $_switch_conf_value"
    fi
else
    verbose "  switch.conf = $_switch_conf_current (OK)"
fi

# Also check switch.sounds
_switch_sounds_current=$(runuser -u postgres -- psql -d "$database_name" -tAc \
    "SELECT default_setting_value FROM v_default_settings
     WHERE default_setting_category = 'switch' AND default_setting_subcategory = 'sounds';" 2>/dev/null)

if [ -z "$_switch_sounds_current" ] || [ "$_switch_sounds_current" = "" ]; then
    verbose "  switch.sounds is empty, updating to $_switch_sounds_value"

    _updated=$(runuser -u postgres -- psql -d "$database_name" -tAc \
        "UPDATE v_default_settings SET default_setting_value = '$_switch_sounds_value'
         WHERE default_setting_category = 'switch' AND default_setting_subcategory = 'sounds'
         RETURNING default_setting_uuid;" 2>/dev/null)

    if [ -z "$_updated" ]; then
        _setting_uuid=$(/usr/bin/php /var/www/fusionpbx/resources/uuid.php 2>/dev/null || uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)
        runuser -u postgres -- psql -d "$database_name" -c \
            "INSERT INTO v_default_settings (default_setting_uuid, default_setting_category, default_setting_subcategory, default_setting_name, default_setting_value, default_setting_enabled)
             VALUES ('$_setting_uuid', 'switch', 'sounds', 'dir', '$_switch_sounds_value', 'true');" 2>/dev/null
        verbose "  INSERTED switch.sounds = $_switch_sounds_value"
    else
        verbose "  UPDATED switch.sounds = $_switch_sounds_value"
    fi
else
    verbose "  switch.sounds = $_switch_sounds_current (OK)"
fi

# Update any other empty switch settings from config.conf values
# These are needed by various FusionPBX XML handlers
verbose "Updating other empty switch settings from config.conf..."

for _subcat in db recordings storage voicemail scripts log mod; do
    case "$_subcat" in
        db)       _value="/var/lib/freeswitch/db" ;;
        recordings) _value="/var/lib/freeswitch/recordings" ;;
        storage)  _value="/var/lib/freeswitch/storage" ;;
        voicemail) _value="/var/lib/freeswitch/storage/voicemail" ;;
        scripts)  _value="/usr/share/freeswitch/scripts" ;;
        log)      _value="/var/log/freeswitch" ;;
        mod)      _value="/usr/lib64/freeswitch" ;;
        *)        continue ;;
    esac

    _current=$(runuser -u postgres -- psql -d "$database_name" -tAc \
        "SELECT default_setting_value FROM v_default_settings
         WHERE default_setting_category = 'switch' AND default_setting_subcategory = '$_subcat';" 2>/dev/null)

    if [ -z "$_current" ] || [ "$_current" = "" ]; then
        runuser -u postgres -- psql -d "$database_name" -c \
            "UPDATE v_default_settings SET default_setting_value = '$_value'
             WHERE default_setting_category = 'switch' AND default_setting_subcategory = '$_subcat'
             AND (default_setting_value IS NULL OR default_setting_value = '');" 2>/dev/null
        verbose "  switch.$_subcat updated to $_value"
    fi
done

# =============================================================================
# 3. Clear FusionPBX cache and re-run app defaults
# With the switch.conf setting now populated, the music_on_hold app_defaults
# should be able to read local_stream.conf and populate v_music_on_hold.
# =============================================================================

verbose "Clearing FusionPBX cache before re-running app defaults..."

if [ -d "/var/cache/fusionpbx" ]; then
    rm -rf /var/cache/fusionpbx/*
    verbose "  Cache cleared"
fi

verbose "Re-running app defaults to populate music_on_hold..."

cd /var/www/fusionpbx && /usr/bin/php /var/www/fusionpbx/core/upgrade/upgrade.php --defaults 2>&1 | while read -r _line; do
    # Only show important lines (errors, warnings, or key messages)
    case "$_line" in
        *error*|*Error*|*ERROR*|*Fatal*|*warning*|*Warning*)
            verbose "  [app_defaults] $_line"
            ;;
    esac
done

# =============================================================================
# 4. Check if v_music_on_hold was populated
# If the app_defaults mechanism worked, the table should have rows.
# If it's still empty, fall back to direct SQL inserts.
# =============================================================================

verbose "Checking v_music_on_hold table..."

_moh_count=$(runuser -u postgres -- psql -d "$database_name" -tAc \
    "SELECT count(*) FROM v_music_on_hold;" 2>/dev/null)

if [ -n "$_moh_count" ] && [ "$_moh_count" -gt 0 ] 2>/dev/null; then
    verbose "  v_music_on_hold has $_moh_count rows (app_defaults worked)"
else
    verbose "  v_music_on_hold is empty (app_defaults didn't populate it)"
    verbose "  Inserting default music on hold entries via SQL..."

    # Get the domain UUID (needed for the music_on_hold entries)
    _domain_uuid=$(runuser -u postgres -- psql -d "$database_name" -tAc \
        "SELECT domain_uuid FROM v_domains LIMIT 1;" 2>/dev/null)

    if [ -z "$_domain_uuid" ]; then
        warn "  No domain found in v_domains — inserting without domain_uuid"
    fi

    # Get sounds_dir from FreeSWITCH settings or use default
    _sounds_dir="/usr/share/freeswitch/sounds"

    # Insert default music on hold entries
    # These correspond to the entries in FusionPBX's bundled local_stream.conf
    # Stream name "default" with rates 8000, 16000, 32000, 48000
    #
    # IMPORTANT: Use the resolved path (e.g. /usr/share/freeswitch/sounds/music/default/8000)
    # instead of $${sounds_dir}/music/default/8000 because:
    #   1. In a double-quoted shell string, $$ becomes the PID and ${sounds_dir}
    #      becomes an empty shell variable expansion — the path would be corrupted.
    #   2. The resolved path is what FreeSWITCH expands $${sounds_dir} to anyway.
    #   3. When users add MoH via the FusionPBX web interface, paths are stored
    #      resolved (not as FreeSWITCH variables).
    for _rate in 8000 16000 32000 48000; do
        _moh_uuid=$(/usr/bin/php /var/www/fusionpbx/resources/uuid.php 2>/dev/null || cat /proc/sys/kernel/random/uuid)
        _moh_path="${_sounds_dir}/music/default/${_rate}"

        if [ -n "$_domain_uuid" ]; then
            runuser -u postgres -- psql -d "$database_name" -c \
                "INSERT INTO v_music_on_hold (music_on_hold_uuid, domain_uuid, music_on_hold_name, music_on_hold_rate, music_on_hold_shuffle, music_on_hold_timer_name, music_on_hold_chime_list, music_on_hold_chime_freq, music_on_hold_chime_max, music_on_hold_path)
                 VALUES ('$_moh_uuid', '$_domain_uuid', 'default', '$_rate', 'true', 'soft', NULL, NULL, NULL, '$_moh_path');" 2>/dev/null
        else
            runuser -u postgres -- psql -d "$database_name" -c \
                "INSERT INTO v_music_on_hold (music_on_hold_uuid, music_on_hold_name, music_on_hold_rate, music_on_hold_shuffle, music_on_hold_timer_name, music_on_hold_chime_list, music_on_hold_chime_freq, music_on_hold_chime_max, music_on_hold_path)
                 VALUES ('$_moh_uuid', 'default', '$_rate', 'true', 'soft', NULL, NULL, NULL, '$_moh_path');" 2>/dev/null
        fi

        verbose "  Inserted: default/$_rate -> $_moh_path"
    done

    # Verify the insert
    _moh_count=$(runuser -u postgres -- psql -d "$database_name" -tAc \
        "SELECT count(*) FROM v_music_on_hold;" 2>/dev/null)
    verbose "  v_music_on_hold now has $_moh_count rows"
fi

# =============================================================================
# 5. Ensure the bundled local_stream.conf exists for future app_defaults runs
# The app/music_on_hold/app_defaults.php looks for:
#   1. /etc/freeswitch/autoload_configs/local_stream.conf (note: without .xml)
#   2. Fallback: /var/www/fusionpbx/app/switch/resources/conf/autoload_configs/local_stream.conf
#
# FreeSWITCH package creates local_stream.conf.xml (with .xml extension),
# but the app_defaults code looks for local_stream.conf (without .xml).
# The bundled fallback file should exist from the FusionPBX git clone,
# but we verify it here.
# =============================================================================

verbose "Verifying local_stream.conf availability..."

_bundle_conf="/var/www/fusionpbx/app/switch/resources/conf/autoload_configs/local_stream.conf"
_fs_conf="/etc/freeswitch/autoload_configs/local_stream.conf"
_fs_conf_xml="/etc/freeswitch/autoload_configs/local_stream.conf.xml"

if [ ! -f "$_bundle_conf" ] && [ ! -f "$_fs_conf" ]; then
    # Neither the bundled conf nor the FS conf exists
    # Create the bundled directory structure and file
    verbose "  Creating bundled local_stream.conf for app_defaults fallback..."

    mkdir -p "$(dirname "$_bundle_conf")"

    cat > "$_bundle_conf" << 'LOCALSTREAM_EOF'
<configuration name="local_stream.conf" description="stream files from local dir">

        <!-- fallback to default if requested moh class isn't found -->
        <directory name="default" path="$${sounds_dir}/music/default/8000">
                <param name="rate" value="8000"/>
                <param name="shuffle" value="true"/>
                <param name="channels" value="1"/>
                <param name="interval" value="20"/>
                <param name="timer-name" value="soft"/>
        </directory>

        <directory name="default" path="$${sounds_dir}/music/default/16000">
                <param name="rate" value="16000"/>
                <param name="shuffle" value="true"/>
                <param name="channels" value="1"/>
                <param name="interval" value="20"/>
                <param name="timer-name" value="soft"/>
        </directory>

        <directory name="default" path="$${sounds_dir}/music/default/32000">
                <param name="rate" value="32000"/>
                <param name="shuffle" value="true"/>
                <param name="channels" value="1"/>
                <param name="interval" value="20"/>
                <param name="timer-name" value="soft"/>
        </directory>

        <directory name="default" path="$${sounds_dir}/music/default/48000">
                <param name="rate" value="48000"/>
                <param name="shuffle" value="true"/>
                <param name="channels" value="1"/>
                <param name="interval" value="10"/>
                <param name="timer-name" value="soft"/>
        </directory>

</configuration>
LOCALSTREAM_EOF

    chown "$web_user:$web_group" "$_bundle_conf"
    verbose "  Created $_bundle_conf"
else
    verbose "  local_stream.conf available (app_defaults can use it)"
fi

# =============================================================================
# 6. Final cache clear
# Ensure the FusionPBX XML handler cache is cleared so it regenerates
# the local_stream.conf with the new v_music_on_hold entries.
# =============================================================================

verbose "Clearing FusionPBX cache for XML handler refresh..."

if [ -d "/var/cache/fusionpbx" ]; then
    rm -rf /var/cache/fusionpbx/*
    verbose "  Cache cleared"
fi

# Unset PGPASSWORD for security
unset PGPASSWORD

# =============================================================================
# Summary
# =============================================================================

verbose ""
verbose "Music on Hold configuration summary:"
verbose "  config.conf symlink:  $([ -L "$_local_etc_fpbx" ] && echo "yes" || echo "no")"
verbose "  switch.conf setting:  $([ -n "$_switch_conf_current" ] && echo "$_switch_conf_current" || echo "$_switch_conf_value")"
verbose "  v_music_on_hold rows: $_moh_count"
verbose "  local_stream.conf:    $([ -f "$_bundle_conf" ] && echo "bundled" || echo "$([ -f "$_fs_conf" ] && echo "FS config" || echo "N/A")")"
verbose "  FusionPBX cache:      cleared"
verbose ""
