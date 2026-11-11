#!/usr/bin/env bash
# App Director protected-space guard · Claude Code PreToolUse hook on Edit, Write, MultiEdit and NotebookEdit.
# Blocks any write to director/ (the human's personal workspace), whether Claude Code sends a
# relative path or an absolute one. Relative paths resolve against the project root
# ($CLAUDE_PROJECT_DIR, else the current directory); paths outside the root pass. The path is read by record-paths.sh,
# as the record watch reads it: \\?\ prefixes go, and on Windows a segment's trailing dots and spaces go; on Windows and
# macOS (and a Windows drive under WSL) the match ignores case. On Windows a path with a stream (a : after the drive) or
# an 8.3 short name (~1) is refused, whatever it names. The input is read as far as the path (64 KB at first).
# In a prototype (PROTOTYPE.md at the root) it also blocks the gates, which are main's: .githooks/, .claude/,
# tools/prototype.sh, tools/setup-clone.sh, .gitleaksignore and .gitleaks.toml.
# The records (.app-director/rules.md › The human decides): a write under .app-director/state/records/ (the approvals)
# is always blocked, and a write to the brief or the decisions is blocked from a subagent (its input has an agent_id), and
# otherwise unless an approval of the human's no commit has used yet has lines for that file
# (bash tools/records.sh open <path>). The brief and the decisions are the [records] brief and decisions paths of the
# working copy's tools/check.cfg (product/brief.md and product/decisions.md by default), and, while tools/check.cfg
# differs from the last commit, also the last commit's, which the record watch saves
# (.app-director/state/records/claude/head-check.cfg): the commit gate reads the last commit's, so moving a path in an
# uncommitted tools/check.cfg doesn't unguard the file it named. The defaults are guarded always, so a tools/check.cfg
# changed where the watch didn't see it can't unguard a project that uses them.
# It starts no other processes, except one records.sh run for a write to the brief or the decisions, and one cat for an
# input longer than 64 KB (to read on to the path, or drain the rest).
# framework-owned: replaced on upgrade.

set -f   # no globbing of the path

case "${BASH_SOURCE[0]}" in */*) here="${BASH_SOURCE[0]%/*}" ;; *) here=. ;; esac
re='"(file_path|notebook_path)"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)"'
if [ -f "$here/record-paths.sh" ]; then
  . "$here/record-paths.sh"
  rp_need="$re"; rp_read   # the first 64 KB, where the path and agent_id are; on only while the path isn't there
else
  IFS= read -r -d '' input || true
  exit 0
fi

[[ $input =~ $re ]] || exit 0
path="${BASH_REMATCH[2]}"
rp_target "$path"

[ "$rp_nocase" -eq 1 ] && shopt -s nocasematch

# On Windows a stream (decisions.md::$DATA) or an 8.3 short name (DECISI~1.MD) can name a record file the plain path
# doesn't show, so such a path is refused whatever it names.
if ! rp_plain; then
  echo "App Director: blocked: on Windows, write a path in its plain form: one with a stream (a : after the drive) or a short name (~1) can name a file the guard can't see." >&2
  exit 2
fi

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

# The records: the approvals are the human's, so their state is never written by a tool.
case "$resolved" in
  "$root/.app-director/state/records"|"$root/.app-director/state/records/"*)
    echo "App Director: blocked: .app-director/state/records/ holds the human's approvals, and no tool writes there. 'bash tools/records.sh status' says what it holds." >&2
    exit 2
    ;;
esac
# The brief and the decisions: the working copy's paths, and the last commit's while the record watch has saved them.
rp_cfg "$root/tools/check.cfg" w_
h_brief="$w_brief"; h_decisions="$w_decisions"
[ -f "$root/.app-director/state/records/claude/head-check.cfg" ] && rp_cfg "$root/.app-director/state/records/claude/head-check.cfg" h_
case "$resolved" in
  "$root/$h_brief") rec="$h_brief" ;;
  "$root/$h_decisions") rec="$h_decisions" ;;
  "$root/$w_brief") rec="$w_brief" ;;
  "$root/$w_decisions") rec="$w_decisions" ;;
  "$root/product/brief.md") rec=product/brief.md ;;          # the defaults, always: a tools/check.cfg changed where the
  "$root/product/decisions.md") rec=product/decisions.md ;;  # record watch didn't see it can't unguard them
  *) exit 0 ;;
esac
agent_re='"agent_id"[[:space:]]*:[[:space:]]*"'
if [[ $input =~ $agent_re ]]; then
  echo "App Director: blocked: a subagent never writes $rec. Report the text you'd write to the session that started you; the human approves it there." >&2
  exit 2
fi
[ -f "$root/tools/records.sh" ] || exit 0
bash "$root/tools/records.sh" open "$rec" >/dev/null 2>&1 && exit 0
echo "App Director: blocked: no approval of the human's covers a change to $rec. Register the lines as a summary with 'bash tools/records.sh summary <file>', show the human its lines word for word with its id, and write them once they approve it (.app-director/rules.md › The human decides)." >&2
exit 2
