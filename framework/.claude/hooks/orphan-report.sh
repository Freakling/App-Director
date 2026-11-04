#!/usr/bin/env bash
# App Director orphan report · Claude Code hook · framework-owned: replaced on upgrade.
#
# At session start, tells the human and Claude about long-running processes whose parent shell is gone, and leaves stopping
# them to the human: a subagent's or session's cleanup only reaches what a running session knows about, and a process from an
# ended session can spin a core for days unnoticed. A process is listed when its name is python, python3, python3.<n>, pythonw,
# py, node, bash, sh, godot* or chrome-headless-shell (any case, .exe dropped), it is an hour old or more, and its parent is
# gone: a ppid of 0 or 1, no process with that pid, or a parent younger than the process (Windows reuses pids and doesn't
# reparent). The oldest ten are named, with how many more there are. The list comes from PowerShell (Get-CimInstance
# Win32_Process, under timeout 8 when timeout exists) on Windows (Git Bash, MSYS, Cygwin) and from `ps -A -o pid=,ppid=,etime=,comm=`
# elsewhere. It reads the names, ids and ages of the processes on this machine and nothing else; it stores nothing, sends
# nothing and never stops, signals or changes a process; PRIVACY.md says what it reads. APP_DIRECTOR_ORPHAN_REPORT=0 turns it off.
# It prints one line of JSON, or nothing: a machine with no such process, or one whose process list can't be read (no
# PowerShell or ps, a tool that fails or times out), costs no context, and every path ends in exit 0, so it never blocks a
# session. A process name is reduced to [A-Za-z0-9._-] before it is printed, so it can't break the JSON. Bash 3.2 and BSD
# tools run it, and it starts as few processes as it can (uname and one process list, with timeout on Windows).

IFS= read -r -d '' input || true
[ "${APP_DIRECTOR_ORPHAN_REPORT:-1}" = "0" ] && exit 0
exec 2>/dev/null
LC_ALL=C
shopt -s nocasematch

# The process list: on Windows from PowerShell as rows "pid ppid age_seconds name" (a process with no CreationDate is skipped),
# elsewhere from ps, whose etime is read into seconds below.
win=0
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) win=1 ;; esac
if [ "$win" = "1" ]; then
  script='$n=Get-Date;Get-CimInstance Win32_Process -Property ProcessId,ParentProcessId,CreationDate,Name|ForEach-Object{if($_.CreationDate){@($_.ProcessId,$_.ParentProcessId,[int]($n-$_.CreationDate).TotalSeconds,$_.Name)-join[char]32}}'
  if command -v timeout >/dev/null; then
    rows="$(timeout 8 powershell.exe -NoProfile -NonInteractive -Command "$script" < /dev/null)" || exit 0
  else
    rows="$(powershell.exe -NoProfile -NonInteractive -Command "$script" < /dev/null)" || exit 0
  fi
else
  rows="$(ps -A -o pid=,ppid=,etime=,comm= < /dev/null)" || exit 0
fi
[ -n "$rows" ] || exit 0

isnum() { # is $1 one to ten digits
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  [ "${#1}" -le 10 ]
}

# Every row's age is kept by pid, to look a parent up; the rows that could be orphans (a listed name, an hour old) are kept to judge.
etime_re='^(([0-9]{1,9})-)?(([0-9]{1,9}):)?([0-9]{1,9}):([0-9]{1,9})$'   # [[dd-]hh:]mm:ss
py_re='^python3\.[0-9]+$'
age_of=(); c_pid=(); c_ppid=(); c_age=(); c_name=()
while IFS=' ' read -r pid ppid field name; do
  name="${name%$'\r'}"
  isnum "$pid" && isnum "$ppid" || continue
  if [ "$win" = "1" ]; then
    isnum "$field" || continue
    age=$((10#$field))
  else
    [[ $field =~ $etime_re ]] || continue
    age=$(( ((10#${BASH_REMATCH[2]:-0} * 24 + 10#${BASH_REMATCH[4]:-0}) * 60 + 10#${BASH_REMATCH[5]}) * 60 + 10#${BASH_REMATCH[6]} ))
    name="${name##*/}"
  fi
  pid=$((10#$pid)); ppid=$((10#$ppid))
  age_of[$pid]=$age
  [ "$age" -ge 3600 ] || continue
  name="${name%.[eE][xX][eE]}"
  case "$name" in
    python|python3|pythonw|py|node|bash|sh|godot*|chrome-headless-shell|chrome-headless) ;;   # Linux cuts a name to 15 characters: chrome-headless
    *) [[ $name =~ $py_re ]] || continue ;;
  esac
  c_pid[${#c_pid[@]}]=$pid; c_ppid[${#c_ppid[@]}]=$ppid; c_age[${#c_age[@]}]=$age; c_name[${#c_name[@]}]="$name"
done <<< "$rows"

# An orphan's parent is gone: ppid 0 or 1, no row with that pid, or a row younger than the process (a reused pid).
o_pid=(); o_age=(); o_name=()
i=0
while [ "$i" -lt "${#c_pid[@]}" ]; do
  ppid="${c_ppid[$i]}"
  if [ "$ppid" -le 1 ] || [ -z "${age_of[$ppid]+x}" ] || [ "${age_of[$ppid]}" -lt "${c_age[$i]}" ]; then
    o_pid[${#o_pid[@]}]="${c_pid[$i]}"; o_age[${#o_age[@]}]="${c_age[$i]}"; o_name[${#o_name[@]}]="${c_name[$i]}"
  fi
  i=$((i + 1))
done
total="${#o_pid[@]}"
[ "$total" -gt 0 ] || exit 0

# The oldest ten, oldest first; a name is reduced to characters that need no JSON escape.
list=""; shown=0
while [ "$shown" -lt 10 ] && [ "$shown" -lt "$total" ]; do
  best=-1; at=0; i=0
  while [ "$i" -lt "$total" ]; do
    if [ "${o_age[$i]}" -gt "$best" ]; then best="${o_age[$i]}"; at="$i"; fi
    i=$((i + 1))
  done
  if [ "$best" -le 172800 ]; then age_text="$((best / 3600)) h"; else age_text="$((best / 86400)) d"; fi
  nm="${o_name[$at]//[^A-Za-z0-9._-]/}"
  [ -z "$list" ] || list="$list, "
  list="${list}pid ${o_pid[$at]} $nm ($age_text)"
  o_age[$at]=-1
  shown=$((shown + 1))
done
[ "$total" -le 10 ] || list="$list, and $((total - 10)) more"

text="Processes that outlived the shell that started them (parent gone, over an hour old): $list. They may be left over from an ended session. Stopping them is your call."
ask="Tell the human this once, in your first reply, and don't stop them unless the human asks."
printf '{"systemMessage":"%s","hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s %s"}}\n' "$text" "$text" "$ask"
exit 0
