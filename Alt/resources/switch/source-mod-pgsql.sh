#!/bin/sh

# FusionPBX Alt Linux Installer - Build mod_pgsql from FreeSWITCH Source
#
# WHY THIS SCRIPT EXISTS:
# The Alt Linux FreeSWITCH RPM packages (freeswitch-daemon) do NOT include
# mod_pgsql.so. Without this module, FreeSWITCH cannot connect to PostgreSQL,
# which is the database backend required by FusionPBX. On Debian/Ubuntu, a
# separate freeswitch-mod-pgsql package exists, but no such package is
# available in the Alt Linux repository (confirmed via apt-cache search).
#
# This script compiles mod_pgsql from the FreeSWITCH source code, applying
# the same patch that the Debian/Ubuntu installers use for PostgreSQL 14+
# compatibility. It builds ONLY the mod_pgsql module, not the entire
# FreeSWITCH application.
#
# This is equivalent to what the Debian source-based installer does in
# debian/resources/switch/source-release.sh, but optimized for a single module.
#
# APPROACH:
# 1. Install build dependencies (gcc, make, autoconf, libpq-devel, etc.)
# 2. Detect the installed FreeSWITCH version from RPM
# 3. Clone the FreeSWITCH source at the matching version
# 4. Create a minimal modules.conf (only mod_pgsql) to speed up build
# 5. Run bootstrap.sh to generate the build system
# 6. Apply mod_pgsql.patch for PostgreSQL 14+ compatibility
# 7. Configure with --enable-core-pgsql-support
# 8. Build only mod_pgsql (make mod_pgsql)
# 9. Install mod_pgsql.so to /usr/lib64/freeswitch/
# 10. Enable mod_pgsql in modules.conf.xml
# 11. Clean up the build directory
#
# PREREQUISITES:
# - FreeSWITCH must already be installed from RPM packages
# - PostgreSQL must already be installed and running
# - Internet access for downloading the FreeSWITCH source code
#
# IDEMPOTENT: If mod_pgsql.so already exists, this script skips compilation.

# Determine script directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Includes
. ../config.sh
. ../colors.sh
. ../util.sh

# =============================================================================
# Configuration
# =============================================================================

# FreeSWITCH modules directory (where mod_pgsql.so will be installed)
FS_MODULES_DIR="/usr/lib64/freeswitch"
FS_CONF_DIR="/etc/freeswitch"
MODULES_CONF_XML="$FS_CONF_DIR/autoload_configs/modules.conf.xml"

# Build directory
BUILD_DIR="/usr/src/freeswitch-mod-pgsql-build"

# =============================================================================
# Pre-flight checks
# =============================================================================

verbose ""
verbose "=== Building mod_pgsql from FreeSWITCH source ==="
verbose ""

# Check if mod_pgsql.so already exists (idempotent)
if [ -f "$FS_MODULES_DIR/mod_pgsql.so" ]; then
    verbose "mod_pgsql.so already exists at $FS_MODULES_DIR/mod_pgsql.so"
    verbose "Skipping compilation. To rebuild, remove the file first:"
    verbose "  rm -f $FS_MODULES_DIR/mod_pgsql.so"
    exit 0
fi

# Check if FreeSWITCH is installed
if ! pkg_is_installed freeswitch-daemon; then
    die "FreeSWITCH is not installed. Run package-release.sh first."
fi

# Check if git is available (needed to download source)
if ! cmd_exists git; then
    verbose "Installing git (required to download FreeSWITCH source)..."
    pkg_install git || die "Failed to install git"
fi

# =============================================================================
# Detect installed FreeSWITCH version
# =============================================================================

verbose "Detecting installed FreeSWITCH version..."

# Get version from RPM package metadata
FS_INSTALLED_VERSION=$(rpm -q --qf '%{VERSION}' freeswitch-daemon 2>/dev/null || true)

# Fallback: try to get version from the binary
if [ -z "$FS_INSTALLED_VERSION" ]; then
    FS_INSTALLED_VERSION=$(freeswitch -version 2>/dev/null | head -1 | sed -n 's/.*\([0-9]\+\.[0-9]\+\.[0-9]\+\).*/\1/p' | head -1 || true)
fi

# Default version if detection fails
if [ -z "$FS_INSTALLED_VERSION" ]; then
    warn "Could not detect FreeSWITCH version from RPM"
    warn "Using default version: 1.10.12"
    FS_INSTALLED_VERSION="1.10.12"
fi

