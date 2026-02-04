#!/usr/bin/env bash
#
# Lobsters Production Setup Script
# Run on a fresh Ubuntu 24.04 LTS EC2 instance.
#
# Usage:
#   chmod +x deploy/setup.sh
#   sudo ./deploy/setup.sh
#
# Required environment variables (set before running or enter interactively):
#   LOBSTERS_DOMAIN     - Your domain name (or Elastic IP for initial setup)
#   LOBSTERS_SITE_NAME  - Display name of your site
#   LOBSTERS_DB_PASS    - Password for the lobsters MariaDB user
#   LOBSTERS_ADMIN_USER - Username for the first admin account
#   SMTP_HOST           - SES SMTP endpoint (e.g. email-smtp.us-east-1.amazonaws.com)
#   SMTP_PORT           - SES SMTP port (587)
#   SMTP_USERNAME       - SES SMTP username
#   SMTP_PASSWORD       - SES SMTP password
#   LOBSTERS_REPO       - Git repository URL (default: https://github.com/lobsters/lobsters.git)
#
set -euo pipefail

# ─── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ─── Root check ───────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || error "This script must be run as root (use sudo)"

# ─── Interactive prompts for missing variables ────────────────────────────────
prompt_var() {
  local var_name="$1" prompt_text="$2" default="${3:-}"
  if [[ -z "${!var_name:-}" ]]; then
    if [[ -n "$default" ]]; then
      read -rp "$prompt_text [$default]: " value
      export "$var_name"="${value:-$default}"
    else
      read -rp "$prompt_text: " value
      [[ -n "$value" ]] || error "$var_name is required"
      export "$var_name"="$value"
    fi
  fi
}

prompt_var LOBSTERS_DOMAIN     "Domain name (or Elastic IP if no domain yet)"
prompt_var LOBSTERS_SITE_NAME  "Site display name" "Lobsters"
prompt_var LOBSTERS_DB_PASS    "MariaDB password for lobsters user"
prompt_var LOBSTERS_ADMIN_USER "Admin username for the first account"
prompt_var SMTP_HOST           "SMTP host (e.g. email-smtp.us-east-1.amazonaws.com)" "127.0.0.1"
prompt_var SMTP_PORT           "SMTP port" "587"
prompt_var SMTP_USERNAME       "SMTP username (leave blank to skip)" ""
prompt_var SMTP_PASSWORD       "SMTP password (leave blank to skip)" ""
prompt_var LOBSTERS_REPO       "Git repository URL" "https://github.com/lobsters/lobsters.git"

APP_DIR="/srv/lobsters"
RUBY_VERSION="4.0.0"
DEPLOY_USER="lobsters"

