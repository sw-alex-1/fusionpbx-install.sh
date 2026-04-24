#!/bin/sh

# FusionPBX Alt Linux Installer - PostgreSQL Database
# Installs and configures PostgreSQL for FusionPBX.
# Safe for re-runs: checks existing databases, roles, and configs.
#
# Alt Linux specifics:
#   - Package: postgresql16-server (not postgresql-16 as in Debian)
#   - Data dir: /var/lib/pgsql/data (NO version number in path!)
#   - initdb is INTERACTIVE by default — prompts for superuser password
#     We must use --auth-local=trust --auth-host=trust to make it non-interactive
#   - Service: postgresql.service (unversioned)
#
# IMPORTANT: The order of operations matters!
#   1. Ensure pg_hba.conf has trust auth (before starting or right after start)
#   2. Reload config via pg_ctl (NOT psql — psql can't connect if auth is broken)
#   3. THEN do ALTER USER, CREATE DATABASE, etc. via runuser -u postgres -- psql
#   4. FINALLY switch host connections to md5 and reload again

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
# =============================================================================

if [ "$database_password" = "random" ]; then
    database_password=$(dd if=/dev/urandom bs=1 count=20 2>/dev/null | base64 | tr -d '=/+' | head -c 20)
    if [ -z "$database_password" ]; then
        database_password=$(cat /proc/sys/kernel/random/uuid 2>/dev/null | tr -d '-' | head -c 20)
    fi
    verbose "Generated random database password"
else
    verbose "Using custom database password"
fi

# =============================================================================
# Install PostgreSQL
# =============================================================================

verbose "Installing PostgreSQL..."

if [ "$database_host" = "127.0.0.1" ] || [ "$database_host" = "::1" ] || [ "$database_host" = "localhost" ]; then
    pkg_install "$pg_package"
    if ! pkg_is_installed "$pg_package"; then
        die "Failed to install $pg_package. Check that the package is available in your Alt Linux repository."
    fi
    verbose "PostgreSQL server package installed: $pg_package"
else
    pkg_install "postgresql${database_version}"
    verbose "PostgreSQL client installed (remote database at $database_host)"
fi

# =============================================================================
# Detect actual PostgreSQL data directory
# Alt Linux places data in /var/lib/pgsql/data/ (NO version number!)
# But we check multiple paths just in case.
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
# Initialize the database cluster (only if not already initialized)
#
# CRITICAL: Alt Linux initdb is INTERACTIVE — it prompts for superuser password.
# We bypass this by running initdb directly with --auth-local=trust --auth-host=trust
# =============================================================================

if [ "$database_host" = "127.0.0.1" ] || [ "$database_host" = "::1" ] || [ "$database_host" = "localhost" ]; then
    if [ -d "$pg_data_dir" ] && [ -f "$pg_data_dir/PG_VERSION" ]; then
        verbose "PostgreSQL data directory already initialized: $pg_data_dir"
    else
        verbose "Initializing PostgreSQL database cluster (non-interactive)..."

        ensure_dir "/var/lib/pgsql"

        verbose "  Running initdb with trust authentication (no password prompt)..."

        # NOTE: On Alt Linux, 'sudo -u postgres' does NOT work from root
        # (root is not in sudoers). Use 'runuser' instead — it is the standard
        # way for root to run commands as another user.
        if runuser -u postgres -- initdb \
            --auth-local=trust \
            --auth-host=trust \
            --encoding=UTF8 \
            -D "$pg_data_dir" 2>&1; then
            verbose "PostgreSQL database cluster initialized (trust auth)"
        else
            # Fallback: try 'su - postgres -c' (works on most systems from root)
            warn "runuser initdb failed, trying su - postgres..."
            if su - postgres -c "initdb --auth-local=trust --auth-host=trust --encoding=UTF8 -D '$pg_data_dir'" 2>&1; then
                verbose "PostgreSQL database cluster initialized via su"
            else
                # Last resort: try the init script with PGSETUP_INITDB_OPTIONS
                warn "su initdb also failed, trying via init script..."
                if [ -x "$pg_init_script" ]; then
                    # Pre-configure /etc/sysconfig/postgresql to pass initdb options
                    if [ -f /etc/sysconfig/postgresql ]; then
                        sed -i "s/^PGDATA=.*/PGDATA=\"$pg_data_dir\"/" /etc/sysconfig/postgresql 2>/dev/null
                        echo "PGSETUP_INITDB_OPTIONS=\"--auth-local=trust --auth-host=trust\"" >> /etc/sysconfig/postgresql
                    fi
                    if "$pg_init_script" initdb 2>&1; then
                        verbose "PostgreSQL database cluster initialized via init script"
                    else
                        die "Failed to initialize PostgreSQL database cluster (all methods failed)"
                    fi
                else
                    die "Failed to initialize PostgreSQL database cluster (runuser, su, and init script all failed)"
                fi
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
# STEP 1: Force pg_hba.conf to trust BEFORE starting PostgreSQL
# This is critical for re-runs where the previous initdb may have set
# scram-sha-256 or password authentication, which would prevent
# runuser -u postgres -- psql from connecting.
#
# We set ALL connections (local + host) to trust temporarily.
# We'll switch host connections to md5 AFTER setting the password.
# =============================================================================

_pg_hba="$pg_conf_dir/pg_hba.conf"

