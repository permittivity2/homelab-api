-- Migration 003: dovecot.postfix_virtual_aliases -- alias/forwarding
-- map (source address or "%@domain" catch-all -> destination address).
-- Idempotent; byte-identical copy also shipped by homelab-mailsend.
CREATE SCHEMA IF NOT EXISTS dovecot;

CREATE TABLE IF NOT EXISTS dovecot.postfix_virtual_aliases (
    id           SERIAL PRIMARY KEY,
    source       VARCHAR NOT NULL,
    destination  VARCHAR NOT NULL,
    UNIQUE (source, destination)
);
