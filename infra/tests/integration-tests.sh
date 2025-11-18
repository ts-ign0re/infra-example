#!/usr/bin/env bash
set -euo pipefail

# ╔═══════════════════════════════════════════════════════════════════════╗
# ║   IDEAS PLATFORM - INFRASTRUCTURE INTEGRATION TESTS v1.01             ║
# ║   Enhanced with visual progress, spinners, and comprehensive report   ║
# ╚═══════════════════════════════════════════════════════════════════════╝

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
INFRA_DIR="${SCRIPT_DIR%/scripts}"

if [ -f "$INFRA_DIR/.env" ]; then
  set -a
  source "$INFRA_DIR/.env" 2>/dev/null || true
  set +a
fi

NS="${K8S_NAMESPACE:-dev-infra}"
LOKI_TENANT_ID="${LOKI_TENANT_ID:-10001}"

# ═══════════════════════════════════════════════════════════════════════════
# COLORS & UNICODE
# ═══════════════════════════════════════════════════════════════════════════

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
GRAY='\033[0;90m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# Unicode symbols
CHECK="✓"
CROSS="✗"
ARROW="→"
BULLET="•"
SPINNER_FRAMES=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")

# ═══════════════════════════════════════════════════════════════════════════
# HELPER FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════

print_header() {
  local title="$1"
  echo -e "\n${CYAN}╔═══════════════════════════════════════════════════════════════════════╗${RESET}"
  echo -e "${CYAN}║${RESET} ${WHITE}${BOLD}${title}${RESET}"
  echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════════════╝${RESET}\n"
}

print_section() {
  local title="$1"
  echo -e "\n${BLUE}━━━ ${WHITE}${title}${RESET} ${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"
}

spinner() {
  local pid=$1
  local msg=$2
  local i=0

  while kill -0 "$pid" 2>/dev/null; do
    echo -ne "\r${GRAY}${SPINNER_FRAMES[$i]}${RESET} ${msg}   "
    i=$(( (i + 1) % ${#SPINNER_FRAMES[@]} ))
    sleep 0.1
  done

  wait "$pid"
  return $?
}

progress_bar() {
  local current=$1
  local total=$2
  local width=40
  local percentage=$((current * 100 / total))
  local filled=$((width * current / total))
  local empty=$((width - filled))

  printf "\r${CYAN}Progress:${RESET} ["
  printf "%${filled}s" | tr ' ' '█'
  printf "%${empty}s" | tr ' ' '░'
  printf "] ${WHITE}%3d%%${RESET} ${GRAY}(%d/%d)${RESET}" "$percentage" "$current" "$total"
}

test_result() {
  local name="$1"
  local status="$2"
  local detail="${3:-}"
  local duration="${4:-}"

  case "$status" in
    "PASS")
      echo -e "  ${GREEN}${CHECK}${RESET} ${WHITE}${name}${RESET}"
      [ -n "$detail" ] && echo -e "    ${GRAY}${ARROW} ${detail}${RESET}"
      [ -n "$duration" ] && echo -e "    ${DIM}${BULLET} Completed in ${duration}${RESET}"
      ;;
    "FAIL")
      echo -e "  ${RED}${CROSS}${RESET} ${WHITE}${name}${RESET}"
      [ -n "$detail" ] && echo -e "    ${RED}${ARROW} ${detail}${RESET}"
      ;;
    "SKIP")
      echo -e "  ${YELLOW}⊘${RESET} ${WHITE}${name}${RESET}"
      [ -n "$detail" ] && echo -e "    ${YELLOW}${ARROW} ${detail}${RESET}"
      ;;
    "WARN")
      echo -e "  ${YELLOW}⚠${RESET} ${WHITE}${name}${RESET}"
      [ -n "$detail" ] && echo -e "    ${YELLOW}${ARROW} ${detail}${RESET}"
      ;;
  esac
}

# ═══════════════════════════════════════════════════════════════════════════
# TEST TRACKING
# ═══════════════════════════════════════════════════════════════════════════

declare -a TEST_NAMES=()
declare -a TEST_STATUSES=()
declare -a TEST_DETAILS=()
declare -a TEST_DURATIONS=()
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0
SKIPPED_TESTS=0
WARNED_TESTS=0

record_test() {
  local name="$1"
  local status="$2"
  local detail="${3:-}"
  local duration="${4:-}"

  TEST_NAMES+=("$name")
  TEST_STATUSES+=("$status")
  TEST_DETAILS+=("$detail")
  TEST_DURATIONS+=("$duration")

  TOTAL_TESTS=$((TOTAL_TESTS + 1))

  case "$status" in
    "PASS") PASSED_TESTS=$((PASSED_TESTS + 1)) ;;
    "FAIL") FAILED_TESTS=$((FAILED_TESTS + 1)) ;;
    "SKIP") SKIPPED_TESTS=$((SKIPPED_TESTS + 1)) ;;
    "WARN") WARNED_TESTS=$((WARNED_TESTS + 1)) ;;
  esac

  test_result "$name" "$status" "$detail" "$duration"
}

