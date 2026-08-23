-- Migration 001: dovecot.users -- the core mail identity table.
-- Idempotent: safe to run on every package configure, not just first
-- install (a real bug class this project has hit before -- see
-- homelab-api's own postinst history). Byte-identical copy also shipped
-- by homelab-mailsend, since either package may be the first one
-- installed against a given database (they can run on different hosts).
--
-- Column shape matches what homelab-api's own postinst already creates
-- when self-provisioning a local test database, so both stay consistent.

CREATE SCHEMA IF NOT EXISTS dovecot;

CREATE TABLE IF NOT EXISTS dovecot.users (
    id         SERIAL PRIMARY KEY,
    username   VARCHAR NOT NULL,
    domain     VARCHAR NOT NULL,
    password   VARCHAR NOT NULL,
    active     CHAR(1) NOT NULL DEFAULT 'Y',
    quota_mb   INT DEFAULT 1024,
    UNIQUE (username, domain)
);
