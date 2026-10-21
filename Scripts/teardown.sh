#!/usr/bin/env bash
# End of a work session: remove everything that is billed by the hour, in the
# only safe order, then prove that nothing billable is left.
#
#   1. delete the "cloud-design" namespace while the cluster still runs: its
#      volume claims delete their EBS volumes (StorageClass reclaimPolicy Delete)
#   2. wait for those volumes to disappear; delete any that would remain
#   3. terraform destroy of terraform/platform (cluster, nodes, NAT, ALB, VPC)
#   4. Scripts/inventory.sh in every Region (exit status 1 if anything is left)
#
# The ECR repositories of terraform/persistent and their images are kept.
#
# Usage: Scripts/teardown.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="cloud-design"
NAMESPACE="cloud-design"
# Tag the EBS CSI driver puts on the volumes it creates for a claim.
PVC_VOLUMES=(--filters "Name=tag:kubernetes.io/created-for/pvc/namespace,Values=$NAMESPACE")

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  sed -n '2,/^set -euo/p' "$0" | sed '$d' | cut -c3-
  exit 0
fi

region="${AWS_REGION:-$(aws configure get region || true)}"
region="${region:-eu-west-3}"

pvc_volume_count() {
  aws ec2 describe-volumes --region "$region" "${PVC_VOLUMES[@]}" --query 'length(Volumes)' --output text
}

echo "== 1. application and volume claims"
if aws eks describe-cluster --region "$region" --name "$PROJECT" --query 'cluster.status' --output text >/dev/null 2>&1; then
  aws eks update-kubeconfig --region "$region" --name "$PROJECT" --alias "$PROJECT" >/dev/null
  kubectl --context "$PROJECT" delete namespace "$NAMESPACE" --ignore-not-found --wait=true --timeout=10m
else
  echo "no $PROJECT cluster: nothing to delete inside Kubernetes"
fi

echo "== 2. EBS volumes of the claims"
for _ in $(seq 1 30); do
  # Counted once per round: a second call could already see fewer volumes.
  count="$(pvc_volume_count)"
  [[ "$count" -eq 0 ]] && break
  echo "waiting for $count volume(s) to be deleted by the EBS CSI driver..."
  sleep 10
done

echo "== 3. terraform destroy (platform)"
# No colour codes when the output goes to a file (session logs).
tf_color=()
[[ -t 1 ]] || tf_color=(-no-color)
terraform -chdir="$ROOT_DIR/terraform/platform" destroy -auto-approve -input=false "${tf_color[@]}"

# Last resort: the nodes are gone, so a volume still there is detached and only billed.
leftover="$(aws ec2 describe-volumes --region "$region" "${PVC_VOLUMES[@]}" --query 'Volumes[].VolumeId' --output text)"
for volume in $leftover; do
  echo "deleting leftover volume $volume"
  aws ec2 delete-volume --region "$region" --volume-id "$volume"
done

echo "== 4. inventory"
"$ROOT_DIR/Scripts/inventory.sh"
