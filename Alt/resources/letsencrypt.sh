#!/bin/sh

# FusionPBX Alt Linux Installer - Let's Encrypt SSL Certificates
# Uses dehydrated ACME client for certificate management.
#
# Alt Linux specifics:
#   - curl available in repos (same as Debian)
#   - nginx sites dir: /etc/nginx/sites-available.d/ (NOT sites-available)
#   - nginx SSL paths: /etc/nginx/ssl/ (same)
#   - FreeSWITCH TLS owner: _pbx:_pbx (NOT www-data:www-data)
#   - No certbot — dehydrated is used (same as Debian installer)
#
# This script is interactive — it prompts for domain name and email.

# Determine script directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Includes
. "$SCRIPT_DIR/config.sh"
. "$SCRIPT_DIR/colors.sh"
. "$SCRIPT_DIR/util.sh"
. "$SCRIPT_DIR/environment.sh"

# =============================================================================
# Install dependencies
# =============================================================================

verbose "Installing Let's Encrypt dependencies..."

pkg_install curl

# =============================================================================
# Remove old dehydrated installation (if any)
# =============================================================================

rm -f /usr/local/sbin/dehydrated
rm -rf /usr/src/dehydrated

# =============================================================================
# Get domain name and email
# =============================================================================

read -p 'Domain Name: ' domain_name
read -p 'Email Address: ' email_address

# =============================================================================
# Install dehydrated
# =============================================================================

verbose "Installing dehydrated ACME client..."

cd /usr/src && git clone https://github.com/dehydrated-io/dehydrated.git
cd /usr/src/dehydrated
cp dehydrated /usr/local/sbin
mkdir -p /var/www/dehydrated
mkdir -p /etc/dehydrated/certs

# =============================================================================
# Wildcard detection
# =============================================================================

wildcard_domain=$(echo "$domain_name" | cut -c1-1)
if [ "$wildcard_domain" = "*" ]; then
    wildcard_domain="true"
else
    wildcard_domain="false"
fi

# Remove the wildcard prefix (*.) from the domain name
if [ ."${wildcard_domain}" = ."true" ]; then
    domain_name=$(echo "$domain_name" | cut -c3-255)
fi

# =============================================================================
# DNS hook for wildcard certificates
# =============================================================================

if [ ."${wildcard_domain}" = ."true" ]; then
    cd /usr/src
    git clone https://github.com/gheja/dns-01-manual.git
    cd /usr/src/dns-01-manual/
    cp hook.sh /etc/dehydrated/hook.sh
    chmod 755 /etc/dehydrated/hook.sh
fi

# =============================================================================
# Configure dehydrated
# =============================================================================

cd /usr/src/dehydrated
cp docs/examples/config /etc/dehydrated

# Update the dehydrated config
sed -i 's/#CONTACT_EMAIL=/CONTACT_EMAIL="'"$email_address"'"/g' /etc/dehydrated/config
sed -i 's/#WELLKNOWN=/WELLKNOWN=/g' /etc/dehydrated/config

# Accept the Let's Encrypt terms of service
./dehydrated --register --accept-terms --config /etc/dehydrated/config

# =============================================================================
# Domain alias and domains.txt
# =============================================================================

domain_alias=$(echo "$domain_name" | head -n1 | cut -d " " -f1)

if [ ."${wildcard_domain}" = ."true" ]; then
    echo "*.$domain_name > $domain_name" > /etc/dehydrated/domains.txt
else
    echo "$domain_name" > /etc/dehydrated/domains.txt
fi

# =============================================================================
# Request certificates
# =============================================================================

verbose "Requesting Let's Encrypt certificate for $domain_name..."

if [ ."${wildcard_domain}" = ."true" ]; then
    ./dehydrated --cron --domain "*.$domain_name" --preferred-chain "ISRG Root X1" --algo rsa \
        --alias "$domain_alias" --config /etc/dehydrated/config --out /etc/dehydrated/certs \
        --challenge dns-01 --hook /etc/dehydrated/hook.sh
else
    ./dehydrated --cron --alias "$domain_alias" --preferred-chain "ISRG Root X1" --algo rsa \
        --config /etc/dehydrated/config --out /etc/dehydrated/certs --challenge http-01
fi

# =============================================================================
# Update nginx configuration
# =============================================================================

verbose "Updating nginx SSL configuration..."

mkdir -p /etc/nginx/ssl

# Alt Linux: sites-available.d directory (not sites-available)
_nginx_site="/etc/nginx/sites-available.d/fusionpbx"

if [ -f "$_nginx_site" ]; then
    sed "s@ssl_certificate[ \t]*/etc/ssl/certs/nginx.crt;@ssl_certificate /etc/dehydrated/certs/$domain_alias/fullchain.pem;@g" -i "$_nginx_site"
    sed "s@ssl_certificate_key[ \t]*/etc/ssl/private/nginx.key;@ssl_certificate_key /etc/dehydrated/certs/$domain_alias/privkey.pem;@g" -i "$_nginx_site"
else
    warn "nginx site config not found at $_nginx_site — update SSL paths manually"
fi

# Test and reload nginx
/usr/sbin/nginx -t && /usr/sbin/nginx -s reload

# =============================================================================
# FreeSWITCH TLS setup
# =============================================================================

if [ ."${switch_tls}" = ."true" ]; then
    verbose "Configuring FreeSWITCH TLS certificates..."

    # Make sure the freeswitch directory exists and is empty
    mkdir -p /etc/freeswitch/tls
    rm -f /etc/freeswitch/tls/*

    # Combine the certs into all.pem
    cat /etc/dehydrated/certs/$domain_alias/fullchain.pem > /etc/freeswitch/tls/all.pem
    cat /etc/dehydrated/certs/$domain_alias/privkey.pem >> /etc/freeswitch/tls/all.pem

    # Copy the individual certificates
    cp /etc/dehydrated/certs/$domain_alias/cert.pem /etc/freeswitch/tls/
    cp /etc/dehydrated/certs/$domain_alias/chain.pem /etc/freeswitch/tls/
    cp /etc/dehydrated/certs/$domain_alias/fullchain.pem /etc/freeswitch/tls/
    cp /etc/dehydrated/certs/$domain_alias/privkey.pem /etc/freeswitch/tls/

    # Create symbolic links for FreeSWITCH compatibility
    ln -s /etc/freeswitch/tls/all.pem /etc/freeswitch/tls/agent.pem
    ln -s /etc/freeswitch/tls/all.pem /etc/freeswitch/tls/tls.pem
    ln -s /etc/freeswitch/tls/all.pem /etc/freeswitch/tls/wss.pem
    ln -s /etc/freeswitch/tls/all.pem /etc/freeswitch/tls/dtls-srtp.pem

    # Set the permissions — Alt Linux uses _pbx:_pbx for FreeSWITCH
    chown -R ${fs_user}:${fs_group} /etc/freeswitch/tls

    verbose "  FreeSWITCH TLS configured with Let's Encrypt certificate"
fi

verbose "Let's Encrypt setup complete!"
