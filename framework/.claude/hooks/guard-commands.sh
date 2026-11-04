#!/usr/bin/env bash
# App Director command guard · Claude Code PreToolUse hook on Bash, Monitor and PowerShell · framework-owned: replaced on upgrade.
#
# Permission rules match how a command starts, so `git commit -m x --no-verify` or
# `git push origin main --force` would slip past them. This hook looks at the whole command and
# blocks what rules.md › Git reserves for the human: rewriting history, discarding work, and
# skipping the check. It pattern-matches the text, so it's a strong safety net, not a guarantee.
# It starts no other processes (it runs on every Bash call).
#
# It also blocks the git flags that write a file, read a file outside the repository or run a
# configured command (--output, --no-index, --ext-diff, commit and tag -F and --file, grep -O and
# --open-files-in-pager), because the allow rules in settings.json let `git diff *`, `git log *`,
# `git show *`, `git commit *`, `git tag *`, `git grep *` and `git stash *` run with any flag. See the
# section "git: flags that write a file" below. And a `bash` or `sh` command whose script path under
# tools/ leaves it with `..`, because `bash tools/stacks/*.sh*` would match `tools/stacks/../../x.sh`.
#
# Also blocks shell commands, Bash or PowerShell, that read credential files directly (.env and .env.<suffix>,
# *.pem, *.key, ~/.ssh, git's credentials files, the gh CLI's hosts.yml) and the commands that print a stored
# credential (gh auth token, gh auth status -t, git credential fill or get). This is a guardrail, not a
# guarantee: complex pipelines or indirect reads are not detected. The Read-tool deny rules in settings.json
# cover the most common path. In Bash, an escaped space in a store path (GitHub\ CLI) is a space, and an ANSI-C
# string ($'...') in a reader's or a file's name is the text it spells (B52). See "Credential file reads" below.
#
# A command substitution ($(...), `...`, <(...), >(...); PowerShell's $(...), @(...) and (...)) runs a command the
# guard can't see, and what it prints is text the rules can't read (B32). In a git command's words it can be a flag, and
# as a command's name it can be git. So the substitutions are read out of the command, each one's text is read as a
# command of its own, and in a git command's words only a double-quoted one that starts with fixed text (or a commit's
# or tag's -m value) passes, and only when its text is a plain read. In Bash a comment holds no substitution, and its quotes
# open no string (B43). See the section "Substitutions" below. The word decoder reads each comment on its own line, so a quote
# in a comment pairs with nothing after the line break, and a quoted flag or refspec after it is read (B51). See "Comments".
#
# A quoted script given to a shell or an interpreter (bash -c, sh -c, zsh -c, eval, powershell -Command, pwsh -c, cmd /c)
# is a command of its own: each is read as one, and a script nested in one to four levels too (B34). See the section
# "Shell wrappers" below. A wait loop in such a script is judged too, and a script under timeout 280 or less is bounded (B42).
# The hang check also reads a C-style for ((...)) loop, PowerShell's do { } while or until, Start-Sleep, cmd's timeout /t, and a
# command's substitutions, which run before a timeout above them starts, so the timeout doesn't bound them (B49). A PowerShell
# command's $(...) is read the same way, for the hang check and the credential-read check (B52).
# The hang rules read the command without the bodies no shell runs (B50): a commit's, tag's or gh message, and a cat or tee
# body nothing runs, are left out, so a message can name a loop, a pause or a timed wait. In PowerShell a here-string body
# nothing runs is left out the same way. A wait loop is read to the done that closes it, counting the do and done of the loops
# nested in it, and a pause may have a fraction (sleep 600.5, Start-Sleep 280.5). A Python interpreter that reads its script from a
# heredoc or a here-string (python - <<'EOF', python <<<"x", cat <<'EOF' | python -) is blocked whatever the body, also behind a path
# (/usr/bin/python3) or a wrapper (timeout 60); a script file given a heredoc of data (python tool.py <<'EOF') passes, and so does
# a message that names the form.
# A shell or PowerShell name starts a script anywhere except right after a word that only prints its words (echo, printf,
# Write-Output, Write-Host, write): `echo PowerShell 'x'` is text, and `ssh host pwsh -c 'x'` is still read (B48).
#
# A variable in a git command's words holds a value the guard can't read (B37). A variable that the command assigns once,
# to a plain value, is read as that value (FLAG=--force; git push $FLAG is git push --force). Any other variable in the words
# of a git subcommand whose flags the rules read is blocked when it's unquoted, or quoted where a flag or a path could be; a
# variable as the subcommand, and a variable as a command's name followed by -c or -Command, are blocked too. See the
# section "Variables" below.
#
# A variable as a command's name runs what it holds (B45). A plain value the command assigns is that name (G=git; $G push
# --force is git push --force). Otherwise it's blocked when the command sets a variable the guard can't resolve, or when a git
# subcommand or a destructive flag follows it; "$PY" -I script.py passes. A shell's script, eval's argument or -Command that
# holds a variable or a substitution is blocked, since the shell expands it before the guard can read it, and a bash script
# path under tools/ that holds a variable is blocked, since it can add a .. the guard can't see. See "A variable as a command's name".
# A PowerShell assignment ($x = 1, $x += 1, $env:X = 'y'), a constant ($true, $false, $null) or an automatic value ($_, $args) that
# no call operator (& or .) runs is no command name, and a Bash NAME+=value is an assignment prefix (B55).
#
# PowerShell's Invoke-Expression (iex) runs its one string argument as a script, as eval does (B60). That argument is read as a
# script of its own, and a variable the command assigns once to a plain literal before the call is read as its value. A pipeline
# into it, no argument, or an expression or a second argument the guard can't read is blocked. See "Invoke-Expression" below.
#
# A git -c key, or --config-env, that names a program git runs (an alias that starts with !, core.pager, core.sshCommand,
# diff.external, a credential helper) runs a command of the caller's choice, so the keys are an allow list: only the keys that
# run nothing pass, and a key a variable holds is blocked (B38). The flags that name a program for a remote (--upload-pack,
# --receive-pack, --exec, and clone's -u) are blocked on fetch, pull, push, clone, ls-remote and archive, abbreviations too. A
# variable that names a program git runs (GIT_CONFIG_*, GIT_SSH_COMMAND, GIT_PAGER, EDITOR and the like) set on a git command is
# blocked. See the section "Git configuration and program flags" below.
#
# The git name is read as the shell reads it, quotes removed, so "git", 'git' and g"it" are git (B39), in any case too:
# PowerShell finds a command case-insensitively, and Windows finds GIT, so GIT and Git are git (B46). Only the name is
# matched so: git's subcommands and flags stay case-sensitive, as git reads them, and the name is written [Gg][Ii][Tt].
# A path before the name and .exe after it are part of the shell's finding it, so /usr/bin/git and git.exe are git too (gitw_re).
# A command name written as a path is read as its last part too: a quoted path with a space in it, or an unquoted backslash path
# that starts with a drive, ., .., ~ or two backslashes (C:\Git\bin\git.exe push --force). See "Command names that are paths".
# The shell's name in the script-path rule is read the same way (B47): "bash", 'sh' and BASH are bash and sh.
# A heredoc body a shell runs (any body but a message, B40 and B48) takes a backtick as the end of a flag, and its words and the file-writing flags
# are read there too; git branch with a delete and a force flag, git push --mirror, --delete and -d, and a :ref refspec are
# blocked, and the credential-print rules read the decoded words (B39, where the git rules below read the bodies and the words).
# A heredoc body that no shell runs is text (B40, B48): a commit's or tag's message, a gh pr, issue or release message with a quoted
# delimiter (its body from stdin, --body-file -, -F -, --notes-file -, or from a $(cat <<'EOF') given to --body, -b, --notes or -n), and
# a cat or tee body that the command doesn't run (no shell, interpreter, ssh, chmod, make or npm, call operator, ./ path, dot-source or
# .git folder names it). The destructive rules, the file-writing flag rules, the variable rules (B37), the hang rules (B50), the
# credential-print rules and the walks that read a command a character at a time skip such a body; the substitutions in it are still
# read (B32). A hook that runs past its 10 seconds doesn't block, so a long file body must not cost the rules a pass of every character.
#
# The hook's own state starts empty (the view flags vdep, vcov, vpx and vhang, and the rest it reads before it sets it), so a variable
# of the same name in its environment is no flag.

IFS= read -r -d '' input || true
re='"command"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)"'
[[ $input =~ $re ]] || exit 0
raw="${BASH_REMATCH[1]}"

# The tool's name (B28): only PowerShell reads a backtick at a line's end as a continuation, and the readings below
# depend on it. The name is a JSON string, matched as the command is.
tre='"tool_name"[[:space:]]*:[[:space:]]*"([^"]*)"'
tool=""; [[ $input =~ $tre ]] && tool="${BASH_REMATCH[1]}"

# PowerShell (B28, B35): a backtick that ends a line continues it, as a backslash does in Bash (B25). PowerShell's
# parser agrees when the backtick isn't escaped: an odd run of backticks before the line break joins it, so
# `` (an escaped backtick) keeps the break, and a backtick followed by spaces doesn't continue. In Bash a
# backtick is command substitution, so the text stays. Its readings are made below with Bash's (B31). A backslash at a line's end
# is a path separator in PowerShell, not a continuation, so only Bash joins the lines it ends.
bt='`'; x3=$'\x03'
# The git name as a word: in any case, after a path and with .exe, so /usr/bin/git and GIT.EXE are git, as they are for the shell
# (the rules read the name with its quotes removed, so "git" and /usr/bin/"git" are git too).
gitw_re='^(.*/)?[Gg][Ii][Tt](\.[Ee][Xx][Ee])?$'

# The readings of the command (B31, B35). A backslash at a line's end continues the command in Bash (B25), but a comment
# holds its backslash: Bash ends a comment at the line break, so `# note\` is a comment and the next line is a command
# of its own. Joining that line onto the comment would hide it. PowerShell's backtick does the same (B28, B35), since it
# ends its comment at the line break too. So each rule reads every reading in turn, and no reading joins two lines that
# the shell keeps apart:
#   as written: every line break kept, so a command after a comment shows on its own line;
#   as joined: every continuation joined, as the shell reads a command that holds no comment (PowerShell's escapes too);
#   from each line after one that holds a comment marker and ends in a continuation: joined from that line on, since
#     the comment may have ended that line (the joined reading glues `git` onto a comment's last word: `# a`, `git`).
# A # inside a word (a#b) is no comment, so its continuation is joined in the joined reading, as the shell joins it.
# x1 is a command backslash, x2 an escaped pair (two backslashes) and x4 a continuation's mark before a line break.
bs='\'; x1=$'\x01'; x2=$'\x02'; x4=$'\x04'; nl=$'\n'
# str_swap <text> <literal> <value>: sets SW to the text with each <literal> replaced by <value>, both taken as written. A quoted
# replacement string (${t//x/"$y"}) keeps its quotes before bash 4.3, and macOS ships bash 3.2, so no replacement here is quoted.
str_swap() {
  local t="$1" out="" ncm=0
  shopt -q nocasematch && { ncm=1; shopt -u nocasematch; }
  if [[ -n $2 ]]; then
    while [[ $t == *"$2"* ]]; do out+="${t%%"$2"*}$3"; t="${t#*"$2"}"; done
  fi
  SW="$out$t"
  ((ncm)) && shopt -s nocasematch
  return 0
}
# view_of <k> <join>: the view from line k on, each line's marks turned back into JSON text (x2 an escaped pair, x1 a backslash) and
# the lines joined with the JSON \n, or with nothing after a continuation when <join> is 1. The marks are swapped line by line, and
# the \n is added as the lines are joined, so a long command costs one pass (a swap over the whole text costs one per line).
view_of() {
  local s="" k line jb=$'\x5c\x5c' jb4=$'\x5c\x5c\x5c\x5c' bsl=$'\x5c' cont
  for ((k = $1; k < nphys; k++)); do
    line="${phys[k]}"; cont=0
    if [[ $line == *"$x4" ]]; then line="${line%"$x4"}"; cont=1; fi
    if [[ $line == *"$x2"* ]]; then str_swap "$line" "$x2" "$jb4"; line="$SW"; fi
    if [[ $line == *"$x1"* ]]; then str_swap "$line" "$x1" "$jb"; line="$SW"; fi
    s+="$line"
    if ((cont && $2)); then continue; fi
    if ((k < nphys - 1)); then s+="${bsl}n"; fi
  done
  view="$s"
}

# ps_clean <view>: sets joined to a joined view as PowerShell reads it (B28, B30): a backtick before a letter, digit or name
# punctuation is an escape that leaves that character, so Get-Con`tent is Get-Content, and .en`v.local names .env.local. A
# backtick before a quote, a $, a space or a separator stays, since it escapes only that character and joins no name.
# A doubled backtick is an escaped one, so it's set aside first.
ps_clean() {
  local c t="$1"
  t="${t//"$bt$bt"/$x3}"
  if [[ $t == *"$bt"* ]]; then
    for c in {a..z} {A..Z} {0..9} . _ / '\' : '*' '?' '~' % @ + = , '#' -; do
      [[ $t == *"$bt$c"* ]] && { str_swap "$t" "$bt$c" "$c"; t="$SW"; }
    done
  fi
  t="${t%"$bt"}"   # a backtick at the very end escapes nothing, so `git push `echo --force` reads as git push echo --force (B32)
  joined="${t//$x3/$bt$bt}"
}

# reading_of <k> <join>: sets view to the reading view_of makes from line k (0 for the whole command), joined when <join>
# is 1. A joined reading of PowerShell is read with its escapes removed as PowerShell reads them (ps_clean).
reading_of() {
  view_of "$1" "$2"
  if (($2)) && [[ $tool == PowerShell ]]; then ps_clean "$view"; view="$joined"; fi
}

# lower <text>: sets LC to the text in lower case. Bash 3.2 (macOS) has no ${x,,}, and no process may start, so each upper-case
# letter the text holds is replaced by its lower-case one.
lc_up=ABCDEFGHIJKLMNOPQRSTUVWXYZ; lc_lo=abcdefghijklmnopqrstuvwxyz
lower() {
  LC="$1"
  [[ $LC == *[[:upper:]]* ]] || return 0
  local li
  for ((li = 0; li < 26; li++)); do
    [[ $LC == *"${lc_up:li:1}"* ]] && LC="${LC//${lc_up:li:1}/${lc_lo:li:1}}"
  done
  return 0
}

# --- Substitutions (B32) -------------------------------------------------------------------------
# A command substitution runs a command the guard can't see, and what it prints is text the rules can't read. In a git
# command's words it can be a flag (git push "$(echo --force)"), and as a command's name it can be git ($(echo git) push).
# subst_cut reads every substitution out of the command, before the quote reading below: each becomes a placeholder
# \x1a<n>\x1b in cut_out, its text goes to subc[n] (the quoted strings inside it are skipped as the shell skips them, so
# its end is the shell's), and its kind to subk[n]: u when unquoted, or, inside double quotes, the kind of its word: d
# when the word starts with fixed text that isn't a dash (or the word is --name=<value>), m when -m or --message is the
# word before it, x otherwise. Each text is also read as a command of its own (a view), so git's rules judge the git in it.
brackets='[(){}`]'
MSG_CMD="a command substitution is the command name, so the guard can't tell which command runs"
MSG_POS="a command substitution in a git command's words prints text the guard can't read, and that text can be a flag; write the value out, or put it in double quotes after fixed text, such as ddd/bundle-\$(date +%F)"
MSG_MSG="a command substitution is a commit's or tag's message only as the value of -m, with no option before -m that takes a value"
MSG_READ="a command substitution in a git command's words runs a command the guard can't judge; only git, date, cat, echo and printf are read there"
MSG_UNREAD="the guard can't read a command substitution here: it's unclosed, or it holds a backtick, or a double-quoted string with a substitution"

# cmt_start <text> <i>: 0 when the # at <i> starts a Bash comment (B43). It starts a word, which a # does at the text's start,
# or after a blank, a line break, or ; & | ( that isn't escaped. A # after a ) joins its word (the ) that closes a
# substitution ends none), and a # inside a word (a#b, ${#x}, $#) starts no comment. Nor does one inside ${...} (x:- #a),
# which the readers track (pbr, pb): a blank there is part of the expansion.
cmt_start() {
  local s="$1" i=$2 k b=0
  ((i == 0)) && return 0
  case ${s:i-1:1} in ' ' | $'\t' | "$nl" | ';' | '&' | '|' | '(') ;; *) return 1 ;; esac
  k=$((i - 2))
  while ((k >= 0)) && [[ ${s:k:1} == '\' ]]; do b=$((b + 1)); k=$((k - 1)); done
  ((b % 2 == 0))
}

# sub_end <text> <start> [1]: sub_e is the index of the ) that closes a substitution whose text starts at <start>. Quoted strings
# and escapes are skipped, so a ) inside them doesn't count. Returns 1 when it doesn't close, or when a double-quoted string
# in it holds a substitution or a backtick. With a third argument of 1 (Bash, B43) a comment inside the substitution runs to its
# line break, so a ) or a backtick in it closes nothing and starts nothing.
sub_end() {
  local s="$1" j=$2 L=${#s} depth=1 c k cm=${3:-0} pb=0
  while ((j < L)); do
    c="${s:j:1}"
    if [[ $c == "$sesc" ]]; then ((j += 2)); continue; fi
    if ((cm && pb == 0)) && [[ $c == '#' ]] && cmt_start "$s" "$j"; then
      k="${s:j}"; k="${k%%"$nl"*}"; ((j += ${#k})); continue
    fi
    case $c in
      '$')
        if [[ ${s:j+1:1} == '{' ]]; then ((pb++, j += 2)); continue; fi ;;
      '}') ((pb > 0)) && ((pb--)) ;;
      "'")
        k="${s:j+1}"; [[ $k == *"'"* ]] || return 1
        k="${k%%"'"*}"; ((j += ${#k} + 2)); continue ;;
      '"')
        k=$((j + 1))
        while ((k < L)) && [[ ${s:k:1} != '"' ]]; do
          if [[ ${s:k:1} == "$sesc" ]]; then ((k++))
          elif [[ ${s:k:1} == '`' || ${s:k:2} == '$(' ]]; then return 1; fi
          ((k++))
        done
        ((k < L)) || return 1
        j=$((k + 1)); continue ;;
      '`') return 1 ;;
      '(') ((depth++)) ;;
      ')')
        ((depth--))
        if ((depth == 0)); then sub_e=$j; return 0; fi ;;
    esac
    ((j++))
  done
  return 1
}

