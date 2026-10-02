#!/bin/sh

# FusionPBX Alt Linux Installer - Angie Web Server
# Installs and configures Angie as the web server for FusionPBX.
# Safe for re-runs: backs up configs, skips existing setups.
#
# Angie replaces nginx (this installer used to deploy nginx):
#   - Angie is a technically advanced nginx fork with an active
#     development model and no license-clause risks for production use
#   - Configuration is nginx-compatible; directives are unchanged
#     (see https://angie.software/angie/docs/configuration/migration/)
#
# Alt Linux specifics:
#   - Angie is NOT in the Alt repositories: it is installed from the
#     vendor's official repository, configured below following
#     https://angie.software/angie/docs/installation/oss_packages/#install-alt-oss
#   - Package paths: /etc/angie/angie.conf, sites in /etc/angie/http.d/,
#     logs in /var/log/angie/, service 'angie', binary /usr/sbin/angie
#   - Web user: angie (created by the angie package; PHP-FPM and FreeSWITCH
#     run as the same user - mirrors the Debian www-data approach)
#   - The default angie.conf already includes /etc/angie/http.d/*.conf,
#     so no include-directive surgery on the main config is needed

# Determine script directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Includes
. "$SCRIPT_DIR/config.sh"
. "$SCRIPT_DIR/colors.sh"
. "$SCRIPT_DIR/util.sh"
. "$SCRIPT_DIR/environment.sh"

# =============================================================================
# Detect the Alt Linux variant and version for the Angie repository
# Official Angie repositories:
#   Alt 11, Alt 10        -> https://download.angie.software/angie/altlinux/{11,10}/
#   Alt SP 10, Alt SP 8   -> https://download.angie.software/angie/altlinux-sp/{10,8}/
# =============================================================================

_alt_release=""
if [ -r /etc/altlinux-release ]; then
    _alt_release=$(cat /etc/altlinux-release 2>/dev/null)
elif [ -r /etc/os-release ]; then
    . /etc/os-release
    _alt_release="ALT ${VERSION_ID:-unknown}"
fi

if [ -z "$_alt_release" ]; then
    die "Cannot detect the Alt Linux version (/etc/altlinux-release not found). Unable to configure the Angie repository."
fi

# SP (Server Platform) variant?
case "$_alt_release" in
    *SP*|*"СП"*) _alt_variant="sp" ;;
    *)           _alt_variant="std" ;;
esac

# Major version: first number sequence in the release string
_alt_major=$(echo "$_alt_release" | grep -o '[0-9][0-9]*' | head -1)
if [ -z "$_alt_major" ] && [ -n "${os_version:-}" ]; then
    _alt_major=$(echo "$os_version" | grep -o '[0-9][0-9]*' | head -1)
fi

_angie_repo_url=""
if [ "$_alt_variant" = "sp" ]; then
    case "$_alt_major" in
        10) _angie_repo_url="https://download.angie.software/angie/altlinux-sp/10/" ;;
        8)  _angie_repo_url="https://download.angie.software/angie/altlinux-sp/8/" ;;
    esac
else
    case "$_alt_major" in
        11) _angie_repo_url="https://download.angie.software/angie/altlinux/11/" ;;
        10) _angie_repo_url="https://download.angie.software/angie/altlinux/10/" ;;
    esac
fi

if [ -z "$_angie_repo_url" ]; then
    error "Unsupported Alt Linux version for the official Angie repository."
    error "  Detected release: $_alt_release"
    error "  Supported: Alt 11, Alt 10, Alt SP 10, Alt SP 8"
    error "  See https://angie.software/angie/docs/installation/oss_packages/#install-alt-oss"
    die "The installer cannot continue without the Angie web server."
fi

verbose "Angie repository: $_angie_repo_url ($(uname -m))"

# =============================================================================
# Configure the Angie package repository
# Follows the official vendor instructions for Alt Linux.
# Idempotent: key files are only downloaded when missing, repo lists are
# rewritten with the same content on re-runs.
# =============================================================================

verbose "Configuring the Angie package repository..."

# a. Helper packages: curl (key download) and gnupg (key import) are
#    essential. apt-https enables the HTTPS transport for apt-rpm — it is a
#    separate package on most Alt versions (and a hard requirement there),
#    but may be built into apt on others, so install it as best-effort:
#    if it is genuinely required and missing, apt-get update below fails
#    with a clear message pointing at the repository config.
pkg_install_required curl gnupg
pkg_install apt-https || verbose "apt-https package not found (HTTPS transport may be built into apt)"

