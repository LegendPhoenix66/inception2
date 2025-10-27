FROM alpine:3.19

# Install MariaDB and required packages
RUN apk update && apk add --no-cache \
    mariadb \
    mariadb-client \
    mariadb-server-utils \
    && rm -rf /var/cache/apk/*

# Create necessary directories
RUN mkdir -p /var/lib/mysql \
    && mkdir -p /run/mysqld \
    && chown -R mysql:mysql /var/lib/mysql \
    && chown -R mysql:mysql /run/mysqld

# Copy configuration files
COPY conf/my.cnf /etc/my.cnf.d/mariadb-server.cnf
COPY tools/init_db.sh /usr/local/bin/init_db.sh

# Make script executable
RUN chmod +x /usr/local/bin/init_db.sh

# Expose MySQL port
EXPOSE 3306

# Run initialization script
ENTRYPOINT ["/usr/local/bin/init_db.sh"]