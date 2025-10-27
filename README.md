# Inception - Docker Infrastructure Project

## Overview

Inception is a Docker-based infrastructure project that sets up a complete web application stack using Docker Compose. The project creates a secure, containerized environment with NGINX, WordPress, and MariaDB services, following strict security and architectural requirements.

## Architecture

The infrastructure consists of three main services:

```
┌─────────────────┐
│     NGINX       │ ← HTTPS (Port 443 only)
│   (TLS 1.2/1.3) │
└─────────┬───────┘
          │
┌─────────▼───────┐
│   WordPress     │
│   + PHP-FPM     │
└─────────┬───────┘
          │
┌─────────▼───────┐
│    MariaDB      │
│   (Database)    │
└─────────────────┘
```

## Services

### 1. NGINX (Web Server)
- **Base Image**: Alpine 3.19
- **Purpose**: Reverse proxy and SSL termination
- **Features**:
  - TLS 1.2/1.3 only (no HTTP)
  - Self-signed SSL certificates
  - Security headers (HSTS, XSS protection, etc.)
  - FastCGI proxy to WordPress
  - Static file serving optimization

### 2. WordPress (Application)
- **Base Image**: Alpine 3.19
- **Purpose**: Content Management System
- **Features**:
  - PHP 8.1 with PHP-FPM
  - WordPress latest version
  - WP-CLI for automated setup
  - Two WordPress users created from secrets (admin and regular user)
  - Database connection via Docker secrets

### 3. MariaDB (Database)
- **Base Image**: Alpine 3.19
- **Purpose**: Database server
- **Features**:
  - MariaDB latest stable version
  - Automated database initialization
  - User and privilege management
  - Persistent data storage

## Directory Structure

```
inception/
├── Makefile                          # Build and management commands
├── README.md                         # This documentation
├── secrets/                          # Sensitive credentials
│   ├── credentials.txt
│   ├── db_password.txt
│   └── db_root_password.txt
└── srcs/                            # Source files
    ├── .env                         # Environment variables
    ├── docker-compose.yml           # Service orchestration
    └── requirements/                # Service configurations
        ├── mariadb/
        │   ├── Dockerfile
        │   ├── .dockerignore
        │   ├── conf/
        │   │   └── my.cnf
        │   └── tools/
        │       └── init_db.sh
        ├── nginx/
        │   ├── Dockerfile
        │   ├── .dockerignore
        │   ├── conf/
        │   │   ├── default.conf
        │   │   └── nginx.conf
        │   └── tools/
        │       ├── generate_ssl.sh
        │       └── start_nginx.sh
        └── wordpress/
            ├── Dockerfile
            ├── .dockerignore
            ├── conf/
            │   ├── php.ini
            │   └── www.conf
            └── tools/
                └── setup_wordpress.sh
```

## Configuration

### Environment Variables (.env)
- DOMAIN_NAME: login.42.fr (replace 'login' with your 42 login)
- MYSQL_DATABASE, MYSQL_USER: non-sensitive DB settings
- DATA_PATH: host path for bind-mounted volumes (e.g., /home/login/data)
Note: Do NOT put passwords or WP users here; use Docker secrets files under secrets/.

### Docker Secrets
- `db_root_password`: MariaDB root password
- `db_password`: WordPress database user password
- `credentials`: WordPress user credentials

### Volumes
- `mariadb_data`: Database persistent storage → `/home/lhopp/data/mariadb`
- `wordpress_data`: WordPress files → `/home/lhopp/data/wordpress`

## Usage

### Prerequisites
- Linux Virtual Machine (required by subject)
- Docker and Docker Compose installed
- Domain configuration: set your domain (login.42.fr) to 127.0.0.1 in /etc/hosts

### Quick Start

0. **Setup env and secrets (first time only):**
   ```bash
   cp srcs/.env.example srcs/.env
   # Edit srcs/.env to set DOMAIN_NAME and DATA_PATH
   # Create secrets with your own values (do NOT commit these files):
   printf "CHANGE_ME_ROOT_PWD" > secrets/db_root_password.txt
   printf "CHANGE_ME_DB_PWD" > secrets/db_password.txt
   cat > secrets/credentials.txt <<'EOF'
WP_ADMIN_USER=siteowner
WP_ADMIN_PASSWORD=change_me
WP_ADMIN_EMAIL=owner@example.com
WP_USER=authoruser
WP_USER_PASSWORD=change_me_too
WP_USER_EMAIL=author@example.com
EOF
   ```

1. **Build and start all services:**
   ```bash
   make
   # or
   make all
   ```

2. **Access the website:**
   - URL: https://${DOMAIN_NAME}
   - Admin and regular users: defined in secrets/credentials.txt

### Available Commands

```bash
# Build Docker images
make build

# Start services
make up

# Stop services
make down

# View logs
make logs

# Check service status
make status

# Restart services
make restart

# Clean up (remove containers and networks)
make clean

# Full cleanup (remove everything including data)
make fclean

# Rebuild from scratch
make re

# Execute command in container
make exec SERVICE=nginx
```

## Security Features

### SSL/TLS Configuration
- **Protocols**: TLS 1.2 and 1.3 only
- **Ciphers**: Strong cipher suites (ECDHE-RSA-AES)
- **Headers**: HSTS, XSS protection, content type options
- **Certificates**: Self-signed for lhopp.42.fr

### Container Security
- **No root processes**: Services run as dedicated users
- **Secrets management**: Sensitive data via Docker secrets
- **Network isolation**: Custom bridge network
- **File permissions**: Proper ownership and permissions

### WordPress Security
- **Database isolation**: Separate database user with limited privileges
- **File protection**: Restricted access to sensitive files
- **User management**: Two users with different roles
- **Environment variables**: No hardcoded credentials

## Technical Requirements Compliance

✅ **Virtual Machine**: Designed for VM deployment  
✅ **Docker Compose**: All services orchestrated via docker-compose.yml  
✅ **Custom Dockerfiles**: One per service, built from Alpine 3.19
✅ **No ready-made images**: All images built from scratch  
✅ **TLS only**: NGINX serves HTTPS on port 443 only  
✅ **Separate containers**: Each service in dedicated container  
✅ **Restart policy**: Containers restart on crash  
✅ **No infinite loops**: Proper PID 1 processes  
✅ **Environment variables**: No passwords in Dockerfiles  
✅ **Docker secrets**: Sensitive data management  
✅ **Custom network**: Bridge network for inter-service communication  
✅ **Persistent volumes**: Database and WordPress data persistence  
✅ **Two WordPress users**: Admin and regular user  

## Troubleshooting

### Common Issues

1. **Permission denied on data directories:**
   ```bash
   sudo mkdir -p /home/lhopp/data/{mariadb,wordpress}
   sudo chown -R $USER:$USER /home/lhopp/data
   ```

2. **Domain not resolving:**
   ```bash
   echo "127.0.0.1 lhopp.42.fr" | sudo tee -a /etc/hosts
   ```

3. **SSL certificate warnings:**
   - Expected behavior with self-signed certificates
   - Accept the security warning in browser

4. **Services not starting:**
   ```bash
   make logs  # Check service logs
   make status  # Check service status
   ```

### Log Locations
- NGINX: `/var/log/nginx/`
- PHP-FPM: `/var/log/fpm-php.www.log`
- MariaDB: `/var/log/mysql/`

## Development

### Modifying Services
1. Edit configuration files in respective `conf/` directories
2. Modify initialization scripts in `tools/` directories
3. Rebuild: `make re`

### Adding New Services
1. Create new directory in `srcs/requirements/`
2. Add Dockerfile and configurations
3. Update `docker-compose.yml`
4. Update Makefile if needed

## Project Structure Validation

The project follows the exact directory structure specified in the subject:
- ✅ Makefile at root
- ✅ secrets/ directory with credential files
- ✅ srcs/ directory with docker-compose.yml and .env
- ✅ requirements/ subdirectories for each service
- ✅ Dockerfiles and configuration files properly organized

## Author

This Inception project was created following the 42 School curriculum requirements for system administration and Docker containerization.

---

**Note**: This project is designed to run in a Linux Virtual Machine environment as specified in the subject requirements. Ensure proper VM setup before deployment.