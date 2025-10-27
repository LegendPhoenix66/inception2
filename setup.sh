#!/usr/bin/env bash
set -Eeuo pipefail

# Inception project setup script
# - Installs dependencies (Debian/Ubuntu)
# - Creates/updates srcs/.env
# - Generates secure secrets in secrets/
# - Prepares host data directories used by bind mounts
# After this script completes, you should be able to run: make up

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
REPO_ROOT="$SCRIPT_DIR"
SECRETS_DIR="$REPO_ROOT/secrets"
ENVDIR="$REPO_ROOT/srcs"
ENV_FILE="$ENVDIR/.env"

# Defaults (can be overridden via environment variables when invoking the script)
DEFAULT_DOMAIN_NAME=${DOMAIN_NAME:-localhost}
DEFAULT_DB_NAME=${MYSQL_DATABASE:-wordpress}
DEFAULT_DB_USER=${MYSQL_USER:-wpuser}

# Determine the non-root user to own created data
RUN_USER=${SUDO_USER:-${USER:-$(id -un)}}
# Resolve the home directory for RUN_USER
RUN_HOME=$(getent passwd "$RUN_USER" 2>/dev/null | awk -F: '{print $6}')
RUN_HOME=${RUN_HOME:-$HOME}

DEFAULT_DATA_PATH=${DATA_PATH:-"$RUN_HOME/data"}

# Colors for output
c_green='\033[0;32m'
c_yellow='\033[0;33m'
c_red='\033[0;31m'
c_reset='\033[0m'

