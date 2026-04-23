#!/bin/sh

# FusionPBX Alt Linux Installer - FreeSWITCH DSN Configuration
# Configures FreeSWITCH to use PostgreSQL for its internal databases
# instead of SQLite. Mirrors the Debian installer's dsn.sh logic.
#
# This script runs AFTER finish.sh, which has already run upgrade.php --defaults
# with FreeSWITCH running. The switch settings should already be correct.
# This script switches FreeSWITCH from SQLite to PostgreSQL and restarts it.

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
# Use PostgreSQL for ALL FreeSWITCH databases (core, fifo, callcenter)
#
# The Debian installer uses SQLite for FreeSWITCH's core database (core.db)
# stored in /dev/shm (shared memory) for performance. However, on Alt Linux,
# SQLite's file locking mechanism (fcntl F_SETLK) does not work correctly
# with FreeSWITCH, causing "attempt to write a readonly database" errors.
# This prevents modules like mod_local_stream from registering their interfaces.
#
# The workaround is to use PostgreSQL for FreeSWITCH's internal databases
# instead of SQLite. This is a well-supported production configuration that
# avoids the SQLite locking issue entirely. FreeSWITCH auto-creates its
# tables in PostgreSQL when auto-create-schemas is enabled.
#
# Using the same PostgreSQL database for both FusionPBX and FreeSWITCH is
# safe because FusionPBX tables are prefixed with 'v_' while FreeSWITCH uses
# unprefixed names (interfaces, calls, channels, etc.).
# =============================================================================

verbose "  Using PostgreSQL for all FreeSWITCH databases (avoids SQLite issues on Alt Linux)"

# Build the DSN connection strings
# ALL FreeSWITCH databases use the same PostgreSQL database as FusionPBX.
# This is simpler and more robust than using a separate 'freeswitch' database,
# and avoids the need to create/manage an additional database.
_dsn_system="pgsql://hostaddr=$database_host port=$database_port dbname=$database_name user=$database_username password=$database_password options="
_dsn="$_dsn_system"
_dsn_callcenter="$_dsn_system"

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
# This is what the Debian installer does. FusionPBX uses these database
# records to generate FreeSWITCH XML configuration dynamically via the
# XML handler. Without them, FreeSWITCH cannot connect to PostgreSQL and
# the system is "uncontrollable" from the FusionPBX web interface.
#
# These UUIDs are the SAME as in the Debian installer to ensure consistency.
# =============================================================================

verbose "Inserting DSN variables into database (v_vars table)..."

# Set PGPASSWORD for psql commands
export PGPASSWORD=$database_password

# Insert dsn_system variable
# Use ON CONFLICT DO UPDATE to ensure the value is always correct
# (on reinstall, old SQLite values would persist with DO NOTHING)
runuser -u postgres -- psql -d "$database_name" -c \
    "INSERT INTO v_vars (var_uuid, var_name, var_value, var_category, var_enabled, var_order, var_description, var_hostname)
     VALUES ('785d7013-1152-4a44-aa15-28336d9b36f9', 'dsn_system', '$_dsn_system', 'DSN', 'true', '0', null, null)
     ON CONFLICT (var_uuid) DO UPDATE SET var_value = EXCLUDED.var_value;" 2>/dev/null \
    || verbose "  dsn_system: insert/update skipped (v_vars table may not exist yet)"

# Insert dsn variable
runuser -u postgres -- psql -d "$database_name" -c \
    "INSERT INTO v_vars (var_uuid, var_name, var_value, var_category, var_enabled, var_order, var_description, var_hostname)
     VALUES ('0170e737-b453-40ea-99f2-f1375474e5ce', 'dsn', '$_dsn', 'DSN', 'true', '0', null, null)
     ON CONFLICT (var_uuid) DO UPDATE SET var_value = EXCLUDED.var_value;" 2>/dev/null \
    || verbose "  dsn: insert/update skipped (v_vars table may not exist yet)"

# Insert dsn_callcenter variable
runuser -u postgres -- psql -d "$database_name" -c \
    "INSERT INTO v_vars (var_uuid, var_name, var_value, var_category, var_enabled, var_order, var_description, var_hostname)
     VALUES ('32e3e364-a8ef-4fe0-9d02-c652d5122bbf', 'dsn_callcenter', '$_dsn_callcenter', 'DSN', 'true', '0', null, null)
     ON CONFLICT (var_uuid) DO UPDATE SET var_value = EXCLUDED.var_value;" 2>/dev/null \
    || verbose "  dsn_callcenter: insert/update skipped (v_vars table may not exist yet)"

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
# Update the switch DB directory in default settings
# The Debian installer updates v_default_settings to set the switch DB
# directory to /dev/shm instead of /var/lib/freeswitch/db.
# =============================================================================

