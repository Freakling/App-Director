#!/usr/bin/env bash
# App Director security tools · framework-owned: replaced on upgrade.
#
# Step 1 of the security assessment (.app-director/procedures/security.md): the tools that run before
# the reviewer pass. It never installs anything: a tool that isn't installed is skipped with a note.
#   bash tools/security.sh          run the tools: one line per tool, each tool's output in .app-director/state/security/
#   bash tools/security.sh --due    say whether an assessment is due: [security] every in tools/check.cfg (default 10)
#                                   built items (commits whose subject ends in "(T<n>)" or "(B<n>)", or that and a squash
#                                   merge's " (#<pr>)") since the newest report in product/security/; due when there is none
# Exit codes: 0 = no tool reported a finding (a skipped tool doesn't count) · 1 = a tool reported findings · 3 = couldn't run
#
# The tools:
#   1. Dependency audit, by the manifests found: npm audit --omit=dev (package-lock.json), pnpm audit --prod
#      (pnpm-lock.yaml), yarn's audit (yarn.lock), pip-audit (a requirements.txt with every package pinned by ==,
#      read without installing anything; otherwise skipped), dotnet list
#      <the .sln, or else the .csproj> package --vulnerable --include-transitive, and flutter pub outdated (pubspec.yaml) as
#      information only, since it isn't a vulnerability audit. Serves OWASP A03:2025 Software Supply Chain Failures.
#   2. The check's secrets scan and UI purity step (bash tools/check.sh --architecture). Serves A07:2025 and A01:2025.
#   3. Semgrep with the p/owasp-top-ten rules, when semgrep is installed. Each rule names its OWASP category.
# A clean run proves only that these tools found nothing they look for. It never marks a category met.

set -u
cd "$(dirname "$0")/.." || exit 3
mode="${1:-}"
state_dir=".app-director/state/security"
EVERY_DEFAULT=10
TOOL_LIMIT=240

# Read an ini-style check.cfg value: cfg_get <section> <key>
cfg_get() {
  local section="$1" key="$2" in_section=0 line k v
  [ -f tools/check.cfg ] || return 0
  while IFS= read -r line; do
    line="$(printf '%s' "$line" | tr -d '\r' | sed 's/[[:space:]]*;.*//')"
    case "$line" in
      "[$section]") in_section=1 ;;
      "["*"]") in_section=0 ;;
      *) if [ "$in_section" -eq 1 ]; then
           k="${line%%=*}"; v="${line#*=}"
           k="${k%"${k##*[! ]}"}"; v="${v#"${v%%[! ]*}"}"
           [ "$k" = "$key" ] && { printf '%s' "$v"; return; }
         fi ;;
    esac
  done < tools/check.cfg
}

# --- --due ----------------------------------------------------------------------------------------
# Built items: commit subjects ending in "(T<n>)" or "(B<n>)", also with a squash merge's " (#<pr>)" after it.
ITEM_RE='\((T|B)[0-9]+\)( \(#[0-9]+\))?$'
if [ "$mode" = "--due" ]; then
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "security: couldn't count: not a git repository"; exit 3; }
  [ "$(git rev-parse --is-shallow-repository 2>/dev/null)" = "true" ] \
    && echo "security: note: this is a shallow clone, so items before its oldest commit aren't counted"
  every="$(cfg_get security every)"
  case "$every" in
    ''|*[!0-9]*|0) [ -n "$every" ] && echo "security: note: [security] every = $every isn't a whole number of 1 or more; using $EVERY_DEFAULT"
                   every="$EVERY_DEFAULT" ;;
  esac
  latest=""
  for f in product/security/*.md; do
    case "${f##*/}" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].md) latest="$f" ;; esac
  done
  if [ -z "$latest" ]; then
    echo "security: due: no assessment yet (no report in product/security/), [security] every = $every"
    exit 0
  fi
  commit="$(sed -n 's/^- Commit:[[:space:]]*`\{0,1\}\([0-9a-fA-F]\{7,40\}\).*/\1/p' "$latest" | head -n 1)"
  if [ -n "$commit" ] && git cat-file -e "$commit^{commit}" 2>/dev/null; then
    count="$(git log --format=%s "$commit..HEAD" | grep -cE "$ITEM_RE")"
    since="$latest (commit $commit)"
  else
    day="${latest##*/}"; day="${day%.md}"
    count="$(git log --format=%s --since="${day}T00:00:00" | grep -cE "$ITEM_RE")"
    since="$latest (by its date: its commit isn't in this history)"
  fi
  if [ "$count" -ge "$every" ]; then
    echo "security: due: built items since $since: $count, [security] every = $every"
  else
    echo "security: not due: built items since $since: $count, [security] every = $every"
  fi
  exit 0
