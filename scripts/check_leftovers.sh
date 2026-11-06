#!/usr/bin/env bash
# Lists anything from this stack that still exists after a destroy.
# Prints "Nothing left" when the account is clean for this project and Region.
#   AWS_REGION / PROJECT must match infra/terraform.tfvars (defaults below).
set -uo pipefail

REGION="${AWS_REGION:-eu-west-1}"
PROJECT="${PROJECT:-claims-assist}"
RUNTIME_NAME="${PROJECT//-/_}_agent"
FOUND=0

check() { # label, command...
  local label="$1"; shift
  local out
  if ! out="$("$@" 2>/dev/null)"; then
    echo "?  $label: could not check (CLI too old or no permission)"
    return
  fi
  out="$(echo "$out" | tr -s '[:space:]' ' ' | sed 's/^ *//;s/ *$//')"
  if [[ -n "$out" && "$out" != "None" ]]; then
    echo "!! $label: $out"
    FOUND=1
  fi
}

aws() { command aws --region "$REGION" --output text "$@"; }

echo "Checking for leftovers of '$PROJECT' in $REGION ..."

# The billable-by-the-hour resources first.
check "NAT gateways" aws ec2 describe-nat-gateways \
  --filter "Name=tag:Project,Values=$PROJECT" "Name=state,Values=pending,available" \
  --query 'NatGateways[].NatGatewayId'
check "Elastic IPs" aws ec2 describe-addresses \
  --filters "Name=tag:Project,Values=$PROJECT" --query 'Addresses[].PublicIp'
check "Load balancers" aws elbv2 describe-load-balancers \
  --query "LoadBalancers[?LoadBalancerName=='$PROJECT-api'].LoadBalancerName"
check "ECS clusters" aws ecs describe-clusters --clusters "$PROJECT-apis" \
  --query "clusters[?status=='ACTIVE'].clusterName"
check "AgentCore runtimes" aws bedrock-agentcore-control list-agent-runtimes \
  --query "agentRuntimes[?agentRuntimeName=='$RUNTIME_NAME'].agentRuntimeId"
check "AgentCore gateways" aws bedrock-agentcore-control list-gateways \
  --query "items[?name=='$PROJECT-gateway'].gatewayId"

# Everything else.
check "VPCs" aws ec2 describe-vpcs \
  --filters "Name=tag:Project,Values=$PROJECT" --query 'Vpcs[].VpcId'
check "Lambda functions" aws lambda list-functions \
  --query "Functions[?starts_with(FunctionName, '$PROJECT-')].FunctionName"
check "Cognito user pools" aws cognito-idp list-user-pools --max-results 60 \
  --query "UserPools[?Name=='$PROJECT-users'].Id"
check "ECR repositories" aws ecr describe-repositories \
  --query "repositories[?starts_with(repositoryName, '$PROJECT/')].repositoryName"
for prefix in "/aws/lambda/$PROJECT-" "/ecs/$PROJECT/" "/aws/bedrock-agentcore/runtimes/$RUNTIME_NAME"; do
  check "Log groups ($prefix)" aws logs describe-log-groups \
    --log-group-name-prefix "$prefix" --query 'logGroups[].logGroupName'
done
# Catch-all for anything tagged with this project (Verified Permissions, IAM, alarms ...).
check "Other tagged resources" aws resourcegroupstaggingapi get-resources \
  --tag-filters "Key=Project,Values=$PROJECT" --query 'ResourceTagMappingList[].ResourceARN'

if [[ "$FOUND" == 0 ]]; then
  echo "Nothing left. No resources from this stack remain in $REGION."
else
  echo
  echo "Some resources remain. Re-run scripts/destroy.sh, or delete the items above."
  echo "Note: the tagging API can list a just-deleted resource for a short while; re-check in an hour."
  exit 1
fi
