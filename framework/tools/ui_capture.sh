#!/usr/bin/env bash
# App Director screen capture · framework-owned: replaced on upgrade.
#
#   bash tools/ui_capture.sh [<screen>|--all] [--state <name>] [--size <W>x<H>]   capture (default --all)
#   bash tools/ui_capture.sh --list             the screens in the catalog
#   bash tools/ui_capture.sh --missing          the UI files that look like screens and have no catalog entry (never fails)
#   bash tools/ui_capture.sh <screen> --verify  capture the screen, then check it against its spec
#                                               (product/ui/<screen>.md) and write the compare images
# Exit codes: 0 = done (lint findings don't count) · 1 = a screen failed, or --verify found
# deviations · 3 = couldn't run (no Node, no web app to open, a host that isn't this machine, no
# Playwright or Chromium, the app didn't start), or --verify had no spec or capture to check
#
# For every screen in tools/ui/screens.mjs, state and size in tools/ui_capture.cfg, it writes
# <id>[.<state>]@<W>x<H> .png, .elements.json, .map.png and .lint.txt to product/ui/captures/
# (.app-director/procedures/ui-design.md). It opens the app on this machine in headless Chromium
# (Playwright, installed once in tools/ui), so it needs no display. It needs Node 20 or newer; the
# project's own check (bash tools/check.sh) never does.
# Without a web app to capture (native Flutter, mobile or desktop), --verify still checks that the
# spec's names are in the source, and exits 3: the screen's position and focus stay unverified.

set -u
cd "$(dirname "$0")/.." || exit 3

verify=0; screen_arg=""; list=0
count=$#
while [ "$count" -gt 0 ]; do   # --verify is ours; everything else goes to tools/ui/capture.mjs
  arg="$1"; shift; count=$((count - 1))
  case "$arg" in
    --verify) verify=1; continue ;;
    --list|--missing) list=1 ;;
    --state|--size)
      if [ "$count" -gt 0 ]; then set -- "$@" "$arg" "$1"; shift; count=$((count - 1)); continue; fi ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    -*) ;;
    *) screen_arg="$arg" ;;
  esac
  set -- "$@" "$arg"
done
if [ "$verify" -eq 1 ] && { [ -z "$screen_arg" ] || [ "$screen_arg" = "all" ] || [ "$list" -eq 1 ]; }; then
  echo "ui_capture: --verify takes one screen: bash tools/ui_capture.sh <screen> --verify" >&2
  exit 1
fi

# --- Node 20 or newer ---------------------------------------------------------------------------
if ! command -v node >/dev/null 2>&1; then
  echo "ui_capture: needs Node 20 or newer (https://nodejs.org), then once: cd tools/ui && npm install && npx playwright install chromium" >&2
  exit 3
fi
major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null | tr -d '\r')"
case "$major" in ''|*[!0-9]*) major=0 ;; esac
if [ "$major" -lt 20 ]; then
  echo "ui_capture: needs Node 20 or newer; this is $(node --version 2>/dev/null | tr -d '\r')." >&2
  exit 3
fi
if [ ! -f tools/ui/capture.mjs ]; then
  echo "ui_capture: tools/ui/capture.mjs is missing; rerun the App Director installer." >&2
  exit 3
fi

node tools/ui/capture.mjs "$@"
status=$?
[ "$verify" -eq 1 ] || exit "$status"

if [ "$status" -eq 3 ]; then
  # No capture: the spec's names in the source are all that can be checked.
  node tools/ui/verify.mjs "$screen_arg" --static
  exit 3
fi
[ "$status" -eq 0 ] || exit 1
node tools/ui/verify.mjs "$@"
exit $?
