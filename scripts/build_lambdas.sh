#!/usr/bin/env bash
# Builds Lambda source folders into build/lambdas/<name>. Terraform zips them.
# Dependencies are fetched as manylinux arm64 wheels to match the Lambda runtime.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/lambdas"

rm -rf "$OUT"
mkdir -p "$OUT"

for fn in pre_token interceptor tools; do
  src="$ROOT/lambdas/$fn"
  dst="$OUT/$fn"
  mkdir -p "$dst"
  cp "$src"/*.py "$dst"/

  # Lambdas with third-party dependencies have a dependency group named after them.
  if grep -q "^$fn = \[" "$ROOT/pyproject.toml"; then
    uv export --quiet --frozen --only-group "$fn" --no-hashes | uv pip install --quiet \
      --requirement - \
      --target "$dst" \
      --python-platform aarch64-manylinux2014 \
      --python-version 3.12 \
      --only-binary=:all:
  fi
  echo "built $fn"
done
