#!/bin/sh

# FusionPBX Alt Linux - Fix Service Files
#
# Replaces www-data with angie in:
#   1. FusionPBX service TEMPLATE files in the source tree
#      (so future module activations generate correct services)
#   2. Installed systemd service files in /etc/systemd/system/
#   3. Cron files in /etc/cron.d/
#
# Run this after:
#   - Enabling additional FusionPBX modules that may have added
#     new service template files with www-data
#   - Updating FusionPBX (git pull may restore www-data in templates)
#
# Usage:
#   ./fix-services.sh
#
# This script is safe to run multiple times.

# Alt Linux web/FreeSWITCH user
_web_user="angie"
_web_group="angie"
_fpbx_dir="/var/www/fusionpbx"

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

if [ "$_patched" -eq 0 ]; then
    echo ""
    echo "No www-data references found — nothing to patch"
else
    systemctl daemon-reload
    echo ""
    echo "Patched $_patched file(s), systemd reloaded"
fi
