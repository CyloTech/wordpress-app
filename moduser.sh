#!/bin/bash
set -Eeuo pipefail

NEW_PASSWORD="${1:-}"
WP_CORE_PATH="${WP_CORE_PATH:-/home/appbox/public_html}"
MYSQL_SOCKET="${MYSQL_SOCKET:-/run/mysqld/mysqld.sock}"
MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-mysqlr00t}"

if [[ -z "${NEW_PASSWORD}" ]]; then
    echo "Usage: /moduser.sh <new_password>" >&2
    exit 1
fi

if [[ ! -f "${WP_CORE_PATH}/wp-config.php" ]]; then
    echo "WordPress is not installed at ${WP_CORE_PATH}" >&2
    exit 1
fi

if ! mysqladmin --protocol=socket --socket="${MYSQL_SOCKET}" --user=root --password="${MYSQL_ROOT_PASSWORD}" ping >/dev/null 2>&1; then
    echo "MySQL is not ready; cannot reset the WordPress password" >&2
    exit 1
fi

ADMIN_USER="$(
    wp --allow-root --path="${WP_CORE_PATH}" user list \
        --role=administrator \
        --field=user_login \
        --number=1
)"

if [[ -z "${ADMIN_USER}" ]]; then
    echo "No administrator user found" >&2
    exit 1
fi

wp --allow-root --path="${WP_CORE_PATH}" user update "${ADMIN_USER}" --user_pass="${NEW_PASSWORD}" --skip-email >/dev/null
echo "Password updated for WordPress administrator: ${ADMIN_USER}"
