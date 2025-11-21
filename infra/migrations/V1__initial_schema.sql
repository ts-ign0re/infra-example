-- ============================================
-- V1: Initial Event Sourcing Schema
-- Creates tenants, event tables, and idempotency protection
-- ============================================

-- Enable necessary extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";

-- ============================================
-- TENANTS TABLE
-- ============================================

CREATE TABLE IF NOT EXISTS tenants (
    id BIGINT PRIMARY KEY,
    created_at TIMESTAMP NOT NULL DEFAULT NOW(),
    name VARCHAR(255) NOT NULL DEFAULT 'Unnamed Tenant',
    slug VARCHAR(100) NOT NULL,
    status VARCHAR(50) NOT NULL DEFAULT 'active',
    plan VARCHAR(50) NOT NULL DEFAULT 'basic',
    updated_at TIMESTAMP NOT NULL DEFAULT NOW(),
    metadata JSONB DEFAULT '{}'::jsonb
);

CREATE INDEX IF NOT EXISTS idx_tenants_slug ON tenants(slug);
CREATE INDEX IF NOT EXISTS idx_tenants_status ON tenants(status);

-- Distribute tenants table by tenant_id
SELECT create_distributed_table('tenants', 'id');

-- Seed default tenant
INSERT INTO tenants (id, name, slug, status, plan)
VALUES (10001, 'Default Tenant', 'default', 'active', 'basic')
ON CONFLICT (id) DO NOTHING;

-- ============================================
-- EVENT TABLES (Event Sourcing)
-- All events are append-only, immutable logs
-- ============================================

-- BET EVENTS - все события ставок
CREATE TABLE IF NOT EXISTS bet_events (
    id UUID DEFAULT uuid_generate_v4(),
    tenant_id BIGINT NOT NULL,
    aggregate_id VARCHAR(255) NOT NULL,  -- bet_id
    idempotency_key VARCHAR(255) NOT NULL,  -- уникальный ключ от клиента
    event_type VARCHAR(100) NOT NULL,    -- V1_BET_PLACED, V1_BET_SETTLED, etc.
    event_data JSONB NOT NULL,
    timestamp BIGINT NOT NULL DEFAULT (extract(epoch from now()) * 1000)::BIGINT,           -- Unix timestamp ms
    version INT NOT NULL DEFAULT 1,      -- schema version
    metadata JSONB,                      -- correlation_id, user_agent, etc.
    created_at TIMESTAMP NOT NULL DEFAULT NOW(),
    PRIMARY KEY (tenant_id, id),
    FOREIGN KEY (tenant_id) REFERENCES tenants(id)
);

CREATE INDEX IF NOT EXISTS idx_bet_events_tenant_id ON bet_events(tenant_id);
CREATE INDEX IF NOT EXISTS idx_bet_events_aggregate_id ON bet_events(aggregate_id);
CREATE INDEX IF NOT EXISTS idx_bet_events_tenant_aggregate ON bet_events(tenant_id, aggregate_id);
CREATE INDEX IF NOT EXISTS idx_bet_events_event_type ON bet_events(event_type);
CREATE INDEX IF NOT EXISTS idx_bet_events_timestamp ON bet_events(timestamp);

-- Unique constraint для idempotency
CREATE UNIQUE INDEX IF NOT EXISTS idx_bet_events_idempotency_unique 
ON bet_events(tenant_id, idempotency_key);

SELECT create_distributed_table('bet_events', 'tenant_id');

-- PAYMENT EVENTS - все события платежей
CREATE TABLE IF NOT EXISTS payment_events (
    id UUID DEFAULT uuid_generate_v4(),
    tenant_id BIGINT NOT NULL,
    aggregate_id VARCHAR(255) NOT NULL,  -- payment_id
    idempotency_key VARCHAR(255) NOT NULL,  -- уникальный ключ от клиента
    event_type VARCHAR(100) NOT NULL,    -- V1_PAYMENTS_DEPOSIT_CREATED, etc.
    event_data JSONB NOT NULL,
    timestamp BIGINT NOT NULL DEFAULT (extract(epoch from now()) * 1000)::BIGINT,
    version INT NOT NULL DEFAULT 1,
    metadata JSONB,
    created_at TIMESTAMP NOT NULL DEFAULT NOW(),
    PRIMARY KEY (tenant_id, id),
    FOREIGN KEY (tenant_id) REFERENCES tenants(id)
);

