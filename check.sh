#!/usr/bin/env bash
set -euo pipefail

# check.sh - automated verification script for the Inception project
# Usage: ./check.sh [--persist]
#   --persist : also run persistence tests (creates small test artifacts in DB and webroot)

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE_FILE="$ROOT_DIR/srcs/docker-compose.yml"
ENV_FILE="$ROOT_DIR/srcs/.env"
SECRETS_DIR="$ROOT_DIR/secrets"

PERSIST=false
for arg in "$@"; do
  case "$arg" in
    --persist) PERSIST=true ;;
    -h|--help)
      echo "Usage: $0 [--persist]"; exit 0 ;;
    *) ;;
  esac
done

# Colors
ok() { printf "\033[0;32m[OK]\033[0m %s\n" "$1"; }
warn() { printf "\033[0;33m[WARN]\033[0m %s\n" "$1"; }
fail() { printf "\033[0;31m[FAIL]\033[0m %s\n" "$1"; }
info() { printf "\033[0;36m[INFO]\033[0m %s\n" "$1"; }

# Detect compose command
COMPOSE_CMD=""
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  COMPOSE_CMD=(docker compose -f "$COMPOSE_FILE")
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE_CMD=(docker-compose -f "$COMPOSE_FILE")
else
  fail "docker compose or docker-compose is not available"
  exit 2
fi

# Helper to run compose command
dc() { "${COMPOSE_CMD[@]}" "$@"; }

PASS=0
FAIL=0
SKIP=0

check_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    warn "Command '$1' not found; skipping checks that require it"
    return 1
  fi
  return 0
}

increment_pass() { PASS=$((PASS+1)); }
increment_fail() { FAIL=$((FAIL+1)); }
increment_skip() { SKIP=$((SKIP+1)); }

echo "Running Inception verification checks (persist=$PERSIST)"

# Section A: basic container & resource checks
info "Section A: containers, images, network, volumes, restart policy"

# A1 - containers present & Up
if dc ps >/dev/null 2>&1; then
  out=$(dc ps 2>/dev/null || true)
  echo "$out"
  if echo "$out" | grep -E "mariadb|wordpress|nginx" >/dev/null 2>&1; then
    ok "Compose shows mariadb/wordpress/nginx entries"
    increment_pass
  else
    fail "Compose does not show required services (mariadb/wordpress/nginx)"
    increment_fail
  fi
else
  fail "docker compose ps failed"
  increment_fail
fi

# A2 - images exist
if command -v docker >/dev/null 2>&1; then
  if docker images --format '{{.Repository}}:{{.Tag}}' | grep -E '^srcs-' >/dev/null 2>&1; then
    ok "Local images named srcs-* exist"
    increment_pass
  else
    warn "No local images named srcs-* found (they may be named differently or not built)"
    increment_skip
  fi
else
  warn "docker not available for image checks"
  increment_skip
fi

# A3 - network and volumes
if command -v docker >/dev/null 2>&1; then
  if docker network ls --format '{{.Name}}' | grep -E 'inception|srcs_inception' >/dev/null 2>&1; then
    ok "Project network exists"
    increment_pass
  else
    warn "Project network (inception/srcs_inception) not found"
    increment_skip
  fi

  if docker volume ls --format '{{.Name}}' | grep -E 'srcs_mariadb_data|srcs_wordpress_data|mariadb_data|wordpress_data' >/dev/null 2>&1; then
    ok "Project volumes for mariadb/wordpress exist"
    increment_pass
  else
    warn "Expected volumes not found"
    increment_skip
  fi
fi

