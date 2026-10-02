#!/bin/sh

# FusionPBX Alt Linux Installer - Optional Applications
# Installs optional FusionPBX applications from Git repositories.
# Safe for re-runs: skips already installed apps.
#
# Alt Linux specifics:
#   - Web user: angie:angie (NOT www-data:www-data)
#   - Applications are cloned into /var/www/fusionpbx/app/

# Determine script directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Includes
. "$SCRIPT_DIR/config.sh"
. "$SCRIPT_DIR/colors.sh"
. "$SCRIPT_DIR/util.sh"
. "$SCRIPT_DIR/environment.sh"

# =============================================================================
# Install optional applications
# Each application is only cloned if its config flag is set and
# it doesn't already exist in the app directory.
# =============================================================================

verbose "Installing optional FusionPBX applications..."

_app_dir="/var/www/fusionpbx/app"
cd "$_app_dir" || warn "FusionPBX app directory not found at $_app_dir"

# Helper: clone an app if enabled and not already present
# Usage: install_app <config_flag> <repo_url> <directory_name>
install_app() {
    _flag="$1"
    _repo="$2"
    _name="$3"

    if [ ."$_flag" = ."true" ]; then
        if [ -d "$_app_dir/$_name" ]; then
            verbose "  $_name: already installed (skipping)"
        else
            verbose "  Installing $_name..."
            git clone "$_repo" "$_name" 2>/dev/null || warn "Failed to clone $_name"
        fi
    fi
}

install_app "$application_transcribe" "https://github.com/fusionpbx/fusionpbx-app-transcribe.git" "transcribe"
install_app "$application_speech" "https://github.com/fusionpbx/fusionpbx-app-speech.git" "speech"
install_app "$application_language_model" "https://github.com/fusionpbx/fusionpbx-app-language_model.git" "language_model"
install_app "$application_device_logs" "https://github.com/fusionpbx/fusionpbx-app-device_logs.git" "device_logs"
install_app "$application_dialplan_tools" "https://github.com/fusionpbx/fusionpbx-app-dialplan_tools.git" "dialplan_tools"
install_app "$application_edit" "https://github.com/fusionpbx/fusionpbx-app-edit.git" "edit"
install_app "$application_sip_trunks" "https://github.com/fusionpbx/fusionpbx-app-sip_trunks.git" "sip_trunks"

# Set ownership for all application files
chown -R "$web_user:$web_group" /var/www/fusionpbx

verbose "Optional applications installation complete"
