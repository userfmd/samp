#!/usr/bin/env bash
set -euo pipefail

# =========================
#   CONFIG (modifiable)
# =========================
SAMP_DIR="/home/samp"
SAMP_USER="samp"
SAMP_PORT="7777"
DB_ROOT_PASS="root" # Change si désiré
SAMP_TGZ_URL="https://files.sa-mp.com/samp038svr_DL_R1.tar.gz" # SA:MP 0.3.DL server

# =========================
#   Helpers
# =========================
log() { echo -e "\n\033[1;32m[+]\033[0m $*"; }
warn() { echo -e "\n\033[1;33m[!]\033[0m $*"; }
die() { echo -e "\n\033[1;31m[✗]\033[0m $*"; exit 1; }

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Lance ce script en root : sudo bash samp.sh"
  fi
}

require_root

log "Mise à jour + outils de base"
apt update -y
apt install -y curl wget unzip tar ca-certificates gnupg2 lsb-release \
  apt-transport-https software-properties-common openssl

# -------------------------
# Apache2
# -------------------------
log "Installation Apache2"
apt install -y apache2
systemctl enable --now apache2

# -------------------------
# MariaDB (mysql-server équivalent)
# -------------------------
log "Installation MariaDB"
apt install -y mariadb-server
systemctl enable --now mariadb

log "Sécurisation MariaDB root"
mariadb -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASS}'; FLUSH PRIVILEGES;" || true

# -------------------------
# PHP 7.4 via Sury
# -------------------------
log "Ajout du repo Sury (PHP 7.4)"
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://packages.sury.org/php/apt.gpg | gpg --dearmor -o /etc/apt/keyrings/sury-php.gpg

echo "deb [signed-by=/etc/apt/keyrings/sury-php.gpg] https://packages.sury.org/php/ $(lsb_release -sc) main" \
  > /etc/apt/sources.list.d/sury-php.list

apt update -y

log "Installation PHP 7.4 + modules"
apt install -y php7.4 libapache2-mod-php7.4 \
  php7.4-cli php7.4-common php7.4-mbstring php7.4-xml \
  php7.4-zip php7.4-curl php7.4-gd php7.4-mysql

a2dismod php8.2 >/dev/null 2>&1 || true
a2enmod php7.4 rewrite headers
systemctl restart apache2

# -------------------------
# phpMyAdmin (officiel)
# -------------------------
log "Installation phpMyAdmin"
PMA_VERSION="5.2.1"
PMA_DIR="/usr/share/phpmyadmin"

if [[ ! -d "${PMA_DIR}" ]]; then
  cd /tmp
  wget -q "https://files.phpmyadmin.net/phpMyAdmin/${PMA_VERSION}/phpMyAdmin-${PMA_VERSION}-all-languages.zip" -O pma.zip
  unzip -q pma.zip
  mv "phpMyAdmin-${PMA_VERSION}-all-languages" "${PMA_DIR}"
  rm -f pma.zip
else
  warn "phpMyAdmin déjà installé"
fi

log "Config phpMyAdmin"
install -d -m 0755 /var/lib/phpmyadmin/tmp
chown -R www-data:www-data /var/lib/phpmyadmin

cat > /usr/share/phpmyadmin/config.inc.php <<EOF
<?php
\$cfg['blowfish_secret'] = '$(openssl rand -base64 32 | tr -d '\n' | cut -c1-32)';
\$i = 0;
\$i++;
\$cfg['Servers'][\$i]['auth_type'] = 'cookie';
\$cfg['Servers'][\$i]['host'] = 'localhost';
\$cfg['Servers'][\$i]['compress'] = false;
\$cfg['Servers'][\$i]['AllowNoPassword'] = false;
\$cfg['TempDir'] = '/var/lib/phpmyadmin/tmp';
EOF

cat > /etc/apache2/conf-available/phpmyadmin.conf <<'EOF'
Alias /phpmyadmin /usr/share/phpmyadmin

<Directory /usr/share/phpmyadmin>
    Options SymLinksIfOwnerMatch
    DirectoryIndex index.php
    AllowOverride All
    Require all granted
</Directory>
EOF

a2enconf phpmyadmin
systemctl reload apache2

# -------------------------
# SA:MP install
# -------------------------
log "Création utilisateur système SA:MP"
if ! id -u "${SAMP_USER}" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "${SAMP_USER}"
fi

log "Téléchargement SA:MP"
install -d -m 0755 "${SAMP_DIR}"
chown -R "${SAMP_USER}:${SAMP_USER}" "${SAMP_DIR}"

cd /tmp
wget -q "${SAMP_TGZ_URL}" -O samp.tgz
tar -xzf samp.tgz
rm -f samp.tgz

mv /tmp/samp03/* "${SAMP_DIR}/"
chown -R "${SAMP_USER}:${SAMP_USER}" "${SAMP_DIR}"
chmod +x "${SAMP_DIR}/samp03svr"

# -------------------------
# systemd service
# -------------------------
log "Création service systemd"
cat > /etc/systemd/system/samp.service <<EOF
[Unit]
Description=SA:MP Server
After=network.target mariadb.service apache2.service

[Service]
Type=simple
User=${SAMP_USER}
WorkingDirectory=${SAMP_DIR}
ExecStart=${SAMP_DIR}/samp03svr
Restart=on-failure
RestartSec=3
LimitNOFILE=100000

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now samp

# -------------------------
# Firewall UFW
# -------------------------
log "Activation UFW"
apt install -y ufw
ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow "${SAMP_PORT}/udp"
ufw --force enable

# -------------------------
# Summary
# -------------------------
IP="$(hostname -I | awk '{print \$1}')"

echo ""
echo "======================================="
echo "  INSTALLATION TERMINÉE (Debian 12)"
echo "======================================="
echo "Web : http://${IP}"
echo "phpMyAdmin : http://${IP}/phpmyadmin"
echo "DB Root Pass : ${DB_ROOT_PASS}"
echo "SA:MP Directory : ${SAMP_DIR}"
echo "Start/Stop SA:MP : systemctl {start|stop} samp"
echo "======================================="
