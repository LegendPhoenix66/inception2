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
    # Build SQL safely in a shell string (escape backticks so the shell doesn't treat them as command substitution)
    SQL_CMD="ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASSWORD}';"
    SQL_CMD+="\nCREATE DATABASE IF NOT EXISTS \`\${MYSQL_DATABASE}\`;"
    SQL_CMD+="\nCREATE USER IF NOT EXISTS '${MYSQL_USER}'@'%' IDENTIFIED BY '${DB_PASSWORD}';"
    SQL_CMD+="\nGRANT ALL PRIVILEGES ON \`\${MYSQL_DATABASE}\`.* TO '${MYSQL_USER}'@'%';"
    SQL_CMD+="\nDELETE FROM mysql.user WHERE User='';"
    SQL_CMD+="\nDROP DATABASE IF EXISTS test;"
    SQL_CMD+="\nFLUSH PRIVILEGES;"

    # Expand environment variables into the SQL command and execute via -e
    # Note: we escape backticks above so the shell won't try to run them.
    eval "mysql --protocol=socket --socket=\"$SOCKET_PATH\" $ROOT_FLAGS -e \"$SQL_CMD\""

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

# --- Maintenance: ensure root password matches the secret even when DB was previously initialized ---
# If the DB was already initialized but root cannot authenticate using the secret, try a non-destructive fix:
if [ -f "/var/lib/mysql/.initialized" ] && [ ! -f "/var/lib/mysql/.root_fixed" ]; then
  SOCKET_PATH="/run/mysqld/mysqld.sock"
  log "Performing maintenance: enforcing root password from secret (temporary skip-grant-tables)..."

  # Start mysqld with skip-grant-tables so we can update user table
  mysqld --user=mysql \
         --datadir=/var/lib/mysql \
         --socket="$SOCKET_PATH" \
         --skip-networking \
         --skip-grant-tables &
  MGMT_PID=$!

  # Wait for socket file or mysqladmin ping (short timeout)
  ATTEMPTS=0
  until [ -S "$SOCKET_PATH" ] || mysqladmin --protocol=socket --socket="$SOCKET_PATH" ping --silent >/dev/null 2>&1; do
    ATTEMPTS=$((ATTEMPTS+1))
    if [ $ATTEMPTS -ge 60 ]; then
      log "Maintenance mysqld did not become ready in time"; break
    fi
    sleep 1
  done

  # Try to update root account directly in mysql.user (works under skip-grant-tables)
  if mysql --protocol=socket --socket="$SOCKET_PATH" -e "UPDATE mysql.user SET plugin='mysql_native_password' WHERE User='root' AND Host='localhost'; FLUSH PRIVILEGES;" >/dev/null 2>&1; then
    log "Set root plugin to mysql_native_password"
  fi

  # Try to set password in either authentication_string or Password columns
  mysql --protocol=socket --socket="$SOCKET_PATH" <<-SQL || true
    UPDATE mysql.user SET authentication_string=PASSWORD('${DB_ROOT_PASSWORD}') WHERE User='root' AND Host='localhost';
    UPDATE mysql.user SET Password=PASSWORD('${DB_ROOT_PASSWORD}') WHERE User='root' AND Host='localhost';
    FLUSH PRIVILEGES;
SQL

  # Stop the temporary server
  if mysqladmin --protocol=socket --socket="$SOCKET_PATH" shutdown >/dev/null 2>&1; then
    log "Temporary maintenance server shut down cleanly"
  else
    kill $MGMT_PID || true
    wait $MGMT_PID || true
  fi

  # mark maintenance done so we don't repeat it
  touch /var/lib/mysql/.root_fixed
  log "Maintenance: root password enforced (marker created)."
fi

# Exec mysqld in foreground as PID 1
log "Starting MariaDB server..."
exec mysqld --user=mysql --datadir=/var/lib/mysql --socket=/run/mysqld/mysqld.sock --pid-file=/run/mysqld/mysqld.pid
