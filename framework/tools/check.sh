#!/usr/bin/env bash
# App Director project check · framework-owned: replaced on upgrade.
#
# The single definition of "it works", in two tiers:
#   bash tools/check.sh                    the full tier: every step over the whole project. Same as --full
#   bash tools/check.sh --fast             the fast tier: the same steps, with the stack check doing what the change needs
#                                          (TypeScript: tsc over the project, eslint on the changed files, the related tests)
#   bash tools/check.sh --if-changed       with either tier: repeat the recorded result at once when these exact files were
#                                          checked with this gitleaks by a tier that covers the request (a full result covers
#                                          a fast request; a fast result covers only a fast request, on the commit it checked
#                                          the changes from or on another where every path that differs from HEAD was among
#                                          those it checked, as after committing them, and never a full one); a miss says
#                                          what changed
#   bash tools/check.sh --due              say whether the full tier is due (below), and run nothing else
#   bash tools/check.sh --fingerprint      print the fingerprint of the current files (for hooks)
#   bash tools/check.sh --architecture     run only the UI purity and secrets checks (fast, no build)
#   bash tools/check.sh --unignored        print the paths read from stdin, one per line, that count as source (source_re,
#                                          below) and that [tests] ignore doesn't cover (the pre-commit hook asks it which
#                                          staged files count as source)
# Flags combine in any order. Exit codes: 0 = pass · 1 = fail · 3 = couldn't run (gitleaks missing, old or unable to scan,
# stack tool missing, a test run hit its time limit, another check still running past CHECK_WAIT, or an unknown flag)
#
# Steps, in both tiers:
#   1. UI purity: scan UI-layer files for imports from data-layer folders (serves OWASP Broken Access
#      Control: no direct data access from UI code).
#   2. Secrets (serves OWASP Authentication Failures: no credentials in source): run gitleaks dir --redact on the working tree (detect --no-git before 8.19.1;
#      8.19.0 can't scan at all, so the check exits 3).
#   3. Stack check: run tools/stacks/<stack>.sh with CHECK_TIER (full or fast), CHECK_STATE (.app-director/state, an
#      absolute path) and, in the fast tier, CHECK_CHANGED (an absolute path of a file listing the paths that differ from
#      HEAD, staged or not, deletions and untracked files included, less [tests] ignore: one per line, from the repository
#      root). Lines it writes to $CHECK_STATE/stack-summary are printed in the summary at the end of the run.
#   4. Custom: run tools/check.local.sh, if the project has one, with the same environment, so it can leave its own slow
#      parts (a production build, say) to the full tier.
# A fast request runs as the full tier, with its limit and its record, and says why, when there's no commit yet, and when
# more than 100 source paths or 6,000 characters (each path and one) differ from HEAD: the stack check's file lists must
# fit on one command line (cmd.exe, which runs npx on Windows, takes 8,191 characters).
#
# The full tier is due (--due, and the result line of a fast pass) when no full pass is recorded
# (.app-director/state/last-full), when [tests] full-every commits (default 10; 0 = never by count) were made since it, or
# when a changed path matches [tests] full-when or the framework's own list (full_when_framework below). Patterns, there
# and in [tests] ignore and fast-map, are bash case patterns against the path from the repository root; one that ends in
# / is a folder and matches everything under it.
#
# Settings are in tools/check.cfg. State is kept in .app-director/state/:
#   last-pass, last-fail  line 1 the key (the fingerprint and gitleaks's version), line 2 the tier, time, commit, caller
#                         and run; beside each a .files list (<blob hash> <path>), which names what changed on a miss, and
#                         for a fast result a .changed list (run=<run>, then the changed paths it checked, one per line)
#   check-runs.log        one line per run or reuse, trimmed to its last 500 lines past 1000. CHECK_CALLER names the
#                         caller (the hooks set it; manual when unset)
# The stack check and tools/check.local.sh are each limited to [tests] timeout-fast seconds in the fast tier (default 300)
# and timeout-full in the full tier (default 3600; the older [tests] timeout counts when timeout-full isn't set).
# CHECK_TIMEOUT overrides both. GNU timeout (or gtimeout) is needed; a run that hits the limit exits 3, unless a failure
# was already seen (then it exits 1). While either runs, a line every 60 s (CHECK_PROGRESS_EVERY seconds) says so.
# gitleaks minimum version is read from check.cfg [gitleaks] min-version (default 8.18.0).
#
# One run at a time per checkout (single flight): a run of either tier holds .app-director/state/check.lock, with its time
# limit in it, and touches it every 60 s while the lock is its own (the heartbeat). Another run that finds it waits, says
# for what, and polls every 2 s; once that run is done, it reads HEAD again, and reuses the result that run recorded (pass
# or fail) when it was recorded after this run started and stands for the files as they are now and the request, and runs
# itself otherwise. The wait doesn't count against its own time limits. A lock is stale, and removed with a note, when its
# process is gone; when it is older than twice the longer of its holder's limit and this run's, plus 600 s; or when it
# hasn't been touched for 5 minutes (its pid is another process's now) at two looks at least 75 s apart by this run's
# clock (CHECK_UNTOUCHED_RECHECK seconds), since after a sleep and wake the holder's heartbeat is a minute late. CHECK_WAIT
# caps the wait in seconds (fast or full: that tier's limit, as above); past it the check runs nothing, prints a check:
# busy: line and exits 3.

set -u
cd "$(dirname "$0")/.." || exit 3
state_dir=".app-director/state"
GITLEAKS_MIN_DEFAULT="8.18.0"
nl='
'
SORT=sort; [ -x /usr/bin/sort ] && SORT=/usr/bin/sort
FIND=find; [ -x /usr/bin/find ] && FIND=/usr/bin/find
# Paths that make the full tier due whenever they change: dependencies, toolchain settings and the tools themselves.
full_when_framework="package.json package-lock.json pnpm-lock.yaml yarn.lock tools/* tsconfig*.json vitest.config.* vite.config.* jest.config.* eslint.config.* .eslintrc* pyproject.toml requirements*.txt pubspec.yaml pubspec.lock analysis_options.yaml"
usage="usage: bash tools/check.sh [--full | --fast] [--if-changed] | --due | --fingerprint | --architecture | --unignored"

# --- the command line -----------------------------------------------------------------------------
tier=""; if_changed=0; mode=""
for arg; do
  case "$arg" in
    --full|--fast)
      if [ -n "$tier" ] && [ "$tier" != "${arg#--}" ]; then
        echo "check: --full and --fast can't be combined"; echo "$usage"; exit 3
      fi
      tier="${arg#--}" ;;
    --if-changed) if_changed=1 ;;
    --due|--fingerprint|--architecture|--unignored) mode="$arg" ;;
    *) echo "check: unknown flag: $arg"; echo "$usage"; exit 3 ;;
  esac
