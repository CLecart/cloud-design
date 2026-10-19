#!/usr/bin/env bash
# Horizontal autoscaling demo: floods GET /api/movies/ from inside the cluster
# so the CPU usage of api-gateway and inventory-app goes above the 60 % target
# of their HorizontalPodAutoscalers, and prints the HPAs while they scale out.
#
# The load comes from a temporary "load-generator" pod (busybox running
# parallel wget loops against the api-gateway Service); it is deleted at the
# end, even on Ctrl-C. The HPAs scale back in about 1 minute after the load stops.
#
# Usage: Scripts/load-test.sh [--duration SECONDS] [--workers N]   (or ./orchestrator.sh load)
#   --duration  how long the load lasts (default 180)
#   --workers   parallel request loops (default 8)
#
# Environment:
#   KUBE_CONTEXT  kubectl context of the cluster (default orchestrator)
set -euo pipefail

usage() {
  sed -n '2,/^set -euo/p' "$0" | sed '$d' | cut -c3-
}

duration=180
workers=8
while [[ $# -gt 0 ]]; do
  case "$1" in
    --duration) duration=${2:?--duration needs a value}; shift 2 ;;
    --workers) workers=${2:?--workers needs a value}; shift 2 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option '$1' (see $0 --help)" >&2
      exit 2
      ;;
  esac
done
[[ "$duration" =~ ^[0-9]+$ && "$workers" =~ ^[0-9]+$ && "$workers" -gt 0 ]] ||
  { echo "error: --duration and --workers take positive integers" >&2; exit 2; }

KUBE_CONTEXT="${KUBE_CONTEXT:-orchestrator}"
kube() { kubectl --context "$KUBE_CONTEXT" "$@"; }

cleanup() {
  echo "deleting the load generator"
  # --grace-period=1: the busybox shell waits on its request loops and would
  # otherwise sit in Terminating for its whole grace period.
  kube delete pod load-generator --ignore-not-found --wait=false --grace-period=1 >/dev/null
}
trap cleanup EXIT

echo "== autoscalers before the load"
kube get hpa

echo "== starting $workers request loops against http://api-gateway:3000/api/movies/ for ${duration}s"
kube apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: load-generator
  labels:
    app: load-generator
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: load-generator
      image: busybox:1.37
      command:
        - sh
        - -c
        - |
          for i in \$(seq $workers); do
            while true; do wget -q -O /dev/null http://api-gateway:3000/api/movies/; done &
          done
          wait
      resources:
        limits:
          cpu: 500m
          memory: 64Mi
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
EOF
kube wait --for=condition=Ready pod/load-generator --timeout=120s >/dev/null

# The metrics server samples every ~15 s and the HPA controller reconciles
# every 15 s: the first scale-out shows up after 30 to 60 s.
end=$((SECONDS + duration))
while [[ $SECONDS -lt $end ]]; do
  echo "-- $(date +%T)"
  kube get hpa -o custom-columns='HPA:.metadata.name,CPU%:.status.currentMetrics[0].resource.current.averageUtilization,TARGET%:.spec.metrics[0].resource.target.averageUtilization,REPLICAS:.status.currentReplicas,DESIRED:.status.desiredReplicas'
  sleep 15
done

echo "== autoscalers and pods at the end of the load"
kube get hpa
kube get pods -l 'app in (api-gateway, inventory-app)' -o wide
# 15 s between two metric samples, then the 60 s stabilization window of the
# autoscalers: the replicas go back to 1 a minute or two after the load stops.
echo "the autoscalers scale back to 1 replica 1 to 2 minutes from now (kubectl get hpa -w, Ctrl-C to leave)"
