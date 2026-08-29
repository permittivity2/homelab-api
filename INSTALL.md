# Installation Guide

## Development Installation

### Prerequisites

```bash
sudo apt install perl cpanminus postgresql-client build-essential
```

### Install Perl Dependencies

```bash
cpanm Mojolicious DBD::Pg Crypt::JWT Crypt::Argon2 JSON::XS DateTime YAML::XS
```

### Configuration

Copy the example configuration:

```bash
cp config/config.example.yml config.yml
```

Edit `config.yml` with your database credentials:

```yaml
database:
  host: YOUR_DB_HOST
  port: 5432
  name: mailserver
  user: dovecot_user
  password: YOUR_DB_PASSWORD_HERE

jwt:
  secret: YOUR_SECRET_KEY_HERE_AT_LEAST_32_CHARS
```

### Database Setup

Create the refresh tokens table and Drive schema (run once):

```bash
psql -h YOUR_DB_HOST -U dovecot_user -d mailserver -f migrations/001-create-refresh-tokens.sql
psql -h YOUR_DB_HOST -U dovecot_user -d mailserver -f migrations/002-drive-schema.sql
psql -h YOUR_DB_HOST -U dovecot_user -d mailserver -f migrations/003-drive-tasks-schema.sql
psql -h YOUR_DB_HOST -U dovecot_user -d mailserver -f migrations/004-sharing-folders.sql
# ... 005 through 010 (rate limits, RBAC, mail permissions) ...
psql -h YOUR_DB_HOST -U dovecot_user -d mailserver -f migrations/011-backup-schema.sql
psql -h YOUR_DB_HOST -U dovecot_user -d mailserver -f migrations/012-create-user-support.sql
```

Migrations 011/012 must be applied **in that order** and before installing
`homelab-backup-server`/`homelab-backup-client` anywhere — those packages assume
`/api/v1/backup/*` and `POST /api/v1/admin/users` already exist. See
`migrations/011-backup-schema.sql`'s header comment for what it adds (the
`backup` schema/role, plus `/api/v1/backup/*` endpoint permissions) and
`migrations/012-create-user-support.sql`'s (the `create-user` admin endpoint's
supporting grant + the `api.role_grant_permissions` table).

### Start Development Server

```bash
export HOMELAB_API_CONFIG=$PWD/config.yml
morbo script/homelab-api
```

Server will start at `http://localhost:3000`.

---

## Production Installation (Debian Package)

### Build Package

```bash
cd homelab-api/   # your clone of this repository
unset TMPDIR      # avoid a dpkg-deb tmpfile bug if TMPDIR is set to a non-existent path
dpkg-buildpackage -us -uc -b
```

The `drive-web-ui/` and `processor/` subdirectories are each their own Debian
source package — build them the same way from within their own directory.

### Transfer to your server

```bash
scp homelab-api_0.1.0_amd64.deb your-server:~
```

### Install

```bash
ssh your-server
sudo apt install ./homelab-api_0.1.0_amd64.deb
```

Installing the package (via `apt install ./*.deb`) pulls in Perl module
dependencies automatically and creates the `homelab` system user/group,
`/etc/homelab/api/`, and `/var/lib/homelab/`.

### Edit Configuration

```bash
sudo vim /etc/homelab/api/config.yml
```

If you're also installing `homelab-api-backend-processor`, it has its own
independent config file — set the database credentials there too:

```bash
sudo vim /etc/homelab/processor/config.yml
```

### Create Database Schema

The `.sql` files under `migrations/` are not installed by the package — run them
directly from your git checkout against your production database:

```bash
psql -h YOUR_DB_HOST -U dovecot_user -d mailserver -f migrations/001-create-refresh-tokens.sql
psql -h YOUR_DB_HOST -U dovecot_user -d mailserver -f migrations/002-drive-schema.sql
psql -h YOUR_DB_HOST -U dovecot_user -d mailserver -f migrations/003-drive-tasks-schema.sql
psql -h YOUR_DB_HOST -U dovecot_user -d mailserver -f migrations/004-sharing-folders.sql
# ... 005 through 010 (rate limits, RBAC, mail permissions) ...
psql -h YOUR_DB_HOST -U dovecot_user -d mailserver -f migrations/011-backup-schema.sql
psql -h YOUR_DB_HOST -U dovecot_user -d mailserver -f migrations/012-create-user-support.sql
```

Migrations 011/012 must be applied **in that order** and before installing
`homelab-backup-server`/`homelab-backup-client` anywhere — those packages assume
`/api/v1/backup/*` and `POST /api/v1/admin/users` already exist. See
`migrations/011-backup-schema.sql`'s header comment for what it adds (the
`backup` schema/role, plus `/api/v1/backup/*` endpoint permissions) and
`migrations/012-create-user-support.sql`'s (the `create-user` admin endpoint's
supporting grant + the `api.role_grant_permissions` table).

### Start Service

```bash
sudo systemctl start homelab-api
sudo systemctl status homelab-api
```

---

## Testing

### Run Test Suite

```bash
export HOMELAB_API_CONFIG=$PWD/config.yml
prove t/
```

### Health Check

```bash
curl http://localhost:3000/api/v1/health
```

### Manual API Test

```bash
# Login
curl -X POST http://localhost:3000/api/v1/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"email":"user@example.com","password":"password"}'

# Validate token
curl -X GET http://localhost:3000/api/v1/auth/validate \
  -H 'Authorization: Bearer <JWT_TOKEN>'
```

---

See [`API.md`](./API.md) for the endpoint reference and [`DEVELOPMENT.md`](./DEVELOPMENT.md)
for the development workflow.
