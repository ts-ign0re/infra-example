#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
INFRA_DIR="${SCRIPT_DIR%/scripts}"

echo "Database Migrations"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ "${USE_K8S:-}" = "1" ]; then
  NS="${K8S_NAMESPACE:-dev-infra}"
  
  echo "Using Kubernetes namespace: $NS"
  echo ""
  
  # Wait for PostgreSQL to be ready
  echo "Waiting for PostgreSQL to be ready..."
  for i in $(seq 1 60); do
    if kubectl -n "$NS" exec -i deploy/citus-coordinator -- \
       psql -U "${POSTGRES_USER:-app}" -d "${POSTGRES_DB:-app}" -c "SELECT 1" >/dev/null 2>&1; then
      echo "PostgreSQL ready"
      break
    fi
    sleep 2
    if [ "$i" -eq 60 ]; then
      echo "ERROR: PostgreSQL not ready after 120 seconds" >&2
      exit 1
    fi
  done
  
  echo ""
  
  # Apply SQL files in order using psql inside Citus coordinator pod
  shopt -s nullglob
  files=("$INFRA_DIR"/migrations/V*.sql)
  if [ ${#files[@]} -eq 0 ]; then
    echo "WARNING: No migrations found in $INFRA_DIR/migrations" >&2
    exit 0
  fi
  
  migration_count=0
  
  for f in "${files[@]}"; do
    migration_name=$(basename "$f")
    echo "  Applying: $migration_name"
    
    # Capture stderr to check if it's just "already exists" warnings
    if error_output=$(kubectl -n "$NS" exec -i deploy/citus-coordinator -- \
       psql -U "${POSTGRES_USER:-app}" -d "${POSTGRES_DB:-app}" -f - < "$f" 2>&1 >/dev/null); then
      echo "     → Applied successfully"
      ((migration_count++))
    else
      # Check if error is just "already exists" warnings
      if echo "$error_output" | grep -q "already exists"; then
        echo "     → Already applied (objects exist)"
        ((migration_count++))
      else
        echo "     → Failed to apply"
        echo "$error_output" >&2
        exit 1
      fi
    fi
  done
  
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Migrations completed: $migration_count migration(s)"
  echo ""
else
  COMPOSE=(docker compose -f "$INFRA_DIR/docker-compose.yml" --env-file "$INFRA_DIR/.env")
  "${COMPOSE[@]}" run --rm flyway -configFiles=/flyway/conf/flyway.conf -locations=filesystem:/flyway/sql migrate
fi