info()  { echo -e "${c_green}[+]${c_reset} $*"; }
warn()  { echo -e "${c_yellow}[!]${c_reset} $*"; }
error() { echo -e "${c_red}[-]${c_reset} $*"; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

install_dependencies_debian() {
  info "Detected Debian/Ubuntu. Installing dependencies (requires sudo)..."
  sudo apt-get update -y
  # Basic utilities that may be used by this script and make/docker
  sudo apt-get install -y ca-certificates curl gnupg lsb-release make openssl

  # Set up Docker's official APT repository (idempotent)
  if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
    info "Adding Docker's official APT repository key"
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/$(. /etc/os-release; echo "$ID")/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg || true
    sudo chmod a+r /etc/apt/keyrings/docker.gpg || true
  fi
  if [ ! -f /etc/apt/sources.list.d/docker.list ]; then
    info "Configuring Docker APT repository"
    codename=$(. /etc/os-release; echo "$VERSION_CODENAME")
    arch=$(dpkg --print-architecture)
    echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$(. /etc/os-release; echo "$ID") ${codename} stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null || true
  fi

  sudo apt-get update -y || true
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || true

  # Fallback to distro Docker if official packages failed and docker is still missing
  if ! need_cmd docker; then
    warn "Falling back to distro Docker packages (docker.io)."
    sudo apt-get install -y docker.io || true
  fi

  # If Compose v2 still missing, try legacy docker-compose v1
  if ! docker compose version >/dev/null 2>&1; then
    warn "docker compose (v2) not available; attempting to install legacy docker-compose (v1) as a fallback."
    sudo apt-get install -y docker-compose || true
    if ! need_cmd docker-compose; then
      ver="1.29.2"
      uname_s=$(uname -s)
      uname_m=$(uname -m)
      url="https://github.com/docker/compose/releases/download/${ver}/docker-compose-${uname_s}-${uname_m}"
      warn "Downloading docker-compose v${ver} from ${url}"
      sudo curl -fsSL "$url" -o /usr/local/bin/docker-compose || true
      sudo chmod +x /usr/local/bin/docker-compose || true
    fi
  fi

  # Ensure docker service is running
  sudo systemctl enable --now docker || true

  # Add the current user to the docker group to run docker without sudo
  if getent group docker >/dev/null 2>&1; then
    if ! id -nG "$RUN_USER" | grep -qw docker; then
      info "Adding $RUN_USER to docker group"
      sudo usermod -aG docker "$RUN_USER" || true
      ADDED_TO_DOCKER_GROUP=1
    fi
  fi

  # Post-install check and info
  if docker compose version >/dev/null 2>&1; then
    info "docker compose (v2) is installed and available."
  elif need_cmd docker-compose; then
    info "docker-compose (v1) is installed. The Makefile will automatically use it as a fallback."
  else
    warn "Neither docker compose v2 nor docker-compose v1 is available. Please install Docker Compose manually."
  fi
}

install_dependencies() {
  if need_cmd apt-get; then
    install_dependencies_debian
  else
    warn "Unsupported distro detected for automated install. Please ensure Docker Engine, docker compose (v2), and make are installed. Skipping automatic dependency installation."
  fi
}

random_hex() {
  # Generate a secure random hex string of the requested byte length (default 16 => 32 hex chars)
  local bytes=${1:-16}
  openssl rand -hex "$bytes"
}

ensure_secrets() {
  mkdir -p "$SECRETS_DIR"

  # DB root password
  local root_pw_file="$SECRETS_DIR/db_root_password.txt"
  if [ -f "$root_pw_file" ]; then
    local existing
    existing=$(tr -d '\r\n' < "$root_pw_file" || true)
    if [ -z "$existing" ] || [ "$existing" = "rootpass123" ] || [ ${#existing} -lt 12 ]; then
      info "Updating weak/placeholder db_root_password.txt"
      random_hex 24 > "$root_pw_file"
    else
      info "Keeping existing db_root_password.txt"
    fi
  else
    info "Creating db_root_password.txt"
    random_hex 24 > "$root_pw_file"
  fi
  chmod 600 "$root_pw_file" || true

  # DB user password
  local db_pw_file="$SECRETS_DIR/db_password.txt"
  if [ -f "$db_pw_file" ]; then
    local existing
    existing=$(tr -d '\r\n' < "$db_pw_file" || true)
    if [ -z "$existing" ] || [ "$existing" = "wppass123" ] || [ ${#existing} -lt 12 ]; then
      info "Updating weak/placeholder db_password.txt"
      random_hex 24 > "$db_pw_file"
    else
      info "Keeping existing db_password.txt"
    fi
  else
    info "Creating db_password.txt"
    random_hex 24 > "$db_pw_file"
  fi
  chmod 600 "$db_pw_file" || true

  # WordPress credentials secret
  local cred_file="$SECRETS_DIR/credentials.txt"
  local admin_user="siteowner"
  local admin_pass
  local admin_email="admin@example.com"
  local user_name="writer"
  local user_pass
  local user_email="writer@example.com"

  admin_pass=$(random_hex 24)
  user_pass=$(random_hex 20)

  if [ -f "$cred_file" ]; then
    # Source existing values if the format is key=value
    # shellcheck disable=SC1090
    . "$cred_file" || true
    # Preserve non-empty, valid existing fields
    if [ -n "${WP_ADMIN_USER:-}" ]; then
      # Enforce subject rule: admin username must not contain 'admin' or 'administrator'
      local lower
      lower=$(echo "$WP_ADMIN_USER" | tr '[:upper:]' '[:lower:]')
      if echo "$lower" | grep -qE 'admin|administrator'; then
        warn "Existing WP_ADMIN_USER contains 'admin'. Replacing with a safe default."
      else
        admin_user="$WP_ADMIN_USER"
      fi
    fi
    if [ -n "${WP_ADMIN_PASSWORD:-}" ] && [ "${WP_ADMIN_PASSWORD}" != "admin123" ] && [ ${#WP_ADMIN_PASSWORD} -ge 12 ]; then
      admin_pass="$WP_ADMIN_PASSWORD"
    fi
    if [ -n "${WP_ADMIN_EMAIL:-}" ]; then
      admin_email="$WP_ADMIN_EMAIL"
    fi
    if [ -n "${WP_USER:-}" ]; then
      user_name="$WP_USER"
    fi
    if [ -n "${WP_USER_PASSWORD:-}" ] && [ "${WP_USER_PASSWORD}" != "user123" ] && [ ${#WP_USER_PASSWORD} -ge 8 ]; then
      user_pass="$WP_USER_PASSWORD"
    fi
    if [ -n "${WP_USER_EMAIL:-}" ]; then
      user_email="$WP_USER_EMAIL"
    fi
  fi

  cat > "$cred_file" <<EOF
WP_ADMIN_USER=$admin_user
WP_ADMIN_PASSWORD=$admin_pass
WP_ADMIN_EMAIL=$admin_email
WP_USER=$user_name
WP_USER_PASSWORD=$user_pass
WP_USER_EMAIL=$user_email
EOF
  chmod 600 "$cred_file" || true

  info "Secrets ready in $SECRETS_DIR"
}

ensure_env_file() {
  mkdir -p "$ENVDIR"

  local domain="$DEFAULT_DOMAIN_NAME"
  local dbname="$DEFAULT_DB_NAME"
  local dbuser="$DEFAULT_DB_USER"
  local datapath="$DEFAULT_DATA_PATH"

  if [ -f "$ENV_FILE" ]; then
    info "Updating srcs/.env (preserving existing non-placeholder values)"
    # Read existing values
    local cur_domain cur_dbname cur_dbuser cur_datapath
    cur_domain=$(awk -F= '/^DOMAIN_NAME=/{print $2}' "$ENV_FILE" | tail -n1 || true)
    cur_dbname=$(awk -F= '/^MYSQL_DATABASE=/{print $2}' "$ENV_FILE" | tail -n1 || true)
    cur_dbuser=$(awk -F= '/^MYSQL_USER=/{print $2}' "$ENV_FILE" | tail -n1 || true)
    cur_datapath=$(awk -F= '/^DATA_PATH=/{print $2}' "$ENV_FILE" | tail -n1 || true)

    if [ -n "$cur_domain" ]; then domain="$cur_domain"; fi
    if [ -n "$cur_dbname" ]; then dbname="$cur_dbname"; fi
    if [ -n "$cur_dbuser" ]; then dbuser="$cur_dbuser"; fi
    # If env contains placeholder /home/login/data, replace with actual path
    if [ -n "$cur_datapath" ]; then
      if echo "$cur_datapath" | grep -q "/home/login/data"; then
        warn "Replacing placeholder DATA_PATH with $datapath"
      else
        datapath="$cur_datapath"
      fi
    fi
  else
    info "Creating srcs/.env"
  fi

  cat > "$ENV_FILE" <<EOF
# Domain configuration
DOMAIN_NAME=$domain

# Database (non-sensitive)
MYSQL_DATABASE=$dbname
MYSQL_USER=$dbuser

# Host bind-mount base path for volumes (must exist on the VM)
DATA_PATH=$datapath
EOF
}

prepare_data_dirs() {
  local datapath
  datapath=$(awk -F= '/^DATA_PATH=/{print $2}' "$ENV_FILE" | tail -n1)
  if [ -z "$datapath" ]; then
    datapath="$DEFAULT_DATA_PATH"
  fi
  info "Ensuring data directories exist under $datapath"
  sudo mkdir -p "$datapath/wordpress" "$datapath/mariadb"
  sudo chown -R "$RUN_USER":"$RUN_USER" "$datapath" || true
}

ensure_hosts_mapping() {
  # Map DOMAIN_NAME to 127.0.0.1 inside the VM for in-VM browsing only.
  # This does not modify your host computer.
  local domain
  domain=$(awk -F= '/^DOMAIN_NAME=/{print $2}' "$ENV_FILE" | tail -n1 || true)
  if [ -z "$domain" ]; then
    domain="$DEFAULT_DOMAIN_NAME"
  fi

  # If localhost, mapping already exists implicitly
  if [ "$domain" = "localhost" ]; then
    info "DOMAIN_NAME is localhost; no /etc/hosts change needed."
    return
  fi

  # Already mapped?
  if grep -E "^\s*127\.0\.0\.1\s+.*\b$domain\b" /etc/hosts >/dev/null 2>&1; then
    info "/etc/hosts already maps $domain to 127.0.0.1"
    return
  fi

  info "Adding 127.0.0.1 mapping for $domain to /etc/hosts"
  echo "127.0.0.1 $domain" | sudo tee -a /etc/hosts >/dev/null
}

main() {
  info "Starting Inception setup"
  install_dependencies
  ensure_secrets
  ensure_env_file
  prepare_data_dirs
  ensure_hosts_mapping

  echo
  info "Setup completed. Next steps:"
  echo "  1) If this is your first Docker install and you were added to the docker group, log out and back in (or run: newgrp docker)."
  echo "  2) From the repo root, run: make up"
  echo
  info "Using configuration:"
  echo "  DOMAIN_NAME=$(awk -F= '/^DOMAIN_NAME=/{print $2}' "$ENV_FILE")"
  echo "  MYSQL_DATABASE=$(awk -F= '/^MYSQL_DATABASE=/{print $2}' "$ENV_FILE")"
  echo "  MYSQL_USER=$(awk -F= '/^MYSQL_USER=/{print $2}' "$ENV_FILE")"
  echo "  DATA_PATH=$(awk -F= '/^DATA_PATH=/{print $2}' "$ENV_FILE")"
}

main "$@"