done
tier="${tier:-full}"
requested="$tier"

# Read an ini-style check.cfg value into cfg_value: cfg_get <section> <key>
# The first call reads the file into cfg_text, without comments and carriage returns; the others read cfg_text.
cfg_text=""; cfg_read=0
cfg_get() {
  local section="$1" key="$2" in_section=0 line k v cr=$'\r'
  cfg_value=""
  if [ "$cfg_read" -eq 0 ]; then
    cfg_read=1
    [ -f tools/check.cfg ] || return 0
    while IFS= read -r line; do
      # The pipeline starts four processes and the file has about sixty lines, so only a line with a comment after its
      # value, or a carriage return, goes through it, and a line that is all comment is left out.
      case "$line" in
        \;*) continue ;;
        *\;*|*"$cr"*) line="$(printf '%s' "$line" | tr -d '\r' | sed 's/[[:space:]]*;.*//')" ;;
      esac
      cfg_text="$cfg_text$line$nl"
    done < tools/check.cfg
  fi
  while IFS= read -r line; do
    case "$line" in
      "[$section]") in_section=1 ;;
      "["*"]") in_section=0 ;;
      *) if [ "$in_section" -eq 1 ]; then
           k="${line%%=*}"; v="${line#*=}"
           k="${k%"${k##*[! ]}"}"; v="${v#"${v%%[! ]*}"}"
           [ "$k" = "$key" ] && { cfg_value="$v"; return; }
         fi ;;
    esac
  done <<< "$cfg_text"
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

# path_in <path> <patterns>: 0 when the path matches one of the space-separated patterns (bash case patterns against the
# path from the repository root; one that ends in / is a folder, and matches everything under it).
path_in() {
  local p="$1" pat hit=1
  set -f
  for pat in $2; do
    case "$pat" in
      */) case "$p" in "$pat"*) hit=0; break ;; esac ;;
      *) case "$p" in $pat) hit=0; break ;; esac ;;
    esac
  done
  set +f
  return "$hit"
}

# now: the local time, as YYYY-MM-DDTHH:MM:SS, in now_iso. bash 4.2 and later format it without a process.
now() { printf -v now_iso '%(%Y-%m-%dT%H:%M:%S)T' -1 2>/dev/null || now_iso="$(date '+%Y-%m-%dT%H:%M:%S')"; }

# remove <file>: rm -f, with no process when there's nothing to remove.
remove() { if [ -e "$1" ] || [ -L "$1" ]; then rm -f "$1"; fi; }

# epoch: the seconds since 1970 in now_epoch. bash 5 has them without a process.
epoch() { now_epoch="${EPOCHSECONDS:-}"; [ -n "$now_epoch" ] || now_epoch="$(date +%s)"; }

# tier_limit <fast|full> [cfg]: the tier's time limit in seconds in t_limit, the setting that gives it in t_name and where
# that is in t_where. [tests] timeout-fast (default 300) or timeout-full (default 3600; [tests] timeout when it isn't set)
# in tools/check.cfg; CHECK_TIMEOUT overrides both, unless cfg asks for the file's value only.
tier_limit() {
  local default=3600
  if [ "$1" = fast ]; then
    cfg_get tests timeout-fast; t_limit="$cfg_value"; t_name="[tests] timeout-fast"; default=300
  else
    cfg_get tests timeout-full; t_limit="$cfg_value"; t_name="[tests] timeout-full"
    if [ -z "$t_limit" ]; then cfg_get tests timeout; t_limit="$cfg_value"; [ -z "$t_limit" ] || t_name="[tests] timeout"; fi
  fi
  t_where="$t_name in tools/check.cfg"
  if [ -n "${CHECK_TIMEOUT:-}" ] && [ "${2:-}" != cfg ]; then t_limit="$CHECK_TIMEOUT"; t_name="CHECK_TIMEOUT"; t_where="CHECK_TIMEOUT"; fi
  case "$t_limit" in ''|*[!0-9]*|0) t_limit="$default" ;; esac
}

cfg_get tests ignore; ignore="$cfg_value"

