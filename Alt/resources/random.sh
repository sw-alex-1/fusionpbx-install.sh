#!/bin/sh

# FusionPBX Alt Linux Installer - Random String Generation
# Generates a random alphanumeric string suitable for passwords and tokens.

random=$(dd if=/dev/urandom bs=1 count=20 2>/dev/null | base64 | sed 's/[=\+//]//g')
echo "$random"
