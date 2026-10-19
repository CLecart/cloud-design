#!/usr/bin/env bash
# End-to-end audit scenario against the stack deployed on the K3s cluster:
#
#   1. wait for the gateway GET /health
#   2. POST /api/movies/ -> 201, then GET /api/movies/ -> 200 contains the new title
#   3. POST /api/billing/ -> 200, a new row appears in billing-db (orders table)
#   4. scale billing-app to 0, POST /api/billing/ -> 200, the message waits in RabbitMQ
#   5. scale billing-app back to 1 -> the queue is drained and the order is stored
#
# Usage: Scripts/test-api.sh [--skip-stop]      (or ./orchestrator.sh test)
#   --skip-stop   run steps 1-3 only (billing-app is never stopped)
#
# Environment:
#   GATEWAY_URL     default http://192.168.56.110:3000
#   KUBE_CONTEXT    kubectl context of the cluster (default orchestrator)
#   HEALTH_TIMEOUT  seconds to wait for /health (default 120)
#   WAIT_TIMEOUT    seconds to wait for the database/queue to reflect a request (default 60)
set -euo pipefail

usage() {
  sed -n '2,/^set -euo/p' "$0" | sed '$d' | cut -c3-
}

skip_stop=false
for arg in "$@"; do
  case "$arg" in
    --skip-stop) skip_stop=true ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option '$arg' (usage: $0 [--skip-stop])" >&2
      exit 2
      ;;
  esac
done

GATEWAY_URL="${GATEWAY_URL:-http://192.168.56.110:3000}"
KUBE_CONTEXT="${KUBE_CONTEXT:-orchestrator}"
RABBITMQ_QUEUE=billing_queue
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-120}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-60}"

kube() { kubectl --context "$KUBE_CONTEXT" "$@"; }

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  GREEN=$'\033[32m' RED=$'\033[31m' YELLOW=$'\033[33m' BOLD=$'\033[1m' RESET=$'\033[0m'
else
  GREEN='' RED='' YELLOW='' BOLD='' RESET=''
fi

# --- Reporting helpers -------------------------------------------------------
results=()
failed=0

section() {
  echo
  echo "${BOLD}== $1 ==${RESET}"
}

pass() {
  results+=("${GREEN}PASS${RESET}  $1")
  echo "  ${GREEN}PASS${RESET} $1"
}

fail() {
  results+=("${RED}FAIL${RESET}  $1")
  failed=$((failed + 1))
  echo "  ${RED}FAIL${RESET} $1"
  if [[ -n "${2:-}" ]]; then
    echo "       $2"
  fi
}

# Print at most 300 characters of a response body.
show_body() {
  if [[ -n "$1" ]]; then
    echo "       ${1:0:300}"
  fi
}

summary() {
  section "Summary"
  printf '  %s\n' "${results[@]}"
  if [[ "$failed" -eq 0 ]]; then
    echo "${GREEN}All ${#results[@]} checks passed${RESET}"
  else
    echo "${RED}$failed of ${#results[@]} checks failed${RESET}"
  fi
}

