#!/bin/sh
set -x
# Setup the LAMP Stack.
/bin/sh /scripts/Entrypoint.sh


if [ ! -f /etc/wp_installed ]; then
    rm -fr /home/lamp/public_html/index.php

    /usr/bin/mysqld --user=lamp --verbose=0 &

    # Download WordPress
    wp_version=4.9.5 && \
    curl -L "https://wordpress.org/wordpress-${wp_version}.tar.gz" > /wordpress-${wp_version}.tar.gz && \
    rm -fr /home/lamp/public_html/index.html && \
    tar -xzf /wordpress-${wp_version}.tar.gz -C /home/lamp/public_html --strip-components=1 && \
    rm /wordpress-${wp_version}.tar.gz

    # Download WordPress CLI
    cli_version=1.4.1 && \
    curl -L "https://github.com/wp-cli/wp-cli/releases/download/v${cli_version}/wp-cli-${cli_version}.phar" > /usr/bin/wp && \
    chmod +x /usr/bin/wp

    if ! $(wp core is-installed  --allow-root --path='/home/lamp/public_html'); then
       echo "=> WordPress is not configured yet, configuring WordPress ..."

       mv /wp-config.php /home/lamp/public_html/wp-config.php
       chown -R lamp:lamp /home/lamp/public_html

       echo "=> Installing WordPress to ${WP_URL}"
       sed -i "s#WP_URL#${WP_URL}#g" /home/lamp/public_html/wp-config.php
       sed -i "s/MYSQL_USERNAME/root/g" /home/lamp/public_html/wp-config.php
       sed -i "s/MYSQL_PASSWORD/${MYSQL_ROOT_PASSWORD}/g" /home/lamp/public_html/wp-config.php
       wp --allow-root core install --path='/home/lamp/public_html' --url="$WP_URL" --title="$WP_TITLE" --admin_user="$WP_ADMIN_USER" --admin_password="$WP_ADMIN_PASSWORD" --admin_email="$WP_ADMIN_EMAIL"
       touch /etc/wp_installed

       curl -i -H "Accept: application/json" -H "Content-Type:application/json" -X POST "https://api.cylo.io/v1/apps/installed/$INSTANCE_ID"

       pkill -9 mysqld
    else
       echo "=> WordPress is already configured."
    fi

else
    echo "WP is already installed, just start up."
fi

exec /usr/bin/supervisord -n -c /etc/supervisord.conf
exec "$@"
