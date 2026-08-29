-- Migration 012: support for the new POST /api/v1/admin/users (create-user)
-- endpoint -- widens homelab_api's grant on dovecot.users (currently
-- SELECT-only plus UPDATE(password) from migration 006) just enough to
-- INSERT a new account row, and adds a table to make "which role may grant
-- which other role" table-driven instead of unconditional (today
-- Homelab::Roles::assign_role accepts any role for any target with no
-- check at all).

GRANT INSERT (username, domain, password, active, quota_mb) ON dovecot.users TO homelab_api;
GRANT USAGE, SELECT ON SEQUENCE dovecot.users_id_seq TO homelab_api;

CREATE TABLE IF NOT EXISTS api.role_grant_permissions (
    id               BIGSERIAL PRIMARY KEY,
    granter_role_id  BIGINT NOT NULL REFERENCES api.roles(id) ON DELETE CASCADE,
    grantee_role_id  BIGINT NOT NULL REFERENCES api.roles(id) ON DELETE CASCADE,
    UNIQUE (granter_role_id, grantee_role_id)
);
GRANT SELECT, INSERT, UPDATE, DELETE ON api.role_grant_permissions TO homelab_api;
GRANT USAGE, SELECT ON SEQUENCE api.role_grant_permissions_id_seq TO homelab_api;

-- site_admin's own grant-ability is ALSO hardcoded (see
-- Homelab::Roles::can_grant_role) for the same "a bad table edit can never
-- lock every admin out" reason site_admin's endpoint permissions are
-- hardcoded -- these rows are documentation/future-proofing (e.g. if a
-- future non-site_admin role should be allowed to create `backup`-flavored
-- accounts, add a row here, no code change needed), not load-bearing today.
INSERT INTO api.role_grant_permissions (granter_role_id, grantee_role_id)
SELECT (SELECT id FROM api.roles WHERE name = 'site_admin'), r.id
FROM api.roles r
ON CONFLICT (granter_role_id, grantee_role_id) DO NOTHING;