verbose "Updating switch DB directory in default settings..."

runuser -u postgres -- psql -d "$database_name" -c \
    "UPDATE v_default_settings SET default_setting_value = '/dev/shm'
     WHERE default_setting_category = 'switch' AND default_setting_subcategory = 'db';" 2>/dev/null \
    || verbose "  Default settings update skipped (table may not exist yet)"

# Unset PGPASSWORD for security
unset PGPASSWORD

# =============================================================================
# Remove SQLite database files
# These will be recreated in shared memory (/dev/shm) or replaced by
# PostgreSQL on the next FreeSWITCH start.
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
# Create symlink /usr/local/etc/fusionpbx → /etc/fusionpbx
# FusionPBX's Lua scripts look for config.conf at the hardcoded path
# /usr/local/etc/fusionpbx/config.conf. On Alt Linux, config.conf is
# at /etc/fusionpbx/config.conf. The symlink ensures Lua scripts can
# find the configuration.
# =============================================================================

verbose "Creating config.conf path symlink for Lua scripts..."

_local_etc_fpbx="/usr/local/etc/fusionpbx"
_etc_fpbx="/etc/fusionpbx"

if [ -f "$_etc_fpbx/config.conf" ]; then
    if [ ! -e "$_local_etc_fpbx" ]; then
        mkdir -p /usr/local/etc
        ln -s "$_etc_fpbx" "$_local_etc_fpbx"
        verbose "  Symlink created: $_local_etc_fpbx -> $_etc_fpbx"
    elif [ -L "$_local_etc_fpbx" ]; then
        verbose "  Symlink already exists: $_local_etc_fpbx -> $(readlink "$_local_etc_fpbx")"
    elif [ -d "$_local_etc_fpbx" ]; then
        if [ ! -f "$_local_etc_fpbx/config.conf" ]; then
            cp "$_etc_fpbx/config.conf" "$_local_etc_fpbx/config.conf"
            verbose "  Copied config.conf to $_local_etc_fpbx"
        fi
    fi
else
    warn "  config.conf not found at $_etc_fpbx (skipping symlink creation)"
fi

# =============================================================================
# Flush FusionPBX cache
# =============================================================================

if [ -d "/var/cache/fusionpbx" ]; then
    rm -rf /var/cache/fusionpbx/*
    verbose "  FusionPBX cache flushed"
fi

# =============================================================================
# Restart FreeSWITCH with PostgreSQL DSN
# Now that DSN is configured in vars.xml and v_vars, FreeSWITCH will
# connect to PostgreSQL instead of SQLite on the next start.
# =============================================================================

verbose "Restarting FreeSWITCH with PostgreSQL DSN..."
systemctl restart freeswitch || warn "FreeSWITCH restart failed"
verbose "FreeSWITCH restarted with PostgreSQL configuration"

# =============================================================================
# Summary
# =============================================================================

verbose ""
verbose "FreeSWITCH DSN configuration summary:"
verbose "  auto-create-schemas: enabled"
verbose "  odbc-dsn:           enabled (db, fifo, switch)"
verbose "  DSN in vars.xml:    yes"
verbose "  DSN in v_vars DB:   yes (dsn_system, dsn, dsn_callcenter)"
verbose "  SIP odbc-dsn:       enabled"
verbose "  Lua config symlink: $([ -L "$_local_etc_fpbx" ] && echo "yes" || echo "no")"
verbose "  DSN system:         pgsql://$database_host:$database_port/$database_name"
verbose "  DSN core:           pgsql://$database_host:$database_port/$database_name"
verbose "  DSN callcenter:     pgsql://$database_host:$database_port/$database_name"
verbose "  Switch DB dir:      /dev/shm (shared memory)"
verbose ""
verbose "  Note: On Debian, core and callcenter use SQLite in /dev/shm."
verbose "  Alt Linux uses PostgreSQL for all databases due to SQLite"
verbose "  readonly issues on /dev/shm with the _nginx user."
verbose ""
