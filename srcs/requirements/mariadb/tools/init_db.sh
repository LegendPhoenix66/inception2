#!/bin/sh
set -e

# Create required directories and set permissions
mkdir -p /var/log/mysql
mkdir -p /run/mysqld
chown -R mysql:mysql /var/log/mysql /run/mysqld /var/lib/mysql || true
chmod 0750 /var/lib/mysql || true

# Initialize database directory if it doesn't exist
FIRST_RUN=0
if [ ! -d "/var/lib/mysql/mysql" ]; then
    echo "Initializing MariaDB database directory..."
    mysql_install_db --user=mysql --datadir=/var/lib/mysql
    FIRST_RUN=1
fi

# Run initial SQL setup only on first-run
if [ $FIRST_RUN -eq 1 ] || [ ! -f "/var/lib/mysql/.initialized" ]; then
    # Read passwords from secrets early (for ping/auth)
    DB_ROOT_PASSWORD=$(cat /run/secrets/db_root_password)
    DB_PASSWORD=$(cat /run/secrets/db_password)

    # Start MariaDB in background for initial setup
    mysqld_safe --user=mysql --datadir=/var/lib/mysql &
    MYSQL_PID=$!

    # Wait for MariaDB to start (try both unauthenticated and with root secret)
    echo "Waiting for MariaDB to start..."
    while true; do
        if mysqladmin ping --silent >/dev/null 2>&1; then
            break
        fi
        if mysqladmin -p"$DB_ROOT_PASSWORD" ping --silent >/dev/null 2>&1; then
            break
        fi
        sleep 1
    done

    # Determine root auth method
    if mysql -uroot -p"$DB_ROOT_PASSWORD" -e "SELECT 1;" >/dev/null 2>&1; then
        ROOT_AUTH="-uroot -p$DB_ROOT_PASSWORD"
    else
        ROOT_AUTH="-uroot"
    fi

    # Set root password (idempotent) and create database/user
    mysql $ROOT_AUTH << EOF
-- Set root password (safe if already set)
ALTER USER 'root'@'localhost' IDENTIFIED BY '$DB_ROOT_PASSWORD';

-- Create database
CREATE DATABASE IF NOT EXISTS $MYSQL_DATABASE;

-- Create user and grant privileges
CREATE USER IF NOT EXISTS '$MYSQL_USER'@'%' IDENTIFIED BY '$DB_PASSWORD';
GRANT ALL PRIVILEGES ON $MYSQL_DATABASE.* TO '$MYSQL_USER'@'%';

-- Remove anonymous users and test database
DELETE FROM mysql.user WHERE User='';
DROP DATABASE IF EXISTS test;

-- Flush privileges
FLUSH PRIVILEGES;
EOF

    # Stop the background MariaDB process
    kill $MYSQL_PID
    wait $MYSQL_PID

    touch /var/lib/mysql/.initialized
    echo "MariaDB initialization completed."
fi

# Start MariaDB in foreground
exec mysqld --user=mysql --datadir=/var/lib/mysql