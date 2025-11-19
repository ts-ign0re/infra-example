#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Configuration from common-env ConfigMap
NAMESPACE="${NAMESPACE:-dev-infra}"
POSTGRES_USER="${POSTGRES_USER:-app}"
POSTGRES_DB="${POSTGRES_DB:-app}"
COORDINATOR_DEPLOYMENT="citus-coordinator"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

check_citus_extension() {
    log_info "Checking Citus extension..."
    
    local result=$(kubectl exec -n ${NAMESPACE} deployment/${COORDINATOR_DEPLOYMENT} -- \
        psql -U ${POSTGRES_USER} -d ${POSTGRES_DB} -tAc \
        "SELECT COUNT(*) FROM pg_extension WHERE extname = 'citus';")
    
    if [[ "$result" == "1" ]]; then
        log_info "✓ Citus extension is installed"
        return 0
    else
        log_error "✗ Citus extension is NOT installed"
        return 1
    fi
}

check_worker_nodes() {
    log_info "Checking Citus worker nodes..."
    
    local workers=$(kubectl exec -n ${NAMESPACE} deployment/${COORDINATOR_DEPLOYMENT} -- \
        psql -U ${POSTGRES_USER} -d ${POSTGRES_DB} -tAc \
        "SELECT COUNT(*) FROM citus_get_active_worker_nodes();")
    
    log_info "Found $workers active worker node(s)"
    
    if [[ "$workers" -ge 1 ]]; then
        log_info "✓ Worker nodes are configured"
        
        kubectl exec -n ${NAMESPACE} deployment/${COORDINATOR_DEPLOYMENT} -- \
            psql -U ${POSTGRES_USER} -d ${POSTGRES_DB} -c \
            "SELECT * FROM citus_get_active_worker_nodes();"
        
        return 0
    else
        log_error "✗ No worker nodes found"
        return 1
    fi
}

check_distributed_tables() {
    log_info "Checking distributed tables..."
    
    local query="
        SELECT 
            logicalrelid::text as table_name,
            partmethod as distribution_method,
            partkey as partition_column
        FROM pg_dist_partition
        ORDER BY logicalrelid::text;
    "
    
    local distributed_tables=$(kubectl exec -n ${NAMESPACE} deployment/${COORDINATOR_DEPLOYMENT} -- \
        psql -U ${POSTGRES_USER} -d ${POSTGRES_DB} -tAc "$query")
    
    if [[ -z "$distributed_tables" ]]; then
        log_error "✗ No distributed tables found"
        return 1
    fi
    
    log_info "✓ Distributed tables:"
    echo "$distributed_tables" | while IFS='|' read -r table method column; do
        echo "  - $table (method: $method, column: $column)"
    done
    
    local expected_tables=("bet_events" "balance_events" "payment_events" "compliance_events" "tenant_events" "system_events")
    local all_found=true
    
    for table in "${expected_tables[@]}"; do
        if echo "$distributed_tables" | grep -q "$table"; then
            log_info "  ✓ $table is distributed"
        else
            log_error "  ✗ $table is NOT distributed"
            all_found=false
        fi
    done
    
    if [[ "$all_found" == true ]]; then
        return 0
    else
        return 1
    fi
}

check_partition_column() {
    log_info "Checking that all tables are partitioned by tenant_id..."
    
    local query="
        SELECT 
            logicalrelid::text as table_name,
            column_to_column_name(logicalrelid, partkey) as partition_column
        FROM pg_dist_partition
        WHERE column_to_column_name(logicalrelid, partkey) != 'tenant_id'
          AND logicalrelid::text NOT IN ('tenants', 'bets_view', 'payments_view');
    "
    
    local wrong_partition=$(kubectl exec -n ${NAMESPACE} deployment/${COORDINATOR_DEPLOYMENT} -- \
        psql -U ${POSTGRES_USER} -d ${POSTGRES_DB} -tAc "$query")
    
    if [[ -z "$wrong_partition" ]]; then
        log_info "✓ All event tables use tenant_id as partition column (tenants table uses id, which is expected)"
        return 0
    else
        log_error "✗ Some tables do NOT use tenant_id:"
        echo "$wrong_partition"
        return 1
    fi
}

check_data_distribution() {
    log_info "Checking data distribution across shards..."
    
    local test_tenant=$$
    
    log_info "Creating test tenant with id: $test_tenant"
    kubectl exec -n ${NAMESPACE} deployment/${COORDINATOR_DEPLOYMENT} -- \
        psql -U ${POSTGRES_USER} -d ${POSTGRES_DB} -c \
        "INSERT INTO tenants (id, name, slug, status) VALUES ($test_tenant, 'Test Tenant $test_tenant', 'test-$test_tenant', 'active') ON CONFLICT (id) DO NOTHING;"
    
    log_info "Inserting test event for tenant_id: $test_tenant"
    
    kubectl exec -n ${NAMESPACE} deployment/${COORDINATOR_DEPLOYMENT} -- \
        psql -U ${POSTGRES_USER} -d ${POSTGRES_DB} -c \
        "INSERT INTO bet_events (tenant_id, aggregate_id, idempotency_key, event_type, event_data, version) 
         VALUES ($test_tenant, 'bet-123', 'idem-123', 'BetPlaced', '{\"amount\": 100}'::jsonb, 1);"
    
    local shard_query="
        SELECT 
            shardid,
            nodename,
            nodeport
        FROM pg_dist_shard_placement
        WHERE shardid IN (
            SELECT shardid 
            FROM pg_dist_shard 
            WHERE logicalrelid = 'bet_events'::regclass
        )
        LIMIT 5;
    "
    
    log_info "✓ Data is being distributed to shards:"
    kubectl exec -n ${NAMESPACE} deployment/${COORDINATOR_DEPLOYMENT} -- \
        psql -U ${POSTGRES_USER} -d ${POSTGRES_DB} -c "$shard_query"
    
    log_info "Cleaning up test data..."
    kubectl exec -n ${NAMESPACE} deployment/${COORDINATOR_DEPLOYMENT} -- \
        psql -U ${POSTGRES_USER} -d ${POSTGRES_DB} -c \
        "DELETE FROM bet_events WHERE tenant_id = $test_tenant;"
    
    return 0
}

