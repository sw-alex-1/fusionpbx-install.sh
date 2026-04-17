#!/bin/sh

# FusionPBX Alt Linux Installer - FreeSWITCH Configuration Copy
# Replaces the default FreeSWITCH configuration with the
# FusionPBX-provided configuration from the web application.
# Safe for re-runs: backs up existing config before replacing.

# Determine script directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Includes
. ../config.sh
. ../colors.sh
. ../util.sh

_fs_conf_dir="/etc/freeswitch"
_fpbx_conf_source="/var/www/fusionpbx/app/switch/resources/conf"

# =============================================================================
# Check that FusionPBX is installed
# =============================================================================

if [ ! -d "$_fpbx_conf_source" ]; then
    die "FusionPBX switch config not found at $_fpbx_conf_source. Run fusionpbx.sh first."
fi

# =============================================================================
# Backup existing FreeSWITCH config
# Only backup once — if .orig already exists, the original is safe.
# =============================================================================

if [ -d "$_fs_conf_dir" ]; then
    if [ ! -d "${_fs_conf_dir}.orig" ]; then
        verbose "Backing up default FreeSWITCH config to ${_fs_conf_dir}.orig"
        mv "$_fs_conf_dir" "${_fs_conf_dir}.orig"
    else
        # .orig already exists — this is a re-run
        # Remove the current config (it was replaced on a previous run)
        verbose "Removing previously deployed FreeSWITCH config"
        rm -rf "$_fs_conf_dir"
    fi
fi

# =============================================================================
# Deploy FusionPBX-provided FreeSWITCH config
# =============================================================================

verbose "Deploying FusionPBX FreeSWITCH configuration..."

mkdir -p "$_fs_conf_dir"
cp -R "$_fpbx_conf_source"/* "$_fs_conf_dir"/

if [ -d "$_fs_conf_dir" ] && [ "$(ls -A "$_fs_conf_dir" 2>/dev/null)" ]; then
    verbose "FusionPBX FreeSWITCH configuration deployed to $_fs_conf_dir"
    verbose "  Original config backed up at ${_fs_conf_dir}.orig"
else
    die "Failed to deploy FusionPBX FreeSWITCH configuration"
fi
