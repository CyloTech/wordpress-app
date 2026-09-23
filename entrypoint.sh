#!/bin/bash
set -Eeuo pipefail

CORE_PATH="${WP_CORE_PATH:-/home/appbox/public_html}"
MYSQL_SOCKET="/run/mysqld/mysqld.sock"
CALLBACK_PENDING_FILE="/etc/appbox-wordpress-callback.pending"
PIDS=()

log() {
    echo "[entrypoint] $*"
}

prepare_runtime() {
    mkdir -p \
        /home/appbox/config/nginx/sites-enabled \
        /home/appbox/config/nginx/modules-enabled \
        /home/appbox/config/php-fpm/pool.d \
        /home/appbox/config/mysql \
        /home/appbox/logs/nginx \
        /home/appbox/logs/mysql \
        /home/appbox/mysql/data \
        /home/appbox/mysql/run \
        /home/appbox/public_html \
        /var/lib/mysql-files \
        /run/mysqld \
        /run/php \
        /tmp

    cp /usr/local/share/wordpress/nginx.conf /home/appbox/config/nginx/nginx.conf
    cp /usr/local/share/wordpress/php-fpm.conf /home/appbox/config/php-fpm/php-fpm.conf
    cp /usr/local/share/wordpress/www.conf /home/appbox/config/php-fpm/pool.d/www.conf
    cp /usr/local/share/wordpress/mysqld.cnf /home/appbox/config/mysql/mysqld.cnf
    cp /etc/nginx/fastcgi_params /home/appbox/config/nginx/fastcgi_params

    touch /home/appbox/logs/mysql/error.log
    chown -R appbox:appbox /home/appbox /run/mysqld /run/php /var/lib/mysql-files
    chmod 0775 /run/mysqld /run/php /home/appbox/mysql/run /var/lib/mysql-files
}

shutdown() {
    log "Stopping services"
    mysqladmin --protocol=socket --socket="${MYSQL_SOCKET}" --user=root --password="${MYSQL_ROOT_PASSWORD:-mysqlr00t}" shutdown >/dev/null 2>&1 || true
    for pid in "${PIDS[@]:-}"; do
        kill "${pid}" >/dev/null 2>&1 || true
    done
    wait >/dev/null 2>&1 || true
}

wait_for_mysql() {
    for _ in $(seq 1 120); do
        if mysqladmin --protocol=socket --socket="${MYSQL_SOCKET}" --user=root --password="${MYSQL_ROOT_PASSWORD:-mysqlr00t}" ping >/dev/null 2>&1; then
            return 0
        fi
        if mysqladmin --protocol=socket --socket="${MYSQL_SOCKET}" --user=root ping >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done

    echo "Timed out waiting for MySQL" >&2
    return 1
}