# subst_cut <text>: cut_out is the text with each substitution as a placeholder, and subc and subk are set (above). A
# single quote starts a quoted string outside double quotes and is skipped whole, so a substitution inside it isn't one.
# Returns 1 when a substitution can't be read (see MSG_UNREAD). In Bash a comment is copied as text (B43): a backtick, a
# $( or a quote in it starts nothing. A heredoc body with a substitution is read whole, as the shell expands it, so the
# comment reading is off for a command with one (hsubb, set where the bodies are collected).
subst_cut() {
  local s="$1" i=0 L ch nx t st e txt kind start wsf lit before pwd dqkind="" indq=0 dqpos=0 cmtc=0 pbr=0
  if [[ $tool == PowerShell ]]; then sesc='`'; else sesc='\'; fi
  if [[ $tool != PowerShell ]] && ((${hsubb:-0} == 0)); then cmtc=1; fi
  L=${#s}; cut_out=""; sn=0; subc=(); subk=()
  while ((i < L)); do
    ch="${s:i:1}"; nx="${s:i+1:1}"
    if [[ $ch == "$sesc" ]]; then cut_out+="${s:i:2}"; ((i += 2)); continue; fi
    if ((indq)); then
      if [[ $ch == '"' ]]; then indq=0; cut_out+='"'; ((i++)); continue; fi
    elif [[ $ch == "'" ]]; then
      t="${s:i+1}"; [[ $t == *"'"* ]] || { cut_out+="${s:i}"; break; }
      t="${t%%"'"*}"; cut_out+="'$t'"; ((i += ${#t} + 2)); continue
    elif [[ $ch == '"' ]]; then
      indq=1; dqpos=${#cut_out}; dqkind=""; cut_out+='"'; ((i++)); continue
    elif [[ $ch == '$' && $nx == '{' ]]; then pbr=$((pbr + 1)); cut_out+='${'; ((i += 2)); continue
    elif ((pbr > 0)) && [[ $ch == '}' ]]; then pbr=$((pbr - 1)); cut_out+='}'; ((i++)); continue
    elif ((cmtc && pbr == 0)) && [[ $ch == '#' ]] && cmt_start "$s" "$i"; then
      t="${s:i}"; t="${t%%"$nl"*}"; cut_out+="$t"; ((i += ${#t})); continue
    fi
    st=0
    if [[ $ch == '$' && $nx == '(' ]]; then st=$((i + 2))
    elif ((!indq)) && [[ $tool == PowerShell && $ch == '(' ]]; then st=$((i + 1))
    elif ((!indq)) && [[ $tool != PowerShell && ( $ch == '<' || $ch == '>' ) && $nx == '(' ]]; then st=$((i + 2))
    fi
    if ((st > 0)); then
      sub_end "$s" "$st" "$cmtc" || return 1
      e=$sub_e; txt="${s:st:e-st}"
    elif [[ $ch == '`' && $tool != PowerShell ]]; then
      t="${s:i+1}"; [[ $t == *'`'* ]] || return 1
      txt="${t%%\`*}"; e=$((i + ${#txt} + 1))
    else
      cut_out+="$ch"; ((i++)); continue
    fi
    kind=u
    if ((indq)); then
      if [[ -z $dqkind ]]; then
        before="${cut_out:0:dqpos}"; lit="${cut_out:dqpos+1}"; lit="${lit//\\/}"
        wsf="${before##*[[:space:];&|]}"
        start="$wsf$lit"; start="${start%%$'\x1a'*}"
        t="${before%"${before##*[![:space:]]}"}"; pwd="${t##*[[:space:];&|]}"
        if [[ $wsf == *[\'\"\\]* ]]; then dqkind=x
        elif [[ -n $start && ( $start != -* || $start == --*=* ) ]]; then dqkind=d
        elif [[ $before == *[[:space:]] && ( $pwd =~ ^-[[:alpha:]]*m$ || $pwd == --message ) ]]; then dqkind=m
        else dqkind=x; fi
      fi
      kind=$dqkind
    fi
    subc[sn]="$txt"; subk[sn]=$kind
    cut_out+=$'\x1a'"$sn"$'\x1b'; ((sn++))
    i=$((e + 1))
  done
  return 0
}

# subst_read <text>: the text a substitution runs is a read the guard judges: git (as a command of its own, in a view),
# date, cat, echo or printf, with no separator, no redirect and no nested substitution.
subst_read() {
  local c="$1" c2
  c="${c#"${c%%[![:space:]]*}"}"; c="${c%"${c##*[![:space:];]}"}"
  [[ $c =~ ^([Gg][Ii][Tt]|date|cat|echo|printf)([[:space:]]|$) ]] || return 1
  c2="${c//<</}"
  [[ $c2 == *'$('* || $c2 == *'`'* || $c2 == *[\;\&\|\<\>\(\)$nl]* ]] && return 1
  return 0
}

# walk_msg <j>: word j is a placeholder that's the value of a commit's or tag's -m. -m must be the word before it, and
# every option between the subcommand and -m must take no value, since one that does would take -m as its value.
walk_msg() {
  local j=$1 i
  case $bsub in commit | tag) ;; *) return 1 ;; esac
  ((j - 1 > bsk)) || return 1
  [[ ${w[j - 1]} =~ ^-[aqsvefiSo]*m$ || ${w[j - 1]} == --message ]] || return 1
  for ((i = bsk + 1; i < j - 1; i++)); do
    case ${w[i]} in
      --amend | --all | --quiet | --verbose | --signoff | --no-edit | --edit | --allow-empty | --include | --only) continue ;;
      -*) [[ ${w[i]} =~ ^-[aqsvefiSo]+$ ]] || return 1 ;;
    esac
  done
  return 0
}

# subst_segment: the substitutions among one segment's words (w, n). A command name can't be one. In a git command's
# words (bsk is its subcommand's index, bsub the subcommand) only a d or m value passes, and only when its text is a read.
subst_segment() {
  local cw=0 gi=-1 j rest idx
  while ((cw < n)) && [[ ${w[cw]} =~ ^(([A-Za-z_][A-Za-z0-9_]*=.*)|\$|env|time|nohup|exec|command|sudo|if|then|else|elif|do|while|until|!)$ ]]; do ((cw++)); done
  [[ ${w[cw]:-} == *$'\x1a'* ]] && block "$MSG_CMD"
  # git is the word git anywhere, or a path-qualified or .exe git as the command's name (cw), where /usr/bin/git can run.
  for ((j = 0; j < n; j++)); do
    [[ ${w[j]} == [Gg][Ii][Tt] ]] || { ((j == cw)) && [[ ${w[j]} =~ $gitw_re ]]; } && { gi=$j; break; }
  done
  ((gi < 0)) && return 0
  bsk=$((gi + 1))
  while ((bsk < n)); do case ${w[bsk]} in -C | -c | --git-dir | --work-tree | --namespace | --config-env | --attr-source | --super-prefix) ((bsk += 2)) ;; -*) ((bsk++)) ;; *) break ;; esac; done
  bsub="${w[bsk]:-}"
  for ((j = gi + 1; j < n; j++)); do
    rest="${w[j]}"
    while [[ $rest == *$'\x1a'* ]]; do
      idx="${rest#*$'\x1a'}"; idx="${idx%%$'\x1b'*}"; rest="${rest#*$'\x1b'}"
      case ${subk[idx]} in
        d) subst_read "${subc[idx]}" || block "$MSG_READ" ;;
        m) walk_msg "$j" || block "$MSG_MSG"; subst_read "${subc[idx]}" || block "$MSG_READ" ;;
        *) block "$MSG_POS" ;;
      esac
    done
  done
}

# --- Variables (B37) ----------------------------------------------------------------------------
# A variable in a git command's words holds a value the guard can't read, and that value can be a flag (git push $FLAG
# with FLAG=--force) or a path outside the repository. var_resolve first replaces each variable the command assigns once,
# to a plain value (letters, digits and - _ . / : = + @ % , ~), with that value wherever it's used, as the shell expands
# it, so the rules above judge what git gets. A name set another way (read, for, +=), set twice, or to any other value
# stays a variable. var_judge then judges each variable left in a git command's words, and in a body a shell runs: an
# unquoted one is blocked, since the shell splits it into several words, and a quoted one is blocked where its value could
# be a flag or a path. It passes as the value of an option that takes the next word whole (-m, -e, -b, -C and the like),
# after -- (paths), as a push's branch after its remote, and after fixed text that doesn't start a flag ("ddd/bundle-$day",
# "--since=$since"). A variable as the subcommand is blocked. Only the subcommands in vb_scope are judged: those whose flags a
# rule reads (--output, -F, -O, -D and the like). A variable in another subcommand's words, such as git status or git add,
# passes, since no rule reads the flags they take.
vb_scope=" archive commit diff format-patch grep log show tag stash branch checkout switch restore reset clean push "
MSG_VAR="a variable in a git command's words holds a value the guard can't read, and it can be a flag or a path: write the value out, quote it as the value of -m, -e or -b, or put it after --"
MSG_SUB="a variable as a git command's subcommand holds a value the guard can't read"
MSG_SHVAR="a variable as a command's name, followed by -c or -Command, runs a shell or an interpreter the guard can't tell apart"
vsh_pre_re='\$[^[:space:]]*[[:space:]]+-[a-zA-Z]*[cC]'
# The words that may come before a command's name: NAME=value, the wrappers that run what follows (env, sudo, xargs and the like), and
# the keywords that begin a command (if, then, do, {, !, and the rest), so `then $G push` and `xargs $G push` name $G (B45).
vsh_prefix_re='^([A-Za-z_][A-Za-z0-9_]*\+?=.*|env|exec|command|sudo|nohup|time|timeout|nice|ionice|stdbuf|xargs|builtin|setsid|watch|doas|coproc|if|then|else|elif|do|while|until|!|\{|-.*|[0-9.]+[smhd]?)$'
vsh_opt_re='^-[a-zA-Z]*[cC]'

# --- A variable as a command's name (B45) ------------------------------------------------------
# A command whose name is a variable runs what the variable holds. When the command assigns it a plain value, var_resolve
# replaces it, so the name is judged as its value (G=git; $G push --force is git push --force). Otherwise the guard can't
# read the name, and it's blocked when the command sets that name another way (cn_asg), or when a git subcommand or a
# destructive flag follows the name in its segment. Everyday forms pass: "$PY" -I script.py, $EDITOR notes.txt,
# PYTHONPATH="a b" "$PY" -I script.py, and for f in *.py; do "$PY" "$f"; done (the loop sets f, not PY).
# cname_judge <text> <mode>: each segment of the text whose command name (after the prefixes vsh_prefix_re and NAME=value
# allow) is a variable. Mode 0 sets cnv to 1 when there is one, so the command is read; mode 1 judges the ones left.
MSG_CNAME="a variable as a command's name, followed by a git subcommand or a destructive flag, can run git, and the guard can't read what it holds: write the command out"
MSG_CNASG="a variable as a command's name, which the command sets another way than a plain value, can run any command, and the guard can't read what it holds: write the value out"
MSG_CNSCR="a variable as a command's name inside a script that a shell runs can hold any command, and the guard can't read what the caller's environment sets it to: write the command out"
cn_sub=" add am annotate apply archive bisect blame branch bundle checkout cherry cherry-pick clean clone commit config describe diff fetch format-patch gc grep init log ls-remote merge mv notes pull push range-diff rebase reflog remote repack replace reset restore revert rm shortlog show stash status submodule switch tag worktree "
# cn_kw: the words that set a name (read NAME, for NAME in ..., declare NAME, Set-Variable NAME and the like).
cn_kw='(read|for|foreach|select|mapfile|readarray|getopts|declare|typeset|local|export|readonly|let|set-variable|sv|new-variable|nv|read-host)'
# cn_ps_re: PowerShell's $name = or $env:name = (a PowerShell assignment, which sets any name).
cn_ps_re='\$[A-Za-z_][A-Za-z0-9_:]*[[:space:]]*[-+]?=[^=]'
# cn_asg_re: for a name the walk can't name (a $1 or a $@), any of those words or an assignment in the command.
cn_asg_re="(^|[[:space:];&|()])${cn_kw}([[:space:]]|\$)|\\\$\\{[A-Za-z_][A-Za-z0-9_]*:?=|$cn_ps_re"
# cn_pre_re: a cheap superset of a command with a variable as a name (a segment that starts, after NAME=value words and the
# prefixes, with a word holding a $), so the walk runs only on those commands. A miss would pass a command, so it stays loose.
cn_pre_re='(^|[;&|()'"$nl"'])[[:space:]]*(([A-Za-z_][A-Za-z0-9_]*\+?=[^;&|()'"$nl"']*|env|exec|command|sudo|nohup|time|timeout|nice|ionice|stdbuf|xargs|builtin|setsid|watch|doas|coproc|if|then|else|elif|do|while|until|!|\{|-[^[:space:]]*|[0-9.]+[smhd]?)[[:space:]]+)*[^[:space:];&|()]*\$'
# cn_asg <name>: 0 when the command sets the name another way than a plain value var_resolve reads (cn_all is the command): NAME=
# or NAME+= with a value it doesn't resolve, a cn_kw word before NAME, ${NAME:=...}, or a PowerShell assignment (cn_ps_re). With no
# name (a $1), any of those in the command counts. Names are case-insensitive in PowerShell, so the match is too.
cn_asg() {
  local n="$1" t="$cn_all" rr=0 re
  shopt -s nocasematch
  if [[ -z $n ]]; then [[ $t =~ $cn_asg_re ]] && rr=1
  else
    re="(^|[^[:alnum:]_])${n}[[:space:]]*\\+?=([^=]|\$)"; [[ $t =~ $re ]] && rr=1
    re="(^|[[:space:];&|()])${cn_kw}[^;&|()]*[[:space:]]${n}([[:space:]]|[;&|()]|\$)"; [[ $t =~ $re ]] && rr=1
    re="\\\$\\{${n}:?="; [[ $t =~ $re ]] && rr=1
    [[ $t =~ $cn_ps_re ]] && rr=1
  fi
  shopt -u nocasematch
  ((rr))
}
# cn_exec_re: a find-style -exec, -execdir, -ok or -okdir whose next word holds a $ (the command it runs is a variable too).
cn_exec_re='(^|[[:space:]])-(exec|execdir|ok|okdir)[[:space:]]+[^[:space:]]*\$'
# ps_here_strip <text>: sets PH to the text with the bodies of its PowerShell here-strings left out. A here-string opens with @' or @"
# at a line's end and closes with '@ or "@ at a line's start. Its body is a string, not commands; a @"...@" body that holds $( keeps
# its text, since PowerShell runs that substitution. A here-string that never closes keeps its body: a false block beats a miss.
ps_here_strip() {
  local line open="" body="" out="" t
  while IFS= read -r line || [ -n "$line" ]; do
    if [ -n "$open" ]; then
      t="${line#"${line%%[![:space:]]*}"}"
      if [[ $t == "$open@"* ]]; then
        [[ $open == '"' && $body == *'$('* ]] && out+="$body"
        out+="$line$nl"; open=""; body=""
      else body+="$line$nl"; fi
      continue
    fi
    out+="$line$nl"
    [[ $line =~ @([\"\'])[[:space:]]*$ ]] && open="${BASH_REMATCH[1]}"
  done <<<"$1"
  PH="$out$body"
}
# ps_name_kind <word> <text>: how a PowerShell variable at word <word> of a segment is read (B55), by its return code. In PowerShell
# (vps: a PowerShell command, or a script one runs) a $name followed by an assignment operator is an assignment's target, in its
# word ($x=1, $x+=1, $env:X='y', $x[0]=1) or as the next word ($x = 1, $x ??= 'a'): 0, it runs no command. A constant ($true, $false,
# $null) or an automatic value ($_, $PSItem, $args, $input, $this, $env:NAME) that no call operator (& or .) runs before it is no
# command name: 2, so only the words after it are read. Any other name, and a called constant or value (& $args[0], & "$_"), is
# judged as before: 1.
ps_name_kind() {
  local p=$1 s="$2" w="${vbw[$1]}" tail nm call_re rr=0 q="'" d='"'
  local lv='^(:[A-Za-z_][A-Za-z0-9_]*)?([[][^]]*[]]|[.][A-Za-z_][A-Za-z0-9_]*)*' opre='(\+|-|\*|/|%|\?\?)?=([^=]|$)'
  ((${vps[vi]:-0})) || return 1
  [[ $w == $'\x07'* ]] || return 1
  tail="${w#$'\x07'}"
  [[ $tail =~ $lv$opre ]] && return 0
  if [[ $tail =~ $lv$ ]] && ((p + 1 < ${#vbw[@]})) && ((vbs[p + 1] == vbs[p])) && [[ ${vbw[p + 1]} =~ ^$opre ]]; then return 0; fi
  lower "${vbn[p]}"; nm="$LC"
  case $nm in true | false | null | _ | psitem | args | input | this | env) ;; *) return 1 ;; esac
  call_re="(^|[^[:alnum:]_])[&.][[:space:](${d}${q}]*[$]${vbn[p]}([^[:alnum:]_]|\$)"
  shopt -s nocasematch
  [[ $s =~ $call_re ]] && rr=1
  shopt -u nocasematch
  ((rr)) && return 1
  return 2
}
cname_judge() {
  local s="$1" mode="$2" a=0 b j k n nm p pk w sub_done
  local -a pos
  var_walk "$s"
  n=${#vbw[@]}
  while ((a < n)); do
    b=$a
    while ((b + 1 < n && vbs[b + 1] == vbs[a])); do ((b++)); done
    # The name positions of the segment: the first word after the prefixes, and the word after each find-style -exec, -execdir,
    # -ok or -okdir, which runs the command that follows it.
    pos=(); j=$a
    while ((j <= b)); do
      w="${vbw[j]}"
      if [[ $w =~ ^[A-Za-z_][A-Za-z0-9_]*\+?= ]]; then :
      elif [[ $w != *$'\x07'* && $w =~ $vsh_prefix_re ]]; then :
      else break; fi
      ((j++))
    done
    ((j <= b)) && pos+=("$j")
    for ((k = a; k < b; k++)); do
      [[ ${vbw[k]} =~ ^-(exec|execdir|ok|okdir)$ ]] && pos+=("$((k + 1))")
    done
    for p in "${pos[@]}"; do
      [[ ${vbw[p]} == *$'\x07'* ]] || continue
      # B55: a PowerShell assignment runs no command (0); a constant or automatic value that no call operator runs is no command
      # name (2), so only the words after it are read below.
      ps_name_kind "$p" "$s"; pk=$?
      ((pk == 0)) && continue
      if ((mode == 0)); then cnv=1; continue; fi
      if ((pk == 1)); then
        # A script a shell runs (a view from a wrapper) gets its variables from its caller's environment too, so one as the name is
        # blocked whatever the script assigns (B45).
        ((${vdep[vi]:-0} > 0)) && block "$MSG_CNSCR"
        nm="${vbn[p]}"; cn_asg "$nm" && block "$MSG_CNASG"
      fi
      # The words after the name, as git reads them: the subcommand is the first word that isn't an option (-C and -c take a
      # value), and a destructive long flag is blocked anywhere after the name.
      j=$((p + 1)); sub_done=0
      while ((j <= b)); do
        w="${vbw[j]}"
        case $w in
          --force* | --hard | --mirror | --delete* | --no-veri* | --discard-changes | --upload-pack* | --receive-pack* | --exec*) block "$MSG_CNAME" ;;
        esac
        if ((!sub_done)); then
          if [[ $w == -[Cc] ]]; then ((j += 2)); continue; fi
          if [[ $w == -* ]]; then ((j++)); continue; fi
          sub_done=1
          [[ " $cn_sub " == *" $w "* ]] && block "$MSG_CNAME"
        fi
        ((j++))
      done
    done
    a=$((b + 1))
  done
}

# var_sub <text>: sets vbout to the text with each reference to a name in kn replaced by its value in kv (the other
# references stay as they are).
var_sub() {
  local s="$1" nm orig k
  vbout=""
  while [[ $s == *'$'* ]]; do
    vbout+="${s%%\$*}"; s="${s#*\$}"
    if [[ $s =~ ^\{([A-Za-z_][A-Za-z0-9_]*)\} ]]; then orig="${BASH_REMATCH[0]}"; nm="${BASH_REMATCH[1]}"
    elif [[ $s =~ ^([A-Za-z_][A-Za-z0-9_]*) ]]; then orig="${BASH_REMATCH[1]}"; nm="$orig"
    else vbout+='$'; continue; fi
    for ((k = 0; k < ${#kn[@]}; k++)); do [[ ${kn[k]} == "$nm" ]] && break; done
    if ((k < ${#kn[@]})); then vbout+="${kv[k]}"; else vbout+="\$$orig"; fi
    s="${s:${#orig}}"
  done
  vbout+="$s"
}

# var_resolve: a name the command assigns once, with a plain value, is replaced by that value in cut_out and hall (the
# bodies a shell runs). The name must occur once as a word that isn't a reference, and that occurrence must be the
# assignment NAME=value at a word's start, with its value ending at a space or a separator. kn and kv get the names.
var_resolve() {
  local all="$cut_out"$'\n'"$hall"$'\n'"${subc[*]}" rest n w t re cnt seen=" " cand_re
  local -a cand=()
  cand_re='(^|[[:space:];&|()])([A-Za-z_][A-Za-z0-9_]*)\+?='
  rest="$all"
  while [[ $rest =~ $cand_re ]]; do
    cand+=("${BASH_REMATCH[2]}")
    rest="${rest#*"${BASH_REMATCH[0]}"}"
  done
  kn=(); kv=()
  for n in "${cand[@]}"; do
    [[ $seen == *" $n "* ]] && continue
    seen+="$n "
    t="${all//"\${$n}"/ }"; t="${t//"\$$n"/ }"; t="${t//[^[:alnum:]_]/ }"
    cnt=0
    for w in $t; do [[ $w == "$n" ]] && cnt=$((cnt + 1)); done
    ((cnt == 1)) || continue
    re="(^|[[:space:];&|()])${n}=([-A-Za-z0-9_./:=+@%,~]*)([[:space:];&|()<>]|\$)"
    [[ $all =~ $re ]] || continue
    kn+=("$n"); kv+=("${BASH_REMATCH[2]}")
  done
  cn_all="$all"   # B45: the command as cn_asg reads it, for a variable as a command's name
  ((${#kn[@]})) || return 0
  if [[ $cut_out == *'$'* ]]; then var_sub "$cut_out"; cut_out="$vbout"; fi
  if [[ $hall == *'$'* ]]; then var_sub "$hall"; hall="$vbout"; fi
  if [[ $hdc == *'$'* ]]; then var_sub "$hdc"; hdc="$vbout"; fi
  if [[ $hnm == *'$'* ]]; then var_sub "$hnm"; hnm="$vbout"; fi
  return 0
}

# vend, vref and var_walk: var_walk reads the words of a text as the shell does (quotes removed, and a line break or ; & |
# ( ) ends a segment). Each variable reference is \x07 in its word. vbs, vbw and vbu get each word's segment, its text and
# whether a reference in it is unquoted (a double-quoted one is only a marker). A redirect's target is no word here. vend,
# vref and var_walk share their locals, which is how vend and vref see the word being read (bash's dynamic scope).
vend() {
  if ((st)); then
    if ((skipnext)); then skipnext=0
    else vbs+=("$seg"); vbw+=("$w"); vbu+=("$uq"); vbn+=("$vn"); fi
  fi
  st=0; w=""; uq=0; vn=""
}
vref() { # at a $ (s[i]): a variable reference adds \x07 to the word and moves past itself; returns 1 when there is none
  local rest="${s:i}"
  if [[ $rest =~ ^\$\{[^}]*\} || $rest =~ ^\$[A-Za-z_][A-Za-z0-9_]* || $rest =~ ^\$[0-9@*#?!$-] ]]; then
    i=$((i + ${#BASH_REMATCH[0]})); w+=$'\x07'; st=1
    # vbn gets the name of the word's first reference (B45: a name as a command's name is checked for its assignments)
    if [[ $rest =~ ^\$\{?([A-Za-z_][A-Za-z0-9_]*) ]] && [[ -z $vn ]]; then vn="${BASH_REMATCH[1]}"; fi
    ((inq)) || uq=1
    return 0
  fi
  return 1
}
var_walk() {
  local s="$1" L=${#1} i=0 c n ch k content w="" uq=0 st=0 seg=0 skipnext=0 inq=0 vn=""
  local sesc='\'
  [[ $tool == PowerShell ]] && sesc='`'
  vbs=(); vbw=(); vbu=(); vbn=()
  while ((i < L)); do
    c="${s:i:1}"; n="${s:i+1:1}"
    if ((inq)); then
      if [[ $c == '"' ]]; then
        if [[ $tool == PowerShell && $n == '"' ]]; then w+='"'; ((i += 2)); continue; fi
        inq=0; ((i++)); continue
      fi
      if [[ $c == "$sesc" ]]; then
        if [[ $tool == PowerShell ]]; then
          [[ -n $n && $n != "$nl" ]] && w+="$n"; ((i += 2)); continue
        fi
        case $n in
          '$' | '"' | "$sesc" | '`') w+="$n"; ((i += 2)); continue ;;
          "$nl") ((i += 2)); continue ;;
        esac
      fi
      if [[ $c == '$' ]] && vref; then continue; fi
      w+="$c"; ((i++)); continue
    fi
    case $c in
      ' ' | $'\t') vend; ((i++)) ;;
      "$nl" | ';' | '&' | '|' | '(' | ')') vend; skipnext=0; ((seg++)); ((i++)) ;;
      '<' | '>') vend; skipnext=1; ((i++)) ;;
      '#')
        if ((st)); then w+='#'; ((i++))
        else k="${s:i}"; k="${k%%"$nl"*}"; ((i += ${#k})); fi ;;
      "$sesc")
        if [[ -z $n ]]; then ((i++))
        elif [[ $n == "$nl" ]]; then ((i += 2))
        else w+="$n"; st=1; ((i += 2)); fi ;;
      "'")
        k=$((i + 1)); content=""
        while ((k < L)); do
          ch="${s:k:1}"
          if [[ $ch == "'" ]]; then
            if [[ $tool == PowerShell && ${s:k+1:1} == "'" ]]; then content+="'"; ((k += 2)); continue; fi
            break
          fi
          content+="$ch"; ((k++))
        done
        w+="$content"; st=1; i=$((k + 1)) ;;
      '"') inq=1; st=1; ((i++)) ;;
      '$')
        if [[ $tool != PowerShell && ( $n == "'" || $n == '"' ) ]]; then ((i++))   # $'...' and $"...": the quote follows
        elif vref; then :
        else w+='$'; st=1; ((i++)); fi ;;
      *) w+="$c"; st=1; ((i++)) ;;
    esac
  done
  vend
}

# gitw_find <first word> <last word>: sets gitw_i to the index in vbw of the git in one segment, or -1. It is the word git (in any case)
# anywhere, or a path-qualified or .exe git (/usr/bin/git, git.exe) as the command's name: after the NAME=value words and the
# prefixes vsh_prefix_re allows, where the word runs as the command. A path that ends in git elsewhere (cp $SRC/git $DST) is an argument.
gitw_find() {
  local j cp=1 w
  gitw_i=-1
  for ((j = $1; j <= $2; j++)); do
    w="${vbw[j]}"
    if [[ $w == [Gg][Ii][Tt] ]] || { ((cp)) && [[ $w =~ $gitw_re ]]; }; then gitw_i=$j; return 0; fi
    [[ $w =~ ^[A-Za-z_][A-Za-z0-9_]*\+?= || $w =~ $vsh_prefix_re ]] || cp=0
  done
  return 0
}

# vtaker <subcommand> <word>: the word is an option that takes its value from the next word, or attached to it.
vtaker() {
  case $1 in
    commit) [[ $2 =~ ^-[aqsvefiSo]*[mCc]$ || $2 == --message ]] ;;
    tag) [[ $2 =~ ^-[aqsvefiSo]*m$ || $2 == --message ]] ;;
    checkout | switch) [[ $2 =~ ^-[a-zA-Z]*[bBcC]$ ]] ;;
    grep) [[ $2 =~ ^-[a-zA-Z]*e$ ]] ;;
    *) false ;;
  esac
}

# var_segment <first word> <last word>: the git command in one segment, if it has one, and its subcommand. In its words a
# variable is blocked when it is unquoted, a subcommand, or a quoted one that a flag or a path could be: a quoted variable
# alone, a fixed text that starts a flag without =, or no text before it. A quoted variable passes as a value taken by the
# option before it, after --, or as a push's branch after the remote (npos counts the words before it after the subcommand).
var_segment() {
  local a=$1 b=$2 gi=-1 j sub si=-1 npos=0 prev="" w p
  gitw_find "$a" "$b"; gi=$gitw_i
  ((gi < 0)) && return 0
  j=$((gi + 1))
  while ((j <= b)); do
    case ${vbw[j]} in
      -C | -c | --git-dir | --work-tree | --namespace | --config-env | --attr-source | --super-prefix) j=$((j + 2)) ;;
      -*) j=$((j + 1)) ;;
      *) break ;;
    esac
  done
  ((j <= b)) || return 0
  si=$j; sub="${vbw[j]}"
  [[ $sub == *$'\x07'* ]] && block "$MSG_SUB"
  [[ " $vb_scope " == *" $sub "* ]] || return 0
  for ((j = gi + 1; j <= b; j++)); do
    w="${vbw[j]}"
    [[ $w == -- ]] && break
    if ((j < si)) && [[ $prev == -[Cc] ]]; then   # the value of -C or -c, before the subcommand
      ((vbu[j])) && block "$MSG_VAR"
      prev="$w"; continue
    fi
    if ((j == si)); then prev="$w"; continue; fi
    if [[ $w == *$'\x07'* ]]; then
      ((vbu[j])) && block "$MSG_VAR"
      p="${w%%$'\x07'*}"
      if vtaker "$sub" "$prev" || vtaker "$sub" "$p"; then :
      elif [[ $w == $'\x07' ]]; then
        [[ $sub == push ]] && ((npos >= 1)) || block "$MSG_VAR"
      elif [[ -z $p || ( $p == -* && $p != *=* ) ]]; then block "$MSG_VAR"
      fi
    fi
    if ((j > si)) && [[ $w != -* ]] && ! vtaker "$sub" "$prev"; then npos=$((npos + 1)); fi
    prev="$w"
  done
}

# var_judge <text> [1]: each segment of the text, judged by var_segment. With a second argument of 1 each segment is also read by
# cfg_segment (B38), so only the git command's own words are, not a heredoc body. Redirections are read as the shell reads them
# (>& and &> are a redirection, not a separator), so a target such as git log > "$f" is no word of git's.
var_judge() {
  local s="${1//>&/> }" a=0 b n
  s="${s//&>/> }"
  var_walk "$s"
  n=${#vbw[@]}
  while ((a < n)); do
    b=$a
    while ((b + 1 < n && vbs[b + 1] == vbs[a])); do ((b++)); done
    var_segment "$a" "$b"
    ((${2:-0})) && cfg_segment "$a" "$b"
    a=$((b + 1))
  done
}

# --- Git configuration and program flags (B38) ----------------------------------------------------
# git -c <key>=<value> sets a configuration key for one command, and a key can name a program git runs: an alias that starts
# with !, the pager, the editor, the ssh command, a diff, merge or credential helper, a filter, an include. --config-env sets a
# key from an environment variable, and clone takes -c and --config after its subcommand too. So a key passes only when it runs
# nothing (cfg_ok), and a key that a variable or a substitution holds is blocked, since the guard can't read it (cfg_check). The
# flags that name a program for a remote, --upload-pack, --receive-pack and --exec (clone's -u as well), are blocked on fetch,
# pull, push, clone, ls-remote and archive, and so is a prefix of their names, which git accepts (cfg_segment). The variables
# that name a program git runs are blocked on a git command's line (env_run_re, read in the git rules below).
MSG_CFGVAR="a variable as a git -c or --config-env key holds a name the guard can't read, and that name can be a program git runs: write the key out"
MSG_CFGSUB="a command substitution as a git -c or --config-env key prints a name the guard can't read: write the key out"
MSG_ENVRUN="a variable that names a program git runs (GIT_PAGER, GIT_EDITOR, GIT_SSH_COMMAND, GIT_CONFIG_*, EDITOR, PAGER and the like) is set on a git command, and the guard can't see which program runs"
# cfg_pre: the words name a git command's global option (git -c, git -C) or a remote subcommand, where cfg_segment reads.
cfg_pre='[Gg][Ii][Tt][[:space:]]+-|(^|[^[:alnum:]_.-])(fetch|pull|push|clone|ls-remote|archive)([^[:alnum:]_.-]|$)'
# The names above as they're set on a command's line: before git, after export or env, or as PowerShell's $env:NAME = value.
env_run_re='(^|[^[:alnum:]_.-])(\$env:)?(GIT_(CONFIG|SSH|PAGER|EDITOR|SEQUENCE_EDITOR|EXTERNAL_DIFF|ASKPASS|PROXY_COMMAND|EXEC_PATH|ALLOW_PROTOCOL)[[:alnum:]_]*|EDITOR|VISUAL|PAGER)[[:space:]]*='

# cfg_ok <key> <value>: 0 when the key runs nothing, with the names read as git reads them (case-insensitive). pager.<cmd>
# passes only as false, which turns the pager off.
cfg_ok() {
  local ok=1
  shopt -s nocasematch
  case $1 in
    core.quotepath | core.autocrlf | core.safecrlf | core.eol | core.longpaths | core.symlinks | core.ignorecase | core.filemode \
      | core.precomposeunicode | core.abbrev | color.* | advice.* | log.* | status.* | i18n.* | user.name | user.email) ok=0 ;;
    pager.*) [[ $2 == false ]] && ok=0 ;;
  esac
  shopt -u nocasematch
  return $ok
}

# cfg_check <word>: <word> is a git -c argument, key=value, or a --config-env argument, where the value is the name of an
# environment variable. A variable or a substitution in the key is blocked, and so is a key that cfg_ok doesn't pass.
cfg_check() {
  local key="${1%%=*}" val=""
  [[ $1 == *=* ]] && val="${1#*=}"
  [[ $key == *$'\x07'* ]] && block "$MSG_CFGVAR"
  [[ $key == *$'\x1a'* ]] && block "$MSG_CFGSUB"
  cfg_ok "$key" "$val" && return 0
  block "git sets the config key $key, which can run a program or change which one git runs (an alias that starts with !, the pager, the editor, the ssh command, a diff, merge or credential helper); the keys that run nothing pass: core.quotepath, core.autocrlf, color.*, advice.*, log.*, status.*, i18n.*, user.name, user.email and pager.<cmd>=false"
}

# cfg_segment <first word> <last word>: the git command in one segment, found as var_segment finds it. Before its subcommand,
# -c and --config-env give a key, and -C, --git-dir, --work-tree, --namespace and --super-prefix take a value (so that value
# isn't taken for the subcommand). After a remote subcommand, its options before -- are read: a program flag is blocked, and
# clone also takes -c and --config (checked as keys) and the short -u, which is its upload-pack.
cfg_segment() {
  local a=$1 b=$2 gi=-1 j sub w name nxt cl c rest q
  gitw_find "$a" "$b"; gi=$gitw_i
  ((gi < 0)) && return 0
  j=$((gi + 1))
  while ((j <= b)); do
    w="${vbw[j]}"
    case $w in
      -c | --config-env)
        nxt=""; ((j + 1 <= b)) && nxt="${vbw[j + 1]}"
        cfg_check "$nxt"; j=$((j + 2)) ;;
      --config-env=*) cfg_check "${w#--config-env=}"; j=$((j + 1)) ;;
      -C | --git-dir | --work-tree | --namespace | --attr-source | --super-prefix) j=$((j + 2)) ;;
      -*) j=$((j + 1)) ;;
      *) break ;;
    esac
  done
  ((j <= b)) || return 0
  sub="${vbw[j]}"
  case $sub in fetch | pull | push | clone | ls-remote | archive) ;; *) return 0 ;; esac
  for ((j = j + 1; j <= b; j++)); do
    w="${vbw[j]}"
    [[ $w == -- ]] && break
    if [[ $w == --* ]]; then
      name="${w%%=*}"; name="${name#--}"
      [[ -n $name ]] || continue
      shopt -s nocasematch
      if [[ upload-pack == "$name"* || receive-pack == "$name"* || exec == "$name"* ]]; then
        block "git $sub --$name names a program that git runs, and the guard can't judge which one"
      fi
      if [[ $sub == clone && config == "$name"* ]]; then
        shopt -u nocasematch
        if [[ $w == *=* ]]; then cfg_check "${w#*=}"
        else nxt=""; ((j + 1 <= b)) && nxt="${vbw[j + 1]}"; cfg_check "$nxt"; j=$((j + 1)); fi
        continue
      fi
      shopt -u nocasematch
    elif [[ $sub == clone && $w == -?* ]]; then
      cl="${w#-}"
      for ((q = 0; q < ${#cl}; q++)); do
        c="${cl:q:1}"; rest="${cl:q + 1}"
        case $c in
          u) block "git clone -u names a program that git runs on the remote end, and the guard can't judge which one" ;;
          c)
            if [[ -n $rest ]]; then cfg_check "$rest"
            else nxt=""; ((j + 1 <= b)) && nxt="${vbw[j + 1]}"; cfg_check "$nxt"; j=$((j + 1)); fi
            break ;;
          b | o | j) [[ -n $rest ]] || j=$((j + 1)); break ;;
        esac
      done
    fi
  done
}

