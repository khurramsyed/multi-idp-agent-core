#!/usr/bin/env bash
# End-to-end deploy: build Lambdas, create ECR repos, push images, apply everything.
# Extra arguments are passed to the final `terraform apply` (for example -auto-approve).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF="terraform -chdir=$ROOT/infra"
TAG="${IMAGE_TAG:-$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || date +%Y%m%d%H%M%S)}"
# ECR tags are immutable: add a timestamp when the working tree has uncommitted changes.
if [[ -z "${IMAGE_TAG:-}" ]] && ! git -C "$ROOT" diff --quiet 2>/dev/null; then
  TAG="$TAG-$(date +%Y%m%d%H%M%S)"
fi
export TF_VAR_image_tag="$TAG"

echo "Image tag: $TAG"
"$ROOT/scripts/build_lambdas.sh"

$TF init -upgrade
echo "==> Creating ECR repositories"
$TF apply -target='aws_ecr_repository.this' -auto-approve

echo "==> Building and pushing images"
"$ROOT/scripts/build_and_push.sh" "$TAG"

echo "==> Applying the full stack"
$TF apply "$@"

echo
$TF output
