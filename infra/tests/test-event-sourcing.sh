#!/usr/bin/env bash
# Quick test for Event Sourcing & Materialized Views

set -euo pipefail

NS="${K8S_NAMESPACE:-dev-infra}"

echo "Testing Event Sourcing & Materialized Views..."
echo ""

# Test 1: Insert bet event
echo "1. Inserting test bet event..."
IDEMPOTENCY_KEY_BET="test-bet-$(date +%s)-$$"
BET_AGGREGATE_ID="bet-quick-test-$(date +%s)-$$"
if kubectl -n "$NS" exec -i deploy/citus-coordinator -- psql -U app -d app -c "
  INSERT INTO bet_events (id, tenant_id, aggregate_id, idempotency_key, event_type, event_data, timestamp, version)
  VALUES (
    gen_random_uuid(),
    10001,
    '$BET_AGGREGATE_ID',
    '$IDEMPOTENCY_KEY_BET',
    'V1_BETS_BET_PLACED',
    '{\"user_id\": \"user-test\", \"stake\": 100, \"odds\": 2.0, \"fixture_id\": \"test-fixture\"}'::jsonb,
    EXTRACT(EPOCH FROM NOW())::BIGINT * 1000,
    1
  );
" 2>&1; then
  echo "   → Event inserted (aggregate_id: $BET_AGGREGATE_ID)"
else
  echo "   → Failed to insert event"
  exit 1
fi

# Test 2: Manually UPSERT into view (simulating application behavior)
echo "2. Manually updating bets_view (application-level)..."
kubectl -n "$NS" exec -i deploy/citus-coordinator -- psql -U app -d app -c "
  INSERT INTO bets_view (
    tenant_id, bet_id, idempotency_key, user_id, 
    amount, odds, selection, status, last_updated_timestamp, last_updated_at
  )
  SELECT 
    tenant_id,
    aggregate_id as bet_id,
    idempotency_key,
    (event_data->>'user_id') as user_id,
    (event_data->>'stake')::decimal as amount,
    (event_data->>'odds')::decimal as odds,
    (event_data->>'fixture_id') as selection,
    'placed' as status,
    timestamp as last_updated_timestamp,
    created_at as last_updated_at
  FROM bet_events
  WHERE tenant_id = 10001 
    AND aggregate_id = '$BET_AGGREGATE_ID'
  ORDER BY timestamp DESC
  LIMIT 1
  ON CONFLICT (tenant_id, bet_id) DO UPDATE SET
    status = EXCLUDED.status,
    last_updated_timestamp = EXCLUDED.last_updated_timestamp;
" >/dev/null 2>&1

# Test 3: Check view was updated
echo "3. Checking bets_view was updated..."
bet_count=$(kubectl -n "$NS" exec -i deploy/citus-coordinator -- \
  psql -U app -d app -tAc "SELECT COUNT(*) FROM bets_view WHERE tenant_id = 10001" 2>/dev/null)
echo "   → Found $bet_count bets in view"

# Test 4: Insert payment with idempotency key
echo ""
echo "4. Testing idempotency key protection..."
IDEMPOTENCY_KEY="test-payment-$(date +%s)-$$"
PAYMENT_AGGREGATE_ID="payment-idempotency-test-$(date +%s)-$$"
EXTERNAL_ID="ext-$IDEMPOTENCY_KEY"

kubectl -n "$NS" exec -i deploy/citus-coordinator -- psql -U app -d app -c "
  INSERT INTO payment_events (id, tenant_id, aggregate_id, idempotency_key, event_type, event_data, timestamp, version)
  VALUES (
    gen_random_uuid(),
    10001,
    '$PAYMENT_AGGREGATE_ID',
    '$IDEMPOTENCY_KEY',
    'V1_PAYMENTS_DEPOSIT_CREATED',
    '{\"user_id\": \"user-test\", \"amount\": 1000, \"external_id\": \"$EXTERNAL_ID\"}'::jsonb,
    EXTRACT(EPOCH FROM NOW())::BIGINT * 1000,
    1
  );
