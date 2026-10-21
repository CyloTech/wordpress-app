# WordPress 7.1.2-1 Test Plan

All release builds and Docker compatibility tests must run on the dedicated Appbox builder. Run `./release-gate.sh repo.cylo.net/wordpress:7.1.2-1` after building and before pushing. Besides a fresh install, restart and the 7.0.2 upgrade, the gate checks the php8.5 package floor, that the `php` and `php-fpm8.5` module lists are identical to the deployed 7.1.2 image, the runtime php-fpm and nginx configuration tests, a multipart upload through the built-in server and through nginx and PHP-FPM, and an upgrade from the legacy `wordpress:latest` image (Ubuntu 24.04 / PHP 8.3, MySQL 8.0) with a root account on `mysql_native_password`. That fixture installs MySQL with apt on first start, so the gate needs network access. The Ubuntu 20.04 / PHP 7.4 `wordpress:latest` build that older sites still run is no longer in the registry, so the gate does not cover upgrades from it; canary those sites individually with backups.

## Fresh Install

Build the image:

```bash
docker build --platform linux/amd64 -t repo.cylo.net/wordpress:7.1.2-1 .
```

Run a fresh install with persistent directories:

```bash
docker rm -f wordpress-fresh >/dev/null 2>&1 || true
rm -rf /home/appbox/testdata/wordpress-fresh
mkdir -p /home/appbox/testdata/wordpress-fresh/{public_html,mysql_data,logs,config}

docker run -d --name wordpress-fresh \
  -e SKIP_APPBOX_CALLBACK=1 \
  -e WP_URL=wordpress-fresh.local \
  -e WP_TITLE='WordPress Fresh Test' \
  -e WP_ADMIN_USER=admin \
  -e WP_ADMIN_PASSWORD='ChangeMe!12345' \
  -e WP_ADMIN_EMAIL=admin@example.com \
  -p 18080:80 \
  -p 18443:443 \
  -v /home/appbox/testdata/wordpress-fresh/public_html:/home/appbox/public_html \
  -v /home/appbox/testdata/wordpress-fresh/mysql_data:/home/appbox/mysql \
  -v /home/appbox/testdata/wordpress-fresh/logs:/home/appbox/logs \
  -v /home/appbox/testdata/wordpress-fresh/config:/home/appbox/config \
  repo.cylo.net/wordpress:7.1.2-1
```

Verify:

```bash
docker exec wordpress-fresh wp --allow-root --path=/home/appbox/public_html core version
docker exec wordpress-fresh wp --allow-root --path=/home/appbox/public_html core is-installed
docker exec wordpress-fresh wp --allow-root --path=/home/appbox/public_html config is-true WP_AUTO_UPDATE_CORE
docker exec -u 1000 wordpress-fresh test -w /home/appbox/public_html/wp-includes/version.php
curl -fsS http://127.0.0.1:18080/appbox-health
curl -kfsS https://127.0.0.1:18443/appbox-health
docker exec wordpress-fresh php -m | grep -F ionCube
docker exec wordpress-fresh /moduser.sh 'ChangeMe!67890'
```

## Restart

Record salts, restart, and confirm salts did not change:

```bash
docker exec wordpress-fresh sh -c "grep \"AUTH_KEY\" /home/appbox/public_html/wp-config.php" > /tmp/wp-salt-before
docker restart wordpress-fresh
docker exec wordpress-fresh sh -c "grep \"AUTH_KEY\" /home/appbox/public_html/wp-config.php" > /tmp/wp-salt-after
diff -u /tmp/wp-salt-before /tmp/wp-salt-after
```

## Legacy Upgrade

Use a copy of a representative legacy `/public_html`, `/mysql_data`, `/logs`, and `/config` dataset. Never test against the live source directories.

```bash
docker rm -f wordpress-upgrade >/dev/null 2>&1 || true

docker run -d --name wordpress-upgrade \
  -e SKIP_APPBOX_CALLBACK=1 \
  -e WP_URL=wordpress-upgrade.local \
  -e WP_TITLE='WordPress Upgrade Test' \
  -e WP_ADMIN_USER=admin \
  -e WP_ADMIN_PASSWORD='ChangeMe!12345' \
  -e WP_ADMIN_EMAIL=admin@example.com \
  -p 28080:80 \
  -p 28443:443 \
  -v /home/appbox/testdata/wordpress-upgrade/public_html:/home/appbox/public_html \
  -v /home/appbox/testdata/wordpress-upgrade/mysql_data:/home/appbox/mysql \
  -v /home/appbox/testdata/wordpress-upgrade/logs:/home/appbox/logs \
  -v /home/appbox/testdata/wordpress-upgrade/config:/home/appbox/config \
  repo.cylo.net/wordpress:7.1.2-1
```

Verify:

```bash
docker exec wordpress-upgrade wp --allow-root --path=/home/appbox/public_html core version
docker exec wordpress-upgrade wp --allow-root --path=/home/appbox/public_html core update-db --dry-run
docker exec wordpress-upgrade wp --allow-root --path=/home/appbox/public_html config is-true WP_AUTO_UPDATE_CORE
docker exec wordpress-upgrade wp --allow-root --path=/home/appbox/public_html plugin list
docker exec wordpress-upgrade wp --allow-root --path=/home/appbox/public_html theme list
curl -fsS http://127.0.0.1:28080/appbox-health
```

## Rollback Backup Check

Before upgrading any production instance, take filesystem and database backups of:

- `/home/appbox/public_html`
- `/home/appbox/mysql`
- `/home/appbox/config`
- `/home/appbox/logs`

For compatibility testing, restore those backups into a clean test directory and confirm the old image can boot again. Do not rely on Docker image downgrade alone after WordPress has upgraded its database.

## Import Gate

Before importing into app ID 87:

1. Run the Cylo API importer with `--dry-run`.
2. Confirm no validation errors.
3. Confirm the pushed `repo.cylo.net/wordpress:7.1.2-1` manifest has a `linux/amd64` digest and add the immutable index digest to `appbox.yml`.
4. Agree the catalogue default separately from image publication, then import through the supported importer.
5. Re-query `app_versions`, `apps`, and `appinstance` to confirm only the authorised catalogue and instance changes occurred.
