#!/usr/bin/env bash
# Build the six images from Dockerfiles/ and push them to Docker Hub, where
# the manifests pull them from (docker.io/<user>/<image>:<tag>).
#
# Run `docker login` once beforehand.
#
# Usage: Scripts/push-images.sh [--no-push] [image...]   (or ./orchestrator.sh push)
#   --no-push   build and tag only
#   image...    subset of: api-gateway inventory-app inventory-database
#               billing-app billing-database rabbitmq-server (default: all)
#
# Environment:
#   DOCKERHUB_USER  Docker Hub account (default clecart)
#   IMAGE_TAG       tag referenced by the manifests (default 1.0.0)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCKERHUB_USER="${DOCKERHUB_USER:-clecart}"
IMAGE_TAG="${IMAGE_TAG:-1.0.0}"
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

for image in "${images[@]}"; do
  ref="docker.io/$DOCKERHUB_USER/$image:$IMAGE_TAG"
  echo "== $ref"
  # --pull: always start from the latest alpine:3.23 patch release.
  docker build --pull --tag "$ref" "$ROOT_DIR/Dockerfiles/$image"
  if [[ "$push" == true ]]; then
    docker push "$ref"
  fi
done

if [[ "$push" == true ]]; then
  echo "pushed ${#images[@]} image(s) to https://hub.docker.com/u/$DOCKERHUB_USER"
fi
