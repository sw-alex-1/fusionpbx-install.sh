#!/bin/sh

# FusionPBX Alt Linux Installer - Fail2ban Configuration
# Installs and configures fail2ban for intrusion prevention.
# Safe for re-runs: filters are overwritten, service is restarted.
#
# Alt Linux specifics:
#   - Auth log:      /var/log/auth/secure  (NOT /var/log/auth.log)
#   - Syslog:        /var/log/syslog/messages (NOT /var/log/syslog)
#   - systemd-journald is the default log system, but fail2ban can read
#     both journal and traditional log files
#   - rsyslog may need to be installed for file-based logging
#   - Action iptables-allports works with iptables (no ufw)
#   - FreeSWITCH log: /var/log/freeswitch/freeswitch.log (same as Debian)

# Determine script directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Includes
. ./config.sh
. ./colors.sh
. ./util.sh
. ./environment.sh

# =============================================================================
# Install fail2ban and rsyslog
# =============================================================================

verbose "Installing Fail2ban..."

# fail2ban is required; rsyslog ensures traditional log files exist
# (Alt Linux uses systemd-journald by default, but fail2ban needs file-based
#  logs for most filters — rsyslog creates /var/log/auth/secure etc.)
pkg_install fail2ban
pkg_install rsyslog

# =============================================================================
# Ensure log files exist (rsyslog may not have created them yet)
# Some fail2ban jails fail silently if the log file doesn't exist.
# =============================================================================

verbose "Ensuring log files exist..."

ensure_dir "/var/log/auth"
ensure_dir "/var/log/syslog"

# Touch log files so fail2ban can find them even if rsyslog hasn't written yet
for _logfile in /var/log/auth/secure /var/log/syslog/messages; do
    if [ ! -f "$_logfile" ]; then
        touch "$_logfile"
        verbose "  Created $_logfile"
    fi
done

# =============================================================================
# Enable and start rsyslog
# This ensures traditional log files are populated, which fail2ban relies on.
# =============================================================================

verbose "Enabling rsyslog service..."
service_enable_start rsyslog

# =============================================================================
# Install fail2ban filters
# These filter configs are OS-independent — they match log message patterns
# from FreeSWITCH, nginx, and FusionPBX which are the same on any distro.
# =============================================================================

verbose "Installing fail2ban filters..."

_fail2ban_filter_dir="/etc/fail2ban/filter.d"
_fail2ban_src_dir="$(pwd)/fail2ban"

# List of filter configuration files to install
_filters="
freeswitch.conf
freeswitch-acl.conf
sip-auth-failure.conf
sip-auth-challenge.conf
auth-challenge-ip.conf
freeswitch-ip.conf
fusionpbx.conf
fusionpbx-mac.conf
fusionpbx-404.conf
nginx-404.conf
nginx-dos.conf
"

for _filter in $_filters; do
    # Trim whitespace
    _filter="$(echo "$_filter" | tr -d '[:space:]')"
    if [ -z "$_filter" ]; then
        continue
    fi

    if [ -f "$_fail2ban_src_dir/$_filter" ]; then
        cp "$_fail2ban_src_dir/$_filter" "$_fail2ban_filter_dir/$_filter"
        verbose "  Installed filter: $_filter"
    else
        warn "Filter file not found: $_fail2ban_src_dir/$_filter (skipping)"
    fi
done

# =============================================================================
# Install jail.local (main fail2ban configuration)
# This file defines which jails are enabled and their parameters.
# Alt Linux paths are used for log files.
# =============================================================================

verbose "Installing fail2ban jail configuration..."

cp "$_fail2ban_src_dir/jail.local" /etc/fail2ban/jail.local
verbose "  Installed jail.local"

# =============================================================================
# Install fail2ban.local (fail2ban daemon settings)
# =============================================================================

if [ -f "$_fail2ban_src_dir/fail2ban.local" ]; then
    cp "$_fail2ban_src_dir/fail2ban.local" /etc/fail2ban/fail2ban.local
    verbose "  Installed fail2ban.local"
fi

# =============================================================================
# Restart fail2ban to apply all changes
# =============================================================================

verbose "Restarting fail2ban service..."
service_enable_start fail2ban

# Verify fail2ban is running
if service_is_active fail2ban; then
    verbose "  Fail2ban is running"
else
    warn "Fail2ban service is not active — check /var/log/fail2ban.log for errors"
fi

# =============================================================================
# Summary
# =============================================================================

verbose ""
verbose "Fail2ban configuration summary:"
verbose "  Auth log:     /var/log/auth/secure (Alt Linux path)"
verbose "  Syslog:       /var/log/syslog/messages (Alt Linux path)"
verbose "  FS log:       /var/log/freeswitch/freeswitch.log"
verbose "  Nginx log:    /var/log/nginx/access*.log"
verbose "  Action:       iptables-allports (compatible with iptables firewall)"
verbose "  Active jails: ssh, fusionpbx, fusionpbx-mac, nginx-404, nginx-dos"
verbose "  (FreeSWITCH jails disabled by default — enable after verifying logs)"
verbose ""
