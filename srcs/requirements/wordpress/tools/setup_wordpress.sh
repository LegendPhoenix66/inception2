#!/bin/sh
set -e

# Create necessary directories
mkdir -p /var/lib/php81/sessions
mkdir -p /var/log
chown -R www-data:www-data /var/lib/php81/sessions

# Read database password early from secret so it's available for later patches and wp-cli
if [ -f /run/secrets/db_password ]; then
    DB_PASSWORD=$(cat /run/secrets/db_password)
    export DB_PASSWORD
else
    echo "Missing /run/secrets/db_password"; exit 1
fi

# Wait for MariaDB to be ready
echo "Waiting for MariaDB to be ready..."
while ! nc -z mariadb 3306; do
    sleep 1
done
echo "MariaDB is ready!"

# Load WordPress credential secrets
CRED_FILE="/run/secrets/credentials"
if [ -f "$CRED_FILE" ]; then
    . "$CRED_FILE"
else
    echo "Credentials secret file not found at $CRED_FILE"
    exit 1
fi

# Validate required variables
for var in WP_ADMIN_USER WP_ADMIN_PASSWORD WP_ADMIN_EMAIL WP_USER WP_USER_PASSWORD WP_USER_EMAIL; do
    eval val=\${$var}
    if [ -z "$val" ]; then
        echo "Missing required variable $var in credentials secret"
        exit 1
    fi
done

# Ensure admin username does not contain 'admin' or 'administrator'
LOWER_ADMIN=$(echo "$WP_ADMIN_USER" | tr '[:upper:]' '[:lower:]')
if echo "$LOWER_ADMIN" | grep -qE 'admin|administrator'; then
    echo "WP_ADMIN_USER must not contain 'admin' or 'administrator' per subject requirements."
    exit 1
fi

# Download WordPress if not already present
if [ ! -f "/var/www/html/wp-config.php" ]; then
    echo "Downloading WordPress..."
    cd /var/www/html
    wget https://wordpress.org/latest.tar.gz
    tar -xzf latest.tar.gz --strip-components=1
    rm latest.tar.gz

    # Download WP-CLI (stable build)
    wget -O wp-cli.phar https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
    chmod +x wp-cli.phar
    mv wp-cli.phar /usr/local/bin/wp

    # Create wp-config.php using the DB_PASSWORD read from secret earlier
    wp config create \
        --dbname="$WORDPRESS_DB_NAME" \
        --dbuser="$WORDPRESS_DB_USER" \
        --dbpass="$DB_PASSWORD" \
        --dbhost="$WORDPRESS_DB_HOST" \
        --allow-root

    # Wait a bit more for database to be fully ready
    sleep 5

    # Install WordPress
    wp core install \
        --url="https://${DOMAIN_NAME}" \
        --title="Inception WordPress" \
        --admin_user="$WP_ADMIN_USER" \
        --admin_password="$WP_ADMIN_PASSWORD" \
        --admin_email="$WP_ADMIN_EMAIL" \
        --allow-root

    # Create additional user
    wp user create \
        "$WP_USER" \
        "$WP_USER_EMAIL" \
        --user_pass="$WP_USER_PASSWORD" \
        --role=author \
        --allow-root

    echo "WordPress installation completed!"
fi

# If wp-config.php was inherited from another image/setup and reads Docker secrets at runtime,
# replace that with the actual DB password value (our PHP-FPM runs as www-data and cannot read /run/secrets).
if grep -q "/run/secrets/db_password" /var/www/html/wp-config.php 2>/dev/null; then
    echo "Patching wp-config.php to embed DB password instead of reading Docker secrets at runtime..."
    sed -i "s|file_get_contents('/run/secrets/db_password')|'$DB_PASSWORD'|g" /var/www/html/wp-config.php || true
    sed -i 's|file_get_contents("/run/secrets/db_password")|"'$DB_PASSWORD'"|g' /var/www/html/wp-config.php || true
fi

# Set proper permissions
chown -R www-data:www-data /var/www/html || true
chmod -R 755 /var/www/html || true

echo "Starting PHP-FPM..."
exec php-fpm81 -F