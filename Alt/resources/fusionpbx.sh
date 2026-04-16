#!/bin/sh

# FusionPBX Alt Linux Installer - FusionPBX Application
# Downloads and installs the FusionPBX web application from Git.
# Safe for re-runs: skips git clone if directory already exists.
#
# Alt Linux specifics:
#   - No ssl-cert package (already handled in nginx.sh with self-signed)
#   - No libtiff5-dev (dev package not needed for runtime)
#   - Some packages (qrencode, libtiff-tools, at) are optional
#   - File ownership: _nginx:_nginx (web server user, not www-data)

# Determine script directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Includes
. ./config.sh
. ./colors.sh
. ./util.sh
. ./environment.sh

# =============================================================================
# Install FusionPBX dependencies
# Split into: required (must have) and optional (nice to have)
# =============================================================================

verbose "Installing FusionPBX dependencies..."

# Required packages - these are known to exist in Alt Linux
# Some were already installed in pre-install.sh, pkg_install skips them
pkg_install \
    git \
    vim-console \
    ghostscript \
    sox \
    haveged \
    ffmpeg

# Optional packages - may or may not be available in Alt Linux repos
# We try to install them but do not fail if they're unavailable
_optional_pkgs="qrencode libtiff-tools at dbus"
for _pkg in $_optional_pkgs; do
    if apt-cache show "$_pkg" >/dev/null 2>&1; then
        pkg_install "$_pkg"
    else
        warn "Optional package '$_pkg' not found in repository (skipping)"
    fi
done

# =============================================================================
# Ensure haveged is running (important for entropy on VMs)
# FusionPBX and FreeSWITCH need good entropy for random number generation.
# =============================================================================

if pkg_is_installed haveged; then
    service_enable_start haveged
    verbose "haveged service is running (entropy daemon)"
else
    warn "haveged not installed - random number generation may be slow on VMs"
fi

# =============================================================================
# Get the FusionPBX source code
# Use the configured branch (system_branch from config.sh).
# Idempotent: skip git clone if /var/www/fusionpbx already exists with content.
# =============================================================================

verbose "Downloading FusionPBX source code..."

_fpbx_dir="/var/www/fusionpbx"

if [ -d "$_fpbx_dir/.git" ]; then
    verbose "FusionPBX already cloned at $_fpbx_dir (skipping git clone)"
    # Optionally update the existing checkout
    verbose "Updating existing FusionPBX checkout..."
    cd "$_fpbx_dir"
    git pull 2>/dev/null || warn "Failed to update FusionPBX (may be offline or modified)"
    cd "$SCRIPT_DIR"
elif [ -d "$_fpbx_dir" ] && [ "$(ls -A "$_fpbx_dir" 2>/dev/null)" ]; then
    # Directory exists but is not a git repo - could be from a failed previous run
    warn "Directory $_fpbx_dir exists but is not a git repository"
    warn "Backing up and re-cloning..."
    backup_file "$_fpbx_dir"
    rm -rf "$_fpbx_dir"

    # Determine the branch to clone
    if [ "$system_branch" = "master" ]; then
        verbose "Using master branch"
        _branch=""
    else
        verbose "Using branch: $system_branch"
        _branch="-b $system_branch"
    fi

    git clone $_branch https://github.com/fusionpbx/fusionpbx.git "$_fpbx_dir"
    if [ ! -d "$_fpbx_dir/.git" ]; then
        die "Failed to clone FusionPBX repository"
    fi
else
    # Fresh clone
    if [ "$system_branch" = "master" ]; then
        verbose "Using master branch"
        _branch=""
    else
        verbose "Using branch: $system_branch"
        _branch="-b $system_branch"
    fi

    git clone $_branch https://github.com/fusionpbx/fusionpbx.git "$_fpbx_dir"
    if [ ! -d "$_fpbx_dir/.git" ]; then
        die "Failed to clone FusionPBX repository"
    fi
    verbose "FusionPBX cloned successfully"
fi

# =============================================================================
# Create cache directory
# FusionPBX uses /var/cache/fusionpbx for template caching and other data.
# =============================================================================

verbose "Creating FusionPBX cache directory..."
ensure_dir "/var/cache/fusionpbx" "$web_user:$web_group"

# =============================================================================
# Set file ownership
# FusionPBX files must be owned by the web server user (_nginx) so that
# PHP-FPM can write to them (uploads, cache, config, etc.).
# FreeSWITCH directories will be handled separately in switch.sh.
# =============================================================================

verbose "Setting FusionPBX file ownership..."
chown -R "$web_user:$web_group" "$_fpbx_dir"
verbose "  $_fpbx_dir -> $web_user:$web_group"

# =============================================================================
# Deploy FusionPBX configuration (config.conf)
# Only deploy if config.conf doesn't already exist with real values.
# The template uses {placeholder} variables that are replaced by finish.sh.
# =============================================================================

_fpbx_config="$_fpbx_dir/resources/config.conf"

if [ -f "$_fpbx_config" ] && ! grep -q '{database_' "$_fpbx_config" 2>/dev/null; then
    # Config exists and has been personalized (no {placeholders} left)
    verbose "FusionPBX config.conf already configured (keeping existing)"
else
    # Deploy the template with placeholder values
    # These will be filled in by finish.sh with actual database credentials
    if [ -f "fusionpbx/config.conf" ]; then
        cp -f fusionpbx/config.conf "$_fpbx_config"
        chown "$web_user:$web_group" "$_fpbx_config"
        verbose "FusionPBX config.conf template deployed (placeholders will be replaced in finish.sh)"
    else
        warn "FusionPBX config.conf template not found at fusionpbx/config.conf"
    fi
fi

# =============================================================================
# Create .pgpass for the web user (if not already created by postgresql.sh)
# This allows FusionPBX PHP scripts to connect to PostgreSQL without
# exposing the password on the command line.
# =============================================================================

_pgpass_file="$_fpbx_dir/.pgpass"

# Read database credentials from the temporary file created by postgresql.sh
if [ -f "/tmp/fusionpbx_db_credentials" ]; then
    . /tmp/fusionpbx_db_credentials

    # Create/update .pgpass
    echo "${database_host}:${database_port}:${database_name}:${database_username}:${database_password}" > "$_pgpass_file"

    # Also add an entry for the 'fusionpbx' database (same credentials)
    # Some FusionPBX scripts may connect to the default DB
    echo "${database_host}:${database_port}:*:${database_username}:${database_password}" >> "$_pgpass_file"

    chown "$web_user:$web_group" "$_pgpass_file"
    chmod 600 "$_pgpass_file"
    verbose ".pgpass created for FusionPBX database access"
else
    warn "Database credentials file not found at /tmp/fusionpbx_db_credentials"
    warn ".pgpass will be created in finish.sh when credentials are available"
fi

# =============================================================================
# Summary
# =============================================================================

verbose ""
verbose "FusionPBX installation summary:"
verbose "  Source:        $_fpbx_dir"
verbose "  Branch:        ${system_branch:-master}"
verbose "  Cache dir:     /var/cache/fusionpbx"
verbose "  Config:        $_fpbx_config"
verbose "  Owner:         $web_user:$web_group"
verbose "  .pgpass:       $([ -f "$_pgpass_file" ] && echo "created" || echo "pending")"
verbose "  Dependencies:  installed (required), attempted (optional)"
verbose ""
