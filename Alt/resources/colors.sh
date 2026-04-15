#!/bin/sh

# FusionPBX Alt Linux Installer - Color Output
# Provides colored terminal output functions.
# Gracefully degrades to plain text when colors are not available.

# Output functions (depend on color variables set below)
verbose() {
    echo "${green}$1${normal}"
}

error() {
    echo "${red}$1${normal}" >&2
}

warning() {
    echo "${yellow}$1${normal}"
}

warn() {
    echo "${yellow}$1${normal}"
}

# Initialize color variables (empty by default = no color)
normal=""
red=""
green=""
yellow=""

# Detect color support only when output is to a terminal
if test -t 1; then
    # Check if terminal supports colors
    _ncolors=$(tput colors 2>/dev/null)
    if test -n "$_ncolors" && test "$_ncolors" -ge 8; then
        normal="$(tput sgr0)"
        red="$(tput setaf 1)"
        green="$(tput setaf 2)"
        yellow="$(tput setaf 3)"
    fi
fi
