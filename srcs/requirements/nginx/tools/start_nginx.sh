#!/bin/sh
set -e

# Ensure DOMAIN_NAME is set
DOMAIN="${DOMAIN_NAME:-localhost}"

# Generate SSL certificates (if needed)
/usr/local/bin/generate_ssl.sh

# Inject domain name into NGINX server_name
if [ -f /etc/nginx/http.d/default.conf ]; then
    sed -i "s/server_name .*/server_name ${DOMAIN} localhost 127.0.0.1;/" /etc/nginx/http.d/default.conf
fi

# Test NGINX configuration
echo "Testing NGINX configuration..."
nginx -t

echo "NGINX configuration is valid"

# Start NGINX in foreground mode
echo "Starting NGINX for domain ${DOMAIN}..."
exec nginx -g "daemon off;"