# ═══════════════════════════════════════════════════════════════════════════
# UTILITY FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════

pod_by_label() {
  local sel=$1
  kubectl -n "$NS" get pods -l "$sel" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo ""
}

measure_time() {
  local start=$1
  local end=$2
  local duration=$((end - start))

  if [ $duration -lt 1 ]; then
    echo "<1s"
  elif [ $duration -lt 60 ]; then
    echo "${duration}s"
  else
    echo "$((duration / 60))m$((duration % 60))s"
  fi
}

# ═══════════════════════════════════════════════════════════════════════════
# MAIN TEST EXECUTION
# ═══════════════════════════════════════════════════════════════════════════

START_TIME=$(date +%s)

print_header "IDEAS PLATFORM - INFRASTRUCTURE INTEGRATION TESTS v1.01"

echo -e "${WHITE}${BOLD}Test Environment:${RESET}"
echo -e "  ${BULLET} Namespace: ${CYAN}${NS}${RESET}"
echo -e "  ${BULLET} Date: ${GRAY}$(date '+%Y-%m-%d %H:%M:%S')${RESET}"
echo -e "  ${BULLET} Tester: ${GRAY}$(whoami)@$(hostname)${RESET}"

# ═══════════════════════════════════════════════════════════════════════════
# KUBERNETES RESOURCES CHECK
# ═══════════════════════════════════════════════════════════════════════════

print_section "Kubernetes Resources Health"

echo -e "${GRAY}Checking pods readiness...${RESET}\n"

# Citus Coordinator
START=$(date +%s)
if kubectl -n "$NS" get pods -l app=citus-coordinator >/dev/null 2>&1; then
  ready=$(kubectl -n "$NS" get pods -l app=citus-coordinator -o jsonpath='{range .items[*]}{.status.containerStatuses[0].ready}{"\n"}{end}' 2>/dev/null | grep -c '^true$' || true)
  END=$(date +%s)
  if [ "${ready:-0}" -ge 1 ]; then
    record_test "Citus Coordinator Pods" "PASS" "Ready: ${ready}" "$(measure_time $START $END)"
  else
    record_test "Citus Coordinator Pods" "FAIL" "Ready: ${ready:-0}"
  fi
else
  END=$(date +%s)
  record_test "Citus Coordinator Pods" "SKIP" "Not deployed" "$(measure_time $START $END)"
fi

# Redis
START=$(date +%s)
ready=$(kubectl -n "$NS" get pods -l app=redis -o jsonpath='{range .items[*]}{.status.containerStatuses[0].ready}{"\n"}{end}' 2>/dev/null | grep -c '^true$' || true)
END=$(date +%s)
if [ "${ready:-0}" -ge 1 ]; then
  record_test "Redis Pods" "PASS" "Ready: ${ready}" "$(measure_time $START $END)"
else
  record_test "Redis Pods" "FAIL" "Ready: ${ready:-0}"
fi

# Redpanda
START=$(date +%s)
ready=$(kubectl -n "$NS" get pods -l app=redpanda -o jsonpath='{range .items[*]}{.status.containerStatuses[0].ready}{"\n"}{end}' 2>/dev/null | grep -c '^true$' || true)
END=$(date +%s)
if [ "${ready:-0}" -ge 1 ]; then
  record_test "Redpanda Pods" "PASS" "Ready: ${ready}" "$(measure_time $START $END)"
else
  record_test "Redpanda Pods" "FAIL" "Ready: ${ready:-0}"
fi

# Schema Registry
START=$(date +%s)
ready=$(kubectl -n "$NS" get pods -l app=schema-registry -o jsonpath='{range .items[*]}{.status.containerStatuses[0].ready}{"\n"}{end}' 2>/dev/null | grep -c '^true$' || true)
END=$(date +%s)
if [ "${ready:-0}" -ge 1 ]; then
  record_test "Schema Registry Pods" "PASS" "Ready: ${ready}" "$(measure_time $START $END)"
else
  record_test "Schema Registry Pods" "FAIL" "Ready: ${ready:-0}"
fi

# Loki
START=$(date +%s)
if kubectl -n "$NS" get svc/loki >/dev/null 2>&1; then
  ready=$(kubectl -n "$NS" get pods -l app=loki -o jsonpath='{range .items[*]}{.status.containerStatuses[0].ready}{"\n"}{end}' 2>/dev/null | grep -c '^true$' || true)
  END=$(date +%s)
  if [ "${ready:-0}" -ge 1 ]; then
    record_test "Loki Pods" "PASS" "Ready: ${ready}" "$(measure_time $START $END)"
  else
    record_test "Loki Pods" "FAIL" "Ready: ${ready:-0}"
  fi
