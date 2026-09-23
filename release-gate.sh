#!/bin/bash
set -Eeuo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: release-gate.sh repo.cylo.net/wordpress:7.1.2" >&2
    exit 2
fi
if [[ "$1" != "repo.cylo.net/wordpress:7.1.2" ]]; then
    echo "Usage: release-gate.sh repo.cylo.net/wordpress:7.1.2" >&2
    exit 2
fi

image_ref="$1"
baseline_ref="repo.cylo.net/wordpress@sha256:f40b3d3637e5457fdb5f2acce820da5106c230ee9280749bd6bac564031fe79d"
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
test_password="$(openssl rand -base64 30)"

cleanup() {
    docker rm -f "${fresh_container}" "${legacy_container}" "${upgrade_container}" >/dev/null 2>&1 || true
    if [[ "${gate_root}" =~ ^/home/appbox/builds/wordpress-gate\.[A-Za-z0-9]{6}$ ]]; then
        rm -rf -- "${gate_root}"
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
    docker exec -u 1000 "${container}" wp --path="${wp_path}" --skip-plugins --skip-themes \
        eval 'if ((new WP_Automatic_Updater())->is_disabled()) { exit(1); }' >/dev/null \
        || fail "${container} reports its automatic updater disabled"
}

[[ "$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "${image_ref}")" == "linux/amd64" ]] \
    || fail "built image is not linux/amd64"
[[ "$(docker run --rm --entrypoint php "${image_ref}" -r \
    'include "/opt/wordpress-7.1.2/wp-includes/version.php"; echo $wp_version;')" == "7.1.2" ]] \
    || fail "staged core is not WordPress 7.1.2"

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

launch "${fresh_container}" "${gate_root}/fresh" "${image_ref}"
check_core_updates "${fresh_container}" 7.1.2
fresh_config_hash="$(docker exec "${fresh_container}" sha256sum "${wp_path}/wp-config.php" | cut -d' ' -f1)"
docker restart "${fresh_container}" >/dev/null
wait_ready "${fresh_container}"
[[ "$(docker exec "${fresh_container}" sha256sum "${wp_path}/wp-config.php" | cut -d' ' -f1)" == "${fresh_config_hash}" ]] \
    || fail "restart changed WordPress configuration or salts"

docker pull --platform linux/amd64 "${baseline_ref}" >/dev/null
launch "${legacy_container}" "${gate_root}/upgrade" "${baseline_ref}"
[[ "$(docker exec "${legacy_container}" wp --allow-root --path="${wp_path}" core version)" == "7.0.2" ]] \
    || fail "legacy fixture has the wrong core version"
docker exec -u 1000 "${legacy_container}" mkdir -p "${wp_path}/wp-content/uploads"
docker exec -u 1000 "${legacy_container}" touch "${wp_path}/wp-content/uploads/release-gate-marker"
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

# A 404 from the authenticated registry API proves the exact tag is unused.
python3 - "${image_ref}" <<'PY'
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
        'https://repo.cylo.net/v2/wordpress/manifests/7.1.2',
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
except Exception as error:
    print(f'Registry precondition failed: {error}', file=sys.stderr)
    sys.exit(1)

print('Authenticated registry confirms WordPress 7.1.2 tag is unused')
PY

echo "WordPress 7.1.2 release gate passed"
