#!/bin/sh

# FusionPBX Alt Linux Installer - Proxy Configuration
# Configures HTTP/HTTPS proxy for all network operations performed
# by the installer: apt-get (APT-RPM), git, wget, curl.
#
# IMPORTANT: This file is DESIGNED TO BE SOURCED (not executed as a
# subprocess). This ensures that exported environment variables
# (http_proxy, https_proxy, etc.) propagate to the calling script
# (install.sh) and all its child processes.
#
# When sourced: use 'return' instead of 'exit', don't change cwd.
#
# What this configures:
#   1. Shell environment variables (http_proxy, https_proxy, etc.)
#   2. APT proxy configuration (/etc/apt/apt.conf AND apt.conf.d/99proxy)
#   3. Git global proxy configuration (if git is installed)
#   4. wget proxy configuration in /etc/wgetrc
#   5. curl proxy configuration in /root/.curlrc
#   6. Proxy connectivity test (if curl is installed)
#
# Proxy format: host:port (e.g. 192.168.0.1:8080)
# The protocol prefix (http://) is added automatically where needed.

# =============================================================================
# Pre-flight check
# =============================================================================

if [ -z "$PROXY_SERVER" ]; then
    # No proxy configured — nothing to do
    return 0 2>/dev/null || exit 0
fi

verbose ""
verbose "=== Configuring proxy: $PROXY_SERVER ==="
verbose ""

# =============================================================================
# Build proxy URLs
# Most tools expect http://host:port format.
# We build both HTTP and HTTPS proxy URLs from the single host:port argument.
# The proxy server itself is almost always HTTP (even for HTTPS traffic),
# because the CONNECT method is used for HTTPS tunneling.
# =============================================================================

PROXY_URL="http://${PROXY_SERVER}"

verbose "Proxy URLs:"
verbose "  HTTP  proxy: $PROXY_URL"
verbose "  HTTPS proxy: $PROXY_URL (CONNECT tunnel for HTTPS)"
verbose ""

# =============================================================================
# 1. Shell environment variables
# These are inherited by ALL child processes (apt-get, git, wget, curl, etc.)
# Both lowercase and uppercase variants are set for maximum compatibility:
#   - Lowercase (http_proxy): used by wget, curl, and most Unix tools
#   - Uppercase (HTTP_PROXY): used by some applications (e.g. Python, Node.js)
#
# This is ALWAYS done first — it requires no installed tools and works for
# everything that respects standard proxy environment variables.
#
# CRITICAL: These exports persist in the calling script's environment
# because this file is SOURCED, not executed as a subprocess.
# =============================================================================

verbose "Setting proxy environment variables..."

export http_proxy="$PROXY_URL"
export https_proxy="$PROXY_URL"
export ftp_proxy="$PROXY_URL"
export HTTP_PROXY="$PROXY_URL"
export HTTPS_PROXY="$PROXY_URL"
export FTP_PROXY="$PROXY_URL"

# no_proxy: local addresses that should bypass the proxy
# This prevents the proxy from being used for local connections
# (localhost, 127.0.0.1, local hostnames, .local domains)
export no_proxy="localhost,127.0.0.1,::1,.local"
export NO_PROXY="localhost,127.0.0.1,::1,.local"

verbose "  Environment variables set (http_proxy, https_proxy, etc.)"

# =============================================================================
# 2. APT-RPM proxy configuration
# Alt Linux uses APT-RPM which reads proxy settings from:
#   a) /etc/apt/apt.conf — the PRIMARY configuration file (always read)
#   b) /etc/apt/apt.conf.d/*.conf — additional configs (may not be read
#      on all Alt Linux versions, as apt.conf.d/ is a Debian convention)
#
# We write to BOTH locations for maximum compatibility:
#   - /etc/apt/apt.conf: guaranteed to be read by all APT-RPM versions
#   - /etc/apt/apt.conf.d/99proxy: works on versions that support apt.conf.d
#
# Acquire::http::Proxy  — proxy for HTTP repository access
# Acquire::https::Proxy — proxy for HTTPS repository access
#   (Note: HTTPS goes through the HTTP proxy via CONNECT method)
# =============================================================================

verbose "Configuring APT proxy..."

# --- 2a. Write to /etc/apt/apt.conf (PRIMARY — always read by Alt Linux APT) ---

_APT_CONF="/etc/apt/apt.conf"

if [ -f "$_APT_CONF" ]; then
    # Remove any existing proxy lines we added (idempotent)
    # First try: remove our marked block
    if grep -q '# Proxy configuration added by FusionPBX installer' "$_APT_CONF" 2>/dev/null; then
        sed -i '/# Proxy configuration added by FusionPBX installer/,/# End FusionPBX proxy config/d' "$_APT_CONF" 2>/dev/null
    fi
    # Also remove any standalone Acquire::http::Proxy / Acquire::https::Proxy lines
    sed -i '/^Acquire::http::Proxy/d' "$_APT_CONF" 2>/dev/null
    sed -i '/^Acquire::https::Proxy/d' "$_APT_CONF" 2>/dev/null
