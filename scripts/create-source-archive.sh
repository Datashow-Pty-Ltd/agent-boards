#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
VERSION=$(node -p "require('$ROOT_DIR/package.json').version")
OUTPUT=${1:-"$ROOT_DIR/release/agent-boards-$VERSION-source.tgz"}

mkdir -p "$(dirname -- "$OUTPUT")"
cd "$ROOT_DIR"

# This is an allowlist, not a repository dump. Curated README media lives under
# docs; transient captures, prior build output, caches, obsolete vendored
# packages, and editor state never enter the source distribution.
tar -czf "$OUTPUT" \
  --exclude='**/node_modules' \
  --exclude='**/dist' \
  --exclude='**/*.tsbuildinfo' \
  --exclude='apps/web/vendor' \
  --exclude='apps/web/vite.config.js' \
  --exclude='apps/web/vite.config.d.ts' \
  --exclude='.env' \
  --exclude='*.log' \
  LICENSE NOTICE README.md CHANGELOG.md CONTRIBUTING.md SECURITY.md SUPPORT.md CODE_OF_CONDUCT.md AGENTS.md CLAUDE.md \
  .dockerignore .env.example .gitignore .hadolint.yaml .trivyignore.yaml .github \
  package.json pnpm-lock.yaml pnpm-workspace.yaml aqua.yaml eslint.config.mjs playwright.config.ts compose.yaml \
  apps database docker docs scripts skills tests

echo "$OUTPUT"
