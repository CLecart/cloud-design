#!/usr/bin/env bash
# Checks the NetworkPolicies of Manifests/network-policies.yaml: tries TCP
# connections between the services, and from an "intruder" pod that no policy
# allows, then compares every result with the expected one.
#
# A connection refused by a policy is dropped, so it ends in a timeout. The
# probes use Node.js, present in the application images: from the api-gateway,
# inventory-app and billing-app containers (kubectl exec), and from a temporary
# intruder pod started from the api-gateway image.
#
# Usage: Scripts/network-test.sh
#
# Environment:
#   KUBE_CONTEXT  kubectl context of the cluster (default cloud-design)
#   NAMESPACE     namespace of the application (default cloud-design)
set -euo pipefail

KUBE_CONTEXT="${KUBE_CONTEXT:-cloud-design}"
NAMESPACE="${NAMESPACE:-cloud-design}"
kube() { kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" "$@"; }

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  sed -n '2,/^set -euo/p' "$0" | sed '$d' | cut -c3-
  exit 0
fi

# Prints "<host:port> OPEN|BLOCKED|ERROR <code>" for every argument.
PROBE='
const net = require("net");
const targets = process.argv.slice(1);
let pending = targets.length;
for (const target of targets) {
  const [host, port] = target.split(":");
  const socket = net.connect({ host, port: Number(port) });
  const done = (result) => {
    console.log(`${target} ${result}`);
    socket.destroy();
    if (--pending === 0) process.exit(0);
  };
  socket.setTimeout(4000);
  socket.on("connect", () => done("OPEN"));
  socket.on("timeout", () => done("BLOCKED"));
  socket.on("error", (error) => done(`ERROR ${error.code}`));
}'

failed=0
# check SOURCE "EXPECTED_OPEN..." OUTPUT TARGET...: every target must appear in
# OUTPUT with the expected result; a missing line counts as a failure.
check() {
  local source=$1 expected_open=$2 output=$3 target result expected
  shift 3
  echo "== from $source"
  for target in "$@"; do
    result="$(awk -v t="$target" '$1 == t { print $2; exit }' <<<"$output")"
    expected=BLOCKED
    [[ " $expected_open " == *" $target "* ]] && expected=OPEN
    if [[ "$result" == "$expected" ]]; then
      printf '  PASS  %-20s %s\n' "$target" "$result"
    else
      printf '  FAIL  %-20s %s (expected %s)\n' "$target" "${result:-no answer}" "$expected"
      failed=$((failed + 1))
    fi
  done
}

# The outputs are captured first (set -e stops on a failed command), then checked
# in this shell so the failure counter is kept.
targets=(inventory-app:8080 rabbitmq:5672 inventory-db:5432 billing-db:5432)
output="$(kube exec deploy/api-gateway -- node -e "$PROBE" "${targets[@]}")"
check api-gateway "inventory-app:8080 rabbitmq:5672" "$output" "${targets[@]}"

targets=(inventory-db:5432 billing-db:5432 rabbitmq:5672)
output="$(kube exec deploy/inventory-app -- node -e "$PROBE" "${targets[@]}")"
check inventory-app "inventory-db:5432" "$output" "${targets[@]}"

targets=(billing-db:5432 rabbitmq:5672 inventory-db:5432 inventory-app:8080)
output="$(kube exec statefulset/billing-app -- node -e "$PROBE" "${targets[@]}")"
check billing-app "billing-db:5432 rabbitmq:5672" "$output" "${targets[@]}"

image="$(kube get deployment api-gateway -o jsonpath='{.spec.template.spec.containers[0].image}')"
kube delete pod intruder --ignore-not-found --wait=true >/dev/null
trap 'kube delete pod intruder --ignore-not-found --wait=false >/dev/null' EXIT
targets=(api-gateway:3000 inventory-app:8080 rabbitmq:5672 inventory-db:5432 billing-db:5432)
kube run intruder --image="$image" --labels=app=intruder --restart=Never --command -- \
  node -e "$PROBE" "${targets[@]}" >/dev/null
kube wait --for=jsonpath='{.status.phase}'=Succeeded pod/intruder --timeout=90s >/dev/null
output="$(kube logs intruder)"
check "an intruder pod (label app=intruder)" "api-gateway:3000" "$output" "${targets[@]}"

echo
if [[ "$failed" -eq 0 ]]; then
  echo "All network checks passed"
else
  echo "$failed network check(s) failed"
  exit 1
fi