fi

[ -z "$mode" ] || { echo "usage: bash tools/security.sh [--due]"; exit 3; }
mkdir -p "$state_dir" || exit 3
# Corepack may otherwise download yarn or pnpm, or wait at a prompt. A tool it hasn't cached couldn't run.
export COREPACK_ENABLE_NETWORK=0 COREPACK_ENABLE_DOWNLOAD_PROMPT=0

FIND=find; [ -x /usr/bin/find ] && FIND=/usr/bin/find
SORT=sort; [ -x /usr/bin/sort ] && SORT=/usr/bin/sort
timeout_cmd=""
for candidate in timeout gtimeout; do
  if "$candidate" --version </dev/null 2>/dev/null | grep -qi coreutils; then timeout_cmd="$candidate"; break; fi
done

found=0; clean=0; skipped=0
out_file=""

# run_tool <name> <command...>: run it under the time limit, its output to the state folder; sets rc.
run_tool() {
  out_file="$state_dir/$1.txt"; shift
  if [ -n "$timeout_cmd" ]; then "$timeout_cmd" "$TOOL_LIMIT" "$@" </dev/null > "$out_file" 2>&1; else "$@" </dev/null > "$out_file" 2>&1; fi
  rc=$?
}
skip() { skipped=$((skipped + 1)); echo "security: $1: skipped: $2"; }
last_line() { tr -d '\r' < "$out_file" | grep -v '^[[:space:]]*$' | tail -n 1; }
# why: the reason a tool couldn't run, from its output: the first line that names an error (a network
# or restore failure), else its last line.
why() {
  local l; l="$(tr -d '\r' < "$out_file" | grep -m 1 -iE 'error|fail|unable|could not|timed out|ENOTFOUND|ETIMEDOUT|ECONNREFUSED|EAI_AGAIN' | sed 's/^[[:space:]]*//')"
  if [ -n "$l" ]; then printf '%s' "$l"; else last_line; fi
}
# couldnt <label> [reason]: the tool didn't exit 0 with its clean or finding output, or hit its time limit (124)
couldnt() {
  skipped=$((skipped + 1))
  if [ "$rc" -eq 124 ] && [ -n "$timeout_cmd" ]; then
    echo "security: $1: couldn't run: no result within $TOOL_LIMIT s (output in $out_file)"
  else
    echo "security: $1: couldn't run: ${2:-$(why)} (output in $out_file)"
  fi
}

A03="OWASP A03:2025 Software Supply Chain Failures"

# Classify a JavaScript package manager's audit output.
js_audit() { # <label> <name> <command...>
  local label="$1" name="$2"; shift 2
  run_tool "$name" "$@"
  local text; text="$(tr -d '\r' < "$out_file")"
  # Clean only when the audit exits 0 with its nothing-found output; that text with a non-zero exit is a failed run.
  if [ "$rc" -eq 0 ] && printf '%s\n' "$text" | grep -qE '^found 0 vulnerabilities|No known vulnerabilities found|^0 vulnerabilities found|No audit suggestions'; then
    clean=$((clean + 1)); echo "security: $label: clean"
  elif printf '%s\n' "$text" | grep -qE '[0-9]+ (info|low|moderate|high|critical) severity vulnerabilit|[0-9]+ vulnerabilit(y|ies) found|^[0-9]+ vulnerabilities \(|^Severity: '; then
    found=$((found + 1))
    echo "security: $label: FINDINGS ($A03): $(printf '%s\n' "$text" | grep -E 'severity vulnerabilit|vulnerabilit(y|ies) found|^[0-9]+ vulnerabilities \(' | head -n 1)"
    printf '%s\n' "$text" | grep -E '^[@A-Za-z0-9][^ ]*  +[^ ]' | awk '!seen[$1]++ { print "  package: " $1 " " $2 }'
  else
    couldnt "$label"
  fi
}

