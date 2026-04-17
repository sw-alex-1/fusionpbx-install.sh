#!/bin/sh

# FusionPBX Alt Linux Installer - FreeSWITCH systemd Service Setup
# Configures and enables the FreeSWITCH systemd service.
# Uses a custom service unit to ensure correct user/group and
# proper dependency on PostgreSQL.
#
# Alt Linux specifics:
#   - FreeSWITCH user: _nginx:_nginx (same as web server, like Debian's www-data)
#   - Service must start after postgresql.service
#   - The freeswitch-systemd package (if it exists) should be removed
#     to avoid conflicts with our custom unit file.
#
# DESIGN: In Debian, FreeSWITCH runs as www-data (the web server user) so
# that FusionPBX (also running as www-data via PHP-FPM) can read and write
# FreeSWITCH configuration files. We replicate this on Alt Linux by running
# FreeSWITCH as _nginx.

# Determine script directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Includes
. ../config.sh
. ../colors.sh
. ../util.sh

_fs_service="freeswitch"
_fs_unit="/lib/systemd/system/freeswitch.service"
_fs_unit_alt="/etc/systemd/system/freeswitch.service"
_fs_default="/etc/default/freeswitch"
_our_unit="source/freeswitch.service.package"
_our_default="source/etc.default.freeswitch.package"

# =============================================================================
# Remove conflicting freeswitch-systemd package if installed
# The Debian installer does this too - the package-provided unit file
# may have incorrect user/group settings.
# =============================================================================

if pkg_is_installed freeswitch-systemd 2>/dev/null; then
    verbose "Removing conflicting freeswitch-systemd package..."
    apt-get remove -y freeswitch-systemd 2>/dev/null || warn "Failed to remove freeswitch-systemd (may not exist)"
fi

# =============================================================================
# Deploy custom systemd unit file
# We use /etc/systemd/system/ (takes priority over /lib/systemd/system/)
# so that package updates don't overwrite our customizations.
# =============================================================================

verbose "Deploying FreeSWITCH systemd service unit..."

if [ -f "$_our_unit" ]; then
    # Back up existing unit file if it differs from ours
    if [ -f "$_fs_unit_alt" ]; then
        if ! diff -q "$_our_unit" "$_fs_unit_alt" >/dev/null 2>&1; then
            backup_file "$_fs_unit_alt"
        fi
    fi

    # Also check the distro-provided unit in /lib
    if [ -f "$_fs_unit" ] && [ ! -f "$_fs_unit_alt" ]; then
        backup_file "$_fs_unit"
    fi

    cp "$_our_unit" "$_fs_unit_alt"
    chmod 644 "$_fs_unit_alt"
    verbose "Systemd unit deployed to $_fs_unit_alt"
else
    warn "Custom unit file not found: $_our_unit"
    warn "Will try to use existing FreeSWITCH unit file"
fi

# =============================================================================
# Deploy /etc/default/freeswitch
# =============================================================================

if [ -f "$_our_default" ]; then
    if [ -f "$_fs_default" ]; then
        if ! diff -q "$_our_default" "$_fs_default" >/dev/null 2>&1; then
            backup_file "$_fs_default"
        fi
    fi
    cp "$_our_default" "$_fs_default"
    verbose "Default options deployed to $_fs_default"
fi

# =============================================================================
# Handle OpenVZ environments
# OpenVZ does not support real-time CPU scheduling.
# =============================================================================

if [ -e /proc/user_beancounters ]; then
    verbose "OpenVZ detected - disabling CPU real-time scheduling"
    if [ -f "$_fs_unit_alt" ]; then
        sed -i -e "s/CPUSchedulingPolicy=rr/;CPUSchedulingPolicy=rr/g" "$_fs_unit_alt"
    fi
fi

# =============================================================================
# Ensure FreeSWITCH user exists
# The _nginx user should already exist (created by nginx package), but verify.
# FreeSWITCH runs as _nginx (same as web server) so FusionPBX can access
# FreeSWITCH configuration files.
# =============================================================================

if ! id "$fs_user" >/dev/null 2>&1; then
    verbose "FreeSWITCH user ($fs_user) does not exist - creating..."
    useradd -r -s /sbin/nologin -d /var/lib/freeswitch -g "$fs_group" "$fs_user" 2>/dev/null || \
        warn "Failed to create user $fs_user (may already exist as system user)"
else
    verbose "FreeSWITCH user ($fs_user) exists"
fi

# =============================================================================
# Enable and start the service
# =============================================================================

systemctl daemon-reload
systemctl unmask "$_fs_service" 2>/dev/null || true
systemctl enable "$_fs_service" 2>/dev/null || warn "Failed to enable $_fs_service"

# Don't start FreeSWITCH yet - dsn.sh needs to configure it first
# It will be started by finish.sh after all configuration is complete
verbose "FreeSWITCH service enabled (will be started in finish.sh after configuration)"

# =============================================================================
# Summary
# =============================================================================

verbose ""
verbose "FreeSWITCH systemd service summary:"
verbose "  Unit file:  $_fs_unit_alt"
verbose "  Default:    $_fs_default"
verbose "  User:       $fs_user"
verbose "  Group:      $fs_group"
verbose "  Service:    $_fs_service (enabled, not yet started)"
verbose ""
