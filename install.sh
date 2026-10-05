#!/usr/bin/env bash
# App Director installer: installs the workflow into an app project, or upgrades it.
#
#   bash /path/to/App-Director/install.sh [--force] [project folder]
#
# The project folder defaults to the current one and must be the root of a git repository
# (--force skips that check).
#
# - framework/ is framework-owned and is copied on every run. A file you changed locally stays as
#   it is. If this version changes that file too, the new version is written next to it as
#   <file>.adir-new for you to merge.
# - project/ holds project-owned seeds, copied only when missing. They're yours from then on.
# - Framework files an earlier version installed but this one no longer ships are deleted,
#   unless you changed them.
# - .gitignore and .gitattributes get the lines App Director needs.
# - What was installed is recorded in .app-director/manifest (commit it).
# Nothing is committed. Review with `git status` and `git diff`, then follow ONBOARDING.md.

set -eu

FIND=find; [ -x /usr/bin/find ] && FIND=/usr/bin/find
SORT=sort; [ -x /usr/bin/sort ] && SORT=/usr/bin/sort
TAR=tar;   [ -x /usr/bin/tar ] && TAR=/usr/bin/tar
tab="$(printf '\t')"
nl='
'

force=0; target="."
while [ "$#" -gt 0 ]; do
  case "$1" in
    --force) force=1; shift ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) target="$1"; shift ;;
  esac
done

src="$(cd "$(dirname "$0")" && pwd)"
dest="$(cd "$target" && pwd)"
if [ "$src" = "$dest" ]; then
  echo "install: give the app project's folder, not the App Director folder." >&2
  exit 1
fi
command -v git >/dev/null 2>&1 || { echo "install: git is required." >&2; exit 1; }
if [ "$force" -eq 0 ]; then
  if ! prefix="$(git -C "$dest" rev-parse --show-prefix 2>/dev/null)"; then
    echo "install: $dest isn't a git repository. Run 'git init' there first (or pass --force)." >&2
    exit 1
  fi
  if [ -n "$prefix" ]; then
    echo "install: $dest is inside a git repository, not at its root. Install at the root (or pass --force)." >&2
    exit 1
  fi
fi
if grep -rlq "$(printf '\r')" "$src/framework" "$src/project" 2>/dev/null; then
  echo "install: App Director's files have CRLF line endings. Check the folder out again with LF" >&2
  echo "         (its .gitattributes asks for LF), or convert them, then rerun." >&2
  exit 1
fi

version="$(tr -d '\r\n' < "$src/VERSION")"
manifest_rel=".app-director/manifest"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

: > "$tmp/old"
old_version=""
if [ -f "$dest/$manifest_rel" ]; then
  tr -d '\r' < "$dest/$manifest_rel" > "$tmp/manifest"
  old_version="$(sed -n 's/^# app-director //p' "$tmp/manifest" | head -n 1)"
  grep -v '^#' "$tmp/manifest" > "$tmp/old" || true
fi

# list_files <folder>: all files under it, sorted.
list_files() {
  (cd "$1" && "$FIND" . -type f | sed 's|^\./||' | LC_ALL=C "$SORT")
}

# hash_paths <folder> <file of relative paths> [filters] → "hash<TAB>path" lines, one git call.
hash_paths() {
  if [ -s "$2" ]; then
    local prefix top
    prefix="$(cd "$1" && git rev-parse --show-prefix 2>/dev/null)" || prefix=""
    top="$1"
    if [ -n "$prefix" ]; then top="$(cd "$1" && git rev-parse --show-toplevel)"; fi
    sed "s|^|$prefix|" "$2" > "$tmp/hash-input"
    if [ "${3:-}" = "filters" ]; then
      (cd "$top" && git hash-object --stdin-paths < "$tmp/hash-input") > "$tmp/hashes"
    else
      (cd "$top" && git hash-object --no-filters --stdin-paths < "$tmp/hash-input") > "$tmp/hashes"
    fi
    awk 'NR == FNR { hash[FNR] = $0; next } { print hash[FNR] "\t" $0 }' "$tmp/hashes" "$2"
  fi
}

# copy_list <from> <to> <file of relative paths>: one tar pipe for all of them.
copy_list() {
  if [ -s "$3" ]; then
    (cd "$1" && "$TAR" -cf - -T "$3") | (cd "$2" && "$TAR" -xf -)
  fi
}

# --- plan -----------------------------------------------------------------------------------------
list_files "$src/framework" > "$tmp/paths"
hash_paths "$src/framework" "$tmp/paths" > "$tmp/new"

awk -F'\t' '$2 != "" && !seen[$2]++ { print $2 }' "$tmp/new" "$tmp/old" \
  | (cd "$dest" && while IFS= read -r path; do [ -f "$path" ] && printf '%s\n' "$path"; done) > "$tmp/present" || true
hash_paths "$dest" "$tmp/present" filters > "$tmp/current"

