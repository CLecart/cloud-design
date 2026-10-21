#!/usr/bin/env bash
# Read-only inventory of the billable resources in every enabled AWS Region:
# EC2 instances, EBS volumes, NAT gateways, Elastic IPs, load balancers, EKS
# clusters, RDS instances/clusters/manual snapshots and Lambda functions.
# The ECR repositories of terraform/persistent are listed apart: they are kept
# on purpose between sessions.
#
# Exit status: 0 when nothing billable remains, 1 otherwise (2 on an AWS error),
# so Scripts/teardown.sh can tell whether the session really ended.
#
# Usage: Scripts/inventory.sh
set -euo pipefail

COLUMNS_HEADER="REGION EC2 EBS NAT EIP ELB EKS RDS RDS-CLUSTER RDS-SNAPSHOT LAMBDA"

# Counts are computed by AWS itself (JMESPath length), never by counting lines.
count_region() {
  local r="$1"
  local q=(--region "$r" --output text)
  printf '%s %s %s %s %s %s %s %s %s %s %s\n' "$r" \
    "$(aws ec2 describe-instances "${q[@]}" --filters Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down --query 'length(Reservations[].Instances[])')" \
    "$(aws ec2 describe-volumes "${q[@]}" --query 'length(Volumes)')" \
    "$(aws ec2 describe-nat-gateways "${q[@]}" --filter Name=state,Values=pending,available,deleting --query 'length(NatGateways)')" \
    "$(aws ec2 describe-addresses "${q[@]}" --query 'length(Addresses)')" \
    "$(aws elbv2 describe-load-balancers "${q[@]}" --query 'length(LoadBalancers)')" \
    "$(aws eks list-clusters "${q[@]}" --query 'length(clusters)')" \
    "$(aws rds describe-db-instances "${q[@]}" --query 'length(DBInstances)')" \
    "$(aws rds describe-db-clusters "${q[@]}" --query 'length(DBClusters)')" \
    "$(aws rds describe-db-cluster-snapshots "${q[@]}" --snapshot-type manual --query 'length(DBClusterSnapshots)')" \
    "$(aws lambda list-functions "${q[@]}" --query 'length(Functions)')"
}
export -f count_region

regions="$(aws ec2 describe-regions --query 'Regions[].RegionName' --output text)"
echo "# Inventory of account $(aws sts get-caller-identity --query Account --output text), $(date '+%F %H:%M:%S')"

# Each line must hold the Region and ten numbers, otherwise an AWS call failed.
if ! rows="$(printf '%s\n' $regions | xargs -P 8 -I{} bash -c 'count_region "$1"' _ {} | sort)"; then
  echo "error: an AWS call failed during the inventory" >&2
  exit 2
fi
if grep -q -v -E '^[a-z0-9-]+( [0-9]+){10}$' <<<"$rows"; then
  echo "error: unexpected AWS answer:" >&2
  grep -v -E '^[a-z0-9-]+( [0-9]+){10}$' <<<"$rows" >&2
  exit 2
fi

{ echo "$COLUMNS_HEADER"; echo "$rows"; } | column -t
billable="$(awk '{ for (i = 2; i <= NF; i++) s += $i } END { print s + 0 }' <<<"$rows")"

echo
echo "# Kept on purpose (terraform/persistent):"
aws ecr describe-repositories --region "${AWS_REGION:-eu-west-3}" \
  --query 'repositories[].[repositoryName]' --output text | sed 's/^/  ECR /'

echo
if [[ "$billable" -eq 0 ]]; then
  echo "OK: nothing billable is running in the $(wc -w <<<"$regions") Regions."
else
  echo "WARNING: $billable billable resource(s) still exist, see the table above." >&2
  exit 1
fi