if [ "$database_host" = "127.0.0.1" ] || [ "$database_host" = "::1" ] || [ "$database_host" = "localhost" ]; then
    if [ -f "$_pg_hba" ]; then
        verbose "Ensuring pg_hba.conf has trust authentication (temporary)..."

        backup_file "$_pg_hba"

        # Replace ALL auth methods with trust for now
        # This includes: scram-sha-256, md5, password, ident, peer, gss, sspi
        # Only modify non-comment lines
        sed -i '/^#/!s/\bscram-sha-256\b/trust/g' "$_pg_hba" 2>/dev/null
        sed -i '/^#/!s/\bmd5\b/trust/g' "$_pg_hba" 2>/dev/null
        sed -i '/^#/!s/\bpassword\b/trust/g' "$_pg_hba" 2>/dev/null
        sed -i '/^#/!s/\bident\b/trust/g' "$_pg_hba" 2>/dev/null
        sed -i '/^#/!s/\bpeer\b/trust/g' "$_pg_hba" 2>/dev/null

        verbose "  pg_hba.conf: all connections set to trust (temporary)"
    else
        die "pg_hba.conf not found at $_pg_hba!"
    fi
fi

# =============================================================================
# STEP 2: Start PostgreSQL with trust auth
# =============================================================================

if [ "$database_host" = "127.0.0.1" ] || [ "$database_host" = "::1" ] || [ "$database_host" = "localhost" ]; then
    systemctl daemon-reload
    service_enable_start_required "$pg_service"

    if ! wait_for_service "$pg_service" 30; then
        die "PostgreSQL service failed to start within 30 seconds. Check: journalctl -u $pg_service -n 50"
    fi
    verbose "PostgreSQL service is running"

    # Reload config in case PostgreSQL was already running with old pg_hba.conf
    # Use pg_ctl reload (NOT psql — psql might not work if auth was broken)
    runuser -u postgres -- pg_ctl reload -D "$pg_data_dir" 2>/dev/null \
        || systemctl reload "$pg_service" 2>/dev/null \
        || warn "Could not reload PostgreSQL config (may need manual reload)"
    sleep 1
fi

# =============================================================================
# STEP 3: Set superuser password and create database/users
# Now that trust auth is active, runuser -u postgres -- psql will work.
# =============================================================================

if [ "$database_host" = "127.0.0.1" ] || [ "$database_host" = "::1" ] || [ "$database_host" = "localhost" ]; then
    _cwd=$(pwd)
    cd /tmp

    # Set postgres superuser password
    verbose "Setting postgres superuser password..."
    if runuser -u postgres -- psql -c "ALTER USER postgres WITH PASSWORD '$database_password';" 2>/dev/null; then
        verbose "  Postgres superuser password set"
    else
        warn "  Failed to set postgres superuser password (may already be set or not needed)"
    fi

    # Create database (idempotent: skip if exists)
    if pg_db_exists "$database_name"; then
        verbose "Database '$database_name' already exists (keeping)"
    else
        verbose "Creating database '$database_name'..."
        if runuser -u postgres -- psql -c "CREATE DATABASE $database_name;" 2>/dev/null; then
            verbose "  Database '$database_name' created"
        else
            die "Failed to create database '$database_name'"
        fi
    fi

    # Create role (idempotent: skip if exists)
    if pg_role_exists "$database_username"; then
        verbose "Role '$database_username' already exists (keeping, password unchanged)"
    else
        verbose "Creating role '$database_username'..."
        runuser -u postgres -- psql \
            -c "CREATE ROLE $database_username WITH SUPERUSER LOGIN PASSWORD '$database_password';" 2>/dev/null

        if pg_role_exists "$database_username"; then
            verbose "  Role '$database_username' created with SUPERUSER privileges"
        else
            die "Failed to create role '$database_username'"
        fi
    fi

    # Grant privileges (idempotent)
    runuser -u postgres -- psql -c "GRANT ALL PRIVILEGES ON DATABASE $database_name TO $database_username;" 2>/dev/null
    verbose "Privileges granted on '$database_name' to '$database_username'"

    cd "$_cwd"
fi

# =============================================================================
# STEP 4: Switch host connections to md5 authentication
# Now that the password is set, we can enforce md5 auth for TCP connections.
# Keep local (Unix socket) connections as trust for runuser -u postgres -- psql.
# =============================================================================

if [ "$database_host" = "127.0.0.1" ] || [ "$database_host" = "::1" ] || [ "$database_host" = "localhost" ]; then
    if [ -f "$_pg_hba" ]; then
        verbose "Switching host connections to md5 authentication..."

        # Replace trust with md5 for host (TCP) connections ONLY
        # Keep "local" lines as trust so runuser -u postgres -- psql works without password
        sed -i '/^host/s/\btrust\b/md5/g' "$_pg_hba" 2>/dev/null

        verbose "  pg_hba.conf: local=trust, host=md5"

        # Reload config via pg_ctl (NOT psql — psql might not connect with new md5 rules)
        runuser -u postgres -- pg_ctl reload -D "$pg_data_dir" 2>/dev/null \
            || systemctl reload "$pg_service" 2>/dev/null \
            || warn "Could not reload PostgreSQL config after md5 switch"
        sleep 1
    fi
fi

# =============================================================================
# Save database credentials for other scripts
# =============================================================================

if [ "$database_host" = "127.0.0.1" ] || [ "$database_host" = "::1" ] || [ "$database_host" = "localhost" ]; then
    _pgpass_file="/var/www/fusionpbx/.pgpass"

    if [ -d "/var/www/fusionpbx" ]; then
        verbose "Creating .pgpass for FusionPBX..."
        echo "${database_host}:${database_port}:${database_name}:${database_username}:${database_password}" > "$_pgpass_file"
        chown "$web_user:$web_group" "$_pgpass_file" 2>/dev/null
        chmod 600 "$_pgpass_file"
        verbose ".pgpass created at $_pgpass_file"
    fi
fi

# Store password for finish.sh
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
