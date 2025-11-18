#!/bin/sh
set -e

log() {
  echo "[init_db] $1"
}

# Validate secrets early to fail fast with a clear message
if [ ! -f /run/secrets/db_root_password ]; then
  log "Missing secret: /run/secrets/db_root_password"; exit 1
fi
if [ ! -f /run/secrets/db_password ]; then
  log "Missing secret: /run/secrets/db_password"; exit 1
fi

DB_ROOT_PASSWORD=$(cat /run/secrets/db_root_password)
DB_PASSWORD=$(cat /run/secrets/db_password)

# Ensure sensible defaults for database/user to avoid empty identifiers in SQL
# (These can be overridden via environment variables passed by docker-compose)
: ${MYSQL_DATABASE:="wordpress"}
: ${MYSQL_USER:="wpuser"}

log "Using MYSQL_DATABASE=${MYSQL_DATABASE} MYSQL_USER=${MYSQL_USER}"

# Create required directories and set permissions
mkdir -p /var/log/mysql
mkdir -p /run/mysqld
chown -R mysql:mysql /var/log/mysql /run/mysqld /var/lib/mysql || true
chmod 0750 /var/lib/mysql || true

# Initialize database directory if it doesn't exist
FIRST_RUN=0
if [ ! -d "/var/lib/mysql/mysql" ]; then
    log "Initializing MariaDB data directory..."
    if command -v mariadb-install-db >/dev/null 2>&1; then
      mariadb-install-db --user=mysql --datadir=/var/lib/mysql --auth-root-authentication-method=normal
    else
      # Fallback for environments where mysql_install_db is present
      mysql_install_db --user=mysql --datadir=/var/lib/mysql || true
    fi
    FIRST_RUN=1
fi

# Bootstrap only if never initialized
if [ $FIRST_RUN -eq 1 ] || [ ! -f "/var/lib/mysql/.initialized" ]; then
    SOCKET_PATH="/run/mysqld/mysqld.sock"
    PID_FILE="/run/mysqld/mysqld.pid"

    log "Starting MariaDB temporarily for bootstrap..."
    mysqld --user=mysql \
           --datadir=/var/lib/mysql \
           --socket="$SOCKET_PATH" \
           --pid-file="$PID_FILE" \
           --skip-networking=0 &
    MYSQL_PID=$!

    # Wait for server to accept connections on socket
    log "Waiting for MariaDB to become ready..."
    ATTEMPTS=0
    until mysqladmin --protocol=socket --socket="$SOCKET_PATH" ping --silent >/dev/null 2>&1; do
      ATTEMPTS=$((ATTEMPTS+1))
      if [ $ATTEMPTS -ge 120 ]; then
        log "MariaDB did not become ready in time"; exit 1
      fi
      sleep 1
    done

    # Determine a working root authentication method (no password first, then secret)
    ROOT_FLAGS="-uroot"
    if mysql --protocol=socket --socket="$SOCKET_PATH" $ROOT_FLAGS -e "SELECT 1;" >/dev/null 2>&1; then
      :
    elif mysql --protocol=socket --socket="$SOCKET_PATH" -uroot -p"$DB_ROOT_PASSWORD" -e "SELECT 1;" >/dev/null 2>&1; then
      ROOT_FLAGS="-uroot -p$DB_ROOT_PASSWORD"
    else
      log "Unable to authenticate as root for bootstrap (tried no password and provided password)."
      exit 1
    fi

    # Apply configuration using determined root auth
    log "Applying initial database configuration..."
    mysql --protocol=socket --socket="$SOCKET_PATH" $ROOT_FLAGS <<-SQL
      -- set SQL mode safe quoting for identifiers
      ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASSWORD}';
      CREATE DATABASE IF NOT EXISTS \
        \\`\${MYSQL_DATABASE}\\`;
      CREATE USER IF NOT EXISTS '${MYSQL_USER}'@'%' IDENTIFIED BY '${DB_PASSWORD}';
      GRANT ALL PRIVILEGES ON \\`\${MYSQL_DATABASE}\\`.* TO '${MYSQL_USER}'@'%';
      DELETE FROM mysql.user WHERE User='';
      DROP DATABASE IF EXISTS test;
      FLUSH PRIVILEGES;
SQL

    # Shutdown bootstrap server cleanly (try with password, then without)
    if ! mysqladmin --protocol=socket --socket="$SOCKET_PATH" -uroot -p"$DB_ROOT_PASSWORD" shutdown >/dev/null 2>&1; then
      mysqladmin --protocol=socket --socket="$SOCKET_PATH" -uroot shutdown >/dev/null 2>&1 || true
    fi

    # Ensure the background process is gone
    if kill -0 $MYSQL_PID >/dev/null 2>&1; then
      kill $MYSQL_PID || true
      wait $MYSQL_PID || true
    fi

    touch /var/lib/mysql/.initialized
    log "MariaDB initialization completed."
fi

# Exec mysqld in foreground as PID 1
log "Starting MariaDB server..."
exec mysqld --user=mysql --datadir=/var/lib/mysql --socket=/run/mysqld/mysqld.sock --pid-file=/run/mysqld/mysqld.pid