#!/bin/sh

# /etc/apache2/sites-available
# /var/www/html
# sudo systemctl restart apache

# how to copy files off server
# scp dave@hoverflytest39.westeurope.cloudapp.azure.com:/home/dave/php.ini .

#
# Disable auto upgrades
# Keep in now (was a potential problem for another application)
#
# cd /home/dave

# cat <<EOT >> 20auto-upgrades
# APT::Periodic::Update-Package-Lists "0";
# APT::Periodic::Download-Upgradeable-Packages "0";
# APT::Periodic::AutocleanInterval "0";
# APT::Periodic::Unattended-Upgrade "1";
# EOT

# sudo mv /home/dave/20auto-upgrades /etc/apt/apt.conf.d/20auto-upgrades

sudo apt update -y
sudo apt upgrade -y

sudo apt install apache2 -y

# Get helper files from repo
# dave directory created from ssh key passed in?
cd /home/dave
sudo git clone https://github.com/djhmateer/hoverfly-website.git source

# AllowOverride in web root for url rewriting
sudo cp /home/dave/source/infra/000-default.conf /etc/apache2/sites-available
# Cloudflare connects on SSL (even though we're using the default self signed ssl)
sudo cp /home/dave/source/infra/default-ssl.conf /etc/apache2/sites-available

sudo a2enmod rewrite
sudo a2enmod ssl
sudo a2ensite default-ssl.conf
sudo service apache2 restart

# Mysql
sudo apt install mysql-server -y

# https://www.digitalocean.com/community/tutorials/how-to-install-linux-apache-mysql-php-lamp-stack-on-ubuntu-20-04
#- sudo mysql_secure_installation

sudo mysql -e "CREATE DATABASE wordpress;"
sudo mysql -e "CREATE USER 'wp_user'@'localhost' IDENTIFIED BY 'password';"
sudo mysql -e "GRANT ALL ON wordpress.* TO 'wp_user'@'localhost';"
sudo mysql -e "FLUSH PRIVILEGES;"

# PHP7.4 is included in 21.04 so no need to point to this new repo unless want PHP8
# Easier to leave with default version as extensions below get harder when specifying versions

# sudo apt install software-properties-common -y
# sudo add-apt-repository ppa:ondrej/php -y
# sudo apt update -y
# sudo apt upgrade -y

# PHP default version install
sudo apt install php -y
sudo apt install php-curl php-gd php-mbstring php-xml php-xmlrpc php-soap php-intl php-zip -y
sudo apt install libapache2-mod-php -y
sudo apt install php-mysql -y
sudo apt install php-imagick -y

# To install specific version of PHP
# sudo apt install php7.4 libapache2-mod-php php-mysql -y

# Then need specific versions of extensions eg
# sudo apt install php7.4-mysql -y
# sudo apt install php7.4-curl

#  # settings needed for wp all in one website import
#  # https://help.servmask.com/2018/10/27/how-to-increase-maximum-upload-file-size-in-wordpress/
#  # .htaccess works, but not auto generated until after wordpress starts
#  # wp-config.php putting in settings didn't work for me
#  # **WILL NEED TO PATCH IN NEW VERSION WHEN NEW VERSION OF PHP**
#  # - cd /etc/php/7.2/apache2
cd /etc/php/7.4/apache2
sudo cp php.ini phpoldini.txt
sudo cp /home/dave/source/infra/php74.ini /etc/php/7.4/apache2/php.ini

# delete the apache default index.html
sudo rm /var/www/html/index.html

# info.php
# sudo cp /home/dave/source/infra/info.php /var/www/html/

# checks for syntax errors in apache conf
sudo apache2ctl configtest
sudo systemctl restart apache2

# Wordpress CLI
# https://www.linode.com/docs/websites/cms/wordpress/install-wordpress-using-wp-cli-on-ubuntu-18-04/
cd /home/dave
sudo curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
sudo chmod +x wp-cli.phar
sudo mv wp-cli.phar /usr/local/bin/wp

cd /var/www/html
#  sudo chown -R www-data:www-data html
sudo chown -R www-data:www-data /var/www
sudo -u www-data wp core download
sudo -u www-data wp core config --dbname='wordpress' --dbuser='wp_user' --dbpass='password' --dbhost='localhost' --dbprefix='wp_'

sudo chmod -R 755 /var/www/html/wp-content

# I need the domain name eg http://hoverflytest427.westeurope.cloudapp.azure.com/
# Or use Cloudflare DNS to switch
sudo -u www-data wp core install --url='https://hoverflylagoons.co.uk' --title='Blog Title' --admin_user='dave' --admin_password='letmein' --admin_email='email@domain.com'
# sudo -u www-data wp core install --url='http://hoverflylagoons821.westeurope.cloudapp.azure.com/' --title='Blog Title' --admin_user='dave' --admin_password='letmein' --admin_email='email@domain.com'

# plugins
sudo -u www-data wp plugin install all-in-one-wp-migration --activate  

# all in one file extension
cd ~
sudo curl -O https://import.wp-migration.com/all-in-one-wp-migration-file-extension.zip
sudo -u www-data cp all-in-one-wp-migration-file-extension.zip /var/www/html
cd /var/www/html
sudo -u www-data wp plugin install all-in-one-wp-migration-file-extension.zip --activate

# wp mail smtp (I'll bring this in through the restore so don't need to do here)

sudo systemctl restart apache2