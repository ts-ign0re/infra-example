-- ============================================
-- V3: Update Materialized Views with idempotency_key
-- idempotency_key теперь прямое поле в event tables (не в metadata)
-- ============================================

-- Drop existing views (will be recreated with idempotency_key)
DROP MATERIALIZED VIEW IF EXISTS bets_view CASCADE;
DROP MATERIALIZED VIEW IF EXISTS payments_view CASCADE;

-- ============================================
-- RECREATE BETS VIEW with idempotency_key
-- ============================================
CREATE MATERIALIZED VIEW bets_view AS
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

-- Indexes
CREATE INDEX IF NOT EXISTS idx_bets_view_tenant_user ON bets_view(tenant_id, user_id);
CREATE INDEX IF NOT EXISTS idx_bets_view_status ON bets_view(tenant_id, status);
CREATE INDEX IF NOT EXISTS idx_bets_view_event ON bets_view(tenant_id, event_id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_bets_view_pk ON bets_view(tenant_id, bet_id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_bets_view_idempotency ON bets_view(tenant_id, idempotency_key);

-- ============================================
-- RECREATE PAYMENTS VIEW with idempotency_key
-- ============================================
CREATE MATERIALIZED VIEW payments_view AS
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

-- Indexes
CREATE INDEX IF NOT EXISTS idx_payments_view_tenant_user ON payments_view(tenant_id, user_id);
CREATE INDEX IF NOT EXISTS idx_payments_view_status ON payments_view(tenant_id, status);
CREATE INDEX IF NOT EXISTS idx_payments_view_type ON payments_view(tenant_id, payment_type);
CREATE INDEX IF NOT EXISTS idx_payments_view_external ON payments_view(tenant_id, external_id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_payments_view_pk ON payments_view(tenant_id, payment_id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_payments_view_idempotency ON payments_view(tenant_id, idempotency_key);

-- ============================================
-- Note: Triggers from V2 will continue to work
-- They refresh materialized views automatically
-- ============================================