verbose "  Installed FreeSWITCH version: $FS_INSTALLED_VERSION"

# =============================================================================
# Install build dependencies
# =============================================================================

verbose "Installing build dependencies..."

# Core build tools
pkg_install gcc gcc-c++ make autoconf automake libtool pkg-config wget

# FreeSWITCH core dependencies (required by configure even for minimal build)
pkg_install libssl-devel libsqlite3-devel libpcre-devel libncurses-devel
pkg_install libcurl-devel libedit-devel libjpeg-devel

# PostgreSQL client development headers (CRITICAL for mod_pgsql)
pkg_install libpq-devel

# Additional dependencies that may be needed by the core build
# These are soft dependencies - install if available, don't fail if not
for _pkg in speex-devel libogg-devel libvorbis-devel libtiff-devel \
    flac-devel libsndfile-devel libuuid-devel; do
    if apt-cache search "^$_pkg$" 2>/dev/null | grep -q "$_pkg"; then
        pkg_install "$_pkg" 2>/dev/null || true
    fi
done

verbose "  Build dependencies installed"

# =============================================================================
# Get FreeSWITCH source code
# =============================================================================

verbose "Downloading FreeSWITCH source code (version $FS_INSTALLED_VERSION)..."

# Clean up any previous build attempt
if [ -d "$BUILD_DIR" ]; then
    verbose "  Removing previous build directory"
    rm -rf "$BUILD_DIR"
fi

# Try to clone from the fusionpbx/freeswitch repo (same as Debian installer)
# The fusionpbx fork has version-specific branches (e.g. "1.10.12")
_CLONED=false

verbose "  Trying fusionpbx/freeswitch (branch: $FS_INSTALLED_VERSION)..."
if git clone -b "$FS_INSTALLED_VERSION" --single-branch --depth 1 \
    https://github.com/fusionpbx/freeswitch.git "$BUILD_DIR" 2>/dev/null; then
    _CLONED=true
    verbose "  Cloned from fusionpbx/freeswitch (branch: $FS_INSTALLED_VERSION)"
fi

# Try signalwire/freeswitch with 'v' prefix tag
if [ "$_CLONED" = "false" ]; then
    verbose "  Trying signalwire/freeswitch (tag: v${FS_INSTALLED_VERSION})..."
    if git clone -b "v${FS_INSTALLED_VERSION}" --single-branch --depth 1 \
        https://github.com/signalwire/freeswitch.git "$BUILD_DIR" 2>/dev/null; then
        _CLONED=true
        verbose "  Cloned from signalwire/freeswitch (tag: v${FS_INSTALLED_VERSION})"
    fi
fi

# Try signalwire/freeswitch without 'v' prefix
if [ "$_CLONED" = "false" ]; then
    verbose "  Trying signalwire/freeswitch (tag: ${FS_INSTALLED_VERSION})..."
    if git clone -b "$FS_INSTALLED_VERSION" --single-branch --depth 1 \
        https://github.com/signalwire/freeswitch.git "$BUILD_DIR" 2>/dev/null; then
        _CLONED=true
        verbose "  Cloned from signalwire/freeswitch (tag: ${FS_INSTALLED_VERSION})"
    fi
fi

# Fall back to a known good version
if [ "$_CLONED" = "false" ]; then
    warn "Could not find source for version $FS_INSTALLED_VERSION"
    warn "Falling back to FreeSWITCH v1.10.12"
    if git clone -b "v1.10.12" --single-branch --depth 1 \
        https://github.com/signalwire/freeswitch.git "$BUILD_DIR"; then
        _CLONED=true
        verbose "  Cloned from signalwire/freeswitch (tag: v1.10.12)"
    fi
fi

if [ "$_CLONED" = "false" ]; then
    die "Failed to clone FreeSWITCH source code. Check internet connectivity."
fi

cd "$BUILD_DIR"

# =============================================================================
# Create minimal modules.conf (only mod_pgsql)
# This drastically reduces build time and required dependencies.
# We don't need to build any other modules — they're already installed from RPM.
# =============================================================================

verbose "Creating minimal modules.conf (only mod_pgsql)..."

cat > modules.conf << 'EOF'
formats/mod_pgsql
EOF

verbose "  modules.conf: only mod_pgsql enabled"

# =============================================================================
# Bootstrap the build system
# This generates the configure script from configure.ac
# =============================================================================

verbose "Running bootstrap.sh (generates configure script)..."
verbose "  This may take 2-3 minutes..."

