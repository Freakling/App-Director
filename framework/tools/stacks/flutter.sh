#!/usr/bin/env bash
# App Director Flutter stack check · framework-owned: replaced on upgrade.
# Expects: flutter (Dart SDK included).
set -e
STACK_ROOT="${STACK_ROOT:-.}"
cd "$STACK_ROOT"

flutter analyze --no-fatal-infos
flutter test
