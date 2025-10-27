#!/bin/sh
set -e

# Create log directory
mkdir -p /var/log/mysql
chown mysql:mysql /var/log/mysql

# Initialize database directory if it doesn't exist
FIRST_RUN=0
if [ ! -d "/var/lib/mysql/mysql" ]; then
    echo "Initializing MariaDB database directory..."
    mysql_install_db --user=mysql --datadir=/var/lib/mysql
    FIRST_RUN=1
fi

# Run initial SQL setup only on first-run
if [ $FIRST_RUN -eq 1 ] || [ ! -f "/var/lib/mysql/.initialized" ]; then
    # Start MariaDB in background for initial setup
    mysqld_safe --user=mysql --datadir=/var/lib/mysql &
    MYSQL_PID=$!

    # Wait for MariaDB to start
    echo "Waiting for MariaDB to start..."
    while ! mysqladmin ping --silent; do
        sleep 1
    done

    # Read passwords from secrets
    DB_ROOT_PASSWORD=$(cat /run/secrets/db_root_password)
    DB_PASSWORD=$(cat /run/secrets/db_password)

    # Set root password and create database/user
    mysql -u root << EOF
-- Set root password
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