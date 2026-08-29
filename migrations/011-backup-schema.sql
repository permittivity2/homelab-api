-- Migration 011: backup control-plane schema (hosts/repos/enrollment
-- requests/run history/server discovery) for homelab-backup-client/-server,
-- plus the new `backup` role and its endpoint permissions.
--
-- Lives in its own `backup` schema (not `api`, not the old borg-backup-
-- client's local `service_backup` schema) because, unlike the old design,
-- homelab-api's own `homelab_api` DB role owns and exclusively accesses
-- these tables now -- homelab-backup-server never connects to Postgres
-- directly.

CREATE SCHEMA IF NOT EXISTS backup;

CREATE TABLE IF NOT EXISTS backup.hosts (
    id            BIGSERIAL PRIMARY KEY,
    identifier    TEXT NOT NULL UNIQUE,   -- caller-supplied host identifier, NOT derived from JWT/email
    hostname      TEXT NOT NULL,
    pubkey        TEXT NOT NULL,          -- currently-active enrolled pubkey
    status        TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'revoked')),
    first_seen_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_seen_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Pending-reconciliation queue: homelab-backup-client submits 'enroll' rows
-- via POST /api/v1/backup/enroll; an admin-initiated revoke submits
-- 'revoke' rows via POST /api/v1/backup/hosts/:identifier/revoke.
-- homelab-backup-server polls status='pending' periodically, materializes/
-- removes the authorized_keys line locally, then acks each one.
CREATE TABLE IF NOT EXISTS backup.enrollment_requests (
    id           BIGSERIAL PRIMARY KEY,
    identifier   TEXT NOT NULL,
    hostname     TEXT NOT NULL,
    pubkey       TEXT NOT NULL,
    action       TEXT NOT NULL CHECK (action IN ('enroll', 'revoke')),
    status       TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'acked')),
    requested_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    acked_at     TIMESTAMPTZ
);
-- A retried/duplicate submit for the same (identifier, pubkey, action) while
-- one is still pending should not create a second row -- INSERT ... ON
-- CONFLICT DO NOTHING against this partial unique index makes enroll()
-- idempotent without a pre-check SELECT+INSERT race.
CREATE UNIQUE INDEX IF NOT EXISTS backup_enrollment_requests_pending_uniq
    ON backup.enrollment_requests (identifier, pubkey, action) WHERE status = 'pending';
CREATE INDEX IF NOT EXISTS backup_enrollment_requests_status_idx
    ON backup.enrollment_requests (status, requested_at);

CREATE TABLE IF NOT EXISTS backup.repos (
    id         BIGSERIAL PRIMARY KEY,
    host_id    BIGINT NOT NULL REFERENCES backup.hosts(id) ON DELETE CASCADE,
    ssh_user   TEXT NOT NULL,
    server     TEXT NOT NULL,
    location   TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (host_id, ssh_user, server, location)
);

CREATE TABLE IF NOT EXISTS backup.backup_runs (
    id                      BIGSERIAL PRIMARY KEY,
    repo_id                 BIGINT NOT NULL REFERENCES backup.repos(id) ON DELETE CASCADE,
    mode                    TEXT NOT NULL CHECK (mode IN ('full_host', 'local_only', 'homelab_only', 'specific')),
    archive_name            TEXT,
    started_at              TIMESTAMPTZ NOT NULL,
    finished_at             TIMESTAMPTZ NOT NULL,
    status                  TEXT NOT NULL CHECK (status IN ('success', 'warning', 'failure')),
    original_size_bytes     BIGINT,
    compressed_size_bytes   BIGINT,
    deduplicated_size_bytes BIGINT,
    file_count              INTEGER,
    error_message           TEXT
);
CREATE INDEX IF NOT EXISTS backup_runs_repo_started_idx ON backup.backup_runs (repo_id, started_at DESC);

CREATE TABLE IF NOT EXISTS backup.check_runs (
    id            BIGSERIAL PRIMARY KEY,
    repo_id       BIGINT NOT NULL REFERENCES backup.repos(id) ON DELETE CASCADE,
    started_at    TIMESTAMPTZ NOT NULL,
    finished_at   TIMESTAMPTZ NOT NULL,
    status        TEXT NOT NULL CHECK (status IN ('success', 'failure')),
    error_message TEXT
);
CREATE INDEX IF NOT EXISTS check_runs_repo_started_idx ON backup.check_runs (repo_id, started_at DESC);

