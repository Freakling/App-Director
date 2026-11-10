#!/usr/bin/env bash
# App Director self-test. Tests the installer, the project check, the hooks and the pre-commit
# hook using a temporary copy of examples/todo-web. No network access; no external tools required
# (the example uses the `none` stack). Run it after every change to the framework.
# The /ui-design tests use Node when it's installed; the capture of the fixture web app also needs
# Playwright with Chromium, once: cd tests/ui-web && npm install && npx playwright install chromium
# (or ADIR_PLAYWRIGHT=<a node_modules folder that has playwright>). Without them they're skipped.
# The security assessment's tests run npm audit on a fixture when npm is installed, which asks the
# npm registry; without npm, or when the registry doesn't answer, that test is skipped with a note.
#
#   bash selftest.sh
#
# KEEP=1 keeps the temporary folder for inspection.

set -u
src="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"
cleanup() { # stops the app and the browser a capture left running, then removes the temporary folder (unless KEEP=1)
  stop_ui_leftovers
  [ "${KEEP:-0}" = "1" ] && return 0
  rm -rf "$work" 2>/dev/null || { sleep 2; rm -rf "$work"; }
}
if [ "${KEEP:-0}" = "1" ]; then echo "keeping $work"; fi
trap cleanup EXIT

passed=0; failed=0
nl='
'

ok()  { passed=$((passed + 1)); echo "  ok    $1"; }
bad() { failed=$((failed + 1)); echo "  FAIL  $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | tail -n 15 | sed 's/^/          /'; }
expect_status() { # <what> <expected> <actual> [output]
  if [ "$3" -eq "$2" ]; then ok "$1"; else bad "$1 (exit $3, expected $2)" "${4:-}"; fi
}
expect_output() { # <what> <pattern> <output>
  if [ -n "$3" ] && grep -qE -- "$2" <<< "$3"; then ok "$1"; else bad "$1 (no match for /$2/)" "$3"; fi
}
expect_no_output() { # <what> <pattern> <output>
  if [ -n "$3" ] && grep -qE -- "$2" <<< "$3"; then bad "$1 (unexpected /$2/)" "$3"; else ok "$1"; fi
}
git_q() { git -c user.name=selftest -c user.email=selftest@localhost "$@"; }
hash_of() { git hash-object --stdin < "$1"; }
finish() {
  echo "selftest: $passed passed, $failed failed"
  [ "$failed" -eq 0 ]
  exit $?
}
new_repo() { # new_repo <folder>
  mkdir -p "$1" && (cd "$1" && git init -q && git config core.autocrlf false \
    && printf '# app\n' > README.md && git add -A && git_q commit -qm init)
}
TAR=tar; [ -x /usr/bin/tar ] && TAR=/usr/bin/tar
copy_without() { # copy_without <from> <to> <name>...: the folder's contents, without any file or folder of these names
  local from="$1" to="$2" name skip=()
  shift 2
  for name in "$@"; do skip+=("--exclude=$name"); done
  mkdir -p "$to" && (cd "$from" && "$TAR" "${skip[@]}" -cf - .) | (cd "$to" && "$TAR" -xf -)
}
# What a capture leaves behind when it is killed (T304). A capture killed while Chromium starts leaves the browser's helper processes
# running on Windows (they hold the folder the browser was started in, which can't then be removed). Windows keeps a gone process's
# children listed under its id, even when it has gone itself, so they are found from the capture's id through the processes under
# it, and each is stopped by itself (taskkill's /T can't walk through a browser process that has already gone). The second pass
# catches what the first one raced with. Elsewhere the browser ends with the capture.
stop_orphans_of() { # stop_orphans_of <pid of a process that is gone> <pid to leave running, with what is under it>
  case "${1:-}" in ''|*[!0-9]*) return 0 ;; esac
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
      ADIR_ROOT="$1" ADIR_KEEP="${2:-0}" MSYS_NO_PATHCONV=1 powershell -NoProfile -NonInteractive -Command '
        $root = [int]$env:ADIR_ROOT; $keep = [int]$env:ADIR_KEEP
        for ($pass = 0; $pass -lt 2; $pass++) {
          $all = @(Get-CimInstance Win32_Process); $todo = @($root); $ids = @()
          while ($todo.Count -gt 0) {
            $next = @()
            foreach ($parent in $todo) {
              foreach ($child in @($all | Where-Object { $_.ParentProcessId -eq $parent })) {
                if ($child.ProcessId -ne $keep -and $child.ProcessId -ne $PID -and $ids -notcontains $child.ProcessId) { $ids += $child.ProcessId; $next += $child.ProcessId }
              }
            }
            $todo = $next
          }
          foreach ($id in $ids) { taskkill /PID $id /F | Out-Null }
          Start-Sleep -Milliseconds 300
        }' >/dev/null 2>&1 ;;
  esac
  return 0
}
# The app and the browser of a capture that never stopped them (the run was interrupted, or ended early), named by the record the
# capture keeps in the example app: "<app pid> <capture pid>". A capture that finished leaves no record.
stop_ui_leftovers() {
  local record="$work/todo-web/.app-director/state/ui_app.pid" app_pid="" capture_pid=""
  [ -f "$record" ] || return 0
  read -r app_pid capture_pid < "$record" || true
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
      [ -z "$capture_pid" ] || taskkill //PID "$capture_pid" //T //F >/dev/null 2>&1
      stop_orphans_of "$capture_pid" 0
      [ -z "$app_pid" ] || taskkill //PID "$app_pid" //T //F >/dev/null 2>&1
      stop_orphans_of "$app_pid" 0 ;;
    *)
      [ -z "$capture_pid" ] || kill -9 "$capture_pid" 2>/dev/null
      [ -z "$app_pid" ] || kill -9 -- "-$app_pid" "$app_pid" 2>/dev/null ;;
  esac
  return 0
}

stories_seed="$src/project/product/user-stories.md"
settings="$src/framework/.claude/settings.json"
# The parts of the selftest run side by side (T283), and the last lines of this file start them. Each part is a function, run
# in a subshell of its own from the temporary folder, and shares nothing another part changes: the ones that change the
# installed example app each get a copy of it. Each writes its output and its counts to its own file here, and the files print
# in the order of the sections, so the output reads as it always did. On a Windows machine measured here, processes start at about
# 35 a second however many parts ask for them, from six parts up to thirty-two, so a run's length there is the number of processes
# it starts, not the number of parts. Keep them few: a check that reads text already in a variable needs no pipeline.
seg="$work/seg"; mkdir -p "$seg"
# git's automatic maintenance starts a process after each commit, and no case tests it.
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=maintenance.auto GIT_CONFIG_VALUE_0=false
part() { # part <name> <output file>: starts part_<name> beside the others. A part that stops early fails the run.
  (
    part_name="$1"
    trap 'status=$?; printf "%s %s %s\n" "$passed" "$failed" "$status" > "$seg/count-$part_name"' EXIT
    passed=0; failed=0
    cd "$work" || exit 3
    "part_$part_name"
    exit 0
  ) > "$seg/$2" 2>&1 &
}
part_framework() {
# --- framework files ------------------------------------------------------------------------------
echo "framework"
# Most checks here ask whether a source file holds a plain text, hundreds of times. This grep answers grep -q and grep -qF on
# one file under $src from the file's text, kept from the last call, when the pattern has nothing a regular expression reads
# specially (\. and \* are a dot and a star). Everything else goes to grep itself.
grep() {
  local pattern="${2:-}" plain
  if [ "$#" -eq 3 ] && [ -n "$pattern" ] && [ -f "$3" ]; then
    case "$3" in "$src"/*) ;; *) command grep "$@"; return ;; esac
    case "$1" in
      -qF) ;;
      -q) plain="${pattern//\\./}"; plain="${plain//\\\*/}"
          case "$plain" in *[\\.*[\]^\$]*) command grep "$@"; return ;; esac
          pattern="${pattern//\\./.}"; pattern="${pattern//\\\*/*}" ;;
      *) command grep "$@"; return ;;
    esac
    if [ "$3" != "${grep_file:-}" ]; then
      grep_file="$3"
      IFS= read -r -d '' grep_text < "$3"
    fi
    case "$grep_text" in *"$pattern"*) return 0 ;; *) return 1 ;; esac
  fi
  command grep "$@"
}

plugin_version="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
  "$src/.claude-plugin/plugin.json")"
[ "$plugin_version" = "$(tr -d '\r\n' < "$src/VERSION")" ] \
  && ok "plugin.json version matches VERSION" \
  || bad "plugin.json version ($plugin_version) != VERSION ($(cat "$src/VERSION"))"

# Every install path gets the latest release, tagged v<version>. The files that carry the version
# must agree with VERSION: package.json, the release the marketplace pins the plugin to, each
# skill's metadata.version and the release it clones, and the fetch script's tag.
version="$(tr -d '\r\n' < "$src/VERSION")"
package_version="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$src/package.json")"
[ "$package_version" = "$version" ] \
  && ok "package.json version matches VERSION" \
  || bad "package.json version ($package_version) != VERSION ($version)"
pinned_ref="$(sed -n 's/.*"ref"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$src/.claude-plugin/marketplace.json")"
[ "$pinned_ref" = "v$version" ] \
  && ok "the marketplace pins the plugin to the release v<VERSION>" \
  || bad "the marketplace pins the plugin to '$pinned_ref', VERSION is $version"
for skill in "$src/SKILL.md" "$src"/skills/*/SKILL.md; do
  skill_name="${skill#"$src"/}"
  skill_version=""; branch=""; dashes=0
  while IFS= read -r line; do
    [ "$line" = "---" ] && { dashes=$((dashes + 1)); continue; }
    if [ "$dashes" -eq 1 ]; then case "$line" in "  version: "*) skill_version="${line#  version: }" ;; esac; fi
    [[ $line =~ --branch[[:space:]]+v([0-9.]+) ]] && branch="${BASH_REMATCH[1]}"
  done < "$skill"
  [ "$skill_version" = "$version" ] && [ "$branch" = "$version" ] \
    && ok "$skill_name: metadata.version and the release it clones match VERSION" \
    || bad "$skill_name: version '$skill_version', clones v$branch, VERSION is $version"
done
fetch_tag="$(sed -n 's/^tag=\(v[0-9.]*\)$/\1/p' "$src/scripts/fetch-app-director.sh")"
[ "$fetch_tag" = "v$version" ] \
  && ok "scripts/fetch-app-director.sh fetches the release v<VERSION>" \
  || bad "scripts/fetch-app-director.sh fetches '$fetch_tag', VERSION is $version"

# The fetch script moves a folder left by an earlier run to its release tag. A local repository
# with two tags stands in for GitHub, so this needs no network.
fetch_origin="$work/fetch-origin"
mkdir -p "$fetch_origin"
(cd "$fetch_origin" && git init -q && git config core.autocrlf false \
  && printf 'one\n' > release.txt && git add -A && git_q commit -qm one && git tag v0.0.1 \
  && printf 'two\n' > release.txt && git_q commit -qam two && git tag v0.0.2 \
  && printf 'three\n' > release.txt && git_q commit -qam three) >/dev/null 2>&1
fetch_run() { # <tag>: the fetch script with its tag and repository replaced
  sed -e "s#^tag=.*#tag=$1#" -e "s#https://github.com/Freakling/App-Director.git#file://$fetch_origin#" \
    "$src/scripts/fetch-app-director.sh" > "$work/fetch-run.sh"
  TMPDIR="$work/fetch-tmp" bash "$work/fetch-run.sh" 2>&1
}
mkdir -p "$work/fetch-tmp"
out="$(fetch_run v0.0.1)"; status=$?
expect_status "fetch-app-director.sh clones the release tag" 0 $status "$out"
[ "$(tr -d '\r\n' < "$work/fetch-tmp/app-director/release.txt")" = "one" ] \
  && ok "the clone is at the tag, not at the default branch" \
  || bad "the clone is not at v0.0.1" "$(cat "$work/fetch-tmp/app-director/release.txt")"
out="$(fetch_run v0.0.2)"; status=$?
expect_status "fetch-app-director.sh moves a reused folder to the new tag" 0 $status "$out"
[ "$(tr -d '\r\n' < "$work/fetch-tmp/app-director/release.txt")" = "two" ] \
  && ok "the reused folder is at the new tag" \
  || bad "the reused folder is not at v0.0.2" "$(cat "$work/fetch-tmp/app-director/release.txt")"

cmp -s "$src/LICENSE" "$src/framework/.app-director/LICENSE" \
  && ok "the installed LICENSE copy matches LICENSE" \
  || bad "framework/.app-director/LICENSE differs from LICENSE"

missing=""
for skill in "$src"/framework/.claude/skills/*/SKILL.md; do
  name="${skill%/*}"; name="${name##*/}"
  [ -f "$src/framework/.app-director/procedures/$name.md" ] || missing="$missing $name"
  grep -q "^name: $name$" "$skill" || missing="$missing $name(name)"
done
[ -z "$missing" ] && ok "every Claude Code skill points to an existing procedure" \
  || bad "skills without procedures or mismatched names:$missing"

# The research assistant: every piece exists and is wired in, and the researcher can read and search but not change anything.
missing=""
for file in framework/.app-director/procedures/research.md framework/.app-director/research-domain.md \
    framework/.claude/agents/researcher.md framework/.claude/skills/research/SKILL.md \
    project/product/research/README.md examples/todo-web/product/research/README.md; do
  [ -f "$src/$file" ] || missing="$missing $file"
done
[ -z "$missing" ] && ok "the research assistant's files exist" || bad "research assistant files missing:$missing"
researcher="$src/framework/.claude/agents/researcher.md"
if [ "$(sed -n 's/^tools: //p' "$researcher" | tr -d '\r')" = "Read, Grep, Glob, WebSearch, WebFetch" ] \
    && grep -q '^model: inherit' "$researcher" \
    && grep -Eq '^ *"WebSearch",?[[:space:]]*$' "$settings" && grep -Eq '^ *"WebFetch",?[[:space:]]*$' "$settings"; then
  ok "the researcher has read, search and fetch tools only, and settings.json allows web search and fetch"
else
  bad "researcher.md must have exactly the tools Read, Grep, Glob, WebSearch, WebFetch (no edit, write or shell), and settings.json must allow WebSearch and WebFetch"
fi
wired=""
proc="$src/framework/.app-director"
grep -q 'research-domain\.md' "$proc/procedures/research.md" || wired="$wired research.md>research-domain.md"
grep -q 'researcher' "$proc/procedures/next-task.md" && grep -q 'Research items' "$proc/procedures/next-task.md" || wired="$wired next-task.md"
grep -q 'research\.md' "$proc/procedures/design.md" && grep -q 'product/research/' "$proc/procedures/design.md" || wired="$wired design.md"
grep -q 'R<n>' "$proc/tasks.md" && grep -q '^- \*\*Research\.\*\*' "$proc/tasks.md" || wired="$wired tasks.md"
grep -q 'research' "$proc/procedures/align.md" || wired="$wired align.md"
grep -q '/research' "$src/README.md" && grep -q '/research' "$src/ONBOARDING.md" || wired="$wired README.md/ONBOARDING.md"
grep -q '^\*\*Next IDs:\*\* T[0-9]* · B[0-9]* · R[0-9]*$' "$src/project/TASKS.md" || wired="$wired project/TASKS.md(Next IDs)"
grep -q '^T[0-9]* · B[0-9]* · R[0-9]*$' "$src/examples/todo-web/TASKS.md" || wired="$wired todo-web/TASKS.md(Next IDs)"
[ -z "$wired" ] && ok "the research assistant is wired into the procedures, the item format, the seeds and the docs" \
  || bad "the research assistant isn't wired into:$wired"
# The human-written product brief: the director's template ships as a seed (and in the example,
# blank), keeps the director's structure, and onboarding and the README present it.
wired=""
brief_seed="$src/project/product/director-brief.md"
cmp -s "$brief_seed" "$src/examples/todo-web/product/director-brief.md" || wired="$wired example copy differs from the seed"
grep -q '^# Product Brief: \[App Name\]$' "$brief_seed" || wired="$wired title"
for heading in "1\. Executive" "2\. Problem" "3\. Goals" "4\. Target" "5\. Core" "6\. User" "7\. Technical" \
    "8\. Launch" "9\. Risks" "10\. Open"; do
  grep -qE "^## $heading" "$brief_seed" || wired="$wired [## $heading]"
done
grep -q '^### Your own product brief' "$src/ONBOARDING.md" && grep -q 'product/director-brief\.md' "$src/ONBOARDING.md" \
  && grep -q '(from your brief)' "$src/ONBOARDING.md" && grep -q '(inferred, please confirm)' "$src/ONBOARDING.md" \
  && grep -q 'alternative to the chat interview or an addition to it' "$src/ONBOARDING.md" \
  && grep -q 'sets the stage for later development' "$src/ONBOARDING.md" || wired="$wired ONBOARDING.md"
grep -q 'product/director-brief\.md' "$src/README.md" || wired="$wired README.md"
[ -z "$wired" ] && ok "the human-written product brief ships as a seed (and in the example) with the director's structure, and onboarding and the README present it" \
  || bad "the human-written product brief isn't wired into:$wired"
# The start-here step in the README and the template's header link to the latest template at the
# release tag. Both carry the same link, and its version is VERSION, as the fetch script's tag is.
brief_link_re='https://raw\.githubusercontent\.com/Freakling/App-Director/v[0-9.]+/project/product/director-brief\.md'
readme_link="$(grep -oE "$brief_link_re" "$src/README.md" | head -1)"
seed_link="$(grep -oE "$brief_link_re" "$brief_seed" | head -1)"
[ -n "$readme_link" ] && [ "$readme_link" = "$seed_link" ] \
  && [ "$readme_link" = "https://raw.githubusercontent.com/Freakling/App-Director/v$version/project/product/director-brief.md" ] \
  && grep -q '^\*\*Start here: write your product brief\.\*\*' "$src/README.md" \
  && ok "the README's Start here step (first in Install) and the template's header link to the latest template at v<VERSION>" \
  || bad "the latest-template link isn't at v<VERSION> in both the README and the template header (README: '$readme_link', header: '$seed_link', VERSION is $version)"

# /ui-design: every piece exists and is wired in, the same way the research assistant is.
missing=""
for file in framework/.app-director/procedures/ui-design.md framework/.claude/skills/ui-design/SKILL.md \
    framework/tools/ui_capture.sh framework/tools/ui/capture.mjs framework/tools/ui/lint.mjs framework/tools/ui/drawing.mjs \
    framework/tools/ui/overlay.mjs framework/tools/ui/verify.mjs framework/tools/ui/common.mjs framework/tools/ui/package.json \
    framework/tools/ui/.npmrc project/tools/ui/screens.mjs project/tools/ui_capture.cfg project/product/ui/README.md \
    tests/ui-drawing/fixture.excalidraw tests/ui-drawing/fixture-scaled.excalidraw tests/ui-drawing/fixture-conflict.excalidraw tests/ui-drawing/fixture.elements.json \
    tests/ui-drawing/fixture.expected.json tests/ui-drawing/fixture.png tests/ui-drawing/starter.expected.excalidraw \
    tests/ui-drawing/fixture.godot.drawing.json tests/ui-drawing/fixture-scaled.godot.drawing.json \
    tests/ui-drawing/README.md tests/ui-web/serve.mjs tests/ui-web/package.json tests/ui-web/site/index.html tests/ui-web/site/lint.html \
    tests/ui-web/site/order.html tests/ui-web/site/away.html tests/ui-web/site/modal.html tests/ui-web/site/reload.html; do
  [ -f "$src/$file" ] || missing="$missing $file"
done
[ -z "$missing" ] && ok "the /ui-design files exist" || bad "/ui-design files missing:$missing"
wired=""
uiproc="$proc/procedures/ui-design.md"
grep -q 'procedures/ui-design\.md' "$src/framework/.claude/skills/ui-design/SKILL.md" || wired="$wired SKILL.md"
grep -q '^- `process <screen>`' "$uiproc" && grep -q 'tools/ui/drawing\.mjs' "$uiproc" && grep -q '\.drawing\.json' "$uiproc" \
  && grep -q '\.starter\.excalidraw' "$uiproc" && grep -q 'Never read the raw' "$uiproc" && grep -q '^### The screen spec' "$uiproc" \
  && grep -q "^## If you can't view images" "$uiproc" && grep -q -- '--verify' "$uiproc" || wired="$wired ui-design.md"
grep -q 'product/ui/<screen>\.md' "$proc/rules.md" && grep -q '`director/ui/`' "$proc/rules.md" && grep -q 'tools/ui/screens\.mjs' "$proc/rules.md" \
  && grep -q 'data-testid' "$proc/rules.md" || wired="$wired rules.md"
grep -q '^- \*\*`UI:`\*\*' "$proc/tasks.md" || wired="$wired tasks.md"
grep -q '\*\*Screens\*\*' "$proc/procedures/build.md" && grep -q 'Screen: <' "$proc/procedures/build.md" \
  && grep -q 'ui_capture\.sh <id> --verify' "$proc/procedures/build.md" || wired="$wired build.md"
grep -q '`UI:`' "$proc/procedures/review.md" && grep -q 'compare@' "$proc/procedures/review.md" || wired="$wired review.md"
grep -q '`UI:`' "$proc/procedures/acceptance.md" && grep -q 'compare@' "$proc/procedures/acceptance.md" || wired="$wired acceptance.md"
grep -q -- '--missing' "$proc/procedures/align.md" && grep -q -- '--static' "$proc/procedures/align.md" \
  && grep -q '/product/ui/captures/' "$proc/procedures/align.md" || wired="$wired align.md"
grep -q 'ui-design\.md' "$proc/procedures/design.md" || wired="$wired design.md"
grep -q '^- \*\*OWASP baseline\.\*\*' "$proc/rules.md" && grep -q 'no project setting turns it off' "$proc/rules.md"   && grep -q 'OWASP' "$proc/procedures/design.md" && grep -q 'OWASP' "$proc/procedures/review.md"   && grep -q 'OWASP' "$src/ONBOARDING.md" && grep -q 'OWASP' "$src/framework/tools/check.sh" || wired="$wired OWASP baseline"
grep -q '"Bash(bash tools/ui_capture.sh\*)"' "$settings" && grep -q '"Bash(node tools/ui/drawing.mjs \*)"' "$settings" \
  && grep -q '"Bash(node tools/ui/verify.mjs \*)"' "$settings" && ! grep -q '"Bash(node tools/ui/\*)"' "$settings" || wired="$wired settings.json"
grep -q '/ui-design' "$src/README.md" && grep -q '/ui-design' "$src/ONBOARDING.md" && grep -q 'UI / screen layout' "$src/ONBOARDING.md" \
  && grep -q 'UI / screen layout' "$src/project/AGENTS.md" && grep -q '`product/ui/`' "$src/project/AGENTS.md" || wired="$wired README.md/ONBOARDING.md/AGENTS.md"
grep -q '"/product/ui/captures/" "/tools/ui/node_modules/" "/tools/ui/.auth/"' "$src/install.sh" || wired="$wired install.sh"
[ -z "$wired" ] && ok "/ui-design is wired into the rules, the item format, the procedures, the settings, the seeds and the docs" \
  || bad "/ui-design isn't wired into:$wired"
# The check must not start needing Node: it never runs the capture tools.
if grep -qiE 'ui_capture|tools/ui/|playwright' "$src/framework/tools/check.sh" "$src/framework/tools/setup-clone.sh"; then
  bad "the check and setup-clone never run the capture tools (they would need Node)"
else
  ok "the check and setup-clone never run the capture tools (they would need Node)"
fi
# Which paths count as source has one definition, tools/check.sh's source_re: the pre-commit hook asks check.sh
# --unignored and keeps no copy, and the TypeScript stack hands the related tests the same extensions.
if command grep -qE '(^|[^a-z])(tsx|mjs|mts)([^a-z]|$)|tools/stacks' "$src/framework/.githooks/pre-commit"; then
  bad "the pre-commit hook keeps no copy of the source-path rule (it asks tools/check.sh --unignored)" \
    "$(command grep -nE '(^|[^a-z])(tsx|mjs|mts)([^a-z]|$)|tools/stacks' "$src/framework/.githooks/pre-commit")"
else
  ok "the pre-commit hook keeps no copy of the source-path rule (it asks tools/check.sh --unignored)"
fi
_src_ext="$(sed -n "s/^source_re='\\\\\\.(\\([a-z|]*\\))\\\$|.*/\\1/p" "$src/framework/tools/check.sh")"
_ts_ext="$(sed -n 's/^ *\(\*\.[a-z|*.]*\)) related+=.*/\1/p' "$src/framework/tools/stacks/typescript.sh")"; _ts_ext="${_ts_ext//\*./}"
[ -n "$_src_ext" ] && [ "$_ts_ext" = "$_src_ext" ] && ok "the TypeScript stack's related run takes check.sh's source extensions" \
  || bad "the TypeScript stack's related run takes check.sh's source extensions" "check.sh: $_src_ext${nl}typescript.sh: $_ts_ext"
_pw_range() { sed -n 's/.*"playwright"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1"; }
[ "$(_pw_range "$src/framework/tools/ui/package.json")" = "$(_pw_range "$src/tests/ui-web/package.json")" ] \
  && ok "the selftest's Playwright is the version range capture asks for" \
  || bad "framework/tools/ui/package.json and tests/ui-web/package.json ask for different Playwright versions"
# One exact version, not a range: no lock file ships, so the pin is what fixes the installed tree (framework/tools/ui/.npmrc).
pw_exact=1
for pw_file in "$src/framework/tools/ui/package.json" "$src/tests/ui-web/package.json"; do
  _pw_range "$pw_file" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || pw_exact=0
done
[ "$pw_exact" -eq 1 ] && ok "Playwright is pinned to one exact version in both package.json files (no ^ or ~)" \
  || bad "Playwright is a range in framework/tools/ui/package.json or tests/ui-web/package.json (pin one exact version: no lock file ships)"

unrouted=""
for proc in "$src"/framework/.app-director/procedures/*.md; do
  name="${proc##*/}"
  grep -qF "**$name:**" "$src/framework/.app-director/rules.md" \
    || grep -qF "\`$name\`" "$src/framework/.app-director/rules.md" \
    || unrouted="$unrouted $name"
done
[ -z "$unrouted" ] && ok "every procedure is routed in rules.md" \
  || bad "procedures missing from rules.md routing:$unrouted"

# Sessions building at once each get a git worktree, and the rule gives the reason (a shared checkout
# lets one session's half-written files fail the other's check and Stop hook).
_wt_rule="$src/framework/.app-director/rules.md"
grep -qF 'git worktree add ../app-design' "$_wt_rule" && grep -qF 'bash tools/setup-clone.sh' "$_wt_rule" \
  && grep -qF 'half-written files fail the other' "$_wt_rule" \
  && ok "sessions building at once each get a worktree, with the reason, in rules.md" \
  || bad "rules.md doesn't name the worktree rule for sessions building at once, with its reason"

# Every subagent launch sets its model explicitly from the sizing table, so none inherits the session's
# model. next-task.md says so for the builder, the reviewer, the researcher and an escalated retry;
# rules.md states the rule the launches apply.
_nt="$src/framework/.app-director/procedures/next-task.md"
_rules_model="$src/framework/.app-director/rules.md"
_launch_wording=""
grep -qF 'Every subagent launch sets its model explicitly' "$_nt" || _launch_wording="$_launch_wording launch-rule"
grep -qF "A launch never lets a subagent inherit the session's model" "$_nt" || _launch_wording="$_launch_wording no-inherit"
grep -qF 'Where the table has no entry for the size, or model sizing is off, the launch passes the session model explicitly' "$_nt" \
  || _launch_wording="$_launch_wording session-fallback"
grep -qF 'the builder, the reviewer (step 6), the researcher (Research items) and an escalated retry' "$_nt" \
  || _launch_wording="$_launch_wording launches"
grep -qF 'Pass that model as `model:`' "$_nt" || _launch_wording="$_launch_wording builder-model"
grep -qF 'retry once with its model set to the next size' "$_nt" || _launch_wording="$_launch_wording escalation"
[ "$(grep -cF 'with its model set as section 3 says' "$_nt")" -ge 2 ] || _launch_wording="$_launch_wording reviewer-researcher"
grep -qF 'model sizing on' "$_nt" && _launch_wording="$_launch_wording old-conditional"
grep -qF "passes the entry for the current item's size as an explicit model on every subagent launch" "$_rules_model" \
  || _launch_wording="$_launch_wording rules.md"
[ -z "$_launch_wording" ] \
  && ok "every subagent launch sets its model explicitly, and next-task.md and rules.md say so" \
  || bad "the subagent model wording is missing or has drifted:$_launch_wording"

# Model IDs must live only in the refresh-model-sizing procedure (single source of truth).
_rms="$src/framework/.app-director/procedures/refresh-model-sizing.md"
_rms_ids="$(grep -oE 'claude-[a-z0-9-]+' "$_rms" | sort -u | tr '\n' '|' | sed 's/|$//')"
_model_id_leak=""
for _f in "$src/README.md" "$src/ONBOARDING.md"; do
  if [ -n "$_rms_ids" ] && grep -qE "$_rms_ids" "$_f" 2>/dev/null; then
    _model_id_leak="$_model_id_leak $(basename "$_f")"
  fi
done
[ -z "$_model_id_leak" ] \
  && ok "model IDs appear only in refresh-model-sizing procedure" \
  || bad "model IDs leaked outside refresh-model-sizing:$_model_id_leak"

# No en dashes (U+2013) or em dashes (U+2014) in any tracked or new file.
_dash_files="$(git -C "$src" grep --untracked -lP '[\x{2013}\x{2014}]' 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"
[ -z "$_dash_files" ] \
  && ok "no en or em dashes in tracked files" \
  || bad "en/em dashes found in: $_dash_files"

# The security assessment: every piece exists and is wired in, the checklist covers every OWASP category
# and marks each check, and the procedure keeps a tool's pass from marking a category met.
adir="$src/framework/.app-director"
missing=""
for file in framework/.app-director/procedures/security.md framework/.app-director/reference/owasp.md \
    framework/.claude/skills/security/SKILL.md framework/tools/security.sh tests/security/README.md \
    tests/security/vulnerable/src/server.js tests/security/vulnerable/src/payments.js tests/security/vulnerable/package.fixture.json \
    tests/security/vulnerable/package-lock.fixture.json tests/security/clean/src/server.js tests/security/clean/src/payments.js \
    tests/security/clean/package.fixture.json tests/security/clean/package-lock.fixture.json; do
  [ -f "$src/$file" ] || missing="$missing $file"
done
[ -z "$missing" ] && ok "the security assessment's files exist" || bad "security assessment files missing:$missing"
owasp_ref="$adir/reference/owasp.md"
_cats=""
for n in 01 02 03 04 05 06 07 08 09 10; do grep -q "^### A$n:2025 " "$owasp_ref" || _cats="$_cats A$n"; done
for n in 1 2 3 4 5 6 7 8 9 10; do grep -q "^### API$n:2023 " "$owasp_ref" || _cats="$_cats API$n"; done
_unmarked="$(sed -n '/^## OWASP Top 10 (2025)$/,$p' "$owasp_ref" | grep '^- ' | grep -vE '^- (code|config|people): |^- Not applicable')"
[ -z "$_cats" ] && [ -z "$_unmarked" ] && grep -q '^## Where to look, by stack' "$owasp_ref" \
  && [ "$(sed -n '/^## Where to look, by stack/,/^## OWASP/p' "$owasp_ref" | grep -cE '^- \*\*(typescript|flutter|python|none):\*\*')" -eq 4 ] \
  && ok "the OWASP checklist has every OWASP Top 10 (2025) and API Security Top 10 (2023) category, each check marked code, config or people, and where to look per stack" \
  || bad "the OWASP checklist is missing categories:$_cats; unmarked checks: $_unmarked"
wired=""
secproc="$adir/procedures/security.md"
grep -q 'reference/owasp\.md' "$secproc" && grep -q 'bash tools/security\.sh' "$secproc" && grep -q 'product/security/YYYY-MM-DD\.md' "$secproc" \
  && grep -q '`reviewer` subagent' "$secproc" && grep -q 'review\.md' "$secproc" && grep -q 'tasks\.md' "$secproc" \
  && grep -q 'never install one without asking' "$secproc" && grep -q 'never marked verified from a tool passing alone' "$secproc" \
  && grep -q "^## What a clean run doesn't prove" "$secproc" && grep -q '^- \*\*high:\*\*' "$secproc" && grep -q '^## 4\. People and process' "$secproc" || wired="$wired security.md"
grep -q 'procedures/security\.md' "$src/framework/.claude/skills/security/SKILL.md" || wired="$wired SKILL.md"
grep -q 'security\.md' "$src/framework/.claude/agents/reviewer.md" && grep -q 'reference/owasp\.md' "$src/framework/.claude/agents/reviewer.md" || wired="$wired reviewer.md"
grep -q '^- \*\*security\.md:\*\*' "$adir/rules.md" && grep -q 'product/security/YYYY-MM-DD\.md' "$adir/rules.md" || wired="$wired rules.md"
grep -q 'security\.md' "$adir/procedures/release.md" && grep -q 'blocks the release' "$adir/procedures/release.md" || wired="$wired release.md"
grep -q 'bash tools/security\.sh --due' "$adir/procedures/next-task.md" && grep -q '\[security\] every' "$adir/procedures/next-task.md" || wired="$wired next-task.md"
grep -qF '"Bash(bash tools/security.sh)",' "$settings" && grep -qF '"Bash(bash tools/security.sh --due)",' "$settings" \
  && ! grep -qF '"Bash(bash tools/security.sh*)"' "$settings" || wired="$wired settings.json"
sed -n '/^\[security\]$/,/^\[/p' "$src/project/tools/check.cfg" | grep -q '^every = 10$' || wired="$wired project/tools/check.cfg"
grep -q '`/security`' "$src/ONBOARDING.md" && grep -q '`\[security\] every`' "$src/ONBOARDING.md" && grep -q '`/security`' "$src/README.md" || wired="$wired README.md/ONBOARDING.md"
[ -z "$wired" ] && ok "the security assessment is wired into the rules, the reviewer, release, next-task, the settings, the check.cfg seed and the docs" \
  || bad "the security assessment isn't wired into:$wired"

# User stories: the seed has its header line, its sections and a worked example in the story format; the
# item format and the TASKS.md seed carry Stories:; the check.cfg seed has the cadence; and the rules,
# the procedures, the settings and the docs name them. tools/stories.sh --due is tested under "user stories".
wired=""
[ -f "$stories_seed" ] && [ -f "$src/framework/tools/stories.sh" ] || wired="$wired files"
grep -q '^# User stories: {{APP_NAME}}$' "$stories_seed" || wired="$wired seed(title)"
grep -qE '^\*\*Next ID:\*\* US-[0-9]+ · \*\*Last validated:\*\* never$' "$stories_seed" || wired="$wired seed(Next ID and Last validated)"
grep -q '^## The value in one paragraph per role$' "$stories_seed" && grep -q '^## Roles$' "$stories_seed" || wired="$wired seed(sections)"
_st_rows="$(grep -E '^\| US-' "$stories_seed")"
[ -n "$_st_rows" ] && grep -q '^| ID | Story | Confirmed |$' "$stories_seed" || wired="$wired seed(tables)"
printf '%s\n' "$_st_rows" | grep -vqE '^\| US-[0-9]+ \| As an? [^|]+ I [^|]+, so [^|]+\. \| ([0-9]{4}-[0-9]{2}-[0-9]{2}|unconfirmed) \|$' \
  && wired="$wired seed(a row isn't | US-<n> | As a <role> I ..., so ... | <date> or unconfirmed |)"
_st_next="$(sed -n 's/^\*\*Next ID:\*\* US-\([0-9]*\) .*/\1/p' "$stories_seed")"
_st_ids="$(printf '%s\n' "$_st_rows" | sed -n 's/^| US-\([0-9]*\) .*/\1/p')"
[ -n "$_st_next" ] && [ -z "$(printf '%s\n' "$_st_ids" | awk -v next_id="$_st_next" '$1 + 0 >= next_id + 0 || seen[$1]++')" ] \
  || wired="$wired seed(IDs unique and below Next ID)"
for _st_role in $(printf '%s\n' "$_st_rows" | sed -n 's/^| US-[0-9]* | As an\{0,1\} \([A-Za-z]*\) I .*/\1/p' | tr 'A-Z' 'a-z' | awk '!seen[$0]++'); do
  sed -n '/^## Roles$/,/^## [^R]/p' "$stories_seed" | tr 'A-Z' 'a-z' | grep -q "^- \*\*$_st_role:\*\*" || wired="$wired seed(role $_st_role not in Roles)"
done
grep -q '^- Stories: US-[0-9]' "$adir/tasks.md" && grep -q '^- \*\*`Stories:`\.\*\*' "$adir/tasks.md" || wired="$wired tasks.md"
grep -q '^- Stories: -$' "$src/project/TASKS.md" || wired="$wired project/TASKS.md"
sed -n '/^\[stories\]$/,/^\[/p' "$src/project/tools/check.cfg" | grep -q '^every = 10$' || wired="$wired project/tools/check.cfg"
grep -q '^| The roles the app serves, and why each feature is built | `product/user-stories\.md`' "$adir/rules.md" \
  && grep -q '^- \*\*Why it.s built\.\*\* A feature item names the user stories it serves' "$adir/rules.md" || wired="$wired rules.md"
grep -q '^## User stories$' "$adir/procedures/design.md" && grep -q '^### Validate the stories$' "$adir/procedures/design.md" \
  && grep -q 'bash tools/stories\.sh --due' "$adir/procedures/design.md" && grep -q 'its `Stories:`' "$adir/procedures/design.md" || wired="$wired design.md"
grep -q 'bash tools/stories\.sh --due' "$adir/procedures/next-task.md" && grep -q '\[stories\] every' "$adir/procedures/next-task.md" \
  && grep -q 'A feature item (not a research item) with no story gets one before it is built' "$adir/procedures/next-task.md" \
  && grep -q 'with `product/user-stories\.md` when the claim drafted a story' "$adir/procedures/next-task.md" || wired="$wired next-task.md"
grep -qF -- '- [ ] Still right   - [ ] Needs a change' "$adir/procedures/acceptance.md" && grep -q '^4\. \*\*Stories\*\*' "$adir/procedures/acceptance.md" || wired="$wired acceptance.md"
grep -q 'stories no item serves' "$adir/procedures/align.md" && grep -q 'feature items with no story' "$adir/procedures/align.md" \
  && grep -q 'bugs with no story' "$adir/procedures/align.md" \
  && grep -q 'stories unconfirmed past the cadence' "$adir/procedures/align.md" || wired="$wired align.md"
grep -qF '"Bash(bash tools/stories.sh --due)",' "$settings" && ! grep -qF '"Bash(bash tools/stories.sh*)"' "$settings" || wired="$wired settings.json"
grep -q 'product/user-stories\.md' "$src/ONBOARDING.md" && grep -q '`\[stories\] every`' "$src/ONBOARDING.md" \
  && grep -q 'were written from the code on <date>, before the app kept user stories\.' "$src/ONBOARDING.md" || wired="$wired ONBOARDING.md"
grep -q 'were written from the code on <date>, before the app kept user stories\.' "$adir/procedures/align.md" || wired="$wired align.md(written from the code)"
grep -q 'product/user-stories\.md' "$src/README.md" && grep -q 'tools/stories\.sh' "$src/README.md" || wired="$wired README.md"
[ -z "$wired" ] && ok "the user stories seed has its header and sections, and Stories:, the cadence, the rules, the procedures, the settings and the docs name them" \
  || bad "the user stories aren't wired into:$wired"

# Prototypes: the procedure, the skill and tools/prototype.sh exist and are wired in. rules.md routes the
# procedure and says a prototype session is outside the loop and reaches main only through the harvest, the
# item format has Prototype:, the design procedure harvests one and files nothing without the human, the
# settings allow the script, the hooks know proto/ branches, and the docs name it. The script and the hooks
# run under "prototype".
_pp="$adir/procedures/prototype.md"
wired=""
for file in framework/.app-director/procedures/prototype.md framework/.claude/skills/prototype/SKILL.md framework/tools/prototype.sh; do
  [ -f "$src/$file" ] || wired="$wired $file"
done
grep -q 'procedures/prototype\.md' "$src/framework/.claude/skills/prototype/SKILL.md" || wired="$wired SKILL.md"
grep -q '^## Start$' "$_pp" && grep -q '^## In a prototype session$' "$_pp" && grep -q '^## Harvest$' "$_pp" \
  && grep -qF 'bash tools/prototype.sh start <name>' "$_pp" && grep -qF 'bash tools/prototype.sh harvest <name>' "$_pp" \
  && grep -qF 'bash tools/prototype.sh remove <name>' "$_pp" && grep -qF 'bash tools/prototype.sh list' "$_pp" \
  && grep -qF 'git diff main...proto/<name>' "$_pp" && grep -qF 'Never push a `proto/` branch' "$_pp" \
  && grep -qF 'git branch -D proto/<name>' "$_pp" && grep -qF 'Never force it' "$_pp" \
  && grep -q 'Nothing is filed without the human.s answer' "$_pp" && grep -qF 'Commits need no approval' "$_pp" \
  && grep -qF '`ui-design.md` › capture' "$_pp" && grep -q 'Run `design\.md` on them' "$_pp" \
  && grep -qF 'git pull --ff-only' "$_pp" && grep -qF 'start <name> --as-is' "$_pp" \
  && grep -q "ask the human to stop the prototype's app and close its session" "$_pp" && grep -qF 'node_modules' "$_pp" \
  && [ "$(grep -c 'A capture opens whatever answers at `base_url`' "$_pp")" -ge 2 ] || wired="$wired prototype.md"
grep -qF 'Unlike Record step 4, a drafted story the human doesn' "$adir/procedures/design.md" || wired="$wired design.md(unanswered story)"
grep -qF '**prototype.md:**' "$adir/rules.md" && grep -q '^- \*\*Prototypes\.\*\*' "$adir/rules.md" \
  && grep -q 'That session is outside the loop' "$adir/rules.md" && grep -q 'reaches main only through the harvest' "$adir/rules.md" || wired="$wired rules.md"
grep -q '^- \*\*`Prototype:`\*\* (optional)\. `proto/<name>`' "$adir/tasks.md" || wired="$wired tasks.md"
grep -q '^## Harvest a prototype$' "$adir/procedures/design.md" && grep -q 'or harvest a prototype (Harvest a prototype, below)' "$adir/procedures/design.md" \
  && grep -qF -- '- Prototype: proto/<name>' "$adir/procedures/design.md" && grep -qF '(prototype: proto/<name>)' "$adir/procedures/design.md" \
  && grep -q 'Nothing is filed without the human.s answer' "$adir/procedures/design.md" || wired="$wired design.md"
grep -qF '"Bash(bash tools/prototype.sh *)",' "$settings" || wired="$wired settings.json"
grep -qF 'bash tools/prototype.sh here' "$src/framework/.githooks/pre-commit" && grep -qF 'bash tools/prototype.sh here' "$src/framework/.claude/hooks/stop-check.sh" \
  && grep -qF 'refs/heads/proto/' "$src/framework/.githooks/pre-push" && grep -qF 'pre-commit pre-push' "$src/framework/tools/setup-clone.sh" || wired="$wired hooks"
grep -qF 'A session in a checkout that `bash tools/prototype.sh here` calls a prototype (a linked worktree on a `proto/` branch with `PROTOTYPE.md` at its root) is a prototype session: read `prototype.md` › In a prototype session before any work.' "$adir/rules.md" \
  && grep -qF 'git diff main...proto/<name> -- <path>' "$adir/procedures/build.md" || wired="$wired rules.md(prototype session) build.md"
grep -qF '`/prototype {name}`' "$src/README.md" && grep -qF 'tools/prototype.sh' "$src/README.md" && grep -qF '· prototype ·' "$src/README.md" || wired="$wired README.md"
grep -qF '`/prototype`' "$src/ONBOARDING.md" || wired="$wired ONBOARDING.md"
[ -z "$wired" ] && ok "prototypes: the procedure, the skill and tools/prototype.sh exist, and the rules, the item format, the design procedure, the settings, the hooks and the docs name them" \
  || bad "prototypes aren't wired into:$wired"

# Nothing is written without the human's approval of a summary: rules.md has the bullet right after the
# design-call bullet, design.md holds the answers in the conversation, has Summary and approval between
# For each question and Record each decision in one change, and Finish writes what the summary lists, and
# every procedure that records from a conversation (design.md's validation and harvest, research.md,
# next-task.md, drift-reset.md, ui-design.md, acceptance.md, align.md and ONBOARDING.md) carries the pointer.
wired=""
_ap_ptr='Write nothing until the human approves a summary of all of it (`design.md` › Summary and approval); a chat message or an "Other" answer before then re-opens the options.'
_ap_rules="$adir/rules.md"
_ap_dm="$adir/procedures/design.md"
_ap_call="$(grep -n '^- A design call is a feature behaviour' "$_ap_rules" | cut -d: -f1)"
_ap_rule="$(grep -n "^- \*\*Nothing is written without the human.s explicit approval\.\*\* While a session runs, the answers stay in the conversation\." "$_ap_rules" | cut -d: -f1)"
[ -n "$_ap_call" ] && [ -n "$_ap_rule" ] && [ "$_ap_rule" -eq $((_ap_call + 1)) ] \
  && grep -qF 'is a scope change or a modification, not an answer to record: it re-opens the options it touches, and the session reassesses, then restarts or continues.' "$_ap_rules" \
  && grep -qF 'show a summary of every file, line, item and story to be written (`design.md` › Summary and approval), and write and commit all of it in one change only after the human approves the summary.' "$_ap_rules" \
  || wired="$wired rules.md(the approval bullet after the design-call bullet)"
_ap_each="$(grep -n '^## For each question$' "$_ap_dm" | cut -d: -f1)"
_ap_sum="$(grep -n '^## Summary and approval$' "$_ap_dm" | cut -d: -f1)"
_ap_rec="$(grep -n '^## Record each decision in one change$' "$_ap_dm" | cut -d: -f1)"
[ -n "$_ap_each" ] && [ -n "$_ap_sum" ] && [ -n "$_ap_rec" ] && [ "$_ap_each" -lt "$_ap_sum" ] && [ "$_ap_sum" -lt "$_ap_rec" ] \
  || wired="$wired design.md(Summary and approval between For each question and Record)"
grep -qF 'Hold the answer in the conversation: nothing is recorded yet, and an answered part is not recorded by itself.' "$_ap_dm" \
  && ! grep -qF 'record only that part' "$_ap_dm" || wired="$wired design.md(the wait holds the answers)"
grep -qF 'Nothing is written before the human approves it.' "$_ap_dm" && grep -qF 'Approve this summary, or tell me what to change?' "$_ap_dm" \
  && grep -qF 'Only a yes to the summary as shown approves it.' "$_ap_dm" \
  && grep -qF 'each user story with its ID and its Confirmed date, or `unconfirmed`;' "$_ap_dm" \
  && grep -qF 'the research notes and `R<n>` items.' "$_ap_dm" || wired="$wired design.md(the summary's list)"
grep -qF 'Write everything the approved summary lists and commit it as one change, `docs: <summary>`' "$_ap_dm" \
  && grep -qF 'The approval of the summary is the approval to commit (`rules.md` › Git).' "$_ap_dm" || wired="$wired design.md(Finish)"
[ "$(grep -cF "$_ap_ptr" "$_ap_dm")" -ge 2 ] || wired="$wired design.md(pointers in the validation and the harvest)"
for _ap_f in research.md next-task.md ui-design.md acceptance.md align.md; do
  grep -qF "$_ap_ptr" "$adir/procedures/$_ap_f" || wired="$wired $_ap_f(pointer)"
done
[ "$(grep -cF "$_ap_ptr" "$adir/procedures/drift-reset.md")" -ge 2 ] || wired="$wired drift-reset.md(pointers in the reset and the postmortem)"
grep -qF "$_ap_ptr" "$src/ONBOARDING.md" && grep -q '^### Summary and approval$' "$src/ONBOARDING.md" || wired="$wired ONBOARDING.md(pointer and Summary and approval)"
grep -qF 'Inside a session or onboarding the fixes join its summary.' "$adir/procedures/align.md" || wired="$wired align.md(the fixes join the summary)"
grep -qF 'the decision lines word for word, the design diff' "$adir/procedures/drift-reset.md" && grep -qF 'and each TASKS.md item in full' "$adir/procedures/drift-reset.md" \
  || wired="$wired drift-reset.md(the summary's list)"
grep -qF 'Hold the note and the item in the conversation.' "$adir/procedures/research.md" || wired="$wired research.md(holds the note and the item)"
grep -qF 'the summary lists its records, as `design.md` lists them' "$adir/procedures/next-task.md" || wired="$wired next-task.md(blocked)"
grep -qF 'The summary lists the spec, the decision lines, the open questions and the item.' "$adir/procedures/ui-design.md" || wired="$wired ui-design.md(the summary's list)"
grep -q 'once the human approves a summary of them' "$src/framework/.claude/skills/design/SKILL.md" || wired="$wired skills/design/SKILL.md(description)"
[ -z "$wired" ] && ok "nothing is written until the human approves a summary: the rule, design.md's Summary and approval, and the pointer in each procedure that records from a conversation" \
  || bad "the approval of a summary isn't wired into:$wired"

# Agent permissions: the template's allow rules run without a prompt. A generic code runner with a
# wildcard runs any code, so a prompt-injected page could push or read credentials (the docs repo's
# security assessment, product/security/2026-10-26.md, F1). A rule that names a script under tools/
# passes, with or without a wildcard (`bash tools/check.sh*`, `node tools/ui/capture.mjs *`), and so
# does an exact command (`flutter test`). A runner followed by a wildcard fails (`npm *`,
# `npm run build *`, `python -m *`, `node*`, `bash -c *`), and so does a rule that allows every
# command (`Bash(*)`, or a bare `"Bash"`).
perm_runners='npm|npx|pnpm|yarn|bun|deno|node|flutter|dart|dotnet|python3?|pip3?|pipx|uv|ruby|perl|php|go|cargo|make|sh|bash|zsh|env|xargs'
perm_bad='"Bash\(('"$perm_runners"')( [^ /*()]+)*( ?\*)\)"|"Bash\(:?\*\)"|^ *"Bash",?[[:space:]]*$'
perm_hits() { grep -nE "$perm_bad" "$1" || true; }
if [ ! -f "$settings" ]; then
  bad "the settings template is missing, so the agent's permissions can't be checked"
elif [ -n "$(perm_hits "$settings")" ]; then
  bad "the settings template allows a generic code runner or every command with a wildcard (allow the exact commands instead):" "$(perm_hits "$settings")"
else
  ok "the settings template allows no generic code runner or every command with a wildcard"
fi
# The check is tested on planted rules, so a change that stops it flagging one fails here.
planted=""
for perm_rule in 'Bash(npm *)' 'Bash(npx *)' 'Bash(pnpm *)' 'Bash(yarn *)' 'Bash(flutter *)' 'Bash(python *)' 'Bash(pip *)' \
    'Bash(npm run build *)' 'Bash(python -m *)' 'Bash(node*)' 'Bash(bash -c *)' 'Bash(*)' 'Bash(:*)' 'Bash'; do
  printf '{\n  "permissions": {\n    "allow": [\n      "%s"\n    ]\n  }\n}\n' "$perm_rule" > "$work/permissions-rule.json"
  [ -n "$(perm_hits "$work/permissions-rule.json")" ] || planted="$planted $perm_rule"
done
[ -z "$planted" ] && ok "the permission check flags every generic runner with a wildcard, and every rule for every command" \
  || bad "the permission check doesn't flag:$planted"
cat > "$work/permissions-named.json" << 'EOF'
{
  "permissions": {
    "allow": [
      "Bash(bash tools/check.sh*)",
      "Bash(bash tools/stacks/*.sh*)",
      "Bash(node tools/ui/capture.mjs *)",
      "Bash(flutter test)",
      "WebSearch"
    ]
  }
}
EOF
[ -z "$(perm_hits "$work/permissions-named.json")" ] && ok "the permission check passes the named commands and an exact command" \
  || bad "the permission check flags a named command or an exact one" "$(perm_hits "$work/permissions-named.json")"

# The wildcard git rules take any flag, and some git flags write a file (--output), read a file
# outside the repository (--no-index, commit and tag -F and --file) or run a configured command
# (--ext-diff, grep -O), none of which should run without the human (the docs repo's security
# assessment, product/security/2026-10-29.md, F1; B14). A * in `bash tools/stacks/*.sh*` matches `..`
# too, so a script path can leave tools/. A template that allows a wildcard rule has to carry the deny
# rules for it; the guard hook's tests (below, "guard-commands hook") cover the rest. And the Read tool
# may not open the credential stores (B15): five Read rules, always required, and the .env files that
# hold values (.env.local and the other .env.<suffix> files the guard hook blocks, B21): twelve more,
# each in its plain and **/ form.
deny_needs() { # deny_needs <allow rule pattern> <deny rule>...: the deny rules $deny lacks, when $allow has that rule
  local pattern="$1" rule
  grep -qE "$pattern" <<< "$allow" || return 0
  shift
  for rule in "$@"; do
    case "$deny" in *"\"$rule\""*) ;; *) printf '%s\n' "$rule" ;; esac
  done
}
git_deny_missing() { # git_deny_missing <settings file>: the deny rules it lacks, for each wildcard rule it allows
  local allow deny
  allow="$(sed -n '/"allow": *\[/,/\]/p' "$1")"
  deny="$(sed -n '/"deny": *\[/,/\]/p' "$1")"
  deny_needs '"Bash\(git (diff|log|show|stash|commit) \*\)"' \
    'Bash(git *--output*)' 'Bash(git *--no-index*)' 'Bash(git *--ext-diff*)' 'Bash(git commit *--file*)'
  deny_needs '"Bash\(git grep \*\)"' 'Bash(git grep *--open*)' 'Bash(git grep *-O*)'
  deny_needs '"Bash\(git tag \*\)"' 'Bash(git tag *--file*)'
  deny_needs '"Bash\(bash tools/[^"]*\*' 'Bash(bash tools/*..*)'
}
read_deny_missing() { # read_deny_missing <settings file>: the credential-store and .env Read rules it doesn't deny
  local rule deny
  deny="$(sed -n '/"deny": *\[/,/\]/p' "$1")"
  for rule in 'Read(~/.ssh/**)' 'Read(~/.git-credentials)' 'Read(~/.config/git/credentials)' \
      'Read(~/.config/gh/**)' 'Read(~/AppData/Roaming/GitHub CLI/**)' \
      'Read(.env.local)' 'Read(**/.env.local)' 'Read(.env.*.local)' 'Read(**/.env.*.local)' \
      'Read(.env.development)' 'Read(**/.env.development)' 'Read(.env.production)' 'Read(**/.env.production)' \
      'Read(.env.staging)' 'Read(**/.env.staging)' 'Read(.env.test)' 'Read(**/.env.test)'; do
    case "$deny" in *"\"$rule\""*) ;; *) printf '%s\n' "$rule" ;; esac
  done
}
if [ ! -f "$settings" ]; then
  bad "the settings template is missing, so its git deny rules can't be checked"
elif [ -n "$(git_deny_missing "$settings")" ]; then
  bad "the settings template allows a wildcard rule but doesn't deny these (git flags that write, read or run, and script paths that leave tools/):" "$(git_deny_missing "$settings")"
else
  ok "the settings template denies git's file-writing, file-reading and external-command flags and script paths outside tools/ next to its wildcard rules"
fi
if [ -f "$settings" ] && [ -n "$(read_deny_missing "$settings")" ]; then
  bad "the settings template doesn't deny the Read tool these credential stores (the gh CLI's, git's credentials, ~/.ssh) or the .env files with values:" "$(read_deny_missing "$settings")"
elif [ -f "$settings" ]; then
  ok "the settings template denies the Read tool the gh CLI's, git's and SSH credential stores and the .env files with values"
fi
# The checks are tested on planted settings, so a change that stops them flagging a missing rule fails here.
git_planted=""
printf '{\n  "permissions": {\n    "allow": [\n      "Bash(git diff *)"\n    ],\n    "deny": [\n      "Read(.env)"\n    ]\n  }\n}\n' > "$work/git-deny-none.json"
[ "$(git_deny_missing "$work/git-deny-none.json" | wc -l | tr -d ' ')" = 4 ] || git_planted="$git_planted none"
for git_rule in 'git log' 'git show' 'git stash' 'git commit'; do
  printf '{\n  "permissions": {\n    "allow": [\n      "Bash(%s *)"\n    ],\n    "deny": [\n      "Bash(git *--output*)"\n    ]\n  }\n}\n' \
    "$git_rule" > "$work/git-deny-one.json"
  [ "$(git_deny_missing "$work/git-deny-one.json" | wc -l | tr -d ' ')" = 3 ] || git_planted="$git_planted $git_rule"
done
# git grep needs two deny rules, git tag one, and a `bash tools/` rule with a wildcard one; an exact
# `bash tools/` rule needs none.
for git_case in 'Bash(git grep *)|2' 'Bash(git tag *)|1' 'Bash(bash tools/stacks/*.sh*)|1' 'Bash(bash tools/check.sh*)|1' 'Bash(bash tools/security.sh)|0'; do
  printf '{\n  "permissions": {\n    "allow": [\n      "%s"\n    ],\n    "deny": [\n      "Read(.env)"\n    ]\n  }\n}\n' \
    "${git_case%|*}" > "$work/git-deny-rule.json"
  [ "$(git_deny_missing "$work/git-deny-rule.json" | wc -l | tr -d ' ')" = "${git_case##*|}" ] || git_planted="$git_planted ${git_case%|*}"
done
printf '{\n  "permissions": {\n    "allow": [\n      "Bash(git grep *)",\n      "Bash(git tag *)",\n      "Bash(bash tools/stacks/*.sh*)"\n    ],\n    "deny": [\n      "Bash(git grep *--open*)",\n      "Bash(git grep *-O*)",\n      "Bash(git tag *--file*)",\n      "Bash(bash tools/*..*)"\n    ]\n  }\n}\n' > "$work/git-deny-full.json"
[ -z "$(git_deny_missing "$work/git-deny-full.json")" ] || git_planted="$git_planted full"
printf '{\n  "permissions": {\n    "allow": [\n      "Bash(git status)",\n      "Bash(git add *)"\n    ]\n  }\n}\n' > "$work/git-deny-no-wildcard.json"
[ -z "$(git_deny_missing "$work/git-deny-no-wildcard.json")" ] || git_planted="$git_planted no-wildcard"
[ -z "$git_planted" ] && ok "the git deny check flags each missing deny rule, and passes settings with every deny rule or no wildcard rule" \
  || bad "the git deny check misses a planted case:$git_planted"
read_planted=""
printf '{\n  "permissions": {\n    "deny": [\n      "Read(.env)",\n      "Read(~/.ssh/**)"\n    ]\n  }\n}\n' > "$work/read-deny-some.json"
[ "$(read_deny_missing "$work/read-deny-some.json" | wc -l | tr -d ' ')" = 16 ] || read_planted="$read_planted some"
printf '{\n  "permissions": {\n    "allow": [\n      "WebSearch"\n    ]\n  }\n}\n' > "$work/read-deny-none.json"
[ "$(read_deny_missing "$work/read-deny-none.json" | wc -l | tr -d ' ')" = 17 ] || read_planted="$read_planted none"
printf '{\n  "permissions": {\n    "deny": [\n      "Read(~/.ssh/**)",\n      "Read(~/.git-credentials)",\n      "Read(~/.config/git/credentials)",\n      "Read(~/.config/gh/**)",\n      "Read(~/AppData/Roaming/GitHub CLI/**)"\n    ]\n  }\n}\n' > "$work/read-deny-stores.json"
[ "$(read_deny_missing "$work/read-deny-stores.json" | wc -l | tr -d ' ')" = 12 ] || read_planted="$read_planted stores"
printf '{\n  "permissions": {\n    "deny": [\n      "Read(~/.ssh/**)",\n      "Read(~/.git-credentials)",\n      "Read(~/.config/git/credentials)",\n      "Read(~/.config/gh/**)",\n      "Read(~/AppData/Roaming/GitHub CLI/**)",\n      "Read(.env.local)",\n      "Read(**/.env.local)",\n      "Read(.env.*.local)",\n      "Read(**/.env.*.local)",\n      "Read(.env.development)",\n      "Read(**/.env.development)",\n      "Read(.env.production)",\n      "Read(**/.env.production)",\n      "Read(.env.staging)",\n      "Read(**/.env.staging)",\n      "Read(.env.test)",\n      "Read(**/.env.test)"\n    ]\n  }\n}\n' > "$work/read-deny-all.json"
[ -z "$(read_deny_missing "$work/read-deny-all.json")" ] || read_planted="$read_planted all"
[ -z "$read_planted" ] && ok "the Read deny check flags each missing credential-store and .env rule, and passes settings with all seventeen" \
  || bad "the Read deny check misses a planted case:$read_planted"
# Claude Code reads a hook's timeout in seconds and cancels the hook past it, so the guard's limit is 10 seconds (the guard's
# long file body is timed above), and no hook waits an hour or more. settings.json has no bash key: Claude Code doesn't read
# one, and the Bash tool's limits are the BASH_DEFAULT_TIMEOUT_MS and BASH_MAX_TIMEOUT_MS variables (T45).
hook_timeouts="$(grep -oE '"timeout"[[:space:]]*:[[:space:]]*[0-9]+' "$settings" | grep -oE '[0-9]+$')"
guard_timeout="$(awk '/guard-commands\.sh/ { g = 1 } g && /"timeout"/ { gsub(/[^0-9]/, ""); print; exit }' "$settings")"
timeout_fail=""
[ -n "$hook_timeouts" ] || timeout_fail="$timeout_fail none-found"
for hook_t in $hook_timeouts; do [ "$hook_t" -le 3600 ] || timeout_fail="$timeout_fail $hook_t"; done
[ -n "$guard_timeout" ] && [ "$guard_timeout" -le 10 ] || timeout_fail="$timeout_fail guard=${guard_timeout:-none}"
grep -qE '"bash"[[:space:]]*:' "$settings" && timeout_fail="$timeout_fail bash-key"
[ -z "$timeout_fail" ] && ok "every hook timeout in settings.json is at most 3600 seconds, the guard's at most 10, and the file has no bash key" \
  || bad "settings.json's hook timeouts (seconds: at most 3600, the guard's at most 10) or its bash key are wrong:$timeout_fail"

}

part_release() {
# --- release check hook -------------------------------------------------------------------------
# release-check.sh runs when a session starts and says when the installed version (the manifest's first line) is below the
# latest release tag on GitHub. A throwaway project holds the manifest and the cache, and a stand-in git (first on PATH) records
# each call and answers with the tags a case sets, so no case reaches the network (T308).
echo "release check hook"
rc_hook="$src/framework/.claude/hooks/release-check.sh"
rc_proj="$work/rc-project"; rc_stub="$work/rc-stub"; rc_tstub="$work/rc-tstub"
rc_cache="$rc_proj/.app-director/state/latest-release"
rc_url="https://github.com/Freakling/App-Director.git"
mkdir -p "$rc_proj/.app-director" "$rc_stub" "$rc_tstub"
cat > "$rc_stub/git" <<'EOF'
#!/bin/bash
# a stand-in git: it records each call (the prompt setting and the arguments), then fails when git-fails exists, or prints the tags file
printf '%s|%s\n' "${GIT_TERMINAL_PROMPT:-unset}" "$*" >> "$RC_STUB/calls"
[ -e "$RC_STUB/git-fails" ] && exit 128
while IFS= read -r line; do printf '%s\n' "$line"; done < "$RC_STUB/tags"
exit 0
EOF
cat > "$rc_tstub/timeout" <<'EOF'
#!/bin/bash
# a stand-in timeout: it records its limit and runs the command
printf '%s\n' "$1" >> "$RC_STUB/timeouts"
shift
exec "$@"
EOF
chmod +x "$rc_stub/git" "$rc_tstub/timeout"
unset APP_DIRECTOR_RELEASE_CHECK
export CLAUDE_PROJECT_DIR="$rc_proj" RC_STUB="$rc_stub"
rc_sha="0123456789abcdef0123456789abcdef01234567"
rc_set() { # rc_set <manifest first line> [tag…]: a project at that version, no cache, and a git that lists these tags
  local t
  rm -rf "$rc_proj/.app-director/state" "$rc_stub/calls" "$rc_stub/timeouts" "$rc_stub/git-fails"
  printf '%s\n# source %s\n%s\t.claude/settings.json\n' "$1" "$rc_sha" "$rc_sha" > "$rc_proj/.app-director/manifest"
  shift
  : > "$rc_stub/tags"
  for t in "$@"; do printf '%s\trefs/tags/%s\n' "$rc_sha" "$t" >> "$rc_stub/tags"; done
}
rc_cache_is() { # rc_cache_is <version>: write the cache with that value
  mkdir -p "$rc_proj/.app-director/state"; printf '%s\n' "$1" > "$rc_cache"
}
printf '{"session_id":"s","hook_event_name":"SessionStart","source":"startup"}' > "$work/rc-input"
rc_run() { # the hook's output, stdout and stderr together; its exit status is the hook's. Always called in $(...).
  PATH="$rc_stub:$PATH" exec bash "$rc_hook" < "$work/rc-input" 2>&1
}
rc_calls() { # how many times git was called
  local n=0 l
  [ -f "$rc_stub/calls" ] && while IFS= read -r l; do n=$((n + 1)); done < "$rc_stub/calls"
  echo "$n"
}
rc_json() { # rc_json <installed> <latest>: the line the hook prints
  local t="App Director $1 is installed, and the latest release is $2. Ask the agent to upgrade it when it suits you."
  printf '{"systemMessage":"%s","hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s Tell the human this once, in your first reply."}}' "$t" "$t"
}

# 1. Behind the latest release: it warns, with the text for the human and for Claude in one line of JSON, and looks the tags up once.
rc_set "# app-director 1.14.0" v1.13.0 v1.15.0 v1.14.0
out="$(rc_run)"; status=$?
expect_status "a project behind the latest release: the hook exits 0" 0 "$status" "$out"
[ "$out" = "$(rc_json 1.14.0 1.15.0)" ] && ok "and prints one line of JSON with the message for the human and the same text and the instruction for Claude" \
  || bad "and prints one line of JSON with the message for the human and the same text and the instruction for Claude" "$out"
if command -v node >/dev/null 2>&1; then
  RC_OUT="$out" node -e 'const o = JSON.parse(process.env.RC_OUT); const h = o.hookSpecificOutput; if (typeof o.systemMessage !== "string" || h.hookEventName !== "SessionStart" || h.additionalContext.indexOf(o.systemMessage) !== 0) process.exit(1);' \
    && ok "and the line parses as JSON: systemMessage for the human, additionalContext for Claude" || bad "and the line parses as JSON: systemMessage for the human, additionalContext for Claude" "$out"
else
  echo "  skip  the line parses as JSON (node not found)"
fi
[ "$(rc_calls)" = "1" ] && [ "$(<"$rc_stub/calls")" = "0|ls-remote --tags --refs $rc_url refs/tags/v*" ] \
  && ok "it asked git once, for the release tags only, with the terminal prompt off" || bad "it asked git once, for the release tags only, with the terminal prompt off" "$(<"$rc_stub/calls")"
[ "$(<"$rc_cache")" = "1.15.0" ] && ok "and kept the highest version in .app-director/state/latest-release" || bad "and kept the highest version in .app-director/state/latest-release" "$(<"$rc_cache")"
rc_set "# app-director 1.9.0" v1.14.0 v1.9.0
out="$(rc_run)"; [ "$out" = "$(rc_json 1.9.0 1.14.0)" ] && ok "1.9.0 is below 1.14.0: versions compare field by field as numbers" || bad "1.9.0 is below 1.14.0: versions compare field by field as numbers" "$out"
rc_set "# app-director 1.14.0" v1.9.0
out="$(rc_run)"; status=$?
[ -z "$out" ] && [ "$status" -eq 0 ] && ok "and 1.14.0 is not below 1.9.0" || bad "and 1.14.0 is not below 1.9.0" "$out"
rc_set "# app-director 9.9.9" v10.0.0
out="$(rc_run)"; [ "$out" = "$(rc_json 9.9.9 10.0.0)" ] && ok "9.9.9 is below 10.0.0" || bad "9.9.9 is below 10.0.0" "$out"

# 2. Up to date, ahead, and nothing found: silent.
rc_set "# app-director 1.15.0" v1.14.0 v1.15.0
out="$(rc_run)"; status=$?
[ -z "$out" ] && [ "$status" -eq 0 ] && ok "the latest release installed: nothing is printed" || bad "the latest release installed: nothing is printed" "$out"
rc_set "# app-director 1.16.0" v1.15.0
out="$(rc_run)"; status=$?
[ -z "$out" ] && [ "$status" -eq 0 ] && ok "a newer install than the latest tag: nothing is printed" || bad "a newer install than the latest tag: nothing is printed" "$out"
rc_set "# app-director 1.14.0"
out="$(rc_run)"; status=$?
[ -z "$out" ] && [ "$status" -eq 0 ] && ok "a lookup that finds no tag: nothing is printed" || bad "a lookup that finds no tag: nothing is printed" "$out"

# 3. A development snapshot's ' + unreleased (...)' tail is read as its version, and a CRLF manifest as the same one.
rc_set "# app-director 1.14.0 + unreleased (abc1234)" v1.15.0
out="$(rc_run)"; [ "$out" = "$(rc_json 1.14.0 1.15.0)" ] && ok "a manifest saying '1.14.0 + unreleased (abc1234)' is read as 1.14.0" || bad "a manifest saying '1.14.0 + unreleased (abc1234)' is read as 1.14.0" "$out"
rc_set "# app-director 1.14.0 + unreleased" v1.14.0
out="$(rc_run)"; [ -z "$out" ] && ok "and a snapshot of the latest release is up to date" || bad "and a snapshot of the latest release is up to date" "$out"
rc_set "# app-director 1.14.0" v1.15.0
printf '# app-director 1.14.0\r\n# source %s\r\n' "$rc_sha" > "$rc_proj/.app-director/manifest"
out="$(rc_run)"; [ "$out" = "$(rc_json 1.14.0 1.15.0)" ] && ok "a manifest with CRLF line endings is read too" || bad "a manifest with CRLF line endings is read too" "$out"

# 4. The cache: a fresh one is used without git, a day-old one is refreshed once, and the day's next start doesn't ask again.
rc_set "# app-director 1.14.0" v1.16.0
rc_cache_is 1.15.0
out="$(rc_run)"; status=$?
[ "$out" = "$(rc_json 1.14.0 1.15.0)" ] && [ "$(rc_calls)" = "0" ] && [ "$status" -eq 0 ] && ok "a fresh cache is used and git isn't called" || bad "a fresh cache is used and git isn't called" "$out"
touch -t 202001010000 "$rc_cache"
out="$(rc_run)"
[ "$out" = "$(rc_json 1.14.0 1.16.0)" ] && [ "$(rc_calls)" = "1" ] && [ "$(<"$rc_cache")" = "1.16.0" ] \
  && ok "a cache a day old calls git once and takes the new value" || bad "a cache a day old calls git once and takes the new value" "calls $(rc_calls): $out"
out="$(rc_run)"; [ "$out" = "$(rc_json 1.14.0 1.16.0)" ] && [ "$(rc_calls)" = "1" ] && ok "and the next start the same day doesn't call it again" || bad "and the next start the same day doesn't call it again" "calls $(rc_calls): $out"
rc_set "# app-director 1.14.0" v1.16.0
rc_cache_is "not a version"
out="$(rc_run)"; status=$?
[ -z "$out" ] && [ "$status" -eq 0 ] && [ "$(rc_calls)" = "0" ] && ok "a cache that doesn't hold a version is silent until it is a day old" || bad "a cache that doesn't hold a version is silent until it is a day old" "$out"

# 5. A lookup that fails: nothing printed, exit 0, and the day's one try is spent; an old value is kept.
rc_set "# app-director 1.14.0" v1.16.0
: > "$rc_stub/git-fails"
out="$(rc_run)"; status=$?
[ -z "$out" ] && [ "$status" -eq 0 ] && [ "$(rc_calls)" = "1" ] && [ -f "$rc_cache" ] && [ ! -s "$rc_cache" ] \
  && ok "a failed git prints nothing, exits 0 and leaves an empty cache" || bad "a failed git prints nothing, exits 0 and leaves an empty cache" "exit $status, calls $(rc_calls): $out"
out="$(rc_run)"; status=$?
[ -z "$out" ] && [ "$status" -eq 0 ] && [ "$(rc_calls)" = "1" ] && ok "and doesn't call git again that day" || bad "and doesn't call git again that day" "exit $status, calls $(rc_calls): $out"
rc_set "# app-director 1.14.0" v1.16.0
: > "$rc_stub/git-fails"
rc_cache_is 1.15.0; touch -t 202001010000 "$rc_cache"
out="$(rc_run)"; status=$?
[ "$out" = "$(rc_json 1.14.0 1.15.0)" ] && [ "$status" -eq 0 ] && [ "$(rc_calls)" = "1" ] && [ "$(<"$rc_cache")" = "1.15.0" ] \
  && ok "a failed refresh keeps the old value, and still warns by it" || bad "a failed refresh keeps the old value, and still warns by it" "exit $status, calls $(rc_calls): $out"
out="$(rc_run)"; [ "$out" = "$(rc_json 1.14.0 1.15.0)" ] && [ "$(rc_calls)" = "1" ] && ok "and the old value's day starts again, so git isn't called a second time that day" || bad "and the old value's day starts again, so git isn't called a second time that day" "calls $(rc_calls): $out"
rc_set "# app-director 1.14.0" v1.16.0
out="$(printf '{}' | PATH="/nonexistent" "$BASH" "$rc_hook" 2>&1)"; status=$?
[ -z "$out" ] && [ "$status" -eq 0 ] && ok "a PATH with no git at all prints nothing and exits 0" || bad "a PATH with no git at all prints nothing and exits 0" "exit $status: $out"

# 6. Only v<major>.<minor>.<patch> tags count.
rc_set "# app-director 1.14.0" v2.0.0-rc1 latest v1.15.0 v5.0.0-beta v1.16 v1.16.0.1 v1.17.0-rc1 nightly/v9.9.9 V9.0.0
out="$(rc_run)"
[ "$out" = "$(rc_json 1.14.0 1.15.0)" ] && [ "$(<"$rc_cache")" = "1.15.0" ] && ok "tags of any other shape (-rc1, a name, two or four fields, a prefix, a capital V) are ignored" \
  || bad "tags of any other shape (-rc1, a name, two or four fields, a prefix, a capital V) are ignored" "$out"
rc_set "# app-director 1.14.0" v2.0.0-rc1 latest
out="$(rc_run)"; status=$?
[ -z "$out" ] && [ "$status" -eq 0 ] && [ ! -s "$rc_cache" ] && ok "and with only such tags nothing is printed" || bad "and with only such tags nothing is printed" "$out"
rc_set "# app-director 1.14.0" v08.09.0
out="$(rc_run)"; status=$?
[ "$out" = "$(rc_json 1.14.0 8.9.0)" ] && [ "$status" -eq 0 ] && ok "a field with a leading zero is a decimal number, not an octal one" || bad "a field with a leading zero is a decimal number, not an octal one" "exit $status: $out"

# 7. The time limit: 5 seconds when timeout exists, and the lookup still runs without it.
rc_set "# app-director 1.14.0" v1.15.0
out="$(printf '{}' | PATH="$rc_tstub:$rc_stub:$PATH" bash "$rc_hook" 2>&1)"
[ "$out" = "$(rc_json 1.14.0 1.15.0)" ] && [ "$(<"$rc_stub/timeouts")" = "5" ] && ok "the lookup runs under timeout 5 when timeout exists" || bad "the lookup runs under timeout 5 when timeout exists" "$out"
rc_set "# app-director 1.14.0" v1.15.0
out="$(printf '{}' | PATH="$rc_stub:/nonexistent" "$BASH" "$rc_hook" 2>&1)"
[ "$out" = "$(rc_json 1.14.0 1.15.0)" ] && [ "$(rc_calls)" = "1" ] && [ ! -e "$rc_stub/timeouts" ] && ok "and without timeout on PATH it still looks the tags up" || bad "and without timeout on PATH it still looks the tags up" "calls $(rc_calls): $out"

# 8. Off, and nothing to compare: silent, and git is never called.
rc_set "# app-director 1.14.0" v1.15.0
out="$(printf '{}' | APP_DIRECTOR_RELEASE_CHECK=0 PATH="$rc_stub:$PATH" bash "$rc_hook" 2>&1)"; status=$?
[ -z "$out" ] && [ "$status" -eq 0 ] && [ "$(rc_calls)" = "0" ] && [ ! -e "$rc_cache" ] && ok "APP_DIRECTOR_RELEASE_CHECK=0 turns the hook off: nothing printed, git not called" || bad "APP_DIRECTOR_RELEASE_CHECK=0 turns the hook off" "exit $status: $out"
rc_set "# app-director 1.14.0" v1.15.0
rm -f "$rc_proj/.app-director/manifest"
out="$(rc_run)"; status=$?
[ -z "$out" ] && [ "$status" -eq 0 ] && [ "$(rc_calls)" = "0" ] && ok "a project with no manifest: nothing printed, git not called" || bad "a project with no manifest: nothing printed, git not called" "exit $status: $out"
printf '# source %s\n%s\t.claude/settings.json\n' "$rc_sha" "$rc_sha" > "$rc_proj/.app-director/manifest"
out="$(rc_run)"; status=$?
[ -z "$out" ] && [ "$status" -eq 0 ] && [ "$(rc_calls)" = "0" ] && ok "a manifest with no version line: nothing printed, git not called" || bad "a manifest with no version line: nothing printed, git not called" "exit $status: $out"
rc_set "# app-director 1.x" v1.15.0
out="$(rc_run)"; status=$?
[ -z "$out" ] && [ "$status" -eq 0 ] && [ "$(rc_calls)" = "0" ] && ok "and one whose version isn't three numbers" || bad "and one whose version isn't three numbers" "exit $status: $out"
out="$(printf '{}' | CLAUDE_PROJECT_DIR="$work/no-such-folder" PATH="$rc_stub:$PATH" bash "$rc_hook" 2>&1)"; status=$?
[ -z "$out" ] && [ "$status" -eq 0 ] && ok "a project folder that doesn't exist: nothing printed, exit 0" || bad "a project folder that doesn't exist: nothing printed, exit 0" "exit $status: $out"

# 9. The project check never runs it, so a warning can't fail tools/check.sh; settings.json runs it at session start only.
if ! grep -rq 'release-check' "$src/framework/tools" "$src/framework/.githooks" "$src/framework/.app-director"; then ok "the project check and the git hooks don't run the release check, so a warning never fails tools/check.sh"
else bad "the project check and the git hooks don't run the release check" "$(grep -rn 'release-check' "$src/framework/tools" "$src/framework/.githooks" "$src/framework/.app-director")"; fi
rc_wiring="$(awk '/^    "[A-Za-z]+": \[/ { ev = $1; gsub(/[":]/, "", ev) } /"matcher"/ { split($0, a, "\""); m = a[4] }
  /release-check\.sh/ { hit = ev ";" m; next } hit != "" && /"timeout"/ { t = $2; gsub(/[^0-9]/, "", t); print hit ";" t; hit = "" }' "$settings")"
[ "$rc_wiring" = "SessionStart;startup|resume;10" ] && ok "settings.json runs the release check at SessionStart, on startup and resume, with a timeout of 10 seconds" \
  || bad "settings.json runs the release check at SessionStart, on startup and resume, with a timeout of 10 seconds" "$rc_wiring"
rc_bash4=$(grep -nE '^[^#]*(\$\{[A-Za-z_0-9]+(\[[^]]*\])?(,,|\^\^)\}|(declare|local|typeset) +-[a-zA-Z]*A|(^|[;&| ])(mapfile|readarray) +|(^|[;&| ])coproc +[A-Za-z]|[[:space:]]\|&[[:space:]]|\$\{[A-Za-z_0-9@*]+(\[[^]]*\])?: -[0-9]|stat +-c|date +-d|sed +-i|readlink +-f|-printf|-delete)' \
  "$rc_hook" || true)
if [ -z "$rc_bash4" ]; then ok "the release check uses no bash 4 form and no GNU-only tool flag"; else bad "the release check uses no bash 4 form and no GNU-only tool flag" "$rc_bash4"; fi

}

part_orphans() {
# --- orphan report hook -------------------------------------------------------------------------
# orphan-report.sh runs when a session starts and lists the Python, node, shell, Godot and headless browser processes that are
# an hour old or more and whose parent is gone. Stand-ins first on PATH answer for the process list (powershell.exe on Windows, ps
# elsewhere, and uname to choose between them), and others stand in for every program that stops a process, so no case reads this
# machine's own processes or could stop one (T310).
echo "orphan report hook"
or_hook="$src/framework/.claude/hooks/orphan-report.sh"
or_stub="$work/or-stub"; or_tstub="$work/or-tstub"; or_t124="$work/or-t124"; or_bare="$work/or-bare"; or_cwd="$work/or-cwd"
mkdir -p "$or_stub" "$or_tstub" "$or_t124" "$or_bare" "$or_cwd"
cat > "$or_stub/uname" <<'EOF'
#!/bin/bash
# a stand-in uname: the system a case sets in uname-is, Linux when it sets none
if [ -f "$OR_STUB/uname-is" ]; then IFS= read -r line < "$OR_STUB/uname-is"; echo "$line"; else echo Linux; fi
EOF
cat > "$or_stub/ps" <<'EOF'
#!/bin/bash
# a stand-in ps: it records its arguments, then fails when ps-fails exists, or prints the rows a case sets
printf '%s\n' "$*" >> "$OR_STUB/ps-calls"
[ -e "$OR_STUB/ps-fails" ] && exit 1
while IFS= read -r line; do printf '%s\n' "$line"; done < "$OR_STUB/ps-rows"
EOF
cat > "$or_stub/powershell.exe" <<'EOF'
#!/bin/bash
# a stand-in powershell.exe: it records its arguments, then fails when pwsh-fails exists, or prints the rows a case sets, with PowerShell's line ends
printf '%s\n' "$*" >> "$OR_STUB/pwsh-calls"
[ -e "$OR_STUB/pwsh-fails" ] && exit 1
while IFS= read -r line; do printf '%s\r\n' "$line"; done < "$OR_STUB/win-rows"
EOF
cat > "$or_stub/kill" <<'EOF'
#!/bin/bash
# a stand-in for a program that stops a process: it records the call, and no case should make one
printf '%s %s\n' "${0##*/}" "$*" >> "$OR_STUB/killed"
EOF
cp "$or_stub/kill" "$or_stub/taskkill"; cp "$or_stub/kill" "$or_stub/taskkill.exe"; cp "$or_stub/kill" "$or_stub/pkill"; cp "$or_stub/kill" "$or_stub/killall"
cat > "$or_tstub/timeout" <<'EOF'
#!/bin/bash
# a stand-in timeout: it records its limit and runs the command
printf '%s\n' "$1" >> "$OR_STUB/timeouts"
shift
exec "$@"
EOF
cat > "$or_t124/timeout" <<'EOF'
#!/bin/bash
# a stand-in timeout that runs out: the command runs, then the status is 124, as when the limit ends it
shift
"$@"
exit 124
EOF
cat > "$or_bare/uname" <<'EOF'
#!/bin/bash
echo MINGW64_NT-10.0-26300
EOF
chmod +x "$or_stub"/* "$or_tstub/timeout" "$or_t124/timeout" "$or_bare/uname"
# The builtin kill is no program on PATH, so a function stands in for it, exported to reach the hook's own bash.
kill() { printf 'kill %s\n' "$*" >> "$OR_STUB/killed"; }
export -f kill
unset APP_DIRECTOR_ORPHAN_REPORT
export OR_STUB="$or_stub"
or_ask="Tell the human this once, in your first reply, and don't stop them unless the human asks."
or_set() { # or_set <win|ps> [<pid> <ppid> <age in seconds> <name>]…: that machine, with these processes, in the shape of its list
  local shape="$1" f d h m s
  shift
  rm -f "$or_stub/ps-calls" "$or_stub/pwsh-calls" "$or_stub/ps-fails" "$or_stub/pwsh-fails" "$or_stub/timeouts" "$or_stub/uname-is" "$or_stub/ps-rows" "$or_stub/win-rows"
  if [ "$shape" = win ]; then echo MINGW64_NT-10.0-26300 > "$or_stub/uname-is"; f="$or_stub/win-rows"; else f="$or_stub/ps-rows"; fi
  : > "$f"
  while [ "$#" -ge 4 ]; do
    if [ "$shape" = win ]; then
      printf '%s %s %s %s\n' "$1" "$2" "$3" "$4" >> "$f"
    else   # etime as ps writes it: dd-hh:mm:ss, hh:mm:ss or mm:ss
      d=$(($3 / 86400)); h=$(($3 % 86400 / 3600)); m=$(($3 % 3600 / 60)); s=$(($3 % 60))
      if [ "$d" -gt 0 ]; then printf '%6s %5s %d-%02d:%02d:%02d %s\n' "$1" "$2" "$d" "$h" "$m" "$s" "$4" >> "$f"
      elif [ "$h" -gt 0 ]; then printf '%6s %5s %02d:%02d:%02d %s\n' "$1" "$2" "$h" "$m" "$s" "$4" >> "$f"
      else printf '%6s %5s %02d:%02d %s\n' "$1" "$2" "$m" "$s" "$4" >> "$f"; fi
    fi
    shift 4
  done
}
or_raw() { # or_raw <win|ps> <line>…: that machine, with these lines as its list, as given
  local shape="$1" f l
  or_set "$shape"
  shift
  if [ "$shape" = win ]; then f="$or_stub/win-rows"; else f="$or_stub/ps-rows"; fi
  for l in "$@"; do printf '%s\n' "$l" >> "$f"; done
}
printf '{"session_id":"s","hook_event_name":"SessionStart","source":"startup"}' > "$work/or-input"
or_run() { # the hook's output, stdout and stderr together; its exit status is the hook's. Always called in $(...).
  PATH="$or_stub:$PATH" exec bash "$or_hook" < "$work/or-input" 2>&1
}
or_json() { # or_json <list>: the line the hook prints for this list
  local t="Processes that outlived the shell that started them (parent gone, over an hour old): $1. They may be left over from an ended session. Stopping them is your call."
  printf '{"systemMessage":"%s","hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s %s"}}' "$t" "$t" "$or_ask"
}
or_expect() { # or_expect <what> [<list>]: the process list was read, the hook exits 0 and prints the line for this list, or nothing without one
  local out status read_it=no
  out="$(or_run)"; status=$?
  { [ -e "$or_stub/ps-calls" ] || [ -e "$or_stub/pwsh-calls" ]; } && read_it=yes
  if [ -z "${2:-}" ]; then
    [ -z "$out" ] && [ "$status" -eq 0 ] && [ "$read_it" = yes ] && ok "$1" || bad "$1" "exit $status, list read: $read_it: $out"
  else
    [ "$out" = "$(or_json "$2")" ] && [ "$status" -eq 0 ] && [ "$read_it" = yes ] && ok "$1" || bad "$1" "exit $status, list read: $read_it: $out"
  fi
}

# 0. The stand-ins are in place: the stop programs are first on PATH, and the builtin kill is a function in the hook's own bash.
if [ "$(PATH="$or_stub:$PATH" type -P taskkill)" = "$or_stub/taskkill" ] && [ "$(PATH="$or_stub:$PATH" type -P pkill)" = "$or_stub/pkill" ] && [ "$(bash -c 'type -t kill')" = function ]; then
  ok "stand-ins for kill, taskkill and pkill are in place before every case"
else bad "stand-ins for kill, taskkill and pkill are in place before every case" "$(PATH="$or_stub:$PATH" type -P taskkill) $(bash -c 'type -t kill')"; fi

# 1. The cases that read the same on both machines, with the rows in the shape of each one's list.
or_cases() { # or_cases <win|ps> <label>
  local sh="$1" lb="$2" x="" X="" odd good
  if [ "$sh" = win ]; then x=".exe"; X=".EXE"; fi
  or_set "$sh" 4 0 900000 System 500 999 3600 "python3.13$x"
  or_expect "$lb: an hour-old python3.13 with a dead parent is listed" "pid 500 python3.13 (1 h)"
  or_set "$sh" 600 700 7200 "python3.13$x" 700 4 9000 "explorer$x"
  or_expect "$lb: a process with a live parent isn't" ""
  or_set "$sh" 500 999 3540 "python3.13$x" 501 999 3599 "node$x"
  or_expect "$lb: processes 59 minutes old aren't" ""
  or_set "$sh" 500 600 7200 "node$x" 600 4 100 "cmd$x"
  or_expect "$lb: a process whose parent row is younger is listed (a reused pid)" "pid 500 node (2 h)"
  or_set "$sh" 500 600 7200 "node$x" 600 4 7200 "cmd$x"
  or_expect "$lb: and one whose parent is as old is not" ""
  or_set "$sh" 40 999 7200 "notepad$x" 41 999 7200 "sshd$x" 42 999 7200 "nodejs$x" 43 999 7200 "bashful$x" 44 999 7200 "pythonista$x" 45 999 7200 "python3.x$x" 46 999 7200 "pyw$x" 47 999 7200 "shell$x" 48 999 7200 "godo$x" 49 999 7200 "chrome-headless-shells$x"
  or_expect "$lb: names that aren't on the list (notepad, sshd, nodejs, bashful, python3.x, godo...) aren't listed" ""
  or_set "$sh" 25 999 37000 "pythonw$x" 30 999 32000 "Godot_v4.7.2-stable_win64_console$x" 21 999 41000 "python$x" 28 999 34000 "bash$x" 22 999 40000 "python3$x" 26 999 36000 "py$x" 24 999 38000 "PYTHON3.13$X" 29 999 33000 "sh$x" 23 999 39000 "python3.9$x" 27 999 35000 "node$x"
  or_ten="pid 21 python (11 h), pid 22 python3 (11 h), pid 23 python3.9 (10 h), pid 24 PYTHON3.13 (10 h), pid 25 pythonw (10 h), pid 26 py (10 h), pid 27 node (9 h), pid 28 bash (9 h), pid 29 sh (9 h), pid 30 Godot_v4.7.2-stable_win64_console (8 h)"
  or_expect "$lb: python, python3, python3.<n>, pythonw, py, node, bash, sh and godot*, in any case, are listed, oldest first" "$or_ten"
  or_set "$sh" 31 999 31000 "chrome-headless-shell$x" 25 999 37000 "pythonw$x" 30 999 32000 "Godot_v4.7.2-stable_win64_console$x" 21 999 41000 "python$x" 28 999 34000 "bash$x" 22 999 40000 "python3$x" 26 999 36000 "py$x" 24 999 38000 "PYTHON3.13$X" 29 999 33000 "sh$x" 23 999 39000 "python3.9$x" 27 999 35000 "node$x"
  or_expect "$lb: eleven orphans print the oldest ten and 'and 1 more' (a headless browser is on the list)" "$or_ten, and 1 more"
  or_set "$sh" 31 999 31000 "chrome-headless-shell$x" 32 999 30000 "node$x" 33 999 29000 "node$x" 25 999 37000 "pythonw$x" 30 999 32000 "Godot_v4.7.2-stable_win64_console$x" 21 999 41000 "python$x" 28 999 34000 "bash$x" 22 999 40000 "python3$x" 26 999 36000 "py$x" 24 999 38000 "PYTHON3.13$X" 29 999 33000 "sh$x" 23 999 39000 "python3.9$x" 27 999 35000 "node$x"
  or_expect "$lb: thirteen print ten and 'and 3 more'" "$or_ten, and 3 more"
  or_set "$sh" 31 999 172801 "node$x" 32 999 172800 "node$x" 33 999 50400 "python3.13$x" 34 999 259200 "node$x" 35 999 7199 "bash$x"
  or_expect "$lb: ages read as hours up to 48 and as days after" "pid 34 node (3 d), pid 31 node (2 d), pid 32 node (48 h), pid 33 python3.13 (14 h), pid 35 bash (1 h)"
  odd='godot "x" \y {z}, $(w) `v` 100%'
  or_set "$sh" 70 999 7200 "$odd$x" 71 999 3700 $'godot\303\276x'"$x"
  or_expect "$lb: a name with quotes, backslashes, braces, a substitution and a percent sign is cut down to [A-Za-z0-9._-], so the JSON holds" "pid 70 godotxyzwv100 (2 h), pid 71 godotx (1 h)"
  if [ "$sh" = win ]; then good="80 999 7200 node.exe"; else good="   80   999 02:00:00 node"; fi
  or_raw "$sh" 'PID PPID ELAPSED COMM' '1 2' 'a b c d' "5 6 -3 node$x" "7 8 9999999999999 node$x" '' "$good"
  or_expect "$lb: rows that aren't pid, ppid, age and name (a header, a short row, words, a negative age) are skipped" "pid 80 node (2 h)"
  or_set "$sh"
  or_expect "$lb: an empty list prints nothing" ""
  or_set "$sh" 500 999 7200 "node$x"
  if [ "$sh" = win ]; then : > "$or_stub/pwsh-fails"; else : > "$or_stub/ps-fails"; fi
  or_expect "$lb: a process tool that fails prints nothing and exits 0" ""
  or_set "$sh" 500 999 7200 "node$x"
  out="$(printf '{}' | APP_DIRECTOR_ORPHAN_REPORT=0 PATH="$or_stub:$PATH" bash "$or_hook" 2>&1)"; status=$?
  if [ -z "$out" ] && [ "$status" -eq 0 ] && [ ! -e "$or_stub/ps-calls" ] && [ ! -e "$or_stub/pwsh-calls" ]; then ok "$lb: APP_DIRECTOR_ORPHAN_REPORT=0 turns the hook off: nothing printed, the process list not read"
  else bad "$lb: APP_DIRECTOR_ORPHAN_REPORT=0 turns the hook off" "exit $status: $out"; fi
}
or_cases win "Windows list"
or_cases ps "ps list"

# 2. Windows: PowerShell is asked for the processes, under timeout 8 when timeout exists, and the list's own shape is read.
or_set win 500 999 7200 node.exe
out="$(or_run)"
case "$(<"$or_stub/pwsh-calls")" in
  "-NoProfile -NonInteractive -Command "*"Get-CimInstance Win32_Process"*"CreationDate"*) ok "Windows: PowerShell runs with -NoProfile -NonInteractive -Command, and asks Get-CimInstance Win32_Process for each CreationDate" ;;
  *) bad "Windows: PowerShell runs with -NoProfile -NonInteractive -Command, and asks Get-CimInstance Win32_Process for each CreationDate" "$(<"$or_stub/pwsh-calls")" ;;
esac
case "$(<"$or_stub/pwsh-calls")" in
  *'if($_.CreationDate)'*) ok "and skips a process that has no CreationDate" ;;
  *) bad "and skips a process that has no CreationDate" "$(<"$or_stub/pwsh-calls")" ;;
esac
[ ! -e "$or_stub/ps-calls" ] && ok "and ps isn't run" || bad "and ps isn't run" "$(<"$or_stub/ps-calls")"
or_set win 500 999 7200 node.exe
out="$(printf '{}' | PATH="$or_tstub:$or_stub:$PATH" bash "$or_hook" 2>&1)"
[ "$out" = "$(or_json 'pid 500 node (2 h)')" ] && [ "$(<"$or_stub/timeouts")" = "8" ] && [ -e "$or_stub/pwsh-calls" ] && ok "the PowerShell run is under timeout 8 when timeout exists" || bad "the PowerShell run is under timeout 8 when timeout exists" "$out"
or_set win 500 999 7200 node.exe
out="$(printf '{}' | PATH="$or_stub:/nonexistent" "$BASH" "$or_hook" 2>&1)"
[ "$out" = "$(or_json 'pid 500 node (2 h)')" ] && [ ! -e "$or_stub/timeouts" ] && ok "and without timeout on PATH it still asks" || bad "and without timeout on PATH it still asks" "$out"
or_set win 500 999 7200 node.exe
out="$(printf '{}' | PATH="$or_t124:$or_stub:$PATH" bash "$or_hook" 2>&1)"; status=$?
[ -z "$out" ] && [ "$status" -eq 0 ] && [ -e "$or_stub/pwsh-calls" ] && ok "a PowerShell run that times out (status 124) prints nothing, even with rows read, and exits 0" || bad "a PowerShell run that times out prints nothing" "exit $status: $out"
out="$(printf '{}' | PATH="$or_bare" "$BASH" "$or_hook" 2>&1)"; status=$?
[ -z "$out" ] && [ "$status" -eq 0 ] && ok "a Windows machine with no PowerShell prints nothing and exits 0" || bad "a Windows machine with no PowerShell prints nothing and exits 0" "exit $status: $out"
or_set win 600 0 7200 node.exe
or_expect "Windows: a ppid of 0 is a gone parent" "pid 600 node (2 h)"
for or_sys in MSYS_NT-10.0-26200 CYGWIN_NT-10.0-19045; do
  or_set win 500 999 7200 node.exe
  echo "$or_sys" > "$or_stub/uname-is"
  or_expect "$or_sys is a Windows machine too" "pid 500 node (2 h)"
done

# 3. Elsewhere: ps -A -o pid=,ppid=,etime=,comm=, with etime read from [[dd-]hh:]mm:ss and comm cut to its base name.
or_set ps 500 999 7200 node
out="$(printf '{}' | PATH="$or_tstub:$or_stub:$PATH" bash "$or_hook" 2>&1)"
[ "$out" = "$(or_json 'pid 500 node (2 h)')" ] && [ "$(<"$or_stub/ps-calls")" = "-A -o pid=,ppid=,etime=,comm=" ] && [ ! -e "$or_stub/pwsh-calls" ] && [ ! -e "$or_stub/timeouts" ] \
  && ok "elsewhere ps -A -o pid=,ppid=,etime=,comm= is run, with no PowerShell and no timeout" || bad "elsewhere ps -A -o pid=,ppid=,etime=,comm= is run" "$out"
or_raw ps '   11     1 10-00:00:00 node' '   12     1  2-01:00:00 node' '   13     1  1-23:59:59 node' '   14     1  1-08:09:09 node' '   15     1    08:09:09 node' \
  '   16     1    01:08:09 node' '   17     1       60:00 node' '   18     1       59:59 node' '   19     1    00:59:59 node'
or_expect "etime reads right as dd-hh:mm:ss, hh:mm:ss and mm:ss, with zeros that aren't octal (08:09:09), and 59:59 is under the hour" \
  "pid 11 node (10 d), pid 12 node (2 d), pid 13 node (47 h), pid 14 node (32 h), pid 15 node (8 h), pid 16 node (1 h), pid 17 node (1 h)"
or_raw ps '   81     1 05:00:00 /usr/local/bin/node' '   82     1 04:00:00 /Applications/Some App.app/Contents/MacOS/python3.13' '   83     1 03:00:00 chrome-headless' \
  '   84     1 02:00:01 Godot_v4.7-stab' '   85     1 02:00:00 /usr/sbin/sshd'
or_expect "comm is cut to its base name (a path with spaces too), and Linux's 15-character chrome-headless counts" \
  "pid 81 node (5 h), pid 82 python3.13 (4 h), pid 83 chrome-headless (3 h), pid 84 Godot_v4.7-stab (2 h)"
or_raw ps '    1     0 10-00:00:00 launchd' '   90     1 02:00:00 node' '   91     0 02:00:00 sh'
or_expect "a ppid of 1 or 0 is a gone parent, though a row for pid 1 exists and is older" "pid 90 node (2 h), pid 91 sh (2 h)"
or_set ps 500 999 7200 node
out="$(printf '{}' | PATH="/nonexistent" "$BASH" "$or_hook" 2>&1)"; status=$?
[ -z "$out" ] && [ "$status" -eq 0 ] && ok "a machine with no ps (and no uname) prints nothing and exits 0" || bad "a machine with no ps (and no uname) prints nothing and exits 0" "exit $status: $out"
or_set ps 500 999 7200 node
echo Darwin > "$or_stub/uname-is"
or_expect "Darwin reads ps too" "pid 500 node (2 h)"

# 4. It only reads: nothing is stopped, signalled or written.
if [ ! -e "$or_stub/killed" ]; then ok "no case called kill, taskkill, pkill or killall"; else bad "no case called kill, taskkill, pkill or killall" "$(<"$or_stub/killed")"; fi
or_set ps 500 999 7200 node
out="$(cd "$or_cwd" && printf '{}' | PATH="$or_stub:$PATH" bash "$or_hook" 2>&1)"
if [ -n "$out" ] && [ -z "$(ls -A "$or_cwd")" ]; then ok "a run writes no file in the folder it runs in"; else bad "a run writes no file in the folder it runs in" "$(ls -A "$or_cwd")"; fi
or_stops=$(grep -vE '^[[:space:]]*#' "$or_hook" | grep -niE 'kill|Stop-Process|Remove-|Set-|New-Item|Out-File|Add-Content|Invoke-' || true)
if [ -z "$or_stops" ]; then ok "the hook names no command that stops, changes or writes anything"; else bad "the hook names no command that stops, changes or writes anything" "$or_stops"; fi
or_writes=$(grep -vE '^[[:space:]]*#' "$or_hook" | grep '>' | grep -v '/dev/null' || true)
if [ -z "$or_writes" ]; then ok "and redirects its output nowhere but /dev/null"; else bad "and redirects its output nowhere but /dev/null" "$or_writes"; fi
unset -f kill

# 5. The project check never runs it; settings.json runs it at session start with the release check, in one entry.
if ! grep -rq 'orphan-report' "$src/framework/tools" "$src/framework/.githooks" "$src/framework/.app-director"; then ok "the project check and the git hooks don't run the orphan report, so a report never fails tools/check.sh"
else bad "the project check and the git hooks don't run the orphan report" "$(grep -rn 'orphan-report' "$src/framework/tools" "$src/framework/.githooks" "$src/framework/.app-director")"; fi
or_wiring="$(awk '/^    "[A-Za-z]+": \[/ { ev = $1; gsub(/[":]/, "", ev) } /"matcher"/ { split($0, a, "\""); m = a[4] }
  /orphan-report\.sh/ { hit = ev ";" m; next } hit != "" && /"timeout"/ { t = $2; gsub(/[^0-9]/, "", t); print hit ";" t; hit = "" }' "$settings")"
[ "$or_wiring" = "SessionStart;startup|resume;10" ] && ok "settings.json runs the orphan report at SessionStart, on startup and resume, with a timeout of 10 seconds" \
  || bad "settings.json runs the orphan report at SessionStart, on startup and resume, with a timeout of 10 seconds" "$or_wiring"
or_entry="$(awk '/^    "[A-Za-z]+": \[/ { ev = $1; gsub(/[":]/, "", ev) } ev == "SessionStart" && /"matcher"/ { m++ } ev == "SessionStart" && /"command":/ { n++ } END { print m ";" n }' "$settings")"
[ "$or_entry" = "1;2" ] && ok "and in the same entry as the release check: one matcher, two hooks" || bad "and in the same entry as the release check: one matcher, two hooks" "$or_entry"
or_bash4=$(grep -nE '^[^#]*(\$\{[A-Za-z_0-9]+(\[[^]]*\])?(,,|\^\^)\}|(declare|local|typeset) +-[a-zA-Z]*A|(^|[;&| ])(mapfile|readarray) +|(^|[;&| ])coproc +[A-Za-z]|[[:space:]]\|&[[:space:]]|\$\{[A-Za-z_0-9@*]+(\[[^]]*\])?: -[0-9]|stat +-c|date +-d|sed +-i|readlink +-f|-printf|-delete)' \
  "$or_hook" || true)
if [ -z "$or_bash4" ]; then ok "the orphan report uses no bash 4 form and no GNU-only tool flag"; else bad "the orphan report uses no bash 4 form and no GNU-only tool flag" "$or_bash4"; fi
if grep -q 'APP_DIRECTOR_ORPHAN_REPORT=0' "$src/PRIVACY.md" && grep -q 'names, ids and ages of the processes on this machine' "$src/PRIVACY.md" && grep -q 'ended session left behind' "$src/README.md"; then
  ok "PRIVACY.md says the hook reads the names, ids and ages of the processes and names the switch, and the README names the hook"
else bad "PRIVACY.md says the hook reads the names, ids and ages of the processes and names the switch, and the README names the hook"; fi

}

part_main() {
# --- installer ------------------------------------------------------------------------------------
echo "installer"
app="$work/todo-web"
cp -R "$src/examples/todo-web" "$app"
rm -rf "$app/.app-director" "$app/.claude" "$app/.githooks"
(cd "$app" && git init -q && git config core.autocrlf false \
  && git add -A && git_q commit -qm "example") || exit 1
cd "$app" || exit 1

out="$(bash "$src/install.sh" . 2>&1)"; expect_status "installs" 0 $? "$out"
if [ -f .app-director/manifest ] \
    && [ -f .app-director/procedures/next-task.md ] \
    && [ -f .app-director/LICENSE ] \
    && [ -f tools/check.sh ] \
    && [ -f tools/setup-clone.sh ] \
    && [ -f .claude/skills/next-task/SKILL.md ] \
    && [ -f .claude/hooks/guard-commands.sh ]; then
  ok "copies the core and the Claude adapter, and writes the manifest"
else
  bad "copies the core and the Claude adapter, and writes the manifest" "$out"
fi
grep -q "To-Do Web" AGENTS.md && ok "keeps the project's own AGENTS.md" \
  || bad "keeps the project's own AGENTS.md"
if [ -f .app-director/procedures/research.md ] && [ -f .app-director/research-domain.md ] && [ -f .claude/agents/researcher.md ] \
    && [ -f .claude/skills/research/SKILL.md ] && [ -f product/research/README.md ]; then
  ok "installs the research assistant: procedure, domain file, researcher, skill and note folder"
else
  bad "installs the research assistant: procedure, domain file, researcher, skill and note folder" "$out"
fi
if [ -f .app-director/procedures/ui-design.md ] && [ -f .claude/skills/ui-design/SKILL.md ] && [ -x tools/ui_capture.sh ] \
    && [ -f tools/ui/capture.mjs ] && [ -f tools/ui/drawing.mjs ] && [ -f tools/ui/package.json ] && [ -f tools/ui/.npmrc ] \
    && [ -f tools/ui/screens.mjs ] && [ -f tools/ui_capture.cfg ] && [ -f product/ui/README.md ]; then
  ok "installs /ui-design: procedure, skill, capture tools, catalog, settings and the drawing guide"
else
  bad "installs /ui-design: procedure, skill, capture tools, catalog, settings and the drawing guide" "$out"
fi
if [ -f .app-director/procedures/security.md ] && [ -f .app-director/reference/owasp.md ] && [ -f .claude/skills/security/SKILL.md ] \
    && [ -x tools/security.sh ]; then
  ok "installs the security assessment: procedure, OWASP checklist, skill and tools/security.sh"
else
  bad "installs the security assessment: procedure, OWASP checklist, skill and tools/security.sh" "$out"
fi
[ -f .app-director/procedures/prototype.md ] && [ -f .claude/skills/prototype/SKILL.md ] && [ -x tools/prototype.sh ] \
  && [ -x .githooks/pre-push ] \
  && ok "installs prototypes: the procedure, the skill, tools/prototype.sh and the pre-push hook" \
  || bad "installs prototypes: the procedure, the skill, tools/prototype.sh and the pre-push hook" "$out"
[ -x tools/stories.sh ] && cmp -s product/user-stories.md "$src/project/product/user-stories.md" \
  && ok "installs tools/stories.sh and seeds product/user-stories.md" \
  || bad "installs tools/stories.sh and seeds product/user-stories.md" "$out"
grep -qx '/product/ui/captures/' .gitignore && grep -qx '/tools/ui/node_modules/' .gitignore && grep -qx '/tools/ui/.auth/' .gitignore \
  && grep -qx '/tools/ui/\*\* text eol=lf' .gitattributes \
  && ok "ignores captures, the capture tools' packages and saved sign-ins" || bad "the /ui-design .gitignore and .gitattributes lines" "$(cat .gitignore)"
# The personal settings file is ignored, as the README says. `*.local` doesn't reach it (its name ends in .json).
git check-ignore -q .claude/settings.local.json && ok "ignores .claude/settings.local.json, the personal settings file" \
  || bad "ignores .claude/settings.local.json, the personal settings file" "$(cat .gitignore)"
grep -q "$(printf '\t')tools/ui/capture.mjs$" .app-director/manifest && ! grep -q "$(printf '\t')tools/ui/screens.mjs$" .app-director/manifest \
  && ok "the manifest lists the capture tools, not the app's own catalog" || bad "the manifest lists the capture tools, not the app's own catalog"
[ -x .claude/hooks/session-touched.sh ] && grep -q "$(printf '\t').claude/hooks/session-touched.sh$" .app-director/manifest \
  && git check-ignore -q .app-director/state/sessions/design.touched && git check-ignore -q .app-director/state/sessions/design.before \
  && ok "installs the session record hook, and git ignores the records it keeps" || bad "installs the session record hook, and git ignores the records it keeps" "$(cat .gitignore)"
[ -x .claude/hooks/release-check.sh ] && grep -q "$(printf '\t').claude/hooks/release-check.sh$" .app-director/manifest \
  && grep -q 'release-check\.sh' .claude/settings.json && git check-ignore -q .app-director/state/latest-release \
  && ok "installs the release check hook, wires it into settings.json, and git ignores the cache it keeps" \
  || bad "installs the release check hook, wires it into settings.json, and git ignores the cache it keeps" "$(cat .gitignore)"
[ -x .claude/hooks/orphan-report.sh ] && grep -q "$(printf '\t').claude/hooks/orphan-report.sh$" .app-director/manifest \
  && grep -q 'orphan-report\.sh' .claude/settings.json \
  && ok "installs the orphan report hook and wires it into settings.json" \
  || bad "installs the orphan report hook and wires it into settings.json"

out="$(bash "$src/install.sh" . 2>&1)"
expect_output "a second run changes nothing" "0 new, 0 updated" "$out"
adir_lines="$(grep -c '^# App Director$' .gitignore 2>/dev/null || true)"
[ "${adir_lines:-0}" -le 1 ] \
  && ok "no duplicate .gitignore lines after reinstall" \
  || bad "no duplicate .gitignore lines after reinstall"

# Local edit that this version doesn't touch; must be kept as-is.
echo "# my own note" >> .app-director/procedures/prune.md
out="$(bash "$src/install.sh" . 2>&1)"
if grep -q "my own note" .app-director/procedures/prune.md \
    && [ ! -f .app-director/procedures/prune.md.adir-new ]; then
  ok "keeps a local edit when this version doesn't change the file"
else
  bad "keeps a local edit when this version doesn't change the file" "$out"
fi

# Simulate both sides changed; installer must write .adir-new.
awk -F'\t' -v OFS='\t' \
  '$2 == ".app-director/procedures/prune.md" { $1 = "0000000000000000000000000000000000000000" } { print }' \
  .app-director/manifest > "$work/manifest" && cp "$work/manifest" .app-director/manifest
out="$(bash "$src/install.sh" . 2>&1)"
if [ -f .app-director/procedures/prune.md.adir-new ] \
    && grep -q "my own note" .app-director/procedures/prune.md; then
  ok "writes .adir-new when both sides changed a file"
else
  bad "writes .adir-new when both sides changed a file" "$out"
fi
# Restore prune.md to clean state.
cp "$src/framework/.app-director/procedures/prune.md" .app-director/procedures/prune.md
rm -f .app-director/procedures/prune.md.adir-new
awk -F'\t' -v OFS='\t' -v h="$(hash_of .app-director/procedures/prune.md)" \
  '$2 == ".app-director/procedures/prune.md" { $1 = h } { print }' \
  .app-director/manifest > "$work/manifest" && cp "$work/manifest" .app-director/manifest

# An unchanged file from an older install is replaced by the new version.
printf 'old version\n' > .app-director/procedures/align.md
awk -F'\t' -v OFS='\t' -v h="$(hash_of .app-director/procedures/align.md)" \
  '$2 == ".app-director/procedures/align.md" { $1 = h } { print }' \
  .app-director/manifest > "$work/manifest" && cp "$work/manifest" .app-director/manifest
out="$(bash "$src/install.sh" . 2>&1)"
cmp -s .app-director/procedures/align.md "$src/framework/.app-director/procedures/align.md" \
  && ok "replaces a file unchanged since the last install" \
  || bad "replaces a file unchanged since the last install" "$out"

# A file the installer no longer ships is removed when unmodified.
printf 'old stuff\n' > .app-director/retired.md
printf '%s\t.app-director/retired.md\n' "$(hash_of .app-director/retired.md)" \
  >> .app-director/manifest
out="$(bash "$src/install.sh" . 2>&1)"
[ ! -f .app-director/retired.md ] && ok "removes a dropped file" \
  || bad "removes a dropped file" "$out"

# LICENSE copy reaches the installed project.
[ -f .app-director/LICENSE ] && ok "installs the LICENSE copy" \
  || bad "installs the LICENSE copy" "$out"

app_parts
}

# The rest of the installer's cases build their own apps from the source and share nothing with the example app.
part_installer() {
# Installs from a cloned App Director folder and from one inside the app. A clone has no node_modules, and its .git is made here.
adir_clone="$work/adir-clone"; copy_without "$src" "$adir_clone" .git node_modules
(cd "$adir_clone" && git init -q && git config core.autocrlf false \
  && git add -A && git_q commit -qm adir) >/dev/null 2>&1
from_clone="$work/from-clone"; new_repo "$from_clone"
out="$(bash "$adir_clone/install.sh" "$from_clone" 2>&1)"
expect_status "installs from an App Director git clone" 0 $? "$out"
cmp -s "$from_clone/product/director-brief.md" "$src/project/product/director-brief.md" \
  && ok "a new app gets the product brief template" \
  || bad "a new app gets the product brief template" "$out"

# An app installed by the release before the brief template gets it on upgrade. v1.6.0 is that
# release (cloned from this repository); without its tag, the installed template is removed to
# stand for the earlier install.
upgraded="$work/upgraded"; new_repo "$upgraded"
if git -C "$src" rev-parse -q --verify 'v1.6.0^{commit}' >/dev/null 2>&1; then
  old_release="$work/old-release"
  git clone -q --branch v1.6.0 "$src" "$old_release" >/dev/null 2>&1
  bash "$old_release/install.sh" "$upgraded" >/dev/null 2>&1
else
  bash "$src/install.sh" "$upgraded" >/dev/null 2>&1; rm -f "$upgraded/product/director-brief.md"
fi
(cd "$upgraded" && git add -A && git_q commit -qm "install the earlier release" >/dev/null 2>&1)
out="$(bash "$src/install.sh" "$upgraded" 2>&1)"; expect_status "upgrades an app installed before the brief template" 0 $? "$out"
cmp -s "$upgraded/product/director-brief.md" "$src/project/product/director-brief.md" \
  && ok "an upgraded app gets the product brief template" \
  || bad "an upgraded app gets the product brief template" "$out"

# An app whose .gitignore predates the settings line gets it on upgrade, and only once. The line is taken
# out of a fresh install's .gitignore to stand for that app: the source is this same version, so no older
# release is needed. The app's own line sits after a blank line, so the check shows where the App Director
# block ends.
gi_app="$work/gitignore-app"; new_repo "$gi_app"
bash "$src/install.sh" "$gi_app" >/dev/null 2>&1
grep -vxF '/.claude/settings.local.json' "$gi_app/.gitignore" > "$work/gitignore-old" && cp "$work/gitignore-old" "$gi_app/.gitignore"
printf '\ndist/\n' >> "$gi_app/.gitignore"
git -C "$gi_app" check-ignore -q .claude/settings.local.json \
  && bad "the setup removes the settings line from .gitignore" "$(cat "$gi_app/.gitignore")"
out="$(bash "$src/install.sh" "$gi_app" 2>&1)"; expect_status "upgrades an app whose .gitignore lacks the settings line" 0 $? "$out"
git -C "$gi_app" check-ignore -q .claude/settings.local.json \
  && ok "the upgrade adds the settings line, so .claude/settings.local.json is ignored" \
  || bad "the upgrade adds the settings line, so .claude/settings.local.json is ignored" "$(cat "$gi_app/.gitignore")"
[ "$(grep -cxF '/.claude/settings.local.json' "$gi_app/.gitignore")" -eq 1 ] \
  && ok "the settings line is in .gitignore once after the upgrade" \
  || bad "the settings line is in .gitignore once after the upgrade" "$(cat "$gi_app/.gitignore")"
[ "$(grep -cxF '# App Director' "$gi_app/.gitignore")" -eq 1 ] \
  && ok "the upgrade leaves one # App Director heading in .gitignore" \
  || bad "the upgrade leaves one # App Director heading in .gitignore" "$(cat "$gi_app/.gitignore")"
sed -n '/^# App Director$/,/^$/p' "$gi_app/.gitignore" | grep -qxF '/.claude/settings.local.json' \
  && ok "the settings line goes under that heading, before the app's own lines" \
  || bad "the settings line goes under that heading, before the app's own lines" "$(cat "$gi_app/.gitignore")"
# .gitattributes gets its lines the same way, so an upgrade that adds one keeps one heading there too.
grep -vxF '/tools/ui/** text eol=lf' "$gi_app/.gitattributes" > "$work/gitattributes-old" && cp "$work/gitattributes-old" "$gi_app/.gitattributes"
out="$(bash "$src/install.sh" "$gi_app" 2>&1)"; expect_status "upgrades an app whose .gitattributes lacks a line" 0 $? "$out"
[ "$(grep -cxF '/tools/ui/** text eol=lf' "$gi_app/.gitattributes")" -eq 1 ] && [ "$(grep -cxF '# App Director' "$gi_app/.gitattributes")" -eq 1 ] \
  && ok "the upgrade's .gitattributes line goes under the one # App Director heading" \
  || bad "the upgrade's .gitattributes line goes under the one # App Director heading" "$(cat "$gi_app/.gitattributes")"

inside="$work/inside"; new_repo "$inside"
copy_without "$adir_clone" "$inside/App-Director" .git
printf '/App-Director/\n' >> "$inside/.git/info/exclude"
out="$(bash "$inside/App-Director/install.sh" "$inside" 2>&1)"
expect_status "installs from a folder inside the app" 0 $? "$out"

}

part_snapshot() {
# An install from a source with unreleased changes says so. A copy of the installer and its files, in
# a git repository of its own (so the commit is known), with the CHANGELOG given. The copy leaves out
# the rest of this folder (tests, node_modules) to stay quick.
snapshot_source() { # snapshot_source <folder> <CHANGELOG to use>
  rm -rf "$1" && mkdir -p "$1" \
    && cp -R "$src/framework" "$src/project" "$src/install.sh" "$src/VERSION" "$1/" \
    && cp "$2" "$1/CHANGELOG.md" && printf '1.8.0\n' > "$1/VERSION" \
    && (cd "$1" && git init -q && git config core.autocrlf false && git add -A && git_q commit -qm snapshot) >/dev/null 2>&1
}
printf '# Changelog\n\n## Unreleased\n\n- **New: a snapshot entry.**\n\n## 1.8.0 (2026-10-16)\n\n- Earlier.\n' > "$work/changelog-unreleased.md"
printf '# Changelog\n\n## Unreleased\n\n## 1.8.0 (2026-10-16)\n\n- Earlier.\n' > "$work/changelog-empty.md"
printf '# Changelog\n\n## 1.8.0 (2026-10-16)\n\n- Earlier.\n' > "$work/changelog-release.md"

snap="$work/snapshot"
snapshot_source "$snap" "$work/changelog-unreleased.md" || bad "builds a source with unreleased entries"
snap_commit="$(git -C "$snap" rev-parse --short HEAD 2>/dev/null)"
snap_app="$work/snapshot-app"; new_repo "$snap_app"
out="$(bash "$snap/install.sh" "$snap_app" 2>&1)"; expect_status "installs from a source with unreleased entries" 0 $? "$out"
if [ "$(sed -n 1p "$snap_app/.app-director/manifest")" = "# app-director 1.8.0 + unreleased ($snap_commit)" ] \
    && [ "$(sed -n 2p "$snap_app/.app-director/manifest")" = "# source $snap_commit" ]; then
  ok "the manifest says unreleased, with the source commit on its own line"
else
  bad "the manifest says unreleased, with the source commit on its own line" "$(head -n 3 "$snap_app/.app-director/manifest")"
fi
closing="Installed 1.8.0 + unreleased ($snap_commit): a development snapshot, not a release. The latest release is at https://github.com/Freakling/App-Director/releases."
printf '%s\n' "$out" | grep -qxF "$closing" \
  && ok "the closing lines say the install is a development snapshot" \
  || bad "the closing lines say the install is a development snapshot" "$out"

empty="$work/snapshot-empty"
snapshot_source "$empty" "$work/changelog-empty.md" || bad "builds a source with an empty Unreleased section"
empty_commit="$(git -C "$empty" rev-parse --short HEAD 2>/dev/null)"
empty_app="$work/empty-app"; new_repo "$empty_app"
out="$(bash "$empty/install.sh" "$empty_app" 2>&1)"; expect_status "installs from a source with an empty Unreleased section" 0 $? "$out"
[ "$(sed -n 1p "$empty_app/.app-director/manifest")" = "# app-director 1.8.0" ] \
  && ok "an empty Unreleased section records the plain version" \
  || bad "an empty Unreleased section records the plain version" "$(head -n 2 "$empty_app/.app-director/manifest")"
expect_no_output "an empty Unreleased section adds no closing line" "development snapshot" "$out"

# A release records the plain version, and its commit when it comes from a git checkout. A release
# zip has no .git, and an enclosing repository's commit must not be recorded for it.
rel="$work/snapshot-release"
snapshot_source "$rel" "$work/changelog-release.md" || bad "builds a release source"
rel_commit="$(git -C "$rel" rev-parse --short HEAD 2>/dev/null)"
rel_app="$work/release-app"; new_repo "$rel_app"
out="$(bash "$rel/install.sh" "$rel_app" 2>&1)"; expect_status "installs from a release checkout" 0 $? "$out"
if [ "$(sed -n 1p "$rel_app/.app-director/manifest")" = "# app-director 1.8.0" ] \
    && [ "$(sed -n 2p "$rel_app/.app-director/manifest")" = "# source $rel_commit" ]; then
  ok "a release checkout records the plain version and its commit"
else
  bad "a release checkout records the plain version and its commit" "$(head -n 3 "$rel_app/.app-director/manifest")"
fi
expect_no_output "a release adds no closing line about snapshots" "development snapshot" "$out"

zip_app="$work/zip-app"; new_repo "$zip_app"
mkdir -p "$zip_app/App-Director"
cp -R "$rel/framework" "$rel/project" "$rel/install.sh" "$rel/VERSION" "$rel/CHANGELOG.md" "$zip_app/App-Director/"
out="$(bash "$zip_app/App-Director/install.sh" "$zip_app" 2>&1)"; expect_status "installs from a release folder with no git, inside an app repository" 0 $? "$out"
if [ "$(sed -n 1p "$zip_app/.app-director/manifest")" = "# app-director 1.8.0" ] \
    && [ "$(grep -c '^# source' "$zip_app/.app-director/manifest")" -eq 0 ]; then
  ok "a release folder with no git records no commit"
else
  bad "a release folder with no git records no commit" "$(head -n 3 "$zip_app/.app-director/manifest")"
fi

# An upgrade from the unreleased install reads the old version without its suffix (and skips the
# # source line): the next release, 1.9.0, upgrades it, and the message says so.
next="$work/snapshot-next"
snapshot_source "$next" "$work/changelog-release.md" && printf '1.9.0\n' > "$next/VERSION" \
  || bad "builds the next release source"
out="$(bash "$next/install.sh" "$snap_app" 2>&1)"; expect_status "upgrades from an unreleased install" 0 $? "$out"
expect_output "the upgrade reads the old version without the unreleased suffix" "upgraded from 1.8.0 to 1.9.0" "$out"
expect_no_output "the # source line isn't read as a file" "no longer part of App Director" "$out"
expect_no_output "the upgrade from an unreleased install closes without the snapshot line" "development snapshot" "$out"

# Refuses a folder that isn't the repository root.
mkdir -p "$snap_app/sub"
out="$(bash "$src/install.sh" "$snap_app/sub" 2>&1)"
expect_status "refuses a non-root folder" 1 $? "$out"
}

# --- check ----------------------------------------------------------------------------------------

# What the parts know about gitleaks, and the stand-ins they share. It runs before the parts that need it start.
gitleaks_setup() {
_gl_rule_id="selftest-marker"
_gl_marker_name="ADIR_SELFTEST_CRED"

# _cred_val assembled at test time from parts; no literal appears in this file and gitleaks
# never sees it in source; it is written only to the temp working directory.
_cv1="SelfTestFake"; _cv2="Key1234ABCD"
_cred_val="${_cv1}${_cv2}"

# Determine if a real gitleaks >= minimum is available. gitleaks 8.19.0 doesn't count: it can't scan
# at all, so the real-gitleaks tests would fail on it (the check exits 3 there, by design).
_gl_min_req="8.18.0"
_gl_ok=0
_gl_path_ver=""  # the version of the gitleaks the machine has on PATH, before any stand-in is added
if command -v gitleaks >/dev/null 2>&1; then
  _gl_raw="$(gitleaks version 2>/dev/null)"; _gl_ver="$(printf '%s' "$_gl_raw" | tr -d 'v \r\n')"
  _gl_path_ver="$_gl_ver"
  _gl_maj="${_gl_ver%%.*}"; _rest="${_gl_ver#*.}"; _gl_min_v="${_rest%%.*}"
  _req_maj="${_gl_min_req%%.*}"; _rest="${_gl_min_req#*.}"; _req_min_v="${_rest%%.*}"
  if [ "${_gl_maj:-0}" -gt "${_req_maj:-0}" ] || \
     { [ "${_gl_maj:-0}" -eq "${_req_maj:-0}" ] && [ "${_gl_min_v:-0}" -ge "${_req_min_v:-0}" ]; }; then
    _gl_ok=1
  fi
  if [ "$_gl_ver" = "8.19.0" ]; then
    _gl_ok=0
  fi
fi

# Build a PATH that includes gitleaks: real if available, otherwise a passthrough fake that
# always exits 0. Used everywhere except the "exits 3 when gitleaks is missing" test.
_real_path="$PATH"
_stop_path="$PATH"
if [ "$_gl_ok" -eq 0 ]; then
  _fake_gl="$work/fake-gl-pass"
  mkdir -p "$_fake_gl"
  printf '#!/usr/bin/env bash\ncase "$1" in version) printf "v8.18.0\\n";; esac; exit 0\n' \
    > "$_fake_gl/gitleaks"
  chmod +x "$_fake_gl/gitleaks"
  _stop_path="$_fake_gl:$PATH"
fi
export PATH="$_stop_path"

# Exit 3 when gitleaks is absent: the PATH without any directory that holds gitleaks (the stand-in's too).
_no_gl_path=""
for _gl_dir in $(printf '%s' "$PATH" | tr ':' '\n'); do
  [ -x "$_gl_dir/gitleaks" ] || _no_gl_path="${_no_gl_path:+$_no_gl_path:}$_gl_dir"
done

# Stand-in for gitleaks: protect writes one finding, or exits 1 with no report (FAKE_GL_PROTECT=error),
# as gitleaks 8.19.0 does for every scan. The check's dir and detect scans find nothing.
_hook_gl="$work/fake-gl-hook"
mkdir -p "$_hook_gl"
cat > "$_hook_gl/gitleaks" << 'FAKE'
#!/bin/bash
case "$1" in
  version) echo "v${FAKE_GL_VERSION:-8.18.0}" ;;
  protect)
    for a in "$@"; do case "$a" in --report-path=*) report="${a#--report-path=}" ;; esac; done
    [ "${FAKE_GL_PROTECT:-finding}" = error ] && exit 1
    printf '[\n {\n  "RuleID": "selftest-marker",\n  "Secret": "REDACTED",\n  "File": "src/services/TodoService.ts",\n  "Fingerprint": "src/services/TodoService.ts:selftest-marker:14"\n }\n]\n' > "$report"
    exit 1 ;;
  *) exit 0 ;;
esac
FAKE
chmod +x "$_hook_gl/gitleaks"
}

# Once the installer's first cases have left the example app: the parts that need it.
app_parts() {
cd "$app" || exit 1

# Add a selftest detection rule to .gitleaks.toml so the planted marker is caught regardless of
# entropy. The marker string is assembled at test time and never stored in this file.
cat >> .gitleaks.toml << EOF

[[rules]]
id = "$_gl_rule_id"
description = "App Director selftest marker; remove before production."
regex = '''${_gl_marker_name}\\s*=\\s*['"]([A-Za-z0-9+/]{16,})['"]'''
secretGroup = 1
EOF

# The parts that change the app each get a copy of it as the installer left it (with the rule above). The example app itself
# stays with /ui-design, which needs its path.
_cp_pids=""
for _lane_app in check1 check2 check3 check4 check5 guard hooks commit; do
  ( rm -rf "$work/$_lane_app-app"; cp -R "$app" "$work/$_lane_app-app" ) &
  _cp_pids="$_cp_pids $!"
done
for _cp_pid in $_cp_pids; do wait "$_cp_pid" || exit 3; done
part check1 2c-check1
part check2 2d-check2
part check3 2e-check3
part check4 2f-check4
part check5 2f2-check5
part guard 3-guard
part hooks 4a-hooks
part commit 4b-precommit
part ui_design 5-ui-design
wait
}

part_check1() {
  cd "$work/check1-app" || exit 3
echo "check"
out="$(bash tools/check.sh 2>&1)"
expect_status "passes on a fresh install of the example" 0 $? "$out"
out="$(bash tools/check.sh --if-changed 2>&1)"
expect_output "--if-changed reuses the last pass" "nothing changed" "$out"

# Planted UI purity failure: a UI file that imports directly from the data layer.
cp src/ui/TodoList.ts "$work/saved-ui"
{ printf '\n'; printf 'import { TodoStore } from '"'"'../store/TodoStore'"'"';\n'; } >> src/ui/TodoList.ts
out="$(bash tools/check.sh 2>&1)"
expect_status "fails on a UI file importing from the data layer" 1 $? "$out"
expect_output "names the offending file" "TodoList" "$out"
cp "$work/saved-ui" src/ui/TodoList.ts

if [ "$_gl_ok" -eq 1 ]; then
  # Planted fake credential: written only to temp dir, never committed.
  cp src/services/TodoService.ts "$work/saved-svc"
  { printf '\n'; printf "%s = '%s';\n" "$_gl_marker_name" "$_cred_val"; } >> src/services/TodoService.ts
  out="$(bash tools/check.sh 2>&1)"
  expect_status "fails on a planted secret" 1 $? "$out"
  expect_output "names the file with the secret" "TodoService" "$out"
  # --redact must keep the secret value out of check output and the state report
  expect_no_output "secret value not in check output" "$_cred_val" "$out"
  state_json="$(cat .app-director/state/gitleaks.json 2>/dev/null || true)"
  expect_no_output "secret value not in state file" "$_cred_val" "$state_json"

  # Allowlisted fingerprint passes the check.
  # gitleaks writes `"Fingerprint": "..."` (with a space, indented). JSON escapes a Windows path's
  # backslashes, so decode `\\` to `\` before the value goes into .gitleaksignore.
  fingerprint="$(printf '%s' "$state_json" | sed -n 's/.*"Fingerprint"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1 | sed 's/\\\\/\\/g')"
  if [ -n "$fingerprint" ]; then
    printf '%s\n' "$fingerprint" >> .gitleaksignore
    out="$(bash tools/check.sh 2>&1)"
    expect_status "allowlisted fingerprint passes" 0 $? "$out"
    # Remove the test entry (restore .gitleaksignore to original state)
    gl_lines="$(wc -l < .gitleaksignore)"; head -n "$((gl_lines - 1))" .gitleaksignore > "$work/gl-ignore-clean"
    cp "$work/gl-ignore-clean" .gitleaksignore
  else
    bad "allowlisted fingerprint passes (could not extract fingerprint from report)" "$state_json"
  fi

  cp "$work/saved-svc" src/services/TodoService.ts

  # A drawing in director/ui/ is allowlisted by path: its dataURL holds the marker string, which the
  # secrets step flags in any other file (src/x.ts, the same line) and passes in the drawing.
  _drawing_line="${_gl_marker_name} = '${_cred_val}'"
  mkdir -p director/ui
  printf '{\n  "type": "excalidraw",\n  "files": {\n    "f1": {\n      "dataURL": "%s"\n    }\n  }\n}\n' \
    "$_drawing_line" > director/ui/x.excalidraw
  out="$(bash tools/check.sh --architecture 2>&1)"
  expect_status "a drawing in director/ui/ with a flagged string passes the secrets check" 0 $? "$out"
  printf '%s\n' "$_drawing_line" > src/x.ts
  out="$(bash tools/check.sh --architecture 2>&1)"
  expect_status "the same string in src/x.ts still fails the secrets check" 1 $? "$out"
  expect_output "names src/x.ts as the file with the secret" "found in: src/x.ts" "$out"
  rm -rf director src/x.ts
else
  echo "  skip  gitleaks secrets tests (gitleaks not found, below $_gl_min_req, or 8.19.0, which can't scan)"
  echo "  skip  secret value not in check output"
  echo "  skip  secret value not in state file"
  echo "  skip  allowlisted fingerprint passes"
  echo "  skip  a drawing in director/ui/ passes the secrets check"
  echo "  skip  the same string in src/x.ts still fails the secrets check"
fi

}

part_check2() {
  cd "$work/check2-app" || exit 3
# Scan command by gitleaks version, with a test double, so it runs without real gitleaks: the double
# reports $FAKE_GL_VERSION, scans with $FAKE_GL_SCAN, writes one finding in gitleaks' report layout
# and exits 1 (leaks found). Regression: gitleaks 8.18 has no working `dir`, so check.sh must scan
# with `detect --no-git` there and use `dir` from 8.19.1. Either way the output names the file.
_scan_gl="$work/fake-gl-scan"
mkdir -p "$_scan_gl"
cat > "$_scan_gl/gitleaks" << 'FAKE'
#!/bin/bash
echo "$*" >> "$FAKE_GL_LOG"
case "$1" in
  version) echo "v$FAKE_GL_VERSION" ;;
  "$FAKE_GL_SCAN")
    for a in "$@"; do case "$a" in --report-path=*) report="${a#--report-path=}" ;; esac; done
    printf '[\n {\n  "RuleID": "selftest-marker",\n  "File": "src/services/TodoService.ts",\n  "StartLine": 14,\n  "Fingerprint": "src/services/TodoService.ts:selftest-marker:14"\n }\n]\n' > "$report"
    exit 1 ;;
  *) echo "FTL unknown command \"$1\"" >&2; exit 1 ;;
esac
FAKE
chmod +x "$_scan_gl/gitleaks"
_scan_log="$work/fake-gl-scan.log"
for _v in 8.18.0 8.30.1; do
  if [ "$_v" = "8.18.0" ]; then _scan=detect; _want="detect --no-git"; else _scan=dir; _want="dir "; fi
  : > "$_scan_log"
  out="$(FAKE_GL_VERSION="$_v" FAKE_GL_SCAN="$_scan" FAKE_GL_LOG="$_scan_log" PATH="$_scan_gl:$PATH" bash tools/check.sh 2>&1)"
  expect_status "fails on a finding with gitleaks $_v" 1 $? "$out"
  expect_output "names the file in a finding with gitleaks $_v" "found in: src/services/TodoService.ts" "$out"
  expect_output "scans with $_scan on gitleaks $_v" "^$_want" "$(cat "$_scan_log")"
done

# A scan that fails with no finding in its report is "couldn't scan", not a finding: check.sh exits 3,
# names no file and gives gitleaks' own error line. gitleaks 8.19.0 is the case that matters (every
# command fails with the same flag error and writes no report). The 8.30.1 double shows the rule holds
# for any scan error. A stale report from an earlier run must not be read as a finding either.
_err_gl="$work/fake-gl-error"
mkdir -p "$_err_gl"
cat > "$_err_gl/gitleaks" << 'FAKE'
#!/bin/bash
case "$1" in
  version) echo "v$FAKE_GL_VERSION" ;;
  *) echo "FTL $FAKE_GL_ERROR" >&2; exit 1 ;;
esac
FAKE
chmod +x "$_err_gl/gitleaks"

out="$(FAKE_GL_VERSION=8.19.0 FAKE_GL_ERROR="flag accessed but not defined: source" PATH="$_err_gl:$PATH" bash tools/check.sh 2>&1)"
expect_status "exits 3 when gitleaks 8.19.0 can't scan" 3 $? "$out"
expect_output "says gitleaks couldn't scan, not that it found credentials" "secrets FAIL: gitleaks couldn't scan" "$out"
expect_output "shows gitleaks' own error with 8.19.0" "gitleaks: .*flag accessed but not defined" "$out"
expect_output "hints to upgrade gitleaks to 8.19.1 or later with 8.19.0" "Upgrade to 8.19.1 or later" "$out"
expect_no_output "reports no finding with gitleaks 8.19.0" "found (in|credentials)" "$out"

printf '[\n {\n  "File": "src/services/TodoService.ts"\n }\n]\n' > .app-director/state/gitleaks.json
out="$(FAKE_GL_VERSION=8.30.1 FAKE_GL_ERROR="could not read the config" PATH="$_err_gl:$PATH" bash tools/check.sh 2>&1)"
expect_status "exits 3 when a gitleaks 8.30.1 scan errors with no finding" 3 $? "$out"
expect_no_output "a scan error with no finding is not a finding, and a stale report is ignored" "found (in|credentials)" "$out"
rm -f .app-director/state/gitleaks.json

# Exit 3 when gitleaks is absent: rebuild PATH stripping every directory that holds gitleaks
# (including the fake one when we set it up, so this path contains neither). Built before the parts fork.
out="$(PATH="$_no_gl_path" bash tools/check.sh 2>&1)"
if [ $? -eq 3 ]; then ok "exits 3 when gitleaks is missing"; else bad "exits 3 when gitleaks is missing" "$out"; fi

# Exit 3 when the configured stack script is missing.
cp tools/check.cfg "$work/saved-cfg"
printf '[project]\nstack = nonexistent\n[gitleaks]\nmin-version = 8.18.0\n' > tools/check.cfg
out="$(bash tools/check.sh 2>&1)"
expect_status "exits 3 when the stack script is missing" 3 $? "$out"
cp "$work/saved-cfg" tools/check.cfg

# A test run past [tests] timeout exits 3 and says so; a failure seen before it still exits 1.
# Needs GNU timeout (Windows' timeout.exe is not it); skipped without.
_gnu_timeout=""
for _c in timeout gtimeout; do
  if "$_c" --version 2>/dev/null | grep -qi coreutils; then _gnu_timeout="$_c"; break; fi
done
if [ -n "$_gnu_timeout" ]; then
  printf '#!/usr/bin/env bash\nsleep 20\n' > tools/stacks/slow.sh
  printf '#!/usr/bin/env bash\nexit 1\n' > tools/stacks/failing.sh
  printf '[project]\nstack = slow\n[gitleaks]\nmin-version = 8.18.0\n[tests]\ntimeout = 1\n' > tools/check.cfg
  out="$(bash tools/check.sh 2>&1)"
  expect_status "exits 3 when the stack check outlasts [tests] timeout" 3 $? "$out"
  printf '%s' "$out" | grep -q "timed out after 1 s" && ok "and says which run timed out and the limit" || bad "the timeout message" "$out"
  printf '[project]\nstack = failing\n[gitleaks]\nmin-version = 8.18.0\n[tests]\ntimeout = 5\n' > tools/check.cfg
  printf '#!/usr/bin/env bash\nsleep 20\n' > tools/check.local.sh
  out="$(bash tools/check.sh 2>&1)"
  expect_status "exits 1, not 3, when a failure was seen before the timeout" 1 $? "$out"
  rm -f tools/check.local.sh tools/stacks/slow.sh tools/stacks/failing.sh
else
  echo "  skip: no GNU timeout, so the check's test time limit isn't tested"
fi
cp "$work/saved-cfg" tools/check.cfg

out="$(bash tools/check.sh 2>&1)"
expect_status "passes again after faults removed" 0 $? "$out"

}

part_check3() {
  cd "$work/check3-app" || exit 3
# --if-changed repeats a result only while gitleaks is the one it ran with. A changed version (even
# the 8.19.0 that can't scan) or a removed gitleaks runs the secrets step again. The stand-in logs each
# call, and a reused pass calls `gitleaks version` once and nothing else.
_cache_gl="$work/fake-gl-cache"
_cache_log="$work/fake-gl-cache.log"
mkdir -p "$_cache_gl"
cat > "$_cache_gl/gitleaks" << 'FAKE'
#!/bin/bash
[ -n "${FAKE_GL_LOG:-}" ] && echo "$1" >> "$FAKE_GL_LOG"
case "$1" in
  version) echo "v$FAKE_GL_VERSION" ;;
  *) if [ -n "${FAKE_GL_SCAN_ERROR:-}" ]; then echo "FTL $FAKE_GL_SCAN_ERROR" >&2; exit 1; fi
     exit 0 ;;
esac
FAKE
chmod +x "$_cache_gl/gitleaks"

: > "$_cache_log"
out="$(PATH="$_cache_gl:$PATH" FAKE_GL_VERSION=8.30.1 FAKE_GL_LOG="$_cache_log" bash tools/check.sh 2>&1)"
expect_status "passes with a stand-in gitleaks 8.30.1" 0 $? "$out"

: > "$_cache_log"
out="$(PATH="$_cache_gl:$PATH" FAKE_GL_VERSION=8.30.1 FAKE_GL_LOG="$_cache_log" bash tools/check.sh --if-changed 2>&1)"; status=$?
expect_status "--if-changed reuses a pass when gitleaks is unchanged" 0 "$status" "$out"
expect_output "says the pass is reused" "nothing changed" "$out"
if [ "$(wc -l < "$_cache_log" | tr -d ' ')" -eq 1 ]; then ok "a reused pass calls gitleaks version once"; else bad "a reused pass calls gitleaks version once" "$(cat "$_cache_log")"; fi

out="$(PATH="$_cache_gl:$PATH" FAKE_GL_VERSION=8.29.0 bash tools/check.sh --if-changed 2>&1)"; status=$?
expect_status "--if-changed passes after gitleaks changed to 8.29.0" 0 "$status" "$out"
expect_output "a changed gitleaks version runs the secrets step again" "^check: secrets$" "$out"

out="$(PATH="$_cache_gl:$PATH" FAKE_GL_VERSION=8.19.0 FAKE_GL_SCAN_ERROR="flag accessed but not defined: source" bash tools/check.sh --if-changed 2>&1)"; status=$?
expect_status "--if-changed exits 3 after gitleaks was downgraded to 8.19.0" 3 "$status" "$out"
expect_output "the 8.19.0 downgrade runs the secrets step and says it can't scan" "secrets FAIL: gitleaks couldn't scan" "$out"

out="$(PATH="$_no_gl_path" bash tools/check.sh --if-changed 2>&1)"; status=$?
expect_status "--if-changed exits 3 after gitleaks was removed" 3 "$status" "$out"
expect_output "a removed gitleaks runs the secrets step again" "^check: secrets FAIL: gitleaks not found" "$out"

out="$(PATH="$_cache_gl:$PATH" FAKE_GL_VERSION=8.30.1 bash tools/check.sh --if-changed 2>&1)"; status=$?
expect_status "--if-changed passes again once gitleaks is back" 0 "$status" "$out"

# A failure is repeated the same way: nothing changed with the same gitleaks, a full run after a change.
cp src/ui/TodoList.ts "$work/saved-ui-cache"
{ printf '\n'; printf 'import { TodoStore } from '"'"'../store/TodoStore'"'"';\n'; } >> src/ui/TodoList.ts
out="$(PATH="$_cache_gl:$PATH" FAKE_GL_VERSION=8.30.1 bash tools/check.sh 2>&1)"
expect_status "fails with a planted UI violation (stand-in gitleaks 8.30.1)" 1 $? "$out"
out="$(PATH="$_cache_gl:$PATH" FAKE_GL_VERSION=8.30.1 bash tools/check.sh --if-changed 2>&1)"; status=$?
expect_status "--if-changed repeats the failure while gitleaks is unchanged" 1 "$status" "$out"
expect_output "says the failure is unchanged" "nothing changed" "$out"
out="$(PATH="$_cache_gl:$PATH" FAKE_GL_VERSION=8.29.0 bash tools/check.sh --if-changed 2>&1)"; status=$?
expect_status "--if-changed reruns the failure after gitleaks changed" 1 "$status" "$out"
expect_output "the rerun checks the UI files again" "check: UI purity FAIL" "$out"
cp "$work/saved-ui-cache" src/ui/TodoList.ts
out="$(bash tools/check.sh 2>&1)"
expect_status "passes again once the UI violation is removed" 0 $? "$out"

}

part_check4() {
  cd "$work/check4-app" || exit 3
echo "check tiers, the cache and the run log"
# The two tiers on the example app: what a fast and a full result record and stand for, the line each miss prints, when
# the full tier is due, the summary, the run log, what tools/check.local.sh is given, the per-tier time limits, the
# progress line, a stack with no fast mode and the paths that count. A stand-in gitleaks reports $FAKE_GL_VERSION
# (8.30.1 by default) and finds nothing, so a run is quick and the version can change. The example's stack (none) has no
# fast mode, so a fast request there runs as the full tier (the cases near the end): a stand-in stack that reads the
# tier, as tools/stacks/typescript.sh does, keeps the two tiers apart for the others.
_t_gl="$work/fake-gl-tiers"; mkdir -p "$_t_gl"
printf '#!/bin/bash\n[ "$1" = version ] && echo "v${FAKE_GL_VERSION:-8.30.1}"\nexit 0\n' > "$_t_gl/gitleaks"
chmod +x "$_t_gl/gitleaks"
c4() { PATH="$_t_gl:$PATH" bash tools/check.sh "$@" 2>&1; }
_st=.app-director/state
printf '#!/usr/bin/env bash\n: "${CHECK_TIER:-full}"\nexit 0\n' > tools/stacks/tiers.sh
sed 's/^stack = .*/stack = tiers/' tools/check.cfg > "$work/c4-cfg-tiers" && cp "$work/c4-cfg-tiers" tools/check.cfg
rm -f "$_st/last-pass" "$_st/last-fail" "$_st/last-full" "$_st/check-runs.log"
git add -A >/dev/null 2>&1 && git_q commit -qm "the tiers' start" >/dev/null 2>&1

out="$(c4 --due)"; status=$?
expect_status "--due exits 0" 0 "$status" "$out"
expect_output "--due with no full pass recorded says the full tier is due" "^check: full tier due: no full pass recorded yet$" "$out"
out="$(c4 --fast --if-changed)"; status=$?
expect_status "--fast --if-changed passes on the example" 0 "$status" "$out"
expect_output "a miss with nothing recorded says so before the run" "^check: running the fast tier: no result recorded yet$" "$out"
expect_output "a fast pass is reported as fast, with when the full tier is due" "^check: PASS \(fast tier; full tier due now: no full pass recorded yet\)$" "$out"
expect_output "the summary names the tier, the result and the time" "^check: summary: fast tier, PASS in [0-9]+ s$" "$out"
expect_output "and each step's time" "^check:   steps: UI purity [0-9]+ s, secrets [0-9]+ s, stack [0-9]+ s$" "$out"
expect_output "and what the cache found" "^check:   cache: no result recorded yet$" "$out"
rec="$(cat "$_st/last-pass" 2>/dev/null)"
expect_output "a pass's line 1 is the key: the fingerprint and gitleaks's version" "^[0-9a-f]{40} gitleaks=8\.30\.1$" "$rec"
expect_output "line 2 the tier, time, commit, caller and run" "^tier=fast at=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2} commit=[0-9a-f]{7} caller=manual run=[0-9T]+-[0-9]+$" "$rec"
grep -qxF "$(git hash-object --no-filters src/ui/TodoList.ts) src/ui/TodoList.ts" "$_st/last-pass.files" \
  && ok "beside it, the files it checked, each with its blob hash" || bad "beside it, the files it checked, each with its blob hash" "$(cat "$_st/last-pass.files" 2>&1)"
expect_output "the run log has a line for the run" \
  "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8} tier=fast result=pass secs=[0-9]+ caller=manual commit=[0-9a-f]{7} tests=\?/\?$" "$(cat "$_st/check-runs.log" 2>&1)"

out="$(c4 --fast --if-changed)"; status=$?
expect_status "--fast --if-changed reuses a fast pass" 0 "$status" "$out"
expect_output "and says which pass it reused" "^check: PASS \(reused the fast pass at [0-9]{2}:[0-9]{2}, commit [0-9a-f]{7}, by manual; nothing changed\)$" "$out"
expect_no_output "a reuse prints no summary" "summary" "$out"
# A fast pass checks the changes from HEAD. It stands on a later commit when every path that differs from HEAD now was
# among those it checked: committing the checked change leaves fewer. A reset to the commit before leaves more, which it
# didn't check.
_c4_h0="$(git rev-parse HEAD)"; _c4_h0="${_c4_h0:0:7}"
printf '\n// committed next\n' >> src/ui/TodoList.ts
out="$(c4 --fast)"; expect_status "a fast pass of a change" 0 $? "$out"
git add src/ui/TodoList.ts && git_q commit -qm "the checked change" >/dev/null 2>&1
out="$(c4 --fast --if-changed)"; status=$?
expect_status "--fast --if-changed passes once that change is committed" 0 "$status" "$out"
expect_output "and reuses the pass from the commit before" \
  "^check: PASS \(reused the fast pass at [0-9:]{5}, commit $_c4_h0, by manual; nothing changed\)$" "$out"
_c4_h1="$(git rev-parse HEAD)"; _c4_h1="${_c4_h1:0:7}"
out="$(c4 --fast)"; expect_status "a fast pass of the clean tree" 0 $? "$out"
git reset -q --soft HEAD~1
out="$(c4 --fast --if-changed)"
expect_output "isn't reused after a reset to the commit before, which leaves a change it didn't check; the miss names both commits" \
  "^check: running the fast tier: the fast pass at [0-9:]{5} \(manual\) checked the changes from commit $_c4_h1; HEAD is now $_c4_h0$" "$out"
git_q commit -qm "the checked change, again" >/dev/null 2>&1
out="$(CHECK_CALLER=pre-commit c4 --if-changed --full)"; status=$?
expect_status "--if-changed --full runs the full tier after a fast pass" 0 "$status" "$out"
expect_output "a fast pass never satisfies a full request, and the miss says so" "^check: running the full tier: the last pass was the fast tier, at [0-9]{2}:[0-9]{2} \(commit [0-9a-f]{7}, manual\)$" "$out"
expect_output "a full pass is reported as the full tier" "^check: PASS \(full tier\)$" "$out"
lf="$(cat "$_st/last-full" 2>/dev/null)"
[ "${lf%% *}" = "$(git rev-parse HEAD)" ] && ok "a full pass writes last-full: HEAD's commit and the time" || bad "a full pass writes last-full: HEAD's commit and the time" "$lf"
out="$(c4 --fast --if-changed)"
expect_output "a full pass satisfies --fast --if-changed, and the reuse names its caller" "^check: PASS \(reused the full pass at [0-9:]+, commit [0-9a-f]{7}, by pre-commit; nothing changed\)$" "$out"
out="$(c4 --fast)"; status=$?
expect_status "--fast without --if-changed runs" 0 "$status" "$out"
expect_output "and its summary says the cache wasn't asked" "^check:   cache: not used \(run without --if-changed\)$" "$out"
{ IFS= read -r _l1; IFS= read -r _l2; } < "$_st/last-pass"
expect_output "a fast pass leaves a full pass of the same files recorded" "^tier=full .* caller=pre-commit " "$_l2"
log="$(cat "$_st/check-runs.log")"
expect_output "the log names the caller from CHECK_CALLER" " tier=full result=pass secs=[0-9]+ caller=pre-commit commit=[0-9a-f]{7} " "$log"
expect_output "and logs a reuse" " tier=fast result=reused-pass secs=0 caller=manual commit=[0-9a-f]{7} tests=0/\?$" "$log"
out="$(c4 --due)"
expect_output "--due right after a full pass: not due, with the count, the pass and the setting" \
  "^check: full tier not due: 0 commits since the last full pass \([0-9a-f]{7}, [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}\), \[tests\] full-every = 10$" "$out"

# Each miss names what changed since the result it compared with, in one line before the run.
cp src/ui/TodoList.ts "$work/c4-ui"; cp src/services/TodoService.ts "$work/c4-svc"; cp src/store/TodoStore.ts "$work/c4-store"
printf '\n// changed\n' >> src/ui/TodoList.ts
out="$(c4 --if-changed)"
expect_output "a miss names a changed file and the pass it compared with" "^check: running the full tier: src/ui/TodoList\.ts changed since the full pass at [0-9]{2}:[0-9]{2} \(commit [0-9a-f]{7}, pre-commit\)$" "$out"
printf '\n// changed\n' >> src/services/TodoService.ts; printf '\n// changed\n' >> src/store/TodoStore.ts
printf '{}\n' > a.json; printf '{}\n' > b.json; rm src/ui/TodoList.ts
out="$(c4 --if-changed)"
expect_output "a miss names the first changed file and how many more" "src/services/TodoService\.ts and 1 more changed, " "$out"
expect_output "new files" ", a\.json and 1 more are new, " "$out"
expect_output "and a removed one" ", src/ui/TodoList\.ts was removed since the full pass at " "$out"
cp "$work/c4-ui" src/ui/TodoList.ts; cp "$work/c4-svc" src/services/TodoService.ts; cp "$work/c4-store" src/store/TodoStore.ts; rm a.json b.json
out="$(c4 --if-changed)"
expect_output "a new file, and removed files" ", src/ui/TodoList\.ts is new, a\.json and 1 more were removed since " "$out"
out="$(FAKE_GL_VERSION=8.29.0 c4 --if-changed)"
expect_output "a miss names a changed gitleaks, with both versions" "^check: running the full tier: gitleaks changed from 8\.30\.1 to 8\.29\.0 since the full pass at " "$out"
printf '%s gitleaks=8.30.1' "$(c4 --fingerprint)" > "$_st/last-pass"
out="$(c4 --fast --if-changed)"; status=$?
expect_status "a record in the older one-line format is a miss, and the run goes on" 0 "$status" "$out"
expect_output "which says the last result was recorded by an older check" "^check: running the fast tier: the last result was recorded by an older check$" "$out"

# A failure: exit 1, recorded with its tier. A fast failure doesn't stand for a full request; a full one covers a fast request.
{ printf '\n'; printf 'import { TodoStore } from '"'"'../store/TodoStore'"'"';\n'; } >> src/ui/TodoList.ts
out="$(c4 --fast)"; status=$?
expect_status "the fast tier fails on a UI purity violation, with exit 1" 1 "$status" "$out"
expect_output "and says FAIL with its tier" "^check: FAIL \(fast tier; logs above\)$" "$out"
expect_output "its summary says FAIL" "^check: summary: fast tier, FAIL in [0-9]+ s$" "$out"
out="$(c4 --full --if-changed)"; status=$?
expect_status "a fast failure doesn't stand for a full request: the full tier runs, and fails" 1 "$status" "$out"
expect_output "the miss says the last failure was the fast tier" "^check: running the full tier: the last failure was the fast tier, at " "$out"
out="$(c4 --fast --if-changed)"; status=$?
expect_status "a full failure stands for a fast request on the same files" 1 "$status" "$out"
expect_output "and says which failure it repeated" "^check: FAIL \(reused the full failure at [0-9:]+, commit [0-9a-f]{7}, by manual; nothing changed; run 'bash tools/check\.sh' to see why\)$" "$out"
cp "$work/c4-ui" src/ui/TodoList.ts

out="$(c4 --bogus)"; status=$?
expect_status "an unknown flag exits 3" 3 "$status" "$out"
expect_output "with a usage line" "^usage: bash tools/check\.sh \[--full \| --fast\] \[--if-changed\]" "$out"
out="$(c4 --fast --full)"; expect_status "--fast with --full exits 3" 3 $? "$out"
out="$(PATH="$_no_gl_path" bash tools/check.sh --fast 2>&1)"; expect_status "the fast tier exits 3 without gitleaks" 3 $? "$out"
expect_output "and the log says it couldn't run" " tier=fast result=couldnt-run " "$(tail -n 1 "$_st/check-runs.log")"

# When the full tier is due: [tests] full-every commits after the last full pass, a [tests] full-when path, a path on the
# framework's own list, or a last full pass that isn't in this history.
cp tools/check.cfg "$work/c4-cfg"
printf '\n[tests]\nfull-every = 2\nfull-when = db/migrations/\n' >> tools/check.cfg
git add -A >/dev/null 2>&1 && git_q commit -qm "full-every 2" >/dev/null 2>&1
out="$(c4)"; expect_status "the full tier passes after the settings change" 0 $? "$out"
git_q commit -q --allow-empty -m "one" >/dev/null 2>&1
out="$(c4 --due)"
expect_output "--due one commit after the full pass, with full-every = 2: not due" "^check: full tier not due: 1 commit since the last full pass \([0-9a-f]{7}, .*\), \[tests\] full-every = 2$" "$out"
out="$(c4 --fast)"
expect_output "a fast pass says in how many commits the full tier is due" "^check: PASS \(fast tier; full tier due in 1 commit\)$" "$out"
git_q commit -q --allow-empty -m "two" >/dev/null 2>&1
out="$(c4 --due)"
expect_output "--due when full-every is reached" "^check: full tier due: 2 commits since the last full pass \([0-9a-f]{7}, [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}\), \[tests\] full-every = 2$" "$out"
mkdir -p db/migrations && printf 'create table t (id int);\n' > db/migrations/001.sql
out="$(c4 --due)"
expect_output "--due for a changed path under [tests] full-when" "^check: full tier due: db/migrations/001\.sql changed$" "$out"
rm -rf db; printf '{}\n' > package.json
out="$(c4 --due)"
expect_output "--due for a path on the framework's own list" "^check: full tier due: package\.json changed$" "$out"
out="$(c4 --fast)"
expect_output "a fast pass says the full tier is due now, and why" "^check: PASS \(fast tier; full tier due now: package\.json changed\)$" "$out"
rm package.json
cp "$_st/last-full" "$work/c4-last-full"
printf '0123456789012345678901234567890123456789 2026-01-01T00:00:00\n' > "$_st/last-full"
out="$(c4 --due)"
expect_output "--due when the last full pass isn't in this history" "^check: full tier due: the last full pass \(0123456, 2026-01-01 00:00\) isn't in this history$" "$out"
cp "$work/c4-last-full" "$_st/last-full"

# [tests] ignore: a change only under it leaves the fingerprint, so a recorded pass stands, and isn't a changed path.
# tools/check.local.sh gets the tier, the state folder and, in the fast tier, the list of changed paths, and what it
# writes to stack-summary is printed in the summary.
printf 'ignore = marketing/ *.draft.json\n' >> tools/check.cfg
cat > tools/check.local.sh << 'EOF'
#!/usr/bin/env bash
{ echo "tier=$CHECK_TIER"; echo "state=$CHECK_STATE"; echo "changed=${CHECK_CHANGED:-}"; [ -z "${CHECK_CHANGED:-}" ] || cat "$CHECK_CHANGED"; } > "$CHECK_STATE/local-env"
echo "local: ran in the $CHECK_TIER tier" >> "$CHECK_STATE/stack-summary"
EOF
out="$(c4 --fast)"; expect_status "passes with a tools/check.local.sh" 0 $? "$out"
fp1="$(c4 --fingerprint)"
mkdir -p marketing && printf '{ "title": "x" }\n' > marketing/page.json && printf '{}\n' > notes.draft.json
[ "$(c4 --fingerprint)" = "$fp1" ] && ok "a change only under [tests] ignore leaves the fingerprint as it was" \
  || bad "a change only under [tests] ignore leaves the fingerprint as it was"
out="$(c4 --fast --if-changed)"
expect_output "so the recorded pass stands" "^check: PASS \(reused the fast pass at " "$out"
printf '\n// changed\n' >> src/ui/TodoList.ts
out="$(c4 --fast)"
env_seen="$(cat "$_st/local-env" 2>&1)"
expect_output "tools/check.local.sh gets CHECK_TIER" "^tier=fast$" "$env_seen"
expect_output "and CHECK_STATE, an absolute path" "^state=/.*\.app-director/state$" "$env_seen"
expect_output "and CHECK_CHANGED, an absolute path, in the fast tier" "^changed=/.*\.app-director/state/changed$" "$env_seen"
expect_output "which lists a changed file" "^src/ui/TodoList\.ts$" "$env_seen"
expect_output "and an untracked one" "^tools/check\.local\.sh$" "$env_seen"
expect_no_output "but not a path under [tests] ignore, nor the check's state" "marketing|draft|\.app-director/state/" "$(printf '%s\n' "$env_seen" | sed 1,3d)"
expect_output "what it writes to stack-summary is in the summary" "^check:   local: ran in the fast tier$" "$out"
out="$(c4)"
env_seen="$(cat "$_st/local-env" 2>&1)"
expect_output "the full tier gives CHECK_TIER=full" "^tier=full$" "$env_seen"
expect_output "and no CHECK_CHANGED" "^changed=$" "$env_seen"

# The run log keeps its last 500 lines once it passes 1000.
_i=0; while [ "$_i" -lt 1000 ]; do echo "an earlier run $_i"; _i=$((_i + 1)); done > "$_st/check-runs.log"
out="$(c4 --fast)"
_n="$(wc -l < "$_st/check-runs.log" | tr -d ' ')"; _first="$(head -n 1 "$_st/check-runs.log")"
if [ "$_n" -eq 500 ] && [ "$_first" = "an earlier run 501" ]; then ok "the run log is trimmed to its last 500 lines past 1000"
else bad "the run log is trimmed to its last 500 lines past 1000" "$_n lines, the first: $_first"; fi
cp "$work/c4-ui" src/ui/TodoList.ts

# Per-tier time limits and the progress line. GNU timeout only, as in the check's own limit; skipped without.
_c4_timeout=""
for _c in timeout gtimeout; do
  if "$_c" --version 2>/dev/null | grep -qi coreutils; then _c4_timeout="$_c"; break; fi
done
if [ -n "$_c4_timeout" ]; then
  rm -f tools/check.local.sh
  printf '#!/usr/bin/env bash\n: "${CHECK_TIER:-full}"\nsleep 10\n' > tools/stacks/slow.sh
  printf '[project]\nstack = slow\n[gitleaks]\nmin-version = 8.18.0\n[tests]\ntimeout-fast = 1\ntimeout = 30\n' > tools/check.cfg
  out="$(c4 --fast)"; status=$?
  expect_status "the fast tier exits 3 past [tests] timeout-fast" 3 "$status" "$out"
  expect_output "and says which run timed out, after how long, and the setting" "^check: couldn't run to the end: the stack check timed out after 1 s \(the fast tier's limit, \[tests\] timeout-fast in tools/check\.cfg\)$" "$out"
  expect_output "and how to go on: again in the background with a longer CHECK_TIMEOUT, whose pass a commit reuses, or a higher setting" \
    "^check: to go on, run it again in the background with a longer limit, 'CHECK_TIMEOUT=<seconds> bash tools/check\.sh --fast': a commit then reuses its pass, since the limit isn't part of what a pass stands for\. Or raise \[tests\] timeout-fast in tools/check\.cfg\.$" "$out"
  [ ! -f "$_st/last-pass" ] && ok "a run past its limit records no pass" || bad "a run past its limit records no pass" "$(cat "$_st/last-pass")"
  expect_output "and the log says it couldn't run" " tier=fast result=couldnt-run " "$(tail -n 1 "$_st/check-runs.log")"
  printf '[project]\nstack = slow\n[gitleaks]\nmin-version = 8.18.0\n[tests]\ntimeout-full = 1\ntimeout = 30\n' > tools/check.cfg
  out="$(c4)"; status=$?
  expect_status "the full tier exits 3 past [tests] timeout-full, which wins over timeout" 3 "$status" "$out"
  expect_output "and names timeout-full and the full tier" "timed out after 1 s \(the full tier's limit, \[tests\] timeout-full in tools/check\.cfg\)$" "$out"
  printf '[project]\nstack = slow\n[gitleaks]\nmin-version = 8.18.0\n[tests]\ntimeout-fast = 30\n' > tools/check.cfg
  out="$(CHECK_TIMEOUT=1 c4 --fast)"; status=$?
  expect_status "CHECK_TIMEOUT overrides the tier's limit" 3 "$status" "$out"
  expect_output "and is named as the limit" "timed out after 1 s \(the fast tier's limit, CHECK_TIMEOUT\)$" "$out"
  printf '#!/usr/bin/env bash\nsleep 3\n' > tools/stacks/slow.sh
  # That stand-in has no fast mode, so a fast request runs under the full tier's limit: [tests] timeout-fast doesn't end it.
  printf '[project]\nstack = slow\n[gitleaks]\nmin-version = 8.18.0\n[tests]\ntimeout-fast = 1\n' > tools/check.cfg
  out="$(c4 --fast)"; status=$?
  expect_status "a fast request on a stack with no fast mode runs under the full tier's limit, past [tests] timeout-fast" 0 "$status" "$out"
  printf '[project]\nstack = slow\n[gitleaks]\nmin-version = 8.18.0\n' > tools/check.cfg
  _t0=$SECONDS
  out="$(CHECK_PROGRESS_EVERY=1 PATH="$_t_gl:$PATH" "$_c4_timeout" 60 bash tools/check.sh 2>&1)"; status=$?
  _took=$((SECONDS - _t0))
  expect_status "a run with the progress line passes" 0 "$status" "$out"
  expect_output "a long stack check prints that it is still running, with the tier and the minutes" "^check: still running the stack check \(full tier\), 0 min$" "$out"
  [ "$_took" -lt 30 ] && ok "the progress line ends with the check, and holds nothing open" || bad "the progress line ends with the check, and holds nothing open" "took $_took s"
  rm -f tools/stacks/slow.sh
else
  echo "  skip: no GNU timeout, so the per-tier time limits and the progress line aren't tested"
fi
cp "$work/c4-cfg" tools/check.cfg; rm -rf marketing notes.draft.json tools/check.local.sh

# A stack with no fast mode: neither the stack check nor tools/check.local.sh names CHECK_TIER outside a comment, so there
# is one suite. A fast request runs as the full tier and says why, its pass is a full pass, and a full request (a
# push's) reuses it: the suite runs once for both.
sed 's/^stack = .*/stack = none/' "$work/c4-cfg" > tools/check.cfg
printf '#!/usr/bin/env bash\n# No fast mode: this comment names CHECK_TIER, and no command does.\necho ran >> "$CHECK_STATE/suite-runs"\n' > tools/check.local.sh
rm -f "$_st/suite-runs"
out="$(c4 --fast)"; status=$?
expect_status "a fast request passes on a stack with no fast mode" 0 "$status" "$out"
expect_output "it runs as the full tier, and says why" \
  "^check: note: neither the stack check nor tools/check\.local\.sh has a fast mode \(reads CHECK_TIER\), so the fast tier runs as the full tier$" "$out"
expect_output "and reports a full pass" "^check: PASS \(full tier\)$" "$out"
{ IFS= read -r _l1; IFS= read -r _l2; } < "$_st/last-pass"
expect_output "which it records as one" "^tier=full " "$_l2"
out="$(CHECK_CALLER=pre-push c4 --full --if-changed)"
expect_output "a full request, a push's, reuses that pass" "^check: PASS \(reused the full pass at [0-9:]{5}, commit [0-9a-f]{7}, by manual; nothing changed\)$" "$out"
_n="$(wc -l < "$_st/suite-runs" | tr -d ' ')"
[ "$_n" -eq 1 ] && ok "so the suite ran once for both" || bad "so the suite ran once for both" "$_n runs"
printf '#!/usr/bin/env bash\n[ "$CHECK_TIER" = fast ] || echo ran >> "$CHECK_STATE/suite-runs"\n' > tools/check.local.sh
out="$(c4 --fast)"
expect_output "a tools/check.local.sh that reads CHECK_TIER is a fast mode: the fast tier stays" "^check: PASS \(fast tier" "$out"
expect_no_output "with no note" "so the fast tier runs as the full tier" "$out"
rm -f tools/check.local.sh "$_st/suite-runs"

# The paths that make the full tier due count like source paths: a change to one changes the fingerprint, so a recorded
# pass doesn't stand, and --unignored keeps it (the pre-commit hook's question). [tests] ignore still wins, and a path
# that is neither source nor due counts for nothing.
printf '\n[tests]\nfull-when = db/migrations/\nignore = db/migrations/old/\n' >> tools/check.cfg
mkdir -p db/migrations/old && printf 'create table t (id int);\n' > db/migrations/001.sql
out="$(c4)"; expect_status "a full pass with a migration in the tree" 0 $? "$out"
fp1="$(c4 --fingerprint)"
printf 'alter table t add n int;\n' >> db/migrations/001.sql
[ "$(c4 --fingerprint)" != "$fp1" ] && ok "a change under [tests] full-when changes the fingerprint" \
  || bad "a change under [tests] full-when changes the fingerprint"
out="$(c4 --if-changed)"
expect_output "so the recorded pass doesn't stand, and the miss names the path" \
  "^check: running the full tier: db/migrations/001\.sql changed since the full pass at " "$out"
fp1="$(c4 --fingerprint)"
printf 'pytest==8.0\n' > requirements.txt
[ "$(c4 --fingerprint)" != "$fp1" ] && ok "and so does a path on the framework's own list (requirements.txt)" \
  || bad "and so does a path on the framework's own list (requirements.txt)"
fp1="$(c4 --fingerprint)"
printf 'drop table t;\n' > db/migrations/old/000.sql; printf 'notes\n' > notes.txt
[ "$(c4 --fingerprint)" = "$fp1" ] && ok "a path under [tests] ignore, or one that is neither source nor due, leaves it as it was" \
  || bad "a path under [tests] ignore, or one that is neither source nor due, leaves it as it was"
out="$(printf '%s\n' db/migrations/001.sql requirements.txt db/migrations/old/000.sql notes.txt src/ui/TodoList.ts | c4 --unignored)"
[ "$out" = "db/migrations/001.sql${nl}requirements.txt${nl}src/ui/TodoList.ts" ] \
  && ok "--unignored keeps the paths that make the full tier due, less [tests] ignore" \
  || bad "--unignored keeps the paths that make the full tier due, less [tests] ignore" "$out"
# The settings read the same from a file checked out with CRLF line endings: a value has no carriage return, nor the
# comment after it.
printf '[project]\r\nstack = none\r\n[gitleaks]\r\nmin-version = 8.18.0\r\n[tests]\r\nfull-when = db/migrations/   ; a comment after the value\r\nignore = marketing/\r\n' > tools/check.cfg
out="$(printf '%s\n' db/migrations/001.sql marketing/page.json notes.txt | c4 --unignored)"
[ "$out" = "db/migrations/001.sql" ] && ok "settings with CRLF line endings, and a comment after a value, read as the same settings" \
  || bad "settings with CRLF line endings, and a comment after a value, read as the same settings" "$out"
cp "$work/c4-cfg" tools/check.cfg; rm -rf db requirements.txt notes.txt

# With no commit yet, the fast tier runs as the full tier and says why.
_nh="$work/no-head"; mkdir -p "$_nh/tools/stacks" && git init -q "$_nh"
cp "$src/framework/tools/check.sh" "$_nh/tools/" && cp "$src/framework/tools/stacks/none.sh" "$_nh/tools/stacks/"
printf '[project]\nstack = none\n' > "$_nh/tools/check.cfg"; printf '.app-director/state/\n' > "$_nh/.gitignore"; printf 'export const x = 1;\n' > "$_nh/x.ts"
# The Stop hook does nothing there: the first commit's hook gates the work.
out="$(printf '{}' | CLAUDE_PROJECT_DIR="$_nh" PATH="$_t_gl:$PATH" bash "$src/framework/.claude/hooks/stop-check.sh" 2>&1)"; status=$?
expect_status "the Stop hook ends the turn in a repository with no commit" 0 "$status" "$out"
[ -z "$out" ] && [ ! -e "$_nh/.app-director/state/check-runs.log" ] && ok "quietly, and starts no check" || bad "quietly, and starts no check" "$out"
out="$(cd "$_nh" && PATH="$_t_gl:$PATH" bash tools/check.sh --fast 2>&1)"; status=$?
expect_status "the fast tier passes in a repository with no commit" 0 "$status" "$out"
expect_output "and says it runs as the full tier, and why" "^check: note: there's no commit yet, so the fast tier runs as the full tier$" "$out"
expect_output "and reports the full tier" "^check: PASS \(full tier\)$" "$out"
}

part_check5() {
  cd "$work/check5-app" || exit 3
echo "check, single flight"
# One run at a time per checkout. A stand-in stack counts its starts (a line each, with the tier, in suites), sleeps
# $SLOW_SECS seconds (3 by default) and exits $SLOW_EXIT, so two runs side by side show whether a second suite started. A
# stand-in gitleaks finds nothing, and the settings name no UI folders, so a run starts few processes. The stale and busy
# cases plant a lock: a pid that has ended, or this selftest's own, which is running.
_f_gl="$work/fake-gl-flight"; mkdir -p "$_f_gl"
printf '#!/bin/bash\n[ "$1" = version ] && echo v8.30.1\nexit 0\n' > "$_f_gl/gitleaks"; chmod +x "$_f_gl/gitleaks"
printf '#!/usr/bin/env bash\necho "$CHECK_TIER" >> "$CHECK_STATE/suites"\nsleep "${SLOW_SECS:-3}"\nexit "${SLOW_EXIT:-0}"\n' > tools/stacks/slow.sh
printf '[project]\nstack = slow\n[gitleaks]\nmin-version = 8.18.0\n' > tools/check.cfg
_st=.app-director/state; _lock="$_st/check.lock"
c5() { PATH="$_f_gl:$PATH" bash tools/check.sh "$@" 2>&1; }
c5_bg() { # c5_bg <name> <flag>...: a check in the background, its output in $work/c5-<name>.out and its status in .rc
  local name="$1"; shift
  ( PATH="$_f_gl:$PATH" bash tools/check.sh "$@" > "$work/c5-$name.out" 2>&1; echo "$?" > "$work/c5-$name.rc" ) &
}
c5_read() { c5_out=""; c5_rc=""; IFS= read -r -d '' c5_out < "$work/c5-$1.out"; read -r c5_rc < "$work/c5-$1.rc"; }  # c5_read <name>
c5_suites() { # the suites started since the file was last removed: how many in c5_n, their tiers in c5_list
  local l
  c5_n=0; c5_list=""
  [ -f "$_st/suites" ] || return 0
  while IFS= read -r l; do c5_n=$((c5_n + 1)); c5_list="$c5_list$l "; done < "$_st/suites"
}
c5_lock_gone() { # c5_lock_gone <after what>
  if [ ! -e "$_lock" ]; then ok "the lock is gone after $1"; else bad "the lock is gone after $1" "$(cat "$_lock")"; fi
}

# 1. Two runs started at once: one suite starts, and the other waits for it and reuses its pass.
rm -f "$_st/suites"
c5_bg a --fast; c5_bg b --fast; wait
c5_read a; _oa="$c5_out"; _ra="$c5_rc"; c5_read b; _ob="$c5_out"; _rb="$c5_rc"
c5_suites
[ "$c5_n" -eq 1 ] && ok "two runs started at once start one suite" || bad "two runs started at once start one suite ($c5_n started)" "$_oa$nl$_ob"
[ "$_ra" = 0 ] && [ "$_rb" = 0 ] && ok "and both pass" || bad "and both pass (exit $_ra and $_rb)" "$_oa$nl$_ob"
expect_output "the second says what it waits for: the start, the caller, the tier and the pid" \
  "^check: waiting for the check started [0-9]{2}:[0-9]{2} by manual \(fast tier, pid [0-9]+\)$" "$_oa$nl$_ob"
expect_output "and reuses the first one's pass, recorded while it waited" \
  "^check: PASS \(reused the fast pass at [0-9]{2}:[0-9]{2}, commit [0-9a-f]{7}, by manual, recorded while this check waited; nothing changed\)$" "$_oa$nl$_ob"
c5_lock_gone "a pass"
_log=""; IFS= read -r -d '' _log < "$_st/check-runs.log"
expect_output "the run log has the reuse, with the seconds it waited" " tier=fast result=reused-pass secs=[0-9]+ caller=manual " "$_log"

# 2. The same with a failing suite: the second repeats the first one's failure.
rm -f "$_st/suites"
export SLOW_EXIT=1
c5_bg a --fast; c5_bg b --fast; wait
unset SLOW_EXIT
c5_read a; _oa="$c5_out"; _ra="$c5_rc"; c5_read b; _ob="$c5_out"; _rb="$c5_rc"
c5_suites
[ "$c5_n" -eq 1 ] && ok "two failing runs started at once start one suite" || bad "two failing runs started at once start one suite ($c5_n started)" "$_oa$nl$_ob"
[ "$_ra" = 1 ] && [ "$_rb" = 1 ] && ok "and both fail" || bad "and both fail (exit $_ra and $_rb)" "$_oa$nl$_ob"
expect_output "the second reuses the first one's failure, and says so" \
  "^check: FAIL \(reused the fast failure at [0-9:]{5}, commit [0-9a-f]{7}, by manual, recorded while this check waited; nothing changed; run 'bash tools/check\.sh --fast' to see why\)$" "$_oa$nl$_ob"
c5_lock_gone "a failure"

# 3. A full request waits for a fast run, then runs its own full suite: a fast pass doesn't stand for a full request.
rm -f "$_st/suites"
c5_bg a --fast
_i=0; while [ ! -s "$_lock" ] && [ "$_i" -lt 100 ]; do sleep 0.1; _i=$((_i + 1)); done
_held=""; [ -f "$_lock" ] && IFS= read -r _held < "$_lock"
out="$(c5 --full --if-changed)"; status=$?
wait
expect_output "the lock names the run that holds it: its pid, start, time, caller, tier and time limit" \
  "^pid=[0-9]+ started=[0-9]+ at=[0-9]{2}:[0-9]{2} caller=manual tier=fast limit=300$" "$_held"
expect_output "a full request waits for a fast run" "^check: waiting for the check started [0-9:]{5} by manual \(fast tier, pid [0-9]+\)$" "$out"
expect_output "then says why the fast run's pass doesn't stand for it" "^check: running the full tier after the wait: the last pass was the fast tier, at " "$out"
expect_status "and runs its own full suite, which passes" 0 "$status" "$out"
c5_suites
[ "$c5_list" = "fast full " ] && ok "the full suite starts once the fast one has ended" || bad "the full suite starts once the fast one has ended" "$c5_list"

# 4. A stale lock, whose process is gone or which is older than twice the full tier's limit plus 600 s, is removed with a
# note, and the run goes on.
export SLOW_SECS=0
true & _dead=$!; wait "$_dead"
_now="${EPOCHSECONDS:-$(date +%s)}"
printf 'pid=%s started=%s at=09:15 caller=pre-commit tier=full\n' "$_dead" "$_now" > "$_lock"
out="$(c5 --fast)"; status=$?
expect_status "a run that finds a stale lock goes on, and passes" 0 "$status" "$out"
expect_output "it removes a lock whose process is gone, with a note naming its pid and start" \
  "^check: note: removed a stale lock \(pid $_dead, started 09:15 by pre-commit\): its process is gone$" "$out"
printf 'pid=%s started=1000 at=01:00 caller=stop-hook tier=fast\n' "$$" > "$_lock"
out="$(c5 --fast)"; status=$?
expect_status "and a run goes on past a lock that is too old" 0 "$status" "$out"
expect_output "older than twice the full tier's limit plus 600 s, though its process runs" \
  "^check: note: removed a stale lock \(pid $$, started 01:00 by stop-hook\): it is older than 7800 s, " "$out"
c5_lock_gone "a run that removed a stale lock"
# The age bound is the holder's limit (limit= in its lock) when that is longer than this run's: a lock 8000 s old, of a
# run with a 5000 s limit, isn't stale.
_c5_long="pid=$$ started=$((_now - 8000)) at=10:30 caller=pre-push tier=full limit=5000"
printf '%s\n' "$_c5_long" > "$_lock"
out="$(CHECK_WAIT=1 c5 --fast)"; status=$?
_held=""; IFS= read -r _held < "$_lock"
[ "$status" -eq 3 ] && [ "$_held" = "$_c5_long" ] && ok "a lock younger than twice its holder's limit plus 600 s stands, past this run's own bound" \
  || bad "a lock younger than twice its holder's limit plus 600 s stands, past this run's own bound (exit $status)" "$out"
# A lock whose pid runs (this selftest's, which isn't a check) but that no heartbeat has touched for 5 minutes names a
# pid another process has taken since, when that holds at two looks CHECK_UNTOUCHED_RECHECK seconds apart (75 by
# default): one look isn't enough, since a machine that wakes from sleep wakes the waiter before the holder's heartbeat.
printf 'pid=%s started=%s at=12:41 caller=pre-commit tier=full limit=3600\n' "$$" "$_now" > "$_lock"
touch -t 202001010000 "$_lock"
out="$(CHECK_WAIT=1 c5 --fast)"; status=$?
[ "$status" -eq 3 ] && [ -e "$_lock" ] && ok "one look at a lock no heartbeat has touched for 5 minutes leaves it alone" \
  || bad "one look at a lock no heartbeat has touched for 5 minutes leaves it alone (exit $status)" "$out"
out="$(CHECK_UNTOUCHED_RECHECK=1 c5 --fast)"; status=$?
expect_status "a run goes on past it once a second look, a poll later, finds it untouched too" 0 "$status" "$out"
expect_output "and says why it removed it" \
  "^check: note: removed a stale lock \(pid $$, started 12:41 by pre-commit\): it hasn't been touched for 5 minutes, though a running check touches it every minute$" "$out"
c5_lock_gone "a run that removed a lock no heartbeat touched"

# 4b. Another run takes the lock between this run's look at a stale one and its move (a stand-in mv plays that run,
# once): the moved lock is that run's, so it goes back, and this run waits for it, then runs its own suite once it is
# gone.
_c5_real_mv="$(command -v mv)"; mkdir -p "$work/c5-mv"
printf '#!/usr/bin/env bash\n[ -e "$C5_MV_DONE" ] || { : > "$C5_MV_DONE"; printf "%%s\\n" "$C5_MV_LINE" > "$C5_MV_LOCK"; }\nexec "$C5_REAL_MV" "$@"\n' > "$work/c5-mv/mv"
chmod +x "$work/c5-mv/mv"
rm -f "$_st/suites" "$work/c5-mv-done"; : > "$work/c5-mv.out"
printf 'pid=%s started=%s at=09:15 caller=pre-commit tier=full limit=3600\n' "$_dead" "$_now" > "$_lock"
_c5_live="pid=$$ started=$_now at=12:41 caller=stop-hook tier=fast limit=300"
( C5_MV_DONE="$work/c5-mv-done" C5_MV_LINE="$_c5_live" C5_MV_LOCK="$PWD/$_lock" C5_REAL_MV="$_c5_real_mv" \
  PATH="$work/c5-mv:$_f_gl:$PATH" bash tools/check.sh --fast > "$work/c5-mv.out" 2>&1; echo "$?" > "$work/c5-mv.rc" ) &
_bg=$!
_i=0; _o=""
while [ "$_i" -lt 100 ]; do
  IFS= read -r -d '' _o < "$work/c5-mv.out"
  case "$_o" in *"check: waiting for "*) break ;; esac
  sleep 0.1; _i=$((_i + 1))
done
_held=""; [ -f "$_lock" ] && IFS= read -r _held < "$_lock"
[ "$_held" = "$_c5_live" ] && ok "a lock another run took while this one removed a stale lock is put back" \
  || bad "a lock another run took while this one removed a stale lock is put back" "$_held$nl$_o"
expect_output "and the run waits for that run" "^check: waiting for the check started 12:41 by stop-hook \(fast tier, pid $$\)$" "$_o"
rm -f "$_lock"; wait "$_bg"
c5_read mv; c5_suites
[ "$c5_rc" = 0 ] && [ "$c5_n" -eq 1 ] && ok "then runs its own suite once that lock is gone: one suite, and a pass" \
  || bad "then runs its own suite once that lock is gone: one suite, and a pass (exit $c5_rc, $c5_n suites)" "$c5_out"
c5_lock_gone "that run"

# 5. CHECK_WAIT caps the wait: past it nothing starts, the check says it is busy and exits 3, and the other's lock stays.
printf 'pid=%s started=%s at=12:41 caller=pre-commit tier=full\n' "$$" "$_now" > "$_lock"
c5_suites; _n0="$c5_n"
out="$(CHECK_WAIT=1 c5 --fast)"; status=$?
expect_status "CHECK_WAIT past its limit exits 3" 3 "$status" "$out"
expect_output "with the busy line" "^check: busy: the check started 12:41 by pre-commit \(full tier\) is still running after [0-9]+ s; no second check started$" "$out"
c5_suites
[ "$c5_n" -eq "$_n0" ] && ok "and starts nothing" || bad "and starts nothing" "$c5_list"
_held=""; IFS= read -r _held < "$_lock"
[ "$_held" = "pid=$$ started=$_now at=12:41 caller=pre-commit tier=full" ] && ok "and leaves the other check's lock alone" || bad "and leaves the other check's lock alone" "$_held"
IFS= read -r -d '' _log < "$_st/check-runs.log"
expect_output "the run log says it was busy" " tier=fast result=busy secs=[0-9]+ caller=manual " "$_log"
rm -f "$_lock"

# 6. The lock is gone after a run that couldn't run (exit 3), and after one past its time limit (GNU timeout only).
out="$(PATH="$_no_gl_path" bash tools/check.sh --fast 2>&1)"; status=$?
expect_status "a run without gitleaks exits 3" 3 "$status" "$out"
c5_lock_gone "a run that couldn't run"
_c5_timeout=""
for _c in timeout gtimeout; do
  if "$_c" --version 2>/dev/null | grep -qi coreutils; then _c5_timeout="$_c"; break; fi
done
if [ -n "$_c5_timeout" ]; then
  export SLOW_SECS=5
  out="$(CHECK_TIMEOUT=1 c5 --fast)"; status=$?
  expect_status "a run past its time limit exits 3" 3 "$status" "$out"
  c5_lock_gone "a run past its time limit, with the ticker stopped"
else
  echo "  skip: no GNU timeout, so the lock after a run past its time limit isn't tested"
fi

# 7. The heartbeat, and a check killed with SIGKILL. With a line a second (CHECK_PROGRESS_EVERY=1), a running check
# touches its lock as often: a lock aged on disk is fresh again by the next progress line. Killed during its stack step,
# the check leaves its background loop behind for a tick at most: no progress line comes after that.
_c5_find=find; [ -x /usr/bin/find ] && _c5_find=/usr/bin/find
c5_ticks() { # the progress lines in c5-kill.out, in c5_t; in c5_ended whether the check printed its result, and in
  # c5_joined how many progress lines don't come after an empty line
  local l prev=""
  c5_t=0; c5_ended=0; c5_joined=0
  while IFS= read -r l; do
    case "$l" in
      "check: still running "*) c5_t=$((c5_t + 1)); [ -z "$prev" ] || c5_joined=$((c5_joined + 1)) ;;
      "check: PASS"*|"check: FAIL"*) c5_ended=1 ;;
    esac
    prev="$l"
  done < "$work/c5-kill.out"
}
# Long enough for the waits below on a busy machine: the check is killed well before its stack step ends.
export SLOW_SECS=15
rm -f "$_st/suites" "$_lock"
CHECK_PROGRESS_EVERY=1 PATH="$_f_gl:$PATH" bash tools/check.sh --fast > "$work/c5-kill.out" 2>&1 &
_bg=$!
_i=0; while [ ! -s "$_st/suites" ] && [ "$_i" -lt 100 ]; do sleep 0.1; _i=$((_i + 1)); done
touch -t 202001010000 "$_lock"
# Two lines after the lock was aged: a whole turn of the loop, its touch included, came after it.
c5_ticks; _t0="$c5_t"
_i=0; while [ "$c5_t" -le $((_t0 + 1)) ] && [ "$_i" -lt 60 ]; do sleep 0.1; c5_ticks; _i=$((_i + 1)); done
[ -n "$("$_c5_find" "$_lock" -mmin -5 2>/dev/null)" ] && ok "a running check touches its lock (the heartbeat)" \
  || bad "a running check touches its lock (the heartbeat)" "$(cat "$work/c5-kill.out")"
_held=""; [ -f "$_lock" ] && IFS= read -r _held < "$_lock"
_pid="${_held#pid=}"; _pid="${_pid%% *}"
# A lock with another run's line in it is that run's: the heartbeat leaves it alone.
printf 'pid=%s started=%s at=12:41 caller=pre-commit tier=full limit=3600\n' "$$" "$_now" > "$_lock"
touch -t 202001010000 "$_lock"
c5_ticks; _t0="$c5_t"
_i=0; while [ "$c5_t" -le $((_t0 + 1)) ] && [ "$_i" -lt 60 ]; do sleep 0.1; c5_ticks; _i=$((_i + 1)); done
[ -z "$("$_c5_find" "$_lock" -mmin -5 2>/dev/null)" ] && ok "and touches no other run's lock" \
  || bad "and touches no other run's lock" "$(cat "$work/c5-kill.out")"
kill -9 "${_pid:-$_bg}" 2>/dev/null; wait "$_bg" 2>/dev/null
sleep 2; c5_ticks; _t1="$c5_t"
sleep 2; c5_ticks
[ "$c5_t" -eq "$_t1" ] && [ "$_t1" -gt 0 ] && [ "$c5_ended" -eq 0 ] \
  && ok "a check killed with SIGKILL leaves no progress line after a tick: its loop ends with it" \
  || bad "a check killed with SIGKILL leaves no progress line after a tick: its loop ends with it ($_t1 lines, then $c5_t)" "$(cat "$work/c5-kill.out")"
[ "$c5_joined" -eq 0 ] && ok "the progress line starts with a line break when the output isn't a terminal" \
  || bad "the progress line starts with a line break when the output isn't a terminal" "$(cat "$work/c5-kill.out")"
rm -f "$_lock"
unset SLOW_SECS
}

part_check_ts() {
echo "check, TypeScript tiers"
# The TypeScript stack in both tiers, with a stand-in npx that logs each command and plays tsc, eslint and vitest (or
# jest): vitest writes a json report of $FAKE_VITEST_TESTS tests (3 by default) in two files, and $FAKE_<TOOL>_EXIT is
# each tool's exit status. The fixture has a package.json, a vitest config, an eslint config and a node_modules folder,
# so nothing installs, and a [tests] fast-map rule for its translations. A stand-in gitleaks finds nothing.
ts="$work/ts-app"; new_repo "$ts" >/dev/null 2>&1
mkdir -p "$ts/tools/stacks" "$ts/src/i18n" "$ts/tests" "$ts/node_modules"
cp "$src/framework/tools/check.sh" "$ts/tools/" && cp "$src/framework/tools/stacks/typescript.sh" "$ts/tools/stacks/"
ts_cfg='[project]\nstack = typescript\n\n[gitleaks]\nmin-version = 8.18.0\n\n[tests]\nfast-map = src/i18n/*.json:tests/i18n.test.ts\n'
printf '%b' "$ts_cfg" > "$ts/tools/check.cfg"
printf '{ "name": "ts-app", "private": true }\n' > "$ts/package.json"
printf 'export default {};\n' > "$ts/vitest.config.ts"
printf '{ "root": true }\n' > "$ts/.eslintrc.json"
printf 'export const a = 1;\n' > "$ts/src/a.ts"
printf 'import { a } from "./a";\n' > "$ts/src/a.test.ts"
printf '{ "hello": "Hello" }\n' > "$ts/src/i18n/en.json"
printf 'import en from "../src/i18n/en.json";\n' > "$ts/tests/i18n.test.ts"
printf '/node_modules/\n.app-director/state/\n' > "$ts/.gitignore"
(cd "$ts" && git add -A && git_q commit -qm "a TypeScript app") >/dev/null 2>&1
cd "$ts" || exit 3
_ts_bin="$work/fake-ts-bin"; mkdir -p "$_ts_bin"
printf '#!/bin/bash\n[ "$1" = version ] && echo v8.30.1\nexit 0\n' > "$_ts_bin/gitleaks"
cat > "$_ts_bin/npx" << 'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_NPX_LOG"
case "$1" in
  tsc) exit "${FAKE_TSC_EXIT:-0}" ;;
  eslint) exit "${FAKE_ESLINT_EXIT:-0}" ;;
  vitest)
    out=""
    for a in "$@"; do case "$a" in --outputFile.json=*) out="${a#--outputFile.json=}" ;; esac; done
    root="$(pwd -W 2>/dev/null || pwd -P)"
    [ -z "$out" ] || printf '{"numTotalTests":%s,"testResults":[{"startTime":1000,"endTime":1500,"name":"%s/src/a.test.ts"},{"startTime":1000,"endTime":4200,"name":"%s/tests/i18n.test.ts"}]}' \
      "${FAKE_VITEST_TESTS:-3}" "$root" "$root" > "$out"
    exit "${FAKE_VITEST_EXIT:-0}" ;;
  jest) exit "${FAKE_JEST_EXIT:-0}" ;;
esac
exit 0
FAKE
chmod +x "$_ts_bin/gitleaks" "$_ts_bin/npx"
_npx_log="$work/fake-npx.log"
ts_check() { : > "$_npx_log"; FAKE_NPX_LOG="$_npx_log" PATH="$_ts_bin:$PATH" bash tools/check.sh "$@" 2>&1; }
_have_node=0; command -v node >/dev/null 2>&1 && _have_node=1

out="$(ts_check)"; status=$?; log="$(cat "$_npx_log")"
expect_status "TypeScript: no argument runs the full tier, and passes" 0 "$status" "$out"
expect_output "the full tier type-checks with no build info of the fast tier's" "^tsc --noEmit$" "$log"
expect_output "lints the whole project" "^eslint \. --max-warnings 0$" "$log"
expect_output "and runs the whole suite, with the dot reporter (the output isn't a terminal) and the json report" \
  "^vitest run --reporter=dot --reporter=json --outputFile\.json=/.*/\.app-director/state/vitest\.json$" "$log"
expect_output "and says PASS (full tier)" "^check: PASS \(full tier\)$" "$out"
if [ "$_have_node" -eq 1 ]; then
  expect_output "after a full run, the slowest test files, under their heading" "^check: slowest test files \(full tier\):$" "$out"
  expect_output "the slowest first, with its path from the repository root" "^ +3\.2 s  tests/i18n\.test\.ts$" "$out"
  expect_output "the summary counts the tests" "^check:   tests: 3 run, the whole suite$" "$out"
else
  echo "  skip  the slowest test files and the test count (no node to read vitest's report)"
fi
out="$(FAKE_TSC_EXIT=2 ts_check)"; expect_status "the full tier fails when tsc fails" 1 $? "$out"
out="$(FAKE_VITEST_EXIT=1 ts_check)"; expect_status "and when a test fails" 1 $? "$out"

printf 'export const a = 2;\n' > src/a.ts
out="$(FAKE_VITEST_TESTS=1 ts_check --fast)"; status=$?; log="$(cat "$_npx_log")"
expect_status "--fast passes after a change to a source file" 0 "$status" "$out"
expect_output "the fast tier type-checks the whole project, incrementally, with its build info in the state folder" \
  "^tsc --noEmit --incremental --tsBuildInfoFile /.*/\.app-director/state/tsc-fast\.tsbuildinfo$" "$log"
expect_output "with a legacy eslint config (.eslintrc*), it lints the whole project, as the full tier does" "^eslint \. --max-warnings 0$" "$log"
expect_output "and says so" "^check: eslint on the whole project: a legacy config \(\.eslintrc\*\) can't lint only the changed files$" "$out"
expect_output "in the summary too" "^check:   lint: eslint on the whole project, as the config is a legacy one \(\.eslintrc\*\)$" "$out"
expect_output "and runs only the tests related to the change, with coverage off" \
  "^vitest related --run --passWithNoTests --coverage\.enabled=false --reporter=dot --reporter=json --outputFile\.json=[^ ]*/vitest\.json src/a\.ts$" "$log"
expect_output "a fast pass says when the full tier is due" "^check: PASS \(fast tier; full tier due in 10 commits\)$" "$out"
expect_output "and what the fast tier left to the full tier" "^check:   left to the full tier: the tests not related to the change$" "$out"
expect_no_output "a fast run prints no slowest test files" "slowest test files" "$out"
if [ "$_have_node" -eq 1 ]; then
  expect_output "the summary counts the tests run against the last full run's" "^check:   tests: 1 of 3 run, 2 not related to the change$" "$out"
  expect_output "and the run log has both" " tier=fast result=pass .* tests=1/3$" "$(tail -n 1 .app-director/state/check-runs.log)"
fi
printf 'export const a = 1;\n' > src/a.ts

printf '{ "hello": "Hej" }\n' > src/i18n/en.json
out="$(ts_check --fast)"; log="$(cat "$_npx_log")"
expect_output "a change matching [tests] fast-map runs the test it maps to" "^vitest related --run --passWithNoTests .* tests/i18n\.test\.ts$" "$log"
expect_no_output "instead of the tests related to the changed file" "^vitest .*src/i18n/en\.json" "$log"
rm src/i18n/en.json
out="$(ts_check --fast)"; log="$(cat "$_npx_log")"
expect_output "removing a file that matches a [tests] fast-map rule still runs the test it maps to" \
  "^vitest related --run --passWithNoTests .* tests/i18n\.test\.ts$" "$log"
printf '{ "hello": "Hello" }\n' > src/i18n/en.json

printf '%bignore = marketing/\n' "$ts_cfg" > tools/check.cfg
git add tools/check.cfg >/dev/null 2>&1 && git_q commit -qm "ignore marketing" >/dev/null 2>&1
fp1="$(bash tools/check.sh --fingerprint)"
mkdir -p marketing && printf '{ "title": "Buy" }\n' > marketing/page.json
[ "$(bash tools/check.sh --fingerprint)" = "$fp1" ] && ok "a change only under [tests] ignore doesn't change the fingerprint" \
  || bad "a change only under [tests] ignore doesn't change the fingerprint"
out="$(ts_check --fast)"; log="$(cat "$_npx_log")"
expect_no_output "nor start a test" "^vitest" "$log"
expect_output "the fast tier says no tests are related to the change" "^check: no tests related to the change$" "$out"
printf 'x\n' > .gitleaksignore
out="$(ts_check --fast)"; log="$(cat "$_npx_log")"
expect_output "a change to only the check's own files (.gitleaksignore) has no tests related to it" "^check: no tests related to the change$" "$out"
expect_no_output "and starts none" "^vitest" "$log"
rm .gitleaksignore

printf '%bignore = marketing/\nworkers = 2\n' "$ts_cfg" > tools/check.cfg
printf 'export default [];\n' > eslint.config.js; printf 'export const a = 3;\n' > src/a.ts
out="$(ts_check --fast)"; log="$(cat "$_npx_log")"
expect_output "[tests] workers sets vitest's --maxWorkers" "^vitest related .* --maxWorkers=2 src/a\.ts" "$log"
expect_output "a flat eslint config lints only the changed files, with --no-warn-ignored" "^eslint --max-warnings 0 --no-warn-ignored src/a\.ts eslint\.config\.js$" "$log"
expect_output "a changed tools file makes the full tier due now" "^check: PASS \(fast tier; full tier due now: tools/check\.cfg changed\)$" "$out"
git add -A >/dev/null 2>&1 && git_q commit -qm "a flat eslint config" >/dev/null 2>&1
printf '{ "hello": "Hej" }\n' > src/i18n/en.json
out="$(ts_check --fast)"; log="$(cat "$_npx_log")"
expect_output "with a flat config and no changed file to lint, eslint is skipped, and says so" "^check: eslint skipped: no changed file to lint$" "$out"
expect_no_output "and doesn't run" "^eslint" "$log"
printf '{ "hello": "Hello" }\n' > src/i18n/en.json
# A change of more than 100 files (101 here) runs as the full tier, since its file lists wouldn't fit on one command line.
mkdir -p src/many
_i=0; while [ "$_i" -le 100 ]; do printf 'export const n = %s;\n' "$_i" > "src/many/f$_i.ts"; _i=$((_i + 1)); done
out="$(ts_check --fast)"; status=$?; log="$(cat "$_npx_log")"
expect_status "a fast request with 101 changed files passes" 0 "$status" "$out"
expect_output "it runs as the full tier, and says why" "^check: note: 101 changed source files, so the fast tier runs as the full tier$" "$out"
expect_output "tsc as the full tier runs it" "^tsc --noEmit$" "$log"
expect_output "eslint over the whole project" "^eslint \. --max-warnings 0$" "$log"
expect_output "and the whole suite" "^vitest run --reporter=dot " "$log"
expect_no_output "with no file list" "^vitest related|^eslint .*src/many" "$log"
expect_output "it reports a full pass" "^check: PASS \(full tier\)$" "$out"
{ IFS= read -r _l1; IFS= read -r _l2; } < .app-director/state/last-pass
expect_output "and records one" "^tier=full " "$_l2"
rm -rf src/many
# Only source paths count toward it: 150 changed images keep the fast tier.
mkdir -p assets/many
_i=0; while [ "$_i" -lt 150 ]; do : > "assets/many/i$_i.png"; _i=$((_i + 1)); done
out="$(ts_check --fast)"
expect_no_output "150 changed images keep the fast tier" "so the fast tier runs as the full tier" "$out"
rm -rf assets
printf '%bignore = marketing/\nfast = none\n' "$ts_cfg" > tools/check.cfg
out="$(ts_check --fast)"; log="$(cat "$_npx_log")"
expect_no_output "[tests] fast = none runs no test" "^vitest" "$log"
expect_output "and leaves every test to the full tier" "^check:   left to the full tier: every test, eslint on unchanged files$" "$out"
printf '%bignore = marketing/\nfast = all\n' "$ts_cfg" > tools/check.cfg
out="$(ts_check --fast)"; log="$(cat "$_npx_log")"
expect_output "[tests] fast = all runs the whole suite" "^vitest run --reporter=dot " "$log"
expect_output "and leaves only eslint on the unchanged files" "^check:   left to the full tier: eslint on unchanged files$" "$out"
printf '%bignore = marketing/\n' "$ts_cfg" > tools/check.cfg
rm vitest.config.ts; printf 'module.exports = {};\n' > jest.config.js; printf 'export const a = 4;\n' > src/a.ts
out="$(ts_check --fast)"; status=$?; log="$(cat "$_npx_log")"
expect_status "the fast tier passes with jest" 0 "$status" "$out"
expect_output "jest runs the tests related to the changed files, with coverage off" "^jest --findRelatedTests src/a\.ts .*--passWithNoTests --coverage=false$" "$log"
out="$(FAKE_JEST_EXIT=1 ts_check --fast)"; expect_status "and fails when they fail" 1 $? "$out"
}

part_guard() {
    cd "$work/guard-app" || exit 3
# --- guard-commands hook --------------------------------------------------------------------------
echo "guard-commands hook"
guard_dir="$work/guard-cases"; mkdir -p "$guard_dir"
git_fail=""
guard_report() { # guard_report <failed cases> <what is wrong> <what holds>
  if [ -n "$1" ]; then
    bad "$2"
    printf '%s\n' "${1#$'\n'}" | sed 's/^/          /'
  else ok "$3"; fi
}
# json_str <text>: sets JSON_STR to the text as the inside of a JSON string, with \, ", a line break, a tab and a return escaped. (A ${//}
# replacement left a backslash single and turned a line break into n, so a newline case reached the guard as a joined word.)
json_str() {
  local s="$1" out="" i c
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:i:1}"
    case $c in
      '\') out+='\\' ;;
      '"') out+='\"' ;;
      $'\n') out+='\n' ;;
      $'\t') out+='\t' ;;
      $'\r') out+='\r' ;;
      *) out+="$c" ;;
    esac
  done
  JSON_STR="$out"
}
# The guard cases (Director-Driven-Development B41). guard queues a case: its JSON payload goes to a file, and its expected
# exit code, tool and text are kept. guard_run runs the queued cases, up to guard_jobs at a time, each as its own run of the
# hook with its own payload, then checks every exit code against that case's expected one, in the order the cases were queued,
# so a failure names its case and why. Each block of cases ends with guard_run and guard_report.
# Each lane is a bash of its own that holds no variables, and each case sources the hook in a subshell of it, with no
# arguments and the payload on stdin (T283). The hook sees what a run of its own sees, and on Windows this takes a fraction
# of the time of starting a bash on a script this long, thousands of times over. The cases below that need the hook's
# own environment (env.json) or its real time (slow.json) still start it as Claude Code does.
guard_jobs=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4); [ "$guard_jobs" -le 6 ] || guard_jobs=6
guard_cmds=(); guard_exps=(); guard_tools=(); guard_msgs=()
guard() { # guard <expected-exit> <command> [tool name: Bash by default, or PowerShell] [pattern its message must match, any case]
  local n=${#guard_cmds[@]} tool="${3:-Bash}"
  json_str "$2"
  printf '{"session_id":"s","tool_name":"%s","tool_input":{"command":"%s","description":"run"}}' "$tool" "$JSON_STR" > "$guard_dir/$n.json"
  guard_cmds+=("$2"); guard_exps+=("$1"); guard_tools+=("$tool"); guard_msgs+=("${4:-}")
}
guard_run() {
  local n=${#guard_cmds[@]} lanes i j k rc msg="" said=$'\n' files
  lanes=$(((n + 19) / 20)); [ "$lanes" -le "$guard_jobs" ] || lanes=$guard_jobs
  for ((k = 0; k < lanes; k++)); do
    bash -c 'while [ "$2" -lt "$4" ]; do
      ( set --; . .claude/hooks/guard-commands.sh ) < "$1/$2.json" >/dev/null 2>"$1/$2.err"
      echo "$?" > "$1/$2.rc"
      set -- "$1" "$(($2 + $3))" "$3" "$4"
    done' guard-lane "$guard_dir" "$k" "$lanes" "$n" &
  done
  wait
  # One grep for each message, over the cases that expect it.
  for ((i = 0; i < n; i++)); do
    [ -n "${guard_msgs[i]}" ] && [ "${guard_msgs[i]}" != "$msg" ] || continue
    msg="${guard_msgs[i]}"; files=()
    for ((j = i; j < n; j++)); do [ "${guard_msgs[j]}" != "$msg" ] || files+=("$guard_dir/$j.err"); done
    said+="$(grep -li -- "$msg" "${files[@]}")"$'\n'
  done
  for ((i = 0; i < n; i++)); do
    read -r rc < "$guard_dir/$i.rc" || rc=-1
    if [ "$rc" -ne "${guard_exps[i]}" ]; then
      git_fail="$git_fail"$'\n'"  guard exited $rc, expected ${guard_exps[i]} (${guard_tools[i]}): ${guard_cmds[i]//$'\n'/ NL }"
    elif [ -n "${guard_msgs[i]}" ] && [[ $said != *$'\n'"$guard_dir/$i.err"$'\n'* ]]; then
      git_fail="$git_fail"$'\n'"  guard's message lacks \"${guard_msgs[i]}\" (${guard_tools[i]}): ${guard_cmds[i]//$'\n'/ NL }"
    fi
  done
  guard_cmds=(); guard_exps=(); guard_tools=(); guard_msgs=()
  rm -f "$guard_dir"/*.json "$guard_dir"/*.rc "$guard_dir"/*.err
}
for cmd in \
    'git commit -m x --no-verify' \
    'git commit -nm "x"' \
    'git push origin main --force' \
    'git push --force-with-lease=main origin' \
    'git push origin +main' \
    'git reset HEAD --hard' \
    'git config core.hooksPath ""' \
    'git clean -fd' \
    'git checkout -- .' \
    'git restore .' \
    'git stash drop' \
    'git branch -D topic' \
    'git branch -D proto/quick-add' \
    'git worktree remove --force ../todo-web-proto-quick-add' \
    'git worktree remove --forc ../x' \
    'git worktree remove --f ../x' \
    "git worktree remove '--force' ../x" \
    'git worktree remove ../todo-web-proto-quick-add -f' \
    'git worktree remove -ff ../x' \
    'git -C ../todo-web worktree remove --fo ../x' \
    'git branch -d -f proto/quick-add' \
    'git branch --delete --force proto/quick-add' \
    'git branch --del --forc proto/quick-add' \
    'git branch -df proto/quick-add' \
    'git branch -qD proto/quick-add' \
    'git worktree remove --{force,} x' \
    'git worktree remove -{f,f} x' \
    'git worktree remove x$IFS--force' \
    'git worktree remove x${IFS}--force' \
    'git branch -{D,} x' \
    'git branch -{d..f} x' \
    'git --git-dir .git worktree remove --forc x' \
    'git --work-tree . branch -df x' \
    'git --config-env x=Y worktree remove -f x' \
    'git branch -M a b' \
    'git branch -C a b' \
    'git branch -m -f a b' \
    'git branch --move --force a b' \
    'git branch -cf a b' \
    'git worktree add -B proto/x ../x main' \
    'git worktree add -f ../x proto/x' \
    'git worktree add --forc ../x proto/x' \
    'git --attr-source HEAD worktree remove -f x' \
    'git --namespace x branch -df y' \
    'git --super-prefix x worktree add -B y ../y main' \
    'cat .env' \
    'head .env' \
    'cat ./server.key' \
    'cat certificates/cert.pem'; do
  guard 2 "$cmd"
done
for cmd in \
    'git status --short' \
    'git commit -m "feat: add form (T4)" -- src/ui/TodoList.ts' \
    'git push origin feature-branch' \
    'git restore --staged src/ui/TodoList.ts' \
    'git checkout -b topic' \
    'git reset --soft HEAD~1' \
    'git switch main' \
    'git worktree add --no-track -b proto/quick-add ../todo-web-proto-quick-add main' \
    'git worktree remove ../todo-web-proto-quick-add' \
    'git branch -d proto/quick-add' \
    'git branch -f topic main' \
    'git branch -uorigin/feature-dev' \
    'git commit -m "git branch -d -f x"' \
    'git log HEAD@{1}' \
    'git log --oneline @{u}..HEAD' \
    'git diff stash@{0}' \
    'git branch -m old new' \
    'git branch -c old new' \
    'git commit -m "a {b,c} message"' \
    'git commit -m "-n"' \
    "git commit -m '-n'" \
    'bash tools/prototype.sh start quick-add' \
    'bash tools/prototype.sh remove quick-add' \
    'cat .env.example'; do
  guard 0 "$cmd"
done
for cmd in \
    $'python3 - <<\'EOF\' 2>/dev/null || echo "no python"\nEOF' \
    $'python - <<EOF\nEOF' \
    $'py.exe - <<-"EOF"\n  EOF' \
    $'python3 - <<\'EOF\' 2>/dev/null || python - <<\'EOF2\'\nEOF\nprint(1)\nEOF2' \
    $'python3 - <<\'EOF\'\nprint("hi")\nEOF' \
    'until grep -q "^exit" /tmp/x/tasks/abc.output; do sleep 5; done' \
    'until test -f done.txt; do sleep 5; done' \
    'while true; do sleep 2; done' \
    'timeout 600 bash -c "until test -f x; do sleep 5; done"' \
    'echo go && until test -f x; do sleep 1; done' \
    'sleep 300' \
    'sleep 5m'; do
  guard 2 "$cmd"
done
for cmd in \
    $'python3 --version 2>/dev/null || echo "no python"' \
    "timeout 240 bash -c 'until test -f x; do sleep 5; done'" \
    '(timeout 4m bash -c "while true; do sleep 1; done")' \
    'echo go && timeout 120s bash -c "until test -f x; do sleep 1; done"' \
    'until grep -qE "exited with code|\[killed\]" /tmp/x/tasks/abc.output; do sleep 5; done' \
    'sleep 5' \
    'sleep 280' \
    'git commit -m "until x; do sleep 3; done"'; do
  guard 0 "$cmd"
done
# The wildcard git allow rules (`git diff *`, `git log *`, `git show *`, `git stash *`, `git commit *`,
# `git tag *`, `git grep *`) take any flag, and some flags write a file (--output), read a file outside
# the repository (--no-index, commit and tag -F and --file, a `git diff` of a path outside it) or run a
# configured command (--ext-diff, grep -O and --open-files-in-pager), with no prompt. The hook reads the
# command as the shell hands it to git, so a flag that is quoted, escaped, attached to a short option,
# hidden in a cluster (-iO) or behind another command is still seen, and a flag named inside a commit
# message or a heredoc body is not. The deny rules in settings.json cover the plain forms; the hook
# covers the rest, and commit and tag -F, where a rule can't tell `-F <path>` from `-F -` (the docs
# repo's security assessment, product/security/2026-10-29.md, F1; B14). The same goes for a script path
# under tools/ with a `..` segment, which `Bash(bash tools/stacks/*.sh*)` would match, and for the
# shell reads of the credential stores and the gh and git commands that print a stored credential (B15),
# and of the .env files with values, while the committed templates (.env.example and the like) stay readable (B21).
# The hook tests every argument of a read, so the file may follow an option or another file (B22).
for cmd in \
    'git log -1 --format=probe --output=/tmp/probe.txt' \
    'git log --output /tmp/probe.txt' \
    'git show --output /tmp/probe.txt HEAD' \
    'git diff --output=probe.txt' \
    'git stash show --output=/tmp/probe.txt' \
    "git log '--output=/tmp/probe.txt'" \
    'git log "--no-index"' \
    'git log --out\put=/tmp/probe.txt' \
    'git log --output="/tmp/my probe.txt"' \
    'git diff --no-index a b' \
    'git diff --no-index /dev/null /etc/hosts' \
    'git log -p --ext-diff' \
    'git diff --ext-diff' \
    'git diff /etc/hosts README.md' \
    'git diff ../other.txt README.md' \
    'git commit -F /tmp/msg.txt' \
    'git commit -F/tmp/msg.txt' \
    'git commit -aF /tmp/msg.txt' \
    'git commit -F "/tmp/my msg.txt"' \
    'git commit --file /tmp/msg.txt' \
    'git commit --file=/tmp/msg.txt' \
    'git commit -F - -F /tmp/msg.txt' \
    'git add -A && git commit -F /tmp/msg.txt' \
    'git -C work/App-Director log --output=/tmp/probe.txt' \
    $'git commit -q -F - <<\'EOF\'\nmsg\nEOF\ngit log --output=/tmp/probe.txt' \
    'git grep -O foo' \
    'git grep -Oecho foo' \
    'git grep -n -Ovim foo' \
    'git grep -iO foo' \
    'git grep -nOvim foo' \
    'git grep -e foo -Oecho' \
    'git grep -A 1 -Oecho foo' \
    'git grep --open-files-in-pager foo' \
    'git grep --open-files-in-pager=echo foo' \
    'git grep --open=echo foo' \
    'git grep --op foo' \
    'git grep "-Obj"' \
    "git grep '-Oecho' foo" \
    'git grep -nO"echo hi" foo' \
    'git grep --"open-files-in-pager"=echo foo' \
    'git -C work/App-Director grep -Oecho foo' \
    'git add . && git grep -Oecho foo' \
    'git tag -F /tmp/msg.txt v1' \
    'git tag -aF /tmp/msg.txt v1' \
    'git tag -a v1 -F/tmp/msg.txt' \
    'git tag -a v1 --file=/tmp/msg.txt' \
    'git tag --file /tmp/msg.txt v1' \
    'git tag --fi=/tmp/msg.txt v1' \
    'bash tools/stacks/../../x.sh' \
    'bash -x tools/stacks/../x.sh' \
    'bash tools/stacks/.\./x.sh' \
    'bash tools/stacks/".."/x.sh' \
    'sh ./tools/../x.sh' \
    '/bin/bash tools/stacks/../x.sh' \
    'cat ~/.ssh/id_ed25519' \
    'head "$HOME/.git-credentials"' \
    'cat ~/.config/gh/hosts.yml' \
    'less "/c/Users/V/AppData/Roaming/GitHub CLI/hosts.yml"' \
    'cat "C:\Users\V\.ssh\id_rsa"' \
    'cat "certs/server.pem"' \
    "head '.env'" \
    'cat .env.local' \
    'head ./.env.production' \
    'cat "config/.env.staging"' \
    'less .env.development.local' \
    "tail '.env.test'" \
    'tail -n 20 .env.local' \
    'cat .env.example; cat .env.local' \
    'cat README.md .env.local' \
    'tail -n 20 .env' \
    'head -5 certs/server.pem' \
    'cat docs/a.md "deploy.key"' \
    'less -R .env.production' \
    'gh auth token' \
    'gh auth status -t' \
    "printf 'protocol=https\\nhost=github.com\\n' | git credential fill" \
    "printf 'protocol=https\\nhost=github.com\\n' | git credential get"; do
  guard 2 "$cmd"
done
for cmd in \
    'git log --oneline -5' \
    'git diff HEAD' \
    'git diff --cached --stat' \
    'git diff origin/main..HEAD -- docs/index.md' \
    'git show HEAD:README.md' \
    'git commit -m "fix the --output handling"' \
    'git commit -F -' \
    'git commit --file=-' \
    $'git commit -q -F - <<\'EOF\'\nfix the --output and --no-index handling, not -F /tmp/x\nEOF' \
    'git stash list' \
    'git worktree list' \
    'git grep -n foo' \
    "git grep -i -e x -- '*.md'" \
    'git grep -ie -O' \
    'git grep -e -Oecho' \
    'git grep -n "an -Obj pattern"' \
    'git grep -c --no-open-files-in-pager foo' \
    'git grep --only-matching foo' \
    'git log --grep -O' \
    'git tag -a v1 -m x' \
    'git tag -a v1 -m "see --file and -F"' \
    'git tag -n' \
    'git tag -a v1 -F -' \
    'git tag --file=- -a v1' \
    'bash tools/check.sh' \
    'bash tools/setup-clone.sh' \
    'bash tools/stacks/typescript.sh --since HEAD~3..HEAD' \
    'bash tools/check.sh && git log origin/main..HEAD' \
    'bash ../x.sh' \
    'cd tools && bash ../x.sh' \
    'cat README.md' \
    'cat product/brief.md' \
    'cat .env.example' \
    'cat config/.env.sample' \
    'head .env.template' \
    'cat .env.dist' \
    'cat README.md docs/x.md' \
    'tail -n 20 .env.example' \
    'head -5 notes.txt' \
    'cat .env.example .env.sample' \
    'grep -n ssh ONBOARDING.md' \
    'git log --oneline -3' \
    'ls ~/.ssh' \
    'gh auth status'; do
  guard 0 "$cmd"
done
# A git command on a later line, after a newline or a tab, reaches every git rule (Director-Driven-Development
# T268). The early tests used to read the JSON-escaped text, where a newline is the two characters \n, so the
# hook exited before any rule ran. A backslash that escapes a line's end joins the next line to the command;
# an even run of backslashes ends the line, as the shell does.
for cmd in \
    $'cd x\ngit branch -D y' \
    $'cd x\ngit commit --no-verify -m x' \
    $'cd x\n\tgit log --output=/tmp/x' \
    $'echo a\ngit push --force' \
    $'git commit \\\n-n -m x' \
    $'gi\\\nt push --force' \
    $'git status \\\\\ngit commit -F /tmp/x' \
    $'git push origin main\t--force' \
    $'cat\t.env' \
    $'cd x\ngit credential fill'; do
  guard 2 "$cmd"
done
for cmd in \
    $'git status\ngit log --oneline -3' \
    $'cd x\ngit commit -q -F - <<\'EOF\'\nfix the --output and --no-index handling, not -F /tmp/x\nEOF' \
    $'echo a\n\tgit log --format=%s\n--output=x'; do
  guard 0 "$cmd"
done
# A -n or --no-verify quoted or split is the same flag, so it skips the project check as `git commit -n` does (B26,
# T271). The words are read after their quotes resolve. A -- ends the flags unless the word before it starts with -:
# an option may take it as its value, and git does (`git commit -m -- -n` and `--mess -- -n` commit with the message --
# and skip the hook). A word an option takes as its value (-m "-n") isn't a flag, and a -n after a -- (a path) isn't either.
for cmd in \
    "git commit '-n' -m x" \
    'git commit "-n" -m x' \
    'git commit -""n -m x' \
    "git commit --no-ve''rify -m x" \
    "git commit -'n' -m x" \
    "git commit \$'-n' -m x" \
    'git commit "--no-ve""rify" -m x' \
    'git commit -m x "-n"' \
    "git commit -m -- '-n'" \
    "git commit --mess -- '-n'"; do
  guard 2 "$cmd"
done
for cmd in \
    'git commit -m "message naming -n"' \
    'git commit -m "-n is a message"' \
    'git commit -m "-nodejs fix"' \
    "git commit -m x -- '-n'" \
    $'git commit -q -F - <<\'EOF\'\nmessage naming -n\nEOF' \
    'git tag -n'; do
  guard 0 "$cmd"
done
# The PowerShell tool hands the hook the same text, so the branch and worktree rules block the same commands there.
for cmd in \
    'git worktree remove --force x' \
    'git worktree add -B y ../y main' \
    'git branch -M a b' \
    'git branch -df x' \
    'git branch -m -f a b' \
    "git commit '-n' -m x"; do
  guard 2 "$cmd" PowerShell
done
for cmd in \
    'git worktree add --no-track -b proto/x ../x main' \
    'git branch -m old new' \
    'git branch -uorigin/feature-dev' \
    'git commit -m "-n"'; do
  guard 0 "$cmd" PowerShell
done
guard_run
guard_report "$git_fail" "the guard hook blocks a destructive git command, a hang, a git flag that writes or reads a file and a credential read, or blocks a plain form" "the guard hook blocks a destructive git command, a hang, a git flag that writes or reads a file and a credential read, and passes the plain forms"
git_fail=""
grep -q "Commands that may run long" .app-director/rules.md && grep -q "run_in_background" .app-director/rules.md \
  && grep -q "Python its script from a heredoc" .app-director/rules.md && grep -q "python3 --version" .app-director/rules.md \
  && ok "rules.md gives the time-limit, background and Python-heredoc rules" \
  || bad "rules.md gives the time-limit, background and Python-heredoc rules"

# The hook runs under macOS's bash 3.2 too (CLAUDE.md > Scripts), so it holds no bash 4 form: case conversion (${x,,}, ${x^^}),
# an associative array, mapfile or readarray, coproc, |&, or a negative substring offset (${x: -1}). Comment lines are skipped.
bash4=$(grep -nE '^[^#]*(\$\{[A-Za-z_0-9]+(\[[^]]*\])?(,,|\^\^)\}|(declare|local|typeset) +-[a-zA-Z]*A|(^|[;&| ])(mapfile|readarray) +|(^|[;&| ])coproc +[A-Za-z]|[[:space:]]\|&[[:space:]]|\$\{[A-Za-z_0-9@*]+(\[[^]]*\])?: -[0-9])' .claude/hooks/guard-commands.sh || true)
if [ -z "$bash4" ]; then ok "the guard hook uses no bash 4 form, so it runs under bash 3.2"
else bad "the guard hook uses a bash 4 form (bash 3.2 on macOS has none)" "$bash4"; fi

# The guard's reading of a command, case by case (Director-Driven-Development T276; the B numbers are its bug IDs): the PowerShell
# tool, the readers of credential files, continuations (a backslash in Bash, a backtick in PowerShell, and the comments
# that end in one), tabs, command substitutions, variables, shell wrappers, wait loops, heredoc bodies, git configuration
# and program flags, quoted and capitalised names, and Invoke-Expression.
if [ ! -f .claude/settings.json ]; then
  bad ".claude/settings.json is missing, so the guard's wiring can't be checked"
else
  git_fail=""
  perm_allow=$(sed -n '/"allow": *\[/,/\]/p' .claude/settings.json)
  if [ ! -f .claude/hooks/guard-commands.sh ]; then
    git_fail="$git_fail"$'\n'"  .claude/hooks/guard-commands.sh is missing"
  else
    for cmd in \
        'git log -1 --format=probe --output=/tmp/probe.txt' \
        'git log --output /tmp/probe.txt' \
        'git show --output /tmp/probe.txt HEAD' \
        'git diff --output=probe.txt' \
        'git stash show --output=/tmp/probe.txt' \
        "git log '--output=/tmp/probe.txt'" \
        'git log "--no-index"' \
        'git log --out\put=/tmp/probe.txt' \
        'git log --output="/tmp/my probe.txt"' \
        'git diff --no-index a b' \
        'git diff --no-index /dev/null /etc/hosts' \
        'git log -p --ext-diff' \
        'git diff --ext-diff' \
        'git diff /etc/hosts README.md' \
        'git diff ../other.txt README.md' \
        'git commit -F /tmp/msg.txt' \
        'git commit -F/tmp/msg.txt' \
        'git commit -aF /tmp/msg.txt' \
        'git commit -F "/tmp/my msg.txt"' \
        'git commit --file /tmp/msg.txt' \
        'git commit --file=/tmp/msg.txt' \
        'git commit -F - -F /tmp/msg.txt' \
        'git add -A && git commit -F /tmp/msg.txt' \
        'git -C work/App-Director log --output=/tmp/probe.txt' \
        $'git commit -q -F - <<\'EOF\'\nmsg\nEOF\ngit log --output=/tmp/probe.txt' \
        'git grep -O foo' \
        'git grep -Oecho foo' \
        'git grep -n -Ovim foo' \
        'git grep -iO foo' \
        'git grep -nOvim foo' \
        'git grep -e foo -Oecho' \
        'git grep -A 1 -Oecho foo' \
        'git grep --open-files-in-pager foo' \
        'git grep --open-files-in-pager=echo foo' \
        'git grep --open=echo foo' \
        'git grep --op foo' \
        'git grep "-Obj"' \
        "git grep '-Oecho' foo" \
        'git grep -nO"echo hi" foo' \
        'git grep --"open-files-in-pager"=echo foo' \
        'git -C work/App-Director grep -Oecho foo' \
        'git add . && git grep -Oecho foo' \
        'git tag -F /tmp/msg.txt v1' \
        'git tag -aF /tmp/msg.txt v1' \
        'git tag -a v1 -F/tmp/msg.txt' \
        'git tag -a v1 --file=/tmp/msg.txt' \
        'git tag --file /tmp/msg.txt v1' \
        'git tag --fi=/tmp/msg.txt v1' \
        'bash tools/stacks/../../x.sh' \
        'bash -x tools/stacks/../x.sh' \
        'bash tools/stacks/.\./x.sh' \
        'bash tools/stacks/".."/x.sh' \
        'sh ./tools/../x.sh' \
        '/bin/bash tools/stacks/../x.sh' \
        'cat ~/.ssh/id_ed25519' \
        'head "$HOME/.git-credentials"' \
        'cat ~/.config/gh/hosts.yml' \
        'less "/c/Users/V/AppData/Roaming/GitHub CLI/hosts.yml"' \
        'cat "C:\Users\V\.ssh\id_rsa"' \
        'cat "certs/server.pem"' \
        "head '.env'" \
        'cat .env.local' \
        'head ./.env.production' \
        'cat "config/.env.staging"' \
        'less .env.development.local' \
        "tail '.env.test'" \
        'tail -n 20 .env.local' \
        'cat .env.example; cat .env.local' \
        'cat README.md .env.local' \
        'tail -n 20 .env' \
        'head -5 certs/server.pem' \
        'cat docs/a.md "deploy.key"' \
        'less -R .env.production' \
        'gh auth token' \
        'gh auth status -t' \
        "printf 'protocol=https\\nhost=github.com\\n' | git credential fill" \
        "printf 'protocol=https\\nhost=github.com\\n' | git credential get" \
        $'cd x\ngit branch -D y' \
        $'cd x\ngit commit --no-verify -m x' \
        $'cd x\n\tgit log --output=/tmp/x' \
        $'echo a\ngit push --force' \
        $'cd x\ngit commit -F /tmp/msg.txt' \
        $'cd x\ngit credential fill' \
        $'echo x\nbash tools/stacks/../x.sh' \
        "git commit '-n' -m x" \
        'git commit "-n" -m x' \
        'git commit -""n -m x' \
        "git commit --no-ve''rify -m x" \
        "git commit -m -- '-n'" \
        $'git commit \\\n-n -m x' \
        $'git push \\\n--force' \
        $'git push origin \\\n+main' \
        $'git reset \\\n--hard' \
        $'git credential \\\nfill' \
        $'git log \\\n--output=/tmp/probe.txt' \
        $'cat \\\n.env.local' \
        $'cat README.md \\\n.env.local' \
        $'cat\t.env.local' \
        $'head\t-n\t20\t.env' \
        $'git\tpush --force' \
        $'git\tcommit -n -m x' \
        $'git\tlog --output=/tmp/probe.txt' \
        $'echo a\\\\\ngit push --force' \
        $'echo a\\\\\ngit commit -F /tmp/msg.txt' \
        $'sleep \\\n300'; do
      guard 2 "$cmd"
    done
    for cmd in \
        'git log --oneline -5' \
        'git diff HEAD' \
        'git diff --cached --stat' \
        'git diff origin/main..HEAD -- docs/index.md' \
        'git show HEAD:README.md' \
        'git commit -m "fix the --output handling"' \
        'git commit -m x -- docs/index.md' \
        "git commit -m x -- '-n'" \
        'git commit -F -' \
        'git commit --file=-' \
        $'git commit -q -F - <<\'EOF\'\nfix the --output and --no-index handling, not -F /tmp/x\nEOF' \
        'git stash list' \
        'git worktree list' \
        'git grep -n foo' \
        "git grep -i -e x -- '*.md'" \
        'git grep -ie -O' \
        'git grep -e -Oecho' \
        'git grep -n "an -Obj pattern"' \
        'git grep -c --no-open-files-in-pager foo' \
        'git grep --only-matching foo' \
        'git log --grep -O' \
        'git tag -a v1 -m x' \
        'git tag -a v1 -m "see --file and -F"' \
        'git tag -n' \
        'git tag -a v1 -F -' \
        'git tag --file=- -a v1' \
        'bash tools/check.sh' \
        'bash tools/work-publish.sh work/App-Director' \
        'bash tools/stacks/godot.sh --since HEAD~3..HEAD' \
        'bash tools/check.sh && git log origin/main..HEAD' \
        'bash ../x.sh' \
        'cd tools && bash ../x.sh' \
        'cat README.md' \
        'cat docs/how-to/where.md' \
        'cat .env.example' \
        'cat config/.env.sample' \
        'head .env.template' \
        'cat .env.dist' \
        'cat README.md docs/x.md' \
        'tail -n 20 .env.example' \
        'head -5 notes.txt' \
        'cat .env.example .env.sample' \
        'grep -n ssh docs/how-to/trouble.md' \
        'git log --oneline -3' \
        'ls ~/.ssh' \
        'gh auth status' \
        $'git status\ngit log --oneline -3' \
        $'git status\ngit commit -q -F - <<\'EOF\'\nfix the --output and --no-index handling, not -F /tmp/x\nEOF' \
        $'git commit -q -F - <<\'EOF\'\nfix the -n flag, not a flag\nEOF' \
        'echo x\\ngit branch -D y' \
        $'git log \\\n--oneline -3' \
        $'git status \\\n-s' \
        $'git diff \\\nHEAD' \
        $'echo a\\\\\nls' \
        $'cat README.md \\\ndocs/x.md' \
        $'cat\tREADME.md' \
        $'git\tstatus'; do
      guard 0 "$cmd"
    done
    # PowerShell (B24): its input carries the command as tool_input.command, like Bash's, so the hook must
    # exit the same way on a PowerShell payload. These are the git flags the deny rules and the guard block.
    for cmd in \
        'git push --force' \
        'git commit --no-verify -m x' \
        'git reset --hard HEAD~1' \
        'git log --output=/tmp/probe.txt' \
        'git diff --no-index a b' \
        'git commit -F /tmp/msg.txt' \
        'git grep -Oecho foo' \
        'git tag -F /tmp/msg.txt v1' \
        'bash tools/stacks/../../x.sh' \
        'cat .env.local'; do
      guard 2 "$cmd" PowerShell
    done
    for cmd in 'git status' 'git log --oneline -5' 'git diff HEAD'; do
      guard 0 "$cmd" PowerShell
    done
  fi
  guard_run
  guard_report "$git_fail" "git's file-writing, file-reading and external-command flags, and script paths outside tools/, are not all blocked" "the wildcard rules deny, and the guard hook blocks, git's file-writing, file-reading and external-command flags and script paths outside tools/"

  # The PowerShell readers of credential files (B27): Get-Content and its aliases gc and type, Select-String
  # and sls, and [IO.File]::ReadAll... block a credential file in any case, as cat does, and so does a reader
  # inside a -Command or -c string. The same readers of ordinary files pass, and the checks run for the Bash
  # tool too, since the hook reads every tool's command the same way.
  git_fail=""
  if [ -f .claude/hooks/guard-commands.sh ]; then
    for reader in 'Get-Content' 'gc' 'type' 'GET-CONTENT' 'Select-String -Pattern x' 'sls x' \
        'Get-Content -Path' 'Get-Content -LiteralPath'; do
      for target in '.env.local' '.env' '.env*' 'certs/server.pem' '~/.ssh/id_ed25519' \
          '$HOME\.ssh\id_rsa' '~/.config/gh/hosts.yml' '"$env:APPDATA\GitHub CLI\hosts.yml"'; do
        guard 2 "$reader $target" PowerShell
      done
    done
    for cmd in \
        "[IO.File]::ReadAllText('.env.local')" \
        '[System.IO.File]::ReadAllLines(".env")' \
        '[io.file]::readallbytes("certs/server.pem")' \
        '[IO.File]::ReadLines("$HOME\.ssh\id_rsa")' \
        'Get-Content .env.example; Get-Content .env.local' \
        'powershell -NoProfile -Command "Get-Content .env.local"' \
        'powershell -c "gc .env"' \
        'cmd /c "type .env.local"' \
        "bash -c 'cat .env.local'" \
        'bash -c "cat .env.local"' \
        'cat .env*' \
        '\cat .env.local' \
        'echo `cat .env.local`' \
        'type .env.local' \
        'gc .env.local'; do
      guard 2 "$cmd"
    done
    for cmd in \
        'Get-Content README.md' \
        'gc docs/index.md' \
        'Get-Content -Path docs/index.md' \
        'Get-Content -LiteralPath README.md' \
        'Select-String -Path docs/index.md -Pattern title' \
        'Get-Content .env.example' \
        'gc config/.env.sample' \
        '[IO.File]::ReadAllText("docs/index.md")' \
        'Get-ChildItem ~/.ssh' \
        'powershell -NoProfile -Command "Get-Content README.md"' \
        'type git'; do
      guard 0 "$cmd" PowerShell
    done
    guard 0 'type git'
    guard 0 'type README.md'
  fi
  guard_run
  guard_report "$git_fail" "the guard hook doesn't block every read of a credential file, or blocks a read of an ordinary file (B27)" "the guard hook blocks the PowerShell and Bash readers of credential files, in any case, and passes the readers of ordinary files and templates"

  # PowerShell's backtick (B28): a backtick that ends a line continues it, so a flag or a read it splits is
  # blocked as the plain form is, and a benign continuation passes. An escaped backtick (``) and a backtick
  # followed by spaces don't continue. In Bash a backtick is command substitution, so the same text passes
  # there. A comment that ends in a backtick still shows the next line, which the joined text would hide.
  git_fail=""
  if [ -f .claude/hooks/guard-commands.sh ]; then
    for cmd in \
        $'git push `\n--force' \
        $'git commit `\n-n -m x' \
        $'cat `\n.env.local' \
        $'cat README.md `\n.env.local' \
        $'git push `\r\n--force' \
        $'git push `\r--force' \
        $'git log `\n--output=/tmp/probe.txt' \
        $'git pu`\nsh --force' \
        $'cat .en`\nv.local' \
        $'# note`\ngit push --force'; do
      guard 2 "$cmd" PowerShell
    done
    for cmd in \
        $'git log `\n--oneline -3' \
        $'git status `\n-s' \
        $'cat ``\n.env.local' \
        $'git push ``\n--force' \
        $'git push ` \n--force'; do
      guard 0 "$cmd" PowerShell
    done
    guard 0 $'cat README.md `\n.env.local'
  fi
  guard_run
  guard_report "$git_fail" "the guard hook doesn't treat a PowerShell backtick at a line's end as a continuation, or treats a Bash or an escaped one as one (B28)" "the guard hook blocks a flag or a read that a PowerShell backtick continuation splits, and passes the benign continuations and the escaped and Bash backticks (B28)"

  # A Bash comment that ends in a backslash (B31): Bash ends the comment at the line break, so the line after it is a
  # command of its own, and the guard reads it as written. A continued command after such a comment is read from its
  # own line on. A # inside a word (a#b) is no comment, so its continuation is joined, as Bash joins it. The hang
  # check reads a heredoc header joined to its delimiter (B29): python3 with - <<'EOF' on the next line, with a body or not.
  git_fail=""
  if [ -f .claude/hooks/guard-commands.sh ]; then
    for cmd in \
        $'# note\\\ngit push --force' \
        $'# note\\\ngit commit --no-verify -m x' \
        $'git status # note\\\ngit push --force' \
        $'# a\\\ngit commit \\\n-F /tmp/msg.txt' \
        $'# a\\\ngit push \\\n--force' \
        $'# a\\\n# b\\\ngit push \\\n--force' \
        $'git push origin main#\\\n  --force' \
        $'python3 \\\n- <<\'EOF\'\nEOF' \
        $'python3 \\\n- <<\'EOF\'\nprint(1)\nEOF'; do
      guard 2 "$cmd"
    done
    for cmd in \
        $'# note\\\ngit status' \
        $'git status # note\\\n-s' \
        $'echo a#b\\\n--force' \
        $'python3 tool.py \\\n--flag <<\'EOF\'\ndata\nEOF'; do
      guard 0 "$cmd"
    done
  fi
  guard_run
  guard_report "$git_fail" "the guard hook reads a command after a Bash comment that ends in a backslash as hidden, or blocks a benign one (B31, B29)" "the guard hook reads the line after a Bash comment that ends in a backslash, and the command continued after it, as Bash does (B31, B29)"

  # A PowerShell comment that ends in a backtick (B35): PowerShell ends the comment at the line break too, so the line after it
  # is a command of its own, and a continued command after it is read from its own line on, as for a Bash comment (B31). A CRLF
  # break is the same. A comment that ends in a backtick, followed by a plain command, passes.
  git_fail=""
  if [ -f .claude/hooks/guard-commands.sh ]; then
    for cmd in \
        $'# note`\ngit commit `\n-F x' \
        $'# note`\r\ngit commit `\r\n-F x'; do
      guard 2 "$cmd" PowerShell
    done
    guard 0 $'# note`\ngit status' PowerShell
  fi
  guard_run
  guard_report "$git_fail" "the guard hook doesn't read a command after a PowerShell comment that ends in a backtick, or blocks a plain one (B35)" "the guard hook reads the command after a PowerShell comment that ends in a backtick, and the command continued after it, as PowerShell does (B35)"

  # A quoted or path-qualified reader, a backtick inside a word and a StreamReader (B30): the call operator with a
  # quoted name (& 'Get-Content' .env.local), a reader by its path (/bin/cat, cat.exe, the Management module's
  # Get-Content), a backtick escape that leaves a letter or a dot in a reader or a name (Get-Con`tent, .en`v.local),
  # and the StreamReader constructors are read as the plain forms are. A reader in a string with a backtick-escaped
  # quote, a template and an ordinary file pass. In PowerShell the escape also reaches the git flag rules (--fo`rce).
  git_fail=""
  if [ -f .claude/hooks/guard-commands.sh ]; then
    for cmd in \
        "& 'Get-Content' .env.local" \
        '& "gc" .env.local' \
        ". 'type' .env.local" \
        "& 'Get-Content' -Path '.env.local'" \
        "Get-Content '.env.local'" \
        'Get-Con`tent .env.local' \
        'gc .en`v.local' \
        'type `.env.local' \
        'C:\Git\usr\bin\cat.exe .env.local' \
        'Microsoft.PowerShell.Management\Get-Content .env.local' \
        '[System.IO.StreamReader]::new(".env.local")' \
        "[IO.StreamReader]::new('.env')" \
        "New-Object System.IO.StreamReader('.env.local')" \
        'New-Object -TypeName System.IO.StreamReader -ArgumentList .env.local' \
        'git push --fo`rce' \
        'Write-Output x; & "gc" .env'; do
      guard 2 "$cmd" PowerShell
    done
    for cmd in \
        '/bin/cat .env.local' \
        '/usr/bin/head -n 5 .env' \
        "'/bin/cat' .env.local" \
        '/usr/bin/tail -n 20 .env.production'; do
      guard 2 "$cmd"
    done
    for cmd in \
        "& 'Get-Content' README.md" \
        "& 'Get-Content' '.env.example'" \
        'Write-Output "say `"hi`" now"' \
        'Write-Output "run `"gc README.md`" next"' \
        "[System.IO.StreamReader]::new('docs/index.md')" \
        "New-Object System.IO.StreamReader('README.md')" \
        'Get-Con`tent README.md' \
        'cat.exe README.md'; do
      guard 0 "$cmd" PowerShell
    done
    for cmd in \
        '/bin/cat README.md' \
        '/usr/bin/head -n 5 .env.example' \
        "'/bin/cat' README.md"; do
      guard 0 "$cmd"
    done
  fi
  guard_run
  guard_report "$git_fail" "the guard hook misses a quoted or path-qualified reader, a backtick inside a word or a StreamReader of a credential file (B30)" "the guard hook blocks a quoted or path-qualified reader, a backtick-escaped word and a StreamReader of a credential file, and passes the same readers of ordinary files (B30)"

  # The common file readers (B36): grep, sed, awk, sort, base64, xxd and the rest of the list in the hook print a
  # credential file as cat does, in Bash and in a PowerShell payload; a reader or a name split by quotes (ca''t, c"a"t)
  # is read as the shell runs it; [IO.File]::OpenText, OpenRead and Open read one. A pattern is an argument as well
  # (B27), so grep "\.env" and git grep .env are blocked, and the templates and ordinary files pass. A commit message
  # that names a reader, with no credential file after it, passes.
  git_fail=""
  if [ -f .claude/hooks/guard-commands.sh ]; then
    for cmd in \
        'grep x .env.local' \
        'awk 1 .env' \
        'sed -n p .env.local' \
        'base64 .env.local' \
        'xxd .env.local' \
        'egrep x .env' \
        'fgrep -i x .env.production' \
        'rg x .env.local' \
        'gawk "{print}" .env.staging' \
        'sort .env.local' \
        'uniq .env' \
        'cut -d= -f2 .env.local' \
        'nl .env' \
        'tac .env.local' \
        'rev .env' \
        'od -c .env' \
        'hexdump -C .env.local' \
        'diff .env.local .env.example' \
        'cmp .env .env.example' \
        '/usr/bin/grep x .env.local' \
        'grep -rn "\.env" docs/' \
        'git grep .env' \
        "ca''t .env.local" \
        'c"a"t .env.local' \
        "'ca'\"t\" .env" \
        'g""rep x .env' \
        'ba"se"64 .env.local' \
        'cat .en'"''"'v.local' \
        'c'"'"'a'"'"'t .env.local'; do
      guard 2 "$cmd"
    done
    for cmd in \
        "[System.IO.File]::OpenText('.env.local')" \
        '[IO.File]::OpenRead(".env")' \
        "[System.IO.File]::Open('.env.local', 'Open', 'Read')" \
        '[io.file]::opentext("certs/server.pem")' \
        '[IO.File]::OpenRead("$HOME\.ssh\id_rsa")' \
        '& "Get-Content" .env.local' \
        'Select-String -Path .env -Pattern x'; do
      guard 2 "$cmd" PowerShell
    done
    for cmd in \
        'grep x .env.example' \
        'sed -n p .env.sample' \
        'awk 1 .env.template' \
        'base64 .env.dist' \
        'xxd .env.example' \
        'ca""t .env.example' \
        'c"a"t config/.env.sample' \
        'grep -n "DATABASE_URL" src/' \
        'sed -n 1,5p docs/index.md' \
        'awk 1 docs/index.md' \
        'sort README.md' \
        'cut -c1-3 README.md' \
        'diff README.md docs/index.md' \
        'git grep TODO' \
        'git diff README.md' \
        'git commit -m "fix: sort the docs and grep notes"' \
        'git commit -m "docs: sed, awk and diff notes" -- docs/index.md' \
        'rev-parse --show-toplevel'; do
      guard 0 "$cmd"
    done
    for cmd in \
        "[System.IO.File]::OpenText('docs/index.md')" \
        '[IO.File]::OpenRead("README.md")' \
        "[System.IO.File]::Open('docs/index.md', 'Open')" \
        "[IO.File]::OpenText('.env.example')"; do
      guard 0 "$cmd" PowerShell
    done
  fi
  guard_run
  guard_report "$git_fail" "the guard hook misses a common file reader, a reader or a name split by quotes, or an IO.File Open method of a credential file, or blocks an ordinary read (B36)" "the guard hook blocks grep, sed, awk, sort, base64, xxd and the other common readers, a reader or name split by quotes, and [IO.File]::OpenText, OpenRead and Open of a credential file, and passes the same readers of templates and ordinary files (B36)"

  # A backslash that escapes an ordinary character in a Bash command is removed by the shell (B44): c\at is cat, and .en\v.local
  # is .env.local, so the reader and the name are read as the shell runs them. An escaped backslash (\\) is one backslash, and a
  # backslash before a space stays, as the shell keeps the name one word. Windows paths and the templates pass, and PowerShell's
  # escape is the backtick (B30), so a backslash in a PowerShell payload is a path separator, not an escape.
  git_fail=""
  if [ -f .claude/hooks/guard-commands.sh ]; then
    for cmd in \
        'c\at .env.local' \
        'he\ad .env' \
        'cat .en\v.local' \
        'cat .env\.local' \
        'cat .e\nv.local' \
        'c\a\t .env.local' \
        'ca\t .en\v.local' \
        'sed -n p .en\v.local' \
        'C\AT .env.local' \
        'c\at "config/.en\v.local"' \
        'cat ~/.s\sh/id_rsa' \
        'cat C:\Users\V\.env' \
        'cat .\pem'; do
      guard 2 "$cmd"
    done
    for cmd in \
        'c\\at .env.local' \
        'cat .en\\v.local' \
        'cat .en\v.example' \
        'cat .en\v.sample' \
        'cat .env\ .example' \
        'c\at README.md' \
        'cat C:\Users\V\README.md' \
        'cat C:\Users\V\docs\index.md' \
        'cat C:\repo\.env.example' \
        'git commit -m "docs: c\at notes"'; do
      guard 0 "$cmd"
    done
    guard 0 'c\at .env.local' PowerShell
    guard 0 "bash -c 'c\at README.md'" PowerShell
    guard 0 "powershell -c \"c\at .env.local\"" PowerShell
    guard 2 "bash -c 'c\at .env.local'" PowerShell
    guard 2 'bash -c "cat .en\v.local"' PowerShell
    guard 2 'type C:\x\.env' PowerShell
  fi
  guard_run
  guard_report "$git_fail" "the guard hook misses a backslash that escapes a character in a Bash credential read, or blocks an ordinary read or a PowerShell backslash (B44)" "the guard hook blocks a Bash credential read whose reader or name has a backslash that escapes a character (c\\at, .en\\v.local), and passes the templates, Windows paths and a PowerShell backslash (B44)"

  # The credential-read check (B52): an escaped space in a store path (GitHub\ CLI is the gh CLI's folder, and the backslash-space is
  # the space in it); an ANSI-C string ($'...') in a reader's or a file's name, which is read as the shell reads it (\xHH, \NNN and the
  # common escapes), with an escape the guard can't decode (\u, \0) blocked as unjudgeable; and a PowerShell command's $(...), read as
  # a command of its own, so a Bash command in it that reads through a backslash (c\at) is blocked. A backslash-space in a name
  # (.env\ .example) is one word, not .env, and passes. PowerShell's backslash is no escape (its escape is the backtick), so its store
  # path passes as written (B44).
  git_fail=""
  if [ -f .claude/hooks/guard-commands.sh ]; then
    for cmd in \
        'cat ~/AppData/Roaming/GitHub\ CLI/hosts.yml' \
        'cat ~/AppData/Roaming/GitHub\ CLI' \
        'cat "~/AppData/Roaming/GitHub\ CLI/hosts.yml"' \
        'cat ~/AppData/Roaming/Git\Hub\ CLI/hosts.yml' \
        "\$'\\x63at' .env.local" \
        "\$'\\143at' .env.local" \
        "cat \$'.en\\x76.local'" \
        "cat \$'\\x2eenv.local'" \
        "cat \$'\\x2e\\x65nv\\x2elocal'" \
        "cat \$'\\x2eenv'\$'.local'" \
        "cat \$'.env\\x2elocal' docs/index.md" \
        "cat \$'\\x2eenv' .example" \
        "cat \$'\\u0063at' .env.local" \
        "cat \$'\\0' README.md" \
        "echo \$(bash -c \$'c\\x61t .env.local')" \
        "echo \$(bash -c 'c\\at .env.local')" \
        "git log \$(bash -c 'c\\at .env.local')"; do
      guard 2 "$cmd"
    done
    for cmd in \
        "echo \$(bash -c 'c\\at .env.local')" \
        "echo \"\$(bash -c 'c\\at .env.local')\"" \
        "Write-Output \$(bash -c \"c\\at ~/.ssh/id_rsa\")"; do
      guard 2 "$cmd" PowerShell
    done
    for cmd in \
        'cat .env\ .example' \
        'cat README.md docs/index.md' \
        "printf '%s' \$'\\e[31mred\\e[0m'" \
        "tr -d \$'\\r' < docs/index.md" \
        "cat \$'README\\56md'" \
        "cat \$'\\101\\x42C.md'" \
        "cat \$'.env.example'" \
        "cat \$'\\x2eenv.template'" \
        "echo \"\$(bash -c 'c\\at README.md')\"" \
        "echo \$(bash -c 'echo hi')"; do
      guard 0 "$cmd"
    done
    for cmd in \
        'cat ~/AppData/Roaming/GitHub\ CLI/hosts.yml' \
        'Write-Output "$(Get-Content .env.example)"' \
        'Write-Output "$(Get-Content README.md)"' \
        "Write-Output \"\$(bash -c 'c\\at README.md')\""; do
      guard 0 "$cmd" PowerShell
    done
  fi
  guard_run
  guard_report "$git_fail" "the guard hook misses an escaped space in a store path, an ANSI-C string in a reader's or a file's name, or a PowerShell command's substitution that reads a credential file, or blocks an ordinary read (B52)" "the guard hook blocks a credential read through an escaped space in a store path, an ANSI-C string in a name, and a PowerShell command's substitution, and passes an ANSI-C string that names no credential and the substitutions that read none (B52)"

  # A command substitution in a git command's words (B32): what it prints can be a flag, and the text it runs is a command
  # the guard can't see. The repro (git push $(echo --force) and its backtick form) is blocked as the plain flag is, in Bash
  # and PowerShell, and so is a substitution as the command name, or one that runs a non-reading command. A double-quoted
  # value that starts with fixed text, a commit's or tag's -m value and a read (git, date, cat, echo, printf) pass, as the
  # procedures use them. The text of a substitution is judged as a command of its own.
  git_fail=""
  if [ -f .claude/hooks/guard-commands.sh ]; then
    for cmd in \
        'git push $(echo --force)' \
        'git push `echo --force`' \
        'git push "$(echo --force)"' \
        'git log $(echo --output=/tmp/x)' \
        'git log "$(echo --output=/tmp/x)"' \
        'git log "--output=$(echo /tmp/x)"' \
        'git log "--since=$(rm -rf x)"' \
        'git log -1 "$(date +%F)"' \
        'git log "x$(git push --force)"' \
        'git push $(git push --force)' \
        'git status && echo $(git push --force)' \
        'echo "$(git push --force)"' \
        'git log > >(git push --force)' \
        '$(echo git) push --force' \
        'git log $(echo git) push' \
        'git commit -m x "$(cat x)"' \
        'git commit -m "$(echo $(rm -rf x))"' \
        $'git commit -c -m "$(cat <<\'EOF\'\n--file=/tmp/x\nEOF\n)"' \
        $'git commit -m -m "$(cat <<\'EOF\'\n--file=/tmp/x\nEOF\n)"' \
        $'git commit -m "$(cat <<EOF\n$(git push --force)\nEOF\n)"' \
        $'git commit -m "$(cat x; git push --force)"' \
        $'git log \\\n$(echo --output=/tmp/x)' \
        'git push "--force"$(echo x)'; do
      guard 2 "$cmd"
    done
    for cmd in \
        'git push $(echo --force)' \
        'git push `echo --force`' \
        'git push "$(echo --force)"' \
        'git push (echo --force)' \
        'git push @(echo --force)' \
        '$(echo git) push --force' \
        'git log -- $(echo --output=/tmp/x)' \
        'git log "$(git push --force)"'; do
      guard 2 "$cmd" PowerShell
    done
    for cmd in \
        $'git commit -m "$(cat <<\'EOF\'\nfix the --output handling, and -F /tmp/x\nEOF\n)"' \
        $'git commit -a -m "$(cat <<\'EOF\'\nmsg one\n\nBody with `ticks` and $(vars) text\nEOF\n)" -- docs/index.md' \
        $'git commit -m "$(cat <<\'EOF\'\nmsg `git push --force` in a quoted heredoc\nEOF\n)" -- x' \
        $'git commit -m "$(cat <<EOF\nplain body\nEOF\n)"' \
        'git commit -m "$(git log -1 --format=%s)"' \
        'git commit -m "$(echo --file=/tmp/x)"' \
        'git tag -a "v$(cat VERSION)" -m "release"' \
        'git checkout -q -b "ddd/bundle-$(date +%F)" origin/main' \
        'git ls-remote --heads origin "ddd/bundle-$(date +%F)*"' \
        "git log --since=\"\$(date -d '7 days ago' +%F)\" --oneline" \
        'git log --format=%h -n 1 -- "docs/$(echo index).md"' \
        'test -z "$(git status --porcelain)"' \
        'echo "$r $(git -C work/$r describe --tags)"' \
        'for f in $(git diff --name-only); do echo "$f"; done' \
        'K=$(git rev-parse HEAD); echo $K' \
        'cd "$(git rev-parse --show-toplevel)" && git status' \
        'git status; echo $(date)' \
        'git log -1 --format=%h \$(echo --output)' \
        'echo `date`'; do
      guard 0 "$cmd"
    done
    guard 0 'Write-Output "$(git status)"' PowerShell
    guard 0 $'git commit -m "$(cat <<\'EOF\'\nmsg\nEOF\n)" && git push origin main' PowerShell
  fi
  guard_run
  guard_report "$git_fail" "the guard hook reads a command substitution in a git command's words, or as its name, as harmless, or blocks a plain read (B32)" "the guard hook blocks a command substitution that can print a git flag or run a command the guard can't read, in git's words or as a command name, and passes the quoted values, messages and reads the procedures use (B32)"

  # A Bash comment holds no substitution and opens no quoted string (B43): a backtick, $( or quote in it is text, so the
  # command after the comment is read as Bash reads it. A substitution after a comment, a tab, ; or & is still read, and so is
  # one after a # inside a word (a#b) or after an escaped blank, since neither starts a comment. A ) in a comment doesn't close a
  # substitution, so its text runs to the next line and is blocked. A blank before a # inside ${...} is part of the expansion,
  # not a comment. An unquoted heredoc body's substitutions are read whole, as the shell expands them, so a comment in one is
  # read too; a quoted body is text.
  git_fail=""
  if [ -f .claude/hooks/guard-commands.sh ]; then
    for cmd in \
        $'git push # x\n`echo --force`' \
        $'git push # x\ngit push `echo --force`' \
        $'git status # note\ngit push $(echo --force)' \
        $'# it\'s\ngit push `echo --force`' \
        $'git status a#b `echo --force`' \
        $'git status a\\ #`echo --force`' \
        $'git status ${x:- #a} $(echo --force)' \
        $'git push origin ":${y:- #}$(echo main)"' \
        $'git push `# x`' \
        $'git push `echo --force` # x' \
        $'git push $(echo --force) # `' \
        $'git status $(echo a # `)' \
        $'git log "--format=$(echo a # )\nprintf x)"' \
        $'git commit -q -F - <<EOF\n# note `\nmsg\nEOF' \
        $'git log <<EOF\n# $(git push --force)\nEOF' \
        $'git status <<EOF\n# `git push --force`\nEOF' \
        $'# note `\\\ngit push `echo --force`'; do
      guard 2 "$cmd"
    done
    for cmd in \
        $'# note `\ngit status' \
        $'# note `echo --force`\ngit status' \
        $'# note $(echo --force)\ngit status' \
        $'git status\t# note `\ngit log -1' \
        $'git status;# note `\ngit log -1' \
        $'# it\'s\ngit status' \
        $'git status # $(echo --force)' \
        $'git status # `echo --force`' \
        $'git status ${x:-y} # $(echo --force)' \
        $'# note `\\\ngit status' \
        $'git commit -q -F - <<\'EOF\'\n# note `echo --force`\nmsg\nEOF'; do
      guard 0 "$cmd"
    done
  fi
  guard_run
  guard_report "$git_fail" "the guard hook reads a backtick, \$( or quote in a Bash comment as a substitution or a string, or misses a substitution after one (B43)" "the guard hook reads a Bash comment as text, so a backtick, \$( or quote in it starts no substitution or string, and a substitution after a comment, an escaped blank or a # in a word is still read (B43)"

  # The word decoder (B51) reads a comment on its own line: a quote in it pairs with nothing after the line break, so the
  # quoted flag, refspec or credential command after it is seen, in Bash, in a heredoc body a shell runs and in PowerShell
  # (whose # starts a comment the same way). A quote in a comment that never closes is text, so the flags it names pass,
  # and a quoted command in a comment passes as it did; a # inside a quoted string, an escaped #, ${#x} or $# starts no
  # comment, so a flag after one is blocked.
  git_fail=""
  if [ -f .claude/hooks/guard-commands.sh ]; then
    for cmd in \
        $'# it\'s\ngit push origin \':main\'' \
        $'# it\'s\ngit push "--force" \'x\'' \
        $'# say "hi\ngit push "--force" "x"' \
        $'# it\'s\ngit commit -q "-n" -m \'x\'' \
        $'# it\'s\ngit push origin "+main" \'x\'' \
        $'# say "hi\ngit push origin \':main\'' \
        $'# say "hi\ngit commit -q "-n" -m "x"' \
        $'git status\n# it\'s\ngit push "--force" \'x\'' \
        $'echo \'a\'  # it\'s\ngit push "--force" \'x\'' \
        $'# it\'s\n# don\'t\ngit push origin \':main\' \'x\'' \
        $'bash <<\'EOF\'\n# it\'s\ngit push origin \':main\'\nEOF' \
        $'bash <<\'EOF\'\n# it\'s\ngit push "--force" \'x\'\nEOF' \
        $'# it\'s\ngit credential fill \'x\'' \
        $'# note\\\ngit push --force' \
        $'echo a\\ #b ; git push --force' \
        $'echo "#" ; git push --force' \
        $'git status ${x:- #} ; git push --force' \
        $'echo "$(echo "a #") # b" ; git push --force'; do
      guard 2 "$cmd"
    done
    for cmd in \
        $'# it\'s\ngit status' \
        $'# it\'s --force\ngit status' \
        $'# it\'s "--force" -n :main\ngit status' \
        $'# it\'s \':main\'\ngit log -1' \
        $'# it\'s "git push --force"\ngit status' \
        $'# say "--force" and "-n" and ":main"\ngit status' \
        $'git status # it\'s --force\ngit log -1' \
        $'git status\n# it\'s\ngit log --oneline -3' \
        $'# it\'s -n\ngit push origin main' \
        $'git commit -q -F - <<\'EOF\'\n# it\'s git push origin \':main\'\nEOF' \
        $'bash <<\'EOF\'\n# it\'s --force\necho done\nEOF' \
        $'git commit -m "fix #12 it\'s" -m "x"' \
        $'git status "#" \'it\'' \
        $'echo ;#x'; do
      guard 0 "$cmd"
    done
    for cmd in \
        $'# it\'s\ngit push "--force" \'x\'' \
        $'# it\'s\ngit commit -q "-n" -m \'x\'' \
        $'echo "a""b # " ; git push --force' \
        'git push `#x --force'; do
      guard 2 "$cmd" PowerShell
    done
    guard 0 $'# it\'s --force\ngit status' PowerShell
    guard 0 $'# it\'s\ngit log -1' PowerShell
  fi
  guard_run
  guard_report "$git_fail" "the guard hook reads a quote in a comment as pairing with a quote after its line break, or blocks a comment that names a flag or quotes a command (B51)" "the guard hook reads a quote in a Bash or PowerShell comment as pairing with nothing after its line break, so a quoted flag, refspec or credential command after it is blocked, and a comment that names a flag or quotes a command passes (B51)"

  # A destructive git rule (B33) reads the words as the shell hands them over: a quoted flag, refspec or path is seen, a flag
  # ends at ; & | ) or a line break as it does at a space, and a heredoc body a shell runs is read too. The rules are a force
  # push, a +refspec, reset --hard, clean -f, checkout or switch -f, checkout or restore of ".", stash drop or clear, and
  # branch -D. A quoted message that names one passes, and so does a quoted word that isn't a flag.
  git_fail=""
  if [ -f .claude/hooks/guard-commands.sh ]; then
    for cmd in \
      $'git push --force\necho done' \
      'git push --force;echo done' \
      'git push --force&&echo done' \
      'git push --force|cat' \
      '(git push --force)' \
      'git push "--force"' \
      "git push '--force'" \
      'git push "--force-with-lease=origin/main"' \
      'git push --fo"rce"' \
      'git push -f;echo done' \
      'git push origin "+main"' \
      "git push origin '+main'" \
      'git pu"sh" --force' \
      'git status && git push --force' \
      $'git status\ngit push "--force"' \
      'git checkout "."' \
      'git checkout -- "."' \
      'git restore "."' \
      'git checkout .;echo done' \
      'git checkout -f;echo done' \
      'git checkout "-f" main' \
      'git checkout -qf main' \
      'git switch "--discard-changes" main' \
      'git reset "--hard"' \
      'git reset --hard;echo done' \
      'git clean "-f"' \
      'git stash "drop"' \
      'git stash drop;echo done' \
      'git branch "-D" x' \
      'git branch -D x;echo done' \
      'git branch -vD x' \
      'git commit -n;echo done' \
      'git commit -m "-x;y" -F /tmp/msg.txt' \
      'git diff "/etc/passwd"' \
      'bash "tools/../x.sh"' \
      $'bash <<\'EOF\'\ngit push --force\nEOF' \
      $'bash <<\'EOF\'\ngit push "--force"\nEOF' \
      $'bash <<\'EOF\'\ngit push origin "+main"\nEOF' \
      $'bash <<\'EOF\'\ngit checkout "."\nEOF' \
      $'bash <<\'EOF\'\ngit commit -n -m x\nEOF' \
      $'sh <<EOF\ngit reset --hard\nEOF'; do
      guard 2 "$cmd"
    done
    for cmd in \
      'git push origin main' \
      'git push origin "HEAD:refs/heads/main"' \
      'git push "origin" main' \
      'git push origin main;git status' \
      'git push -u origin "ddd/bundle-$(date +%F)"' \
      'git commit -m "stop git push --force;"' \
      'git commit -m "reset --hard" -m "checkout ."' \
      'git commit -m "stash drop"' \
      'git commit -m "-x" -F -' \
      'git checkout -b "feature/x"' \
      'git checkout "main"' \
      'git branch -d x' \
      'git branch -vv' \
      'git log --grep "push --force"' \
      'git log --oneline "--grep=push"' \
      'git stash show "drop"' \
      'git tag -a v1 -m "push --force note"' \
      'echo "git push --force"' \
      'git status && echo "reset --hard"' \
      $'git status\ngit log --oneline -3' \
      $'git commit -q -F - <<\'EOF\'\nStop "git push --force" in the hook, and "git reset --hard".\nEOF' \
      $'git commit -q -F - <<\'EOF\'\nfix the --output and --no-index handling, not -F /tmp/x\nEOF'; do
      guard 0 "$cmd"
    done
    for cmd in 'git push "--force"' 'git push origin "+main"' 'git checkout "."' 'git push --force;echo done' 'git reset "--hard"'; do
      guard 2 "$cmd" PowerShell
    done
    guard 0 'Write-Output "git push --force"' PowerShell
    guard 0 'git push origin "HEAD:main"' PowerShell
  fi
  guard_run
  guard_report "$git_fail" "the guard hook doesn't read a destructive git rule's flag, refspec or path as the shell does, or blocks a message that names one (B33)" "the guard hook blocks a force push, a +refspec, reset, clean, checkout, stash drop and branch -D that a quote, a line break, ; & | ) or a heredoc body hides, and passes the quoted messages (B33)"

  # A script a shell or an interpreter runs is a command of its own (B34): a quoted string given to bash -c, sh -c or
  # zsh -c (with options before -c), eval, powershell -Command, pwsh -c or cmd /c is read by the same rules, to four levels
  # of nesting, whatever the name is quoted or prefixed with. A comment, a heredoc body or a message in quotes that names
  # one is text, and a read or a benign script passes. A command whose quoting the guard can't close, and PowerShell's
  # -EncodedCommand, whose text is hidden, are blocked.
  git_fail=""
  if [ -f .claude/hooks/guard-commands.sh ]; then
    for cmd in \
        "bash -c 'git push --force'" \
        'sh -c "git commit --no-verify -m x"' \
        "eval 'git log --output=x'" \
        'sh -c "git push $(echo --force)"' \
        "sh -c 'git commit -n -m x'" \
        "zsh -c 'git branch -D x'" \
        "bash -lc 'git reset --hard'" \
        "bash -o pipefail -c 'git push --force'" \
        'eval "git push" --force' \
        "bash -c \"git push '--force'\"" \
        "timeout 240 bash -c 'git push --force'" \
        "bash -c 'bash -c \"git push --force\"'" \
        'sh -c "git commit -m \"x\" -n"' \
        'powershell -NoProfile -Command "git push --force"' \
        'cmd /c "git push --force"' \
        '"bash" -c "git push --force"' \
        "ba''sh -c 'git push --force'" \
        "nice -n 5 bash -c 'git push --force'" \
        "sudo sh -c 'git push --force'" \
        "eval 'bash -c \"git push --force\"'" \
        "bash -c \"\$(echo git push --force)\"" \
        "bash -c 'git checkout .'" \
        'bash -c "git push origin +main"' \
        "/bin/bash -c 'git push --force'" \
        "bash -c \$'git push --force'" \
        "bash -c 'git commit -F /tmp/msg.txt'" \
        "bash -c 'bash tools/stacks/../x.sh'" \
        "bash -c 'sleep 300'" \
        'sh -c "git status' \
        'powershell -EncodedCommand ZwBpAHQAIABwAHUAcwBoAA==' \
        $'# don\'t\nbash -c \'git push --force\'' \
        $'cat <<\'EOF\'\nit\'s\nEOF\nbash -c \'git push --force\'' \
        $'bash -c \'echo hi\' ; sh -c "git status\nbash -c \'git push --force\'"'; do
      guard 2 "$cmd"
    done
    # Four wrappers nested (bash -c inside sh -c inside zsh -c inside bash -c) reach the git inside; a fifth is blocked.
    wrap_esc() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; printf '%s' "$s"; }
    nest="bash -c 'git push --force'"
    for _ in 1 2 3; do nest="sh -c \"$(wrap_esc "$nest")\""; done
    guard 2 "$nest"
    nest="bash -c 'echo hi'"
    for _ in 1 2 3; do nest="sh -c \"$(wrap_esc "$nest")\""; done
    guard 0 "$nest"
    nest="sh -c \"$(wrap_esc "$nest")\""
    guard 2 "$nest"
    for cmd in \
        "bash -c 'git status'" \
        'sh -c "echo hi"' \
        "bash -c 'git log --oneline -3'" \
        "sh -c \"git commit -m 'fix the --output handling'\"" \
        'echo "bash -c '"'"'git push --force'"'"'"' \
        'git commit -m "fix: sh -c '"'"'git push --force'"'"' now blocked"' \
        $'git commit -q -F - <<\'EOF\'\nthe sh -c \'git push --force\' guard\nEOF' \
        "timeout 240 bash -c 'until test -f x; do sleep 5; done'" \
        '(timeout 4m bash -c "while true; do sleep 1; done")' \
        'bash -c "echo $(date)"' \
        'powershell -NoProfile -Command "Write-Output '"'"'hi'"'"'"' \
        "bash -c 'cat README.md'" \
        'eval "echo hi"' \
        'git log --grep "bash -c git push --force"' \
        "bash -c 'echo hi' git status" \
        'echo sh -c' \
        'git commit -m "run cmd /c later"' \
        $'bash -c "git commit -F - <<\'EOF\'\nmsg\nEOF"' \
        $'git commit -m "$(cat <<\'EOF\'\nmsg with sh -c \'git push --force\'\nEOF\n)"' \
        'bash tools/check.sh'; do
      guard 0 "$cmd"
    done
    # PowerShell (B34): the same wrappers in the PowerShell tool's payload, and a backtick that joins a flag.
    for cmd in \
        "pwsh -c 'git reset --hard'" \
        'powershell -Command "git push --force"' \
        'bash -c "git push --force"' \
        'cmd /c "git push --force"' \
        'powershell -EncodedCommand ZwBpAHQAIABwAHUAcwBoAA==' \
        'powershell -c "git push --fo`rce"'; do
      guard 2 "$cmd" PowerShell
    done
    for cmd in \
        "pwsh -c 'git status'" \
        'powershell -NoProfile -Command "Write-Output '"'"'hi'"'"'"' \
        'cmd /c "echo hi"' \
        'powershell -File tools/x.ps1 "git push --force"' \
        'pwsh -c "Get-ChildItem | Select-Object Name"'; do
      guard 0 "$cmd" PowerShell
    done
  fi
  guard_run
  guard_report "$git_fail" "the guard hook doesn't read a script a shell or an interpreter runs as a command of its own, or blocks a message that names one (B34)" "the guard hook reads a script given to bash -c, sh -c, zsh -c, eval, powershell -Command, pwsh -c or cmd /c as a command, to four levels, and passes the messages, heredocs and reads that name one (B34)"

  # A wait loop in a script a shell or an interpreter runs (B42): the hang check reads each such script as it reads the command,
  # so an until, while true or while : loop with sleep is blocked under eval, bash -c, sh -c, powershell -Command and cmd /c.
  # A timeout of 280 seconds or less above the wrapper bounds the whole script, as it bounds a loop the command runs itself,
  # and a loop with no sleep, or in a message that names one, passes.
  git_fail=""
  if [ -f .claude/hooks/guard-commands.sh ]; then
    for cmd in \
        "eval 'until false; do sleep 1; done'" \
        "eval 'while true; do sleep 1; done'" \
        "eval 'while :; do sleep 1; done'" \
        "sh -c 'until false; do sleep 1; done'" \
        "eval \"until false; do sleep 1; done\"" \
        "eval 'bash -c \"until false; do sleep 1; done\"'" \
        "eval 'eval \"while true; do sleep 1; done\"'" \
        "sh -c \"eval 'while : ; do sleep 1; done'\"" \
        "timeout 9999 eval 'until false; do sleep 1; done'" \
        "timeout 0 eval 'until false; do sleep 1; done'" \
        "timeout 5m eval 'until false; do sleep 1; done'" \
        'cmd /c "until false; do sleep 1; done"' \
        'cmd /c "while true; do sleep 1; done"' \
        'powershell -Command "while ($true) { Start-Sleep 1 }"' \
        'powershell -NoProfile -Command "while ($true) { sleep 1 }"'; do
      guard 2 "$cmd"
    done
    for cmd in \
        'while ($true) { Start-Sleep 1 }' \
        'While ($true) { Start-Sleep -Seconds 5 }' \
        'WHILE ($true) { start-sleep 2 }'; do
      guard 2 "$cmd" PowerShell
    done
    for cmd in \
        "timeout 60 eval 'until false; do sleep 1; done'" \
        "timeout 4m eval 'until false; do sleep 1; done'" \
        "timeout 240s eval 'until false; do sleep 1; done'" \
        'timeout 60 cmd /c "until false; do sleep 1; done"' \
        "timeout 60 bash -c \"eval 'until false; do sleep 1; done'\"" \
        "sh -c \"timeout 60 eval 'until false; do sleep 1; done'\"" \
        "eval 'timeout 60 bash -c \"until false; do sleep 1; done\"'" \
        "eval 'until false; do echo hi; done'" \
        "eval 'sleep 1'" \
        "eval 'git commit -m \"until false; do sleep 1; done\"'" \
        'cmd /c "echo until"' \
        'powershell -Command "Write-Output (Get-Date)"'; do
      guard 0 "$cmd"
    done
    for cmd in \
        'while ($true) { Get-Date }' \
        'timeout 60 powershell -Command "while ($true) { Start-Sleep 1 }"'; do
      guard 0 "$cmd" PowerShell
    done
  fi
  guard_run
  guard_report "$git_fail" "the guard hook doesn't block a wait loop in a script a shell or an interpreter runs, or blocks one a timeout bounds (B42)" "the guard hook blocks an until or while loop with sleep in a script given to eval, bash -c, sh -c, powershell -Command or cmd /c, and passes one under a timeout of 280 seconds or less (B42)"

  # The hang check's other forms (B49): a C-style for (( loop with sleep and no time limit; a PowerShell do { } while or until with a
  # sleep in its body; Start-Sleep and its alias sleep with -Seconds, -s or -Milliseconds over 280 seconds; cmd's timeout /t N over 280
  # seconds, or -1, which waits for a key press for ever (cmd's timeout is a wait, not a time limit); and a Bash substitution, which
  # runs before a timeout above it starts, so the timeout doesn't bound it. A substitution in single quotes, or escaped, is the
  # script's own, so a timeout above a script bounds it. A message that names one of these passes (the quoted text is blanked).
  git_fail=""
  if [ -f .claude/hooks/guard-commands.sh ]; then
    for cmd in \
        'for ((;;)); do sleep 1; done' \
        'for (( ; ; )); do sleep 1; done' \
        'for ((i = 0; i < 3; i++)); do sleep 1; done' \
        'timeout 60 echo "$(until false; do sleep 1; done)"' \
        'timeout 60 echo $(until false; do sleep 1; done)' \
        'timeout 60 bash -c "echo $(until false; do sleep 1; done)"' \
        'timeout 60 echo "$(bash -c "until false; do sleep 1; done")"' \
        'echo "$(sleep 600)"' \
        'echo "$(cmd /c "timeout /t 600")"' \
        'powershell -Command "Start-Sleep -Seconds 600"' \
        'powershell -Command "Start-Sleep -Milliseconds 300001"' \
        'cmd /c "timeout /t 300"' \
        'cmd /c "timeout /t -1"' \
        'timeout 60 cmd /c "timeout /t 600"' \
        'timeout 60 echo $(cat <<'"'"'EOF'"'"'
x
EOF
) ; while true; do sleep 1; done'; do
      guard 2 "$cmd"
    done
    for cmd in \
        'do { Start-Sleep 1 } while ($true)' \
        'do { Start-Sleep 1 } until ($false)' \
        'DO { START-SLEEP -S 600 } WHILE ($true)' \
        'Start-Sleep -Seconds 600' \
        'Start-Sleep -s 600' \
        'Start-Sleep -Milliseconds 280001' \
        'sleep -Seconds 300' \
        'timeout 60 Write-Output $(while ($true) { Start-Sleep 1 })' \
        'powershell -Command "do { Start-Sleep 1 } while ($true)"'; do
      guard 2 "$cmd" PowerShell
    done
    for cmd in \
        "timeout 60 bash -c 'echo \$(until false; do sleep 1; done)'" \
        'timeout 240 bash -c "echo \$(until test -f x; do sleep 5; done)"' \
        "timeout 240 bash -c 'for ((i = 0; i < 3; i++)); do sleep 1; done'" \
        'echo "$(date +%s)"' \
        'echo $(sleep 280)' \
        'bash -c "echo $(date)"' \
        'timeout 60 cmd /c "timeout /t 60"' \
        'cmd /c "timeout /t 280"' \
        "echo '\$(until false; do sleep 1; done)'" \
        'git commit -m "wait: Start-Sleep 600 and for ((;;)) and do { x } while (y)"' \
        'git log --format="%h $(date +%F)" -3' \
        'echo "$(git log --oneline -3)"' \
        'for i in 1 2 3; do echo $i; done' \
        'for ((i = 0; i < 3; i++)); do echo $i; done'; do
      guard 0 "$cmd"
    done
    for cmd in \
        'timeout 60 powershell -Command "do { Start-Sleep 1 } while ($true)"' \
        'timeout 240 powershell -Command "Start-Sleep -Seconds 240"' \
        'Start-Sleep -Seconds 280' \
        'Start-Sleep -Milliseconds 280000' \
        'Start-Sleep 5' \
        'do { Get-Date } while ($false)' \
        "Write-Output 'do { Start-Sleep 1 } while (\$true)'"; do
      guard 0 "$cmd" PowerShell
    done
  fi
  guard_run
  guard_report "$git_fail" "the guard hook doesn't block a for (( loop, a do ... while, Start-Sleep or timeout /t over 280 seconds, or a substitution before a timeout, or blocks a message or a bounded script that names one (B49)" "the guard hook blocks a for (( loop with sleep, a do ... while with sleep, Start-Sleep and timeout /t over 280 seconds, and a substitution that runs before a timeout, and passes a bounded script and a message that names them (B49)"

  # The hang check reads the command without the bodies no shell runs (B50): a commit's, tag's or gh message, and a cat or tee body
  # nothing runs (the classification's reading, B40 and B48). So a message can name a loop, a pause or a timed wait, as plain text,
  # in a C-style or a PowerShell loop, with a pause or a wait over five minutes. A body a shell, an interpreter or a runner executes
  # is still read, and so is a Python heredoc and a command after a message. An unquoted message's substitution is run, so it
  # is read; a quoted one is text, and so are its backticks.
  git_fail=""
  if [ -f .claude/hooks/guard-commands.sh ]; then
    for cmd in \
        $'git commit -q -F - -- a <<\'EOF\'\nPowerShell\'s While loop with Start-Sleep is now seen.\nEOF' \
        $'gh pr edit 5 --body-file - <<\'EOF\'\nPowerShell\'s While loop with Start-Sleep is now seen.\nEOF' \
        $'git commit -q -F - <<\'EOF\'\nfix: for ((i = 0; i < 3; i++)); do sleep 600; done\nEOF' \
        $'git commit -q -F - <<\'EOF\'\nwait: Start-Sleep -Seconds 600 before retry\nEOF' \
        $'gh pr create --body-file - <<\'EOF\'\nUse cmd\'s timeout /t 600 to wait\nEOF' \
        $'gh pr create --body-file - <<\'EOF\'\ndo { Start-Sleep 600 } while ($true)\nEOF' \
        $'gh pr create --body-file - <<\'EOF\'\nuse `sleep 600` and `timeout /t 600` as examples\nEOF' \
        $'gh pr create --body-file - <<\'EOF\'\n$(until false; do sleep 1; done)\nEOF' \
        $'git commit -q -F - <<EOF\nwhile you wait, Start-Sleep 600 $(date +%F)\nEOF' \
        $'git tag -a v1 -F - <<\'EOF\'\nwhile true; do sleep 600; done\nEOF' \
        $'gh issue comment 5 -F - <<\'EOF\'\nfor ((;;)); do sleep 1; done\nEOF' \
        $'gh release create v1 --notes-file - <<\'EOF\'\ndo { Start-Sleep 600 } until ($false)\nEOF' \
        $'git commit -q -F - <<\'EOF\'\nfix: sleep 600\nEOF\ngit status' \
        $'cat > notes.md <<\'EOF\'\nuntil false; do sleep 600; done\nEOF' \
        $'cat > notes.md <<EOF\nuntil false; do sleep 600; done\nEOF' \
        $'tee notes.md <<\'EOF\'\nStart-Sleep -Seconds 600\nEOF'; do
      guard 0 "$cmd"
    done
    guard 0 'git commit -q -m "wait: Start-Sleep -Seconds 600"' PowerShell
    for cmd in \
        $'python3 - <<\'EOF\'\nEOF' \
        $'bash <<\'EOF\'\nuntil false; do sleep 600; done\nEOF' \
        $'cat > x.sh <<\'EOF\'\nwhile true; do sleep 1; done\nEOF\nbash x.sh' \
        $'cat > x.sh <<\'EOF\'\nStart-Sleep -Seconds 600\nEOF\nsh x.sh' \
        $'cat > x.sh <<\'EOF\'\nuntil false; do sleep 1; done\nEOF\n. ./x.sh' \
        $'echo start; cat > x.sh <<\'EOF\'\nuntil false; do sleep 1; done\nEOF\nbash x.sh' \
        $'git commit -q -F - <<\'EOF\'\nmsg\nEOF\nwhile true; do sleep 1; done' \
        $'gh pr create --body-file - <<\'EOF\'\nmsg\nEOF\nsleep 600' \
        $'git commit -q -F - <<EOF\n$(until false; do sleep 1; done)\nEOF' \
        $'gh pr create --body-file - <<EOF\n$(sleep 600)\nEOF' \
        $'git commit -q -F - <<EOF\n`until false; do sleep 1; done`\nEOF' \
        $'cat > notes.md <<\'EOF\'\nmsg\nEOF\nbash -c "until false; do sleep 600; done"'; do
      guard 2 "$cmd"
    done
  fi
  guard_run
  guard_report "$git_fail" "the guard hook blocks a message or an unrun cat body that names a loop, a pause or a timed wait, or passes a body a shell, an interpreter or a runner executes (B50)" "the guard hook passes a commit's, tag's or gh message, and a cat or tee body nothing runs, that names a loop, a pause or a timed wait, and blocks a body a shell, an interpreter or a runner executes (B50)"

  # A variable in a git command's words (B37): the guard can't read what it holds. A variable that the command assigns once,
  # to a plain value, is read as that value, so FLAG=--force; git push $FLAG is the force push it is. Any other unquoted
  # variable in the words of a git subcommand the rules read is blocked, and so is a quoted one that a flag or a path could
  # be, a fixed text that starts a flag (--$X), a variable as the subcommand, and a variable as a command's name followed by
  # -c or -Command. The everyday forms pass: a quoted variable as the value of -m, -e, -b or -C, after --, after fixed text
  # that doesn't start a flag, as a push's branch after its remote, and in a subcommand the rules don't read (git status).
  git_fail=""
  if [ -f .claude/hooks/guard-commands.sh ]; then
    for cmd in \
        'FLAG=--force; git push $FLAG' \
        'FLAG=-f; git push ${FLAG} origin' \
        'export ST=-f && git push $ST origin' \
        'FLAG=--force; git push "$FLAG"' \
        'FLAG=ok; FLAG=--force; git push $FLAG' \
        'FLAG=ok; read FLAG; git push $FLAG' \
        'NV=--no-verify; git commit $NV -m x' \
        'git commit $NV -m x' \
        "git commit \"\$NV\" -m x" \
        'git push $FLAG' \
        'git push "$FLAG"' \
        'git push origin $BR' \
        'git push --$X' \
        'git push "--$X"' \
        'git push -$F origin' \
        'git log $X' \
        'git log --output="$X"' \
        'git diff "$f"' \
        'git -C $d log' \
        'git $CMD --force' \
        'git commit -nm"$x" -- a' \
        'git commit -m$msg' \
        'git checkout -b $name' \
        'git reset --hard $REF' \
        'git branch -D "$b"' \
        'git grep "$p"' \
        $'bash <<\'EOF\'\ngit push $FLAG\nEOF' \
        "\$X -c 'git push --force'" \
        '"$SHELL" -c "git push --force"' \
        'sudo "$X" -c "git push --force"' \
        'env FOO=1 $X -c x' \
        'timeout 240 "$X" -c x' \
        'echo ok && $X -c x' \
        '"$EDITOR" -c x'; do
      guard 2 "$cmd"
    done
    for cmd in 'git commit $NV -m x' 'git push "$FLAG"' 'git push -u origin $BR' '$X -c "git push --force"' \
        '& $X -c "git push --force"'; do
      guard 2 "$cmd" PowerShell
    done
    for cmd in \
        'for r in A B C; do git -C work/$r status --short; done' \
        'git -C "work/$r" log --oneline -1' \
        'git -C "$repo" fetch' \
        'git -C $d status' \
        'git status $X' \
        'git add $FILE' \
        'git log --since="$since"' \
        'git commit -m "$msg" -- a' \
        'git commit -m"$msg" -- a' \
        'git commit -am "$msg"' \
        'git commit -C "$c"' \
        'git push -u origin "$branch"' \
        'git push origin "$a" "$b"' \
        'git checkout -b "ddd/bundle-$day"' \
        'git checkout -b "ddd/bundle-$day" origin/main' \
        'git switch -c "$b"' \
        'git grep -e "$p"' \
        'git tag -a "v$VER" -m "release"' \
        'git log --format="%h $X"' \
        'git log -- $X' \
        'git commit -m "$msg" -- $X' \
        'git log > "$out"' \
        'git log >"$out" --oneline' \
        'FLAG=ok; git push $FLAG' \
        'FLAG=--force; echo $FLAG' \
        'MSG=--force; git commit -m "$MSG"' \
        'a=1; git push $a' \
        'echo $X -c x' \
        'echo -n $X -c x' \
        'echo "$X -c y"' \
        '"$EDITOR" notes.txt' \
        'git commit -m "& $X -c y" -- a' \
        $'git commit -q -F - <<\'EOF\'\nfix the $X handling\nEOF'; do
      guard 0 "$cmd"
    done
    guard 0 'git push -u origin "$branch"' PowerShell
    guard 0 'git commit -m "$msg" -- a' PowerShell
  fi
  guard_run
  guard_report "$git_fail" "the guard hook reads a variable in a git command's words as a value it can't see, or blocks a plain form (B37)" "the guard hook reads a variable a git command assigns once as its value, blocks an unquoted or flag-capable variable in a git command's words, a variable as a subcommand or as a shell's name followed by -c, and passes the everyday forms (B37)"

  # A variable as a command's name, and a variable a shell's script or a script path holds (B45): the name a command assigns is
  # the name it runs (G=git; $G push --force is git), and an unresolved name that the command sets another way, or that a git
  # subcommand or a destructive flag follows, is blocked. A variable a shell's script (bash -c, eval, -Command) holds, or that a
  # script path under tools/ holds, is blocked too. The everyday forms pass: "$PY" -I script.py, a loop that runs "$PY" "$f", a
  # variable as an argument, and a single-quoted script's own variable (its shell reads it, and it can't name a command here).
  git_fail=""
  if [ -f .claude/hooks/guard-commands.sh ]; then
    for cmd in \
        'G=git; $G push --force' \
        '$G push --force' \
        '"$G" push --force' \
        'G=git; ${G} push --force' \
        'G=git; "$G" push --force' \
        '$G --force' \
        'if true; then $G push --force; fi' \
        'for f in x; do $G push --force; done' \
        '{ $G push --force; }' \
        'xargs $G push --force' \
        'find . -exec $G push --force \;' \
        'if true; then "$X" -c x; fi' \
        'CMD="git push --force"; $CMD' \
        'read CMD <<< "git push --force"; $CMD' \
        'FOO=$(echo git); $FOO push --force' \
        'X=../../evil.sh; bash tools/stacks/$X' \
        'bash tools/stacks/$X.sh' \
        'bash "tools/$X"' \
        'bash -c "$CMD"' \
        'eval "$CMD"' \
        'eval $CMD' \
        "bash -c '\$CMD'" \
        'CMD="git push --force" bash -c '"'"'$CMD'"'"'' \
        'sh -c "echo $HOME"' \
        $'G=git; bash <<\'EOF\'\n$G push --force\nEOF' \
        $'bash <<\'EOF\'\n$G push --force\nEOF' \
        $'CMD="git push --force" bash <<\'EOF\'\n$CMD\nEOF'; do
      guard 2 "$cmd"
    done
    for cmd in "\$G = 'git'; & \$G push --force" '& $G push --force'; do
      guard 2 "$cmd" PowerShell
    done
    guard 2 'powershell -Command "$P"' PowerShell
    for cmd in \
        'G=git; $G status' \
        'G=ls; $G push --force' \
        'echo $G push --force' \
        '"$PY" -I script.py' \
        'PY=python3; "$PY" -I script.py' \
        'FOO="a b" "$PY" -I x.py' \
        'for f in tools/*.py; do "$PY" "$f"; done' \
        'for f in a b; do echo "$f"; done' \
        'if true; then "$PY" -I x.py; fi' \
        'find . -name x -exec "$PY" -I y {} \;' \
        'xargs -I{} echo {}' \
        '"$PY" tools/usage.py status' \
        'bash "$script"' \
        'bash tools/check.sh "$X"' \
        'cd "$dir" && git status' \
        'bash -c "echo \$HOME"' \
        "bash -c 'echo \$HOME'" \
        $'git commit -q -F - <<\'EOF\'\n$G push --force\nEOF'; do
      guard 0 "$cmd"
    done
    guard 0 "powershell -Command 'Get-ChildItem | % { \$_.Name }'" PowerShell
  fi
  guard_run
  guard_report "$git_fail" "the guard hook doesn't read a variable as a command's name, or a script or script path that a variable holds, or blocks an everyday form (B45)" "the guard hook reads a variable as a command's name as the value it assigns, blocks an unresolved one that the command sets another way or a git subcommand follows, blocks a shell's script, eval or -Command that a variable holds and a tools/ script path with a variable, and passes the everyday forms (B45)"

  # An assignment is not a command, so it isn't read as a variable command name (B55): a PowerShell $x = 1, $x += 1 or $env:X = 'y',
  # and a PowerShell constant or automatic value that no call operator runs ($true, $null, $args), pass in a PowerShell payload and in
  # a PowerShell script a shell runs. A Bash NAME+=value is an assignment prefix, as NAME=value is. A call operator still runs
  # what its name holds, and a git subcommand after any name is still read: & $x, & $args[0], $args push --force and $G push
  # --force block, and so does out+=x $G push --force.
  git_fail=""
  if [ -f .claude/hooks/guard-commands.sh ]; then
    for cmd in \
        '$x = 1' \
        '$files = Get-ChildItem docs' \
        '$x=1' \
        '$x += 1' \
        '$x ??= 1' \
        "\$env:X = 'y'" \
        '$x[0] = 1' \
        '$null = Get-Date' \
        '$true' \
        '$false' \
        '$null' \
        'while ($true) { Get-Date }' \
        '$args' \
        '$_.Name' \
        '$input | Out-Null'; do
      guard 0 "$cmd" PowerShell
    done
    for cmd in \
        "\$x = 1; & \$x" \
        "\$x = 'git'; & \$x push --force" \
        '$args push --force' \
        '& $args[0] push --force' \
        '$input | ForEach-Object { & $_ push --force }' \
        '& $env:COMSPEC push --force'; do
      guard 2 "$cmd" PowerShell
    done
    for cmd in \
        "powershell -Command 'while (\$true) { Get-Date }'" \
        "powershell -Command '\$x = 1'" \
        'c="${x:0:1}"; out+="$c"; echo hi' \
        'out+=x; echo hi'; do
      guard 0 "$cmd"
    done
    for cmd in \
        'out+=x $G push --force' \
        'out+=x; $G push --force' \
        'c+=y; "$c" push --force' \
        "powershell -Command '\$args push --force'" \
        "powershell -Command '\$G = \"git\"; & \$G status'"; do
      guard 2 "$cmd"
    done
  fi
  guard_run
  guard_report "$git_fail" "the guard hook reads an assignment or a constant as a variable command name, or passes a call operator or a NAME+=value prefix that runs a git command (B55)" "the guard hook passes a PowerShell assignment, a constant and an automatic value that runs nothing, and a Bash NAME+=value assignment, and blocks a call operator or a prefixed variable that runs git (B55)"

  # PowerShell's Invoke-Expression and iex (B60) run their one string argument as a script, as eval does. A literal argument is read as
  # a script of its own, and a variable the command assigns once to a plain literal before the call is read as its value. A pipeline into
  # the call, no argument, an argument that isn't one string (a concatenation, a second argument, a double-quoted $( the caller expands),
  # and a variable that can't be resolved (one set another way, in a branch, or after the call) are blocked. The benign forms pass.
  git_fail=""
  if [ -f .claude/hooks/guard-commands.sh ]; then
    for cmd in \
        "iex 'git push --force'" \
        "Invoke-Expression 'git push --force'" \
        "Invoke-Expression -Command 'git push --force'" \
        "iex -Command:'git push --force'" \
        "IEX \"git push --force\"" \
        "iex 'git push --force' -Verbose" \
        "iex -Verbose 'git push --force'" \
        "iex '-Verbose git push --force'" \
        "Microsoft.PowerShell.Utility\\Invoke-Expression 'git push --force'" \
        "& iex 'git push --force'" \
        "ForEach-Object { iex 'git push --force' }" \
        "ForEach-Object {iex 'git push --force'}" \
        "\$x = 'git push --force'; iex \$x" \
        "\$x='git push --force'; iex \$x" \
        "\$x = 'git push --force'; Invoke-Expression \$x" \
        "\$x = 'git push --force'; iex \"\$x\"" \
        "\$x = \"git push --force\"; iex \$x" \
        "\$x = 'git push --force'; iex \${x}" \
        "\$x = 'git push --force'; iex \$x -Verbose" \
        "\$x = 'git push --force'; iex \$x | Out-Null" \
        "\$x = 'git'; iex \"\$x push --force\"" \
        "iex \$x" \
        "iex \"\$x\"" \
        "iex" \
        "iex \$x; \$x = 'git push --force'" \
        "\$x = 'git push --force' | Out-Null; iex \$x" \
        "\$x = 'ls'; iex \"\$x\" \"--force\"" \
        "\$x = 'ls'; iex \"\$x\"-f ''" \
        "\$x = 'ls'; iex \$x \$y" \
        "\$x = 'ls'; Set-Variable x 'git push --force'; iex \$x" \
        "\$x = 'ls'; . ./evil.ps1; iex \$x" \
        "\$x = 'ls'; Import-Module ./m.psm1; iex \$x" \
        "if (\$true) { \$x = 'ls' }; iex \$x" \
        "\$x = 'git push --force'; iex \$x[0]" \
        "\$x = 'ls'; \$x[0] = 'git push --force'; iex \$x" \
        "\$x = 'ls'; \$x += 'git push --force'; iex \$x" \
        "\$y = '\$x = ''git push --force'''; iex \$y; iex \$x" \
        "\$x = 'ls'; \$y = '\$x = ''git push --force'''; iex \$y; iex \$x" \
        "\$x = 'git push --force'; \$y = \$x; iex \$y" \
        "iex \"\$(Get-Content x.txt)\"" \
        "iex @args" \
        "\$x = 'Get-Date'; iex @x" \
        "iex ('git push' + ' --force')" \
        "iex 'git pu' + 'sh --force'" \
        "iex \"git push\" + \" --force\"" \
        "'git push --force' | iex" \
        "Get-Content x.ps1 | iex"; do
      guard 2 "$cmd" PowerShell
    done
    guard 2 "powershell -Command \"iex 'git push --force'\"" PowerShell
    for cmd in \
        "\$x = 'Get-Date'; iex \$x" \
        "\$x = 'Get-Date'; iex \"\$x\"" \
        "\$x = 'git status'; iex \$x" \
        "\$x = 'Get-Date'; \$y = 'git status'; iex \$x; iex \$y" \
        "\$x = 'git push --force'" \
        "\$x = 'git push --force'; iex 'Get-Date'" \
        "iex 'Get-Date'" \
        "iex 'Get-Date' -Verbose" \
        "Invoke-Expression -Command 'Get-Date' -Verbose" \
        "iex 'Write-Output \$x'" \
        "iex '\$x = 1'" \
        "iex \$true" \
        "iex 'Get-Date' | Out-Null" \
        "ForEach-Object { iex 'Get-Date' }" \
        "Get-Help Invoke-Expression" \
        "Get-Command iex" \
        "Write-Output 'iex git push --force'"; do
      guard 0 "$cmd" PowerShell
    done
  fi
  guard_run
  guard_report "$git_fail" "the guard hook doesn't read an Invoke-Expression or iex script as a command, or passes one it can't read (B60)" "the guard hook reads the string argument of Invoke-Expression and iex as a script, resolves a variable the command assigns once to a plain literal, blocks a pipeline into it, an argument that isn't one string and an unresolved variable, and passes the benign forms (B60)"

  # A git command name in another case (B46): PowerShell finds a command case-insensitively, and Windows finds GIT too, so GIT and
  # Git are git in every git rule. Only the name is matched so: git's subcommands and flags stay case-sensitive, as git reads them.
  # The git rules, the credential prints, a substitution in the words and a shell body that runs GIT block as their lowercase
  # forms do, and the everyday forms and a quoted or heredoc message that names git in another case pass.
  git_fail=""
  if [ -f .claude/hooks/guard-commands.sh ]; then
    for cmd in \
        'GIT push --force origin main' \
        'Git commit --no-verify -m x' \
        'GIT reset --hard HEAD~1' \
        'GIT log --output=/tmp/probe.txt' \
        'Git diff --no-index a b' \
        'GIT commit -F /tmp/msg.txt' \
        'GIT grep -Oecho foo' \
        'GIT push origin :main' \
        'GIT branch -D x' \
        'GIT credential fill' \
        'Git credential get' \
        'GIT -c core.pager=calc log' \
        'Git push "$(echo --force)" origin main' \
        $'bash <<\'EOF\'\nGIT push --force\nEOF'; do
      guard 2 "$cmd" PowerShell
    done
    for cmd in 'GIT push --force origin main' 'Git commit --no-verify -m x'; do
      guard 2 "$cmd"
    done
    for cmd in \
        'GIT status' \
        'Git log --oneline -5' \
        'GIT diff HEAD' \
        'GIT grep -n foo' \
        'GIT tag -a v1 -m "see --force and -F"' \
        'echo "Git push --force is blocked"' \
        'echo "Git credential fill is blocked"' \
        $'Git commit -q -F - <<\'EOF\'\nfix the --output and --no-index handling, not -F /tmp/x\nEOF'; do
      guard 0 "$cmd" PowerShell
    done
    guard 0 'GIT status'
  fi
  guard_run
  guard_report "$git_fail" "the guard hook passes a git command name in another case, or blocks a message that names git in another case (B46)" "the guard hook blocks a git command name in any case (GIT, Git) as it blocks git, and passes the everyday forms and the messages that name git in another case (B46)"

  # A shell's name in a bash script path under tools/ (B47): a quoted name is the same shell as the bare one, and so is one in another
  # case (PowerShell and Windows find a command case-insensitively). So "bash", 'sh' and BASH lead a path that leaves tools/ as bash
  # and sh do, and a quoted or split path, and a wrapper's script that names the shell in any case, are read too. The everyday forms
  # pass, and so does a message or an echo that names a shell with its path.
  git_fail=""
  if [ -f .claude/hooks/guard-commands.sh ]; then
    for cmd in \
        '"bash" tools/../x.sh' \
        "'sh' tools/stacks/../../x.sh" \
        'BASH tools/stacks/../../x.sh' \
        'Bash tools/../x.sh' \
        '"bash" "tools/../x.sh"' \
        'sh -x "tools/stacks/../x.sh"' \
        'BASH -x tools/stacks/../x.sh' \
        '"/bin/bash" tools/../x.sh' \
        'bash tools/".."/x.sh' \
        "bash 'tools/../x.sh'" \
        'env "bash" tools/../x.sh' \
        '"bash" ./tools/../x.sh' \
        '"BASH" -c "BASH tools/../x.sh"' \
        "sh -c 'BASH tools/../x.sh'" \
        '"bash" tools/stacks/$X.sh' \
        $'echo x\n"bash" tools/../x.sh'; do
      guard 2 "$cmd"
    done
    for cmd in '"bash" tools/../x.sh' 'BASH tools/stacks/../../x.sh'; do
      guard 2 "$cmd" PowerShell
    done
    for cmd in \
        'bash tools/check.sh' \
        '"bash" tools/check.sh' \
        'BASH tools/check.sh' \
        "'sh' tools/stacks/godot.sh --since HEAD~3..HEAD" \
        'echo "bash" tools/../x.sh' \
        'echo "BASH tools/../x.sh"' \
        'git commit -m "bash tools/../x.sh"' \
        'cat "sh" tools/../x.sh' \
        'git status'; do
      guard 0 "$cmd"
    done
    guard 0 '"bash" tools/check.sh' PowerShell
  fi
  guard_run
  guard_report "$git_fail" "the guard hook passes a bash script path that leaves tools/ when its shell's name is quoted or in another case (B47)" "the guard hook blocks a script path under tools/ that leaves it, when bash or sh is quoted or in any case, and passes the everyday forms and the messages that name a shell (B47)"

  # Git's configuration keys and program flags (B38). A -c key, or --config-env, that names a program git runs (an alias that
  # starts with !, the pager, the editor, the ssh command, a diff or credential helper, an include) is blocked, and so is a key a
  # variable holds; the keys that run nothing pass (core.quotepath, color.*, advice.*, log.*, user.name, pager.<cmd>=false). The
  # flags that name a program for a remote (--upload-pack, --receive-pack, --exec, and clone's -u), abbreviations included, are
  # blocked on fetch, pull, push, clone, ls-remote and archive, and a plain fetch, push -u and clone -b pass. A variable that names
  # a program git runs (GIT_CONFIG_*, GIT_SSH_COMMAND, GIT_PAGER, GIT_EDITOR, EDITOR) set on a git command is blocked too.
  git_fail=""
  if [ -f .claude/hooks/guard-commands.sh ]; then
    for cmd in \
        'git -c alias.x="!echo hi" x' \
        "git -c 'alias.x=!echo hi' x" \
        'git -c "alias.x=!echo hi" x' \
        'git -c core.pager="sh -c x" log' \
        'git -c core.sshCommand=x fetch' \
        'git -c diff.external=x diff' \
        'git -c "$k=v" log' \
        'git -c Alias.X=y x' \
        'git -c core.quotepath=false -c alias.x=y x' \
        'git -c color.ui=always -c core.pager=x log' \
        'git -c sequence.editor=x rebase -i HEAD~2' \
        "git -c credential.helper='!x' fetch origin" \
        'git -c protocol.ext.allow=always fetch origin' \
        'git -c include.path=/tmp/x log' \
        'git -c "core.$(echo pager)=x" log' \
        'git -c pager.log=less log' \
        'git --config-env=core.pager=PAGER_VAR log' \
        'git --git-dir .git -c alias.x=y x' \
        "git -c \$'alias.x=!echo hi' x" \
        "git -c 'alias.x=y' x" \
        'git -c "alias.x" x' \
        'git -c "a""lias.x=!echo" x' \
        'git -c "core.pager"=sh x' \
        'k=core.pager; git -c "$k=sh" log' \
        $'git \\\n-c core.pager=x log' \
        'git clone -c core.sshCommand=x https://example.com/r.git d' \
        'git clone --config=alias.x=y https://example.com/r.git d' \
        'git clone --config alias.x=y https://example.com/r.git d' \
        'git clone -c alias.x=y https://example.com/r.git d' \
        'git clone -u "sh -c x" https://example.com/r.git d' \
        'git clone --upload-pack="sh -c x" https://example.com/r.git d' \
        'git clone -qu "sh -c x" https://example.com/r.git d' \
        'git fetch --upload-pack x origin' \
        'git fetch --upl=x origin' \
        'git fetch --upload-pack="$(echo x)" origin' \
        'git fetch "--$(echo upload-pack)=x" origin' \
        'git pull --upload-pack=x' \
        'git push --receive-pack=x origin main' \
        'git push --receive-pack x origin main' \
        'git push --exec=x origin main' \
        'git push origin main --receive=x' \
        'git ls-remote --upload-pack=x origin' \
        'git archive --remote=origin --exec=x HEAD' \
        'GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.pager GIT_CONFIG_VALUE_0=x git log' \
        'GIT_SSH_COMMAND=x git fetch' \
        'GIT_PAGER=x git log' \
        'GIT_EXTERNAL_DIFF=x git log -p' \
        'env GIT_EDITOR=x git commit' \
        'export GIT_PAGER=x; git log' \
        'EDITOR=x git commit -a'; do
      guard 2 "$cmd"
    done
    for cmd in 'git -c core.pager=x log' 'git -c "$k=v" log' 'git fetch --upload-pack=x' 'git -c alias.x=!echo x' \
        '$env:GIT_PAGER="x"; git log'; do
      guard 2 "$cmd" PowerShell
    done
    for cmd in \
        'git -c core.quotePath=false status --porcelain --untracked-files=all' \
        'git -c core.quotepath=off log --oneline -3' \
        'git -c color.ui=never log --oneline' \
        'git -c user.name=selftest -c user.email=selftest@localhost commit -m x' \
        "git -c 'user.name=A B' commit -m x" \
        'git -c advice.detachedHead=false checkout HEAD~1' \
        'git -c log.showSignature=false log -1' \
        'git -c pager.log=false log --oneline' \
        'git -c "color.ui=always" diff --stat' \
        'k=color.ui; git -c "$k=always" log --oneline' \
        'git -C work/App-Director fetch' \
        'git -c core.quotepath=false -C work/App-Director status' \
        'git clone -b main https://example.com/r.git d' \
        'git clone -q --depth 1 https://example.com/r.git d' \
        'git clone -c core.quotepath=false https://example.com/r.git d' \
        'git fetch origin' \
        'git fetch --unshallow origin' \
        'git push -u origin "$branch"' \
        'git push origin main' \
        'git push --recurse-submodules=check origin main' \
        'git ls-remote origin' \
        'git archive --format=tar HEAD' \
        'git pull --rebase origin main' \
        'git log -c' \
        'git commit -c HEAD' \
        'git commit -m "--upload-pack=x fix"' \
        'git commit -m "alias.x=!echo hi"' \
        'git tag -a v1 -m "-c alias.x=y"' \
        'git commit -m "set EDITOR=vim and GIT_PAGER=x"' \
        'GIT_AUTHOR_NAME=x git commit -m y' \
        'FOO=1 git status' \
        'EDITORCONFIG=x git status' \
        $'git commit -q -F - <<\'EOF\'\nGIT_PAGER=x and EDITOR=vim in a message\nEOF' \
        $'git \\\n-c core.quotepath=false status'; do
      guard 0 "$cmd"
    done
    guard 0 'git -c user.email=a@b.c commit -m x' PowerShell
    guard 0 'git -c color.ui=always status' PowerShell
    guard 0 'git push -u origin main' PowerShell
  fi
  guard_run
  guard_report "$git_fail" "the guard hook passes a git -c key or a program flag that runs a command, or a variable that names one, or blocks a plain form (B38)" "the guard hook blocks a git -c key that names a program (an alias, the pager, the ssh command, a diff or credential helper), a key a variable holds, a program flag for a remote (--upload-pack, --receive-pack, --exec, clone's -u), and a GIT_CONFIG_*, GIT_PAGER or EDITOR variable on a git command; the keys that run nothing and the plain forms pass (B38)"

  # A quoted git name, a heredoc body a shell runs, the long forms and a credential subcommand in quotes (B39). The git name is
  # read as the shell reads it, quotes removed, so "git", 'git' and g"it" are git. A heredoc body a shell runs (any body but a
  # commit's or tag's message) is read by the file-writing flag rules, and a backtick ends a flag in it. git branch with --delete
  # and --force (-d -f, -df, --del --forc), git push --mirror, --delete and -d (abbreviations too) and a :ref refspec are blocked,
  # as their plain forms are, and the credential-print rules read the decoded words. A message that names them, and a read that
  # names none, pass: a commit's or tag's message is text no shell runs.
  git_fail=""
  if [ -f .claude/hooks/guard-commands.sh ]; then
    for cmd in \
        '"git" push --force' \
        "'git' push --force" \
        'g"it" push --force' \
        '"git" log --output=/tmp/x' \
        $'bash <<\'EOF\'\ngit log --output=/tmp/x\nEOF' \
        $'sh <<EOF\ngit diff --no-index a b\nEOF' \
        $'bash <<\'EOF\'\ngit commit -F /tmp/msg.txt\nEOF' \
        $'bash <<\'EOF\'\ngit grep -Oecho foo\nEOF' \
        $'cat <<\'EOF\' | bash\ngit log --output=/tmp/x\nEOF' \
        $'bash <<\'EOF\'\ngit branch --delete --force x\nEOF' \
        $'bash <<\'EOF\'\ngit push --mirror\nEOF' \
        $'bash <<\'EOF\'\ngit credential "fill"\nEOF' \
        $'bash <<\'EOF\'\ngit push `echo --force`\nEOF' \
        $'bash <<\'EOF\'\ngit push --force`echo x`\nEOF' \
        $'ssh host <<\'EOF\'\ngit push `echo --force`\nEOF' \
        $'git status && bash <<\'EOF\'\ngit push `echo --force`\nEOF' \
        $'"bash" <<\'EOF\'\ngit push --mirror\nEOF' \
        $'git commit -m "$(source /dev/stdin <<\'EOF\'\ngit push `echo --force`\nEOF\n)"' \
        'sh -c "git push --mirror"' \
        'git branch --delete --force x' \
        'git branch --delete -f x' \
        'git branch -d -f x' \
        'git branch -df x' \
        'git branch -fd x' \
        'git branch --del --forc x' \
        'git push --mirror' \
        'git push --mirror origin' \
        'git push --mi origin' \
        'git push --delete origin x' \
        'git push --de origin x' \
        'git push -d origin x' \
        'git push -fd origin x' \
        'git push origin :x' \
        'git push origin ":x"' \
        'git push origin :refs/heads/x' \
        'git credential "fill"' \
        "git credential 'get'" \
        'git credential fi"ll"' \
        'gh "auth" "token"' \
        'g"h" auth token'; do
      guard 2 "$cmd"
    done
    for cmd in \
        'git branch -d x' \
        'git branch -vv' \
        'git branch -m old new' \
        'git branch --list "*f*"' \
        'git push origin main:main' \
        'git push origin HEAD:refs/heads/x' \
        'git push --dry-run origin main' \
        'git push --set-upstream origin x' \
        'echo "git push --mirror"' \
        'echo "git credential fill"' \
        'git log --grep "push --mirror"' \
        'git status && echo "git credential fill"' \
        $'git commit -q -F - <<\'EOF\'\nfix: git push --mirror and git branch -d x\nEOF' \
        $'git commit -q -F - <<\'EOF\'\nfix: git log --output=x in the docs\nEOF' \
        $'git commit -q -F - <<\'EOF\'\nmsg with `git push --force` in it\nEOF' \
        $'git tag -a v1 -F - <<\'EOF\'\nfix: git push --delete origin x\nEOF' \
        $'git commit -q -F - <<\'EOF\'\nfix the --mirror and --delete flags, not -d\nEOF' \
        $'bash <<\'EOF\'\necho hi\nEOF' \
        $'bash <<\'EOF\'\ngit status\nEOF' \
        $'bash <<\'EOF\'\ngit branch -d x\nEOF' \
        $'git status && bash <<\'EOF\'\necho x\nEOF'; do
      guard 0 "$cmd"
    done
    for cmd in '"git" push --force' 'git branch --delete --force x' 'git push --mirror' 'git push origin :x' \
        'git credential "fill"' 'gh "auth" "token"'; do
      guard 2 "$cmd" PowerShell
    done
    for cmd in 'git branch -d x' 'git push origin main'; do
      guard 0 "$cmd" PowerShell
    done
  fi
  guard_run
  guard_report "$git_fail" "the guard hook doesn't read a quoted git name, a heredoc body a shell runs, a long-form branch or push flag, a push refspec that deletes, or a quoted credential subcommand as the shell does, or blocks a message that names a plain form (B39)" "the guard hook blocks a quoted git name, a heredoc body a shell runs with a file-writing flag, a backtick flag or a destructive command, git branch --delete --force, git push --mirror, --delete or a :ref refspec, and a quoted credential subcommand, and passes the messages and reads that name them (B39)"

  # A heredoc body no shell runs is text (B40): a commit's or tag's message, and a cat or tee body that the command doesn't run (no
  # shell, interpreter, ssh, chmod, make, a ./ path, a dot-source or the .git folder). The destructive rules and the file-writing flag
  # rules skip such a body, so a message or a written file that names a destructive git command passes, and its substitutions are
  # still read. A body written to a file and run in the same command (cat > x.sh, then bash x.sh, ./x.sh or . x.sh) is a script a
  # shell runs, and is read as before. The guard reads command text, so a file written by an earlier command isn't judged.
  git_fail=""
  if [ -f .claude/hooks/guard-commands.sh ]; then
    for cmd in \
        $'git commit -q -F - <<\'EOF\'\nfix: git push --force; done\nEOF' \
        $'git tag -a v1 -F - <<\'EOF\'\nfix: git push --delete origin x\nEOF' \
        $'git commit -q -F - <<\'EOF\'\nmsg with `git push --force` in it\nEOF' \
        $'git commit -m "$(cat <<\'EOF\'\nfix: git reset --hard\nEOF\n)"' \
        $'git commit -q -F - <<\'EOF\'\nfix: git log --output=x in the docs\nEOF\nbash x.sh' \
        $'cat > notes.md <<\'EOF\'\nsee git log --output=x\nEOF' \
        $'cat > notes.md <<\'EOF\'\na backticked `git push --force` here\nEOF' \
        $'tee notes.md <<\'EOF\'\ngit push --mirror\nEOF' \
        $'cat <<\'EOF\' > notes.md\ngit reset --hard\nEOF' \
        $'cat >> notes.md <<\'EOF\'\ngit branch -D x\nEOF' \
        $'cat > notes.md <<\'EOF\'\ngit push --force\nEOF\ngit add notes.md && git status' \
        $'cat > ./notes.md <<\'EOF\'\ngit grep -Oecho foo\nEOF' \
        $'cat > notes.md <<\'EOF\'\nbash -c \'git push --force\'\nEOF' \
        $'cat > notes.md <<EOF\nplain text, no git here\nEOF' \
        $'cat > notes.md <<\'EOF\'\ngit push --force\nEOF\necho "run bash later"' \
        $'cat > notes.md <<\'EOF\'\ngit push --force\nEOF\ngit commit -q -F - <<\'EOF2\'\nfix: git push --force\nEOF2'; do
      guard 0 "$cmd"
    done
    for cmd in \
        $'cat > x.sh <<EOF\ngit push --force\nEOF\nbash x.sh' \
        $'cat > x.sh <<\'EOF\'\ngit push --force\nEOF\nbash x.sh' \
        $'cat > x.sh <<\'EOF\'\ngit push --force\nEOF\nchmod +x x.sh && ./x.sh' \
        $'cat > x.sh <<\'EOF\'\ngit reset --hard\nEOF && sh x.sh' \
        $'cat > x.sh <<\'EOF\'\ngit log --output=/tmp/x\nEOF\nbash x.sh' \
        $'cat > x.sh <<\'EOF\'\ngit push --force\nEOF\nsource x.sh' \
        $'tee x.sh <<\'EOF\'\ngit push --force\nEOF\n. ./x.sh' \
        $'cat > x.sh <<\'EOF\'\ngit push --force\nEOF\n"bash" x.sh' \
        $'cat > x.sh <<\'EOF\'\ngit push --force\nEOF\npython3 x.sh' \
        $'cat > x.sh <<\'EOF\'\ngit push --force\nEOF\nenv bash x.sh' \
        $'cat > Makefile <<\'EOF\'\npush:\n\tgit push --force\nEOF\nmake push' \
        $'cat > .git/hooks/pre-commit <<\'EOF\'\ngit push --force\nEOF\ngit commit -q -m x' \
        $'cat > notes.md <<EOF\n$(git push --force)\nEOF' \
        $'cat > notes.md <<EOF\n`git push --force`\nEOF' \
        $'git commit -q -F - <<EOF\nfix `git push --force`\nEOF' \
        $'cat <<\'EOF\' | bash\ngit push --force\nEOF' \
        $'bash <<\'EOF\'\ngit push --force\nEOF'; do
      guard 2 "$cmd"
    done
    guard 2 $'cat > x.ps1 <<\'EOF\'\ngit push --force\nEOF\n& ./x.ps1' PowerShell
  fi
  guard_run
  guard_report "$git_fail" "the guard hook reads a commit's or tag's message, or a cat or tee body that nothing in the command runs, as a script (B40), or passes a body a shell runs" "the guard hook passes a commit's or tag's message and a cat or tee body that the command doesn't run, and blocks a body written to a file and run in the same command (B40)"

  # A gh message with a quoted delimiter (B48): gh pr create and edit, issue create, edit and comment, and release create and edit
  # take the body from stdin (--body-file -, -F -, --notes-file -) or from a $(cat <<'EOF') given to --body, -b, --notes or -n. That
  # body is text no shell runs, as a commit's message is (B40), so the destructive rules skip it, and the variable rules (B37)
  # skip it and a cat body nothing runs. A body a shell runs, an unquoted body with a substitution, a git command that goes on past
  # the body, or a body piped to a shell is still read.
  git_fail=""
  if [ -f .claude/hooks/guard-commands.sh ]; then
    for cmd in \
        $'gh pr edit 5 --body-file - <<\'EOF\'\nfix: git push --force; done\nEOF' \
        $'gh pr create --body "$(cat <<\'EOF\'\nfix: git push --force\nEOF\n)"' \
        $'gh pr create --title t --body-file - <<\'EOF\'\nDo not run git push --force\nEOF' \
        $'gh issue comment 5 -F - <<\'EOF\'\ngit reset --hard\nEOF' \
        $'gh issue create -b "$(cat <<\'EOF\'\ngit branch -D x\nEOF\n)"' \
        $'gh release create v1 --notes-file - <<\'EOF\'\ngit push --mirror\nEOF' \
        $'gh release edit v1 -n "$(cat <<\'EOF\'\ngit push --delete origin x\nEOF\n)"' \
        $'gh pr create --body-file=- <<\'EOF\'\ngit push --force\nEOF' \
        $'GH pr create -F- <<\'EOF\'\ngit push --force\nEOF' \
        $'gh pr create --body="$(cat <<\'EOF\'\ngit push --force\nEOF\n)"' \
        $'gh pr edit 5 --body-file - <<\'EOF\'\ngit push --force\nEOF' \
        $'gh pr create --body-file - <<\'EOF\'\nbash -c \'git push --force\'\nEOF' \
        $'gh pr create --body-file - <<\'EOF\'\necho cmd /c "git push --force"\nEOF' \
        $'gh pr edit 5 --body-file - <<\'EOF\'\nfix: git push $X handling\nEOF' \
        $'git commit -q -F - <<\'EOF\'\nfix: git push $X handling\nEOF' \
        $'git tag -a v1 -F - <<\'EOF\'\nfix: git push $X handling\nEOF' \
        $'cat > notes.md <<\'EOF\'\nfix: git push $X handling\nEOF'; do
      guard 0 "$cmd"
    done
    for cmd in \
        $'gh pr edit 5 --body-file - <<\'EOF\' && git push --force\nmsg\nEOF' \
        $'gh pr create --body-file - <<\'EOF\'\nmsg\nEOF\ngit push --force' \
        $'gh pr create --body-file - <<\'EOF\' | bash\ngit push --force\nEOF' \
        $'gh pr create --body-file - <<EOF\nfix: git push --force\nEOF' \
        $'gh pr create --body "$(cat <<EOF\n$(git push --force)\nEOF\n)"' \
        $'gh pr create --body "$(cat <<\'EOF\'\nmsg\nEOF\n)" --title "$(git push --force)"' \
        $'bash <<\'EOF\'\ngit push $X\nEOF' \
        $'cat > x.sh <<\'EOF\'\ngit push $X\nEOF\nbash x.sh'; do
      guard 2 "$cmd"
    done
    # A shell or PowerShell name right after a word that only prints its words (echo, printf, Write-Output, Write-Host, write) is
    # text (B48). Anywhere else it may run a script, so a launcher's argument stays read: ssh, find -exec, docker exec, Start-Process.
    for cmd in \
        "echo PowerShell 'bash tools/../x.sh'" \
        "echo pwsh 'bash tools/../x.sh'" \
        "echo bash -c 'git push --force'" \
        'echo sh -c "git push --force"' \
        $'printf sh -c \'git push --force\'' \
        $'echo eval \'git push --force\'' \
        'echo PowerShell -Command "git push --force"'; do
      guard 0 "$cmd"
    done
    for cmd in \
        'ssh host pwsh -c "git push --force"' \
        'find . -exec pwsh -c "git push --force" \;' \
        'docker exec ctr pwsh -c "git push --force"' \
        'ssh host sh -c "git push --force"' \
        'find . -exec sh -c "git push --force" \;' \
        $'docker exec ctr bash -c \'git push --force\''; do
      guard 2 "$cmd"
    done
    for cmd in \
        'Write-Output PowerShell -Command "git push --force"' \
        "Write-Output powershell 'bash tools/../x.sh'" \
        "echo pwsh 'bash tools/../x.sh'" \
        "Write-Host Pwsh.exe 'bash tools/../x.sh'"; do
      guard 0 "$cmd" PowerShell
    done
    for cmd in \
        "Start-Process powershell -ArgumentList 'git push --force'" \
        'ssh host pwsh -c "git push --force"' \
        'timeout 60 powershell -c "git push --force"'; do
      guard 2 "$cmd" PowerShell
    done
  fi
  guard_run
  guard_report "$git_fail" "the guard hook reads a gh message's body, or a variable in a message or a cat body nothing runs, as a command, passes a body a shell runs, or reads a word after echo, printf, Write-Output, Write-Host or write, or a launcher's argument, wrongly (B48)" "the guard hook passes a gh pr, issue or release message with a quoted delimiter, and a variable in a message or in a cat body nothing runs, and blocks a git command after a message, an unquoted message, a message piped to a shell, and a variable in a body a shell runs; a shell or PowerShell name after echo, printf, Write-Output, Write-Host or write is text, and one that a launcher passes a script to is read (B48)"

  # The fixes the ports to SaaSAllTheThings and Godot-Director brought back (Director-Driven-Development T285). A path-qualified or
  # .exe git is git, in any case (/usr/bin/git, git.exe, GIT.EXE), where a path that only ends in git is an argument. A Python heredoc
  # is blocked whatever its body, also behind a path (a body of blank lines, one line), and a script file given a heredoc passes. In PowerShell a
  # backslash at a line's end is a path separator, not a continuation, so the line after a comment that ends in one is a command of
  # its own. A wait loop ends at the done that closes it, counting the do and done of the loops nested in it and skipping a done in
  # its condition, and a pause may have a fraction (sleep 600.5). The credential-print rules read a command without its messages.
  git_fail=""
  nlc=$'\n'
  if [ -f .claude/hooks/guard-commands.sh ]; then
    for cmd in \
        '/usr/bin/git push --force origin main' \
        'git.exe push --force origin main' \
        'GIT.EXE push --force' \
        '/usr/bin/git branch -D y' \
        'cd x && /usr/bin/git commit -m x --no-verify' \
        '/usr/bin/git -c core.pager=x log' \
        '/usr/bin/git push "$(echo --force)"' \
        'FLAG=--force; /usr/bin/git push $FLAG' \
        'sudo /usr/bin/git push --force' \
        '/usr/bin/git credential fill' \
        'echo hi && git.exe reset --hard' \
        "cd x && /usr/bin/python3 - <<'EOF'${nlc}EOF" \
        "/usr/bin/python3 - <<'EOF'${nlc}EOF" \
        "python3 - <<'EOF'${nlc}${nlc}EOF" \
        "python - <<-'EOF'${nlc}${nlc}EOF" \
        "/usr/bin/python3 - <<'EOF'${nlc}${nlc}${nlc}EOF" \
        "/usr/bin/python3 - <<'EOF'${nlc}print(1)${nlc}EOF" \
        "# c\\${nlc}gh auth token" \
        'until [ -f done ]; do sleep 5; done' \
        'until [ -f done ]; do sleep 5; done; echo done' \
        'while true; do for f in a b; do :; done; sleep 5; done' \
        'until [ -f done ]; do for f in a; do :; done; sleep 5; done' \
        'until false; do while read l; do :; done < f; sleep 5; done' \
        "while true; do${nlc}  for f in a b; do :; done${nlc}  sleep 5${nlc}done" \
        'sleep 600.5' \
        'sleep 280.5' \
        'sleep 5.5m' \
        'echo hi && sleep 300.0' \
        'gh auth token' \
        'gh auth status -t' \
        'git credential fill' \
        "git commit -q -F - <<'EOF'${nlc}msg${nlc}EOF${nlc}gh auth token" \
        "git commit -q -m x && gh auth token" \
        "bash <<'EOF'${nlc}gh auth token${nlc}EOF"; do
      guard 2 "$cmd"
    done
    for cmd in \
        '/usr/bin/git status' \
        'git.exe log -1' \
        '/usr/bin/git commit -m "docs: a note"' \
        '/usr/bin/git push origin main' \
        'ls /usr/bin/git' \
        'cp $SRC/git $DST' \
        'cd /c/git && ls' \
        "python3 tool.py <<'EOF'${nlc}${nlc}EOF" \
        "python tool.py <<-'EOF'${nlc}${nlc}EOF" \
        "/usr/bin/python3 tool.py <<'EOF'${nlc}${nlc}${nlc}EOF" \
        "/usr/bin/python3 tool.py <<'EOF'${nlc}print(1)${nlc}EOF" \
        'timeout 240 bash -c "until [ -f done ]; do sleep 5; done"' \
        'timeout 120 bash -c "while true; do for f in a b; do :; done; sleep 5; done"' \
        'for f in a b; do echo "$f"; done; sleep 5' \
        'until [ -f done ]; do echo wait; done' \
        'while true; do for f in a b; do :; done; done' \
        'while read -r l; do echo "$l"; done < f' \
        'sleep 280.0' \
        'sleep 4.5m' \
        'sleep 0.5' \
        'sleep 280' \
        "git commit -q -F - <<'EOF'${nlc}docs: the hook blocks gh auth token${nlc}EOF" \
        "git commit -q -F - <<'EOF'${nlc}docs: git credential fill prints a credential${nlc}EOF" \
        "gh pr edit 5 --body-file - <<'EOF'${nlc}It blocks gh auth token and git credential fill.${nlc}EOF" \
        'git commit -m "mention gh auth token in the notes"' \
        'gh auth login'; do
      guard 0 "$cmd"
    done
    for cmd in \
        "# c\\${nlc}gh auth token" \
        "# c\\${nlc}git push --force" \
        "git status # c\\${nlc}gh auth token" \
        'Start-Sleep -Seconds 600.5' \
        'Start-Sleep 280.5' \
        'Start-Sleep -Milliseconds 280000.5' \
        '/usr/bin/git push --force origin main' \
        'gh auth token'; do
      guard 2 "$cmd" PowerShell
    done
    for cmd in \
        "# c\\${nlc}Get-Date" \
        "dir C:\\x\\${nlc}git status" \
        "git push \\${nlc}--force" \
        'Start-Sleep -Seconds 0.5' \
        'Start-Sleep -Milliseconds 280000.0' \
        'Start-Sleep -Milliseconds 280000' \
        '/usr/bin/git status' \
        "git commit -q -F - <<'EOF'${nlc}docs: the hook blocks gh auth token${nlc}EOF"; do
      guard 0 "$cmd" PowerShell
    done
    # In Bash the same backslash continues the line, so the lines are one command.
    guard 2 "git push \\${nlc}--force"
  fi
  guard_run
  # The view flags (vdep, vcov, vpx, vhang) and the rest of what the hook reads before it sets it start empty, so a variable of the same
  # name in the hook's environment is no flag: vhang=1 would skip every git rule and vcov=1 would bound every wait loop.
  if [ -f .claude/hooks/guard-commands.sh ]; then
    for env_cmd in 'git push --force origin main' 'until [ -f x ]; do sleep 5; done' 'git status'; do
      json_str "$env_cmd"
      printf '{"session_id":"s","tool_name":"Bash","tool_input":{"command":"%s","description":"run"}}' "$JSON_STR" > "$guard_dir/env.json"
      expect_rc=2; [ "$env_cmd" = 'git status' ] && expect_rc=0
      for env_flag in vps vdep vcov vpx vhang cn_all hsubb; do
        env "$env_flag=1" bash .claude/hooks/guard-commands.sh < "$guard_dir/env.json" >/dev/null 2>&1; env_rc=$?
        [ "$env_rc" -eq "$expect_rc" ] || git_fail="$git_fail"$'\n'"  $env_flag=1 in the hook's environment changed the exit code to $env_rc, expected $expect_rc: $env_cmd"
      done
    done
  fi
  guard_report "$git_fail" "the guard hook misses a path-qualified or .exe git, a PowerShell backslash, a nested or condition-named done in a wait loop, a pause with a fraction, a flag set by the environment or a credential-print command, or blocks a message that names one (T285)" "the guard hook reads a path-qualified or .exe git as git, a PowerShell backslash as a path separator, a wait loop to the done that closes it, a pause with a fraction, no flag from the environment, and a credential-print command but not a message that names one"

  # Python that reads its script from a heredoc or a here-string is blocked whatever the body (Director-Driven-Development T309, B64):
  # on Windows it can wait for console input and never return, so the check no longer looks for an empty body. Every form blocks and
  # names Python: python, python3, python3.13, pythonw and py, with or without .exe, bare, behind a path or quoted; with or without the
  # - and with interpreter options; each heredoc form and a here-string; behind a wrapper or in a chain, a time limit too; piped in
  # (cat <<'E' | python -, and in PowerShell a here-string); split by a continuation; inside a heredoc body or a script a shell runs; and
  # B64's form (a node -e string after the header closes on the second line, so the body looks empty). A script file given a heredoc
  # of data, python -c and -m, python3 --version, and a message that names the form (a commit's or tag's body, a gh message, an echo or
  # grep of the text, a cat body nothing runs) pass.
  git_fail=""
  nlc=$'\n'; py_msg='python reading its script from a heredoc'; py_body=$'\nprint(1)\nE'
  if [ -f .claude/hooks/guard-commands.sh ]; then
    for cmd in \
        "python - <<'E'$py_body" \
        "python <<'E'$py_body" \
        "python3 - <<'E'$py_body" \
        "python3 <<'E'$py_body" \
        "python3.13 - <<'E'$py_body" \
        "pythonw - <<'E'$py_body" \
        "py - <<'E'$py_body" \
        "py <<'E'$py_body" \
        "python.exe - <<'E'$py_body" \
        "python3.exe - <<'E'$py_body" \
        "py.exe - <<'E'$py_body" \
        "PYTHON.EXE - <<'E'$py_body" \
        "/usr/bin/python3 - <<'E'$py_body" \
        "/usr/bin/env python3 - <<'E'$py_body" \
        "C:\\Python313\\python.exe - <<'E'$py_body" \
        "\"C:/Program Files/Python313/python.exe\" - <<'E'$py_body" \
        "'C:\\Program Files\\Python313\\python.exe' - <<'E'$py_body" \
        "\"python3\" - <<'E'$py_body" \
        "python3 -u - <<E$py_body" \
        "python3 -X utf8 - <<E$py_body" \
        "python3 -I -B - <<E$py_body" \
        "python3 -W error - <<E$py_body" \
        "py -3 - <<E$py_body" \
        "py -3.12 -u - <<E$py_body" \
        "python3 -u <<E$py_body" \
        "python - <<E$py_body" \
        "python - <<\"E\"$py_body" \
        "python - <<\\E$py_body" \
        "python - <<-E$py_body" \
        "python - <<-'E'$py_body" \
        "python -<<E$py_body" \
        "python - <<<'print(1)'" \
        "python <<<\"print(1)\"" \
        "python3 - <<<\"print(1)\"" \
        "timeout 60 python - <<E$py_body" \
        "timeout -k 5 60 python3 - <<E$py_body" \
        "env X=1 python - <<E$py_body" \
        "PYTHONUNBUFFERED=1 python3 -u - <<E$py_body" \
        "winpty python - <<E$py_body" \
        "cd x && python - <<E$py_body" \
        "python3 - <<E 2>/dev/null || true$py_body" \
        "python3 - 2>/dev/null <<'E'$py_body" \
        "python3 - <<'E' 2>/dev/null || echo \"no python\"$py_body" \
        "python3 - <<'E' 2>/dev/null || node -e \"${nlc}x()\"${nlc}E" \
        "python3 - <<'E' 2>/dev/null || node -e 'x()'${nlc}print(1)${nlc}E" \
        "python3 - <<'E'${nlc}${nlc}E" \
        "cat <<'E' | python -$py_body" \
        "cat <<E | python3$py_body" \
        "cat <<'E' | python3 -u -$py_body" \
        "cat <<'E' | /usr/bin/python3 -$py_body" \
        "cat <<'E' | timeout 60 python -$py_body" \
        "cat <<'E' | \"C:/Program Files/Python313/python.exe\" -$py_body" \
        "cat <<'E' | tr a b | python -$py_body" \
        "python3 \\${nlc}- <<'E'$py_body" \
        "python3 \\${nlc}  -u \\${nlc}  - <<'E'$py_body" \
        "bash <<'X'${nlc}python3 - <<'E'${nlc}print(1)${nlc}E${nlc}X" \
        "bash <<X${nlc}python3 - <<E${nlc}print(1)${nlc}E${nlc}X" \
        "cat <<'X' | bash${nlc}python3 - <<'E'${nlc}print(1)${nlc}E${nlc}X" \
        "bash -c \"python3 - <<'E'${nlc}print(1)${nlc}E\"" \
        "bash -c 'python3 <<<\"print(1)\"'" \
        "sh -c \"timeout 60 python3 - <<E${nlc}print(1)${nlc}E\"" \
        "eval \"python3 - <<'E'${nlc}print(1)${nlc}E\"" \
        "echo \$(python3 - <<'E'${nlc}print(1)${nlc}E${nlc})" \
        "git commit -q -F - <<'E'${nlc}msg${nlc}E${nlc}python3 - <<'F'${nlc}print(1)${nlc}F" \
        "cat > x.py <<'E'${nlc}print(1)${nlc}E${nlc}python3 - <<'F'${nlc}print(2)${nlc}F" \
        "python3 - <<'E'${nlc}print(\"it's\")${nlc}E"; do
      guard 2 "$cmd" Bash "$py_msg"
    done
    # The PowerShell tool reads the same text, and a here-string piped into the interpreter is its form of the pipe.
    for cmd in \
        "python - <<'E'$py_body" \
        "python3 <<<\"print(1)\"" \
        "timeout 60 python - <<E$py_body" \
        "py -3 - <<E$py_body" \
        "cat <<'E' | python -$py_body" \
        "bash <<'X'${nlc}python3 - <<'E'${nlc}print(1)${nlc}E${nlc}X" \
        "@'${nlc}print(1)${nlc}'@ | python -" \
        "@\"${nlc}print(1)${nlc}\"@ | python" \
        "@'${nlc}print(1)${nlc}'@ | python3 -u -" \
        "@'${nlc}print(1)${nlc}'@ | python.exe -" \
        "@'${nlc}print(1)${nlc}'@ | py -3 -" \
        "@'${nlc}print(1)${nlc}'@ | & python -" \
        "@'${nlc}print(1)${nlc}'@ | & \"C:\\Program Files\\Python313\\python.exe\" -" \
        "@'${nlc}print(1)${nlc}'@ | C:\\Python313\\python.exe -" \
        "@'${nlc}print(\"it's\")${nlc}'@ | python -" \
        "@'${nlc}print(1)${nlc}'@ | python -${nlc}Get-Date" \
        "@'${nlc}print(1)${nlc}'@ | python3.13 -"; do
      guard 2 "$cmd" PowerShell "$py_msg"
    done
    guard 2 "@'${nlc}print(1)${nlc}'@ | python -" Bash "$py_msg"
    for cmd in \
        "python tool.py <<'E'${nlc}data${nlc}E" \
        "python3 tool.py --flag <<E${nlc}data${nlc}E" \
        "python3 tool.py <<<\"data\"" \
        "python3 -u tool.py <<'E'${nlc}data${nlc}E" \
        "py -3 tool.py <<'E'${nlc}data${nlc}E" \
        "\"C:/Program Files/Python313/python.exe\" tool.py <<'E'${nlc}data${nlc}E" \
        "timeout 60 python3 tool.py <<'E'${nlc}data${nlc}E" \
        "python tool.py 2>/dev/null <<'E'${nlc}data${nlc}E" \
        "python -c \"print(1)\"" \
        "python -c \"print(1)\" <<'E'${nlc}data${nlc}E" \
        "python3 -c \"print(1)\" <<<'data'" \
        "python -m mod" \
        "python -m mod <<'E'${nlc}data${nlc}E" \
        "python3 -m json.tool <<<'{}'" \
        "python3 --version" \
        "python3 --version 2>/dev/null || echo \"no python\"" \
        "python3 tool.py" \
        "echo hi | python3 -c \"import sys\"" \
        "cat <<'E' | python tool.py${nlc}data${nlc}E" \
        "cat <<'E' | python3 -c \"import sys; print(sys.stdin.read())\"${nlc}data${nlc}E" \
        "pytest -q <<E${nlc}E" \
        "git commit -q -F - <<'E'${nlc}fix: the guard blocks python3 - <<'X' with a body${nlc}E" \
        "git commit -q -F - <<E${nlc}docs: python <<E2 can hang${nlc}E" \
        "git commit -q -m \"docs: python3 - <<'E' can hang\"" \
        "git commit -q -m \"\$(cat <<'EOF'${nlc}fix: python3 - <<'X' can hang${nlc}EOF${nlc})\"" \
        "git tag -a v1 -F - <<'E'${nlc}python3 - <<'X'${nlc}print(1)${nlc}X${nlc}E" \
        "gh pr create --body-file - <<'E'${nlc}python3 - <<'X'${nlc}print(1)${nlc}X${nlc}E" \
        "gh pr edit 5 --body-file - <<'E'${nlc}It blocks python <<<\"x\" and cat <<'X' | python -.${nlc}E" \
        "echo \"python3 - <<'E'\"" \
        "echo 'python3 - <<\"E\"'" \
        "grep -n \"python3 - <<\" notes.md" \
        "grep -rn 'python - <<' ." \
        "cat > notes.md <<'E'${nlc}python3 - <<'X'${nlc}print(1)${nlc}X${nlc}E" \
        "cat > notes.md <<'E'${nlc}run python <<<\"x\" or cat <<'X' | python -${nlc}E" \
        "tee notes.md <<E${nlc}python3 - <<X${nlc}X${nlc}E"; do
      guard 0 "$cmd"
    done
    for cmd in \
        "@'${nlc}data${nlc}'@ | python tool.py" \
        "@'${nlc}data${nlc}'@ | python -c \"import sys; print(sys.stdin.read())\"" \
        "@'${nlc}data${nlc}'@ | python -m json.tool" \
        "@'${nlc}data${nlc}'@ | Set-Content x.txt" \
        "@'${nlc}python3 - <<'E'${nlc}'@ | Set-Content notes.md" \
        "Get-Content x.py | python -" \
        "python3 --version" \
        "git commit -m \"python - <<E\"" \
        "git commit -q -F - <<'E'${nlc}python3 - <<'X'${nlc}E"; do
      guard 0 "$cmd" PowerShell
    done
  fi
  guard_run
  guard_report "$git_fail" "the guard hook passes Python that reads its script from a heredoc or a here-string, or blocks a script file given a heredoc of data, python -c or -m, or a message that names the form (T309, B64)" "the guard hook blocks Python reading its script from a heredoc or a here-string, whatever the body, behind a path, a wrapper or a time limit, piped in or inside a script a shell runs, and passes a script file given a heredoc of data, python -c and -m, and a message that names the form (T309, B64)"

  # Python with nothing to run (Director-Driven-Development B66): python3 -, python or py -3 with no script, no -c, no -m and nothing
  # fed to it waits for input that never comes, so it is blocked bare, with options, behind a path, a quote or a wrapper, in a chain,
  # with a time limit above it or a redirect after it, in the Bash and the PowerShell tool, and the refusal names it. A file fed to it
  # (python3 - < x.py), a pipe into it, a script file, -c, -m, --version and the like, and text that names Python (command -v python3,
  # pip install python, a quoted message) pass.
  git_fail=""
  bare_msg='python with no script'
  if [ -f .claude/hooks/guard-commands.sh ]; then
    for cmd in \
      'python3 -' \
      'python' \
      'py -3' \
      'python3 2>/dev/null || true' \
      'python3 - 2>/dev/null; sed -n 1p x' \
      'python -' \
      'python3' \
      'pythonw' \
      'python3.13 -' \
      'python.exe' \
      'py' \
      'py -3.13' \
      'PYTHON3' \
      'Python.EXE -' \
      '/usr/bin/python3 -' \
      'C:/Python313/python.exe -' \
      'C:\Python313\python.exe' \
      '"C:/Program Files/Python313/python.exe" -' \
      $'\'/usr/bin/python3\' -' \
      'python3 -u' \
      'python3 -u -' \
      'python3 -X utf8' \
      'python3 -Xutf8 -' \
      'python -W ignore -' \
      'python3 -B -E' \
      'cd x && python3 -' \
      'cd x; python3 -' \
      'false || python3 -' \
      'python3 - && echo ok' \
      'python3 - | tee log' \
      'python3 2>&1 | head' \
      'python3 - &' \
      'python3 >out.txt' \
      'python3 > out.txt 2>&1' \
      'python3 &> out.txt' \
      'timeout 60 python3 -' \
      'timeout -k 5 60 python3 -' \
      'timeout 2m python' \
      'env python3 -' \
      '/usr/bin/env python3 -' \
      'env X=1 python3 -' \
      'X=1 python3 -' \
      'PYTHONPATH="a b" python3 -' \
      'sudo python3 -' \
      'nohup python3 -' \
      'nice -n 5 python3 -' \
      'time python3 -' \
      'exec python3 -' \
      'command python3 -' \
      'winpty python' \
      'uv run python' \
      'poetry run python3 -' \
      'if python3 -; then echo x; fi' \
      'x=$(python3 -)' \
      '(python3 -)' \
      '{ python3 -; }' \
      '! python3 -' \
      'echo "a"; python3 -; echo "b"' \
      $'echo \'a\'; python3 -; echo \'b\'' \
      $'cd x\npython3 -\necho done' \
      'python3 -c "print(1)"; python3 -' \
      'cat x | head; python3 -' \
      'bash -c "python3 -"' \
      'eval "python3 -"' \
      $'python3 \\\n  -' \
      $'python3 \\\n  -u \\\n  -' \
      $'timeout 60 \\\n  python3 -' \
      $'# note \\\npython3 -' \
      $'cat <<E | head\nx\nE\npython3' \
      $'bash <<\'X\'\npython3 -\nX'; do
      guard 2 "$cmd" Bash "$bare_msg"
    done
    for cmd in \
      'python -' \
      'python' \
      'python | Out-Null' \
      'python 2>$null' \
      'python *> $null' \
      '& python -' \
      '& python.exe' \
      'py -3' \
      'Set-Location x; python -' \
      $'python `\n  -' \
      $'echo \'a\'; python -; echo \'b\''; do
      guard 2 "$cmd" PowerShell "$bare_msg"
    done
    for cmd in \
      'python3 - < x.py' \
      'python3 < x.py' \
      'python3 -u - < x.py' \
      'python3 - </dev/null' \
      'cat x.py | python3 -' \
      'cat x.py | python3' \
      'cat x | timeout 60 python3 -' \
      'git show HEAD:x.py | python3 -' \
      'cat x |& python3 -' \
      'python3 --version' \
      'python --version 2>&1' \
      'python3 -V' \
      'python3 -VV' \
      'python3 -h' \
      'python3 --help' \
      'python3 --help-env' \
      'python -?' \
      'py --list' \
      'py --list-paths' \
      'py -0' \
      'py -0p' \
      'py -V:3.13 x.py' \
      'python3 -c "print(1)"' \
      'python3 -c print' \
      'python -m pytest' \
      'python3 -mpytest' \
      'python3 -um pip list' \
      'python3 -Bc "x"' \
      'python3 x.py' \
      'python3 tool.py --flag' \
      'python -I script.py' \
      'python3 -u x.py' \
      'python3 -X utf8 x.py' \
      'python3 -Xdev x.py' \
      'python -W ignore x.py' \
      'py -3 x.py' \
      'py -3 -c "x"' \
      'py install 3.13' \
      'python3 "$f"' \
      'python3 $f' \
      'python3 "x y.py"' \
      'python3 $(ls x.py)' \
      'if python3 --version; then echo x; fi' \
      'command -v python' \
      'command -V python3' \
      'command -v python3 >/dev/null || echo no' \
      'which python3' \
      'where python' \
      'where.exe python' \
      'type python' \
      'type -p python3' \
      'hash python' \
      'pip install python' \
      'winget install python' \
      'brew install python' \
      'apt install python3' \
      'choco install python' \
      'echo python' \
      'echo python3 -' \
      'printf "%s" python' \
      'grep -rn python .' \
      'rg python' \
      'ls python' \
      'cd python' \
      'mkdir py' \
      'cat py' \
      'git add python' \
      'git log --grep python' \
      'case "$x" in python) echo y ;; esac' \
      'PY=python3' \
      'PY="python3"' \
      'PY=python3; $PY x.py' \
      'export PY=python3' \
      'export PY="python3"' \
      'x=$(command -v python3)' \
      '[ -x python ]' \
      'test -f python' \
      'git commit -m "python3 -"' \
      $'git commit -m \'run python\'' \
      'echo "a; python3 -; b"' \
      'gh pr view 1 --json body -q .body' \
      'find . -name "*.py" -exec python3 {} \;' \
      'ls *.py | xargs python3' \
      'xargs python3' \
      'python3 <(cat x.py)' \
      'sed -n "/python/p" x' \
      'node -e "python"' \
      $'git commit -m "a\npython\nb"' \
      $'echo \'x\npython3 -\ny\'' \
      $'cat > x.sh <<\'E\'\npython3 -\nE' \
      $'git commit -F - <<\'E\'\npython\nE' \
      $'python3 \\\n  tool.py' \
      $'python3 \\\n  tool.py --flag \\\n  --other' \
      $'python3 \\\n  -c "print(1)"' \
      $'python3 -u \\\n  x.py' \
      $'timeout 60 \\\n  python3 tool.py' \
      $'python3 \\\n  - < x.py' \
      $'cat x.py | \\\n  python3 -' \
      $'cat x.py |\n  python3 -' \
      $'# note \\\npython3 tool.py' \
      $'python3 tool.py <<\'PY\'\ndata\nPY' \
      $'python3 tool.py <<PY\ndata\nPY' \
      $'node x.js <<-PY\n\tdata\n\tPY' \
      $'ruby x.rb <<"python"\ndata\npython' \
      $'gh pr create --title t --body-file - <<\'E\'\npython3 -\nE'; do
      guard 0 "$cmd"
    done
    for cmd in \
      'Get-Content x.py -Raw | python -' \
      'Get-Command python' \
      '(Get-Command python).Source' \
      'gcm python' \
      'Write-Output python' \
      'Write-Host python' \
      'python --version' \
      $'python -c \'print(1)\'' \
      'python x.py' \
      'Start-Process python' \
      $'python `\n  x.py' \
      $'python `\n  -c \'print(1)\'' \
      $'Get-Content x.py -Raw |\n  python -' \
      'if (Get-Command python -ErrorAction SilentlyContinue) { python --version }'; do
      guard 0 "$cmd" PowerShell
    done
  fi
  guard_run
  guard_report "$git_fail" "the guard hook passes a Python with no script, no -c, no -m and nothing fed to it, or blocks one that has a script, a file or a pipe fed to it, or text that names Python (B66)" "the guard hook blocks a Python with nothing to run, bare, behind a path, a quote or a wrapper, in a chain, in the Bash and the PowerShell tool, and passes one that has a script, a file or a pipe fed to it, and text that names Python (B66)"

  # The guard reads a long file body in time: the hook's timeout in settings.json is 10 seconds, and a hook that times out doesn't
  # block, so a command padded with a long body could pass unguarded. 900 lines of GDScript ($Node.method("x") calls, about 29 KB),
  # written from a Bash heredoc and from a PowerShell here-string, each under 5 seconds. Bash's time keyword reads the clock, so the
  # measurement starts no process of its own, and the best of three runs counts, since a busy machine can slow a run but not all three.
  slow_fail=""; slow_times=""
  if [ -f .claude/hooks/guard-commands.sh ]; then
    slow_body=""; for ((si = 0; si < 900; si++)); do slow_body+=$'$AnimationPlayer.play("walk_1")\n'; done
    for slow_tool in Bash PowerShell; do
      if [ "$slow_tool" = Bash ]; then slow_cmd=$'cat > x.gd <<\'EOF\'\n'"$slow_body"$'EOF'
      else slow_cmd=$'@\'\n'"$slow_body"$'\'@ | Set-Content x.gd'; fi
      json_str "$slow_cmd"
      printf '{"session_id":"s","tool_name":"%s","tool_input":{"command":"%s","description":"run"}}' "$slow_tool" "$JSON_STR" > "$guard_dir/slow.json"
      slow_best=999; slow_rc=0
      for slow_try in 1 2 3; do
        TIMEFORMAT='%R'
        { time bash .claude/hooks/guard-commands.sh < "$guard_dir/slow.json" >/dev/null 2>&1; slow_rc=$?; } 2> "$guard_dir/slow.time"
        slow_s=$(<"$guard_dir/slow.time")
        [ "${slow_s%%[.,]*}" -lt "${slow_best%%[.,]*}" ] 2>/dev/null && slow_best="$slow_s"
        [ "${slow_s%%[.,]*}" -lt 5 ] 2>/dev/null && break
      done
      slow_times="$slow_times ($slow_tool ${slow_best}s)"
      [ "$slow_rc" = 0 ] || slow_fail="$slow_fail"$'\n'"  ($slow_tool) the guard exited $slow_rc on a 29 KB file body, expected 0"
      [ "${slow_best%%[.,]*}" -lt 5 ] 2>/dev/null || slow_fail="$slow_fail"$'\n'"  ($slow_tool) the guard took ${slow_best}s on a 29 KB file body, over 5 seconds"
    done
    rm -f "$guard_dir/slow.json" "$guard_dir/slow.time" "$guard_dir/env.json"
  fi
  guard_report "$slow_fail" "the guard is too slow on a long file body" "the guard reads a 29 KB GDScript heredoc and here-string, each in under 5 seconds:$slow_times"

  # The same, for a body that names the programs the shell and git rules look for (Director-Driven-Development T294): 300 lines of
  # "see C:\Git\bin\bash.exe -c and git.exe -c here" (about 14 KB), in a Bash heredoc and a PowerShell here-string. Every line gives
  # the wrapper gate and the git option rules something to read, so this body costs more than the GDScript one, and its cost grows
  # faster than its length (900 lines take about 6 seconds in the heredoc and 2 in the here-string; 300 take about 1 and 0.4). The
  # body is short because this part runs beside the others, where a 900-line body took 14 seconds. Each must take under 5 seconds, the
  # best of three runs counting. A here-string's body is no command, so the rules leave it out and it must cost about what the
  # heredoc costs: the here-string must also take no more than 1.5 times the heredoc's time plus half a second (it took 13 seconds
  # against 6 at 900 lines when the rules read it). The two are measured one after the other, so a busy machine slows both.
  slow_fail=""; slow_times=""; slow_bt_Bash=999
  if [ -f .claude/hooks/guard-commands.sh ]; then
    slow_body=""; for ((si = 0; si < 300; si++)); do slow_body+=$'see C:\\Git\\bin\\bash.exe -c and git.exe -c here\n'; done
    for slow_tool in Bash PowerShell; do
      if [ "$slow_tool" = Bash ]; then slow_cmd=$'cat > x.gd <<\'EOF\'\n'"$slow_body"$'EOF'
      else slow_cmd=$'@\'\n'"$slow_body"$'\'@ | Set-Content x.gd'; fi
      json_str "$slow_cmd"
      printf '{"session_id":"s","tool_name":"%s","tool_input":{"command":"%s","description":"run"}}' "$slow_tool" "$JSON_STR" > "$guard_dir/slow.json"
      slow_best=999; slow_rc=0
      for slow_try in 1 2 3; do
        TIMEFORMAT='%R'
        { time bash .claude/hooks/guard-commands.sh < "$guard_dir/slow.json" >/dev/null 2>&1; slow_rc=$?; } 2> "$guard_dir/slow.time"
        slow_s=$(<"$guard_dir/slow.time")
        [ "${slow_s%%[.,]*}" -lt "${slow_best%%[.,]*}" ] 2>/dev/null && slow_best="$slow_s"
      done
      slow_times="$slow_times ($slow_tool ${slow_best}s)"
      [ "$slow_tool" = Bash ] && slow_bt_Bash="$slow_best"
      [ "$slow_rc" = 0 ] || slow_fail="$slow_fail"$'\n'"  ($slow_tool) the guard exited $slow_rc on a 14 KB body that names bash.exe and git.exe, expected 0"
      [ "${slow_best%%[.,]*}" -lt 5 ] 2>/dev/null || slow_fail="$slow_fail"$'\n'"  ($slow_tool) the guard took ${slow_best}s on a 14 KB body that names bash.exe and git.exe, over 5 seconds"
      if [ "$slow_tool" = PowerShell ] && ! awk -v p="$slow_best" -v b="$slow_bt_Bash" 'BEGIN { exit !(p <= 1.5 * b + 0.5) }'; then
        slow_fail="$slow_fail"$'\n'"  (PowerShell) the here-string took ${slow_best}s against ${slow_bt_Bash}s for the heredoc: its body is read as commands"
      fi
    done
    rm -f "$guard_dir/slow.json" "$guard_dir/slow.time"
  fi
  guard_report "$slow_fail" "the guard is too slow on a long body that names bash.exe and git.exe -c, reads a here-string's body as commands, or exits non-zero on one" "the guard reads a 14 KB heredoc and here-string that name bash.exe and git.exe -c, each in under 5 seconds, the here-string in about the heredoc's time:$slow_times"

  # A command name written as a path (Director-Driven-Development T292): a quoted name with a space in its path, or an unquoted backslash
  # path that starts with a drive, ., .., ~ or two backslashes, is read as its last part (git.exe is git) in the Bash and the PowerShell
  # tool, after a prefix, a separator or a call operator. A path that is an argument, a message or a body nothing runs is text, and an
  # escaped name (c\at) is still the shell's name.
  git_fail=""
  for cmd in \
      '"C:\Program Files\Git\bin\git.exe" push --force' \
      "& 'C:\\Program Files\\Git\\bin\\git.exe' push --force" \
      'C:\Git\bin\git.exe push --force' \
      '"C:\Program Files\Git\cmd\git.exe" push --force' \
      'FOO=1 "C:\Program Files\Git\bin\git.exe" push --force' \
      'env "C:\Program Files\Git\bin\git.exe" push --force' \
      'cd x && "C:\Program Files\Git\bin\git.exe" push --force' \
      'true; C:\Git\bin\git.exe push --force' \
      'echo $("C:\Program Files\Git\bin\git.exe" push --force)' \
      '"/usr/bin/git" push --force' \
      '..\bin\git.exe push --force' \
      '~\bin\git.exe push --force' \
      '\\server\share\git.exe push --force' \
      '"C:\Program Files\Git\bin\git.exe" reset --hard' \
      '"C:\Program Files\Git\bin\git.exe" commit -m x --no-verify'; do
    guard 2 "$cmd"
    guard 2 "$cmd" PowerShell
  done
  guard 2 "bash <<'EOF'${nlc}\"C:\\Program Files\\Git\\bin\\git.exe\" push --force${nlc}EOF"
  for cmd in \
      "& 'C:\\Program Files\\Git\\bin\\git.exe' status" \
      '"C:\Program Files\Git\bin\git.exe" log -1' \
      '"C:\Program Files\Git\bin\git.exe" push origin main' \
      'git commit -q -m "docs: C:\Program Files\Git\bin\git.exe push --force is blocked"' \
      'echo "C:\Program Files\Git"' \
      'echo "C:\Program Files\Git\bin\git.exe push --force"' \
      'git log "C:\Program Files\Git\bin\git.exe"' \
      'git log --format="C:\Git\bin\git.exe push --force"' \
      'cp "C:\x y\git.exe" backup' \
      'c\at README.md'; do
    guard 0 "$cmd"
    guard 0 "$cmd" PowerShell
  done
  guard 0 "cat > notes.md <<'EOF'${nlc}\"C:\\Program Files\\Git\\bin\\git.exe\" push --force${nlc}EOF${nlc}git add notes.md"
  guard 0 "git commit -q -F - <<'EOF'${nlc}docs: \"C:\\Program Files\\Git\\bin\\git.exe\" push --force is blocked${nlc}EOF"
  guard_run
  guard_report "$git_fail" "the guard hook doesn't read a command name written as a path, quoted with a space or as a backslash path, so git passes behind it, or it blocks a path that is an argument, a message or a body nothing runs (Director-Driven-Development T292)" "the guard hook blocks git behind a quoted path with a space, a backslash path, a prefix, a separator, a call operator and a substitution, in the Bash and the PowerShell tool, and a heredoc body a shell runs, and passes the paths that are arguments and messages and an escaped name (T292)"

  # The same paths in front of git's -c and program flags and in front of a shell (Director-Driven-Development T294): the name is its last
  # part without .exe in any case, quoted with a space, as a backslash path, with forward slashes, behind a prefix, so the rules that read
  # git's options and the shell wrapper's script judge them as they do the bare names.
  git_fail=""
  for cmd in \
      '"C:\Program Files\Git\bin\git.exe" -c core.pager=calc log' \
      'C:\Git\bin\git.exe -c core.pager=calc log' \
      '"C:/Program Files/Git/bin/git.exe" -c core.pager=calc log' \
      '"C:\Program Files\Git\bin\GIT.EXE" -c core.sshCommand=calc fetch' \
      'env "C:\Program Files\Git\bin\git.exe" -c core.pager=calc log' \
      '..\bin\git.exe -c core.pager=calc log' \
      '\\server\share\git.exe -c core.pager=calc log' \
      '"C:\Program Files\Git\bin\git.exe" fetch --upload-pack=calc origin' \
      '"C:\Program Files\Git\bin\git.exe" ls-remote --upload-pack calc origin' \
      'C:\Git\bin\git.exe push --receive-pack=calc origin' \
      '"C:\Program Files\Git\bin\git.exe" clone -u calc u' \
      '"C:\Program Files\Git\bin\bash.exe" -c "git push --force"' \
      'C:\Git\bin\bash.exe -c "git push --force"' \
      '"C:\Program Files\Git\bin\sh.exe" -c "git reset --hard"' \
      'C:\Git\usr\bin\sh.exe -c "git push --force"' \
      '/c/Git/bin/BASH.EXE -c "git push --force"' \
      '"C:/Program Files/Git/bin/bash.exe" -c "git push --force"' \
      'C:/Git/bin/bash.exe -c "git push --force"' \
      '"C:\Program Files\Git\bin\BASH.EXE" -c "git push --force"' \
      '"C:\Program Files\Git\bin\zsh.exe" -c "git push --force"' \
      'env "C:\Program Files\Git\bin\bash.exe" -c "git push --force"' \
      'timeout 5 C:\Git\bin\bash.exe -c "git push --force"' \
      'x && C:\Git\bin\bash.exe -lc "git push --force"' \
      '..\bin\bash.exe -c "git push --force"' \
      '\\server\share\bash.exe -c "git push --force"' \
      '~\bin\sh.exe -c "git push --force"'; do
    guard 2 "$cmd"
    guard 2 "$cmd" PowerShell
  done
  for cmd in \
      '"C:\Program Files\Git\bin\git.exe" -c user.name=x log' \
      '"C:\Program Files\Git\bin\git.exe" log -1' \
      '"C:\Program Files\tool\app.exe" -c x' \
      'C:\tools\app.exe -c "git push --force"' \
      'echo "C:\Program Files\Git\bin\bash.exe -c foo"' \
      'echo "C:\Program Files\Git\bin\git.exe -c core.pager=calc log"' \
      'cp "C:\Program Files\Git\bin\bash.exe" backup' \
      'ls C:\Git\bin\bash.exe' \
      'C:\Windows\System32\notepad.exe C:\Git\bin\bash.exe -c foo' \
      'git log "C:\Program Files\Git\bin\bash.exe" -c' \
      'git commit -q -m "docs: C:\Program Files\Git\bin\git.exe -c core.pager=calc log is blocked"' \
      '"C:\Program Files\Git\bin\bash.exe" -c "echo hi"' \
      'C:\Git\bin\bash.exe tools/check.sh'; do
    guard 0 "$cmd"
    guard 0 "$cmd" PowerShell
  done
  guard_run
  guard_report "$git_fail" "the guard hook doesn't read a path in front of git's -c and program flags or in front of a shell, so they pass behind it, or it blocks a path that is an argument or a message (Director-Driven-Development T294)" "the guard hook blocks git's -c and program flags and a shell's script behind a quoted path with a space, a backslash path, forward slashes, .exe in any case and a prefix, in the Bash and the PowerShell tool, and passes the paths that are arguments, messages and other programs (T294)"

  # The PowerShell tool (B24) has its own name. The guard runs for it only when the hook's matcher names it,
  # and a Bash(...) deny or ask rule stops the same command in PowerShell only through its PowerShell(...)
  # twin, in the same list. The allow list names no PowerShell command, so nothing PowerShell runs is allowed
  # without a prompt. Read(...) rules are the Read tool's; PowerShell's own file reads are not covered here.
  ps_fail=""
  guard_matcher=$(awk -F'"' '/"matcher"/ { m = $4 } /guard-commands\.sh/ { print m; exit }' .claude/settings.json)
  for tool in Bash Monitor PowerShell; do
    case "|$guard_matcher|" in
      *"|$tool|"*) ;;
      *) ps_fail="$ps_fail"$'\n'"  the guard hook's matcher \"$guard_matcher\" doesn't name $tool" ;;
    esac
  done
  for list in deny ask; do
    arr=$(sed -n "/\"$list\": *\[/,/\]/p" .claude/settings.json)
    while IFS= read -r rule; do
      [ -n "$rule" ] || continue
      twin="PowerShell(${rule#Bash(}"
      case "$arr" in
        *"\"$twin\""*) ;;
        *) ps_fail="$ps_fail"$'\n'"  settings.json's $list rules have $rule but no $twin" ;;
      esac
    done <<< "$(printf '%s\n' "$arr" | grep -oE '"Bash\([^"]*\)"' | tr -d '"')"
  done
  printf '%s\n' "$perm_allow" | grep -q 'PowerShell(' \
    && ps_fail="$ps_fail"$'\n'"  settings.json's allow list names a PowerShell command, so PowerShell would run it without a prompt"
  guard_report "$ps_fail" "the PowerShell tool isn't wired to the guard and the deny rules (B24)" "the guard hook's matcher names PowerShell, every Bash deny rule has a PowerShell twin, and the allow list names no PowerShell command"
fi

}

part_security() {
# --- security assessment --------------------------------------------------------------------------
echo "security assessment"
# The tool step (tools/security.sh) on the seeded fixture and its clean twin (tests/security/README.md).
# Each copy gets the manifests under their real names, the check and the seed .gitleaks.toml. The
# credential is assembled here at run time, so neither this file nor the fixture holds one.
sec_copy() { # sec_copy <vulnerable|clean> -> $work/security/<name>
  local dir="$work/security/$1"
  rm -rf "$dir"; mkdir -p "$work/security"; cp -R "$src/tests/security/$1" "$dir"
  mv "$dir/package.fixture.json" "$dir/package.json"; mv "$dir/package-lock.fixture.json" "$dir/package-lock.json"
  mkdir -p "$dir/tools"; cp "$src/framework/tools/check.sh" "$src/framework/tools/security.sh" "$dir/tools/"
  cp "$src/project/.gitleaks.toml" "$dir/.gitleaks.toml"
  printf '[project]\nstack = none\n[gitleaks]\nmin-version = 8.18.0\n' > "$dir/tools/check.cfg"
  (cd "$dir" && git init -q && git config core.autocrlf false && git add -A && git_q commit -qm "fixture")
}
sec_copy vulnerable; sec_copy clean
_sv="$work/security/vulnerable"; _sc="$work/security/clean"
_tk1="ghp_R8xK2mQ9vL4tW7nB3pZ6"; _tk2="cY1hJ5dF0sG8aE2u"
sed "s/__SEEDED_SECRET__/${_tk1}${_tk2}/" "$_sv/src/payments.js" > "$work/payments.js" && cp "$work/payments.js" "$_sv/src/payments.js"
grep -q "${_tk1}${_tk2}" "$_sv/src/payments.js" && ok "the seeded copy holds a generated credential" || bad "the seeded copy holds a generated credential"

# Stand-ins: an npm whose audit reports lodash (or can't reach the registry), and a semgrep with one finding.
_sec_bin="$work/security-bin"; mkdir -p "$_sec_bin/vuln" "$_sec_bin/offline" "$_sec_bin/semgrep"
cat > "$_sec_bin/vuln/npm" << 'FAKE'
#!/bin/bash
[ "$1" = "audit" ] || exit 0
printf '# npm audit report\n\nlodash  <=4.17.20\nSeverity: high\nPrototype Pollution in lodash\nnode_modules/lodash\n\n3 vulnerabilities (1 moderate, 2 high)\n'
exit 1
FAKE
cat > "$_sec_bin/offline/npm" << 'FAKE'
#!/bin/bash
printf 'npm error code ENOTFOUND\nnpm error audit endpoint returned an error\n'
exit 1
FAKE
cat > "$_sec_bin/semgrep/semgrep" << 'FAKE'
#!/bin/bash
printf 'src/server.js:20:24:error(javascript.lang.security.audit.sqli.node-sqli):Untrusted input in a SQL string MATCHED_SOURCE_TEXT\n'
exit 1
FAKE
chmod +x "$_sec_bin"/*/*
out="$(cd "$_sc" && PATH="$_sec_bin/vuln:$_sec_bin/semgrep:$_stop_path" bash tools/security.sh 2>&1)"; status=$?
expect_status "the tool step exits 1 when a tool reports findings" 1 "$status" "$out"
expect_output "a dependency audit's findings are labelled A03, with npm 7's summary" "^security: dependencies \(npm audit --omit=dev\): FINDINGS \(OWASP A03:2025 Software Supply Chain Failures\): 3 vulnerabilities \(1 moderate, 2 high\)" "$out"
expect_output "and name the package" "  package: lodash <=4.17.20" "$out"
expect_output "Semgrep's findings keep file, line, column and rule" "^  src/server\.js:20:24:javascript\.lang\.security\.audit\.sqli\.node-sqli$" "$out"
expect_output "Semgrep's findings are reported as findings" "^security: semgrep \(p/owasp-top-ten\): FINDINGS" "$out"
expect_no_output "Semgrep's message and matched source aren't printed" "MATCHED_SOURCE_TEXT|Untrusted input" "$out"
expect_no_output "or stored" "MATCHED_SOURCE_TEXT|Untrusted input" "$(cat "$_sc/.app-director/state/security/semgrep.txt" 2>/dev/null)"
expect_output "the summary says a tool passing never marks a category met" "A tool passing never marks an OWASP category met" "$out"
_no_sg_path=""
_oldifs="$IFS"; IFS=':'
for _d in $_stop_path; do [ -x "$_d/semgrep" ] || _no_sg_path="${_no_sg_path:+$_no_sg_path:}$_d"; done
IFS="$_oldifs"
out="$(cd "$_sc" && PATH="$_sec_bin/offline:$_no_sg_path" bash tools/security.sh 2>&1)"; status=$?
expect_status "an audit that can't reach the registry isn't a finding" 0 "$status" "$out"
expect_output "it is noted with its reason" "^security: dependencies \(npm audit --omit=dev\): couldn't run: npm error code ENOTFOUND" "$out"
expect_output "a tool that isn't installed is skipped with a note" "^security: semgrep \(p/owasp-top-ten\): skipped: semgrep isn't installed" "$out"
# A non-zero exit is never clean, even with the nothing-found line: a failed run is couldn't run.
mkdir -p "$_sec_bin/failed"; cat > "$_sec_bin/failed/npm" << 'FAKE'
#!/bin/bash
printf 'npm error network request failed\nfound 0 vulnerabilities\n'
exit 1
FAKE
chmod +x "$_sec_bin/failed/npm"
out="$(cd "$_sc" && PATH="$_sec_bin/failed:$_no_sg_path" bash tools/security.sh 2>&1)"; status=$?
expect_output "a failed audit with the nothing-found line is couldn't run, with its reason" "^security: dependencies \(npm audit --omit=dev\): couldn't run: npm error network request failed" "$out"
expect_no_output "and isn't reported clean" "dependencies \(npm audit --omit=dev\): clean" "$out"

# pip-audit only reads requirements that are all pinned with ==; otherwise it would install them.
_sp="$work/security/python"; mkdir -p "$_sp/tools"; cp "$src/framework/tools/security.sh" "$_sp/tools/"
printf 'requests==2.32.3\nflask>=3.0\n' > "$_sp/requirements.txt"
out="$(cd "$_sp" && PATH="$_no_sg_path" bash tools/security.sh 2>&1)"
expect_output "pip-audit is skipped, with the reason, for a requirement that isn't pinned" "^security: dependencies \(pip-audit\): skipped: requirements\.txt has a requirement that isn't pinned with == \(flask>=3\.0\)" "$out"
rm -f "$_sp/requirements.txt"; printf '[project]\nname = "x"\n' > "$_sp/pyproject.toml"
out="$(cd "$_sp" && PATH="$_no_sg_path" bash tools/security.sh 2>&1)"
expect_output "and for a pyproject.toml without pinned requirements" "^security: dependencies \(pip-audit\): skipped: only pyproject\.toml" "$out"

# The real tools: gitleaks when it can scan, npm when it's installed and the registry answers. Semgrep
# is left out (the stand-in covers it): its rules could flag the clean twin's plain HTTP server.
out_v="$(cd "$_sv" && PATH="$_no_sg_path" bash tools/security.sh 2>&1)"; status_v=$?
out_c="$(cd "$_sc" && PATH="$_no_sg_path" bash tools/security.sh 2>&1)"; status_c=$?
if [ "$_gl_ok" -eq 1 ]; then
  expect_output "gitleaks finds the seeded credential under its OWASP item" "secrets FAIL \(OWASP Authentication Failures" "$out_v"
  expect_output "and names its file" "  found in: src/payments\.js" "$out_v"
  expect_no_output "the clean twin has no credential finding" "secrets FAIL|found in:" "$out_c"
  expect_status "the seeded copy fails the tool step" 1 "$status_v" "$out_v"
else
  echo "  skip  the seeded credential (gitleaks not found, below $_gl_min_req, or 8.19.0)"
fi
if ! command -v npm >/dev/null 2>&1; then
  echo "  skip  npm audit on the fixture (npm isn't installed)"
elif printf '%s' "$out_v" | grep -q "^security: dependencies (npm audit --omit=dev): couldn't run"; then
  echo "  skip  npm audit on the fixture (the registry didn't answer)"
else
  expect_output "npm audit finds the vulnerable lodash, labelled A03" "^security: dependencies \(npm audit --omit=dev\): FINDINGS \(OWASP A03:2025" "$out_v"
  expect_output "and names lodash" "  package: lodash " "$out_v"
  expect_output "the clean twin's audit is clean" "^security: dependencies \(npm audit --omit=dev\): clean" "$out_c"
fi
expect_status "the clean twin passes the tool step" 0 "$status_c" "$out_c"
expect_no_output "the clean twin has no finding" "FINDINGS" "$out_c"

# --due: always due with no report yet; then it counts built items (subjects ending in (T<n>) or
# (B<n>), also with a squash merge's " (#<pr>)") since the newest report's commit.
(cd "$_sv" && for i in 1 2 3; do git_q commit -q --allow-empty -m "feat: item (T$i)"; done && git_q commit -q --allow-empty -m "docs: note (R1)")
out="$(cd "$_sv" && bash tools/security.sh --due 2>&1)"
expect_output "--due: due when there is no report yet" "^security: due: no assessment yet \(no report in product/security/\), \[security\] every = 10" "$out"
printf '[security]\nevery = 3\n' >> "$_sv/tools/check.cfg"
mkdir -p "$_sv/product/security"
printf '# Security assessment 2026-01-01\n\n- Commit: `%s`\n' "$(cd "$_sv" && git rev-parse --short HEAD~2)" > "$_sv/product/security/2026-01-01.md"
out="$(cd "$_sv" && bash tools/security.sh --due 2>&1)"
expect_output "--due counts from the newest report's commit, research items left out" "^security: not due: built items since product/security/2026-01-01\.md \(commit [0-9a-f]+\): 1, \[security\] every = 3" "$out"
(cd "$_sv" && git_q commit -q --allow-empty -m "feat: squashed item (T4) (#12)" && git_q commit -q --allow-empty -m "fix: squashed bug (B2) (#13)")
out="$(cd "$_sv" && bash tools/security.sh --due 2>&1)"
expect_output "--due counts squash-merge subjects and is due at [security] every = 3" "^security: due: built items since product/security/2026-01-01\.md \(commit [0-9a-f]+\): 3, \[security\] every = 3" "$out"
(cd "$_sv" && git_q commit -q --allow-empty -m "fix: B5 is mentioned (B5) but not at the end")
out="$(cd "$_sv" && bash tools/security.sh --due 2>&1)"
expect_output "--due ignores an item ID that doesn't end the subject" ": 3, \[security\] every = 3" "$out"

}

part_stories() {
# --- user stories ---------------------------------------------------------------------------------
echo "user stories"
# tools/stories.sh --due counts built items as tools/security.sh --due does, from the commit on the
# stories file's Last validated line (by its date when that commit isn't in the history), and is due
# when the stories were never validated. The seed stands in for an app's file.
_st="$work/stories"; new_repo "$_st"; mkdir -p "$_st/tools" "$_st/product"
cp "$src/framework/tools/stories.sh" "$_st/tools/"
out="$(cd "$_st" && bash tools/stories.sh --due 2>&1)"; status=$?
expect_status "stories --due exits 0 without a stories file" 0 "$status" "$out"
expect_output "stories --due: not due without a stories file" "^stories: not due: no stories yet \(no product/user-stories\.md\), \[stories\] every = 10$" "$out"
printf '# User stories: x\n\n**Next ID:** US-1 · **Last validated:** never\n\n## Roles\n' > "$_st/product/user-stories.md"
out="$(cd "$_st" && bash tools/stories.sh --due 2>&1)"
expect_output "stories --due: not due while the file has no stories" "^stories: not due: no stories yet in product/user-stories\.md" "$out"
cp "$stories_seed" "$_st/product/user-stories.md"
_st_total="$(grep -c '^| US-' "$stories_seed")"; _st_unc="$(grep -c '| unconfirmed |$' "$stories_seed")"
out="$(cd "$_st" && bash tools/stories.sh --due 2>&1)"
expect_output "stories --due: due when never validated, counting the stories and the unconfirmed ones" \
  "^stories: due: never validated \(Last validated: never\), $_st_total stories, $_st_unc unconfirmed, \[stories\] every = 10$" "$out"
(cd "$_st" && for i in 1 2 3; do git_q commit -q --allow-empty -m "feat: item (T$i)"; done && git_q commit -q --allow-empty -m "docs: note (R1)")
printf '[stories]\nevery = 3\n' > "$_st/tools/check.cfg"
_st_validated() { # <the Last validated value>
  sed "s/\*\*Last validated:\*\* never/**Last validated:** $1/" "$stories_seed" > "$_st/product/user-stories.md"
}
_st_validated "2026-01-01 at \`$(cd "$_st" && git rev-parse --short HEAD~2)\`"
out="$(cd "$_st" && bash tools/stories.sh --due 2>&1)"
expect_output "stories --due counts from the Last validated commit, research items left out" \
  "^stories: not due: built items since the last validation \(2026-01-01, commit [0-9a-f]+\): 1, \[stories\] every = 3; $_st_total stories, $_st_unc unconfirmed$" "$out"
(cd "$_st" && git_q commit -q --allow-empty -m "feat: squashed item (T4) (#12)" && git_q commit -q --allow-empty -m "fix: squashed bug (B2) (#13)")
out="$(cd "$_st" && bash tools/stories.sh --due 2>&1)"
expect_output "stories --due counts squash-merge subjects and is due at [stories] every = 3" "^stories: due: built items since the last validation \(2026-01-01, commit [0-9a-f]+\): 3, \[stories\] every = 3" "$out"
(cd "$_st" && git_q commit -q --allow-empty -m "fix: B5 is mentioned (B5) but not at the end")
out="$(cd "$_st" && bash tools/stories.sh --due 2>&1)"
expect_output "stories --due ignores an item ID that doesn't end the subject" ": 3, \[stories\] every = 3" "$out"
_st_validated "2000-01-01 at \`0000000\`"
out="$(cd "$_st" && bash tools/stories.sh --due 2>&1)"
expect_output "stories --due counts by the date when the commit isn't in this history" \
  "^stories: due: built items since the last validation \(2000-01-01, by its date: its commit isn't in this history\): 5, \[stories\] every = 3" "$out"
_st_validated "2000-01-01"
out="$(cd "$_st" && bash tools/stories.sh --due 2>&1)"
expect_output "stories --due counts by the date when the line names no commit" \
  "^stories: due: built items since the last validation \(2000-01-01, by its date: the line names no commit\): 5, \[stories\] every = 3" "$out"
grep -v '^\*\*Next ID:\*\*' "$stories_seed" > "$_st/product/user-stories.md"
out="$(cd "$_st" && bash tools/stories.sh --due 2>&1)"
expect_output "stories --due is due, and says why, when the file has no Last validated line" \
  "^stories: due: never validated \(product/user-stories\.md has no Last validated line\), $_st_total stories" "$out"
printf '[stories]\nevery = often\n' > "$_st/tools/check.cfg"
out="$(cd "$_st" && bash tools/stories.sh --due 2>&1)"
expect_output "stories --due notes a setting that isn't a whole number and uses 10" "^stories: note: \[stories\] every = often isn't a whole number of 1 or more; using 10" "$out"
out="$(cd "$_st" && bash tools/stories.sh 2>&1)"; status=$?
expect_status "stories.sh without --due exits 3" 3 "$status" "$out"
# Outside a git repository (git isn't allowed to look above $work for one) it can't count, and says so.
_st_nogit="$work/stories-nogit"; mkdir -p "$_st_nogit/tools" "$_st_nogit/product"
cp "$src/framework/tools/stories.sh" "$_st_nogit/tools/"; cp "$stories_seed" "$_st_nogit/product/"
out="$(cd "$_st_nogit" && GIT_CEILING_DIRECTORIES="$work" bash tools/stories.sh --due 2>&1)"; status=$?
expect_status "stories --due exits 3 outside a git repository" 3 "$status" "$out"
expect_output "and says it couldn't count" "^stories: couldn't count: not a git repository$" "$out"
}

part_hooks() {
  app="$work/hooks-app"; cd "$app" || exit 3
# --- guard-protected hook -------------------------------------------------------------------------
echo "guard-protected hook"
# Claude Code sends the path as given: relative, absolute POSIX, or Windows (JSON-escaped). The
# project root is $CLAUDE_PROJECT_DIR (the Windows cases pass a made-up root; the hook only reads text).
guard_write() { # guard_write <expected exit> <what> <file_path as sent (JSON-escaped)> [project dir]
  local out got verdict=allows
  out="$(printf '{"session_id":"s","tool_name":"Write","tool_input":{"file_path":"%s","content":"x"}}' "$3" \
    | CLAUDE_PROJECT_DIR="${4:-$app}" bash .claude/hooks/guard-protected.sh 2>&1)"
  got=$?
  [ "$1" -eq 2 ] && verdict=blocks
  if [ "$got" -eq "$1" ]; then ok "$verdict: $2"; else bad "guard-protected exit $got, expected $1: $2" "$out"; fi
}
guard_write 2 "relative director/mockup.png" 'director/mockup.png'
guard_write 2 "relative director/notes.md" 'director/notes.md'
guard_write 2 "relative director" 'director'
guard_write 2 "./director/x" './director/x'
guard_write 2 "x/../director/y" 'x/../director/y'
guard_write 2 "absolute POSIX <root>/director/x" "$app/director/x"
guard_write 2 "Windows C:\\...\\director\\x (escaped backslashes)" 'C:\\git\\Proj\\director\\x' 'C:\git\Proj'
guard_write 2 "Windows C:/.../director/x" 'C:/git/Proj/director/x' 'C:\git\Proj'
guard_write 2 "Git Bash /c/.../director/x" '/c/git/Proj/director/x' 'C:\git\Proj'
guard_write 2 "Windows path, project root given in Git Bash form" 'C:\\git\\Proj\\director\\x' '/c/git/Proj'
guard_write 2 "relative director/ui/home.excalidraw" 'director/ui/home.excalidraw'
guard_write 0 "relative src/ui/TodoList.ts" 'src/ui/TodoList.ts'
guard_write 0 "relative AGENTS.md" 'AGENTS.md'
guard_write 0 "relative TASKS.md" 'TASKS.md'
guard_write 0 "relative docs/director-notes.md" 'docs/director-notes.md'
guard_write 0 "absolute <root>/docs/director-notes.md" "$app/docs/director-notes.md"
guard_write 0 "relative src/director/x.ts (nested folder)" 'src/director/x.ts'
guard_write 0 "absolute <root>/src/director/x.ts (nested folder)" "$app/src/director/x.ts"
guard_write 0 "outside the project root" '/nonexistent/elsewhere/director/x'
guard_write 0 "Windows path outside the project root" 'D:\\other\\director\\x' 'C:\git\Proj'
guard_write 0 "Windows sibling folder with the root's name as a prefix" 'C:\\git\\Proj-old\\director\\x' 'C:\git\Proj'
guard_write 0 "../director/x (outside the project root)" '../director/x'
out="$(printf '%s' '{"tool_name":"Edit","tool_input":{"file_path":"director/x"}}' | env -u CLAUDE_PROJECT_DIR bash .claude/hooks/guard-protected.sh 2>&1)"
got=$?
if [ "$got" -eq 2 ]; then ok "blocks a relative path against the current directory when CLAUDE_PROJECT_DIR is unset"; else bad "guard-protected without CLAUDE_PROJECT_DIR exit $got, expected 2" "$out"; fi

# In a prototype (PROTOTYPE.md at the root) Edit and Write refuse the gates, which are main's: the hooks and the guard
# (.githooks/, .claude/), tools/prototype.sh, tools/setup-clone.sh and the gitleaks files (T271). Its notes and the
# ordinary files stay writable, and outside a prototype the gates are writable, as they are in the main session.
proto_root="$work/guard-proto"; mkdir -p "$proto_root" && printf '# Prototype: guard\n' > "$proto_root/PROTOTYPE.md"
for f in .githooks/pre-commit .githooks/pre-push .claude/hooks/guard-commands.sh .claude/settings.json \
    tools/prototype.sh tools/setup-clone.sh .gitleaksignore .gitleaks.toml ./tools/prototype.sh \
    tools/stacks/../prototype.sh ".githooks/../.gitleaks.toml" "$proto_root/.githooks/pre-commit" \
    "$proto_root/.gitleaks.toml"; do
  guard_write 2 "a prototype refuses its gate $f" "$f" "$proto_root"
done
for f in src/ui/TodoList.ts tools/check.sh tools/stacks/typescript.sh TASKS.md PROTOTYPE.md .githooks-old/x \
    tools/prototype.sh.bak .gitleaks.toml.bak "$proto_root/src/ui/TodoList.ts"; do
  guard_write 0 "a prototype allows an ordinary file $f" "$f" "$proto_root"
done
if [ -e "$app/PROTOTYPE.md" ]; then
  bad "the example app has a PROTOTYPE.md, so the outside-a-prototype cases don't test it"
else
  for f in .githooks/pre-commit .claude/settings.json tools/prototype.sh .gitleaks.toml; do
    guard_write 0 "outside a prototype the gate $f stays writable" "$f"
  done
fi

# --- stop-check hook ------------------------------------------------------------------------------
echo "stop-check hook"
# PATH is already set to $_stop_path (includes gitleaks, real or fake) from the check section.

git add -A && { git_q commit -qm "clean state for hook tests" >/dev/null 2>&1 || true; }

stop_hook() {
  printf '{}' | CLAUDE_PROJECT_DIR="$app" PATH="$_stop_path" bash .claude/hooks/stop-check.sh 2>&1
}
out="$(stop_hook)"; expect_status "does nothing when code is unchanged" 0 $? "$out"

{ printf '\n'; printf '// a harmless change\n'; } >> src/services/TodoService.ts
out="$(stop_hook)"; expect_status "lets a passing change through" 0 $? "$out"

# Plant a UI purity violation as the failing state so the stop-check tests work with or without
# gitleaks. (Secret detection in check.sh is exercised above in the check section.)
cp src/ui/TodoList.ts "$work/stop-passing"
{ printf '\n'; printf 'import { TodoStore } from '"'"'../store/TodoStore'"'"';\n'; } >> src/ui/TodoList.ts
cp src/ui/TodoList.ts "$work/stop-failing"
out="$(stop_hook)"; status=$?
expect_status "blocks a failing change" 2 "$status" "$out"
expect_output "gives Claude the check output" "check.sh fails" "$out"
out="$(stop_hook)"; expect_status "reports the same failing state only once" 0 $? "$out"

out="$(bash tools/check.sh --fast --if-changed 2>&1)"; status=$?
expect_status "--fast --if-changed repeats the Stop hook's failure without rerunning" 1 "$status" "$out"
expect_output "says the failing state is unchanged" "nothing changed" "$out"

rm -f .app-director/state/last-reported
: > .app-director/state/building
out="$(stop_hook)"; expect_status "leaves a builder's half-built files alone" 0 $? "$out"
rm -f .app-director/state/building

out="$(stop_hook)"; expect_status "blocks again once the builder is done" 2 $? "$out"
cp "$work/stop-passing" src/ui/TodoList.ts
out="$(stop_hook)"; expect_status "lets the fixed state through" 0 $? "$out"

# The Stop hook runs the fast tier only, as stop-hook. While another check holds the lock it waits no longer than the fast
# tier's limit (CHECK_TIMEOUT=1 here), then ends the turn quietly and records nothing as reported. A check that couldn't
# run for another reason (a stand-in gitleaks below the minimum) blocks once, and asks for the work to be reported as
# unverified.
_hl=""; IFS= read -r -d '' _hl < .app-director/state/check-runs.log
expect_output "the Stop hook runs the fast tier, as stop-hook" " tier=fast result=pass secs=[0-9]+ caller=stop-hook " "$_hl"
expect_no_output "and never the full tier" " tier=full .* caller=stop-hook " "$_hl"
printf '// one more harmless change\n' >> src/services/TodoService.ts
printf 'pid=%s started=%s at=12:41 caller=pre-commit tier=full\n' "$$" "${EPOCHSECONDS:-$(date +%s)}" > .app-director/state/check.lock
rm -f .app-director/state/last-reported
out="$(CHECK_TIMEOUT=1 stop_hook)"; status=$?
expect_status "while another check holds the lock past the fast tier's limit, the Stop hook ends the turn" 0 "$status" "$out"
[ -z "$out" ] && ok "quietly" || bad "quietly" "$out"
[ ! -e .app-director/state/last-reported ] && ok "and records nothing as reported" || bad "and records nothing as reported"
rm -f .app-director/state/check.lock
_old_gl="$work/fake-gl-old"; mkdir -p "$_old_gl"
printf '#!/bin/bash\n[ "$1" = version ] && echo v8.0.0\nexit 0\n' > "$_old_gl/gitleaks"; chmod +x "$_old_gl/gitleaks"
out="$(printf '{}' | CLAUDE_PROJECT_DIR="$app" PATH="$_old_gl:$_stop_path" bash .claude/hooks/stop-check.sh 2>&1)"; status=$?
expect_status "a check that couldn't run for another reason blocks the turn once" 2 "$status" "$out"
expect_output "and says it couldn't verify this work" "^App Director: the project check couldn't verify this work:$" "$out"
expect_output "quoting the reason" "^check: secrets FAIL: gitleaks 8\.0\.0 is below minimum 8\.18\.0\.$" "$out"
expect_output "and asks for the work to be reported as unverified, not failed" "^Report this work as unverified, not failed" "$out"
expect_no_output "without telling Claude to stop, or that the work isn't done" "Don't call the work done|[Ss]top" "$out"
}

part_session() {
# --- Stop hook, per session -----------------------------------------------------------------------
# Two sessions can share one working folder (a design session and a build session, no worktree). The Stop hook runs the
# check only for a session that wrote or edited a source file itself: session-touched.sh keeps that record by the
# session_id in the hook input (a file tool's PostToolUse; for Bash and PowerShell the git status before and after the
# command). So a design session that edits only Markdown never waits for, or is blocked by, another session's
# uncommitted code. A throwaway repository holds it, with a stand-in check that records that it ran and fails while
# .app-director/state/fail exists, and scripted hook inputs.
echo "stop hook, per session"
sr="$work/session-stop"; new_repo "$sr"
sr_hooks="$src/framework/.claude/hooks"
mkdir -p "$sr/tools" "$sr/src"
cat > "$sr/tools/check.sh" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in --fingerprint) cat src/*.cs 2>/dev/null | git hash-object --stdin; exit 0 ;; esac
: > .app-director/state/check-ran
if [ -f .app-director/state/fail ]; then echo "layering: src/Billing.cs imports the UI"; exit 1; fi
exit 0
EOF
printf '/.app-director/state/\n' > "$sr/.gitignore"
git -C "$sr" add -A >/dev/null 2>&1; git_q -C "$sr" commit -qm "a stand-in check" >/dev/null 2>&1
sr_state="$sr/.app-director/state"
sr_nl=$'\n'
sr_put() { [ -d "${1%/*}" ] || mkdir -p "${1%/*}"; printf '%s\n' "$2" > "$1"; }   # sr_put <file> <content>
_sr_wrote() { # _sr_wrote <session> <tool> <path> [path key] [event]: a file tool's PostToolUse input, through the recorder
  printf '{"session_id":"%s","cwd":"%s","hook_event_name":"%s","tool_name":"%s","tool_input":{"%s":"%s","content":"x"},"tool_response":{"success":true}}' \
    "$1" "$sr" "${5:-PostToolUse}" "$2" "${4:-file_path}" "$3" | CLAUDE_PROJECT_DIR="$sr" bash "$sr_hooks/session-touched.sh" after 2>&1
}
_sr_cmd() { # _sr_cmd <session> before|after <tool> [event]: a Bash or PowerShell command's PreToolUse or PostToolUse input
  printf '{"session_id":"%s","cwd":"%s","hook_event_name":"%s","tool_name":"%s","tool_input":{"command":"make"}}' \
    "$1" "$sr" "${4:-PostToolUse}" "$3" | CLAUDE_PROJECT_DIR="$sr" bash "$sr_hooks/session-touched.sh" "$2" 2>&1
}
_sr_stop() { # _sr_stop <hook input>: the Stop hook's output; the exit status is the hook's
  printf '%s' "$1" | CLAUDE_PROJECT_DIR="$sr" bash "$sr_hooks/stop-check.sh" 2>&1
}
_sr_stop_as() { _sr_stop "{\"session_id\":\"$1\",\"transcript_path\":\"/x/y.jsonl\",\"hook_event_name\":\"Stop\",\"stop_hook_active\":false}"; }
_sr_rec() { cat "$sr_state/sessions/$1.touched" 2>/dev/null; }
_sr_ran() { [ -e "$sr_state/check-ran" ]; }

# 1. A design session that edits only Markdown, while a build session has uncommitted source in the same folder.
sr_put "$sr/src/Billing.cs" 'class Billing {}'
_sr_wrote build Write "$sr/src/Billing.cs" >/dev/null
_sr_wrote design Write "$sr/docs/notes.md" >/dev/null
_sr_wrote design Edit "$sr/TASKS.md" >/dev/null
_sr_wrote design MultiEdit "$sr/product/brief.md" >/dev/null
out="$(_sr_rec build)"; expect_output "records the source file a session wrote, from the project root" '^src/Billing\.cs$' "$out"
if [ ! -e "$sr_state/sessions/design.touched" ]; then ok "records nothing for a session that edited only Markdown"; else bad "records nothing for a session that edited only Markdown" "$(_sr_rec design)"; fi
: > "$sr_state/fail"   # a check that would fail, as the other session's unfinished code makes it
out="$(_sr_stop_as design)"; status=$?
expect_status "the Stop hook exits 0 for a design session while another session has uncommitted source in the folder" 0 "$status" "$out"
if _sr_ran; then bad "the check doesn't run for the session that edited only Markdown"; else ok "the check doesn't run for the session that edited only Markdown"; fi
_sr_wrote kinds Write "$sr/adr/ADR-9-x.md" >/dev/null
_sr_wrote kinds NotebookEdit "$sr/analysis/model.ipynb" notebook_path >/dev/null
_sr_wrote kinds Write "$sr/.app-director/state/building" >/dev/null
_sr_wrote kinds Write "/elsewhere/Outside.cs" >/dev/null
_sr_wrote kinds Write "$sr/README.md" >/dev/null
out="$(_sr_rec kinds)"
[ "$out" = "analysis/model.ipynb" ] && ok "records a notebook as source, and skips Markdown (an ADR too), the state folder and a file outside the project" \
  || bad "records a notebook as source, and skips Markdown (an ADR too), the state folder and a file outside the project" "$out"
if command -v cygpath >/dev/null 2>&1; then
  # Claude Code on Windows sends the path with JSON-escaped backslashes (two for each separator), and the project folder as C:\...
  sr_bs2='\\'
  sr_winroot="$(cygpath -w "$sr")"
  sr_winjson="$(printf '%s' "$sr_winroot" | sed 's/\\/\\\\/g')"
  printf '{"session_id":"winpath","cwd":"%s","hook_event_name":"PostToolUse","tool_name":"Write","tool_input":{"file_path":"%s","content":"x"}}' \
    "$sr_winjson" "$sr_winjson$sr_bs2"src"$sr_bs2"Win.cs | CLAUDE_PROJECT_DIR="$sr_winroot" bash "$sr_hooks/session-touched.sh" after >/dev/null 2>&1
  out="$(_sr_rec winpath)"
  [ "$out" = "src/Win.cs" ] && ok "reads a Windows path with JSON-escaped backslashes against a project folder written as C:\\..." \
    || bad "reads a Windows path with JSON-escaped backslashes against a project folder written as C:\\..." "$out"
fi

# 2. The build session that wrote source gets the check, is blocked once for a failure, and not twice for the same one.
: > "$sr_state/fail"
out="$(_sr_stop_as build)"; status=$?
expect_status "the session that wrote source gets the check, and is blocked when it fails" 2 "$status" "$out"
expect_output "and is given the check's output" 'layering' "$out"
if _sr_ran; then ok "the check ran for it"; else bad "the check ran for it"; fi
rm -f "$sr_state/check-ran"
out="$(_sr_stop_as build)"; status=$?
expect_status "the same failure isn't reported twice" 0 "$status" "$out"
if _sr_ran; then bad "and the check isn't run again for it"; else ok "and the check isn't run again for it"; fi

# 3. A Bash or PowerShell command is read from git's list of changed files before and after it.
_sr_cmd shell before Bash >/dev/null
sleep 1
sr_put "$sr/src/Made.cs" 'class Made {}'
sr_put "$sr/notes.md" '# notes'
_sr_cmd shell after Bash >/dev/null
out="$(_sr_rec shell)"
[ "$out" = "src/Made.cs" ] && ok "a Bash command that creates a source file is recorded, and a Markdown file and a file already changed before it are not" \
  || bad "a Bash command that creates a source file is recorded, and a Markdown file and a file already changed before it are not" "$out"
_sr_cmd shell2 before PowerShell PreToolUse >/dev/null
sleep 1
printf '// edited by a command\n' >> "$sr/src/Billing.cs"
_sr_cmd shell2 after PowerShell PostToolUseFailure >/dev/null
out="$(_sr_rec shell2)"
[ "$out" = "src/Billing.cs" ] && ok "a PowerShell command that modifies a file changed before it is recorded, one that fails too" \
  || bad "a PowerShell command that modifies a file changed before it is recorded, one that fails too" "$out"
_sr_cmd shell3 before Bash >/dev/null; _sr_cmd shell3 after Bash >/dev/null
if [ ! -e "$sr_state/sessions/shell3.touched" ]; then ok "a command that changes nothing records nothing"; else bad "a command that changes nothing records nothing" "$(_sr_rec shell3)"; fi
_sr_cmd shell4 after Bash >/dev/null
if [ ! -e "$sr_state/sessions/shell4.touched" ]; then ok "a command with no snapshot before it records nothing"; else bad "a command with no snapshot before it records nothing" "$(_sr_rec shell4)"; fi

# 4. A passing check removes the session's record, and not another session's.
rm -f "$sr_state/fail" "$sr_state/check-ran"
_sr_cmd build before Bash >/dev/null
printf '// the fix\n' >> "$sr/src/Billing.cs"
out="$(_sr_stop_as build)"; status=$?
expect_status "a session whose code passes the check ends its turn" 0 "$status" "$out"
if _sr_ran; then ok "the check ran for it"; else bad "the check ran for it"; fi
if [ ! -e "$sr_state/sessions/build.touched" ] && [ ! -e "$sr_state/sessions/build.before" ]; then ok "a passing check removes the session's record"; else bad "a passing check removes the session's record" "$(ls "$sr_state/sessions")"; fi
if [ -s "$sr_state/sessions/shell.touched" ]; then ok "and leaves another session's"; else bad "and leaves another session's"; fi

# 5. A record older than a day is ignored, and deleted with any other session's that old.
: > "$sr_state/fail"; rm -f "$sr_state/check-ran" "$sr_state/last-reported"
_sr_wrote old Write "$sr/src/Billing.cs" >/dev/null
_sr_wrote stale Write "$sr/src/Billing.cs" >/dev/null
touch -t 202001010000 "$sr_state/sessions/old.touched" "$sr_state/sessions/stale.touched"
out="$(_sr_stop_as old)"; status=$?
expect_status "a record older than a day is ignored" 0 "$status" "$out"
if _sr_ran; then bad "and the check doesn't run for it"; else ok "and the check doesn't run for it"; fi
if [ ! -e "$sr_state/sessions/old.touched" ] && [ ! -e "$sr_state/sessions/stale.touched" ]; then ok "and it is deleted, as is another session's that old"; else bad "and it is deleted, as is another session's that old" "$(ls "$sr_state/sessions")"; fi

# 6. No session_id, or one that can't be a file name, behaves as before: uncommitted source runs the check once.
out="$(_sr_stop '{"hook_event_name":"Stop"}')"; status=$?
expect_status "with no session_id the hook decides from git alone: uncommitted source runs the check, and a failure blocks" 2 "$status" "$out"
if _sr_ran; then ok "and the check ran"; else bad "and the check ran"; fi
out="$(_sr_stop '{"hook_event_name":"Stop"}')"; expect_status "and the same failure isn't reported twice" 0 $? "$out"
printf '// another change\n' >> "$sr/src/Billing.cs"; rm -f "$sr_state/check-ran"
out="$(_sr_stop_as '../../escape')"; status=$?
expect_status "a session_id that isn't a plain name behaves the same" 2 "$status" "$out"
printf '// and another\n' >> "$sr/src/Billing.cs"
out="$(_sr_stop '{"session_id":"","hook_event_name":"Stop"}')"; expect_status "so does an empty one" 2 $? "$out"

# 7. What stays as it was: the builder marker, APP_DIRECTOR_STOP_CHECK=0 and a project with no tools/check.sh.
printf '// once more\n' >> "$sr/src/Billing.cs"; rm -f "$sr_state/check-ran"
_sr_wrote marked Write "$sr/src/Billing.cs" >/dev/null
: > "$sr_state/building"
out="$(_sr_stop_as marked)"; status=$?
expect_status "a session with a record leaves a builder's half-built files alone" 0 "$status" "$out"
rm -f "$sr_state/building"
out="$(APP_DIRECTOR_STOP_CHECK=0 _sr_stop_as marked)"; expect_status "APP_DIRECTOR_STOP_CHECK=0 turns the Stop hook off for it" 0 $? "$out"
APP_DIRECTOR_STOP_CHECK=0 _sr_wrote off Write "$sr/src/Billing.cs" >/dev/null
if [ ! -e "$sr_state/sessions/off.touched" ]; then ok "and the record with it"; else bad "and the record with it"; fi
mv "$sr/tools/check.sh" "$sr/tools/check.sh.away"
out="$(_sr_stop_as marked)"; expect_status "a project with no tools/check.sh ends the turn" 0 $? "$out"
mv "$sr/tools/check.sh.away" "$sr/tools/check.sh"
if _sr_ran; then bad "the check isn't run while the builder marker, the switch or a missing script excuses it"; else ok "the check isn't run while the builder marker, the switch or a missing script excuses it"; fi
out="$(_sr_stop_as marked)"; expect_status "and the record still blocks once those are gone" 2 $? "$out"

# 8. Work that is committed ends the record: the check passed in the commit, and what differs later is another's.
rm -f "$sr_state/fail" "$sr_state/check-ran"
git -C "$sr" add -A >/dev/null 2>&1; git_q -C "$sr" commit -qm "the build session's work" >/dev/null 2>&1
out="$(_sr_stop_as marked)"; status=$?
expect_status "a session whose source is all committed ends its turn" 0 "$status" "$out"
if [ ! -e "$sr_state/sessions/marked.touched" ] && ! _sr_ran; then ok "and its record is removed without running the check"; else bad "and its record is removed without running the check" "$(ls "$sr_state/sessions")"; fi
sr_put "$sr/docs/more.md" '# more'
out="$(_sr_stop '{"hook_event_name":"Stop"}')"; expect_status "with no session_id, a Markdown-only change ends the turn, as before" 0 $? "$out"

# The hooks are wired in settings.json: the snapshot before a command, the record after a file tool or a command
# (a failing one too), and the hook runs under macOS's bash 3.2 and BSD tools, so it holds none of the forms they lack.
wiring="$(awk '/^    "[A-Za-z]+": \[/ { ev = $1; gsub(/[":]/, "", ev) } /"matcher"/ { split($0, a, "\""); m = a[4] }
  /session-touched\.sh/ { print ev ";" m ";" ($0 ~ / before"/ ? "before" : "after") }' "$src/framework/.claude/settings.json")"
[ "$wiring" = "PreToolUse;Bash|PowerShell;before${sr_nl}PostToolUse;Edit|Write|MultiEdit|NotebookEdit;after${sr_nl}PostToolUse;Bash|PowerShell;after${sr_nl}PostToolUseFailure;Bash|PowerShell;after" ] \
  && ok "settings.json runs the record hook before Bash and PowerShell, after them (a failing one too) and after Edit, Write, MultiEdit and NotebookEdit" \
  || bad "settings.json runs the record hook before Bash and PowerShell, after them (a failing one too) and after Edit, Write, MultiEdit and NotebookEdit" "$wiring"
bash4=$(grep -nE '^[^#]*(\$\{[A-Za-z_0-9]+(\[[^]]*\])?(,,|\^\^)\}|(declare|local|typeset) +-[a-zA-Z]*A|(^|[;&| ])(mapfile|readarray) +|(^|[;&| ])coproc +[A-Za-z]|[[:space:]]\|&[[:space:]]|\$\{[A-Za-z_0-9@*]+(\[[^]]*\])?: -[0-9]|stat +-c|date +-d|sed +-i|readlink +-f|-printf|-delete)' \
  "$sr_hooks/session-touched.sh" "$sr_hooks/stop-check.sh" || true)
if [ -z "$bash4" ]; then ok "the Stop hook and the record hook use no bash 4 form and no GNU-only tool flag"
else bad "the Stop hook and the record hook use no bash 4 form and no GNU-only tool flag" "$bash4"; fi
}

part_commit() {
  app="$work/commit-app"; cd "$app" || exit 3
# --- pre-commit hook ------------------------------------------------------------------------------
echo "pre-commit hook"
# PATH already includes gitleaks (real or fake) from the check section export above.
# setup-clone refuses gitleaks 8.19.0 (exit 3) and still installs the hooks, which fail closed: a commit is
# blocked until gitleaks can scan. With 8.19.0 on the machine's PATH the check expects that, run on the real
# PATH (the 8.18.0 stand-in would hide the 8.19.0). The hook is then installed again with the stand-in for
# the tests below. Otherwise the check expects the hook.
_hook="$(git rev-parse --git-path hooks)/pre-commit"
if [ "$_gl_path_ver" = "8.19.0" ]; then
  out="$(PATH="$_real_path" bash tools/setup-clone.sh 2>&1)"
  expect_status "setup-clone refuses the gitleaks 8.19.0 on PATH" 3 $? "$out"
  expect_output "setup-clone says 8.19.0 can't scan and asks for 8.19.1" "8.19.0 can't scan.*8.19.1" "$out"
  grep -qs "App Director" "$_hook" && ok "setup-clone still installs the pre-commit hook for the gitleaks 8.19.0 on PATH (it fails closed)" \
    || bad "setup-clone still installs the pre-commit hook for the gitleaks 8.19.0 on PATH (it fails closed)"
  bash tools/setup-clone.sh >/dev/null 2>&1
else
  bash tools/setup-clone.sh >/dev/null 2>&1
  grep -qs "App Director" "$_hook" \
    && ok "setup-clone installs the pre-commit hook" \
    || bad "setup-clone installs the pre-commit hook"
  grep -qs '\.githooks/pre-push' "${_hook%pre-commit}pre-push" \
    && ok "setup-clone installs the pre-push hook" \
    || bad "setup-clone installs the pre-push hook"
fi

# Stand-in gitleaks 8.19.0 (every command fails, as the real one does) in a fresh repository: setup-clone
# refuses it and installs no hook, whatever gitleaks the machine has.
_refuse_gl="$work/fake-gl-refuse"
mkdir -p "$_refuse_gl"
cat > "$_refuse_gl/gitleaks" << 'FAKE'
#!/bin/bash
case "$1" in
  version) echo "v8.19.0" ;;
  *) echo "FTL flag accessed but not defined: source" >&2; exit 1 ;;
esac
FAKE
chmod +x "$_refuse_gl/gitleaks"
_refuse="$work/refuse-clone"; new_repo "$_refuse" && mkdir -p "$_refuse/tools" \
  && cp "$src/framework/tools/setup-clone.sh" "$_refuse/tools/"
out="$(PATH="$_refuse_gl:$PATH" bash "$_refuse/tools/setup-clone.sh" 2>&1)"
expect_status "setup-clone refuses a stand-in gitleaks 8.19.0" 3 $? "$out"
expect_output "stand-in 8.19.0: setup-clone says it can't scan and asks for 8.19.1" "8.19.0 can't scan.*8.19.1" "$out"
grep -qs "App Director" "$_refuse/.git/hooks/pre-commit" && grep -qs "App Director" "$_refuse/.git/hooks/pre-push" \
  && ok "stand-in 8.19.0: setup-clone still installs the pre-commit and pre-push hooks, which fail closed" \
  || bad "stand-in 8.19.0: setup-clone still installs the pre-commit and pre-push hooks, which fail closed"
if PATH="$_no_gl_path" command -v git >/dev/null 2>&1 && PATH="$_no_gl_path" command -v bash >/dev/null 2>&1; then
  _nogl_clone="$work/nogl-clone"; new_repo "$_nogl_clone" && mkdir -p "$_nogl_clone/tools" "$_nogl_clone/.githooks" \
    && cp "$src/framework/tools/setup-clone.sh" "$_nogl_clone/tools/" && cp "$src/framework/.githooks/pre-commit" "$_nogl_clone/.githooks/" \
    && printf '#!/usr/bin/env bash\nexit 0\n' > "$_nogl_clone/tools/check.sh"
  out="$(cd "$_nogl_clone" && PATH="$_no_gl_path" bash tools/setup-clone.sh 2>&1)"
  expect_status "setup-clone exits 3 without gitleaks" 3 $? "$out"
  grep -qs "App Director" "$_nogl_clone/.git/hooks/pre-commit" && grep -qs "App Director" "$_nogl_clone/.git/hooks/pre-push" \
    && ok "and still installs the pre-commit and pre-push hooks" || bad "setup-clone without gitleaks installs no hooks" "$out"
  out="$(cd "$_nogl_clone" && printf '# notes\n' > notes.md && git add notes.md && PATH="$_no_gl_path" git_q commit -qm "a note" 2>&1)"
  expect_status "pre-commit blocks any commit, a Markdown one too, when gitleaks is missing" 1 $? "$out"
  expect_output "and says the staged changes can't be scanned" "gitleaks isn't installed, so the staged changes can't be scanned for secrets" "$out"
else
  echo "  skip  setup-clone and pre-commit without gitleaks (git or bash shares a folder with gitleaks on this machine)"
fi

git add -A && { git_q commit -qm "clean state for commit tests" >/dev/null 2>&1 || true; }

# Blocked: UI file imports from data layer.
{ printf '\n'; printf 'import { TodoStore } from '"'"'../store/TodoStore'"'"';\n'; } >> src/ui/TodoList.ts
git add src/ui/TodoList.ts
out="$(git_q commit -qm "purity violation" 2>&1)"
expect_status "pre-commit blocks a failing commit" 1 $? "$out"
git restore --staged src/ui/TodoList.ts && git checkout -- src/ui/TodoList.ts

# Allowed: clean change.
printf '\n// updated\n' >> src/ui/TodoList.ts
git add src/ui/TodoList.ts
out="$(git_q commit -qm "clean change" 2>&1)"
expect_status "pre-commit allows a passing commit" 0 $? "$out"

# Docs-only commit skips the check entirely.
printf '# note\n' > notes.md && git add notes.md
out="$(git_q commit -qm "docs only" 2>&1)"
expect_status "docs-only commit is allowed" 0 $? "$out"
expect_no_output "doesn't run the check for docs-only" "running the project check" "$out"

# A research item changes no code: its note and the records commit without the check.
mkdir -p product/research
printf '# Which date library fits\nR1 · Informs: - · Verified as of 2026-10-15 · Size: M\n' > product/research/2026-10-15-date-library.md
git add product/research/2026-10-15-date-library.md
out="$(git_q commit -qm "docs: research a date library (R1)" 2>&1)"; status=$?
expect_status "allows a commit with only a research note" 0 "$status" "$out"
expect_no_output "doesn't run the check for a research note" "running the project check" "$out"

# Blocked while a .adir-new file is unmerged.
printf 'x\n' > tools/check.sh.adir-new
printf '\n// another change\n' >> src/ui/TodoList.ts && git add src/ui/TodoList.ts
out="$(git_q commit -qm "with adir-new" 2>&1)"
expect_status "refuses while a .adir-new file is unmerged" 1 $? "$out"
rm -f tools/check.sh.adir-new

# A nested clone in an ignored folder is listed by ls-files as a directory. It doesn't block a
# commit, but a real upgrade file still does while the clone is there.
git restore --staged src/ui/TodoList.ts && git checkout -- src/ui/TodoList.ts
printf '/clones/\n' >> .git/info/exclude
mkdir -p clones/nested && (cd clones/nested && git init -q && git_q commit -q --allow-empty -m nested) >/dev/null 2>&1
out="$(git_q commit -q --allow-empty -m "with a nested clone" 2>&1)"
expect_status "a nested clone in an ignored folder doesn't block a commit" 0 $? "$out"
printf 'x\n' > tools/check.sh.adir-new
out="$(git_q commit -q --allow-empty -m "with a nested clone and adir-new" 2>&1)"
expect_status "a real upgrade file still blocks with a nested clone present" 1 $? "$out"
expect_no_output "names the upgrade file, not the nested clone" "clones/" "$out"
rm -f tools/check.sh.adir-new

# --- staged secret --------------------------------------------------------------------------------
# The working copy stays clean and only the index holds the credential, so the check passes and the
# hook's staged scan is the one that has to catch it.
cp src/services/TodoService.ts "$work/saved-svc-staged"
stage_secret() {
  { printf '\n'; printf "%s = '%s';\n" "$_gl_marker_name" "$_cred_val"; } >> src/services/TodoService.ts
  git add src/services/TodoService.ts
  cp "$work/saved-svc-staged" src/services/TodoService.ts
}

# The stand-in gitleaks for the staged scan ($_hook_gl) is built before the parts fork (see the check section).
stage_secret
out="$(export PATH="$_hook_gl:$PATH"; git_q commit -qm "staged secret" 2>&1)"
expect_status "pre-commit blocks a staged secret (stand-in)" 1 $? "$out"
expect_output "pre-commit names the file with a staged secret (stand-in)" "found in: src/services/TodoService.ts" "$out"
expect_no_output "pre-commit doesn't print the staged secret (stand-in)" "$_cred_val" "$out"
git reset -q -- src/services/TodoService.ts

stage_secret
out="$(export PATH="$_hook_gl:$PATH" FAKE_GL_VERSION=8.19.0 FAKE_GL_PROTECT=error; git_q commit -qm "cannot scan" 2>&1)"
expect_status "pre-commit blocks when gitleaks can't scan (stand-in 8.19.0)" 1 $? "$out"
expect_output "pre-commit says gitleaks couldn't scan, not that it found a secret" "couldn't scan" "$out"
expect_no_output "pre-commit names no file when gitleaks can't scan" "found in:" "$out"
git reset -q -- src/services/TodoService.ts

if [ "$_gl_ok" -eq 1 ]; then
  stage_secret
  out="$(git_q commit -qm "real staged secret" 2>&1)"
  expect_status "pre-commit blocks a secret staged for real gitleaks" 1 $? "$out"
  expect_output "pre-commit names the staged file with real gitleaks" "found in: src/services/TodoService.ts" "$out"
  expect_no_output "pre-commit doesn't print the secret with real gitleaks" "$_cred_val" "$out"
  git reset -q -- src/services/TodoService.ts
else
  echo "  skip  real gitleaks staged-secret tests (gitleaks not found or below $_gl_min_req)"
fi
cp "$work/saved-svc-staged" src/services/TodoService.ts

# The staged scan runs on every commit, not only when a source file is staged (B18): a token pasted
# into a Markdown page, a script or a record used to reach history unscanned. A throwaway repository
# holds the committed hook, a stub check and the shim that setup-clone installs, and stages one
# Markdown file. The token ("ghp_" and 36 generated letters and digits) is assembled at run time and
# written only to that repository's working copy, never to a tracked file here.
_md="$work/md-secret"; new_repo "$_md" >/dev/null 2>&1
mkdir -p "$_md/tools" "$_md/.githooks"
cp "$src/framework/.githooks/pre-commit" "$_md/.githooks/pre-commit"
printf '#!/usr/bin/env bash\nexit 0\n' > "$_md/tools/check.sh"
(cd "$_md" && git add -A && git_q commit -qm "hook and stub") >/dev/null 2>&1
printf '#!/usr/bin/env bash\nexec bash "$(git rev-parse --show-toplevel)/.githooks/pre-commit" "$@"\n' > "$_md/.git/hooks/pre-commit"
chmod +x "$_md/.git/hooks/pre-commit"
_md_commits="$(cd "$_md" && git rev-list --count HEAD)"

(cd "$_md" && printf '# Notes\n\nNothing to see here.\n' > notes.md && git add notes.md)
out="$(export PATH="$_hook_gl:$PATH"; cd "$_md" && git_q commit -qm "a note" 2>&1)"
expect_status "pre-commit blocks a staged Markdown file when the scan finds a secret (stand-in)" 1 $? "$out"
expect_output "pre-commit scans a commit with no source file staged" "scanning staged changes for secrets" "$out"
expect_output "pre-commit names the Markdown commit's finding (stand-in)" "found in: " "$out"
expect_no_output "pre-commit doesn't run the project check for a Markdown file" "running the project check" "$out"
(cd "$_md" && git reset -q -- notes.md)

if [ "$_gl_ok" -eq 1 ]; then
  _alnum='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
  _md_token="ghp_"
  for ((_i = 0; _i < 36; _i++)); do _md_token="$_md_token${_alnum:$((RANDOM % 62)):1}"; done
  (cd "$_md" && printf '# Notes\n\nThe token is %s\n' "$_md_token" > notes.md && git add notes.md)
  out="$(cd "$_md" && git_q commit -qm "a note with a token" 2>&1)"
  expect_status "pre-commit blocks a staged Markdown file holding a secret (real gitleaks)" 1 $? "$out"
  expect_output "pre-commit names the Markdown file with real gitleaks" "found in: notes.md" "$out"
  expect_no_output "pre-commit doesn't print the Markdown file's token" "$_md_token" "$out"
  [ "$(cd "$_md" && git rev-list --count HEAD)" = "$_md_commits" ] && ok "the blocked Markdown commit is not made" \
    || bad "the blocked Markdown commit is not made"
  (cd "$_md" && printf '# Notes\n\nNothing to see here.\n' > notes.md && git add notes.md)
  out="$(cd "$_md" && git_q commit -qm "a clean note" 2>&1)"
  expect_status "pre-commit allows a staged Markdown file with no secret (real gitleaks)" 0 $? "$out"
else
  echo "  skip  real gitleaks Markdown staged-secret tests (gitleaks not found or below $_gl_min_req)"
fi

# --- pre-commit and pre-push: the tiers -----------------------------------------------------------
# The pre-commit hook asks `bash tools/check.sh --due` for the tier: full when it's due, fast otherwise, and says which and
# why; the pre-push hook runs the full tier. A stand-in stack counts the suites that start (a line each, with the tier and
# the caller, in suites), so a reused pass adds none, and keeps a line it could read from its stdin (stdin-seen: there
# should be none). The settings bring the full tier every 3 commits and for anything under db/, and leave marketing/ out.
echo "pre-commit and pre-push, the tiers"
_pst=.app-director/state
printf '#!/usr/bin/env bash\nread -r -t 5 _line && echo "$_line" >> "$CHECK_STATE/stdin-seen"\necho "$CHECK_TIER ${CHECK_CALLER:-manual}" >> "$CHECK_STATE/suites"\nexit 0\n' > tools/stacks/counted.sh
printf '[project]\nstack = counted\n\n[ui]\ndirs = src/ui\n\n[data]\ndirs = store\n\n[gitleaks]\nmin-version = 8.18.0\n\n[tests]\nfull-every = 3\nfull-when = db/\nignore = marketing/\n' > tools/check.cfg
pc_suites() { # the suites started: how many in pc_n, the last one's tier and caller in pc_last
  local l
  pc_n=0; pc_last=""
  [ -f "$_pst/suites" ] || return 0
  while IFS= read -r l; do pc_n=$((pc_n + 1)); pc_last="$l"; done < "$_pst/suites"
}
_pc_violation() { { printf '\n'; printf 'import { TodoStore } from '"'"'../store/TodoStore'"'"';\n'; } >> src/ui/TodoList.ts; }

git add tools/check.cfg tools/stacks/counted.sh
out="$(git_q commit -qm "a counted stack" 2>&1)"; status=$?
expect_status "pre-commit: a commit that stages tools/check.cfg passes" 0 "$status" "$out"
expect_output "it runs the full tier, and says why: a path on the framework's list is staged" "^pre-commit: running the project check, full tier: tools/check\.cfg changed$" "$out"
pc_suites
[ "$pc_last" = "full pre-commit" ] && ok "the full suite runs, as pre-commit" || bad "the full suite runs, as pre-commit" "$pc_last"

printf '\n// staged\n' >> src/ui/TodoList.ts && git add src/ui/TodoList.ts && printf '// not staged\n' >> src/ui/TodoList.ts
out="$(git_q commit -qm "a fast commit" 2>&1)"; status=$?
expect_status "a commit when the full tier isn't due passes" 0 "$status" "$out"
expect_output "it runs the fast tier, and says why" \
  "^pre-commit: running the project check, fast tier: the full tier isn't due \(1 commit since the last full pass \([0-9a-f]{7}, [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}\), \[tests\] full-every = 3\)$" "$out"
expect_output "a staged source file with unstaged changes gets a note" \
  "^pre-commit: note: src/ui/TodoList\.ts has unstaged changes too\. The check covers the working tree, not exactly what this commit records\.$" "$out"
pc_suites
[ "$pc_last" = "fast pre-commit" ] && ok "the fast suite runs, as pre-commit" || bad "the fast suite runs, as pre-commit" "$pc_last"
git checkout -- src/ui/TodoList.ts

# The builder's change adds a file: staging it leaves the fingerprint as it was (the list is sorted, tracked or not).
printf '\n// a builder change\n' >> src/ui/TodoList.ts; printf 'export const banner = "hi";\n' > src/ui/Banner.ts
out="$(bash tools/check.sh --fast 2>&1)"; expect_status "a builder's fast pass, with a new untracked file" 0 $? "$out"
pc_suites; _pc_n="$pc_n"
git add src/ui/TodoList.ts src/ui/Banner.ts
out="$(bash tools/check.sh --fast --if-changed 2>&1)"
expect_output "once the new file is staged, --fast --if-changed reuses that pass" "^check: PASS \(reused the fast pass at [0-9:]{5}, commit [0-9a-f]{7}, by manual; nothing changed\)$" "$out"
out="$(git_q commit -qm "a builder's commit" 2>&1)"; status=$?
expect_status "the commit after it passes" 0 "$status" "$out"
expect_output "and reuses the builder's fast pass on the same files" "^check: PASS \(reused the fast pass at [0-9:]{5}, commit [0-9a-f]{7}, by manual; nothing changed\)$" "$out"
out="$(CHECK_CALLER=stop-hook bash tools/check.sh --fast --if-changed 2>&1)"
expect_output "after the commit, --fast --if-changed (the Stop hook's, the next item's) still reuses that pass" \
  "^check: PASS \(reused the fast pass at [0-9:]{5}, commit [0-9a-f]{7}, by manual; nothing changed\)$" "$out"
pc_suites
[ "$pc_n" -eq "$_pc_n" ] && ok "with no second suite" || bad "with no second suite" "$pc_last"

printf '\n// the third commit\n' >> src/ui/TodoList.ts && git add src/ui/TodoList.ts
out="$(git_q commit -qm "the third since the full pass" 2>&1)"; status=$?
expect_status "the third commit since the full pass passes" 0 "$status" "$out"
expect_output "and runs the full tier, saying why: [tests] full-every commits since the last full pass" \
  "^pre-commit: running the project check, full tier: 3 commits since the last full pass \([0-9a-f]{7}, [^)]*\), \[tests\] full-every = 3$" "$out"
pc_suites
[ "$pc_last" = "full pre-commit" ] && ok "the full suite runs" || bad "the full suite runs" "$pc_last"

mkdir -p db && printf '{ "seed": 1 }\n' > db/seed.json && git add db/seed.json
out="$(git_q commit -qm "a seed" 2>&1)"; status=$?
expect_status "a commit that stages a path under [tests] full-when passes" 0 "$status" "$out"
expect_output "and runs the full tier, saying why" "^pre-commit: running the project check, full tier: db/seed\.json changed$" "$out"

# A path that makes the full tier due starts the check though it isn't a source path and nothing else is staged: a
# migration under [tests] full-when, and requirements.txt on the framework's list. The pass before it doesn't stand.
printf 'create table t (id int);\n' > db/001.sql && git add db/001.sql
pc_suites; _pc_n="$pc_n"
out="$(git_q commit -qm "a migration" 2>&1)"; status=$?
expect_status "a commit that stages only a migration under [tests] full-when passes" 0 "$status" "$out"
expect_output "and runs the full tier, saying why" "^pre-commit: running the project check, full tier: db/001\.sql changed$" "$out"
pc_suites
[ "$pc_n" -eq $((_pc_n + 1)) ] && [ "$pc_last" = "full pre-commit" ] && ok "the full suite runs: the pass before it doesn't stand for a new migration" \
  || bad "the full suite runs: the pass before it doesn't stand for a new migration" "$pc_n suites, the last: $pc_last"
printf 'pytest==8.0\n' > requirements.txt && git add requirements.txt
out="$(git_q commit -qm "a dependency" 2>&1)"; status=$?
expect_status "a commit that stages only requirements.txt passes" 0 "$status" "$out"
expect_output "and runs the full tier, saying why" "^pre-commit: running the project check, full tier: requirements\.txt changed$" "$out"
pc_suites
[ "$pc_n" -eq $((_pc_n + 2)) ] && [ "$pc_last" = "full pre-commit" ] && ok "and the full suite runs for it too" \
  || bad "and the full suite runs for it too" "$pc_n suites, the last: $pc_last"
# Before a commit, `bash tools/check.sh --due` says whether the full tier is due; run first, its pass is the one the
# commit's hook reuses, so the full run never sits inside the commit (rules.md, Running the check).
printf 'alter table t add n int;\n' >> db/001.sql && git add db/001.sql
out="$(bash tools/check.sh --due 2>&1)"
expect_output "--due before a commit says the full tier is due, and why" "^check: full tier due: db/001\.sql changed$" "$out"
out="$(bash tools/check.sh --if-changed 2>&1)"; expect_status "the full tier, run before the commit" 0 $? "$out"
pc_suites; _pc_n="$pc_n"
out="$(git_q commit -qm "a migration, checked first" 2>&1)"; status=$?
expect_status "the commit after it passes" 0 "$status" "$out"
expect_output "and its hook reuses that full pass" "^check: PASS \(reused the full pass at [0-9:]{5}, commit [0-9a-f]{7}, by manual; nothing changed\)$" "$out"
pc_suites
[ "$pc_n" -eq "$_pc_n" ] && ok "with no suite inside the commit" || bad "with no suite inside the commit" "$pc_last"

mkdir -p marketing && printf '{ "title": "Buy" }\n' > marketing/page.json && git add marketing/page.json
pc_suites; _pc_n="$pc_n"
out="$(git_q commit -qm "a marketing page" 2>&1)"; status=$?
expect_status "a commit that stages only a path under [tests] ignore passes" 0 "$status" "$out"
expect_no_output "and runs no check: the path doesn't count as source" "running the project check" "$out"
expect_output "the staged secrets scan still runs on it" "^pre-commit: scanning staged changes for secrets$" "$out"
pc_suites
[ "$pc_n" -eq "$_pc_n" ] && ok "and no suite starts" || bad "and no suite starts" "$pc_last"

_pc_old="$work/fake-gl-pc-old"; mkdir -p "$_pc_old"
printf '#!/bin/bash\n[ "$1" = version ] && echo v8.0.0\nexit 0\n' > "$_pc_old/gitleaks"; chmod +x "$_pc_old/gitleaks"
printf '\n// not committed\n' >> src/ui/TodoList.ts && git add src/ui/TodoList.ts
_pc_head="$(git rev-parse HEAD)"
out="$(export PATH="$_pc_old:$PATH"; git_q commit -qm "a check that can't run" 2>&1)"; status=$?
expect_status "pre-commit blocks a commit whose check couldn't run" 1 "$status" "$out"
expect_output "and says nothing was committed and the staged changes are as they were" \
  "^pre-commit: the check couldn't run \(the reason is above\), so nothing was committed; the staged changes are as they were\.$" "$out"
expect_output "and how to go on: the tier's run in the background with a longer limit, whose pass the commit reuses" \
  "^            'CHECK_TIMEOUT=<seconds> bash tools/check\.sh --(fast|full)', and commit again once it passes \(the commit reuses$" "$out"
[ "$(git rev-parse HEAD)" = "$_pc_head" ] && [ "$(git diff --cached --name-only)" = "src/ui/TodoList.ts" ] \
  && ok "nothing is committed, and the change is still staged" || bad "nothing is committed, and the change is still staged" "$(git status --short)"
git reset -q -- src/ui/TodoList.ts && git checkout -- src/ui/TodoList.ts

# pre-push: the full tier, blocking on a failure; a full pass of the same files is reused; a push that only deletes a ref
# runs no check.
_pc_origin="$work/commit-origin.git"
git init -q --bare "$_pc_origin" && git remote add origin "$_pc_origin"
_pc_violation
out="$(git_q push -q origin HEAD:refs/heads/main 2>&1)"; status=$?
[ "$status" -ne 0 ] && [ -z "$(git --git-dir="$_pc_origin" for-each-ref)" ] && ok "pre-push blocks a push while the full check fails" \
  || bad "pre-push blocks a push while the full check fails (exit $status)" "$out"
expect_output "it runs the full tier, and says so" "^pre-push: running the project check, full tier: a push gets the full check$" "$out"
expect_output "and says nothing was pushed, and how to go on" "^pre-push: the full check fails, so nothing was pushed\. Fix what it names" "$out"
pc_suites
[ "$pc_last" = "full pre-push" ] && ok "the full suite runs, as pre-push" || bad "the full suite runs, as pre-push" "$pc_last"
[ ! -e "$_pst/stdin-seen" ] && ok "and reads nothing from git's ref list" || bad "and reads nothing from git's ref list" "$(cat "$_pst/stdin-seen")"
git checkout -- src/ui/TodoList.ts
out="$(bash tools/check.sh 2>&1)"; expect_status "a full pass before the push" 0 $? "$out"
pc_suites; _pc_n="$pc_n"
out="$(git_q push -q origin HEAD:refs/heads/main HEAD:refs/heads/gone 2>&1)"; status=$?
expect_status "pre-push lets the push through once a full pass of these files stands" 0 "$status" "$out"
expect_output "and reuses that pass" "^check: PASS \(reused the full pass at [0-9:]{5}, commit [0-9a-f]{7}, by manual; nothing changed\)$" "$out"
pc_suites
[ "$pc_n" -eq "$_pc_n" ] && ok "with no second suite" || bad "with no second suite" "$pc_last"
_pc_violation
out="$(git_q push -q origin :refs/heads/gone 2>&1)"; status=$?
expect_status "a push that only deletes a ref goes through, though the check would fail" 0 "$status" "$out"
expect_no_output "and runs no check" "running the project check" "$out"
[ "$(git --git-dir="$_pc_origin" for-each-ref --format='%(refname)')" = "refs/heads/main" ] && ok "the remote has main, and not the deleted branch" \
  || bad "the remote has main, and not the deleted branch" "$(git --git-dir="$_pc_origin" for-each-ref)"
git checkout -- src/ui/TodoList.ts
}

# --- prototypes -----------------------------------------------------------------------------------
# tools/prototype.sh on a throwaway repository with an origin: start stops while origin/main is ahead, creates the
# worktree beside the project, the branch from main with no upstream and the committed PROTOTYPE.md, and refuses
# an existing name or an invalid one. Only a prototype (a linked worktree on a proto/ branch with PROTOTYPE.md at
# its root) skips the check: the pre-commit hook still blocks a staged secret there and a commit without gitleaks,
# and runs the check everywhere else, the Stop hook likewise, and the pre-push hook refuses a proto/ branch.
# harvest prints what the harvest reads and changes nothing; remove never forces and keeps the branch. The stub
# check always fails, so a commit of a source file that goes through shows the check was skipped; asked which staged
# paths are source (--unignored), it answers with the framework's check, as a working one does, so a commit of no
# source file starts no check. A token is assembled at run time, never kept in a tracked file.
_proto_repo() { # _proto_repo <folder> <origin>: an app with the prototype tools, a failing stub check and an origin
  new_repo "$1" >/dev/null 2>&1
  mkdir -p "$1/tools" "$1/.githooks"
  cp "$src/framework/tools/prototype.sh" "$src/framework/tools/setup-clone.sh" "$1/tools/"
  cp "$src/framework/.githooks/pre-commit" "$src/framework/.githooks/pre-push" "$1/.githooks/"
  printf '#!/usr/bin/env bash\n[ "$1" != --unignored ] || exec bash "%s" --unignored\necho "stub check: fails"\nexit 1\n' \
    "$src/framework/tools/check.sh" > "$1/tools/check.sh"
  printf '# Tasks\n\n**Next IDs:** T1 · B1 · R1\n' > "$1/TASKS.md"
  printf '.app-director/state/\n' > "$1/.gitignore"
  git init -q --bare "$2"
  (cd "$1" && git config user.name selftest && git config user.email selftest@localhost && git branch -M main \
    && git config branch.autoSetupMerge always \
    && git add -A && git commit -qm "tools and a stub check" && git remote add origin "$2" \
    && git push -q origin main && PATH="$_stop_path" bash tools/setup-clone.sh) >/dev/null 2>&1
}
part_prototype() {
echo "prototype"
_pa="$work/proto-app"; _pw="$work/proto-app-proto-quick-add"; _po="$work/proto-origin.git"
_proto_repo "$_pa" "$_po"
# Both are always called in $(...), so they can change folder and give their process to the command.
proto() { cd "$_pa" && PATH="$_stop_path" exec bash tools/prototype.sh "$@" 2>&1; }
commit_in() { cd "$1" && PATH="$2" exec git commit -qm "$3" 2>&1; }   # commit_in <folder> <PATH> <message>
_pa_none() { [ ! -e "$_pw" ] && [ -z "$(git -C "$_pa" for-each-ref refs/heads/proto/)" ]; }   # no prototype yet

out="$(proto list)"
expect_output "list says so when there are no prototypes" "^prototype: no prototypes \(no proto/ branches\)$" "$out"

# A prototype's only gates are its hooks and gitleaks, so start refuses, creating nothing, without them.
_pa_hooks="$(git -C "$_pa" rev-parse --git-path hooks)"
[ "${_pa_hooks#/}" = "$_pa_hooks" ] && [ "${_pa_hooks#?:}" = "$_pa_hooks" ] && _pa_hooks="$_pa/$_pa_hooks"
mv "$_pa_hooks/pre-push" "$work/pre-push.saved"
out="$(proto start quick-add)"; status=$?
{ [ "$status" -eq 1 ] && printf '%s' "$out" | grep -q "this clone has no App Director pre-push hook: run bash tools/setup-clone.sh here first" && _pa_none; } \
  && ok "start refuses, creating nothing, while this clone has no pre-push hook" || bad "start refuses while this clone has no pre-push hook (exit $status)" "$out"
mv "$work/pre-push.saved" "$_pa_hooks/pre-push"
if PATH="$_no_gl_path" command -v git >/dev/null 2>&1 && PATH="$_no_gl_path" command -v bash >/dev/null 2>&1; then
  out="$(cd "$_pa" && PATH="$_no_gl_path" bash tools/prototype.sh start quick-add 2>&1)"; status=$?
  { [ "$status" -eq 1 ] && printf '%s' "$out" | grep -q "gitleaks isn't on PATH" && _pa_none; } \
    && ok "start refuses, creating nothing, without gitleaks" || bad "start refuses without gitleaks (exit $status)" "$out"
else
  echo "  skip  start without gitleaks (git or bash shares a folder with gitleaks on this machine)"
fi
_pm="$work/proto-old-main"; _proto_repo "$_pm" "$work/proto-old-origin.git"
(cd "$_pm" && git rm -q .githooks/pre-push && PATH="$_stop_path" git commit -qm "a main from before the pre-push hook") >/dev/null 2>&1
out="$(cd "$_pm" && PATH="$_stop_path" bash tools/prototype.sh start quick-add 2>&1)"; status=$?
{ [ "$status" -eq 1 ] && printf '%s' "$out" | grep -q "main has no committed .githooks/pre-push" && [ ! -e "$work/proto-old-main-proto-quick-add" ]; } \
  && ok "start refuses, creating nothing, when main has no committed pre-push hook" || bad "start refuses when main has no committed pre-push hook (exit $status)" "$out"

# origin/main ahead of main (as last fetched): start creates nothing and says how to go on.
_pa_ahead="$(cd "$_pa" && git commit-tree -p main -m "a commit only origin has" "main^{tree}")"
git -C "$_pa" update-ref refs/remotes/origin/main "$_pa_ahead"
out="$(proto start quick-add)"; status=$?
expect_status "start stops when origin/main is ahead of main (exit 5)" 5 "$status" "$out"
expect_output "and offers to bring main up to date or to start as it is" "git pull --ff-only.*start quick-add --as-is" "$out"
[ ! -e "$_pw" ] && ! git -C "$_pa" show-ref --verify --quiet refs/heads/proto/quick-add \
  && ok "and creates no branch and no worktree" || bad "start created a prototype while origin/main was ahead"
out="$(proto start quick-add --as-is)"; status=$?
git -C "$_pa" update-ref refs/remotes/origin/main main
expect_status "start --as-is creates a prototype from main as it is" 0 "$status" "$out"
[ -d "$_pw" ] && [ "$(git -C "$_pw" symbolic-ref --short HEAD 2>/dev/null)" = "proto/quick-add" ] \
  && ok "start creates the worktree beside the project, named after it, on the new branch proto/quick-add" \
  || bad "start creates the worktree beside the project, named after it, on the new branch proto/quick-add" "$out"
[ "$(git -C "$_pa" merge-base main proto/quick-add 2>/dev/null)" = "$(git -C "$_pa" rev-parse main)" ] \
  && ok "the prototype's branch starts from local main" || bad "the prototype's branch starts from local main"
[ -z "$(git -C "$_pa" config --get branch.proto/quick-add.merge)" ] \
  && ok "the prototype's branch has no upstream, even with branch.autoSetupMerge = always" \
  || bad "the prototype's branch has an upstream: $(git -C "$_pa" config --get branch.proto/quick-add.merge)"
expect_output "start runs setup-clone in the worktree, which installs the pre-commit hook" "^setup: pre-commit hook installed" "$out"
expect_output "and the pre-push hook" "^setup: pre-push hook installed" "$out"
grep -q "^## What we're trying$" "$_pw/PROTOTYPE.md" && grep -q '^## How it felt$' "$_pw/PROTOTYPE.md" \
  && grep -q '^## What to keep$' "$_pw/PROTOTYPE.md" \
  && grep -qF 'A session in a checkout that `bash tools/prototype.sh here` calls a prototype (a linked worktree on a `proto/` branch with this file at its root) is a prototype session: read `.app-director/procedures/prototype.md` › In a prototype session before any work.' "$_pw/PROTOTYPE.md" \
  && [ -z "$(git -C "$_pw" status --porcelain)" ] && [ "$(git -C "$_pa" rev-list --count main..proto/quick-add)" = 1 ] \
  && ok "start writes PROTOTYPE.md from its template (what we're trying, how it felt, what to keep) and commits it" \
  || bad "start writes PROTOTYPE.md from its template and commits it" "$(cat "$_pw/PROTOTYPE.md" 2>&1)"

out="$(proto start quick-add)"; status=$?
expect_status "start refuses a name whose branch exists" 1 "$status" "$out"
expect_output "and says the branch exists" "the branch proto/quick-add already exists" "$out"
mkdir -p "$work/proto-app-proto-taken"
out="$(proto start taken)"; status=$?
expect_status "start refuses a name whose folder exists" 1 "$status" "$out"
expect_output "and says the folder exists" "the folder .*proto-app-proto-taken already exists" "$out"
_proto_bad=""
for _pn in Quick quick_add -x x- a/b .. 'two words' list harvest remove here ''; do
  out="$(proto start "$_pn")"; status=$?
  { [ "$status" -eq 1 ] && printf '%s' "$out" | grep -q "isn't a prototype name"; } || _proto_bad="$_proto_bad '$_pn'"
done
[ -z "$_proto_bad" ] && ok "start refuses an invalid name: capitals, an underscore, a dash at either end, a slash, dots, a space, a command word, none" \
  || bad "start doesn't refuse these names:$_proto_bad"
[ "$(git -C "$_pa" for-each-ref refs/heads/proto/ | wc -l | tr -d ' ')" = 1 ] && [ "$(git -C "$_pa" worktree list | wc -l | tr -d ' ')" = 2 ] \
  && ok "a refused start creates no branch and no worktree" || bad "a refused start creates no branch and no worktree" "$(git -C "$_pa" worktree list)"
out="$(cd "$_pw" && PATH="$_stop_path" bash tools/prototype.sh start other 2>&1)"; status=$?
expect_status "start refuses to run in a prototype session" 1 "$status" "$out"
out="$(cd "$_pw" && bash tools/prototype.sh here 2>&1)"; status=$?
expect_status "here: the worktree is a prototype" 0 "$status" "$out"
out="$(cd "$_pa" && bash tools/prototype.sh here 2>&1)"; status=$?
expect_status "here: the main checkout isn't" 1 "$status" "$out"
out="$(proto list)"
expect_output "list shows the prototype, its worktree and its commits since main" "^proto/quick-add · .*proto-app-proto-quick-add · 1 commit\(s\) since main$" "$out"
expect_no_output "list names no gate file for a prototype that changes none" "gate file" "$out"

# The pre-commit hook in the prototype: no check, but the staged secrets scan, which needs gitleaks there.
(cd "$_pw" && printf 'export const tried = 1;\n' > tried.ts && git add tried.ts)
out="$(commit_in "$_pw" "$_stop_path" "proto: try it")"; status=$?
expect_status "pre-commit lets a source commit through in a prototype while the check fails" 0 "$status" "$out"
expect_output "and says the check is skipped in a prototype" "this checkout is a prototype, so the project check is skipped" "$out"
expect_no_output "and doesn't run the check there" "running the project check|stub check" "$out"
(cd "$_pw" && printf 'export const more = 2;\n' >> tried.ts && git add tried.ts)
out="$(commit_in "$_pw" "$_hook_gl:$_stop_path" "proto: a secret")"; status=$?
expect_status "pre-commit still blocks a staged secret in a prototype (stand-in)" 1 "$status" "$out"
expect_output "and names the finding in the prototype (stand-in)" "found in: " "$out"
if PATH="$_no_gl_path" command -v git >/dev/null 2>&1 && PATH="$_no_gl_path" command -v bash >/dev/null 2>&1; then
  out="$(commit_in "$_pw" "$_no_gl_path" "proto: no gitleaks")"; status=$?
  expect_status "pre-commit blocks a commit in a prototype when gitleaks is missing" 1 "$status" "$out"
  expect_output "and says the scan is the only gate there" "in a prototype the secrets scan is the only gate, so the" "$out"
else
  echo "  skip  a prototype commit without gitleaks (git or bash shares a folder with gitleaks on this machine)"
fi
(cd "$_pw" && git reset -q -- tried.ts && git checkout -q -- tried.ts)
# In a prototype, .gitleaksignore and .gitleaks.toml must be main's, on disk and staged: allowlisting needs the human.
(cd "$_pw" && printf 'export const ok = 3;\n' >> tried.ts && git add tried.ts && printf 'tried.ts:generic-api-key:1\n' > .gitleaksignore)
out="$(commit_in "$_pw" "$_stop_path" "proto: an allowlist on disk")"; status=$?
expect_status "pre-commit blocks a prototype commit while a .gitleaksignore on disk differs from main's" 1 "$status" "$out"
expect_output "and says allowlisting needs the human" "\.gitleaksignore differs from main's in this prototype; commit blocked" "$out"
(cd "$_pw" && git add .gitleaksignore)
out="$(commit_in "$_pw" "$_stop_path" "proto: an allowlist staged")"; status=$?
expect_status "pre-commit blocks a prototype commit that stages a .gitleaksignore" 1 "$status" "$out"
(cd "$_pw" && git rm -q --cached .gitleaksignore && rm -f .gitleaksignore && printf '[extend]\nuseDefault = true\n' > .gitleaks.toml)
out="$(commit_in "$_pw" "$_stop_path" "proto: rules on disk")"; status=$?
expect_status "pre-commit blocks a prototype commit while a .gitleaks.toml on disk differs from main's" 1 "$status" "$out"
rm -f "$_pw/.gitleaks.toml"
(cd "$_pw" && git reset -q -- tried.ts && git checkout -q -- tried.ts)
if [ "$_gl_ok" -eq 1 ]; then
  _alnum='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
  _pt_token="ghp_"
  for ((_i = 0; _i < 36; _i++)); do _pt_token="$_pt_token${_alnum:$((RANDOM % 62)):1}"; done
  (cd "$_pw" && printf 'export const token = "%s";\n' "$_pt_token" > leak.ts && git add leak.ts)
  _pt_commits="$(git -C "$_pw" rev-list --count HEAD)"
  out="$(commit_in "$_pw" "$_stop_path" "proto: a token")"; status=$?
  expect_status "pre-commit blocks a token staged in a prototype (real gitleaks)" 1 "$status" "$out"
  expect_output "and names the file in the prototype (real gitleaks)" "found in: leak.ts" "$out"
  expect_no_output "and doesn't print the token" "$_pt_token" "$out"
  [ "$(git -C "$_pw" rev-list --count HEAD)" = "$_pt_commits" ] && ok "the blocked commit in the prototype is not made" \
    || bad "the blocked commit in the prototype is not made"
  (cd "$_pw" && git reset -q -- leak.ts && rm -f leak.ts)
else
  echo "  skip  real gitleaks staged-secret test in a prototype (gitleaks not found or below $_gl_min_req)"
fi

# An inline allow (gitleaks:allow on a line) is an allowlist too, so in a prototype the pre-commit hook refuses a staged
# line that adds it: allowlisting needs the human (T271). The stand-in gitleaks here passes every scan, so only the hook's
# check can stop the commit; the token is assembled at run time, as above, and written only to the prototype's worktree.
_alnum='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
_ia_token="ghp_"
for ((_i = 0; _i < 36; _i++)); do _ia_token="$_ia_token${_alnum:$((RANDOM % 62)):1}"; done
(cd "$_pw" && printf 'export const token = "%s"; // gitleaks:allow\n' "$_ia_token" > inline.ts && git add inline.ts)
_ia_commits="$(git -C "$_pw" rev-list --count HEAD)"
out="$(commit_in "$_pw" "$_stop_path" "proto: an inline allow")"; status=$?
expect_status "pre-commit blocks a prototype commit that stages a gitleaks:allow line" 1 "$status" "$out"
expect_output "and names the staged line that adds gitleaks:allow" "a staged line adds gitleaks:allow" "$out"
expect_output "and says allowlisting needs the human, in the main session" "needs the human, in the main session" "$out"
expect_no_output "and doesn't print the token" "$_ia_token" "$out"
[ "$(git -C "$_pw" rev-list --count HEAD)" = "$_ia_commits" ] && ok "the blocked inline-allow commit is not made" \
  || bad "the blocked inline-allow commit is not made"
# The same line without the allow is not this check's business: the hook (run here, so nothing is committed) lets it through.
(cd "$_pw" && git reset -q -- inline.ts && printf 'export const note = 1; // gitleaks runs on save\n' > inline.ts && git add inline.ts)
out="$(cd "$_pw" && PATH="$_stop_path" bash .githooks/pre-commit 2>&1)"; status=$?
expect_status "pre-commit lets a prototype's staged line through when it names gitleaks but doesn't allow it" 0 "$status" "$out"
expect_no_output "and says nothing about an inline allow" "gitleaks:allow" "$out"
(cd "$_pw" && git reset -q -- inline.ts && rm -f inline.ts)

# Everywhere else the check runs: the prototype's worktree without PROTOTYPE.md or on a detached HEAD, a proto/
# branch in the main checkout (with or without PROTOTYPE.md: it isn't a linked worktree), main, and protoish.
_proto_runs() { # _proto_runs <what> <folder>: a staged source file's commit there runs the failing check
  (cd "$2" && printf 'export const x = 1;\n' > runs.ts && git add runs.ts)
  out="$(commit_in "$2" "$_stop_path" "feat: runs")"; status=$?
  { [ "$status" -eq 1 ] && printf '%s' "$out" | grep -q "running the project check"; } \
    && ok "pre-commit runs the check $1" || bad "pre-commit runs the check $1 (exit $status)" "$out"
  (cd "$2" && git reset -q -- runs.ts && rm -f runs.ts)
}
mv "$_pw/PROTOTYPE.md" "$work/PROTOTYPE.md.saved"
_proto_runs "in a worktree on a proto/ branch without PROTOTYPE.md" "$_pw"
mv "$work/PROTOTYPE.md.saved" "$_pw/PROTOTYPE.md"
git -C "$_pw" checkout -q --detach
_proto_runs "on a detached HEAD, in the prototype's worktree" "$_pw"
git -C "$_pw" switch -q proto/quick-add
git -C "$_pa" switch -q -c proto/fake
_proto_runs "on a proto/ branch in the main checkout" "$_pa"
printf '# Prototype: fake\n' > "$_pa/PROTOTYPE.md"
_proto_runs "on a proto/ branch in the main checkout, with a PROTOTYPE.md (not a linked worktree)" "$_pa"
rm -f "$_pa/PROTOTYPE.md"
git -C "$_pa" switch -q main && git -C "$_pa" branch -q -d proto/fake
_proto_runs "on main" "$_pa"
git -C "$_pa" switch -q -c protoish
_proto_runs "on a branch whose name only starts like one (protoish)" "$_pa"
git -C "$_pa" switch -q main

# The Stop hook runs the check when source files differ from the last commit, but not in a prototype.
_stop_in() { printf '{}' | CLAUDE_PROJECT_DIR="$1" PATH="$_stop_path" bash "$src/framework/.claude/hooks/stop-check.sh" 2>&1; }
printf 'export const wip = 1;\n' > "$_pw/wip.ts"
out="$(_stop_in "$_pw")"; expect_status "the Stop hook doesn't run the check in a prototype" 0 $? "$out"
printf 'export const wip = 1;\n' > "$_pa/wip.ts"
out="$(_stop_in "$_pa")"; expect_status "the Stop hook runs the check on main, and blocks on a failure" 2 $? "$out"
rm -f "$_pa/wip.ts"

# The pre-push hook refuses a proto/ branch, from the prototype or to the remote, and any push that carries a
# prototype's commits under another name, and lets main through.
_push_refused() { # _push_refused <what> <folder> <refspec> <reason pattern>
  out="$(cd "$2" && PATH="$_stop_path" git push -q origin "$3" 2>&1)"; status=$?
  { [ "$status" -ne 0 ] && printf '%s' "$out" | grep -q "a prototype is never pushed; push blocked" && printf '%s' "$out" | grep -q "$4"; } \
    && ok "pre-push refuses $1" || bad "pre-push refuses $1 (exit $status)" "$out"
}
_push_refused "a proto/ branch" "$_pw" proto/quick-add "(a proto/ branch)"
_push_refused "a push to a proto/ branch on the remote" "$_pa" main:refs/heads/proto/sneak "(a proto/ branch)"
_push_refused "HEAD under another name, from the prototype" "$_pw" HEAD:refs/heads/x "carries a prototype's commits"
_push_refused "a prototype's commit by its hash" "$_pa" "$(git -C "$_pa" rev-parse proto/quick-add):refs/heads/y" "carries a prototype's commits"
_push_refused "proto/quick-add~0 under another name" "$_pa" "proto/quick-add~0:refs/heads/z" "carries a prototype's commits"
git -C "$_pa" branch from-proto proto/quick-add >/dev/null 2>&1
_push_refused "a branch made from a prototype's commit" "$_pa" from-proto "carries a prototype's commits"
(cd "$_pa" && printf '# app\n\nA note.\n' > README.md && git add README.md && PATH="$_stop_path" git commit -qm "docs: a note") >/dev/null 2>&1
# The refusal lets main through. Outside a prototype the push then runs the project check, whose stub fails here; in a
# prototype it doesn't.
out="$(cd "$_pa" && PATH="$_stop_path" git push -q origin main 2>&1)"; status=$?
[ "$status" -ne 0 ] && ok "pre-push runs the check for main outside a prototype, and blocks the push when it fails" \
  || bad "pre-push runs the check for main outside a prototype, and blocks the push when it fails (exit $status)" "$out"
expect_output "with the check's own output" "^stub check: fails$" "$out"
expect_output "and says the full check fails" "^pre-push: the full check fails, so nothing was pushed\." "$out"
out="$(cd "$_pw" && PATH="$_stop_path" git push -q origin main 2>&1)"
expect_status "pre-push lets main through from a prototype, where the check doesn't run" 0 $? "$out"
expect_no_output "and doesn't run the check there" "running the project check|stub check" "$out"
[ "$(git --git-dir="$_po" for-each-ref --format='%(refname)')" = "refs/heads/main" ] \
  && ok "the origin has main and nothing else" || bad "a refused push reached the origin" "$(git --git-dir="$_po" for-each-ref)"

# harvest prints the prototype's commits, files, the diff command, uncommitted changes and notes, and writes nothing.
_pa_state() { git -C "$_pa" status --porcelain; git -C "$_pa" rev-parse HEAD proto/quick-add; git -C "$_pa" for-each-ref; cksum < "$_pa/TASKS.md"; }
_pa_before="$(_pa_state)"
out="$(proto harvest quick-add)"; status=$?
expect_status "harvest prints what the harvest reads" 0 "$status" "$out"
expect_output "harvest lists the prototype's commits since main" "proto: try it" "$out"
expect_output "harvest lists the files the prototype changed, with the diff command" "read the diff with: git diff main\.\.\.proto/quick-add$" "$out"
expect_output "harvest lists a changed file" "tried\.ts" "$out"
expect_output "harvest names the worktree's uncommitted changes, which the diff leaves out" "^\?\? wip\.ts$" "$out"
expect_output "harvest shows the prototype's notes" "^## How it felt$" "$out"
[ "$(_pa_state)" = "$_pa_before" ] && ok "harvest writes no item, record, commit or branch without the human" \
  || bad "harvest changed the main checkout or the branches" "$(_pa_state)"
out="$(proto harvest nothing-here)"; expect_status "harvest refuses a prototype that doesn't exist" 1 $? "$out"

# harvest and list name a gate file that differs from main's, committed on the branch or only edited in the worktree
# (T271). A prototype's gates are main's, so the human decides them in the main session. The commit goes through the
# passthrough gitleaks: it changes no source file, and a gate change needs no check.
_pg="$work/proto-app-proto-gated"
out="$(proto start gated)"; status=$?
expect_status "start makes a second prototype, to change a gate in" 0 "$status" "$out"
(cd "$_pg" && printf '# a change to the pre-push hook\n' >> .githooks/pre-push && git add .githooks/pre-push)
out="$(commit_in "$_pg" "$_stop_path" "proto: change the pre-push hook")"; status=$?
expect_status "the prototype commits a change to a gate file" 0 "$status" "$out"
out="$(proto harvest gated)"
expect_output "harvest names the committed gate file that differs from main's" "^--- gate files that differ from main's: .*$" "$out"
expect_output "and lists it" "^  \.githooks/pre-push$" "$out"
out="$(proto list)"
expect_output "list names it under the prototype" "^  gate files that differ from main's: \.githooks/pre-push$" "$out"
printf '# an edit to the setup script, not committed\n' >> "$_pg/tools/setup-clone.sh"
out="$(proto harvest gated)"
expect_output "harvest names a gate file edited in the worktree but not committed" "^  tools/setup-clone\.sh$" "$out"
(cd "$_pg" && git checkout -q -- tools/setup-clone.sh)
out="$(proto remove gated)"; status=$?
expect_status "remove takes the second prototype's worktree away" 0 "$status" "$out"

# remove: never forced, and the branch stays for the human to delete.
out="$(proto remove quick-add)"; status=$?
expect_status "remove fails on a worktree with uncommitted changes" 1 "$status" "$out"
[ -f "$_pw/wip.ts" ] && ok "and leaves the worktree and its changes in place" || bad "remove deleted a worktree with uncommitted changes"
expect_output "and says why, without forcing it" "git worktree remove failed \(above\); uncommitted changes are the usual cause.*never force it" "$out"
rm -f "$_pw/wip.ts"
out="$(proto remove quick-add)"; status=$?
expect_status "remove removes a clean worktree" 0 "$status" "$out"
[ ! -e "$_pw" ] && git -C "$_pa" show-ref --verify --quiet refs/heads/proto/quick-add \
  && ok "remove deletes the worktree's folder and keeps the branch with its commits" \
  || bad "remove deletes the worktree's folder and keeps the branch with its commits" "$out"
expect_output "remove asks the human to delete the branch, with the command" "the human runs that.*: git branch -D proto/quick-add$" "$out"
out="$(proto list)"
expect_output "list shows a prototype whose worktree is gone" "^proto/quick-add · no worktree · 2 commit\(s\) since main$" "$out"
[ -z "$(git --git-dir="$_po" for-each-ref refs/heads/proto/)" ] && [ -n "$(git --git-dir="$_po" for-each-ref refs/heads/main)" ] \
  && ok "nothing pushes a proto/ branch" || bad "a proto/ branch reached the origin" "$(git --git-dir="$_po" for-each-ref)"

}

# A project folder whose name has a space.
part_protospace() {
_ps="$work/proto space app"; _psw="$work/proto space app-proto-try"
_proto_repo "$_ps" "$work/proto-space-origin.git"
out="$(cd "$_ps" && PATH="$_stop_path" bash tools/prototype.sh start try 2>&1)"; status=$?
expect_status "start works in a project folder whose name has a space" 0 "$status" "$out"
out="$(cd "$_psw" && bash tools/prototype.sh here 2>&1)"
expect_status "the worktree beside it, named after it, is a prototype" 0 $? "$out"
out="$(cd "$_ps" && bash tools/prototype.sh list 2>&1)"
expect_output "list names its folder, space and all" "^proto/try · .*proto space app-proto-try · 1 commit\(s\) since main$" "$out"
out="$(cd "$_ps" && bash tools/prototype.sh harvest try 2>&1)"
expect_status "harvest works there" 0 $? "$out"
out="$(cd "$_ps" && bash tools/prototype.sh remove try 2>&1)"; status=$?
[ "$status" -eq 0 ] && [ ! -e "$_psw" ] && ok "remove works there" || bad "remove works in a folder whose name has a space (exit $status)" "$out"
}

part_ui_design() {
# --- /ui-design -----------------------------------------------------------------------------------
echo "ui-design"
# Everything here runs in the installed example ($app). The reader and the capture checks need Node;
# the capture of the fixture web app (tests/ui-web) also needs Playwright and Chromium, found in
# tests/ui-web/node_modules (npm install there, then npx playwright install chromium) or in the
# node_modules folder $ADIR_PLAYWRIGHT names. Without them those tests are skipped.
cd "$app" || exit 1
helpers="$work/ui-helpers"
mkdir -p "$helpers"
# compare <actual> <expected>: the same reading, apart from where it came from.
cat > "$helpers/compare.mjs" <<'EOF'
import { readFileSync } from "node:fs";
const load = (path) => { const value = JSON.parse(readFileSync(path, "utf8")); delete value.source; delete value.sha1; return value; };
const same = (a, b) => {
  if (typeof a === "number" && typeof b === "number") return a === b;
  if (Array.isArray(a) || Array.isArray(b)) return Array.isArray(a) && Array.isArray(b) && a.length === b.length && a.every((item, index) => same(item, b[index]));
  if (a && b && typeof a === "object" && typeof b === "object") {
    const keys = Object.keys(a).sort();
    return same(keys, Object.keys(b).sort()) && keys.every((key) => same(a[key], b[key]));
  }
  return a === b;
};
const [actual, expected] = [load(process.argv[2]), load(process.argv[3])];
console.log(same(actual, expected) ? "SAME" : "DIFFERENT\n" + JSON.stringify(actual) + "\n" + JSON.stringify(expected));
EOF
# validate <starter> <screen> <W> <H> <drawing.mjs>: valid Excalidraw (types.ts in excalidraw/excalidraw) that reads back empty.
cat > "$helpers/validate.mjs" <<'EOF'
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { pathToFileURL } from "node:url";
const [path, screen, width, height, reader] = process.argv.slice(2);
const { readDrawing } = await import(pathToFileURL(reader).href);
const TYPES = ["rectangle", "text", "image", "frame", "line", "arrow", "freedraw", "ellipse", "diamond"];
const problems = [];
const doc = JSON.parse(readFileSync(path, "utf8"));
if (doc.type !== "excalidraw" || doc.version !== 2) problems.push("type excalidraw, version 2");
if (!Array.isArray(doc.elements) || typeof doc.appState !== "object" || typeof doc.files !== "object") { console.log("elements, appState and files are required"); process.exit(1); }
for (const [key, file] of Object.entries(doc.files)) {
  if (file.id !== key || file.mimeType !== "image/png" || !String(file.dataURL).startsWith("data:image/png;base64,") || typeof file.created !== "number") problems.push("file " + key);
}
const ids = new Map();
const frames = [];
let previous = "";
for (const e of doc.elements) {
  if (!e.id || ids.has(e.id)) problems.push(`id '${e.id}' is empty or repeated`);
  ids.set(e.id, e);
  if (e.type === "frame") frames.push(e.id);
  if (!TYPES.includes(e.type)) problems.push(e.id + ": type");
  for (const key of ["x", "y", "width", "height", "angle", "strokeWidth", "roughness", "opacity", "updated"]) if (typeof e[key] !== "number") problems.push(`${e.id}: ${key} must be a number`);
  for (const key of ["seed", "version", "versionNonce"]) if (!Number.isInteger(e[key])) problems.push(`${e.id}: ${key} must be an integer`);
  for (const key of ["strokeColor", "backgroundColor", "index"]) if (typeof e[key] !== "string") problems.push(`${e.id}: ${key} must be a string`);
  if (!["hachure", "cross-hatch", "solid", "zigzag"].includes(e.fillStyle) || !["solid", "dashed", "dotted"].includes(e.strokeStyle)) problems.push(e.id + ": fillStyle or strokeStyle");
  if (!Array.isArray(e.groupIds) || typeof e.isDeleted !== "boolean" || typeof e.locked !== "boolean") problems.push(e.id + ": groupIds, isDeleted or locked");
  for (const key of ["frameId", "roundness", "boundElements", "link"]) if (!(key in e)) problems.push(`${e.id}: ${key} is missing (null is fine)`);
  if (!(String(e.index) > previous)) problems.push(e.id + ": index must grow with the array order");
  previous = String(e.index);
  if (e.type === "text" && (typeof e.text !== "string" || typeof e.originalText !== "string" || typeof e.fontSize !== "number" || typeof e.fontFamily !== "number"
      || typeof e.lineHeight !== "number" || typeof e.autoResize !== "boolean" || !["left", "center", "right"].includes(e.textAlign)
      || !["top", "middle", "bottom"].includes(e.verticalAlign) || !("containerId" in e))) problems.push(e.id + ": text fields");
  if (e.type === "image" && (!(e.fileId in doc.files) || e.status !== "saved" || !Array.isArray(e.scale) || e.scale.length !== 2 || !("crop" in e))) problems.push(e.id + ": fileId, status, scale or crop");
  if (e.type === "frame" && typeof e.name !== "string") problems.push(e.id + ": name");
}
if (frames.length !== 1) problems.push("one frame is expected");
else {
  const frame = ids.get(frames[0]);
  const background = ids.get("ddd-background") || {};
  if (frame.name !== screen || frame.width !== Number(width) || frame.height !== Number(height)) problems.push("the frame is named after the screen and is the size of the capture");
  if (background.type !== "image" || background.locked !== true || background.frameId !== frames[0] || background.width !== Number(width) || background.height !== Number(height)) problems.push("the screenshot is a locked image filling the frame");
  for (const [id, e] of ids) {
    if (e.type !== "frame" && e.frameId !== frames[0] && id !== "ddd-legend") problems.push(id + ": frameId");
    if (id.startsWith("ddd-existing") && (e.locked !== false || e.opacity !== 25 || JSON.stringify(e.groupIds) !== '["ddd-existing"]')) problems.push(id + ": the existing group is unlocked (it can be dragged), at 25% opacity");
  }
  if (ids.has("ddd-legend") && ids.get("ddd-legend").frameId !== null) problems.push("the legend is outside the frame");
}
const read = readDrawing(readFileSync(path, "utf8"), path, "", screen, join(dirname(path), "captures"));
if (read.error) problems.push("reading it back: " + read.error);
else {
  const back = read.drawing.frames[0];
  if (back.boxes.length || back.unparsed.length || back.notes.length || back.removed.length) problems.push("saving the starter unchanged and reading it back must give no boxes, notes or unparsed entries");
}
console.log(problems.length === 0 ? "VALID" : problems.join("\n"));
EOF

if ! command -v node >/dev/null 2>&1; then
  echo "  skip  /ui-design reader and capture tests (Node isn't installed)"
else
  # Drawings. The fixture drawing (tests/ui-drawing/, shared with Godot Director) has a green box with
  # bound text and click:, a blue box over an existing element, a red X over an element, an arrowed
  # comment, a box inside a box, a note outside the frame and a freehand squiggle; its expected
  # reading was worked out by hand. The scaled copy has the background image and everything over it
  # moved and scaled to 50% (the frame stays). The *.godot.drawing.json files are what Godot
  # Director's reader (tools/ui_drawing.gd) writes for them: the port must write the same text.
  drawings="$work/drawings"
  mkdir -p "$drawings/drawing_fixtures/read" "$drawings/drawing_fixtures/moved"
  cp "$src"/tests/ui-drawing/* "$drawings/drawing_fixtures/"
  for variant in fixture:read fixture-scaled:moved; do
    name="${variant%%:*}"; folder="${variant#*:}"
    cp "$src/tests/ui-drawing/fixture.elements.json" "$drawings/drawing_fixtures/$folder/hero_room@1000x500.elements.json"
    out="$(cd "$drawings" && node "$app/tools/ui/drawing.mjs" "drawing_fixtures/$name.excalidraw" "drawing_fixtures/$folder/hero_room.drawing.json" 2>&1)"
    expect_status "the reader reads $name.excalidraw" 0 $? "$out"
    out="$(node "$helpers/compare.mjs" "$drawings/drawing_fixtures/$folder/hero_room.drawing.json" "$src/tests/ui-drawing/fixture.expected.json" 2>&1)"
    case "$name" in
      fixture) expect_output "the fixture drawing gives exactly the expected boxes, intents, parent, comment, removal, note and one unparsed entry, to 0.1%" "^SAME" "$out" ;;
      *) expect_output "the same drawing with the background image moved and scaled 50% gives the same percentages" "^SAME" "$out" ;;
    esac
    cmp -s "$drawings/drawing_fixtures/$folder/hero_room.drawing.json" "$src/tests/ui-drawing/$name.godot.drawing.json" \
      && ok "and exactly the drawing.json Godot Director's reader writes for $name.excalidraw" \
      || bad "the reader writes the drawing.json Godot Director's reader writes for $name.excalidraw" \
        "$(diff "$drawings/drawing_fixtures/$folder/hero_room.drawing.json" "$src/tests/ui-drawing/$name.godot.drawing.json" | head -n 10)"
  done
  out="$(cd "$drawings" && node "$app/tools/ui/drawing.mjs" drawing_fixtures/fixture.excalidraw drawing_fixtures/read/hero_room.drawing.json 2>&1)"
  case "$out" in *claimed*) bad "the fixture has no claimed element" "$out" ;; *) ok "the fixture has no claimed element" ;; esac
  out="$(cd "$drawings" && node "$app/tools/ui/drawing.mjs" drawing_fixtures/fixture-conflict.excalidraw drawing_fixtures/read/conflict.drawing.json 2>&1)"
  expect_output "an element claimed by a moved grey box and a blue box is named in one note" "note: hero_room: element 4 \(GearList\) is claimed by a moved grey box and a blue box named after it" "$out"
  mkdir -p "$drawings/drawing_fixtures/nomap"
  out="$(cd "$drawings" && node "$app/tools/ui/drawing.mjs" drawing_fixtures/fixture.excalidraw drawing_fixtures/nomap/hero_room.drawing.json 2>&1)"
  expect_output "with no element map the moved grey boxes are skipped with one note per frame" "note: hero_room: no element map hero_room@1000x500.elements.json, so the moved grey boxes are ignored" "$out"
  [ "$(printf '%s
' "$out" | grep -c 'no element map')" = "1" ] && ok "and it is one note" || bad "and it is one note" "$out"
  out="$(node tools/ui/drawing.mjs "$drawings/nowhere.excalidraw" "$drawings/read.json" 2>&1)"; expect_status "the reader refuses a missing drawing" 1 $? "$out"
  printf '{ not json' > "$drawings/broken.excalidraw"
  out="$(node tools/ui/drawing.mjs "$drawings/broken.excalidraw" "$drawings/read.json" 2>&1)"; expect_status "the reader refuses invalid JSON" 1 $? "$out"
  expect_output "and says so" "isn't valid JSON" "$out"
  printf '{"type":"excalidraw","version":2,"elements":[],"files":{}}' > "$drawings/empty.excalidraw"
  out="$(node tools/ui/drawing.mjs "$drawings/empty.excalidraw" "$drawings/read.json" 2>&1)"; expect_status "the reader refuses a drawing with no frame" 1 $? "$out"
  expect_output "and says so" "has no frame" "$out"
  out="$(node tools/ui/drawing.mjs starter "$drawings/drawing_fixtures/fixture" "$drawings/hero_room.starter.excalidraw" 2>&1)"
  expect_status "the starter drawing is written from a capture's files" 0 $? "$out"
  cmp -s "$drawings/hero_room.starter.excalidraw" "$src/tests/ui-drawing/starter.expected.excalidraw" \
    && ok "the starter matches the hand-checked fixture that Godot Director's starter matches" \
    || bad "the starter matches the hand-checked fixture" "$(diff "$drawings/hero_room.starter.excalidraw" "$src/tests/ui-drawing/starter.expected.excalidraw" | head -n 10)"
  out="$(node "$helpers/validate.mjs" "$drawings/hero_room.starter.excalidraw" hero_room 1000 500 "$app/tools/ui/drawing.mjs" 2>&1)"
  expect_output "the starter is valid Excalidraw, and saved unchanged it reads back with no boxes and no unparsed entries" "^VALID" "$out"

  # What capture needs, and what it says without it. Nothing may be written when it can't run.
  cp tools/ui_capture.cfg "$work/saved-ui-cfg"; cp tools/ui/screens.mjs "$work/saved-catalog"; cp tools/check.cfg "$work/saved-check-cfg"
  rm -rf product/ui/captures
  out="$(bash tools/ui_capture.sh --list 2>&1)"; expect_status "lists the catalog with Node alone" 0 $? "$out"
  expect_output "a line per screen: id, title, states, route, drawing and spec" "home · Home · states: default · opens / · drawing: no · spec: no" "$out"
  printf 'export default { screens: [\n  { id: "a", title: "A", route: "/" },\n  { id: "a", title: "Again", route: "/again" },\n  { id: "b", title: "B", route: "b", scene: "x" },\n] };\n' > tools/ui/screens.mjs
  out="$(bash tools/ui_capture.sh --list 2>&1)"; expect_status "fails a catalog with broken entries" 1 $? "$out"
  expect_output "and names each problem" "the id 'a' is used twice" "$out"
  expect_output "and an unknown key and a route that isn't a path" "unknown key 'scene'.*route must be a path" "$out"
  cp "$work/saved-catalog" tools/ui/screens.mjs
  mkdir -p src/ui/screens
  printf 'export const HomeScreen = () => `<h1 data-testid="home-title">Home</h1>`;\n' > src/ui/screens/HomeScreen.ts
  out="$(bash tools/ui_capture.sh --missing 2>&1)"; expect_status "--missing never fails" 0 $? "$out"
  expect_output "it lists a screen file the catalog doesn't name as a source" "missing: src/ui/screens/HomeScreen.ts" "$out"
  out="$(bash tools/ui_capture.sh --all 2>&1)"; expect_status "exits 3 for an app with no web UI to open" 3 $? "$out"
  expect_output "and says capture isn't available for it yet" "capture isn't available for this .*app yet" "$out"
  printf '# Home\n\n## Layout (at 1280x720)\n| # | Element | Name | Where (x, y, w, h %%) | Shows | Does | Size |\n|---|---|---|---|---|---|---|\n| 1 | Title | home-title | 2, 2, 20, 5 | - | - | fit |\n| 2 | Menu | home-menu | 2, 10, 20, 5 | - | - | fit |\n' > product/ui/home.md
  out="$(bash tools/ui_capture.sh home --verify 2>&1)"; expect_status "verify without capture exits 3: unverified" 3 $? "$out"
  expect_output "but checks the spec's names in the source" "\| Title \| home-title \| src/ui/screens/HomeScreen.ts \|" "$out"
  expect_output "and names one that isn't there" "\| Menu \| home-menu \| not found \|" "$out"
  sed 's#^base_url =.*#base_url = https://example.com#' "$work/saved-ui-cfg" > tools/ui_capture.cfg
  out="$(bash tools/ui_capture.sh --all 2>&1)"; expect_status "refuses a host that isn't this machine (exit 3)" 3 $? "$out"
  expect_output "and says why" "refusing \[web\] base_url: example.com isn't this machine" "$out"
  sed 's#^base_url =.*#base_url = http://127.0.0.1:9#' "$work/saved-ui-cfg" > tools/ui_capture.cfg
  out="$(bash tools/ui_capture.sh --all 2>&1)"; expect_status "exits 3 without Playwright" 3 $? "$out"
  expect_output "and gives the command that installs it" "cd tools/ui && npm install && npx playwright install chromium" "$out"
  _no_node_path=""
  for _dir in $(printf '%s' "$PATH" | tr ':' '\n'); do
    [ -x "$_dir/node" ] || [ -x "$_dir/node.exe" ] || _no_node_path="${_no_node_path:+$_no_node_path:}$_dir"
  done
  out="$(PATH="$_no_node_path" bash tools/ui_capture.sh --all 2>&1)"; expect_status "exits 3 without Node" 3 $? "$out"
  expect_output "and says it needs Node 20" "needs Node 20 or newer" "$out"
  # The floor is Node 20, the lowest that Playwright 1.64.1 declares: a Node 19 is refused, not run.
  mkdir -p "$work/node19" && printf '#!/bin/sh\ncase "$1" in -p) echo 19 ;; --version) echo v19.9.0 ;; esac\n' > "$work/node19/node" && chmod +x "$work/node19/node"
  out="$(PATH="$work/node19:$PATH" bash tools/ui_capture.sh --all 2>&1)"; expect_status "exits 3 on Node 19, below the floor" 3 $? "$out"
  expect_output "and says it needs Node 20 or newer, and which Node it found" "needs Node 20 or newer; this is v19.9.0" "$out"
  [ ! -e product/ui/captures ] && ok "writes nothing when it can't run" || bad "writes nothing when it can't run" "$(ls product/ui/captures)"
  out="$(PATH="$_no_node_path" bash tools/check.sh 2>&1)"; expect_status "the check passes without Node" 0 $? "$out"
  fingerprint="$(bash tools/check.sh --fingerprint)"
  mkdir -p product/ui/captures && printf '{}\n' > product/ui/captures/home@1280x720.elements.json && printf 'x' > product/ui/captures/home@1280x720.png
  [ "$(bash tools/check.sh --fingerprint)" = "$fingerprint" ] && ok "captures don't change the check's fingerprint (they're gitignored)" \
    || bad "captures don't change the check's fingerprint (they're gitignored)"
  rm -rf product/ui/captures product/ui/home.md

  # An upgrade from the release before /ui-design: an app without its files gets the stubs, the
  # .gitignore lines and the manifest entries, and keeps its own AGENTS.md and check.cfg.
  upgraded="$work/upgraded-ui"
  new_repo "$upgraded"
  bash "$src/install.sh" "$upgraded" >/dev/null 2>&1
  (cd "$upgraded" && rm -rf .app-director/procedures/ui-design.md .claude/skills/ui-design tools/ui_capture.sh tools/ui tools/ui_capture.cfg product/ui \
    && grep -v -e '/product/ui/captures/' -e '/tools/ui/' .gitignore > .gitignore.new && mv .gitignore.new .gitignore \
    && grep -v -e 'tools/ui' -e 'ui-design' .app-director/manifest > manifest.new && mv manifest.new .app-director/manifest \
    && printf '# My app\nOur own AGENTS.md\n' > AGENTS.md && printf '[project]\nstack = none\n[ui]\ndirs = web/pages\n' > tools/check.cfg \
    && mkdir -p web/pages && printf 'export default () => "<main>Orders</main>";\n' > web/pages/orders.tsx)
  out="$(bash "$src/install.sh" "$upgraded" 2>&1)"; expect_status "upgrades an app from before /ui-design" 0 $? "$out"
  if [ -f "$upgraded/tools/ui/screens.mjs" ] && [ -f "$upgraded/tools/ui_capture.cfg" ] && [ -f "$upgraded/product/ui/README.md" ] \
      && [ -x "$upgraded/tools/ui_capture.sh" ] && grep -qx '/product/ui/captures/' "$upgraded/.gitignore" && grep -qx '/tools/ui/node_modules/' "$upgraded/.gitignore" \
      && grep -q "$(printf '\t')tools/ui/capture.mjs$" "$upgraded/.app-director/manifest" && grep -q "$(printf '\t').app-director/procedures/ui-design.md$" "$upgraded/.app-director/manifest"; then
    ok "it gets the catalog, the settings, the tools, the .gitignore lines and the manifest entries"
  else
    bad "the upgrade gets the catalog, the settings, the tools, the .gitignore lines and the manifest entries" "$out"
  fi
  grep -q "Our own AGENTS.md" "$upgraded/AGENTS.md" && grep -q "dirs = web/pages" "$upgraded/tools/check.cfg" \
    && ok "and keeps its own AGENTS.md and check.cfg" || bad "the upgrade keeps the app's own AGENTS.md and check.cfg"
  out="$(cd "$upgraded" && bash tools/ui_capture.sh --missing 2>&1)"; expect_status "align's screen check lists without failing" 0 $? "$out"
  expect_output "the app's screens the catalog doesn't cover yet" "missing: web/pages/orders.tsx" "$out"

  # Capture of the fixture web app (tests/ui-web), served on this machine by its start_command.
  pw="${ADIR_PLAYWRIGHT:-$src/tests/ui-web/node_modules}"
  chromium_ok=0
  if [ -d "$pw/playwright" ] && [ -d "$pw/playwright-core" ]; then
    mkdir -p tools/ui/node_modules && cp -R "$pw/playwright" "$pw/playwright-core" tools/ui/node_modules/
    (cd tools/ui && node --input-type=module -e 'import { chromium } from "playwright"; import { existsSync } from "node:fs"; process.exit(existsSync(chromium.executablePath()) ? 0 : 1);') >/dev/null 2>&1 && chromium_ok=1
  fi
  if [ "$chromium_ok" -eq 0 ]; then
    echo "  skip  capture of the fixture web app (no Playwright with Chromium in tests/ui-web/node_modules or \$ADIR_PLAYWRIGHT)"
  else
    rm -rf uifixture && copy_without "$src/tests/ui-web" uifixture node_modules
    port=$((40000 + $$ % 20000))
    # The runs that capture states that finish keep the shipped 60-second setup_timeout: a state here takes a fraction of a second,
    # but on a busy machine (the other parts of this selftest run beside this one, and so may other work) it can take seconds, and
    # a short limit made it fail (T304). Only the run of the one state that never finishes sets 3 seconds, so that it fails at once.
    sed -e "s#^base_url =.*#base_url = http://127.0.0.1:$port#" -e "s#^start_command =.*#start_command = node uifixture/serve.mjs $port#" \
      -e 's#^list = .*#list = 1280x720 800x600#' -e 's#^setup_timeout = .*#setup_timeout = 60#' "$work/saved-ui-cfg" > tools/ui_capture.cfg
    cp tools/ui_capture.cfg "$work/fixture-cfg"
    cat > tools/ui/screens.mjs <<'EOF'
export default {
  screens: [
    { id: "clean", title: "Hero room", route: "/", source: "uifixture/site/index.html",
      states: {
        default: null,
        busy: async (page, api, screen) => { await screen.open(); await page.evaluate(() => { document.querySelector("h2").textContent = "Ada (busy)"; }); },
      } },
    { id: "lint", title: "Lint fixture", route: "/lint" },
    { id: "order", title: "Tab order", route: "/order" },
    { id: "broken", title: "Throws", route: "/broken" },
    { id: "gone", title: "Missing route", route: "/missing" },
    { id: "stuck", title: "A state that never finishes", route: "/", states: { default: () => new Promise(() => undefined) } },
    { id: "away", title: "Calls a hosted backend", route: "/away" },
    { id: "apiaway", title: "Seeds through a redirect off this machine", route: "/", states: { default: async (page, api) => { await api.get("/redirect-away"); } } },
    { id: "modal", title: "A modal dialog", route: "/modal" },
    { id: "reload", title: "Reloads when focused", route: "/reload" },
    { id: "bad", title: "A broken entry", route: "nope" },
  ],
};
EOF
    captures=product/ui/captures
    # Every screen but the one that never finishes (it would wait out the whole limit, twice); then that one with the short limit and
    # the screen after it, which shows the run goes on after a state is cut off.
    sed 's#^skip =.*#skip = stuck#' "$work/fixture-cfg" > tools/ui_capture.cfg
    out="$(bash tools/ui_capture.sh --all 2>&1)"; status=$?
    sed -e 's#^setup_timeout = .*#setup_timeout = 3#' -e 's#^skip =.*#skip = clean lint order broken gone apiaway modal reload#' "$work/fixture-cfg" > tools/ui_capture.cfg
    stuck_out="$(bash tools/ui_capture.sh --all --size 1280x720 2>&1)"
    cp "$work/fixture-cfg" tools/ui_capture.cfg
    expect_status "a screen that fails fails the run (exit 1), and the others are captured" 1 "$status" "$out"
    missing=""
    for base in clean clean.busy lint order away modal; do
      for size in 1280x720 800x600; do
        for ext in png elements.json map.png lint.txt; do [ -f "$captures/$base@$size.$ext" ] || missing="$missing $base@$size.$ext"; done
      done
    done
    [ -z "$missing" ] && ok "writes a PNG, element map, map image and lint file per screen, state and size" || bad "capture outputs missing:$missing" "$out"
    [ "$(od -An -tu1 -j16 -N8 "$captures/clean@800x600.png" | tr -s ' ' | sed 's/^ //;s/ $//')" = "0 0 3 32 0 0 2 88" ] \
      && ok "a capture has the requested size (800x600)" || bad "a capture has the requested size (800x600)"
    (cd "$captures" && ls -- *.starter.excalidraw 2>/dev/null | tr '\n' ' ') > "$work/starters"
    [ "$(cat "$work/starters")" = "away.starter.excalidraw broken.starter.excalidraw clean.starter.excalidraw lint.starter.excalidraw modal.starter.excalidraw order.starter.excalidraw " ] \
      && ok "writes a starter drawing for the default state at the default size" || bad "writes a starter drawing for the default state at the default size" "$(cat "$work/starters")"
    grep -q '"schema": 1, "adapter": "playwright"' "$captures/clean@1280x720.elements.json" \
      && grep -q '"id":"change","stable":true,"path":"\[data-testid=\\"change\\"\]","kind":"button","name":"Change",' "$captures/clean@1280x720.elements.json" \
      && ok "the element map lists the data-testid elements with their role and name" || bad "the element map lists the data-testid elements with their role and name" "$(head -n 8 "$captures/clean@1280x720.elements.json")"
    grep -q 'Ada (busy)' "$captures/clean.busy@1280x720.elements.json" && ! grep -q 'Ada (busy)' "$captures/clean@1280x720.elements.json" \
      && ok "a state prepares the page after opening it" || bad "a state prepares the page after opening it"
    [ -z "$(cat "$captures"/clean@*.lint.txt "$captures"/clean.busy@*.lint.txt)" ] && ok "the clean page is lint-clean at every size" \
      || bad "the clean page is lint-clean at every size" "$(cat "$captures"/clean*.lint.txt)"
    lint="$(cat "$captures/lint@1280x720.lint.txt")"
    for rule in 'squeezed-text element [0-9]* \[data-testid="squeezed"\]' 'stretched-control element [0-9]* \[data-testid="stretched"\]' \
        'off-screen element [0-9]* \[data-testid="far"\]' 'overlap element [0-9]* \[data-testid="link-one"\]: element [0-9]* \(Two\)' \
        'unreachable element [0-9]* \[data-testid="skipped"\]' 'no-default-focus element [0-9]* \[data-testid="ok"\]' \
        'hard-coded-position element [0-9]* \[data-testid="pinned"\].*\(warning\)'; do
      expect_output "lint: ${rule%% *} on the element built to break it" "$rule" "$lint"
    done
    [ "$(printf '%s\n' "$lint" | grep -c .)" = "7" ] && ok "and nothing else on that page" || bad "the lint page has exactly seven findings" "$lint"
    order="$(node -e 'const m = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); console.log(m.elements.map((e) => e.id + "=" + e.focus_order).join(" "));' "$captures/order@1280x720.elements.json")"
    [ "$order" = "first=3 third=2 second=1 trap=4 after=null" ] && ok "Tab order follows tabindex, and stops at the focus trap" || bad "Tab order follows tabindex, and stops at the focus trap" "$order"
    [ "$(cat "$captures/order@1280x720.lint.txt")" = 'unreachable element 5 [data-testid="after"]: Tab never reaches it from the default focus' ] \
      && ok "the element after the trap is the one unreachable element" || bad "the element after the trap is the one unreachable element" "$(cat "$captures/order@1280x720.lint.txt")"
    head -n 1 "$captures/broken@1280x720.lint.txt" | grep -q '^error: a page error: selftest page error' && [ -f "$captures/broken@1280x720.png" ] \
      && ok "a page error fails its screen, which is still captured, with the error at the top of its lint file" || bad "a page error fails its screen, with the error at the top of its lint file" "$out"
    grep -q '^error: /missing answered 404' "$captures/gone@1280x720.lint.txt" && [ ! -f "$captures/gone@1280x720.png" ] \
      && ok "a route that answers 404 fails its screen and leaves only the error" || bad "a route that answers 404 fails its screen and leaves only the error" "$out"
    if printf '%s' "$stuck_out" | grep -qE -- "FAIL: stuck@1280x720: the setup didn't finish within 3 seconds" && printf '%s' "$stuck_out" | grep -q -- "begin away@1280x720"; then
      ok "a state that doesn't finish fails only its screen"
    else
      bad "a state that doesn't finish fails only its screen (no match for its failure, then the next screen's start)" "$stuck_out"
    fi
    expect_output "a broken catalog entry is named" "FAIL: bad: its route must be a path" "$out"
    away="$(cat "$captures/away@1280x720.lint.txt")"
    expect_output "a request to a host that isn't this machine is blocked and noted" "^note: blocked requests to 192\.0\.2\.1: not this machine" "$away"
    expect_output "so is a redirect off this machine, which capture doesn't follow" "^note: blocked requests to 203\.0\.113\.9:" "$away"
    expect_output "and a WebSocket to another host" "^note: blocked requests to 198\.51\.100\.7:" "$away"
    grep -q '"name":"local data"' "$captures/away@1280x720.elements.json" && ok "while the page's own requests to this machine go through" \
      || bad "the page's own requests to this machine go through" "$(head -n 8 "$captures/away@1280x720.elements.json")"
    expect_output "the api helper doesn't follow a redirect (it fails the state)" "FAIL: apiaway@1280x720: api: GET http://127\.0\.0\.1:$port/redirect-away answered 302" "$out"
    [ -z "$(cat "$captures/modal@1280x720.lint.txt")" ] && ok "behind an open modal dialog, nothing counts as unreachable" \
      || bad "behind an open modal dialog, nothing counts as unreachable" "$(cat "$captures/modal@1280x720.lint.txt")"
    expect_output "a page that reloads while it is mapped fails only its screen" "FAIL: reload@1280x720: the page changed while it was mapped" "$out"
    expect_output "capture starts the app with start_command" "starting the app: node uifixture/serve.mjs $port" "$out"
    node -e 'require("http").get(process.argv[1], () => process.exit(1)).on("error", () => process.exit(0));' "http://127.0.0.1:$port/" \
      && ok "and stops it afterwards" || bad "capture stops the app it started"
    cp "$captures/clean@1280x720.elements.json" "$work/first-map"; cp "$captures/clean@1280x720.png" "$work/first-png"
    out="$(bash tools/ui_capture.sh clean --state default --size 1280x720 2>&1)"; expect_status "captures one screen, state and size" 0 $? "$out"
    cmp -s "$captures/clean@1280x720.elements.json" "$work/first-map" && ok "a second capture gives the same element map" || bad "a second capture gives the same element map" "$out"
    cmp -s "$captures/clean@1280x720.png" "$work/first-png" && ok "and the same image" || bad "a second capture gives the same image"
    out="$(node "$helpers/validate.mjs" "$captures/clean.starter.excalidraw" clean 1280 720 "$app/tools/ui/drawing.mjs" 2>&1)"
    expect_output "a captured starter drawing is valid Excalidraw and reads back empty" "^VALID" "$out"

    # verify: a spec written from the capture matches it; moving one element 10% reports exactly it.
    node -e '
      const m = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
      const rows = m.elements.filter((e) => ["back", "hero-sheet", "gear-list", "change"].includes(e.id))
        .map((e, i) => `| ${i + 1} | ${e.id} | ${e.id} | ${e.rect_pct.join(", ")} | - | - | fit |`);
      require("fs").writeFileSync(process.argv[2], "# Hero room\n\n## Layout (at 1280x720)\n| # | Element | Name | Where (x, y, w, h %) | Shows | Does | Size |\n|---|---|---|---|---|---|---|\n" + rows.join("\n") + "\n");
    ' "$captures/clean@1280x720.elements.json" product/ui/clean.md
    mkdir -p "$work/director-ui" && cp "$captures/clean.starter.excalidraw" "$work/director-ui/clean.excalidraw"
    node tools/ui/drawing.mjs "$work/director-ui/clean.excalidraw" "$captures/clean.drawing.json" clean >/dev/null 2>&1
    out="$(bash tools/ui_capture.sh clean --verify --size 1280x720 2>&1)"; expect_status "verify passes a screen built as its spec says" 0 $? "$out"
    expect_output "with no deviations" "4 elements checked, 0 deviations" "$out"
    expect_output "a broken entry elsewhere in the catalog doesn't stop it" "note: another entry in tools/ui/screens.mjs has a problem: bad:" "$out"
    expect_output "it names the compare image" "compare image: product/ui/captures/clean.compare@1280x720.png" "$out"
    [ "$(od -An -tu1 -j16 -N8 "$captures/clean.compare@1280x720.png" 2>/dev/null | tr -s ' ' | sed 's/^ //;s/ $//')" = "0 0 10 8 0 0 2 208" ] \
      && ok "and writes it: the drawing's screenshot and the capture side by side (2568x720)" || bad "the compare image is the drawing's screenshot and the capture side by side (2568x720)" "$out"
    sed 's#<section class="panel" data-testid="hero-sheet">#<section class="panel" data-testid="hero-sheet" style="margin-left:128px">#' "$src/tests/ui-web/site/index.html" > uifixture/site/index.html
    out="$(bash tools/ui_capture.sh clean --verify --size 1280x720 2>&1)"; expect_status "verify fails a screen with an element moved 10%" 1 $? "$out"
    if [ "$(printf '%s\n' "$out" | grep -c '^ui_verify: | .* | moved: ')" = "1" ]; then
      expect_output "and reports exactly that element" "\| hero-sheet \| hero-sheet \| .* \| moved: left edge" "$out"
    else
      bad "verify reports exactly the moved element" "$out"
    fi
    cp "$src/tests/ui-web/site/index.html" uifixture/site/index.html

    # A capture killed mid-run leaves the app it started running; the next capture stops it first,
    # instead of taking it for an app the human started.
    answers() { node -e 'require("http").get(process.argv[1], () => process.exit(0)).on("error", () => process.exit(1));' "http://127.0.0.1:$port/"; }
    sed 's#^setup_timeout = .*#setup_timeout = 120#' "$work/fixture-cfg" > tools/ui_capture.cfg
    rm -f .app-director/state/ui_app.pid
    bash tools/ui_capture.sh stuck > "$work/stuck.log" 2>&1 &
    stuck_pid=$!
    waited=0
    # Killed once it is at work in the browser ("begin stuck@..." comes after Chromium has started), not while Chromium is starting:
    # a capture killed then leaves the browser running (T304). Whatever it left is stopped below, except the app.
    until [ -f .app-director/state/ui_app.pid ] && answers && grep -q 'begin stuck@' "$work/stuck.log" 2>/dev/null; do
      waited=$((waited + 1)); [ "$waited" -ge 60 ] && break; sleep 1
    done
    sleep 1
    app_pid="$(cut -d' ' -f1 .app-director/state/ui_app.pid 2>/dev/null)"
    capture_pid="$(cut -d' ' -f2 .app-director/state/ui_app.pid 2>/dev/null)"
    case "$(uname -s)" in
      MINGW*|MSYS*|CYGWIN*) taskkill //PID "$capture_pid" //F >/dev/null 2>&1 ;;
      *) kill -9 "$capture_pid" 2>/dev/null ;;
    esac
    wait "$stuck_pid" 2>/dev/null
    stop_orphans_of "$capture_pid" "$app_pid"
    sleep 1
    if answers; then ok "a capture killed mid-run leaves the app it started running"; else bad "a capture killed mid-run leaves the app it started running" "$(cat "$work/stuck.log")"; fi
    cp "$work/fixture-cfg" tools/ui_capture.cfg
    out="$(bash tools/ui_capture.sh clean --state default --size 1280x720 2>&1)"; expect_status "the next capture runs" 0 $? "$out"
    expect_output "it stops the app the killed capture left running" "stopping the app an interrupted capture left running" "$out"
    expect_output "and starts its own" "starting the app: node uifixture/serve.mjs $port" "$out"
    if answers; then bad "and stops it afterwards: nothing is left running" "$out"; else ok "and stops it afterwards: nothing is left running"; fi
    [ ! -f .app-director/state/ui_app.pid ] && ok "and clears its record of the app" || bad "capture clears its record of the app it started"

    sed -e "s#^base_url =.*#base_url = http://127.0.0.1:$((port + 1))#" -e 's#^start_command =.*#start_command = node -e "process.exit(4)"#' "$work/saved-ui-cfg" > tools/ui_capture.cfg
    out="$(bash tools/ui_capture.sh clean 2>&1)"; expect_status "exits 3 when the start command ends before the app answers" 3 $? "$out"
    expect_output "and says so, naming the app's output" "ended with exit 4 before the app answered at .* \(its output: \.app-director/state/ui_app\.log\)" "$out"
  fi
  cp "$work/saved-ui-cfg" tools/ui_capture.cfg; cp "$work/saved-catalog" tools/ui/screens.mjs; cp "$work/saved-check-cfg" tools/check.cfg
  rm -rf product/ui/captures product/ui/clean.md uifixture tools/ui/node_modules src/ui/screens
fi
}

# --- the run --------------------------------------------------------------------------------------
# The parts that need only the source start at once. part_main installs the example app and starts the ones that need it (app_parts).
part framework 1-framework
part release 1b-release
part orphans 1c-orphans
gitleaks_setup
part installer 2b-installer
part snapshot 2b-snapshot
part check_ts 2g-check-ts
part security 6-security
part stories 6b-stories
part session 4b-session
part prototype 7-prototype
part protospace 7b-protospace
part main 2-installer
wait
passed=0; failed=0
stopped=""
for name in framework release orphans main installer snapshot check1 check2 check3 check4 check5 check_ts guard hooks session commit ui_design security stories prototype protospace; do
  if [ -f "$seg/count-$name" ]; then read -r p f status < "$seg/count-$name"; else p=0; f=1; status="no count"; fi
  passed=$((passed + p)); failed=$((failed + f))
  [ "$status" = 0 ] || { failed=$((failed + 1)); stopped="$stopped$nl  FAIL  the $name part stopped early ($status)"; }
done
cat "$seg"/1-framework "$seg"/1b-release "$seg"/1c-orphans "$seg"/2-installer "$seg"/2b-installer "$seg"/2b-snapshot \
  "$seg"/2c-check1 "$seg"/2d-check2 "$seg"/2e-check3 "$seg"/2f-check4 "$seg"/2f2-check5 "$seg"/2g-check-ts "$seg"/3-guard "$seg"/4a-hooks "$seg"/4b-session "$seg"/4b-precommit \
  "$seg"/5-ui-design "$seg"/6-security "$seg"/6b-stories "$seg"/7-prototype "$seg"/7b-protospace
[ -z "$stopped" ] || printf '%s\n' "${stopped#"$nl"}"
finish
