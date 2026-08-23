-- Migration 005: dovecot.allowed_sender_addresses -- a VIEW (not a table)
-- listing which addresses/domain-wildcards each sasl_username may send
-- as; consumed by Postfix's smtpd_sender_login_maps and by homelab-api's
-- Mail API (list_allowed_senders). Idempotent; byte-identical copy also
-- shipped by homelab-mailsend.
--
-- IMPORTANT: unlike the CREATE TABLE/SCHEMA statements elsewhere in this
-- migration set, a plain `CREATE OR REPLACE VIEW` is NOT safe here -- on
-- production, this view already exists with real, hand-tuned business
-- logic (catch-all-forward ownership, veilmail.us subdomain ownership,
-- etc. -- more than this greenfield reconstruction implements). Blindly
-- replacing it would silently clobber production's real behavior. This
-- migration only creates the view if it doesn't already exist at all --
-- on production (and any host where it's already been created), this is
-- a pure no-op; the simplified logic below only ever takes effect on a
-- genuinely fresh/test database that has never had this view.
CREATE SCHEMA IF NOT EXISTS dovecot;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_views
        WHERE schemaname = 'dovecot' AND viewname = 'allowed_sender_addresses'
    ) THEN
        EXECUTE $view$
            CREATE VIEW dovecot.allowed_sender_addresses AS
            SELECT
                (username || '@' || domain) AS sasl_username,
                (username || '@' || domain) AS sender_address
            FROM dovecot.users
            WHERE active = 'Y'
        $view$;
    END IF;
END
$$;
