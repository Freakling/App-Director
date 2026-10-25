#!/usr/bin/env bash
# App Director project check · framework-owned: replaced on upgrade.
#
# The single definition of "it works":
#   bash tools/check.sh                    run the check
#   bash tools/check.sh --if-changed       repeat the last result at once if these exact files were checked with this gitleaks
#   bash tools/check.sh --fingerprint      print the fingerprint of the current files (for hooks)
#   bash tools/check.sh --architecture     run only the UI purity and secrets checks (fast, no build)
# Exit codes: 0 = pass · 1 = fail · 3 = couldn't run (gitleaks missing, old or unable to scan, stack tool missing, or a test run hit its time limit)
#
# Steps:
#   1. UI purity: scan UI-layer files for imports from data-layer folders (serves OWASP Broken Access
#      Control: no direct data access from UI code).
#   2. Secrets (serves OWASP Authentication Failures: no credentials in source): run gitleaks dir --redact on the working tree (detect --no-git before 8.19.1;
#      8.19.0 can't scan at all, so the check exits 3).
#   3. Stack check: source tools/stacks/<stack>.sh and run it.
#   4. Custom: run tools/check.local.sh, if the project has one.
#
# Settings are in tools/check.cfg. State is cached in .app-director/state/.
# The stack check and tools/check.local.sh are each limited to [tests] timeout seconds from tools/check.cfg
# (default 600; CHECK_TIMEOUT overrides it) when GNU timeout (or gtimeout) is available; a run that hits
# the limit exits 3, unless a failure was already seen (then it exits 1).
# gitleaks minimum version is read from check.cfg [gitleaks] min-version (default 8.18.0).

set -u
cd "$(dirname "$0")/.." || exit 3
mode="${1:-}"
state_dir=".app-director/state"
GITLEAKS_MIN_DEFAULT="8.18.0"

# Read an ini-style check.cfg value: cfg_get <section> <key>
cfg_get() {
  local section="$1" key="$2" in_section=0
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

# version_gte <installed> <minimum> → 0 if installed >= minimum
version_gte() {
  local inst="$1" min="$2" ia ib ic ma mb mc rest
  ia="${inst%%.*}"; rest="${inst#*.}"; ib="${rest%%.*}"; ic="${rest#*.}"
  ma="${min%%.*}"; rest="${min#*.}"; mb="${rest%%.*}"; mc="${rest#*.}"
  ia="${ia:-0}"; ib="${ib:-0}"; ic="${ic:-0}"
  ma="${ma:-0}"; mb="${mb:-0}"; mc="${mc:-0}"
  [ "$ia" -gt "$ma" ] && return 0
  [ "$ia" -lt "$ma" ] && return 1
  [ "$ib" -gt "$mb" ] && return 0
  [ "$ib" -lt "$mb" ] && return 1
  [ "$ic" -ge "$mc" ]
}

# Hash of every file that can change the result.
fingerprint() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  local paths
  paths="$(git -c core.quotePath=false ls-files -z -c -o --exclude-standard 2>/dev/null \
    | tr '\0' '\n' \
    | grep -v -E '^(node_modules/|dist/|build/|\.dart_tool/|__pycache__/)' \
    | grep -E '\.(ts|tsx|js|jsx|mjs|dart|py|json|yaml|yml)$|^tools/check\.(cfg|sh|local\.sh)$|^\.gitleaks(\.toml|ignore)$' \
    | while IFS= read -r p; do [ -f "$p" ] && printf '%s\n' "$p"; done)"
  [ -n "$paths" ] || return 0
  { printf '%s\n' "$paths"; printf '%s\n' "$paths" | git hash-object --no-filters --stdin-paths; } \
    | git hash-object --stdin
}

if [ "$mode" = "--fingerprint" ]; then fingerprint; exit 0; fi
mkdir -p "$state_dir" || exit 3
before="$(fingerprint)"

# gitleaks's version, or "missing". Read once: the cached result depends on it (cache_key), and the
# secrets step uses it, so a run calls `gitleaks version` at most once.
gl_ver="missing"
if command -v gitleaks >/dev/null 2>&1; then
  gl_ver="$(gitleaks version 2>/dev/null | tr -d 'v \r\n')"
fi

# What a cached result stands for: the files' fingerprint and gitleaks's version. A removed or changed
# gitleaks makes the cache miss, so --if-changed runs the secrets step again.
cache_key() { printf '%s gitleaks=%s' "$1" "$gl_ver"; }

