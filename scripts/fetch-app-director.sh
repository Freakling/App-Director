#!/usr/bin/env bash
# Fetch App Director's release to a temporary location outside the current project.
# Prints the absolute path to the App Director folder on stdout.
# It fetches the release tagged v<version>, the one this script belongs to. A folder left by an
# earlier run moves to that release.
set -euo pipefail
tag=v1.5.0
ADIR="${TMPDIR:-/tmp}/app-director"
if [ -d "$ADIR/.git" ]; then
  git -C "$ADIR" fetch -q --depth 1 origin "+refs/tags/$tag:refs/tags/$tag"
  git -C "$ADIR" -c advice.detachedHead=false checkout -q "$tag"
else
  git -c advice.detachedHead=false clone -q --depth 1 --branch "$tag" https://github.com/Freakling/App-Director.git "$ADIR"
fi
printf '%s\n' "$ADIR"
