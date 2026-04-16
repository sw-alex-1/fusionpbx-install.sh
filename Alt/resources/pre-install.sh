#!/bin/sh

# FusionPBX Alt Linux Installer - Pre-Install
# Prepares the system: updates packages, installs base utilities,
# removes cdrom from sources.list, configures basic services.
# Safe for re-runs: all operations are idempotent.

# Determine script directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Includes
. ./config.sh
. ./colors.sh
. ./util.sh
. ./environment.sh

# =============================================================================
# Remove cdrom from APT sources
# Alt Linux may include cdrom in /etc/apt/sources.list after base installation.
# This prevents apt-get from failing when no CD is present.
# =============================================================================

verbose "Checking for cdrom entries in APT sources..."

_sources_file="/etc/apt/sources.list"
if [ -f "$_sources_file" ]; then
    if grep -q 'cdrom:' "$_sources_file" 2>/dev/null; then
        backup_file "$_sources_file"
        verbose "Removing cdrom entries from $_sources_file"
        sed -i '/cdrom:/d' "$_sources_file"
    else
        verbose "No cdrom entries found in $_sources_file"
    fi
fi

# Also check sources.list.d for any cdrom entries
for _src_d_file in /etc/apt/sources.list.d/*.list; do
    if [ -f "$_src_d_file" ] && grep -q 'cdrom:' "$_src_d_file" 2>/dev/null; then
        backup_file "$_src_d_file"
        verbose "Removing cdrom entries from $_src_d_file"
        sed -i '/cdrom:/d' "$_src_d_file"
    fi
done

# =============================================================================
# Update package index and upgrade installed packages
# =============================================================================

verbose "Updating package index..."
apt-get update || warn "apt-get update encountered warnings (may be normal for some repos)"

verbose "Upgrading installed packages..."
apt-get dist-upgrade -y || warn "apt-get dist-upgrade encountered warnings"

# =============================================================================
# Install base utilities
# These are required by the installer itself or are commonly needed.
# pkg_install() skips already-installed packages automatically.
# =============================================================================

verbose "Installing base utilities..."

pkg_install \
    wget \
    git \
    ca-certificates \
    dialog \
    nano \
    net-tools \
    unzip

# Note: 'gpg' command is available in Alt Linux without a separate package

# =============================================================================
# SNMP (optional but useful for monitoring)
# =============================================================================

if pkg_is_installed net-snmp-snmpd; then
    verbose "snmpd is already installed"
else
    verbose "Installing and configuring SNMP..."
    pkg_install net-snmp-snmpd
    if pkg_is_installed net-snmp-snmpd; then
        echo "rocommunity public" > /etc/snmp/snmpd.conf
        service_enable_start snmpd
    fi
fi

# =============================================================================
# Disable vi visual mode (mouse)
# This prevents vi from capturing mouse events, which is confusing in terminal.
# =============================================================================

_vimrc="$HOME/.vimrc"
if [ -f "$_vimrc" ]; then
    if ! grep -q 'mouse-=a' "$_vimrc" 2>/dev/null; then
        verbose "Disabling vi visual mouse mode..."
        echo "set mouse-=a" >> "$_vimrc"
    fi
else
    verbose "Creating .vimrc with mouse mode disabled..."
    echo "set mouse-=a" > "$_vimrc"
fi

# =============================================================================
# Verify base tools are available
# =============================================================================

verbose "Verifying base tools..."

_required_commands="wget git unzip"
_missing=""
for _cmd in $_required_commands; do
    if ! cmd_exists "$_cmd"; then
        _missing="$_missing $_cmd"
    fi
done

if [ -n "$_missing" ]; then
    die "Required commands not found:$_missing - install failed. Check apt-get output above."
fi

verbose "Base system preparation completed."
