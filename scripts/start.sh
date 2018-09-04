#!/bin/sh
set -x

if [ ! -f /etc/wp_installed ]; then
    if [ ! -f /home/appbox/public_html/wp-config.php ]; then
        # Setup the LEMP Stack.
        /bin/sh /scripts/lemp.sh

        rm -fr /home/appbox/public_html/index.php

        /usr/sbin/mysqld --user=appbox --socket=/run/mysqld/mysqld.sock &

        # Download WordPress
        wp_version=4.9.8 && \
        curl -L "https://wordpress.org/wordpress-${wp_version}.tar.gz" > /wordpress-${wp_version}.tar.gz && \
        rm -fr /home/appbox/public_html/index.html && \
        tar -xzf /wordpress-${wp_version}.tar.gz -C /home/appbox/public_html --strip-components=1 && \
        rm /wordpress-${wp_version}.tar.gz

        # Download WordPress CLI
        cli_version=1.4.1 && \
        curl -L "https://github.com/wp-cli/wp-cli/releases/download/v${cli_version}/wp-cli-${cli_version}.phar" > /usr/bin/wp && \
        chmod +x /usr/bin/wp

        if ! $(wp core is-installed  --allow-root --path='/home/appbox/public_html'); then
           echo "=> WordPress is not configured yet, configuring WordPress ..."

           mv /wp-config.php /home/appbox/public_html/wp-config.php
           chown -R appbox:appbox /home/appbox/public_html

           echo "=> Installing WordPress to ${WP_URL}"
           sed -i "s#WP_URL#${WP_URL}#g" /home/appbox/public_html/wp-config.php
           sed -i "s/MYSQL_USERNAME/root/g" /home/appbox/public_html/wp-config.php
           sed -i "s/MYSQL_PASSWORD/${MYSQL_ROOT_PASSWORD}/g" /home/appbox/public_html/wp-config.php
           wp --allow-root core install --path='/home/appbox/public_html' --url="$WP_URL" --title="$WP_TITLE" --admin_user="$WP_ADMIN_USER" --admin_password="$WP_ADMIN_PASSWORD" --admin_email="$WP_ADMIN_EMAIL"

           chmod -R 777 /home/appbox/public_html/wp-content/uploads
           chmod -R 777 /home/appbox/public_html/wp-content/themes
           chmod -R 777 /home/appbox/public_html/wp-content/plugins

           touch /etc/wp_installed
           curl -i -H "Accept: application/json" -H "Content-Type:application/json" -X POST "https://api.cylo.io/v1/apps/installed/$INSTANCE_ID"

           pkill -9 mysqld
        else
           echo "=> WordPress is already configured."
        fi
    else
        pkill -9 mysqld
        echo "This is an update, do nothing, Wordpress updates should be done from within the app".
    fi
else
    echo "WP is already installed, just start up."
fi

exec /usr/bin/supervisord -n -c /home/appbox/config/supervisor/supervisord.conf
exec "$@"
