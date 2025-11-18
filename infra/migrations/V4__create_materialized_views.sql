-- ============================================
-- V4: Create materialized views for read models (projections)
-- ============================================

-- ============================================
-- 1. BETS PROJECTION - текущее состояние всех ставок
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
  (event_data->>'stake')::decimal as stake,
  (event_data->>'odds')::decimal as odds,
  (event_data->>'fixture_id') as fixture_id,
  CASE 
    WHEN event_type = 'V1_BETS_BET_PLACED' THEN 'placed'
    WHEN event_type = 'V1_BETS_BET_CONFIRMED' THEN 'confirmed'
    WHEN event_type = 'V1_BETS_BET_SETTLED' THEN 'settled'
    WHEN event_type = 'V1_BETS_BET_CANCELLED' THEN 'cancelled'
    WHEN event_type = 'V1_BETS_BET_VOIDED' THEN 'voided'
    ELSE 'unknown'
  END as status,
  (event_data->>'result') as result,
  (event_data->>'payout')::decimal as payout,
  timestamp as last_updated_timestamp,
  created_at as last_updated_at
FROM latest_bet_events;

-- Индексы для быстрого поиска
CREATE INDEX IF NOT EXISTS idx_bets_view_tenant_user ON bets_view(tenant_id, user_id);
CREATE INDEX IF NOT EXISTS idx_bets_view_status ON bets_view(tenant_id, status);
CREATE INDEX IF NOT EXISTS idx_bets_view_fixture ON bets_view(tenant_id, fixture_id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_bets_view_pk ON bets_view(tenant_id, bet_id);

-- ============================================
-- 2. USER BALANCES PROJECTION - текущий баланс пользователей
-- ============================================
CREATE MATERIALIZED VIEW IF NOT EXISTS user_balances_view AS
WITH balance_changes AS (
  SELECT 
    tenant_id,
    (event_data->>'user_id') as user_id,
    CASE 
      WHEN event_type = 'V1_BALANCES_BALANCE_INCREASED' THEN (event_data->>'amount')::decimal
      WHEN event_type = 'V1_BALANCES_BALANCE_DECREASED' THEN -(event_data->>'amount')::decimal
      WHEN event_type = 'V1_BALANCES_BALANCE_RESERVED' THEN -(event_data->>'amount')::decimal
      WHEN event_type = 'V1_BALANCES_BALANCE_RELEASED' THEN (event_data->>'amount')::decimal
      ELSE 0
    END as amount,
    timestamp,
    created_at
  FROM balance_events
)
SELECT 
  tenant_id,
  user_id,
  SUM(amount) as balance,
  COUNT(*) as transaction_count,
  MAX(timestamp) as last_transaction_timestamp,
  MAX(created_at) as last_transaction_at
FROM balance_changes
GROUP BY tenant_id, user_id;

CREATE UNIQUE INDEX IF NOT EXISTS idx_user_balances_view_pk ON user_balances_view(tenant_id, user_id);
CREATE INDEX IF NOT EXISTS idx_user_balances_view_balance ON user_balances_view(tenant_id, balance);

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
  COALESCE(bet_stats.total_bets, 0) as total_bets,
  COALESCE(bet_stats.active_bets, 0) as active_bets,
  COALESCE(bet_stats.total_stake, 0) as total_stake,
  COALESCE(payment_stats.total_deposits, 0) as total_deposits,
  COALESCE(payment_stats.total_withdrawals, 0) as total_withdrawals,
  COALESCE(user_stats.total_users, 0) as total_users,
  COALESCE(user_stats.total_balance, 0) as total_balance,
  NOW() as last_refreshed_at
FROM tenants t
LEFT JOIN (
  SELECT 
    tenant_id,
    COUNT(*) as total_bets,
    COUNT(*) FILTER (WHERE status IN ('placed', 'confirmed')) as active_bets,
    SUM(stake) as total_stake
  FROM bets_view
  GROUP BY tenant_id
) bet_stats ON t.id = bet_stats.tenant_id
LEFT JOIN (
  SELECT 
    tenant_id,
    SUM(amount) FILTER (WHERE payment_type = 'deposit' AND status = 'completed') as total_deposits,
    SUM(amount) FILTER (WHERE payment_type = 'withdrawal' AND status = 'completed') as total_withdrawals
  FROM payments_view
  GROUP BY tenant_id
) payment_stats ON t.id = payment_stats.tenant_id
LEFT JOIN (
  SELECT 
    tenant_id,
    COUNT(DISTINCT user_id) as total_users,
    SUM(balance) as total_balance
  FROM user_balances_view
  GROUP BY tenant_id
) user_stats ON t.id = user_stats.tenant_id;

CREATE UNIQUE INDEX IF NOT EXISTS idx_tenants_summary_view_pk ON tenants_summary_view(tenant_id);

-- ============================================
-- 5. USER ACTIVITY - активность пользователей
-- ============================================
CREATE MATERIALIZED VIEW IF NOT EXISTS user_activity_view AS
WITH user_bets AS (
  SELECT 
    tenant_id,
    user_id,
    COUNT(*) as total_bets,
    SUM(stake) as total_wagered,
    SUM(CASE WHEN status = 'settled' AND result = 'win' THEN payout ELSE 0 END) as total_winnings,
    MAX(last_updated_timestamp) as last_bet_at
  FROM bets_view
  GROUP BY tenant_id, user_id
),
user_payments AS (
  SELECT 
    tenant_id,
    user_id,
    SUM(CASE WHEN payment_type = 'deposit' THEN amount ELSE 0 END) as total_deposited,
    SUM(CASE WHEN payment_type = 'withdrawal' THEN amount ELSE 0 END) as total_withdrawn,
    MAX(last_updated_timestamp) as last_payment_at
  FROM payments_view
  GROUP BY tenant_id, user_id
)
SELECT 
  COALESCE(ub.tenant_id, up.tenant_id) as tenant_id,
  COALESCE(ub.user_id, up.user_id) as user_id,
  COALESCE(bal.balance, 0) as current_balance,
  COALESCE(ub.total_bets, 0) as total_bets,
  COALESCE(ub.total_wagered, 0) as total_wagered,
  COALESCE(ub.total_winnings, 0) as total_winnings,
  COALESCE(up.total_deposited, 0) as total_deposited,
  COALESCE(up.total_withdrawn, 0) as total_withdrawn,
  GREATEST(ub.last_bet_at, up.last_payment_at) as last_activity_at
FROM user_bets ub
FULL OUTER JOIN user_payments up ON ub.tenant_id = up.tenant_id AND ub.user_id = up.user_id
LEFT JOIN user_balances_view bal ON COALESCE(ub.tenant_id, up.tenant_id) = bal.tenant_id 
  AND COALESCE(ub.user_id, up.user_id) = bal.user_id;

CREATE UNIQUE INDEX IF NOT EXISTS idx_user_activity_view_pk ON user_activity_view(tenant_id, user_id);
CREATE INDEX IF NOT EXISTS idx_user_activity_view_last_activity ON user_activity_view(tenant_id, last_activity_at);

-- ============================================
-- REFRESH FUNCTIONS
-- ============================================

-- Функция для обновления всех materialized views
CREATE OR REPLACE FUNCTION refresh_all_views()
RETURNS void AS $$
BEGIN
  REFRESH MATERIALIZED VIEW CONCURRENTLY bets_view;
  REFRESH MATERIALIZED VIEW CONCURRENTLY user_balances_view;
  REFRESH MATERIALIZED VIEW CONCURRENTLY payments_view;
  REFRESH MATERIALIZED VIEW CONCURRENTLY tenants_summary_view;
  REFRESH MATERIALIZED VIEW CONCURRENTLY user_activity_view;
END;
$$ LANGUAGE plpgsql;

-- Функция для обновления view конкретного тенанта (для production с большими данными)
CREATE OR REPLACE FUNCTION refresh_tenant_views(p_tenant_id bigint)
RETURNS void AS $$
BEGIN
  -- Для больших систем можно добавить инкрементальное обновление
  -- Пока используем полное обновление всех views
  PERFORM refresh_all_views();
END;
$$ LANGUAGE plpgsql;

-- ============================================
-- COMMENTS для документации
-- ============================================
COMMENT ON MATERIALIZED VIEW bets_view IS 'Текущее состояние всех ставок (проекция из bet_events)';
COMMENT ON MATERIALIZED VIEW user_balances_view IS 'Текущие балансы пользователей (проекция из balance_events)';
COMMENT ON MATERIALIZED VIEW payments_view IS 'История платежей (проекция из payment_events)';
COMMENT ON MATERIALIZED VIEW tenants_summary_view IS 'Агрегированная статистика по тенантам';
COMMENT ON MATERIALIZED VIEW user_activity_view IS 'Активность и статистика пользователей';