CREATE INDEX IF NOT EXISTS idx_payment_events_tenant_id ON payment_events(tenant_id);
CREATE INDEX IF NOT EXISTS idx_payment_events_aggregate_id ON payment_events(aggregate_id);
CREATE INDEX IF NOT EXISTS idx_payment_events_tenant_aggregate ON payment_events(tenant_id, aggregate_id);
CREATE INDEX IF NOT EXISTS idx_payment_events_event_type ON payment_events(event_type);
CREATE INDEX IF NOT EXISTS idx_payment_events_timestamp ON payment_events(timestamp);

-- Unique constraint для idempotency
CREATE UNIQUE INDEX IF NOT EXISTS idx_payment_events_idempotency_unique 
ON payment_events(tenant_id, idempotency_key);

SELECT create_distributed_table('payment_events', 'tenant_id');

-- BALANCE EVENTS - все события балансов
CREATE TABLE IF NOT EXISTS balance_events (
    id UUID DEFAULT uuid_generate_v4(),
    tenant_id BIGINT NOT NULL,
    aggregate_id VARCHAR(255) NOT NULL,  -- user_id or balance_id
    idempotency_key VARCHAR(255) NOT NULL,  -- уникальный ключ от клиента
    event_type VARCHAR(100) NOT NULL,    -- V1_BALANCE_ADJUSTED, etc.
    event_data JSONB NOT NULL,
    timestamp BIGINT NOT NULL DEFAULT (extract(epoch from now()) * 1000)::BIGINT,
    version INT NOT NULL DEFAULT 1,
    metadata JSONB,
    created_at TIMESTAMP NOT NULL DEFAULT NOW(),
    PRIMARY KEY (tenant_id, id),
    FOREIGN KEY (tenant_id) REFERENCES tenants(id)
);

CREATE INDEX IF NOT EXISTS idx_balance_events_tenant_id ON balance_events(tenant_id);
CREATE INDEX IF NOT EXISTS idx_balance_events_aggregate_id ON balance_events(aggregate_id);
CREATE INDEX IF NOT EXISTS idx_balance_events_tenant_aggregate ON balance_events(tenant_id, aggregate_id);
CREATE INDEX IF NOT EXISTS idx_balance_events_event_type ON balance_events(event_type);
CREATE INDEX IF NOT EXISTS idx_balance_events_timestamp ON balance_events(timestamp);

-- Unique constraint для idempotency
CREATE UNIQUE INDEX IF NOT EXISTS idx_balance_events_idempotency_unique 
ON balance_events(tenant_id, idempotency_key);

SELECT create_distributed_table('balance_events', 'tenant_id');

-- COMPLIANCE EVENTS - все события комплаенса
CREATE TABLE IF NOT EXISTS compliance_events (
    id UUID DEFAULT uuid_generate_v4(),
    tenant_id BIGINT NOT NULL,
    aggregate_id VARCHAR(255) NOT NULL,  -- user_id or check_id
    idempotency_key VARCHAR(255) NOT NULL,  -- уникальный ключ от клиента
    event_type VARCHAR(100) NOT NULL,    -- V1_KYC_VERIFIED, V1_LIMIT_EXCEEDED, etc.
    event_data JSONB NOT NULL,
    timestamp BIGINT NOT NULL DEFAULT (extract(epoch from now()) * 1000)::BIGINT,
    version INT NOT NULL DEFAULT 1,
    metadata JSONB,
    created_at TIMESTAMP NOT NULL DEFAULT NOW(),
    PRIMARY KEY (tenant_id, id),
    FOREIGN KEY (tenant_id) REFERENCES tenants(id)
);

