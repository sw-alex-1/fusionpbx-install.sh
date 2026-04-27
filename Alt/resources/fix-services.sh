#!/bin/sh

# FusionPBX Alt Linux - Fix Service Files
#
# Replaces www-data with _nginx in all FusionPBX-generated systemd
# service files and cron entries. Run this after enabling additional
# FusionPBX modules that may have created new service files with the
# wrong user.
#
# Usage:
#   ./fix-services.sh
#
# This script is safe to run multiple times — it only modifies files
# that contain "www-data", which is a Debian-specific user that does
# not exist on Alt Linux.

# Alt Linux web/FreeSWITCH user
_web_user="_nginx"
_web_group="_nginx"

echo "Patching service and cron files (www-data -> ${_web_user})..."

_patched=0

# Patch systemd service files
for _svc_file in /etc/systemd/system/*.service /lib/systemd/system/*.service; do
    if [ -f "$_svc_file" ] && grep -q 'www-data' "$_svc_file" 2>/dev/null; then
        sed -i "s/www-data/${_web_user}/g" "$_svc_file"
        echo "  Patched: $(basename "$_svc_file")"
        _patched=$((_patched + 1))
    fi
done

# Patch cron files
for _cron_file in /etc/cron.d/*; do
    if [ -f "$_cron_file" ] && grep -q 'www-data' "$_cron_file" 2>/dev/null; then
        sed -i "s/www-data/${_web_user}/g" "$_cron_file"
        echo "  Patched cron: $(basename "$_cron_file")"
        _patched=$((_patched + 1))
    fi
done

if [ "$_patched" -eq 0 ]; then
    echo "  No www-data references found — nothing to patch"
else
    systemctl daemon-reload
    echo "  Patched $_patched file(s), systemd reloaded"
fi

echo "Done."
