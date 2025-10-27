#!/bin/sh
set -e

DOMAIN="${DOMAIN_NAME:-localhost}"

# Create SSL directory if it doesn't exist
mkdir -p /etc/nginx/ssl

# Generate SSL certs only if missing
if [ ! -f /etc/nginx/ssl/nginx.key ] || [ ! -f /etc/nginx/ssl/nginx.crt ]; then
    echo "Generating self-signed TLS certificate for ${DOMAIN} (with SANs)..."
    openssl req -x509 -nodes -newkey rsa:2048 \
        -subj "/C=FR/ST=Paris/L=Paris/O=42School/OU=Inception/CN=${DOMAIN}" \
        -addext "subjectAltName=DNS:${DOMAIN},DNS:localhost,IP:127.0.0.1" \
        -days 365 \
        -keyout /etc/nginx/ssl/nginx.key \
        -out /etc/nginx/ssl/nginx.crt

    chmod 600 /etc/nginx/ssl/nginx.key
    chmod 644 /etc/nginx/ssl/nginx.crt
    echo "Self-signed certificate created for ${DOMAIN}"
else
    echo "SSL certificates already exist, skipping generation"
fi