-- ============================================
-- V2: Read Views as Tables with Incremental Updates
-- Read-optimized projections with ROW-level trigger updates
-- ============================================

-- ============================================
-- BETS_VIEW: Regular Table with Triggers
-- ============================================

-- Create as regular table
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

-- ============================================
-- PAYMENTS_VIEW: Regular Table with Triggers
-- ============================================

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
-- VIEW UPDATE STRATEGY
-- ============================================
-- ⚠️ ВАЖНО: Citus НЕ поддерживает триггеры на distributed tables!
--
-- Read views (bets_view, payments_view) обновляются:
-- 1. При вставке события - приложение делает UPSERT в view
-- 2. Или периодически через scheduled job (каждые N секунд)
-- 
-- Пример UPSERT из приложения:
-- INSERT INTO bets_view (...) VALUES (...) 
-- ON CONFLICT (tenant_id, bet_id) DO UPDATE SET ...
--
-- Преимущества:
-- - Контроль производительности на уровне приложения
-- - Возможность батчинга обновлений
-- - Нет overhead от триггеров на каждый INSERT
-- ============================================


