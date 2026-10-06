#!/usr/bin/env bash
# Fetch or update App Director to a temporary location outside the current project.
# Prints the absolute path to the App Director folder on stdout.
set -euo pipefail
ADIR="${TMPDIR:-/tmp}/app-director"
if [ -d "$ADIR/.git" ]; then
  git -C "$ADIR" pull --ff-only
else
  git clone --depth 1 https://github.com/Freakling/App-Director.git "$ADIR"
fi
printf '%s\n' "$ADIR"
