-- LICENSEURI https://yuruna.link/license
-- Copyright (c) 2019-2026 by Alisson Sol et al.
-- ----------------------------------------------------------------------------
-- Yuruna Text-to-SQL example schema: a small SaaS-style subscriptions
-- warehouse with intentionally diverse table sizes, a deliberate naming
-- mismatch, and a FK graph that exercises schema retrieval.
--
-- Load order:
--    psql -h localhost -U yuruna -d yuruna_demo -f schema.sql
--
-- The deep-dive notes are kept inline as COMMENT ON ... so the schema
-- retriever has real prose to embed (mirrors what a production warehouse
-- catalog looks like).
-- ----------------------------------------------------------------------------

DROP TABLE IF EXISTS churn_event       CASCADE;
DROP TABLE IF EXISTS invoice           CASCADE;
DROP TABLE IF EXISTS subscription      CASCADE;
DROP TABLE IF EXISTS customer          CASCADE;
DROP TABLE IF EXISTS plan_tier         CASCADE;
DROP TABLE IF EXISTS acquisition_channel CASCADE;
DROP TABLE IF EXISTS geography         CASCADE;

-- ── Reference tables ────────────────────────────────────────────────────────

CREATE TABLE geography (
    geo_id        SERIAL PRIMARY KEY,
    iso_country   CHAR(2)   NOT NULL UNIQUE,
    region        TEXT      NOT NULL,           -- EMEA, AMER, APAC, LATAM
    country_name  TEXT      NOT NULL
);
COMMENT ON TABLE  geography IS 'Country reference with macro region (EMEA, AMER, APAC, LATAM).';
COMMENT ON COLUMN geography.region IS 'Macro sales region. Use this column for "EMEA / AMER / APAC / LATAM" filters.';

CREATE TABLE acquisition_channel (
    channel_id    SERIAL PRIMARY KEY,
    channel_name  TEXT      NOT NULL UNIQUE,    -- "Organic", "Paid Search", "Partner", "Outbound"
    channel_kind  TEXT      NOT NULL            -- "self-serve" | "sales-led"
);
COMMENT ON TABLE  acquisition_channel IS 'How customers found us: Organic, Paid Search, Partner, Outbound.';

CREATE TABLE plan_tier (
    tier_id       SERIAL PRIMARY KEY,
    -- NOTE: "tier_code" was renamed from "plan_code" in 2026-Q1 and this is
    -- the naming-mismatch trap that the agent must navigate. A user asking
    -- "by plan tier" should land on plan_tier.tier_code, not a fictional
    -- subscription.plan_tier column.
    tier_code     TEXT      NOT NULL UNIQUE,    -- "Starter", "Pro", "Enterprise"
    monthly_usd   NUMERIC(10,2) NOT NULL
);
COMMENT ON TABLE  plan_tier IS 'Pricing tier dimension. tier_code values: Starter, Pro, Enterprise.';
COMMENT ON COLUMN plan_tier.tier_code IS 'Plan tier code. RENAMED 2026-Q1 from plan_code → tier_code.';

-- ── Core entities ───────────────────────────────────────────────────────────

CREATE TABLE customer (
    customer_id   SERIAL PRIMARY KEY,
    customer_uuid UUID      NOT NULL DEFAULT gen_random_uuid() UNIQUE,
    company_name  TEXT      NOT NULL,
    email         TEXT      NOT NULL,            -- PII: redact in the UI
    geo_id        INT       NOT NULL REFERENCES geography(geo_id),
    channel_id    INT       NOT NULL REFERENCES acquisition_channel(channel_id),
    signed_up_at  TIMESTAMPTZ NOT NULL
);
COMMENT ON TABLE  customer IS 'Customer (B2B account). One row per company. PII columns: email.';
COMMENT ON COLUMN customer.email IS 'PII — must be redacted unless caller has role pii_reader.';

