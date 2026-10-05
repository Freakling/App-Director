#!/usr/bin/env bash
# App Director project check · framework-owned: replaced on upgrade.
#
# The single definition of "it works":
#   bash tools/check.sh                    run the check
#   bash tools/check.sh --if-changed       repeat the last result at once if these exact files were checked
#   bash tools/check.sh --fingerprint      print the fingerprint of the current files (for hooks)
#   bash tools/check.sh --architecture     run only the UI purity and secrets checks (fast, no build)
# Exit codes: 0 = pass · 1 = fail · 3 = couldn't run (stack tool missing)
#
# Steps:
#   1. UI purity: scan UI-layer files for imports from data-layer folders.
#   2. Secrets: scan source for patterns that look like keys, passwords or tokens.
#   3. Stack check: source tools/stacks/<stack>.sh and run it.
#   4. Custom: run tools/check.local.sh, if the project has one.
#
# Settings are in tools/check.cfg. State is cached in .app-director/state/.

set -u
cd "$(dirname "$0")/.." || exit 3
mode="${1:-}"
state_dir=".app-director/state"

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

# Hash of every file that can change the result.
fingerprint() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  local paths
  paths="$(git -c core.quotePath=false ls-files -z -c -o --exclude-standard 2>/dev/null \
    | tr '\0' '\n' \
    | grep -v -E '^(node_modules/|dist/|build/|\.dart_tool/|__pycache__/)' \
    | grep -E '\.(ts|tsx|js|jsx|mjs|dart|py|json|yaml|yml)$|^tools/check\.(cfg|sh|local\.sh)$' \
    | while IFS= read -r p; do [ -f "$p" ] && printf '%s\n' "$p"; done)"
  [ -n "$paths" ] || return 0
  { printf '%s\n' "$paths"; printf '%s\n' "$paths" | git hash-object --no-filters --stdin-paths; } \
    | git hash-object --stdin
}

if [ "$mode" = "--fingerprint" ]; then fingerprint; exit 0; fi
mkdir -p "$state_dir" || exit 3
before="$(fingerprint)"

reuse_last() {
  [ "$mode" = "--if-changed" ] && [ -n "$before" ] || return 0
  if [ "$(cat "$state_dir/last-pass" 2>/dev/null)" = "$before" ]; then
    echo "check: PASS (nothing changed since the last passing run)"
    exit 0
  fi
  if [ "$(cat "$state_dir/last-fail" 2>/dev/null)" = "$before" ]; then
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
    purity_fail=0
    for ui_dir in $ui_dirs; do
      [ -d "$ui_dir" ] || continue
      find_args="-type f"
      for sd in $skip_dirs; do
        find_args="$find_args ! -path './$sd/*'"
      done
      # Find source files in this UI dir
      eval '"$FIND"' "$ui_dir" $find_args \
        '\( -name "*.ts" -o -name "*.tsx" -o -name "*.js" -o -name "*.jsx" -o -name "*.dart" -o -name "*.py" \)' \
        2>/dev/null | while IFS= read -r f; do
        if grep -qE "from ['\"]\.\..*($data_pattern)|import .*from ['\"]\.\..*($data_pattern)" "$f" 2>/dev/null \
          || grep -qE "^import .*($data_pattern)" "$f" 2>/dev/null; then
          echo "  GDIR-FAIL: $f imports from data layer directly"
          purity_fail=1
        fi
      done
    done
    # Check if any violations were found via exit status trick
    violations="$("$FIND" $ui_dirs -type f \( -name "*.ts" -o -name "*.tsx" -o -name "*.js" -o -name "*.jsx" -o -name "*.dart" -o -name "*.py" \) 2>/dev/null \
      | while IFS= read -r f; do
          if grep -lE "from ['\"](\.\./)+.*($data_pattern)" "$f" 2>/dev/null; then
            printf '%s\n' "$f"
          fi
        done)"
    if [ -n "$violations" ]; then
      echo "check: UI purity FAIL — data-layer imports in UI files:"
      printf '%s\n' "$violations" | sed 's/^/  /'
      failed=1
    fi
  fi
fi

# --- 2. Secrets check -----------------------------------------------------------------------------
echo "check: secrets"
FIND=find; [ -x /usr/bin/find ] && FIND=/usr/bin/find
skip_pattern=".app-director .git node_modules dist build .dart_tool __pycache__ .venv"
find_skip=""
for sd in $skip_pattern $skip_dirs; do
  find_skip="$find_skip -path './$sd' -prune -o"
done

secret_hits=""
secret_hits="$(eval '"$FIND"' . $find_skip \
  '-type f \( -name "*.ts" -o -name "*.tsx" -o -name "*.js" -o -name "*.jsx" -o -name "*.py" -o -name "*.dart" -o -name "*.json" -o -name "*.yaml" -o -name "*.yml" \)' \
  '-print' 2>/dev/null \
  | grep -v '\.env\.' \
  | while IFS= read -r f; do
      if grep -qE \
        "(password|passwd|api_key|apikey|secret_key|private_key|access_key|auth_token|bearer)\s*[:=]\s*['\"][^'\"]{8,}" \
        "$f" 2>/dev/null \
        || grep -qE "['\"][0-9a-fA-F]{32,}['\"]" "$f" 2>/dev/null; then
        printf '%s\n' "$f"
      fi
    done)"
if [ -n "$secret_hits" ]; then
  echo "check: secrets FAIL — possible credentials in source files:"
  printf '%s\n' "$secret_hits" | sed 's/^/  /'
  failed=1
fi

if [ "$arch_only" -eq 1 ]; then
  if [ "$failed" -eq 0 ]; then echo "check: PASS (architecture only)"; exit 0; fi
  echo "check: FAIL (architecture only)"
  exit 1
fi

# --- 3. Stack check -------------------------------------------------------------------------------
stack="$(cfg_get project stack)"
if [ -z "$stack" ]; then
  echo "check: note: no stack set in tools/check.cfg [project] stack — only architecture checks ran"
else
  stack_script="tools/stacks/$stack.sh"
  if [ ! -f "$stack_script" ]; then
    echo "check: can't find $stack_script — run: bash tools/setup-clone.sh"
    exit 3
  fi
  echo "check: stack ($stack)"
  if ! bash "$stack_script"; then
    echo "check: stack check failed"
    failed=1
  fi
fi

# --- 4. Custom check ------------------------------------------------------------------------------
if [ -f tools/check.local.sh ]; then
  echo "check: running tools/check.local.sh"
  if ! bash tools/check.local.sh; then
    echo "check: tools/check.local.sh failed"
    failed=1
  fi
fi

# --- result ---------------------------------------------------------------------------------------
hooks_dir="$(git rev-parse --git-path hooks 2>/dev/null)"
if [ -n "$hooks_dir" ] && ! grep -qs "App Director" "$hooks_dir/pre-commit" 2>/dev/null; then
  echo "check: note: this clone has no App Director pre-commit hook. Run: bash tools/setup-clone.sh"
fi

if [ "$failed" -eq 0 ]; then
  after="$(fingerprint)"
  if [ -n "$before" ] && [ "$before" = "$after" ]; then
    printf '%s' "$before" > "$state_dir/last-pass"
  elif [ -n "$before" ]; then
    echo "check: note: files changed while the check ran; run it again to cover the changes."
  fi
  rm -f "$state_dir/last-fail"
  echo "check: PASS"
  exit 0
fi
rm -f "$state_dir/last-pass"
if [ -n "$before" ] && [ "$before" = "$(fingerprint)" ]; then printf '%s' "$before" > "$state_dir/last-fail"; fi
echo "check: FAIL (logs above)"
exit 1
