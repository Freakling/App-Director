#!/usr/bin/env bash
# App Director user stories · framework-owned: replaced on upgrade.
#
# Whether the user stories in product/user-stories.md are due for validation (.app-director/procedures/design.md
# › Validate the stories), counted the way tools/security.sh --due counts for the security assessment:
#   bash tools/stories.sh --due    due when the stories were never validated (Last validated: never), or after
#                                  [stories] every in tools/check.cfg (default 10) built items (commits whose subject
#                                  ends in "(T<n>)" or "(B<n>)", or that and a squash merge's " (#<pr>)") since the
#                                  commit on the file's Last validated line; by its date when that commit isn't in
#                                  this history. Not due while the file has no stories.
# Exit codes: 0 = it printed its line · 3 = couldn't run

set -u
cd "$(dirname "$0")/.." || exit 3
mode="${1:-}"
stories="product/user-stories.md"
EVERY_DEFAULT=10

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

[ "$mode" = "--due" ] || { echo "usage: bash tools/stories.sh --due"; exit 3; }

# Built items: commit subjects ending in "(T<n>)" or "(B<n>)", also with a squash merge's " (#<pr>)" after it.
ITEM_RE='\((T|B)[0-9]+\)( \(#[0-9]+\))?$'
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "stories: couldn't count: not a git repository"; exit 3; }
[ "$(git rev-parse --is-shallow-repository 2>/dev/null)" = "true" ] \
  && echo "stories: note: this is a shallow clone, so items before its oldest commit aren't counted"
every="$(cfg_get stories every)"
case "$every" in
  ''|*[!0-9]*|0) [ -n "$every" ] && echo "stories: note: [stories] every = $every isn't a whole number of 1 or more; using $EVERY_DEFAULT"
                 every="$EVERY_DEFAULT" ;;
esac
if [ ! -f "$stories" ]; then
  echo "stories: not due: no stories yet (no $stories), [stories] every = $every"
  exit 0
fi
text="$(tr -d '\r' < "$stories")"
# A story is a table row whose first cell is its ID (US-<n>; an app's own US-<prefix><n> IDs count too).
row_re='^\|[[:space:]]*US-[A-Za-z0-9]+[[:space:]]*\|'
total="$(printf '%s\n' "$text" | grep -cE "$row_re")"
unconfirmed="$(printf '%s\n' "$text" | grep -E "$row_re" | grep -ciE '\|[[:space:]]*unconfirmed[[:space:]]*\|')"
if [ "$total" -eq 0 ]; then
  echo "stories: not due: no stories yet in $stories, [stories] every = $every"
  exit 0
fi
summary="$total stories, $unconfirmed unconfirmed"
validated="$(printf '%s\n' "$text" | sed -n 's/.*\*\*Last validated:\*\*[[:space:]]*//p' | head -n 1)"
day="$(printf '%s' "$validated" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -n 1)"
commit="$(printf '%s' "$validated" | sed -n 's/.*`\([0-9a-fA-F]\{7,40\}\)`.*/\1/p' | head -n 1)"
if [ -n "$commit" ] && git cat-file -e "$commit^{commit}" 2>/dev/null; then
  count="$(git log --format=%s "$commit..HEAD" | grep -cE "$ITEM_RE")"
  since="the last validation (${day:-no date}, commit $commit)"
elif [ -n "$day" ]; then
  count="$(git log --format=%s --since="${day}T00:00:00" | grep -cE "$ITEM_RE")"
  if [ -n "$commit" ]; then since="the last validation ($day, by its date: its commit isn't in this history)"
  else since="the last validation ($day, by its date: the line names no commit)"; fi
else
  if [ -z "$validated" ]; then why="$stories has no Last validated line"; else why="Last validated: $validated"; fi
  echo "stories: due: never validated ($why), $summary, [stories] every = $every"
  exit 0
fi
if [ "$count" -ge "$every" ]; then
  echo "stories: due: built items since $since: $count, [stories] every = $every; $summary"
else
  echo "stories: not due: built items since $since: $count, [stories] every = $every; $summary"
fi
exit 0
