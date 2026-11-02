#!/usr/bin/env bash
# App Director protected-space guard · Claude Code PreToolUse hook on Edit and Write.
# Blocks any write to director/ (the human's personal workspace), whether Claude Code sends a
# relative path or an absolute one. Relative paths resolve against the project root
# ($CLAUDE_PROJECT_DIR, else the current directory); paths outside the root pass.
# In a prototype (PROTOTYPE.md at the root) it also blocks the gates, which are main's: .githooks/, .claude/,
# tools/prototype.sh, tools/setup-clone.sh, .gitleaksignore and .gitleaks.toml.
# It starts no other processes.
# framework-owned: replaced on upgrade.

set -f   # no globbing of the path

IFS= read -r -d '' input || true

re='"file_path"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)"'
[[ $input =~ $re ]] || exit 0
path="${BASH_REMATCH[1]}"

# to_posix <path>: backslashes (JSON-escaped or not) become /, and a drive form C:/x becomes /c/x,
# the Git Bash form. Sets $posix.
to_posix() {
  local l abc=abcdefghijklmnopqrstuvwxyz ABC=ABCDEFGHIJKLMNOPQRSTUVWXYZ rest
  posix="${1//\\//}"
  if [[ $posix =~ ^([A-Za-z]):/(.*)$ ]]; then
    l="${BASH_REMATCH[1]}"
    if [[ $ABC == *"$l"* ]]; then rest="${ABC%%"$l"*}"; l="${abc:${#rest}:1}"; fi
    posix="/$l/${BASH_REMATCH[2]}"
  fi
}

# resolve <posix path>: drops . and empty segments and applies .. to the segment before it.
# Sets $resolved ("/" for the root).
resolve() {
  local IFS=/ seg out=""
  for seg in $1; do
    case "$seg" in
      ""|.) ;;
      ..) out="${out%/*}" ;;
      *) out="$out/$seg" ;;
    esac
  done
  resolved="${out:-/}"
}

to_posix "${CLAUDE_PROJECT_DIR:-$PWD}"
resolve "$posix"
root="${resolved%/}"   # "" for the file system root

to_posix "$path"
case "$posix" in
  /*) ;;
  *) posix="$root/$posix" ;;   # relative to the project root
esac
resolve "$posix"

# Git Bash on Windows and MSYS: the file system is case-insensitive, so match case-insensitively.
case "${OSTYPE:-}" in msys*|cygwin*) shopt -s nocasematch ;; esac

case "$resolved" in
  "$root/director"|"$root/director/"*)
    echo "App Director: blocked: director/ is the human's personal workspace. Read files there for context; never write to them." >&2
    exit 2
    ;;
esac

# In a prototype the gates are main's, so a prototype's session can't change them. PROTOTYPE.md at the root is tested
# with the shell's own test, not tools/prototype.sh, so no process starts here.
if [ -f "$root/PROTOTYPE.md" ]; then
  case "$resolved" in
    "$root/.githooks"|"$root/.githooks/"*|"$root/.claude"|"$root/.claude/"*|"$root/tools/prototype.sh"|"$root/tools/setup-clone.sh"|"$root/.gitleaksignore"|"$root/.gitleaks.toml")
      echo "App Director: blocked: in a prototype, the hooks, the guard, tools/prototype.sh, tools/setup-clone.sh and the gitleaks files are main's. Change them in the main session." >&2
      exit 2
      ;;
  esac
fi
exit 0
