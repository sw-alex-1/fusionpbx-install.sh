#!/bin/sh

# Monit shell script for starting FreeSWITCH on Alt Linux
# Called by monit to start the FreeSWITCH process.

mkdir -p /var/run/freeswitch
chown -R _pbx:_pbx /var/run/freeswitch
/usr/bin/freeswitch -nc -u _pbx -g _pbx -nonat