CREATE INDEX IF NOT EXISTS idx_compliance_events_tenant_id ON compliance_events(tenant_id);
CREATE INDEX IF NOT EXISTS idx_compliance_events_aggregate_id ON compliance_events(aggregate_id);
CREATE INDEX IF NOT EXISTS idx_compliance_events_tenant_aggregate ON compliance_events(tenant_id, aggregate_id);
CREATE INDEX IF NOT EXISTS idx_compliance_events_event_type ON compliance_events(event_type);
CREATE INDEX IF NOT EXISTS idx_compliance_events_timestamp ON compliance_events(timestamp);

-- Unique constraint для idempotency
CREATE UNIQUE INDEX IF NOT EXISTS idx_compliance_events_idempotency_unique 
ON compliance_events(tenant_id, idempotency_key);

SELECT create_distributed_table('compliance_events', 'tenant_id');

-- TENANT EVENTS - события управления тенантами
CREATE TABLE IF NOT EXISTS tenant_events (
    id UUID DEFAULT uuid_generate_v4(),
    tenant_id BIGINT NOT NULL,
    aggregate_id VARCHAR(255) NOT NULL,  -- tenant_id as string
    idempotency_key VARCHAR(255) NOT NULL,  -- уникальный ключ от клиента
    event_type VARCHAR(100) NOT NULL,    -- V1_TENANT_CREATED, V1_TENANT_PLAN_CHANGED, etc.
    event_data JSONB NOT NULL,
    timestamp BIGINT NOT NULL DEFAULT (extract(epoch from now()) * 1000)::BIGINT,
    version INT NOT NULL DEFAULT 1,
    metadata JSONB,
    created_at TIMESTAMP NOT NULL DEFAULT NOW(),
    PRIMARY KEY (tenant_id, id),
    FOREIGN KEY (tenant_id) REFERENCES tenants(id)
);

CREATE INDEX IF NOT EXISTS idx_tenant_events_tenant_id ON tenant_events(tenant_id);
CREATE INDEX IF NOT EXISTS idx_tenant_events_aggregate_id ON tenant_events(aggregate_id);
CREATE INDEX IF NOT EXISTS idx_tenant_events_event_type ON tenant_events(event_type);
CREATE INDEX IF NOT EXISTS idx_tenant_events_timestamp ON tenant_events(timestamp);

-- Unique constraint для idempotency
CREATE UNIQUE INDEX IF NOT EXISTS idx_tenant_events_idempotency_unique 
ON tenant_events(tenant_id, idempotency_key);

SELECT create_distributed_table('tenant_events', 'tenant_id');

-- SYSTEM EVENTS - аналитика и системные события (некритичные)
-- ⚠️ Для system_events idempotency_key опциональный, т.к. эти события некритичны
CREATE TABLE IF NOT EXISTS system_events (
    id UUID DEFAULT uuid_generate_v4(),
    tenant_id BIGINT NOT NULL,
    aggregate_id VARCHAR(255),
    event_type VARCHAR(100) NOT NULL,
    event_data JSONB NOT NULL,
    timestamp BIGINT NOT NULL DEFAULT (extract(epoch from now()) * 1000)::BIGINT,
    version INT NOT NULL DEFAULT 1,
    metadata JSONB,
    created_at TIMESTAMP NOT NULL DEFAULT NOW(),
    PRIMARY KEY (tenant_id, id),
    FOREIGN KEY (tenant_id) REFERENCES tenants(id)
);

CREATE INDEX IF NOT EXISTS idx_system_events_tenant_id ON system_events(tenant_id);
CREATE INDEX IF NOT EXISTS idx_system_events_event_type ON system_events(event_type);
CREATE INDEX IF NOT EXISTS idx_system_events_timestamp ON system_events(timestamp);

SELECT create_distributed_table('system_events', 'tenant_id');

-- ============================================
-- MATERIALIZED VIEWS (Cron-based refresh)
-- ============================================

