#!/usr/bin/env bash
# App Director session record · Claude Code hook · framework-owned: replaced on upgrade.
#
# The Stop hook (stop-check.sh) runs the project check at the end of a turn only for a session that wrote or
# edited a source file itself since its last passing check. Two sessions can share one working folder, and one
# session's uncommitted code must not make the other, which edited only documentation, wait for the check. This
# hook keeps the record: .app-director/state/sessions/<session_id>.touched, one path from the project root per line.
# A file is source when it isn't Markdown and isn't under .app-director/state/ (the Stop hook's own rule). The
# hook runs in three places (settings.json), told apart by its argument:
#   after   PostToolUse on Edit, Write, MultiEdit and NotebookEdit: records the file the tool wrote, when it is
#           source and inside the project.
#   before  PreToolUse on Bash and PowerShell: saves what `git status` lists as changed in
#           .app-director/state/sessions/<session_id>.before; the file's own modification time is the moment.
#   after   PostToolUse and PostToolUseFailure on Bash and PowerShell: records the source files that are new in
#           git's list, or that changed since the moment (one find -newer for all of them, not a process per file).
# No session_id in the input (an older Claude Code) records nothing, and the Stop hook then behaves as it did.
# Subagents report their parent's session_id, so a builder's edits count for the session that started it.
# APP_DIRECTOR_STOP_CHECK=0 turns it off with the Stop hook. It never blocks: every path ends in exit 0. Bash 3.2 and
# BSD tools run it, and it starts as few processes as it can (git and find, once each, for a command).

mode="${1:-}"
IFS= read -r -d '' input || true
[ "${APP_DIRECTOR_STOP_CHECK:-1}" = "0" ] && exit 0
sid_re='"session_id"[[:space:]]*:[[:space:]]*"([A-Za-z0-9_-]{1,100})"'
[[ $input =~ $sid_re ]] || exit 0
sid="${BASH_REMATCH[1]}"
cd "${CLAUDE_PROJECT_DIR:-.}" 2>/dev/null || exit 0
[ -f tools/check.sh ] || exit 0
dir=".app-director/state/sessions"
nl=$'\n'
dq='"'
find_cmd=find; [ -x /usr/bin/find ] && find_cmd=/usr/bin/find

is_source() { # is_source <path from the project root>: not Markdown (as stop-check.sh reads git status)
  case "$1" in
    .app-director/state/*) return 1 ;;   # these records and the builder's marker; git ignores them
    *.md) return 1 ;;
  esac
  return 0
}
same_form() { # same_form <path>: / separators, a drive as c:/, no ./ or trailing /
  local p="${1//\\//}"
  case "$p" in /[A-Za-z]/*|/[A-Za-z]) p="${p:1:1}:${p:2}" ;; esac
  p="${p#./}"; p="${p%/}"
  REPLY="$p"
}
dirty() { GIT_OPTIONAL_LOCKS=0 git -c core.quotePath=false status --porcelain --untracked-files=all 2>/dev/null; }
porcelain_path() { # porcelain_path <line of git status --porcelain>: its path (a rename's new name, no quotes) in REPLY
  REPLY="${1:3}"; REPLY="${REPLY##* -> }"; REPLY="${REPLY//$dq/}"
}
record() { # record <path>…: add them to this session's record. A path already there is added again, so the record's age is its last use
  [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null || return 0
  printf '%s\n' "$@" >> "$dir/$sid.touched"
}

edited_file() { # the file an Edit, Write, MultiEdit or NotebookEdit wrote
  local re='"(file_path|notebook_path)"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)"' p r
  [[ $input =~ $re ]] || return 0
  p="${BASH_REMATCH[2]}"
  p="${p//\\\\//}"   # JSON-escaped Windows separators (\\) to /
  same_form "$p"; p="$REPLY"
  # The path from the project root: C:/x, C:\x and /c/x spell one Windows folder, in any case.
  shopt -s nocasematch
  for r in "${CLAUDE_PROJECT_DIR:-}" "$PWD"; do
    [ -n "$r" ] || continue
    same_form "$r"; r="$REPLY"
    if [[ $p == "$r"/* ]]; then p="${p:${#r}+1}"; break; fi
  done
  shopt -u nocasematch
  case "$p" in /*|[A-Za-z]:/*|../*) return 0 ;; esac   # outside the project
  is_source "$p" && record "$p"
  return 0
}

changed_by_command() { # the source files a Bash or PowerShell command created, deleted or modified
  local marker="$dir/$sid.before" was="" now line p known="$nl" found="" newer i n
  local -a cands
  [ -f "$marker" ] || return 0
  now="$(dirty)" || return 0
  IFS= read -r -d '' was < "$marker" || true
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    porcelain_path "$line"; known="$known$REPLY$nl"
  done <<< "$was"
  cands=()
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    porcelain_path "$line"; p="$REPLY"
    case "$p" in */) continue ;; esac   # a nested repository
    is_source "$p" || continue
    case "$known" in
      *"$nl$p$nl"*) [ -f "$p" ] && cands[${#cands[@]}]="./$p" ;;   # dirty before: only if it was modified since
      *) found="$found$p$nl" ;;                                      # new in the list
    esac
  done <<< "$now"
  n=${#cands[@]}; i=0
  while [ "$i" -lt "$n" ]; do
    newer="$("$find_cmd" "${cands[@]:$i:100}" -type f -newer "$marker" 2>/dev/null)"
    [ -n "$newer" ] && found="$found$newer$nl"
    i=$((i + 100))
  done
  set --
  while IFS= read -r line; do
    [ -n "$line" ] && set -- "$@" "${line#./}"   # find prints the ./ it was given
  done <<< "$found"
  [ "$#" -gt 0 ] && record "$@"
  return 0
}

case "$mode" in
  before)
    [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null || exit 0
    # Written once git has answered, so every change the command makes is newer than the file.
    if snapshot="$(dirty)"; then printf '%s\n' "$snapshot" > "$dir/$sid.before"; else rm -f "$dir/$sid.before"; fi ;;
  after)
    tool_re='"tool_name"[[:space:]]*:[[:space:]]*"([A-Za-z_]+)"'
    [[ $input =~ $tool_re ]] || exit 0
    case "${BASH_REMATCH[1]}" in
      Edit|Write|MultiEdit|NotebookEdit) edited_file ;;
      Bash|PowerShell) changed_by_command ;;
    esac ;;
esac
exit 0
