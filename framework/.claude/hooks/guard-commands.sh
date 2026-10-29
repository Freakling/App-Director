#!/usr/bin/env bash
# App Director command guard · Claude Code PreToolUse hook on Bash · framework-owned: replaced on upgrade.
#
# Permission rules match how a command starts, so `git commit -m x --no-verify` or
# `git push origin main --force` would slip past them. This hook looks at the whole command and
# blocks what rules.md › Git reserves for the human: rewriting history, discarding work, and
# skipping the check. It pattern-matches the text, so it's a strong safety net, not a guarantee.
# It starts no other processes (it runs on every Bash call).
#
# It also blocks the git flags that write a file, read a file outside the repository or run a
# configured command (--output, --no-index, --ext-diff, commit -F and --file), because the allow
# rules in settings.json let `git diff *`, `git log *`, `git show *`, `git commit *` and
# `git stash *` run with any flag. See the section "git: flags that write a file" below.
#
# Also blocks shell commands that read credential files (.env, *.pem, *.key) directly. This is a
# guardrail, not a guarantee: complex pipelines or indirect reads are not detected. The Read-tool
# deny rules in settings.json cover the most common path.

IFS= read -r -d '' input || true
re='"command"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)"'
[[ $input =~ $re ]] || exit 0
raw="${BASH_REMATCH[1]}"

# Blank quoted strings so a commit message or filename can't trip flag tests.
code="$raw"
dq='\\"([^\\]|\\[^"])*\\"'
while [[ $code =~ $dq ]]; do code="${code/"${BASH_REMATCH[0]}"/ Q }"; done
sq="'[^']*'"
while [[ $code =~ $sq ]]; do code="${code/"${BASH_REMATCH[0]}"/ Q }"; done

block() {
  echo "App Director: blocked: $1. If it's really needed, ask the human to run it." >&2
  exit 2
}

# --- Credential file reads ------------------------------------------------------------------------
# Block direct shell reads of .env, *.pem, *.key: these files may hold live credentials.
# Any credential read in a conversation context must be considered compromised and rotated.
# This is a best-effort check on the command text; indirect reads are not detected.
reads_cred_file() {
  local cmd="$raw"
  # Commands that print file contents
  [[ $cmd =~ (^|[[:space:]|;&])(cat|head|tail|less|more|strings)[[:space:]]+(\.\/)?\.env([[:space:]|;&]|$) ]] && return 0
  [[ $cmd =~ (^|[[:space:]|;&])(cat|head|tail|less|more|strings)[[:space:]]+[^[:space:]]*(\.pem|\.key)([[:space:]|;&]|$) ]] && return 0
  return 1
}
if reads_cred_file; then
  echo "App Director: blocked: reading credential files exposes secrets to the AI context." >&2
  echo "              Use .env.example for documentation; real credentials stay out of AI context." >&2
  echo "              Any credential read in a conversation must be treated as compromised and rotated." >&2
  exit 2
fi

# --- Hangs ---------------------------------------------------------------------------------------
# A command that never returns, or runs past five minutes, lets the prompt cache expire, and the next
# turn rewrites the whole context. So: no empty-heredoc probes, no unbounded wait loops, no long sleeps.
# Text matching only: a loop built another way isn't seen. The guard is also wired to Monitor.
nl=$'\n'
hang() {
  echo "App Director: blocked: $1" >&2
  echo "              $2" >&2
  exit 2
}
limit_s=280

