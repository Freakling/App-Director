#!/usr/bin/env bash
# App Director project check · framework-owned: replaced on upgrade.
#
# The single definition of "it works", in two tiers:
#   bash tools/check.sh                    the full tier: every step over the whole project. Same as --full
#   bash tools/check.sh --fast             the fast tier: the same steps, with the stack check doing what the change needs
#                                          (TypeScript: tsc over the project, eslint on the changed files, the related tests)
#   bash tools/check.sh --if-changed       with either tier: repeat the recorded result at once when these exact files were
#                                          checked with this gitleaks by a tier that covers the request (a full result covers
#                                          a fast request; a fast result never covers a full one); a miss says what changed
#   bash tools/check.sh --due              say whether the full tier is due (below), and run nothing else
#   bash tools/check.sh --fingerprint      print the fingerprint of the current files (for hooks)
#   bash tools/check.sh --architecture     run only the UI purity and secrets checks (fast, no build)
# Flags combine in any order. Exit codes: 0 = pass · 1 = fail · 3 = couldn't run (gitleaks missing, old or unable to scan,
# stack tool missing, a test run hit its time limit, or an unknown flag)
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
# With no commit yet, the fast tier runs as the full tier.
#
# The full tier is due (--due, and the result line of a fast pass) when no full pass is recorded
# (.app-director/state/last-full), when [tests] full-every commits (default 10; 0 = never by count) were made since it, or
# when a changed path matches [tests] full-when or the framework's own list (full_when_framework below). Patterns, there
# and in [tests] ignore and fast-map, are bash case patterns against the path from the repository root; one that ends in
# / is a folder and matches everything under it.
#
# Settings are in tools/check.cfg. State is kept in .app-director/state/:
#   last-pass, last-fail  line 1 the key (the fingerprint and gitleaks's version), line 2 the tier, time, commit, caller
#                         and run; beside each a .files list (<blob hash> <path>), which names what changed on a miss
#   check-runs.log        one line per run or reuse, trimmed to its last 500 lines past 1000. CHECK_CALLER names the
#                         caller (the hooks set it; manual when unset)
# The stack check and tools/check.local.sh are each limited to [tests] timeout-fast seconds in the fast tier (default 300)
# and timeout-full in the full tier (default 3600; the older [tests] timeout counts when timeout-full isn't set).
# CHECK_TIMEOUT overrides both. GNU timeout (or gtimeout) is needed; a run that hits the limit exits 3, unless a failure
# was already seen (then it exits 1). While either runs, a line every 60 s (CHECK_PROGRESS_EVERY seconds) says so.
# gitleaks minimum version is read from check.cfg [gitleaks] min-version (default 8.18.0).

set -u
cd "$(dirname "$0")/.." || exit 3
state_dir=".app-director/state"
GITLEAKS_MIN_DEFAULT="8.18.0"
nl='
'
# Paths that make the full tier due whenever they change: dependencies, toolchain settings and the tools themselves.
full_when_framework="package.json package-lock.json pnpm-lock.yaml yarn.lock tools/* tsconfig*.json vitest.config.* vite.config.* jest.config.* eslint.config.* .eslintrc* pyproject.toml requirements*.txt pubspec.yaml pubspec.lock analysis_options.yaml"
usage="usage: bash tools/check.sh [--full | --fast] [--if-changed] | --due | --fingerprint | --architecture"

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
    --due|--fingerprint|--architecture) mode="$arg" ;;
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

cfg_get tests ignore; ignore="$cfg_value"

