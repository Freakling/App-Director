#!/usr/bin/env bash
# App Director TypeScript stack check · framework-owned: replaced on upgrade.
# Expects: node, npm (or pnpm or yarn), tsc, eslint, vitest or jest.
#
# tools/check.sh runs it from the repository root with:
#   CHECK_TIER     full: tsc, eslint and the tests over the whole project. fast: tsc over the whole project
#                  (incremental), eslint on the changed files, and the tests by [tests] fast: related (the default: the
#                  tests related to the change, by vitest related or jest --findRelatedTests), all, or none
#   CHECK_CHANGED  in the fast tier, a file listing the changed paths from the repository root, one per line
#   CHECK_STATE    .app-director/state, an absolute path: tsc's build info and vitest's json report are kept there, and
#                  the lines this script writes to $CHECK_STATE/stack-summary are printed in the check's summary
#   CHECK_TESTS_FAST, CHECK_TESTS_FAST_MAP, CHECK_TESTS_WORKERS: [tests] fast, fast-map and workers from tools/check.cfg
# [tests] fast-map rules, <changed-path pattern>:<test path>, run the named test for a changed path that matches,
# instead of every test related to it. vitest gets the dot reporter when the output isn't a terminal, and always the json
# report, which gives the summary its test count and, after a full run, the ten slowest test files. [tests] workers
# (a whole number) sets vitest's --maxWorkers; empty leaves it to the project's vitest config.
set -e
nl='
'
tier="${CHECK_TIER:-full}"
state="${CHECK_STATE:-$PWD/.app-director/state}"
summary="$state/stack-summary"
STACK_ROOT="${STACK_ROOT:-.}"
# The project's folder from the repository root, when it isn't the root: the changed paths are the repository's.
prefix=""
case "$STACK_ROOT" in .|./) ;; *) prefix="${STACK_ROOT#./}"; prefix="${prefix%/}/" ;; esac
cd "$STACK_ROOT"
[ -d "$state" ] || mkdir -p "$state"
fact() { printf '%s\n' "$1" >> "$summary"; }  # fact <line>: a line for the check's summary

# Install dependencies if needed.
if [ ! -d node_modules ]; then
  if [ -f pnpm-lock.yaml ]; then pnpm install --frozen-lockfile --silent
  elif [ -f yarn.lock ]; then yarn install --frozen-lockfile --silent
  else npm install --silent
  fi
fi

# matches <path> <pattern>: a bash case pattern against the path; one that ends in / is a folder, and matches everything
# under it.
matches() {
  case "$2" in
    */) case "$1" in "$2"*) return 0 ;; esac ;;
    *) case "$1" in $2) return 0 ;; esac ;;
  esac
  return 1
}

