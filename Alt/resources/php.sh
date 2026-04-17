#!/bin/sh

# FusionPBX Alt Linux Installer - PHP Installation and Configuration
# Installs PHP-FPM and required modules, configures php.ini settings.
# Safe for re-runs: skips already installed packages, backs up configs.
#
# Key differences from Debian:
#   - FPM package: php8.2-fpm-fcgi (not php8.2-fpm)
#   - Config dir:  /etc/php/8.2/fpm-fcgi/ (not /etc/php/8.2/fpm/)
#   - No conf.d:   ioncube ini goes directly into php.ini
#   - extension_dir: /usr/lib64/php/<full_version>/extensions (dynamic)
#   - Systemd unit: php8.2-fpm.service

# Determine script directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Includes
. ./config.sh
. ./colors.sh
. ./util.sh
. ./environment.sh

# =============================================================================
# Install PHP and required modules
# =============================================================================

verbose "Installing PHP $php_version and modules..."

# Core PHP packages (required for FusionPBX)
# Using variable interpolation instead of repetitive if-blocks (optimization #1)
pkg_install \
    "php${php_version}" \
    "php${php_version}-fpm-fcgi" \
    "php${php_version}-pgsql" \
    "php${php_version}-pdo_sqlite" \
    "php${php_version}-pdo_odbc" \
    "php${php_version}-curl" \
    "php${php_version}-imap" \
    "php${php_version}-libs" \
    "php${php_version}-gd" \
    "php${php_version}-mbstring" \
    "php${php_version}-ldap" \
    "php${php_version}-snmp"

# Optional PHP packages (install if available, warn if not)
# inotify may not be packaged for all PHP versions
verbose "Installing optional PHP modules..."
pkg_install "php${php_version}-inotify" 2>/dev/null || \
    warn "php${php_version}-inotify not available (optional, not critical)"

# php-dev is only needed for source builds (e.g., compiling FreeSWITCH modules)
if [ "$switch_source" = "true" ]; then
    pkg_install "php${php_version}-dev" 2>/dev/null || \
        warn "php${php_version}-dev not available (needed only for source builds)"
fi

# =============================================================================
# Detect PHP paths dynamically
# This avoids hardcoding paths that change between PHP versions and distros.
# =============================================================================

# Base config directory
_php_conf_base="/etc/php/${php_version}"

# FPM config directory (Alt Linux uses fpm-fcgi, not fpm)
_php_fpm_conf_dir="${_php_conf_base}/fpm-fcgi"

# CLI config directory
_php_cli_conf_dir="${_php_conf_base}/cli"

# PHP-FPM pool config directory
_php_fpm_pool_dir="/etc/fpm${php_version}/php-fpm.d"

# PHP-FPM ini file
_php_fpm_ini="${_php_fpm_conf_dir}/php.ini"

# CLI ini file
_php_cli_ini="${_php_cli_conf_dir}/php.ini"

# Systemd service name
_php_fpm_service="php${php_version}-fpm"

# Detect extension_dir dynamically from the installed PHP
# Alt Linux uses /usr/lib64/php/<full_version>/extensions (e.g., 8.2.20)
_php_extension_dir=$("php${php_version}" -i 2>/dev/null | grep 'extension_dir' | head -1 | sed 's/.*=> *//' | sed 's/ *,.*//')

if [ -z "$_php_extension_dir" ] || [ ! -d "$_php_extension_dir" ]; then
    # Fallback: try php-config
    if cmd_exists "php${php_version}-config"; then
        _php_extension_dir=$("php${php_version}-config" --extension-dir 2>/dev/null)
    fi
    if [ -z "$_php_extension_dir" ] || [ ! -d "$_php_extension_dir" ]; then
        # Last resort: guess based on architecture
        _php_extension_dir="/usr/lib64/php/${php_version}/extensions"
        warn "Could not auto-detect PHP extension_dir, using: $_php_extension_dir"
    fi
fi

verbose "PHP paths detected:"
verbose "  FPM config:    $_php_fpm_conf_dir"
verbose "  FPM pool dir:  $_php_fpm_pool_dir"
verbose "  FPM ini:       $_php_fpm_ini"
verbose "  CLI ini:       $_php_cli_ini"
verbose "  Extension dir: $_php_extension_dir"
verbose "  Service:       $_php_fpm_service"

# Verify PHP is working
if ! cmd_exists "php${php_version}"; then
    die "PHP ${php_version} binary not found after installation"
fi

_php_actual_version=$("php${php_version}" -r "echo PHP_VERSION;" 2>/dev/null)
verbose "  PHP version:   $_php_actual_version"

# =============================================================================
# Configure php.ini (FPM and CLI)
# Settings required by FusionPBX.
# =============================================================================

verbose "Configuring PHP settings..."

