#!/bin/bash
# =============================================================================
# EC2 user data: SonarQube Community Build + PostgreSQL (direct on port 9000)
# Target AMI : Ubuntu Server 26.04 LTS (Resolute Raccoon), x86_64 or arm64
# Instance   : t3.medium (4 GB RAM) minimum; t3.large recommended
# Access     : http://<EC2-public-IP>:9000  (open TCP 9000 in the Security Group)
# Log        : /var/log/user-data.log
# =============================================================================
set -euxo pipefail
exec > >(tee -a /var/log/user-data.log) 2>&1
export DEBIAN_FRONTEND=noninteractive

# ---------- Variables (change these) ----------------------------------------
SQ_VERSION="26.11.0.134175"          # latest Community Build, Nov 2026
SQ_HOME="/opt/sonarqube"
DB_NAME="sonarqube"
DB_USER="sonar"
DB_PASS="ChangeMe-$(openssl rand -hex 8)"   # or set your own / pull from SSM

# ---------- Kernel & limits (Elasticsearch requirements) --------------------
# Ubuntu 26.04 uses /etc/sysctl.d drop-ins; don't overwrite /etc/sysctl.conf
cat > /etc/sysctl.d/99-sonarqube.conf <<EOT
vm.max_map_count=524288
fs.file-max=131072
EOT
sysctl --system

cat > /etc/security/limits.d/99-sonarqube.conf <<EOT
sonarqube   -   nofile   131072
sonarqube   -   nproc    8192
EOT

# ---------- Packages --------------------------------------------------------
# Ubuntu 26.04 ships PostgreSQL 18 (supported by SonarQube 2026.x),
# so the PGDG repo / apt-key step is no longer needed.
apt-get update -y
apt-get install -y openjdk-21-jdk-headless postgresql postgresql-contrib \
                   unzip curl
java -version

# ---------- PostgreSQL ------------------------------------------------------
systemctl enable --now postgresql
sudo -u postgres psql -v ON_ERROR_STOP=1 <<EOSQL
CREATE ROLE ${DB_USER} WITH LOGIN ENCRYPTED PASSWORD '${DB_PASS}';
CREATE DATABASE ${DB_NAME} OWNER ${DB_USER};
GRANT ALL PRIVILEGES ON DATABASE ${DB_NAME} TO ${DB_USER};
EOSQL
ss -tlnp | grep postgres || true

# ---------- SonarQube -------------------------------------------------------
useradd --system --home-dir "${SQ_HOME}" --shell /usr/sbin/nologin sonarqube || true

cd /tmp
curl -fsSLO "https://binaries.sonarsource.com/Distribution/sonarqube/sonarqube-${SQ_VERSION}.zip"
unzip -q -o "sonarqube-${SQ_VERSION}.zip" -d /opt/
rm -rf "${SQ_HOME}"
mv "/opt/sonarqube-${SQ_VERSION}" "${SQ_HOME}"
rm -f "sonarqube-${SQ_VERSION}.zip"

cp "${SQ_HOME}/conf/sonar.properties" /root/sonar.properties_backup
cat > "${SQ_HOME}/conf/sonar.properties" <<EOT
sonar.jdbc.username=${DB_USER}
sonar.jdbc.password=${DB_PASS}
sonar.jdbc.url=jdbc:postgresql://localhost/${DB_NAME}
# Listen on all interfaces so it is reachable on port 9000
sonar.web.host=0.0.0.0
sonar.web.port=9000
sonar.search.javaOpts=-Xmx512m -Xms512m -XX:+HeapDumpOnOutOfMemoryError
sonar.log.level=INFO
sonar.path.logs=logs
EOT
chown -R sonarqube:sonarqube "${SQ_HOME}"
chmod 600 "${SQ_HOME}/conf/sonar.properties"

# Arch-independent unit (works on Graviton/arm64 as well as x86_64)
cat > /etc/systemd/system/sonarqube.service <<EOT
[Unit]
Description=SonarQube service
After=network-online.target postgresql.service
Wants=network-online.target
Requires=postgresql.service

[Service]
Type=simple
User=sonarqube
Group=sonarqube
WorkingDirectory=${SQ_HOME}
ExecStart=/usr/bin/java -Xms32m -Xmx32m -Djava.net.preferIPv4Stack=true -jar ${SQ_HOME}/lib/sonar-application-${SQ_VERSION}.jar
SuccessExitStatus=143
Restart=on-failure
RestartSec=10
LimitNOFILE=131072
LimitNPROC=8192
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
EOT

systemctl daemon-reload
systemctl enable --now sonarqube.service

# ---------- Firewall --------------------------------------------------------
# ufw is inactive on Ubuntu AMIs; the Security Group is the real control.
# Only 9000 (SonarQube web UI/API) needs to be open. Never expose 9001:
# that is Elasticsearch's internal port and it stays bound to 127.0.0.1.
if ufw status | grep -q "Status: active"; then
  ufw allow 22/tcp
  ufw allow 9000/tcp
fi

# ---------- Done ------------------------------------------------------------
echo "SonarQube DB password: ${DB_PASS}" > /root/sonarqube-credentials.txt
chmod 600 /root/sonarqube-credentials.txt
echo "SonarQube ${SQ_VERSION} installed. First start takes 1-3 minutes."
PUBLIC_IP=$(curl -s -H "X-aws-ec2-metadata-token: $(curl -s -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')" http://169.254.169.254/latest/meta-data/public-ipv4 || echo "<EC2-public-IP>")
echo "Browse to http://${PUBLIC_IP}:9000/  (default login admin / admin)"
