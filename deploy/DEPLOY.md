# Lobsters Production Deployment Guide

Deploy Lobsters on a single AWS EC2 instance with MariaDB, Caddy (auto-SSL), and AWS SES for email.

## Architecture

```
Internet → Caddy (ports 80/443) → Puma (localhost:3000) → MariaDB + SQLite
                                      ↕
                                  Solid Queue (in-process)
                                  Solid Cache (SQLite)
```

Single-server setup: Caddy handles TLS termination and reverse-proxies to Puma. MariaDB stores the primary data. SQLite handles the cache store (Solid Cache) and background job queue (Solid Queue, running inside Puma).

## Prerequisites

### 1. EC2 Instance

- **AMI**: Ubuntu 24.04 LTS
- **Instance type**: `t3.small` (2 vCPU, 2 GB RAM) — minimum recommended
- **Storage**: 20 GB+ EBS (gp3)
- **Security group**: Open ports **22** (SSH), **80** (HTTP), **443** (HTTPS)

### 2. Elastic IP

Attach an Elastic IP to the instance so the public IP survives stop/start cycles.

### 3. AWS SES (Email)

1. Go to **SES Console** → verify a sender email address or domain
2. **Create SMTP credentials** (SES generates an IAM user; save the username/password)
3. Note the SMTP endpoint for your region (e.g. `email-smtp.us-east-1.amazonaws.com`)
4. If still in the SES sandbox, request production access — sandbox only allows sending to verified addresses

### 4. Domain (optional, can do later)

Point an **A record** at the Elastic IP. Caddy will automatically obtain a Let's Encrypt certificate once DNS propagates.

If you don't have a domain yet, the script can run with just the IP address (HTTP only, no SSL).

## Running the Setup Script

SSH into the instance and run:

```bash
# Upload or clone the repo
git clone <repo name here>
cd lobsters

# Run the setup script
sudo ./deploy/setup.sh
```

The script prompts for these values interactively if not set as environment variables:

| Variable | Description | Example |
|---|---|---|
| `LOBSTERS_DOMAIN` | Your domain (or Elastic IP) | `news.example.com` or `54.123.45.67` |
| `LOBSTERS_SITE_NAME` | Display name for the site | `My News` |
| `LOBSTERS_DB_PASS` | MariaDB password for the lobsters user | (any strong password) |
| `LOBSTERS_ADMIN_USER` | Username for the first admin account | `admin` |
| `SMTP_HOST` | SES SMTP endpoint | `email-smtp.us-east-1.amazonaws.com` |
| `SMTP_PORT` | SMTP port | `587` |
| `SMTP_USERNAME` | SES SMTP username | (from SES credentials) |
| `SMTP_PASSWORD` | SES SMTP password | (from SES credentials) |

Or export them before running:

```bash
export LOBSTERS_DOMAIN="news.example.com"
export LOBSTERS_SITE_NAME="My News"
export LOBSTERS_DB_PASS="supersecretpassword"
export LOBSTERS_ADMIN_USER="admin"
export SMTP_HOST="email-smtp.us-east-1.amazonaws.com"
export SMTP_PORT="587"
export SMTP_USERNAME="AKIAIOSFODNN7EXAMPLE"
export SMTP_PASSWORD="wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
sudo -E ./deploy/setup.sh
```

## What the Script Does (Phase by Phase)

### Phase 1: System Dependencies

Installs everything needed to build Ruby and run the app:

- **Ruby build deps**: autoconf, bison, build-essential, libssl-dev, etc.
- **MariaDB 11.4**: from the official MariaDB repository (the `trilogy` gem speaks the MySQL protocol)
- **Caddy**: reverse proxy with automatic Let's Encrypt certificates
- **jemalloc**: memory allocator that reduces Ruby's memory fragmentation
- **libvips**: image processing library (used for avatar resizing)
- **rbenv + ruby-build**: installs Ruby 4.0.0 with jemalloc support

Ruby is installed under a dedicated `lobsters` system user via rbenv.

### Phase 2: MariaDB Setup

