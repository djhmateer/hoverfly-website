#!/bin/sh

# Builds the hoverflylagoons.co.uk WordPress webserver on Ubuntu 26.04
# Run by infra.azcli via az vm run-command (runs as root)
# Expects /home/dave/dnsimpletoken.txt and /home/dave/backup.wpress (scp'd by infra.azcli)

set -x

# daily unattended security upgrades
cat <<EOT > /etc/apt/apt.conf.d/20auto-upgrades
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOT

apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

# nginx, php-fpm and mysql from the Ubuntu archive
DEBIAN_FRONTEND=noninteractive apt-get install -y nginx mysql-server ufw \
  php-fpm php-mysql php-curl php-gd php-mbstring php-xml php-intl php-zip php-imagick

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

# same WordPress version as the export so pages render the same
# update to the latest from wp-admin after switching DNS
rm -f /var/www/html/index.nginx-debian.html
chown -R www-data:www-data /var/www/html
cd /var/www/html
sudo -u www-data wp core download --version=6.9.12
sudo -u www-data wp config create --dbname=wordpress --dbuser=wp_user --dbpass="${dbpass}" --dbhost=localhost --dbprefix=wp_
set -x

# unpack the export and copy wp-content over the fresh install
# mu-plugins (an old host's sso.php login plugin) and upgrade are deliberately not copied
python3 -I /gitsource/infra/restore-wpress.py /home/dave/backup.wpress /home/dave/restore
for d in plugins themes uploads languages; do
  cp -a /home/dave/restore/$d /var/www/html/wp-content/
done

# the export replaces the table prefix with a placeholder
# sql_mode off as MySQL's default strict mode rejects the '0000-00-00' date defaults in the dump
# (WordPress and the plugin importer turn it off the same way)
{ echo "SET SESSION sql_mode='';"; sed 's/SERVMASK_PREFIX_/wp_/g' /home/dave/restore/database.sql; } | mysql wordpress

chown -R www-data:www-data /var/www/html
find /var/www/html -type d -exec chmod 755 {} \;
find /var/www/html -type f -exec chmod 644 {} \;
chmod 640 /var/www/html/wp-config.php

rm -rf /home/dave/restore

# nginx config - certs are in /etc/letsencrypt/live/hoverflylagoons.co.uk/
cp /gitsource/infra/nginx.conf /etc/nginx/sites-available/default
nginx -t
systemctl reload nginx

ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable
