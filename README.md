# Homelab API

Unified REST API backend for a self-hosted "homelab" service ecosystem: authentication,
file storage (Drive), and future messaging/social features, all backed by a shared
Dovecot/PostgreSQL user directory.

This repository contains three components:

- **`homelab-api`** (repo root) — the REST API (auth + Drive), a Mojolicious app.
- **`drive-web-ui/`** — `homelab-drive-web-ui`, a browser-based front end (BFF) for Drive.
- **`processor/`** — `homelab-api-backend-processor`, a background daemon that handles
  out-of-band file tasks (checksums, thumbnails, zips, deletes) queued by the API.

## Quick Start

### Development

```bash
# Install dependencies
cpanm Mojolicious DBD::Pg Crypt::JWT Crypt::Argon2 JSON::XS DateTime YAML::XS

# Start dev server (auto-reload on changes)
cp config/config.example.yml config.yml   # edit with your DB credentials
export HOMELAB_API_CONFIG=$PWD/config.yml
morbo script/homelab-api

# Server runs at http://localhost:3000
```

### Running Tests

```bash
export HOMELAB_API_CONFIG=/etc/homelab/api/config.yml
prove t/
```

## Project Structure

- `lib/Homelab/` — Core modules
  - `API.pm` — Mojolicious app and routes
  - `Database.pm` — PostgreSQL connection
  - `Auth.pm` — Authentication logic
  - `Drive.pm` — File storage business logic
  - `RateLimit.pm` — Login rate limiting
  - `Utils/` — Utility modules (JWT, Password)
- `t/` — Test suite
- `script/` — Startup scripts
- `debian/` — Debian package files
- `config/config.example.yml` — Example configuration
- `drive-web-ui/` — Web UI package (separate Perl distribution)
- `processor/` — Background task processor package (separate Debian package)

## API Endpoints

See [`API.md`](./API.md) for the full REST endpoint reference.

## Installing

Packages are distributed as `.deb`s via an apt repository (reprepro). See
[`INSTALL.md`](./INSTALL.md) for distribution/build instructions and manual
installation steps.

```bash
sudo apt install ./homelab-api_0.1.0_amd64.deb
sudo apt install ./homelab-drive-web-ui_0.1.0_amd64.deb
sudo apt install ./homelab-api-backend-processor_0.1.0_amd64.deb
```

## Documentation

- [`INSTALL.md`](./INSTALL.md) — Installation and setup instructions
- [`API.md`](./API.md) — REST endpoint specifications
- [`DEVELOPMENT.md`](./DEVELOPMENT.md) — Dev workflow, testing, debugging

## License

Licensed under the [GNU Affero General Public License v3.0 or later](./LICENSE)
(AGPL-3.0-or-later).
