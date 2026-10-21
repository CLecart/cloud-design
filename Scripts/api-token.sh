#!/usr/bin/env bash
# Print a Cognito access token for the public API (valid one hour), creating the
# test user on the first run.
#
# The user (default "auditor") is created in the user pool of terraform/persistent
# with a random password, saved in .cognito-test-user (mode 600, ignored by Git).
# The password is handed to the AWS CLI in a private temporary file, never on the
# command line, so it does not show in the process list.
#
# Usage: Scripts/api-token.sh
#   e.g. API_TOKEN="$(Scripts/api-token.sh)" \
#        GATEWAY_URL="$(terraform -chdir=terraform/platform output -raw api_url)" \
#        Scripts/test-api.sh
#
# Environment:
#   COGNITO_USERNAME  user to sign in as (default auditor)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CRED_FILE="$ROOT_DIR/.cognito-test-user"
USERNAME="${COGNITO_USERNAME:-auditor}"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  sed -n '2,/^set -euo/p' "$0" | sed '$d' | cut -c3-
  exit 0
fi

tf_out() { terraform -chdir="$ROOT_DIR/terraform/persistent" output -raw "$1"; }
pool="$(tf_out cognito_user_pool_id)"
client="$(tf_out cognito_client_id)"
region="${pool%%_*}"

saved() { sed -n "s/^$1=//p" "$CRED_FILE" 2>/dev/null; }

# The AWS CLI cannot read --cli-input-json from a pipe: use a file in a private
# directory (mktemp -d creates it with mode 700), removed on exit.
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir:?}"' EXIT
aws_json() {
  local json=$1
  shift
  (umask 077 && printf '%s' "$json" >"$tmp_dir/input.json")
  aws "$@" --cli-input-json "file://$tmp_dir/input.json"
}

# A new user (or a recreated user pool) gets a new random password.
if [[ "$(saved pool)" != "$pool" || "$(saved username)" != "$USERNAME" ]]; then
  # 24 random letters and digits, plus one character of each required class.
  # (Not `tr </dev/urandom | head`: tr would die of SIGPIPE and pipefail stop the script.)
  password="$(head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-24)Aa1!"
  if ! aws cognito-idp admin-get-user --region "$region" --user-pool-id "$pool" --username "$USERNAME" >/dev/null 2>&1; then
    aws cognito-idp admin-create-user --region "$region" --user-pool-id "$pool" \
      --username "$USERNAME" --message-action SUPPRESS >/dev/null
  fi
  aws_json "$(printf '{"UserPoolId":"%s","Username":"%s","Password":"%s","Permanent":true}' "$pool" "$USERNAME" "$password")" \
    cognito-idp admin-set-user-password --region "$region"
  (umask 077 && printf 'pool=%s\nusername=%s\npassword=%s\n' "$pool" "$USERNAME" "$password" >"$CRED_FILE")
  echo "created the Cognito user $USERNAME (credentials in .cognito-test-user)" >&2
fi

aws_json "$(printf '{"ClientId":"%s","AuthFlow":"USER_PASSWORD_AUTH","AuthParameters":{"USERNAME":"%s","PASSWORD":"%s"}}' \
  "$client" "$USERNAME" "$(saved password)")" \
  cognito-idp initiate-auth --region "$region" --query 'AuthenticationResult.AccessToken' --output text
