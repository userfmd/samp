#!/bin/bash

clear
echo "======================================"
echo "   SA:MP 0.3.DL - Auto Installer"
echo "   Apache2 | PHP 7.4 | MySQL | PMA"
echo "======================================"
sleep 2

# Vérification root
if [ "$EUID" -ne 0 ]; then
  echo "❌ Lance ce script en root"
  exit 1
fi

# Mise à jour du système
echo "🔄 Mise à jour du système..."
apt update -y && apt upgrade -y

# Dépendances
echo "📦 Installation des dépendances..."
apt install -y software-properties-common ca-certificates curl wget unzip lsb-release gnupg

# PHP 7.4
echo "🐘 Installation PHP 7.4..."
add-apt-repository ppa:ondrej/php -y
apt update -y
apt install -y php7.4 php7.4-cli php7.4-mysql php7.4-curl php7.4-mbstring php7.4-xml php7.4-zip libapache2-mod-php7.4

# Apache
echo "🌐 Installation Apache2..."
apt install -y apache2
systemctl enable apache2
systemctl restart apache2

# MySQL
echo "🛢 Installation MySQL Server..."
apt install -y mysql-server
systemctl enable mysql
systemctl start mysql

# Sécurisation MySQL (automatique soft)
mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY 'root'; FLUSH PRIVILEGES;" 2>/dev/null

# phpMyAdmin
echo "📊 Installation phpMyAdmin..."
echo "phpmyadmin phpmyadmin/dbconfig-install boolean true" | debconf-set-selections
echo "phpmyadmin phpmyadmin/app-password-confirm password root" | debconf-set-selections
echo "phpmyadmin phpmyadmin/mysql/admin-pass password root" | debconf-set-selections
echo "phpmyadmin phpmyadmin/mysql/app-pass password root" | debconf-set-selections
echo "phpmyadmin phpmyadmin/reconfigure-webserver multiselect apache2" | debconf-set-selections

apt install -y phpmyadmin

# Lien phpMyAdmin
ln -s /usr/share/phpmyadmin /var/www/html/phpmyadmin

systemctl restart apache2

# SA:MP
echo "🎮 Installation SA:MP 0.3.DL..."
mkdir -p /home/samp
cd /home/samp

wget -q https://files.sa-mp.com/samp037svr_R2-1.tar.gz
tar -xzf samp037svr_R2-1.tar.gz
rm samp037svr_R2-1.tar.gz

chmod +x samp03/samp03svr

# Firewall (optionnel)
echo "🔥 Configuration UFW..."
apt install -y ufw
ufw allow 22
ufw allow 80
ufw allow 443
ufw allow 7777/udp
ufw --force enable

# Infos finales
IP=$(curl -s ifconfig.me)

clear
echo "======================================"
echo " ✅ INSTALLATION TERMINÉE"
echo "======================================"
echo ""
echo "🌍 Site web     : http://$IP"
echo "📊 phpMyAdmin   : http://$IP/phpmyadmin"
echo "👤 MySQL user   : root"
echo "🔐 MySQL pass   : root"
echo ""
echo "🎮 SA:MP dossier: /home/samp/samp03"
echo "🚀 Lancer SA:MP : ./samp03svr"
echo ""
echo "Ports ouverts : 22 / 80 / 443 / 7777"
echo "======================================"
