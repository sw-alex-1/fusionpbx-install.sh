
# FusionPBX Settings
domain_name=ip_address                      # hostname, ip_address or a custom value
system_username=admin                       # default username admin
system_password=random                      # random or a custom value
system_branch=5.5                           # master, 5.5

# FreeSWITCH Settings
switch_branch=stable                        # master, stable
switch_source=false                         # Always false — Alt Linux has RPM packages, no source build needed
switch_package=true                         # Always true — use RPM packages from Alt Linux repository
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
php_package_suffix=-fcgi                     # Alt Linux: -fcgi (NOT -fpm like Debian)
php_fpm_service=php${php_version}-fpm         # systemd service name
php_fpm_sock_dir=/var/run/php${php_version}-fpm  # socket directory
php_fpm_sock=unix:${php_fpm_sock_dir}/php${php_version}-fpm.sock  # full socket path
php_ini_path=/etc/php/${php_version}/fpm-fcgi/php.ini  # php.ini location
php_session_dir=/var/lib/php/${php_version}/sessions  # PHP sessions directory

# PostgreSQL Settings (Alt Linux specifics)
pg_package=postgresql${database_version}-server  # e.g. postgresql16-server
pg_init_script=/etc/rc.d/init.d/postgresql      # initdb via this script, NOT systemctl
pg_service=postgresql                            # systemd service name
pg_data_dir=/var/lib/pgsql/${database_version}/data  # default PGDATA
pg_conf_dir=/var/lib/pgsql/${database_version}/data  # pg_hba.conf, postgresql.conf live here

# General Settings
letsencrypt_folder=true                     # true or false

# Alt Linux Log Paths (for fail2ban and maintenance scripts)
auth_log=/var/log/auth/secure               # SSH/auth log (NOT /var/log/auth.log)
syslog_path=/var/log/syslog/messages         # Syslog (NOT /var/log/syslog)

# Alt Linux User/Group Settings
# These define the system users used by web and telephony services.
# Adjust if your Alt Linux installation uses different user names.
web_user=_nginx                             # nginx and php-fpm user
web_group=_nginx                            # nginx and php-fpm group
fs_user=_pbx                                # FreeSWITCH runtime user (Alt Linux default)
fs_group=_pbx                               # FreeSWITCH runtime group (Alt Linux default)

# Optional Applications
application_transcribe=true                # Speech to Text
application_speech=true                    # Text to Speech
application_language_model=true            # Language model
application_device_logs=true               # Log device provision requests
application_dialplan_tools=false           # Add additional dialplan applications
application_edit=false                     # Editor for XML, Provision, Scripts, and PHP
application_sip_trunks=false               # Registration-based SIP trunks
