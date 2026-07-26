# Development Guide

## Project Structure

```
.
├── lib/Homelab/
│   ├── API.pm              — Main Mojolicious app
│   ├── Database.pm         — PostgreSQL wrapper
│   ├── Auth.pm              — Auth business logic
│   ├── Drive.pm             — Drive (file storage) business logic
│   ├── RateLimit.pm         — Login rate limiting
│   └── Utils/
│       ├── JWT.pm          — JWT token handling
│       └── Password.pm     — Password verification
├── t/
│   ├── database.t          — Database tests
│   ├── auth.t               — Auth endpoint tests
│   ├── drive.t               — Drive endpoint tests
│   └── rate_limit.t          — Rate limiting tests
├── script/
│   └── homelab-api          — Startup script
├── debian/                 — Debian packaging
├── systemd/                — Systemd service unit
├── migrations/             — Database migrations
├── config/config.example.yml — Example configuration
├── Makefile.PL             — Build configuration
└── MANIFEST                — File manifest
```

## Running Locally

### Start Dev Server

```bash
export HOMELAB_API_CONFIG=$PWD/config.yml
morbo script/homelab-api
```

The app reloads automatically on code changes.

### Run Tests

```bash
# All tests
prove t/

# Specific test file
prove t/auth.t -v

# With coverage
cover -test
```

Most test files require `HOMELAB_API_CONFIG` to point at a real (ideally
disposable/test) Postgres database — they `plan skip_all` otherwise.

## Code Style

Follow **Perl Best Practices**:
- Use `strict` and `warnings`
- 4-space indentation
- Meaningful variable names
- Parameterized SQL queries (prevent injection)
- Error handling with `eval` or Carp

## Adding Features

### Add New Endpoint

1. **Add route in `lib/Homelab/API.pm`:**

```perl
post '/api/v1/auth/new-endpoint' => sub ($c) {
    # Handle request
    return _set_json_response($c, { success => 1 }, 200);
};
```

2. **Add business logic in `lib/Homelab/*.pm`:**

```perl
sub new_method {
    my ($self, $param) = @_;
    # Do work
    return { result => '...' };
}
```

3. **Add tests in `t/*.t`:**

```perl
subtest 'New endpoint' => sub {
    $t->post_ok('/api/v1/auth/new-endpoint', json => { ... })
        ->status_is(200);
};
```

4. **Update `API.md`** with the new endpoint's method/path/request/response.

### Add New Module

1. Create file in `lib/Homelab/`
2. Add to `MANIFEST`
3. Use `use` in dependent modules
4. Add tests

### Database Changes

1. Write migration SQL in `migrations/NNN-description.sql`
2. Test locally: `psql -h ... -f migrations/NNN-description.sql`
3. Add to `INSTALL.md`'s migration list

## Debugging

### Enable Debug Output

```bash
export PERL_DEBUG=1
morbo script/homelab-api
```

### Inspect Requests

In controller:

```perl
$c->app->log->debug("Request: " . $c->req->body);
my $json = $c->req->json;
$c->app->log->debug("Email: " . $json->{email});
```

### Test Manually

```bash
# Login
curl -X POST http://localhost:3000/api/v1/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"email":"user@example.com","password":"password"}' | jq

# Validate
curl -X GET http://localhost:3000/api/v1/auth/validate \
  -H 'Authorization: Bearer <TOKEN>' | jq
```

## Git Workflow

```bash
# Check status
git status

# Stage changes
git add lib/Homelab/Auth.pm t/auth.t

# Commit
git commit -m "Add new auth feature"

# View log
git log --oneline -n 10
```

## Packaging

### Build .deb

```bash
unset TMPDIR
dpkg-buildpackage -us -uc -b
```

### Test Package Installation

Install on a disposable scratch VM — never against a production database.

```bash
scp homelab-api_0.1.0_amd64.deb your-test-host:~
ssh your-test-host
sudo apt install ./homelab-api_0.1.0_amd64.deb
systemctl status homelab-api
curl http://localhost:3000/api/v1/health
```

## Dependencies

### Runtime

- `Mojolicious` — Web framework
- `DBD::Pg` — PostgreSQL driver
- `Crypt::JWT` — JWT tokens
- `Crypt::Argon2` — Password hashing
- `JSON::XS` — JSON parsing
- `DateTime` — Date/time
- `YAML::XS` — YAML config

### Build

- `ExtUtils::MakeMaker` — Build system
- `Test::Mojo` — Test framework
- `perl` >= 5.40

---

See [`README.md`](./README.md) for the project overview and [`API.md`](./API.md)
for the endpoint reference.