# Detect whether LOBSTERS_DOMAIN looks like an IP address
IS_IP=false
if [[ "$LOBSTERS_DOMAIN" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  IS_IP=true
  warn "Domain looks like an IP address — SSL will be disabled, Caddy will serve plain HTTP."
fi

# ─── Phase 1: System dependencies ────────────────────────────────────────────
info "Phase 1: Installing system dependencies..."

export DEBIAN_FRONTEND=noninteractive

apt-get update -qq
apt-get upgrade -y -qq

# Ruby build dependencies + runtime deps
apt-get install -y -qq \
  autoconf bison build-essential libssl-dev libyaml-dev libreadline-dev \
  zlib1g-dev libncurses5-dev libffi-dev libgdbm-dev rustc \
  libjemalloc-dev libvips-dev \
  git curl wget unzip \
  apt-transport-https ca-certificates gnupg lsb-release

# MariaDB 11
info "Installing MariaDB..."
curl -sS https://downloads.mariadb.com/MariaDB/mariadb_repo_setup | bash -s -- --mariadb-server-version=mariadb-11.4
apt-get update -qq
apt-get install -y -qq mariadb-server mariadb-client libmariadb-dev

systemctl enable mariadb
systemctl start mariadb

# Caddy
info "Installing Caddy..."
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
apt-get update -qq
apt-get install -y -qq caddy

# ─── Create deploy user ──────────────────────────────────────────────────────
info "Creating $DEPLOY_USER system user..."
if ! id "$DEPLOY_USER" &>/dev/null; then
  useradd --system --create-home --shell /bin/bash "$DEPLOY_USER"
fi

# ─── Phase 1b: Install rbenv + Ruby ──────────────────────────────────────────
info "Installing rbenv and Ruby $RUBY_VERSION (this will take a while)..."

sudo -u "$DEPLOY_USER" bash <<'RBENV_SCRIPT'
set -euo pipefail

# Install rbenv
if [[ ! -d "$HOME/.rbenv" ]]; then
  git clone https://github.com/rbenv/rbenv.git "$HOME/.rbenv"
fi

# Add rbenv to PATH for this script
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
eval "$(rbenv init - bash)"

# Install ruby-build plugin
if [[ ! -d "$HOME/.rbenv/plugins/ruby-build" ]]; then
  git clone https://github.com/rbenv/ruby-build.git "$HOME/.rbenv/plugins/ruby-build"
fi

# Install Ruby if not already installed
if ! rbenv versions --bare | grep -qx "$RUBY_VERSION"; then
  RUBY_CONFIGURE_OPTS="--with-jemalloc" rbenv install "$RUBY_VERSION"
fi

rbenv global "$RUBY_VERSION"
gem install bundler --no-document
RBENV_SCRIPT

# Add rbenv to the deploy user's shell profile
sudo -u "$DEPLOY_USER" bash -c 'cat >> "$HOME/.bashrc" <<PROFILE

# rbenv
export PATH="\$HOME/.rbenv/bin:\$PATH"
eval "\$(rbenv init - bash)"
PROFILE'

# ─── Phase 2: MariaDB setup ──────────────────────────────────────────────────
info "Phase 2: Configuring MariaDB..."

mariadb -u root <<DBSQL
CREATE DATABASE IF NOT EXISTS lobsters CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER IF NOT EXISTS 'lobsters'@'localhost' IDENTIFIED BY '${LOBSTERS_DB_PASS}';
GRANT ALL PRIVILEGES ON lobsters.* TO 'lobsters'@'localhost';
FLUSH PRIVILEGES;
DBSQL

info "MariaDB database and user created."

# ─── Phase 3: Application setup ──────────────────────────────────────────────
info "Phase 3: Setting up application..."

mkdir -p "$APP_DIR"
chown "$DEPLOY_USER":"$DEPLOY_USER" "$APP_DIR"

# Clone repo
if [[ ! -d "$APP_DIR/.git" ]]; then
  sudo -u "$DEPLOY_USER" git clone "$LOBSTERS_REPO" "$APP_DIR"
else
  info "Repository already cloned, pulling latest..."
  sudo -u "$DEPLOY_USER" git -C "$APP_DIR" pull
fi

# Create storage directory for SQLite cache/queue databases
sudo -u "$DEPLOY_USER" mkdir -p "$APP_DIR/storage"
sudo -u "$DEPLOY_USER" mkdir -p "$APP_DIR/log"
sudo -u "$DEPLOY_USER" mkdir -p "$APP_DIR/tmp/pids"
sudo -u "$DEPLOY_USER" mkdir -p "$APP_DIR/public/cache"

# Configure database.yml — add production credentials
sudo -u "$DEPLOY_USER" bash -c "cat > '$APP_DIR/config/database.yml'" <<DBCONFIG
---
trilogy: &trilogy
  adapter: trilogy
  encoding: utf8mb4
  host: 127.0.0.1
  port: 3306
  pool: 5

sqlite3: &sqlite3
  adapter: sqlite3
  timeout: 1000

development:
  primary:
    <<: *trilogy
    database: lobsters_development
    username: root
    password: localdev
  cache:
    <<: *sqlite3
    database: db/development/cache.sqlite3
    migrations_paths: db/development/cache_migrate
  queue:
    <<: *sqlite3
    database: db/development/queue.sqlite3
    migrations_paths: db/development/queue_migrate

test:
  primary:
    <<: *trilogy
    database: lobsters_test
    username: root
    password: localdev
  cache:
    <<: *sqlite3
    database: db/test/cache.sqlite3
    migrations_paths: db/test/cache_migrate
  queue:
    <<: *sqlite3
    database: db/test/queue.sqlite3
    migrations_paths: db/test/queue_migrate

production:
  primary:
    <<: *trilogy
    database: lobsters
    username: lobsters
    password: ${LOBSTERS_DB_PASS}
  cache:
    <<: *sqlite3
    database: storage/cache.sqlite3
    migrations_paths: db/cache_migrate
  queue:
    <<: *sqlite3
    database: storage/queue.sqlite3
    migrations_paths: db/queue_migrate
DBCONFIG

# Bundle install
info "Running bundle install..."
sudo -u "$DEPLOY_USER" bash -c "
  export PATH=\"\$HOME/.rbenv/bin:\$HOME/.rbenv/shims:\$PATH\"
  eval \"\$(rbenv init - bash)\"
  cd '$APP_DIR'
  bundle config set --local without 'development test'
  bundle install
"

# Generate Rails master key and credentials
info "Setting up Rails credentials..."
RAILS_MASTER_KEY=""
if [[ ! -f "$APP_DIR/config/master.key" ]]; then
  sudo -u "$DEPLOY_USER" bash -c "
    export PATH=\"\$HOME/.rbenv/bin:\$HOME/.rbenv/shims:\$PATH\"
    eval \"\$(rbenv init - bash)\"
    cd '$APP_DIR'
    RAILS_ENV=production EDITOR='cat' bin/rails credentials:edit 2>/dev/null || true
  "
fi
RAILS_MASTER_KEY=$(cat "$APP_DIR/config/master.key")
info "Master key: $RAILS_MASTER_KEY (save this somewhere safe!)"

# ─── Phase 4: Configuration ──────────────────────────────────────────────────
info "Phase 4: Applying configuration..."

# Update config/application.rb — domain, name, ssl
cd "$APP_DIR"

# Patch domain
sudo -u "$DEPLOY_USER" sed -i "s|\"lobste.rs\"|\"${LOBSTERS_DOMAIN}\"|" config/application.rb

# Patch site name
sudo -u "$DEPLOY_USER" sed -i "s|\"Lobsters\"|\"${LOBSTERS_SITE_NAME}\"|" config/application.rb

# If using IP address, disable SSL
if [[ "$IS_IP" = true ]]; then
  # Set ssl? to false
  sudo -u "$DEPLOY_USER" sed -i '/def ssl?/,/end/{s/true/false/}' config/application.rb
  # Set force_ssl to false in production.rb
  sudo -u "$DEPLOY_USER" sed -i 's/config.force_ssl = true/config.force_ssl = false/' config/environments/production.rb
  # Disable assume_ssl
  sudo -u "$DEPLOY_USER" sed -i 's/config.assume_ssl = true/config.assume_ssl = false/' config/environments/production.rb
fi

# Update puma.rb pidfile for our deployment path
sudo -u "$DEPLOY_USER" sed -i "s|/home/deploy/lobsters/shared/tmp/pids/puma.pid|${APP_DIR}/tmp/pids/puma.pid|" config/puma.rb

# Create .env file
cat > "$APP_DIR/.env" <<ENVFILE
RAILS_ENV=production
RAILS_MASTER_KEY=${RAILS_MASTER_KEY}
RAILS_SERVE_STATIC_FILES=true
SOLID_QUEUE_IN_PUMA=true
SMTP_HOST=${SMTP_HOST}
SMTP_PORT=${SMTP_PORT}
SMTP_USERNAME=${SMTP_USERNAME}
SMTP_PASSWORD=${SMTP_PASSWORD}
SMTP_STARTTLS_AUTO=true
BANNED_DOMAINS_ADMIN=${LOBSTERS_ADMIN_USER}
ENVFILE
chown "$DEPLOY_USER":"$DEPLOY_USER" "$APP_DIR/.env"
chmod 600 "$APP_DIR/.env"

# ─── Run db:setup and assets:precompile ───────────────────────────────────────
info "Running database setup and asset precompilation..."
sudo -u "$DEPLOY_USER" bash -c "
  export PATH=\"\$HOME/.rbenv/bin:\$HOME/.rbenv/shims:\$PATH\"
  eval \"\$(rbenv init - bash)\"
  cd '$APP_DIR'
  set -a; source .env; set +a
  bin/rails db:setup
  bin/rails assets:precompile
"

# ─── Phase 5: Systemd service ────────────────────────────────────────────────
info "Phase 5: Creating systemd service..."

cat > /etc/systemd/system/lobsters.service <<UNIT
[Unit]
Description=Lobsters (Puma)
After=network.target mariadb.service
Requires=mariadb.service

[Service]
Type=simple
User=${DEPLOY_USER}
Group=${DEPLOY_USER}
WorkingDirectory=${APP_DIR}
EnvironmentFile=${APP_DIR}/.env
ExecStart=/home/${DEPLOY_USER}/.rbenv/shims/bundle exec puma -C config/puma.rb
Restart=on-failure
RestartSec=5
SyslogIdentifier=lobsters

# Hardening
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable lobsters
systemctl start lobsters

info "Lobsters service started."

# ─── Phase 6: Caddy reverse proxy ────────────────────────────────────────────
info "Phase 6: Configuring Caddy..."

if [[ "$IS_IP" = true ]]; then
  # HTTP-only for bare IP
  cat > /etc/caddy/Caddyfile <<CADDYFILE
:80 {
    reverse_proxy localhost:3000

    header {
        X-Content-Type-Options "nosniff"
        X-Frame-Options "SAMEORIGIN"
        Referrer-Policy "strict-origin-when-cross-origin"
    }

    log {
        output file /var/log/caddy/access.log
    }
}
CADDYFILE
else
  # Auto-HTTPS with domain
  cat > /etc/caddy/Caddyfile <<CADDYFILE
${LOBSTERS_DOMAIN} {
    reverse_proxy localhost:3000

    header {
        Strict-Transport-Security "max-age=63072000; includeSubDomains; preload"
        X-Content-Type-Options "nosniff"
        X-Frame-Options "SAMEORIGIN"
        Referrer-Policy "strict-origin-when-cross-origin"
    }

    log {
        output file /var/log/caddy/access.log
    }
}
CADDYFILE
fi

mkdir -p /var/log/caddy
systemctl restart caddy
systemctl enable caddy

info "Caddy configured and running."

# ─── Phase 7: Page cache cron ────────────────────────────────────────────────
info "Phase 7: Setting up page cache expiration cron..."

cat > /etc/cron.d/lobsters-cache <<CRON
# Expire cached pages older than 5 minutes
* * * * * ${DEPLOY_USER} find ${APP_DIR}/public/cache/ -type f -not -mmin 5 -delete 2>/dev/null
CRON
chmod 644 /etc/cron.d/lobsters-cache

info "Cache expiration cron installed."

# ─── Phase 8: Create admin user ──────────────────────────────────────────────
info "Phase 8: Creating admin user '${LOBSTERS_ADMIN_USER}'..."

sudo -u "$DEPLOY_USER" bash -c "
  export PATH=\"\$HOME/.rbenv/bin:\$HOME/.rbenv/shims:\$PATH\"
  eval \"\$(rbenv init - bash)\"
  cd '$APP_DIR'
  set -a; source .env; set +a
  bin/rails runner \"
    u = User.new
    u.username = '${LOBSTERS_ADMIN_USER}'
    u.email = '${LOBSTERS_ADMIN_USER}@${LOBSTERS_DOMAIN}'
    u.password = 'changeme123'
    u.password_confirmation = 'changeme123'
    u.is_admin = true
    u.is_moderator = true
    u.save!
    puts 'Admin user created: ${LOBSTERS_ADMIN_USER} / changeme123'
  \"
"

# ─── Done ─────────────────────────────────────────────────────────────────────
echo ""
info "============================================"
info "  Lobsters deployment complete!"
info "============================================"
echo ""
if [[ "$IS_IP" = true ]]; then
  info "Visit: http://${LOBSTERS_DOMAIN}"
else
  info "Visit: https://${LOBSTERS_DOMAIN}"
fi
echo ""
info "Admin login: ${LOBSTERS_ADMIN_USER} / changeme123"
warn "CHANGE THE ADMIN PASSWORD IMMEDIATELY after first login!"
echo ""
info "Master key (save this!): ${RAILS_MASTER_KEY}"
echo ""
info "Useful commands:"
info "  systemctl status lobsters    — check Puma status"
info "  journalctl -u lobsters -f    — follow application logs"
info "  systemctl status caddy       — check Caddy status"
info "  sudo -u lobsters -i          — switch to the lobsters user"
echo ""