" >/dev/null 2>&1

# Wait and update payments_view manually
sleep 1

echo "   → Updating payments_view (application-level)..."
kubectl -n "$NS" exec -i deploy/citus-coordinator -- psql -U app -d app -c "
  INSERT INTO payments_view (
    tenant_id, payment_id, idempotency_key, user_id,
    amount, currency, payment_type, status,
    external_id, last_updated_timestamp, last_updated_at
  )
  SELECT 
    tenant_id,
    aggregate_id as payment_id,
    idempotency_key,
    (event_data->>'user_id') as user_id,
    (event_data->>'amount')::decimal as amount,
    COALESCE((event_data->>'currency'), 'USD') as currency,
    'deposit' as payment_type,
    'created' as status,
    (event_data->>'external_id') as external_id,
    timestamp as last_updated_timestamp,
    created_at as last_updated_at
  FROM payment_events
  WHERE tenant_id = 10001 
    AND aggregate_id = '$PAYMENT_AGGREGATE_ID'
  ORDER BY timestamp DESC
  LIMIT 1
  ON CONFLICT (tenant_id, payment_id) DO UPDATE SET
    status = EXCLUDED.status,
    last_updated_timestamp = EXCLUDED.last_updated_timestamp;
" >/dev/null 2>&1

# Check that payment appears in view
duplicate_result=$(kubectl -n "$NS" exec -i deploy/citus-coordinator -- psql -U app -d app -tAc "
  SELECT COUNT(*) FROM payments_view 
  WHERE tenant_id = 10001 
    AND external_id = '$EXTERNAL_ID'
" 2>/dev/null)

if [ "$duplicate_result" = "1" ]; then
  echo "   → Payment materialized correctly (found in view)"
else
  echo "   → View refresh issue (found $duplicate_result payments with external_id)"
fi

# Try duplicate insert (should fail due to idempotency_key unique constraint)
set +e  # Temporarily disable exit on error
duplicate_error=$(kubectl -n "$NS" exec -i deploy/citus-coordinator -- psql -U app -d app -c "
  INSERT INTO payment_events (id, tenant_id, aggregate_id, idempotency_key, event_type, event_data, timestamp, version)
  VALUES (
    gen_random_uuid(),
    10001,
    'payment-idempotency-test-2',
    '$IDEMPOTENCY_KEY',
    'V1_PAYMENTS_DEPOSIT_CREATED',
    '{\"user_id\": \"user-test\", \"amount\": 2000, \"external_id\": \"$EXTERNAL_ID-duplicate\"}'::jsonb,
    EXTRACT(EPOCH FROM NOW())::BIGINT * 1000,
    1
  );
" 2>&1)
set -e  # Re-enable exit on error

if echo "$duplicate_error" | grep -q "duplicate key value violates unique constraint"; then
  echo "   → Idempotency key protection working (duplicate rejected)"
else
  echo "   → Idempotency key issue (duplicate was accepted)"
  echo "   → Error: $duplicate_error"
fi

# Test 5: Verify NO triggers (Citus doesn't support them)
echo ""
echo "5. Verifying NO triggers on distributed tables..."
trigger_count=$(kubectl -n "$NS" exec -i deploy/citus-coordinator -- psql -U app -d app -tAc "
  SELECT COUNT(*) FROM pg_trigger 
  WHERE tgrelid IN ('bet_events'::regclass, 'payment_events'::regclass)
    AND tgname NOT LIKE 'RI_%'  -- Exclude foreign key triggers
    AND tgname NOT LIKE 'pg_%'  -- Exclude system triggers
    AND tgname NOT LIKE 'truncate_trigger_%'  -- Exclude Citus system triggers
" 2>/dev/null)

if [ "$trigger_count" = "0" ]; then
  echo "   → ✅ No application triggers on distributed tables (correct for Citus)"
else
  echo "   → ⚠️  Found $trigger_count application triggers (Citus doesn't support them)"
fi

echo ""
echo "✅ Event Sourcing tests completed"
