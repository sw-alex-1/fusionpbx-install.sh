#!/bin/sh

# FusionPBX Alt Linux Installer - FreeSWITCH Dispatcher
# Determines which FreeSWITCH installation method to use.
# For Alt Linux, the main FreeSWITCH is installed from RPM packages,
# but mod_pgsql must be compiled from source because the Alt Linux
# repository does not include a freeswitch-mod-pgsql package.

# Determine script directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Includes
. ./config.sh
. ./colors.sh
. ./util.sh

# =============================================================================
# FreeSWITCH installation - RPM packages + mod_pgsql from source
#
# Alt Linux has FreeSWITCH RPM packages in the system repository,
# but they do NOT include mod_pgsql.so. Without mod_pgsql, FreeSWITCH
# cannot connect to PostgreSQL, making FusionPBX non-functional.
#
# On Debian/Ubuntu, a separate freeswitch-mod-pgsql package exists.
# On Alt Linux, we must compile mod_pgsql from source.
# =============================================================================

if [ "$switch_package" = "true" ]; then
    verbose "Installing FreeSWITCH from RPM packages..."
    switch/package-release.sh

    # Copy the FusionPBX-provided FreeSWITCH configuration
    switch/conf-copy.sh

    # Build and install mod_pgsql from source
    # This is CRITICAL: without mod_pgsql, FreeSWITCH cannot connect to
    # PostgreSQL and FusionPBX will be completely non-functional.
    # Must run AFTER package-release.sh (needs installed FreeSWITCH headers)
    # Must run BEFORE disable-missing-modules.sh (so the .so file exists)
    verbose "Building mod_pgsql from source (not included in Alt Linux RPMs)..."
    switch/source-mod-pgsql.sh

    # Disable modules that don't exist in Alt Linux RPM packages
    # Note: mod_pgsql.so now exists (built above), so it won't be disabled
    switch/disable-missing-modules.sh

    # Set file permissions for FreeSWITCH directories
    switch/package-permissions.sh

    # Configure and start the systemd service
    switch/package-systemd.sh
else
    warn "switch_package=false but source build is not supported on Alt Linux"
    warn "Setting switch_package=true and proceeding with RPM installation"
    switch_package=true
    switch/package-release.sh
    switch/conf-copy.sh
    switch/source-mod-pgsql.sh
    switch/disable-missing-modules.sh
    switch/package-permissions.sh
    switch/package-systemd.sh
fi