- Creates a `lobsters` database with `utf8mb4` encoding (full Unicode support including emoji)
- Creates a dedicated `lobsters` database user (not root) with only the permissions it needs

### Phase 3: Application Setup

- Clones the repo to `/srv/lobsters`
- Writes `config/database.yml` with the production MariaDB credentials
- Runs `bundle install --without development test`
- Generates Rails encrypted credentials (`config/credentials.yml.enc` + `config/master.key`)
- Creates `storage/` for the SQLite databases used by Solid Cache and Solid Queue
- Runs `rails db:setup` (creates tables) and `rails assets:precompile`

**Important**: The script prints the `RAILS_MASTER_KEY` — save it. You need it to decrypt credentials if you redeploy.

### Phase 4: Configuration Changes

The script patches these files:

**`config/application.rb`**:
- `domain` → your domain (used for URLs, emails, cookies)
- `name` → your site name
- `ssl?` → `false` if using an IP address (no cert possible)

**`config/environments/production.rb`** (IP-only mode):
- `force_ssl` → `false`
- `assume_ssl` → `false`

**`config/puma.rb`**:
- PID file path updated to `/srv/lobsters/tmp/pids/puma.pid`

**`/srv/lobsters/.env`**: Environment variables loaded by systemd:

```
RAILS_ENV=production
RAILS_MASTER_KEY=<key>
RAILS_SERVE_STATIC_FILES=true    # Puma serves assets (no separate nginx)
SOLID_QUEUE_IN_PUMA=true          # Background jobs run inside Puma
SMTP_HOST=...
SMTP_PORT=...
SMTP_USERNAME=...
SMTP_PASSWORD=...
SMTP_STARTTLS_AUTO=true
BANNED_DOMAINS_ADMIN=<admin_username>
```

### Phase 5: Systemd Service

Creates `/etc/systemd/system/lobsters.service` — a systemd unit that:

- Runs Puma as the `lobsters` user
- Loads environment from `/srv/lobsters/.env`
- Starts after MariaDB
- Restarts automatically on failure (5 second delay)

Useful commands:

```bash
systemctl status lobsters       # check if running
systemctl restart lobsters      # restart after config changes
journalctl -u lobsters -f       # follow live logs
journalctl -u lobsters --since "1 hour ago"  # recent logs
```

### Phase 6: Caddy Reverse Proxy

**With a domain**: Caddy automatically obtains a Let's Encrypt TLS certificate and serves HTTPS. HTTP requests redirect to HTTPS.

**With an IP address**: Caddy serves plain HTTP on port 80 (Let's Encrypt doesn't issue certs for IP addresses).

The Caddyfile also:
- Serves cached pages directly from disk for logged-out visitors (the `lobster_trap` cookie indicates a logged-in session)
- Adds security headers (HSTS, X-Content-Type-Options, X-Frame-Options)

### Phase 7: Page Cache Cron

Lobsters uses ActionPack page caching for logged-out visitors. A cron job runs every minute and deletes cached files older than 5 minutes:

```
* * * * * lobsters find /srv/lobsters/public/cache/ -type f -not -mmin 5 -delete
```

This keeps cached content fresh without requiring cache invalidation logic.

### Phase 8: Admin User

Creates the first admin user with:
- Username: whatever you specified
- Password: `changeme123`
- Admin + moderator privileges

**Change the password immediately after first login.**

## Post-Deployment

### Switching from IP to Domain

Once you have a domain and its A record points to the Elastic IP:

1. Update `config/application.rb`:
   ```ruby
   def domain
     "yournewdomain.com"
   end

   def ssl?
     true
   end
   ```

2. Update `config/environments/production.rb`:
   ```ruby
   config.force_ssl = true
   config.assume_ssl = true
   ```

3. Update `/etc/caddy/Caddyfile`:
   ```
   yournewdomain.com {
       reverse_proxy localhost:3000
       # ... (copy the full block from the script)
   }
   ```

4. Update `BANNED_DOMAINS_ADMIN` in `.env` if needed.

5. Restart services:
   ```bash
   systemctl restart lobsters
   systemctl restart caddy
   ```

Caddy will automatically obtain a Let's Encrypt certificate.

