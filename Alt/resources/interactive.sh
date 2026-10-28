#!/bin/sh

# FusionPBX Alt Linux Installer - Interactive Questions Layer
#
# Sourcing contract: install.sh sources this file AFTER resources/arguments.sh
# (so CLI flags are already applied and win over any answer) and BEFORE
# resources/proxy.sh (so an answered proxy reaches every network operation).
#
# UX rules:
#   1. Every question has a safe default - a bare Enter is always safe.
#   2. Anything already given (CLI flag, an edited config.sh value) is NEVER
#      asked for again - questions only fill the gaps.
#   3. No terminal on stdin (piped / 'curl | sh' / ssh without -t / CI):
#      ZERO questions, the documented defaults are used. The installer must
#      stay automatable - a question on a pipe would hang it forever.
#   4. POSIX sh only (dash-safe): no 'read -p', no 'read -s', no printf -v.
#      Passwords are hidden with stty (which needs the same terminal anyway).
#
# What is asked (in order):
#   - whether to ask at all (the meta-question; answering 'n' takes the
#     defaults for everything below)
#   - an HTTP proxy for the installation (default: direct connection)
#   - the FusionPBX domain (default: this node's IP address)
#   - the admin password (default: a random one, shown at the end)
#
# The answers are EXPORTED by the caller (install.sh): the step scripts run
# as child processes and re-source config.sh, whose ${var:-default} defaults
# keep an inherited value (see resources/config.sh).

# =============================================================================
# Primitives (POSIX sh)
# =============================================================================

# ask_value "question" "default" -> prints THE ANSWER on stdout (default on
# empty input or EOF). All prompts go to STDERR: the result is consumed via
# command substitution, and a prompt on stdout would glue itself to the
# answer (a regression this file will not repeat).
ask_value() {
    _av_q="$1"
    _av_def="${2:-}"
    if [ -n "$_av_def" ]; then
        printf '%s [%s]: ' "$_av_q" "$_av_def" >&2
    else
        printf '%s: ' "$_av_q" >&2
    fi
    read -r _av_ans || { printf '\n' >&2; printf '%s\n' "$_av_def"; return 0; }
    [ -z "$_av_ans" ] && _av_ans="$_av_def"
    printf '%s\n' "$_av_ans"
}

# ask_secret "question" -> prints THE ANSWER on stdout, "" on empty input or
# EOF; the prompt and the echo-restoring newline go to stderr. Hides the
# input with stty when stdin is a terminal (stty is the POSIX way - dash
# has no 'read -s'); falls back to a plain read on a pipe (tests).
ask_secret() {
    _as_q="$1"
    printf '%s' "$_as_q" >&2
    if [ -t 0 ] && stty -echo 2>/dev/null; then
        read -r _as_ans || _as_ans=""
        stty echo 2>/dev/null
        printf '\n' >&2
    else
        read -r _as_ans || _as_ans=""
    fi
    printf '%s\n' "$_as_ans"
}

# ask_yesno "question" y|n -> exit code 0 = yes, 1 = no. Bare Enter takes the
# default; an unrecognized answer re-asks.
ask_yesno() {
    _ay_q="$1"
    _ay_def="$2"
    if [ "$_ay_def" = "y" ]; then
        printf '%s [Y/n]: ' "$_ay_q" >&2
    else
        printf '%s [y/N]: ' "$_ay_q" >&2
    fi
    read -r _ay_ans || { printf '\n' >&2; [ "$_ay_def" = "y" ]; return; }
    case "$_ay_ans" in
        [Yy]|[Yy][Ee][Ss]) return 0 ;;
        [Nn]|[Nn][Oo])     return 1 ;;
        "")                [ "$_ay_def" = "y" ] && return 0; return 1 ;;
        *) printf '  Please answer y or n.\n' >&2; ask_yesno "$_ay_q" "$_ay_def"; return ;;
    esac
}

# ask_password -> prints a password typed twice (hidden), or "" when the
# first input is empty (the caller then keeps its random default).
ask_password() {
    while :; do
        _apw_1="$(ask_secret "  Password (Enter = generate a random one): ")"
        [ -z "$_apw_1" ] && return 0
        _apw_2="$(ask_secret "  Repeat the password: ")"
        if [ "$_apw_1" = "$_apw_2" ]; then
            printf '%s\n' "$_apw_1"
            return 0
        fi
        printf '  Passwords do not match - try again (or press Enter to keep the random one).\n' >&2
    done
}

