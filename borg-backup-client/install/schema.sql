-- homelab-borg-service-backup run-tracking schema.
--
-- Lives in its own Postgres schema (not `public`) so other homelab-*
-- packages sharing the `homelab` database later (e.g. a future
-- homelab-borg-user-backup) don't collide on table names.
--
-- Idempotent: safe to run against an existing, already-populated
-- database (install.sh does, on every install/configure run).

CREATE SCHEMA IF NOT EXISTS service_backup;

-- One row per physical/logical host that has ever reported in.
CREATE TABLE IF NOT EXISTS service_backup.hosts (
    id            SERIAL PRIMARY KEY,
    identifier    TEXT NOT NULL UNIQUE,   -- matches resolve_identifier(): the repo path segment
    hostname      TEXT NOT NULL,          -- socket.gethostname() as of last report
    first_seen_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_seen_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- A host's backup destination. Split from hosts so a change in
-- borgbackup_server/location gets its own row (and run history)
-- rather than silently rewriting where past runs "belong".
CREATE TABLE IF NOT EXISTS service_backup.repos (
    id         SERIAL PRIMARY KEY,
    host_id    INTEGER NOT NULL REFERENCES service_backup.hosts(id) ON DELETE CASCADE,
    ssh_user   TEXT NOT NULL,
    server     TEXT NOT NULL,
    location   TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (host_id, ssh_user, server, location)
);

-- One row per completed `homelab-borg-service-backup-client backup` invocation.
-- Written once, after the run finishes (this is a historical log, not
-- a live-progress tracker) -- deliberately no duration_seconds column:
-- it's derivable from finished_at - started_at, and storing it would
-- be a non-key-attribute-depends-on-non-key-attribute violation of 3NF.
CREATE TABLE IF NOT EXISTS service_backup.backup_runs (
    id                      BIGSERIAL PRIMARY KEY,
    repo_id                 INTEGER NOT NULL REFERENCES service_backup.repos(id) ON DELETE CASCADE,
    mode                    TEXT NOT NULL CHECK (mode IN ('full_host', 'local_only', 'homelab_only', 'specific')),
    archive_name            TEXT,          -- NULL if the run failed before `borg create` resolved one
    started_at              TIMESTAMPTZ NOT NULL,
    finished_at             TIMESTAMPTZ NOT NULL,
    status                  TEXT NOT NULL CHECK (status IN ('success', 'warning', 'failure')),
    original_size_bytes     BIGINT,        -- from `borg create --json` archive.stats
    compressed_size_bytes   BIGINT,
    deduplicated_size_bytes BIGINT,
    file_count              INTEGER,
    error_message           TEXT
);
CREATE INDEX IF NOT EXISTS backup_runs_repo_started_idx
    ON service_backup.backup_runs (repo_id, started_at DESC);

-- One row per completed `homelab-borg-service-backup-client check` invocation.
CREATE TABLE IF NOT EXISTS service_backup.check_runs (
    id            BIGSERIAL PRIMARY KEY,
    repo_id       INTEGER NOT NULL REFERENCES service_backup.repos(id) ON DELETE CASCADE,
    started_at    TIMESTAMPTZ NOT NULL,
    finished_at   TIMESTAMPTZ NOT NULL,
    status        TEXT NOT NULL CHECK (status IN ('success', 'failure')),
    error_message TEXT
);
CREATE INDEX IF NOT EXISTS check_runs_repo_started_idx
    ON service_backup.check_runs (repo_id, started_at DESC);
