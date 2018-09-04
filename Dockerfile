FROM repo.cylo.io/ubuntu-lemp

# Disable Supervisor on the parent image, this allows us to run commands after the parent has finished installing.
ENV START_SUPERVISOR=false

# Declare Environment variables required by the parent:
ENV MYSQL_ROOT_PASS=mysqlr00t
ENV DB_NAME=wordpress

# WordPress environment variables
ENV WP_URL                  ${WP_URL:-"localhost"}
ENV WP_TITLE                ${WP_TITLE:-"Wordpress Blog"}
ENV WP_ADMIN_USER           ${WP_ADMIN_USER:-"admin"}
ENV WP_ADMIN_PASSWORD       ${WP_ADMIN_PASSWORD:-"admin123"}
ENV WP_ADMIN_EMAIL          ${WP_ADMIN_EMAIL:-"test@test.com"}

# WordPress configuration
ADD sources/wp-config.php /wp-config.php

ADD scripts/start.sh /scripts/start.sh
RUN chmod -R +x /scripts

ENTRYPOINT [ "/scripts/start.sh" ]