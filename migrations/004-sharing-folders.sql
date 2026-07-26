-- Migration 004: Extend drive_shares to support folder sharing
--
-- Note: shared_with_user_id already exists as of migration 002 (correctly
-- referencing dovecot.users) — only dir_id and the one-target constraint
-- are new here. All statements are idempotent so this is safe to re-run.

-- Allow file_id to be nullable (folder shares have no file_id)
ALTER TABLE api.drive_shares ALTER COLUMN file_id DROP NOT NULL;

-- Add dir_id for folder shares
ALTER TABLE api.drive_shares
    ADD COLUMN IF NOT EXISTS dir_id BIGINT REFERENCES api.drive_directories(id) ON DELETE CASCADE;

-- Exactly one of file_id or dir_id must be set
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'drive_shares_one_target'
    ) THEN
        ALTER TABLE api.drive_shares ADD CONSTRAINT drive_shares_one_target CHECK (
            (file_id IS NOT NULL AND dir_id IS NULL) OR
            (file_id IS NULL AND dir_id IS NOT NULL)
        );
    END IF;
END $$;

CREATE INDEX IF NOT EXISTS drive_shares_dir_id_idx ON api.drive_shares(dir_id)
    WHERE dir_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS drive_shares_shared_with_idx ON api.drive_shares(shared_with_user_id)
    WHERE shared_with_user_id IS NOT NULL;
