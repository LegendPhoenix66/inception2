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

# Wait for PHP-FPM (WordPress) upstream to be ready to avoid 502 at startup
UPSTREAM_HOST="wordpress"
UPSTREAM_PORT=9000
printf "Waiting for upstream %s:%s to be ready" "$UPSTREAM_HOST" "$UPSTREAM_PORT"
ATTEMPTS=0
until nc -z -w 1 "$UPSTREAM_HOST" "$UPSTREAM_PORT" >/dev/null 2>&1; do
  ATTEMPTS=$((ATTEMPTS+1))
  if [ $ATTEMPTS -ge 120 ]; then
    echo "\nUpstream not ready after 120s, proceeding anyway."
    break
  fi
  printf "."
  sleep 1
done
echo ""

# Test NGINX configuration
echo "Testing NGINX configuration..."
nginx -t

echo "NGINX configuration is valid"

# Start NGINX in foreground mode
echo "Starting NGINX for domain ${DOMAIN}..."
exec nginx -g "daemon off;"