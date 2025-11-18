-- ============================================
-- V6: Add UNIQUE constraints for idempotency keys
-- Prevents duplicate critical operations
-- ============================================

-- First, clean up any existing duplicates (keep only the oldest record per idempotency_key)
-- This is a one-time cleanup for existing data

-- Payment events
DELETE FROM payment_events
WHERE id IN (
  SELECT id FROM (
    SELECT id,
           ROW_NUMBER() OVER (
             PARTITION BY tenant_id, (metadata->>'idempotency_key')
             ORDER BY created_at
           ) as rn
    FROM payment_events
    WHERE metadata->>'idempotency_key' IS NOT NULL
  ) t
  WHERE rn > 1
);

-- Bet events
DELETE FROM bet_events
WHERE id IN (
  SELECT id FROM (
    SELECT id,
           ROW_NUMBER() OVER (
             PARTITION BY tenant_id, (metadata->>'idempotency_key')
             ORDER BY created_at
           ) as rn
    FROM bet_events
    WHERE metadata->>'idempotency_key' IS NOT NULL
  ) t
  WHERE rn > 1
);

-- Balance events
DELETE FROM balance_events
WHERE id IN (
  SELECT id FROM (
    SELECT id,
           ROW_NUMBER() OVER (
             PARTITION BY tenant_id, (metadata->>'idempotency_key')
             ORDER BY created_at
           ) as rn
    FROM balance_events
    WHERE metadata->>'idempotency_key' IS NOT NULL
  ) t
  WHERE rn > 1
);

-- Compliance events
DELETE FROM compliance_events
WHERE id IN (
  SELECT id FROM (
    SELECT id,
           ROW_NUMBER() OVER (
             PARTITION BY tenant_id, (metadata->>'idempotency_key')
             ORDER BY created_at
           ) as rn
    FROM compliance_events
    WHERE metadata->>'idempotency_key' IS NOT NULL
  ) t
  WHERE rn > 1
);

-- Tenant events
DELETE FROM tenant_events
WHERE id IN (
  SELECT id FROM (
    SELECT id,
           ROW_NUMBER() OVER (
             PARTITION BY tenant_id, (metadata->>'idempotency_key')
             ORDER BY created_at
           ) as rn
    FROM tenant_events
    WHERE metadata->>'idempotency_key' IS NOT NULL
  ) t
  WHERE rn > 1
);

-- Drop old non-unique indexes
DROP INDEX IF EXISTS idx_payment_events_idempotency;
DROP INDEX IF EXISTS idx_bet_events_idempotency;
DROP INDEX IF EXISTS idx_balance_events_idempotency;
DROP INDEX IF EXISTS idx_compliance_events_idempotency;
DROP INDEX IF EXISTS idx_tenant_events_idempotency;

-- Create UNIQUE indexes to enforce idempotency at DB level
CREATE UNIQUE INDEX IF NOT EXISTS idx_payment_events_idempotency_unique 
ON payment_events(tenant_id, ((metadata->>'idempotency_key'))) 
WHERE metadata->>'idempotency_key' IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS idx_bet_events_idempotency_unique 
ON bet_events(tenant_id, ((metadata->>'idempotency_key'))) 
WHERE metadata->>'idempotency_key' IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS idx_balance_events_idempotency_unique 
ON balance_events(tenant_id, ((metadata->>'idempotency_key'))) 
WHERE metadata->>'idempotency_key' IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS idx_compliance_events_idempotency_unique 
ON compliance_events(tenant_id, ((metadata->>'idempotency_key'))) 
WHERE metadata->>'idempotency_key' IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS idx_tenant_events_idempotency_unique 
ON tenant_events(tenant_id, ((metadata->>'idempotency_key'))) 
WHERE metadata->>'idempotency_key' IS NOT NULL;

-- Note: These indexes guarantee that within a tenant, 
-- each idempotency_key can only be used once.
-- This prevents duplicate payments, bets, balance adjustments, etc.
