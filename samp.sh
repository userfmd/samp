#!/usr/bin/env bash
set -euo pipefail

# =========================
#   CONFIG (MODIFIABLE)
# =========================
SAMP_DIR="/home/samp"
SAMP_USER="samp"
SAMP_PORT="7777"

DB_ROOT_PASS="root"
PMA_BLOWFISH_SECRET="$(openssl rand -base64 32 | tr -d '\n' | cut -c1-32)"

# SA:MP 0.3.7 R2-1 (souvent utilisé pour 0.3DL aussi côté serveur)
# Si tu as un lien exact 0.3DL server pack, remplace ici.
SAMP_TGZ_URL="https://files.sa-mp.com/samp037svr_R2-1.tar.gz"

# phpMyAdmin version (stable)
PMA_VERSION="5.2.1"

# =========================
#   HELPERS
# =========================
log() { echo -e "\n\033[1;32m[+]\033[0m $*"; }
warn() { echo -e "\n\033[1;33m[!]\033[0m $*"; }
die() { echo -e "\n\033[1;31m[✗]\033[0m $*"; exit 1; }

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Lance ce script en root : sudo bash setup.sh"
  fi
}

# =========================
#   START
# =========================
require_root

log "Mise à jour APT + packages de base"
apt update -y
apt install -y curl wget unzip tar ca-certificates gnupg2 lsb-release apt-transport-https \
  software-properties-common openssl

# -------------------------
# Apache
# -------------------------
log "Installation Apache2"
apt install -y apache2
systemctl enable --now apache2

# -------------------------
# MariaDB (mysql-server equivalent)
# -------------------------
log "Installation MariaDB (SQL server)"
apt install -y mariadb-server
systemctl enable --now mariadb

log "Sécurisation root MariaDB (mot de passe) + auth native"
mariadb -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASS}'; FLUSH PRIVILEGES;" || true

# -------------------------
# PHP 7.4 via Sury (Debian 12)
# -------------------------
log "Ajout dépôt Sury (PHP 7.4) pour Debian 12"
# clé + repo
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://packages.sury.org/php/apt.gpg | gpg --dearmor -o /etc/apt/keyrings/sury-php.gpg

echo "deb [signed-by=/etc/apt/keyrings/sury-php.gpg] https://packages.sury.org/php/ $(lsb_release -sc) main" \
  > /etc/apt/sources.list.d/sury-php.list

apt update -y

log "Installation PHP 7.4 + modules Apache"
apt install -y php7.4 libapache2-mod-php7.4 \
  php7.4-cli php7.4-common php7.4-mbstring php7.4-xml php7.4-zip php7.4-curl php7.4-gd php7.4-mysql

# Désactiver PHP 8.2 si chargé / activer PHP 7.4
log "Activation module PHP 7.4 sur Apache"
a2dismod php8.2 >/dev/null 2>&1 || true
a2enmod php7.4 rewrite headers
systemctl restart apache2

# -------------------------
# phpMyAdmin (archive officielle)
# -------------------------
log "Installation phpMyAdmin (archive officielle) v${PMA_VERSION}"
PMA_DIR="/usr/share/phpmyadmin"
if [[ ! -d "${PMA_DIR}" ]]; then
  cd /tmp
  wget -q "https://files.phpmyadmin.net/phpMyAdmin/${PMA_VERSION}/phpMyAdmin-${PMA_VERSION}-all-languages.zip" -O pma.zip
  unzip -q pma.zip
  mv "phpMyAdmin-${PMA_VERSION}-all-languages" "${PMA_DIR}"
  rm -f pma.zip
else
  warn "phpMyAdmin déjà présent : ${PMA_DIR}"
fi

log "Création config phpMyAdmin"
install -d -m 0755 /var/lib/phpmyadmin/tmp
chown -R www-data:www-data /var/lib/phpmyadmin

PMA_CONFIG="${PMA_DIR}/config.inc.php"
if [[ ! -f "${PMA_CONFIG}" ]]; then
  cat > "${PMA_CONFIG}" <<EOF