# b. Directory for the repository signing key
ensure_dir "/etc/ssl/angie"

# c. Download the Angie repository signing key
_angie_key="/etc/ssl/angie/angie-signing.gpg"
if [ ! -s "$_angie_key" ]; then
    verbose "Downloading the Angie repository signing key..."
    curl -fsSL -o "$_angie_key" https://angie.software/keys/angie-signing.gpg \
        || die "Failed to download the Angie signing key from https://angie.software/keys/angie-signing.gpg"
    chmod 644 "$_angie_key"
else
    verbose "Angie signing key already present: $_angie_key"
fi

# d. Import the key into the Alt system keyring (used by apt-rpm to verify
#    package signatures). Importing an already-imported key is a no-op.
ensure_dir "/usr/lib/alt-gpgkeys"
if ! gpg --no-default-keyring --keyring /usr/lib/alt-gpgkeys/pubring.gpg --import "$_angie_key" >/dev/null 2>&1; then
    die "Failed to import the Angie signing key into /usr/lib/alt-gpgkeys/pubring.gpg"
fi
verbose "Angie signing key present in the Alt system keyring"

# e. Vendor key description for apt-rpm signature checking
ensure_dir "/etc/apt/vendors.list.d"
_angie_vendors="/etc/apt/vendors.list.d/angie.list"
cat > "$_angie_vendors" << 'EOF'
simple-key "angie" {
    Fingerprint "EB8EAF3D4EF1B1ECF34865A2617AB978CB849A76";
    Name "Angie (Signing Key) <devops@tech.wbsrv.ru>";
}
EOF
verbose "Vendor key description written: $_angie_vendors"

# f. Repository source (arch from uname: x86_64 or aarch64)
_angie_source="/etc/apt/sources.list.d/angie.list"
echo "rpm [angie] ${_angie_repo_url} $(uname -m) main" > "$_angie_source"
verbose "Repository source written: $_angie_source"

# g. Refresh the package index (now includes the Angie repository)
verbose "Updating package index with the Angie repository..."
apt-get update || die "apt-get update failed after adding the Angie repository. Check: $_angie_source"

# =============================================================================
# Install Angie
# =============================================================================

verbose "Installing Angie web server..."
pkg_install_required angie

# =============================================================================
# Stop and disable nginx if present (port 80/443 conflict)
# Angie and nginx can coexist on disk (different paths), but not on the
# same ports. We do NOT remove the nginx package - just make sure it stays
# out of the way. No-op when nginx is not installed.
# =============================================================================

if systemctl is-active --quiet nginx 2>/dev/null; then
    verbose "Stopping nginx to free port 80/443 for Angie..."
    systemctl stop nginx 2>/dev/null || warn "Failed to stop nginx"
fi
if systemctl is-enabled nginx 2>/dev/null; then
    systemctl disable nginx 2>/dev/null || true
    verbose "  nginx disabled (will not start on boot)"
fi

# =============================================================================
# Stop and disable Apache if present (port 80/443 conflict)
# Alt Linux names the Apache service 'httpd2' (package apache2); some setups
# may use 'apache2' — check both. Angie cannot bind 80/443 while it runs.
# No-op when Apache is not installed.
# =============================================================================

for _apache_svc in httpd2 apache2; do
    if systemctl is-active --quiet "$_apache_svc" 2>/dev/null; then
        verbose "Stopping $_apache_svc to free port 80/443..."
        systemctl stop "$_apache_svc" 2>/dev/null || warn "Failed to stop $_apache_svc"
    fi
    # Prevent Apache from starting at boot and taking the ports back
    if systemctl is-enabled "$_apache_svc" 2>/dev/null; then
        systemctl disable "$_apache_svc" 2>/dev/null || true
        verbose "  $_apache_svc disabled (will not start on boot)"
    fi
done

# =============================================================================
# Remove the package's default site
# The angie package ships /etc/angie/http.d/default.conf listening on port 80
# (an Angie welcome page). It would conflict with the FusionPBX :80 server
# block and would become the default server for unmatched host names.
# Back it up and remove it.
# =============================================================================

_angie_default="/etc/angie/http.d/default.conf"
if [ -f "$_angie_default" ]; then
    backup_file "$_angie_default"
    rm -f "$_angie_default"
    verbose "Removed the Angie default site (was listening on port 80)"
else
    verbose "No default Angie site found (already removed)"
fi

# =============================================================================
# Generate self-signed SSL certificate
# Replaced later with a LetsEncrypt certificate when letsencrypt.sh is run.
# =============================================================================