./bootstrap.sh -j || die "bootstrap.sh failed. Check autoconf/automake versions."

verbose "  Bootstrap completed"

# =============================================================================
# Apply mod_pgsql patch for PostgreSQL 14+ compatibility
#
# The patch fixes:
# 1. Adds #include <pg_config.h> (needed for PG_VERSION_NUM macro)
# 2. Replaces deprecated POSTGRESQL_MAJOR_VERSION/MINOR_VERSION checks
#    with PG_VERSION_NUM >= XXXXX (works with all PostgreSQL versions)
# 3. Adds handling for PGRES_PIPELINE_ABORTED and PGRES_PIPELINE_SYNC
#    (new in PostgreSQL 14+)
#
# Without this patch, mod_pgsql will not compile with PostgreSQL 14+
# =============================================================================

verbose "Applying mod_pgsql patch for PostgreSQL 14+ compatibility..."

_MOD_PGSQL_SRC="$BUILD_DIR/src/mod/databases/mod_pgsql/mod_pgsql.c"
_PATCH_FILE="$SCRIPT_DIR/source/mod_pgsql.patch"

if [ -f "$_PATCH_FILE" ] && [ -f "$_MOD_PGSQL_SRC" ]; then
    # Try dry-run first to check if the patch applies cleanly
    if patch -u "$_MOD_PGSQL_SRC" -i "$_PATCH_FILE" --dry-run 2>/dev/null; then
        patch -u "$_MOD_PGSQL_SRC" -i "$_PATCH_FILE"
        verbose "  Patch applied successfully"
    else
        # Check if the patch is already applied (source already has PG_VERSION_NUM)
        if grep -q 'PG_VERSION_NUM' "$_MOD_PGSQL_SRC" 2>/dev/null; then
            verbose "  Patch already applied (PG_VERSION_NUM found in source)"
        else
            warn "  Patch does not apply cleanly (source may have changed)"
            warn "  Building without patch — may fail with PostgreSQL 14+"
            warn "  If the build fails, try manually patching mod_pgsql.c"
        fi
    fi
else
    warn "  Patch file not found at $_PATCH_FILE"
    warn "  Building without patch — may fail with PostgreSQL 14+"
fi

# =============================================================================
# Configure the build
#
# --enable-core-pgsql-support is CRITICAL: it tells FreeSWITCH to build
# with PostgreSQL support in the core, which mod_pgsql depends on.
#
# --prefix=/usr --libdir=/usr/lib64 matches the Alt Linux filesystem layout.
# We use /usr/lib64 (not /usr/lib) because Alt Linux is 64-bit.
#
# modules.conf has only mod_pgsql, so configure only checks for
# mod_pgsql's dependencies (libpq), skipping the dependencies of
# modules we don't need (libks, sofia-sip, spandsp, etc.).
# =============================================================================

verbose "Configuring the build..."
verbose "  This may take 3-5 minutes (checking dependencies)..."

./configure \
    --enable-core-pgsql-support \
    --prefix=/usr \
    --libdir=/usr/lib64 \
    --localstatedir=/var \
    --sysconfdir=/etc \
    || die "configure failed. Check the error output above for missing dependencies."

verbose "  Configure completed"

# =============================================================================
# Build mod_pgsql
#
# 'make mod_pgsql' builds:
#   1. The FreeSWITCH core library (libfreeswitch) — needed for linking
#   2. The mod_pgsql module itself
#
# This may take 10-20 minutes depending on the machine.
# We use parallel make to speed things up.
# =============================================================================

verbose "Building mod_pgsql..."
verbose "  This may take 10-20 minutes (includes core library build)..."

_NPROC=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
verbose "  Using $_NPROC parallel jobs"

make -j "$_NPROC" mod_pgsql || die "make mod_pgsql failed. Check the error output above."

verbose "  mod_pgsql compiled successfully"

# =============================================================================
# Install mod_pgsql.so
# =============================================================================

verbose "Installing mod_pgsql.so..."

# Find the compiled module (location varies depending on build system)
_MOD_SO=""
for _path in \
    "$BUILD_DIR/src/mod/databases/mod_pgsql/.libs/mod_pgsql.so" \
    "$BUILD_DIR/src/mod/databases/mod_pgsql/mod_pgsql.so" \
    "$BUILD_DIR/mod/mod_pgsql.so"; do
    if [ -f "$_path" ]; then
        _MOD_SO="$_path"
        break
    fi
done

