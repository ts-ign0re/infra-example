#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
INFRA_DIR="${SCRIPT_DIR%/scripts}"

if [ -f "$INFRA_DIR/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  source "$INFRA_DIR/.env"
  set +a
fi

SCHEMA_DIR="$INFRA_DIR/schemas"
COMPAT="${SR_COMPATIBILITY:-BACKWARD_TRANSITIVE}"

echo "Avro Schema Registration"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ "${USE_K8S:-}" = "1" ]; then
  NS="${K8S_NAMESPACE:-dev-infra}"
  echo "Setting up port-forward to Schema Registry..."
  kubectl -n "$NS" port-forward svc/schema-registry 18081:8081 >/dev/null 2>&1 & PF_PID=$!
  trap "kill $PF_PID >/dev/null 2>&1 || true" EXIT
  SR_URL="http://localhost:18081"
  
  # Wait for port-forward to accept connections
  echo "Waiting for Schema Registry to be ready..."
  for i in $(seq 1 60); do
    if curl -fsS "$SR_URL/subjects" >/dev/null 2>&1; then
      echo "Schema Registry ready"
      break
    fi
    sleep 1
    if [ "$i" -eq 60 ]; then
      echo "ERROR: Schema Registry port-forward not ready on $SR_URL" >&2
      exit 1
    fi
  done
else
  SR_URL="${SCHEMA_REGISTRY_URL:-http://localhost:8081}"
  echo "Using Schema Registry: $SR_URL"
fi

echo ""
echo "Registering schemas from $SCHEMA_DIR..."
echo ""

map_subject() {
  case "$1" in
    BetEvent) echo "${TOPIC_BETS:-V1_BETS}-value" ;;
    PaymentEvent) echo "${TOPIC_PAYMENTS:-V1_PAYMENTS}-value" ;;
    BalanceEvent) echo "${TOPIC_BALANCES:-V1_BALANCES}-value" ;;
    ComplianceEvent) echo "${TOPIC_COMPLIANCE:-V1_COMPLIANCE}-value" ;;
    SystemEvent) echo "${TOPIC_SYSTEM:-V1_SYSTEM}-value" ;;
    TenantEvent) echo "${TOPIC_TENANTS:-V1_TENANTS}-value" ;;
    *) return 1 ;;
  esac
}

registered_count=0
skipped_count=0

for file in "$SCHEMA_DIR"/*.avsc; do
  # Skip if no files found
  if [ ! -f "$file" ]; then
    echo "WARNING: No .avsc files found in $SCHEMA_DIR"
    exit 0
  fi
  
  name=$(basename "$file" .avsc)
  if ! subject=$(map_subject "$name"); then
    echo "  → Skipped: $name (no subject mapping)"
    ((skipped_count++))
    continue
  fi
  
  echo "  Registering: $name → $subject"
  
  # Register schema
  if jq -nc --arg schema "$(jq -c . "$file")" '{schema: $schema}' | \
     curl -fsS -X POST -H 'Content-Type: application/vnd.schemaregistry.v1+json' \
       --data @- \
       "$SR_URL/subjects/$subject/versions" >/dev/null 2>&1; then
    
    # Set compatibility
    jq -nc --arg c "$COMPAT" '{compatibility: $c}' | \
    curl -fsS -X PUT -H 'Content-Type: application/vnd.schemaregistry.v1+json' \
      --data @- \
      "$SR_URL/config/$subject" >/dev/null 2>&1
    
    echo "     → Registered with compatibility: $COMPAT"
    ((registered_count++))
  else
    echo "     → Already registered or error occurred"
  fi
done

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Schema registration completed: $registered_count"
if [ $skipped_count -gt 0 ]; then
  echo "Skipped: $skipped_count"
fi
echo ""

if [ -n "${PF_PID:-}" ]; then
  kill $PF_PID >/dev/null 2>&1 || true
  trap - EXIT
fi
