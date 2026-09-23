#!/bin/bash
set -Eeuo pipefail

CONFIG_FLAG="/etc/wp_installed"
FRESH_INSTALL_FLAG="/etc/wp_fresh_install_started"
CORE_PATH="${WP_CORE_PATH:-/home/appbox/public_html}"
STAGED_CORE_PATH="${WP_STAGED_CORE_PATH:-/opt/wordpress-${WP_VERSION:-7.1.2}}"
CONFIG_TEMPLATE="${WP_CONFIG_TEMPLATE:-/usr/local/share/wordpress/wp-config.php}"
NGINX_CONFIG="${WP_NGINX_CONFIG:-/usr/local/share/wordpress/wordpress.conf}"
MYSQL_CONFIG="/home/appbox/config/mysql/mysqld.cnf"
MYSQL_SOCKET="/run/mysqld/mysqld.sock"
CALLBACK_PENDING_FILE="/etc/appbox-wordpress-callback.pending"
APP_USER="${APP_USER:-appbox}"
APP_GROUP="${APP_GROUP:-appbox}"
NORMALIZED_WP_URL=""

log() {
    echo "[wordpress] $*"
}

require_env() {
    local key="$1"

    if [[ -z "${!key:-}" ]]; then
        echo "Missing required environment variable: ${key}" >&2
        exit 1
    fi
}