# The files that can change the result: the tracked and untracked files with the code extensions and the check's own
# files, less the dependency and build folders and the paths under [tests] ignore. fingerprint sets fp_paths (one per
# line), fp_hashes (each one's blob hash, in the same order, from one git call) and fp_value, the hash of both. Outside a
# git repository there are no paths, and all three are empty.
fingerprint() {
  fp_hashes=""; fp_value=""
  fp_paths="$(git -c core.quotePath=false ls-files -z -c -o --exclude-standard 2>/dev/null \
    | tr '\0' '\n' \
    | grep -E '\.(ts|tsx|js|jsx|mjs|dart|py|json|yaml|yml)$|^tools/check\.(cfg|sh|local\.sh)$|^\.gitleaks(\.toml|ignore)$' \
    | while IFS= read -r p; do
        case "$p" in node_modules/*|dist/*|build/*|.dart_tool/*|__pycache__/*) continue ;; esac
        if [ -n "$ignore" ] && path_in "$p" "$ignore"; then continue; fi
        [ -f "$p" ] && printf '%s\n' "$p"
      done)"
  [ -n "$fp_paths" ] || return 0
  fp_hashes="$(git hash-object --no-filters --stdin-paths <<< "$fp_paths")"
  fp_value="$(git hash-object --stdin <<< "$fp_paths$nl$fp_hashes")"
}

if [ "$mode" = "--fingerprint" ]; then fingerprint; [ -z "$fp_value" ] || printf '%s\n' "$fp_value"; exit 0; fi
[ -d "$state_dir" ] || mkdir -p "$state_dir" || exit 3

head_full="$(git rev-parse -q --verify HEAD 2>/dev/null)"
head_short="${head_full:0:7}"; [ -n "$head_short" ] || head_short="none"
caller="${CHECK_CALLER:-manual}"; caller="${caller//[[:space:]]/-}"

# changed_paths: the paths that differ from HEAD, staged or not (deletions too), and the untracked files git doesn't
# ignore, less [tests] ignore and the check's own state, one per line in changed_list.
changed_paths() {
  local raw p
  changed_list=""
  raw="$( { git diff --name-only --no-renames -z HEAD -- 2>/dev/null; git ls-files -o --exclude-standard -z 2>/dev/null; } \
    | tr '\0' '\n')"
  while IFS= read -r p; do
    case "$p" in ''|.app-director/state/*) continue ;; esac
    if [ -n "$ignore" ] && path_in "$p" "$ignore"; then continue; fi
    changed_list="$changed_list$p$nl"
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
# read_record <file>: rec_key (line 1) and line 2's rec_tier, rec_at, rec_commit, rec_caller, with rec_hhmm from rec_at.
# A record in the older one-line format has no rec_tier. Returns 1 when there is no record.
read_record() {
  local meta="" w
  rec_key=""; rec_tier=""; rec_at=""; rec_commit=""; rec_caller=""; rec_hhmm=""
  [ -f "$1" ] || return 1
  { IFS= read -r rec_key; IFS= read -r meta; } < "$1"
  set -f
  for w in $meta; do
    case "$w" in
      tier=*) rec_tier="${w#tier=}" ;;
      at=*) rec_at="${w#at=}" ;;
      commit=*) rec_commit="${w#commit=}" ;;
      caller=*) rec_caller="${w#caller=}" ;;
    esac
  done
  set +f
  case "$rec_tier" in fast|full) ;; *) rec_tier="" ;; esac
  rec_hhmm="${rec_at#*T}"; rec_hhmm="${rec_hhmm%:*}"
  return 0
}
# write_record <pass|fail>: this run's result for these files, and the list of the files beside it
write_record() {
  local f="$state_dir/last-$1"
  printf '%s\n\n%s\n' "$fp_paths" "$fp_hashes" \
    | awk '$0 == "" { h = 1; next } !h { p[++n] = $0; next } { print $0 " " p[++m] }' > "$f.files"
  now
  printf '%s\ntier=%s at=%s commit=%s caller=%s run=%s\n' "$key" "$tier" "$now_iso" "$head_short" "$caller" "$run_id" > "$f"
}
remove_record() { remove "$state_dir/last-$1"; remove "$state_dir/last-$1.files"; }

# reuse <pass|fail>: repeat the recorded result (read_record has read it), log it, and exit with its status.
reuse() {
  local total="" flag=""
  [ -f "$state_dir/tests-total" ] && read -r total < "$state_dir/tests-total"
  log_run "reused-$1" 0 "0/${total:-?}"
  if [ "$1" = pass ]; then
    echo "check: PASS (reused the $rec_tier pass at $rec_hhmm, commit $rec_commit, by $rec_caller; nothing changed)"
    exit 0
  fi
  [ "$rec_tier" = fast ] && flag=" --fast"
  echo "check: FAIL (reused the $rec_tier failure at $rec_hhmm, commit $rec_commit, by $rec_caller; nothing changed; run 'bash tools/check.sh$flag' to see why)"
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
    cache_note="the last $kind was the $rec_tier tier, at $rec_hhmm (commit $rec_commit, $rec_caller)"; return 0
  fi
  if [ "${rec_key%% *}" != "$fp_value" ]; then files_differ "$file"; parts="$miss_files"; fi
  rec_gl="${rec_key##* gitleaks=}"
  [ "$rec_gl" = "$gl_ver" ] || parts="${parts:+$parts, }gitleaks changed from $rec_gl to $gl_ver"
  cache_note="${parts:-the files changed} since the $rec_tier $kind at $rec_hhmm (commit $rec_commit, $rec_caller)"
}

failed=0
arch_only=0
[ "$mode" = "--architecture" ] && arch_only=1

# --- the recorded result --------------------------------------------------------------------------
# A recorded result stands for this request when its key is this one and its tier covers the request: a full result
# covers both tiers, a fast one only the fast tier. Every miss says why before the run starts.
cache_note="not used (run without --if-changed)"
if [ "$arch_only" -eq 0 ]; then
  if [ "$if_changed" -eq 1 ]; then
    if [ -n "$fp_value" ]; then
      for kind in pass fail; do
        if read_record "$state_dir/last-$kind" && [ -n "$rec_tier" ] && [ "$rec_key" = "$key" ] \
            && { [ "$rec_tier" = full ] || [ "$rec_tier" = "$requested" ]; }; then
          reuse "$kind"
        fi
      done
    fi
    explain_miss
    echo "check: running the $requested tier: $cache_note"
  else
    echo "check: running the $requested tier"
  fi
  if [ "$tier" = fast ] && [ -z "$head_full" ]; then
    echo "check: note: there's no commit yet, so the fast tier runs as the full tier"
    tier=full
  fi
fi

# --- the run --------------------------------------------------------------------------------------
run_start=$SECONDS
now; run_id="${now_iso//[-:]/}-$$"
steps=""
step_done() { steps="${steps:+$steps, }$1 $((SECONDS - step_start)) s"; }  # step_done <name>, since step_start
# couldnt_run: log a run that couldn't go on, and exit 3
couldnt_run() {
  if [ "$arch_only" -eq 0 ]; then tests_field; log_run couldnt-run "$((SECONDS - run_start))" "$tests_value"; fi
  exit 3
}

# The progress line: while the stack check or tools/check.local.sh runs, one line every 60 s (CHECK_PROGRESS_EVERY). The
# ticker runs from / with its sleep's output closed, so nothing holds the caller's output or the project folder, and
# it is stopped on every way out of the check.
ticker_pid=""
tick_every="${CHECK_PROGRESS_EVERY:-60}"
case "$tick_every" in ''|*[!0-9]*|0) tick_every=60 ;; esac
start_ticker() { # start_ticker <what is running>
  local what="$1" started=$SECONDS
  (
    s=""
    trap '[ -z "$s" ] || kill "$s" 2>/dev/null; exit 0' TERM
    cd / || exit 0
    while :; do
      sleep "$tick_every" </dev/null >/dev/null 2>&1 &
      s=$!
      wait "$s"
      echo "check: still running $what ($tier tier), $(( (SECONDS - started) / 60 )) min"
    done
  ) &
  ticker_pid=$!
}
stop_ticker() {
  [ -n "$ticker_pid" ] || return 0
  kill "$ticker_pid" 2>/dev/null
  wait "$ticker_pid" 2>/dev/null
  ticker_pid=""
}
trap 'stop_ticker' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

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
if [ "$tier" = fast ]; then
  changed_paths
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
# [tests] timeout-fast (default 300 s) or timeout-full (default 3600 s; [tests] timeout when it isn't set) in
# tools/check.cfg; CHECK_TIMEOUT overrides both. GNU timeout only: Windows' timeout.exe is something else. A run past the
# limit leaves exit status 124.
if [ "$tier" = fast ]; then
  cfg_get tests timeout-fast; limit="$cfg_value"; limit_name="[tests] timeout-fast"; limit_default=300
else
  cfg_get tests timeout-full; limit="$cfg_value"; limit_name="[tests] timeout-full"; limit_default=3600
  if [ -z "$limit" ]; then cfg_get tests timeout; limit="$cfg_value"; [ -z "$limit" ] || limit_name="[tests] timeout"; fi
fi
limit_where="$limit_name in tools/check.cfg"
if [ -n "${CHECK_TIMEOUT:-}" ]; then limit="$CHECK_TIMEOUT"; limit_name="CHECK_TIMEOUT"; limit_where="CHECK_TIMEOUT"; fi
case "$limit" in ''|*[!0-9]*|0) limit="$limit_default" ;; esac
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
  start_ticker "$what"
  if [ -n "$timeout_cmd" ]; then "$timeout_cmd" "$limit" "$@" </dev/null; else "$@"; fi
  rc=$?
  stop_ticker
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
    echo "check: to go on, raise $limit_name, or run 'bash tools/check.sh --$tier' again in the background: a commit then reuses its pass."
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
