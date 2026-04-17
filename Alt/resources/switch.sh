#!/bin/sh

# FusionPBX Alt Linux Installer - FreeSWITCH Dispatcher
# Determines which FreeSWITCH installation method to use.
# For Alt Linux, only RPM package installation is supported
# (source compilation is not needed since RPMs are available).

# Determine script directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Includes
. ./config.sh
. ./colors.sh
. ./util.sh

# =============================================================================
# FreeSWITCH installation - RPM packages only
# Alt Linux has FreeSWITCH RPM packages in the system repository,
# so we never need to compile from source.
# =============================================================================

if [ "$switch_package" = "true" ]; then
    verbose "Installing FreeSWITCH from RPM packages..."
    switch/package-release.sh

    # Copy the FusionPBX-provided FreeSWITCH configuration
    switch/conf-copy.sh

    # Disable modules that don't exist in Alt Linux RPM packages
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
    switch/disable-missing-modules.sh
    switch/package-permissions.sh
    switch/package-systemd.sh
fi