# The fast tier's files: lint, the changed files eslint reads that still exist; related, the changed source files whose
# related tests run, less those a fast-map rule matches; mapped, the tests those rules name instead.
lint=(); related=(); mapped=()
if [ "$tier" = fast ]; then
  set -f; rules=(${CHECK_TESTS_FAST_MAP:-}); set +f
  while IFS= read -r path || [ -n "$path" ]; do
    p="$path"
    if [ -n "$prefix" ]; then
      case "$p" in "$prefix"*) p="${p#"$prefix"}" ;; *) continue ;; esac
    fi
    case "$p" in ''|node_modules/*) continue ;; esac
    # A removed file has no tests of its own left; tsc over the project finds what still imports it.
    [ -f "$p" ] || continue
    case "$p" in *.ts|*.tsx|*.js|*.jsx|*.mjs|*.cjs) lint+=("$p") ;; esac
    hit=0
    for rule in "${rules[@]}"; do
      case "$rule" in *?:?*) ;; *) continue ;; esac
      if ! matches "$path" "${rule%%:*}"; then continue; fi
      hit=1; test_path="${rule#*:}"
      if [ -n "$prefix" ]; then test_path="${test_path#"$prefix"}"; fi
      seen=0
      for m in "${mapped[@]}"; do if [ "$m" = "$test_path" ]; then seen=1; fi; done
      if [ "$seen" -eq 0 ]; then
        mapped+=("$test_path")
        if [ ! -f "$test_path" ]; then echo "check: note: [tests] fast-map names $test_path, which doesn't exist"; fi
      fi
    done
    if [ "$hit" -eq 1 ]; then continue; fi
    case "$p" in *.ts|*.tsx|*.js|*.jsx|*.mjs|*.cjs|*.json|*.dart|*.py|*.yaml|*.yml) related+=("$p") ;; esac
  done < "${CHECK_CHANGED:-/dev/null}"
fi

# Type check, over the whole project in both tiers.
if [ "$tier" = fast ]; then
  npx tsc --noEmit --incremental --tsBuildInfoFile "$state/tsc-fast.tsbuildinfo"
else
  npx tsc --noEmit
fi

# Lint (fail on any warning). The fast tier lints the changed files; an ignored file named on the command line is a
# warning under a flat config, unless --no-warn-ignored says otherwise.
left=""
if [ -f .eslintrc.json ] || [ -f .eslintrc.js ] || [ -f .eslintrc.cjs ] || [ -f eslint.config.js ] || [ -f eslint.config.mjs ]; then
  if [ "$tier" != fast ]; then
    npx eslint . --max-warnings 0
  elif [ "${#lint[@]}" -eq 0 ]; then
    echo "check: eslint skipped: no changed file to lint"
  else
    flat=()
    for f in eslint.config.*; do if [ -f "$f" ]; then flat=(--no-warn-ignored); fi; done
    npx eslint --max-warnings 0 "${flat[@]}" "${lint[@]}"
  fi
  left="eslint on unchanged files"
fi

# The test count and, after a full run, the ten slowest test files, from vitest's json report. The first line printed is
# the count; each line after it is "<seconds> <path from the repository root>".
# One line, with no colon: Git Bash rewrites an argument that looks like a list of paths before node sees it.
report_js='const fs = require("fs"), path = require("path"); const r = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); let n = ""; if (Number.isInteger(r.numTotalTests)) n = r.numTotalTests; console.log(n); if (process.argv[2] === "full") (r.testResults || []).map(t => [(t.endTime || 0) - (t.startTime || 0), (process.argv[3] || "") + path.relative(process.cwd(), String(t.name)).split(path.sep).join("/")]).sort((a, b) => b[0] - a[0]).slice(0, 10).forEach(e => console.log((e[0] / 1000).toFixed(1) + " " + e[1]));'
vitest_report() { # vitest_report <whole suite: 1 or 0>
  local report="" ran="" total="" line
  if [ -f "$state/vitest.json" ] && command -v node >/dev/null 2>&1; then
    report="$(node -e "$report_js" "$state/vitest.json" "$tier" "$prefix" 2>/dev/null)" || report=""
  fi
  ran="${report%%"$nl"*}"
  case "$ran" in ''|*[!0-9]*) ran="" ;; esac
  if [ "$1" -eq 1 ]; then
    total="$ran"
    if [ -n "$ran" ]; then printf '%s\n' "$ran" > "$state/tests-total"; fi
  elif [ -f "$state/tests-total" ]; then
    read -r total < "$state/tests-total" || true
  fi
  case "$total" in *[!0-9]*) total="" ;; esac
  if [ -z "$ran" ]; then
    fact "tests: the count isn't known (no vitest json report, or no node to read it)"
  else
    printf '%s %s\n' "$ran" "${total:-?}" > "$state/tests-count"
    if [ "$1" -eq 1 ]; then fact "tests: $ran run, the whole suite"
    elif [ -n "$total" ] && [ "$total" -ge "$ran" ]; then fact "tests: $ran of $total run, $((total - ran)) not related to the change"
    else fact "tests: $ran run, related to the change (the whole suite's count comes with a full run)"
    fi
  fi
  case "$report" in *"$nl"*) ;; *) return 0 ;; esac
  if [ "$tier" = full ]; then
    echo "check: slowest test files (full tier):"
    while IFS= read -r line; do printf '  %6s s  %s\n' "${line%% *}" "${line#* }"; done <<< "${report#*"$nl"}"
  fi
}

# Tests.
vitest=0; jest=0
if [ -f vitest.config.ts ] || [ -f vitest.config.js ] || [ -f vitest.config.mjs ]; then vitest=1
elif [ -f jest.config.ts ] || [ -f jest.config.js ] || grep -q '"jest"' package.json 2>/dev/null; then jest=1
fi
run=all
if [ "$tier" = fast ]; then
  run="${CHECK_TESTS_FAST:-related}"
  case "$run" in
    related|all|none) ;;
    *) echo "check: note: [tests] fast = $run isn't related, all or none; running the related tests"; run=related ;;
  esac
fi
status=0
if [ "$vitest" -eq 1 ] || [ "$jest" -eq 1 ]; then
  if [ "$run" = none ]; then
    echo "check: tests skipped: [tests] fast = none"
    fact "tests: none run ([tests] fast = none)"
    left="every test${left:+, $left}"
  elif [ "$run" = related ] && [ "${#related[@]}" -eq 0 ] && [ "${#mapped[@]}" -eq 0 ]; then
    echo "check: no tests related to the change"
    fact "tests: no tests related to the change"
    left="the tests not related to the change${left:+, $left}"
  elif [ "$vitest" -eq 1 ]; then
    options=()
    if [ -t 1 ]; then options+=(--reporter=default); else options+=(--reporter=dot); fi
    options+=(--reporter=json "--outputFile.json=$state/vitest.json")
    workers="${CHECK_TESTS_WORKERS:-}"
    case "$workers" in
      '') ;;
      *[!0-9]*|0) echo "check: note: [tests] workers = $workers isn't a whole number of 1 or more; left to vitest" ;;
      *) options+=("--maxWorkers=$workers") ;;
    esac
    if [ -f "$state/vitest.json" ]; then rm -f "$state/vitest.json"; fi
    if [ "$run" = related ]; then
      npx vitest related --run --passWithNoTests "${options[@]}" "${related[@]}" "${mapped[@]}" || status=$?
      vitest_report 0
      left="the tests not related to the change${left:+, $left}"
    else
      npx vitest run "${options[@]}" || status=$?
      vitest_report 1
    fi
  elif [ "$run" = related ]; then
    npx jest --findRelatedTests "${related[@]}" "${mapped[@]}" --passWithNoTests || status=$?
    fact "tests: jest, the tests related to the change"
    left="the tests not related to the change${left:+, $left}"
  else
    npx jest --passWithNoTests || status=$?
  fi
fi
if [ "$tier" = fast ] && [ -n "$left" ]; then fact "left to the full tier: $left"; fi
exit "$status"
