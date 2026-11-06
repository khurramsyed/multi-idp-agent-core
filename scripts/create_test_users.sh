#!/usr/bin/env bash
# Creates five admin-managed test users that exercise every Cedar rule.
#   TEST_USER_PASSWORD must meet the pool policy (12+ chars, upper, lower, digit, symbol).
set -euo pipefail

: "${TEST_USER_PASSWORD:?export TEST_USER_PASSWORD first}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
POOL_ID="$(terraform -chdir="$ROOT/infra" output -raw user_pool_id)"
REGION="$(terraform -chdir="$ROOT/infra" output -raw region)"

create() { # username population role region agency ("-" means not set)
  local user="$1" attrs=()
  [[ "$2" != "-" ]] && attrs+=("Name=custom:t_population,Value=$2")
  [[ "$3" != "-" ]] && attrs+=("Name=custom:t_role,Value=$3")
  [[ "$4" != "-" ]] && attrs+=("Name=custom:t_region,Value=$4")
  [[ "$5" != "-" ]] && attrs+=("Name=custom:t_agency,Value=$5")

  if ! aws cognito-idp admin-get-user --region "$REGION" --user-pool-id "$POOL_ID" --username "$user" >/dev/null 2>&1; then
    aws cognito-idp admin-create-user --region "$REGION" --user-pool-id "$POOL_ID" \
      --username "$user" --message-action SUPPRESS >/dev/null
  fi
  # Attributes are set by an administrator only; the app client cannot write t_* attributes.
  aws cognito-idp admin-update-user-attributes --region "$REGION" --user-pool-id "$POOL_ID" \
    --username "$user" --user-attributes "${attrs[@]}"
  aws cognito-idp admin-set-user-password --region "$REGION" --user-pool-id "$POOL_ID" \
    --username "$user" --password "$TEST_USER_PASSWORD" --permanent
  echo "ready: $user"
}

#      username        population role                    region agency
create adjuster.north  staff      claims-adjuster         north  -
create senior.north    staff      claims-senior-adjuster  north  -
create senior.south    staff      claims-senior-adjuster  south  -
create broker.ag100    broker     -                       -      AG-100
create broker.ag200    broker     -                       -      AG-200
