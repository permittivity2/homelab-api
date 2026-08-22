-- Migration 008: grant the Phase 2 mail read endpoints to the `user` role
-- Created: 2026-08-21
--
-- Phase 2 of issue #015 (Mail API) adds folder listing, paginated message
-- listing, single-message fetch, and a generic part-content fetch. Same
-- rationale as migration 007: Homelab::Roles::user_has_permission is
-- table-driven off api.role_permissions, so every new endpoint needs an
-- explicit row here or every existing account gets 403 Forbidden despite
-- a valid JWT.
--
-- Still no new tables/columns/GRANTs: these are all live IMAP passthroughs
-- with no persisted state.

INSERT INTO api.role_permissions (role_id, endpoint_key)
SELECT (SELECT id FROM api.roles WHERE name = 'user'), endpoint_key
FROM (VALUES
    ('GET /api/v1/mail/folders'),
    ('GET /api/v1/mail/messages'),
    ('GET /api/v1/mail/messages/:uid'),
    ('GET /api/v1/mail/messages/:uid/part')
) AS v(endpoint_key)
ON CONFLICT (role_id, endpoint_key) DO NOTHING;