reuse_last() {
  [ "$mode" = "--if-changed" ] && [ -n "$before" ] || return 0
  local key
  key="$(cache_key "$before")"
  if [ "$(cat "$state_dir/last-pass" 2>/dev/null)" = "$key" ]; then
    echo "check: PASS (nothing changed since the last passing run)"
    exit 0
  fi
  if [ "$(cat "$state_dir/last-fail" 2>/dev/null)" = "$key" ]; then
    echo "check: FAIL (nothing changed since the last failing run; run 'bash tools/check.sh' to see why)"
    exit 1
  fi
}
reuse_last

failed=0
arch_only=0
[ "$mode" = "--architecture" ] && arch_only=1

# --- 1. UI purity check ---------------------------------------------------------------------------
ui_dirs="$(cfg_get ui dirs)"
data_dirs="$(cfg_get data dirs)"
skip_dirs="$(cfg_get scan skip)"

if [ -n "$ui_dirs" ] && [ -n "$data_dirs" ]; then
  echo "check: UI purity"
  FIND=find; [ -x /usr/bin/find ] && FIND=/usr/bin/find
  # Build grep pattern for data-layer imports
  data_pattern=""
  for d in $data_dirs; do
    d="${d#./}"; d="${d%/}"
    if [ -z "$data_pattern" ]; then
      data_pattern="$d"
    else
      data_pattern="$data_pattern|$d"
    fi
  done

  if [ -n "$data_pattern" ]; then
    violations="$("$FIND" $ui_dirs -type f \( -name "*.ts" -o -name "*.tsx" -o -name "*.js" -o -name "*.jsx" -o -name "*.dart" -o -name "*.py" \) 2>/dev/null \
      | while IFS= read -r f; do
          if grep -lE "from ['\"](\.\./)+.*($data_pattern)" "$f" 2>/dev/null; then
            printf '%s\n' "$f"
          fi
        done)"
    if [ -n "$violations" ]; then
      echo "check: UI purity FAIL (OWASP Broken Access Control, direct data access from UI code): data-layer imports in UI files:"
      printf '%s\n' "$violations" | sed 's/^/  /'
      failed=1
    fi
  fi
fi

# --- 2. Secrets check (gitleaks) ------------------------------------------------------------------
echo "check: secrets"
gl_min="$(cfg_get gitleaks min-version)"
gl_min="${gl_min:-$GITLEAKS_MIN_DEFAULT}"

if [ "$gl_ver" = "missing" ]; then
  echo "check: secrets FAIL: gitleaks not found (need >= $gl_min)."
  echo "       Install: https://github.com/gitleaks/gitleaks#installing"
  echo "       macOS:   brew install gitleaks"
  echo "       Linux:   https://github.com/gitleaks/gitleaks/releases"
  echo "       Windows: winget install gitleaks  or  choco install gitleaks"
  echo "       Then run: bash tools/setup-clone.sh"
  exit 3
fi

if ! version_gte "$gl_ver" "$gl_min"; then
  echo "check: secrets FAIL: gitleaks $gl_ver is below minimum $gl_min."
  echo "       Upgrade: https://github.com/gitleaks/gitleaks#installing"
  exit 3
fi

gl_report="$state_dir/gitleaks.json"
# gitleaks 8.19.1 is the first release whose `dir` command works; 8.18 scans the folder with
# `detect --no-git`. Both write the same JSON report (a File and a Fingerprint per finding).
# gitleaks 8.19.0 can't scan at all: every command fails with "flag accessed but not defined: source"
# and writes no report. So a failed scan that left no finding in the report is "couldn't scan"
# (exit 3), never "credentials found". The scan's output is kept for that message.
gl_scan() {
  rm -f "$gl_report"
  if version_gte "$gl_ver" 8.19.1; then
    gitleaks dir --redact --report-path="$gl_report" . 2>&1
  else
    gitleaks detect --no-git --redact --report-path="$gl_report" --source . 2>&1
  fi
}
gl_out="$(gl_scan)"; gl_rc=$?
if [ "$gl_rc" -eq 0 ]; then
  rm -f "$gl_report"
elif grep -qs '"File"' "$gl_report"; then
  echo "check: secrets FAIL (OWASP Authentication Failures, credentials in source): gitleaks found credentials in the working tree."
  # Name each file with a finding. Only paths are printed; the values stay redacted in the report.
  # awk keeps the first of repeated paths, so a file with several findings is listed once.
  sed -n 's/.*"File"[[:space:]]*:[[:space:]]*"\(.*\)".*/\1/p' "$gl_report" 2>/dev/null \
    | sed 's/\\\\/\\/g' | awk '!seen[$0]++' | sed 's/^/       found in: /'
  echo "       Report (secrets redacted): $gl_report"
  echo "       To allowlist a finding: add its Fingerprint to .gitleaksignore and document"
  echo "       the reason in product/decisions.md. Ask the human to approve both changes."
  failed=1