-- bets_view
CREATE MATERIALIZED VIEW IF NOT EXISTS bets_view AS
WITH latest_bet_events AS (
  SELECT DISTINCT ON (tenant_id, aggregate_id)
    tenant_id,
    aggregate_id as bet_id,
    idempotency_key,
    event_type,
    event_data,
    timestamp,
    created_at
  FROM bet_events
  ORDER BY tenant_id, aggregate_id, timestamp DESC
)
SELECT 
  tenant_id,
  bet_id,
  idempotency_key,
  (event_data->>'user_id') as user_id,
  (event_data->>'amount')::decimal as amount,
  (event_data->>'odds')::decimal as odds,
  (event_data->>'selection') as selection,
  (event_data->>'event_id') as event_id,
  (event_data->>'market_id') as market_id,
  CASE 
    WHEN event_type = 'V1_BET_PLACED' THEN 'placed'
    WHEN event_type = 'V1_BET_ACCEPTED' THEN 'accepted'
    WHEN event_type = 'V1_BET_REJECTED' THEN 'rejected'
    WHEN event_type = 'V1_BET_SETTLED_WIN' THEN 'won'
    WHEN event_type = 'V1_BET_SETTLED_LOSS' THEN 'lost'
    WHEN event_type = 'V1_BET_SETTLED_VOID' THEN 'void'
    WHEN event_type = 'V1_BET_CANCELLED' THEN 'cancelled'
    ELSE 'unknown'
  END as status,
  (event_data->>'payout')::decimal as payout,
  timestamp as last_updated_timestamp,
  created_at as last_updated_at
FROM latest_bet_events;