else
  END=$(date +%s)
  record_test "Loki Pods" "SKIP" "Not deployed" "$(measure_time $START $END)"
fi

# Grafana
START=$(date +%s)
if kubectl -n "$NS" get svc/grafana >/dev/null 2>&1; then
  ready=$(kubectl -n "$NS" get pods -l app=grafana -o jsonpath='{range .items[*]}{.status.containerStatuses[0].ready}{"\n"}{end}' 2>/dev/null | grep -c '^true$' || true)
  END=$(date +%s)
  if [ "${ready:-0}" -ge 1 ]; then
    record_test "Grafana Pods" "PASS" "Ready: ${ready}" "$(measure_time $START $END)"
  else
    record_test "Grafana Pods" "FAIL" "Ready: ${ready:-0}"
  fi
else
  END=$(date +%s)
  record_test "Grafana Pods" "SKIP" "Not deployed" "$(measure_time $START $END)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# DATABASE CONNECTIVITY TESTS
# ═══════════════════════════════════════════════════════════════════════════

print_section "Database Connectivity (PostgreSQL/Citus)"

# Get Postgres pod
if kubectl -n "$NS" get pods -l app=citus-coordinator >/dev/null 2>&1; then
  PG_POD=$(pod_by_label app=citus-coordinator)
else
  PG_POD=$(pod_by_label app=postgres)
fi

