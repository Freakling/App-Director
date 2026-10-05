#!/usr/bin/env bash
# App Director protected-space guard · Claude Code PreToolUse hook on Edit and Write.
# Blocks any write to director/ (the human's personal workspace).
# framework-owned: replaced on upgrade.

IFS= read -r -d '' input || true

re='"file_path"[[:space:]]*:[[:space:]]*"([^"]*)"'
[[ $input =~ $re ]] || exit 0
path="${BASH_REMATCH[1]}"
path="${path#./}"   # strip leading ./

case "$path" in
  director|director/*)
    echo "App Director: blocked: director/ is the human's personal workspace. Read files there for context; never write to them." >&2
    exit 2
    ;;
esac
exit 0
