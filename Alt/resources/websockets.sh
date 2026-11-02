#!/bin/sh

# FusionPBX Alt Linux Installer - Websocket Router Service
#
# Installs the hardened systemd unit for core/websockets.
#
# Why a custom unit (and not the upstream template as-is):
#   The upstream unit has no ordering against PostgreSQL and no readiness
#   gate. At boot the PHP router starts long before PostgreSQL accepts
#   connections - on HA nodes postgresql.service is additionally delayed
#   by the boot-guard drop-in. websocket_service.php then silently binds
#   its FALLBACK address 127.0.0.1:8080:
#     - resources/classes/database.php catches the PDOException and just
#       returns false (no exception ever reaches the service);
#     - the settings object stays empty;
#     - $settings->get('websocket_server','bind_port', 8080) applies the
#       default through the ?? operator.
#   The router looks healthy ("active (running)") while angie proxies
#   /websockets/ to 8088 and gets 502. The hardened unit fixes both:
#   After=postgresql.service for ordering and an ExecStartPre pg_isready
#   gate for the cases ordering cannot cover (guard-blocked node, remote
#   database, plain slow start).
#
# This script is idempotent and safe to re-run. It also overwrites the
# service TEMPLATE inside the FusionPBX source tree so that a later
# `upgrade.php --services` (or a git pull + re-run) cannot regress the
# installed unit back to vanilla.
#
# Usage:
#   ./websockets.sh                # install + enable + restart
#   ./websockets.sh --no-restart   # install + enable only

# Determine script directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Includes
. "$SCRIPT_DIR/config.sh"
. "$SCRIPT_DIR/colors.sh"
. "$SCRIPT_DIR/util.sh"
. "$SCRIPT_DIR/environment.sh"

_unit_src="$SCRIPT_DIR/websockets/websockets.service"
_unit_dst="/etc/systemd/system/websockets.service"
_fpbx_dir="/var/www/fusionpbx"

# =============================================================================
# Preflight
# =============================================================================

[ "$(id -u)" = "0" ] || die "This script must be run as root"
[ -f "$_unit_src" ] || die "Unit template not found: $_unit_src"
[ -f /etc/fusionpbx/config.conf ] || die "/etc/fusionpbx/config.conf not found (is FusionPBX installed?)"
cmd_exists pg_isready || die "pg_isready not found (PostgreSQL client tools required)"
cmd_exists systemctl || die "systemctl not found"

# =============================================================================
# Render the unit for this system's web user
# =============================================================================
# The template ships User=angie/Group=angie (the Alt web user). Substitute
# the configured values so a future change of web_user keeps working.

verbose "Installing Websocket Router service (hardened unit)..."

_work="$(mktemp)"
sed -e "s/^User=.*/User=${web_user}/" \
    -e "s/^Group=.*/Group=${web_group}/" \
    "$_unit_src" > "$_work" || { rm -f "$_work"; die "Failed to render the unit template"; }

# =============================================================================
# Harden the template inside the FusionPBX source tree
# =============================================================================
# Covers both template layouts (5.6+ per-OS subdirectory and older flat one).
# cat > keeps the existing file's ownership and permissions.

for _tmpl in "$_fpbx_dir/core/websockets/resources/service/debian/websockets.service" \
             "$_fpbx_dir/core/websockets/resources/service/websockets.service"; do
    if [ -f "$_tmpl" ]; then
        if cmp -s "$_work" "$_tmpl"; then
            verbose "  Template already hardened: $(echo "$_tmpl" | sed "s|$_fpbx_dir/||")"
        else
            cat "$_work" > "$_tmpl" || { rm -f "$_work"; die "Failed to write template: $_tmpl"; }
            verbose "  Template hardened: $(echo "$_tmpl" | sed "s|$_fpbx_dir/||")"
        fi
    fi
done

# =============================================================================
# Install the unit
# =============================================================================

if [ -f "$_unit_dst" ] && ! cmp -s "$_work" "$_unit_dst"; then
    cp -a "$_unit_dst" "${_unit_dst}.bak"
    verbose "  Existing unit backed up to ${_unit_dst}.bak"
fi

if cmp -s "$_work" "$_unit_dst"; then
    verbose "  Unit already up to date: $_unit_dst"
else
    cat "$_work" > "$_unit_dst" || { rm -f "$_work"; die "Failed to write $_unit_dst"; }
    verbose "  Unit installed: $_unit_dst"
fi
rm -f "$_work"

systemctl daemon-reload

# =============================================================================
# Enable + (re)start
# =============================================================================

if systemctl is-enabled websockets >/dev/null 2>&1; then
    verbose "  websockets: already enabled"
else
    systemctl enable websockets >/dev/null 2>&1 \
        && verbose "  websockets: enabled" \
        || die "Failed to enable websockets.service"
fi

case " $* " in
    *" --no-restart "*)
        verbose "  websockets: restart skipped (--no-restart)"
        ;;
    *)
        verbose "  Restarting websockets (ExecStartPre waits for PostgreSQL readiness)..."
        if systemctl restart websockets; then
            verbose "  websockets: restarted"
        else
            warn "websockets did not start - is PostgreSQL accepting connections? See: journalctl -u websockets -n 20"
        fi
        # Verify the listening port matches the configured websocket port.
        if command -v ss >/dev/null 2>&1; then
            sleep 2
            if ss -ltn 2>/dev/null | grep -q ":${websocket_port} "; then
                verbose "  websockets: listening on port ${websocket_port}"
            else
                warn "websockets is not listening on ${websocket_port} - check v_default_settings (websocket_server/bind_port) and: journalctl -u websockets -n 20"
            fi
        fi
        ;;
esac

exit 0