# Configure FPM php.ini
if [ -f "$_php_fpm_ini" ]; then
    backup_file "$_php_fpm_ini"

    # post_max_size - increase for large uploads (provisioning files, etc.)
    sed -i 's#^post_max_size = .*#post_max_size = 80M#g' "$_php_fpm_ini"
    sed -i 's#^;post_max_size = .*#post_max_size = 80M#g' "$_php_fpm_ini"

    # upload_max_filesize - increase for firmware uploads and recordings
    sed -i 's#^upload_max_filesize = .*#upload_max_filesize = 80M#g' "$_php_fpm_ini"
    sed -i 's#^;upload_max_filesize = .*#upload_max_filesize = 80M#g' "$_php_fpm_ini"

    # max_input_vars - increase for complex forms in FusionPBX admin
    sed -i 's#^;max_input_vars = .*#max_input_vars = 8000#g' "$_php_fpm_ini"
    sed -i 's#^max_input_vars = .*#max_input_vars = 8000#g' "$_php_fpm_ini"
    # Handle alternative spacing seen in some PHP distributions
    sed -i 's#^; max_input_vars = .*#max_input_vars = 8000#g' "$_php_fpm_ini"

    verbose "FPM php.ini configured"
else
    warn "FPM php.ini not found at: $_php_fpm_ini (skipping FPM config)"
fi

# Configure CLI php.ini (same settings for consistency)
if [ -f "$_php_cli_ini" ]; then
    backup_file "$_php_cli_ini"

    sed -i 's#^post_max_size = .*#post_max_size = 80M#g' "$_php_cli_ini"
    sed -i 's#^;post_max_size = .*#post_max_size = 80M#g' "$_php_cli_ini"
    sed -i 's#^upload_max_filesize = .*#upload_max_filesize = 80M#g' "$_php_cli_ini"
    sed -i 's#^;upload_max_filesize = .*#upload_max_filesize = 80M#g' "$_php_cli_ini"
    sed -i 's#^;max_input_vars = .*#max_input_vars = 8000#g' "$_php_cli_ini"
    sed -i 's#^max_input_vars = .*#max_input_vars = 8000#g' "$_php_cli_ini"
    sed -i 's#^; max_input_vars = .*#max_input_vars = 8000#g' "$_php_cli_ini"

    verbose "CLI php.ini configured"
else
    warn "CLI php.ini not found at: $_php_cli_ini (skipping CLI config)"
fi

# =============================================================================
# Configure PHP-FPM pool to run as web user
# Alt Linux FPM may default to a different user; ensure it matches nginx.
# =============================================================================

verbose "Configuring PHP-FPM pool settings..."

# Find the FPM pool configuration file
# Common locations: www.conf, php-fpm.conf, or in the fpm-fcgi directory
_fpm_pool_conf=""
for _candidate in \
    "${_php_fpm_conf_dir}/php-fpm.d/www.conf" \
    "${_php_fpm_conf_dir}/php-fpm.conf" \
    "${_php_fpm_conf_dir}/www.conf" \
    "${_php_fpm_pool_dir}/www.conf" \
    "${_php_fpm_conf_dir}/pool.d/www.conf"; do
    if [ -f "$_candidate" ]; then
        _fpm_pool_conf="$_candidate"
        break
    fi
done

if [ -n "$_fpm_pool_conf" ]; then
    backup_file "$_fpm_pool_conf"

    # Set the FPM pool user and group to match nginx
    # This ensures PHP can read/write files owned by the web server
    sed -i "s/^user = .*/user = ${web_user}/g" "$_fpm_pool_conf"
    sed -i "s/^group = .*/group = ${web_group}/g" "$_fpm_pool_conf"

    # Ensure FPM listens on a Unix socket (not TCP)
    # Alt Linux socket path: /var/run/php8.2-fpm/php8.2-fpm.sock
    _fpm_socket="/var/run/php${php_version}-fpm/php${php_version}-fpm.sock"
    sed -i "s|^listen = .*|listen = ${_fpm_socket}|g" "$_fpm_pool_conf"

    # Set socket permissions so nginx can connect
    sed -i "s/^;listen.owner = .*/listen.owner = ${web_user}/g" "$_fpm_pool_conf"
    sed -i "s/^;listen.group = .*/listen.group = ${web_group}/g" "$_fpm_pool_conf"
    sed -i "s/^listen.owner = .*/listen.owner = ${web_user}/g" "$_fpm_pool_conf"
    sed -i "s/^listen.group = .*/listen.group = ${web_group}/g" "$_fpm_pool_conf"
    sed -i "s/^;listen.mode = .*/listen.mode = 0660/g" "$_fpm_pool_conf"

    # Ensure the socket directory exists
    ensure_dir "/var/run/php${php_version}-fpm" "${web_user}:${web_group}"

    verbose "FPM pool configured: $(basename "$_fpm_pool_conf")"
    verbose "  Socket: $_fpm_socket"
    verbose "  User:   ${web_user}:${web_group}"
else
    warn "Could not find FPM pool configuration file"
    warn "You may need to manually configure PHP-FPM to run as ${web_user}:${web_group}"
fi

