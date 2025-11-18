#!/usr/bin/env bash
# Quick test for Event Sourcing & Materialized Views

set -euo pipefail

NS="${K8S_NAMESPACE:-dev-infra}"

echo "Testing Event Sourcing & Materialized Views..."
echo ""

# Test 1: Insert bet event
echo "1. Inserting test bet event..."
kubectl -n "$NS" exec -i deploy/citus-coordinator -- psql -U app -d app -c "
  INSERT INTO bet_events (id, tenant_id, aggregate_id, event_type, event_data, timestamp, version)
  VALUES (
    gen_random_uuid(),
    10001,
    'bet-quick-test-$(date +%s)',
    'V1_BETS_BET_PLACED',
    '{\"user_id\": \"user-test\", \"stake\": 100, \"odds\": 2.0, \"fixture_id\": \"test-fixture\"}'::jsonb,
    EXTRACT(EPOCH FROM NOW())::BIGINT * 1000,
    1
  );
" >/dev/null 2>&1
echo "   → Event inserted"

# Test 2: Check view refreshed
echo "2. Checking materialized view refresh..."
bet_count=$(kubectl -n "$NS" exec -i deploy/citus-coordinator -- \
  psql -U app -d app -tAc "SELECT COUNT(*) FROM bets_view WHERE tenant_id = 10001" 2>/dev/null)
echo "   → Found $bet_count bets in view"

# Test 3: Check refresh status
echo "3. Checking refresh status..."
kubectl -n "$NS" exec -i deploy/citus-coordinator -- psql -U app -d app -c "
  SELECT 
    view_name, 
    refresh_count,
    seconds_ago,
    status 
  FROM get_views_refresh_status()
  ORDER BY view_name;
"

# Test 4: Insert payment with idempotency key
echo ""
echo "4. Testing idempotency key protection..."
IDEMPOTENCY_KEY="test-payment-$(date +%s)-$$"
EXTERNAL_ID="ext-$IDEMPOTENCY_KEY"

kubectl -n "$NS" exec -i deploy/citus-coordinator -- psql -U app -d app -c "
  INSERT INTO payment_events (id, tenant_id, aggregate_id, event_type, event_data, timestamp, version, metadata)
  VALUES (
    gen_random_uuid(),
    10001,
    'payment-idempotency-test',
    'V1_PAYMENTS_DEPOSIT_CREATED',
    '{\"user_id\": \"user-test\", \"amount\": 1000, \"external_id\": \"$EXTERNAL_ID\"}'::jsonb,
    EXTRACT(EPOCH FROM NOW())::BIGINT * 1000,
    1,
    '{\"idempotency_key\": \"$IDEMPOTENCY_KEY\"}'::jsonb
  );
" >/dev/null 2>&1

# Wait for trigger to update view
sleep 1

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

# Try duplicate insert (should fail due to metadata->idempotency_key unique constraint)
set +e  # Temporarily disable exit on error
duplicate_error=$(kubectl -n "$NS" exec -i deploy/citus-coordinator -- psql -U app -d app -c "
  INSERT INTO payment_events (id, tenant_id, aggregate_id, event_type, event_data, timestamp, version, metadata)
  VALUES (
    gen_random_uuid(),
    10001,
    'payment-idempotency-test-2',
    'V1_PAYMENTS_DEPOSIT_CREATED',
    '{\"user_id\": \"user-test\", \"amount\": 2000, \"external_id\": \"$EXTERNAL_ID-duplicate\"}'::jsonb,
    EXTRACT(EPOCH FROM NOW())::BIGINT * 1000,
    1,
    '{\"idempotency_key\": \"$IDEMPOTENCY_KEY\"}'::jsonb
  );
" 2>&1)
set -e  # Re-enable exit on error

if echo "$duplicate_error" | grep -q "duplicate key value violates unique constraint"; then
  echo "   → Idempotency key protection working (duplicate rejected)"
else
  echo "   → Idempotency key issue (duplicate was accepted)"
  echo "   → Error: $duplicate_error"
fi

# Test 5: Trigger verification
echo ""
echo "5. Verifying triggers..."
trigger_count=$(kubectl -n "$NS" exec -i deploy/citus-coordinator -- psql -U app -d app -tAc "
  SELECT COUNT(*) FROM pg_trigger 
  WHERE tgname IN (
    'after_bet_events_insert',
    'after_balance_events_insert',
    'after_payment_events_insert'
  )
" 2>/dev/null)

if [ "$trigger_count" = "3" ]; then
  echo "   → All 3 reactive triggers configured"
else
  echo "   → Expected 3 triggers, found $trigger_count"
fi

echo ""
echo "Event Sourcing tests completed"
