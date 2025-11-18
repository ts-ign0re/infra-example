-- ============================================
-- V2: Materialized Views & Reactive Triggers
-- Read-optimized projections with automatic updates
-- ============================================

-- ============================================
-- 1. BETS PROJECTION - текущее состояние ставок
-- ============================================
CREATE MATERIALIZED VIEW IF NOT EXISTS bets_view AS
WITH latest_bet_events AS (
  SELECT DISTINCT ON (tenant_id, aggregate_id)
    tenant_id,
    aggregate_id as bet_id,
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

-- ============================================
-- 2. USER BALANCES PROJECTION
-- ============================================
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
  MAX(timestamp) as last_updated_timestamp,
  MAX(created_at) as last_updated_at
FROM balance_events
GROUP BY tenant_id, (event_data->>'user_id');

CREATE UNIQUE INDEX IF NOT EXISTS idx_user_balances_view_pk ON user_balances_view(tenant_id, user_id);

-- ============================================
-- 3. PAYMENTS PROJECTION - история платежей
-- ============================================
CREATE MATERIALIZED VIEW IF NOT EXISTS payments_view AS
WITH latest_payment_events AS (
  SELECT DISTINCT ON (tenant_id, aggregate_id)
    tenant_id,
    aggregate_id as payment_id,
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

-- ============================================
-- 4. TENANTS SUMMARY - аггрегированная статистика по тенанту
-- ============================================
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

-- ============================================
-- 5. USER ACTIVITY - последняя активность пользователей
-- ============================================
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
-- REACTIVE TRIGGERS - автоматическое обновление views
-- Trigger срабатывает после каждого INSERT/UPDATE
-- ============================================

-- Trigger function для bet_events
CREATE OR REPLACE FUNCTION trigger_refresh_bets_view() RETURNS TRIGGER AS $$
BEGIN
  REFRESH MATERIALIZED VIEW CONCURRENTLY bets_view;
  REFRESH MATERIALIZED VIEW CONCURRENTLY tenants_summary_view;
  REFRESH MATERIALIZED VIEW CONCURRENTLY user_activity_view;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER after_bet_events_insert
AFTER INSERT OR UPDATE ON bet_events
FOR EACH STATEMENT
EXECUTE FUNCTION trigger_refresh_bets_view();

-- Trigger function для balance_events
CREATE OR REPLACE FUNCTION trigger_refresh_balance_view() RETURNS TRIGGER AS $$
BEGIN
  REFRESH MATERIALIZED VIEW CONCURRENTLY user_balances_view;
  REFRESH MATERIALIZED VIEW CONCURRENTLY user_activity_view;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER after_balance_events_insert
AFTER INSERT OR UPDATE ON balance_events
FOR EACH STATEMENT
EXECUTE FUNCTION trigger_refresh_balance_view();

-- Trigger function для payment_events
CREATE OR REPLACE FUNCTION trigger_refresh_payments_view() RETURNS TRIGGER AS $$
BEGIN
  REFRESH MATERIALIZED VIEW CONCURRENTLY payments_view;
  REFRESH MATERIALIZED VIEW CONCURRENTLY tenants_summary_view;
  REFRESH MATERIALIZED VIEW CONCURRENTLY user_activity_view;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER after_payment_events_insert
AFTER INSERT OR UPDATE ON payment_events
FOR EACH STATEMENT
EXECUTE FUNCTION trigger_refresh_payments_view();

-- ============================================
-- UTILITY FUNCTION - проверка свежести views
-- ============================================
CREATE OR REPLACE FUNCTION get_views_refresh_status()
RETURNS TABLE (
  view_name TEXT,
  refresh_count BIGINT,
  seconds_ago BIGINT,
  status TEXT
) AS $$
BEGIN
  RETURN QUERY
  SELECT 
    mv.view_name::TEXT,
    COALESCE(mv.refresh_count, 0) as refresh_count,
    COALESCE(EXTRACT(EPOCH FROM (NOW() - mv.last_refresh))::BIGINT, 999) as seconds_ago,
    CASE 
      WHEN mv.last_refresh IS NULL THEN 'never'
      WHEN EXTRACT(EPOCH FROM (NOW() - mv.last_refresh)) < 10 THEN 'fresh'
      WHEN EXTRACT(EPOCH FROM (NOW() - mv.last_refresh)) < 60 THEN 'aging'
      ELSE 'stale'
    END as status
  FROM (
    SELECT 
      'bets_view' as view_name,
      COUNT(*) as refresh_count,
      MAX(last_updated_at) as last_refresh
    FROM bets_view
    UNION ALL
    SELECT 
      'payments_view',
      COUNT(*),
      MAX(last_updated_at)
    FROM payments_view
    UNION ALL
    SELECT 
      'user_balances_view',
      COUNT(*),
      MAX(last_updated_at)
    FROM user_balances_view
    UNION ALL
    SELECT 
      'tenants_summary_view',
      COUNT(*),
      MAX(updated_at)
    FROM tenants_summary_view
    UNION ALL
    SELECT 
      'user_activity_view',
      COUNT(*),
      MAX(last_activity_at)
    FROM user_activity_view
  ) mv;
END;
$$ LANGUAGE plpgsql;
