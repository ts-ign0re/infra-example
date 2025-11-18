-- ============================================
-- V5: Setup reactive triggers for real-time materialized views refresh
-- ============================================
--
-- АРХИТЕКТУРА: Используем PostgreSQL триггеры вместо pg_cron
-- ПРИЧИНА: pg_cron недоступен в образе citusdata/citus
-- 
-- КОНЦЕПЦИЯ: После каждого INSERT в event tables автоматически обновляем views
-- Задержка: ~100-300ms - приемлемо для беттинга (не банковский софт)
-- Используем STATEMENT-level триггеры (не ROW-level) для эффективности
--
-- АЛЬТЕРНАТИВЫ (не используем):
--  - pg_cron: требует custom образ PostgreSQL
--  - External scheduler: дополнительная сложность
--  - Manual refresh: не real-time
-- ============================================

-- Track refresh statistics
CREATE TABLE IF NOT EXISTS materialized_views_refresh_log (
  view_name text PRIMARY KEY,
  last_refreshed_at timestamp NOT NULL DEFAULT NOW(),
  refresh_count bigint NOT NULL DEFAULT 0,
  avg_refresh_time_ms integer DEFAULT 0
);

-- Insert initial records
INSERT INTO materialized_views_refresh_log (view_name) VALUES 
  ('bets_view'),
  ('user_balances_view'),
  ('payments_view'),
  ('tenants_summary_view'),
  ('user_activity_view')
ON CONFLICT (view_name) DO NOTHING;

-- Enhanced refresh function with timing
CREATE OR REPLACE FUNCTION refresh_all_views_with_timing()
RETURNS void AS $$
DECLARE
  start_time timestamp;
  end_time timestamp;
  duration_ms integer;
BEGIN
  start_time := clock_timestamp();
  
  -- Refresh all views concurrently
  REFRESH MATERIALIZED VIEW CONCURRENTLY bets_view;
  REFRESH MATERIALIZED VIEW CONCURRENTLY user_balances_view;
  REFRESH MATERIALIZED VIEW CONCURRENTLY payments_view;
  REFRESH MATERIALIZED VIEW CONCURRENTLY tenants_summary_view;
  REFRESH MATERIALIZED VIEW CONCURRENTLY user_activity_view;
  
  end_time := clock_timestamp();
  duration_ms := EXTRACT(EPOCH FROM (end_time - start_time)) * 1000;
  
  -- Update log
  UPDATE materialized_views_refresh_log
  SET last_refreshed_at = NOW(),
      refresh_count = refresh_count + 1,
      avg_refresh_time_ms = (avg_refresh_time_ms + duration_ms) / 2;
      
  RAISE NOTICE 'Views refreshed in % ms', duration_ms;
END;
$$ LANGUAGE plpgsql;

-- Trigger function for bet events
CREATE OR REPLACE FUNCTION trigger_refresh_bets_view()
RETURNS TRIGGER AS $$
BEGIN
  -- Refresh only bets_view and dependent views
  REFRESH MATERIALIZED VIEW CONCURRENTLY bets_view;
  REFRESH MATERIALIZED VIEW CONCURRENTLY user_activity_view;
  REFRESH MATERIALIZED VIEW CONCURRENTLY tenants_summary_view;
  
  UPDATE materialized_views_refresh_log
  SET last_refreshed_at = NOW(),
      refresh_count = refresh_count + 1
  WHERE view_name IN ('bets_view', 'user_activity_view', 'tenants_summary_view');
  
  RETURN NULL;
END;
$$ LANGUAGE plpgsql;

-- Trigger function for balance events
CREATE OR REPLACE FUNCTION trigger_refresh_balances_view()
RETURNS TRIGGER AS $$
BEGIN
  -- Refresh balance-related views
  REFRESH MATERIALIZED VIEW CONCURRENTLY user_balances_view;
  REFRESH MATERIALIZED VIEW CONCURRENTLY user_activity_view;
  REFRESH MATERIALIZED VIEW CONCURRENTLY tenants_summary_view;
  
  UPDATE materialized_views_refresh_log
  SET last_refreshed_at = NOW(),
      refresh_count = refresh_count + 1
  WHERE view_name IN ('user_balances_view', 'user_activity_view', 'tenants_summary_view');
  
  RETURN NULL;
END;
$$ LANGUAGE plpgsql;