start_mysql() {
    rm -f /home/appbox/mysql/run/mysqld.pid /run/mysqld/mysqld.sock /run/mysqld/mysqld.sock.lock

    if [[ ! -d /home/appbox/mysql/data/mysql || ! -f /home/appbox/mysql/data/mysql.ibd ]]; then
        log "Initializing fresh MySQL data directory"
        rm -rf /home/appbox/mysql/data/*
        if [[ -n "${MYSQL_DATA_TEMPLATE:-}" && -d "${MYSQL_DATA_TEMPLATE}/mysql" ]]; then
            cp -a "${MYSQL_DATA_TEMPLATE}/." /home/appbox/mysql/data/
        else
            mysqld --defaults-file=/home/appbox/config/mysql/mysqld.cnf --initialize-insecure --user=appbox 2>&1 | tee -a /home/appbox/logs/mysql/error.log &
            init_pid="$!"
            init_ready=0
            for _ in $(seq 1 300); do
                if [[ -f /home/appbox/mysql/data/mysql.ibd ]] \
                    && grep -q "A root@localhost is created with an empty password" /home/appbox/logs/mysql/error.log; then
                    init_ready=1
                    break
                fi
                if ! kill -0 "${init_pid}" >/dev/null 2>&1; then
                    wait "${init_pid}" || true
                    if [[ -f /home/appbox/mysql/data/mysql.ibd ]]; then
                        init_ready=1
                    fi
                    break
                fi
                sleep 1
            done
            if kill -0 "${init_pid}" >/dev/null 2>&1; then
                kill "${init_pid}" >/dev/null 2>&1 || true
                wait "${init_pid}" >/dev/null 2>&1 || true
            fi
            if [[ "${init_ready}" != "1" ]]; then
                echo "MySQL initialization did not complete" >&2
                exit 1
            fi
        fi
    fi
    chown -R appbox:appbox /home/appbox/mysql /run/mysqld

    /usr/sbin/mysqld --defaults-file=/home/appbox/config/mysql/mysqld.cnf --verbose=0 --socket="${MYSQL_SOCKET}" &
    PIDS+=("$!")
    wait_for_mysql

    if mysql --protocol=socket --socket="${MYSQL_SOCKET}" --user=root -NBe "SELECT 1" >/dev/null 2>&1; then
        mysql --protocol=socket --socket="${MYSQL_SOCKET}" --user=root -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD:-mysqlr00t}'; FLUSH PRIVILEGES;" >/dev/null 2>&1 \
            || mysql --protocol=socket --socket="${MYSQL_SOCKET}" --user=root -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${MYSQL_ROOT_PASSWORD:-mysqlr00t}'; FLUSH PRIVILEGES;" >/dev/null 2>&1 \
            || true
    elif ! mysql --protocol=socket --socket="${MYSQL_SOCKET}" --user=root --password="${MYSQL_ROOT_PASSWORD:-mysqlr00t}" -NBe "SELECT 1" >/dev/null 2>&1; then
        mysql --protocol=socket --socket="${MYSQL_SOCKET}" --user=root -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD:-mysqlr00t}'; FLUSH PRIVILEGES;" >/dev/null 2>&1 \
            || mysql --protocol=socket --socket="${MYSQL_SOCKET}" --user=root -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${MYSQL_ROOT_PASSWORD:-mysqlr00t}'; FLUSH PRIVILEGES;" >/dev/null 2>&1 \
            || true
    fi
    mysql --protocol=socket --socket="${MYSQL_SOCKET}" --user=root --password="${MYSQL_ROOT_PASSWORD:-mysqlr00t}" -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME:-wordpress}\`;" \
        || mysql --protocol=socket --socket="${MYSQL_SOCKET}" --user=root -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME:-wordpress}\`;"
}

start_php_fpm() {
    php_fpm_bin="$(command -v php-fpm || find /usr/sbin -maxdepth 1 -type f -name 'php-fpm*' | sort -V | tail -1)"
    if [[ -z "${php_fpm_bin}" ]]; then
        echo "Unable to find php-fpm binary" >&2
        exit 1
    fi
    "${php_fpm_bin}" --nodaemonize --fpm-config /home/appbox/config/php-fpm/php-fpm.conf &
    PIDS+=("$!")
}

start_nginx() {
    nginx -c /home/appbox/config/nginx/nginx.conf -g "daemon off;" &
    PIDS+=("$!")
}

callback_installed() {
    if [[ ! -f "${CALLBACK_PENDING_FILE}" ]]; then
        return 0
    fi

    for _ in $(seq 1 120); do
        if wp --allow-root --path="${CORE_PATH}" core is-installed >/dev/null 2>&1 \
            && curl -fsS --max-time 5 http://127.0.0.1/appbox-health >/dev/null 2>&1; then
            break
        fi
        sleep 2
    done

    if [[ "${SKIP_APPBOX_CALLBACK:-0}" == "1" || -z "${INSTANCE_ID:-}" ]]; then
        rm -f "${CALLBACK_PENDING_FILE}"
        return 0
    fi

    headers=(-H "Accept: application/json" -H "Content-Type:application/json")
    if [[ -n "${CALLBACK_TOKEN:-}" ]]; then
        headers+=(-H "X-Cylo-Callback-Token: ${CALLBACK_TOKEN}")
    fi

    until curl -fsS -o /dev/null "${headers[@]}" -X POST "https://api.cylo.net/v1/apps/installed/${INSTANCE_ID}"; do
        sleep 5
    done

    rm -f "${CALLBACK_PENDING_FILE}"
}

trap shutdown TERM INT EXIT

prepare_runtime
start_mysql
/usr/local/bin/wordpress-setup
start_php_fpm
start_nginx
callback_installed &

wait -n "${PIDS[@]}"
exit $?
