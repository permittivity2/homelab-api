-- Migration 006: Role-based access control (roles, user_roles, role_permissions)
-- Created: 2026-08-02
--
-- Note: earlier migrations (002/003) grant to the legacy `dovecot_user` role.
-- Per issue #003, `homelab-api` now runs as its own dedicated `homelab_api`
-- DB role, so new tables here grant to `homelab_api` instead.

CREATE SCHEMA IF NOT EXISTS api;

CREATE TABLE IF NOT EXISTS api.roles (
    id          BIGSERIAL PRIMARY KEY,
    name        TEXT NOT NULL UNIQUE,
    description TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- User <-> role, many-to-many (a user may hold more than one role)
CREATE TABLE IF NOT EXISTS api.user_roles (
    id         BIGSERIAL PRIMARY KEY,
    user_id    BIGINT NOT NULL REFERENCES dovecot.users(id) ON DELETE CASCADE,
    role_id    BIGINT NOT NULL REFERENCES api.roles(id) ON DELETE CASCADE,
    granted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    granted_by BIGINT REFERENCES dovecot.users(id) ON DELETE SET NULL,
    UNIQUE (user_id, role_id)
);

-- Per-role endpoint permissions (admin-editable). `site_admin`'s own
-- capabilities are hardcoded in the app, not driven by this table, so it
-- can't be misconfigured into locking every admin out.
CREATE TABLE IF NOT EXISTS api.role_permissions (
    id           BIGSERIAL PRIMARY KEY,
    role_id      BIGINT NOT NULL REFERENCES api.roles(id) ON DELETE CASCADE,
    endpoint_key TEXT NOT NULL,      -- e.g. 'GET /api/v1/drive/quota'
    granted_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    granted_by   BIGINT REFERENCES dovecot.users(id) ON DELETE SET NULL,
    UNIQUE (role_id, endpoint_key)
);

CREATE INDEX IF NOT EXISTS idx_user_roles_user_id ON api.user_roles (user_id);
CREATE INDEX IF NOT EXISTS idx_user_roles_role_id ON api.user_roles (role_id);
CREATE INDEX IF NOT EXISTS idx_role_permissions_role_id ON api.role_permissions (role_id);
CREATE INDEX IF NOT EXISTS idx_role_permissions_key ON api.role_permissions (endpoint_key);

GRANT SELECT, INSERT, UPDATE, DELETE ON api.roles            TO homelab_api;
GRANT SELECT, INSERT, UPDATE, DELETE ON api.user_roles        TO homelab_api;
GRANT SELECT, INSERT, UPDATE, DELETE ON api.role_permissions  TO homelab_api;
GRANT USAGE, SELECT ON SEQUENCE api.roles_id_seq             TO homelab_api;
GRANT USAGE, SELECT ON SEQUENCE api.user_roles_id_seq        TO homelab_api;
GRANT USAGE, SELECT ON SEQUENCE api.role_permissions_id_seq  TO homelab_api;

INSERT INTO api.roles (name, description) VALUES
    ('user', 'Default role — standard API access'),
    ('site_admin', 'Administrative capabilities (informational only; admin routes are hardcoded, not gated by this table)')
ON CONFLICT (name) DO NOTHING;

-- Seed: every currently-existing authenticated, non-public endpoint into
-- `user`'s permission set, so nothing regresses on rollout. Public routes
-- (login, health, introspect, public share links) are never gated by this
-- table at all, so they're intentionally absent here.
INSERT INTO api.role_permissions (role_id, endpoint_key)
SELECT (SELECT id FROM api.roles WHERE name = 'user'), k
FROM (VALUES
    ('POST /api/v1/auth/logout'),
    ('GET /api/v1/auth/validate'),
    ('POST /api/v1/auth/refresh'),
    ('GET /api/v1/drive/quota'),
    ('POST /api/v1/drive/fileinfo'),
    ('POST /api/v1/drive/files'),
    ('GET /api/v1/drive/files/:id/meta'),
    ('GET /api/v1/drive/files/:id'),
    ('DELETE /api/v1/drive/files/:id'),
    ('PATCH /api/v1/drive/files/:id'),
    ('POST /api/v1/drive/files/:id/copy'),
    ('GET /api/v1/drive/files/:id/versions'),
    ('GET /api/v1/drive/trash'),
    ('POST /api/v1/drive/files/:id/restore'),
    ('DELETE /api/v1/drive/trash'),
    ('GET /api/v1/drive/directories'),
    ('POST /api/v1/drive/directories'),
    ('DELETE /api/v1/drive/directories/:id'),
    ('PATCH /api/v1/drive/directories/:id'),
    ('POST /api/v1/drive/files/:id/share'),
    ('POST /api/v1/drive/directories/:id/share'),
    ('GET /api/v1/drive/shares'),
    ('GET /api/v1/drive/shares/with-me'),
    ('DELETE /api/v1/drive/shares/:id'),
    ('POST /api/v1/drive/bulk/trash'),
    ('POST /api/v1/drive/bulk/restore'),
    ('GET /api/v1/drive/trash/dir'),
    ('POST /api/v1/drive/bulk/move'),
    ('POST /api/v1/drive/bulk/copy'),
    ('POST /api/v1/drive/zip')
) AS t(k)
ON CONFLICT (role_id, endpoint_key) DO NOTHING;

-- Seed: assign the `user` role to every existing active account. Without
-- this, every pre-existing account holds zero roles after this migration
-- (api.user_roles starts empty), so every Drive/auth call from every
-- existing user would 403 the moment this ships — the exact regression
-- this migration is supposed to avoid. New accounts created after this
-- migration runs still need `user` assigned explicitly (or via whatever
-- account-creation path is extended to do so).
INSERT INTO api.user_roles (user_id, role_id)
SELECT u.id, (SELECT id FROM api.roles WHERE name = 'user')
FROM dovecot.users u
WHERE u.active = 'Y'
ON CONFLICT (user_id, role_id) DO NOTHING;
