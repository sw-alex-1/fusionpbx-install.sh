#!/bin/sh

# FusionPBX Alt Linux Installer - Utility Functions
# Provides error handling, idempotency helpers, and safe operations.
# All functions are designed to be safe for re-runs on partially configured systems.

# =============================================================================
# Error Handling
# =============================================================================

# Fatal error: print message and exit
# Usage: die "error message"
die() {
    error "FATAL: $1"
    exit 1
}

# =============================================================================
# Command Checks
# =============================================================================

# Check if a command exists in PATH
# Usage: cmd_exists <command_name>
# Returns: 0 if exists, 1 if not
cmd_exists() {
    command -v "$1" >/dev/null 2>&1
}

# =============================================================================
# Package Management (APT-RPM)
# =============================================================================

# Check if an RPM package is installed
# Usage: pkg_is_installed <package_name>
# Returns: 0 if installed, 1 if not
pkg_is_installed() {
    rpm -q "$1" >/dev/null 2>&1
}

# Install packages idempotently - skips already installed packages
# Usage: pkg_install package1 package2 ...
# Returns: 0 on success, 1 if any package failed to install
pkg_install() {
    local _pi_failed=0
    local _pi_to_install=()
    local _pi_pkg

    # Проверяем, какие пакеты нужно установить
    for _pi_pkg in "$@"; do
        if pkg_is_installed "$_pi_pkg"; then
            verbose "Package already installed: $_pi_pkg"
        else
            verbose "Will install package: $_pi_pkg"
            _pi_to_install+=("$_pi_pkg")
        fi
    done

    # Если нет пакетов для установки, выходим успешно
    if [ ${#_pi_to_install[@]} -eq 0 ]; then
        verbose "All packages are already installed"
        return 0
    fi

    # Обновляем кэш перед установкой (рекомендуется для ALT Linux)
    verbose "Updating package index..."
    if ! apt-get update; then
        error "Failed to update package index"
        _pi_failed=1
        return $_pi_failed
    fi

    # Устанавливаем все пакеты одной командой
    verbose "Installing packages: ${_pi_to_install[*]}"
    if ! apt-get install -y "${_pi_to_install[@]}"; then
        error "Failed to install some packages: ${_pi_to_install[*]}"
        _pi_failed=1
    fi

    return $_pi_failed
}

# Remove packages idempotently - skips packages that are not installed
# Usage: pkg_remove package1 package2 ...
pkg_remove() {
    for _pr_pkg in "$@"; do
        if pkg_is_installed "$_pr_pkg"; then
            verbose "Removing package: $_pr_pkg"
            apt-get remove -y "$_pr_pkg" || warn "Failed to remove package: $_pr_pkg"
        else
            verbose "Package not installed, skipping: $_pr_pkg"
        fi
    done
}

# =============================================================================
# File and Directory Operations
# =============================================================================

# Ensure a directory exists with optional ownership
# Usage: ensure_dir <path> [owner:group]
# Safe for re-runs: won't fail if directory already exists
ensure_dir() {
    _ed_dir="$1"
    _ed_owner="$2"
    if [ ! -d "$_ed_dir" ]; then
        verbose "Creating directory: $_ed_dir"
        mkdir -p "$_ed_dir" || die "Failed to create directory: $_ed_dir"
    fi
    if [ -n "$_ed_owner" ]; then
        chown -R "$_ed_owner" "$_ed_dir" 2>/dev/null
    fi
}

# Backup a file with timestamp suffix
# Usage: backup_file <path>
# Safe for re-runs: creates a new backup each time, doesn't overwrite originals
# Returns: 0 if backed up, 1 if file didn't exist
backup_file() {
    _bf_file="$1"
    if [ -f "$_bf_file" ]; then
        _bf_stamp=$(date +%Y%m%d%H%M%S)
        _bf_backup="${_bf_file}.${_bf_stamp}.bak"
        # Don't overwrite existing backups from the same second
        if [ -f "$_bf_backup" ]; then
            _bf_backup="${_bf_file}.${_bf_stamp}.$$ .bak"
        fi
        verbose "Backing up: $_bf_file -> $(basename "$_bf_backup")"
        cp -a "$_bf_file" "$_bf_backup" || warn "Failed to backup: $_bf_file"
        return 0
    fi
    return 1
}

# Replace a pattern in a file, with automatic backup
# Usage: file_replace <file> <pattern> <replacement>
# Example: file_replace /etc/nginx/nginx.conf "user nginx" "user _nginx"
# Safe for re-runs: backs up before modifying, pattern replacement is idempotent
file_replace() {
    _fr_file="$1"
    _fr_pattern="$2"
    _fr_replacement="$3"
    if [ ! -f "$_fr_file" ]; then
        warn "file_replace: file not found: $_fr_file"
        return 1
    fi
    backup_file "$_fr_file"
    sed -i "s#${_fr_pattern}#${_fr_replacement}#g" "$_fr_file"
}

# =============================================================================
# Systemd Service Management
# =============================================================================

# Enable and start (restart) a systemd service
# Usage: service_enable_start <service_name>
# Safe for re-runs: enable is idempotent, restart works if already running
service_enable_start() {
    _ses_svc="$1"
    verbose "Enabling service: $_ses_svc"
    systemctl enable "$_ses_svc" 2>/dev/null || warn "Failed to enable service: $_ses_svc"
    verbose "Starting service: $_ses_svc"
    systemctl restart "$_ses_svc" 2>/dev/null || warn "Failed to start service: $_ses_svc"
}

# Restart a systemd service safely (start if not running, restart if running)
# Usage: service_restart <service_name>
# Safe for re-runs: handles both running and stopped states
service_restart() {
    _sr_svc="$1"
    if systemctl is-active --quiet "$_sr_svc" 2>/dev/null; then
        verbose "Restarting service: $_sr_svc"
        systemctl restart "$_sr_svc" || warn "Failed to restart service: $_sr_svc"
    else
        verbose "Starting service: $_sr_svc"
        systemctl start "$_sr_svc" || warn "Failed to start service: $_sr_svc"
    fi
}

# Stop a systemd service safely (skip if not running)
# Usage: service_stop <service_name>
# Safe for re-runs: no error if service is already stopped
service_stop() {
    _ss_svc="$1"
    if systemctl is-active --quiet "$_ss_svc" 2>/dev/null; then
        verbose "Stopping service: $_ss_svc"
        systemctl stop "$_ss_svc" || warn "Failed to stop service: $_ss_svc"
    else
        verbose "Service already stopped: $_ss_svc"
    fi
}

# Check if a systemd service is active
# Usage: service_is_active <service_name>
# Returns: 0 if active, 1 if not
service_is_active() {
    systemctl is-active --quiet "$1" 2>/dev/null
}

# Wait for a service to become active
# Usage: wait_for_service <service_name> [timeout_seconds]
# Returns: 0 if service became active, 1 if timeout
wait_for_service() {
    _wfs_svc="$1"
    _wfs_timeout="${2:-30}"
    _wfs_elapsed=0
    verbose "Waiting for service $_wfs_svc (timeout: ${_wfs_timeout}s)..."
    while [ "$_wfs_elapsed" -lt "$_wfs_timeout" ]; do
        if service_is_active "$_wfs_svc"; then
            verbose "Service $_wfs_svc is active"
            return 0
        fi
        sleep 1
        _wfs_elapsed=$((_wfs_elapsed + 1))
    done
    error "Service $_wfs_svc did not become active within ${_wfs_timeout}s"
    return 1
}

# =============================================================================
# Database Helpers
# =============================================================================

# Check if a PostgreSQL database exists
# Usage: pg_db_exists <db_name>
# Returns: 0 if exists, 1 if not
pg_db_exists() {
    _pde_db="$1"
    # NOTE: On Alt Linux, 'sudo -u postgres' does NOT work from root.
    # Use 'runuser' instead — the standard way for root to switch users.
    runuser -u postgres -- psql -lqt 2>/dev/null | cut -d \| -f 1 | grep -qw "$_pde_db"
}

# Check if a PostgreSQL role exists
# Usage: pg_role_exists <role_name>
# Returns: 0 if exists, 1 if not
pg_role_exists() {
    _pre_role="$1"
    runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$_pre_role'" 2>/dev/null | grep -q 1
}
