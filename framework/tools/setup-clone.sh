#!/usr/bin/env bash
# App Director per-clone setup · framework-owned: replaced on upgrade.
#
#   bash tools/setup-clone.sh              check toolchain + install pre-commit hook
#   bash tools/setup-clone.sh --skip-hook  check toolchain only
#
# Run it once in every new clone or worktree; running it again is harmless.
# 1. Reads tools/check.cfg [project] stack and checks that the stack tool is available.
# 2. Installs the pre-commit hook via a small shim in .git/hooks that runs .githooks/pre-commit.
#    An existing non-App-Director hook is never overwritten.
# Exit codes: 0 = done · 3 = stack tool missing · 4 = done, but the hook needs your attention.

set -u
cd "$(dirname "$0")/.." || exit 1
skip_hook=0
for arg in "$@"; do
  case "$arg" in --skip-hook) skip_hook=1 ;; esac
done

# Read an ini-style check.cfg value.
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

# --- 1. Toolchain check ---------------------------------------------------------------------------
stack="$(cfg_get project stack)"
exit_code=0

check_tool() {
  local name="$1"
  if command -v "$name" >/dev/null 2>&1; then
    echo "setup: found $name ($(command -v "$name"))"
  else
    echo "setup: $name not found — install it and rerun."
    exit_code=3
  fi
}

case "$stack" in
  typescript|ts)
    check_tool node
    check_tool npm
    ;;
  flutter)
    check_tool flutter
    ;;
  python)
    check_tool python
    if ! python -m pytest --version >/dev/null 2>&1; then
      echo "setup: pytest not found — run: pip install pytest"
      exit_code=3
    fi
    ;;
  none|"")
    echo "setup: no stack configured in tools/check.cfg; only architecture checks will run."
    ;;
  *)
    echo "setup: unknown stack '$stack' in tools/check.cfg [project] stack."
    echo "       Known stacks: typescript, flutter, python, none."
    exit_code=3
    ;;
esac

[ "$exit_code" -ne 0 ] && exit "$exit_code"

# --- 2. Pre-commit hook ---------------------------------------------------------------------------
[ "$skip_hook" -eq 1 ] && exit 0
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "setup: not a git repository, so no pre-commit hook."
  exit 4
fi

hooks_path="$(git config --get core.hooksPath 2>/dev/null)"
if [ -n "$hooks_path" ]; then
  echo "setup: this clone uses core.hooksPath=$hooks_path (e.g. husky)."
  echo "       Add this line to its pre-commit hook: bash .githooks/pre-commit || exit 1"
  exit 4
fi

hooks_dir="$(git rev-parse --git-path hooks)"
hook="$hooks_dir/pre-commit"
if [ -f "$hook" ] && ! grep -qE "App Director" "$hook" 2>/dev/null; then
  echo "setup: $hook already exists and isn't App Director's."
  echo "       Add this line to it: bash .githooks/pre-commit || exit 1"
  exit 4
fi
mkdir -p "$hooks_dir"
cat > "$hook" <<'HOOK'
#!/usr/bin/env bash
# App Director: runs the project's committed pre-commit hook. Installed by tools/setup-clone.sh.
root="$(git rev-parse --show-toplevel)" || exit 1
[ -f "$root/.githooks/pre-commit" ] || exit 0
exec bash "$root/.githooks/pre-commit" "$@"
HOOK
chmod +x "$hook"
echo "setup: pre-commit hook installed ($hook)"
exit 0
