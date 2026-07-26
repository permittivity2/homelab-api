-- Homelab Drive Schema
-- Created: 2026-07-18
-- Phase 2: File storage with full versioning

-- Directories (NULL parent_id = root)
CREATE TABLE api.drive_directories (
    id         BIGSERIAL PRIMARY KEY,
    user_id    BIGINT NOT NULL REFERENCES dovecot.users(id) ON DELETE CASCADE,
    dir_name   TEXT NOT NULL,
    parent_id  BIGINT REFERENCES api.drive_directories(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (user_id, parent_id, dir_name)
);

-- File metadata: human name + location pointer
CREATE TABLE api.drive_files (
    id                 BIGSERIAL PRIMARY KEY,
    user_id            BIGINT NOT NULL REFERENCES dovecot.users(id) ON DELETE CASCADE,
    file_name          TEXT NOT NULL,
    dir_id             BIGINT REFERENCES api.drive_directories(id) ON DELETE SET NULL,
    current_version_id BIGINT,
    is_deleted         BOOLEAN NOT NULL DEFAULT false,
    deleted_at         TIMESTAMPTZ,
    created_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at         TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Content versions: one row per upload; UUID = actual filename on disk
CREATE TABLE api.drive_versions (
    id         BIGSERIAL PRIMARY KEY,
    file_id    BIGINT NOT NULL REFERENCES api.drive_files(id) ON DELETE CASCADE,
    uuid       UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
    file_size  BIGINT NOT NULL,
    mime_type  TEXT,
    sha256     TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE api.drive_files
    ADD CONSTRAINT drive_files_current_version_fkey
    FOREIGN KEY (current_version_id) REFERENCES api.drive_versions(id);

-- Pre-computed quota (updated on every upload/delete/empty-trash)
CREATE TABLE api.drive_quota (
    user_id      BIGINT PRIMARY KEY REFERENCES dovecot.users(id) ON DELETE CASCADE,
    usage_bytes  BIGINT NOT NULL DEFAULT 0,
    file_count   INT NOT NULL DEFAULT 0,
    last_updated TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Shares (user-to-user or public token link; NULL shared_with = public)
CREATE TABLE api.drive_shares (
    id                   BIGSERIAL PRIMARY KEY,
    file_id              BIGINT NOT NULL REFERENCES api.drive_files(id) ON DELETE CASCADE,
    owner_user_id        BIGINT NOT NULL REFERENCES dovecot.users(id) ON DELETE CASCADE,
    shared_with_user_id  BIGINT REFERENCES dovecot.users(id) ON DELETE CASCADE,
    share_token          VARCHAR(64) UNIQUE,
    permission           VARCHAR(20) NOT NULL DEFAULT 'read',
    expires_at           TIMESTAMPTZ,
    is_active            BOOLEAN NOT NULL DEFAULT true,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    accessed_at          TIMESTAMPTZ,
    access_count         INT NOT NULL DEFAULT 0
);

-- Indexes
CREATE INDEX ON api.drive_directories (user_id, parent_id);
CREATE INDEX ON api.drive_files (user_id, is_deleted);
CREATE INDEX ON api.drive_files (dir_id);
CREATE INDEX ON api.drive_versions (file_id);
CREATE INDEX ON api.drive_shares (share_token);
CREATE INDEX ON api.drive_shares (owner_user_id);
CREATE INDEX ON api.drive_shares (file_id);

-- Grants
GRANT SELECT, INSERT, UPDATE, DELETE ON api.drive_directories TO dovecot_user;
GRANT SELECT, INSERT, UPDATE, DELETE ON api.drive_files       TO dovecot_user;
GRANT SELECT, INSERT, UPDATE, DELETE ON api.drive_versions    TO dovecot_user;
GRANT SELECT, INSERT, UPDATE, DELETE ON api.drive_quota       TO dovecot_user;
GRANT SELECT, INSERT, UPDATE, DELETE ON api.drive_shares      TO dovecot_user;
GRANT USAGE, SELECT ON SEQUENCE api.drive_directories_id_seq  TO dovecot_user;
GRANT USAGE, SELECT ON SEQUENCE api.drive_files_id_seq        TO dovecot_user;
GRANT USAGE, SELECT ON SEQUENCE api.drive_versions_id_seq     TO dovecot_user;
GRANT USAGE, SELECT ON SEQUENCE api.drive_shares_id_seq       TO dovecot_user;
