#!/usr/bin/env bash
# GitHub Actions only. Points Terraform at the S3 state bucket created by bootstrap/
# and passes optional repository settings through as Terraform variables.
# Local runs never call this, so local deploys keep their local state.
set -euo pipefail

: "${GITHUB_ENV:?Run this inside GitHub Actions}"
: "${TF_STATE_BUCKET:?Set TF_STATE_BUCKET on the GitHub environment (bootstrap output)}"
: "${AWS_REGION:?}"
: "${PROJECT:?}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# An override file swaps the backend without touching versions.tf.
cat > "$ROOT/infra/backend_override.tf" <<'EOF'
terraform {
  backend "s3" {}
}
EOF

{
  echo "TF_CLI_ARGS_init=-backend-config=bucket=$TF_STATE_BUCKET -backend-config=key=$PROJECT/terraform.tfstate -backend-config=region=$AWS_REGION -backend-config=use_lockfile=true"
  # Only override Terraform defaults when the repository sets a value.
  if [[ -n "${MODEL_ID:-}" ]]; then echo "TF_VAR_model_id=$MODEL_ID"; fi
  if [[ -n "${ENABLE_TEST_USERS:-}" ]]; then echo "TF_VAR_enable_test_users=$ENABLE_TEST_USERS"; fi
} >> "$GITHUB_ENV"

echo "Terraform state: s3://$TF_STATE_BUCKET/$PROJECT/terraform.tfstate"