normalize_wp_url() {
    local raw_url="$1"

    if [[ "${raw_url}" =~ ^https?:// ]]; then
        printf '%s' "${raw_url}"
    else
        printf 'https://%s' "${raw_url}"
    fi
}

safe_rm_stale_mysql_files() {
    rm -f /home/appbox/mysql/run/mysqld.pid
    rm -f /var/run/mysqld/mysqld.sock.lock
    rm -f /run/mysqld/mysqld.sock.lock
}

install_nginx_config() {
    mkdir -p /home/appbox/config/nginx/sites-enabled
    mkdir -p /etc/ssl
    if [[ ! -s /etc/ssl/cert.pem || ! -s /etc/ssl/key.pem ]]; then
        log "Generating temporary self-signed TLS certificate for local readiness"
        openssl req -x509 -nodes -newkey rsa:2048 -days 1 \
            -subj "/CN=localhost" \
            -keyout /etc/ssl/key.pem \
            -out /etc/ssl/cert.pem >/dev/null 2>&1
        chmod 0600 /etc/ssl/key.pem
        chmod 0644 /etc/ssl/cert.pem
    fi
    cp "${NGINX_CONFIG}" /home/appbox/config/nginx/sites-enabled/wordpress.conf
    rm -f /home/appbox/config/nginx/sites-enabled/default-site.conf
    chown "${APP_USER}:${APP_GROUP}" /home/appbox/config/nginx/sites-enabled/wordpress.conf
    chmod 0644 /home/appbox/config/nginx/sites-enabled/wordpress.conf
}

start_mysql_for_setup() {
    if [[ ! -f "${MYSQL_CONFIG}" ]]; then
        echo "MySQL config is missing at ${MYSQL_CONFIG}" >&2
        return 1
    fi

    for _ in $(seq 1 120); do
        if mysqladmin --protocol=socket --socket="${MYSQL_SOCKET}" --user=root ping >/dev/null 2>&1; then
            if ! mysql --protocol=socket --socket="${MYSQL_SOCKET}" --user=root -NBe "SELECT 1" >/dev/null 2>&1; then
                mysql --protocol=socket --socket="${MYSQL_SOCKET}" --user=root -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${MYSQL_ROOT_PASSWORD}'; FLUSH PRIVILEGES;" >/dev/null 2>&1 || true
            fi
            if ! mysql --protocol=socket --socket="${MYSQL_SOCKET}" --user=root --password="${MYSQL_ROOT_PASSWORD}" -NBe "SELECT 1" >/dev/null 2>&1; then
                mysql --protocol=socket --socket="${MYSQL_SOCKET}" --user=root -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${MYSQL_ROOT_PASSWORD}'; FLUSH PRIVILEGES;" >/dev/null 2>&1 || true
            fi
            mysql --protocol=socket --socket="${MYSQL_SOCKET}" --user=root --password="${MYSQL_ROOT_PASSWORD}" -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME:-wordpress}\`;" >/dev/null
            return 0
        fi
        sleep 2
    done

    echo "Timed out waiting for MySQL" >&2
    return 1
}

wp_cli() {
    wp --allow-root --path="${CORE_PATH}" "$@"
}

generate_wp_salts() {
    local config_file="$1"
    local salt_file

    salt_file="$(mktemp)"
    {
        printf "define('AUTH_KEY',         '%s');\n" "$(openssl rand -base64 64 | tr -d '\n')"
        printf "define('SECURE_AUTH_KEY',  '%s');\n" "$(openssl rand -base64 64 | tr -d '\n')"
        printf "define('LOGGED_IN_KEY',    '%s');\n" "$(openssl rand -base64 64 | tr -d '\n')"
        printf "define('NONCE_KEY',        '%s');\n" "$(openssl rand -base64 64 | tr -d '\n')"
        printf "define('AUTH_SALT',        '%s');\n" "$(openssl rand -base64 64 | tr -d '\n')"
        printf "define('SECURE_AUTH_SALT', '%s');\n" "$(openssl rand -base64 64 | tr -d '\n')"
        printf "define('LOGGED_IN_SALT',   '%s');\n" "$(openssl rand -base64 64 | tr -d '\n')"
        printf "define('NONCE_SALT',       '%s');\n" "$(openssl rand -base64 64 | tr -d '\n')"
    } > "${salt_file}"

    SALT_FILE="${salt_file}" perl -0pi -e '
        my $salt_path = $ENV{"SALT_FILE"};
        local $/;
        open my $fh, "<", $salt_path or die $!;
        my $salts = <$fh>;
        s#define\('\''AUTH_KEY'\''.*?define\('\''NONCE_SALT'\''.*?;#$salts#s;
    ' "${config_file}"
    rm -f "${salt_file}"
}

configure_fresh_wp_config() {
    NORMALIZED_WP_URL="$(normalize_wp_url "${WP_URL}")"
    cp "${CONFIG_TEMPLATE}" "${CORE_PATH}/wp-config.php"
    sed -i "s#%%WP_URL%%#${NORMALIZED_WP_URL}#g" "${CORE_PATH}/wp-config.php"
    sed -i "s#%%DB_NAME%%#wordpress#g" "${CORE_PATH}/wp-config.php"
    sed -i "s#%%DB_USER%%#root#g" "${CORE_PATH}/wp-config.php"
    sed -i "s#%%DB_PASSWORD%%#${MYSQL_ROOT_PASSWORD}#g" "${CORE_PATH}/wp-config.php"
    sed -i "s#%%DB_HOST%%#localhost:3306#g" "${CORE_PATH}/wp-config.php"
    sed -i "s#%%DB_CHARSET%%#utf8#g" "${CORE_PATH}/wp-config.php"
    generate_wp_salts "${CORE_PATH}/wp-config.php"
}

seed_wordpress_files() {
    mkdir -p "${CORE_PATH}"
    rm -f "${CORE_PATH}/index.html"

    if [[ -f "${CORE_PATH}/wp-load.php" ]]; then
        log "Existing WordPress core files detected; preserving them"
        return 0
    fi

    log "Seeding WordPress ${WP_VERSION:-7.1.2} files"
    tar -C "${STAGED_CORE_PATH}" -cf - . | tar -C "${CORE_PATH}" -xf -
}

sync_wordpress_core_files() {
    /usr/local/bin/sync-wordpress-core "${STAGED_CORE_PATH}" "${CORE_PATH}"
}

enable_core_auto_updates_by_default() {
    if ! wp_cli config has WP_AUTO_UPDATE_CORE --type=constant >/dev/null 2>&1; then
        wp_cli config set WP_AUTO_UPDATE_CORE true --raw --type=constant \
            --anchor=require_once --placement=before
        chown "${APP_USER}:${APP_GROUP}" "${CORE_PATH}/wp-config.php"
    fi
}

set_permissions() {
    chown -R "${APP_USER}:${APP_GROUP}" "${CORE_PATH}" /home/appbox/config /home/appbox/logs
    if [[ "$(stat -c '%u:%g' /home/appbox/mysql 2>/dev/null || true)" != "1000:1000" \
        || "$(stat -c '%u:%g' /home/appbox/mysql/data 2>/dev/null || true)" != "1000:1000" ]]; then
        chown -R "${APP_USER}:${APP_GROUP}" /home/appbox/mysql
    else
        chown "${APP_USER}:${APP_GROUP}" /home/appbox/mysql /home/appbox/mysql/data /home/appbox/mysql/run
    fi
    find "${CORE_PATH}" -type d -exec chmod 0755 {} +
    find "${CORE_PATH}" -type f -exec chmod 0644 {} +
    if [[ -d "${CORE_PATH}/wp-content" ]]; then
        find "${CORE_PATH}/wp-content" -type d -exec chmod 0775 {} +
        find "${CORE_PATH}/wp-content" -type f -exec chmod 0664 {} +
    fi
}

wait_for_wordpress_cli() {
    for _ in $(seq 1 60); do
        if wp_cli core is-installed >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done

    echo "Timed out waiting for an installed WordPress site" >&2
    return 1
}

fresh_install() {
    require_env WP_URL
    require_env WP_TITLE
    require_env WP_ADMIN_USER
    require_env WP_ADMIN_PASSWORD
    require_env WP_ADMIN_EMAIL

    touch "${FRESH_INSTALL_FLAG}"
    seed_wordpress_files
    sync_wordpress_core_files
    configure_fresh_wp_config
    set_permissions

    start_mysql_for_setup

    if ! wp_cli core is-installed >/dev/null 2>&1; then
        NORMALIZED_WP_URL="$(normalize_wp_url "${WP_URL}")"
        log "Installing WordPress at ${NORMALIZED_WP_URL}"
        wp_cli core install \
            --url="${NORMALIZED_WP_URL}" \
            --title="${WP_TITLE}" \
            --admin_user="${WP_ADMIN_USER}" \
            --admin_password="${WP_ADMIN_PASSWORD}" \
            --admin_email="${WP_ADMIN_EMAIL}" \
            --skip-email
    fi

    wp_cli core update-db
    enable_core_auto_updates_by_default
    rm -f "${FRESH_INSTALL_FLAG}"
}

upgrade_install() {
    log "Upgrade detected; preserving existing WordPress files and database"
    sync_wordpress_core_files
    set_permissions
    start_mysql_for_setup
    wait_for_wordpress_cli
    wp_cli core update-db
    enable_core_auto_updates_by_default
}

install_nginx_config
safe_rm_stale_mysql_files

if [[ ! -f "${CONFIG_FLAG}" ]]; then
    if [[ -f "${FRESH_INSTALL_FLAG}" ]]; then
        log "Retrying incomplete fresh install"
        fresh_install
    elif [[ -f "${CORE_PATH}/wp-config.php" ]]; then
        upgrade_install
    else
        fresh_install
    fi

    touch "${CALLBACK_PENDING_FILE}"
    touch "${CONFIG_FLAG}"
else
    log "Configured container restart detected; preserving existing WordPress salts and data"
fi

safe_rm_stale_mysql_files
