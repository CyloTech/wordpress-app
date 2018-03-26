FROM repo.cylo.io/alpine-lep

ENV MYSQL_ROOT_PASSWORD=mysqlr00t

# WordPress environment variables
ENV WP_URL ${WP_URL:-"localhost"}
ENV WP_TITLE ${WP_TITLE:-"Wordpress Blog"}
ENV WP_ADMIN_USER ${WP_ADMIN_USER:-"admin"}
ENV WP_ADMIN_PASSWORD ${WP_ADMIN_PASSWORD:-"admin123"}
ENV WP_ADMIN_EMAIL ${WP_ADMIN_EMAIL:-"test@test.com"}

RUN apk --update add mariadb mariadb-client

RUN \
 echo "**** install build packages ****" && \
 apk add --no-cache --virtual=build-dependencies \
	autoconf \
	automake \
	file \
	g++ \
	gcc \
	make \
	php7-dev \
	re2c \
	samba-dev \
	zlib-dev && \
 echo "**** install runtime packages ****" && \
 apk add --no-cache \
    php7-mysqli \
	curl \
	ffmpeg \
	libxml2 \
	php7-apcu \
	php7-bz2 \
	php7-ctype \
	php7-curl \
	php7-dom \
	php7-exif \
	php7-ftp \
	php7-gd \
	php7-gmp \
	php7-iconv \
	php7-imap \
	php7-intl \
	php7-ldap \
	php7-mbstring \
	php7-mcrypt \
	php7-memcached \
	php7-opcache \
	php7-pcntl \
	php7-pdo_mysql \
	php7-pdo_pgsql \
	php7-pdo_sqlite \
	php7-pgsql \
	php7-posix \
	php7-sqlite3 \
	php7-xml \
	php7-xmlreader \
	php7-zip \
	samba \
	sudo \
	tar \
	unzip && \
 echo "**** compile smbclient ****" && \
 git clone git://github.com/eduardok/libsmbclient-php.git /tmp/smbclient && \
 cd /tmp/smbclient && \
 phpize7 && \
 ./configure && \
 make && \
 make install && \
 echo "**** configure php and nginx for nextcloud ****" && \
 echo "extension="smbclient.so"" > /usr/local/etc/php/conf.d/00_smbclient.ini && \
 echo "opcache.enable = 1" >> /usr/local/etc/php/conf.d/docker-vars.ini && \
 echo "opcache.interned_strings_buffer=8" >> /usr/local/etc/php/conf.d/docker-vars.ini && \
 echo "opcache.max_accelerated_files=10000" >> /usr/local/etc/php/conf.d/docker-vars.ini && \
 echo "opcache.memory_consumption=128" >> /usr/local/etc/php/conf.d/docker-vars.ini && \
 echo "opcache.save_comments=1" >> /usr/local/etc/php/conf.d/docker-vars.ini && \
 echo "opcache.revalidate_freq=1" >> /usr/local/etc/php/conf.d/docker-vars.ini && \
 echo "always_populate_raw_post_data=-1" >> /usr/local/etc/php/conf.d/docker-vars.ini && \
 echo "opcache.enable_cli=1" >> /usr/local/etc/php/conf.d/docker-vars.ini && \
 echo "env[PATH] = /usr/local/bin:/usr/bin:/bin" >> /usr/local/etc/php-fpm.conf && \
 echo "**** cleanup ****" && \
 apk del --purge \
	build-dependencies && \
 rm -rf \
	/tmp/*

RUN docker-php-ext-configure gd --with-freetype-dir=/usr --with-png-dir=/usr --with-jpeg-dir=/usr; \
        docker-php-ext-install \
            exif \
            gd \
            intl \
            mbstring \
            mysqli \
            opcache \
            pcntl \
            pdo_mysql \
            zip

# WordPress configuration
ADD sources/wp-config.php /wp-config.php

ADD scripts/entrypoint.sh /scripts/entrypoint.sh
ADD scripts/mariadb.sh /scripts/mariadb.sh
RUN chmod -R +x /scripts

ENTRYPOINT [ "/scripts/entrypoint.sh" ]
CMD [ "/start.sh" ]