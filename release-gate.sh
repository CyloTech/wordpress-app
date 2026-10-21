#!/bin/bash
set -Eeuo pipefail

release_ref="repo.cylo.net/wordpress:7.1.2-1"
usage() {
    echo "Usage: release-gate.sh ${release_ref}" >&2
    echo "       release-gate.sh local/wordpress-trial:7.1.2-1 ${release_ref}   (trial build, never pushed)" >&2
    exit 2
}
case $# in
    1) [[ "$1" == "${release_ref}" ]] || usage; mode=release ;;
    2) [[ "$1" == local/wordpress-trial:* && "$1" =~ ^[A-Za-z0-9._/:-]+$ && "$2" == "${release_ref}" ]] || usage; mode=trial ;;
    *) usage ;;
esac

image_ref="$1"
gate_dir="$(cd "$(dirname "$0")" && pwd)"
baseline_ref="repo.cylo.net/wordpress@sha256:f40b3d3637e5457fdb5f2acce820da5106c230ee9280749bd6bac564031fe79d"
# The deployed 7.1.2 image that 7.1.2-1 replaces; the PHP module lists must match it.
deployed_ref="repo.cylo.net/wordpress@sha256:5331635e2be71a41ff2186a6f99fcc5dc560d344d324c1e68b5ac83280bd2928"
# The mutable wordpress:latest line (catalogue version latest-4) that the
# release moves onto 7.1.2-1: Ubuntu 20.04 / PHP 7.4 and Ubuntu 24.04 / PHP 8.3.
legacy_focal_ref="repo.cylo.net/wordpress@sha256:dcd14f5eb6ac90fed9d14b44856329af8eb3797c9f606c25a604b31c62bfa17b"
legacy_noble_ref="repo.cylo.net/wordpress@sha256:c3f4b3726aa0d6a26a4e85f52ab6e80d8bc2a96036216fbb3ae9a09fa57899c7"
wp_path="/home/appbox/public_html"
gate_root="$(mktemp -d /home/appbox/builds/wordpress-gate.XXXXXX)"

if [[ ! "${gate_root}" =~ ^/home/appbox/builds/wordpress-gate\.[A-Za-z0-9]{6}$ ]]; then
    echo "Unexpected release-gate directory" >&2
    exit 1
fi

gate_suffix="${gate_root##*.}"
fresh_container="wp-gate-fresh-${gate_suffix}"
legacy_container="wp-gate-legacy-${gate_suffix}"
upgrade_container="wp-gate-upgrade-${gate_suffix}"
focal_container="wp-gate-focal-${gate_suffix}"
focal_upgrade_container="wp-gate-focal-upgrade-${gate_suffix}"
noble_container="wp-gate-noble-${gate_suffix}"
noble_upgrade_container="wp-gate-noble-upgrade-${gate_suffix}"
test_password="$(openssl rand -base64 30)"

