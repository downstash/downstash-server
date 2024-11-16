#!/bin/bash

# System dependencies
apt update
apt install -y make pkg-config gcc libjemalloc-dev certbot libssl-dev

# Install Valkey
git clone https://github.com/valkey-io/valkey.git
cd valkey
git checkout 8.0
make BUILD_TLS=yes

# Store current build directory (using absolute path)
INSTALL_DIR=$(realpath .)

# System configuration
echo "vm.overcommit_memory=1" >> /etc/sysctl.conf
sysctl vm.overcommit_memory=1

# Generate secure password and save it
REDIS_PASSWORD=$(openssl rand -hex 64)
echo "${REDIS_PASSWORD}" > ${INSTALL_DIR}/.redis_password
chmod 600 ${INSTALL_DIR}/.redis_password

# SSL certificate
certbot certonly --standalone \
  --non-interactive \
  --agree-tos \
  --register-unsafely-without-email \
  -d $(hostname).internal.downstash.com

# Create and configure log file
touch ${INSTALL_DIR}/valkey.log
chmod 640 ${INSTALL_DIR}/valkey.log

# Create configuration file
cat > ${INSTALL_DIR}/valkey.conf << EOF
port 0
tls-port 6379
tls-cert-file /etc/letsencrypt/live/$(hostname).internal.downstash.com/fullchain.pem
tls-key-file /etc/letsencrypt/live/$(hostname).internal.downstash.com/privkey.pem
tls-ca-cert-file /etc/letsencrypt/live/$(hostname).internal.downstash.com/chain.pem
tls-protocols "TLSv1.2 TLSv1.3"
protected-mode yes
daemonize yes
logfile ${INSTALL_DIR}/valkey.log
requirepass ${REDIS_PASSWORD}
EOF

# Create systemd service
cat > /etc/systemd/system/valkey.service << EOF
[Unit]
Description=Valkey Server
After=network.target

[Service]
Type=forking
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/src/valkey-server ${INSTALL_DIR}/valkey.conf
PIDFile=${INSTALL_DIR}/valkey.pid
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd and start Valkey
systemctl daemon-reload
systemctl enable valkey
systemctl start valkey

# Set up certbot renewal hook to restart Valkey when certificate renews
mkdir -p /etc/letsencrypt/renewal-hooks/post
cat > /etc/letsencrypt/renewal-hooks/post/valkey-reload << EOF
#!/bin/bash
systemctl restart valkey
EOF
chmod +x /etc/letsencrypt/renewal-hooks/post/valkey-reload

# Print password location
echo "Redis password has been stored in ${INSTALL_DIR}/.redis_password"