# The source-path rule, the one definition of the paths that count as source: the extensions ts tsx js jsx mjs cjs mts
# cts dart py json yaml yml, and the check's own files (tools/check.cfg, tools/check.sh, tools/check.local.sh, a script
# directly in tools/stacks/, .gitleaks.toml and .gitleaksignore), outside the dependency and build folders. The
# fingerprint reads source_re with grep, over the whole tree; source_path tests one path, for --unignored and so for the
# pre-commit hook. tools/stacks/typescript.sh hands the related tests the changed files with these extensions.
source_re='\.(ts|tsx|js|jsx|mjs|cjs|mts|cts|dart|py|json|yaml|yml)$|^tools/check\.(cfg|sh|local\.sh)$|^tools/stacks/[^/]+\.sh$|^\.gitleaks(\.toml|ignore)$'
source_path() { # source_path <path from the repository root>: 0 when it counts as source
  case "$1" in node_modules/*|dist/*|build/*|.dart_tool/*|__pycache__/*) return 1 ;; esac
  [[ $1 =~ $source_re ]]
}

# --unignored: the paths on stdin that count as source and that [tests] ignore doesn't cover, as they came. The pre-commit
# hook gives it the staged files, so a commit that stages no source file, or only ignored ones, starts no check.
if [ "$mode" = "--unignored" ]; then
  while IFS= read -r p || [ -n "$p" ]; do
    [ -n "$p" ] && source_path "$p" || continue
    if [ -n "$ignore" ] && path_in "$p" "$ignore"; then continue; fi
    printf '%s\n' "$p"
  done
  exit 0
fi

# The files that can change the result: the tracked and untracked source files (source_re), less the paths under
# [tests] ignore. The list is sorted, so a file counts the same whether git tracks it or not: staging a new file leaves
# the fingerprint as it was. fingerprint sets fp_paths (one per line), fp_hashes (each one's blob hash, in the same order,
# from one git call) and fp_value, the hash of both. Outside a git repository there are no paths, and all three are empty.
fingerprint() {
  fp_hashes=""; fp_value=""
  fp_paths="$(git -c core.quotePath=false ls-files -z -c -o --exclude-standard 2>/dev/null \
    | tr '\0' '\n' \
    | grep -E "$source_re" \
    | LC_ALL=C "$SORT" -u \
    | while IFS= read -r p; do
        source_path "$p" || continue
        if [ -n "$ignore" ] && path_in "$p" "$ignore"; then continue; fi
        [ -f "$p" ] && printf '%s\n' "$p"
      done)"
  [ -n "$fp_paths" ] || return 0
  fp_hashes="$(git hash-object --no-filters --stdin-paths <<< "$fp_paths")"
  fp_value="$(git hash-object --stdin <<< "$fp_paths$nl$fp_hashes")"
}

if [ "$mode" = "--fingerprint" ]; then fingerprint; [ -z "$fp_value" ] || printf '%s\n' "$fp_value"; exit 0; fi
[ -d "$state_dir" ] || mkdir -p "$state_dir" || exit 3

# read_head: HEAD's commit in head_full and its short form in head_short ("none" with no commit yet). Read at the start,
# and again after a wait, since a commit may have been made meanwhile.
read_head() {
  head_full="$(git rev-parse -q --verify HEAD 2>/dev/null)"
  head_short="${head_full:0:7}"; [ -n "$head_short" ] || head_short="none"
}
read_head
caller="${CHECK_CALLER:-manual}"; caller="${caller//[[:space:]]/-}"

# changed_paths: the paths that differ from HEAD, staged or not (deletions too), and the untracked files git doesn't
# ignore, less [tests] ignore and the check's own state, one per line in changed_list; how many of them are source
# paths (source_path) in changed_n, and their characters, each path and one, in changed_chars. changed_ready is 1 while
# the list is current.
changed_ready=0
changed_paths() {
  local raw p
  changed_list=""; changed_n=0; changed_chars=0; changed_ready=1
  raw="$( { git diff --name-only --no-renames -z HEAD -- 2>/dev/null; git ls-files -o --exclude-standard -z 2>/dev/null; } \
    | tr '\0' '\n')"
  while IFS= read -r p; do
    case "$p" in ''|.app-director/state/*) continue ;; esac
    if [ -n "$ignore" ] && path_in "$p" "$ignore"; then continue; fi
    changed_list="$changed_list$p$nl"
    # Only a source path can reach the stack check's command lines, so only those count toward the limit.
    if source_path "$p"; then changed_n=$((changed_n + 1)); changed_chars=$((changed_chars + ${#p} + 1)); fi
  done <<< "$raw"
}

# due_check: whether the full tier is due (due_now 1 or 0) and why (due_why). Also due_count, the commits since the last
# full pass; lf_desc, its short commit and time; due_in, the commits until [tests] full-every brings it (empty when that
# is 0); and every, the setting. Reads changed_list.
due_check() {
  local lf_commit="" lf_at="" lf_time p when word
  due_now=1; due_why=""; due_count=0; due_in=""; lf_desc=""
  cfg_get tests full-every; every="$cfg_value"
  case "$every" in ''|*[!0-9]*) every=10 ;; esac
  cfg_get tests full-when; when="$full_when_framework $cfg_value"
  [ -f "$state_dir/last-full" ] && read -r lf_commit lf_at < "$state_dir/last-full"
  if [ -z "$lf_commit" ]; then due_why="no full pass recorded yet"; return 0; fi
  lf_time="${lf_at#*T}"; lf_desc="${lf_commit:0:7}, ${lf_at%%T*} ${lf_time%:*}"
  if [ -z "$head_full" ] || ! git merge-base --is-ancestor "$lf_commit" "$head_full" >/dev/null 2>&1; then
    due_why="the last full pass ($lf_desc) isn't in this history"; return 0
  fi
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if path_in "$p" "$when"; then due_why="$p changed"; return 0; fi
  done <<< "$changed_list"
  due_count="$(git rev-list --count "$lf_commit..$head_full" 2>/dev/null)"
  case "$due_count" in ''|*[!0-9]*) due_count=0 ;; esac
  word=commits; [ "$due_count" -eq 1 ] && word=commit
  if [ "$every" -gt 0 ]; then
    if [ "$due_count" -ge "$every" ]; then
      due_why="$due_count $word since the last full pass ($lf_desc), [tests] full-every = $every"; return 0
    fi
    due_in=$((every - due_count))
  fi
  due_now=0
}

if [ "$mode" = "--due" ]; then
  changed_paths
  due_check
  if [ "$due_now" -eq 1 ]; then
    echo "check: full tier due: $due_why"
  else
    word=commits; [ "$due_count" -eq 1 ] && word=commit
    echo "check: full tier not due: $due_count $word since the last full pass ($lf_desc), [tests] full-every = $every"
  fi
  exit 0
fi

fingerprint

# gitleaks's version, or "missing". Read once: the cached result depends on it (the key), and the
# secrets step uses it, so a run calls `gitleaks version` at most once.
gl_ver="missing"
if command -v gitleaks >/dev/null 2>&1; then
  gl_ver="$(gitleaks version 2>/dev/null | tr -d 'v \r\n')"
fi
# What a recorded result stands for: the files' fingerprint and gitleaks's version. A removed or changed
# gitleaks makes the cache miss, so --if-changed runs the secrets step again.
key="$fp_value gitleaks=$gl_ver"

# --- the run log and the recorded results ---------------------------------------------------------
# log_run <result> <seconds> <tests run>/<total>: one line in check-runs.log
log_run() {
  now
  printf '%s tier=%s result=%s secs=%s caller=%s commit=%s tests=%s\n' \
    "$now_iso" "$requested" "$1" "$2" "$caller" "$head_short" "$3" >> "$state_dir/check-runs.log"
}
# tests_field: "<run>/<total>" for the log, from the stack's count (tests-count: "<run> <total>") or the last full run's
# total (tests-total); ? for what isn't known.
tests_field() {
  local ran="" total=""
  [ -f "$state_dir/tests-count" ] && read -r ran total < "$state_dir/tests-count"
  [ -n "$total" ] || { [ -f "$state_dir/tests-total" ] && read -r total < "$state_dir/tests-total"; }
  tests_value="${ran:-?}/${total:-?}"
}
# read_record <file>: rec_key (line 1) and line 2's rec_tier, rec_at, rec_commit, rec_caller and rec_run, with rec_hhmm
# from rec_at. A record in the older one-line format has no rec_tier. Returns 1 when there is no record.
read_record() {
  local meta="" w
  rec_key=""; rec_tier=""; rec_at=""; rec_commit=""; rec_caller=""; rec_run=""; rec_hhmm=""
  [ -f "$1" ] || return 1
  { IFS= read -r rec_key; IFS= read -r meta; } < "$1"
  set -f
  for w in $meta; do
    case "$w" in
      tier=*) rec_tier="${w#tier=}" ;;
      at=*) rec_at="${w#at=}" ;;
      commit=*) rec_commit="${w#commit=}" ;;
      caller=*) rec_caller="${w#caller=}" ;;
      run=*) rec_run="${w#run=}" ;;
    esac
  done
  set +f
  case "$rec_tier" in fast|full) ;; *) rec_tier="" ;; esac
  rec_hhmm="${rec_at#*T}"; rec_hhmm="${rec_hhmm%:*}"
  return 0
}
# write_record <pass|fail>: this run's result for these files, the list of the files beside it and, for a fast result,
# the changed paths it checked (with its run, so a reader never takes another run's list for this record's)
write_record() {
  local f="$state_dir/last-$1"
  printf '%s\n\n%s\n' "$fp_paths" "$fp_hashes" \
    | awk '$0 == "" { h = 1; next } !h { p[++n] = $0; next } { print $0 " " p[++m] }' > "$f.files"
  if [ "$tier" = fast ]; then printf 'run=%s\n%s' "$run_id" "$changed_list" > "$f.changed"; else remove "$f.changed"; fi
  now
  printf '%s\ntier=%s at=%s commit=%s caller=%s run=%s\n' "$key" "$tier" "$now_iso" "$head_short" "$caller" "$run_id" > "$f"
}
remove_record() { remove "$state_dir/last-$1"; remove "$state_dir/last-$1.files"; remove "$state_dir/last-$1.changed"; }
# covers: 0 when the record read_record has read covers this request's tier on this commit. A full result covers either
# tier. A fast one covers a fast request on the commit it was recorded on.
covers() { [ "$rec_tier" = full ] || { [ "$rec_tier" = "$requested" ] && [ "$rec_commit" = "$head_short" ]; }; }
# stands <record file>: 0 when the record read_record has read from that file stands for this request: its key is this
# one, and it covers the request (covers), or it is a fast result of another commit and every path that differs from HEAD
# now was among those it checked (checked_within). The fast tier checks the changes from HEAD: committing the work it
# checked moves HEAD on and leaves fewer, while a reset to an earlier commit leaves more, which it didn't check.
stands() {
  [ -n "$rec_tier" ] && [ -n "$fp_value" ] && [ "$rec_key" = "$key" ] || return 1
  covers && return 0
  [ "$rec_tier" = fast ] && [ "$requested" = fast ] && [ -n "$head_full" ] || return 1
  checked_within "$1.changed"
}
# checked_within <.changed file>: 0 when every path in changed_list is in the list of the record read_record has read.
# Costs the changed paths' git calls (the fast tier needs them anyway), only when the commit is another.
checked_within() {
  local first="" checked="" p
  [ -f "$1" ] || return 1
  { IFS= read -r first; IFS= read -r -d '' checked; } < "$1"
  [ "$first" = "run=$rec_run" ] || return 1
  [ "$changed_ready" -eq 1 ] || changed_paths
  checked="$nl$checked"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "$checked" in *"$nl$p$nl"*) ;; *) return 1 ;; esac
  done <<< "$changed_list"
  return 0
}

# reuse <pass|fail> [seconds waited]: repeat the recorded result (read_record has read it), log it, and exit with its
# status. After a wait for another run, the line says the result was recorded while this one waited.
reuse() {
  local total="" flag="" waited_note=""
  [ -z "${2:-}" ] || waited_note=", recorded while this check waited"
  [ -f "$state_dir/tests-total" ] && read -r total < "$state_dir/tests-total"
  log_run "reused-$1" "${2:-0}" "0/${total:-?}"
  if [ "$1" = pass ]; then
    echo "check: PASS (reused the $rec_tier pass at $rec_hhmm, commit $rec_commit, by $rec_caller$waited_note; nothing changed)"
    exit 0
  fi
  [ "$rec_tier" = fast ] && flag=" --fast"
  echo "check: FAIL (reused the $rec_tier failure at $rec_hhmm, commit $rec_commit, by $rec_caller$waited_note; nothing changed; run 'bash tools/check.sh$flag' to see why)"
  exit 1
}

# files_differ <recorded .files>: what differs between the recorded list and the current files, in miss_files, such as
# "src/x.ts and 3 more changed, src/y.ts is new"
files_differ() {
  miss_files="the files changed"
  [ -f "$1" ] || return 0
  miss_files="$(printf '%s\n\n%s\n' "$fp_paths" "$fp_hashes" | awk -v old="$1" '
    function said(n, first, one, many) { return n == 1 ? first " " one : first " and " (n - 1) " more " many }
    BEGIN {
      while ((getline line < old) > 0) {
        i = index(line, " ")
        if (i > 1) { p = substr(line, i + 1); was[p] = substr(line, 1, i - 1); order[++no] = p }
      }
    }
    $0 == "" { h = 1; next }
    !h { path[++np] = $0; next }
    { hash[++nh] = $0 }
    END {
      for (k = 1; k <= np; k++) {
        p = path[k]; cur[p] = 1
        if (!(p in was)) { if (!nn++) fn = p }
        else if (was[p] != hash[k]) { if (!nc++) fc = p }
      }
      for (k = 1; k <= no; k++) if (!(order[k] in cur)) { if (!nr++) fr = order[k] }
      out = ""
      if (nc) out = said(nc, fc, "changed", "changed")
      if (nn) out = out (out == "" ? "" : ", ") said(nn, fn, "is new", "are new")
      if (nr) out = out (out == "" ? "" : ", ") said(nr, fr, "was removed", "were removed")
      print (out == "" ? "the files changed" : out)
    }')"
}

# explain_miss: why no recorded result stands for this request, in cache_note
explain_miss() {
  local kind file rec_gl parts=""
  if [ -z "$fp_value" ]; then cache_note="there are no files to compare (no git repository, or no source files)"; return 0; fi
  if read_record "$state_dir/last-pass"; then kind=pass; file="$state_dir/last-pass.files"
  elif read_record "$state_dir/last-fail"; then kind=failure; file="$state_dir/last-fail.files"
  else cache_note="no result recorded yet"; return 0
  fi
  if [ -z "$rec_tier" ]; then cache_note="the last result was recorded by an older check"; return 0; fi
  if [ "$rec_key" = "$key" ]; then
    if [ "$rec_tier" = fast ] && [ "$requested" = fast ]; then
      cache_note="the fast $kind at $rec_hhmm ($rec_caller) checked the changes from commit $rec_commit; HEAD is now $head_short"
    else
      cache_note="the last $kind was the $rec_tier tier, at $rec_hhmm (commit $rec_commit, $rec_caller)"
    fi
    return 0
  fi
  if [ "${rec_key%% *}" != "$fp_value" ]; then files_differ "$file"; parts="$miss_files"; fi
  rec_gl="${rec_key##* gitleaks=}"
  [ "$rec_gl" = "$gl_ver" ] || parts="${parts:+$parts, }gitleaks changed from $rec_gl to $gl_ver"
  cache_note="${parts:-the files changed} since the $rec_tier $kind at $rec_hhmm (commit $rec_commit, $rec_caller)"
}

failed=0
arch_only=0
[ "$mode" = "--architecture" ] && arch_only=1

# pick_tier: the tier this run goes in (tier), its time limit (limit) and the setting that gives it (limit_where). A fast
# request runs as the full tier with no commit yet, and when more than 100 source paths or 6,000 characters (each path
# and one) differ from HEAD, since the stack check's file lists must fit on one command line. Each reason is said once, though a
# wait picks again.
tier_why=""
pick_tier() {
  local why=""
  tier="$requested"
  if [ "$tier" = fast ]; then
    if [ -z "$head_full" ]; then why="there's no commit yet, so the fast tier runs as the full tier"
    else
      [ "$changed_ready" -eq 1 ] || changed_paths
      if [ "$changed_n" -gt 100 ] || [ "$changed_chars" -gt 6000 ]; then
        why="$changed_n changed source files, so the fast tier runs as the full tier"
      fi
    fi
    [ -z "$why" ] || tier=full
  fi
  [ -z "$why" ] || [ "$why" = "$tier_why" ] || echo "check: note: $why"
  tier_why="$why"
  tier_limit "$tier"; limit="$t_limit"; limit_where="$t_where"
}

# --- the recorded result --------------------------------------------------------------------------
# A recorded result stands for this request when its key is this one and it covers the request (stands). Every miss says
# why before the run starts. The runs recorded now are noted first (pass_before, fail_before): a result that another run
# records from here on, while this one looks or waits, is new to this run, and may stand for it after a wait.
cache_note="not used (run without --if-changed)"
pass_before=""; fail_before=""
if [ "$arch_only" -eq 0 ]; then
  read_record "$state_dir/last-pass"; pass_before="$rec_run"
  read_record "$state_dir/last-fail"; fail_before="$rec_run"
  if [ "$if_changed" -eq 1 ]; then
    for kind in pass fail; do
      if read_record "$state_dir/last-$kind" && stands "$state_dir/last-$kind"; then reuse "$kind"; fi
    done
    explain_miss
    echo "check: running the $requested tier: $cache_note"
  else
    echo "check: running the $requested tier"
  fi
  pick_tier
fi

# --- the run --------------------------------------------------------------------------------------
steps=""
step_done() { steps="${steps:+$steps, }$1 $((SECONDS - step_start)) s"; }  # step_done <name>, since step_start
# couldnt_run: log a run that couldn't go on, and exit 3
couldnt_run() {
  if [ "$arch_only" -eq 0 ]; then tests_field; log_run couldnt-run "$((SECONDS - run_start))" "$tests_value"; fi
  exit 3
}

# The run's background loop, from the moment it holds the lock until it lets it go: every 60 s it touches the lock while
# the lock's line is this run's (the heartbeat: a waiter takes a lock untouched for 5 minutes for stale; a lock another run
# took is that run's to touch), and while the stack check or tools/check.local.sh runs (step_begin names it in
# .app-director/state/check.step) it prints the progress line every 60 s (CHECK_PROGRESS_EVERY seconds; the heartbeat
# comes as often when that is shorter). When the output isn't a terminal the line starts with a line break, since a test
# reporter's dots leave the cursor mid-line. A reader that stops reading early (bash tools/check.sh | head) doesn't end
# the heartbeat: the loop ignores SIGPIPE, and a line it can't write is dropped. The loop runs from / with its sleep's
# output closed, so nothing holds the caller's output or the project folder. The check stops it on every way out, and it
# ends by itself within a tick once the check's process is gone (a check killed with SIGKILL, say), so it never writes to
# the caller's output after the check.
loop_pid=""
tick_every="${CHECK_PROGRESS_EVERY:-60}"
case "$tick_every" in ''|*[!0-9]*|0) tick_every=60 ;; esac
step_file="$state_dir/check.step"
step_begin() { printf '%s %s\n' "$SECONDS" "$1" > "$step_file"; }  # step_begin <what is running>
step_end() { : > "$step_file"; }
start_loop() {
  local abs_lock="$PWD/$lock" abs_step="$PWD/$step_file" nap="$tick_every" lead="" own="$lock_line"
  [ "$nap" -le 60 ] || nap=60
  [ -t 1 ] || lead="$nl"
  step_end
  (
    s=""; parent=$$; shown=""; next=0; d="$nap"
    trap '[ -z "$s" ] || kill "$s" 2>/dev/null; exit 0' TERM
    trap '' PIPE
    cd / || exit 0
    while :; do
      sleep "$d" </dev/null >/dev/null 2>&1 &
      s=$!
      wait "$s"; s=""
      kill -0 "$parent" 2>/dev/null || exit 0
      held=""; { IFS= read -r held < "$abs_lock"; } 2>/dev/null
      [ "$held" != "$own" ] || touch -c "$abs_lock" 2>/dev/null
      line=""; { IFS= read -r line < "$abs_step"; } 2>/dev/null
      d="$nap"
      if [ -z "$line" ]; then shown=""; continue; fi
      # A step it hasn't seen yet: its first line is due tick_every seconds after the step began.
      if [ "$line" != "$shown" ]; then shown="$line"; next=$((${line%% *} + tick_every)); fi
      if [ "$SECONDS" -ge "$next" ]; then
        printf '%scheck: still running %s (%s tier), %s min\n' "$lead" "${line#* }" "$tier" "$(( (SECONDS - ${line%% *}) / 60 ))" 2>/dev/null
        next=$((next + tick_every))
      fi
      [ $((next - SECONDS)) -ge "$d" ] || d=$((next - SECONDS))
      [ "$d" -ge 1 ] || d=1
    done
  ) &
  loop_pid=$!
}
stop_loop() {
  [ -n "$loop_pid" ] || return 0
  kill "$loop_pid" 2>/dev/null
  wait "$loop_pid" 2>/dev/null
  loop_pid=""
}

# --- single flight --------------------------------------------------------------------------------
# A run of either tier holds the lock while it runs; --architecture, --due, --fingerprint, --unignored and a reuse hold
# none. The lock is per checkout: each git worktree has its own .app-director/state, so checks in two worktrees never wait
# for each other. It is created atomically (with noclobber the shell opens it with O_EXCL, so of two runs one gets it),
# and holds pid=<$$> started=<seconds since 1970> at=<HH:MM> caller=<c> tier=<t> limit=<the tier's time limit in s>. In
# Git Bash $$ is the MSYS pid, which kill -0 reads from any other Git Bash process, as on macOS and Linux. The run's
# background loop touches it every 60 s (start_loop), so a lock whose pid now belongs to another process is found out by
# its age on disk. Only its owner removes it, on every way out of the check (the EXIT trap, which stops the loop first; a
# run past its time limit ends through it as well), and a run that finds a stale lock removes that one (drop_stale).
lock="$state_dir/check.lock"
lock_line=""; lock_held=0; lock_started=""; lock_at=""
take_lock() { # take_lock: 0 when this run now holds the lock
  epoch; now
  lock_started="$now_epoch"; lock_at="${now_iso:11:5}"
  lock_line="pid=$$ started=$lock_started at=$lock_at caller=$caller tier=$tier limit=$limit"
  set -C
  if { printf '%s\n' "$lock_line" > "$lock"; } 2>/dev/null; then set +C; lock_held=1; return 0; fi
  set +C
  return 1
}
# relock: after a wait has picked the tier again (after_wait), the lock this run holds names the tier and limit it runs with
relock() {
  local line="pid=$$ started=$lock_started at=$lock_at caller=$caller tier=$tier limit=$limit"
  [ "$line" != "$lock_line" ] || return 0
  lock_line="$line"
  printf '%s\n' "$lock_line" > "$lock"
}
release_lock() { # release_lock: remove the lock when this run holds it, and it is still this run's
  local line=""
  [ "$lock_held" -eq 1 ] || return 0
  lock_held=0
  { IFS= read -r line < "$lock"; } 2>/dev/null
  if [ "$line" = "$lock_line" ]; then rm -f "$lock"; fi
}
# read_lock: the holder's line in h_line, and its pid, start, time, caller, tier and limit in h_pid, h_started, h_at,
# h_caller, h_tier and h_limit (parse_lock). h_pid or h_started is empty while the line isn't whole, and h_limit when it
# has none. Returns 1 when there is no lock.
read_lock() {
  h_line=""
  [ -e "$lock" ] || { parse_lock ""; return 1; }
  { IFS= read -r h_line < "$lock"; } 2>/dev/null || [ -e "$lock" ] || { parse_lock ""; return 1; }
  parse_lock "$h_line"
}
parse_lock() { # parse_lock <line>: a lock's line in h_line, h_pid, h_started, h_at, h_caller, h_tier and h_limit
  local w
  h_line="$1"; h_pid=""; h_started=""; h_at=""; h_caller=""; h_tier=""; h_limit=""
  set -f
  for w in $h_line; do
    case "$w" in
      pid=*) h_pid="${w#pid=}" ;;
      started=*) h_started="${w#started=}" ;;
      at=*) h_at="${w#at=}" ;;
      caller=*) h_caller="${w#caller=}" ;;
      tier=*) h_tier="${w#tier=}" ;;
      limit=*) h_limit="${w#limit=}" ;;
    esac
  done
  set +f
  case "$h_pid" in *[!0-9]*) h_pid="" ;; esac
  case "$h_started" in *[!0-9]*) h_started="" ;; esac
  case "$h_limit" in *[!0-9]*) h_limit="" ;; esac
  return 0
}
# drop_stale <line read>: remove the stale lock this run read as that line. It is moved to a name of this run's own first,
# so nothing can remove a lock another run took after the read. When the moved file isn't the stale one, another run had
# taken the lock in between: its line goes back with noclobber, which can't replace a lock a third run has taken since,
# and this run waits for whichever lock is there.
drop_stale() {
  local moved="$lock.stale-$$-$RANDOM" line=""
  mv -f "$lock" "$moved" 2>/dev/null || return 0
  { IFS= read -r line < "$moved"; } 2>/dev/null
  if [ -n "$line" ] && [ "$line" != "$1" ]; then
    set -C
    { printf '%s\n' "$line" > "$lock"; } 2>/dev/null
    set +C
  fi
  rm -f "$moved"
}
# after_wait <seconds waited>: the run this one waited for is done, or another has taken its place. HEAD is read again
# (a commit may have come meanwhile), and a result recorded since this run started (its run isn't the one recorded then)
# is reused (reuse exits) when it stands for the files as they are now and the request (stands); otherwise the tier is
# picked again for the change as it is now.
after_wait() {
  local kind before
  read_head; changed_ready=0; fp_fresh=0; view_fresh=1
  for kind in pass fail; do
    if [ "$kind" = pass ]; then before="$pass_before"; else before="$fail_before"; fi
    read_record "$state_dir/last-$kind" && [ -n "$rec_tier" ] && [ "$rec_run" != "$before" ] || continue
    [ "$rec_tier" = full ] || [ "$rec_tier" = "$requested" ] || continue
    if [ "$fp_fresh" -eq 0 ]; then fingerprint; key="$fp_value gitleaks=$gl_ver"; fp_fresh=1; fi
    stands "$state_dir/last-$kind" && reuse "$kind" "$1"
  done
  pick_tier
}
# acquire_lock: take the lock, waiting while another run holds it, and remove a stale one with a note. A poll costs one
# kill -0 and, at most every 30 s, one look at the lock's age on disk (the heartbeat).
acquire_lock() {
  local waiting=0 wait_start=0 waited=0 announced="" empty_seen=0 missing=0 why cap="" note_at=0 mtime_at=0 \
    full_limit held_limit stale_after recheck untouched_at="" untouched_of=""
  fp_fresh=1; view_fresh=1
  case "${CHECK_WAIT:-}" in
    '') ;;
    fast|full) tier_limit "$CHECK_WAIT"; cap="$t_limit" ;;
    *[!0-9]*) echo "check: note: CHECK_WAIT=$CHECK_WAIT is neither a number of seconds nor fast or full, so the wait has no cap" ;;
    *) cap="$CHECK_WAIT" ;;
  esac
  # A lock line without its limit is taken to have the full tier's in tools/check.cfg.
  tier_limit full cfg; full_limit="$t_limit"
  recheck="${CHECK_UNTOUCHED_RECHECK:-75}"
  case "$recheck" in ''|*[!0-9]*) recheck=75 ;; esac
  while :; do
    if take_lock; then
      # Taken after a wait, with HEAD and the files not read since the last poll (the run waited for ended, or its stale
      # lock was removed, between two looks): this run reads them now, and runs with the tier they call for.
      if [ "$waiting" -eq 1 ] && [ "$view_fresh" -eq 0 ]; then after_wait "$((SECONDS - wait_start))"; relock; fi
      break
    fi
    # No lock, yet none could be made: once is a race with a run that just ended, three times is a state folder that
    # can't be written.
    if ! read_lock; then
      missing=$((missing + 1))
      [ "$missing" -lt 3 ] || { echo "check: can't create $lock"; couldnt_run; }
      continue
    fi
    missing=0
    if [ -z "$h_pid" ] || [ -z "$h_started" ]; then
      # The shell creates the file, then writes its line: a lock seen twice without a whole line, 2 s apart, was never
      # written.
      if [ "$empty_seen" -eq 1 ]; then
        echo "check: note: removed a stale lock that names no run"
        drop_stale "$h_line"; empty_seen=0
      else
        empty_seen=1; sleep 2 </dev/null >/dev/null 2>&1; view_fresh=0
      fi
      continue
    fi
    empty_seen=0
    why=""
    epoch
    # Each of the stack check and tools/check.local.sh may run for the holder's limit, and the other steps take less than
    # 600 s. The holder's limit is in its line; this run's own counts too, when it is longer.
    held_limit="${h_limit:-$full_limit}"
    [ "$held_limit" -ge "$limit" ] || held_limit="$limit"
    stale_after=$((2 * held_limit + 600))
    # A lock that names this run's own pid is an earlier run's, whose pid this one now has. One whose pid runs but whose
    # file no heartbeat has touched for 5 minutes names a pid that another process has taken since, when that holds at two
    # looks recheck seconds apart: a machine that wakes from sleep wakes the waiter and the holder's heartbeat alike, and
    # the heartbeat's next touch is up to a minute away.
    if [ "$h_pid" = "$$" ] || ! kill -0 "$h_pid" 2>/dev/null; then why="its process is gone"
    elif [ $((now_epoch - h_started)) -gt "$stale_after" ]; then
      why="it is older than $stale_after s, twice the longer of its time limit and this check's, and 600 s"
    elif [ "$SECONDS" -ge "$mtime_at" ]; then
      [ "$untouched_of" = "$h_line" ] || untouched_at=""
      if [ -z "$("$FIND" "$lock" -mmin +5 2>/dev/null)" ]; then
        untouched_at=""; mtime_at=$((SECONDS + 30))
      elif [ -n "$untouched_at" ] && [ $((SECONDS - untouched_at)) -ge "$recheck" ]; then
        why="it hasn't been touched for 5 minutes, though a running check touches it every minute"
      else
        if [ -z "$untouched_at" ]; then untouched_at=$SECONDS; untouched_of="$h_line"; fi
        mtime_at=$((untouched_at + recheck))
      fi
    fi
    if [ -n "$why" ]; then
      echo "check: note: removed a stale lock (pid $h_pid, started $h_at by $h_caller): $why"
      drop_stale "$h_line"; continue
    fi
    if [ "$waiting" -eq 0 ]; then waiting=1; wait_start=$SECONDS; note_at=$tick_every; fi
    if [ "$h_pid $h_started" != "$announced" ]; then
      announced="$h_pid $h_started"
      echo "check: waiting for the check started $h_at by $h_caller ($h_tier tier, pid $h_pid)"
    fi
    waited=$((SECONDS - wait_start))
    if [ -n "$cap" ] && [ "$waited" -ge "$cap" ]; then
      echo "check: busy: the check started $h_at by $h_caller ($h_tier tier) is still running after $waited s; no second check started"
      tests_field; log_run busy "$waited" "0/${tests_value#*/}"
      exit 3
    fi
    if [ "$waited" -ge "$note_at" ]; then
      echo "check: still waiting for the check started $h_at by $h_caller, $((waited / 60)) min"
      note_at=$((note_at + tick_every))
    fi
    sleep 2 </dev/null >/dev/null 2>&1
    view_fresh=0
    # The run it waited for is done, or another has taken its place: what was recorded since may stand for this request.
    if ! read_lock || [ "$h_pid $h_started" != "$announced" ]; then after_wait "$((SECONDS - wait_start))"; fi
  done
  [ "$waiting" -eq 1 ] || return 0
  # This run goes on after the wait: it checks the files as they are now, and says why no result stood for it.
  if [ "$fp_fresh" -eq 0 ]; then fingerprint; key="$fp_value gitleaks=$gl_ver"; fi
  if [ "$if_changed" -eq 1 ]; then explain_miss; echo "check: running the $requested tier after the wait: $cache_note"; fi
}