<?php
\$cfg['blowfish_secret'] = '${PMA_BLOWFISH_SECRET}';
\$i = 0;
\$i++;
\$cfg['Servers'][\$i]['auth_type'] = 'cookie';
\$cfg['Servers'][\$i]['host'] = 'localhost';
\$cfg['Servers'][\$i]['compress'] = false;
\$cfg['Servers'][\$i]['AllowNoPassword'] = false;

\$cfg['TempDir'] = '/var/lib/phpmyadmin/tmp';
EOF
fi

log "Alias Apache pour /phpmyadmin"
PMA_APACHE_CONF="/etc/apache2/conf-available/phpmyadmin.conf"
cat > "${PMA_APACHE_CONF}" <<'EOF'
Alias /phpmyadmin /usr/share/phpmyadmin

<Directory /usr/share/phpmyadmin>
    Options SymLinksIfOwnerMatch
    DirectoryIndex index.php
    AllowOverride All
    Require all granted
</Directory>

# Bloquer dossiers sensibles
<Directory /usr/share/phpmyadmin/libraries>
    Require all denied
</Directory>
<Directory /usr/share/phpmyadmin/setup>
    Require all denied
</Directory>
EOF

a2enconf phpmyadmin
systemctl reload apache2

# -------------------------
# SA:MP user + installation
# -------------------------
log "Création utilisateur système SA:MP (${SAMP_USER})"
if ! id -u "${SAMP_USER}" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "${SAMP_USER}"
fi

log "Installation SA:MP dans ${SAMP_DIR}"
install -d -m 0755 "${SAMP_DIR}"
chown -R "${SAMP_USER}:${SAMP_USER}" "${SAMP_DIR}"

if [[ ! -f "${SAMP_DIR}/samp03svr" && ! -f "${SAMP_DIR}/samp03/samp03svr" ]]; then
  cd /tmp
  wget -q "${SAMP_TGZ_URL}" -O samp.tgz
  tar -xzf samp.tgz
  rm -f samp.tgz

  # selon archive: dossier samp03/
  if [[ -d "/tmp/samp03" ]]; then
    rm -rf "${SAMP_DIR:?}/"* || true
    mv /tmp/samp03/* "${SAMP_DIR}/"
  else
    die "Archive SA:MP inattendue (dossier /tmp/samp03 introuvable)."
  fi

  chown -R "${SAMP_USER}:${SAMP_USER}" "${SAMP_DIR}"
  chmod +x "${SAMP_DIR}/samp03svr" || true
else
  warn "SA:MP semble déjà installé dans ${SAMP_DIR}"
fi

# -------------------------
# systemd service SA:MP
# -------------------------
log "Création service systemd SA:MP"
SERVICE_FILE="/etc/systemd/system/samp.service"
cat > "${SERVICE_FILE}" <<EOF
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

# SA:MP port (optionnel: juste info)
Environment=SAMP_PORT=${SAMP_PORT}

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now samp

# -------------------------
# Firewall (UFW)
# -------------------------
log "Firewall UFW (80/443 + ${SAMP_PORT}/udp + SSH)"
apt install -y ufw
ufw allow OpenSSH || true
ufw allow 80/tcp || true
ufw allow 443/tcp || true
ufw allow "${SAMP_PORT}/udp" || true
ufw --force enable || true

# -------------------------
# Résumé
# -------------------------
IP="$(hostname -I | awk '{print $1}')"

clear
echo "==============================================="
echo " ✅ INSTALLATION TERMINÉE (Debian 12)"
echo "==============================================="
echo ""
echo "🌐 Apache         : http://${IP}"
echo "📊 phpMyAdmin     : http://${IP}/phpmyadmin"
echo "🛢 SQL root user  : root"
echo "🔐 SQL root pass  : ${DB_ROOT_PASS}"
echo ""
echo "🎮 SA:MP dossier  : ${SAMP_DIR}"
echo "🚀 Service SA:MP  : systemctl status samp"
echo "🔁 Restart SA:MP  : systemctl restart samp"
echo ""
echo "Ports ouverts     : 22/tcp 80/tcp 443/tcp ${SAMP_PORT}/udp"
echo "==============================================="
