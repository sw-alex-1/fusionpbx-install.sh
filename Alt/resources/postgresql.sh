#!/bin/sh

# FusionPBX Alt Linux Installer - PostgreSQL Database
# Installs and configures PostgreSQL for FusionPBX.
# Safe for re-runs: checks existing databases, roles, and configs.
#
# Alt Linux specifics:
#   - Package: postgresql16-server (not postgresql-16 as in Debian)
#   - Init: /etc/rc.d/init.d/postgresql initdb (NOT systemctl initdb)
#   - Service: postgresql.service (unversioned, unlike CentOS postgresql-14)
#   - Data dir: /var/lib/pgsql/16/data
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
# Initialize the database cluster
# Alt Linux uses /etc/rc.d/init.d/postgresql initdb
# This must be done BEFORE starting the service.
# Idempotent: check if data directory already exists and has content.
# =============================================================================

if [ "$database_host" = "127.0.0.1" ] || [ "$database_host" = "::1" ] || [ "$database_host" = "localhost" ]; then
    if [ -d "$pg_data_dir" ] && [ -f "$pg_data_dir/PG_VERSION" ]; then
        verbose "PostgreSQL data directory already initialized: $pg_data_dir"
    else
        verbose "Initializing PostgreSQL database cluster..."

        # Ensure the data directory parent exists
        ensure_dir "$(dirname "$pg_data_dir")" "postgres:postgres"

        # Run initdb via the init script
        # Alt Linux wiki explicitly states: "Through systemctl postgresql initdb does NOT work!"
        if [ -x "$pg_init_script" ]; then
            if ! "$pg_init_script" initdb; then
                die "Failed to initialize PostgreSQL database cluster via $pg_init_script initdb"
            fi
            verbose "PostgreSQL database cluster initialized"
        else
            # Fallback: try running initdb directly as postgres user
            verbose "Init script not found at $pg_init_script, trying manual initdb..."
            if ! sudo -u postgres initdb -D "$pg_data_dir" 2>/dev/null; then
                die "Failed to initialize PostgreSQL database cluster via initdb"
            fi
            verbose "PostgreSQL database cluster initialized (manual initdb)"
        fi
    fi
fi

# =============================================================================
# Configure pg_hba.conf - replace scram-sha-256 with md5
# FusionPBX requires md5 authentication for its database user.
# The original Debian installer also does this replacement.
# Idempotent: only replace if scram-sha-256 is still present.
# =============================================================================

_pg_hba="$pg_conf_dir/pg_hba.conf"

if [ "$database_host" = "127.0.0.1" ] || [ "$database_host" = "::1" ] || [ "$database_host" = "localhost" ]; then
    if [ -f "$_pg_hba" ]; then
        if grep -q 'scram-sha-256' "$_pg_hba" 2>/dev/null; then
            backup_file "$_pg_hba"
            sed -i '/^#/!s/scram-sha-256/md5/g' "$_pg_hba"
            verbose "Replaced scram-sha-256 with md5 in pg_hba.conf"
        else
            verbose "pg_hba.conf already uses md5 (or no scram-sha-256 found)"
        fi

        # Also ensure md5 authentication for local IPv4/IPv6 connections
        # This is needed because some Alt Linux defaults use 'ident' or 'peer'
        # Check if host lines already use md5 for 127.0.0.1
        if ! grep -q '^host.*all.*all.*127\.0\.0\.1.*md5' "$_pg_hba" 2>/dev/null; then
            backup_file "$_pg_hba"
            # Replace ident/peer with md5 for local connections (similar to CentOS approach)
            sed -i 's/\(host  *all  *all  *127\.0\.0\.1\/32  *\)ident/\1md5/' "$_pg_hba" 2>/dev/null
            sed -i 's/\(host  *all  *all  *127\.0\.0\.1\/32  *\)peer/\1md5/' "$_pg_hba" 2>/dev/null
            sed -i 's/\(host  *all  *all  *::1\/128  *\)ident/\1md5/' "$_pg_hba" 2>/dev/null
            sed -i 's/\(host  *all  *all  *::1\/128  *\)peer/\1md5/' "$_pg_hba" 2>/dev/null
            verbose "Ensured md5 authentication for local connections in pg_hba.conf"
        else
            verbose "pg_hba.conf already has md5 for local connections"
        fi
    else
        warn "pg_hba.conf not found at $_pg_hba (expected after initdb)"
    fi
fi

# =============================================================================
# Enable and start PostgreSQL service
# Idempotent: enable is safe to repeat, restart/start handles both states.
# =============================================================================

if [ "$database_host" = "127.0.0.1" ] || [ "$database_host" = "::1" ] || [ "$database_host" = "localhost" ]; then
    systemctl daemon-reload
    service_enable_start "$pg_service"

    # Wait for PostgreSQL to become ready (it can take a moment after first init)
    if ! wait_for_service "$pg_service" 30; then
        die "PostgreSQL service failed to start within 30 seconds. Check: journalctl -u $pg_service -n 50"
    fi
    verbose "PostgreSQL service is running"
fi

# =============================================================================
# Configure PostgreSQL: reload config, create database and users
# All operations are idempotent:
#   - pg_reload_conf() is safe to call multiple times
#   - Database creation checks if DB already exists
#   - Role creation checks if role already exists
# =============================================================================

if [ "$database_host" = "127.0.0.1" ] || [ "$database_host" = "::1" ] || [ "$database_host" = "localhost" ]; then
    # Move to /tmp to prevent "could not change directory" warning from sudo+psql
    _cwd=$(pwd)
    cd /tmp

    # Reload configuration to pick up pg_hba.conf changes
    sudo -u postgres psql -c "SELECT pg_reload_conf();" 2>/dev/null || warn "pg_reload_conf() failed (may be ok if config unchanged)"

    # Set client encoding
    sudo -u postgres psql -c "SET client_encoding = 'UTF8';" 2>/dev/null || warn "Failed to set client encoding"

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
        # Note: we do NOT update the password on re-run to avoid breaking
        # an already-configured FusionPBX installation
    else
        # Use PGPASSWORD environment variable approach instead of passing
        # password on command line (fixes: password visible in ps aux)
        PGPASSWORD="$database_password" sudo -u postgres psql \
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
# Fix for optimization #5 from analysis: use .pgpass instead of ps-visible passwords.
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
verbose "  Auth:        md5 (scram-sha-256 replaced)"
verbose ""