trap 'stop_loop; release_lock' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

run_start=$SECONDS
if [ "$arch_only" -eq 0 ]; then acquire_lock; start_loop; fi
run_start=$SECONDS   # the summary's time leaves the wait out
now; run_id="${now_iso//[-:]/}-$$"

if [ "$arch_only" -eq 0 ]; then
  : > "$state_dir/stack-summary"
  remove "$state_dir/tests-count"
fi

# --- 1. UI purity check ---------------------------------------------------------------------------
cfg_get ui dirs; ui_dirs="$cfg_value"
cfg_get data dirs; data_dirs="$cfg_value"
cfg_get scan skip; skip_dirs="$cfg_value"

if [ -n "$ui_dirs" ] && [ -n "$data_dirs" ]; then
  echo "check: UI purity"
  step_start=$SECONDS
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
  step_done "UI purity"
fi

# --- 2. Secrets check (gitleaks) ------------------------------------------------------------------
echo "check: secrets"
step_start=$SECONDS
cfg_get gitleaks min-version; gl_min="$cfg_value"
gl_min="${gl_min:-$GITLEAKS_MIN_DEFAULT}"

if [ "$gl_ver" = "missing" ]; then
  echo "check: secrets FAIL: gitleaks not found (need >= $gl_min)."
  echo "       Install: https://github.com/gitleaks/gitleaks#installing"
  echo "       macOS:   brew install gitleaks"
  echo "       Linux:   https://github.com/gitleaks/gitleaks/releases"
  echo "       Windows: winget install gitleaks  or  choco install gitleaks"
  echo "       Then run: bash tools/setup-clone.sh"
  couldnt_run
