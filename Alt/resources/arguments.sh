#!/bin/sh

# FusionPBX Alt Linux Installer - Command Line Arguments
# Processes command-line options and applies overrides to config variables.
# Safe for re-runs: uses ARGUMENTS_PROCESSED guard to avoid double-parsing.

# Only process arguments once (guard against re-sourcing)
if [ -z "$ARGUMENTS_PROCESSED" ]; then
    export script_name=$(basename "$0")

    # Parse options using getopt
    # Fixed bug from original: used single quotes around $script_name preventing expansion
    # --proxy requires an argument (the colon after proxy means "takes a value")
    ARGS=$(getopt -n "$script_name" -o h -l help,use-switch-source,use-switch-package-all,use-switch-master,use-system-master,no-cpu-check,force,proxy: -- "$@")

    if [ $? -ne 0 ]; then
        error "Failed parsing command line options."
        exit 1
    fi

    # Default values for flags
    export USE_SWITCH_SOURCE=false
    export USE_SWITCH_PACKAGE_ALL=false
    export USE_SWITCH_MASTER=false
    export USE_SYSTEM_MASTER=false
    export CPU_CHECK=true
    export FORCE_INSTALL=false
    export ARGUMENTS_PROCESSED=true
    export PROXY_SERVER=""
    HELP=false

    # Process parsed options
    while true; do
        case "$1" in
            --use-switch-source )
                export USE_SWITCH_SOURCE=true
                shift
                ;;
            --use-switch-package-all )
                export USE_SWITCH_PACKAGE_ALL=true
                shift
                ;;
            --use-switch-master )
                export USE_SWITCH_MASTER=true
                shift
                ;;
            --use-system-master )
                export USE_SYSTEM_MASTER=true
                shift
                ;;
            --no-cpu-check )
                export CPU_CHECK=false
                shift
                ;;
            --force )
                export FORCE_INSTALL=true
                shift
                ;;
            --proxy )
                export PROXY_SERVER="$2"
                shift 2
                ;;
            -h | --help )
                HELP=true
                shift
                ;;
            -- )
                shift
                break
                ;;
            * )
                break
                ;;
        esac
    done

    # Show help and exit
    if [ "$HELP" = "true" ]; then
        warning "FusionPBX Alt Linux Installer"
        warning ""
        warning "Usage: $script_name [OPTIONS]"
        warning ""
        warning "Options:"
        warning "  --use-switch-source      Build FreeSWITCH from source instead of ${green}(default: RPM packages)"
        warning "  --use-switch-package-all Install all FreeSWITCH modules (meta-package)"
        warning "  --use-switch-master      Use FreeSWITCH master branch instead of ${green}(default: stable)"
        warning "  --use-system-master      Use FusionPBX master branch instead of ${green}(default: $system_branch)"
        warning "  --no-cpu-check           Skip CPU architecture validation ${green}(default: check enabled)"
        warning "  --force                  Bypass the installed-system protection"
        warning "                           DANGER: re-running on an installed system"
        warning "                           destroys its configuration (see resources/guard.sh)"
        warning "  --proxy host:port        Use HTTP proxy for all network operations"
        warning "                           Example: --proxy 192.168.0.1:8080"
        warning "  -h, --help               Show this help message"
        exit 0
    fi

    # Apply argument overrides to config variables
    # These override the defaults set in config.sh
    if [ "$USE_SWITCH_SOURCE" = "true" ]; then
        switch_source=true
        switch_package=false
    fi
    if [ "$USE_SWITCH_PACKAGE_ALL" = "true" ]; then
        switch_package_all=true
    fi
    if [ "$USE_SWITCH_MASTER" = "true" ]; then
        switch_branch=master
    fi
    if [ "$USE_SYSTEM_MASTER" = "true" ]; then
        system_branch=master
    fi

    # Validate proxy format if specified
    if [ -n "$PROXY_SERVER" ]; then
        # Strip protocol prefix if user provided it
        PROXY_SERVER=$(echo "$PROXY_SERVER" | sed 's|^https\?://||')
        export PROXY_SERVER

        # Basic validation: must contain a colon (host:port)
        if ! echo "$PROXY_SERVER" | grep -q ':'; then
            error "Invalid proxy format: $PROXY_SERVER"
            error "Expected format: host:port (e.g. 192.168.0.1:8080)"
            exit 1
        fi

        verbose "Proxy server configured: $PROXY_SERVER"
    fi
fi
