#!/usr/bin/env bash
# Tears down everything scripts/deploy.sh created, deletes the log groups that
# AgentCore Runtime creates outside Terraform, then checks for anything left over.
#   AWS_REGION / PROJECT must match infra/terraform.tfvars (defaults below).
# Extra arguments are passed to `terraform destroy` (for example -auto-approve).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF="terraform -chdir=$ROOT/infra"
PROJECT="${PROJECT:-claims-assist}"
REGION="${AWS_REGION:-$($TF output -raw region 2>/dev/null || echo eu-west-1)}"

# Terraform reads the Lambda build folders (archive_file) even when destroying.
"$ROOT/scripts/build_lambdas.sh"
$TF init -input=false >/dev/null

# image_tag has no default because deploy.sh always sets it; any value works for destroy.
if ! $TF destroy -var "image_tag=destroy" "$@"; then
  echo >&2
  echo "Destroy did not finish. The tools Lambda runs in the VPC, and AWS can take" >&2
  echo "10-40 minutes to release its network interfaces. Wait, then run this script again." >&2
  exit 1
fi

# AgentCore Runtime creates its own log group on first use. Terraform does not
# manage it, and it never expires, so remove it explicitly.
RUNTIME_PREFIX="/aws/bedrock-agentcore/runtimes/${PROJECT//-/_}_agent"
for lg in $(aws logs describe-log-groups --region "$REGION" \
              --log-group-name-prefix "$RUNTIME_PREFIX" \
              --query 'logGroups[].logGroupName' --output text); do
  [[ "$lg" == "None" ]] && continue
  aws logs delete-log-group --region "$REGION" --log-group-name "$lg"
  echo "deleted log group $lg"
done

AWS_REGION="$REGION" PROJECT="$PROJECT" "$ROOT/scripts/check_leftovers.sh"
