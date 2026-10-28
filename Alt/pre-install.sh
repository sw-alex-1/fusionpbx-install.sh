#!/bin/sh

# FusionPBX Alt Linux Installer - Bootstrap Script
# This is the FIRST script to run on a fresh Alt Linux system.
# It updates packages, installs git, and downloads the installer.
#
# Usage:
#   ./pre-install.sh                              # Default
#   ./pre-install.sh --proxy 192.168.0.1:8080     # Use HTTP proxy
#   ./pre-install.sh --force                      # Bypass installed-system
#                                                 # protection (DANGER)
#
# INSTALLED-SYSTEM PROTECTION: this script refuses to run when FusionPBX
# is already installed and configured on this system, because it runs
# 'apt-get dist-upgrade' which can restart telephony services on a
# production system. --force bypasses. Detection logic: resources/guard.sh.
#
# If your server has no direct internet access, use --proxy to specify
# an HTTP proxy server. All subsequent network operations (apt-get, git)
# will go through the proxy.
#
# You can also set proxy manually before running this script:
#   export http_proxy=http://192.168.0.1:8080
#   export https_proxy=http://192.168.0.1:8080
#   ./pre-install.sh

# =============================================================================
# Parse arguments (--proxy host:port, --force)
# =============================================================================
PROXY_SERVER=""
FORCE_INSTALL=false

for _arg in "$@"; do
    case "$_arg" in
        --proxy=*)
            PROXY_SERVER="${_arg#--proxy=}"
            ;;
        --proxy)
            # Next argument is the proxy value (handled below)
            _next_arg=true
            ;;
        --force)
            FORCE_INSTALL=true
            ;;
        *)
            if [ "$_next_arg" = "true" ]; then
                PROXY_SERVER="$_arg"
                _next_arg=false
            fi
            ;;
    esac
done

# =============================================================================
# Installed-system protection
# pre-install.sh runs 'apt-get dist-upgrade', which can restart telephony
# services (FreeSWITCH, PostgreSQL, Angie) on a production system.
# Refuse to run when FusionPBX is already installed. --force bypasses.
# Detection logic: resources/guard.sh
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/resources/guard.sh"
guard_check_installed

# =============================================================================
# Configure proxy (if specified)
# Sets environment variables and APT config so that all subsequent
# apt-get and git operations use the proxy.
# =============================================================================
if [ -n "$PROXY_SERVER" ]; then
    # Strip protocol prefix if user provided it
    PROXY_SERVER=$(echo "$PROXY_SERVER" | sed 's|^https\?://||')

    # Basic validation
    if ! echo "$PROXY_SERVER" | grep -q ':'; then
        echo "ERROR: Invalid proxy format: $PROXY_SERVER"
        echo "Expected format: host:port (e.g. 192.168.0.1:8080)"
        exit 1
    fi

    PROXY_URL="http://${PROXY_SERVER}"

    echo "Configuring proxy: $PROXY_SERVER"

    # 1. Shell environment variables (inherited by all child processes)
    export http_proxy="$PROXY_URL"
    export https_proxy="$PROXY_URL"
    export ftp_proxy="$PROXY_URL"
    export HTTP_PROXY="$PROXY_URL"
    export HTTPS_PROXY="$PROXY_URL"
    export FTP_PROXY="$PROXY_URL"
    export no_proxy="localhost,127.0.0.1,::1,.local"
    export NO_PROXY="localhost,127.0.0.1,::1,.local"

    # 2. APT proxy configuration
    # Alt Linux APT reads /etc/apt/apt.conf as PRIMARY config (always read),
    # and may also read /etc/apt/apt.conf.d/ (Debian convention, not always
    # supported on all Alt Linux versions). Write to BOTH for safety.

    # 2a. Primary: /etc/apt/apt.conf
    _APT_CONF="/etc/apt/apt.conf"
    if [ -f "$_APT_CONF" ]; then
        # Remove existing proxy lines (idempotent)
        sed -i '/# Proxy configuration added by FusionPBX installer/,/# End FusionPBX proxy config/d' "$_APT_CONF" 2>/dev/null
        sed -i '/^Acquire::http::Proxy/d' "$_APT_CONF" 2>/dev/null
        sed -i '/^Acquire::https::Proxy/d' "$_APT_CONF" 2>/dev/null
    fi
    cat >> "$_APT_CONF" << PROXYEOF

// Proxy configuration added by FusionPBX installer
Acquire::http::Proxy "$PROXY_URL";
Acquire::https::Proxy "$PROXY_URL";
// End FusionPBX proxy config
PROXYEOF

    # 2b. Secondary: /etc/apt/apt.conf.d/99proxy
    _APT_PROXY_DIR="/etc/apt/apt.conf.d"
    _APT_PROXY_FILE="${_APT_PROXY_DIR}/99proxy"

    if [ ! -d "$_APT_PROXY_DIR" ]; then
        mkdir -p "$_APT_PROXY_DIR"
    fi

    cat > "$_APT_PROXY_FILE" << PROXYEOF
// Proxy configuration for FusionPBX installer
// To add authentication: http://user:password@host:port

Acquire::http::Proxy "$PROXY_URL";
Acquire::https::Proxy "$PROXY_URL";
PROXYEOF
    chmod 644 "$_APT_PROXY_FILE"

    # 3. wget/curl config for any future downloads
    # /etc/wgetrc — enable proxy
    if [ -f /etc/wgetrc ]; then
        sed -i 's/^use_proxy.*=.*off/use_proxy = on/' /etc/wgetrc 2>/dev/null
    fi

    # ~/.curlrc — set proxy + keep local addresses out of it (the HA layer's
    # role agents live on 127.0.0.1; a bare root curl to them must not be
    # routed through the proxy)
    sed -i '/^--proxy/d' /root/.curlrc 2>/dev/null
    sed -i '/^--noproxy/d' /root/.curlrc 2>/dev/null
    echo "--proxy $PROXY_URL" >> /root/.curlrc 2>/dev/null
    echo "--noproxy localhost,127.0.0.1,::1,.local" >> /root/.curlrc 2>/dev/null

    echo "  Proxy configured (env vars + APT config + wget/curl)"
fi

# =============================================================================
# Upgrade packages
# =============================================================================
apt-get update && apt-get -y dist-upgrade

# =============================================================================
# Install git
# =============================================================================
apt-get install -y git lsb-release

# =============================================================================
# Configure git proxy (git is now installed, so we can use git config)
# =============================================================================
if [ -n "$PROXY_SERVER" ]; then
    git config --global http.proxy "$PROXY_URL"
    git config --global https.proxy "$PROXY_URL"
    git config --global http.sslVerify false
    echo "  Git proxy configured"
fi

# =============================================================================
# Download the installer (skip if already downloaded)
# =============================================================================
if [ -d /usr/src/fusionpbx-install.sh/.git ]; then
    echo "Installer already downloaded: /usr/src/fusionpbx-install.sh (skipping git clone)"
else
    cd /usr/src && git clone https://github.com/sw-alex-1/fusionpbx-install.sh.git
fi

# =============================================================================
# Change to the installer directory
# =============================================================================
cd /usr/src/fusionpbx-install.sh/Alt
chmod +x ./install.sh

if [ -n "$PROXY_SERVER" ]; then
    echo ""
    echo "Proxy is configured. Run the installer with:"
    echo "  ./install.sh --proxy $PROXY_SERVER"
    echo ""
else
    echo ""
    echo "Run the installer:"
    echo "  ./install.sh"
    echo ""
fi
