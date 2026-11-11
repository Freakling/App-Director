#!/usr/bin/env bash
# App Director record watch · Claude Code hook · framework-owned: replaced on upgrade.
#
# Runs after a file tool (PostToolUse on Edit, Write, MultiEdit and NotebookEdit) and after a shell command, failed or not
# (PostToolUse and PostToolUseFailure on Bash and PowerShell). Two jobs:
#   stamp  only the call that registered a summary stamps it: a Bash or PowerShell call whose response (the text after
#          "tool_response", never the command's own text) holds the line records.sh summary prints,
#          "records: summary S<n> · <hash>", for a summary that has that hash and no stamp yet. Every such line stamps its
#          summary, so two summaries in one command are both stamped. The summary gets this call's session_id in
#          .app-director/state/records/claude/S<n>.stamp, marked as a subagent's when the input has an agent_id, and a
#          main-session summary goes on that session's list (<session_id>.pending). record-approval.sh counts an approval
#          only in the session that stamped the summary, and never for a subagent's. A summary no call stamped (one the
#          human registered in their own terminal) belongs to no session. A command that ran records.sh summary (at the
#          start of the command or of a segment) and stamped nothing (its output went to a file, or tail cut the line) is
#          told so, and to run it again with its whole output; not a failed call, nor one whose summary records.sh refused.
#   watch  when a record file ([records] brief, decisions, stories and tasks in tools/check.cfg, and tools/check.cfg) differs
#          from the last commit, bash tools/records.sh check --worktree lists the lines no approval covers, and the
#          assistant is told at once, whatever wrote them (the file tools, sed -i, a node -e or python -c one-liner, a shell
#          redirect, or the human): which lines, that a commit with them will be refused, and what to do, which depends on
#          who wrote them, which the hook can't know. A subagent is told that it never writes records. The list each
#          session (and each subagent) was told is kept, so the same lines aren't reported after every call; once the record
#          files match the last commit again it is cleared.
# The record paths are the defaults (always), the working copy's tools/check.cfg's, and while tools/check.cfg differs from
# the last commit also the last commit's: the watch then saves the last commit's tools/check.cfg as claude/head-check.cfg,
# which guard-protected.sh reads too, and removes it once tools/check.cfg matches the last commit again. The commit gate
# reads the last commit's. A file tool's path is read by record-paths.sh, as the file guard reads it; on Windows a path with
# a stream or an 8.3 short name may be a record file, so it goes on to the git test as a command does.
# It tells the assistant through stderr with exit 2, which Claude Code shows the assistant after a tool has run, for the
# file tools and the shell tools alike. Its git commands and records.sh run with GIT_OPTIONAL_LOCKS=0, so they never take
# a lock another session's commit needs.
# Cost: the input is read by bash (a file tool's first 64 KB, as far as its path; a command's whole input, with one cat
# past 64 KB). The stamp is bash alone. The watch reads tools/check.cfg with bash: after a file tool that wrote no record
# file it starts nothing, and after a shell command one git process (git diff --quiet) tells whether a record file
# differs. Only when one does: a second git diff for tools/check.cfg (and git show to save the last commit's, or rm once it
# matches again), then tools/records.sh. A file tool that wrote tools/check.cfg starts git show too. A record file the last
# commit doesn't have isn't judged, as the gate doesn't judge it.
# Bash 3.2 and BSD tools run it. It never blocks a tool: the tool has already run.

