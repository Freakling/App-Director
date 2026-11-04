#!/usr/bin/env bash
# App Director release check · Claude Code hook · framework-owned: replaced on upgrade.
#
# At session start, tells the human and Claude when the installed App Director is older than its latest release,
# so a framework fix reaches a project that had fallen behind. The installed version is the one on the first line
# of .app-director/manifest (any ` + unreleased ...` tail is ignored). The latest is the highest v<major>.<minor>.<patch>
# tag in the public repository, read with `git ls-remote` and kept in .app-director/state/latest-release; the file is
# refreshed at most once a day, and a lookup that fails (offline, no git, a timeout of 5 seconds) keeps the old value
# and counts as the day's try. Versions compare field by field as numbers (1.9.0 is below 1.14.0). It sends no project
# data; PRIVACY.md says what the request is. APP_DIRECTOR_RELEASE_CHECK=0 turns it off.
# It prints one line of JSON, or nothing: a project that is up to date, offline or without a manifest costs no context,
# and every path ends in exit 0, so it never blocks a session. Bash 3.2 and BSD tools run it, and it starts as few
# processes as it can (one find when the file exists; with a lookup also timeout and git).

IFS= read -r -d '' input || true
[ "${APP_DIRECTOR_RELEASE_CHECK:-1}" = "0" ] && exit 0
exec 2>/dev/null
cd "${CLAUDE_PROJECT_DIR:-.}" || exit 0
manifest=".app-director/manifest"
state=".app-director/state"
cache="$state/latest-release"
url="https://github.com/Freakling/App-Director.git"
find_cmd=find; [ -x /usr/bin/find ] && find_cmd=/usr/bin/find
[ -f "$manifest" ] || exit 0

# The installed version: the first line "# app-director <version>", among the comment lines at the top.
version_re='^# app-director ([0-9]{1,6})\.([0-9]{1,6})\.([0-9]{1,6})( \+ unreleased.*)?$'
installed=""
while IFS= read -r line || [ -n "$line" ]; do
  line="${line%$'\r'}"
  case "$line" in '#'*) ;; *) break ;; esac
  if [[ $line =~ $version_re ]]; then
    installed="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}"
    installed_key=$(( (10#${BASH_REMATCH[1]} * 1000000 + 10#${BASH_REMATCH[2]}) * 1000000 + 10#${BASH_REMATCH[3]} ))
    break
  fi
done < "$manifest"
[ -n "$installed" ] || exit 0

# The latest release: the file's value, refreshed when it is missing or a day old.
semver_re='^([0-9]{1,6})\.([0-9]{1,6})\.([0-9]{1,6})$'
latest=""; latest_key=0
if [ -f "$cache" ]; then
  IFS= read -r latest < "$cache" || true
  latest="${latest%$'\r'}"
  if [[ $latest =~ $semver_re ]]; then
    latest_key=$(( (10#${BASH_REMATCH[1]} * 1000000 + 10#${BASH_REMATCH[2]}) * 1000000 + 10#${BASH_REMATCH[3]} ))
  else
    latest=""
  fi
  [ -n "$("$find_cmd" "$cache" -mmin +1440)" ] && stale=1 || stale=0
else
  stale=1
fi

if [ "$stale" = "1" ]; then
  tag_re='[[:space:]]refs/tags/v([0-9]{1,6})\.([0-9]{1,6})\.([0-9]{1,6})$'
  if command -v timeout >/dev/null; then
    tags="$(GIT_TERMINAL_PROMPT=0 timeout 5 git ls-remote --tags --refs "$url" 'refs/tags/v*' < /dev/null)" || tags=""
  else
    tags="$(GIT_TERMINAL_PROMPT=0 git ls-remote --tags --refs "$url" 'refs/tags/v*' < /dev/null)" || tags=""
  fi
  best=0; found=""
  while IFS= read -r line; do
    line="${line%$'\r'}"
    [[ $line =~ $tag_re ]] || continue
    key=$(( (10#${BASH_REMATCH[1]} * 1000000 + 10#${BASH_REMATCH[2]}) * 1000000 + 10#${BASH_REMATCH[3]} ))
    if [ "$key" -gt "$best" ]; then
      best=$key
      found="$((10#${BASH_REMATCH[1]})).$((10#${BASH_REMATCH[2]})).$((10#${BASH_REMATCH[3]}))"
    fi
  done <<< "$tags"
  if [ -n "$found" ]; then latest="$found"; latest_key=$best; fi   # a failed lookup, or one with no release tag, keeps the old value
  # Written either way, so the next try is tomorrow: an offline machine pays for one try a day.
  [ -d "$state" ] || mkdir -p "$state"
  if [ -n "$latest" ]; then printf '%s\n' "$latest" > "$cache"; else : > "$cache"; fi
fi

if [ -n "$latest" ] && [ "$latest_key" -gt "$installed_key" ]; then
  text="App Director $installed is installed, and the latest release is $latest. Ask the agent to upgrade it when it suits you."
  printf '{"systemMessage":"%s","hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s Tell the human this once, in your first reply."}}\n' "$text" "$text"
fi
exit 0
