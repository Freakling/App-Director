#!/usr/bin/env bash
# App Director prototypes · framework-owned: replaced on upgrade.
#
# The git steps of .app-director/procedures/prototype.md. A prototype is a git worktree beside the project, on
# its own proto/<name> branch, where a change is tried outside the loop; the harvest turns it into items.
#   bash tools/prototype.sh start <name>    the worktree ../<project folder>-proto-<name> on a new branch
#                                           proto/<name> from main (no upstream), tools/setup-clone.sh run there,
#                                           and its PROTOTYPE.md (the notes) written from the template and committed.
#                                           It refuses, creating nothing, unless main has the hooks and this script
#                                           committed, this clone's pre-commit and pre-push hooks are App Director's
#                                           (or core.hooksPath is set) and gitleaks is on PATH: they are a
#                                           prototype's only gates. When origin/main (as last fetched) is ahead of
#                                           main, it stops first and creates nothing (exit 5); --as-is starts from
#                                           main as it is
#   bash tools/prototype.sh list            each proto/ branch, its worktree and its commits since main
#   bash tools/prototype.sh harvest <name>  what the harvest reads: the commits, the files changed since main and
#                                           the diff command, the worktree's uncommitted changes and its
#                                           PROTOTYPE.md; changes nothing
#   bash tools/prototype.sh remove <name>   git worktree remove, never forced. The branch stays: it is never
#                                           merged, so deleting it (git branch -D) discards its commits, and the
#                                           human runs that
#   bash tools/prototype.sh here            whether this checkout is a prototype: a linked worktree on a proto/
#                                           branch with PROTOTYPE.md at its root (exit 0), or not (exit 1). The
#                                           pre-commit and Stop hooks skip the check only when it is
# A name is lowercase letters, digits and dashes, such as quick-add. start, harvest and remove run in the main
# session's checkout, not in a prototype. This never pushes, merges or deletes a branch.
# Exit codes: 0 = done · 1 = refused or failed (the reason is printed) · 4 = started, but setup-clone or the
# first commit needs attention (above) · 5 = origin/main is ahead of main, nothing created

set -u
cd "$(dirname "$0")/.." || exit 1
cmd="${1:-}"; name="${2:-}"; as_is="${3:-}"

say() { echo "prototype: $*"; }
refuse() { echo "prototype: $*" >&2; exit 1; }

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || refuse "not a git repository"

branch="$(git symbolic-ref --short -q HEAD 2>/dev/null)"