-- Trigger function for payment events
CREATE OR REPLACE FUNCTION trigger_refresh_payments_view()
RETURNS TRIGGER AS $$
BEGIN
  -- Refresh payment-related views
  REFRESH MATERIALIZED VIEW CONCURRENTLY payments_view;
  REFRESH MATERIALIZED VIEW CONCURRENTLY user_activity_view;
  REFRESH MATERIALIZED VIEW CONCURRENTLY tenants_summary_view;
  
  UPDATE materialized_views_refresh_log
  SET last_refreshed_at = NOW(),
      refresh_count = refresh_count + 1
  WHERE view_name IN ('payments_view', 'user_activity_view', 'tenants_summary_view');
  
  RETURN NULL;
END;
$$ LANGUAGE plpgsql;

-- Create STATEMENT-level triggers (более эффективны чем ROW-level)
DROP TRIGGER IF EXISTS after_bet_events_insert ON bet_events;
CREATE TRIGGER after_bet_events_insert
AFTER INSERT ON bet_events
FOR EACH STATEMENT
EXECUTE FUNCTION trigger_refresh_bets_view();

DROP TRIGGER IF EXISTS after_balance_events_insert ON balance_events;
CREATE TRIGGER after_balance_events_insert
AFTER INSERT ON balance_events
FOR EACH STATEMENT
EXECUTE FUNCTION trigger_refresh_balances_view();

DROP TRIGGER IF EXISTS after_payment_events_insert ON payment_events;
CREATE TRIGGER after_payment_events_insert
AFTER INSERT ON payment_events
FOR EACH STATEMENT
EXECUTE FUNCTION trigger_refresh_payments_view();

-- Optional: Update triggers for completeness
DROP TRIGGER IF EXISTS after_bet_events_update ON bet_events;
CREATE TRIGGER after_bet_events_update
AFTER UPDATE ON bet_events
FOR EACH STATEMENT
EXECUTE FUNCTION trigger_refresh_bets_view();

DROP TRIGGER IF EXISTS after_balance_events_update ON balance_events;
CREATE TRIGGER after_balance_events_update
AFTER UPDATE ON balance_events
FOR EACH STATEMENT
EXECUTE FUNCTION trigger_refresh_balances_view();

DROP TRIGGER IF EXISTS after_payment_events_update ON payment_events;
CREATE TRIGGER after_payment_events_update
AFTER UPDATE ON payment_events
FOR EACH STATEMENT
EXECUTE FUNCTION trigger_refresh_payments_view();

-- Helper function to check refresh status
CREATE OR REPLACE FUNCTION get_views_refresh_status()
RETURNS TABLE(
  view_name text,
  last_refreshed_at timestamp,
  seconds_ago integer,
  refresh_count bigint,
  avg_refresh_time_ms integer,
  status text
) AS $$
BEGIN
  RETURN QUERY
  SELECT 
    l.view_name,
    l.last_refreshed_at,
    EXTRACT(EPOCH FROM (NOW() - l.last_refreshed_at))::integer as seconds_ago,
    l.refresh_count,
    l.avg_refresh_time_ms,
    CASE 
      WHEN EXTRACT(EPOCH FROM (NOW() - l.last_refreshed_at)) > 60 THEN 'stale'
      WHEN EXTRACT(EPOCH FROM (NOW() - l.last_refreshed_at)) > 30 THEN 'aging'
      ELSE 'fresh'
    END as status
  FROM materialized_views_refresh_log l
  ORDER BY l.view_name;
END;
$$ LANGUAGE plpgsql;

-- Helper to manually refresh all views
CREATE OR REPLACE FUNCTION manual_refresh_all_views()
RETURNS text AS $$
BEGIN
  PERFORM refresh_all_views_with_timing();
  RETURN 'All views refreshed successfully';
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION trigger_refresh_bets_view() IS 'Automatically refreshes bets-related views after INSERT/UPDATE';
COMMENT ON FUNCTION trigger_refresh_balances_view() IS 'Automatically refreshes balance-related views after INSERT/UPDATE';
COMMENT ON FUNCTION trigger_refresh_payments_view() IS 'Automatically refreshes payment-related views after INSERT/UPDATE';
COMMENT ON FUNCTION get_views_refresh_status() IS 'Check when materialized views were last refreshed';
COMMENT ON FUNCTION manual_refresh_all_views() IS 'Manually trigger refresh of all views';


