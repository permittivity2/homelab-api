-- Migration 007: grant GET /api/v1/mail/status to the `user` role
-- Created: 2026-08-21
--
-- Phase 1 of issue #015 (Mail API). Homelab::Roles::user_has_permission is
-- table-driven off api.role_permissions, and migration 006 only seeded
-- endpoints that existed at the time -- without this row, every existing
-- account gets 403 Forbidden on the new endpoint despite holding a
-- perfectly valid JWT.
--
-- No new tables/columns and no new GRANTs to the homelab_api DB role are
-- needed here: Phase 1 is a live IMAP passthrough with no persisted state,
-- so this migration only inserts a permissions row.

INSERT INTO api.role_permissions (role_id, endpoint_key)
SELECT (SELECT id FROM api.roles WHERE name = 'user'), 'GET /api/v1/mail/status'
ON CONFLICT (role_id, endpoint_key) DO NOTHING;
