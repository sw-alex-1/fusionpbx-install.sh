#!/bin/sh

# FusionPBX Alt Linux Installer - Environment Detection
# Detects OS version, CPU architecture, and sets environment variables.
# Uses /etc/os-release as primary source (no extra packages needed).
# Safe for re-runs: all detection is stateless and idempotent.

# --- OS Detection ---
# Use /etc/os-release as primary source (always available on modern Linux,
# no need to install lsb-release separately)
os_name="unknown"
os_version="unknown"

if [ -f /etc/os-release ]; then
    # Source the file to get standard variables (ID, VERSION_ID, etc.)
    . /etc/os-release

    # Normalize OS name to a standard identifier
    case "$ID" in
        altlinux|alt\ linux|alt_linux|basealt)
            os_name="AltLinux"
            ;;
        *)
            os_name="$ID"
            ;;
    esac
    os_version="${VERSION_ID:-unknown}"

elif cmd_exists lsb_release; then
    # Fallback to lsb_release if /etc/os-release is missing
    _lsb_id=$(lsb_release -is 2>/dev/null | tr '[:upper:]' '[:lower:]' | sed 's/ //g')
    case "$_lsb_id" in
        altlinux|altlinux*)
            os_name="AltLinux"
            ;;
        *)
            os_name="$_lsb_id"
            ;;
    esac
    os_version=$(lsb_release -rs 2>/dev/null)
fi

# Verify we are running on Alt Linux
if [ "$os_name" != "AltLinux" ]; then
    error "This installer is designed for Alt Linux."
    error "Detected OS: $os_name ($os_version)"
    error "Please use the appropriate installer for your operating system."
    exit 1
fi

# --- CPU Detection ---
cpu_name=$(uname -m)
cpu_architecture='unknown'
cpu_mode='unknown'
os_mode='unknown'

# Determine CPU architecture and OS bitness
case "$cpu_name" in
    armv6l)
        # Raspberry Pi Zero
        os_mode='32'
        cpu_mode='32'
        cpu_architecture='arm'
        ;;
    armv7l)
        # Raspberry Pi 3 (reports as armv7l on 32-bit OS)
        os_mode='32'
        cpu_mode='32'
        cpu_architecture='arm'
        ;;
    armv8l)
        # ARMv8 running 32-bit userspace
        os_mode='unknown'
        cpu_mode='64'
        cpu_architecture='arm'
        ;;
    aarch64)
        # ARMv8 64-bit
        os_mode='64'
        cpu_mode='64'
        cpu_architecture='arm'
        ;;
    i386|i686)
        os_mode='32'
        if grep -q -w 'lm' /proc/cpuinfo 2>/dev/null; then
            cpu_mode='64'
        else
            cpu_mode='32'
        fi
        cpu_architecture='x86'
        ;;
    x86_64)
        os_mode='64'
        cpu_mode='64'
        cpu_architecture='x86'
        ;;
    *)
        error "Unsupported CPU architecture: $cpu_name"
        error "Supported: x86_64, i386, i686, aarch64, armv7l, armv8l"
        exit 3
        ;;
esac

# --- Validate Architecture and Set Defaults ---
# ARM 64-bit: FreeSWITCH packages may not be available, default to source build
if [ "$cpu_architecture" = 'arm' ]; then
    if [ "$os_mode" = '32' ]; then
        verbose "ARM 32-bit detected - FreeSWITCH will be compiled from source"
        switch_source=true
        switch_package=false
    elif [ "$os_mode" = '64' ]; then
        verbose "ARM 64-bit detected"
        # ARM64 may have FreeSWITCH packages; leave config as-is
    else
        error "Unknown ARM OS mode: $os_mode - will compile FreeSWITCH from source"
        switch_source=true
        switch_package=false
    fi
elif [ "$cpu_architecture" = 'x86' ]; then
    if [ "$os_mode" = '32' ]; then
        error "32-bit OS is not supported"
        if [ "$cpu_mode" = '64' ]; then
            warning "Your CPU supports 64-bit - please reinstall with a 64-bit OS"
        fi
        exit 3
    elif [ "$os_mode" = '64' ]; then
        verbose "Alt Linux $os_version on $cpu_name (64-bit)"
    else
        error "Unknown OS mode: $os_mode"
        exit 3
    fi
else
    error "Unsupported architecture: $cpu_architecture"
    exit 3
fi

# --- PATH ---
export PATH="$PATH:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# --- Environment Summary ---
verbose "Environment detected:"
verbose "  OS:      $os_name $os_version"
verbose "  CPU:     $cpu_name ($cpu_architecture, ${os_mode}-bit)"