### Inviting Users

Lobsters uses an invitation-based system by default. Open signups are disabled to prevent spam. To invite users:

1. Log in as the admin user
2. Go to your profile → Invitations
3. Generate invitation links

Or temporarily enable open signups by adding `OPEN_SIGNUPS=true` to `.env` and restarting. Be careful — the codebase warns that it lacks antispam features for open signups.

### Setting Up Credentials (Optional Services)

Edit Rails credentials to configure optional integrations:

```bash
sudo -u lobsters -i
cd /srv/lobsters
RAILS_ENV=production EDITOR=nano bin/rails credentials:edit
```

Available credential keys (see `config/credentials.yml.enc.sample`):

```yaml
secret_key_base: "auto-generated"

diffbot:
  api_key: null          # link preview parsing

github:
  client_id: null        # OAuth login
  client_secret: null

mastodon:
  instance_name: null    # bot posting
  bot_name: null
  client_id: null
  client_secret: null
  token: null
  list_id: null

pushover:
  api_token: null        # push notifications
  subscription_code: null
```

### Backups

Back up these critical files:

- **MariaDB**: `mariadb-dump lobsters > backup.sql`
- **Master key**: `/srv/lobsters/config/master.key`
- **Credentials**: `/srv/lobsters/config/credentials.yml.enc`
- **Env file**: `/srv/lobsters/.env`
- **Uploaded avatars**: `/srv/lobsters/public/avatars/`

Example backup cron:

```bash
# /etc/cron.d/lobsters-backup
0 3 * * * lobsters mariadb-dump lobsters | gzip > /home/lobsters/backups/lobsters-$(date +\%Y\%m\%d).sql.gz
```

### Updating the Application

```bash
sudo -u lobsters -i
cd /srv/lobsters
git pull
bundle install
RAILS_ENV=production bin/rails db:migrate
RAILS_ENV=production bin/rails assets:precompile
exit
sudo systemctl restart lobsters
```

## Troubleshooting

### Puma won't start

```bash
journalctl -u lobsters -n 50    # check recent logs
sudo -u lobsters -i
cd /srv/lobsters
set -a; source .env; set +a
bundle exec puma -C config/puma.rb  # run manually to see errors
```

### Database connection errors

```bash
systemctl status mariadb           # is MariaDB running?
mariadb -u lobsters -p lobsters    # can you connect manually?
```

### Caddy certificate issues

```bash
systemctl status caddy
journalctl -u caddy -n 50
# Ensure port 80 is open (Let's Encrypt HTTP-01 challenge needs it)
# Ensure DNS A record points to this server's IP
```

### Asset errors (missing CSS/JS)

```bash
sudo -u lobsters -i
cd /srv/lobsters
set -a; source .env; set +a
bin/rails assets:precompile
exit
sudo systemctl restart lobsters
```

## File Reference

| File | Purpose |
|---|---|
| `/srv/lobsters/` | Application root |
| `/srv/lobsters/.env` | Environment variables (mode 600) |
| `/srv/lobsters/config/master.key` | Rails encryption key |
| `/srv/lobsters/config/database.yml` | Database config with production credentials |
| `/srv/lobsters/storage/` | SQLite databases for cache and queue |
| `/srv/lobsters/public/cache/` | Page cache for logged-out visitors |
| `/srv/lobsters/log/rails.log` | Application log |
| `/srv/lobsters/log/solid_queue.log` | Background job log |
| `/etc/systemd/system/lobsters.service` | Systemd unit |
| `/etc/caddy/Caddyfile` | Caddy reverse proxy config |
| `/etc/cron.d/lobsters-cache` | Page cache expiration cron |

## Verification Checklist

After deployment:

- [ ] `systemctl status lobsters` shows `active (running)`
- [ ] `systemctl status caddy` shows `active (running)`
- [ ] Homepage loads at `http://<ip>` or `https://<domain>`
- [ ] Can log in with the admin account
- [ ] Change the admin password
- [ ] Submit a test story and verify it appears
- [ ] Check `journalctl -u lobsters` for any errors
- [ ] Test email delivery (try password reset or invitation)
