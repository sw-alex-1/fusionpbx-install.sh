#!/bin/sh

#upgrade the packages
apt-get update && apt-get -y dist-upgrade

#install packages
apt-get install -y git lsb-release

#get the install script
cd /usr/src && git clone https://github.com/sw-alex-1/fusionpbx-install.sh.git

#change the working directory
cd /usr/src/fusionpbx-install.sh/Alt
chmod +x ./install.sh
