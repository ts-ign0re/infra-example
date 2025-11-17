#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
INFRA_DIR="${SCRIPT_DIR%/scripts}"

if [ "${USE_K8S:-}" = "1" ]; then
  NS="${K8S_NAMESPACE:-dev-infra}"
  # Apply SQL files in order using psql inside Postgres pod
  shopt -s nullglob
  files=("$INFRA_DIR"/migrations/V*.sql)
  if [ ${#files[@]} -eq 0 ]; then
    echo "No migrations found in $INFRA_DIR/migrations" >&2
    exit 0
  fi
  for f in "${files[@]}"; do
    echo "Applying migration: $(basename "$f")"
    kubectl -n "$NS" exec -i deploy/postgres -- psql -U "${POSTGRES_USER:-app}" -d "${POSTGRES_DB:-app}" -v ON_ERROR_STOP=1 -f - < "$f"
  done
  echo "Migrations applied via kubectl/psql."
else
  COMPOSE=(docker compose -f "$INFRA_DIR/docker-compose.yml" --env-file "$INFRA_DIR/.env")
  "${COMPOSE[@]}" run --rm flyway -configFiles=/flyway/conf/flyway.conf -locations=filesystem:/flyway/sql migrate
fi