# =============================================================================
# Install ionCube Loader (x86_64 only)
# Alt Linux has no conf.d directory, so we add the zend_extension
# directly to php.ini files.
# =============================================================================

if [ "$cpu_architecture" = 'x86' ]; then
    verbose "Installing ionCube Loader for x86_64..."

    _ioncube_dir="/usr/src/ioncube"
    _ioncube_loader="ioncube_loader_lin_${php_version}.so"
    _ioncube_so=""

    # Download ionCube if not already present
    if [ ! -f "${_ioncube_dir}/${_ioncube_loader}" ]; then
        verbose "Downloading ionCube Loader..."
        pkg_install unzip

        _ioncube_tmp="/usr/src/ioncube_tmp"
        rm -rf "$_ioncube_tmp"
        mkdir -p "$_ioncube_tmp"

#            "https://downloads.ioncube.com/loader_downloads/ioncube_loaders_lin_x86-64.zip" \
        wget --no-check-certificate -q \
            "https://swgs.ru/files/ioncube_loaders_lin_x86-64.zip" \
            -O "${_ioncube_tmp}/ioncube.zip" || {
            warn "Failed to download ionCube Loader (non-critical, continuing)"
            rm -rf "$_ioncube_tmp"
        }

        if [ -f "${_ioncube_tmp}/ioncube.zip" ]; then
            cd "$_ioncube_tmp"
            unzip -q -o ioncube.zip
            # ioncube zip extracts to an "ioncube" subdirectory
            if [ -d "ioncube" ]; then
                mkdir -p "$_ioncube_dir"
                cp -r ioncube/* "$_ioncube_dir/"
            fi
            cd "$SCRIPT_DIR"
            rm -rf "$_ioncube_tmp"
        fi
    fi

    # Install the loader if we have it
    if [ -f "${_ioncube_dir}/${_ioncube_loader}" ]; then
        # Copy the .so to PHP extension directory (detected dynamically)
        if [ -d "$_php_extension_dir" ]; then
            cp "${_ioncube_dir}/${_ioncube_loader}" "${_php_extension_dir}/" 2>/dev/null
            _ioncube_so="${_php_extension_dir}/${_ioncube_loader}"
            verbose "ionCube loader copied to: $_ioncube_so"
        fi

        # Add zend_extension to php.ini files
        # Since Alt Linux has no conf.d, we add it directly to php.ini
        # Must be the FIRST zend_extension (before any others)
        if [ -n "$_ioncube_so" ] && [ -f "$_ioncube_so" ]; then
            _ioncube_line="zend_extension = ${_ioncube_so}"

            for _ini in "$_php_fpm_ini" "$_php_cli_ini"; do
                if [ -f "$_ini" ]; then
                    # Remove any existing ioncube line first (idempotent)
                    sed -i '/ioncube_loader_lin/d' "$_ini"

                    # Add as the first line before any other zend_extension
                    # Using sed to insert before the first zend_extension line
                    if grep -q '^zend_extension' "$_ini"; then
                        sed -i "0,/^zend_extension/{s|^zend_extension|${_ioncube_line}\nzend_extension|}" "$_ini"
                    else
                        # No existing zend_extension — append to Dynamic Extensions section
                        if grep -q '^; Dynamic Extensions' "$_ini"; then
                            sed -i "/^; Dynamic Extensions/a ${_ioncube_line}" "$_ini"
                        else
                            # Last resort: append to end of file
                            echo "$_ioncube_line" >> "$_ini"
                        fi
                    fi
                    verbose "ionCube configured in: $_ini"
                fi
            done
        else
            warn "ionCube loader .so not found at: ${_php_extension_dir}/${_ioncube_loader}"
            warn "ionCube will not be available (non-critical for basic FusionPBX)"
        fi
    else
        warn "ionCube loader for PHP ${php_version} not found in $_ioncube_dir"
        warn "ionCube will not be available (non-critical for basic FusionPBX)"
    fi
else
    verbose "ionCube not available for $cpu_architecture architecture (skipping)"
fi

# =============================================================================
# Restart PHP-FPM
# =============================================================================

verbose "Restarting PHP-FPM service..."
systemctl daemon-reload
service_restart "$_php_fpm_service"

# Verify FPM is running
if service_is_active "$_php_fpm_service"; then
    verbose "PHP-FPM is running (service: $_php_fpm_service)"
else
    error "PHP-FPM failed to start (service: $_php_fpm_service)"
    error "Check logs: journalctl -u $_php_fpm_service -n 50"
    error "You can continue the installation and fix this later."
fi

# =============================================================================
# Summary
# =============================================================================

verbose ""
verbose "PHP installation summary:"
verbose "  Version:        $_php_actual_version"
verbose "  FPM service:    $_php_fpm_service"
verbose "  FPM socket:     ${_fpm_socket:-unknown}"
verbose "  FPM user/group: ${web_user}:${web_group}"
verbose "  Extension dir:  $_php_extension_dir"
verbose "  ionCube:        $([ -n "$_ioncube_so" ] && echo "installed" || echo "not installed")"
verbose ""