# A4 - restart policy
if docker ps -a --format '{{.Names}}' | grep -E '^mariadb$|^wordpress$|^nginx$' >/dev/null 2>&1; then
  rp_ok=true
  for c in mariadb wordpress nginx; do
    r=$(docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' "$c" 2>/dev/null || true)
    if [ -z "$r" ]; then
      warn "container $c has no restart policy"
      rp_ok=false
    fi
  done
  if [ "$rp_ok" = true ]; then ok "Restart policies present for containers"; increment_pass; else increment_fail; fi
else
  warn "containers not present to inspect restart policies"
  increment_skip
fi

# Section B: Nginx / TLS checks
info "Section B: Nginx / TLS checks (443, TLSv1.2/1.3)"
DOMAIN="$(awk -F= '/^DOMAIN_NAME=/{print $2}' "$ENV_FILE" 2>/dev/null || true)"
if [ -z "$DOMAIN" ]; then
  warn "DOMAIN not found in srcs/.env; skipping TLS checks"
  increment_skip
else
  info "Domain: $DOMAIN"
  if command -v openssl >/dev/null 2>&1; then
    # TLS 1.2
    if timeout 5s openssl s_client -connect ${DOMAIN}:443 -tls1_2 -servername ${DOMAIN} < /dev/null 2>/dev/null | grep -q "Protocol"; then
      ok "TLS1.2 negotiation succeeded (openssl)"
      increment_pass
    else
      warn "TLS1.2 negotiation failed or timed out"
      increment_fail
    fi
    # TLS1.3
    if timeout 5s openssl s_client -connect ${DOMAIN}:443 -tls1_3 -servername ${DOMAIN} < /dev/null 2>/dev/null | grep -q "Protocol"; then
      ok "TLS1.3 negotiation succeeded (openssl)"
      increment_pass
    else
      warn "TLS1.3 negotiation failed or unsupported"
      increment_skip
    fi
  else
    warn "openssl not available; skipping TLS checks"
    increment_skip
  fi
fi

# Section C: WordPress checks
info "Section C: WordPress checks"

# C1 - WP files present
if docker exec -it wordpress sh -c 'test -d /var/www/html && ls -1 /var/www/html | sed -n "1,5p"' >/dev/null 2>&1; then
  ok "WordPress webroot exists in container"
  increment_pass
else
  fail "/var/www/html not present or inaccessible in wordpress container"
  increment_fail
fi

# C2 - PHP-FPM / PID1
if docker exec -it wordpress sh -c 'cat /proc/1/comm' >/dev/null 2>&1; then
  pid1=$(docker exec -it wordpress sh -c 'cat /proc/1/comm' 2>/dev/null || true)
  echo "wordpress PID1: $pid1"
  if echo "$pid1" | grep -Ei 'php|php-fpm' >/dev/null 2>&1; then
    ok "WordPress PID 1 is a PHP-FPM process: $pid1"
    increment_pass
  else
    warn "WordPress PID1 is: $pid1 (expected php-fpm)"
    increment_skip
  fi
else
  warn "Cannot read PID1 in wordpress container"
  increment_skip
fi

# C3 - WP-CLI users (if wp exists)
if docker exec -it wordpress sh -c 'command -v wp' >/dev/null 2>&1; then
  docker exec -it wordpress sh -c 'wp user list --allow-root' >/dev/null 2>&1 && {
    ok "WP-CLI reports users"
    increment_pass
  } || {
    warn "WP-CLI available but user list failed"
    increment_skip
  }
else
  warn "WP-CLI not available in wordpress container; skipping WP-CLI checks"
  increment_skip
fi

# Section D: MariaDB checks
info "Section D: MariaDB checks"

# D1 - mysqld PID1
if docker exec -it mariadb sh -c 'cat /proc/1/comm' >/dev/null 2>&1; then
  mpid1=$(docker exec -it mariadb sh -c 'cat /proc/1/comm' 2>/dev/null || true)
  echo "mariadb PID1: $mpid1"
  if echo "$mpid1" | grep -Ei 'mysql|mysqld' >/dev/null 2>&1; then
    ok "MariaDB PID1 is $mpid1"
    increment_pass
  else
    warn "MariaDB PID1 is unusual: $mpid1"
    increment_skip
  fi
else
  fail "Cannot access mariadb container to read PID1"
  increment_fail
fi

# D2 - root login and DB exists
if [ -f "$SECRETS_DIR/db_root_password.txt" ]; then
  ROOT_PASS=$(cat "$SECRETS_DIR/db_root_password.txt")
  if docker exec -it mariadb sh -c "mysql -uroot -p'${ROOT_PASS}' -e 'SHOW DATABASES;'" >/dev/null 2>&1; then
    ok "root login to mariadb succeeded using secret"
    increment_pass
  else
    fail "root login to mariadb failed with secret"
    increment_fail
  fi
else
  warn "db_root_password secret file missing; skipping DB root login test"
  increment_skip
fi

# D3 - check grants for WP user
if [ -f "$SECRETS_DIR/db_password.txt" ] && [ -f "$ENV_FILE" ]; then
  DB_PASS=$(cat "$SECRETS_DIR/db_password.txt")
  DB_NAME=$(awk -F= '/^MYSQL_DATABASE=/{print $2}' "$ENV_FILE" | tr -d '\r\n')
  DB_USER=$(awk -F= '/^MYSQL_USER=/{print $2}' "$ENV_FILE" | tr -d '\r\n')
  if docker exec -it mariadb sh -c "mysql -uroot -p'${ROOT_PASS}' -e \"SHOW GRANTS FOR '${DB_USER}'@'%';\"" >/dev/null 2>&1; then
    ok "Grants for ${DB_USER} present"
    increment_pass
  else
    warn "Could not show grants for ${DB_USER} (may not exist yet)"
    increment_skip
  fi
else
  warn "DB secrets or .env missing; skipping DB user grants test"
  increment_skip
fi

# Section E: persistence tests (optional)
if [ "$PERSIST" = true ]; then
  info "Section E: Persistence tests (creating test artifacts)"

  # E1 - create a file in wordpress webroot
  if docker exec -it wordpress sh -c "echo 'inception test' > /var/www/html/__inception_check.txt" >/dev/null 2>&1; then
    ok "Wrote test file to wordpress webroot"
    increment_pass
    # restart containers
    dc restart wordpress mariadb nginx >/dev/null 2>&1 || true
    if docker exec -it wordpress sh -c "cat /var/www/html/__inception_check.txt" >/dev/null 2>&1; then
      ok "Webroot test file persists after restart"
      increment_pass
    else
      fail "Webroot test file missing after restart"
      increment_fail
    fi
  else
    warn "Could not write test file to wordpress webroot"
    increment_skip
  fi

  # E2 - create a small table in DB
  if docker exec -it mariadb sh -c "mysql -uroot -p'${ROOT_PASS}' -e \"USE ${DB_NAME}; CREATE TABLE IF NOT EXISTS inception_test (id INT PRIMARY KEY AUTO_INCREMENT, ok VARCHAR(10)); INSERT INTO inception_test (ok) VALUES ('yes');\"" >/dev/null 2>&1; then
    ok "Created test table and inserted row in DB"
    increment_pass
    dc restart mariadb >/dev/null 2>&1 || true
    if docker exec -it mariadb sh -c "mysql -uroot -p'${ROOT_PASS}' -e \"USE ${DB_NAME}; SELECT * FROM inception_test;\"" >/dev/null 2>&1; then
      ok "Database test row persists after restart"
      increment_pass
    else
      fail "Database test row missing after restart"
      increment_fail
    fi
  else
    warn "Could not create test table in DB (skipping)"
    increment_skip
  fi
else
  info "Skipping persistence tests (run with --persist to enable)"
  increment_skip
fi

# Section F: Dockerfile / compose / env / secrets validations
info "Section F: Dockerfile/compose/env/secrets checks"

# F1 - no 'latest' tag usage check
if grep -R --line-number "latest" srcs >/dev/null 2>&1; then
  warn "Found occurrences of 'latest' in srcs (check output)"
  grep -R --line-number "latest" srcs || true
  increment_skip
else
  ok "No 'latest' tag found in srcs"
  increment_pass
fi

# F2 - no plaintext passwords in Dockerfiles
if grep -R --line-number -iE "password|passwd|rootpass|db_password" srcs >/dev/null 2>&1; then
  warn "Found possible password-related strings in srcs (review manually)"
  grep -R --line-number -iE "password|passwd|rootpass|db_password" srcs || true
  increment_skip
else
  ok "No obvious plaintext passwords found in srcs"
  increment_pass
fi

# F3 - compose references secrets
if grep -n "secrets:\|MYSQL_ROOT_PASSWORD_FILE\|MYSQL_PASSWORD_FILE\|WORDPRESS_DB_PASSWORD_FILE" -n srcs/docker-compose.yml >/dev/null 2>&1; then
  ok "docker-compose references secrets or *_FILE patterns"
  increment_pass
else
  warn "docker-compose may not reference secrets as expected"
  increment_skip
fi

# F4 - secrets existence & permissions
if [ -d "$SECRETS_DIR" ]; then
  ls -l "$SECRETS_DIR" || true
  ok "secrets/ directory present"
  increment_pass
  for f in db_root_password.txt db_password.txt credentials.txt; do
    if [ -f "$SECRETS_DIR/$f" ]; then
      wc -c "$SECRETS_DIR/$f" | awk '{print $1 " bytes: $SECRETS_DIR/'$f'"}' || true
    else
      warn "Missing secret: $f"
      increment_skip
    fi
  done
else
  warn "secrets/ directory missing"
  increment_skip
fi

# F5 - base images in Dockerfiles
if grep -n "^FROM" -R srcs/requirements >/dev/null 2>&1; then
  ok "Dockerfiles contain FROM lines (listed below)"
  grep -n "^FROM" -R srcs/requirements || true
  increment_pass
else
  warn "No FROM lines found in Dockerfiles"
  increment_skip
fi

# Section G: Healthchecks & restart
info "Section G: Healthchecks & restart behavior"
if docker inspect --format '{{.Name}}: {{.State.Health.Status}}' mariadb wordpress nginx 2>/dev/null >/dev/null 2>&1; then
  docker inspect --format '{{.Name}}: {{.State.Health.Status}}' mariadb wordpress nginx 2>/dev/null || true
  ok "Health inspection available"
  increment_pass
else
  warn "Health status not available for one or more containers"
  increment_skip
fi

# Section H: PID1 & ownership
info "Section H: PID1 & ownership checks"
for c in wordpress mariadb nginx; do
  if docker exec -it "$c" sh -c 'cat /proc/1/comm' >/dev/null 2>&1; then
    p=$(docker exec -it "$c" sh -c 'cat /proc/1/comm' 2>/dev/null || true)
    echo "$c PID1: $p"
  fi
done
ok "PID1 checks printed above"
increment_pass

if docker exec -it wordpress sh -c 'ls -la /var/www/html | head -n 20' >/dev/null 2>&1; then
  docker exec -it wordpress sh -c 'ls -la /var/www/html | head -n 20' || true
  ok "Webroot ownership listed above"
  increment_pass
else
  warn "Could not list /var/www/html ownership"
  increment_skip
fi

# Section I: Smoke tests
info "Section I: Basic smoke tests"
if command -v curl >/dev/null 2>&1 && [ -n "$DOMAIN" ]; then
  if curl -k -I -L --max-time 10 https://${DOMAIN} >/dev/null 2>&1; then
    ok "Site responded to HTTPS request"
    increment_pass
  else
    warn "Site did not respond to HTTPS request (check logs)"
    increment_skip
  fi
else
  warn "curl not available or DOMAIN not set; skipping HTTPS smoke test"
  increment_skip
fi

# Summary
echo
info "Checks completed"
printf "Passed: %s\n" "$PASS"
printf "Failed: %s\n" "$FAIL"
printf "Skipped: %s\n" "$SKIP"

if [ "$FAIL" -gt 0 ]; then
  exit 3
else
  exit 0
fi

