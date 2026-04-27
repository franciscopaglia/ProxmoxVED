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

# Write config.yml directly to avoid fragile sed surgery on the example file
cat > /opt/invidious/config/config.yml << YMLEOF
database_url: postgres://${PG_DB_USER}:${PG_DB_PASS}@localhost:5432/${PG_DB_NAME}
check_tables: true

invidious_companion:
  - private_url: "http://127.0.0.1:8282/companion"

invidious_companion_key: "${SECRET_KEY}"

hmac_key: "${HMAC_KEY}"

port: 3000
host_binding: 0.0.0.0
YMLEOF

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

# Find the actual companion binary (tarball may extract to a subdirectory)
COMPANION_BIN=$(find /opt/invidious-companion -name "invidious_companion" -type f | head -1)
COMPANION_DIR=$(dirname "$COMPANION_BIN")

# Write companion service from scratch — avoids upstream service issues with
# PrivateTmp/namespace directives that break inside LXC containers
cat > /etc/systemd/system/invidious-companion.service << SVCEOF
[Unit]
Description=invidious-companion (companion for Invidious which handles all the video stream retrieval from YouTube servers)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${COMPANION_DIR}
ExecStart=${COMPANION_BIN}
Environment=SERVER_SECRET_KEY=${SECRET_KEY}
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl -q daemon-reload
systemctl -q enable --now invidious invidious-companion
msg_ok "Configured services"

motd_ssh
customize
cleanup_lxc
