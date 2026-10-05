#!/usr/bin/env bash
# App Director Python stack check · framework-owned: replaced on upgrade.
# Expects: python (3.x), pyright or mypy, pytest.
set -e
STACK_ROOT="${STACK_ROOT:-.}"
cd "$STACK_ROOT"

# Type check: prefer pyright, fall back to mypy.
if command -v pyright >/dev/null 2>&1; then
  pyright .
elif python -m pyright --version >/dev/null 2>&1; then
  python -m pyright .
elif python -m mypy --version >/dev/null 2>&1; then
  python -m mypy .
else
  echo "check: note: no type checker found (pyright or mypy). Install one and rerun."
fi

# Tests.
python -m pytest --tb=short
