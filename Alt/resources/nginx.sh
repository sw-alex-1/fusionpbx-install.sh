#!/bin/sh

# FusionPBX Alt Linux Installer - NGINX Web Server
# Installs and configures nginx as the web server for FusionPBX.
# Safe for re-runs: backs up configs, skips existing setups.
#
# Alt Linux specifics:
#   - Sites directories: /etc/nginx/sites-available.d/ and sites-enabled.d/
#   - No ssl-cert package: self-signed certificate generated with openssl
#   - Web user: _nginx (not www-data)
#   - nginx.conf may need include directive for sites-enabled.d

# Determine script directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Includes
. "$SCRIPT_DIR/config.sh"
. "$SCRIPT_DIR/colors.sh"
. "$SCRIPT_DIR/util.sh"
. "$SCRIPT_DIR/environment.sh"

# =============================================================================
# Install nginx
# =============================================================================

verbose "Installing NGINX web server..."
pkg_install_required nginx

# =============================================================================
# Ensure sites directories exist
# Alt Linux has /etc/nginx/sites-available.d/ and sites-enabled.d/
# but they may not exist on minimal installations.
# =============================================================================

ensure_dir "/etc/nginx/sites-available.d"
ensure_dir "/etc/nginx/sites-enabled.d"

# =============================================================================
# Ensure nginx.conf includes sites-enabled.d
# Check if the include directive already exists (idempotent).
# =============================================================================

verbose "Checking nginx.conf for sites-enabled.d include..."

_nginx_conf="/etc/nginx/nginx.conf"
if [ -f "$_nginx_conf" ]; then
    if ! grep -q 'sites-enabled.d' "$_nginx_conf" 2>/dev/null; then
        backup_file "$_nginx_conf"
        verbose "Adding sites-enabled.d include to nginx.conf"

        # Try to add after the existing conf.d include line (most common location)
        if grep -q 'include.*conf\.d' "$_nginx_conf"; then
            sed -i '/include.*conf\.d/a\    include /etc/nginx/sites-enabled.d/*.conf;' "$_nginx_conf"
        else
            # Fallback: add before the last closing brace of the http block
            # This is a best-effort approach for unusual nginx.conf layouts
            sed -i '/^http {/a\    include /etc/nginx/sites-enabled.d/*.conf;' "$_nginx_conf"
        fi
        verbose "nginx.conf updated with sites-enabled.d include"
    else
        verbose "nginx.conf already includes sites-enabled.d"
    fi
else
    warn "nginx.conf not found at $_nginx_conf (unexpected)"
fi

# =============================================================================
# Generate self-signed SSL certificate
# Alt Linux does not have the ssl-cert package with snakeoil certificates.
# We generate a self-signed certificate that can be replaced later
# with a LetsEncrypt certificate (via letsencrypt.sh).
# =============================================================================

_ssl_dir="/etc/nginx/ssl"
_ssl_crt="$_ssl_dir/nginx.crt"
_ssl_key="$_ssl_dir/nginx.key"

if [ -f "$_ssl_crt" ] && [ -f "$_ssl_key" ]; then
    verbose "SSL certificate already exists at $_ssl_crt (keeping existing)"
else
    verbose "Generating self-signed SSL certificate..."
    ensure_dir "$_ssl_dir"

    # Get the server's hostname for the certificate CN
    _ssl_cn=$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo "localhost")

    # Generate a self-signed certificate valid for 10 years
    openssl req -x509 -nodes -days 3650 \
        -newkey rsa:2048 \
        -keyout "$_ssl_key" \
        -out "$_ssl_crt" \
        -subj "/CN=$_ssl_cn/O=FusionPBX/C=US" \
        2>/dev/null

    if [ -f "$_ssl_crt" ] && [ -f "$_ssl_key" ]; then
        verbose "Self-signed SSL certificate generated (CN=$_ssl_cn)"
        verbose "  Certificate: $_ssl_crt"
        verbose "  Key:         $_ssl_key"
        verbose "  Replace with LetsEncrypt for production use"
    else
        error "Failed to generate self-signed SSL certificate"
        die "Cannot continue without SSL certificate for nginx"
    fi
fi

# Set proper permissions on SSL key
chmod 600 "$_ssl_key" 2>/dev/null
chmod 644 "$_ssl_crt" 2>/dev/null

# =============================================================================
# Deploy FusionPBX nginx configuration
# Uses placeholder variables that are replaced with actual values.
# This approach is cleaner than per-version sed replacements (optimization #1).
# =============================================================================

verbose "Deploying FusionPBX nginx configuration..."

_fusionpbx_conf="/etc/nginx/sites-available.d/fusionpbx.conf"

