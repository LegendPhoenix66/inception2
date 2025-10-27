FROM alpine:3.19

# Install NGINX and OpenSSL
RUN apk update && apk add --no-cache \
    nginx \
    openssl \
    && rm -rf /var/cache/apk/*

# Create necessary directories
RUN mkdir -p /var/www/html \
    && mkdir -p /etc/nginx/ssl \
    && mkdir -p /var/log/nginx \
    && mkdir -p /run/nginx

# Copy NGINX configuration
COPY conf/nginx.conf /etc/nginx/nginx.conf
COPY conf/default.conf /etc/nginx/http.d/default.conf

# Copy SSL certificate generation script
COPY tools/generate_ssl.sh /usr/local/bin/generate_ssl.sh
RUN chmod +x /usr/local/bin/generate_ssl.sh

# Copy startup script
COPY tools/start_nginx.sh /usr/local/bin/start_nginx.sh
RUN chmod +x /usr/local/bin/start_nginx.sh

# SSL certificates will be generated at container start

# Set proper permissions
RUN chown -R nginx:nginx /var/www/html \
    && chown -R nginx:nginx /var/log/nginx \
    && chown -R nginx:nginx /etc/nginx/ssl

# Expose HTTPS port only
EXPOSE 443

# Start NGINX
ENTRYPOINT ["/usr/local/bin/start_nginx.sh"]