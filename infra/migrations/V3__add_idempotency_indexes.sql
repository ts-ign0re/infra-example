-- ============================================
-- V3: Add idempotency key indexes for duplicate protection
-- ============================================

-- Indexes for fast idempotency key lookup in metadata JSONB column
-- These prevent duplicate critical operations (payments, bets, etc.)

CREATE INDEX IF NOT EXISTS idx_payment_events_idempotency 
ON payment_events(tenant_id, ((metadata->>'idempotency_key'))) 
WHERE metadata->>'idempotency_key' IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_bet_events_idempotency 
ON bet_events(tenant_id, ((metadata->>'idempotency_key'))) 
WHERE metadata->>'idempotency_key' IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_balance_events_idempotency 
ON balance_events(tenant_id, ((metadata->>'idempotency_key'))) 
WHERE metadata->>'idempotency_key' IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_compliance_events_idempotency 
ON compliance_events(tenant_id, ((metadata->>'idempotency_key'))) 
WHERE metadata->>'idempotency_key' IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_tenant_events_idempotency 
ON tenant_events(tenant_id, ((metadata->>'idempotency_key'))) 
WHERE metadata->>'idempotency_key' IS NOT NULL;

-- Note: system_events usually don't need idempotency protection
-- as they are non-critical analytics events