else
  echo "check: secrets FAIL: gitleaks couldn't scan the working tree."
  last_line="$(printf '%s\n' "$gl_out" | tr -d '\r' | tail -n 1)"
  [ -n "$last_line" ] && echo "       gitleaks: $last_line"
  if [ "$gl_ver" = "8.19.0" ]; then
    echo "       gitleaks 8.19.0 can't scan (every command fails). Upgrade to 8.19.1 or later."
  else
    echo "       Check the error above. Upgrading gitleaks may help."
  fi
  exit 3
fi

if [ "$arch_only" -eq 1 ]; then
  if [ "$failed" -eq 0 ]; then echo "check: PASS (architecture only)"; exit 0; fi
  echo "check: FAIL (architecture only)"
  exit 1
fi

# --- test time limit -----------------------------------------------------------------------------
# [tests] timeout in tools/check.cfg (CHECK_TIMEOUT overrides it), default 600 seconds. GNU timeout only:
# Windows' timeout.exe is something else. A run past the limit leaves exit status 124.
limit="${CHECK_TIMEOUT:-}"
[ -n "$limit" ] || limit="$(cfg_get tests timeout)"
case "$limit" in ''|*[!0-9]*|0) limit=600 ;; esac
timeout_cmd=""
for candidate in timeout gtimeout; do
  if "$candidate" --version 2>/dev/null | grep -qi coreutils; then timeout_cmd="$candidate"; break; fi
done
[ -n "$timeout_cmd" ] || echo "check: note: no GNU timeout found: a hung test can't be cut short"
timed_out=""
# run_limited <what> <command...>: run it under the limit; a timeout is noted, not counted as a failure.
run_limited() {
  local what="$1" rc; shift
  if [ -n "$timeout_cmd" ]; then "$timeout_cmd" "$limit" "$@" </dev/null; else "$@"; fi
  rc=$?
  if [ "$rc" -eq 124 ] && [ -n "$timeout_cmd" ]; then timed_out="${timed_out:+$timed_out, }$what"; return 0; fi
  return "$rc"
}

# --- 3. Stack check -------------------------------------------------------------------------------
stack="$(cfg_get project stack)"
if [ -z "$stack" ]; then
  echo "check: note: no stack set in tools/check.cfg [project] stack; only architecture checks ran"
else
  stack_script="tools/stacks/$stack.sh"
  if [ ! -f "$stack_script" ]; then
    echo "check: can't find $stack_script; run: bash tools/setup-clone.sh"
    exit 3
  fi
  echo "check: stack ($stack)"
  if ! run_limited "the stack check" bash "$stack_script"; then
    echo "check: stack check failed"
    failed=1
  fi
fi

# --- 4. Custom check ------------------------------------------------------------------------------
if [ -f tools/check.local.sh ]; then
  echo "check: running tools/check.local.sh"
  if ! run_limited "tools/check.local.sh" bash tools/check.local.sh; then
    echo "check: tools/check.local.sh failed"
    failed=1
  fi
fi

# --- a test run hit the limit ---------------------------------------------------------------------
if [ -n "$timed_out" ]; then
  echo "check: couldn't run to the end: $timed_out timed out after ${limit} s ([tests] timeout in tools/check.cfg, or CHECK_TIMEOUT)"
  # A failure seen before the timeout wins and exits 1 below. Exit 3 only when none was seen.
  if [ "$failed" -eq 0 ]; then rm -f "$state_dir/last-pass"; exit 3; fi
fi

# --- result ---------------------------------------------------------------------------------------
hooks_dir="$(git rev-parse --git-path hooks 2>/dev/null)"
if [ -n "$hooks_dir" ] && ! grep -qs "App Director" "$hooks_dir/pre-commit" 2>/dev/null; then
  echo "check: note: this clone has no App Director pre-commit hook. Run: bash tools/setup-clone.sh"
fi

if [ "$failed" -eq 0 ]; then
  after="$(fingerprint)"
  if [ -n "$before" ] && [ "$before" = "$after" ]; then
    cache_key "$before" > "$state_dir/last-pass"
  elif [ -n "$before" ]; then
    echo "check: note: files changed while the check ran; run it again to cover the changes."
  fi
  rm -f "$state_dir/last-fail"
  echo "check: PASS"
  exit 0
fi
rm -f "$state_dir/last-pass"
if [ -n "$before" ] && [ "$before" = "$(fingerprint)" ]; then cache_key "$before" > "$state_dir/last-fail"; fi
echo "check: FAIL (logs above)"
exit 1
