-- Migration 004: dovecot.postfix_recipient_access -- per-recipient
-- allow/reject overrides (Postfix check_recipient_access). Idempotent;
-- byte-identical copy also shipped by homelab-mailsend.
CREATE SCHEMA IF NOT EXISTS dovecot;

CREATE TABLE IF NOT EXISTS dovecot.postfix_recipient_access (
    id         SERIAL PRIMARY KEY,
    recipient  VARCHAR NOT NULL UNIQUE,
    action     VARCHAR NOT NULL DEFAULT 'OK'
);