CREATE TABLE subscription (
    subscription_id  SERIAL PRIMARY KEY,
    customer_id      INT       NOT NULL REFERENCES customer(customer_id),
    tier_id          INT       NOT NULL REFERENCES plan_tier(tier_id),
    started_at       TIMESTAMPTZ NOT NULL,
    cancelled_at     TIMESTAMPTZ NULL,         -- NULL = still active
    seat_count       INT       NOT NULL DEFAULT 1
);
COMMENT ON TABLE  subscription IS 'Time-bounded subscription per customer. cancelled_at NULL means active.';

CREATE TABLE invoice (
    invoice_id       SERIAL PRIMARY KEY,
    subscription_id  INT       NOT NULL REFERENCES subscription(subscription_id),
    issued_at        DATE      NOT NULL,
    amount_usd       NUMERIC(10,2) NOT NULL,
    paid             BOOLEAN   NOT NULL DEFAULT FALSE
);

CREATE TABLE churn_event (
    churn_event_id   SERIAL PRIMARY KEY,
    subscription_id  INT       NOT NULL REFERENCES subscription(subscription_id),
    happened_at      DATE      NOT NULL,
    reason_code      TEXT      NULL              -- "price", "missing-feature", "competitor", "consolidation"
);
COMMENT ON TABLE  churn_event IS 'One row per cancellation. Use this table to compute churn rate. Join via subscription_id.';

-- ── Indexes ─────────────────────────────────────────────────────────────────

CREATE INDEX idx_subscription_tier        ON subscription(tier_id);
CREATE INDEX idx_subscription_customer    ON subscription(customer_id);
CREATE INDEX idx_subscription_started_at  ON subscription(started_at);
CREATE INDEX idx_invoice_subscription     ON invoice(subscription_id);
CREATE INDEX idx_churn_subscription       ON churn_event(subscription_id);
CREATE INDEX idx_churn_happened_at        ON churn_event(happened_at);
CREATE INDEX idx_customer_geo             ON customer(geo_id);
CREATE INDEX idx_customer_channel         ON customer(channel_id);

-- ── Seed data ──────────────────────────────────────────────────────────────

INSERT INTO geography (iso_country, region, country_name) VALUES
  ('DE','EMEA','Germany'),
  ('FR','EMEA','France'),
  ('UK','EMEA','United Kingdom'),
  ('ES','EMEA','Spain'),
  ('IT','EMEA','Italy'),
  ('US','AMER','United States'),
  ('CA','AMER','Canada'),
  ('BR','LATAM','Brazil'),
  ('MX','LATAM','Mexico'),
  ('JP','APAC','Japan'),
  ('AU','APAC','Australia'),
  ('IN','APAC','India');

INSERT INTO acquisition_channel (channel_name, channel_kind) VALUES
  ('Organic',     'self-serve'),
  ('Paid Search', 'self-serve'),
  ('Partner',     'sales-led'),
  ('Outbound',    'sales-led');

INSERT INTO plan_tier (tier_code, monthly_usd) VALUES
  ('Starter',    49.00),
  ('Pro',       249.00),
  ('Enterprise',1499.00);

-- 60 customers, distributed across regions/channels; deterministic seed data.
INSERT INTO customer (company_name, email, geo_id, channel_id, signed_up_at)
SELECT
    'Customer ' || gs                                          AS company_name,
    'cust' || gs || '@example.com'                              AS email,
    ((gs - 1) % 12) + 1                                         AS geo_id,
    ((gs - 1) % 4)  + 1                                         AS channel_id,
    TIMESTAMP '2025-01-01 00:00:00+00' + (gs * INTERVAL '4 days') AS signed_up_at
FROM generate_series(1, 60) gs;