abs_dir() { (cd "$1" 2>/dev/null && pwd -P); }
is_prototype() { # this checkout: a linked worktree, on a proto/ branch, with PROTOTYPE.md at its root
  case "$branch" in proto/*) ;; *) why="it isn't on a proto/ branch"; return 1 ;; esac
  [ -f PROTOTYPE.md ] || { why="it has no PROTOTYPE.md at its root"; return 1; }
  local gd gc
  gd="$(abs_dir "$(git rev-parse --git-dir 2>/dev/null)")"; gc="$(abs_dir "$(git rev-parse --git-common-dir 2>/dev/null)")"
  [ -n "$gd" ] && [ "$gd" != "$gc" ] || { why="it isn't a linked worktree"; return 1; }
  return 0
}
worktree_of() { # the folder of the worktree that has branch $1 checked out, if any
  git worktree list --porcelain | awk -v ref="refs/heads/$1" '
    /^worktree / { wt = substr($0, 10) }
    $0 == "branch " ref { print wt; exit }'
}
has_branch() { git show-ref --verify --quiet "refs/heads/$1"; }
need_main() { has_branch main || refuse "no main branch to start from or compare with"; }
need_main_session() {
  is_prototype && refuse "this checkout is the prototype ${branch#proto/}: run this in the main session"
  return 0
}
need_name() {
  case "$name" in
    ""|-*|*-|*[!abcdefghijklmnopqrstuvwxyz0123456789-]*|list|harvest|remove|here)
      refuse "'$name' isn't a prototype name: lowercase letters, digits and dashes, such as quick-add (not list, harvest, remove or here)" ;;
  esac
}
need_prototype() {
  has_branch "proto/$name" || refuse "there is no prototype $name (no branch proto/$name); list shows the prototypes"
}
need_gates() { # a prototype's only gates are the hooks and gitleaks, so start refuses without them
  local hooks_dir hook f missing=""
  for f in .githooks/pre-commit .githooks/pre-push tools/prototype.sh; do
    git cat-file -e "main:$f" 2>/dev/null || missing="$missing $f"
  done
  [ -z "$missing" ] || refuse "main has no committed$missing: commit the App Director upgrade on main first"
  if [ -z "$(git config --get core.hooksPath 2>/dev/null)" ]; then
    hooks_dir="$(git rev-parse --git-path hooks)"
    for hook in pre-commit pre-push; do
      grep -qs "App Director" "$hooks_dir/$hook" || missing="$missing $hook"
    done
    [ -z "$missing" ] || refuse "this clone has no App Director$missing hook: run bash tools/setup-clone.sh here first"
  fi
  command -v gitleaks >/dev/null 2>&1 || refuse "gitleaks isn't on PATH, and a prototype's commits have no other gate: install it (bash tools/setup-clone.sh says how)"
}

case "$cmd" in
  start)
    need_name; need_main_session; need_main
    case "$as_is" in ""|--as-is) ;; *) refuse "start takes a name and, optionally, --as-is" ;; esac
    need_gates
    # The main worktree (git lists it first): prototypes sit beside it, whichever checkout runs this.
    top="$(git worktree list --porcelain | sed -n '1s/^worktree //p')"
    top="${top:-$(pwd)}"
    path="$(dirname "$top")/$(basename "$top")-proto-$name"
    has_branch "proto/$name" && refuse "the branch proto/$name already exists: pick another name, or harvest that prototype"
    [ -e "$path" ] && refuse "the folder $path already exists: pick another name"
    behind="$(git rev-list --count main..origin/main 2>/dev/null)"
    if [ "${behind:-0}" -gt 0 ] && [ -z "$as_is" ]; then
      say "origin/main has $behind commit(s) that main doesn't (as last fetched), so nothing was created."
      say "Bring main up to date first (git pull --ff-only, on main), or start from main as it is: bash tools/prototype.sh start $name --as-is"
      exit 5
    fi
    git worktree add --no-track -b "proto/$name" "$path" main || refuse "git worktree add failed (above)"
    status=0
    if [ -f "$path/tools/setup-clone.sh" ]; then
      (cd "$path" && bash tools/setup-clone.sh) || { status=4; say "setup-clone needs attention in $path (above)"; }
    else
      status=4; say "main has no tools/setup-clone.sh, so no setup ran in $path"
    fi
    cat > "$path/PROTOTYPE.md" <<EOF
# Prototype: $name

This folder is a prototype, on the branch \`proto/$name\`, started from \`main\` at \`$(git rev-parse --short main)\` on $(date +%Y-%m-%d). A session in a checkout that \`bash tools/prototype.sh here\` calls a prototype (a linked worktree on a \`proto/\` branch with this file at its root) is a prototype session: read \`.app-director/procedures/prototype.md\` › In a prototype session before any work. It is tried outside the loop and never pushed or merged: the harvest, in the main session, turns what is worth keeping into decisions, user stories and items that are built from main. Keep notes here as you go; the harvest reads them.

## What we're trying
<!-- The idea in your words, and what would make it feel right. -->

## How it felt
<!-- As you go: what worked, what didn't, what surprised you. -->

## What to keep
<!-- What the real build should take from this, and what to leave behind. -->
EOF
    if ! { git -C "$path" add PROTOTYPE.md && git -C "$path" commit -q -m "proto: start the $name prototype" -- PROTOTYPE.md; }; then
      status=4; say "couldn't commit PROTOTYPE.md in $path (above): commit it in the prototype session"
    fi
    say "started: the worktree $path on the branch proto/$name"
    exit "$status"
    ;;
  list)
    found=0
    for br in $(git for-each-ref --format='%(refname:short)' refs/heads/proto/); do
      found=1
      wt="$(worktree_of "$br")"
      n="?"; has_branch main && n="$(git rev-list --count "main..$br" 2>/dev/null)"
      echo "$br · ${wt:-no worktree} · $n commit(s) since main"
    done
    [ "$found" -eq 1 ] || say "no prototypes (no proto/ branches)"
    exit 0
    ;;
  harvest)
    need_name; need_main_session; need_prototype; need_main
    wt="$(worktree_of "proto/$name")"
    say "proto/$name · worktree ${wt:-none}"
    echo "--- commits since main (git log --oneline main..proto/$name)"
    git log --oneline "main..proto/$name"
    echo "--- files changed (git diff --stat main...proto/$name); read the diff with: git diff main...proto/$name"
    git diff --stat "main...proto/$name"
    notes=""
    if [ -n "$wt" ] && [ -d "$wt" ]; then
      dirty="$(git -C "$wt" status --porcelain)"
      if [ -n "$dirty" ]; then
        echo "--- uncommitted in the worktree, so not in the diff"
        printf '%s\n' "$dirty"
      fi
      [ -f "$wt/PROTOTYPE.md" ] && notes="$(cat "$wt/PROTOTYPE.md")"
    fi
    [ -n "$notes" ] || notes="$(git show "proto/$name:PROTOTYPE.md" 2>/dev/null)"
    echo "--- PROTOTYPE.md"
    printf '%s\n' "${notes:-(none)}"
    exit 0
    ;;
  remove)
    need_name; need_main_session; need_prototype
    wt="$(worktree_of "proto/$name")"
    if [ -n "$wt" ] && [ -d "$wt" ]; then
      git worktree remove "$wt" \
        || refuse "git worktree remove failed (above); uncommitted changes are the usual cause, or a session or app still using the folder. $wt is left in place; never force it"
      say "removed the worktree $wt"
    elif [ -n "$wt" ]; then
      git worktree prune && say "the folder $wt was already gone; pruned git's record of it"
    else
      say "proto/$name has no worktree"
    fi
    say "the branch proto/$name stays, with its commits. A prototype is never merged, so deleting it takes git branch -D, which discards them: the human runs that, in a terminal in the project folder: git branch -D proto/$name"
    exit 0
    ;;
  here)
    if is_prototype; then say "this checkout is the prototype ${branch#proto/}"; exit 0; fi
    say "this checkout isn't a prototype: $why"
    exit 1
    ;;
  *)
    sed -n '6,26p' "$0"
    exit 1
    ;;
esac