fi

if ! version_gte "$gl_ver" "$gl_min"; then
  echo "check: secrets FAIL: gitleaks $gl_ver is below minimum $gl_min."
  echo "       Upgrade: https://github.com/gitleaks/gitleaks#installing"
  couldnt_run
fi

gl_report="$state_dir/gitleaks.json"
# gitleaks 8.19.1 is the first release whose `dir` command works; 8.18 scans the folder with
# `detect --no-git`. Both write the same JSON report (a File and a Fingerprint per finding).
# gitleaks 8.19.0 can't scan at all: every command fails with "flag accessed but not defined: source"
# and writes no report. So a failed scan that left no finding in the report is "couldn't scan"
# (exit 3), never "credentials found". The scan's output is kept for that message.
gl_scan() {
  remove "$gl_report"
  if version_gte "$gl_ver" 8.19.1; then
    gitleaks dir --redact --report-path="$gl_report" . 2>&1
  else
    gitleaks detect --no-git --redact --report-path="$gl_report" --source . 2>&1
  fi
}
gl_out="$(gl_scan)"; gl_rc=$?
if [ "$gl_rc" -eq 0 ]; then
  remove "$gl_report"
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
  couldnt_run
fi
step_done secrets

if [ "$arch_only" -eq 1 ]; then
  if [ "$failed" -eq 0 ]; then echo "check: PASS (architecture only)"; exit 0; fi
  echo "check: FAIL (architecture only)"
  exit 1
