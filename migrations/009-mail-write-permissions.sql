-- Migration 009: grant the Phase 3 mail write endpoints to the `user` role
-- Created: 2026-08-22
--
-- Phase 3 of issue #015 (Mail API) adds search, flag mutation, move,
-- soft-delete-to-Trash, permanent (Trash-only) expunge, and folder
-- create/rename/delete. Same rationale as migrations 007/008:
-- Homelab::Roles::user_has_permission is table-driven off
-- api.role_permissions, so every new endpoint needs an explicit row here
-- or every existing account gets 403 Forbidden despite a valid JWT.
--
-- Still no new tables/columns/GRANTs: these are all live IMAP passthroughs
-- with no persisted state.

INSERT INTO api.role_permissions (role_id, endpoint_key)
SELECT (SELECT id FROM api.roles WHERE name = 'user'), endpoint_key
FROM (VALUES
    ('GET /api/v1/mail/search'),
    ('POST /api/v1/mail/messages/:uid/flags'),
    ('POST /api/v1/mail/messages/:uid/move'),
    ('DELETE /api/v1/mail/messages/:uid'),
    ('DELETE /api/v1/mail/messages/:uid/permanent'),
    ('POST /api/v1/mail/folders'),
    ('PATCH /api/v1/mail/folders'),
    ('DELETE /api/v1/mail/folders')
) AS v(endpoint_key)
ON CONFLICT (role_id, endpoint_key) DO NOTHING;
