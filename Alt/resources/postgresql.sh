#!/bin/sh

# FusionPBX Alt Linux Installer - PostgreSQL Database
# Installs and configures PostgreSQL for FusionPBX.
# Safe for re-runs: checks existing databases, roles, and configs.
#
# Alt Linux specifics:
#   - Package: postgresql16-server (not postgresql-16 as in Debian)
#   - Init: /etc/rc.d/init.d/postgresql initdb (NOT systemctl initdb)
#   - Service: postgresql.service (unversioned, unlike CentOS postgresql-14)
#   - Data dir: /var/lib/pgsql/data (NO version number in path!)
#   - initdb is INTERACTIVE by default — prompts for superuser password
#     We must use --auth-local=trust --auth-host=trust to make it non-interactive,
#     then configure authentication after the cluster is created
#   - No pg_createcluster (Debian-specific), no postgresql-setup (CentOS-specific)

# Determine script directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Includes
. ./config.sh
. ./colors.sh
. ./util.sh
. ./environment.sh

# =============================================================================
# Generate database password
# Must be done early so it's available for config files and role creation.
# If password was set to 'random', generate one. Otherwise use the custom value.
# =============================================================================

if [ "$database_password" = "random" ]; then
    database_password=$(dd if=/dev/urandom bs=1 count=20 2>/dev/null | base64 | tr -d '=/+' | head -c 20)
    if [ -z "$database_password" ]; then
        # Fallback if dd/base64 fails (very unlikely)
        database_password=$(cat /proc/sys/kernel/random/uuid 2>/dev/null | tr -d '-' | head -c 20)
    fi
    verbose "Generated random database password"
else
    verbose "Using custom database password"
fi

# =============================================================================
# Install PostgreSQL
# Only install server on local database host. For remote databases,
# only the client is needed.
# =============================================================================

verbose "Installing PostgreSQL..."

if [ "$database_host" = "127.0.0.1" ] || [ "$database_host" = "::1" ] || [ "$database_host" = "localhost" ]; then
    # Local database - install server and client
    pkg_install sudo "$pg_package"

    # Verify the package installed successfully
    if ! pkg_is_installed "$pg_package"; then
        die "Failed to install $pg_package. Check that the package is available in your Alt Linux repository."
    fi
    verbose "PostgreSQL server package installed: $pg_package"
else
    # Remote database - only client needed
    pkg_install sudo "postgresql${database_version}"
    verbose "PostgreSQL client installed (remote database at $database_host)"
fi

# =============================================================================
# Detect actual PostgreSQL data directory
# Alt Linux may place data in /var/lib/pgsql/data/ or /var/lib/pgsql/<ver>/data/
# We detect it dynamically by looking for PG_VERSION or using pg_config.
# =============================================================================

_pg_actual_data_dir=""

# Method 1: Check the default Alt Linux path (no version number)
if [ -f "/var/lib/pgsql/data/PG_VERSION" ]; then
    _pg_actual_data_dir="/var/lib/pgsql/data"
fi

# Method 2: Check versioned path (some Alt Linux versions may use this)
if [ -z "$_pg_actual_data_dir" ] && [ -f "/var/lib/pgsql/${database_version}/data/PG_VERSION" ]; then
    _pg_actual_data_dir="/var/lib/pgsql/${database_version}/data"
fi

# Method 3: Use pg_config if available
if [ -z "$_pg_actual_data_dir" ] && command -v pg_config >/dev/null 2>&1; then
    _pg_config_data=$(pg_config --pgdata 2>/dev/null)
    if [ -n "$_pg_config_data" ] && [ -f "$_pg_config_data/PG_VERSION" ]; then
        _pg_actual_data_dir="$_pg_config_data"
    fi
fi

# Method 4: Check the postgresql service configuration
if [ -z "$_pg_actual_data_dir" ] && [ -f "/etc/sysconfig/postgresql" ]; then
    _pg_data_from_config=$(grep -E '^PGDATA=' /etc/sysconfig/postgresql 2>/dev/null | sed 's/PGDATA=//' | tr -d '"' | tr -d "'")
    if [ -n "$_pg_data_from_config" ] && [ -d "$_pg_data_from_config" ]; then
        _pg_actual_data_dir="$_pg_data_from_config"
    fi
fi

# Override config.sh values if we detected a different path
if [ -n "$_pg_actual_data_dir" ]; then
    if [ "$_pg_actual_data_dir" != "$pg_data_dir" ]; then
        verbose "Detected PostgreSQL data directory: $_pg_actual_data_dir (overriding config.sh value: $pg_data_dir)"
    fi
    pg_data_dir="$_pg_actual_data_dir"
    pg_conf_dir="$_pg_actual_data_dir"
else
    verbose "Using configured PostgreSQL data directory: $pg_data_dir"
fi