fi

# --- what the stack check and tools/check.local.sh are given --------------------------------------
# The fast tier's changed paths are those pick_tier counted (read again after a wait), and a fast record keeps them.
if [ "$tier" = fast ]; then
  [ "$changed_ready" -eq 1 ] || changed_paths
  printf '%s' "$changed_list" > "$state_dir/changed"
  export CHECK_CHANGED="$PWD/$state_dir/changed"
else
  unset CHECK_CHANGED
fi
export CHECK_TIER="$tier" CHECK_STATE="$PWD/$state_dir"
# The stack scripts' own [tests] settings: fast (related, all or none), fast-map and workers.
cfg_get tests fast; export CHECK_TESTS_FAST="$cfg_value"
cfg_get tests fast-map; export CHECK_TESTS_FAST_MAP="$cfg_value"
cfg_get tests workers; export CHECK_TESTS_WORKERS="$cfg_value"

# --- test time limit -----------------------------------------------------------------------------
# The tier's limit (pick_tier, above; the lock holds it too). GNU timeout only: Windows' timeout.exe is something else. A
# run past the limit leaves exit status 124.
timeout_cmd=""
for candidate in timeout gtimeout; do
  if "$candidate" --version 2>/dev/null | grep -qi coreutils; then timeout_cmd="$candidate"; break; fi
done
[ -n "$timeout_cmd" ] || echo "check: note: no GNU timeout found: a hung test can't be cut short"
timed_out=""
# run_limited <what> <command...>: run it under the limit, with the progress line; a timeout is noted, not counted as a
# failure.
run_limited() {
  local what="$1" rc; shift
  step_begin "$what"
  if [ -n "$timeout_cmd" ]; then "$timeout_cmd" "$limit" "$@" </dev/null; else "$@"; fi
  rc=$?
  step_end
  if [ "$rc" -eq 124 ] && [ -n "$timeout_cmd" ]; then timed_out="${timed_out:+$timed_out, }$what"; return 0; fi
  return "$rc"
}

# --- 3. Stack check -------------------------------------------------------------------------------
cfg_get project stack; stack="$cfg_value"
if [ -z "$stack" ]; then
  echo "check: note: no stack set in tools/check.cfg [project] stack; only architecture checks ran"
else
  stack_script="tools/stacks/$stack.sh"
  if [ ! -f "$stack_script" ]; then
    echo "check: can't find $stack_script; run: bash tools/setup-clone.sh"
    couldnt_run
  fi
  echo "check: stack ($stack)"
  step_start=$SECONDS
  if ! run_limited "the stack check" bash "$stack_script"; then
    echo "check: stack check failed"
    failed=1
  fi
  step_done stack
fi

# --- 4. Custom check ------------------------------------------------------------------------------
if [ -f tools/check.local.sh ]; then
  echo "check: running tools/check.local.sh"
  step_start=$SECONDS
  if ! run_limited "tools/check.local.sh" bash tools/check.local.sh; then
    echo "check: tools/check.local.sh failed"
    failed=1
  fi
  step_done tools/check.local.sh
fi

# --- the summary ----------------------------------------------------------------------------------
# print_summary <PASS|FAIL|COULDN'T RUN>: the run's tier, result, time and steps, the stack's own lines from
# stack-summary, and what the cache found. A "left to the full tier" line comes last.
print_summary() {
  local line left=""
  echo "check: summary: $tier tier, $1 in $((SECONDS - run_start)) s"
  [ -z "$steps" ] || echo "check:   steps: $steps"
  if [ -s "$state_dir/stack-summary" ]; then
    while IFS= read -r line; do
      case "$line" in
        '') ;;
        "left to the full tier:"*) left="${left:+$left$nl}check:   $line" ;;
        *) echo "check:   $line" ;;
      esac
    done < "$state_dir/stack-summary"
  fi
  echo "check:   cache: $cache_note"
  [ -z "$left" ] || printf '%s\n' "$left"
}
end_log() { tests_field; log_run "$1" "$((SECONDS - run_start))" "$tests_value"; trim_log; }  # end_log <result>
# trim_log: the run log keeps its last 500 lines once it passes 1000
trim_log() {
  local f="$state_dir/check-runs.log" n
  [ -f "$f" ] || return 0
  n="$(wc -l < "$f")"; n="${n//[[:space:]]/}"
  [ "${n:-0}" -gt 1000 ] || return 0
  tail -n 500 "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

# --- a test run hit the limit ---------------------------------------------------------------------
if [ -n "$timed_out" ]; then
  # A failure seen before the timeout wins and exits 1 below. Exit 3 only when none was seen.
  if [ "$failed" -eq 0 ]; then
    remove_record pass
    print_summary "COULDN'T RUN"
    echo "check: couldn't run to the end: $timed_out timed out after ${limit} s (the $tier tier's limit, $limit_where)"
    echo "check: to go on, run it again in the background with a longer limit, 'CHECK_TIMEOUT=<seconds> bash tools/check.sh --$tier': a commit then reuses its pass, since the limit isn't part of what a pass stands for. Or raise [tests] timeout-$tier in tools/check.cfg."
    end_log couldnt-run
    exit 3
  fi
  echo "check: couldn't run to the end: $timed_out timed out after ${limit} s (the $tier tier's limit, $limit_where)"
fi

# --- result ---------------------------------------------------------------------------------------
hooks_dir="$(git rev-parse --git-path hooks 2>/dev/null)"
if [ -n "$hooks_dir" ] && ! grep -qs "App Director" "$hooks_dir/pre-commit" 2>/dev/null; then
  echo "check: note: this clone has no App Director pre-commit hook. Run: bash tools/setup-clone.sh"
fi

# A result is recorded only for the files it checked: the fingerprint is taken again, and must be the same.
before="$fp_value"
fingerprint
stable=0
if [ -n "$before" ] && [ "$fp_value" = "$before" ]; then stable=1; fi

if [ "$failed" -eq 0 ]; then
  if [ "$stable" -eq 1 ]; then
    # A fast pass doesn't replace a full pass of the same files: the full one covers more.
    if [ "$tier" = full ] || ! { read_record "$state_dir/last-pass" && [ "$rec_tier" = full ] && [ "$rec_key" = "$key" ]; }; then
      write_record pass
    fi
  elif [ -n "$before" ]; then
    echo "check: note: files changed while the check ran; run it again to cover the changes."
  fi
  remove_record fail
  if [ "$tier" = full ]; then
    if [ "$stable" -eq 1 ] && [ -n "$head_full" ]; then now; printf '%s %s\n' "$head_full" "$now_iso" > "$state_dir/last-full"; fi
    result="check: PASS (full tier)"
  else
    due_check
    if [ "$due_now" -eq 1 ]; then result="check: PASS (fast tier; full tier due now: $due_why)"
    elif [ -n "$due_in" ]; then
      word=commits; [ "$due_in" -eq 1 ] && word=commit
      result="check: PASS (fast tier; full tier due in $due_in $word)"
    else result="check: PASS (fast tier; full tier not due by count, [tests] full-every = 0)"
    fi
  fi
  print_summary PASS
  echo "$result"
  end_log pass
  exit 0
fi
remove_record pass
[ "$stable" -eq 1 ] && write_record fail
print_summary FAIL
echo "check: FAIL ($tier tier; logs above)"
end_log fail
exit 1
