#!/usr/bin/env bash
# Autoscaling tests on the EKS cluster, with the evidence printed every 15 s.
#
#   pods   floods GET /api/movies/ from inside the cluster so the CPU usage of
#          api-gateway and inventory-app goes above the 60 % target of their
#          HorizontalPodAutoscalers: they scale out (up to 5 replicas each),
#          then back in about a minute after the load stops.
#   nodes  asks for more CPU than the two nodes can give (a "capacity-test"
#          Deployment of pause containers, 1500m each): the pods stay Pending,
#          the Cluster Autoscaler adds a node, never more than node_max_size (3),
#          and removes it about 2 minutes after the Deployment is deleted.
#
# The temporary pods are deleted at the end, even on Ctrl-C.
#
# Usage: Scripts/load-test.sh pods  [--duration SECONDS] [--workers N]
#        Scripts/load-test.sh nodes [--duration SECONDS] [--replicas N]
#   --duration  how long the load or the capacity request lasts (default 180)
#   --workers   parallel request loops of the pods scenario (default 16)
#   --replicas  capacity-test pods of the nodes scenario (default 2)
#
# Environment:
#   KUBE_CONTEXT  kubectl context of the cluster (default cloud-design)
#   NAMESPACE     namespace of the application (default cloud-design)
set -euo pipefail

usage() {
  sed -n '2,/^set -euo/p' "$0" | sed '$d' | cut -c3-
}

scenario="${1:-}"
[[ "$scenario" == "-h" || "$scenario" == "--help" ]] && { usage; exit 0; }
[[ "$scenario" == pods || "$scenario" == nodes ]] ||
  { echo "error: first argument must be 'pods' or 'nodes' (see $0 --help)" >&2; exit 2; }
shift

duration=180
workers=16
replicas=2
while [[ $# -gt 0 ]]; do
  case "$1" in
    --duration) duration=${2:?--duration needs a value}; shift 2 ;;
    --workers) workers=${2:?--workers needs a value}; shift 2 ;;
    --replicas) replicas=${2:?--replicas needs a value}; shift 2 ;;
    *)
      echo "error: unknown option '$1' (see $0 --help)" >&2
      exit 2
      ;;
  esac
done
for value in "$duration" "$workers" "$replicas"; do
  [[ "$value" =~ ^[0-9]+$ && "$value" -gt 0 ]] ||
    { echo "error: --duration, --workers and --replicas take positive integers" >&2; exit 2; }
done

KUBE_CONTEXT="${KUBE_CONTEXT:-cloud-design}"
NAMESPACE="${NAMESPACE:-cloud-design}"
kube() { kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" "$@"; }

cleanup() {
  echo "== deleting the test pods"
  # --grace-period=1: the busybox shell waits on its request loops and would
  # otherwise sit in Terminating for its whole grace period.
  kube delete pod load-generator --ignore-not-found --wait=false --grace-period=1 >/dev/null
  kube delete deployment capacity-test --ignore-not-found --wait=false >/dev/null
}
trap cleanup EXIT

show_hpa() {
  kube get hpa -o custom-columns='HPA:.metadata.name,CPU%:.status.currentMetrics[0].resource.current.averageUtilization,TARGET%:.spec.metrics[0].resource.target.averageUtilization,REPLICAS:.status.currentReplicas,MIN:.spec.minReplicas,MAX:.spec.maxReplicas'
}

show_nodes() {
  kubectl --context "$KUBE_CONTEXT" get nodes --no-headers \
    -o custom-columns='NODE:.metadata.name,TYPE:.metadata.labels.node\.kubernetes\.io/instance-type,ZONE:.metadata.labels.topology\.kubernetes\.io/zone,STATUS:.status.conditions[-1].type'
}

start_pods_load() {
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
        requests:
          cpu: 100m
          memory: 32Mi
        limits:
          cpu: "1"
          memory: 64Mi
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
EOF
  kube wait --for=condition=Ready pod/load-generator --timeout=120s >/dev/null
}

start_capacity_request() {
  echo "== asking for $replicas x 1500m CPU (capacity-test) for ${duration}s"
  kube apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: capacity-test
  labels:
    app: capacity-test
spec:
  replicas: $replicas
  selector:
    matchLabels:
      app: capacity-test
  template:
    metadata:
      labels:
        app: capacity-test
    spec:
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 65535
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: pause
          image: registry.k8s.io/pause:3.10
          resources:
            requests:
              cpu: 1500m
              memory: 32Mi
            limits:
              memory: 32Mi
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
EOF
}

echo "== before the test ($(date +%T))"
show_hpa
show_nodes

if [[ "$scenario" == pods ]]; then
  start_pods_load
else
  start_capacity_request
fi

# The metrics server samples every ~15 s and the HPA controller reconciles every
# 15 s; a new node takes 1 to 2 minutes to join the cluster.
end=$((SECONDS + duration))
while [[ $SECONDS -lt $end ]]; do
  echo "-- $(date +%T)"
  if [[ "$scenario" == pods ]]; then
    show_hpa
  else
    kube get pods -l app=capacity-test --no-headers -o custom-columns='POD:.metadata.name,PHASE:.status.phase,NODE:.spec.nodeName'
    show_nodes
  fi
  sleep 15
done

echo "== at the end of the test ($(date +%T))"
show_hpa
kube get pods -l 'app in (api-gateway, inventory-app, capacity-test)' -o wide
show_nodes
if [[ "$scenario" == pods ]]; then
  echo "the autoscalers go back to 1 replica 1 to 2 minutes from now (kubectl get hpa -n $NAMESPACE -w)"
else
  echo "the extra node is removed about 2 minutes after the capacity-test pods are gone (kubectl get nodes -w)"
fi
