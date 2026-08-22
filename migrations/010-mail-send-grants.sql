-- Migration 010: grant the Phase 4 mail send/draft endpoints to the `user`
-- role, plus a read-only DB grant needed for allowed-sender discovery
-- Created: 2026-08-22
--
-- Phase 4 of issue #015 (Mail API) adds send, drafts, and allowed-from
-- discovery. Same rationale as migrations 007/008/009:
-- Homelab::Roles::user_has_permission is table-driven off
-- api.role_permissions, so every new endpoint needs an explicit row here
-- or every existing account gets 403 Forbidden despite a valid JWT.
--
-- dovecot.allowed_sender_addresses is a view in the same `mailserver` DB
-- homelab_api already connects to (sasl_username, sender_address columns;
-- domain-wide grants are encoded as a "%@domain.tld" wildcard string, not
-- a separate table). This is read-only, purely for client display --
-- Postfix's own smtpd_sender_login_maps remains the actual enforcement
-- point at send time.

GRANT SELECT ON dovecot.allowed_sender_addresses TO homelab_api;

INSERT INTO api.role_permissions (role_id, endpoint_key)
SELECT (SELECT id FROM api.roles WHERE name = 'user'), endpoint_key
FROM (VALUES
    ('POST /api/v1/mail/send'),
    ('POST /api/v1/mail/drafts'),
    ('GET /api/v1/mail/allowed-senders')
) AS v(endpoint_key)
ON CONFLICT (role_id, endpoint_key) DO NOTHING;
