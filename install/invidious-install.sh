#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: vhsdream
# License: MIT | https://github.com/community-scripts/ProxmoxVED/raw/main/LICENSE
# Source: https://github.com/iv-org/invidious

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

msg_info "Installing Dependencies"
$STD apt install -y \
  build-essential \
  git \
  libssl-dev \
  libxml2-dev \
  libyaml-dev \
  libgmp-dev \
  libreadline-dev \
  librsvg2-bin \
  libsqlite3-dev \
  zlib1g-dev \
  libpcre2-dev \
  libevent-dev \
  fonts-open-sans
msg_ok "Installed Dependencies"

setup_deb822_repo "crystal" "https://download.opensuse.org/repositories/devel:/languages:/crystal/Debian_13/Release.key" "https://download.opensuse.org/repositories/devel:/languages:/crystal/Debian_13/" "./"
$STD apt install -y crystal

PG_VERSION="17" setup_postgresql
PG_DB_NAME="invidious" PG_DB_USER="invidious" setup_postgresql_db
fetch_and_deploy_gh_release "Invidious" "iv-org/invidious" "tarball" "latest" "/opt/invidious"
fetch_and_deploy_gh_release "Invidious Companion" "iv-org/invidious-companion" "prebuild" "latest" "/opt/invidious-companion" "invidious_companion-x86_64-unknown-linux-gnu.tar.gz"

msg_info "Patching git macros for tarball build"
perl -i -pe 's|\{\{\s*"#\{`git [^`]+`\.strip\}"\s*\}\}|"tarball"|g' /opt/invidious/src/invidious.cr
msg_ok "Patched git macros"

msg_info "Building Invidious"
cd /opt/invidious
$STD make
msg_ok "Built Invidious"

msg_info "Configuring Invidious"
SECRET_KEY="$(openssl rand -hex 8)"   # exactly 16 chars
HMAC_KEY="$(openssl rand -hex 32)"

# Build config.yml from the example, substituting all required values.
# The config.example.yml uses a YAML 'db:' block for the database connection
# which we replace with the flat 'database_url:' form instead.
# companion private_url uses port 11000 (invidious-companion default).
cp /opt/invidious/config/config.example.yml /opt/invidious/config/config.yml

# Remove the legacy db: block (lines from 'db:' through 'port: 5432')
sed -i '/^db:/,/^  port: 5432/d' /opt/invidious/config/config.yml

# Inject database_url after the check_tables line
sed -i "s|^#database_url:.*|database_url: postgres://${PG_DB_USER}:${PG_DB_PASS}@localhost:5432/${PG_DB_NAME}|" \
  /opt/invidious/config/config.yml

# Enable check_tables
sed -i 's|^#check_tables:.*|check_tables: true|' /opt/invidious/config/config.yml

# Uncomment invidious_companion block and set private_url
sed -i 's|^#invidious_companion:|invidious_companion:|' /opt/invidious/config/config.yml
sed -i 's|^# - private_url:.*\|^#  - private_url:.*|  - private_url: "http://127.0.0.1:11000/companion"|' \
  /opt/invidious/config/config.yml

# Use perl for the companion private_url line since sed alternation is unreliable across platforms
perl -i -pe 's|^#\s*- private_url:.*|  - private_url: "http://127.0.0.1:11000/companion"|' \
  /opt/invidious/config/config.yml

# Set companion key (must be exactly 16 chars)
sed -i "s|^#invidious_companion_key:.*|invidious_companion_key: \"${SECRET_KEY}\"|" \
  /opt/invidious/config/config.yml

# Set HMAC key (mandatory)
sed -i "s|^hmac_key:.*|hmac_key: \"${HMAC_KEY}\"|" /opt/invidious/config/config.yml

chmod 600 /opt/invidious/config/config.yml

cat <<EOF >/etc/logrotate.d/invidious.logrotate
rotate 4
weekly
notifempty
missingok
compress
minsize 1048576
EOF
chmod 0644 /etc/logrotate.d/invidious.logrotate
msg_ok "Configured Invidious"

msg_info "Migrating database"
cd /opt/invidious
$STD ./invidious --migrate
msg_ok "Migrated database"

msg_info "Configuring services"
# invidious.service ships with /home/invidious/invidious paths — rewrite to /opt/invidious
sed -e 's|User=invidious|User=root|' \
    -e 's|Group=invidious|Group=root|' \
    -e 's|/home/invidious/invidious|/opt/invidious|g' \
  /opt/invidious/invidious.service >/etc/systemd/system/invidious.service

# companion service uses SERVER_SECRET_KEY=CHANGE_ME and User/WorkingDirectory paths
curl -fsSL https://github.com/iv-org/invidious-companion/raw/refs/heads/master/invidious-companion.service \
  -o /etc/systemd/system/invidious-companion.service
sed -i \
  -e "s|CHANGE_ME|${SECRET_KEY}|g" \
  -e 's|User=invidious|User=root|' \
  -e 's|Group=invidious|Group=root|' \
  -e 's|/home/invidious|/opt|g' \
  /etc/systemd/system/invidious-companion.service

systemctl -q daemon-reload
systemctl -q enable --now invidious invidious-companion
msg_ok "Configured services"

motd_ssh
customize
cleanup_lxc
