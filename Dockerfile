FROM ubuntu:latest

ARG WORDPRESS_VERSION=7.1.2
ARG WORDPRESS_TARBALL_MD5=b15c6a48881647462db57960a82419d2
ARG WP_CLI_VERSION=2.12.0
ARG WP_CLI_SHA512=be928f6b8ca1e8dfb9d2f4b75a13aa4aee0896f8a9a0a1c45cd5d2c98605e6172e6d014dda2e27f88c98befc16c040cbb2bd1bfa121510ea5cdf5f6a30fe8832
ARG IONCUBE_SHA256=e2193a63a87e2388a71854b0114de4fc71e2e40bcf0794faf74bb562691e5b62

ENV MYSQL_ROOT_PASSWORD=mysqlr00t \
    MYSQL_ROOT_PASS=mysqlr00t \
    DB_NAME=wordpress \
    DEBIAN_FRONTEND=noninteractive \
    WP_VERSION=${WORDPRESS_VERSION} \
    WP_CLI_VERSION=${WP_CLI_VERSION} \
    WP_CORE_PATH=/home/appbox/public_html \
    WP_STAGED_CORE_PATH=/opt/wordpress-${WORDPRESS_VERSION} \
    WP_CONFIG_TEMPLATE=/usr/local/share/wordpress/wp-config.php \
    WP_NGINX_CONFIG=/usr/local/share/wordpress/wordpress.conf \
    MYSQL_DATA_TEMPLATE=

RUN set -eux; \
    existing_group="$(getent group 1000 | cut -d: -f1 || true)"; \
    if [ -n "${existing_group}" ] && [ "${existing_group}" != "appbox" ]; then groupmod -n appbox "${existing_group}"; fi; \
    if ! getent group appbox >/dev/null; then groupadd --gid 1000 appbox; fi; \
    existing_user="$(getent passwd 1000 | cut -d: -f1 || true)"; \
    if [ -n "${existing_user}" ] && [ "${existing_user}" != "appbox" ]; then usermod -l appbox -d /home/appbox -m "${existing_user}"; fi; \
    if ! id appbox >/dev/null 2>&1; then useradd --uid 1000 --gid 1000 --home-dir /home/appbox --create-home --shell /usr/sbin/nologin appbox; fi; \
    usermod --gid appbox --home /home/appbox --shell /usr/sbin/nologin appbox; \
    printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d; \
    chmod 0755 /usr/sbin/policy-rc.d; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        less \
        mysql-client \
        mysql-server-core \
        nginx \
        openssl \
        php-bcmath \
        php-cli \
        php-curl \
        php-fpm \
        php-gd \
        php-imagick \
        php-intl \
        php-mbstring \
        php-mysql \
        php-soap \
        php-xml \
        php-zip \
        procps \
        rsync \
        tar \
        tzdata; \
    rm -f /usr/sbin/policy-rc.d; \
    rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    mkdir -p /usr/local/share/wordpress /tmp/wordpress-build; \
    curl -fsSL "https://wordpress.org/wordpress-${WORDPRESS_VERSION}.tar.gz" -o /tmp/wordpress-build/wordpress.tar.gz; \
    echo "${WORDPRESS_TARBALL_MD5}  /tmp/wordpress-build/wordpress.tar.gz" | md5sum -c -; \
    mkdir -p "${WP_STAGED_CORE_PATH}"; \
    tar -xzf /tmp/wordpress-build/wordpress.tar.gz -C "${WP_STAGED_CORE_PATH}" --strip-components=1; \
    curl -fsSL "https://github.com/wp-cli/wp-cli/releases/download/v${WP_CLI_VERSION}/wp-cli-${WP_CLI_VERSION}.phar" -o /usr/local/bin/wp; \
    echo "${WP_CLI_SHA512}  /usr/local/bin/wp" | sha512sum -c -; \
    chmod 0755 /usr/local/bin/wp; \
    curl -fsSL "https://downloads.ioncube.com/loader_downloads/ioncube_loaders_lin_x86-64.tar.gz" -o /tmp/wordpress-build/ioncube.tar.gz; \
    echo "${IONCUBE_SHA256}  /tmp/wordpress-build/ioncube.tar.gz" | sha256sum -c -; \
    tar -xzf /tmp/wordpress-build/ioncube.tar.gz -C /tmp/wordpress-build; \
    php_major_minor="$(php -r 'echo PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION;')"; \
    ioncube_loader="/tmp/wordpress-build/ioncube/ioncube_loader_lin_${php_major_minor}.so"; \
    test -f "${ioncube_loader}"; \
    php_extension_dir="$(php -r 'echo ini_get("extension_dir");')"; \
    cp "${ioncube_loader}" "${php_extension_dir}/ioncube_loader.so"; \
    php_ini_dir="$(php --ini | awk -F': ' '/Scan for additional/ {print $2; exit}' | tr -d '"')"; \
    mkdir -p "${php_ini_dir}"; \
    echo "zend_extension=${php_extension_dir}/ioncube_loader.so" > "${php_ini_dir}/00-ioncube.ini"; \
    php_fpm_ini_dir="$(find /etc/php -path '*/fpm/conf.d' -type d | sort -V | tail -1)"; \
    mkdir -p "${php_fpm_ini_dir}"; \
    echo "zend_extension=${php_extension_dir}/ioncube_loader.so" > "${php_fpm_ini_dir}/00-ioncube.ini"; \
    wp --allow-root cli version; \
    php -m | grep -F ionCube; \
    rm -rf /tmp/wordpress-build

COPY sources/wp-config.php /usr/local/share/wordpress/wp-config.php
COPY sources/wordpress.conf /usr/local/share/wordpress/wordpress.conf
COPY sources/nginx.conf /usr/local/share/wordpress/nginx.conf
COPY sources/php-fpm.conf /usr/local/share/wordpress/php-fpm.conf
COPY sources/www.conf /usr/local/share/wordpress/www.conf
COPY sources/mysqld.cnf /usr/local/share/wordpress/mysqld.cnf
COPY scripts/sync-wordpress-core.sh /usr/local/bin/sync-wordpress-core
COPY scripts/30_wordpress.sh /usr/local/bin/wordpress-setup
COPY entrypoint.sh /entrypoint.sh
COPY moduser.sh /moduser.sh
COPY sendmail /usr/sbin/sendmail

RUN set -eux; \
    chmod 0644 /usr/local/share/wordpress/*; \
    chmod 0755 /usr/local/bin/sync-wordpress-core /usr/local/bin/wordpress-setup /entrypoint.sh /moduser.sh /usr/sbin/sendmail; \
    mkdir -p /home/appbox/public_html /home/appbox/mysql/data /home/appbox/mysql/run /home/appbox/config /home/appbox/logs /run/mysqld /run/php /var/lib/mysql-files; \
    chown -R appbox:appbox /home/appbox /run/mysqld /run/php /var/lib/mysql-files

EXPOSE 80 443

ENTRYPOINT ["/entrypoint.sh"]
CMD []
