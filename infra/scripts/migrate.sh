#!/usr/bin/env bash
set -euo pipefail

# Debug mode
DEBUG="${DEBUG:-0}"
if [ "$DEBUG" = "1" ]; then
  set -x
fi

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
INFRA_DIR="${SCRIPT_DIR%/scripts}"

echo "Database Migrations"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ "$DEBUG" = "1" ]; then
  echo "DEBUG: INFRA_DIR=$INFRA_DIR"
  echo "DEBUG: bash version: $BASH_VERSION"
  echo "DEBUG: kubectl version: $(kubectl version --client --short 2>/dev/null || echo 'N/A')"
fi

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
    echo "  Attempt $i/60 - PostgreSQL not ready yet..."
    sleep 2
    if [ "$i" -eq 60 ]; then
      echo "ERROR: PostgreSQL not ready after 120 seconds" >&2
      echo "Checking pod status:" >&2
      kubectl -n "$NS" get pods -l app=citus-coordinator >&2
      echo "Checking pod logs:" >&2
      kubectl -n "$NS" logs deploy/citus-coordinator --tail=20 >&2
      exit 1
    fi
  done
  
  echo ""
  
  # Apply SQL files in order using psql inside Citus coordinator pod
  shopt -s nullglob
  files=("$INFRA_DIR"/migrations/V[0-9]*.sql)
  shopt -u nullglob
  
  if [ ${#files[@]} -eq 0 ]; then
    echo "WARNING: No migrations found in $INFRA_DIR/migrations" >&2
    exit 0
  fi
  
  # Sort files to ensure correct order
  IFS=$'\n' sorted_files=($(sort -V <<<"${files[*]}"))
  unset IFS
  
  migration_count=0
  
  for f in "${sorted_files[@]}"; do
    migration_name=$(basename "$f")
    
    # Skip .old files
    if [[ "$migration_name" == *.old ]]; then
      continue
    fi
    
    if [ "$DEBUG" = "1" ]; then
      echo "DEBUG: Processing file: $f"
      echo "DEBUG: File size: $(wc -c < "$f") bytes"
      echo "DEBUG: First 5 lines:"
      head -5 "$f" | sed 's/^/  /'
    fi
    
    echo "  Applying: $migration_name"
    
    # Use temporary file to avoid bash redirection issues
    tmp_output=$(mktemp)
    trap 'rm -f "$tmp_output"' EXIT
    
    # Run migration and capture output
    if kubectl -n "$NS" exec -i deploy/citus-coordinator -- \
       psql -U "${POSTGRES_USER:-app}" -d "${POSTGRES_DB:-app}" \
       --set ON_ERROR_STOP=1 -f - < "$f" >"$tmp_output" 2>&1; then
      echo "     → Applied successfully"
      migration_count=$((migration_count + 1))
    else
      exit_code=$?
      error_output=$(cat "$tmp_output")
      
      if [ "$DEBUG" = "1" ]; then
        echo "DEBUG: psql exit code: $exit_code" >&2
        echo "DEBUG: kubectl/psql error output:" >&2
        cat "$tmp_output" | sed 's/^/  /' >&2
      fi
      
      # Check if error is just "already exists" warnings
      if echo "$error_output" | grep -qi "already exists"; then
        echo "     → Already applied (objects exist)"
        migration_count=$((migration_count + 1))
      else
        echo "     → Failed to apply" >&2
        echo "" >&2
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
        echo "Migration Error Details:" >&2
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
        echo "File: $migration_name" >&2
        echo "Exit code: $exit_code" >&2
        echo "" >&2
        echo "Error Output:" >&2
        echo "$error_output" >&2
        echo "" >&2
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
        rm -f "$tmp_output"
        exit 1
      fi
    fi
    
    rm -f "$tmp_output"
  done
  
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Migrations completed: $migration_count migration(s)"
  echo ""
else
  COMPOSE=(docker compose -f "$INFRA_DIR/docker-compose.yml" --env-file "$INFRA_DIR/.env")
  "${COMPOSE[@]}" run --rm flyway -configFiles=/flyway/conf/flyway.conf -locations=filesystem:/flyway/sql migrate
fi