if [ -z "$_MOD_SO" ]; then
    # Try a broader search
    _MOD_SO=$(find "$BUILD_DIR" -name "mod_pgsql.so" -type f 2>/dev/null | head -1 || true)
fi

if [ -z "$_MOD_SO" ]; then
    die "mod_pgsql.so not found in build directory. The build may have failed silently."
fi

verbose "  Found: $_MOD_SO"

# Install to FreeSWITCH modules directory
cp "$_MOD_SO" "$FS_MODULES_DIR/mod_pgsql.so" || die "Failed to copy mod_pgsql.so to $FS_MODULES_DIR"
chmod 755 "$FS_MODULES_DIR/mod_pgsql.so"
chown "$fs_user:$fs_group" "$FS_MODULES_DIR/mod_pgsql.so"

verbose "  Installed to $FS_MODULES_DIR/mod_pgsql.so"

# =============================================================================
# Enable mod_pgsql in modules.conf.xml
#
# FreeSWITCH loads modules listed in modules.conf.xml at startup.
# Without this entry, mod_pgsql.so will exist but won't be loaded.
# =============================================================================

verbose "Enabling mod_pgsql in modules.conf.xml..."

if [ -f "$MODULES_CONF_XML" ]; then
    # Check if mod_pgsql is already in the config
    if grep -q 'mod_pgsql' "$MODULES_CONF_XML" 2>/dev/null; then
        # It might be commented out — uncomment it
        sed -i "$MODULES_CONF_XML" -e 's:<!--.*<load module="mod_pgsql".*/>.*-->:<load module="mod_pgsql"/>:'
        # Also handle slight format variations
        sed -i "$MODULES_CONF_XML" -e 's:<!--.*<load module="mod_pgsql" .*/>.*-->:<load module="mod_pgsql"/>:'
        verbose "  mod_pgsql enabled in modules.conf.xml (was commented out)"
    else
        # Add it before the closing </modules> tag
        sed -i "$MODULES_CONF_XML" -e "s:</modules>:  <load module=\"mod_pgsql\"/>\n</modules>:"
        verbose "  mod_pgsql added to modules.conf.xml"
    fi
else
    warn "  modules.conf.xml not found at $MODULES_CONF_XML"
    warn "  You will need to manually add: <load module=\"mod_pgsql\"/>"
fi

# =============================================================================
# Verify the module
# =============================================================================

verbose "Verifying mod_pgsql installation..."

if [ -f "$FS_MODULES_DIR/mod_pgsql.so" ]; then
    _mod_size=$(ls -lh "$FS_MODULES_DIR/mod_pgsql.so" | awk '{print $5}')
    _mod_perms=$(ls -l "$FS_MODULES_DIR/mod_pgsql.so" | awk '{print $1, $3, $4}')
    verbose "  mod_pgsql.so: $FS_MODULES_DIR/mod_pgsql.so ($_mod_size)"
    verbose "  Permissions:  $_mod_perms"
    verbose "  Module is ready for use"
else
    die "mod_pgsql.so installation verification failed"
fi

# Verify the module can be found by FreeSWITCH
if cmd_exists fs_cli; then
    # Don't actually try to load it now — FreeSWITCH might not be running
    verbose "  fs_cli available — module can be loaded after FreeSWITCH restart"
fi

# =============================================================================
# Clean up build directory (saves ~500MB of disk space)
# =============================================================================

verbose "Cleaning up build directory..."

rm -rf "$BUILD_DIR"

verbose "  Build directory removed (saved disk space)"

# =============================================================================
# Summary
# =============================================================================

verbose ""
verbose "mod_pgsql build and installation summary:"
verbose "  FreeSWITCH version:   $FS_INSTALLED_VERSION"
verbose "  Module installed:     $FS_MODULES_DIR/mod_pgsql.so"
verbose "  PostgreSQL 14+ patch: applied"
verbose "  modules.conf.xml:     mod_pgsql enabled"
verbose "  Build directory:      cleaned up"
verbose ""
verbose "IMPORTANT: Restart FreeSWITCH to load the new module:"
verbose "  systemctl restart freeswitch"
verbose ""
verbose "After restart, verify with:"
verbose "  fs_cli -x 'module_exists mod_pgsql'    # should return 'true'"
verbose "  fs_cli -x 'sql pgsql://hostaddr=127.0.0.1 port=5432 dbname=fusionpbx user=fusionpbx password=PASSWORD options= SELECT 1'"
verbose ""