fi

# Append proxy configuration
cat >> "$_APT_CONF" << PROXYEOF

// Proxy configuration added by FusionPBX installer
// Generated automatically by proxy.sh — do not edit unless needed
// To add authentication: http://user:password@host:port
Acquire::http::Proxy "$PROXY_URL";
Acquire::https::Proxy "$PROXY_URL";
// End FusionPBX proxy config
PROXYEOF

verbose "  APT proxy configured in $_APT_CONF (primary config)"

# --- 2b. Write to /etc/apt/apt.conf.d/99proxy (secondary — Debian convention) ---

_APT_PROXY_DIR="/etc/apt/apt.conf.d"
_APT_PROXY_FILE="${_APT_PROXY_DIR}/99proxy"

# Ensure the directory exists
if [ ! -d "$_APT_PROXY_DIR" ]; then
    mkdir -p "$_APT_PROXY_DIR"
fi

# Write APT proxy configuration
cat > "$_APT_PROXY_FILE" << PROXYEOF
// Proxy configuration for FusionPBX installer
// Generated automatically by proxy.sh — do not edit unless needed
// To add authentication: http://user:password@host:port

Acquire::http::Proxy "$PROXY_URL";
Acquire::https::Proxy "$PROXY_URL";
PROXYEOF

chmod 644 "$_APT_PROXY_FILE"
verbose "  APT proxy configured in $_APT_PROXY_FILE (apt.conf.d — secondary)"

# =============================================================================
# 3. Git proxy configuration
# Git uses the http.proxy setting for both HTTP and HTTPS remotes.
# This is set globally (--global) so it applies to all repositories.
#
# Note: Git also respects the http_proxy/https_proxy environment variables,
# but the explicit config is more reliable and doesn't depend on env vars
# being passed through correctly.
#
# CONDITIONAL: git may not be installed yet (proxy.sh runs before pre-install.sh).
# If git is not available, we write a ~/.gitconfig file directly instead.
# After pre-install.sh installs git, the config will already be in place.
# =============================================================================

verbose "Configuring Git proxy..."

if cmd_exists git; then
    # git is available — use the proper git config command
    git config --global http.proxy "$PROXY_URL"
    git config --global https.proxy "$PROXY_URL"

    # Also ensure git does not fail on self-signed proxy certificates
    # (some corporate proxies use self-signed certs for HTTPS inspection)
    git config --global http.sslVerify false

    verbose "  Git proxy configured (global http.proxy, https.proxy)"
    verbose "  Git SSL verification disabled (corporate proxy compatibility)"
else
    # git is NOT installed yet — write ~/.gitconfig directly
    # This will be read by git when it's installed later in pre-install.sh
    _GITCONFIG="/root/.gitconfig"

    # Remove existing proxy/ssl settings (avoid duplicates)
    if [ -f "$_GITCONFIG" ]; then
        sed -i '/^\s*proxy/d' "$_GITCONFIG" 2>/dev/null
        sed -i '/^\s*sslVerify/d' "$_GITCONFIG" 2>/dev/null
        # Remove empty [http] sections
        sed -i '/^\[http\]$/,/^\[/{ /^\[http\]$/d; /^\[/!{ /^$/d; }; }' "$_GITCONFIG" 2>/dev/null
    fi

    # Append proxy settings
    cat >> "$_GITCONFIG" << GITEOF

[http]
        proxy = $PROXY_URL
        sslVerify = false
[https]
        proxy = $PROXY_URL
GITEOF

    verbose "  Git proxy configured (written to $_GITCONFIG — git not yet installed)"
    verbose "  Git SSL verification disabled (corporate proxy compatibility)"
fi

# =============================================================================
# 4. wget proxy configuration
# wget reads proxy settings from:
#   a) Environment variables (http_proxy, https_proxy) — already set above
#   b) /etc/wgetrc or ~/.wgetrc
#
# Environment variables are sufficient for wget. However, some systems
# have "use_proxy = off" in /etc/wgetrc which overrides env vars.
# We ensure use_proxy is enabled in the system wgetrc.
# =============================================================================

verbose "Configuring wget proxy..."

_WGETRC="/etc/wgetrc"

if [ -f "$_WGETRC" ]; then
    # Enable use_proxy if it's currently disabled
    if grep -q '^use_proxy.*=.*off' "$_WGETRC" 2>/dev/null; then
        sed -i 's/^use_proxy.*/use_proxy = on/' "$_WGETRC"
        verbose "  Enabled use_proxy in $_WGETRC"
    fi
    # Also check for commented-out use_proxy = on
    if grep -q '^#use_proxy.*=.*on' "$_WGETRC" 2>/dev/null; then
        sed -i 's/^#use_proxy.*=.*on/use_proxy = on/' "$_WGETRC"
        verbose "  Uncommented use_proxy = on in $_WGETRC"
    fi

    # Remove any existing proxy settings that we added (idempotent)
    sed -i '/^# Proxy configuration added by FusionPBX installer/,+3d' "$_WGETRC" 2>/dev/null

    # Append proxy settings
    echo "" >> "$_WGETRC"
    echo "# Proxy configuration added by FusionPBX installer" >> "$_WGETRC"
    echo "http_proxy = $PROXY_URL" >> "$_WGETRC"
    echo "https_proxy = $PROXY_URL" >> "$_WGETRC"
    echo "use_proxy = on" >> "$_WGETRC"

    verbose "  Proxy settings added to $_WGETRC"
