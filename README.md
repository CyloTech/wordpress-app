# WordPress Appbox Image

This repository packages WordPress 7.1.2 for the Appbox platform while preserving the legacy WordPress app contract used by deployed app ID 87.

## Compatibility Contract

Existing instances must keep these values and paths unchanged during upgrades:

- App custom fields: `WP_URL`, `WP_TITLE`, `WP_ADMIN_USER`, `WP_ADMIN_PASSWORD`, `WP_ADMIN_EMAIL`
- WordPress root: `/home/appbox/public_html`
- MySQL data: `/home/appbox/mysql`
- App config: `/home/appbox/config`
- Logs: `/home/appbox/logs`
- Database name: `wordpress`
- Database user/password: `root` / `mysqlr00t`
- Table prefix: `wp_`
- Container listeners: `80` and `443`

The image treats an existing `/home/appbox/public_html/wp-config.php` as upgrade state. It preserves `wp-content`, salts, database credentials, and MySQL data, then runs `wp core update-db`. It only copies bundled core files when their version is at least as new as the installed core, so an Appbox image update cannot roll back a WordPress automatic update.

WordPress core automatic updates are enabled for new installs. During upgrade, the image enables them in an existing `wp-config.php` only when that site has no explicit `WP_AUTO_UPDATE_CORE` setting. An explicit site setting and other WordPress update controls remain in effect. Plugin and theme updates remain under each site's own settings.

## Runtime

The image is self-contained and builds from `ubuntu:26.04`, pinned by digest in the Dockerfile. It installs Nginx, PHP-FPM, MySQL, WordPress, WP-CLI, ionCube, and supporting packages during the Docker build.

Runtime supervision is handled by `/entrypoint.sh`, which starts MySQL, runs the WordPress install/upgrade routine, then starts PHP-FPM and Nginx. The image still preserves the legacy `/home/appbox` layout so existing Appbox mounts remain compatible.

## First Boot

On a fresh install:

1. WordPress 7.1.2 files are copied from `/opt/wordpress-7.1.2` into `/home/appbox/public_html`.
2. `wp-config.php` is generated from `sources/wp-config.php`.
3. Salts are generated once.
4. WP-CLI creates the administrator from the Appbox custom fields.
5. The script posts the Appbox installed callback unless `SKIP_APPBOX_CALLBACK=1`.

On upgrade:

1. Existing content and database are preserved; older core files are updated.
2. Nginx config is refreshed.
3. `wp core update-db` runs against the existing database.
4. The installed callback is posted.

Ordinary restarts do not regenerate salts.

## Password Recovery

The platform can reset the first WordPress administrator password with:

```bash
docker exec <container> /moduser.sh '<new-password>'
```

The script uses WP-CLI and requires the bundled MySQL service to be running.

## Build

Builds and pushes for release run on the dedicated Appbox builder from an archive of the exact pushed Git commit. Build for `linux/amd64`, run `./release-gate.sh repo.cylo.net/wordpress:7.1.2-1` against the built image, then push the new tag.

`PHP85_MIN_VERSION` in the Dockerfile is the oldest acceptable version of Ubuntu's php8.5 packages. Set it to the version from the Ubuntu security notice before a security release; the build fails while it is empty or apt cannot install that version, and the gate checks every php8.5 package in the image against it. `sources/mysqld.cnf` enables `mysql_native_password`, which MySQL 8.4 disables by default, so databases from older Appbox WordPress releases whose accounts still use it keep working.

A trial build of unreleased changes is tagged `local/wordpress-trial:<tag>`, is never pushed, and is gated with `./release-gate.sh local/wordpress-trial:7.1.2-1 repo.cylo.net/wordpress:7.1.2-1`, which runs every check and confirms the release tag is still absent from the registry. Record the registry digest and add it to `appbox.yml` before a separate catalogue import.

## Appbox Import

Import `appbox.yml` into existing app ID 87 only after builder tests pass and its immutable image digest is recorded. Catalogue import, selecting a default version, and updating existing instances are separate actions.

The manifest intentionally leaves `volumes` empty because existing production binds already carry the required host/private/home lock types. The current importer writes manifest volumes at app level and would otherwise rewrite those existing bind locks.
