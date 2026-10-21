#!/usr/bin/env bash
# Build the six images from Dockerfiles/ and push them to the private Amazon ECR
# repositories created by terraform/persistent (<registry>/cloud-design/<image>:<tag>),
# then print the vulnerability counts of the ECR basic scan run at every push.
#
# Prerequisites: AWS CLI configured (aws sts get-caller-identity works) and
# `terraform -chdir=terraform/persistent apply` done once.
#
# Usage: Scripts/push-images.sh [--no-push] [image...]
#   --no-push   build and tag only
#   image...    subset of: api-gateway inventory-app inventory-database
#               billing-app billing-database rabbitmq-server (default: all)
#
# Environment:
#   AWS_REGION  Region of the repositories (default: aws configure get region, else eu-west-3)
#   IMAGE_TAG   tag pushed and deployed (default: last Git commit that changed
#               Dockerfiles/, suffixed -dirty when Dockerfiles/ has uncommitted changes)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="cloud-design"
ALL_IMAGES=(api-gateway inventory-app inventory-database billing-app billing-database rabbitmq-server)

usage() {
  sed -n '2,/^set -euo/p' "$0" | sed '$d' | cut -c3-
}

push=true
images=()
for arg in "$@"; do
  case "$arg" in
    --no-push) push=false ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      echo "error: unknown option '$arg' (see $0 --help)" >&2
      exit 2
      ;;
    *)
      [[ -d "$ROOT_DIR/Dockerfiles/$arg" ]] || { echo "error: no Dockerfiles/$arg directory" >&2; exit 2; }
      images+=("$arg")
      ;;
  esac
done
[[ ${#images[@]} -gt 0 ]] || images=("${ALL_IMAGES[@]}")

command -v docker >/dev/null 2>&1 || { echo "error: docker is not installed" >&2; exit 1; }
command -v aws >/dev/null 2>&1 || { echo "error: the AWS CLI is not installed" >&2; exit 1; }

region="${AWS_REGION:-$(aws configure get region || true)}"
region="${region:-eu-west-3}"
account="$(aws sts get-caller-identity --query Account --output text)"
registry="$account.dkr.ecr.$region.amazonaws.com"

if [[ -z "${IMAGE_TAG:-}" ]]; then
  # The tag only moves when the images change, not at every commit of the repository.
  IMAGE_TAG="$(git -C "$ROOT_DIR" log -1 --format=%h -- Dockerfiles)"
  [[ -z "$(git -C "$ROOT_DIR" status --porcelain -- Dockerfiles)" ]] || IMAGE_TAG="$IMAGE_TAG-dirty"
fi

if [[ "$push" == true ]]; then
  # The token is valid 12 hours; Docker stores it in ~/.docker/config.json.
  aws ecr get-login-password --region "$region" | docker login --username AWS --password-stdin "$registry"
fi

for image in "${images[@]}"; do
  ref="$registry/$PROJECT/$image:$IMAGE_TAG"
  echo "== $ref"
  # --pull: always start from the latest alpine:3.23 patch release.
  # linux/amd64: the EKS nodes are x86_64 (c7i-flex.large).
  # --provenance/--sbom=false: push a plain image manifest; with attestations the
  # tag points to an OCI index, which the ECR basic scan does not report on.
  docker build --pull --platform linux/amd64 --provenance=false --sbom=false \
    --tag "$ref" "$ROOT_DIR/Dockerfiles/$image"
  if [[ "$push" == true ]]; then
    docker push "$ref"
  fi
done

[[ "$push" == true ]] || exit 0

echo
echo "== ECR basic scan results (tag $IMAGE_TAG)"
for image in "${images[@]}"; do
  repo="$PROJECT/$image"
  # Pushing a manifest ECR already holds (same digest) does not trigger the scan
  # on push: start a manual scan then (allowed once per image every 24 hours).
  if ! aws ecr describe-image-scan-findings --region "$region" --repository-name "$repo" \
    --image-id imageTag="$IMAGE_TAG" --query 'imageScanStatus.status' --output text >/dev/null 2>&1; then
    # Tolerated failure: the scan on push may have started in the meantime.
    aws ecr start-image-scan --region "$region" --repository-name "$repo" \
      --image-id imageTag="$IMAGE_TAG" --query 'imageScanStatus.status' --output text >/dev/null ||
      echo "note: manual scan not started for $image, waiting for the scan on push"
  fi
  aws ecr wait image-scan-complete --region "$region" --repository-name "$repo" --image-id imageTag="$IMAGE_TAG"
  # Without findings ECR returns an empty severity map, so count the findings themselves.
  total="$(aws ecr describe-image-scan-findings --region "$region" --repository-name "$repo" \
    --image-id imageTag="$IMAGE_TAG" --query 'length(imageScanFindings.findings)' --output text)"
  if [[ "$total" == 0 ]]; then
    summary="no vulnerability found"
  else
    summary="$total finding(s) $(aws ecr describe-image-scan-findings --region "$region" --repository-name "$repo" \
      --image-id imageTag="$IMAGE_TAG" --query 'imageScanFindings.findingSeverityCounts' --output json | tr -d '\n ')"
  fi
  printf '%-20s %s\n' "$image" "$summary"
done
echo
echo "pushed ${#images[@]} image(s) with tag $IMAGE_TAG to $registry"
