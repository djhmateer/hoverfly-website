#!/bin/sh

# Builds the hoverflylagoons.co.uk WordPress webserver on Ubuntu 26.04
# Run by infra.azcli via az vm run-command (runs as root)
# Expects /home/dave/dnsimpletoken.txt, live-db.sql.gz and live-files.tgz in /home/dave (scp'd by infra.azcli)

set -x

# daily unattended security upgrades
cat <<EOT > /etc/apt/apt.conf.d/20auto-upgrades
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOT

# 2GB swap file - the VM only has 1GB RAM and no temp disk
fallocate -l 2G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab

apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

# nginx, php-fpm and mysql from the Ubuntu archive
DEBIAN_FRONTEND=noninteractive apt-get install -y nginx mysql-server ufw \
  php-fpm php-mysql php-curl php-gd php-mbstring php-xml php-intl php-zip php-imagick

# sysstat (already on the image): sample every minute instead of every 10 so short memory spikes show,
# keep 28 days, and -S XALL adds memory/CPU/IO pressure (sar -q MEM). See README daily checks.
sed -i 's/^ENABLED=.*/ENABLED="true"/' /etc/default/sysstat
sed -i -E -e 's/^HISTORY=.*/HISTORY=28/' -e 's/^SADC_OPTIONS=.*/SADC_OPTIONS="-S XALL"/' /etc/sysstat/sysstat
mkdir -p /etc/systemd/system/sysstat-collect.timer.d
# the empty OnCalendar= clears the package's every-10-minutes one
printf '%s\n' '[Timer]' 'OnCalendar=' 'OnCalendar=*:*:00' > /etc/systemd/system/sysstat-collect.timer.d/zz-every-minute.conf
systemctl daemon-reload
systemctl enable --now sysstat sysstat-collect.timer
systemctl restart sysstat-collect.timer

# keep MySQL small for 1GB RAM (performance_schema alone uses a few hundred MB)
cat <<EOT > /etc/mysql/mysql.conf.d/99-hoverfly.cnf
[mysqld]
performance_schema = OFF
innodb_buffer_pool_size = 128M
max_connections = 30
EOT
systemctl restart mysql

# fail if nginx is older than the nginx2root fix (USN-9159-1) for 26.04
nginx_version=$(dpkg-query -W -f='${Version}' nginx)
if ! dpkg --compare-versions "$nginx_version" ge 1.28.3-2ubuntu1.13; then
  echo "nginx $nginx_version is not patched for nginx2root - stopping"
  exit 1
fi

# SSL cert from Let's Encrypt via DNS-01 challenge on DNSimple
# works before DNS points here, and the certbot snap's systemd timer auto renews
snap wait system seed.loaded
snap install --classic certbot
snap set certbot trust-plugin-with-root=ok
snap install certbot-dns-dnsimple

# set +x so the token isn't echoed into the run-command output
set +x
mkdir -p /etc/letsencrypt
echo "dns_dnsimple_token = $(head -n 1 /home/dave/dnsimpletoken.txt)" > /etc/letsencrypt/dnsimple.ini
chmod 600 /etc/letsencrypt/dnsimple.ini
rm /home/dave/dnsimpletoken.txt
set -x

certbot certonly --non-interactive --agree-tos --register-unsafely-without-email \
  --dns-dnsimple --dns-dnsimple-credentials /etc/letsencrypt/dnsimple.ini \
  -d hoverflylagoons.co.uk -d www.hoverflylagoons.co.uk \
  --deploy-hook "systemctl reload nginx"

# repo for nginx.conf, php ini and the restore script
git clone https://github.com/djhmateer/hoverfly-website.git /gitsource

# php settings (upload size etc) - same values whatever PHP version Ubuntu ships
phpv=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
cp /gitsource/infra/php-hoverfly.ini /etc/php/${phpv}/fpm/conf.d/99-hoverfly.ini
systemctl restart php${phpv}-fpm

# database with a random password (only wp-config.php needs to know it)
# set +x so the password isn't echoed into the run-command output
set +x
dbpass=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c34)
mysql -e "CREATE DATABASE wordpress;"
mysql -e "CREATE USER 'wp_user'@'localhost' IDENTIFIED BY '${dbpass}';"
mysql -e "GRANT ALL ON wordpress.* TO 'wp_user'@'localhost';"

# WordPress CLI
curl -o /usr/local/bin/wp https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
chmod +x /usr/local/bin/wp

# live site files (WordPress core, wp-content and wp-config.php) - same WordPress version as live
rm -rf /var/www/html
tar xzf /home/dave/live-files.tgz -C /var/www
chown -R www-data:www-data /var/www/html

# keep the live wp-config.php (salts, settings) but point it at the new database password
cd /var/www/html
sudo -u www-data wp config set DB_PASSWORD "${dbpass}" --quiet
set -x

gunzip -c /home/dave/live-db.sql.gz | mysql wordpress
rm /home/dave/live-db.sql.gz /home/dave/live-files.tgz

chown -R www-data:www-data /var/www/html
find /var/www/html -type d -exec chmod 755 {} \;
find /var/www/html -type f -exec chmod 644 {} \;
chmod 640 /var/www/html/wp-config.php

# nginx config - certs are in /etc/letsencrypt/live/hoverflylagoons.co.uk/
cp /gitsource/infra/nginx.conf /etc/nginx/sites-available/default
nginx -t
systemctl reload nginx

ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable
