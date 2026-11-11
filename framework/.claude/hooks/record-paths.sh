#!/usr/bin/env bash
# App Director record paths · sourced by guard-protected.sh and record-watch.sh, not a hook of its own · framework-owned:
# replaced on upgrade.
#
# One reading of a path for both hooks, so the file guard and the watch agree on which file a tool wrote:
#   rp_target <path as the tool input gives it, JSON-escaped>: sets root (the project root, $CLAUDE_PROJECT_DIR or the
#     current folder) and resolved, both absolute in the Git Bash form (/c/x for C:\x). Backslashes are separators, a
#     Windows long-path prefix (\\?\ or \\.\) is dropped, . and empty segments are dropped and .. applies to the segment
#     before it; on Windows each segment loses its trailing dots and spaces, as Windows drops them.
#   rp_cfg <file> <prefix>: the [records] paths in a tools/check.cfg text into <prefix>brief, <prefix>decisions,
#     <prefix>stories and <prefix>tasks, with the defaults (product/brief.md, product/decisions.md,
#     product/user-stories.md, TASKS.md) for those it doesn't set. A line is cut at its first ;, as records.sh reads it.
#   rp_nocase is 1 where the file system ignores case (Windows, macOS, and a Windows drive under WSL, /mnt/<letter>/): the
#     callers then match with nocasematch.
#   rp_plain: whether a Windows path is in its plain form (no stream, no 8.3 short name).
#   rp_read: reads the hook's input into input: the first 64 KB, then on to the end only while the key named by
#     rp_need (a regular expression) isn't in it; what is left is drained (cat, a process only for an input that long), so
#     the writer never gets a broken pipe.
# Bash only: it starts no process. Bash 3.2 runs it.

rp_win=0; case "${OSTYPE:-}" in msys*|cygwin*) rp_win=1 ;; esac

rp_read() {
  local more=0 rest
  LC_ALL=C IFS= read -r -d '' -n 65536 input && more=1
  [ "$more" -eq 1 ] || return 0
  if [[ $input =~ $rp_need ]]; then cat > /dev/null; return 0; fi
  rest="$(cat)"; input="$input$rest"
}
rp_nocase=$rp_win; case "${OSTYPE:-}" in darwin*) rp_nocase=1 ;; esac

# rp_posix <path>: posix, with / separators, no long-path prefix, and a drive C:/x as /c/x.
rp_posix() {
  local l abc=abcdefghijklmnopqrstuvwxyz ABC=ABCDEFGHIJKLMNOPQRSTUVWXYZ rest re='^/+[?.]/+([A-Za-z]:.*)$'
  posix="${1//\\//}"
  [[ $posix =~ $re ]] && posix="${BASH_REMATCH[1]}"
  if [[ $posix =~ ^([A-Za-z]):/(.*)$ ]]; then
    l="${BASH_REMATCH[1]}"; rest="${BASH_REMATCH[2]}"
    if [[ $ABC == *"$l"* ]]; then l="${ABC%%"$l"*}"; l="${abc:${#l}:1}"; fi
    posix="/$l/$rest"
  fi
}

# rp_resolve <posix path>: resolved, with . and empty segments dropped and .. applied ("/" for the root).
rp_resolve() {
  local IFS=/ seg out=""
  for seg in $1; do
    if [ "$rp_win" -eq 1 ]; then
      case "$seg" in .|..) ;; *) while [[ $seg == *[.\ ] ]]; do seg="${seg%?}"; done ;; esac
    fi
    case "$seg" in
      ""|.) ;;
      ..) out="${out%/*}" ;;
      *) out="$out/$seg" ;;
    esac
  done
  resolved="${out:-/}"
}

rp_target() {
  rp_posix "${CLAUDE_PROJECT_DIR:-$PWD}"
  rp_resolve "$posix"
  root="${resolved%/}"   # "" for the file system root
  rp_posix "$1"
  case "$posix" in
    /*) ;;
    *) posix="$root/$posix" ;;   # relative to the project root
  esac
  rp_resolve "$posix"
  case "$resolved" in /mnt/[A-Za-z]/*) rp_nocase=1 ;; esac   # a Windows drive under WSL ignores case too
}

# rp_plain: after rp_target, 1 when, on Windows, the path below the project root (one outside it passes) names a stream (a : after the drive's) or a short
# name (a segment with ~ and a digit, DECISI~1.MD): either can name a record file the plain path doesn't show.
rp_plain() {
  local rel="$resolved" re='~[0-9]'
  [ "$rp_win" -eq 1 ] || return 0
  [[ $rel == "$root"/* ]] || return 0   # outside the project (a temp folder in 8.3 form): not ours to judge
  rel="${rel:${#root}}"
  [[ $rel == *:* ]] && return 1
  [[ $rel =~ $re ]] && return 1
  return 0
}

rp_cfg() {
  local line section="" k v cr=$'\r'
  printf -v "${2}brief" '%s' product/brief.md; printf -v "${2}decisions" '%s' product/decisions.md
  printf -v "${2}stories" '%s' product/user-stories.md; printf -v "${2}tasks" '%s' TASKS.md
  [ -f "$1" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%"$cr"}"; line="${line%%;*}"
    line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
    case "$line" in "["*"]") section="$line"; continue ;; *=*) ;; *) continue ;; esac
    [ "$section" = "[records]" ] || continue
    k="${line%%=*}"; v="${line#*=}"
    k="${k%"${k##*[![:space:]]}"}"; v="${v#"${v%%[![:space:]]*}"}"; v="${v//\\//}"
    while :; do case "$v" in ./*) v="${v#./}" ;; */) v="${v%/}" ;; *) break ;; esac; done
    [ -n "$v" ] || continue
    case "$k" in brief|decisions|stories|tasks) printf -v "$2$k" '%s' "$v" ;; esac
  done < "$1"
}
