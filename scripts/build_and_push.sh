#!/usr/bin/env bash
# Builds the three linux/arm64 images and pushes them to ECR.
#   AWS_REGION / PROJECT must match infra/terraform.tfvars (defaults below).
# Usage: scripts/build_and_push.sh <image-tag>
set -euo pipefail

TAG="${1:?usage: build_and_push.sh <image-tag>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REGION="${AWS_REGION:-eu-west-1}"
PROJECT="${PROJECT:-claims-assist}"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
REGISTRY="$ACCOUNT.dkr.ecr.$REGION.amazonaws.com"

aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$REGISTRY"

build() { # repo, context, dockerfile, extra args...
  local repo="$1" context="$2" dockerfile="$3"; shift 3
  local image="$REGISTRY/$PROJECT/$repo:$TAG"
  # Tags are immutable, so a re-run for the same commit reuses the image already pushed.
  if aws ecr describe-images --region "$REGION" --repository-name "$PROJECT/$repo" \
       --image-ids "imageTag=$TAG" >/dev/null 2>&1; then
    echo "==> $image already exists, skipping build"
    return
  fi
  echo "==> $image"
  # --provenance=false keeps a single-platform manifest, which AgentCore and ECS expect.
  docker buildx build --platform linux/arm64 --provenance=false \
    -f "$dockerfile" "$@" -t "$image" --push "$context"
}

build claims-api "$ROOT" "$ROOT/services/Dockerfile" --build-arg SERVICE=claims_api
build policy-api "$ROOT" "$ROOT/services/Dockerfile" --build-arg SERVICE=policy_api
build agent      "$ROOT"          "$ROOT/agent/Dockerfile"
