#!/bin/sh

# FusionPBX Alt Linux Installer - Monit (process monitor)
# Monitors FreeSWITCH process and restarts it if it crashes.
#
# Alt Linux specifics:
#   - Monit config dir: /etc/monit/conf.d/ (same as Debian)
#   - FreeSWITCH user: _pbx:_pbx (NOT www-data:www-data)
#   - FreeSWITCH binary: /usr/bin/freeswitch (RPM package path)
#   - PID file: /run/freeswitch/freeswitch.pid

# Determine script directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Includes
. ./config.sh
. ./colors.sh
. ./util.sh
. ./environment.sh

# =============================================================================
# Install monit
# =============================================================================

verbose "Installing monit..."

pkg_install monit

# =============================================================================
# Deploy monit configuration for FreeSWITCH
# =============================================================================

verbose "Configuring monit for FreeSWITCH..."

_monit_conf_dir="/etc/monit/conf.d"

# Ensure monit config directory exists
ensure_dir "$_monit_conf_dir"

# Make the shell script executable
chmod 755 "$(pwd)/monit/shell.sh"

# Copy the FreeSWITCH monit config
cp "$(pwd)/monit/freeswitch" "$_monit_conf_dir/freeswitch"

verbose "  Installed monit config: $_monit_conf_dir/freeswitch"

# =============================================================================
# Configure monit to start on boot
# =============================================================================

# Enable monit httpd for 'monit summary' and 'monit status' commands
# This is needed for the web interface and CLI management
_monitrc="/etc/monit/monitrc"
if [ -f "$_monitrc" ]; then
    # Ensure the httpd is enabled (commented out by default in some distros)
    if ! grep -q "^set httpd port" "$_monitrc" 2>/dev/null; then
        # Add minimal httpd config if not present
        verbose "  Enabling monit httpd interface..."
        cat >> "$_monitrc" << 'EOF'

# Monit HTTP interface (added by FusionPBX installer)
set httpd port 2812 and
    use address localhost  # only accept connections from localhost
    allow localhost        # allow localhost to connect
EOF
    fi
fi

# =============================================================================
# Restart monit
# =============================================================================

verbose "Restarting monit service..."
service_enable_start monit

if service_is_active monit; then
    verbose "  Monit is running and monitoring FreeSWITCH"
else
    warn "Monit service is not active — check 'systemctl status monit'"
fi
