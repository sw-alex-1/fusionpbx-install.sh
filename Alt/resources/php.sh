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
. "$SCRIPT_DIR/config.sh"
. "$SCRIPT_DIR/colors.sh"
. "$SCRIPT_DIR/util.sh"
. "$SCRIPT_DIR/environment.sh"

# =============================================================================
# Install PHP and required modules
# =============================================================================

verbose "Installing PHP $php_version and modules..."

# Core PHP packages (required for FusionPBX)
# Using variable interpolation instead of repetitive if-blocks (optimization #1)
pkg_install_required \
    "php${php_version}" \
    "php${php_version}-fpm-fcgi" \
    "php${php_version}-pgsql" \
    "php${php_version}-pdo_sqlite" \
    "php${php_version}-pdo_odbc" \
    "php${php_version}-curl" \
    "php${php_version}-fileinfo" \
    "php${php_version}-opcache" \
    "php${php_version}-imap" \
    "php${php_version}-libs" \
    "php${php_version}-gd" \
    "php${php_version}-pcntl" \
    "php${php_version}-mbstring" \
    "php${php_version}-ldap" \
    "php${php_version}-snmp" \
    "php${php_version}-openssl" \
    "php${php_version}-sockets" \
    "php${php_version}-xml" \
    "php${php_version}-xmlrpc"

# Optional PHP packages (install if available, warn if not)
# pdo_pgsql may be a separate package on Alt Linux (provides PDO PostgreSQL driver)
# inotify may not be packaged for all PHP versions
verbose "Installing optional PHP modules..."
pkg_install "php${php_version}-pdo_pgsql" 2>/dev/null || \
    verbose "php${php_version}-pdo_pgsql not a separate package (likely bundled with php${php_version}-pgsql)"
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
# Ensure the web user exists
# The web user (angie) is normally created by the angie package, but that is
# installed later (step 3) - PHP-FPM is configured and started here first.
# Create the user now if missing; the angie package will detect it and skip
# its own creation (its pre-install script checks getent passwd).
# Mirrors the Debian www-data model: angie, php-fpm and FreeSWITCH all run
# as the same user.
# =============================================================================

if ! id "${web_user}" >/dev/null 2>&1; then
    verbose "Web user (${web_user}) does not exist yet - creating..."
    groupadd -r "${web_group}" 2>/dev/null || warn "groupadd ${web_group} failed (may already exist)"
    useradd -r -c "Angie web server" -d /var/cache/angie -g "${web_group}" -s /sbin/nologin "${web_user}" \
        || die "Failed to create the web user ${web_user}"
    verbose "Web user created: ${web_user}:${web_group}"
else
    verbose "Web user (${web_user}) already exists"
fi

# =============================================================================
# Configure PHP-FPM pool to run as web user
# Alt Linux FPM may default to a different user; ensure it matches the web
# server (Angie).
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

    # Set the FPM pool user and group to match the web server (Angie)
    # This ensures PHP can read/write files owned by the web server
    sed -i "s/^user = .*/user = ${web_user}/g" "$_fpm_pool_conf"
    sed -i "s/^group = .*/group = ${web_group}/g" "$_fpm_pool_conf"

    # Ensure FPM listens on a Unix socket (not TCP)
    # Alt Linux socket path: /var/run/php8.2-fpm/php8.2-fpm.sock
    _fpm_socket="/var/run/php${php_version}-fpm/php${php_version}-fpm.sock"
    sed -i "s|^listen = .*|listen = ${_fpm_socket}|g" "$_fpm_pool_conf"

    # Set socket permissions so the web server (Angie) can connect
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
# ionCube Loader (OPTIONAL, off by default)
#
# A closed-source PHP zend_extension required ONLY by commercial FusionPBX
# add-ons distributed in encoded form - the stock FusionPBX tree is plain
# open PHP and does not need it. Disabled by default (config.sh):
# its download source is unreliable, the loader binary must match the exact
# PHP minor version (it breaks on every PHP update) and it is a third-party
# blob in the php-fpm critical path. Enable with: --with-ioncube
#
# Alt Linux has no conf.d directory, so the zend_extension line goes
# directly into the php.ini files.
# =============================================================================

