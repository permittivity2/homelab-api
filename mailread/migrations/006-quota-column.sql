-- Migration 006: defensive ADD COLUMN IF NOT EXISTS for dovecot.users.quota_mb.
-- Already present in 001's CREATE TABLE for a fresh install; this exists
-- as a no-op-safe safety net in case a future schema evolution needs its
-- own additive step here. Idempotent; byte-identical copy also shipped by
-- homelab-mailsend.
ALTER TABLE dovecot.users ADD COLUMN IF NOT EXISTS quota_mb INT DEFAULT 1024;
