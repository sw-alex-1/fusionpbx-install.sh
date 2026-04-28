
# FusionPBX Settings
domain_name=ip_address                      # hostname, ip_address or a custom value
system_username=admin                       # default username admin
system_password=random                      # random or a custom value
system_branch=5.5                           # master, 5.5

# FreeSWITCH Settings
switch_branch=stable                        # master, stable
switch_source=false                         # false — main FreeSWITCH from RPM; mod_pgsql built from source separately
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
# Alt Linux: initdb creates data in /var/lib/pgsql/data/ (NO version number in path!)
# This differs from CentOS which uses /var/lib/pgsql/<ver>/data/
pg_data_dir=/var/lib/pgsql/data                  # default PGDATA (no version subdirectory)
pg_conf_dir=/var/lib/pgsql/data                  # pg_hba.conf, postgresql.conf live here

# General Settings
letsencrypt_folder=true                     # true or false

# Alt Linux Log Paths (for fail2ban and maintenance scripts)
auth_log=/var/log/auth/secure               # SSH/auth log (NOT /var/log/auth.log)
syslog_path=/var/log/syslog/messages         # Syslog (NOT /var/log/syslog)

# Alt Linux User/Group Settings
# These define the system users used by web and telephony services.
#
# CRITICAL: In the Debian installer, FreeSWITCH runs as www-data (same as the
# web server user) so that FusionPBX (PHP-FPM, also www-data) can read and
# write FreeSWITCH configuration files. We replicate this on Alt Linux by
# running FreeSWITCH as _nginx (same as the web server user). Using a separate
# _pbx user caused permission conflicts that made the system uncontrollable
# from the FusionPBX web interface.
web_user=_nginx                             # nginx, php-fpm, AND FreeSWITCH user
web_group=_nginx                            # nginx, php-fpm, AND FreeSWITCH group
fs_user=_nginx                              # FreeSWITCH runtime user (= web_user, like Debian's www-data)
fs_group=_nginx                             # FreeSWITCH runtime group (= web_group, like Debian's www-data)

# Alt Linux WebSocket Port
# Port 8080 is occupied by Alterator (Alt Linux system configuration tool).
# Use port 8088 for FusionPBX WebSocket to avoid conflict.
# This value is used in: config.conf, nginx fusionpbx.conf, v_default_settings
websocket_port=8088

# Optional Applications
application_transcribe=true                # Speech to Text
application_speech=true                    # Text to Speech
application_language_model=true            # Language model
application_device_logs=true               # Log device provision requests
application_dialplan_tools=false           # Add additional dialplan applications
application_edit=false                     # Editor for XML, Provision, Scripts, and PHP
application_sip_trunks=false               # Registration-based SIP trunks