_ioncube_so=""

if [ "${install_ioncube:-false}" != "true" ]; then
    verbose "ionCube Loader: not requested - skipping (enable with --with-ioncube)"
else
    if [ "$cpu_architecture" = 'x86' ]; then
        verbose "Installing ionCube Loader for x86_64 (--with-ioncube)..."

        _ioncube_dir="/usr/src/ioncube"
        _ioncube_loader="ioncube_loader_lin_${php_version}.so"

        # Download ionCube if not already present
        if [ ! -f "${_ioncube_dir}/${_ioncube_loader}" ]; then
            verbose "Downloading ionCube Loader..."
            pkg_install unzip

            _ioncube_tmp="/usr/src/ioncube_tmp"
            rm -rf "$_ioncube_tmp"
            mkdir -p "$_ioncube_tmp"

            wget --no-check-certificate -q \
				"https://downloads.ioncube.com/loader_downloads/ioncube_loaders_lin_x86-64.zip" \
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
        verbose "ionCube requested (--with-ioncube) but not available for $cpu_architecture architecture (skipping)"
    fi
fi

# =============================================================================
# Verify critical PHP extensions are loaded
# FusionPBX REQUIRES: pdo_pgsql, openssl, pgsql
# If these are missing, the entire installation will fail.
# =============================================================================

verbose "Verifying critical PHP extensions..."

_php_bin="php${php_version}"
if ! command -v "$_php_bin" >/dev/null 2>&1; then
    _php_bin="php"
fi

for _ext in pdo_pgsql openssl pgsql; do
    if "$_php_bin" -m 2>/dev/null | grep -qi "$_ext"; then
        verbose "  $_ext: loaded"
    else
        pdo_drivers=$($_php_bin -r 'echo implode(",", PDO::getAvailableDrivers());' 2>/dev/null)
        error "CRITICAL: PHP extension '$_ext' is NOT loaded!"
        error "  FusionPBX cannot work without it."
        error "  Available PDO drivers: $pdo_drivers"
        error "  Try: apt-get install php${php_version}-${_ext}"
    fi
done

# =============================================================================
# Restart PHP-FPM
# =============================================================================

verbose "Restarting PHP-FPM service..."

# Enable PHP-FPM for auto-start on boot
systemctl enable "$_php_fpm_service" 2>/dev/null || warn "Failed to enable $_php_fpm_service for auto-start"
verbose "PHP-FPM enabled for auto-start on boot"

# Install a systemd drop-in so the FPM socket directory survives reboots.
# /var/run is tmpfs: on every boot the packaged php-fpm unit recreates
# /run/php<version>-fpm with permissions that block the Angie worker
# (user angie) from traversing into it -> connect() EACCES -> 502 Bad
# Gateway after every reboot (manual fix was: chmod 0755).
# install -d creates the dir if missing AND resets the mode of an
# existing one, so this works on every start/restart. A drop-in in /etc
# also survives php-fpm package updates (unlike patching the unit file).
_fpm_dropin_dir="/etc/systemd/system/${_php_fpm_service}.service.d"
mkdir -p "$_fpm_dropin_dir"
cat > "${_fpm_dropin_dir}/fusionpbx-socket-dir.conf" <<EOF
# FusionPBX installer: FPM run dir must be traversable by the web server
[Service]
ExecStartPre=/usr/bin/install -d -m 0755 /run/php${php_version}-fpm
EOF
verbose "Systemd drop-in installed: ${_fpm_dropin_dir}/fusionpbx-socket-dir.conf"

systemctl daemon-reload
service_restart_required "$_php_fpm_service"

# Verify FPM is running
if service_is_active "$_php_fpm_service"; then
    verbose "PHP-FPM is running (service: $_php_fpm_service)"
else
    die "PHP-FPM failed to start (service: $_php_fpm_service). Check: journalctl -u $_php_fpm_service -n 50"
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
