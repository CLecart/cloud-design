#!/usr/bin/env bash
# Create the secret manifests of Manifests/secrets/ from their *.yaml.example
# templates, replacing every CHANGE_ME_* placeholder with a random secret.
#
# The generated files are ignored by Git: credentials never reach the repository.
# An existing manifest is kept as is (unless --force), because the databases
# are initialised with the password they found at their first start.
#
# Usage: Scripts/generate-secrets.sh [--force]
#   --force   overwrite the existing secret manifests
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECRETS_DIR="$ROOT_DIR/Manifests/secrets"
force=false

for arg in "$@"; do
  case "$arg" in
    --force) force=true ;;
    -h | --help)
      echo "Usage: $0 [--force]"
      exit 0
      ;;
    *)
      echo "error: unknown option '$arg' (usage: $0 [--force])" >&2
      exit 2
      ;;
  esac
done

# 32 hexadecimal characters (128 bits of entropy) per secret.
random_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 16
  else
    od -An -N16 -tx1 /dev/urandom | tr -d ' \n'
  fi
}

# umask keeps the manifests private from the first write.
umask 077
shopt -s nullglob
templates=("$SECRETS_DIR"/*.yaml.example)
if [[ ${#templates[@]} -eq 0 ]]; then
  echo "error: no *.yaml.example template in $SECRETS_DIR" >&2
  exit 1
fi

for template in "${templates[@]}"; do
  target="${template%.example}"
  name="$(basename "$target")"
  if [[ -f "$target" && "$force" != true ]]; then
    echo "kept      Manifests/secrets/$name (already exists)"
    continue
  fi

  # Written to a temporary file first so an interrupted run never leaves a
  # half-generated manifest behind.
  tmp_file="$(mktemp "$SECRETS_DIR/.$name.XXXXXX")"
  trap 'rm -f "$tmp_file"' EXIT
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^([[:space:]]*[A-Za-z_][A-Za-z0-9_-]*:[[:space:]]*)CHANGE_ME_[A-Za-z0-9_]*$ ]]; then
      line="${BASH_REMATCH[1]}$(random_secret)"
    fi
    printf '%s\n' "$line"
  done <"$template" >"$tmp_file"
  chmod 600 "$tmp_file"
  mv -f "$tmp_file" "$target"
  trap - EXIT
  echo "generated Manifests/secrets/$name (mode 600)"
done
