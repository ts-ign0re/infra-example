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

NS="${K8S_NAMESPACE:-dev-infra}"

  pod_by_label() {
    local sel=$1
    kubectl -n "$NS" get pods -l "$sel" -o jsonpath='{.items[0].metadata.name}'
  }

echo "[TEST][K8S] Postgres/Citus transactional insert/verify/rollback"
# Log selected pods
echo "[INFO] Namespace: $NS"
  # prefer Citus coordinator if present
  if kubectl -n "$NS" get pods -l app=citus-coordinator >/dev/null 2>&1; then
    PG_POD=$(pod_by_label app=citus-coordinator)
  else
    PG_POD=$(pod_by_label app=postgres)
  fi
  echo "[INFO] Postgres pod: $PG_POD"
  CNT=$(kubectl -n "$NS" exec "$PG_POD" -- bash -lc "psql -X -q -t -A -U '${POSTGRES_USER:-app}' -d '${POSTGRES_DB:-app}' -v ON_ERROR_STOP=1 <<'SQL'
BEGIN;
CREATE TEMP TABLE it_health_tmp(id SERIAL PRIMARY KEY, checked_at TIMESTAMPTZ DEFAULT now());
INSERT INTO it_health_tmp DEFAULT VALUES;
SELECT count(*) FROM it_health_tmp;
ROLLBACK;
SQL" | tr -d '[:space:]')
  if [ "$CNT" != "1" ]; then
    echo "Postgres check failed: expected count=1, got '$CNT'" >&2
    exit 1
  fi

  # Verify seed tenant exists if Citus present
  if kubectl -n "$NS" get pods -l app=citus-coordinator >/dev/null 2>&1; then
    TEN_CNT=$(kubectl -n "$NS" exec "$PG_POD" -- bash -lc "psql -t -A -U '${POSTGRES_USER:-app}' -d '${POSTGRES_DB:-app}' -v ON_ERROR_STOP=1 -c \"SELECT count(*) FROM tenants WHERE id='tenant-1';\"" | tr -d '[:space:]')
    if [ "$TEN_CNT" != "1" ]; then
      echo "Seed tenant check failed: expected tenant-1 present, got count='$TEN_CNT'" >&2
      exit 1
    fi
  fi

  REDIS_POD=$(pod_by_label app=redis)
echo "[TEST][K8S] Redis SET/GET (pod=$REDIS_POD)"
  KEY="it:$(date +%s)"
  kubectl -n "$NS" exec "$REDIS_POD" -- sh -lc "redis-cli set '$KEY' 'ok' EX 60 >/dev/null && test \"\$(redis-cli get '$KEY')\" = 'ok'"

echo "[TEST][K8S] Redpanda produce/consume on system topic"
RP_POD=$(pod_by_label app=redpanda)
echo "[INFO] Redpanda pod: $RP_POD"
echo "[INFO] Redpanda cluster info:"
kubectl -n "$NS" exec "$RP_POD" -- rpk cluster info || true

# Ensure only system topic exists (idempotent)
SYS_TOPIC="${TOPIC_SYSTEM:-V1_SYSTEM}"
echo "[INFO] Ensuring topic exists: $SYS_TOPIC"
kubectl -n "$NS" exec "$RP_POD" -- rpk topic create "$SYS_TOPIC" -p 1 -r 1 >/dev/null 2>&1 || true

# Use a unique topic to avoid backlog ambiguity, then produce & consume
TEST_TOPIC="${TOPIC_SYSTEM:-V1_SYSTEM}_IT_$(date +%s)"
MESSAGE="hello-$(date +%s)"
echo "[INFO] Creating test topic: $TEST_TOPIC"
kubectl -n "$NS" exec "$RP_POD" -- rpk topic create "$TEST_TOPIC" -p 1 -r 1

echo "[INFO] Producing test message: $MESSAGE"
kubectl -n "$NS" exec -i "$RP_POD" -- sh -lc "printf '%s\n' '$MESSAGE' | rpk topic produce '$TEST_TOPIC'" || {
  echo "[ERROR] Produce failed" >&2; exit 1; }

echo "[INFO] Consuming back the message"
found=0
for i in $(seq 1 10); do
  out=$(kubectl -n "$NS" exec "$RP_POD" -- rpk topic consume "$TEST_TOPIC" -n 1 --offset start || true)
  echo "$out"
  if echo "$out" | grep -q "$MESSAGE"; then
    found=1; break
  fi
  sleep 1
done
if [ "$found" != "1" ]; then
  echo "[ERROR] Did not consume expected message from $TEST_TOPIC" >&2
  echo "[DIAG] Topic describe:" >&2
  kubectl -n "$NS" exec "$RP_POD" -- rpk topic describe "$TEST_TOPIC" >&2 || true
  echo "[DIAG] Cluster health:" >&2
  kubectl -n "$NS" exec "$RP_POD" -- rpk cluster health --watch=false --exit-when-healthy --api-urls=localhost:9644 >&2 || true
  exit 1
fi

echo "[TEST][K8S] Schema Registry reachable"
  kubectl -n "$NS" port-forward svc/schema-registry 18081:8081 >/dev/null 2>&1 & PF_PID=$!
  trap "kill $PF_PID >/dev/null 2>&1 || true" EXIT
  for i in $(seq 1 30); do
    if curl -fsS "http://localhost:18081/subjects" >/dev/null 2>&1; then
      break
    fi
    sleep 1
    if [ "$i" -eq 30 ]; then
      echo "[ERROR] Schema Registry not reachable on http://localhost:18081" >&2
      exit 1
    fi
  done
  echo "[INFO] Subjects: $(curl -fsS "http://localhost:18081/subjects" || echo '[]')"
  kill $PF_PID >/dev/null 2>&1 || true
  trap - EXIT


echo "All integration checks passed."
