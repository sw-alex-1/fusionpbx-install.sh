#!/bin/sh

# FusionPBX Alt Linux Installer - sngrep (SIP message capture tool)
# sngrep is available in Alt Linux repositories — simple package install.
# No source build needed (ARM source build path from Debian not applicable).

# Determine script directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Includes
. "$SCRIPT_DIR/config.sh"
. "$SCRIPT_DIR/colors.sh"
. "$SCRIPT_DIR/util.sh"
. "$SCRIPT_DIR/environment.sh"

verbose "Installing sngrep..."

pkg_install sngrep

verbose "  sngrep installed — use 'sngrep' to monitor SIP traffic"
