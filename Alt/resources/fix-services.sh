#!/bin/sh

# FusionPBX Alt Linux - Fix Service Files
#
# Replaces www-data with angie in:
#   1. FusionPBX service TEMPLATE files in the source tree
#      (so future module activations generate correct services)
#   2. Installed systemd service files in /etc/systemd/system/
#   3. Cron files in /etc/cron.d/
# and:
#   4. Re-installs the hardened websockets.service. The vanilla unit has no
#      PostgreSQL ordering and no readiness gate: at boot the router cannot
#      read bind_port from the DB, silently binds its fallback 127.0.0.1:8080
#      and angie answers 502 on /websockets/.
#
# Run this after:
#   - Enabling additional FusionPBX modules that may have added
#     new service template files with www-data
#   - Updating FusionPBX (git pull may restore www-data in templates, and
#     upgrade.php --services may regenerate the vanilla websockets.service)
#
# Usage:
#   ./fix-services.sh
#
# This script is safe to run multiple times.

# Alt Linux web/FreeSWITCH user
_web_user="angie"
_web_group="angie"
_fpbx_dir="/var/www/fusionpbx"
_script_dir="$(cd "$(dirname "$0")" && pwd)"

echo "Fixing www-data -> ${_web_user} in FusionPBX service files..."
_patched=0

# 1. Patch service TEMPLATES in the FusionPBX source tree
# This ensures future upgrade.php --services calls generate correct files
# Covers both template layouts:
#   - FusionPBX 5.5 and older: app|core/*/resources/service/*.service (flat)
#   - FusionPBX 5.6 and newer: app|core/*/resources/service/<os>/*.service
#     (per-OS subdirectories; 'debian' is used for all Linux systems)
echo ""
echo "1. Patching service templates in FusionPBX source tree..."
for _tmpl_file in "$_fpbx_dir"/app/*/resources/service/*.service \
                   "$_fpbx_dir"/app/*/resources/service/*/*.service \
                   "$_fpbx_dir"/core/*/resources/service/*.service \
                   "$_fpbx_dir"/core/*/resources/service/*/*.service; do
    if [ -f "$_tmpl_file" ] && grep -q 'www-data' "$_tmpl_file" 2>/dev/null; then
        sed -i "s/www-data/${_web_user}/g" "$_tmpl_file"
        echo "  Patched template: $(echo "$_tmpl_file" | sed "s|$_fpbx_dir/||")"
        _patched=$((_patched + 1))
    fi
done

# 2. Patch installed systemd service files
echo ""
echo "2. Patching installed service files..."
for _svc_file in /etc/systemd/system/*.service /lib/systemd/system/*.service; do
    if [ -f "$_svc_file" ] && grep -q 'www-data' "$_svc_file" 2>/dev/null; then
        sed -i "s/www-data/${_web_user}/g" "$_svc_file"
        echo "  Patched: $(basename "$_svc_file")"
        _patched=$((_patched + 1))
    fi
done

# 3. Patch cron files
echo ""
echo "3. Patching cron files..."
for _cron_file in /etc/cron.d/*; do
    if [ -f "$_cron_file" ] && grep -q 'www-data' "$_cron_file" 2>/dev/null; then
        sed -i "s/www-data/${_web_user}/g" "$_cron_file"
        echo "  Patched cron: $(basename "$_cron_file")"
        _patched=$((_patched + 1))
    fi
done

# 4. Re-install the hardened websockets unit
# A FusionPBX update (git pull + upgrade.php --services) regenerates the
# vanilla websockets.service: no PostgreSQL ordering, no readiness gate (see
# resources/websockets/websockets.service for the full story). websockets.sh
# installs the hardened unit AND re-hardens the source tree template, so a
# later upgrade.php --services cannot regress it. It is idempotent.
echo ""
echo "4. Re-installing the hardened websockets unit..."
if [ -x "$_script_dir/websockets.sh" ]; then
    "$_script_dir/websockets.sh" \
        || echo "  WARNING: websockets.sh reported a problem (see above)"
else
    echo "  NOTE: websockets.sh not found next to fix-services.sh - skipped"
    echo "  (run Alt/resources/websockets.sh manually to install the"
    echo "   PostgreSQL-ready websockets unit)"
fi

if [ "$_patched" -eq 0 ]; then
    echo ""
    echo "No www-data references found — nothing to patch"
else
    systemctl daemon-reload
    echo ""
    echo "Patched $_patched file(s), systemd reloaded"
fi
