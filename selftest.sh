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
if [ "${KEEP:-0}" = "1" ]; then echo "keeping $work"; else trap 'rm -rf "$work"' EXIT; fi

passed=0; failed=0
nl='
'

ok()  { passed=$((passed + 1)); echo "  ok    $1"; }
bad() { failed=$((failed + 1)); echo "  FAIL  $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | tail -n 15 | sed 's/^/          /'; }
expect_status() { # <what> <expected> <actual> [output]
  if [ "$3" -eq "$2" ]; then ok "$1"; else bad "$1 (exit $3, expected $2)" "${4:-}"; fi
}
expect_output() { # <what> <pattern> <output>
  if printf '%s' "$3" | grep -qE -- "$2"; then ok "$1"; else bad "$1 (no match for /$2/)" "$3"; fi
}
expect_no_output() { # <what> <pattern> <output>
  if printf '%s' "$3" | grep -qE -- "$2"; then bad "$1 (unexpected /$2/)" "$3"; else ok "$1"; fi
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

# --- framework files ------------------------------------------------------------------------------
echo "framework"

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
  name="$(basename "$(dirname "$skill")")"
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
settings="$src/framework/.claude/settings.json"
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
  name="$(basename "$proc")"
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
deny_needs() { # deny_needs <settings file> <allow rule pattern> <deny rule>...: the deny rules it lacks, when it allows that rule
  local file="$1" pattern="$2" rule deny
  sed -n '/"allow": *\[/,/\]/p' "$file" | grep -qE "$pattern" || return 0
  deny="$(sed -n '/"deny": *\[/,/\]/p' "$file")"
  shift 2
  for rule in "$@"; do
    printf '%s\n' "$deny" | grep -qF "\"$rule\"" || printf '%s\n' "$rule"
  done
}
git_deny_missing() { # git_deny_missing <settings file>: the deny rules it lacks, for each wildcard rule it allows
  deny_needs "$1" '"Bash\(git (diff|log|show|stash|commit) \*\)"' \
    'Bash(git *--output*)' 'Bash(git *--no-index*)' 'Bash(git *--ext-diff*)' 'Bash(git commit *--file*)'
  deny_needs "$1" '"Bash\(git grep \*\)"' 'Bash(git grep *--open*)' 'Bash(git grep *-O*)'
  deny_needs "$1" '"Bash\(git tag \*\)"' 'Bash(git tag *--file*)'
  deny_needs "$1" '"Bash\(bash tools/[^"]*\*' 'Bash(bash tools/*..*)'
}
read_deny_missing() { # read_deny_missing <settings file>: the credential-store and .env Read rules it doesn't deny
  local rule deny
  deny="$(sed -n '/"deny": *\[/,/\]/p' "$1")"
  for rule in 'Read(~/.ssh/**)' 'Read(~/.git-credentials)' 'Read(~/.config/git/credentials)' \
      'Read(~/.config/gh/**)' 'Read(~/AppData/Roaming/GitHub CLI/**)' \
      'Read(.env.local)' 'Read(**/.env.local)' 'Read(.env.*.local)' 'Read(**/.env.*.local)' \
      'Read(.env.development)' 'Read(**/.env.development)' 'Read(.env.production)' 'Read(**/.env.production)' \
      'Read(.env.staging)' 'Read(**/.env.staging)' 'Read(.env.test)' 'Read(**/.env.test)'; do
    printf '%s\n' "$deny" | grep -qF "\"$rule\"" || printf '%s\n' "$rule"
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
grep -qx '/product/ui/captures/' .gitignore && grep -qx '/tools/ui/node_modules/' .gitignore && grep -qx '/tools/ui/.auth/' .gitignore \
  && grep -qx '/tools/ui/\*\* text eol=lf' .gitattributes \
  && ok "ignores captures, the capture tools' packages and saved sign-ins" || bad "the /ui-design .gitignore and .gitattributes lines" "$(cat .gitignore)"
# The personal settings file is ignored, as the README says. `*.local` doesn't reach it (its name ends in .json).
git check-ignore -q .claude/settings.local.json && ok "ignores .claude/settings.local.json, the personal settings file" \
  || bad "ignores .claude/settings.local.json, the personal settings file" "$(cat .gitignore)"
grep -q "$(printf '\t')tools/ui/capture.mjs$" .app-director/manifest && ! grep -q "$(printf '\t')tools/ui/screens.mjs$" .app-director/manifest \
  && ok "the manifest lists the capture tools, not the app's own catalog" || bad "the manifest lists the capture tools, not the app's own catalog"

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

# Installs from a cloned App Director folder and from one inside the app.
adir_clone="$work/adir-clone"; cp -R "$src" "$adir_clone"; rm -rf "$adir_clone/.git"
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
cp -R "$adir_clone" "$inside/App-Director"; rm -rf "$inside/App-Director/.git"
printf '/App-Director/\n' >> "$inside/.git/info/exclude"
out="$(bash "$inside/App-Director/install.sh" "$inside" 2>&1)"
expect_status "installs from a folder inside the app" 0 $? "$out"

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
mkdir -p "$app/sub"
out="$(bash "$src/install.sh" "$app/sub" 2>&1)"
expect_status "refuses a non-root folder" 1 $? "$out"

cd "$app" || exit 1

# --- check ----------------------------------------------------------------------------------------
echo "check"

# Add a selftest detection rule to .gitleaks.toml so the planted marker is caught regardless of
# entropy. The marker string is assembled at test time and never stored in this file.
_gl_rule_id="selftest-marker"
_gl_marker_name="ADIR_SELFTEST_CRED"
cat >> .gitleaks.toml << EOF

[[rules]]
id = "$_gl_rule_id"
description = "App Director selftest marker; remove before production."
regex = '''${_gl_marker_name}\\s*=\\s*['"]([A-Za-z0-9+/]{16,})['"]'''
secretGroup = 1
EOF

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

# Scan command by gitleaks version, with a test double, so it runs without real gitleaks: the double
# reports $FAKE_GL_VERSION, scans with $FAKE_GL_SCAN, writes one finding in gitleaks' report layout
# and exits 1 (leaks found). Regression: gitleaks 8.18 has no working `dir`, so check.sh must scan
# with `detect --no-git` there and use `dir` from 8.19.1. Either way the output names the file.
_scan_gl="$work/fake-gl-scan"
mkdir -p "$_scan_gl"
cat > "$_scan_gl/gitleaks" << 'FAKE'
#!/usr/bin/env bash
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
#!/usr/bin/env bash
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
# (including the fake one when we set it up, so this path contains neither).
_no_gl_path=""
for _gl_dir in $(printf '%s' "$PATH" | tr ':' '\n'); do
  [ -x "$_gl_dir/gitleaks" ] || _no_gl_path="${_no_gl_path:+$_no_gl_path:}$_gl_dir"
done
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
  printf '[project]\nstack = failing\n[gitleaks]\nmin-version = 8.18.0\n[tests]\ntimeout = 1\n' > tools/check.cfg
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

# --if-changed repeats a result only while gitleaks is the one it ran with. A changed version (even
# the 8.19.0 that can't scan) or a removed gitleaks runs the secrets step again. The stand-in logs each
# call, and a reused pass calls `gitleaks version` once and nothing else.
_cache_gl="$work/fake-gl-cache"
_cache_log="$work/fake-gl-cache.log"
mkdir -p "$_cache_gl"
cat > "$_cache_gl/gitleaks" << 'FAKE'
#!/usr/bin/env bash
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

# --- guard-commands hook --------------------------------------------------------------------------
echo "guard-commands hook"
guard() { # guard <expected-exit> <command>
  local escaped="${2//\\/\\\\}"
  escaped="${escaped//\"/\\\"}"; escaped="${escaped//$'\n'/\\n}"; escaped="${escaped//$'\t'/\\t}"
  printf '{"session_id":"s","tool_name":"Bash","tool_input":{"command":"%s","description":"run"}}' \
    "$escaped" | bash .claude/hooks/guard-commands.sh >/dev/null 2>&1
  local got=$?
  if [ "$got" -eq "$1" ]; then
    ok "$([ "$1" -eq 2 ] && echo blocks || echo allows): $2"
  else
    bad "guard exit $got, expected $1: $2"
  fi
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
    'cat .env.example'; do
  guard 0 "$cmd"
done
for cmd in \
    $'python3 - <<\'EOF\' 2>/dev/null || echo "no python"\nEOF' \
    $'python - <<EOF\nEOF' \
    $'py.exe - <<-"EOF"\n  EOF' \
    $'python3 - <<\'EOF\' 2>/dev/null || python - <<\'EOF2\'\nEOF\nprint(1)\nEOF2' \
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
    $'python3 - <<\'EOF\'\nprint("hi")\nEOF' \
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
    'grep -n ssh ONBOARDING.md' \
    'git log --oneline -3' \
    'ls ~/.ssh' \
    'gh auth status'; do
  guard 0 "$cmd"
done
grep -q '"matcher": "Bash|Monitor"' .claude/settings.json && ok "the guard is wired to Monitor too" || bad "the guard is wired to Monitor too"
grep -q "Commands that may run long" .app-director/rules.md && grep -q "run_in_background" .app-director/rules.md \
  && grep -q "empty heredoc" .app-director/rules.md && ok "rules.md gives the time-limit, background and empty-heredoc rules" \
  || bad "rules.md gives the time-limit, background and empty-heredoc rules"

# --- guard-protected hook -------------------------------------------------------------------------
echo "guard-protected hook"
# Claude Code sends the path as given: relative, absolute POSIX, or Windows (JSON-escaped). The
# project root is $CLAUDE_PROJECT_DIR (the Windows cases pass a made-up root; the hook only reads text).
guard_write() { # guard_write <expected exit> <what> <file_path as sent (JSON-escaped)> [project dir]
  local out got
  out="$(printf '{"session_id":"s","tool_name":"Write","tool_input":{"file_path":"%s","content":"x"}}' "$3" \
    | CLAUDE_PROJECT_DIR="${4:-$app}" bash .claude/hooks/guard-protected.sh 2>&1)"
  got=$?
  if [ "$got" -eq "$1" ]; then ok "$([ "$1" -eq 2 ] && echo blocks || echo allows): $2"; else bad "guard-protected exit $got, expected $1: $2" "$out"; fi
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

out="$(bash tools/check.sh --if-changed 2>&1)"; status=$?
expect_status "--if-changed repeats a failure without rerunning" 1 "$status" "$out"
expect_output "says the failing state is unchanged" "nothing changed" "$out"

rm -f .app-director/state/last-reported
: > .app-director/state/building
out="$(stop_hook)"; expect_status "leaves a builder's half-built files alone" 0 $? "$out"
rm -f .app-director/state/building

out="$(stop_hook)"; expect_status "blocks again once the builder is done" 2 $? "$out"
cp "$work/stop-passing" src/ui/TodoList.ts
out="$(stop_hook)"; expect_status "lets the fixed state through" 0 $? "$out"

# --- pre-commit hook ------------------------------------------------------------------------------
echo "pre-commit hook"
# PATH already includes gitleaks (real or fake) from the check section export above.
# setup-clone refuses gitleaks 8.19.0 before it installs the hook. With 8.19.0 on the machine's PATH the
# check expects that refusal, run on the real PATH (the 8.18.0 stand-in would hide the 8.19.0). The hook
# is then installed with the stand-in for the tests below. Otherwise the check expects the hook.
_hook="$(git rev-parse --git-path hooks)/pre-commit"
if [ "$_gl_path_ver" = "8.19.0" ]; then
  out="$(PATH="$_real_path" bash tools/setup-clone.sh 2>&1)"
  expect_status "setup-clone refuses the gitleaks 8.19.0 on PATH" 3 $? "$out"
  expect_output "setup-clone says 8.19.0 can't scan and asks for 8.19.1" "8.19.0 can't scan.*8.19.1" "$out"
  [ ! -f "$_hook" ] && ok "setup-clone installs no pre-commit hook for the gitleaks 8.19.0 on PATH" \
    || bad "setup-clone installs no pre-commit hook for the gitleaks 8.19.0 on PATH"
  bash tools/setup-clone.sh >/dev/null 2>&1
else
  bash tools/setup-clone.sh >/dev/null 2>&1
  grep -qs "App Director" "$_hook" \
    && ok "setup-clone installs the pre-commit hook" \
    || bad "setup-clone installs the pre-commit hook"
fi

# Stand-in gitleaks 8.19.0 (every command fails, as the real one does) in a fresh repository: setup-clone
# refuses it and installs no hook, whatever gitleaks the machine has.
_refuse_gl="$work/fake-gl-refuse"
mkdir -p "$_refuse_gl"
cat > "$_refuse_gl/gitleaks" << 'FAKE'
#!/usr/bin/env bash
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
[ ! -f "$_refuse/.git/hooks/pre-commit" ] && ok "stand-in 8.19.0: setup-clone installs no pre-commit hook" \
  || bad "stand-in 8.19.0: setup-clone installs no pre-commit hook"

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

# Stand-in for gitleaks: protect writes one finding, or exits 1 with no report (FAKE_GL_PROTECT=error),
# as gitleaks 8.19.0 does for every scan. The check's dir and detect scans find nothing.
_hook_gl="$work/fake-gl-hook"
mkdir -p "$_hook_gl"
cat > "$_hook_gl/gitleaks" << 'FAKE'
#!/usr/bin/env bash
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
  upgraded="$work/upgraded"
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
    rm -rf uifixture && cp -R "$src/tests/ui-web" uifixture && rm -rf uifixture/node_modules
    port=$((40000 + $$ % 20000))
    sed -e "s#^base_url =.*#base_url = http://127.0.0.1:$port#" -e "s#^start_command =.*#start_command = node uifixture/serve.mjs $port#" \
      -e 's#^list = .*#list = 1280x720 800x600#' -e 's#^setup_timeout = .*#setup_timeout = 3#' "$work/saved-ui-cfg" > tools/ui_capture.cfg
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
    out="$(bash tools/ui_capture.sh --all 2>&1)"; status=$?
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
    expect_output "a state that doesn't finish fails only its screen" "FAIL: stuck@1280x720: the setup didn't finish within 3 seconds" "$out"
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
    cp tools/ui_capture.cfg "$work/fixture-cfg"
    sed 's#^setup_timeout = .*#setup_timeout = 120#' "$work/fixture-cfg" > tools/ui_capture.cfg
    rm -f .app-director/state/ui_app.pid
    bash tools/ui_capture.sh stuck > "$work/stuck.log" 2>&1 &
    waited=0
    until [ -f .app-director/state/ui_app.pid ] && answers; do
      waited=$((waited + 1)); [ "$waited" -ge 60 ] && break; sleep 1
    done
    sleep 1
    capture_pid="$(cut -d' ' -f2 .app-director/state/ui_app.pid 2>/dev/null)"
    case "$(uname -s)" in
      MINGW*|MSYS*|CYGWIN*) taskkill //PID "$capture_pid" //F >/dev/null 2>&1 ;;
      *) kill -9 "$capture_pid" 2>/dev/null ;;
    esac
    wait 2>/dev/null
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
#!/usr/bin/env bash
[ "$1" = "audit" ] || exit 0
printf '# npm audit report\n\nlodash  <=4.17.20\nSeverity: high\nPrototype Pollution in lodash\nnode_modules/lodash\n\n3 vulnerabilities (1 moderate, 2 high)\n'
exit 1
FAKE
cat > "$_sec_bin/offline/npm" << 'FAKE'
#!/usr/bin/env bash
printf 'npm error code ENOTFOUND\nnpm error audit endpoint returned an error\n'
exit 1
FAKE
cat > "$_sec_bin/semgrep/semgrep" << 'FAKE'
#!/usr/bin/env bash
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
#!/usr/bin/env bash
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

finish