awk -F'\t' -v OFS='\t' '
  FILENAME == ARGV[1] { old[$2] = $1; next }
  FILENAME == ARGV[2] { current[$2] = $1; next }
  {
    shipped[$2] = 1
    if (!($2 in current)) print "new", $2
    else if (current[$2] == $1) print "same", $2
    else if (($2 in old) && current[$2] == old[$2]) print "update", $2
    else if (($2 in old) && old[$2] == $1) print "keep", $2
    else print "conflict", $2
  }
  END {
    for (path in old)
      if (!(path in shipped) && (path in current)) print (current[path] == old[path] ? "remove" : "left"), path
  }
' "$tmp/old" "$tmp/current" "$tmp/new" > "$tmp/plan"

# --- framework-owned files ------------------------------------------------------------------------
new_count=0; updated_count=0; same_count=0
conflicts=""; kept_local=""; removed=""; left=""; seeded=""; kept=""
: > "$tmp/copy"
while IFS="$tab" read -r action rel; do
  case "$action" in
    new)      printf '%s\n' "$rel" >> "$tmp/copy"; new_count=$((new_count + 1)) ;;
    update)   printf '%s\n' "$rel" >> "$tmp/copy"; updated_count=$((updated_count + 1)) ;;
    same)     same_count=$((same_count + 1)) ;;
    keep)     kept_local="$kept_local$nl    $rel" ;;
    conflict) cp "$src/framework/$rel" "$dest/$rel.adir-new"; conflicts="$conflicts$nl    $rel" ;;
    remove)   rm -f "$dest/$rel"; removed="$removed$nl    $rel" ;;
    left)     left="$left$nl    $rel" ;;
  esac
done < "$tmp/plan"
copy_list "$src/framework" "$dest" "$tmp/copy"

mkdir -p "$dest/${manifest_rel%/*}"
{ printf '# app-director %s\n' "$version"; cat "$tmp/new"; } > "$dest/$manifest_rel"

# --- project-owned seeds --------------------------------------------------------------------------
: > "$tmp/seeds"
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  if [ -e "$dest/$rel" ]; then
    kept="$kept$nl    $rel"
  else
    printf '%s\n' "$rel" >> "$tmp/seeds"; seeded="$seeded$nl    $rel"
  fi
done <<EOF
$(list_files "$src/project")
EOF
copy_list "$src/project" "$dest" "$tmp/seeds"

# Scripts must be executable.
set --
for file in "$dest"/tools/*.sh "$dest"/.githooks/* "$dest"/.claude/hooks/*.sh; do
  if [ -f "$file" ]; then set -- "$@" "$file"; fi
done
if [ "$#" -gt 0 ]; then chmod +x "$@"; fi

# --- .gitignore / .gitattributes ------------------------------------------------------------------
ensure_lines() {
  local file="$1" line content added=0
  shift
  [ -f "$file" ] || : > "$file"
  content="$(tr -d '\r' < "$file")"
  for line in "$@"; do
    case "$nl$content$nl" in *"$nl$line$nl"*) continue ;; esac
    if [ "$added" -eq 0 ]; then
      if [ -s "$file" ] && [ -n "$(tail -c 1 "$file")" ]; then echo >> "$file"; fi
      echo "# App Director" >> "$file"
      added=1
    fi
    echo "$line" >> "$file"
  done
}
ensure_lines "$dest/.gitignore" \
  ".app-director/state/" "*.adir-new" ".env" "*.local"
ensure_lines "$dest/.gitattributes" \
  "*.sh text eol=lf" "/.githooks/** text eol=lf" "/.app-director/** text eol=lf" \
  "/.claude/** text eol=lf" "/tools/check.sh text eol=lf" "/tools/setup-clone.sh text eol=lf"

# --- report ---------------------------------------------------------------------------------------
if [ -z "$old_version" ]; then action="installed $version"
elif [ "$old_version" = "$version" ]; then action="$version reinstalled"
else action="upgraded from $old_version to $version"; fi
echo "App Director $action in $dest"
echo "  framework files: $new_count new, $updated_count updated, $same_count unchanged"
if [ -n "$kept_local" ]; then echo "  kept your changes (this version doesn't change these files):$kept_local"; fi
if [ -n "$seeded" ]; then echo "  project files created:$seeded"; fi
if [ -n "$kept" ]; then echo "  project files kept (they already existed):$kept"; fi
if [ -n "$removed" ]; then echo "  removed (no longer part of App Director):$removed"; fi
if [ -n "$left" ]; then echo "  no longer part of App Director but changed locally, so left in place:$left"; fi
if [ -n "$conflicts" ]; then
  echo "  CONFLICTS: you changed these and so does this version. The new version is next to each as"
  echo "  <file>.adir-new; merge it, then delete it:$conflicts"
fi
echo "Next: review with git status / git diff, then follow $src/ONBOARDING.md."
exit 0