# PHP-FPM socket path (must match what was configured in php.sh)
_fpm_socket="/var/run/php${php_version}-fpm/php${php_version}-fpm.sock"

# Copy the template and replace placeholders
if [ -f "nginx/fusionpbx" ]; then
    # Remove existing config if present (we'll recreate it)
    rm -f "$_fusionpbx_conf"

    # Replace placeholders in the template
    sed -e "s|{PHP_FPM_SOCKET}|${_fpm_socket}|g" \
        nginx/fusionpbx > "$_fusionpbx_conf"

    verbose "FusionPBX nginx config deployed to $_fusionpbx_conf"
    verbose "  PHP-FPM socket: $_fpm_socket"
else
    die "nginx template not found: nginx/fusionpbx"
fi

# =============================================================================
# Enable the FusionPBX site
# Create symlink in sites-enabled.d (idempotent: remove first if exists).
# =============================================================================

_fusionpbx_enabled="/etc/nginx/sites-enabled.d/fusionpbx.conf"

if [ -L "$_fusionpbx_enabled" ] || [ -f "$_fusionpbx_enabled" ]; then
    verbose "FusionPBX site already enabled (refreshing symlink)"
    rm -f "$_fusionpbx_enabled"
fi

ln -s "$_fusionpbx_conf" "$_fusionpbx_enabled"
verbose "FusionPBX site enabled: $_fusionpbx_enabled -> $_fusionpbx_conf"

# =============================================================================
# Remove default site (if it exists and is not FusionPBX)
# Don't remove if it's the only site - nginx needs at least one server block.
# =============================================================================

_default_site="/etc/nginx/sites-enabled.d/default.conf"
if [ -f "$_default_site" ] && [ ! -L "$_default_site" ]; then
    # Only remove if it's an actual file, not our symlink
    backup_file "$_default_site"
    rm -f "$_default_site"
    verbose "Removed default nginx site"
elif [ -L "$_default_site" ]; then
    verbose "Default site is a symlink, leaving it alone"
fi

# Also check for other common default site names
for _default_name in default default_server 000-default; do
    _default_path="/etc/nginx/sites-enabled.d/${_default_name}.conf"
    if [ -f "$_default_path" ]; then
        backup_file "$_default_path"
        rm -f "$_default_path"
        verbose "Removed default nginx site: $_default_name.conf"
    fi
done

# =============================================================================
# LetsEncrypt directory (for future certificate setup)
# =============================================================================

if [ "$letsencrypt_folder" = "true" ]; then
    ensure_dir "/var/www/letsencrypt"
    verbose "LetsEncrypt directory created: /var/www/letsencrypt"
fi

# =============================================================================
# Set nginx user to match PHP-FPM user
# Ensure nginx runs as the same user that PHP-FPM uses.
# =============================================================================

if [ -f "$_nginx_conf" ]; then
    _current_nginx_user=$(grep '^user ' "$_nginx_conf" | head -1 | awk '{print $2}' | sed 's/;//')
    if [ "$_current_nginx_user" != "$web_user" ]; then
        backup_file "$_nginx_conf"
        sed -i "s/^user .*/user ${web_user};/g" "$_nginx_conf"
        verbose "nginx user set to: $web_user"
    else
        verbose "nginx user already set to: $web_user"
    fi
fi

# =============================================================================
# Test and start nginx
# =============================================================================

verbose "Testing nginx configuration..."
if nginx -t 2>/dev/null; then
    verbose "nginx configuration test passed"
else
    error "nginx configuration test FAILED"
    error "Run 'nginx -t' manually to see errors"
    error "Attempting to start nginx anyway - it may fail"
fi

# Enable nginx for auto-start on boot
systemctl enable nginx 2>/dev/null || warn "Failed to enable nginx for auto-start"
verbose "nginx enabled for auto-start on boot"

# Flush systemd cache and restart
systemctl daemon-reload
service_restart_required nginx

# Verify nginx is running
if service_is_active nginx; then
    verbose "nginx is running"
else
    die "nginx failed to start. Check: journalctl -u nginx -n 50, and run 'nginx -t' to test config"
fi

# =============================================================================
# Summary
# =============================================================================

verbose ""
verbose "NGINX installation summary:"
verbose "  Config:         $_nginx_conf"
verbose "  Site config:    $_fusionpbx_conf"
verbose "  SSL cert:       $_ssl_crt"
verbose "  SSL key:        $_ssl_key"
verbose "  PHP-FPM socket: $_fpm_socket"
verbose "  Web user:       $web_user"
verbose "  LetsEncrypt:    $([ "$letsencrypt_folder" = "true" ] && echo "ready" || echo "disabled")"
verbose ""