-- Discovery: closes the "which server do I even talk to" gap for a client
-- that has never enrolled anywhere yet. Single-row table (id fixed at 1).
-- hostname defaults to 127.0.0.1 rather than an auto-detected NIC/hostname,
-- since a multi-homed host has no single obviously-correct guess -- this
-- default is also simply correct when server and client are the same host.
-- The admin explicitly confirms/sets the real reachable address during
-- `homelab-backup-server setup` (or later reconfigure).
CREATE TABLE IF NOT EXISTS backup.server_info (
    id               INTEGER PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    hostname         TEXT NOT NULL DEFAULT '127.0.0.1',
    ssh_user         TEXT NOT NULL DEFAULT 'borgbackup',
    backup_location  TEXT NOT NULL DEFAULT '/var/borgbackup',
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);
INSERT INTO backup.server_info (id) VALUES (1) ON CONFLICT (id) DO NOTHING;

GRANT USAGE ON SCHEMA backup TO homelab_api;
GRANT SELECT, INSERT, UPDATE, DELETE ON
    backup.hosts, backup.enrollment_requests, backup.repos,
    backup.backup_runs, backup.check_runs, backup.server_info
    TO homelab_api;
GRANT USAGE, SELECT ON SEQUENCE backup.hosts_id_seq                TO homelab_api;
GRANT USAGE, SELECT ON SEQUENCE backup.enrollment_requests_id_seq  TO homelab_api;
GRANT USAGE, SELECT ON SEQUENCE backup.repos_id_seq                TO homelab_api;
GRANT USAGE, SELECT ON SEQUENCE backup.backup_runs_id_seq          TO homelab_api;
GRANT USAGE, SELECT ON SEQUENCE backup.check_runs_id_seq           TO homelab_api;

INSERT INTO api.roles (name, description) VALUES
    ('backup', 'Backup control-plane role for homelab-backup-client/-server service accounts')
ON CONFLICT (name) DO NOTHING;

-- /api/v1/backup/* is gated by the ordinary dynamic api.role_permissions
-- table (NOT the hardcoded is_site_admin bypass /api/v1/admin/* uses), so
-- site_admin gets nothing on this bridge for free and must be seeded here
-- too, same as `user` was seeded for Drive/mail routes in migration 006.
-- Also seed the base auth endpoints for `backup` specifically: a
-- homelab-backup-client/-server service account typically holds ONLY the
-- `backup` role (not `user`). homelab-backup-server's own `setup`/
-- `reconcile` sanity checks call `validate`, and every homelab-cli command's
-- transparent-refresh-on-401 path calls `refresh` once the JWT's
-- jwt.expiry_seconds (default 3600s) elapses -- without these two grants a
-- backup-only account could authenticate once but never validate its own
-- session nor refresh past its first hour.
INSERT INTO api.role_permissions (role_id, endpoint_key)
SELECT r.id, k
FROM api.roles r
CROSS JOIN (VALUES
    ('GET /api/v1/auth/validate'),
    ('POST /api/v1/auth/refresh'),
    ('POST /api/v1/auth/logout'),
    ('POST /api/v1/backup/enroll'),
    ('GET /api/v1/backup/enrollments'),
    ('POST /api/v1/backup/enrollments/:id/ack'),
    ('POST /api/v1/backup/hosts/:identifier/revoke'),
    ('POST /api/v1/backup/runs'),
    ('POST /api/v1/backup/checks'),
    ('GET /api/v1/backup/hosts'),
    ('GET /api/v1/backup/repos'),
    ('GET /api/v1/backup/hosts/:identifier/runs'),
    ('GET /api/v1/backup/server-info'),
    ('POST /api/v1/backup/server-info')
) AS t(k)
WHERE r.name IN ('backup', 'site_admin')
ON CONFLICT (role_id, endpoint_key) DO NOTHING;
