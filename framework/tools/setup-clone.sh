#!/usr/bin/env bash
# App Director per-clone setup · framework-owned: replaced on upgrade.
#
#   bash tools/setup-clone.sh              check toolchain + install the pre-commit and pre-push hooks
#   bash tools/setup-clone.sh --skip-hook  check toolchain only
#
# Run it once in every new clone or worktree; running it again is harmless.
# 1. Reads tools/check.cfg [project] stack and checks that the stack tool is available.
# 2. Verifies gitleaks >= minimum version (read from check.cfg [gitleaks] min-version), except
#    8.19.0, which can't scan.
# 3. Installs the pre-commit and pre-push hooks via small shims in .git/hooks that run .githooks/pre-commit
#    and .githooks/pre-push. An existing non-App-Director hook is never overwritten. The hooks are installed
#    even when step 1 or 2 fails: they fail closed, blocking a commit until gitleaks can scan.
# Exit codes: 0 = done · 3 = tool missing, version too old or 8.19.0 (the hooks are installed all the same) ·
# 4 = done, but the hook needs your attention.

set -u
cd "$(dirname "$0")/.." || exit 1
skip_hook=0
for arg in "$@"; do
  case "$arg" in --skip-hook) skip_hook=1 ;; esac
done

GITLEAKS_MIN_DEFAULT="8.18.0"

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

# --- 1. Stack toolchain check ---------------------------------------------------------------------
stack="$(cfg_get project stack)"
exit_code=0

check_tool() {
  local name="$1"
  if command -v "$name" >/dev/null 2>&1; then
    echo "setup: found $name ($(command -v "$name"))"
  else
    echo "setup: $name not found; install it and rerun."
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
      echo "setup: pytest not found; run: pip install pytest"
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

# --- 2. gitleaks version check --------------------------------------------------------------------
gl_min="$(cfg_get gitleaks min-version)"
gl_min="${gl_min:-$GITLEAKS_MIN_DEFAULT}"

if ! command -v gitleaks >/dev/null 2>&1; then
  echo "setup: gitleaks not found (need >= $gl_min)."
  echo "       macOS:   brew install gitleaks"
  echo "       Linux:   https://github.com/gitleaks/gitleaks/releases  (download binary to /usr/local/bin)"
  echo "       Windows: winget install gitleaks  or  choco install gitleaks"
  echo "       No curl-to-shell installs; download the binary directly."
  exit_code=3
else
  gl_raw="$(gitleaks version 2>/dev/null)"
  gl_ver="$(printf '%s' "$gl_raw" | tr -d 'v \r\n')"
  # 8.19.0 is above the minimum but can't scan: every gitleaks command fails with
  # "flag accessed but not defined: source". 8.19.1 is the first release that works.
  if [ "$gl_ver" = "8.19.0" ]; then
    echo "setup: gitleaks 8.19.0 can't scan (every command fails). Upgrade to 8.19.1 or later."
    echo "       https://github.com/gitleaks/gitleaks/releases"
    exit_code=3
  elif version_gte "$gl_ver" "$gl_min"; then
    echo "setup: found gitleaks $gl_ver (>= $gl_min)"
  else
    echo "setup: gitleaks $gl_ver is below minimum $gl_min; upgrade it."
    echo "       https://github.com/gitleaks/gitleaks/releases"
    exit_code=3
  fi
fi

# --- 3. Pre-commit and pre-push hooks -------------------------------------------------------------
# Installed even when a tool is missing (exit 3 above): the hooks fail closed, so a commit is blocked until
# gitleaks can scan, rather than going through with no hook at all. Worktrees share them, prototypes too.
done_with() { [ "$exit_code" -ne 0 ] && exit "$exit_code"; exit "$1"; }
[ "$skip_hook" -eq 1 ] && done_with 0
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "setup: not a git repository, so no pre-commit or pre-push hook."
  done_with 4
fi

hooks_path="$(git config --get core.hooksPath 2>/dev/null)"
if [ -n "$hooks_path" ]; then
  echo "setup: this clone uses core.hooksPath=$hooks_path (e.g. husky)."
  echo "       Add this line to its pre-commit hook: bash .githooks/pre-commit || exit 1"
  echo "       and this one to its pre-push hook: bash .githooks/pre-push \"\$@\" || exit 1"
  done_with 4
fi

# Each hook is a small shim that runs the committed one, so an upgrade needs no new setup. Worktrees
# share the shims: git's hooks folder is the main clone's.
hooks_dir="$(git rev-parse --git-path hooks)"
mkdir -p "$hooks_dir"
hook_status=0
for name in pre-commit pre-push; do
  hook="$hooks_dir/$name"
  if [ -f "$hook" ] && ! grep -qE "App Director" "$hook" 2>/dev/null; then
    echo "setup: $hook already exists and isn't App Director's."
    echo "       Add this line to it: bash .githooks/$name \"\$@\" || exit 1"
    hook_status=4
    continue
  fi
  printf '%s\n' '#!/usr/bin/env bash' \
    "# App Director: runs the project's committed $name hook. Installed by tools/setup-clone.sh." \
    'root="$(git rev-parse --show-toplevel)" || exit 1' \
    "[ -f \"\$root/.githooks/$name\" ] || exit 0" \
    "exec bash \"\$root/.githooks/$name\" \"\$@\"" > "$hook"
  chmod +x "$hook"
  echo "setup: $name hook installed ($hook)"
done
done_with "$hook_status"