# 1. `python - <<'EOF'` whose body is empty: Python waits for console input and never returns on
#    Windows. Typically the "is Python here?" probe.
text="${raw//\\r/}"; text="${text//\\n/$nl}"
heredoc_re='(^|[^[:alnum:]_./-])(python3?|py)(\.exe)?[[:space:]]+-[[:space:]]*<<-?[[:space:]]*\\?["'"'"']?([A-Za-z_][A-Za-z0-9_]*)'
IFS=$'\n' read -r -d '' -a lines <<<"$text" || true
for ((i = 0; i + 1 < ${#lines[@]}; i++)); do
  if [[ ${lines[i]} =~ $heredoc_re ]]; then
    delim="${BASH_REMATCH[4]}"; next="${lines[i + 1]//[[:space:]]/}"
    [ "$next" = "$delim" ] && hang "python reading an empty heredoc waits for console input and never returns (on Windows)." \
      "To test whether Python is there, run: python3 --version"
  fi
done

# 3. A lone sleep over 280 seconds.
sleep_re='(^|[^[:alnum:]_./-])sleep[[:space:]]+([0-9]+)([smhd]?)([[:space:]]|$|[;&|)])'
rest="$code"
while [[ $rest =~ $sleep_re ]]; do
  n="${BASH_REMATCH[2]}"; unit="${BASH_REMATCH[3]}"; secs=$((10#$n))
  case "$unit" in m) secs=$((secs * 60)) ;; h) secs=$((secs * 3600)) ;; d) secs=$((secs * 86400)) ;; esac
  [ "$secs" -gt "$limit_s" ] && hang "sleep $n$unit is longer than $limit_s seconds, and a wait past five minutes lets the prompt cache expire." \
    "Start the work with run_in_background and keep working until its completion notice, or wait in steps of $limit_s seconds or less."
  rest="${rest#*"${BASH_REMATCH[0]}"}"
done

# 2. until/while loops that sleep: under `timeout N` (N <= 280), or ended by the exit line Claude Code
#    appends to a background command's output. A loop quoted into `bash -c '...'` is read from the raw text.
scan="$code"
[[ $code =~ (bash|sh|zsh)[[:space:]]+-[a-z]*c[[:space:]] ]] && scan="$raw"
scan="${scan//\\n/$nl}"
loop_re='(^|[^[:alnum:]_./-])(until|while)[[:space:]]'
timeout_re="(^|[^[:alnum:]_./-])timeout[[:space:]]+(-[-[:alnum:]=]+[[:space:]]+)*([0-9]+)([sm]?)[[:space:]]+[^;&|$nl]*\$"
rest="$scan"; before=""
while [[ $rest =~ $loop_re ]]; do
  before="$before${rest%%"${BASH_REMATCH[0]}"*}${BASH_REMATCH[1]}"
  rest="${rest#*"${BASH_REMATCH[0]}"}"
  loop="${rest%%[;[:space:]]done[;[:space:])\'\"]*}"
  [[ $loop =~ (^|[^[:alnum:]_./-])sleep[[:space:]] ]] || continue
  [[ $raw == *"exited with code"* || $raw == *"[killed]"* ]] && continue
  covered=0
  if [[ $before =~ $timeout_re ]]; then
    secs=$((10#${BASH_REMATCH[3]})); [ "${BASH_REMATCH[4]}" = m ] && secs=$((secs * 60))
    [ "$secs" -le "$limit_s" ] && covered=1
  fi
  [ "$covered" -eq 1 ] && continue
  [[ $loop == *tasks/*.output* ]] && hang "this loop reads a background command's output without waiting for the line Claude Code appends when it ends, so it can wait forever." \
    "Wait for \"exited with code\" or \"[killed]\" in the output file, or wrap the loop in: timeout 240 bash -c '...'"
  hang "an until or while loop with sleep and no time limit can run for ever, and a wait past five minutes lets the prompt cache expire." \
    "Put a limit on it: timeout 240 bash -c 'until ...; do sleep 5; done' (N of $limit_s or less), or start the work with run_in_background."
done

# --- git-specific rules --------------------------------------------------------------------------
[[ $raw =~ (^|[^[:alnum:]_./-])git([[:space:]]|$) ]] || exit 0

shopt -s nocasematch
[[ $raw =~ core\.hookspath ]] && block "changing core.hooksPath switches the pre-commit hook off"
shopt -u nocasematch

seg='[^;&|]*'
[[ $raw =~ --no-veri ]] && block "--no-verify skips the project check"
[[ $code =~ commit${seg}[[:space:]]-[a-mo-zA-Z]*n[a-zA-Z]*([[:space:]]|$) ]] && block "git commit -n skips the project check"
[[ $code =~ push${seg}[[:space:]](--force|--force-with-lease|--force-if-includes|-[a-zA-Z]*f[a-zA-Z]*)([[:space:]=]|$) ]] && block "force-push rewrites shared history"
[[ $code =~ push${seg}[[:space:]]\+[^[:space:]] ]] && block "a +refspec force-pushes"
[[ $code =~ reset${seg}[[:space:]]--ha ]] && block "git reset --hard discards uncommitted work"
[[ $code =~ clean${seg}[[:space:]](-[a-zA-Z]*f|--force) ]] && block "git clean -f deletes untracked files"
[[ $code =~ (checkout|switch)${seg}[[:space:]](-f|--force|--discard-changes)([[:space:]]|$) ]] && block "this discards uncommitted changes"
[[ $code =~ (checkout|restore)${seg}[[:space:]](--[[:space:]]+)?\.([[:space:]]|$) ]] && block "this discards every uncommitted change"
[[ $code =~ stash[[:space:]]+(drop|clear) ]] && block "this deletes stashed work"
[[ $code =~ branch${seg}[[:space:]]-D([[:space:]]|$) ]] && block "git branch -D deletes unmerged work"

# --- git: flags that write a file, read outside the repository or run a configured command --------
# settings.json allows `git diff *`, `git log *`, `git show *`, `git commit *` and `git stash *` without
# a prompt, so every flag after them runs without one too. These turn them into a file write
# (--output), a read of any file on the machine (--no-index; a `git diff` of a path outside the
# repository, which git treats as --no-index; commit -F and --file) or the run of a configured command
# (--ext-diff). The command is read as the shell hands it to git: '--output=x', "--output"=x and
# --out\put=x are the flag, while a flag named inside a quoted message or a heredoc body is not.
# Variables and $(...) outside quotes are not expanded, so this is a text match like the rest.
bs='\'; sq1="'"
real="${raw//\\\\/$'\x01'}"; real="${real//\\\"/\"}"; real="${real//\\n/$nl}"
real="${real//\\t/ }"; real="${real//\\r/}"; real="${real//$'\x01'/$bs}"

# Cut out the heredoc bodies (git commit -F - <<'EOF' ...). A quoted delimiter makes the body plain
# text; an unquoted one expands $(...) and backticks, so a body with those stays.
hre='(^|[^<])<<-?[[:space:]]*(\\?["'"'"']?)([A-Za-z_][A-Za-z0-9_]*)'
gtext=""; delim=""; hquote=""; body=""
while IFS= read -r line || [ -n "$line" ]; do
  if [ -n "$delim" ]; then
    if [ "${line#"${line%%[![:space:]]*}"}" = "$delim" ]; then
      delim=""
      [[ -n $hquote || ( $body != *'$('* && $body != *'`'* ) ]] || gtext+="$body"
      body=""
    else body+="$line$nl"; fi
    continue
  fi
  gtext+="$line$nl"
  [[ $line =~ $hre ]] && { delim="${BASH_REMATCH[3]}"; hquote="${BASH_REMATCH[2]}"; }
done <<<"$real"
gtext+="$body"   # a heredoc that never closes keeps its text: a false block beats a miss

# Walk the quoted strings from the left. One that is a flag by itself ('--output=x') or sits inside
# a word (--out"put"=x) is unquoted so the flag shows; any other is message text and is blanked.
# A "..." holding $(...) or backticks runs a command, so its text stays and is read again.
qre='^(([^"'$sq1'\\]|\\.)*)("(([^"\\]|\\.)*)"|'$sq1'([^'$sq1']*)'$sq1')'
glued='^[^[:space:];&|<>)]'
gcode=""; rest="$gtext"
while [[ $rest =~ $qre ]]; do
  pre="${BASH_REMATCH[1]}"; quoted="${BASH_REMATCH[3]}"; rest="${rest:${#BASH_REMATCH[0]}}"
  inner="${quoted:1:${#quoted}-2}"
  if [[ $pre == *'$' && $pre != *'\$' ]]; then   # $'...' and $"...": drop the $
    pre="${pre%?}"
    [[ $quoted == "'"* && $inner =~ \\[xuU0-7] ]] && block "ANSI-C quoting with a numeric escape (\$'\\055') can spell any flag past this check"
  fi
  pre="${pre//\\$nl/}"; pre="${pre//\\/}"        # outside quotes a backslash only escapes the next character
  gcode+="$pre"
  word="${gcode##*[[:space:];&|]}"               # the word so far
  if [[ $inner =~ ^--?[A-Za-z] ]]; then gcode+="$inner"
  elif [[ $inner != *[[:space:]]* && ( -n $word || $rest =~ $glued ) ]]; then gcode+="$inner"
  elif [[ -n $word && $word =~ ^--[^=]*$ ]]; then gcode+="$inner"
  elif [[ $quoted == '"'* && ( $inner == *'$('* || $inner == *'`'* ) ]]; then rest="$inner $rest"
  else gcode+=" Q "; fi
done
rest="${rest//\\$nl/}"; rest="${rest//\\/}"; gcode+="${rest//[\"$sq1]/}"   # a quote left over never closes
gcode="${gcode//$nl/;}"; gcode="${gcode//>&/> }"; gcode="${gcode//&>/> }"

gitre='(^|[^[:alnum:]_./-])git[[:space:]]'
gitflag() { [[ $gcode =~ $gitre($seg[[:space:]])?$1 ]]; }
gitflag '--output([[:space:]=;&|]|$)' && block "--output writes a file to any path, such as one a later command runs"
gitflag '--no-index([[:space:]=;&|]|$)' && block "--no-index reads any file on the machine"
gitflag '--ext' && block "--ext-diff runs a configured external command"

# Per command: git commit -F and --file read any file (the message may come from stdin: -F -), and a
# git diff of a path outside the repository reads it too. The subcommand is the first word after git
# that isn't an option, so `git log --grep commit -F` is not a commit.
outre='^(/|~|[A-Za-z]:|\$[A-Za-z_{])|(^|/)\.\.(/|$)'
brackets='[(){}`]'
IFS=';&|' read -r -d '' -a gsegs <<<"$gcode" || true
for gs in "${gsegs[@]}"; do
  gs="${gs//$brackets/ }"
  read -ra w <<<"$gs"
  n=${#w[@]}; k=0
  while ((k < n)) && [[ ${w[k]} != git ]]; do ((k++)); done
  ((k++))
  while ((k < n)); do
    case ${w[k]} in -C|-c) ((k += 2)) ;; -*) ((k++)) ;; *) break ;; esac
  done
  case ${w[k]:-} in
    commit)
      for ((k++; k < n; k++)); do
        a="${w[k]}"
        if [[ $a =~ ^-[aeinopqsvz]*F(.*)$ ]]; then v="${BASH_REMATCH[1]:-${w[k+1]:-}}"
        elif [[ $a =~ ^--fil(e?)(=(.*))?$ ]]; then
          if [[ -n ${BASH_REMATCH[2]} ]]; then v="${BASH_REMATCH[3]}"; else v="${w[k+1]:-}"; fi
        else continue; fi
        [[ $v == - ]] || block "git commit -F and --file read any file on the machine; give the message on stdin: git commit -F - <<'EOF'"
      done ;;
    diff)
      for ((k++; k < n; k++)); do
        [[ ${w[k]} == -* ]] && continue
        [[ ${w[k]} =~ $outre ]] && block "git diff of a path outside the repository reads any file on the machine"
      done ;;
  esac
done

exit 0
