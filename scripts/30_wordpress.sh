#!/bin/bash
set -x

if [ ! -f /etc/wp_installed ]; then
    if [ ! -f /home/appbox/public_html/wp-config.php ]; then
        rm -fr /home/appbox/public_html/index.php

        /usr/sbin/mysqld --defaults-file=/home/appbox/config/mysql/mysqld.cnf --verbose=0 --socket=/run/mysqld/mysqld.sock &
        while !(mysqladmin ping)
        do
           sleep 3
           echo "waiting for mysql ..."
        done

        echo "Installing dependencies"
        apt update
        apt install sendmail php-dom php-gd

        # Download WordPress
        curl -L "https://wordpress.org/wordpress-${WP_VERSION}.tar.gz" > /wordpress-${WP_VERSION}.tar.gz && \
        rm -fr /home/appbox/public_html/index.html && \
        tar -xzf /wordpress-${WP_VERSION}.tar.gz -C /home/appbox/public_html --strip-components=1 && \
        rm /wordpress-${WP_VERSION}.tar.gz

        # Download WordPress CLI
        curl -L "https://github.com/wp-cli/wp-cli/releases/download/v${WP_CLI_VERSION}/wp-cli-${WP_CLI_VERSION}.phar" > /usr/bin/wp && \
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

           echo "Finishing Install"
           # Finish Install
           until [[ $(curl -i -H "Accept: application/json" -H "Content-Type:application/json" -X POST "https://api.cylo.io/v1/apps/installed/${INSTANCE_ID}" | grep '200') ]]
               do
               sleep 5
           done

           touch /etc/wp_installed

           pkill -9 mysqld
        else
           echo "=> WordPress is already configured."
        fi
    else
        echo "This is an update, Wordpress updates should be done from within the app.".
        until [[ $(curl -i -H "Accept: application/json" -H "Content-Type:application/json" -X POST "https://api.cylo.io/v1/apps/installed/${INSTANCE_ID}" | grep '200') ]]
           do
           sleep 5
        done
    fi
else
    echo "WP is already installed, just start up."
fi
