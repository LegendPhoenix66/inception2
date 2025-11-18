# Inception Verification Checklist

This document collects the verification steps (sections A–I) you can run on the VM to confirm the project meets the subject requirements. Each step contains the exact command(s) to run and what they check or the expected result.

Run these commands from the repository root (where `Makefile` and `srcs/` are located).

---

## Quick note
- Many commands use `docker compose -f srcs/docker-compose.yml` (Compose v2). If your environment uses legacy `docker-compose`, substitute accordingly.
- Secrets are stored in `secrets/` (created by `setup.sh`). Do not commit them.

---

## Section A — Basic container & resource checks

1) Show running containers and their health

```sh
docker compose -f srcs/docker-compose.yml ps
```
What it checks: that `mariadb`, `wordpress`, and `nginx` containers exist and are `Up`. Look for `(healthy)` on services that have healthchecks.

Expected: rows for `mariadb`, `wordpress`, `nginx` with `STATUS` `Up` and health `healthy` for mariadb and wordpress.


2) Show locally-built images produced by the repo

```sh
docker images | grep srcs-
```
What it checks: your images were built from local Dockerfiles and are named `srcs-*` (e.g., `srcs-mariadb`, `srcs-wordpress`, `srcs-nginx`).

Expected: image names starting with `srcs-` present.


3) Confirm the Docker network and volumes

```sh
docker network ls | grep -E 'inception|srcs_inception' || true
docker volume ls | grep -E 'mariadb|wordpress' || true
```
What it checks: the project-specific network (often `srcs_inception`) exists and volumes for mariadb and wordpress exist.

Expected: network line found and volumes such as `srcs_mariadb_data` and `srcs_wordpress_data` present.


4) Confirm restart policy is set

```sh
docker inspect --format '{{.Name}} restart={{.HostConfig.RestartPolicy.Name}}' mariadb wordpress nginx
```
What it checks: containers have a restart policy (e.g., `unless-stopped`).

Expected: `restart=unless-stopped` (or similar) for each container.

---

## Section B — Nginx / TLS checks (port 443 and TLSv1.2/1.3 only)

Get the configured domain from `.env`:

```sh
DOMAIN=$(awk -F= '/^DOMAIN_NAME=/{print $2}' srcs/.env | tr -d '\r\n')
echo "DOMAIN=$DOMAIN"
```

1) Confirm nginx maps only port 443

```sh
docker inspect --format '{{json .NetworkSettings.Ports}}' nginx
```
What it checks: host port mappings; there should be an entry for `443/tcp` mapped to the host and no `80` mapping.


2) Test TLS negotiation (TLSv1.2 and TLSv1.3)

```sh
# TLS 1.2
openssl s_client -connect ${DOMAIN}:443 -tls1_2 -servername ${DOMAIN} < /dev/null 2>/dev/null | sed -n '1,6p'
# TLS 1.3 (if supported by OpenSSL on the VM)
openssl s_client -connect ${DOMAIN}:443 -tls1_3 -servername ${DOMAIN} < /dev/null 2>/dev/null | sed -n '1,6p'
# Older TLS should fail (example: TLS 1.1)
openssl s_client -connect ${DOMAIN}:443 -tls1_1 -servername ${DOMAIN} < /dev/null 2>/dev/null | sed -n '1,6p' || echo "tls1.1 failed (expected)"
```
What it checks: TLS 1.2/1.3 succeed and older versions are rejected.


3) Inspect certificate details

```sh
printf '' | openssl s_client -connect ${DOMAIN}:443 -servername ${DOMAIN} 2>/dev/null | openssl x509 -noout -subject -issuer -dates
```
What it checks: certificate subject and validity dates; domain should appear in subject or SAN.


4) Quick HTTPS page test

```sh
curl -k -I -L https://${DOMAIN}
```
What it checks: site responds over HTTPS; `-k` allows self-signed certs.

Expected: HTTP headers and a 200/301/302 response (depending on setup).

---

## Section C — WordPress checks

1) WordPress files are present

```sh
docker exec -it wordpress sh -c 'ls -la /var/www/html | sed -n "1,120p"'
```
What it checks: WordPress core files and folders (`index.php`, `wp-config.php`, `wp-admin/`, `wp-content/`).


2) PHP-FPM running / PID1

```sh
docker exec -it wordpress sh -c 'ps aux | grep php-fpm | grep -v grep || true; cat /proc/1/comm'
```
What it checks: php-fpm process running and PID 1 is the php-fpm binary (not a shell loop).


3) WP-CLI and user verification

```sh
docker exec -it wordpress sh -c 'wp user list --allow-root || echo "wp-cli not available or WP not installed"'
```
What it checks: WP-CLI lists users. Expect two users: the administrator (from `secrets/credentials.txt`) and the secondary user. Verify admin username does NOT contain `admin` / `administrator`.


4) Inspect `wp-config.php` DB settings if WP-CLI isn't available

```sh
docker exec -it wordpress sh -c 'grep -n "DB_NAME\|DB_USER\|DB_PASSWORD\|DB_HOST" /var/www/html/wp-config.php || true'
```
What it checks: DB name/host/user present and DB password is embedded (not a runtime call to read `/run/secrets`).

---

## Section D — MariaDB checks

1) MariaDB is running and PID1 is mysqld

```sh
docker exec -it mariadb sh -c 'ps aux | grep mysqld | grep -v grep || true; cat /proc/1/comm'
```
What it checks: mysqld process exists and PID1 is the database daemon.


2) Test root login using secret

```sh
ROOT_PASS=$(cat secrets/db_root_password.txt)
docker exec -it mariadb sh -c "mysql -uroot -p'${ROOT_PASS}' -e 'SHOW DATABASES;'"
```
What it checks: root can authenticate with the secret and the `wordpress` DB exists.