else
    # No system wgetrc — create a minimal one
    cat > "$_WGETRC" << WGETEOF
# Proxy configuration added by FusionPBX installer
http_proxy = $PROXY_URL
https_proxy = $PROXY_URL
use_proxy = on
WGETEOF
    verbose "  Created $_WGETRC with proxy settings"
fi

# =============================================================================
# 5. curl proxy configuration
# curl reads proxy from:
#   a) Environment variables (http_proxy, https_proxy) — already set above
#   b) ~/.curlrc or command-line --proxy flag
#
# We also create /root/.curlrc as a fallback for scripts that run curl
# without inheriting the environment.
# =============================================================================

verbose "Configuring curl proxy..."

_CURLRC="/root/.curlrc"

# Remove any existing proxy setting we added (idempotent)
if [ -f "$_CURLRC" ]; then
    sed -i '/^--proxy/d' "$_CURLRC" 2>/dev/null
    sed -i '/^--noproxy/d' "$_CURLRC" 2>/dev/null
fi

# Append proxy setting
echo "--proxy $PROXY_URL" >> "$_CURLRC"

# Local addresses must NEVER go through the proxy: root on this system will
# later curl LOCAL endpoints (the HA layer's role agents on 127.0.0.1,
# haproxy stats, health checks) and a bare 'curl http://127.0.0.1:...' would
# be routed to the proxy without this line (the HA layer's own probes pass
# --noproxy '*' explicitly - this protects every OTHER curl root runs).
echo "--noproxy localhost,127.0.0.1,::1,.local" >> "$_CURLRC"

verbose "  Curl proxy configured: $_CURLRC (local addresses bypass it)"

# =============================================================================
# 6. Composer proxy configuration (if composer is installed)
# Composer (PHP dependency manager) reads proxy from the HTTP_PROXY
# environment variable, but we also set it explicitly in composer config
# for reliability.
# =============================================================================

if cmd_exists composer; then
    verbose "Configuring Composer proxy..."
    composer config --global http-proxy "$PROXY_URL" 2>/dev/null || true
    verbose "  Composer proxy configured (global http-proxy)"
else
    verbose "  Composer not installed — proxy will be inherited via env vars when available"
fi

# =============================================================================
# 7. Verify proxy connectivity (optional, best-effort)
# Try a simple HTTP request through the proxy to verify it's reachable.
# This is not fatal — the proxy may not be accessible yet (e.g. if
# we're in a network that hasn't fully started).
#
# CONDITIONAL: curl may not be installed yet. If not, skip the test.
# After pre-install.sh installs curl, the proxy will work via env vars.
# =============================================================================

if cmd_exists curl; then
    verbose "Verifying proxy connectivity (best-effort)..."

    _PROXY_TEST_URL="http://ya.ru"
    _PROXY_TEST_RESULT=$(curl --proxy "$PROXY_URL" --connect-timeout 5 --max-time 10 -s -o /dev/null -w "%{http_code}" "$_PROXY_TEST_URL" 2>/dev/null || true)

    if [ -n "$_PROXY_TEST_RESULT" ] && [ "$_PROXY_TEST_RESULT" -ge 200 ] 2>/dev/null && [ "$_PROXY_TEST_RESULT" -lt 400 ] 2>/dev/null; then
        verbose "  Proxy connectivity OK (HTTP $_PROXY_TEST_RESULT from $_PROXY_TEST_URL)"
    else
        warn "  Proxy connectivity test returned: $_PROXY_TEST_RESULT"
        warn "  This may be normal if the proxy is not yet accessible or blocks test URLs"
        warn "  Installation will proceed — network operations will fail if proxy is unreachable"
    fi
else
    verbose "  Skipping proxy connectivity test (curl not installed yet)"
    verbose "  Proxy will be tested when curl is installed in pre-install step"
fi

# =============================================================================
# Summary
# =============================================================================

verbose ""
verbose "Proxy configuration summary:"
verbose "  Proxy server:  $PROXY_SERVER"
verbose "  Proxy URL:     $PROXY_URL"
verbose "  APT config:    $_APT_CONF (primary) + $_APT_PROXY_FILE (secondary)"
verbose "  Git config:    $([ -f /root/.gitconfig ] && echo "/root/.gitconfig" || echo "not configured")"
verbose "  wget config:   $_WGETRC + environment variables"
verbose "  curl config:   $_CURLRC + environment variables"
verbose "  Env vars:      http_proxy, https_proxy, no_proxy (both cases)"
verbose "  Bypass proxy:  $no_proxy"
verbose ""
