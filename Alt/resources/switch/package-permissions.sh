#!/bin/sh

# FusionPBX Alt Linux Installer - FreeSWITCH File Permissions
# Sets correct ownership for all FreeSWITCH directories.
# The _pbx:_pbx user/group is the Alt Linux default for FreeSWITCH.
# Safe for re-runs: chown -R is idempotent.

# Determine script directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Includes
. ../config.sh
. ../colors.sh
. ../util.sh

verbose "Setting FreeSWITCH file permissions..."

# FreeSWITCH directories that must be owned by the FreeSWITCH user
# so that the daemon can read/write configuration, logs, and data.
_fs_dirs="
/etc/freeswitch
/var/lib/freeswitch
/usr/share/freeswitch
/var/log/freeswitch
/var/run/freeswitch
"

for _dir in $_fs_dirs; do
    if [ -d "$_dir" ]; then
        chown -R "$fs_user:$fs_group" "$_dir"
        verbose "  $_dir -> $fs_user:$fs_group"
    else
        # Create directory if it doesn't exist yet
        ensure_dir "$_dir" "$fs_user:$fs_group"
        verbose "  $_dir -> created ($fs_user:$fs_group)"
    fi
done

# FusionPBX cache directory - web user needs access
if [ -d "/var/cache/fusionpbx" ]; then
    chown -R "$web_user:$web_group" /var/cache/fusionpbx
    verbose "  /var/cache/fusionpbx -> $web_user:$web_group"
fi

verbose "FreeSWITCH file permissions set"
