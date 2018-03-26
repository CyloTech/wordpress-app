#!/bin/bash
if [  ! -f /etc/sqlconfigured ]; then

if [ -d "/run/mysqld" ]; then
	echo "[i] mysqld already present, skipping creation"
	chown -R nginx:nginx /run/mysqld
else
	echo "[i] mysqld not found, creating...."
	mkdir -p /run/mysqld
	chown -R nginx:nginx /run/mysqld
fi

if [ -d /var/lib/mysql/mysql ]; then
	echo "[i] MySQL directory already present, skipping creation"
	chown -R nginx:nginx /var/lib/mysql
	chmod -R 777 /var/lib/mysql
else
	echo "[i] MySQL data directory not found, creating initial DBs"

	chown -R nginx:nginx /var/lib/mysql
	chmod -R 777 /var/lib/mysql

	mysql_install_db --user=nginx

	sed -i 's#log-bin#\#log-bin#g' /etc/mysql/my.cnf

	MYSQL_DATABASE=${MYSQL_DATABASE:-"wordpress"}
	MYSQL_USER=${MYSQL_USER:-""}
	MYSQL_PASSWORD=${MYSQL_PASSWORD:-""}

	tfile=/tmp/setupsql

	cat << EOF > $tfile
USE mysql;
FLUSH PRIVILEGES;
GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' identified by '$MYSQL_ROOT_PASSWORD' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON *.* TO 'root'@'localhost' identified by '$MYSQL_ROOT_PASSWORD' WITH GRANT OPTION;
UPDATE user SET password=PASSWORD("$MYSQL_ROOT_PASSWORD") WHERE user='root' AND host='localhost';
EOF

# We will leave this here if we use this as a base image for future projects that require a DB creating.
	if [ "$MYSQL_DATABASE" != "" ]; then
	    echo "[i] Creating database: $MYSQL_DATABASE"
	    echo "CREATE DATABASE IF NOT EXISTS \`$MYSQL_DATABASE\` CHARACTER SET utf8 COLLATE utf8_general_ci;" >> $tfile

	    if [ "$MYSQL_USER" != "" ]; then
		echo "[i] Creating user: $MYSQL_USER with password $MYSQL_PASSWORD"
		echo "GRANT ALL ON \`$MYSQL_DATABASE\`.* to '$MYSQL_USER'@'%' IDENTIFIED BY '$MYSQL_PASSWORD';" >> $tfile
	    fi
	fi

	/usr/bin/mysqld --user=nginx --bootstrap --verbose=0 < $tfile
	#rm -f $tfile

cat << EOF >> /usr/local/etc/php/conf.d/mysqld-sockets.ini
pdo_mysql.default_socket=/run/mysqld/mysqld.sock
mysql.default_socket=/run/mysqld/mysqld.sock
mysqli.default_socket = /run/mysqld/mysqld.sock
EOF

cat << EOF >> /etc/supervisor/conf.d/mysql.conf
[program:mysql]
command=/usr/bin/mysqld --user=nginx --verbose=0 --socket=/run/mysqld/mysqld.sock
autostart=true
autorestart=true
priority=10
stdout_events_enabled=true
stderr_events_enabled=true
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
EOF


fi

touch /etc/sqlconfigured
else

echo "[i] SQL Already Configured"

fi