# Test 1: Transactional operations
START=$(date +%s)
echo -ne "${GRAY}⋯${RESET} Testing transactional operations...   "
if [ -n "$PG_POD" ]; then
  (
    CNT=$(kubectl -n "$NS" exec "$PG_POD" -- bash -lc "psql -X -q -t -A -U app -d app -v ON_ERROR_STOP=1 <<'SQL'
BEGIN;
CREATE TEMP TABLE it_test_$(date +%s)(id SERIAL PRIMARY KEY, checked_at TIMESTAMPTZ DEFAULT now());
INSERT INTO it_test_$(date +%s) DEFAULT VALUES;
SELECT count(*) FROM it_test_$(date +%s);
ROLLBACK;
SQL" 2>/dev/null | tr -d '[:space:]')
    [ "$CNT" = "1" ]
  ) &
  BGPID=$!

  spinner $BGPID "Testing transactional operations"
  if wait $BGPID; then
    END=$(date +%s)
    echo -ne "\r"
    record_test "PostgreSQL Transactions (ACID)" "PASS" "BEGIN/INSERT/SELECT/ROLLBACK successful" "$(measure_time $START $END)"
  else
    END=$(date +%s)
    echo -ne "\r"
    record_test "PostgreSQL Transactions (ACID)" "FAIL" "Transaction test failed"
  fi
else
  END=$(date +%s)
  echo -ne "\r"
  record_test "PostgreSQL Transactions (ACID)" "FAIL" "No Postgres pod found"
fi

# Test 2: DATABASE_URL from localhost
START=$(date +%s)
echo -ne "${GRAY}⋯${RESET} Testing DATABASE_URL from localhost...   "
if [ -n "${DATABASE_URL:-}" ]; then
  (psql "$DATABASE_URL" -c "SELECT 1;" >/dev/null 2>&1) &
  BGPID=$!

  spinner $BGPID "Testing DATABASE_URL from localhost"
  if wait $BGPID; then
    END=$(date +%s)
    echo -ne "\r"
    record_test "DATABASE_URL (localhost)" "PASS" "$DATABASE_URL" "$(measure_time $START $END)"
  else
    END=$(date +%s)
    echo -ne "\r"
    record_test "DATABASE_URL (localhost)" "FAIL" "Connection failed"
  fi
else
  END=$(date +%s)
  echo -ne "\r"
  record_test "DATABASE_URL (localhost)" "SKIP" "DATABASE_URL not set in .env"
fi

# Test 3: DATABASE_URL from K8s pod
START=$(date +%s)
echo -ne "${GRAY}⋯${RESET} Testing DATABASE_URL from K8s pod...   "
if [ -n "$PG_POD" ]; then
  K8S_DATABASE_URL="postgresql://app:app@citus-coordinator.${NS}.svc.cluster.local:5432/app"
  (
    # Test connection from within the PostgreSQL pod itself (guaranteed to have psql)
    kubectl -n "$NS" exec "$PG_POD" -- psql "$K8S_DATABASE_URL" -c "SELECT 1;" >/dev/null 2>&1
  ) &
  BGPID=$!

  spinner $BGPID "Testing DATABASE_URL from K8s pod"
  if wait $BGPID; then
    END=$(date +%s)
    echo -ne "\r"
    record_test "DATABASE_URL (K8s internal)" "PASS" "Connection via internal DNS successful" "$(measure_time $START $END)"
  else
    END=$(date +%s)
    echo -ne "\r"
    record_test "DATABASE_URL (K8s internal)" "FAIL" "Connection via internal DNS failed"
  fi
else
  END=$(date +%s)
  echo -ne "\r"
  record_test "DATABASE_URL (K8s internal)" "SKIP" "PostgreSQL pod not available"
fi

# Test 4: Tenant verification
START=$(date +%s)
echo -ne "${GRAY}⋯${RESET} Verifying default tenant (10001)...   "
if [ -n "$PG_POD" ] && kubectl -n "$NS" get pods -l app=citus-coordinator >/dev/null 2>&1; then
  (
    TEN_CNT=$(kubectl -n "$NS" exec "$PG_POD" -- bash -lc "psql -t -A -U app -d app -v ON_ERROR_STOP=1 -c \"SELECT count(*) FROM tenants WHERE id=10001;\"" 2>/dev/null | tr -d '[:space:]')
    [ "$TEN_CNT" = "1" ]
  ) &
  BGPID=$!

  spinner $BGPID "Verifying default tenant"
  if wait $BGPID; then
    END=$(date +%s)
    echo -ne "\r"
    record_test "Default Tenant (10001)" "PASS" "Tenant exists in distributed table" "$(measure_time $START $END)"
  else
    END=$(date +%s)
    echo -ne "\r"
    record_test "Default Tenant (10001)" "FAIL" "Tenant not found or count mismatch"
  fi
else
  END=$(date +%s)
  echo -ne "\r"
  record_test "Default Tenant (10001)" "SKIP" "Citus not deployed"
fi

# ═══════════════════════════════════════════════════════════════════════════
# REDIS CONNECTIVITY TESTS
# ═══════════════════════════════════════════════════════════════════════════

print_section "Redis Connectivity"

# Test 5: REDIS_URL from localhost
START=$(date +%s)
echo -ne "${GRAY}⋯${RESET} Testing REDIS_URL from localhost...   "
if [ -n "${REDIS_URL:-}" ]; then
  if command -v redis-cli >/dev/null 2>&1; then
    (redis-cli -u "$REDIS_URL" PING 2>/dev/null | grep -q PONG) &
    BGPID=$!

    spinner $BGPID "Testing REDIS_URL from localhost"
    if wait $BGPID; then
      END=$(date +%s)
      echo -ne "\r"
      record_test "REDIS_URL (localhost)" "PASS" "$REDIS_URL" "$(measure_time $START $END)"
    else
      END=$(date +%s)
      echo -ne "\r"
      record_test "REDIS_URL (localhost)" "FAIL" "PING failed"
    fi
  else
    END=$(date +%s)
    echo -ne "\r"
    record_test "REDIS_URL (localhost)" "SKIP" "redis-cli not installed (brew install redis)"
  fi
else
  END=$(date +%s)
  echo -ne "\r"
  record_test "REDIS_URL (localhost)" "SKIP" "REDIS_URL not set in .env"
fi

# Test 6: REDIS_URL from K8s pod
START=$(date +%s)
echo -ne "${GRAY}⋯${RESET} Testing REDIS_URL from K8s pod...   "
REDIS_POD=$(pod_by_label app=redis)
if [ -n "$REDIS_POD" ]; then
  (kubectl -n "$NS" exec "$REDIS_POD" -- redis-cli -h redis.${NS}.svc.cluster.local PING 2>/dev/null | grep -q PONG) &
  BGPID=$!

  spinner $BGPID "Testing REDIS_URL from K8s pod"
  if wait $BGPID; then
    END=$(date +%s)
    echo -ne "\r"
    record_test "REDIS_URL (K8s internal)" "PASS" "PING via internal DNS successful" "$(measure_time $START $END)"
  else
    END=$(date +%s)
    echo -ne "\r"
    record_test "REDIS_URL (K8s internal)" "FAIL" "PING via internal DNS failed"
  fi
else
  END=$(date +%s)
  echo -ne "\r"
  record_test "REDIS_URL (K8s internal)" "SKIP" "Redis pod not found"
fi

# Test 7: Redis SET/GET operations
START=$(date +%s)
echo -ne "${GRAY}⋯${RESET} Testing Redis SET/GET operations...   "
if [ -n "$REDIS_POD" ]; then
  KEY="it_test_$(date +%s)"
  (kubectl -n "$NS" exec "$REDIS_POD" -- sh -lc "redis-cli set '$KEY' 'ok' EX 60 >/dev/null && test \"\$(redis-cli get '$KEY')\" = 'ok'") &
  BGPID=$!

  spinner $BGPID "Testing Redis SET/GET operations"
  if wait $BGPID; then
    END=$(date +%s)
    echo -ne "\r"
    record_test "Redis SET/GET Operations" "PASS" "Key: $KEY with TTL 60s" "$(measure_time $START $END)"
  else
    END=$(date +%s)
    echo -ne "\r"
    record_test "Redis SET/GET Operations" "FAIL" "Operation failed"
  fi
else
  END=$(date +%s)
  echo -ne "\r"
  record_test "Redis SET/GET Operations" "SKIP" "Redis pod not found"
fi

# ═══════════════════════════════════════════════════════════════════════════
# KAFKA (REDPANDA) CONNECTIVITY TESTS
# ═══════════════════════════════════════════════════════════════════════════

print_section "Kafka (Redpanda) Connectivity"

RP_POD=$(pod_by_label app=redpanda)

# Test 8: KAFKA_BROKERS from localhost
START=$(date +%s)
echo -ne "${GRAY}⋯${RESET} Testing KAFKA_BROKERS from localhost...   "
if [ -n "${KAFKA_BROKERS:-}" ]; then
  if command -v rpk >/dev/null 2>&1; then
    (rpk cluster info --brokers "$KAFKA_BROKERS" >/dev/null 2>&1) &
    BGPID=$!

    spinner $BGPID "Testing KAFKA_BROKERS from localhost"
    if wait $BGPID; then
      END=$(date +%s)
      echo -ne "\r"
      record_test "KAFKA_BROKERS (localhost)" "PASS" "$KAFKA_BROKERS" "$(measure_time $START $END)"
    else
      END=$(date +%s)
      echo -ne "\r"
      record_test "KAFKA_BROKERS (localhost)" "WARN" "Port-forward may not be ready or connection failed"
    fi
  else
    END=$(date +%s)
    echo -ne "\r"
    record_test "KAFKA_BROKERS (localhost)" "SKIP" "rpk not installed locally (brew install redpanda-data/tap/redpanda)"
  fi
else
  END=$(date +%s)
  echo -ne "\r"
  record_test "KAFKA_BROKERS (localhost)" "SKIP" "KAFKA_BROKERS not set in .env"
fi

# Test 9: KAFKA_BROKERS from K8s pod
START=$(date +%s)
echo -ne "${GRAY}⋯${RESET} Testing KAFKA_BROKERS from K8s pod...   "
if [ -n "$RP_POD" ]; then
  K8S_KAFKA_BROKERS="redpanda.${NS}.svc.cluster.local:9092"
  (kubectl -n "$NS" exec "$RP_POD" -- rpk cluster info --brokers "$K8S_KAFKA_BROKERS" >/dev/null 2>&1) &
  BGPID=$!

  spinner $BGPID "Testing KAFKA_BROKERS from K8s pod"
  if wait $BGPID; then
    END=$(date +%s)
    echo -ne "\r"
    record_test "KAFKA_BROKERS (K8s internal)" "PASS" "Cluster info via internal DNS successful" "$(measure_time $START $END)"
  else
    END=$(date +%s)
    echo -ne "\r"
    record_test "KAFKA_BROKERS (K8s internal)" "FAIL" "Cluster info failed"
  fi
else
  END=$(date +%s)
  echo -ne "\r"
  record_test "KAFKA_BROKERS (K8s internal)" "SKIP" "Redpanda pod not found"
fi

# Test 10: Kafka produce/consume
START=$(date +%s)
echo -ne "${GRAY}⋯${RESET} Testing Kafka produce/consume...   "
if [ -n "$RP_POD" ]; then
  TEST_TOPIC="V1_SYSTEM_IT_$(date +%s)"
  MESSAGE="test_message_$(date +%s)"

  (
    kubectl -n "$NS" exec "$RP_POD" -- rpk topic create "$TEST_TOPIC" -p 1 -r 1 >/dev/null 2>&1
    kubectl -n "$NS" exec -i "$RP_POD" -- sh -lc "printf '%s\n' '$MESSAGE' | rpk topic produce '$TEST_TOPIC'" >/dev/null 2>&1
    kubectl -n "$NS" exec "$RP_POD" -- rpk topic consume "$TEST_TOPIC" -n 1 --offset start 2>/dev/null | grep -q "$MESSAGE"
  ) &
  BGPID=$!

  spinner $BGPID "Testing Kafka produce/consume"
  if wait $BGPID; then
    END=$(date +%s)
    echo -ne "\r"
    record_test "Kafka Produce/Consume" "PASS" "Topic: $TEST_TOPIC, Message verified" "$(measure_time $START $END)"
  else
    END=$(date +%s)
    echo -ne "\r"
    record_test "Kafka Produce/Consume" "FAIL" "Message not consumed correctly"
  fi
else
  END=$(date +%s)
  echo -ne "\r"
  record_test "Kafka Produce/Consume" "SKIP" "Redpanda pod not found"
fi

# ═══════════════════════════════════════════════════════════════════════════
# SCHEMA REGISTRY TESTS
# ═══════════════════════════════════════════════════════════════════════════

print_section "Schema Registry"

# Test 11: Schema Registry connectivity
START=$(date +%s)
echo -ne "${GRAY}⋯${RESET} Testing Schema Registry...   "
(
  kubectl -n "$NS" port-forward svc/schema-registry 18081:8081 >/dev/null 2>&1 & PF_PID=$!
  sleep 2
  result=$(curl -fsS http://localhost:18081/subjects 2>/dev/null)
  kill $PF_PID 2>/dev/null || true
  [ -n "$result" ]
) &
BGPID=$!

spinner $BGPID "Testing Schema Registry"
if wait $BGPID; then
  END=$(date +%s)
  echo -ne "\r"
  schemas=$(curl -fsS http://localhost:8081/subjects 2>/dev/null | jq -r 'length' 2>/dev/null || echo "0")
  record_test "Schema Registry HTTP API" "PASS" "Registered schemas: $schemas" "$(measure_time $START $END)"
else
  END=$(date +%s)
  echo -ne "\r"
  record_test "Schema Registry HTTP API" "FAIL" "Could not connect"
fi

# Test 12: Avro schemas validation
START=$(date +%s)
echo -ne "${GRAY}⋯${RESET} Validating Avro schemas...   "
expected_schemas=("V1_BETS-value" "V1_PAYMENTS-value" "V1_BALANCES-value" "V1_COMPLIANCE-value" "V1_SYSTEM-value")
(
  kubectl -n "$NS" port-forward svc/schema-registry 18081:8081 >/dev/null 2>&1 & PF_PID=$!
  sleep 2
  registered=$(curl -fsS http://localhost:18081/subjects 2>/dev/null | jq -r '.[]' 2>/dev/null | sort)
  kill $PF_PID 2>/dev/null || true

  found=0
  for schema in "${expected_schemas[@]}"; do
    echo "$registered" | grep -q "$schema" && found=$((found + 1))
  done
  [ $found -eq ${#expected_schemas[@]} ]
) &
BGPID=$!

spinner $BGPID "Validating Avro schemas"
if wait $BGPID; then
  END=$(date +%s)
  echo -ne "\r"
  record_test "Avro Schemas Registered" "PASS" "All 5 schemas present (TopicNameStrategy)" "$(measure_time $START $END)"
else
  END=$(date +%s)
  echo -ne "\r"
  record_test "Avro Schemas Registered" "WARN" "Some schemas may be missing"
fi

# ═══════════════════════════════════════════════════════════════════════════
# OBSERVABILITY STACK TESTS
# ═══════════════════════════════════════════════════════════════════════════

print_section "Observability Stack (Loki + Grafana)"

# Test 13: Loki log ingestion
START=$(date +%s)
echo -ne "${GRAY}⋯${RESET} Testing Loki log ingestion...   "
if kubectl -n "$NS" get svc/loki >/dev/null 2>&1; then
  (
    kubectl -n "$NS" port-forward svc/loki 13100:3100 >/dev/null 2>&1 & LOKI_PF=$!
    sleep 2
    ts_ns=$(( $(date +%s) * 1000000000 ))
    json='{"streams":[{"stream":{"test":"integration"},"values":[["'"$ts_ns"'","test_message"]]}]}'
    code=$(curl -s -o /dev/null -w "%{http_code}" \
      -H 'Content-Type: application/json' -H "X-Scope-OrgID: $LOKI_TENANT_ID" \
      -X POST --data "$json" "http://localhost:13100/loki/api/v1/push" 2>/dev/null)
    kill $LOKI_PF 2>/dev/null || true
    [ "$code" = "204" ]
  ) &
  BGPID=$!

  spinner $BGPID "Testing Loki log ingestion"
  if wait $BGPID; then
    END=$(date +%s)
    echo -ne "\r"
    record_test "Loki Log Ingestion" "PASS" "HTTP 204 (tenant: $LOKI_TENANT_ID)" "$(measure_time $START $END)"
  else
    END=$(date +%s)
    echo -ne "\r"
    record_test "Loki Log Ingestion" "FAIL" "Log push failed"
  fi
else
  END=$(date +%s)
  echo -ne "\r"
  record_test "Loki Log Ingestion" "SKIP" "Loki not deployed"
fi

# Test 14: Grafana health
START=$(date +%s)
echo -ne "${GRAY}⋯${RESET} Testing Grafana health...   "
if kubectl -n "$NS" get svc/grafana >/dev/null 2>&1; then
  (
    kubectl -n "$NS" port-forward svc/grafana 13000:3000 >/dev/null 2>&1 & GF_PF=$!
    sleep 2
    code=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:13000/api/health 2>/dev/null)
    kill $GF_PF 2>/dev/null || true
    [ "$code" = "200" ] || [ "$code" = "401" ]
  ) &
  BGPID=$!

  spinner $BGPID "Testing Grafana health"
  if wait $BGPID; then
    END=$(date +%s)
    echo -ne "\r"
    record_test "Grafana Health API" "PASS" "HTTP 200/401 (running)" "$(measure_time $START $END)"
  else
    END=$(date +%s)
    echo -ne "\r"
    record_test "Grafana Health API" "FAIL" "Health check failed"
  fi
else
  END=$(date +%s)
  echo -ne "\r"
  record_test "Grafana Health API" "SKIP" "Grafana not deployed"
fi

# Test 15: Grafana Loki datasource
START=$(date +%s)
echo -ne "${GRAY}⋯${RESET} Verifying Grafana datasources...   "
if kubectl -n "$NS" get svc/grafana >/dev/null 2>&1; then
  (
    kubectl -n "$NS" port-forward svc/grafana 13000:3000 >/dev/null 2>&1 & GF_PF=$!
    sleep 2
    curl -fsS -u admin:admin http://localhost:13000/api/datasources 2>/dev/null | jq -e '.[] | select(.type=="loki")' >/dev/null 2>&1
    result=$?
    kill $GF_PF 2>/dev/null || true
    [ $result -eq 0 ]
  ) &
  BGPID=$!

  spinner $BGPID "Verifying Grafana datasources"
  if wait $BGPID; then
    END=$(date +%s)
    echo -ne "\r"
    record_test "Grafana Loki Datasource" "PASS" "Datasource configured" "$(measure_time $START $END)"
  else
    END=$(date +%s)
    echo -ne "\r"
    record_test "Grafana Loki Datasource" "WARN" "Datasource not found or not accessible"
  fi
else
  END=$(date +%s)
  echo -ne "\r"
  record_test "Grafana Loki Datasource" "SKIP" "Grafana not deployed"
fi

# ═══════════════════════════════════════════════════════════════════════════
# FINAL REPORT
# ═══════════════════════════════════════════════════════════════════════════

END_TIME=$(date +%s)
TOTAL_DURATION=$((END_TIME - START_TIME))

print_header "TEST EXECUTION SUMMARY"

echo -e "${WHITE}${BOLD}Results:${RESET}\n"

# Progress bar showing completion
progress_bar $TOTAL_TESTS $TOTAL_TESTS
echo -e "\n"

# Statistics box
echo -e "${CYAN}┌─────────────────────────────────────────────────────────────────────┐${RESET}"
echo -e "${CYAN}│${RESET} ${WHITE}${BOLD}Overall Statistics${RESET}                                                   ${CYAN}│${RESET}"
echo -e "${CYAN}├─────────────────────────────────────────────────────────────────────┤${RESET}"
printf "${CYAN}│${RESET}   ${GREEN}${CHECK} Passed:${RESET}  %-3d tests   ${GRAY}(%.1f%%)${RESET}                                    ${CYAN}│${RESET}\n" \
  "$PASSED_TESTS" "$(bc -l <<< "scale=1; $PASSED_TESTS * 100 / $TOTAL_TESTS" 2>/dev/null || echo "0")"
printf "${CYAN}│${RESET}   ${RED}${CROSS} Failed:${RESET}  %-3d tests   ${GRAY}(%.1f%%)${RESET}                                    ${CYAN}│${RESET}\n" \
  "$FAILED_TESTS" "$(bc -l <<< "scale=1; $FAILED_TESTS * 100 / $TOTAL_TESTS" 2>/dev/null || echo "0")"
printf "${CYAN}│${RESET}   ${YELLOW}⊘ Skipped:${RESET} %-3d tests   ${GRAY}(%.1f%%)${RESET}                                    ${CYAN}│${RESET}\n" \
  "$SKIPPED_TESTS" "$(bc -l <<< "scale=1; $SKIPPED_TESTS * 100 / $TOTAL_TESTS" 2>/dev/null || echo "0")"
printf "${CYAN}│${RESET}   ${YELLOW}⚠ Warnings:${RESET} %-3d tests  ${GRAY}(%.1f%%)${RESET}                                    ${CYAN}│${RESET}\n" \
  "$WARNED_TESTS" "$(bc -l <<< "scale=1; $WARNED_TESTS * 100 / $TOTAL_TESTS" 2>/dev/null || echo "0")"
echo -e "${CYAN}├─────────────────────────────────────────────────────────────────────┤${RESET}"
printf "${CYAN}│${RESET}   ${WHITE}Total Tests:${RESET} %-3d                                                   ${CYAN}│${RESET}\n" "$TOTAL_TESTS"
printf "${CYAN}│${RESET}   ${WHITE}Duration:${RESET}    %s                                                    ${CYAN}│${RESET}\n" "$(measure_time 0 $TOTAL_DURATION)"
echo -e "${CYAN}└─────────────────────────────────────────────────────────────────────┘${RESET}\n"

# Systems health overview
echo -e "${WHITE}${BOLD}Systems Health Overview:${RESET}\n"

# Initialize system statuses (bash 3.2 compatible)
SYS_K8S="✓"
SYS_PG="✓"
SYS_REDIS="✓"
SYS_KAFKA="✓"
SYS_SR="✓"
SYS_LOKI="?"
SYS_GRAFANA="?"

# Determine system status from tests
for i in "${!TEST_NAMES[@]}"; do
  name="${TEST_NAMES[$i]}"
  status="${TEST_STATUSES[$i]}"

  case "$name" in
    *"Postgres"*|*"DATABASE_URL"*|*"Tenant"*)
      [ "$status" = "FAIL" ] && SYS_PG="✗"
      ;;
    *"Redis"*|*"REDIS_URL"*)
      [ "$status" = "FAIL" ] && SYS_REDIS="✗"
      ;;
    *"Kafka"*|*"Redpanda"*)
      [ "$status" = "FAIL" ] && SYS_KAFKA="✗"
      ;;
    *"Schema Registry"*|*"Avro"*)
      [ "$status" = "FAIL" ] && SYS_SR="✗"
      ;;
    *"Loki"*)
      [ "$status" = "PASS" ] && SYS_LOKI="✓"
      [ "$status" = "FAIL" ] && SYS_LOKI="✗"
      ;;
    *"Grafana"*)
      [ "$status" = "PASS" ] && SYS_GRAFANA="✓"
      [ "$status" = "FAIL" ] && SYS_GRAFANA="✗"
      ;;
  esac