# =============================================================================
# Initialize the database cluster
# Alt Linux uses /etc/rc.d/init.d/postgresql initdb
# This must be done BEFORE starting the service.
#
# CRITICAL: Alt Linux initdb is INTERACTIVE — it prompts for superuser password.
# We must prevent the interactive prompt. Options:
#   1. Use initdb directly with --auth-local=trust --auth-host=trust
#   2. Then configure password and authentication after cluster is created.
#
# Idempotent: check if data directory already exists and has content.
# =============================================================================

if [ "$database_host" = "127.0.0.1" ] || [ "$database_host" = "::1" ] || [ "$database_host" = "localhost" ]; then
    if [ -d "$pg_data_dir" ] && [ -f "$pg_data_dir/PG_VERSION" ]; then
        verbose "PostgreSQL data directory already initialized: $pg_data_dir"
    else
        verbose "Initializing PostgreSQL database cluster (non-interactive)..."

        # Ensure the postgres user exists and data directory parent exists
        ensure_dir "/var/lib/pgsql"

        # Method 1: Use initdb directly as postgres user with trust authentication
        # This avoids the interactive password prompt from the Alt Linux init script.
        # We'll set the superuser password AFTER the cluster is created.
        verbose "  Running initdb with trust authentication (no password prompt)..."

        if sudo -u postgres initdb \
            --auth-local=trust \
            --auth-host=trust \
            --encoding=UTF8 \
            --locale=ru_RU.UTF-8 \
            -D "$pg_data_dir" 2>&1; then
            verbose "PostgreSQL database cluster initialized (trust auth, no superuser password yet)"
        else
            # Fallback: try the init script, but pipe 'yes' to handle the password prompt
            warn "Direct initdb failed, trying via init script..."
            if [ -x "$pg_init_script" ]; then
                # Try running the init script non-interactively
                # Some Alt Linux versions accept environment variables
                if PGSETUP_INITDB_OPTIONS="--auth-local=trust --auth-host=trust" \
                    "$pg_init_script" initdb 2>&1; then
                    verbose "PostgreSQL database cluster initialized via init script"
                else
                    die "Failed to initialize PostgreSQL database cluster"
                fi
            else
                die "Failed to initialize PostgreSQL database cluster and init script not found"
            fi
        fi

        # Re-detect the data directory after initdb
        if [ -f "/var/lib/pgsql/data/PG_VERSION" ]; then
            pg_data_dir="/var/lib/pgsql/data"
            pg_conf_dir="/var/lib/pgsql/data"
        elif [ -f "/var/lib/pgsql/${database_version}/data/PG_VERSION" ]; then
            pg_data_dir="/var/lib/pgsql/${database_version}/data"
            pg_conf_dir="/var/lib/pgsql/${database_version}/data"
        fi

        verbose "  PostgreSQL data directory: $pg_data_dir"
    fi
fi

# =============================================================================
# Start PostgreSQL (with trust auth — anyone can connect without password)
# We need it running to set the superuser password and configure pg_hba.conf.
# =============================================================================

if [ "$database_host" = "127.0.0.1" ] || [ "$database_host" = "::1" ] || [ "$database_host" = "localhost" ]; then
    systemctl daemon-reload
    service_enable_start "$pg_service"

    # Wait for PostgreSQL to become ready
    if ! wait_for_service "$pg_service" 30; then
        die "PostgreSQL service failed to start within 30 seconds. Check: journalctl -u $pg_service -n 50"
    fi
    verbose "PostgreSQL service is running"
fi

# =============================================================================
# Set superuser password (was skipped during initdb with --auth-local=trust)
# Now that PostgreSQL is running with trust auth, we can set the password.
# =============================================================================

if [ "$database_host" = "127.0.0.1" ] || [ "$database_host" = "::1" ] || [ "$database_host" = "localhost" ]; then
    verbose "Setting postgres superuser password..."
    sudo -u postgres psql -c "ALTER USER postgres WITH PASSWORD '$database_password';" 2>/dev/null \
        || warn "Failed to set postgres superuser password (may already be set)"
fi

# =============================================================================
# Configure pg_hba.conf - switch from trust to md5 authentication
# Now that we've set the superuser password, we can enforce md5 auth.
#
# The approach:
#   1. Replace trust with md5 for host connections (TCP/IP)
#   2. Keep local (Unix socket) connections as trust for sudo -u postgres psql
#      or change to md5 for better security
#   3. Also replace scram-sha-256 with md5 if present
#   4. Replace ident/peer with md5 for local TCP connections
# =============================================================================

_pg_hba="$pg_conf_dir/pg_hba.conf"

