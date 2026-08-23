-- Migration 002: dovecot.postfix_virtual_domains -- domains Postfix will
-- accept mail for. Idempotent; byte-identical copy also shipped by
-- homelab-mailsend (see 001's header comment for why both ship the full
-- set).
CREATE SCHEMA IF NOT EXISTS dovecot;

CREATE TABLE IF NOT EXISTS dovecot.postfix_virtual_domains (
    id      SERIAL PRIMARY KEY,
    domain  VARCHAR NOT NULL UNIQUE
);