# --- 1. Dependency audit --------------------------------------------------------------------------
deps=0
if [ -f package-lock.json ]; then
  deps=1
  if command -v npm >/dev/null 2>&1; then js_audit "dependencies (npm audit --omit=dev)" npm-audit npm audit --omit=dev
  else skip "dependencies (npm audit)" "npm isn't installed"; fi
elif [ -f pnpm-lock.yaml ]; then
  deps=1
  if command -v pnpm >/dev/null 2>&1; then js_audit "dependencies (pnpm audit --prod)" pnpm-audit pnpm audit --prod
  else skip "dependencies (pnpm audit)" "pnpm isn't installed"; fi
elif [ -f yarn.lock ]; then
  deps=1
  if command -v yarn >/dev/null 2>&1; then
    case "$(yarn --version </dev/null 2>/dev/null)" in
      1.*) js_audit "dependencies (yarn audit --groups dependencies)" yarn-audit yarn audit --groups dependencies ;;
      *)   js_audit "dependencies (yarn npm audit --environment production)" yarn-audit yarn npm audit --environment production ;;
    esac
  else skip "dependencies (yarn audit)" "yarn isn't installed"; fi
elif [ -f package.json ]; then
  deps=1
  skip "dependencies (npm audit)" "no lock file (package-lock.json, pnpm-lock.yaml or yarn.lock) to audit"
fi

if [ -f requirements.txt ] || [ -f pyproject.toml ]; then
  deps=1
  label="dependencies (pip-audit)"
  # pip-audit only reads pinned requirements here (--disable-pip --no-deps): resolving anything else
  # makes it build a virtual environment and pip-install the packages, which runs their build code.
  unpinned=""
  if [ -f requirements.txt ]; then
    unpinned="$(tr -d '\r' < requirements.txt | sed 's/[[:space:]]#.*//; s/^#.*//' | grep -v '^[[:space:]]*$' \
      | grep -vE '^[[:space:]]+--hash=' \
      | grep -vE '^[A-Za-z0-9][A-Za-z0-9._-]*(\[[A-Za-z0-9._,-]+\])?[[:space:]]*==[[:space:]]*[A-Za-z0-9.!+_-]+[[:space:]]*(;.*)?(\\|[[:space:]]+--hash=.*)?$' | head -n 1)"
  fi
  if [ ! -f requirements.txt ]; then
    skip "$label" "only pyproject.toml: export pinned requirements (every package ==, such as from your lock file) to requirements.txt, so they're audited without installing them"
  elif [ -n "$unpinned" ]; then
    skip "$label" "requirements.txt has a requirement that isn't pinned with == ($unpinned), and auditing it would install packages and run their build code"
  elif command -v pip-audit >/dev/null 2>&1; then
    run_tool pip-audit pip-audit --progress-spinner off --disable-pip --no-deps -r requirements.txt
    if [ "$rc" -eq 0 ] && grep -q 'No known vulnerabilities found' "$out_file"; then clean=$((clean + 1)); echo "security: $label: clean"
    elif grep -qE 'Found [0-9]+ known vulnerabilit' "$out_file"; then
      found=$((found + 1)); echo "security: $label: FINDINGS ($A03): $(grep -E 'Found [0-9]+ known vulnerabilit' "$out_file" | head -n 1 | tr -d '\r')"
    else couldnt "$label"; fi
  else skip "$label" "pip-audit isn't installed (https://pypi.org/project/pip-audit/)"; fi
fi

dotnet_find() { "$FIND" . -maxdepth 3 \( -name node_modules -o -name .git \) -prune -o -name "$1" -print 2>/dev/null | "$SORT" | head -n 1; }
dotnet_project="$(dotnet_find '*.sln')"
[ -n "$dotnet_project" ] || dotnet_project="$(dotnet_find '*.csproj')"
if [ -n "$dotnet_project" ]; then
  deps=1
  label="dependencies (dotnet list $dotnet_project package --vulnerable --include-transitive)"
  if command -v dotnet >/dev/null 2>&1; then
    run_tool dotnet-vulnerable dotnet list "$dotnet_project" package --vulnerable --include-transitive
    if grep -q 'has the following vulnerable packages' "$out_file"; then
      found=$((found + 1)); echo "security: $label: FINDINGS ($A03): see $out_file"
    elif [ "$rc" -eq 0 ] && grep -q 'has no vulnerable packages' "$out_file"; then clean=$((clean + 1)); echo "security: $label: clean"
    else couldnt "$label"; fi
  else skip "$label" "dotnet isn't installed"; fi
