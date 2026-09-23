#!/bin/bash
set -Eeuo pipefail

if [[ $# -ne 2 ]]; then
    echo "Usage: sync-wordpress-core <staged-core> <installed-core>" >&2
    exit 2
fi

staged_core="$1"
installed_core="$2"

read_core_version() {
    php -r '
        include $argv[1];
        if (!isset($wp_version) || !is_string($wp_version) || $wp_version === "") {
            exit(1);
        }
        echo $wp_version;
    ' "$1"
}

if [[ ! -f "${staged_core}/wp-includes/version.php" ]]; then
    echo "Staged WordPress core is missing its version file" >&2
    exit 1
fi

staged_version="$(read_core_version "${staged_core}/wp-includes/version.php")"

if [[ -f "${installed_core}/wp-includes/version.php" ]]; then
    installed_version="$(read_core_version "${installed_core}/wp-includes/version.php")"
    if php -r 'exit(version_compare($argv[1], $argv[2], ">") ? 0 : 1);' \
        "${installed_version}" "${staged_version}"; then
        echo "Preserving newer installed WordPress ${installed_version} core"
        exit 0
    fi
fi

echo "Syncing WordPress ${staged_version} core while preserving wp-content and wp-config.php"
mkdir -p "${installed_core}"
rsync -a --checksum \
    --exclude wp-config.php \
    --exclude wp-content/ \
    "${staged_core}/" \
    "${installed_core}/"
rm -f "${installed_core}/wp-config-sample.php"
