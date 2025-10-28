FROM alpine:3.19

# Install PHP-FPM and required extensions
RUN apk update && apk add --no-cache \
    php81 \
    php81-fpm \
    php81-mysqli \
    php81-json \
    php81-curl \
    php81-dom \
    php81-exif \
    php81-fileinfo \
    php81-mbstring \
    php81-openssl \
    php81-xml \
    php81-zip \
    php81-redis \
    php81-phar \
    php81-tokenizer \
    php81-session \
    php81-ctype \
    php81-iconv \
    php81-gd \
    php81-intl \
    wget \
    unzip \
    netcat-openbsd \
    && rm -rf /var/cache/apk/*

# Create necessary directories and ensure www-data user/group exist (idempotent)
RUN mkdir -p /var/www/html \
    && mkdir -p /run/php \
    && (grep -q '^www-data:' /etc/group || addgroup -S www-data) \
    && (id -u www-data >/dev/null 2>&1 || adduser -D -S -h /var/www/html -s /sbin/nologin -G www-data www-data)

# Copy PHP-FPM configuration
COPY conf/www.conf /etc/php81/php-fpm.d/www.conf
COPY conf/php.ini /etc/php81/php.ini

# Copy WordPress setup script
COPY tools/setup_wordpress.sh /usr/local/bin/setup_wordpress.sh
RUN chmod +x /usr/local/bin/setup_wordpress.sh

# Set working directory
WORKDIR /var/www/html

# Change ownership
RUN chown -R www-data:www-data /var/www/html

# Expose PHP-FPM port
EXPOSE 9000

# Run setup script
ENTRYPOINT ["/usr/local/bin/setup_wordpress.sh"]