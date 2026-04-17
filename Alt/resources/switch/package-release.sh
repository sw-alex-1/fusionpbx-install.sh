#!/bin/sh

# FusionPBX Alt Linux Installer - FreeSWITCH RPM Package Installation
# Installs FreeSWITCH from Alt Linux system repository via apt-get.
# Safe for re-runs: pkg_install skips already installed packages.
#
# Alt Linux FreeSWITCH package structure (different from Debian):
#   - freeswitch-daemon: the main daemon (includes core modules)
#   - freeswitch-lua: Lua scripting support
#   - freeswitch-av: FFMpeg/media support
#   - freeswitch-imagick: Image processing
#   - freeswitch-lang-*: Language packs with sounds
#   - freeswitch-sounds-*: Sound files (en, ru, music)
#   - libfreeswitch: shared library
#
# Note: Unlike Debian, there are NO individual freeswitch-mod-* packages.
# The freeswitch-daemon package includes all core modules.

# Determine script directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Includes
. ../config.sh
. ../colors.sh
. ../util.sh
. ../environment.sh

# =============================================================================
# Install FreeSWITCH core packages
# =============================================================================

verbose "Installing FreeSWITCH core packages..."

# Core daemon and library,
# Lua scripting (required for FusionPBX integration)
pkg_install \
    freeswitch-daemon \
    libfreeswitch \ 
    freeswitch-lua

# =============================================================================
# Install FreeSWITCH optional packages
# These add functionality that FusionPBX uses.
# =============================================================================

verbose "Installing FreeSWITCH optional packages..."

# FFMpeg support (video, transcoding)
# Image processing (fax thumbnails, etc.)
pkg_install \ 
    freeswitch-av \
    freeswitch-imagick

# =============================================================================
# Install FreeSWITCH language packs
# English is always needed as the base language.
# Russian is added for Russian-language deployments.
# Other languages are optional and can be added later.
# =============================================================================

verbose "Installing FreeSWITCH language packs..."

# Languages
pkg_install \
    freeswitch-lang-en \
    freeswitch-lang-ru

# =============================================================================
# Install FreeSWITCH sound files
# Multiple sample rates ensure best quality for different codec negotiations.
# =============================================================================

verbose "Installing FreeSWITCH sound files..."

# English sounds (Callie) - required for default operation,
# Russian sounds (Elena) - common for Alt Linux deployments,
# Music on hold - multiple sample rates
pkg_install \
    freeswitch-sounds-en-us-callie-8000 \
    freeswitch-sounds-en-us-callie-16000 \
    freeswitch-sounds-en-us-callie-32000 \
    freeswitch-sounds-ru-ru-elena-8000 \
    freeswitch-sounds-ru-ru-elena-16000 \
    freeswitch-sounds-ru-ru-elena-32000 \
    freeswitch-sounds-music-8000 \
    freeswitch-sounds-music-16000 \
    freeswitch-sounds-music-32000

# =============================================================================
# Install additional dependencies
# =============================================================================

verbose "Installing FreeSWITCH dependencies..."

# memcached - used by FusionPBX for caching
pkg_install memcached

# Ensure memcached is running
if pkg_is_installed memcached; then
    service_enable_start memcached
fi

# =============================================================================
# Protect music on hold from package updates
# The original Debian installer removes the music package after moving
# the files, because package updates would overwrite custom music.
# We replicate this behavior for Alt Linux.
# =============================================================================

verbose "Protecting music on hold from package updates..."

_music_dir="/usr/share/freeswitch/sounds/music"
_music_tmp="$_music_dir/../music_tmp"

if [ -d "$_music_dir" ] && [ "$(ls -A "$_music_dir" 2>/dev/null)" ]; then
    # Music files exist - back them up, remove the package, restore
    mkdir -p "$_music_tmp"

    # Move all music files to temp location
    mv "$_music_dir"/* "$_music_tmp"/ 2>/dev/null || true

    # Also handle default subdirectory
    if [ -d "$_music_dir/default" ]; then
        # Move files from default subdirectory
        cp -a "$_music_dir"/default/* "$_music_tmp"/ 2>/dev/null || true
    fi

    # Remove the music packages (files are now safe in temp)
    for _mpkg in freeswitch-sounds-music-8000 freeswitch-sounds-music-16000 freeswitch-sounds-music-32000; do
        if pkg_is_installed "$_mpkg"; then
            verbose "Removing package $_mpkg (music files preserved)"
            apt-get remove -y "$_mpkg" 2>/dev/null || warn "Failed to remove $_mpkg (may be dependency)"
        fi
    done

    # Restore music files
    mkdir -p "$_music_dir/default"
    mv "$_music_tmp"/* "$_music_dir/default"/ 2>/dev/null || true
    rm -rf "$_music_tmp"

    # Set ownership
    chown -R "$fs_user:$fs_group" "$_music_dir" 2>/dev/null || true

    verbose "Music on hold files preserved at $_music_dir/default/"
else
    verbose "No music on hold files found to protect (may be installed later)"
fi

# =============================================================================
# Verify FreeSWITCH installation
# =============================================================================

if cmd_exists freeswitch; then
    _fs_version=$(freeswitch -version 2>/dev/null | head -1 || echo "unknown")
    verbose "FreeSWITCH installed: $_fs_version"
else
    warn "FreeSWITCH command not found after installation"
    warn "The freeswitch-daemon package may use a different binary name"
fi

verbose ""
verbose "FreeSWITCH package installation summary:"
verbose "  Core:          freeswitch-daemon, libfreeswitch"
verbose "  Scripting:     freeswitch-lua"
verbose "  Media:         freeswitch-av, freeswitch-imagick"
verbose "  Languages:     en, ru"
verbose "  Sounds en:     8000, 16000, 32000"
verbose "  Sounds ru:     8000, 16000, 32000"
verbose "  Music:         preserved (packages removed to prevent overwrite)"
verbose "  Cache:         memcached enabled"
verbose ""
