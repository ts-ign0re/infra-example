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
LOKI_TENANT_ID="${LOKI_TENANT_ID:-10001}"

  pod_by_label() {
    local sel=$1
    kubectl -n "$NS" get pods -l "$sel" -o jsonpath='{.items[0].metadata.name}'
  }

# Pre-flight availability checks (visual PASS/FAIL)
check_print() {
  local name="$1"; local ok="$2"; local extra="${3:-}"
  if [ "$ok" = "1" ]; then
    printf "[CHECK][PASS] %s%s\n" "$name" "${extra:+ — $extra}"
  else
    printf "[CHECK][FAIL] %s%s\n" "$name" "${extra:+ — $extra}"
  fi
}

check_pod_ready() {
  local sel="$1"; local name="$2"
  local ready
  ready=$(kubectl -n "$NS" get pods -l "$sel" -o jsonpath='{range .items[*]}{.status.containerStatuses[0].ready}{"\n"}{end}' 2>/dev/null | grep -c '^true$' || true)
  if [ "${ready:-0}" -ge 1 ]; then
    check_print "$name" 1 "pods ready=$ready"
  else
    check_print "$name" 0 "pods ready=${ready:-0}"
  fi
}

check_svc_endpoints() {
  local svc="$1"; local name="$2"
  local eps
  eps=$(kubectl -n "$NS" get endpoints "$svc" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)
  if [ -n "$eps" ]; then
    check_print "$name" 1 "endpoints present"
  else
    check_print "$name" 0 "no endpoints"
  fi
}

check_pf_http() {
  local svc="$1"; local lport="$2"; local tport="$3"; local path="$4"; local header="${5:-}"; local code_ok_re="${6:-^200$}"
  kubectl -n "$NS" port-forward "svc/${svc}" "$lport":"$tport" >/dev/null 2>&1 & PF=$!
  local ok=0 code=
  for i in $(seq 1 10); do
    if [ -n "$header" ]; then
      code=$(curl -s -o /dev/null -w "%{http_code}" -H "$header" "http://localhost:${lport}${path}" || true)
    else
      code=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:${lport}${path}" || true)
    fi
    if echo "$code" | grep -Eq "$code_ok_re"; then ok=1; break; fi
    sleep 0.5
  done
  kill "$PF" >/dev/null 2>&1 || true
  wait "$PF" 2>/dev/null || true
  if [ "$ok" = "1" ]; then
    check_print "${svc} HTTP ${path}" 1 "code=${code}"
  else
    check_print "${svc} HTTP ${path}" 0 "code=${code:-na}"
  fi
}

echo "[CHECK] K8S Services availability in namespace $NS"
check_pod_ready "app=citus-coordinator" "citus-coordinator pods"
check_pod_ready "app=postgres" "postgres pods"
check_pod_ready "app=redis" "redis pods"
check_pod_ready "app=redpanda" "redpanda pods"
check_svc_endpoints "schema-registry" "schema-registry svc"
check_pf_http "schema-registry" 18081 8081 "/subjects" "" "^200$|^204$"
check_svc_endpoints "loki" "loki svc"
check_pf_http "loki" 13100 3100 "/ready" "" "^200$"
check_svc_endpoints "grafana" "grafana svc"
check_pf_http "grafana" 13000 3000 "/api/health" "" "^200$|^401$"

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
    TEN_CNT=$(kubectl -n "$NS" exec "$PG_POD" -- bash -lc "psql -t -A -U '${POSTGRES_USER:-app}' -d '${POSTGRES_DB:-app}' -v ON_ERROR_STOP=1 -c \"SELECT count(*) FROM tenants WHERE id=10001;\"" | tr -d '[:space:]')
    if [ "$TEN_CNT" != "1" ]; then
      echo "Seed tenant check failed: expected 10001 present, got count='$TEN_CNT'" >&2
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


