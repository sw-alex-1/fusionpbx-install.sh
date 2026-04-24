#!/bin/sh

# FusionPBX Alt Linux Installer - IPTables Firewall Configuration
# Sets up iptables rules for FusionPBX and FreeSWITCH.
# Safe for re-runs: flushes existing rules before applying new ones.
#
# Alt Linux specifics:
#   - No ufw (not available in Alt Linux)
#   - No iptables-persistent or debconf (Debian-specific)
#   - No update-alternatives (no iptables-legacy/nftables split)
#   - Rules saved to /etc/sysconfig/iptables (auto-loaded on boot)
#   - Service: iptables.service (disabled by default, must enable after saving rules)
#   - CRITICAL: Must save rules to file BEFORE enabling the service,
#     or the service will fail to start with an empty rules file!

# Determine script directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Includes
. "$SCRIPT_DIR/config.sh"
. "$SCRIPT_DIR/colors.sh"
. "$SCRIPT_DIR/util.sh"
. "$SCRIPT_DIR/environment.sh"

# =============================================================================
# Install iptables (if not already installed)
# =============================================================================

verbose "Installing iptables..."
pkg_install iptables

# =============================================================================
# Flush existing rules
# Start with a clean slate to avoid duplicate or conflicting rules.
# This is safe because we re-apply all rules below.
# =============================================================================

verbose "Flushing existing iptables rules..."

iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT
iptables -F
iptables -X 2>/dev/null  # Delete user-defined chains

# Also flush the mangle table (for DSCP rules)
iptables -t mangle -F 2>/dev/null
iptables -t mangle -X 2>/dev/null

# =============================================================================
# Basic rules - loopback and established connections
# =============================================================================

verbose "Applying iptables rules..."

# Allow loopback interface
iptables -A INPUT -i lo -j ACCEPT

# Allow established and related connections
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# =============================================================================
# SIP Anti-Scanning rules
# Drop known malicious SIP user-agents and patterns.
# These must come BEFORE the general SIP allow rules.
# =============================================================================

verbose "  Adding SIP anti-scanner rules..."

# Known scanner user-agents
_ipt_scan_patterns="friendly-scanner sipcli/ VaxSIPUserAgent/ pplsip system  exec. multipart/mixed;boundary"

for _pattern in $_ipt_scan_patterns; do
    # UDP
    iptables -A INPUT -j DROP -p udp --dport 5060:5091 \
        -m string --string "$_pattern" --algo bm --icase 2>/dev/null
    # TCP
    iptables -A INPUT -j DROP -p tcp --dport 5060:5091 \
        -m string --string "$_pattern" --algo bm --icase 2>/dev/null
done

# =============================================================================
# Service allow rules
# =============================================================================

verbose "  Adding service allow rules..."

# SSH
iptables -A INPUT -p tcp --dport 22 -j ACCEPT

# HTTP / HTTPS
iptables -A INPUT -p tcp --dport 80 -j ACCEPT
iptables -A INPUT -p tcp --dport 443 -j ACCEPT

# WebSocket (FreeSWITCH Verto/WS)
iptables -A INPUT -p tcp --dport 7443 -j ACCEPT

# SIP signaling (TCP and UDP)
iptables -A INPUT -p tcp --dport 5060:5091 -j ACCEPT
iptables -A INPUT -p udp --dport 5060:5091 -j ACCEPT

# RTP media (audio/video) - FreeSWITCH default RTP range
iptables -A INPUT -p udp --dport 16384:32768 -j ACCEPT

# ICMP (ping) - useful for diagnostics
iptables -A INPUT -p icmp --icmp-type echo-request -j ACCEPT

# OpenVPN (optional - commonly used with VoIP)
iptables -A INPUT -p udp --dport 1194 -j ACCEPT

# =============================================================================
# DSCP marking (QoS)
# Mark RTP and SIP traffic with appropriate DSCP values for QoS.
# This ensures VoIP traffic gets priority on managed networks.
# =============================================================================

verbose "  Adding DSCP QoS markings..."

# RTP media - EF (Expedited Forwarding, DSCP 46) - highest priority
iptables -t mangle -A OUTPUT -p udp -m udp --sport 16384:32768 \
    -j DSCP --set-dscp 46 2>/dev/null || warn "DSCP rule for RTP failed (may need kernel module)"

# SIP signaling - AF31 (DSCP 26) - high priority
iptables -t mangle -A OUTPUT -p udp -m udp --sport 5060:5091 \
    -j DSCP --set-dscp 26 2>/dev/null || warn "DSCP rule for SIP UDP failed"
iptables -t mangle -A OUTPUT -p tcp -m tcp --sport 5060:5091 \
    -j DSCP --set-dscp 26 2>/dev/null || warn "DSCP rule for SIP TCP failed"

# =============================================================================
# Default policies
# Drop all incoming and forwarded traffic by default.
# Allow all outgoing traffic.
# =============================================================================

verbose "  Setting default policies (INPUT: DROP, FORWARD: DROP, OUTPUT: ACCEPT)..."

iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT

# =============================================================================
# Save rules to /etc/sysconfig/iptables
# CRITICAL: This must be done BEFORE enabling the iptables service,
# because the service will fail to start with an empty rules file.
# =============================================================================

verbose "Saving iptables rules to /etc/sysconfig/iptables..."

_ipt_rules_file="/etc/sysconfig/iptables"

# Ensure the directory exists
ensure_dir "/etc/sysconfig"

# Save current rules
if iptables-save > "$_ipt_rules_file" 2>/dev/null; then
    verbose "  iptables rules saved to $_ipt_rules_file"

    # Verify the file is not empty (would cause service failure)
    if [ ! -s "$_ipt_rules_file" ]; then
        warn "Saved iptables rules file is empty - this will cause service failure!"
        warn "Attempting to save again..."
        iptables-save > "$_ipt_rules_file" 2>/dev/null
    fi
else
    die "Failed to save iptables rules to $_ipt_rules_file"
fi

# =============================================================================
# Enable and start iptables service
# Rules are already saved, so the service can start successfully.
# =============================================================================

verbose "Enabling iptables service..."

# The iptables service loads rules from /etc/sysconfig/iptables on boot
systemctl enable iptables 2>/dev/null || warn "Failed to enable iptables service"
systemctl start iptables 2>/dev/null || warn "Failed to start iptables service (rules already applied via iptables-save)"

if service_is_active iptables; then
    verbose "  iptables service is running"
else
    # Service may not be available or may have started differently
    # Rules are already applied in memory, this is ok
    verbose "  iptables service not active (rules are in memory, will be loaded from file on reboot)"
fi

# =============================================================================
# Summary
# =============================================================================

verbose ""
verbose "IPTables firewall summary:"
verbose "  Rules file:   $_ipt_rules_file"
verbose "  Default INPUT: DROP (whitelist only)"
verbose "  Allowed ports:"
verbose "    SSH:         22/tcp"
verbose "    HTTP:        80/tcp"
verbose "    HTTPS:       443/tcp"
verbose "    WS:          7443/tcp"
verbose "    SIP:         5060-5091/tcp+udp"
verbose "    RTP:         16384-32768/udp"
verbose "    OpenVPN:     1194/udp"
verbose "    ICMP:        echo-request"
verbose "  QoS (DSCP):"
verbose "    RTP:         DSCP 46 (EF - Expedited Forwarding)"
verbose "    SIP:         DSCP 26 (AF31)"
verbose "  Anti-scan:    7 patterns blocked on SIP ports"
verbose ""