set -f   # no globbing of a path
case "${BASH_SOURCE[0]}" in */*) here="${BASH_SOURCE[0]%/*}" ;; *) here=. ;; esac
[ -f "$here/record-paths.sh" ] || { cat > /dev/null; exit 0; }
. "$here/record-paths.sh"
LC_ALL=C
more=0
IFS= read -r -d '' -n 65536 input && more=1
path_re='"(file_path|notebook_path)"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)"'
tool_re='"tool_name"[[:space:]]*:[[:space:]]*"([A-Za-z_]+)"'
tool=""; [[ $input =~ $tool_re ]] && tool="${BASH_REMATCH[1]}"
if [ "$more" -eq 1 ]; then
  # A file tool needs only its path, which comes early; a command needs its response, which comes last.
  case "$tool" in
    Edit|Write|MultiEdit|NotebookEdit) if [[ $input =~ $path_re ]]; then cat > /dev/null; else input="$input$(cat)"; fi ;;
    *) input="$input$(cat)"; [ -n "$tool" ] || { [[ $input =~ $tool_re ]] && tool="${BASH_REMATCH[1]}"; } ;;
  esac
fi
sid_re='"session_id"[[:space:]]*:[[:space:]]*"([A-Za-z0-9_-]{1,100})"'
[[ $input =~ $sid_re ]] || exit 0
sid="${BASH_REMATCH[1]}"
cd "${CLAUDE_PROJECT_DIR:-.}" 2>/dev/null || exit 0
[ -f tools/records.sh ] || exit 0
rs=".app-director/state/records"
cs="$rs/claude"
agent=""
agent_re='"agent_id"[[:space:]]*:[[:space:]]*"([A-Za-z0-9_-]{1,100})"'
[[ $input =~ $agent_re ]] && agent="${BASH_REMATCH[1]}"
rc=0
say() { printf '%s\n' "$*" >&2; rc=2; }

# --- stamp ---
if [ "$tool" = Bash ] || [ "$tool" = PowerShell ]; then
  resp=""
  re='"tool_response"[[:space:]]*:(.*)$'
  [[ $input =~ $re ]] && resp="${BASH_REMATCH[1]}"
  cmdpart="${input:0:${#input}-${#resp}}"
  cmd_re='records\.sh([\\"'\'']|[[:space:]])+summary([\\"'\'']|[[:space:]])'
  if [[ $cmdpart =~ $cmd_re ]]; then
    stamped=0
    line_re='records: summary S([0-9]{1,9}) (·|\\u00[bB]7) ([0-9a-f]{12})'
    r="$resp"
    while [[ $r =~ $line_re ]]; do
      n="${BASH_REMATCH[1]}"; h="${BASH_REMATCH[3]}"
      r="${r#*"${BASH_REMATCH[0]}"}"
      mh=""
      if [ -f "$rs/S$n.meta" ]; then
        while IFS= read -r l; do case "$l" in hash=*) mh="${l#hash=}" ;; esac; done < "$rs/S$n.meta"
      fi
      [ -n "$mh" ] && [ "${mh:0:12}" = "$h" ] || continue
      [ -f "$cs/S$n.stamp" ] && continue
      { [ -d "$cs" ] || mkdir -p "$cs" 2>/dev/null; } || continue
      if [ -n "$agent" ]; then echo "$sid agent" > "$cs/S$n.stamp"
      else echo "$sid" > "$cs/S$n.stamp"; echo "$n" >> "$cs/$sid.pending"
      fi
      stamped=1
    done
    # Nothing stamped: say so when the command ran records.sh summary (at the start of the command or of a segment, after
    # bash or sh or not), the call didn't fail, and records.sh didn't refuse the summary (the assistant has that error).
    fail_re='"hook_event_name"[[:space:]]*:[[:space:]]*"PostToolUseFailure"'
    refused_re='records: (line [0-9]+ of the summary|no summary file|a summary file is read only|the summary has no lines|not a git repository)'
    cmdv_re='"command"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)"'
    if [ "$stamped" -eq 0 ] && ! [[ $input =~ $fail_re ]] && ! [[ $resp =~ $refused_re ]] && [[ $cmdpart =~ $cmdv_re ]]; then
      c="${BASH_REMATCH[1]}"; c="${c//\\\"/}"; c="${c//[\"\']/}"; c="${c//\\n/;}"; c="${c//&&/;}"; c="${c//||/;}"; c="${c//|/;}"
      run_re='^[[:space:]]*(([^[:space:]]*/)?(ba)?sh([[:space:]]+-[^[:space:]]+)*[[:space:]]+)?([^[:space:]]*[/\\])?records\.sh[[:space:]]+summary([[:space:]]|$)'
      ran=0
      IFS=';' read -r -d '' -a segs <<<"$c" || true
      for s in "${segs[@]}"; do [[ $s =~ $run_re ]] && ran=1; done
      [ "$ran" -eq 1 ] && say "App Director: this command ran records.sh summary, and its summary line (records: summary S<n> · <hash>) didn't come back, so the summary isn't tied to this session and the human's approval of it can't be recorded. Run 'bash tools/records.sh summary <file>' again without redirecting or cutting its output, and show the human the lines it prints."
    fi
  fi
fi

