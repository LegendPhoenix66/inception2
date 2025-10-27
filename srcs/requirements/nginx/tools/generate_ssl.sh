#!/bin/sh
set -e

DOMAIN="${DOMAIN_NAME:-localhost}"

# Create SSL directory if it doesn't exist
mkdir -p /etc/nginx/ssl

# Generate SSL certs only if missing
if [ ! -f /etc/nginx/ssl/nginx.key ] || [ ! -f /etc/nginx/ssl/nginx.crt ]; then
    echo "Generating SSL certificates for ${DOMAIN}..."
    # Generate private key
    openssl genrsa -out /etc/nginx/ssl/nginx.key 2048

    # Generate certificate signing request
    openssl req -new -key /etc/nginx/ssl/nginx.key -out /etc/nginx/ssl/nginx.csr -subj "/C=FR/ST=Paris/L=Paris/O=42School/OU=Inception/CN=${DOMAIN}"

    # Generate self-signed certificate
    openssl x509 -req -days 365 -in /etc/nginx/ssl/nginx.csr -signkey /etc/nginx/ssl/nginx.key -out /etc/nginx/ssl/nginx.crt

    # Set proper permissions
    chmod 600 /etc/nginx/ssl/nginx.key
    chmod 644 /etc/nginx/ssl/nginx.crt

    # Remove CSR file as it's no longer needed
    rm -f /etc/nginx/ssl/nginx.csr

    echo "SSL certificates generated successfully for ${DOMAIN}"
else
    echo "SSL certificates already exist, skipping generation"
fi