# --- Probes ------------------------------------------------------------------
# request METHOD PATH [JSON_BODY]: sets HTTP_STATUS and HTTP_BODY (status 000 when unreachable).
request() {
  local method=$1 path=$2 body=${3:-} response
  local args=(--silent --show-error --max-time 15 --request "$method" --write-out $'\n%{http_code}')
  if [[ -n "$body" ]]; then
    args+=(--header 'Content-Type: application/json' --data "$body")
  fi
  response=$(curl "${args[@]}" "$GATEWAY_URL$path" 2>&1) || true
  HTTP_STATUS=${response##*$'\n'}
  HTTP_BODY=${response%$'\n'*}
  if [[ ! "$HTTP_STATUS" =~ ^[0-9]{3}$ ]]; then
    HTTP_STATUS=000
    HTTP_BODY=$response
  fi
}

expect_status() {
  if [[ "$HTTP_STATUS" == "$1" ]]; then
    pass "$2 -> HTTP $HTTP_STATUS"
  else
    fail "$2 -> HTTP $HTTP_STATUS (expected $1)" "${HTTP_BODY:0:300}"
  fi
}

# Poll COMMAND every second until it succeeds; fails after TIMEOUT seconds.
wait_until() {
  local timeout=$1 elapsed=0
  shift
  until "$@"; do
    if [[ "$elapsed" -ge "$timeout" ]]; then
      return 1
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
}

gateway_healthy() {
  request GET /health
  [[ "$HTTP_STATUS" == 200 ]]
}

# Number of rows of a SQL query in billing-db ("unknown" when the database
# cannot be queried). PGUSER and PGDATABASE are preset in the pod.
orders_count() {
  local where=${1:-true} count
  count=$(kube exec billing-db-0 -- psql -tAc "SELECT count(*) FROM orders WHERE $where" 2>/dev/null | tr -d '[:space:]' || true)
  echo "${count:-unknown}"
}

orders_above() {
  local count
  count=$(orders_count "$2")
  [[ "$count" =~ ^[0-9]+$ && count -gt $1 ]]
}

# Number of messages waiting in the billing queue (empty when the queue does not exist yet).
queue_messages() {
  kube exec rabbitmq-0 -- rabbitmqctl list_queues -q name messages 2>/dev/null |
    awk -v queue="$RABBITMQ_QUEUE" '$1 == queue { print $2 }' || true
}

queue_has() {
  [[ "$(queue_messages)" == "$1" ]]
}

billing_app_gone() {
  [[ -z "$(kube get pods -l app=billing-app -o name 2>/dev/null)" ]]
}

# Never leave billing-app scaled to 0 when the script is interrupted half-way.
billing_stopped=false
restore_billing_app() {
  if [[ "$billing_stopped" == true ]]; then
    echo "Scaling billing-app back to 1 (left stopped by an aborted run)" >&2
    kube scale statefulset billing-app --replicas=1 || true
  fi
}
trap restore_billing_app EXIT

# --- Scenario ----------------------------------------------------------------
echo "${BOLD}orchestrator end-to-end test${RESET}"
echo "  gateway: $GATEWAY_URL   kubectl context: $KUBE_CONTEXT"

section "1. API gateway health"
if wait_until "$HEALTH_TIMEOUT" gateway_healthy; then
  pass "GET /health -> HTTP 200"
  show_body "$HTTP_BODY"
else
  fail "GET /health not healthy after ${HEALTH_TIMEOUT}s (last status $HTTP_STATUS)" "${HTTP_BODY:0:300}"
  summary
  exit 1
fi

section "2. Inventory: POST /api/movies/ then GET /api/movies/"
request POST /api/movies/ '{"title":"A new movie","description":"Very short description"}'
expect_status 201 'POST /api/movies/ {"title":"A new movie","description":"Very short description"}'
show_body "$HTTP_BODY"
request GET /api/movies/
expect_status 200 'GET /api/movies/'
if [[ "$HTTP_BODY" == *'"A new movie"'* ]]; then
  pass 'GET /api/movies/ returns a JSON list containing "A new movie"'
else
  fail 'GET /api/movies/ does not contain "A new movie"' "${HTTP_BODY:0:300}"
fi
show_body "$HTTP_BODY"

section "3. Billing: POST /api/billing/ while billing-app is running"
orders_before=$(orders_count "user_id = 20")
if [[ "$orders_before" =~ ^[0-9]+$ ]]; then
  pass "orders of user 20 in billing-db: $orders_before"
else
  fail "cannot read the orders table (kubectl exec billing-db-0 -- psql ...)"
  orders_before=0
fi
request POST /api/billing/ '{"user_id":"20","number_of_items":"99","total_amount":"250"}'
expect_status 200 'POST /api/billing/ {"user_id":"20","number_of_items":"99","total_amount":"250"}'
show_body "$HTTP_BODY"
if wait_until "$WAIT_TIMEOUT" orders_above "$orders_before" "user_id = 20"; then
  pass "order of user 20 stored: $orders_before -> $(orders_count "user_id = 20")"
else
  fail "no new order of user 20 within ${WAIT_TIMEOUT}s"
fi

if [[ "$skip_stop" == true ]]; then
  echo
  echo "${YELLOW}--skip-stop: steps 4 and 5 (stop/start billing-app) skipped${RESET}"
else
  section "4. Billing: stop billing-app, POST /api/billing/, message kept in the queue"
  billing_stopped=true
  if ! kube scale statefulset billing-app --replicas=0; then
    fail "'kubectl scale statefulset billing-app --replicas=0' failed"
  fi
  if wait_until 60 billing_app_gone; then
    pass "billing-app is stopped (no billing-app pod left)"
  else
    fail "the billing-app-0 pod still exists"
  fi
  kube get statefulset billing-app
  orders_before=$(orders_count "user_id = 22")
  [[ "$orders_before" =~ ^[0-9]+$ ]] || orders_before=0
  request POST /api/billing/ '{"user_id":"22","number_of_items":"10","total_amount":"50"}'
  expect_status 200 'POST /api/billing/ {"user_id":"22","number_of_items":"10","total_amount":"50"}'
  show_body "$HTTP_BODY"
  if wait_until 15 queue_has 1; then
    pass "queue $RABBITMQ_QUEUE holds 1 message"
  else
    fail "queue $RABBITMQ_QUEUE holds '$(queue_messages)' message(s) (expected 1)"
  fi
  if [[ "$(orders_count "user_id = 22")" == "$orders_before" ]]; then
    pass "order of user 22 NOT stored yet ($orders_before row(s))"
  else
    fail "the order of user 22 was stored while billing-app is stopped"
  fi

  section "5. Billing: start billing-app, queue drained, order stored"
  if kube scale statefulset billing-app --replicas=1 && kube rollout status statefulset/billing-app --timeout=120s; then
    billing_stopped=false
    pass "billing-app is running again"
  else
    fail "billing-app did not become ready again"
  fi
  if wait_until "$WAIT_TIMEOUT" queue_has 0; then
    pass "queue $RABBITMQ_QUEUE is drained (0 message)"
  else
    fail "queue $RABBITMQ_QUEUE still holds '$(queue_messages)' message(s) after ${WAIT_TIMEOUT}s"
  fi
  if wait_until "$WAIT_TIMEOUT" orders_above "$orders_before" "user_id = 22"; then
    pass "order of user 22 stored: $orders_before -> $(orders_count "user_id = 22")"
  else
    fail "no new order of user 22 within ${WAIT_TIMEOUT}s"
  fi
fi

section "Orders table"
kube exec billing-db-0 -- psql -c 'TABLE orders' || true

summary
if [[ "$failed" -gt 0 ]]; then
  exit 1
fi
