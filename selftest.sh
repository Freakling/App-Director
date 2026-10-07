#!/usr/bin/env bash
# App Director self-test. Tests the installer, the project check, the hooks and the pre-commit
# hook using a temporary copy of examples/todo-web. No network access; no external tools required
# (the example uses the `none` stack). Run it after every change to the framework.
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

out="$(bash "$src/install.sh" . 2>&1)"
expect_output "a second run changes nothing" "0 new, 0 updated" "$out"
adir_lines="$(grep -c '^# App Director$' .gitignore 2>/dev/null || true)"
[ "${adir_lines:-0}" -le 1 ] \
  && ok "no duplicate .gitignore lines after reinstall" \
  || bad "no duplicate .gitignore lines after reinstall"

# Local edit that this version doesn't touch — must be kept as-is.
echo "# my own note" >> .app-director/procedures/prune.md
out="$(bash "$src/install.sh" . 2>&1)"
if grep -q "my own note" .app-director/procedures/prune.md \
    && [ ! -f .app-director/procedures/prune.md.adir-new ]; then
  ok "keeps a local edit when this version doesn't change the file"
else
  bad "keeps a local edit when this version doesn't change the file" "$out"
fi

# Simulate both sides changed — installer must write .adir-new.
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

inside="$work/inside"; new_repo "$inside"
cp -R "$adir_clone" "$inside/App-Director"; rm -rf "$inside/App-Director/.git"
printf '/App-Director/\n' >> "$inside/.git/info/exclude"
out="$(bash "$inside/App-Director/install.sh" "$inside" 2>&1)"
expect_status "installs from a folder inside the app" 0 $? "$out"

# Refuses a folder that isn't the repository root.
mkdir -p "$app/sub"
out="$(bash "$src/install.sh" "$app/sub" 2>&1)"
expect_status "refuses a non-root folder" 1 $? "$out"

cd "$app" || exit 1

# --- check ----------------------------------------------------------------------------------------
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

# Planted fake credential — value assembled at test time, file written only in temp dir, never committed.
# _cred_val is 32 hex zeros: matches check.sh's hex-secret pattern, clearly not a real key.
_cred_val="00000000000000000000000000000000"
cp src/services/TodoService.ts "$work/saved-svc"
{ printf '\n'; printf "const api_key = '%s';\n" "$_cred_val"; } >> src/services/TodoService.ts
out="$(bash tools/check.sh 2>&1)"
expect_status "fails on a planted secret" 1 $? "$out"
expect_output "names the file with the secret" "TodoService" "$out"
cp "$work/saved-svc" src/services/TodoService.ts

# Exit 3 when the configured stack script is missing.
cp tools/check.cfg "$work/saved-cfg"
printf '[project]\nstack = nonexistent\n' > tools/check.cfg
out="$(bash tools/check.sh 2>&1)"
expect_status "exits 3 when the stack script is missing" 3 $? "$out"
cp "$work/saved-cfg" tools/check.cfg

out="$(bash tools/check.sh 2>&1)"
expect_status "passes again after faults removed" 0 $? "$out"

# --- guard-commands hook --------------------------------------------------------------------------
echo "guard-commands hook"
guard() { # guard <expected-exit> <command>
  local escaped="${2//\\/\\\\}"
  escaped="${escaped//\"/\\\"}"
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
    'git branch -D topic'; do
  guard 2 "$cmd"
done
for cmd in \
    'git status --short' \
    'git commit -m "feat: add form (T4)" -- src/ui/TodoList.ts' \
    'git push origin feature-branch' \
    'git restore --staged src/ui/TodoList.ts' \
    'git checkout -b topic' \
    'git reset --soft HEAD~1' \
    'git switch main'; do
  guard 0 "$cmd"
done

# --- guard-protected hook -------------------------------------------------------------------------
echo "guard-protected hook"
guard_write() { # guard_write <expected-exit> <path>
  printf '{"file_path":"%s"}' "$2" | bash .claude/hooks/guard-protected.sh >/dev/null 2>&1
  local got=$?
  if [ "$got" -eq "$1" ]; then
    ok "$([ "$1" -eq 2 ] && echo blocks || echo allows): write to $2"
  else
    bad "guard-protected exit $got, expected $1: $2"
  fi
}
guard_write 2 "director/mockup.png"
guard_write 2 "director/notes.md"
guard_write 2 "director"
guard_write 0 "src/ui/TodoList.ts"
guard_write 0 "AGENTS.md"
guard_write 0 "TASKS.md"

# --- stop-check hook ------------------------------------------------------------------------------
echo "stop-check hook"
git add -A && { git_q commit -qm "clean state for hook tests" >/dev/null 2>&1 || true; }

stop_hook() {
  printf '{}' | CLAUDE_PROJECT_DIR="$app" bash .claude/hooks/stop-check.sh 2>&1
}
out="$(stop_hook)"; expect_status "does nothing when code is unchanged" 0 $? "$out"

{ printf '\n'; printf '// a harmless change\n'; } >> src/services/TodoService.ts
out="$(stop_hook)"; expect_status "lets a passing change through" 0 $? "$out"

cp src/services/TodoService.ts "$work/passing"
{ printf '\n'; printf "const api_key = '%s';\n" "$_cred_val"; } >> src/services/TodoService.ts
cp src/services/TodoService.ts "$work/failing"
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
cp "$work/passing" src/services/TodoService.ts
out="$(stop_hook)"; expect_status "lets the fixed state through" 0 $? "$out"

# --- pre-commit hook ------------------------------------------------------------------------------
echo "pre-commit hook"
bash tools/setup-clone.sh >/dev/null 2>&1
grep -qs "App Director" "$(git rev-parse --git-path hooks)/pre-commit" \
  && ok "setup-clone installs the pre-commit hook" \
  || bad "setup-clone installs the pre-commit hook"

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

# Blocked while a .adir-new file is unmerged.
printf 'x\n' > tools/check.sh.adir-new
printf '\n// another change\n' >> src/ui/TodoList.ts && git add src/ui/TodoList.ts
out="$(git_q commit -qm "with adir-new" 2>&1)"
expect_status "refuses while a .adir-new file is unmerged" 1 $? "$out"
rm -f tools/check.sh.adir-new

finish