3) Verify WP DB user & grants

```sh
DB_PASS=$(cat secrets/db_password.txt)
DB_NAME=$(awk -F= '/^MYSQL_DATABASE/ {print $2}' srcs/.env | tr -d '\r\n')
DB_USER=$(awk -F= '/^MYSQL_USER/ {print $2}' srcs/.env | tr -d '\r\n')

docker exec -it mariadb sh -c "mysql -uroot -p'${ROOT_PASS}' -e \"SHOW GRANTS FOR '${DB_USER}'@'%';\""
```
What it checks: the wordpress DB user has privileges on `${DB_NAME}`.*.

---

## Section E — Persistence tests (volumes)

1) Website files persistence

```sh
# create a small file inside the WordPress webroot
docker exec -it wordpress sh -c "echo 'inception test' > /var/www/html/__inception_check.txt && ls -l /var/www/html/__inception_check.txt"
# restart the relevant containers
docker compose -f srcs/docker-compose.yml restart wordpress mariadb nginx
# verify the file still exists
docker exec -it wordpress sh -c "cat /var/www/html/__inception_check.txt || echo 'file missing'"
```
What it checks: your `wordpress` bind-mounted volume persists website files across container restarts.


2) Database persistence

```sh
# create a simple test table and insert a row
docker exec -it mariadb sh -c "mysql -uroot -p'${ROOT_PASS}' -e \"USE ${DB_NAME}; CREATE TABLE IF NOT EXISTS inception_test (id INT PRIMARY KEY AUTO_INCREMENT, ok VARCHAR(10)); INSERT INTO inception_test (ok) VALUES ('yes'); SELECT * FROM inception_test;\""
# restart mariadb
docker compose -f srcs/docker-compose.yml restart mariadb
# verify the data persists
docker exec -it mariadb sh -c "mysql -uroot -p'${ROOT_PASS}' -e \"USE ${DB_NAME}; SELECT * FROM inception_test;\""
```
What it checks: database files are stored on the mariadb volume and survive restarts.

---

## Section F — Dockerfile / compose / env / secrets validations

1) No `latest` tag (check Dockerfiles/compose)

```sh
grep -R --line-number "latest" -n srcs || true
```
What it checks: `latest` tag is not used for service images. (Base images like `alpine:3.19` are allowed.)


2) No plaintext passwords in Dockerfiles

```sh
grep -R --line-number -i "password\|passwd\|rootpass\|db_password" srcs || true
```
What it checks: Dockerfiles do not contain passwords; secrets are used instead.


3) Compose references secrets

```sh
grep -n "secrets:\|MYSQL_ROOT_PASSWORD_FILE\|MYSQL_PASSWORD_FILE\|WORDPRESS_DB_PASSWORD_FILE" srcs/docker-compose.yml || true
```
What it checks: compose uses Docker secrets or *_FILE env patterns and does not bake passwords into the compose file.


4) Check secrets permissions on host

```sh
ls -l secrets
wc -c secrets/db_root_password.txt secrets/db_password.txt secrets/credentials.txt
```
What it checks: secrets files exist and have restrictive permissions (e.g., `-rw-------`) and are non-empty.


5) Check base images in Dockerfiles

```sh
grep -n "^FROM" -R srcs/requirements || true
```
What it checks: Dockerfiles use pinned base images (like `alpine:3.19`) and not prebuilt service images from DockerHub.

---

## Section G — Healthchecks & restart behavior

1) Check container health

```sh
docker inspect --format '{{.Name}}: {{.State.Health.Status}}' mariadb wordpress nginx 2>/dev/null || true
```
What it checks: containers with healthchecks should report `healthy`.


2) Verify no hacky infinite-loop entrypoints

```sh
grep -R --line-number "sleep infinity\|tail -f\|while true" -n srcs || true
```
What it checks: entrypoint scripts or Dockerfiles do not use infinite loops or `tail -f` hacks.

---

## Section H — PID1 & runtime model checks

1) Confirm PID1 is the service daemon

```sh
docker exec -it wordpress sh -c 'cat /proc/1/comm'
docker exec -it mariadb sh -c 'cat /proc/1/comm'
docker exec -it nginx sh -c 'cat /proc/1/comm'
```
What it checks: PID 1 inside each container should be the service process (e.g., `php-fpm81`, `mysqld`, `nginx`) — not a shell script.


2) Confirm web files ownership

```sh
docker exec -it wordpress sh -c 'ls -la /var/www/html | head -n 20'
```
What it checks: files are owned by the web user (e.g., `www-data`) to avoid permission issues.

---

## Section I — Final smoke tests

1) Show the site in a browser or curl

```sh
# If Makefile provides a URL target
make url || true
# or quick curl
curl -k -sS https://${DOMAIN} | head -n 20
```
What it checks: website responds; content or WordPress front page HTML appears.


2) Log in to WordPress with admin credentials

```sh
sed -n '1,120p' secrets/credentials.txt
# then navigate to https://${DOMAIN}/wp-admin and log in
```
What it checks: admin can log in and has the expected permissions. Admin username must NOT contain `admin` or `administrator`.


3) Confirm second user exists

```sh
docker exec -it wordpress sh -c 'wp user list --allow-root'
```
What it checks: the secondary user created by the setup script is present.

---

## If anything fails
- Paste the exact command output here and I will help debug the specific failure.
- For container startup failures, include: `docker compose -f srcs/docker-compose.yml logs --no-color --timestamps --tail=200 mariadb` and `docker compose -f srcs/docker-compose.yml ps`.

---

## Optional: automated check script
If you want, I can add a `scripts/check.sh` that runs the non-destructive checks and prints pass/fail for each item. Reply `yes` and I will add it to the repo.

---

End of checklist.