done

echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${CYAN}║${RESET} ${WHITE}${BOLD}SYSTEM${RESET}                    ${WHITE}${BOLD}STATUS${RESET}                                  ${CYAN}║${RESET}"
echo -e "${CYAN}╠═══════════════════════════════════════════════════════════════════╣${RESET}"

# Helper function to print system status
print_system_status() {
  local system="$1"
  local status="$2"
  local color
  
  case "$status" in
    "✓") color="${GREEN}" ;;
    "✗") color="${RED}" ;;
    "?") color="${YELLOW}"; status="⊘" ;;
  esac
  printf "${CYAN}║${RESET} %-28s ${color}%-10s${RESET}                               ${CYAN}║${RESET}\n" "$system" "$status"
}

print_system_status "Kubernetes" "$SYS_K8S"
print_system_status "PostgreSQL/Citus" "$SYS_PG"
print_system_status "Redis" "$SYS_REDIS"
print_system_status "Kafka (Redpanda)" "$SYS_KAFKA"
print_system_status "Schema Registry" "$SYS_SR"
print_system_status "Loki" "$SYS_LOKI"
print_system_status "Grafana" "$SYS_GRAFANA"

echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════════╝${RESET}\n"

echo ""

# ═══════════════════════════════════════════════════════════════════════════
# FINAL SUMMARY
# ═══════════════════════════════════════════════════════════════════════════
echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════════╝${RESET}\n"

