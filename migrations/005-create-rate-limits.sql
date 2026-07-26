-- Migration 005: Login rate limiting (api.rate_limits)
-- Referenced by Homelab::RateLimit but was never captured in a migration
-- until now — it previously existed only as an ad hoc table on production.

CREATE SCHEMA IF NOT EXISTS api;

CREATE TABLE IF NOT EXISTS api.rate_limits (
    id BIGSERIAL PRIMARY KEY,
    email VARCHAR(255) NOT NULL,
    attempt_at TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_rate_limits_email_time ON api.rate_limits (LOWER(email), attempt_at);