if [ "$database_host" = "127.0.0.1" ] || [ "$database_host" = "::1" ] || [ "$database_host" = "localhost" ]; then
    if [ -f "$_pg_hba" ]; then
        verbose "Configuring pg_hba.conf for md5 authentication..."

        backup_file "$_pg_hba"

        # Replace scram-sha-256 with md5
        sed -i '/^#/!s/scram-sha-256/md5/g' "$_pg_hba" 2>/dev/null

        # Replace ident with md5 for TCP connections
        sed -i '/^#/!s/\bident\b/md5/g' "$_pg_hba" 2>/dev/null

        # Replace peer with md5 for TCP connections
        sed -i '/^#/!s/\bpeer\b/md5/g' "$_pg_hba" 2>/dev/null

        # Replace trust with md5 for host (TCP) connections ONLY
        # Keep "local" lines as trust so sudo -u postgres psql still works
        # without password prompts for local administration
        sed -i '/^host/s/\btrust\b/md5/g' "$_pg_hba" 2>/dev/null

        verbose "  pg_hba.conf configured: local=trust, host=md5"

        # Reload PostgreSQL to apply pg_hba.conf changes
        sudo -u postgres psql -c "SELECT pg_reload_conf();" 2>/dev/null \
            || warn "pg_reload_conf() failed (may be ok if config unchanged)"
        sleep 1
    else
        die "pg_hba.conf not found at $_pg_hba after initialization!"
    fi
fi

# =============================================================================
# Create database and users
# All operations are idempotent:
#   - Database creation checks if DB already exists
#   - Role creation checks if role already exists
# =============================================================================

if [ "$database_host" = "127.0.0.1" ] || [ "$database_host" = "::1" ] || [ "$database_host" = "localhost" ]; then
    # Move to /tmp to prevent "could not change directory" warning from sudo+psql
    _cwd=$(pwd)
    cd /tmp

    # Create database (idempotent: skip if exists)
    if pg_db_exists "$database_name"; then
        verbose "Database '$database_name' already exists (keeping)"
    else
        sudo -u postgres psql -c "CREATE DATABASE $database_name;" 2>/dev/null
        if pg_db_exists "$database_name"; then
            verbose "Database '$database_name' created"
        else
            die "Failed to create database '$database_name'"
        fi
    fi

    # Create role (idempotent: skip if exists)
    if pg_role_exists "$database_username"; then
        verbose "Role '$database_username' already exists (keeping, password unchanged)"
    else
        sudo -u postgres psql \
            -c "CREATE ROLE $database_username WITH SUPERUSER LOGIN PASSWORD '$database_password';" 2>/dev/null

        if pg_role_exists "$database_username"; then
            verbose "Role '$database_username' created with SUPERUSER privileges"
        else
            die "Failed to create role '$database_username'"
        fi
    fi

    # Grant privileges (idempotent: GRANT ALL on already-granted DB is safe)
    sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE $database_name TO $database_username;" 2>/dev/null
    verbose "Privileges granted on '$database_name' to '$database_username'"

    cd "$_cwd"
fi

# =============================================================================
# Save database credentials for other scripts
# Write a .pgpass file for the web user so FusionPBX scripts can connect
# without exposing the password on the command line.
# =============================================================================

if [ "$database_host" = "127.0.0.1" ] || [ "$database_host" = "::1" ] || [ "$database_host" = "localhost" ]; then
    _pgpass_file="/var/www/fusionpbx/.pgpass"

    # Only create .pgpass if FusionPBX directory exists (it may not yet at this stage)
    if [ -d "/var/www/fusionpbx" ]; then
        verbose "Creating .pgpass for FusionPBX..."
        echo "${database_host}:${database_port}:${database_name}:${database_username}:${database_password}" > "$_pgpass_file"
        chown "$web_user:$web_group" "$_pgpass_file" 2>/dev/null
        chmod 600 "$_pgpass_file"
        verbose ".pgpass created at $_pgpass_file"
    fi
fi

# =============================================================================
# Store password in a secure temporary file for the finish.sh script
# The finish.sh script will need the password to configure FusionPBX.
# We use a root-only readable file to pass it between installer stages.
# =============================================================================

_pg_cred_file="/tmp/fusionpbx_db_credentials"
cat > "$_pg_cred_file" <<EOF
database_host=$database_host
database_port=$database_port
database_name=$database_name
database_username=$database_username
database_password=$database_password
EOF
chmod 600 "$_pg_cred_file"
verbose "Database credentials saved for subsequent installer steps"

# =============================================================================
# Summary
# =============================================================================

verbose ""
verbose "PostgreSQL installation summary:"
verbose "  Package:     $pg_package"
verbose "  Service:     $pg_service"
verbose "  Data dir:    $pg_data_dir"
verbose "  Config dir:  $pg_conf_dir"
verbose "  pg_hba.conf: $_pg_hba"
verbose "  Database:    $database_name"
verbose "  Username:    $database_username"
verbose "  Host:        $database_host:$database_port"
verbose "  Auth:        local=trust, host=md5"
verbose ""
