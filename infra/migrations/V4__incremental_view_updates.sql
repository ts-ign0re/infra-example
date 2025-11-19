-- ============================================
-- V4: Incremental View Updates - Convert to Regular Tables
-- Materialized views → Regular tables для возможности инкрементальных обновлений
-- ============================================

-- Drop old triggers and functions from V2
DROP TRIGGER IF EXISTS after_bet_events_insert ON bet_events CASCADE;
DROP TRIGGER IF EXISTS after_balance_events_insert ON balance_events CASCADE;
DROP TRIGGER IF EXISTS after_payment_events_insert ON payment_events CASCADE;
DROP FUNCTION IF EXISTS trigger_refresh_bets_view() CASCADE;
DROP FUNCTION IF EXISTS trigger_refresh_balance_view() CASCADE;
DROP FUNCTION IF EXISTS trigger_refresh_payments_view() CASCADE;

-- ============================================
-- CONVERT BETS_VIEW: Materialized View → Table
-- ============================================

-- Drop materialized view
DROP MATERIALIZED VIEW IF EXISTS bets_view CASCADE;

-- Create as regular table (with same structure)
CREATE TABLE IF NOT EXISTS bets_view (
    tenant_id BIGINT NOT NULL,
    bet_id VARCHAR(255) NOT NULL,
    idempotency_key VARCHAR(255) NOT NULL,
    user_id TEXT,
    amount NUMERIC,
    odds NUMERIC,
    selection TEXT,
    event_id TEXT,
    market_id TEXT,
    status TEXT,
    payout NUMERIC,
    last_updated_timestamp BIGINT,
    last_updated_at TIMESTAMP,
    PRIMARY KEY (tenant_id, bet_id)
);

-- Recreate indexes
CREATE INDEX IF NOT EXISTS idx_bets_view_tenant_user ON bets_view(tenant_id, user_id);
CREATE INDEX IF NOT EXISTS idx_bets_view_status ON bets_view(tenant_id, status);
CREATE INDEX IF NOT EXISTS idx_bets_view_event ON bets_view(tenant_id, event_id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_bets_view_idempotency ON bets_view(tenant_id, idempotency_key);

-- Distribute table
SELECT create_distributed_table('bets_view', 'tenant_id');

-- Populate from events
INSERT INTO bets_view
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
FROM latest_bet_events
ON CONFLICT (tenant_id, bet_id) DO NOTHING;

-- ============================================
-- CONVERT PAYMENTS_VIEW: Materialized View → Table
-- ============================================

DROP MATERIALIZED VIEW IF EXISTS payments_view CASCADE;

CREATE TABLE IF NOT EXISTS payments_view (
    tenant_id BIGINT NOT NULL,
    payment_id VARCHAR(255) NOT NULL,
    idempotency_key VARCHAR(255) NOT NULL,
    user_id TEXT,
    amount NUMERIC,
    currency TEXT,
    payment_method TEXT,
    external_id TEXT,
    payment_type TEXT,
    status TEXT,
    last_updated_timestamp BIGINT,
    last_updated_at TIMESTAMP,
    PRIMARY KEY (tenant_id, payment_id)
);

CREATE INDEX IF NOT EXISTS idx_payments_view_tenant_user ON payments_view(tenant_id, user_id);
CREATE INDEX IF NOT EXISTS idx_payments_view_status ON payments_view(tenant_id, status);
CREATE INDEX IF NOT EXISTS idx_payments_view_type ON payments_view(tenant_id, payment_type);
CREATE INDEX IF NOT EXISTS idx_payments_view_external ON payments_view(tenant_id, external_id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_payments_view_idempotency ON payments_view(tenant_id, idempotency_key);

SELECT create_distributed_table('payments_view', 'tenant_id');

-- Populate from events
INSERT INTO payments_view
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
FROM latest_payment_events
ON CONFLICT (tenant_id, payment_id) DO NOTHING;

-- ============================================
-- INCREMENTAL UPDATE TRIGGERS
-- ============================================

-- Trigger function для bet_events
CREATE OR REPLACE FUNCTION incremental_update_bets_view() RETURNS TRIGGER AS $$
BEGIN
  -- UPSERT: обновить или вставить
  INSERT INTO bets_view (
    tenant_id, bet_id, idempotency_key, user_id, amount, odds, 
    selection, event_id, market_id, status, payout, 
    last_updated_timestamp, last_updated_at
  )
  SELECT 
    tenant_id,
    aggregate_id as bet_id,
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
  FROM bet_events
  WHERE tenant_id = NEW.tenant_id 
    AND aggregate_id = NEW.aggregate_id
  ORDER BY timestamp DESC
  LIMIT 1
  ON CONFLICT (tenant_id, bet_id) 
  DO UPDATE SET
    idempotency_key = EXCLUDED.idempotency_key,
    user_id = EXCLUDED.user_id,
    amount = EXCLUDED.amount,
    odds = EXCLUDED.odds,
    selection = EXCLUDED.selection,
    event_id = EXCLUDED.event_id,
    market_id = EXCLUDED.market_id,
    status = EXCLUDED.status,
    payout = EXCLUDED.payout,
    last_updated_timestamp = EXCLUDED.last_updated_timestamp,
    last_updated_at = EXCLUDED.last_updated_at;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER after_bet_events_insert_incremental
AFTER INSERT ON bet_events
FOR EACH ROW
EXECUTE FUNCTION incremental_update_bets_view();

-- Trigger function для payment_events
CREATE OR REPLACE FUNCTION incremental_update_payments_view() RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO payments_view (
    tenant_id, payment_id, idempotency_key, user_id, amount, currency,
    payment_method, external_id, payment_type, status,
    last_updated_timestamp, last_updated_at
  )
  SELECT 
    tenant_id,
    aggregate_id as payment_id,
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
  FROM payment_events
  WHERE tenant_id = NEW.tenant_id 
    AND aggregate_id = NEW.aggregate_id
  ORDER BY timestamp DESC
  LIMIT 1
  ON CONFLICT (tenant_id, payment_id) 
  DO UPDATE SET
    idempotency_key = EXCLUDED.idempotency_key,
    user_id = EXCLUDED.user_id,
    amount = EXCLUDED.amount,
    currency = EXCLUDED.currency,
    payment_method = EXCLUDED.payment_method,
    external_id = EXCLUDED.external_id,
    payment_type = EXCLUDED.payment_type,
    status = EXCLUDED.status,
    last_updated_timestamp = EXCLUDED.last_updated_timestamp,
    last_updated_at = EXCLUDED.last_updated_at;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER after_payment_events_insert_incremental
AFTER INSERT ON payment_events
FOR EACH ROW
EXECUTE FUNCTION incremental_update_payments_view();

-- ============================================
-- AGGREGATE VIEWS остаются materialized
-- Обновляются периодически через CronJob
-- ============================================

-- Функция для периодического обновления агрегатных views
CREATE OR REPLACE FUNCTION refresh_aggregate_views() RETURNS void AS $$
BEGIN
  REFRESH MATERIALIZED VIEW CONCURRENTLY tenants_summary_view;
  REFRESH MATERIALIZED VIEW CONCURRENTLY user_activity_view;
  REFRESH MATERIALIZED VIEW CONCURRENTLY user_balances_view;
END;
$$ LANGUAGE plpgsql;

-- ============================================
-- NOTES:
-- 1. bets_view и payments_view теперь обычные таблицы (не materialized)
-- 2. Инкрементальное обновление через UPSERT (~5-10ms)
-- 3. Агрегатные views остаются materialized (обновляются раз в 5 минут)
-- ============================================

