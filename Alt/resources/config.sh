
# FusionPBX Settings
domain_name=ip_address                      # hostname, ip_address or a custom value
system_username=admin                       # default username admin
system_password=random                      # random or a custom value
system_branch=5.5                           # master, 5.5

# FreeSWITCH Settings
switch_branch=stable                        # master, stable
switch_source=false                         # true (source compile) or false (binary package)
switch_package=true                         # true (binary package) or false (source compile)
switch_tls=true                             # true or false

# Database Settings
database_name=fusionpbx                     # Database name (safe characters A-Z, a-z, 0-9)
database_username=fusionpbx                 # Database username (safe characters A-Z, a-z, 0-9)
database_password=random                    # random or a custom value (safe characters A-Z, a-z, 0-9)
database_repo=system                        # system only (no external repos for Alt Linux)
                                            # postgresql16-server (PostgreSQL 16)
database_version=16                         # PostgreSQL major version (16 = PostgreSQL 16)
database_host=127.0.0.1                     # hostname or IP address
database_port=5432                          # port number
database_backup=false                       # true or false

# PHP Settings
php_version=8.2                             # PHP version: 8.1, 8.2, 8.3

# PostgreSQL Settings (Alt Linux specifics)
pg_package=postgresql${database_version}-server  # e.g. postgresql16-server
pg_init_script=/etc/rc.d/init.d/postgresql      # initdb via this script, NOT systemctl
pg_service=postgresql                            # systemd service name
pg_data_dir=/var/lib/pgsql/${database_version}/data  # default PGDATA
pg_conf_dir=/var/lib/pgsql/${database_version}/data  # pg_hba.conf, postgresql.conf live here

# General Settings
letsencrypt_folder=true                     # true or false

# Alt Linux User/Group Settings
# These define the system users used by web and telephony services.
# Adjust if your Alt Linux installation uses different user names.
web_user=_nginx                             # nginx and php-fpm user
web_group=_nginx                            # nginx and php-fpm group
fs_user=freeswitch                          # FreeSWITCH runtime user
fs_group=daemon                             # FreeSWITCH runtime group

# Optional Applications
application_transcribe=true                # Speech to Text
application_speech=true                    # Text to Speech
application_language_model=true            # Language model
application_device_logs=true               # Log device provision requests
application_dialplan_tools=false           # Add additional dialplan applications
application_edit=false                     # Editor for XML, Provision, Scripts, and PHP
application_sip_trunks=false               # Registration-based SIP trunks
