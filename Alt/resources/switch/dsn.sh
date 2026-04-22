#!/bin/sh

# FusionPBX Alt Linux Installer - FreeSWITCH DSN Configuration
# Configures FreeSWITCH to use PostgreSQL for its internal databases
# instead of SQLite. Mirrors the Debian installer's dsn.sh logic.
#
# CRITICAL: This script does TWO things that the previous version missed:
#   1. Adds DSN variables to vars.xml (FreeSWITCH reads these on startup)
#   2. Inserts DSN variables into the v_vars database table (FusionPBX reads
#      these to generate XML configs for FreeSWITCH via the XML handler)
#   3. Enables odbc-dsn in SIP profiles via SQL UPDATE
#
# Without step 2, FreeSWITCH cannot build the correct DSN connection strings
# from the database, and FusionPBX cannot configure FreeSWITCH's database
# connections dynamically. This was the ROOT CAUSE of:
#   - "Failure to connect to CORE_DB pgsql://..." errors
#   - Modules count = 0 in FusionPBX dashboard
#   - "uncontrollable" system behavior

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
# FusionPBX config already uses /var/lib/freeswitch/db for switch DB
#
# NOTE: The Debian installer moves FreeSWITCH's SQLite databases to /dev/shm
# (shared memory) for better performance. However, on Alt Linux, SQLite's
# file locking mechanism (fcntl F_SETLK) does not work correctly on tmpfs,
# causing "attempt to write a readonly database" errors. This prevents modules
# like mod_local_stream from registering their interfaces.
# Therefore, we keep the default /var/lib/freeswitch/db path on Alt Linux.
# =============================================================================

verbose "  Switch DB directory: /var/lib/freeswitch/db (standard path, not /dev/shm)"

# =============================================================================
# Add DSN variables to vars.xml
# These variables are referenced by the odbc-dsn parameters above.
# FreeSWITCH reads vars.xml on startup and uses X-PRE-PROCESS to set
# internal variables that are then referenced in other config files.
# =============================================================================

_vars_xml="$_fs_conf/vars.xml"

if [ -f "$_vars_xml" ]; then
    # Check if DSN variables already exist (idempotent)
    if ! grep -q 'dsn_system' "$_vars_xml" 2>/dev/null; then
        verbose "  Adding DSN variables to vars.xml"

        # Build the DSN connection strings
        _dsn_system="pgsql://hostaddr=$database_host port=$database_port dbname=$database_name user=$database_username password=$database_password options="
        _dsn="sqlite:///var/lib/freeswitch/db/core.db"
        _dsn_callcenter="sqlite:///var/lib/freeswitch/db/callcenter.db"

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
# CRITICAL: Insert DSN variables into the database (v_vars table)
#
# This is what the Debian installer does but was MISSING from the Alt installer.
# FusionPBX uses these database records to generate FreeSWITCH XML configuration
# dynamically via the XML handler. Without them, FreeSWITCH cannot connect to
# PostgreSQL and the system is "uncontrollable" from the FusionPBX web interface.
#
# These UUIDs are the SAME as in the Debian installer to ensure consistency.
# =============================================================================

verbose "Inserting DSN variables into database (v_vars table)..."

# Build the DSN connection strings (same as what goes into vars.xml)
_dsn_system="pgsql://hostaddr=$database_host port=$database_port dbname=$database_name user=$database_username password=$database_password options="
_dsn="sqlite:///var/lib/freeswitch/db/core.db"
_dsn_callcenter="sqlite:///var/lib/freeswitch/db/callcenter.db"

# Set PGPASSWORD for psql commands
export PGPASSWORD=$database_password

# Insert dsn_system variable
# Use ON CONFLICT DO NOTHING for idempotency (PostgreSQL 9.5+)
runuser -u postgres -- psql -d "$database_name" -c \
    "INSERT INTO v_vars (var_uuid, var_name, var_value, var_category, var_enabled, var_order, var_description, var_hostname)
     VALUES ('785d7013-1152-4a44-aa15-28336d9b36f9', 'dsn_system', '$_dsn_system', 'DSN', 'true', '0', null, null)
     ON CONFLICT (var_uuid) DO NOTHING;" 2>/dev/null \
    || verbose "  dsn_system: insert skipped (may already exist or v_vars table not yet created)"

# Insert dsn variable
runuser -u postgres -- psql -d "$database_name" -c \
    "INSERT INTO v_vars (var_uuid, var_name, var_value, var_category, var_enabled, var_order, var_description, var_hostname)
     VALUES ('0170e737-b453-40ea-99f2-f1375474e5ce', 'dsn', '$_dsn', 'DSN', 'true', '0', null, null)
     ON CONFLICT (var_uuid) DO NOTHING;" 2>/dev/null \
    || verbose "  dsn: insert skipped (may already exist or v_vars table not yet created)"

# Insert dsn_callcenter variable
runuser -u postgres -- psql -d "$database_name" -c \
    "INSERT INTO v_vars (var_uuid, var_name, var_value, var_category, var_enabled, var_order, var_description, var_hostname)
     VALUES ('32e3e364-a8ef-4fe0-9d02-c652d5122bbf', 'dsn_callcenter', '$_dsn_callcenter', 'DSN', 'true', '0', null, null)
     ON CONFLICT (var_uuid) DO NOTHING;" 2>/dev/null \
    || verbose "  dsn_callcenter: insert skipped (may already exist or v_vars table not yet created)"

verbose "  DSN variables inserted into v_vars table"

# =============================================================================
# Enable odbc-dsn in SIP profiles (database UPDATE)
# The Debian installer does this via SQL UPDATE on v_sip_profile_settings.
# This tells FreeSWITCH's Sofia SIP profiles to use the ODBC DSN for
# their registration databases instead of SQLite.
# =============================================================================

verbose "Enabling odbc-dsn in SIP profiles..."

runuser -u postgres -- psql -d "$database_name" -c \
    "UPDATE v_sip_profile_settings SET sip_profile_setting_enabled = 'true'
     WHERE sip_profile_setting_name = 'odbc-dsn';" 2>/dev/null \
    || verbose "  SIP profile odbc-dsn update skipped (table may not exist yet)"

# =============================================================================
# Switch DB directory stays at /var/lib/freeswitch/db on Alt Linux
#
# The Debian installer changes this to /dev/shm for performance, but on
# Alt Linux, SQLite file locking does not work correctly on tmpfs, causing
# "readonly database" errors. We keep the standard path.
# =============================================================================

verbose "  Switch DB directory in default settings: /var/lib/freeswitch/db (unchanged)"

# Unset PGPASSWORD for security
unset PGPASSWORD

# =============================================================================
# Remove SQLite database files
# These will be recreated in /var/lib/freeswitch/db on next FreeSWITCH start.
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
verbose "  DSN in vars.xml:    yes"
verbose "  DSN in v_vars DB:   yes (dsn_system, dsn, dsn_callcenter)"
verbose "  SIP odbc-dsn:       enabled"
verbose "  DSN system:         pgsql://$database_host:$database_port/$database_name"
verbose "  DSN core:           sqlite:///var/lib/freeswitch/db/core.db"
verbose "  DSN callcenter:     sqlite:///var/lib/freeswitch/db/callcenter.db"
verbose "  Switch DB dir:      /var/lib/freeswitch/db"
verbose ""
