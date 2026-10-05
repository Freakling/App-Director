#!/usr/bin/env bash
# App Director TypeScript stack check · framework-owned: replaced on upgrade.
# Expects: node, npm (or pnpm or yarn), tsc, eslint, vitest or jest.
set -e
STACK_ROOT="${STACK_ROOT:-.}"
cd "$STACK_ROOT"

# Install dependencies if needed.
if [ ! -d node_modules ]; then
  if [ -f pnpm-lock.yaml ]; then pnpm install --frozen-lockfile --silent
  elif [ -f yarn.lock ]; then yarn install --frozen-lockfile --silent
  else npm install --silent
  fi
fi

# Type check.
npx tsc --noEmit

# Lint (fail on any warning).
if [ -f .eslintrc.json ] || [ -f .eslintrc.js ] || [ -f .eslintrc.cjs ] || [ -f eslint.config.js ] || [ -f eslint.config.mjs ]; then
  npx eslint . --max-warnings 0
fi

# Tests.
if [ -f vitest.config.ts ] || [ -f vitest.config.js ] || [ -f vitest.config.mjs ]; then
  npx vitest run
elif [ -f jest.config.ts ] || [ -f jest.config.js ] || grep -q '"jest"' package.json 2>/dev/null; then
  npx jest --passWithNoTests
fi