-- Each customer gets exactly one subscription, tier distributed roughly
-- 50% Starter, 35% Pro, 15% Enterprise.
INSERT INTO subscription (customer_id, tier_id, started_at, cancelled_at, seat_count)
SELECT
    c.customer_id,
    CASE
      WHEN (c.customer_id % 20) < 10 THEN 1   -- Starter
      WHEN (c.customer_id % 20) < 17 THEN 2   -- Pro
      ELSE 3                                  -- Enterprise
    END                                                              AS tier_id,
    c.signed_up_at + INTERVAL '1 day'                                AS started_at,
    -- ~25% churn, biased toward Starter + EMEA + Paid Search
    CASE
      WHEN (c.customer_id % 7  = 0)
        OR (c.customer_id % 11 = 0 AND c.geo_id IN (1,2,3,4,5))
        OR (c.customer_id % 13 = 0 AND c.channel_id = 2)
      THEN c.signed_up_at + INTERVAL '90 days'
      ELSE NULL
    END                                                              AS cancelled_at,
    (1 + (c.customer_id % 8))                                        AS seat_count
FROM customer c;

-- One invoice per active subscription-month (small, example-sized).
INSERT INTO invoice (subscription_id, issued_at, amount_usd, paid)
SELECT
    s.subscription_id,
    (s.started_at + (m * INTERVAL '1 month'))::date  AS issued_at,
    p.monthly_usd * s.seat_count                     AS amount_usd,
    TRUE                                             AS paid
FROM subscription s
JOIN plan_tier p ON p.tier_id = s.tier_id
CROSS JOIN generate_series(0, 5) m
WHERE s.cancelled_at IS NULL OR s.started_at + (m * INTERVAL '1 month') <= s.cancelled_at;

-- One churn_event per cancelled subscription, reason cycled.
INSERT INTO churn_event (subscription_id, happened_at, reason_code)
SELECT
    s.subscription_id,
    s.cancelled_at::date,
    (ARRAY['price','missing-feature','competitor','consolidation'])[1 + (s.subscription_id % 4)]
FROM subscription s
WHERE s.cancelled_at IS NOT NULL;

-- ── Convenience views (the agent should NOT need these — they exist so an
-- answer like "use a materialized view for known shapes" is concretely
-- visible). ──

CREATE OR REPLACE VIEW v_active_subscription AS
SELECT s.*, p.tier_code, c.geo_id, g.region, c.channel_id, ch.channel_name
FROM subscription s
JOIN plan_tier             p  ON p.tier_id    = s.tier_id
JOIN customer              c  ON c.customer_id = s.customer_id
JOIN geography             g  ON g.geo_id     = c.geo_id
JOIN acquisition_channel   ch ON ch.channel_id = c.channel_id
WHERE s.cancelled_at IS NULL;

-- ── Roles for the action-gating layer ──────────────────────────────────────
-- A read-only role the .NET app connects as. The agent NEVER connects as
-- the schema owner. This is what action-gating looks like at the DB layer.

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'yuruna_agent_ro') THEN
        CREATE ROLE yuruna_agent_ro LOGIN PASSWORD 'agent_demo_password';
    END IF;
END$$;

GRANT CONNECT ON DATABASE CURRENT_DATABASE() TO yuruna_agent_ro;
GRANT USAGE   ON SCHEMA public TO yuruna_agent_ro;
GRANT SELECT  ON ALL TABLES   IN SCHEMA public TO yuruna_agent_ro;
GRANT SELECT  ON ALL SEQUENCES IN SCHEMA public TO yuruna_agent_ro;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES   TO yuruna_agent_ro;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON SEQUENCES TO yuruna_agent_ro;

-- ── Sanity counts (psql will echo these) ────────────────────────────────────
SELECT 'geography'           AS table_name, COUNT(*) AS row_count FROM geography
UNION ALL SELECT 'acquisition_channel', COUNT(*) FROM acquisition_channel
UNION ALL SELECT 'plan_tier',           COUNT(*) FROM plan_tier
UNION ALL SELECT 'customer',            COUNT(*) FROM customer
UNION ALL SELECT 'subscription',        COUNT(*) FROM subscription
UNION ALL SELECT 'invoice',             COUNT(*) FROM invoice
UNION ALL SELECT 'churn_event',         COUNT(*) FROM churn_event;