cleanup() {
    docker rm -f "${fresh_container}" "${legacy_container}" "${upgrade_container}" \
        "${focal_container}" "${focal_upgrade_container}" \
        "${noble_container}" "${noble_upgrade_container}" >/dev/null 2>&1 || true
    if [[ "${gate_root}" =~ ^/home/appbox/builds/wordpress-gate\.[A-Za-z0-9]{6}$ ]]; then
        docker run --rm --platform linux/amd64 --entrypoint sh \
            -v "${gate_root}:/gate" "${image_ref}" \
            -c 'find /gate -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +' >/dev/null 2>&1 || true
        rmdir -- "${gate_root}" || echo "Builder cleanup needed at ${gate_root}" >&2
    fi
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fail() {
    echo "Release gate failed: $*" >&2
    exit 1
}

wait_ready() {
    local container="$1"

    for _ in $(seq 1 180); do
        if docker exec "${container}" wp --allow-root --path="${wp_path}" core is-installed >/dev/null 2>&1 \
            && docker exec "${container}" curl -kfsS \
                -H 'Host: wordpress-gate.local' \
                https://127.0.0.1/wp-login.php -o /dev/null >/dev/null 2>&1; then
            return 0
        fi

        if [[ "$(docker inspect --format '{{.State.Running}}' "${container}" 2>/dev/null || true)" != "true" ]]; then
            fail "${container} stopped before WordPress was ready"
        fi
        sleep 2
    done

    fail "${container} did not become ready"
}

launch() {
    local container="$1" data_dir="$2" release_image="$3"

    mkdir -p "${data_dir}/public_html" "${data_dir}/mysql" "${data_dir}/logs" "${data_dir}/config"
    docker run -d --platform linux/amd64 --name "${container}" \
        -e SKIP_APPBOX_CALLBACK=1 \
        -e WP_URL=https://wordpress-gate.local \
        -e WP_TITLE='WordPress release gate' \
        -e WP_ADMIN_USER=wpgate \
        -e WP_ADMIN_PASSWORD="${test_password}" \
        -e WP_ADMIN_EMAIL=wpgate@example.invalid \
        -v "${data_dir}/public_html:${wp_path}" \
        -v "${data_dir}/mysql:/home/appbox/mysql" \
        -v "${data_dir}/logs:/home/appbox/logs" \
        -v "${data_dir}/config:/home/appbox/config" \
        "${release_image}" >/dev/null
    wait_ready "${container}"
}

check_core_updates() {
    local container="$1" expected_version="$2"

    [[ "$(docker exec "${container}" wp --allow-root --path="${wp_path}" core version)" == "${expected_version}" ]] \
        || fail "${container} has the wrong WordPress core version"
    docker exec "${container}" wp --allow-root --path="${wp_path}" \
        config is-true WP_AUTO_UPDATE_CORE >/dev/null \
        || fail "${container} does not enable core auto-updates"
    docker exec -u 1000 "${container}" test -w "${wp_path}/wp-includes/version.php" \
        || fail "${container} cannot write WordPress core as the app user"
    docker exec -u 1000 "${container}" test -w "${wp_path}/wp-content" \
        || fail "${container} cannot write WordPress update workspace as the app user"
    docker exec -u 1000 "${container}" wp --path="${wp_path}" --skip-plugins --skip-themes \
        eval 'require_once ABSPATH . "wp-admin/includes/class-wp-automatic-updater.php"; if ((new WP_Automatic_Updater())->is_disabled()) { exit(1); }' >/dev/null \
        || fail "${container} reports its automatic updater disabled"
}

check_fpm_upload() {
    local container="$1" result

    docker exec "${container}" sh -c 'cat > /home/appbox/public_html/appbox-gate-upload.php' <<'PHP'
<?php
echo count($_FILES), ':', $_FILES['f']['size'] ?? -1, ':', $_POST['a'] ?? '';
PHP
    result="$(docker exec "${container}" sh -c 'printf hello > /tmp/gate-upload.txt && curl -kfsS -H "Host: wordpress-gate.local" -F a=b -F f=@/tmp/gate-upload.txt https://127.0.0.1/appbox-gate-upload.php')" || true
    docker exec "${container}" rm -f /home/appbox/public_html/appbox-gate-upload.php /tmp/gate-upload.txt
    [[ "${result}" == "1:5:b" ]] \
        || fail "${container}: multipart upload through nginx and PHP-FPM returned '${result}', expected '1:5:b'"
}

# Install a site with a legacy wordpress:latest image, add content, switch
# its root account to mysql_native_password, then start the release image on
# the same volumes, as `apps update` does. The legacy images install MySQL 8.0
# with apt on first start, so this needs network access; api.cylo.io and
# api.cylo.net resolve to 127.0.0.1 so their install callback never reaches
# the API (it retries forever, which keeps their MySQL running for us).
legacy_upgrade() {
    local label="$1" legacy_ref="$2" legacy_c="$3" upgrade_c="$4"
    local data_dir="${gate_root}/${label}" post_id salt_hash upload_marker

    echo "-- ${label}: ${legacy_ref}"
    docker pull --platform linux/amd64 "${legacy_ref}" >/dev/null
    mkdir -p "${data_dir}/public_html" "${data_dir}/mysql" "${data_dir}/logs" "${data_dir}/config"
    docker run -d --platform linux/amd64 --name "${legacy_c}" \
        --add-host api.cylo.io:127.0.0.1 --add-host api.cylo.net:127.0.0.1 \
        -e INSTANCE_ID=0 \
        -e WP_URL=https://wordpress-gate.local \
        -e WP_TITLE='WordPress release gate' \
        -e WP_ADMIN_USER=wpgate \
        -e WP_ADMIN_PASSWORD="${test_password}" \
        -e WP_ADMIN_EMAIL=wpgate@example.invalid \
        -v "${data_dir}/public_html:${wp_path}" \
        -v "${data_dir}/mysql:/home/appbox/mysql" \
        -v "${data_dir}/logs:/home/appbox/logs" \
        -v "${data_dir}/config:/home/appbox/config" \
        "${legacy_ref}" >/dev/null
    for _ in $(seq 1 300); do
        if docker exec "${legacy_c}" sh -c "wp --allow-root --path='${wp_path}' core is-installed" >/dev/null 2>&1 \
            && docker exec "${legacy_c}" mysql -uroot -p"mysqlr00t" -NBe 'SELECT 1' >/dev/null 2>&1; then
            break
        fi
        [[ "$(docker inspect --format '{{.State.Running}}' "${legacy_c}" 2>/dev/null || true)" == "true" ]] \
            || { docker logs --tail 60 "${legacy_c}" >&2 || true; fail "${legacy_c} stopped before WordPress was installed"; }
        sleep 3
    done
    docker exec "${legacy_c}" sh -c "wp --allow-root --path='${wp_path}' core is-installed" >/dev/null 2>&1 \
        || { docker logs --tail 60 "${legacy_c}" >&2 || true; fail "${legacy_c} did not install WordPress"; }
    echo "${label}: legacy core $(docker exec "${legacy_c}" wp --allow-root --path="${wp_path}" core version), $(docker exec "${legacy_c}" php -r 'echo "PHP ", PHP_VERSION;'), $(docker exec "${legacy_c}" mysql -uroot -pmysqlr00t -NBe 'SELECT CONCAT("MySQL ", VERSION())' 2>/dev/null)"

    post_id="$(docker exec "${legacy_c}" wp --allow-root --path="${wp_path}" post create \
        --post_title='Release gate marker' --post_status=publish --porcelain)"
    upload_marker="$(openssl rand -hex 8)"
    docker exec "${legacy_c}" sh -c "mkdir -p '${wp_path}/wp-content/uploads' && printf '%s' '${upload_marker}' > '${wp_path}/wp-content/uploads/release-gate-marker'"
    salt_hash="$(docker exec "${legacy_c}" wp --allow-root --path="${wp_path}" config get AUTH_KEY | sha256sum | cut -d' ' -f1)"
    docker exec "${legacy_c}" mysql -uroot -pmysqlr00t -e \
        "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY 'mysqlr00t'; FLUSH PRIVILEGES;" \
        || fail "${label}: could not switch root to mysql_native_password"
    docker exec "${legacy_c}" mysqladmin -uroot -pmysqlr00t shutdown >/dev/null 2>&1 || true
    sleep 5
    docker rm -f "${legacy_c}" >/dev/null

    launch "${upgrade_c}" "${data_dir}" "${image_ref}"
    check_core_updates "${upgrade_c}" 7.1.2
    [[ "$(docker exec "${upgrade_c}" wp --allow-root --path="${wp_path}" post get "${post_id}" --field=post_title)" == "Release gate marker" ]] \
        || fail "${label}: site content was not preserved"
    [[ "$(cat "${data_dir}/public_html/wp-content/uploads/release-gate-marker")" == "${upload_marker}" ]] \
        || fail "${label}: uploads were not preserved"
    [[ "$(docker exec "${upgrade_c}" wp --allow-root --path="${wp_path}" config get AUTH_KEY | sha256sum | cut -d' ' -f1)" == "${salt_hash}" ]] \
        || fail "${label}: authentication salts changed"
    [[ "$(docker exec "${upgrade_c}" mysql --protocol=socket --socket=/run/mysqld/mysqld.sock -uroot -pmysqlr00t -NBe \
        "SELECT plugin FROM mysql.user WHERE user = 'root' AND host = 'localhost'" 2>/dev/null)" == "mysql_native_password" ]] \
        || fail "${label}: root no longer logs in with mysql_native_password"
    docker exec "${upgrade_c}" mysql --protocol=socket --socket=/run/mysqld/mysqld.sock -uroot -pmysqlr00t -NBe 'SELECT VERSION()' 2>/dev/null \
        | grep -q '^8\.4\.' || fail "${label}: MySQL was not upgraded to 8.4"
    check_fpm_upload "${upgrade_c}"
    docker restart "${upgrade_c}" >/dev/null
    wait_ready "${upgrade_c}"
    docker rm -f "${upgrade_c}" >/dev/null
    echo "${label}: upgraded to 7.1.2-1 with content, uploads, salts and the root login kept"
}

echo "== Mode: ${mode} (${image_ref}, release tag ${release_ref})"
[[ "$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "${image_ref}")" == "linux/amd64" ]] \
    || fail "built image is not linux/amd64"
[[ "$(docker run --rm --entrypoint php "${image_ref}" -r \
    'include "/opt/wordpress-7.1.2/wp-includes/version.php"; echo $wp_version;')" == "7.1.2" ]] \
    || fail "staged core is not WordPress 7.1.2"

echo "== PHP 8.5 packages"
php85_min="$(docker image inspect --format '{{index .Config.Labels "net.cylo.wordpress.php85-min-version"}}' "${image_ref}")"
dockerfile_min="$(sed -n 's/^ARG PHP85_MIN_VERSION=//p' "${gate_dir}/Dockerfile")"
[[ -n "${php85_min}" ]] || fail "image was built without PHP85_MIN_VERSION"
if [[ "${mode}" == release ]]; then
    [[ "${php85_min}" == "${dockerfile_min}" ]] \
        || fail "image was built with PHP85_MIN_VERSION=${php85_min}, but the Dockerfile pins '${dockerfile_min}'"
else
    echo "TRIAL: built with PHP85_MIN_VERSION=${php85_min}; the Dockerfile pins '${dockerfile_min:-<unset>}'"
fi
docker run --rm --network none -v "${gate_dir}/release:/release:ro" --entrypoint sh "${image_ref}" \
    /release/check-php-packages.sh php8.5 "${php85_min}" \
    || fail "php8.5 packages are not all at ${php85_min} or newer"
docker run --rm --network none --entrypoint php-fpm8.5 "${image_ref}" -v | head -1
docker run --rm --network none --entrypoint php-fpm8.5 "${image_ref}" -t \
    || fail "php-fpm8.5 configuration test failed"

echo "== PHP modules match the deployed 7.1.2 image"
docker pull --platform linux/amd64 "${deployed_ref}" >/dev/null
for sapi in php php-fpm8.5; do
    deployed_modules="$(docker run --rm --network none --entrypoint "${sapi}" "${deployed_ref}" -m)" \
        || fail "could not list ${sapi} modules of ${deployed_ref}"
    release_modules="$(docker run --rm --network none --entrypoint "${sapi}" "${image_ref}" -m)" \
        || fail "could not list ${sapi} modules of ${image_ref}"
    [[ -n "${deployed_modules}" ]] || fail "${deployed_ref} reported no ${sapi} modules"
    if [[ "${deployed_modules}" != "${release_modules}" ]]; then
        diff <(printf '%s\n' "${deployed_modules}") <(printf '%s\n' "${release_modules}") >&2 || true
        fail "${sapi} module list differs from the deployed 7.1.2 image"
    fi
    echo "${sapi}: $(printf '%s\n' "${release_modules}" | grep -cv -e '^\[' -e '^$') modules, identical to 7.1.2"
done

echo "== Multipart upload (built-in server)"
docker run --rm --network none -v "${gate_dir}/release:/release:ro" --entrypoint sh "${image_ref}" \
    /release/multipart-smoke.sh php8.5 \
    || fail "multipart upload smoke test failed"

echo "== Regression checks"
for check in "${gate_dir}"/release/regression/*.sh; do
    [[ -e "${check}" ]] || continue
    echo "-- $(basename "${check}")"
    docker run --rm --network none -v "${gate_dir}/release:/release:ro" --entrypoint sh "${image_ref}" \
        "/release/regression/$(basename "${check}")" \
        || fail "regression check $(basename "${check}") failed"
done

echo "== Core sync"

# Exercise both sides of the version guard without a customer database.
mkdir -p "${gate_root}/older/wp-includes" "${gate_root}/older/wp-content" \
    "${gate_root}/newer/wp-includes" "${gate_root}/newer/wp-content"
printf '%s\n' '<?php' "\$wp_version = '7.0.2';" > "${gate_root}/older/wp-includes/version.php"
printf '%s\n' '<?php' "\$wp_version = '99.0.0';" > "${gate_root}/newer/wp-includes/version.php"
touch "${gate_root}/older/wp-content/keep" "${gate_root}/newer/wp-content/keep"
docker run --rm --platform linux/amd64 \
    --entrypoint /usr/local/bin/sync-wordpress-core \
    -v "${gate_root}/older:/tmp/installed" \
    "${image_ref}" /opt/wordpress-7.1.2 /tmp/installed >/dev/null
[[ "$(docker run --rm --entrypoint php -v "${gate_root}/older:/tmp/installed" "${image_ref}" \
    -r 'include "/tmp/installed/wp-includes/version.php"; echo $wp_version;')" == "7.1.2" ]] \
    || fail "older core was not upgraded"
[[ -f "${gate_root}/older/wp-content/keep" ]] || fail "older site content was removed"
docker run --rm --platform linux/amd64 \
    --entrypoint /usr/local/bin/sync-wordpress-core \
    -v "${gate_root}/newer:/tmp/installed" \
    "${image_ref}" /opt/wordpress-7.1.2 /tmp/installed >/dev/null
[[ "$(docker run --rm --entrypoint php -v "${gate_root}/newer:/tmp/installed" "${image_ref}" \
    -r 'include "/tmp/installed/wp-includes/version.php"; echo $wp_version;')" == "99.0.0" ]] \
    || fail "newer automatically updated core was overwritten"
[[ -f "${gate_root}/newer/wp-content/keep" ]] || fail "newer site content was removed"

echo "== Fresh install and restart"
launch "${fresh_container}" "${gate_root}/fresh" "${image_ref}"
check_core_updates "${fresh_container}" 7.1.2
# Test the configuration files the entrypoint actually runs with.
docker exec "${fresh_container}" php-fpm8.5 -t --fpm-config /home/appbox/config/php-fpm/php-fpm.conf \
    || fail "php-fpm8.5 runtime configuration test failed"
docker exec "${fresh_container}" nginx -t -c /home/appbox/config/nginx/nginx.conf \
    || fail "nginx runtime configuration test failed"
check_fpm_upload "${fresh_container}"
fresh_config_hash="$(docker exec "${fresh_container}" sha256sum "${wp_path}/wp-config.php" | cut -d' ' -f1)"
docker restart "${fresh_container}" >/dev/null
wait_ready "${fresh_container}"
[[ "$(docker exec "${fresh_container}" sha256sum "${wp_path}/wp-config.php" | cut -d' ' -f1)" == "${fresh_config_hash}" ]] \
    || fail "restart changed WordPress configuration or salts"

echo "== Upgrade from 7.0.2"
docker pull --platform linux/amd64 "${baseline_ref}" >/dev/null
launch "${legacy_container}" "${gate_root}/upgrade" "${baseline_ref}"
[[ "$(docker exec "${legacy_container}" wp --allow-root --path="${wp_path}" core version)" == "7.0.2" ]] \
    || fail "legacy fixture has the wrong core version"
docker exec "${legacy_container}" mkdir -p "${wp_path}/wp-content/uploads"
docker exec "${legacy_container}" touch "${wp_path}/wp-content/uploads/release-gate-marker"
legacy_salt_hash="$(docker exec "${legacy_container}" wp --allow-root --path="${wp_path}" \
    config get AUTH_KEY | sha256sum | cut -d' ' -f1)"
docker rm -f "${legacy_container}" >/dev/null
launch "${upgrade_container}" "${gate_root}/upgrade" "${image_ref}"
check_core_updates "${upgrade_container}" 7.1.2
[[ -f "${gate_root}/upgrade/public_html/wp-content/uploads/release-gate-marker" ]] \
    || fail "legacy site content was not preserved"
[[ "$(docker exec "${upgrade_container}" wp --allow-root --path="${wp_path}" \
    config get AUTH_KEY | sha256sum | cut -d' ' -f1)" == "${legacy_salt_hash}" ]] \
    || fail "legacy authentication salts changed"

docker rm -f "${upgrade_container}" >/dev/null

echo "== Upgrade from the legacy wordpress:latest images (latest-4)"
legacy_upgrade focal "${legacy_focal_ref}" "${focal_container}" "${focal_upgrade_container}"
legacy_upgrade noble "${legacy_noble_ref}" "${noble_container}" "${noble_upgrade_container}"

echo "== Registry tag must not exist"
# A 404 from the authenticated registry API proves the exact tag is unused.
python3 - "${release_ref}" <<'PY'
import json
import pathlib
import sys
import urllib.error
import urllib.request

config_path = pathlib.Path.home() / '.docker' / 'config.json'
try:
    auth = json.loads(config_path.read_text())['auths']['repo.cylo.net']['auth']
    if not auth:
        raise ValueError('empty registry authentication')
    request = urllib.request.Request(
        'https://repo.cylo.net/v2/wordpress/manifests/7.1.2-1',
        headers={
            'Authorization': 'Basic ' + auth,
            'Accept': ','.join((
                'application/vnd.oci.image.index.v1+json',
                'application/vnd.oci.image.manifest.v1+json',
                'application/vnd.docker.distribution.manifest.v2+json',
            )),
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            raise RuntimeError(f'tag already exists (HTTP {response.status})')
    except urllib.error.HTTPError as error:
        if error.code != 404:
            raise RuntimeError(f'registry returned HTTP {error.code}') from error
        body = error.read(4096).decode('utf-8', 'replace')
        if 'MANIFEST_UNKNOWN' not in body:
            raise RuntimeError(f'registry returned 404 without MANIFEST_UNKNOWN: {body[:300]}') from error
except Exception as error:
    print(f'Registry precondition failed: {error}', file=sys.stderr)
    sys.exit(1)

print('Authenticated registry confirms repo.cylo.net/wordpress:7.1.2-1 is not in the registry yet')
PY

echo "PASS (${mode}): WordPress 7.1.2-1 release gate passed for ${image_ref}"