CREATE INDEX IF NOT EXISTS idx_bets_view_tenant_user ON bets_view(tenant_id, user_id);
CREATE INDEX IF NOT EXISTS idx_bets_view_status ON bets_view(tenant_id, status);
CREATE INDEX IF NOT EXISTS idx_bets_view_event ON bets_view(tenant_id, event_id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_bets_view_pk ON bets_view(tenant_id, bet_id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_bets_view_idempotency ON bets_view(tenant_id, idempotency_key);

-- user_balances_view
CREATE MATERIALIZED VIEW IF NOT EXISTS user_balances_view AS
SELECT 
  tenant_id,
  (event_data->>'user_id') as user_id,
  SUM(
    CASE 
      WHEN event_type LIKE '%_CREDIT' THEN (event_data->>'amount')::decimal
      WHEN event_type LIKE '%_DEBIT' THEN -(event_data->>'amount')::decimal
      ELSE 0
    END
  ) as balance,
  COUNT(*) as transaction_count,
  MAX(timestamp) as last_transaction_timestamp,
  to_timestamp(MAX(timestamp)::bigint / 1000) as last_transaction_at
FROM balance_events
GROUP BY tenant_id, (event_data->>'user_id');

CREATE UNIQUE INDEX IF NOT EXISTS idx_user_balances_view_pk ON user_balances_view(tenant_id, user_id);

-- payments_view
CREATE MATERIALIZED VIEW IF NOT EXISTS payments_view AS
WITH latest_payment_events AS (
  SELECT DISTINCT ON (tenant_id, aggregate_id)
    tenant_id,
    aggregate_id as payment_id,
    idempotency_key,
    event_type,
    event_data,
    timestamp,
    created_at
  FROM payment_events
  ORDER BY tenant_id, aggregate_id, timestamp DESC
)
SELECT 
  tenant_id,
  payment_id,
  idempotency_key,
  (event_data->>'user_id') as user_id,
  (event_data->>'amount')::decimal as amount,
  (event_data->>'currency') as currency,
  (event_data->>'payment_method') as payment_method,
  (event_data->>'external_id') as external_id,
  CASE 
    WHEN event_type LIKE '%_DEPOSIT_%' THEN 'deposit'
    WHEN event_type LIKE '%_WITHDRAWAL_%' THEN 'withdrawal'
    ELSE 'other'
  END as payment_type,
  CASE 
    WHEN event_type LIKE '%_CREATED' THEN 'created'
    WHEN event_type LIKE '%_PENDING' THEN 'pending'
    WHEN event_type LIKE '%_COMPLETED' THEN 'completed'
    WHEN event_type LIKE '%_FAILED' THEN 'failed'
    WHEN event_type LIKE '%_REFUNDED' THEN 'refunded'
    WHEN event_type LIKE '%_APPROVED' THEN 'approved'
    WHEN event_type LIKE '%_REJECTED' THEN 'rejected'
    ELSE 'unknown'
  END as status,
  timestamp as last_updated_timestamp,
  created_at as last_updated_at
FROM latest_payment_events;

CREATE INDEX IF NOT EXISTS idx_payments_view_tenant_user ON payments_view(tenant_id, user_id);
CREATE INDEX IF NOT EXISTS idx_payments_view_status ON payments_view(tenant_id, status);
CREATE INDEX IF NOT EXISTS idx_payments_view_type ON payments_view(tenant_id, payment_type);
CREATE INDEX IF NOT EXISTS idx_payments_view_external ON payments_view(tenant_id, external_id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_payments_view_pk ON payments_view(tenant_id, payment_id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_payments_view_idempotency ON payments_view(tenant_id, idempotency_key);

-- tenants_summary_view
CREATE MATERIALIZED VIEW IF NOT EXISTS tenants_summary_view AS
SELECT 
  t.id as tenant_id,
  t.name as tenant_name,
  t.slug,
  t.status,
  t.plan,
  COUNT(DISTINCT be.aggregate_id) as total_bets,
  COALESCE(SUM((be.event_data->>'amount')::decimal), 0) as total_bet_amount,
  COUNT(DISTINCT pe.aggregate_id) as total_payments,
  COALESCE(SUM((pe.event_data->>'amount')::decimal), 0) as total_payment_amount,
  t.created_at,
  t.updated_at
FROM tenants t
LEFT JOIN bet_events be ON t.id = be.tenant_id
LEFT JOIN payment_events pe ON t.id = pe.tenant_id
GROUP BY t.id, t.name, t.slug, t.status, t.plan, t.created_at, t.updated_at;

CREATE UNIQUE INDEX IF NOT EXISTS idx_tenants_summary_pk ON tenants_summary_view(tenant_id);

-- user_activity_view
CREATE MATERIALIZED VIEW IF NOT EXISTS user_activity_view AS
WITH user_events AS (
  SELECT tenant_id, (event_data->>'user_id') as user_id, timestamp FROM bet_events
  UNION ALL
  SELECT tenant_id, (event_data->>'user_id') as user_id, timestamp FROM payment_events
  UNION ALL
  SELECT tenant_id, (event_data->>'user_id') as user_id, timestamp FROM balance_events
  UNION ALL
  SELECT tenant_id, (event_data->>'user_id') as user_id, timestamp FROM compliance_events
)
SELECT 
  tenant_id,
  user_id,
  MAX(timestamp) as last_activity_timestamp,
  to_timestamp(MAX(timestamp)::bigint / 1000) as last_activity_at,
  COUNT(*) as total_events
FROM user_events
WHERE user_id IS NOT NULL
GROUP BY tenant_id, user_id;

CREATE UNIQUE INDEX IF NOT EXISTS idx_user_activity_pk ON user_activity_view(tenant_id, user_id);
CREATE INDEX IF NOT EXISTS idx_user_activity_last_activity ON user_activity_view(tenant_id, last_activity_timestamp DESC);

-- ============================================
-- REFRESH FUNCTION (used by Kubernetes CronJob)
-- ============================================

DO $$
BEGIN
  -- Ensure plpgsql is available
  PERFORM 1 FROM pg_language WHERE lanname = 'plpgsql';
  IF NOT FOUND THEN
    CREATE LANGUAGE plpgsql;
  END IF;
END$$;

CREATE OR REPLACE FUNCTION refresh_aggregate_views()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  r record;
BEGIN
  FOR r IN SELECT schemaname, matviewname FROM pg_matviews LOOP
    BEGIN
      EXECUTE format('REFRESH MATERIALIZED VIEW CONCURRENTLY %I.%I', r.schemaname, r.matviewname);
    EXCEPTION WHEN feature_not_supported OR undefined_table OR insufficient_privilege OR undefined_function THEN
      EXECUTE format('REFRESH MATERIALIZED VIEW %I.%I', r.schemaname, r.matviewname);
    END;
  END LOOP;
END;
$$;

-- ============================================
-- IDEMPOTENCY PROTECTION (теперь встроено в таблицы выше)
-- Unique constraints на idempotency_key уже созданы при CREATE TABLE
-- ============================================