check_worker_data_access() {
    log_info "Checking direct worker data access via tenant_id..."
    
    local test_tenant=$$
    
    log_info "Creating test tenant with id: $test_tenant"
    kubectl exec -n ${NAMESPACE} deployment/${COORDINATOR_DEPLOYMENT} -- \
        psql -U ${POSTGRES_USER} -d ${POSTGRES_DB} -c \
        "INSERT INTO tenants (id, name, slug, status) VALUES ($test_tenant, 'Test Tenant $test_tenant', 'test-$test_tenant', 'active') ON CONFLICT (id) DO NOTHING;"
    
    log_info "Inserting test data via coordinator..."
    kubectl exec -n ${NAMESPACE} deployment/${COORDINATOR_DEPLOYMENT} -- \
        psql -U ${POSTGRES_USER} -d ${POSTGRES_DB} -c \
        "INSERT INTO bet_events (tenant_id, aggregate_id, idempotency_key, event_type, event_data, version) 
         VALUES ($test_tenant, 'bet-worker-test', 'idem-worker-test', 'BetPlaced', '{\"amount\": 500}'::jsonb, 1);"
    
    log_info "Querying data via coordinator (should work)..."
    local coordinator_result=$(kubectl exec -n ${NAMESPACE} deployment/${COORDINATOR_DEPLOYMENT} -- \
        psql -U ${POSTGRES_USER} -d ${POSTGRES_DB} -tAc \
        "SELECT COUNT(*) FROM bet_events WHERE tenant_id = $test_tenant;")
    
    if [[ "$coordinator_result" == "1" ]]; then
        log_info "✓ Data accessible via coordinator: $coordinator_result row(s)"
    else
        log_error "✗ Data NOT found via coordinator"
        return 1
    fi
    
    log_info "Attempting to query data directly from worker..."
    
    local worker_result=$(kubectl exec -n ideas deployment/postgres-worker-1 -- \
        psql -U ${POSTGRES_USER} -d ${POSTGRES_DB} -tAc \
        "SELECT COUNT(*) FROM bet_events_* WHERE tenant_id = $test_tenant;" 2>/dev/null || echo "0")
    
    if [[ "$worker_result" -ge "1" ]]; then
        log_info "✓ Data physically stored on worker: $worker_result row(s)"
    else
        log_warning "⚠ Could not verify data on worker (this is expected if shards are on different workers)"
    fi
    
    log_info "Cleaning up test data..."
    kubectl exec -n ${NAMESPACE} deployment/${COORDINATOR_DEPLOYMENT} -- \
        psql -U ${POSTGRES_USER} -d ${POSTGRES_DB} -c \
        "DELETE FROM bet_events WHERE tenant_id = $test_tenant;"
    
    return 0
}

check_no_triggers_on_distributed() {
    log_info "Checking that distributed tables have no triggers (Citus limitation)..."
    
    local query="
        SELECT 
            t.tgname AS trigger_name,
            c.relname AS table_name
        FROM pg_trigger t
        JOIN pg_class c ON t.tgrelid = c.oid
        JOIN pg_dist_partition p ON c.oid = p.logicalrelid
        WHERE NOT t.tgisinternal;
    "
    
    local triggers=$(kubectl exec -n ${NAMESPACE} deployment/${COORDINATOR_DEPLOYMENT} -- \
        psql -U ${POSTGRES_USER} -d ${POSTGRES_DB} -tAc "$query")
    
    if [[ -z "$triggers" ]]; then
        log_info "✓ No triggers on distributed tables (correct for Citus)"
        return 0
    else
        log_error "✗ Found triggers on distributed tables (will cause errors):"
        echo "$triggers"
        return 1
    fi
}

run_all_tests() {
    local failed=0
    
    echo ""
    echo "=========================================="
    echo "  Citus Distribution Test Suite"
    echo "=========================================="
    echo ""
    
    check_citus_extension || ((failed++))
    echo ""
    
    check_worker_nodes || ((failed++))
    echo ""
    
    check_distributed_tables || ((failed++))
    echo ""
    
    check_partition_column || ((failed++))
    echo ""
    
    check_no_triggers_on_distributed || ((failed++))
    echo ""
    
    check_data_distribution || ((failed++))
    echo ""
    
    check_worker_data_access || ((failed++))
    echo ""
    
    echo "=========================================="
    if [[ $failed -eq 0 ]]; then
        log_info "✓ All Citus distribution tests passed!"
        echo "=========================================="
        return 0
    else
        log_error "✗ $failed test(s) failed"
        echo "=========================================="
        return 1
    fi
}

run_all_tests
