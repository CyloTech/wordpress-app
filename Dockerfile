FROM repo.cylo.io/baseimage

ENV MYSQL_ROOT_PASSWORD=mysqlr00t \
    APEX_CALLBACK=false \
    INSTALL_MYSQL=true \
    INSTALL_NGINXPHP=true

# Declare Environment variables required by the parent:
ENV MYSQL_ROOT_PASS=mysqlr00t
ENV DB_NAME=wordpress

# WordPress environment variables
ENV WP_URL                  ${WP_URL:-"localhost"}
ENV WP_TITLE                ${WP_TITLE:-"Wordpress Blog"}
ENV WP_ADMIN_USER           ${WP_ADMIN_USER:-"admin"}
ENV WP_ADMIN_PASSWORD       ${WP_ADMIN_PASSWORD:-"admin123"}
ENV WP_ADMIN_EMAIL          ${WP_ADMIN_EMAIL:-"test@test.com"}
ENV WP_VERSION              ${WP_VERSION:-"5.1.1"}
ENV WP_CLI_VERSION          ${WP_CLI_VERSION:-"2.1.0"}

# WordPress configuration
ADD sources/wp-config.php /wp-config.php

ADD scripts/30_wordpress.sh /etc/my_init.d/30_wordpress.sh
RUN chmod +x /etc/my_init.d/30_wordpress.sh