echo "[TEST][K8S] Loki accepts push (no readback)"
if ! kubectl -n "$NS" get svc/loki >/dev/null 2>&1; then
  echo "[SKIP] Loki not installed in namespace $NS (run 'make obs-up' to enable)"
else
  LOKI_EPS=$(kubectl -n "$NS" get endpoints loki -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)
  if [ -z "$LOKI_EPS" ]; then
    echo "[SKIP] Loki service has no endpoints yet; ensure pods are Ready (try: kubectl -n $NS get pods -l app=loki)"
  else
    kubectl -n "$NS" port-forward svc/loki 13100:3100 >/dev/null 2>&1 & LOKI_PF=$!
    trap "kill $LOKI_PF >/dev/null 2>&1 || true" EXIT
    for i in $(seq 1 30); do
      if curl -fsS http://localhost:13100/ready >/dev/null 2>&1; then break; fi
      sleep 1
      if [ "$i" -eq 30 ]; then
        echo "[ERROR] Loki /ready not reachable via port-forward; endpoints=$LOKI_EPS" >&2
        kill $LOKI_PF >/dev/null 2>&1 || true
        trap - EXIT
        exit 1
      fi
    done
    MESSAGE="it-push-$(date +%s)"
    ts_ns=$(( $(date +%s) * 1000000000 ))
    json=$(cat <<EOF
{"streams":[{"stream":{"namespace":"$NS","test":"it_push"},"values":[["$ts_ns","$MESSAGE"]]}]}
EOF
)
    code=$(curl -s -o /dev/null -w "%{http_code}" \
      -H 'Content-Type: application/json' -H "X-Scope-OrgID: $LOKI_TENANT_ID" \
      -X POST --data "$json" "http://localhost:13100/loki/api/v1/push" || true)
    kill $LOKI_PF >/dev/null 2>&1 || true
    trap - EXIT
    if [ "$code" != "204" ]; then
      echo "[ERROR] Loki push returned unexpected code=$code" >&2
      exit 1
    fi
    echo "[INFO] Loki accepted push (204)"
  fi
fi

echo "[TEST][K8S] Grafana health + datasource"
if ! kubectl -n "$NS" get svc/grafana >/dev/null 2>&1; then
  echo "[SKIP] Grafana not installed in namespace $NS (run 'make obs-up' to enable)"
else
  GF_EPS=$(kubectl -n "$NS" get endpoints grafana -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)
  if [ -z "$GF_EPS" ]; then
    echo "[SKIP] Grafana service has no endpoints yet; ensure pods are Ready (try: kubectl -n $NS get pods -l app=grafana)"
  else
  kubectl -n "$NS" port-forward svc/grafana 13000:3000 >/dev/null 2>&1 & GF_PF=$!
  trap "kill $GF_PF >/dev/null 2>&1 || true" EXIT

  # Health: tolerate 401 (auth-required) as a sign that Grafana is up
  for i in $(seq 1 30); do
    code=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:13000/api/health || true)
    if [ "$code" = "200" ] || [ "$code" = "401" ]; then
      break
    fi
    sleep 1
    if [ "$i" -eq 30 ]; then
      echo "[ERROR] Grafana /api/health not reachable" >&2
      kill $GF_PF >/dev/null 2>&1 || true
      trap - EXIT
      exit 1
    fi
  done
  echo "[INFO] Grafana health: $(curl -fsS -u admin:admin http://localhost:13000/api/health || echo '{}')"

  # Check that Loki datasource is provisioned (needs basic auth)
  if ! curl -fsS -u admin:admin http://localhost:13000/api/datasources | jq -e '.[] | select(.type=="loki")' >/dev/null 2>&1; then
    echo "[ERROR] Grafana has no Loki datasource provisioned" >&2
    kill $GF_PF >/dev/null 2>&1 || true
    trap - EXIT
    exit 1
  fi
  kill $GF_PF >/dev/null 2>&1 || true
  trap - EXIT
  fi
fi

echo "All integration checks passed."
