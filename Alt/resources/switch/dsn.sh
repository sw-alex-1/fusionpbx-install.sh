#!/bin/sh

# FusionPBX Alt Linux Installer - FreeSWITCH DSN Configuration
# Configures FreeSWITCH to use PostgreSQL for its internal databases
# instead of SQLite. This is the same logic as the Debian installer
# but with Alt Linux paths and credentials handling.
#
# IMPORTANT: This script must be run BEFORE starting FreeSWITCH.
# It modifies FreeSWITCH XML configs and creates DSN variables.

# Determine script directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Includes
. ../config.sh
. ../colors.sh
. ../util.sh

# =============================================================================
# Read database credentials
# These were saved by postgresql.sh to a temporary file.
# =============================================================================

if [ -f "/tmp/fusionpbx_db_credentials" ]; then
    . /tmp/fusionpbx_db_credentials
else
    # If credentials file is missing, use config.sh values
    if [ "$database_password" = "random" ]; then
        die "Database password not available. Run postgresql.sh first."
    fi
fi

_fs_conf="/etc/freeswitch"

# =============================================================================
# Verify FreeSWITCH configuration exists
# =============================================================================

if [ ! -d "$_fs_conf" ]; then
    die "FreeSWITCH configuration not found at $_fs_conf. Run conf-copy.sh first."
fi

# =============================================================================
# Enable auto-create-schemas in switch.conf.xml
# This allows FreeSWITCH to automatically create its database tables.
# =============================================================================

verbose "Configuring FreeSWITCH database settings..."

_switch_conf="$_fs_conf/autoload_configs/switch.conf.xml"

if [ -f "$_switch_conf" ]; then
    # Enable auto-create-schemas (commented out -> enabled)
    sed -i "$_switch_conf" -e 's:<!-- <param name="auto-create-schemas" value="true"/> -->:<param name="auto-create-schemas" value="true"/>:'

    # Also handle the case where it's explicitly set to false
    sed -i "$_switch_conf" -e 's:<param name="auto-create-schemas" value="false"/>:<param name="auto-create-schemas" value="true"/>:'

    verbose "  auto-create-schemas enabled"
else
    warn "switch.conf.xml not found at $_switch_conf"
fi

# =============================================================================
# Enable odbc-dsn in FreeSWITCH config files
# These settings configure FreeSWITCH to use the PostgreSQL DSN
# for its internal databases (core, fifo, etc.)
# =============================================================================

# db.conf.xml
_db_conf="$_fs_conf/autoload_configs/db.conf.xml"
if [ -f "$_db_conf" ]; then
    sed -i "$_db_conf" -e 's:<!--<param name="odbc-dsn" value="$${dsn}"/>-->:<param name="odbc-dsn" value="$${dsn}"/>:'
    verbose "  odbc-dsn enabled in db.conf.xml"
fi

# fifo.conf.xml
_fifo_conf="$_fs_conf/autoload_configs/fifo.conf.xml"
if [ -f "$_fifo_conf" ]; then
    sed -i "$_fifo_conf" -e 's:<!--<param name="odbc-dsn" value="$${dsn}"/>-->:<param name="odbc-dsn" value="$${dsn}"/>:'
    verbose "  odbc-dsn enabled in fifo.conf.xml"
fi

# switch.conf.xml - core-db-dsn
if [ -f "$_switch_conf" ]; then
    sed -i "$_switch_conf" -e 's:<!-- <param name="core-db-dsn" value="$${dsn}" /> -->:<param name="core-db-dsn" value="$${dsn}" />:'
    verbose "  core-db-dsn enabled in switch.conf.xml"
fi

# =============================================================================
# Update FusionPBX config to use shared memory for switch DB
# This improves performance by placing FreeSWITCH's SQLite databases
# in shared memory (/dev/shm) instead of on disk.
# =============================================================================

_fpbx_config="/var/www/fusionpbx/resources/config.conf"
if [ -f "$_fpbx_config" ]; then
    sed -i "$_fpbx_config" -e 's:/var/lib/freeswitch/db:/dev/shm:'
    verbose "  FusionPBX switch DB directory set to /dev/shm"
fi

# =============================================================================
# Add DSN variables to vars.xml
# These variables are referenced by the odbc-dsn parameters above.
# =============================================================================

_vars_xml="$_fs_conf/vars.xml"

if [ -f "$_vars_xml" ]; then
    # Check if DSN variables already exist (idempotent)
    if ! grep -q 'dsn_system' "$_vars_xml" 2>/dev/null; then
        verbose "  Adding DSN variables to vars.xml"

        # Build the DSN connection strings
        _dsn_system="pgsql://hostaddr=$database_host port=$database_port dbname=$database_name user=$database_username password=$database_password options="
        _dsn="sqlite:///dev/shm/core.db"
        _dsn_callcenter="sqlite:///dev/shm/callcenter.db"

        echo "" >> "$_vars_xml"
        echo "<!-- DSN -->" >> "$_vars_xml"
        echo "<X-PRE-PROCESS cmd=\"set\" data=\"dsn_system=$_dsn_system\" />" >> "$_vars_xml"
        echo "<X-PRE-PROCESS cmd=\"set\" data=\"dsn=$_dsn\" />" >> "$_vars_xml"
        echo "<X-PRE-PROCESS cmd=\"set\" data=\"dsn_callcenter=$_dsn_callcenter\" />" >> "$_vars_xml"
    else
        verbose "  DSN variables already exist in vars.xml (keeping existing)"
    fi
else
    warn "vars.xml not found at $_vars_xml"
fi

# =============================================================================
# Remove SQLite database files
# These will be recreated in shared memory (/dev/shm) on next FreeSWITCH start.
# =============================================================================

_dbs="/var/lib/freeswitch/db/core.db /var/lib/freeswitch/db/fifo.db /var/lib/freeswitch/db/call_limit.db"
for _db in $_dbs; do
    if [ -f "$_db" ]; then
        verbose "  Removing old SQLite DB: $_db"
        rm -f "$_db"
    fi
done

# Also remove sofia_reg_* databases
for _db in /var/lib/freeswitch/db/sofia_reg_*; do
    if [ -f "$_db" ]; then
        verbose "  Removing old Sofia reg DB: $(basename "$_db")"
        rm -f "$_db"
    fi
done

# =============================================================================
# Flush FusionPBX cache
# =============================================================================

if [ -d "/var/cache/fusionpbx" ]; then
    rm -rf /var/cache/fusionpbx/*
    verbose "  FusionPBX cache flushed"
fi

verbose ""
verbose "FreeSWITCH DSN configuration summary:"
verbose "  auto-create-schemas: enabled"
verbose "  odbc-dsn:           enabled (db, fifo, switch)"
verbose "  DSN system:         pgsql://$database_host:$database_port/$database_name"
verbose "  DSN core:           sqlite:///dev/shm/core.db"
verbose "  DSN callcenter:     sqlite:///dev/shm/callcenter.db"
verbose "  Switch DB dir:      /dev/shm (shared memory)"
verbose ""