# --- watch ---
head_cfg="$cs/head-check.cfg"
save_head() { # the last commit's tools/check.cfg, while the working copy's differs ("" when the last commit has none)
  { [ -d "$cs" ] || mkdir -p "$cs" 2>/dev/null; } || return 0
  GIT_OPTIONAL_LOCKS=0 git show HEAD:tools/check.cfg > "$head_cfg" 2>/dev/null || : > "$head_cfg"
}
rp_cfg tools/check.cfg w_
h_brief="$w_brief"; h_decisions="$w_decisions"; h_stories="$w_stories"; h_tasks="$w_tasks"
[ -f "$head_cfg" ] && rp_cfg "$head_cfg" h_
d_brief=product/brief.md; d_decisions=product/decisions.md; d_stories=product/user-stories.md; d_tasks=TASKS.md
told="$cs/$sid.told"; [ -n "$agent" ] && told="$cs/$sid-$agent.told"
gittest=0
case "$tool" in
  Edit|Write|MultiEdit|NotebookEdit)
    [[ $input =~ $path_re ]] || exit "$rc"
    rp_target "${BASH_REMATCH[2]}"
    [ "$rp_nocase" -eq 1 ] && shopt -s nocasematch
    case "$resolved" in
      "$root/tools/check.cfg") save_head ;;
      "$root/$w_brief"|"$root/$w_decisions"|"$root/$w_stories"|"$root/$w_tasks") ;;
      "$root/$h_brief"|"$root/$h_decisions"|"$root/$h_stories"|"$root/$h_tasks") ;;
      "$root/$d_brief"|"$root/$d_decisions"|"$root/$d_stories"|"$root/$d_tasks") ;;
      *) rp_plain && exit "$rc"; gittest=1 ;;   # a stream or a short name may be a record file
    esac
    shopt -u nocasematch ;;
  Bash|PowerShell) gittest=1 ;;
  *) exit "$rc" ;;
esac
if [ "$gittest" -eq 1 ]; then
  GIT_OPTIONAL_LOCKS=0 git diff --quiet HEAD -- "$w_brief" "$w_decisions" "$w_stories" "$w_tasks" "$h_brief" "$h_decisions" \
    "$h_stories" "$h_tasks" "$d_brief" "$d_decisions" "$d_stories" "$d_tasks" tools/check.cfg >/dev/null 2>&1
  case $? in
    0) [ -s "$told" ] && : > "$told"; [ -f "$head_cfg" ] && rm -f "$head_cfg"; exit "$rc" ;;
    1) ;;
    *) exit "$rc" ;;
  esac
  GIT_OPTIONAL_LOCKS=0 git diff --quiet HEAD -- tools/check.cfg >/dev/null 2>&1
  case $? in
    0) [ -f "$head_cfg" ] && rm -f "$head_cfg" ;;
    1) save_head ;;
  esac
fi

out="$(GIT_OPTIONAL_LOCKS=0 bash tools/records.sh check --worktree 2>&1)"
case $? in
  0) [ -s "$told" ] && : > "$told"; exit "$rc" ;;
  1) ;;
  *) exit "$rc" ;;
esac
list=""
while IFS= read -r line; do
  case "$line" in
    "records: to go on:"*) break ;;
    "  "[!\ ]*) list="$list$line
" ;;
  esac
done <<< "$out"
[ -n "$list" ] || exit "$rc"
last=""; [ -f "$told" ] && IFS= read -r -d '' last < "$told"
[ "$last" = "$list" ] && exit "$rc"
{ [ -d "$cs" ] || mkdir -p "$cs" 2>/dev/null; } && printf '%s' "$list" > "$told"
{
  echo "App Director: these record lines differ from the last commit, and no approval of the human's covers them:"
  printf '%s' "$list"
  echo "A commit with them will be refused."
  if [ -n "$agent" ]; then
    echo "You are a subagent, and a subagent never writes records: if you wrote these lines, take them out again and report their text to the session that started you instead."
  else
    echo "If you wrote these lines, take them out again, or register them as a summary with \`bash tools/records.sh summary <file>\` (the file holds \"## <path>\" and \"+ <line>\" or \"- <line>\" lines), show the human its lines word for word with its id, and wait for their approval. If the human wrote them, leave them and tell the human: they commit an edit of their own after running \`bash tools/records.sh approve --staged\` in their own terminal (.app-director/rules.md › The human decides)."
  fi
} >&2
exit 2