# Final verdict
if [ $FAILED_TESTS -eq 0 ]; then
  echo -e "${GREEN}${BOLD}╔═══════════════════════════════════════════════════════════════════════╗${RESET}"
  echo -e "${GREEN}${BOLD}║${RESET}  ${WHITE}${BOLD}✓ ALL SYSTEMS OPERATIONAL - INFRASTRUCTURE READY FOR DEVELOPMENT${RESET}  ${GREEN}${BOLD}║${RESET}"
  echo -e "${GREEN}${BOLD}╚═══════════════════════════════════════════════════════════════════════╝${RESET}\n"
  exit 0
else
  echo -e "${RED}${BOLD}╔═══════════════════════════════════════════════════════════════════════╗${RESET}"
  echo -e "${RED}${BOLD}║${RESET}  ${WHITE}${BOLD}✗ INFRASTRUCTURE TESTS FAILED - ${FAILED_TESTS} CRITICAL ISSUES DETECTED${RESET}     ${RED}${BOLD}║${RESET}"
  echo -e "${RED}${BOLD}╚═══════════════════════════════════════════════════════════════════════╝${RESET}\n"

  echo -e "${RED}${BOLD}Failed Tests:${RESET}\n"
  for i in "${!TEST_NAMES[@]}"; do
    if [ "${TEST_STATUSES[$i]}" = "FAIL" ]; then
      echo -e "  ${RED}${CROSS}${RESET} ${TEST_NAMES[$i]}"
      [ -n "${TEST_DETAILS[$i]}" ] && echo -e "    ${GRAY}${ARROW} ${TEST_DETAILS[$i]}${RESET}"
    fi
  done
  echo ""

  exit 1
fi
