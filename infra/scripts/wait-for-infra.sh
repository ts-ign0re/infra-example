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

if [ "${USE_K8S:-}" = "1" ]; then
  NS="${K8S_NAMESPACE:-dev-infra}"
  echo "Waiting for Kubernetes resources in namespace $NS ..."

  pod_by_label() {
    local sel=$1
    kubectl -n "$NS" get pods -l "$sel" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
  }

  # Wait for Citus if present, else fallback to postgres
  if kubectl -n "$NS" get deploy citus-coordinator >/dev/null 2>&1; then
    kubectl -n "$NS" rollout status deployment/citus-coordinator --timeout=180s
    kubectl -n "$NS" rollout status statefulset/citus-worker --timeout=180s
    echo "Checking Citus coordinator ..."
    PG_POD=$(pod_by_label app=citus-coordinator)
    kubectl -n "$NS" exec "$PG_POD" -- pg_isready -U "${POSTGRES_USER:-app}" -d "${POSTGRES_DB:-app}"
  else
    kubectl -n "$NS" rollout status deployment/postgres --timeout=120s
  fi
  kubectl -n "$NS" rollout status deployment/redis --timeout=120s
  kubectl -n "$NS" rollout status statefulset/redpanda --timeout=180s

  # Wait for Schema Registry with explicit pod readiness + diagnostics on failure
  echo "Waiting for Schema Registry pods to become Ready ..."
  for i in {1..90}; do
    ready=$(kubectl -n "$NS" get pods -l app=schema-registry -o jsonpath='{range .items[*]}{.status.containerStatuses[0].ready}{"\n"}{end}' 2>/dev/null | grep -c '^true$' || true)
    if [ "${ready:-0}" -ge 1 ]; then
      echo "Schema Registry pod is Ready"
      break
    fi
    sleep 2
    if [ "$i" -eq 90 ]; then
      echo "Schema Registry not Ready in time; collecting diagnostics..." >&2
      kubectl -n "$NS" get pods -l app=schema-registry -o wide >&2 || true
      pod=$(kubectl -n "$NS" get pods -l app=schema-registry -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
      if [ -n "$pod" ]; then
        kubectl -n "$NS" describe pod "$pod" >&2 || true
        echo "--- logs (current) ---" >&2
        kubectl -n "$NS" logs "$pod" >&2 || true
        echo "--- logs (previous, if any) ---" >&2
        kubectl -n "$NS" logs "$pod" --previous >&2 || true
      fi
      exit 1
    fi
  done

  echo "Checking Postgres ..."
  if kubectl -n "$NS" get deploy citus-coordinator >/dev/null 2>&1; then
    PG_POD=$(pod_by_label app=citus-coordinator)
  else
    PG_POD=$(pod_by_label app=postgres)
  fi
  if [ -z "$PG_POD" ]; then
    echo "Postgres/Citus pod not found in namespace $NS" >&2
    kubectl -n "$NS" get pods -o wide >&2 || true
    exit 1
  fi
  kubectl -n "$NS" exec "$PG_POD" -- pg_isready -U "${POSTGRES_USER:-app}" -d "${POSTGRES_DB:-app}"

  echo "Checking Redis ..."
  REDIS_POD=$(pod_by_label app=redis)
  kubectl -n "$NS" exec "$REDIS_POD" -- redis-cli ping | grep -q PONG

  echo "Checking Redpanda ..."
  RP_POD=$(pod_by_label app=redpanda)
  kubectl -n "$NS" exec "$RP_POD" -- rpk cluster health --watch=false --exit-when-healthy --api-urls=localhost:9644

  echo "Checking Schema Registry ..."
  kubectl -n "$NS" port-forward svc/schema-registry 18081:8081 >/dev/null 2>&1 & PF_PID=$!
  trap "kill $PF_PID >/dev/null 2>&1 || true" EXIT
  for i in {1..60}; do
    if curl -fsS http://localhost:18081/subjects >/dev/null 2>&1; then
      echo "Schema Registry is ready"
      break
    fi
    sleep 2
    if [ "$i" -eq 60 ]; then echo "Schema Registry not ready"; exit 1; fi
  done
  kill $PF_PID >/dev/null 2>&1 || true
  trap - EXIT
  echo "All K8s infra services are healthy."
else
  COMPOSE=(docker compose -f "$INFRA_DIR/docker-compose.yml" --env-file "$INFRA_DIR/.env")

  echo "Waiting for Postgres ..."
  for i in {1..60}; do
    if "${COMPOSE[@]}" exec -T postgres pg_isready -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-postgres}" >/dev/null 2>&1; then
      echo "Postgres is ready"
      break
    fi
    sleep 2
    if [ "$i" -eq 60 ]; then echo "Postgres not ready"; exit 1; fi
  done

  echo "Waiting for Redis ..."
  for i in {1..60}; do
    if "${COMPOSE[@]}" exec -T redis redis-cli ping | grep -q PONG; then
      echo "Redis is ready"
      break
    fi
    sleep 2
    if [ "$i" -eq 60 ]; then echo "Redis not ready"; exit 1; fi
  done

  echo "Waiting for Redpanda ..."
  for i in {1..60}; do
    if "${COMPOSE[@]}" exec -T redpanda rpk cluster health --watch=false --exit-when-healthy --api-urls=localhost:9644 >/dev/null 2>&1; then
      echo "Redpanda is ready"
      break
    fi
    sleep 2
    if [ "$i" -eq 60 ]; then echo "Redpanda not ready"; exit 1; fi
  done

  echo "Waiting for Schema Registry ..."
  for i in {1..60}; do
    if curl -fsS "http://localhost:${SCHEMA_REGISTRY_PORT:-8081}/subjects" >/dev/null 2>&1; then
      echo "Schema Registry is ready"
      break
    fi
    sleep 2
    if [ "$i" -eq 60 ]; then echo "Schema Registry not ready"; exit 1; fi
  done

  echo "All infra services are healthy."
fi