_ssl_dir="/etc/angie/ssl"
_ssl_crt="$_ssl_dir/angie.crt"
_ssl_key="$_ssl_dir/angie.key"

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
        die "Cannot continue without SSL certificate for Angie"
    fi
fi

# Set proper permissions on SSL key
chmod 600 "$_ssl_key" 2>/dev/null
chmod 644 "$_ssl_crt" 2>/dev/null

# =============================================================================
# Deploy FusionPBX Angie configuration
# Uses placeholder variables that are replaced with actual values.
# /etc/angie/http.d/*.conf is already included by the default angie.conf,
# so no symlink or main-config changes are required.
# =============================================================================

verbose "Deploying FusionPBX Angie configuration..."

ensure_dir "/etc/angie/http.d"

_fusionpbx_conf="/etc/angie/http.d/fusionpbx.conf"

# PHP-FPM socket path (must match what was configured in php.sh)
_fpm_socket="/var/run/php${php_version}-fpm/php${php_version}-fpm.sock"

# Copy the template and replace placeholders
if [ -f "angie/fusionpbx" ]; then
    # Remove existing config if present (we'll recreate it)
    rm -f "$_fusionpbx_conf"

    # Replace placeholders in the template
    sed -e "s|{PHP_FPM_SOCKET}|${_fpm_socket}|g" \
        -e "s|{WEBSOCKET_PORT}|${websocket_port}|g" \
        angie/fusionpbx > "$_fusionpbx_conf"

    verbose "FusionPBX Angie config deployed to $_fusionpbx_conf"
    verbose "  PHP-FPM socket: $_fpm_socket"
    verbose "  WebSocket port: $websocket_port"
else
    die "Angie template not found: angie/fusionpbx"
fi

# =============================================================================
# LetsEncrypt directory (for future certificate setup)
# =============================================================================

if [ "$letsencrypt_folder" = "true" ]; then
    ensure_dir "/var/www/letsencrypt"
    verbose "LetsEncrypt directory created: /var/www/letsencrypt"
fi

# =============================================================================
# Ensure angie.conf runs workers as the web user
# The package default is 'user angie;' which matches our web_user; this is
# a safety check in case the main config was customized.
# The master process reads configs and certificates as root, so worker
# user changes do not affect certificate readability.
# =============================================================================

_angie_conf="/etc/angie/angie.conf"
if [ -f "$_angie_conf" ]; then
    _current_angie_user=$(grep -E '^[[:space:]]*user[[:space:]]' "$_angie_conf" | head -1 | awk '{print $2}' | sed 's/;.*//')
    if [ "$_current_angie_user" != "$web_user" ]; then
        backup_file "$_angie_conf"
        sed -i "s/^[[:space:]]*user[[:space:]].*/user ${web_user};/" "$_angie_conf"
        verbose "Angie worker user set to: $web_user"
    else
        verbose "Angie worker user already set to: $web_user"
    fi
else
    warn "angie.conf not found at $_angie_conf (unexpected)"
fi

# =============================================================================
# Test and start Angie
# =============================================================================

verbose "Testing Angie configuration..."
if angie -t 2>/dev/null; then
    verbose "Angie configuration test passed"
else
    error "Angie configuration test FAILED"
    error "Run 'angie -t' manually to see errors"
    error "Attempting to start Angie anyway - it may fail"
fi

# Enable Angie for auto-start on boot
systemctl enable angie 2>/dev/null || warn "Failed to enable angie for auto-start"
verbose "Angie enabled for auto-start on boot"

# Flush systemd cache and restart
systemctl daemon-reload
service_restart_required angie

# Verify Angie is running
if service_is_active angie; then
    verbose "Angie is running"
else
    die "Angie failed to start. Check: journalctl -u angie -n 50, and run 'angie -t' to test config"
fi

# =============================================================================
# Summary
# =============================================================================

verbose ""
verbose "Angie installation summary:"
verbose "  Main config:    $_angie_conf"
verbose "  Site config:    $_fusionpbx_conf"
verbose "  SSL cert:       $_ssl_crt"
verbose "  SSL key:        $_ssl_key"
verbose "  PHP-FPM socket: $_fpm_socket"
verbose "  WebSocket port: $websocket_port (Alt Linux: avoids Alterator on 8080)"
verbose "  Web user:       $web_user"
verbose "  LetsEncrypt:    $([ "$letsencrypt_folder" = "true" ] && echo "ready" || echo "disabled")"
verbose ""