# --- Shell wrappers (B34) -----------------------------------------------------------------------
# A quoted string given to a shell or an interpreter is a script it runs: bash -c, sh -c and zsh -c (with any options before
# -c), eval, powershell or pwsh -Command (or with no -File, the text itself) and cmd /c. Each such script is a view, read as a
# command of its own, so the rules judge the git in it. A script nested in one is a view a level deeper, up to WRAP_MAX
# levels; vdep holds each view's depth (0 for the command and its readings). wrap_read reads the command's words as the shell
# does (quotes, escapes, substitutions, comments, and the heredoc bodies gtext leaves out), so a quoted name (ba''sh) or a
# shell behind a prefix (nice -n 5 bash -c) is found too. A command whose quoting it can't close is blocked, and so is
# PowerShell's -EncodedCommand, whose text is hidden from every rule.
WRAP_MAX=4
hre='(^|[^<])<<-?[[:space:]]*(\\?["'"'"']?)([A-Za-z_][A-Za-z0-9_]*)'
wrap_gate='(^|[^[:alnum:]_-])((ba|z|da|k)?sh|eval|powershell|pwsh|cmd)(\.exe)?([[:space:];&|()<>]|$)'
# B39: a heredoc whose header (the text before <<, after its last ; & |) feeds a commit's or tag's message, and whose line
# names no shell, is text no shell runs. A header that names a shell (bash, sh, eval, source...) feeds a script a shell runs.
hmsg_re='(^|[^[:alnum:]_.-])[Gg][Ii][Tt](\.[Ee][Xx][Ee])?[[:space:]]+([^;&|]*[[:space:]])?(commit|tag)([[:space:]]|$)'
# B48: a gh message with a quoted delimiter, of the subcommands that take one: pr create and edit, issue create, edit and comment,
# and release create and edit (gh's -b and --body, -F and --body-file, -n and --notes, --notes-file). Its body comes from stdin
# (hmsg_in_re: --body-file -, -F -, --notes-file -, and =- or -F-), or from a $(cat <<'EOF') given to --body, -b, --notes or -n
# (hmsg_cat_re, read on the header before its $(cat is removed). gh is matched in any case, as git is (B46).
hmsg_gh_re='(^|[^[:alnum:]_./-])[Gg][Hh][[:space:]]+(pr[[:space:]]+(create|edit)|issue[[:space:]]+(create|edit|comment)|release[[:space:]]+(create|edit))([[:space:]]|$)'
hmsg_in_re='(^|[[:space:]])(--body-file|--notes-file|-F)([[:space:]]*=?[[:space:]]*)-([[:space:]]|$)'
hmsg_cat_re='(^|[[:space:]])(--body|--notes|-b|-n)([[:space:]]*=[[:space:]]*|[[:space:]]+)"?\$\(cat[[:space:]]*$'
hshell_re='(^|[^[:alnum:]_./-])((ba|z|da|k)?sh|eval|source|exec)(\.exe)?([[:space:];&|()<>]|$)'
# B40: a cat or tee body (hcat_re is the header's command) is text unless the command names something that runs it (hrun_re): a
# shell or an interpreter, ssh, chmod, iex, a build tool that runs the file it reads (make, npm and its family), a call operator
# (&), a ./, ../ or .\ path, a dot-source, or the .git folder (git runs its hooks from there). A quoted name is read with its
# quotes removed (see the cat or tee rule below).
hcat_re='^[[:space:]]*(cat|tee)([[:space:]]|$)'
hrun_re='(^|[^[:alnum:]_./-])((ba|z|da|k)?sh|eval|source|exec|pwsh|powershell|cmd|python3?|py|perl|ruby|node|ssh|chmod|iex|invoke-expression|make|npm|npx|yarn|pnpm)(\.exe)?([[:space:];&|()<>]|$)'
hrun_re+="|(^|[[:space:];&|()])\\.\\.?[/\\\\]|(^|[[:space:];|()])&[[:space:]]|(^|[;&|()$nl][[:space:]]*)\\.[[:space:]]|\\.git[/\\\\]"
# body_kind <header> <quoted>: sets bk to the kind of the heredoc body under a header line, which the classification below and the hang
# rules read alike (B50). msg is a commit's or tag's message, or a gh message with a quoted delimiter (B40, B48): text no shell runs.
# A substitution in the header's command runs one, so only $(cat, which prints the message, keeps the body a message (hcom). cat is a
# cat or tee body, a script only when the command names a runner (hrun_re). sh is any other body, which a shell or interpreter may
# run. <quoted> is the delimiter's quote, empty when it's unquoted.
body_kind() {
  local line="$1" q="$2" hpre hsub hcom=0
  hpre="${line%%<<*}"; hpre="${hpre##*[;&|]}"; str_swap "$hpre" '$(cat' ''; hsub="$SW"
  [[ $hsub != *'$('* && $hsub != *'<('* && $hsub != *'>('* && $hsub != *"$bt"* ]] && ! [[ $line =~ $hshell_re ]] && hcom=1
  bk=sh
  if ((hcom)) && [[ $hpre =~ $hmsg_re ]]; then bk=msg
  elif ((hcom)) && [[ -n $q && $hpre =~ $hmsg_gh_re && ( $hpre =~ $hmsg_in_re || $hpre =~ $hmsg_cat_re ) ]]; then bk=msg
  elif [[ $hpre =~ $hcat_re ]]; then bk=cat
  fi
  return 0
}

tab=$'\t'; cr=$'\r'
MSG_WRAP="the guard can't read the quoting of this command, which may hold a script a shell or PowerShell runs (or an encoded PowerShell command)"
MSG_DEEP="shell wrappers nest deeper than the guard reads (four levels, such as bash -c inside sh -c)"
MSG_VIEWS="the command runs more scripts in shells than the guard reads in time"
# B45: a script's $NAME or ${NAME}, in double quotes or unquoted, is expanded by the calling shell before the script runs, so the text
# the guard reads isn't what runs (outer_re). PowerShell's $true, $false and $null are constants, and pass. A $ in single quotes,
# or escaped with \ or a backtick, is the script's own: x6 marks it, and the script is restored from it before it's read as a view.
# A $( substitution is read as a substitution (B34's bash -c "echo $(date)" passes).
x6=$'\x0e'; dl='$'
outer_re='\$[A-Za-z_{@*#?!0-9^-]'
MSG_SHSCRIPT="a shell's script, eval's argument or PowerShell's -Command holds a variable that the calling shell expands, so the guard can't read what runs: write the script out"
MSG_SHPATH="a bash script path under tools/ holds a variable, which can add a .. the guard can't see: write the path out"
MSG_IEX="Invoke-Expression runs a script the guard can't read unless it's one string argument: write the script out as one string, not as pipeline input, an expression or a second argument"

# jesc <text>: sets je to the text as the inside of a JSON string, the form a view is read in.
jesc() {
  je="$1"
  je="${je//\\/\\\\}"; je="${je//\"/\\\"}"; je="${je//$nl/\\n}"; je="${je//$tab/\\t}"; je="${je//$cr/\\r}"
}