# =============================================================================
# The questions (split for testability: interactive_install_questions holds
# only the gates - terminal + the meta-question; interactive_collect_answers
# holds the actual questions and can be driven from a pipe in tests)
# =============================================================================

interactive_collect_answers() {
    # --- 1. HTTP proxy (a --proxy flag already given wins - never re-asked) ---
    if [ -z "$PROXY_SERVER" ]; then
        while :; do
            _ica_p="$(ask_value "HTTP proxy for this installation, host:port (leave empty for a direct connection)" "")"
            [ -z "$_ica_p" ] && break
            # same normalization/validation as resources/arguments.sh
            _ica_p=$(echo "$_ica_p" | sed 's|^https\?://||')
            if echo "$_ica_p" | grep -q ':'; then
                PROXY_SERVER="$_ica_p"
                verbose "  Proxy: $PROXY_SERVER"
                break
            fi
            printf '  Invalid proxy format: %s (expected host:port, e.g. 192.168.0.1:8080)\n' "$_ica_p" >&2
        done
    fi

    # --- 2. FusionPBX domain (only when config.sh still carries the sentinel;
    #       a custom value there is an intentional choice - never re-asked) ---
    if [ "$domain_name" = "ip_address" ] || [ "$domain_name" = "hostname" ]; then
        _ica_ip="$(ip -4 addr show scope global 2>/dev/null | grep inet | head -1 | awk '{print $2}' | cut -d'/' -f1)"
        _ica_d="$(ask_value "FusionPBX domain (web UI / SIP realm / provisioning name)" "${_ica_ip:-ip_address}")"
        # only a DIFFERENT answer overrides - the default (this node's IP)
        # stays as the 'ip_address' sentinel so finish.sh keeps its own
        # fallback chain; answering 'hostname' keeps that sentinel too
        if [ -n "$_ica_d" ] && [ "$_ica_d" != "$_ica_ip" ]; then
            domain_name="$_ica_d"
            # export: the step scripts run as child processes and re-source
            # config.sh - the environment is the only carrier
            export domain_name
        fi
        verbose "  NOTE (HA cluster): answer the SAME domain on every node."
        verbose "  Node 2's local database is replaced by the clone from node 1 at"
        verbose "  join, so only node 1's answer survives - a real domain name here"
        verbose "  (one DNS name for the whole cluster) is the operationally right way."
    fi

    # --- 3. Admin password (a custom system_password in config.sh wins) ---
    if [ "$system_password" = "random" ]; then
        _ica_pw="$(ask_password)"
        if [ -n "$_ica_pw" ]; then
            system_password="$_ica_pw"
            export system_password   # same carrier rule as domain_name
            verbose "  Admin password: set interactively (user: $system_username)"
        else
            verbose "  Admin password: a random one will be generated and shown at the end"
        fi
        unset _ica_pw
    fi
}

interactive_install_questions() {
    # no terminal on stdin: piped / 'curl | sh' / ssh without -t / CI -
    # never block, take the defaults
    if ! [ -t 0 ]; then
        verbose "No interactive terminal on stdin - installing with the defaults"
        return 0
    fi

    verbose ""
    verbose "=== Interactive setup (Enter accepts each [default]) ==="

    # the meta-question: ask questions at all?
    if ! ask_yesno "Configure the installation interactively?" "y"; then
        verbose "Skipping the questions - everything gets its default value."
        verbose "(proxy: none, domain: this node's IP, admin password: random)"
        return 0
    fi

    interactive_collect_answers

    # summary + go/no-go
    verbose ""
    verbose "Setup summary:"
    if [ "$domain_name" = "ip_address" ]; then
        verbose "  Domain:        this node's IP address (the default)"
    else
        verbose "  Domain:        $domain_name"
    fi
    if [ "$system_password" = "random" ]; then
        verbose "  Admin user:    $system_username (password: random, shown at the end)"
    else
        verbose "  Admin user:    $system_username (password: set interactively)"
    fi
    verbose "  Proxy:         ${PROXY_SERVER:-none (direct connection)}"
    verbose "  ionCube:       $install_ioncube (enable with --with-ioncube)"
    verbose ""
    if ! ask_yesno "Proceed with the installation?" "y"; then
        error "Installation cancelled by the operator. Nothing has been changed."
        exit 1
    fi
}
