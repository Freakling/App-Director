#!/usr/bin/env bash
# App Director Stop hook · Claude Code · framework-owned: replaced on upgrade.
#
# When Claude is about to finish a turn and source files differ from the last commit,
# run the project check. The check itself skips work when nothing changed since its last pass.
# If the check fails, block once and hand the output back to Claude. The same failing state isn't
# reported twice, so a turn can still end after Claude has explained a failure it can't fix.
# Turn it off per machine with APP_DIRECTOR_STOP_CHECK=0 (e.g. .claude/settings.local.json › env).

IFS= read -r -d '' _input || true
[ "${APP_DIRECTOR_STOP_CHECK:-1}" = "0" ] && exit 0
cd "${CLAUDE_PROJECT_DIR:-.}" 2>/dev/null || exit 0
[ -f tools/check.sh ] || exit 0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

# Check if any source files differ from the last commit.
git -c core.quotePath=false status --porcelain --untracked-files=all 2>/dev/null \
  | awk '{ p = substr($0, 4); sub(/^.* -> /, "", p); gsub(/"/, "", p) }
         p != "" && p !~ /\.md$/ && p !~ /^\.app-director\/state\// { found = 1 }
         END { exit !found }' \
  || exit 0

state=".app-director/state"
mkdir -p "$state" 2>/dev/null

# A builder subagent is still working. Ignore the marker if it's hours old.
if [ -f "$state/building" ]; then
  find_cmd=find; [ -x /usr/bin/find ] && find_cmd=/usr/bin/find
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
