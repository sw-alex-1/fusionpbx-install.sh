#!/bin/sh

# FusionPBX Alt Linux Installer - FreeSWITCH File Permissions
# Sets correct ownership for all FreeSWITCH directories.
#
# CRITICAL DESIGN DECISION:
# In the Debian installer, ALL FreeSWITCH files are owned by www-data:www-data
# (the web server user). FreeSWITCH is also started as www-data. This is
# necessary because FusionPBX (running as www-data via PHP-FPM) must be able
# to read and write FreeSWITCH configuration files, scripts, and recordings.
#
# On Alt Linux, we replicate this pattern:
#   - FreeSWITCH files are owned by _nginx:_nginx (the web server user)
#   - FreeSWITCH is started as _nginx:_nginx (via the systemd unit file)
#   - This ensures both FreeSWITCH and FusionPBX (PHP-FPM) can access
#     all the same files without permission conflicts
#
# Previously, we used _pbx:_pbx which caused FusionPBX to be unable to
# read/write FreeSWITCH configuration, leading to an "uncontrollable" system.

# Determine script directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Includes
. "$SCRIPT_DIR/../config.sh"
. "$SCRIPT_DIR/../colors.sh"
. "$SCRIPT_DIR/../util.sh"

verbose "Setting FreeSWITCH file permissions..."

# FreeSWITCH directories that must be owned by the web user
# so that BOTH the FreeSWITCH daemon AND FusionPBX (PHP-FPM) can
# read/write configuration, logs, recordings, and data.
#
# IMPORTANT: We use $web_user:$web_group (_nginx:_nginx), NOT _pbx:_pbx.
# The systemd unit file (freeswitch.service.package) must also use
# _nginx:_nginx as USER/GROUP for consistency.
_fs_dirs="
/etc/freeswitch
/var/lib/freeswitch
/usr/share/freeswitch
/var/log/freeswitch
/var/run/freeswitch
"

for _dir in $_fs_dirs; do
    if [ -d "$_dir" ]; then
        chown -R "$web_user:$web_group" "$_dir"
        verbose "  $_dir -> $web_user:$web_group"
    else
        # Create directory if it doesn't exist yet
        ensure_dir "$_dir" "$web_user:$web_group"
        verbose "  $_dir -> created ($web_user:$web_group)"
    fi
done

# FusionPBX cache directory - web user needs access
if [ -d "/var/cache/fusionpbx" ]; then
    chown -R "$web_user:$web_group" /var/cache/fusionpbx
    verbose "  /var/cache/fusionpbx -> $web_user:$web_group"
fi

verbose "FreeSWITCH file permissions set (owner: $web_user:$web_group)"
verbose "  Note: FreeSWITCH will run as $web_user:$web_group (same as in Debian where it runs as www-data)"
