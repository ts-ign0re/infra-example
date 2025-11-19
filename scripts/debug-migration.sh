#!/usr/bin/env bash
# Debug script для диагностики проблем с миграциями

set -euo pipefail

NS="${K8S_NAMESPACE:-dev-infra}"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Migration Debug Tool"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# 1. Check namespace
echo "1. Checking namespace..."
if kubectl get namespace "$NS" >/dev/null 2>&1; then
    echo "   ✓ Namespace '$NS' exists"
else
    echo "   ✗ Namespace '$NS' does NOT exist"
    echo "   Run: kubectl create namespace $NS"
    exit 1
fi
echo ""

# 2. Check PostgreSQL deployment
echo "2. Checking PostgreSQL deployment..."
if kubectl -n "$NS" get deploy/citus-coordinator >/dev/null 2>&1; then
    echo "   ✓ Deployment exists"
    
    # Check replicas
    ready=$(kubectl -n "$NS" get deploy/citus-coordinator -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    desired=$(kubectl -n "$NS" get deploy/citus-coordinator -o jsonpath='{.status.replicas}' 2>/dev/null || echo "0")
    
    if [ "$ready" = "$desired" ] && [ "$ready" != "0" ]; then
        echo "   ✓ Replicas ready: $ready/$desired"
    else
        echo "   ✗ Replicas NOT ready: $ready/$desired"
        echo ""
        echo "   Pod status:"
        kubectl -n "$NS" get pods -l app=citus-coordinator
    fi
else
    echo "   ✗ Deployment does NOT exist"
    echo "   PostgreSQL is not deployed yet"
    exit 1
fi
echo ""

# 3. Check PostgreSQL pods
echo "3. Checking PostgreSQL pods..."
pods=$(kubectl -n "$NS" get pods -l app=citus-coordinator -o name 2>/dev/null || true)
if [ -z "$pods" ]; then
    echo "   ✗ No pods found"
    exit 1
fi

for pod in $pods; do
    pod_name=$(basename "$pod")
    status=$(kubectl -n "$NS" get "$pod" -o jsonpath='{.status.phase}')
    echo "   Pod: $pod_name - Status: $status"
    
    if [ "$status" != "Running" ]; then
        echo ""
        echo "   Pod logs (last 20 lines):"
        kubectl -n "$NS" logs "$pod" --tail=20 2>&1 | sed 's/^/      /'
    fi
done
echo ""

# 4. Test PostgreSQL connection
echo "4. Testing PostgreSQL connection..."
if kubectl -n "$NS" exec -i deploy/citus-coordinator -- \
   psql -U "${POSTGRES_USER:-app}" -d "${POSTGRES_DB:-app}" -c "SELECT version();" >/dev/null 2>&1; then
    echo "   ✓ Connection successful"
    
    # Get version
    version=$(kubectl -n "$NS" exec -i deploy/citus-coordinator -- \
              psql -U "${POSTGRES_USER:-app}" -d "${POSTGRES_DB:-app}" -t -c "SELECT version();" 2>/dev/null | xargs)
    echo "   PostgreSQL: $version"
else
    echo "   ✗ Connection FAILED"
    echo ""
    echo "   Trying to get error details..."
    kubectl -n "$NS" exec -i deploy/citus-coordinator -- \
       psql -U "${POSTGRES_USER:-app}" -d "${POSTGRES_DB:-app}" -c "SELECT 1;" 2>&1 | sed 's/^/      /' || true
    exit 1
fi
echo ""

# 5. Check Citus extension
echo "5. Checking Citus extension..."
if kubectl -n "$NS" exec -i deploy/citus-coordinator -- \
   psql -U "${POSTGRES_USER:-app}" -d "${POSTGRES_DB:-app}" -c "SELECT extname, extversion FROM pg_extension WHERE extname='citus';" 2>/dev/null | grep -q citus; then
    citus_version=$(kubectl -n "$NS" exec -i deploy/citus-coordinator -- \
                    psql -U "${POSTGRES_USER:-app}" -d "${POSTGRES_DB:-app}" -t -c "SELECT extversion FROM pg_extension WHERE extname='citus';" 2>/dev/null | xargs)
    echo "   ✓ Citus extension installed: v$citus_version"
else
    echo "   ✗ Citus extension NOT installed"
    echo "   This might be expected if migrations haven't run yet"
fi
echo ""

# 6. List migration files
echo "6. Checking migration files..."
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
INFRA_DIR="${SCRIPT_DIR%/scripts}"
shopt -s nullglob
files=("$INFRA_DIR"/migrations/V*.sql)

if [ ${#files[@]} -eq 0 ]; then
    echo "   ✗ No migration files found in $INFRA_DIR/migrations"
    exit 1
else
    echo "   ✓ Found ${#files[@]} migration file(s):"
    for f in "${files[@]}"; do
        size=$(wc -l < "$f")
        echo "      - $(basename "$f") ($size lines)"
    done
fi
echo ""

# 7. Test migration syntax
echo "7. Testing migration SQL syntax..."
for f in "${files[@]}"; do
    migration_name=$(basename "$f")
    echo "   Testing: $migration_name"
    
    # Test with --dry-run (explain only)
    if error=$(kubectl -n "$NS" exec -i deploy/citus-coordinator -- \
               psql -U "${POSTGRES_USER:-app}" -d "${POSTGRES_DB:-app}" \
               --set ON_ERROR_STOP=1 -f - < "$f" 2>&1 >/dev/null); then
        echo "      ✓ Syntax OK (or already applied)"
    else
        # Check if it's "already exists" error
        if echo "$error" | grep -q "already exists"; then
            echo "      ✓ Already applied"
        else
            echo "      ✗ Syntax error or other issue"
            echo "$error" | head -10 | sed 's/^/         /'
        fi
    fi
done
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Debug complete!"
echo ""
echo "Next steps:"
echo "  - If all checks passed, try: make migrate"
echo "  - Check Tilt UI: http://localhost:10350"
echo "  - View migration logs: kubectl -n $NS logs -l job-name=migrate"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
