#!/usr/bin/env bash
# App Director Stop hook · Claude Code · framework-owned: replaced on upgrade.
#
# When Claude is about to finish a turn and this session wrote or edited a source file since its last passing
# check, and source files differ from the last commit, run the project check. The check itself skips work when
# nothing changed since its last pass. If the check fails, block once and hand the output back to Claude. The same
# failing state isn't reported twice, so a turn can still end after Claude has explained a failure it can't fix.
#
# Whether this session wrote a source file is session-touched.sh's record,
# .app-director/state/sessions/<session_id>.touched (the session_id is in the hook input). A session that edited
# only documentation has none, so it never waits for the check, even while another session in the same folder has
# uncommitted code. A record untouched for a day is deleted. A passing check removes the session's record, and so
# does a turn that ends with no source file differing from the last commit (the session's work is committed). With
# no session_id in the input (an older Claude Code), the hook decides from git alone: source files differing from
# the last commit run the check.
# Turn it off per machine with APP_DIRECTOR_STOP_CHECK=0 (e.g. .claude/settings.local.json › env).
# It never runs in a prototype (bash tools/prototype.sh here).

IFS= read -r -d '' _input || true
[ "${APP_DIRECTOR_STOP_CHECK:-1}" = "0" ] && exit 0
cd "${CLAUDE_PROJECT_DIR:-.}" 2>/dev/null || exit 0
[ -f tools/check.sh ] || exit 0
find_cmd=find; [ -x /usr/bin/find ] && find_cmd=/usr/bin/find

state=".app-director/state"
sessions="$state/sessions"
sid=""
sid_re='"session_id"[[:space:]]*:[[:space:]]*"([A-Za-z0-9_-]{1,100})"'
if [[ $_input =~ $sid_re ]]; then
  sid="${BASH_REMATCH[1]}"
  # Records untouched for a day are no one's work in progress.
  [ -d "$sessions" ] && "$find_cmd" "$sessions" -type f -mmin +1440 -exec rm -f {} + >/dev/null 2>&1
  first=""
  [ -f "$sessions/$sid.touched" ] && IFS= read -r first < "$sessions/$sid.touched"
  [ -n "$first" ] || exit 0
fi

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

# Check if any source files differ from the last commit. If none do, this session's work is committed.
git -c core.quotePath=false status --porcelain --untracked-files=all 2>/dev/null \
  | awk '{ p = substr($0, 4); sub(/^.* -> /, "", p); gsub(/"/, "", p) }
         p != "" && p !~ /\.md$/ && p !~ /^\.app-director\/state\// { found = 1 }
         END { exit !found }' \
  || { [ -n "$sid" ] && rm -f "$sessions/$sid.touched" "$sessions/$sid.before"; exit 0; }

# A prototype (a linked worktree on a proto/ branch with PROTOTYPE.md at its root) is tried outside the
# loop: the check gates nothing there (.app-director/procedures/prototype.md).
[ -f tools/prototype.sh ] && bash tools/prototype.sh here >/dev/null 2>&1 && exit 0

mkdir -p "$state" 2>/dev/null

# A builder subagent is still working. Ignore the marker if it's hours old.
if [ -f "$state/building" ]; then
  [ -n "$("$find_cmd" "$state/building" -mmin -180 2>/dev/null)" ] && exit 0
fi

fingerprint="$(bash tools/check.sh --fingerprint 2>/dev/null)"
if [ -n "$fingerprint" ] && [ "$(cat "$state/last-reported" 2>/dev/null)" = "$fingerprint" ]; then
  exit 0
fi

output="$(bash tools/check.sh --if-changed 2>&1)"
status=$?
if [ "$status" -eq 0 ]; then
  rm -f "$state/last-reported"
  [ -n "$sid" ] && rm -f "$sessions/$sid.touched" "$sessions/$sid.before"
  exit 0
fi
[ -n "$fingerprint" ] && printf '%s' "$fingerprint" > "$state/last-reported"

if [ "$status" -eq 3 ]; then
  {
    echo "App Director: the project check couldn't run, so this work is unverified:"
    printf '%s\n' "$output" | tail -n 5
    echo "Tell the human; 'bash tools/setup-clone.sh' sets up the toolchain for this clone. Don't call the work done."
  } >&2
else
  {
    echo "App Director: bash tools/check.sh fails on the current files:"
    printf '%s\n' "$output" | tail -n 60
    echo "Fix it before finishing. If you're stopping to ask the human something, or the failure comes"
    echo "from changes outside your work, say that the check fails and why, then stop."
  } >&2
fi
exit 2
