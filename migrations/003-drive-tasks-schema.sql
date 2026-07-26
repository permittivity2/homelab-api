-- Homelab Drive Task Queue
-- Created: 2026-07-18
-- Phase 2: Background task processing for file operations

CREATE TABLE api.drive_files_tasks (
    id           BIGSERIAL PRIMARY KEY,
    file_id      BIGINT NOT NULL REFERENCES api.drive_files(id) ON DELETE CASCADE,
    task         TEXT NOT NULL,          -- 'sha256', 'delete', 'virus_scan', etc.
    task_data    TEXT,                   -- JSON-encoded task-specific parameters
    completed    BOOLEAN NOT NULL DEFAULT false,
    status_text  TEXT,                   -- human-readable state or error message
    worker_id    TEXT,                   -- 'hostname:pid' of claiming worker
    retry_count  INT NOT NULL DEFAULT 0,
    inserted_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    started_at   TIMESTAMPTZ,
    completed_at TIMESTAMPTZ
);

CREATE INDEX ON api.drive_files_tasks (completed, started_at);
CREATE INDEX ON api.drive_files_tasks (file_id, inserted_at);

GRANT SELECT, INSERT, UPDATE, DELETE ON api.drive_files_tasks TO dovecot_user;
GRANT USAGE, SELECT ON SEQUENCE api.drive_files_tasks_id_seq TO dovecot_user;