# wrap_word: the word of s at i (s, L, i, wv and sesc belong to wrap_read). Sets wv to its value, the quotes and escapes
# removed and each substitution kept as text, and moves i past it. Returns 1 when a quote, a substitution or an ANSI-C
# string doesn't close, or an ANSI-C string has a numeric escape, which can spell any character.
wrap_word() {
  local c n k
  wv=""
  while ((i < L)); do
    c="${s:i:1}"
    case $c in ' ' | $'\t' | "$nl" | ';' | '&' | '|' | '(' | ')') return 0 ;; esac
    if [[ $c == "$sesc" ]]; then
      n="${s:i+1:1}"; i=$((i + 2))
      # an escaped line break continues the word; an escaped $ is the script's own (x6, B45)
      if [[ $n == '$' ]]; then wv+="$x6"; elif [[ $n != "$nl" && -n $n ]]; then wv+="$n"; fi
      continue
    fi
    case $c in
      "'")
        k="${s:i+1}"; [[ $k == *"'"* ]] || return 1
        k="${k%%"'"*}"; wv+="${k//\$/$x6}"; i=$((i + ${#k} + 2)) ;;   # a $ in single quotes is the script's own (B45)
      '"') wrap_dq || return 1 ;;
      '`')
        k="${s:i+1}"; [[ $k == *'`'* ]] || return 1
        k="${k%%'`'*}"; wv+="\`$k\`"; i=$((i + ${#k} + 2)) ;;
      '$')
        n="${s:i+1:1}"
        if [[ $n == '(' ]]; then
          sub_end "$s" $((i + 2)) || return 1
          wv+="${s:i:sub_e - i + 1}"; i=$((sub_e + 1))
        elif [[ $n == "'" && $tool != PowerShell ]]; then
          wrap_ansi || return 1
        else wv+='$'; ((i++)); fi ;;
      '<' | '>')
        if [[ ${s:i+1:1} == '(' && $tool != PowerShell ]]; then
          sub_end "$s" $((i + 2)) || return 1
          wv+="${s:i:sub_e - i + 1}"; i=$((sub_e + 1))
        else wv+="$c"; ((i++)); fi ;;
      *) if [[ ${s:i} =~ $wrun_word ]]; then k="${BASH_REMATCH[0]}"; wv+="$k"; i=$((i + ${#k}))
         else wv+="$c"; ((i++)); fi ;;
    esac
  done
  return 0
}

# wrap_dq: the double-quoted string at i, read as the shell reads it (PowerShell's backtick and doubled quote too). Sets wv
# and moves i past it. Returns 1 when it doesn't close, or a backtick or substitution inside it doesn't.
wrap_dq() {
  local c n k
  i=$((i + 1))
  while :; do
    ((i < L)) || return 1
    c="${s:i:1}"; n="${s:i+1:1}"
    if [[ $c == '"' ]]; then
      if [[ $tool == PowerShell && $n == '"' ]]; then wv+='"'; i=$((i + 2)); continue; fi
      i=$((i + 1)); return 0
    fi
    if [[ $c == "$sesc" ]]; then
      if [[ $tool == PowerShell ]]; then
        if [[ $n == '$' ]]; then wv+="$x6"; elif [[ $n != "$nl" ]]; then wv+="$n"; fi; i=$((i + 2))   # an escaped $ is the script's own (B45)
      else
        case $n in
          '$') wv+="$x6"; i=$((i + 2)) ;;
          '`' | '"' | "$sesc") wv+="$n"; i=$((i + 2)) ;;
          "$nl") i=$((i + 2)) ;;
          *) wv+="$c"; i=$((i + 1)) ;;
        esac
      fi
      continue
    fi
    if [[ $c == '$' && $n == '(' ]]; then
      sub_end "$s" $((i + 2)) || return 1
      wv+="${s:i:sub_e - i + 1}"; i=$((sub_e + 1))
    elif [[ $c == '`' ]]; then
      k="${s:i+1}"; [[ $k == *'`'* ]] || return 1
      k="${k%%'`'*}"; wv+="\`$k\`"; i=$((i + ${#k} + 2))
    elif [[ ${s:i} =~ $wrun_dq ]]; then
      k="${BASH_REMATCH[0]}"; wv+="$k"; i=$((i + ${#k}))
    else
      wv+="$c"; i=$((i + 1))
    fi
  done
}

# wrap_ansi: the $'...' string at i (its $). Sets wv to its text, escapes kept, and moves i past it.
wrap_ansi() {
  local j=$((i + 2)) c k
  while ((j < L)); do
    c="${s:j:1}"
    if [[ $c == "$sesc" ]]; then ((j += 2)); continue; fi
    [[ $c == "'" ]] && break
    ((j++))
  done
  ((j < L)) || return 1
  k="${s:i+2:j-i-2}"
  [[ $k == *\\[xuU0-7]* ]] && return 1
  wv+="${k//\$/$x6}"; i=$((j + 1))
}

# wrap_push <script>: a non-empty script goes to wscripts, and wtc (1 when its wrapper runs it under a timeout, B42) to wscov.
# wpx is 1 when the wrapper is a POSIX shell or eval, whose script is Bash text (B44), and wsposix gets it with each script.
# wps is 1 when the wrapper is PowerShell, whose script is PowerShell text (B55), and wsps gets it with each script.
# B45: a script with an outer_re variable (one the calling shell expands, not one in single quotes) is blocked. The test runs on
# the lowercased script, so PowerShell's constants are removed from it first.
wrap_push() {
  if [[ -n $1 ]]; then
    local t
    lower "$1"; t="$LC"
    ((wpx)) || { t="${t//\$true/}"; t="${t//\$false/}"; t="${t//\$null/}"; }
    [[ $t =~ $outer_re ]] && block "$MSG_SHSCRIPT"
    wscripts+=("$1"); wscov+=("$wtc"); wsposix+=("$wpx"); wsps+=("$wps")
  fi
  return 0
}

# wrap_rest <from>: sc is the words of wcmd from <from> on, joined by spaces, which is the text the command runs.
wrap_rest() {
  local x
  sc=""
  for ((x = $1; x < n; x++)); do sc+="${wcmd[x]} "; done
  sc="${sc% }"
}

# tcov_before <m>: 0 when a timeout of 280 seconds or less comes before word <m> of wcmd, the word of a shell, an interpreter or
# cmd that runs a script, so the whole script is bounded (B42). It's read as the hang check reads timeout N (options before the
# number, s or m). A timeout of 0 is no limit in GNU timeout, so it doesn't count.
tcov_before() {
  local m=$1 j k secs
  for ((j = 0; j < m; j++)); do
    [[ ${wcmd[j]} == timeout || ${wcmd[j]} == timeout.exe ]] || continue
    k=$((j + 1))
    while ((k < m)) && [[ ${wcmd[k]} =~ ^-[-[:alnum:]=]+$ ]]; do ((k++)); done
    ((k < m)) && [[ ${wcmd[k]} =~ ^([0-9]+)([sm]?)$ ]] || continue
    secs=$((10#${BASH_REMATCH[1]})); [[ ${BASH_REMATCH[2]} == m ]] && secs=$((secs * 60))
    ((secs >= 1 && secs <= limit_s)) && return 0
  done
  return 1
}

# --- Invoke-Expression (B60) ---------------------------------------------------------------------
# PowerShell's Invoke-Expression, and its alias iex, runs its one string argument as a script in the caller's scope, as eval runs
# its argument. That argument is read as a script of its own (PowerShell text, wps), and a $name in it is resolved when the view's
# text sets the name exactly once, with a plain quoted literal, in a command that runs before the call (pt_n, pt_v, straight-line
# code only: a branch may skip the assignment). Anything else that holds a $name the guard can't resolve is blocked by wrap_push,
# as B45 blocks a shell's script. A pipeline into the call, no argument, or an argument that isn't one string (a concatenation, a
# second argument, a splat, or a double-quoted $( the caller expands first) is blocked (MSG_IEX).
# psb_ok is 0 when the text can set a variable the table can't see: a Set-Variable or its kin, [ref], a dot-source, a module or a
# script file (ps_unsafe_re, which may set a global), or a branch or a chain (braces, parentheses, && and ||). A pipeline is no
# branch, but the assignment in one isn't recorded (psb_record). iex glued to a quote (iex'x') is one command name, as PowerShell reads it.
iex_gate='(^|[^[:alnum:]_-])(iex|invoke-expression)([[:space:];&|()<>]|$)'
brace_pat='[{}]'
ps_unsafe_re='(^|[^[:alnum:]_-])(set-variable|sv|new-variable|nv|get-variable|gv|set-item|si|set-content|sc|clear-variable|remove-variable|rv|psvariable|sessionstate|import-module|ipmo|using|variable:)([^[:alnum:]_-]|$)|\[ref\]|\.psm?1([^[:alnum:]_-]|$)|(^|[;[:space:]])\.[[:space:]]'
psb_asg_re='\$\{?(global:|script:|local:|private:)?([A-Za-z_][A-Za-z0-9_]*)\}?(\[[^]]*\])?[[:space:]]*(\+|-|\*|/|%|\?\?)?=([^=]|$)'

# psb_lit <source>: 0 when the source is one plain quoted literal, 'text' or "text", with no $, backtick or quote in its text. psb_l
# is that text.
psb_lit() {
  local t="$1" q="${1:0:1}"
  { [[ $q == "'" || $q == '"' ]] && ((${#t} >= 2)) && [[ ${t:${#t}-1} == "$q" ]]; } || return 1
  psb_l="${t:1:${#t}-2}"
  case $psb_l in *"'"* | *'"'* | *'$'* | *'`'*) return 1 ;; esac
  return 0
}

# psb_prep: sets psb_ok and psb_asg (the lowercased name of each assignment in the view's text, as psb_asg_re finds them, so a name
# set twice appears twice). Run once per view, when an Invoke-Expression needs them.
psb_prep() {
  local rest="$psb_text" ncm=0
  psb_prepped=1; psb_ok=1; psb_asg=()
  case $psb_text in *'{'* | *'}'* | *'('* | *')'* | *'&&'* | *'||'*) psb_ok=0 ;; esac
  shopt -q nocasematch && ncm=1
  shopt -s nocasematch
  [[ $psb_text =~ $ps_unsafe_re ]] && psb_ok=0
  while [[ $rest =~ $psb_asg_re ]]; do
    lower "${BASH_REMATCH[2]}"; psb_asg+=("$LC")
    rest="${rest#*"${BASH_REMATCH[0]}"}"
  done
  ((ncm)) || shopt -u nocasematch
  return 0
}

# psb_value <name>: sets psb_v to the value the name holds at this point, and returns 0, when the view's text assigns it exactly once,
# with a plain literal, in a command already read (pt_n, pt_v). Otherwise it returns 1.
psb_value() {
  local nm a c=0 k found=-1
  lower "$1"; nm="$LC"
  ((psb_prepped)) || psb_prep
  ((psb_ok)) || return 1
  for a in "${psb_asg[@]}"; do [[ $a == "$nm" ]] && c=$((c + 1)); done
  ((c == 1)) || return 1
  for ((k = 0; k < ${#pt_n[@]}; k++)); do [[ ${pt_n[k]} == "$nm" ]] && found=$k; done
  ((found >= 0)) || return 1
  psb_v="${pt_v[found]}"
  return 0
}

# psb_sub <text>: sets psb_s to the text with each $name that psb_value resolves replaced by its value. Any other $ stays, and
# wrap_push blocks a script that still holds one (B45).
psb_sub() {
  local s="$1" nm orig out="" ok
  while [[ $s == *'$'* ]]; do
    out+="${s%%\$*}"; s="${s#*\$}"
    if [[ $s =~ ^\{([A-Za-z_][A-Za-z0-9_]*)\} ]]; then orig="${BASH_REMATCH[0]}"; nm="${BASH_REMATCH[1]}"
    elif [[ $s =~ ^([A-Za-z_][A-Za-z0-9_]*) ]]; then orig="${BASH_REMATCH[1]}"; nm="$orig"
    else out+='$'; continue; fi
    # A reference that a member, an index or an operator follows ($x[0], $x.Substring(0), "$x"-f) is part of an expression, not the
    # value, so it stays and is blocked.
    ok=0
    case ${s:${#orig}:1} in
      '[' | '.' | ':' | '-' | '+' | '*' | '/' | '%' | '?' | '(' | '{' | '&' | '=' | '!' | '<' | '>') ;;
      *) psb_value "$nm" && ok=1 ;;
    esac
    if ((ok)); then out+="$psb_v"; else out+="\$$orig"; fi
    s="${s:${#orig}}"
  done
  psb_s="$out$s"
}

# psb_record: a PowerShell command that is one plain assignment, $x = 'text' or $x='text', is recorded in pt_n and pt_v, so the
# Invoke-Expressions after it in the view can read the value. Any other command records nothing.
psb_record() {
  local n=${#wcmd[@]} nm
  # A pipeline on either side of the assignment makes its value the pipeline's output, not the literal, so it isn't recorded.
  if ((wpipe)) || [[ $wsep == '|' ]]; then return 0; fi
  if ((n == 3)) && [[ ${wsrc[0]} =~ ^\$([A-Za-z_][A-Za-z0-9_]*)$ && ${wsrc[1]} == '=' ]] && psb_lit "${wsrc[2]}"; then
    nm="${BASH_REMATCH[1]}"
  elif ((n == 1)) && [[ ${wsrc[0]} =~ ^\$([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
    nm="${BASH_REMATCH[1]}"
    psb_lit "${BASH_REMATCH[2]}" || return 0
  else return 0; fi
  lower "$nm"; pt_n+=("$LC"); pt_v+=("$psb_l")
  return 0
}

# ps_iex <m>: the script of the Invoke-Expression or iex at word <m> of wcmd, into isc: its one string argument, with the variables
# psb_sub resolves. A -Command word (or -Command:value) is its parameter name, and a common parameter (-Verbose) is no argument. Any
# argument count but one, an unquoted @ (a splat or an array), and a double-quoted $( or @( (the caller expands it first) block (MSG_IEX).
ps_iex() {
  local m=$1 j n=${#wcmd[@]} w a=() asrc=() ncm=0
  shopt -q nocasematch && ncm=1
  shopt -s nocasematch
  for ((j = m + 1; j < n; j++)); do
    w="${wcmd[j]}"
    # A quoted word is always a value, as PowerShell reads it; a bare -word is a parameter, and a bare brace ends the block.
    if [[ ${wsrc[j]} != [\'\"]* && $w =~ ^-(c|co|com|comm|comma|comman|command)(:(.*))?$ ]]; then
      if [[ -n ${BASH_REMATCH[3]} ]]; then a+=("${BASH_REMATCH[3]}"); asrc+=("${wsrc[j]}"); fi
    elif [[ ${wsrc[j]} == [\'\"]* || ( $w != -* && $w != '{' && $w != '}' ) ]]; then
      a+=("$w"); asrc+=("${wsrc[j]}")
    fi
  done
  ((ncm)) || shopt -u nocasematch
  ((${#a[@]} == 1)) || block "$MSG_IEX"
  local v="${a[0]}" trail
  # A brace glued after the argument's closing quote ends a script block (ForEach-Object {iex 'x'}), so it isn't the script's text.
  trail="${asrc[0]##*[\'\"]}"
  if [[ -n $trail && -z ${trail//$brace_pat/} ]]; then v="${v%"$trail"}"; fi
  # An unquoted @ is a splat or an array, and a double-quoted $( or @( is expanded by the caller: the value isn't the text the guard reads.
  if [[ ${asrc[0]} != [\'\"]* && $v == @* ]]; then block "$MSG_IEX"; fi
  if [[ $v == *'$('* || $v == *'@('* ]] && [[ ${asrc[0]} != "'"* ]]; then block "$MSG_IEX"; fi
  psb_sub "$v"
  isc="$psb_s"
  return 0
}

# wrap_cmd: the words of one command (wcmd). A word that names a shell, eval, PowerShell or cmd takes the script its
# arguments give it. Returns 1 for PowerShell's -EncodedCommand, whose text is hidden.
wrap_cmd() {
  local m j n=${#wcmd[@]} w base p sc pr iw
  ((${vps[vi]:-0})) && psb_record
  for ((m = 0; m < n; m++)); do
    w="${wcmd[m]}"; base="${w##*/}"; base="${base##*\\}"
    wtc=0; tcov_before "$m" && wtc=1
    wpx=0; [[ $base =~ ^((ba|z|da|k)?sh)(\.exe)?$ || $base == eval ]] && wpx=1
    wps=0; [[ $base =~ ^(powershell|pwsh)(\.exe)?$ ]] && wps=1
    # B60: Invoke-Expression or iex (PowerShell names are case-insensitive, and a module may name them) in PowerShell text is a
    # wrapper when it starts a command, or follows a { (a script block, glued or not); an iex that is only an argument is text.
    # Its input is its argument: a pipeline into it (the command after a |) is blocked, as is any argument count but one (ps_iex).
    iw="${w##*\\}"; iw="${iw##*/}"; iw="${iw##*$brace_pat}"; iw="${iw%%$brace_pat*}"; lower "$iw"; iw="$LC"
    if ((${vps[vi]:-0})) && [[ $iw == iex || $iw == invoke-expression ]] \
        && { ((m == 0)) || [[ $w == *'{'* || ${wcmd[m - 1]} == *'{' ]]; }; then
      ((m == 0 && wpipe)) && block "$MSG_IEX"
      ps_iex "$m"
      wtc=0; tcov_before "$m" && wtc=1; wpx=0; wps=1
      wrap_push "$isc"
    fi
    # B48: a shell or PowerShell name right after a word that only prints its words (echo, printf, Write-Output, Write-Host, write) is
    # text, as in echo PowerShell 'x'. Anywhere else it may run a script, so ssh host pwsh -c 'x', find -exec sh -c 'x' and
    # Start-Process powershell -ArgumentList 'x' are read as before.
    pr=0; ((m > 0)) && [[ ${wcmd[m - 1]} =~ ^(echo|printf|write-output|write-host|write)$ ]] && pr=1
    if ((!pr)) && [[ $base =~ ^((ba|z|da|k)?sh)(\.exe)?$ ]]; then
      for ((j = m + 1; j < n; j++)); do
        case ${wcmd[j]} in
          --) break ;;
          --rcfile | --init-file | -o | +o | -O | +O) ((j++)) ;;
          --*) ;;
          [-+]*c*) ((j + 1 < n)) && wrap_push "${wcmd[j + 1]}"; break ;;
          [-+]*) ;;
          *) break ;;
        esac
      done
    elif ((!pr)) && [[ $base == eval ]]; then
      wrap_rest $((m + 1)); wrap_push "$sc"
    elif ((!pr)) && [[ $base =~ ^(powershell|pwsh)(\.exe)?$ ]]; then
      for ((j = m + 1; j < n; j++)); do
        w="${wcmd[j]}"; p="${w#[-/]}"
        if [[ $w == [-/]* && -n $p ]]; then
          [[ command == "$p"* ]] && { wrap_rest $((j + 1)); wrap_push "$sc"; break; }
          [[ file == "$p"* ]] && break
          [[ encodedcommand == "$p"* ]] && return 1
          continue
        fi
        [[ $w == *.ps1 ]] && break
        wrap_rest "$j"; wrap_push "$sc"; break
      done
    elif ((!pr)) && [[ $base =~ ^cmd(\.exe)?$ ]]; then
      for ((j = m + 1; j < n; j++)); do
        if [[ ${wcmd[j]} =~ ^/[ck]$ ]]; then wrap_rest $((j + 1)); wrap_push "$sc"; break; fi
      done
    fi
  done
  return 0
}

# wrap_read <text>: the commands of the text, each one's words read as the shell reads them. wscripts gets the scripts the
# shells run. Returns 1 when a quote or a substitution doesn't close, or a PowerShell command is encoded.
wrap_read() {
  local s="$1" L=${#1} i=0 c k i0 wv="" wcmd=() wsrc=() wpipe=0 wsep=""
  # The runs of ordinary characters (no quote, escape, substitution or separator) a word or a double-quoted string takes whole.
  if [[ $tool == PowerShell ]]; then
    sesc='`'; wrun_word='^[^[:space:];&|()<>$`'"'"'"]+'; wrun_dq='^[^"`$]+'
  else
    sesc='\'; wrun_word='^[^[:space:];&|()<>$`'"'"'"\\]+'; wrun_dq='^[^"\\$`]+'
  fi
  wscripts=(); wscov=(); wsposix=(); wsps=()
  # B60: the table of a PowerShell view's plain assignments (pt_n, pt_v), and the view's text for the checks psb_prep makes.
  pt_n=(); pt_v=(); psb_prepped=0; psb_text="$s"
  while ((i < L)); do
    c="${s:i:1}"
    case $c in
      ' ' | $'\t') ((i++)) ;;
      "$nl" | ';' | '&' | '|' | '(' | ')') wsep="$c"; wrap_cmd || return 1; wpipe=0; [[ $c == '|' ]] && wpipe=1; wcmd=(); wsrc=(); ((i++)) ;;
      '#') k="${s:i}"; k="${k%%"$nl"*}"; ((i += ${#k})) ;;
      *) i0=$i; wrap_word || return 1; wcmd+=("$wv"); wsrc+=("${s:i0:i-i0}") ;;   # wsrc: each word as written (B60)
    esac
  done
  wsep=""; wrap_cmd
}

# A comment starts at a # that begins a word: after a blank, a line start or a metacharacter, as Bash reads it. PowerShell's
# comment starts the same way and ends at the line break (B35).
cmt_re='(^|[[:blank:]|&;()<>])#'
views=("$raw")
# vps (B55) is 1 for a view that is PowerShell text: the command itself under the PowerShell tool, its readings, a PowerShell
# script a wrapper runs, and a substitution inside one. A view that is Bash text has 0.
# The other per-view arrays and flags start empty too: a variable of the same name in the hook's environment would otherwise be
# element 0 (an exported vhang=1 would skip every git rule, vcov=1 every loop). vdep is a view's wrapper depth, vcov its timeout bound,
# vpx whether it is Bash text a POSIX shell runs, and vhang whether only the hang rules read it.
vps=(); vdep=(); vcov=(); vpx=(); vhang=(); cn_all=""; hsubb=0
[[ $tool == PowerShell ]] && vps[0]=1
if [[ $tool == PowerShell ]]; then
  # PowerShell's line breaks are CR LF, CR and LF (B35). A backtick before a line break continues the line unless it's
  # escaped (``), which keeps the break; each continuation is marked x4 as a Bash backslash is below.
  pl="${raw//\\\\/$x1}"; pl="${pl//$x1$x1/$x2}"; pl="${pl//\\r\\n/$nl}"; pl="${pl//\\r/$nl}"; pl="${pl//\\n/$nl}"
  pl="${pl//"$bt$bt"/$x3}"; pl="${pl//"$bt$nl"/$x4$nl}"; pl="${pl//$x3/$bt$bt}"
else
  pl="${raw//\\\\/$x1}"; pl="${pl//$x1$x1/$x2}"; pl="${pl//$x1\\n/$x4$nl}"; pl="${pl//\\n/$nl}"
fi
# The readings: as written, as joined, and joined from each line after one that holds a comment marker and ends in a
# continuation (B31). A command with no continuation (and no PowerShell escape to read) has one reading.
if [[ $tool == PowerShell || $pl == *"$x4"* ]]; then
  # The lines, one read each (a blank line stays a line), so a long command costs one pass, not one copy of the rest per line.
  phys=()
  while IFS= read -r p; do phys+=("$p"); done <<<"$pl"
  nphys=${#phys[@]}
  view_of 0 0; views=("$view")
  # The joined reading differs from the written one only when a line continues (x4) or PowerShell has a backtick to read (ps_clean).
  if [[ $pl == *"$x4"* || $pl == *"$bt"* ]]; then
    reading_of 0 1; [[ $view == "${views[0]}" ]] || { vps[${#views[@]}]=${vps[0]:-0}; views+=("$view"); }
  fi
  for ((k = 1; k < nphys; k++)); do
    [[ ${phys[k-1]} == *"$x4" && ${phys[k-1]} =~ $cmt_re ]] || continue
    # Each such line costs a pass of the rules, so a command with very many can't run past the hook's time limit.
    if ((${#views[@]} >= 64)); then
      echo "App Director: blocked: the command has more lines that end in a continuation (a backslash, or a backtick in PowerShell) after a comment marker than the guard can read in time. If it's really needed, ask the human to run it." >&2
      exit 2
    fi
    reading_of "$k" 1; vps[${#views[@]}]=${vps[0]:-0}; views+=("$view")
  done
fi

# Each reading goes through the rules below, one at a time, so a heredoc's state in one reading can't carry
# into another. A command with no continuation has one reading, the command itself.
for ((vi = 0; vi < ${#views[@]}; vi++)); do
raw="${views[vi]}"

# The command as the shell reads its line breaks and tabs: a JSON \n ends a command, as ; does, and \t
# is a space. A real backslash (the pair \\) stays as it is, so \\n is text, not a line break. The early
# tests read this text, so a git command on any line is seen (B23). A backslash at the end of a line
# continues the command on the next line, as the shell does, so `git push \` with `--force` below is one
# command (B25). Expansions only, so no process starts. x1 is one shell backslash, x2 an escaped pair (\\).
# PowerShell's backslash is a path separator, not a continuation (its escape is the backtick, read above), so only Bash's joins the
# lines: `# c\` and a line `gh auth token` after it are two lines in PowerShell, and the command on the second is read.
detect="${raw//\\\\/$x1}"; detect="${detect//$x1$x1/$x2}"; [[ $tool == PowerShell ]] || detect="${detect//$x1\\n/}"
detect="${detect//\\n/;}"; detect="${detect//\\t/ }"; detect="${detect//$x2/$x1$x1}"
detect="${detect//$x1/$bs$bs}"

# The same command with its quotes decoded, for the rules that read words: the git flags below and the
# reads of credential files. A line break that ends a command stays a newline; a continued line (B25) has
# none. A pair of backslashes is an escaped backslash, so a newline after it still ends the command.
# Expansions only.
real="${raw//\\\\/$x1}"; real="${real//\\\"/\"}"; real="${real//$x1$x1/$x2}"; [[ $tool == PowerShell ]] || real="${real//$x1\\n/}"
real="${real//\\n/$nl}"; real="${real//\\t/ }"; real="${real//\\r/}"; real="${real//$x2/$x1$x1}"
real="${real//$x1/$bs}"

# sq: a single-quoted string, blanked by the hang rules (hcode, B50) as the quoted text of a command is.
sq="'[^']*'"

block() {
  echo "App Director: blocked: $1. If it's really needed, ask the human to run it." >&2
  exit 2
}

# (B37's check of a variable as a command's name followed by -c or -Command is below, after hang_strip: it walks the text a character at
# a time, so it reads the command without the bodies nothing runs.)

# --- Credential file reads ------------------------------------------------------------------------
# Block direct shell reads of .env and .env.<suffix> (not the templates .env.example, .env.sample,
# .env.template and .env.dist), of *.pem and *.key, and of the credential stores: ~/.ssh (any key,
# known_hosts too), git's credentials files, and the gh CLI's hosts.yml (.config/gh, or AppData's
# GitHub CLI). A path is blocked when it is one of those or sits inside one, however it is written:
# ~/, $HOME/, ${HOME}/, /c/Users/<name>/, C:\Users\<name>\ or relative. The commands that print a
# stored credential are blocked as well (gh auth token, gh auth status -t, git credential fill or get).
# These files may hold live credentials. Any credential read in a conversation context must be
# considered compromised and rotated. This is a best-effort check on the command text; indirect
# reads are not detected. The readers are Bash's (cat, head, tail, less, more, strings, and the common file readers:
# grep, egrep, fgrep, rg, sed, awk, gawk, sort, uniq, cut, nl, tac, rev, od, xxd, hexdump, base64, diff and cmp, B36)
# and PowerShell's (Get-Content, its aliases gc and type, Select-String and its alias sls, and [IO.File]::ReadAllText
# and its siblings, OpenText, OpenRead and Open, B36), matched in any case (B27), by a path (/bin/cat), quoted
# (& 'Get-Content'), with .exe, or with a backtick escape inside a word (Get-Con`tent, B30); quotes inside a reader's
# or a name's word are removed as the shell removes them (ca''t, c"a"t, B36), and in Bash a backslash that escapes an ordinary
# character is removed the same way (c\at, .en\v.local, B44); [IO.StreamReader]::new and New-Object
# System.IO.StreamReader are readers too (B30). The check runs for every tool the hook is wired to.
cred_end="([[:space:]\"';&|)]|\$)"
cred_store_re='\.ssh([/\\]|'"$cred_end"')|\.git-credentials|\.config[/\\]git[/\\]credentials|\.config[/\\]gh([/\\]|'"$cred_end"')|GitHub CLI([/\\]|'"$cred_end"')'
# A name in a read's arguments is a whole word: .env, or .pem or .key ending a word, after a character that
# isn't part of a name, so x.env doesn't match. A quote, a folder, a redirect or a wildcard (.env*) beside the
# name counts, as in "certs/server.pem", config/.env or >.env. Options and their values are arguments too.
name_end="([[:space:]\"';&|()<>*?]|\$)"
dot_env_re='(^|[^[:alnum:]_.-])\.env'"$name_end"
pem_key_re='\.(pem|key)'"$name_end"
env_re='(^|[^[:alnum:]_.-])\.env\.([^[:space:]"'"'"';&|<>()/]+)'
store_arg_re='(^|[^[:alnum:]_.-])('"$cred_store_re"')'
# Whether the arguments of a read name a credential file (0 if they do). A .env.<suffix> file (.env.local,
# ./.env.production, "config/.env.staging") is one, except the committed templates .env.example, .env.sample,
# .env.template and .env.dist: they hold no values, so they stay readable. Bash regexes have no negative
# lookahead, so each .env.<suffix> match is tested and the search goes on after it.
# cred_args <arguments> [1]: with a second argument of 1 (Bash, B52) an escaped space is a space inside the same word, so the store
# is also tested with each \ space read as a space. Only the store names read it: .env\ .example stays one word, not .env.
MSG_ANSI="an ANSI-C string (\$'...') holds an escape the guard can't decode (\\u, \\U, \\c and the rest, or a NUL or a byte past ASCII), and the text it spells can't be read: write the text out"
cred_args() {
  local args="$1" sp="${2:-0}"
  [[ $args =~ $dot_env_re || $args =~ $pem_key_re || $args =~ $store_arg_re ]] && return 0
  ((sp)) && [[ ${args//'\ '/ } =~ $store_arg_re ]] && return 0
  while [[ $args =~ $env_re ]]; do
    case ${BASH_REMATCH[2]} in example|sample|template|dist) ;; *) return 0 ;; esac
    args="${args#*"${BASH_REMATCH[0]}"}"
  done
  return 1
}
# bs_unescape <text>: sets bsout to the text with each backslash that escapes an ordinary character removed, as Bash removes it
# outside quotes (B44): c\at is cat, and .en\v.local is .env.local. A pair (\\) is one backslash, as the shell reads it, and a
# backslash before a space, a separator or a quote stays. nocasematch is off for the substitutions, since it would match \A
# against \a in the list below.
bs_unescape() {
  local t="$1" c ncm=0
  shopt -q nocasematch && ncm=1
  shopt -u nocasematch
  t="${t//\\\\/$x1}"
  for c in {a..z} {A..Z} {0..9} . _ / : '~' = , + @ % '*' '?' '#' -; do
    [[ $t == *"$bs$c"* ]] && { str_swap "$t" "$bs$c" "$c"; t="$SW"; }
  done
  bsout="${t//$x1/$bs}"
  ((ncm)) && shopt -s nocasematch
  return 0
}
# ascii_of <value>: sets ch to the character of an ASCII value from 1 to 127, and returns 1 for any other value (B52).
ascii_of() {
  (($1 >= 1 && $1 <= 127)) || return 1
  printf -v ch '%03o' "$1"; printf -v ch "\\$ch"
}
# ansi_c <text>: sets ansic to the text with each ANSI-C string ($'...', outside quotes) replaced by the text it spells (B52), as
# the shell reads it: \a \b \e \E \f \n \r \t \v \\ \' \" \? , \xHH (one or two hex digits) and \NNN (one to three octal digits),
# each an ASCII character from 1 to 127. A ; & or | the string holds is a placeholder (\x05), since the shell keeps it in the
# word, so it splits no read. Returns 1 when the string can't be read: an escape not in that list (\u, \U, \c and the rest, which
# can spell any character), a NUL or a byte past ASCII, or no closing quote. Single and double quotes are copied, and a $' inside
# double quotes is text, as the shell reads it.
ansi_c() {
  local s="$1" L=${#1} i=0 j c n k v h ch ncm=0 out=""
  shopt -q nocasematch && ncm=1
  shopt -u nocasematch
  while ((i < L)); do
    c="${s:i:1}"; n="${s:i+1:1}"
    case $c in
      '\') out+="${s:i:2}"; ((i += 2)); continue ;;
      "'")
        k="${s:i+1}"
        [[ $k == *"'"* ]] || { out+="${s:i}"; break; }
        k="${k%%"'"*}"; out+="'$k'"; ((i += ${#k} + 2)); continue ;;
      '"')
        k=$((i + 1))
        while ((k < L)) && [[ ${s:k:1} != '"' ]]; do
          [[ ${s:k:1} == '\' ]] && ((k++))
          ((k++))
        done
        out+="${s:i:k - i + 1}"; i=$((k + 1)); continue ;;
      '$')
        if [[ $n == '$' ]]; then out+='$$'; ((i += 2)); continue; fi
        if [[ $n == "'" ]]; then
          j=$((i + 2)); v=""
          while ((j < L)) && [[ ${s:j:1} != "'" ]]; do
            if [[ ${s:j:1} != '\' ]]; then v+="${s:j:1}"; ((j++)); continue; fi
            n="${s:j+1:1}"; ((j += 2))
            case $n in
              '\' | "'" | '"' | '?') v+="$n" ;;
              a) v+=$'\a' ;;
              b) v+=$'\b' ;;
              e | E) v+=$'\e' ;;
              f) v+=$'\f' ;;
              n) v+=$'\n' ;;
              r) v+=$'\r' ;;
              t) v+=$'\t' ;;
              v) v+=$'\v' ;;
              x)
                h=""
                while ((${#h} < 2)) && [[ ${s:j:1} == [0-9A-Fa-f] ]]; do h+="${s:j:1}"; ((j++)); done
                ((${#h})) || return 1
                ascii_of $((16#$h)) || return 1; v+="$ch" ;;
              [0-7])
                h="$n"
                while ((${#h} < 3)) && [[ ${s:j:1} == [0-7] ]]; do h+="${s:j:1}"; ((j++)); done
                ascii_of $((8#$h)) || return 1; v+="$ch" ;;
              *) return 1 ;;
            esac
          done
          ((j < L)) || return 1
          v="${v//[;&|]/$'\x05'}"; out+="$v"; i=$((j + 1)); continue
        fi ;;
    esac
    out+="$c"; ((i++))
  done
  ansic="$out"
  ((ncm)) && shopt -s nocasematch
  return 0
}
reads_cred_file() {
  # The command as the shell reads it (real, above, with the line breaks that end a command as ;), so
  # C:\Users\V works, a tab is a space and a backslash-joined line is one line (B25).
  local cmd="${real//$nl/;}" sp=0
  # A reader is its command word after a space, a separator, an opening bracket, a quote (a -Command or -c
  # string: powershell -Command "gc .env"), a backslash, a slash or a backtick, then its arguments up to the next ; & or |.
  # Every argument is tested, so the file may follow an option (tail -n 20 .env) or another file (cat README.md
  # .env.local), and a PowerShell -Path or -LiteralPath value is one too. type is a Bash builtin as well
  # (type git), so only a credential name after it is blocked, as for cat. The name may be a path (/bin/cat, or
  # Microsoft.PowerShell.Management\Get-Content), carry .exe (cat.exe), or be quoted (& 'Get-Content' .env.local, B30).
  # The common file readers (B36) print a file's content too: search (grep, egrep, fgrep, rg, sed, awk, gawk), sort,
  # uniq, cut, nl, tac and rev, dump (od, xxd, hexdump, base64) and compare (diff, cmp). A pattern is an argument
  # as well, so grep "\.env" is blocked as Select-String's pattern is (B27): the arguments can't tell a pattern from a
  # path. cp, mv and scp copy a file without printing it, and wc prints only counts, so none of them is in the list.
  local readers='(cat|head|tail|less|more|strings|type|gc|get-content|select-string|sls|grep|egrep|fgrep|rg|sed|awk|gawk|sort|uniq|cut|nl|tac|rev|od|xxd|hexdump|base64|diff|cmp)'
  local name_quote="['\"]*"
  local read_re='(^|[[:space:]|;&("'"'"'`\\/])'"$readers"'(\.exe)?'"$name_quote"'[[:space:]]+([^;&|]*)'
  # [IO.File]::ReadAllText(...), and its ReadAllLines, ReadAllBytes and ReadLines: the arguments run to the next ; & or |.
  # OpenText, OpenRead and Open open a file to read it (B36).
  local file_re='(^|[^[:alnum:]_.-])\[(system\.)?io\.file\]::(readtext|readlines|readbytes|readalltext|readalllines|readallbytes|opentext|openread|open)[[:space:]]*\(([^;&|]*)'
  # [IO.StreamReader]::new(...) and New-Object System.IO.StreamReader (-TypeName ... -ArgumentList ...), whose
  # arguments run to the next ; & or | as well (B30).
  local stream_re='(^|[^[:alnum:]_.-])(\[(system\.)?io\.streamreader\]::new|new-object[[:space:]]+(-typename[[:space:]]+)?(system\.)?io\.streamreader)([^;&|]*)'
  # A name or a reader split by quotes (ca''t, c"a"t, .en''v.local) is read as the shell runs it: the quotes are removed,
  # and the same tests run on that text too (B36). A command with no quote is tested once.
  local -a texts=("$cmd")
  # B52: in Bash an ANSI-C string is the text it spells, and that text is read as the command is (the quote removal below too). An
  # escaped space (sp) is read as a space for the store names only (cred_args).
  if [[ $tool != PowerShell || ${vpx[vi]:-0} == 1 ]]; then
    [[ $cmd == *'\ '* ]] && sp=1
    if [[ $cmd == *'$'\'* ]]; then ansi_c "$cmd" || block "$MSG_ANSI"; texts+=("$ansic"); fi
  fi
  local nq=${#texts[@]} q
  for ((q = 0; q < nq; q++)); do
    [[ ${texts[q]} == *[\"\']* ]] && texts+=("${texts[q]//[\"\']/}")
  done
  # B44: in Bash an unquoted backslash that escapes an ordinary character is removed by the shell, so each text is read again with
  # those removed (c\at is cat). PowerShell's escape is the backtick (B30), so a PowerShell command's text is read as it is; a
  # script that a POSIX shell runs inside it (vpx, set in the wrapper reading) is Bash text.
  if [[ ( $tool != PowerShell || ${vpx[vi]:-0} == 1 ) && $cmd == *\\* ]]; then
    local nt=${#texts[@]} k
    for ((k = 0; k < nt; k++)); do
      bs_unescape "${texts[k]}"
      [[ $bsout == "${texts[k]}" ]] || texts+=("$bsout")
    done
  fi
  local t rest args
  for t in "${texts[@]}"; do
    # cred_args can match only arguments that hold one of these names (.env, .pem, .key and the stores: .ssh, .git-credentials, .config/git,
    # .config/gh, GitHub CLI), in any case (the caller sets nocasematch), so a text without one is not scanned: a long file body costs
    # one test, not three regex passes.
    case $t in *.env* | *.pem* | *.key* | *.ssh* | *.git-credentials* | *.config* | *github*) ;; *) continue ;; esac
    rest="$t"
    while [[ $rest =~ $read_re ]]; do
      args="${BASH_REMATCH[4]}"
      rest="${rest#*"${BASH_REMATCH[0]}"}"
      cred_args "$args" "$sp" && return 0
    done
    rest="$t"
    while [[ $rest =~ $file_re ]]; do
      args="${BASH_REMATCH[4]}"
      rest="${rest#*"${BASH_REMATCH[0]}"}"
      cred_args "$args" "$sp" && return 0
    done
    rest="$t"
    while [[ $rest =~ $stream_re ]]; do
      args="${BASH_REMATCH[6]}"
      rest="${rest#*"${BASH_REMATCH[0]}"}"
      cred_args "$args" "$sp" && return 0
    done
  done
  return 1
}
# PowerShell's names are case-insensitive (GET-CONTENT, Gc), so the matches above are too (B27).
shopt -s nocasematch
if reads_cred_file; then
  echo "App Director: blocked: reading credential files exposes secrets to the AI context." >&2
  echo "              Use .env.example for documentation; real credentials stay out of AI context." >&2
  echo "              Any credential read in a conversation must be treated as compromised and rotated." >&2
  exit 2
fi
shopt -u nocasematch
# gh auth token, gh auth status -t and git credential fill or get print a stored credential. Matched on the decoded words
# (B39, rdec, below), so a quoted subcommand is seen; a commit message that names them has its quoted text blanked, so it isn't.
gh_print_re='(^|[^[:alnum:]_./-])gh[[:space:]]+auth[[:space:]]+(token([[:space:]]|$|[;&|)])|status[^;&|]*[[:space:]](-[[:alpha:]]*t[[:alpha:]]*|--show-token)([[:space:]]|$|[;&|)]))'
git_print_re='(^|[^[:alnum:]_.-])[Gg][Ii][Tt](\.[Ee][Xx][Ee])?[[:space:]]+([^;&|]*[[:space:]])?credential[[:space:]]+(fill|get)([[:space:]]|$|[;&|)])'

# --- Hangs ---------------------------------------------------------------------------------------
# A command that never returns, or runs past five minutes, lets the prompt cache expire, and the next
# turn rewrites the whole context. So: no Python reading its script from a heredoc, no unbounded wait loops, no long sleeps.
# Text matching only: a loop built another way isn't seen. The guard is also wired to Monitor. The rules
# read the command without the bodies no shell runs (B50, hang_strip), so a message can name them.
hang() {
  echo "App Director: blocked: $1" >&2
  echo "              $2" >&2
  exit 2
}
limit_s=280

# hang_strip (B50): sets hbt, the text the hang rules read, and hst, the text whose substitutions the shell runs. Both are the command
# as the shell reads it (real), with the bodies no shell runs left out: a commit's, tag's or gh message, and a cat or tee body that
# nothing in the command runs (body_kind, the classification's reading). A body a shell or an interpreter may run stays, and so does
# a body that never closes: a false block beats a miss. hst keeps the substitutions of an unquoted message or unrun cat body (the shell
# expands them, as gtext does, with its quotes read as text), and drops a quoted one, which the shell doesn't expand.
hang_strip() {
  local line delim="" body="" q="" bk="" hk="" hs="" hgt="" hsp="" hrt="" hrk="" hrs="" hrun=0 k=0
  local -a hcb=() hcm=()
  if [[ $real != *'<<'* ]]; then hbt="$real"; hst="$real"; return 0; fi
  while IFS= read -r line || [ -n "$line" ]; do
    if [ -n "$delim" ]; then
      if [[ $line == *"$delim"* ]] && [ "${line#"${line%%[![:space:]]*}"}" = "$delim" ]; then
        delim=""; hsp=""
        [[ -z $q && ( $body == *'$('* || $body == *'`'* ) ]] && hsp="${body//[\'\"]/_}"
        hgt+="$hsp"
        case $bk in
          sh) hk+="$body$line$nl"; hs+="$body$line$nl" ;;
          msg) hs+="$hsp" ;;
          cat) hk+=$'\x1d'"$k"$'\x1e'; hs+=$'\x1f'"$k"$'\x1f'; hcb+=("$body$line$nl"); hcm+=("$hsp"); k=$((k + 1)) ;;
        esac
      else body+="$line$nl"; fi
      continue
    fi
    hk+="$line$nl"; hs+="$line$nl"; hgt+="$line$nl"
    if [[ $line =~ $hre ]]; then
      delim="${BASH_REMATCH[3]}"; q="${BASH_REMATCH[2]}"; body=""
      body_kind "$line" "$q"
    fi
  done <<<"$real"
  if [ -n "$delim" ]; then hk+="$body"; hs+="$body"; hgt+="$body"; fi
  # The runner test reads the command without its bodies, as the classification does (its gtext and hrt)
  hrt="$hgt"
  while [[ $hrt == *'> '* ]]; do str_swap "$hrt" '> ' '>'; hrt="$SW"; done
  while [[ $hrt =~ \"[^\"]*[[:space:]][^\"]*\" ]]; do hrt="${hrt/"${BASH_REMATCH[0]}"/ Q }"; done
  while [[ $hrt =~ \'[^\']*[[:space:]][^\']*\' ]]; do hrt="${hrt/"${BASH_REMATCH[0]}"/ Q }"; done
  hrt="${hrt//[\"\']/}"
  [[ $hrt =~ $hrun_re ]] && hrun=1
  for ((k = 0; k < ${#hcb[@]}; k++)); do
    if ((hrun)); then hrk="${hcb[k]}"; hrs="${hcb[k]}"; else hrk=""; hrs="${hcm[k]}"; fi
    str_swap "$hk" $'\x1d'"$k"$'\x1e' "$hrk"; hk="$SW"
    str_swap "$hs" $'\x1f'"$k"$'\x1f' "$hrs"; hs="$SW"
  done
  hbt="$hk"; hst="$hs"
  return 0
}
hang_strip
# A PowerShell here-string's body is a string, not commands, so it is left out of hbt and hst as a cat body nothing runs is (ps_here_strip),
# unless the command names something that runs it (hrun_re: iex, a shell, an interpreter, a ./ path, the call operator): a body that may run
# stays, a @"..."@ body that holds $( stays, and so does a body that never closes. A long file written from a here-string (a GDScript file
# of $Node.method() lines) then costs the rules no walk of every character.
ps_hs_skip=0   # 1 when the bodies are left out: the shell wrappers below are read without them too
if ((${vps[vi]:-0})) && [[ $hbt == *"@'"* || $hbt == *'@"'* ]]; then
  ps_here_strip "$hbt"; hps="$PH"
  if [[ $hps != "$hbt" ]]; then
    hpr="${hps//[\"\']/}"
    if ! [[ $hpr =~ $hrun_re ]]; then
      if [[ $hst == "$hbt" ]]; then hst="$hps"; else ps_here_strip "$hst"; hst="$PH"; fi
      hbt="$hps"; ps_hs_skip=1
    fi
  fi
fi

# B37: a variable as a command's name, followed by -c or -Command, runs a shell or an interpreter the guard can't tell apart.
# The words are read as the shell reads them (a quoted "& $X -c" is text, a quoted "$SHELL" is a name), and a precheck
# keeps the common command from the walk. Only the words before the name may be assignments or wrappers (env, sudo, ...). The text is
# hst, the command without the bodies nothing runs (B50), so a long file body costs no walk of every character.
if [[ $hst == *'$'* && $hst =~ $vsh_pre_re ]]; then
  var_walk "$hst"
  for ((vk = 0; vk + 1 < ${#vbw[@]}; vk++)); do
    [[ ${vbw[vk]} == *$'\x07'* ]] || continue
    vq=$vk; vok=1
    while ((vq > 0 && vbs[vq - 1] == vbs[vk])); do
      ((vq--)); [[ ${vbw[vq]} =~ $vsh_prefix_re ]] || { vok=0; break; }
    done
    ((vok && vbs[vk + 1] == vbs[vk])) && [[ ${vbw[vk + 1]} =~ $vsh_opt_re ]] && block "$MSG_SHVAR"
  done
fi

# The text the rules read (B50) is hbt as code is detect: its quoted strings blanked, and its line breaks as ;.
hcode="${hbt//$nl/;}"
hdq='"[^"]*"'
# blank_q <text> <regex>: sets BQ to the text with each match of the regex, from the left, as " Q ". A cursor moves past each
# match, so a long command with many quoted strings costs one pass, not one search of the whole text per string.
blank_q() {
  local t="$1" out="" m
  while [[ $t =~ $2 ]]; do
    m="${BASH_REMATCH[0]}"
    out+="${t%%"$m"*} Q "; t="${t#*"$m"}"
  done
  BQ="$out$t"
}
# The Python rule below reads hcode, so a quoted interpreter path is made the name the shell finds before the quoted strings are
# blanked: "C:/Program Files/Python313/python.exe" and '/usr/bin/python3' are python. A string that ends in the name is one, and only
# a command that can hold the rule's form (py, <<, a quote) is read. The names and the options an interpreter takes are py_name and py_opt.
py_name='(python[0-9]*(\.[0-9]+)*|pythonw|py)(\.exe)?'
py_dq='"([^"]*[/\\])?'"$py_name"'"'
py_sq="'([^']*[/\\\\])?${py_name}'"
if [[ $hcode == *[Pp][Yy]* && $hcode == *'<<'* && $hcode == *[\"\']* ]]; then
  shopt -s nocasematch
  while [[ $hcode =~ $py_dq ]]; do hcode="${hcode/"${BASH_REMATCH[0]}"/ python }"; done
  while [[ $hcode =~ $py_sq ]]; do hcode="${hcode/"${BASH_REMATCH[0]}"/ python }"; done
  shopt -u nocasematch
fi
blank_q "$hcode" "$hdq"; blank_q "$BQ" "$sq"; hcode="$BQ"

# 1. Python that reads its script from a heredoc or a here-string, whatever the body: on Windows it can wait for console input and
#    never return, and nothing shows that a time limit above it stops the Windows Store alias, so a bounded form is blocked too.
#    The interpreter is python, python3, python3.13 (any minor version), pythonw or py, with or without .exe, bare, behind a path
#    (/usr/bin/python3) or quoted (above). The forms, read in hcode (hbt, B50, with its quoted strings blanked, so a command or an echo
#    that names the form is text, and so is a message's body, which hbt leaves out; an interpreter's body stays in hbt):
#      py_here_re: the interpreter, its options (python3 -u, -X utf8, py -3) and a - for stdin, then a heredoc (<<, <<-, <<\E) or a
#                  here-string (<<<), also after a redirect (python - 2>/dev/null <<'E'), behind a wrapper or in a chain
#                  (timeout 60 python - <<E, cd x && python - <<E);
#      py_pipe_re: a heredoc piped into the interpreter with no script (cat <<'E' | python -);
#      py_hs_re:   a PowerShell here-string piped into it ('@ | python -), read in hbt, which keeps the line that closes the string.
#    A script file (python tool.py <<'E'), -c and -m read no script from stdin, so a heredoc of data given to them passes. A line
#    continuation is already joined in the text (Bash), and a script that bash -c, eval and the like run is a view of its own.
py_opt='(-[XW]([^[:space:];&|<>]*|[[:space:]]+[^-[:space:];&|<>][^[:space:];&|<>]*)|-[ABD-LN-VYZabd-ln-z0-9.:_-]+|--[a-z-]+)'
py_red='[0-9&]*>>?&?[^[:space:];&|<>]+'
py_args='([[:space:]]+'"$py_opt"')*([[:space:]]+-)?([[:space:]]+'"$py_red"')*'
py_pfx='((env|timeout|sudo|nice|time|nohup|winpty|exec|command|stdbuf|[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*|-[-A-Za-z0-9=.]+|[0-9][0-9.]*[smhd]?)[[:space:]]+)*'
py_end="$py_args"'[[:space:]]*($|[;&|)}]|'"$nl"')'
py_here_re='(^|[^[:alnum:]_.-])'"$py_name$py_args"'[[:space:]]*<<'
py_pipe_re='<<[^;]*[|][[:space:]]*'"$py_pfx"'([^[:space:];&|<>]*[/\\])?'"$py_name$py_end"
py_hs_re="(^|$nl)[[:space:]]*['\"]@[[:space:]]*[|][[:space:]]*(&[[:space:]]*)?${py_pfx}[\"']?([^;&|<>\"']*[/\\\\])?${py_name}[\"']?${py_end}"
MSG_PY1="python reading its script from a heredoc can hang: on Windows it can wait for console input and never return."
MSG_PY2="Write the script to a file with Write and run it (python3 script.py), use python3 -c for one line, and run python3 --version to test whether Python is there."
shopt -s nocasematch
if [[ $hcode == *py* && $hcode == *'<<'* ]]; then
  [[ $hcode =~ $py_here_re || $hcode =~ $py_pipe_re ]] && hang "$MSG_PY1" "$MSG_PY2"
fi
if [[ $hbt == *py* && ( $hbt == *"@'"* || $hbt == *'@"'* ) ]]; then
  [[ $hbt =~ $py_hs_re ]] && hang "$MSG_PY1" "$MSG_PY2"
fi
shopt -u nocasematch

# 3. A lone sleep over 280 seconds. A count may have a fraction (sleep 600.5), read to the millisecond.
sleep_re='(^|[^[:alnum:]_./-])sleep[[:space:]]+([0-9]+)(\.[0-9]*)?([smhd]?)([[:space:]]|$|[;&|)])'
# wait_ms <whole> <fraction, with its dot or empty>: sets ms to the count in thousandths (a count past nine digits is a wait for ever).
wait_ms() {
  local f="${2#.}000"
  if ((${#1} > 9)); then ms=999999999999; return 0; fi
  ms=$((10#$1 * 1000 + 10#${f:0:3}))
}
rest="$hcode"
while [[ $rest =~ $sleep_re ]]; do
  n="${BASH_REMATCH[2]}"; frac="${BASH_REMATCH[3]}"; unit="${BASH_REMATCH[4]}"
  wait_ms "$n" "$frac"
  case "$unit" in m) ms=$((ms * 60)) ;; h) ms=$((ms * 3600)) ;; d) ms=$((ms * 86400)) ;; esac
  [ "$ms" -gt $((limit_s * 1000)) ] && hang "sleep $n$frac$unit is longer than $limit_s seconds, and a wait past five minutes lets the prompt cache expire." \
    "Start the work with run_in_background and keep working until its completion notice, or wait in steps of $limit_s seconds or less."
  rest="${rest#*"${BASH_REMATCH[0]}"}"
done

# 3b. B49: PowerShell's Start-Sleep (and its alias sleep) with a count of seconds (positional, or -Seconds or -s) or of milliseconds
#     (-Milliseconds or -m), a fraction too (Start-Sleep 600.5), and cmd's timeout /t N, which waits N seconds (-1 waits for a key press
#     for ever). cmd's timeout is a wait, not a time limit: coreutils' timeout N cmd is one, read in the loop rule below.
shopt -s nocasematch
ps_sleep_re='(^|[^[:alnum:]_./-])((start-)?sleep)[[:space:]]+(-[sm][[:alpha:]]*:?[[:space:]]*)?([0-9]+)(\.[0-9]*)?([[:space:]]|$|[;&|)}])'
cmd_wait_re='(^|[^[:alnum:]_./-])timeout(\.exe)?[[:space:]]+/t[[:space:]]+(-?[0-9]+)([[:space:]]|$|[;&|)}])'
rest="$hcode"
while [[ $rest =~ $ps_sleep_re ]]; do
  m="${BASH_REMATCH[0]}"; p="${BASH_REMATCH[4]}"; n="${BASH_REMATCH[5]}"; frac="${BASH_REMATCH[6]}"
  wait_ms "$n" "$frac"
  if [[ $p == -[mM]* ]]; then ms=$(((ms + 999) / 1000)); what="a sleep of $n$frac milliseconds"
  else what="a sleep of $n$frac seconds"; fi
  [ "$ms" -gt $((limit_s * 1000)) ] && hang "$what is longer than $limit_s seconds, and a wait past five minutes lets the prompt cache expire." \
    "Start the work with run_in_background and keep working until its completion notice, or wait in steps of $limit_s seconds or less."
  rest="${rest#*"$m"}"
done
rest="$hcode"
while [[ $rest =~ $cmd_wait_re ]]; do
  m="${BASH_REMATCH[0]}"; n="${BASH_REMATCH[3]}"
  [[ $n == -* ]] && hang "timeout /t -1 waits for a key press for ever, and a wait past five minutes lets the prompt cache expire." \
    "Start the work with run_in_background, or wait in steps of $limit_s seconds or less."
  secs=$((10#$n))
  [ "$secs" -gt "$limit_s" ] && hang "timeout /t $secs waits $secs seconds, and a wait past five minutes lets the prompt cache expire." \
    "Start the work with run_in_background and keep working until its completion notice, or wait in steps of $limit_s seconds or less."
  rest="${rest#*"$m"}"
done
shopt -u nocasematch

# 2. until/while loops that sleep: under `timeout N` (N <= 280), or ended by the exit line Claude Code
#    appends to a background command's output. A loop quoted into `bash -c '...'` is read from the text too (hbt, B50).
#    B42: a script a shell or an interpreter runs (eval, -Command, cmd /c, a nested bash -c) is a view of its own, and its
#    loops are read in its text as the sleep rule reads it. A view whose wrapper is under a timeout of 280 or less (vcov)
#    is bounded whole, so its loops are not read. PowerShell's while and Start-Sleep are read in any case.
scan="$hcode"; rawscan=0
[[ $hcode =~ (bash|sh|zsh)[[:space:]]+-[a-z]*c[[:space:]] ]] && { scan="$hbt"; rawscan=1; }
scan="${scan//\\n/$nl}"
# B49: a C-style for (( loop is read as a loop, as while is; PowerShell's for is not read here.
loop_re='(^|[^[:alnum:]_./-])((until|while)[[:space:]]|for[[:space:]]*\(\()'
sleep_loop_re='(^|[^[:alnum:]_./-])((start-)?sleep)[[:space:]]'
timeout_re="(^|[^[:alnum:]_./-])timeout[[:space:]]+(-[-[:alnum:]=]+[[:space:]]+)*([0-9]+)([sm]?)[[:space:]]+([^;&|$nl]*)\$"
# loop_end <text after a loop's keyword>: sets loop to the text up to the done that closes the loop, counting the do and done of
# each loop nested in it, so an inner loop's done (while true; do for f in a b; do :; done; sleep 5; done) and a done in the
# condition ([ -f done ]) don't end it. A keyword starts a command: after ; & | ( or a line break. With no closing done
# (PowerShell's while (...) { }), loop is the whole text.
kw_re="(^|[;&|($nl])[[:space:]]*(do|done)([;&|)<>[:space:]\"']|\$)"
loop_end() {
  local t="$1" d=0 m kw pre last
  loop=""
  while [[ $t =~ $kw_re ]]; do
    m="${BASH_REMATCH[0]}"; kw="${BASH_REMATCH[2]}"
    pre="${t%%"$m"*}"
    if [[ $kw == done ]]; then
      d=$((d - 1))
      if ((d <= 0)); then loop+="$pre"; return 0; fi
    else d=$((d + 1)); fi
    # The character after the keyword may start the next one (done;done), so a separator goes back into the text.
    last="${m:${#m}-1:1}"
    loop+="$pre${m%?}"; t="${t#*"$m"}"
    case $last in ';' | '&' | '|' | "$nl") t="$last$t" ;; *) loop+="$last" ;; esac
  done
  loop+="$t"
  return 0
}
rest="$scan"; before=""
((${vcov[vi]:-0} == 0)) || rest=""   # under a timeout of 280 seconds or less: bounded whole (B42)
shopt -s nocasematch
while [[ $rest =~ $loop_re ]]; do
  before="$before${rest%%"${BASH_REMATCH[0]}"*}${BASH_REMATCH[1]}"
  rest="${rest#*"${BASH_REMATCH[0]}"}"
  loop_end "$rest"
  [[ $loop =~ $sleep_loop_re ]] || continue
  [[ $hbt == *"exited with code"* || $hbt == *"[killed]"* ]] && continue
  covered=0
  if [[ $before =~ $timeout_re ]]; then
    secs=$((10#${BASH_REMATCH[3]})); [ "${BASH_REMATCH[4]}" = m ] && secs=$((secs * 60))
    ttail="${BASH_REMATCH[5]}"
    # B49: a substitution after the timeout in the command's own text runs before the timeout starts, so it covers nothing. A
    # script read raw (rawscan) is quoted text the shell runs under the timeout, so the timeout covers its substitutions too.
    if ((rawscan)) || [[ $ttail != *'('* && $ttail != *'`'* ]]; then
      [ "$secs" -le "$limit_s" ] && covered=1
    fi
  fi
  [ "$covered" -eq 1 ] && continue
  [[ $loop == *tasks/*.output* ]] && hang "this loop reads a background command's output without waiting for the line Claude Code appends when it ends, so it can wait forever." \
    "Wait for \"exited with code\" or \"[killed]\" in the output file, or wrap the loop in: timeout 240 bash -c '...'"
  hang "an until, while or for (( loop with sleep and no time limit can run for ever, and a wait past five minutes lets the prompt cache expire." \
    "Put a limit on it: timeout 240 bash -c 'until ...; do sleep 5; done' (N of $limit_s or less), or start the work with run_in_background."
done
# B49: PowerShell's do { ... } while (...) or until (...) runs its body before the keyword, so a sleep in the body comes first. The body is
# the text from the do { to the } that the keyword follows. A view under a timeout of 280 seconds or less (vcov) is bounded whole.
if ((${vcov[vi]:-0} == 0)); then
  dorest="$scan"
  while [[ $dorest =~ (^|[^[:alnum:]_./-])do[[:space:]]*\{ ]]; do
    dorest="${dorest#*"${BASH_REMATCH[0]}"}"
    [[ $dorest =~ \}[[:space:]]*(while|until)[[:space:]]*\( ]] || break
    body="${dorest%%"${BASH_REMATCH[0]}"*}"
    if [[ $body =~ $sleep_loop_re ]] && [[ $hbt != *"exited with code"* && $hbt != *"[killed]"* ]]; then
      hang "a do ... while or until loop with sleep and no time limit can run for ever, and a wait past five minutes lets the prompt cache expire." \
        "Put a limit on it: timeout 240 bash -c '...' (N of $limit_s or less), or start the work with run_in_background."
    fi
  done
fi
shopt -u nocasematch

# B34: the scripts that the shells and interpreters in this text run become views, each a level deeper than this one. The
# text is read only when a shell's name shows in it with its quotes removed, so a command that names none goes no further.
wscripts=()
shl="${raw//\\\\/$x1}"; shl="${shl//\\\"/\"}"; shl="${shl//\\n/$nl}"; shl="${shl//\\t/ }"; shl="${shl//\\r/}"; shl="${shl//$x1/$bs}"
# A PowerShell here-string body nothing runs (above) is no script either, so a long file body that names eval or cmd is not read as one.
if ((ps_hs_skip)); then ps_here_strip "$shl"; shl="$PH"; fi
shopt -s nocasematch
bare="${shl//[\"\'\\]/}"
# B60: a PowerShell view that names iex or Invoke-Expression is read too (no Bash view does: iex isn't a Bash command). shl keeps
# the backslash of a module-qualified name (Microsoft.PowerShell.Utility\Invoke-Expression), which bare drops.
if [[ $bare =~ $wrap_gate ]] || { ((${vps[vi]:-0})) && { [[ $bare =~ $iex_gate ]] || [[ $shl =~ $iex_gate ]]; }; }; then
  # The heredoc bodies gtext leaves out (below) are left out here too, so a message that names a shell isn't read as a script.
  wtext=""; wdelim=""; wq=""; wbody=""
  while IFS= read -r line || [ -n "$line" ]; do
    if [ -n "$wdelim" ]; then
      if [[ $line == *"$wdelim"* ]] && [ "${line#"${line%%[![:space:]]*}"}" = "$wdelim" ]; then
        wdelim=""
        [[ -n $wq || ( $wbody != *'$('* && $wbody != *'`'* ) ]] || wtext+="${wbody//[\'\"]/_}"
        wbody=""
      else wbody+="$line$nl"; fi
      continue
    fi
    wtext+="$line$nl"
    [[ $line =~ $hre ]] && { wdelim="${BASH_REMATCH[3]}"; wq="${BASH_REMATCH[2]}"; }
  done <<<"$shl"
  wtext+="$wbody"
  bare="${wtext//[\"\'\\]/}"
  if [[ $bare =~ $wrap_gate ]] || { ((${vps[vi]:-0})) && { [[ $bare =~ $iex_gate ]] || [[ $wtext =~ $iex_gate ]]; }; }; then
    wrap_read "$wtext" || block "$MSG_WRAP"
    for ((wk = 0; wk < ${#wscripts[@]}; wk++)); do
      ((${vdep[vi]:-0} < WRAP_MAX)) || block "$MSG_DEEP"
      ((${#views[@]} < 64)) || block "$MSG_VIEWS"
      jesc "${wscripts[wk]//$x6/$dl}"; vdep[${#views[@]}]=$((${vdep[vi]:-0} + 1))   # x6 restores the script's own $ (B45)
      vcov[${#views[@]}]=$((${vcov[vi]:-0} | ${wscov[wk]:-0}))   # bounded by a timeout above it, or by its own (B42)
      vpx[${#views[@]}]=${wsposix[wk]:-0}; vhang[${#views[@]}]=${vhang[vi]:-0}   # a script a POSIX shell runs is Bash text (B44); B49: a script in a substitution's view is one too
      vps[${#views[@]}]=${wsps[wk]:-0}   # a script PowerShell runs is PowerShell text (B55)
      views+=("$je")
    done
  fi
fi
shopt -u nocasematch

# --- git-specific rules --------------------------------------------------------------------------
# A substitution's brackets are read as blanks, so $(echo git) counts as a git command (B32).
# The git name is read as the shell reads it, quotes removed, so "git", 'git' and g"it" are git (B39).
bare_g="${detect//$brackets/ }"; bare_g="${bare_g//[\"\'\\]/}"
isgit=0; [[ $bare_g =~ (^|[^[:alnum:]_.-])[Gg][Ii][Tt](\.[Ee][Xx][Ee])?([[:space:]]|$) ]] && isgit=1
# A path's last part is a name, so the git gate reads each backslash as a space (gp_g): "C:\Program Files\Git\bin\git.exe" is git, and
# so is C:\Git\bin\git.exe. The words (dec_seg) read the same name, so a quoted path that isn't a name stays text.
gp_g="${hst//[\"\']/}"; gp_g="${gp_g//\\/ }"
[[ $gp_g =~ (^|[^[:alnum:]_.-])[Gg][Ii][Tt](\.[Ee][Xx][Ee])?([[:space:]]|$) ]] && isgit=1
# The shell's name is read as the git name is (B47): quotes removed, and in any case, so "bash", 'sh' and BASH are a shell.
isbash=0; [[ $bare_g =~ (^|[^[:alnum:]_.-])([Bb][Aa])?[Ss][Hh]([[:space:]]|$) ]] && isbash=1
# A gh command (quotes removed, as the shell reads it) is read for the gh auth token rule too (B39).
gh_pre=0; [[ ${real//[\"\'\\]/} =~ (^|[^[:alnum:]_.-])gh[[:space:]] ]] && gh_pre=1
# B45: a variable as a command's name runs what it holds, so a command that has one is read too (cname_judge, mode 0). The text is
# hst, the command without the bodies nothing runs (B50), and in PowerShell without the bodies of its here-strings (above), so a file
# written from a heredoc or a here-string (a GDScript file of $Node.method() lines) costs no walk of every character.
cnv=0
[[ $hst =~ $cn_pre_re || $hst =~ $cn_exec_re ]] && cname_judge "$hst" 0

# B49: a command substitution runs before the command it's an argument of, so a timeout above it doesn't bound it: timeout 60
# echo "$(until false; do sleep 1; done)" loops for ever. A Bash command that isn't git's has each substitution read as a view for
# the hang rules alone (vhang): the gate below skips it, and it has the view's own bound (vcov), not the timeout in front of its
# command. The text read is hst (B50): the command with the bodies no shell runs left out, so a quoted message's substitution, which
# the shell doesn't expand, isn't read, and an unquoted message's is. git's substitutions are read in the git section (B32), and
# these views are read by the rules that come before the git section. B52: a PowerShell command's $(...) gets the same views, for the
# hang rules and the credential-read check, so a Bash command in it (bash -c 'c\at .env.local' inside $(...)) is read as the Bash
# command it is. PowerShell has no backtick or <( >( substitution, so only $( counts there.
if ((!isgit)) && [[ $real == *'$('* || ( $tool != PowerShell && ( $real == *'`'* || $real == *'<('* || $real == *'>('* ) ) ]]; then
  hsubb=0
  if subst_cut "$hst"; then
    for ((vn = 0; vn < sn; vn++)); do
      ((${#views[@]} < 64)) || break
      c="${subc[vn]}"; c="${c#"${c%%[![:space:]]*}"}"; c="${c%"${c##*[![:space:];]}"}"
      vdep[${#views[@]}]=${vdep[vi]:-0}; vcov[${#views[@]}]=${vcov[vi]:-0}; vpx[${#views[@]}]=${vpx[vi]:-0}; vps[${#views[@]}]=${vps[vi]:-0}; vhang[${#views[@]}]=1
      views+=("$c")
    done
  fi
fi

# B49: a view of a substitution in a command that isn't git's (vhang) is read by the hang rules only; no rule below judges it.
((${vhang[vi]:-0} == 0)) && ((isgit || isbash || gh_pre || cnv)) || continue

seg='[^;&|]*'   # the destructive git rules are below the decoding of the command (B33)

# --- git: flags that write a file, read outside the repository or run a configured command --------
# settings.json allows `git diff *`, `git log *`, `git show *`, `git commit *` and `git stash *` without
# a prompt, so every flag after them runs without one too. These turn them into a file write
# (--output), a read of any file on the machine (--no-index; a `git diff` of a path outside the
# repository, which git treats as --no-index; commit -F and --file) or the run of a configured command
# (--ext-diff). The command is read as the shell hands it to git: '--output=x', "--output"=x and
# --out\put=x are the flag, while a flag named inside a quoted message or a heredoc body is not.
# Variables and $(...) outside quotes are not expanded, so this is a text match like the rest.
sq1="'"

# Cut out the heredoc bodies (git commit -F - <<'EOF' ...; hre, the header's pattern, is set above). A quoted delimiter makes
# the body plain text; an unquoted one expands $(...) and backticks, so a body with those stays.
# B40: a body is in hdc (the destructive rules' bodies) and hnm (the file-writing flag rules') only when a shell runs it. A commit's
# or tag's message (hmsg) is text no shell runs, and so is a cat or tee body (hwr, collected in hwb) unless the command names a
# runner (hrun_re, after the loop). A shell body is collected in hsh, and hall (the variable rules' bodies, B37) is hsh once the
# cat and tee bodies that run are in it (B48), so a message or a cat body that nothing runs is no variable's text. An unquoted
# body's substitutions are in gtext (B32).
gtext=""; delim=""; hquote=""; body=""; hall=""; hsh=""; hwb=""; hdc=""; hnm=""; hmsg=0; hwr=0; hsubb=0
while IFS= read -r line || [ -n "$line" ]; do
  if [ -n "$delim" ]; then
    if [[ $line == *"$delim"* ]] && [ "${line#"${line%%[![:space:]]*}"}" = "$delim" ]; then
      delim=""
      [[ -n $hquote || ( $body != *'$('* && $body != *'`'* ) ]] || { gtext+="${body//[\'\"]/_}"; hsubb=1; }   # an unquoted body's quotes are text (B32), and its substitutions are read whole (B43)
      if ((hmsg)); then :
      elif ((hwr)); then hwb+="$body"
      else hsh+="$body"; fi
      body=""
    else body+="$line$nl"; fi
    continue
  fi
  gtext+="$line$nl"
  if [[ $line =~ $hre ]]; then
    delim="${BASH_REMATCH[3]}"; hquote="${BASH_REMATCH[2]}"
    # body_kind reads the header's kind of body (B40, B48, B50): a message no shell runs (hmsg), or a cat or tee body (hwr).
    body_kind "$line" "$hquote"; hmsg=0; hwr=0
    [[ $bk == msg ]] && hmsg=1
    [[ $bk == cat ]] && hwr=1
  fi
done <<<"$real"
gtext+="$body"   # a heredoc that never closes keeps its text: a false block beats a miss
[[ -n $body ]] && hsubb=1   # its text is read whole too, so the comment reading (B43) is off for it
hsh+="$body"
# B40: a cat or tee body is read as a shell body when the command names a runner. The text is read with its quotes removed, so
# "bash" x.sh names bash, and quoted text with a space in it is blanked, as decode_words blanks it, so a message that names bash
# doesn't. A redirect's target (> ./x) is no run, so the space after > goes.
if [[ -n $hwb ]]; then
  rt="$gtext"
  while [[ $rt == *'> '* ]]; do str_swap "$rt" '> ' '>'; rt="$SW"; done
  while [[ $rt =~ \"[^\"]*[[:space:]][^\"]*\" ]]; do rt="${rt/"${BASH_REMATCH[0]}"/ Q }"; done
  while [[ $rt =~ \'[^\']*[[:space:]][^\']*\' ]]; do rt="${rt/"${BASH_REMATCH[0]}"/ Q }"; done
  rt="${rt//[\"\']/}"
  [[ $rt =~ $hrun_re ]] && hsh+="$hwb"
fi
# B39: a backtick ends a flag in a body a shell runs, so hdc and hnm hold each backtick of such a body as a space. A backtick in a
# message is read by B32 in gtext, where an unquoted body's substitutions are.
hdc="${hsh//"$bt"/ }"; hnm="$hdc"
hall="$hsh"   # B48: the variable rules read the bodies a shell runs, as the destructive rules do (B37, B40)

# B32: the substitutions are read out of the command first (subst_cut), so the quote reading below sees placeholders, not
# their text: a quote or a ) inside a substitution can't end a quoted string or the substitution early. Outside git's
# reading (no git in the command) an unreadable substitution is left as it is.
subc=(); subk=(); sn=0
subst_cut "$gtext" || { ((isgit)) && block "$MSG_UNREAD"; cut_out="$gtext"; subc=(); subk=(); sn=0; }
# B37: a variable the command assigns once, to a plain value, is read as that value before the rules below (var_resolve).
# B45: a command name that resolves to git makes the command git, so isgit is set again from the resolved text. A name still a
# variable is judged here, in the command and in the bodies a shell runs (hnm).
[[ $cut_out$hall == *'$'* ]] && var_resolve
if ((cnv)); then
  cname_judge "$cut_out" 1
  [[ $hnm == *'$'* ]] && cname_judge "$hnm" 1
  bare_r="${cut_out//[\"\'\\]/}$nl${hnm//[\"\'\\]/}"
  [[ $bare_r =~ (^|[^[:alnum:]_.-])[Gg][Ii][Tt](\.[Ee][Xx][Ee])?([[:space:]]|$) ]] && isgit=1
fi

# --- Comments (B51) -------------------------------------------------------------------------------
# A comment runs no command, but the rules still read its words, so an unquoted git command in one still blocks. What B51
# changed is that a comment's quotes can't pair with a quote after its line break: "it's" and the 'x' on the next line
# paired, so the refspec between them read as quoted text. cms and cme
# get each comment's start and end: a # that starts a word outside quotes and ${...} (cmt_start, B43), up to the line
# break. In Bash a backslash escapes the next character outside single quotes, $'...' escapes with a backslash, a $( is
# passed over as sub_end (B43) reads it, and a backtick span runs to its closing backtick. In PowerShell a backtick
# escapes the next character outside single quotes, quotes are doubled, and a # starts a comment after a blank, a line
# break, ; & | or (. A joined PowerShell reading has lost the backtick before a #, so a # there is judged as text too.
cms=(); cme=()
# bt_end <text> <i>: sets bt_e to the backtick that closes the one at <i> (a backslash escapes the next character). 1 when none.
bt_end() {
  local s="$1" k=$(($2 + 1)) L=${#1}
  while ((k < L)); do
    case ${s:k:1} in
      '\') ((k += 2)) ;;
      '`') bt_e=$k; return 0 ;;
      *) ((k++)) ;;
    esac
  done
  return 1
}
# cmt_spans <text>: the Bash comments of the text, as cms and cme. A # in a quoted string, in a backtick span or in ${...}
# isn't a comment, and a $( is passed over whole, so a comment inside it is found by sub_end (B43).
cmt_spans() {
  local s="$1" L=${#1} i=0 st=0 pb=0 c r k
  local sesc='\'
  cms=(); cme=()
  [[ $s == *'#'* ]] || return 0
  while ((i < L)); do
    c="${s:i:1}"
    case $st in
      0)
        case $c in
          '\') ((i += 2)); continue ;;
          "'") st=1 ;;
          '"') st=2 ;;
          '`') if bt_end "$s" "$i"; then i=$((bt_e + 1)); continue; fi ;;
          '$')
            r="${s:i+1:1}"
            if [[ $r == "'" ]]; then st=3; ((i += 2)); continue
            elif [[ $r == '(' ]] && sub_end "$s" $((i + 2)) 1; then i=$((sub_e + 1)); continue
            elif [[ $r == '{' ]]; then pb=$((pb + 1)); ((i += 2)); continue; fi ;;
          '}') ((pb > 0)) && ((pb--)) ;;
          '#')
            if ((pb == 0)) && cmt_start "$s" "$i"; then
              r="${s:i}"; k="${r%%"$nl"*}"
              cms+=("$i"); cme+=($((i + ${#k})))
              ((i += ${#k})); continue
            fi ;;
        esac ;;
      1) [[ $c == "'" ]] && st=0 ;;
      2)
        case $c in
          '\') ((i += 2)); continue ;;
          '"') st=0 ;;
          '`') if bt_end "$s" "$i"; then i=$((bt_e + 1)); continue; fi ;;
          '$') if [[ ${s:i+1:1} == '(' ]] && sub_end "$s" $((i + 2)) 1; then i=$((sub_e + 1)); continue; fi ;;
        esac ;;
      3)
        case $c in
          '\') ((i += 2)); continue ;;
          "'") st=0 ;;
        esac ;;
    esac
    ((i++))
  done
}
# cmt_spans_ps <text>: the PowerShell comments of the text, as cms and cme (see above).
cmt_spans_ps() {
  local s="$1" L=${#1} i=0 st=0 pb=0 c p r k
  cms=(); cme=()
  [[ $s == *'#'* ]] || return 0
  while ((i < L)); do
    c="${s:i:1}"
    case $st in
      0)
        case $c in
          '`') ((i += 2)); continue ;;
          "'") st=1 ;;
          '"') st=2 ;;
          '$') if [[ ${s:i+1:1} == '{' ]]; then pb=$((pb + 1)); ((i += 2)); continue; fi ;;
          '}') ((pb > 0)) && ((pb--)) ;;
          '#')
            p=""; ((i > 0)) && p="${s:i-1:1}"
            if ((pb == 0)) && [[ $p == '' || $p == ' ' || $p == $'\t' || $p == "$nl" || $p == [';&|('] ]]; then
              r="${s:i}"; k="${r%%"$nl"*}"
              cms+=("$i"); cme+=($((i + ${#k})))
              ((i += ${#k})); continue
            fi ;;
        esac ;;
      1) if [[ $c == "'" ]]; then
           if [[ ${s:i+1:1} == "'" ]]; then ((i += 2)); continue; fi
           st=0
         fi ;;
      2)
        case $c in
          '`') ((i += 2)); continue ;;
          '"') if [[ ${s:i+1:1} == '"' ]]; then ((i += 2)); continue; fi; st=0 ;;
        esac ;;
    esac
    ((i++))
  done
}

# decode_words <text>: sets dec to the words the shell hands a command, as the rules read them (B26, B33). A comment (B51) is
# decoded on its own, so its quotes pair with nothing after it, and the text between comments is decoded as one.
x5=$'\x05'
qre='^(([^"'$sq1'\\]|\\.)*)("(([^"\\]|\\.)*)"|'$sq1'([^'$sq1']*)'$sq1')'
lre='^(([^"'$sq1'\\]|\\.)*)(["'$sq1'])'
# --- Command names that are paths -----------------------------------------------------------------
# A command's name can be written as a path: a quoted one with a space in it ("C:\Program Files\Git\bin\git.exe" push --force, and
# & 'C:\Program Files\Git\bin\git.exe' status), or a backslash path (C:\Git\bin\git.exe push --force). The first was blanked as text,
# and the second lost its backslashes, so no git rule read the name. A name is the first word of a segment that isn't a prefix word
# (NAME=value, the wrappers in nm_pfx, a . call operator; & is a separator, so the word after it is first). It reads as its last part
# without .exe, .cmd or .bat, in any case. NMS is 1 at a name position. A backslash is a path where the shell doesn't read it as an
# escape: always in PowerShell, and in Bash only when the word starts with a drive, ., .. or ~ or is a UNC path (c\at is still cat).
# The git gate (gp_g, above) reads the same paths. The shell gate and its wrapper reader still read the bare text.
nm_pfx='([A-Za-z_][A-Za-z0-9_]*\+?=[^[:space:]]*|env|exec|command|sudo|nohup|time|timeout|nice|ionice|stdbuf|xargs|builtin|setsid|watch|doas|coproc|if|then|else|elif|do|while|until|!|\{|-[^[:space:]]*|[0-9.]+[smhd]?|\.)'
nm_wpfx_re='^'"$nm_pfx"'$'
nm_all_re='^[[:space:]]*('"$nm_pfx"'[[:space:]]+)*('"$nm_pfx"')?[[:space:]]*$'
nm_last_re='^(.*[;&|()'"$nl"'])?([^;&|()'"$nl"']*)$'
nm_cut='[;&|()'"$nl"']*'
nm_wre='^([[:space:]]*)(([\\].?|[^[:space:]\\])+)(.*)$'
nm_bpath='^(([A-Za-z]:|\.\.?|~)[\\]|[\\][\\])'
nm_path_re='[\\/]([^\\/]*)$'
nm_ext_re='^(.+)\.([Ee][Xx][Ee]|[Cc][Mm][Dd]|[Bb][Aa][Tt])$'
nm_cand_re='[[:space:]\\/]'
NMS=1; NMO=""; NMB=""
nm_bare() { # nm_bare <word>: sets NMB to the name the word names (its last part without .exe, .cmd or .bat), or to "" when it names none
  NMB="$1"
  [[ $NMB =~ $nm_path_re ]] && NMB="${BASH_REMATCH[1]}"
  [[ $NMB =~ $nm_ext_re ]] && NMB="${BASH_REMATCH[1]}"
  [[ -z $NMB || $NMB == *[[:space:]]* ]] && NMB=""
  return 0
}
nm_chunk() { # nm_chunk <text>: sets NMO to a stretch of unquoted text as dec_seg reads it: a backslash that isn't an escape is removed, as
  # before, and a name-position word that is a path is its name. NMS moves to the name state after the stretch, so a later quote knows.
  local t="$1" o="" seg sep sg s2 ws w
  NMO=""
  [[ -z $t ]] && return 0
  if [[ $t != *\\* ]]; then   # no backslash: the text stays, and only the state moves
    NMO="$t"
    if [[ $t =~ $nm_last_re ]]; then
      if [[ -z ${BASH_REMATCH[1]} ]]; then [[ $t =~ $nm_all_re ]] || NMS=0
      elif [[ ${BASH_REMATCH[2]} =~ $nm_all_re ]]; then NMS=1
      else NMS=0; fi
    fi
    return 0
  fi
  while [[ -n $t ]]; do
    seg="${t%%$nm_cut}"; t="${t:${#seg}}"; sep=""
    if [[ -n $t ]]; then sep="${t:0:1}"; t="${t:1}"; fi
    sg=""; s2="$seg"
    while [[ $s2 =~ $nm_wre ]]; do
      ws="${BASH_REMATCH[1]}"; w="${BASH_REMATCH[2]}"; s2="${BASH_REMATCH[4]}"
      sg+="$ws"
      if ((NMS)) && [[ $w =~ $nm_wpfx_re || $w == . ]]; then sg+="${w//\\/}"; continue; fi
      if ((NMS)); then
        NMS=0
        if [[ $w == *\\* && ( $tool == PowerShell || $w =~ $nm_bpath ) ]]; then
          nm_bare "$w"
          if [[ -n $NMB ]]; then sg+="$NMB"; continue; fi
        fi
      fi
      sg+="${w//\\/}"
    done
    o+="$sg$s2$sep"
    [[ -n $sep ]] && NMS=1
  done
  NMO="$o"
}
# dec_seg <text> [1]: appends to dec the words of one stretch of a command, with the quoted strings walked from the left. One
# with a space in it is message text, so it's blanked, unless it is a command's name (a path, see above). One without a space is
# kept as a word: a flag ("--force", '-D'), a refspec ("+main"), a path (".") or a subcommand ("drop") reads as it does to the shell. A quoted string that is a flag by
# itself, or sits inside a word (--out"put"=x), keeps its spaces too. Inside a kept string, ; & | < > ( ) and a line break
# are text, not separators: each is marked \x05, which no rule matches. A "..." holding a substitution keeps its text, which
# has the placeholder, so the substitution's word is judged (B32). With the second argument 1 (a comment, B51) a quote that
# never closes is text, and the quotes after it still pair within the comment.
dec_seg() {
  local rest="$1" lone="${2:-0}" pre quoted inner word keep fresh last
  while [[ $rest =~ $qre ]]; do
    pre="${BASH_REMATCH[1]}"; quoted="${BASH_REMATCH[3]}"; rest="${rest:${#BASH_REMATCH[0]}}"
    inner="${quoted:1:${#quoted}-2}"
    if [[ $pre == *'$' && $pre != *'\$' ]]; then   # $'...' and $"...": drop the $
      pre="${pre%?}"
      [[ $quoted == "'"* && $inner =~ \\[xuU0-7] ]] && block "ANSI-C quoting with a numeric escape (\$'\\055') can spell any flag past this check"
    fi
    nm_chunk "$pre"; dec+="$NMO"   # outside quotes a backslash only escapes the next character (a joined line is already one line)
    # A quote starts a word unless the text before it ends in a word's characters (a glued one, such as --format="x")
    fresh=1
    if ((${#dec})); then
      last="${dec:${#dec}-1}"
      case $last in [[:space:]] | ';' | '&' | '|' | '(' | ')' | "$nl") ;; *) fresh=0 ;; esac
    fi
    if [[ $inner == *$'\x1a'* ]]; then dec+="${inner//\\/}"; ((fresh)) && NMS=0; continue; fi   # a double-quoted substitution (B32)
    if ((fresh && NMS)) && [[ $inner =~ $nm_cand_re ]]; then   # a quoted name with a space or a path is read as its name
      nm_bare "$inner"
      if [[ -n $NMB ]]; then dec+=" $NMB "; NMS=0; continue; fi
    fi
    word="${dec##*[[:space:];&|]}"               # the word so far
    keep=0
    if [[ $inner =~ ^--?[A-Za-z] ]]; then keep=1
    elif [[ $inner != *[[:space:]]* ]]; then keep=1
    elif [[ -n $word && $word =~ ^--[^=]*$ ]]; then keep=1; fi
    if ((keep)); then
      if ((fresh)) && ! [[ $inner =~ $nm_wpfx_re ]]; then NMS=0; fi
      inner="${inner//[;&|<>()]/$x5}"; inner="${inner//$nl/$x5}"
      dec+="$inner"
    else
      ((fresh)) && NMS=0
      dec+=" Q "
    fi
  done
  if ((lone)) && [[ $rest =~ $lre ]]; then           # B51: a comment's quote that never closes is text
    pre="${BASH_REMATCH[1]}"; rest="${rest:${#BASH_REMATCH[0]}}"
    nm_chunk "$pre"; dec+="$NMO"
    dec_seg "$rest" 1; return
  fi
  nm_chunk "$rest"; dec+="${NMO//[\"$sq1]/}"   # a quote left over never closes
}
decode_words() {
  local orig="$1" p=0 k
  dec=""
  NMS=1   # the text starts a command, and the text after a comment starts one too, since a comment ends its line
  if [[ $tool == PowerShell ]]; then cmt_spans_ps "$orig"; else cmt_spans "$orig"; fi
  for ((k = 0; k < ${#cms[@]}; k++)); do
    dec_seg "${orig:p:cms[k]-p}"
    dec_seg "${orig:cms[k]:cme[k]-cms[k]}" 1
    NMS=1
    p=${cme[k]}
  done
  dec_seg "${orig:p}"
  dec="${dec//$nl/;}"; dec="${dec//>&/> }"; dec="${dec//&>/> }"
}
decode_words "$cut_out"; gcode="$dec"

# bdecode <bodies>: sets dec to the bodies as decode_words reads them (B33). A body over 4 KB keeps every word a quote or a
# backslash hid, which costs one pass over the text rather than one per quote (a 300-line body with a quote on each line took
# seconds); exposing a word can't hide a flag.
bdecode() {
  if ((${#1} <= 4096)); then decode_words "$1"
  else
    dec="${1//[\"\'\\]/}"; dec="${dec//$nl/;}"; dec="${dec//>&/> }"; dec="${dec//&>/> }"
  fi
}
# B33, B39: the heredoc bodies the destructive rules read (dcode): each body that names one of their subcommands, decoded as the
# command is. A body without one of those subcommands can't match a rule, so only a body with one is read (the test runs with
# the quotes and backslashes removed, so pu"sh" is still found). A body is a script a shell runs, or a message that names a
# rule (B40 covers the over-block of a message).
bcode=""
if [[ ${hdc//[\"\'\\]/} =~ push|reset|clean|checkout|switch|restore|stash|branch|commit ]]; then bdecode "$hdc"; bcode="$dec"; fi
dcode="$gcode;$bcode"
# B39: the bodies a shell runs (hnm: any heredoc but a commit's or tag's message) that name git are read by the file-writing,
# file-reading and program flags and by the words of a git command (fcode). A message isn't, so it passes as it did.
ncode=""
if [[ ${hnm//[\"\'\\]/} =~ [Gg][Ii][Tt] ]]; then bdecode "$hnm"; ncode="$dec"; fi
fcode="$gcode;$ncode"
# B39: the credential-print rules read the command's decoded words, with the quotes removed as the shell removes them, and the bodies
# a shell runs. They read hst, so a commit's, tag's or gh message, and a cat or tee body nothing runs, is text that may name gh auth
# token or git credential fill (B48, B50). The decode runs only when gh or credential is named in the quote-free text (it's the
# costly part for a long message).
rdec=""
if [[ ${hst//[\"\'\\]/} =~ (^|[^[:alnum:]_.-])(gh|credential)[[:space:]] ]]; then decode_words "$hst"; rdec="$dec"; fi
[[ $rdec =~ $gh_print_re ]] && block "gh auth token and gh auth status -t print the gh CLI's stored token"
[[ $rdec =~ $git_print_re ]] && block "git credential fill and get print a credential from git's credential store"
# B32: each substitution's text is read as a command of its own (a view), so git's rules judge the git inside it.
if ((isgit)); then
  for ((vn = 0; vn < ${#subc[@]}; vn++)); do
    ((${#views[@]} < 64)) || block "the command has more command substitutions than the guard reads in time"
    c="${subc[vn]}"; c="${c#"${c%%[![:space:]]*}"}"; c="${c%"${c##*[![:space:];]}"}"
    vdep[${#views[@]}]=${vdep[vi]:-0}; vcov[${#views[@]}]=${vcov[vi]:-0}; vpx[${#views[@]}]=${vpx[vi]:-0}; vps[${#views[@]}]=${vps[vi]:-0}; views+=("$c")
  done
  # B37: a variable left in a git command's words, or in a body a shell runs, is judged where it stands (var_judge). B38: the
  # command's own words are also read for their configuration keys and program flags (cfg_segment), never a heredoc body. That
  # read is about 0.2 s for a 3 KB message, so it runs only when cfg_pre finds a git option or a remote subcommand in the words
  # (quotes and $ removed, so "git" -c and $'-c' are found too) or a variable is there for B37 to judge.
  cbare="${cut_out//[\"\'\\\$]/}"
  if [[ $cut_out == *'$'* || $cbare =~ $cfg_pre ]]; then var_judge "$cut_out" 1; fi
  [[ $hall == *'$'* ]] && var_judge "$hall"
  # B38: a variable that names a program git runs, set on the command's line. gcode has the quotes decoded, so a quoted message
  # doesn't count, and a heredoc body isn't in it.
  shopt -s nocasematch
  [[ $gcode =~ $env_run_re ]] && block "$MSG_ENVRUN"
  shopt -u nocasematch
fi

# --- git: destructive rules (B33) ------------------------------------------------------------------
# These read dcode: the words as gcode decodes them (decode_words, B26), so a quoted flag or refspec is seen and a quoted
# message is not, plus the heredoc bodies that name one of the subcommands below. A body is text a shell may run
# (bash <<'EOF' with a force push in it), so the cut that keeps a message body out of the flag rules doesn't apply here.
# A flag ends at a space, a separator, a bracket, a redirect or =, or at the end of the command (flag_end), so one
# followed by ; & | ) or a line break is found too.
flag_end='([[:space:];&|()<>=]|$)'
if ((isgit)); then
  # dcode and bcode (the bodies, decoded) are set above, where the bodies are read (B33, B39).
  shopt -s nocasematch
  [[ $raw =~ core\.hookspath ]] && block "changing core.hooksPath switches the pre-commit hook off"
  shopt -u nocasematch

  [[ $raw =~ --no-veri ]] && block "--no-verify skips the project check"
  # git commit -n in a body: the flags of a commit are read from its words below (B26), where -- ends the options.
  [[ $bcode =~ commit${seg}[[:space:]]-[a-mo-zA-Z]*n[a-zA-Z]*$flag_end ]] && block "git commit -n skips the project check"
  [[ $dcode =~ push${seg}[[:space:]](--force|--force-with-lease|--force-if-includes|-[a-zA-Z]*f[a-zA-Z]*)$flag_end ]] && block "force-push rewrites shared history"
  [[ $dcode =~ push${seg}[[:space:]]\+[^[:space:]] ]] && block "a +refspec force-pushes"
  [[ $dcode =~ reset${seg}[[:space:]]--ha ]] && block "git reset --hard discards uncommitted work"
  [[ $dcode =~ clean${seg}[[:space:]](-[a-zA-Z]*f|--force) ]] && block "git clean -f deletes untracked files"
  [[ $dcode =~ (checkout|switch)${seg}[[:space:]](-[a-zA-Z]*f[a-zA-Z]*|--force|--discard-changes)$flag_end ]] && block "this discards uncommitted changes"
  [[ $dcode =~ (checkout|restore)${seg}[[:space:]](--[[:space:]]+)?\.$flag_end ]] && block "this discards every uncommitted change"
  [[ $dcode =~ stash[[:space:]]+(drop|clear) ]] && block "this deletes stashed work"
  [[ $dcode =~ branch${seg}[[:space:]]-[a-zA-Z]*D[a-zA-Z]*$flag_end ]] && block "git branch -D deletes unmerged work"
fi

gitre='(^|[^[:alnum:]_.-])[Gg][Ii][Tt](\.[Ee][Xx][Ee])?[[:space:]]'
gitflag() { [[ $fcode =~ $gitre($seg[[:space:]])?$1 ]]; }
gitflag '--output([[:space:]=;&|]|$)' && block "--output writes a file to any path, such as one a later command runs"
gitflag '--no-index([[:space:]=;&|]|$)' && block "--no-index reads any file on the machine"
gitflag '--ext' && block "--ext-diff runs a configured external command"

# Per command: git commit and git tag -F and --file read any file (the message may come from stdin:
# -F -; `git tag -n` prints a tag's message), a git diff of a path outside the repository reads it too,
# and git grep -O and --open-files-in-pager run a command as the pager. The subcommand is the first word
# after git that isn't an option, so `git log --grep commit -F` is not a commit.
#
# And bash or sh: a script path under tools/, the first word that isn't an option, must not leave it
# with a .. segment. `Bash(bash tools/stacks/*.sh*)` matches `bash tools/stacks/../../x.sh`, and a * in
# a permission rule matches any characters, so the rule alone doesn't keep a script inside tools/. A
# path outside tools/ matches no allow rule, so it asks the human anyway. The command word is read
# with its quotes removed and in any case, as the shell runs it: "bash", 'sh' and BASH are bash and sh (B47).
outre='^(/|~|[A-Za-z]:|\$[A-Za-z_{])|(^|/)\.\.(/|$)'
dotsre='(^|/)\.\.(/|$)'
IFS=';&|' read -r -d '' -a gsegs <<<"$fcode" || true
for gs in "${gsegs[@]}"; do
  # In a git command, an unquoted brace expansion ({a,b} or {a..b}) or $IFS spells a word the parsing
  # below never sees (--{force,}, -{D,}, x$IFS--force). git's own @{...} (HEAD@{1}, @{u}..HEAD) is no
  # expansion that can make a flag: each word it makes keeps the @ in front.
  if [[ $gs =~ (^|[^[:alnum:]_.-])[Gg][Ii][Tt](\.[Ee][Xx][Ee])?([[:space:]]|$) ]]; then
    gb="${gs//@\{/ }"
    [[ $gb =~ \{[^{}[:space:]]*(,|\.\.)[^{}[:space:]]*\} ]] && block "a brace expansion in a git command can spell a flag past this check"
    [[ $gs =~ \$\{?IFS ]] && block "\$IFS in a git command can split a word into a flag past this check"
  fi
  gs="${gs//$brackets/ }"
  read -ra w <<<"$gs"
  n=${#w[@]}; k=0
  ((isgit)) && subst_segment
  # bash or sh as the command word (after VAR=x, env, time, nohup, exec, command and sudo)
  while ((k < n)) && [[ ${w[k]} =~ ^([A-Za-z_][A-Za-z0-9_]*=.*|\$|env|time|nohup|exec|command|sudo)$ ]]; do ((k++)); done
  if ((k < n)) && [[ ${w[k]} =~ (^|/)([Bb][Aa])?[Ss][Hh]$ ]]; then
    for ((k++; k < n; k++)); do
      case ${w[k]} in -o|-O|+o|+O|--rcfile|--init-file) ((k++)); continue ;; -*|+*) continue ;; esac
      # B45: a variable in a script path under tools/ can hold .., which the rule below can't see (the allow rule matches the text too).
      [[ ${w[k]} =~ ^(\./)?tools/ && ${w[k]} == *'$'* ]] && block "$MSG_SHPATH"
      [[ ${w[k]} =~ ^(\./)?tools/ && ${w[k]} =~ $dotsre ]] && block "a bash script path with a .. segment can run a script outside the allowed ones"
      break
    done
  fi
  k=0
  # git is found by its name in any case, after a path and with .exe (/usr/bin/git and GIT.EXE are git, as they are for the shell).
  while ((k < n)) && ! [[ ${w[k]} =~ $gitw_re ]]; do ((k++)); done
  ((k++))
  while ((k < n)); do
    case ${w[k]} in
      -C|-c|--git-dir|--work-tree|--namespace|--config-env|--attr-source|--super-prefix) ((k += 2)) ;;
      -*) ((k++)) ;;
      *) break ;;
    esac
  done
  case ${w[k]:-} in
    commit|tag)
      sub="${w[k]}"
      # git commit -n and --no-verify skip the project check however they are quoted or split (B26): the words here
      # have their quotes resolved, so '-n', "-n", -""n and --no-ve''rify are the flags they spell. The flags end at a
      # -- unless the word before it starts with - (an option may take the -- as its value: git commit -m -- -n
      # commits with the message -- and skips the hook). A word an option takes as its value (-m "-n") isn't a flag.
      # git tag -n lists messages, so only commit is checked.
      stop=0; takes=0
      valopt='^-[^-mFcCt]*[mFcCt]$'
      valname='^--(message|file|author|date|template|cleanup|fixup|squash|trailer|reuse-message|reedit-message|pathspec-from-file)$'
      for ((k++; k < n; k++)); do
        a="${w[k]}"
        if [[ $sub == commit && $stop -eq 0 && $takes -eq 0 ]]; then
          [[ $a == -- && ${w[k-1]} != -* ]] && stop=1
          [[ $a =~ ^-[a-mo-zA-Z]*n[a-zA-Z]*$ || $a == --no-veri* ]] &&
            block "git commit -n and --no-verify skip the project check, however the flag is quoted or split"
        fi
        takes=0; [[ $a =~ $valopt || $a =~ $valname ]] && takes=1
        if [[ $a =~ ^-[adefilnopqsvz]*F(.*)$ ]]; then v="${BASH_REMATCH[1]:-${w[k+1]:-}}"
        elif [[ $a =~ ^--fi(l|le)?(=(.*))?$ ]]; then
          if [[ -n ${BASH_REMATCH[2]} ]]; then v="${BASH_REMATCH[3]}"; else v="${w[k+1]:-}"; fi
        else continue; fi
        [[ $v == - ]] || block "git $sub -F and --file read any file on the machine; give the message on stdin: git $sub -F - <<'EOF'"
      done ;;
    diff)
      for ((k++; k < n; k++)); do
        [[ ${w[k]} == -* ]] && continue
        [[ ${w[k]} =~ $outre ]] && block "git diff of a path outside the repository reads any file on the machine"
      done ;;
    grep)
      # -O takes its command attached (-Ovim; -O alone runs the configured pager), and git reads it inside a
      # cluster too (-iO, -nOvim). -e -f -A -B -C -m take the rest of the word, or the next word, as their
      # value, so a -O after them is a value (-eO is the pattern O). After -- come paths. --open-files-in-pager
      # may be shortened to any prefix git accepts, --op and longer.
      for ((k++; k < n; k++)); do
        a="${w[k]}"
        [[ $a == -- ]] && break
        if [[ $a == --* ]]; then
          name="${a%%=*}"
          [[ $name == --op* && --open-files-in-pager == "$name"* ]] && block "git grep --open-files-in-pager runs a command as the pager"
        elif [[ $a == -* ]]; then
          cl="${a#-}"
          while [[ -n $cl ]]; do
            c="${cl:0:1}"; cl="${cl:1}"
            case $c in
              O) block "git grep -O runs a command as the pager" ;;
              [efABCm]) [[ -n $cl ]] || ((k++)); break ;;
            esac
          done
        fi
      done ;;
    push)
      # B39: --mirror and --delete, and any prefix of them that git accepts (--mi, --de), -d (and a cluster holding d, such as -fd)
      # and a :ref refspec, which deletes the ref it names. A word that starts with : is a refspec, so the rule is conservative.
      for ((k++; k < n; k++)); do
        a="${w[k]}"
        [[ $a == -- ]] && break
        if [[ $a == --* ]]; then
          name="${a%%=*}"; name="${name#--}"
          [[ -n $name && mirror == "$name"* ]] && block "git push --mirror overwrites every ref on the remote"
          [[ -n $name && delete == "$name"* ]] && block "git push --delete deletes a branch or tag on the remote"
        elif [[ $a == -?* ]]; then
          [[ ${a#-} == *d* ]] && block "git push -d deletes a branch or tag on the remote"
        elif [[ $a == :* ]]; then
          block "a push refspec that starts with : deletes the remote ref it names"
        fi
      done ;;
    branch)
      # A forced delete discards a branch's unmerged commits, and a forced move or copy overwrites the branch
      # it lands on: -D, -M or -C anywhere in a cluster, or a delete (-d, --delete), move (-m, --move) or copy
      # (-c, --copy) with a force (-f, --force), in either order or in one cluster (-df). A long option is read as git
      # reads an unambiguous prefix (--del, --forc, B39). -u takes the rest of its word as the upstream, so a cluster
      # stops there. -f alone moves a branch to a commit (git branch -f topic main) and stays allowed.
      del=0; move=0; copy=0; force=0
      for ((k++; k < n; k++)); do
        a="${w[k]}"
        [[ $a == -- ]] && break
        if [[ $a == --* ]]; then
          name="${a%%=*}"; name="${name#--}"
          if [[ -n $name ]]; then
            [[ delete == "$name"* ]] && del=1
            [[ move == "$name"* ]] && move=1
            [[ copy == "$name"* ]] && copy=1
            [[ force == "$name"* ]] && force=1
          fi
        elif [[ $a == -* ]]; then
          cl="${a#-}"
          while [[ -n $cl ]]; do
            c="${cl:0:1}"; cl="${cl:1}"
            case $c in
              D) block "git branch -D deletes unmerged work" ;;
              M|C) block "git branch -$c overwrites the branch it moves or copies onto" ;;
              d) del=1 ;;
              m) move=1 ;;
              c) copy=1 ;;
              f) force=1 ;;
              u) break ;;
            esac
          done
        fi
      done
      ((del && force)) && block "git branch -d with --force deletes unmerged work, as -D does"
      ((force && (move || copy))) && block "git branch -m or -c with --force overwrites the branch it lands on"
      ;;
    worktree)
      # git worktree remove --force (-f, a cluster with f, or --force from its first three characters)
      # deletes the worktree's uncommitted changes, and git worktree add -B resets a branch that may hold
      # commits, as -f or --force does to a branch checked out elsewhere. -b takes the rest of its word.
      ((k++))
      case ${w[k]:-} in
        remove)
          for ((k++; k < n; k++)); do
            a="${w[k]}"
            [[ $a == -- ]] && break
            if [[ $a == --* ]]; then
              name="${a%%=*}"
              ((${#name} >= 3)) && [[ --force == "$name"* ]] && block "git worktree remove --force deletes the worktree's uncommitted changes"
            elif [[ $a == -* && $a == *f* ]]; then
              block "git worktree remove -f deletes the worktree's uncommitted changes"
            fi
          done ;;
        add)
          for ((k++; k < n; k++)); do
            a="${w[k]}"
            [[ $a == -- ]] && break
            if [[ $a == --* ]]; then
              name="${a%%=*}"
              ((${#name} >= 3)) && [[ --force == "$name"* ]] && block "git worktree add --force checks out a branch another worktree has"
            elif [[ $a == -* ]]; then
              cl="${a#-}"
              while [[ -n $cl ]]; do
                c="${cl:0:1}"; cl="${cl:1}"
                case $c in
                  B) block "git worktree add -B resets a branch that may hold commits" ;;
                  f) block "git worktree add -f checks out a branch another worktree has" ;;
                  b) break ;;
                esac
              done
            fi
          done ;;
      esac ;;
  esac
done
done

exit 0