fi

if [ -f pubspec.yaml ]; then
  deps=1
  label="dependencies (flutter pub outdated)"
  if command -v flutter >/dev/null 2>&1; then
    run_tool flutter-outdated flutter pub outdated
    if [ "$rc" -eq 0 ]; then
      skipped=$((skipped + 1))
      echo "security: $label: information only, not a vulnerability audit: check the outdated packages in $out_file against their advisories"
    else couldnt "$label"; fi
  else skip "$label" "flutter isn't installed"; fi
fi
[ "$deps" -eq 1 ] || skip "dependencies" "no manifest this script audits (package-lock.json, pnpm-lock.yaml, yarn.lock, requirements.txt, pyproject.toml, .csproj, .sln, pubspec.yaml)"

# --- 2. Secrets and UI purity (the check's own steps) ---------------------------------------------
label="secrets and UI purity (bash tools/check.sh --architecture)"
if [ -f tools/check.sh ]; then
  run_tool check-architecture bash tools/check.sh --architecture
  case "$rc" in
    0) if grep -q 'check: PASS' "$out_file"; then clean=$((clean + 1)); echo "security: $label: clean"
       else couldnt "$label" "exit 0 without the check's PASS line"; fi ;;
    1) found=$((found + 1)); echo "security: $label: FINDINGS (the OWASP item is on each line):"
       tr -d '\r' < "$out_file" | grep -E 'FAIL|found in:|^  [^ ]' | grep -vF 'FAIL (architecture only)' | sed 's/^ */  /' ;;
    *) couldnt "$label" "$(tr -d '\r' < "$out_file" | grep -m 1 'FAIL' | sed 's/^ *//')" ;;
  esac
else
  skip "$label" "tools/check.sh isn't here"
fi

# --- 3. Semgrep -----------------------------------------------------------------------------------
label="semgrep (p/owasp-top-ten)"
if command -v semgrep >/dev/null 2>&1; then
  # Only path:line:col:rule is kept and printed, never the message or a matched line, so a secret in
  # the source isn't copied into the state folder or the console.
  out_file="$state_dir/semgrep.txt"
  if [ -n "$timeout_cmd" ]; then raw="$("$timeout_cmd" "$TOOL_LIMIT" semgrep scan --config p/owasp-top-ten --metrics=off --quiet --error --emacs . </dev/null 2>&1)"
  else raw="$(semgrep scan --config p/owasp-top-ten --metrics=off --quiet --error --emacs . </dev/null 2>&1)"; fi
  rc=$?
  hits="$(printf '%s\n' "$raw" | tr -d '\r' | sed -n 's/^\([^:][^:]*:[0-9][0-9]*:[0-9][0-9]*\):[^(:]*(\([^)]*\)).*/\1:\2/p')"
  if [ -n "$hits" ]; then printf '%s\n' "$hits" > "$out_file"
  else printf '%s\n' "$raw" | tr -d '\r' | grep -vE '^[^:]+:[0-9]+:[0-9]+:' > "$out_file"; fi
  raw=""
  if [ "$rc" -eq 0 ] && [ -z "$hits" ]; then clean=$((clean + 1)); echo "security: $label: clean"
  elif [ -n "$hits" ]; then
    found=$((found + 1)); echo "security: $label: FINDINGS (the OWASP item is in each rule's metadata):"
    printf '%s\n' "$hits" | sed 's/^/  /'
  else couldnt "$label"; fi
else
  skip "$label" "semgrep isn't installed (https://semgrep.dev/docs/getting-started/)"
fi

echo "security: tools: $found with findings, $clean clean, $skipped skipped or information only. A tool passing never marks an OWASP category met; the reviewer pass follows (.app-director/procedures/security.md)."
[ "$found" -eq 0 ] || exit 1
exit 0
