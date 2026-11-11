#!/usr/bin/env bash
# App Director approval hook · Claude Code · framework-owned: replaced on upgrade.
#
# The human decides what the records say (.app-director/rules.md › The human decides), and tools/records.sh holds a commit
# to it: an assistant registers a summary of the exact lines (bash tools/records.sh summary <file>), and only an approval
# recorded against it lets those lines be committed. This hook records that approval when the human gives it, so the
# assistant never records one itself, and withdraws it when the human's next message says something else. Its argument
# says which event called it (settings.json):
#   prompt    UserPromptSubmit. The message is the prompt with any <system-reminder> blocks in front of it and the white
#             space around it taken off, read from the raw JSON text, so a long message is never decoded. A framed message
#             (<agent-message, <cross-session-message, <task-notification, <side-sessions-event, <ci-monitor-event, known
#             from its first bytes) and a prompt this session scheduled are not the human's: ignored whole. A message longer
#             than 200 bytes is the human's and no approval. A short one that is nothing but one of [approval] words
#             (tools/check.cfg; bash tools/records.sh word judges it), with one . or ! and a summary id (ok S7) allowed,
#             approves that summary, or with no id the newest summary this session registered since the human's previous
#             message and hasn't had approved; the hook runs bash tools/records.sh approve <id> --hook --word <word>
#             --by prompt and tells the assistant to write exactly those lines and commit them with the Approved: line. A
#             bare word with no summary of this session registered since the previous message is an ordinary message, as
#             "yes" to "Shall I run the tests?" is. When the human's previous message, and no earlier one, passed over a
#             summary of this session that is still unapproved (they asked about it, got an answer, and now write "ok"),
#             the assistant is told as well that this approves nothing, to show the lines again and ask for the word with
#             the id. An ordinary message withdraws the approvals of this session's summaries no commit has used, and, for
#             each one withdrawn or registered since the previous message, tells the assistant that nothing of it may be
#             written and that the message is a scope change to reassess. A summary two messages have passed over leaves
#             the session's list: it is forgotten (an approval by its id still counts). A prompt whose session_id isn't in
#             its first 64 KB withdraws every open approval.
#   dialog    PostToolUse on AskUserQuestion in the main conversation. A question that names exactly one summary id (S and
#             digits, a whole word) of a summary this session registered, answered with an approval word (an option
#             labelled Approve, Godkänt, Yes), approves it, --by dialog. The text a dialog left unanswered gets ("[User did
#             not answer this question...") is no answer: it records nothing, and the message the human sent instead
#             arrives on its own. Any other answer is a message from the human, as a typed one is.
#   stop      Stop. Saves the prompts of the session's pending scheduled tasks (session_crons), replacing the list.
#   outgoing  PreToolUse on the tools that carry a prompt or a message to a session (ScheduleWakeup, CronCreate,
#             CronUpdate, SendMessage, RemoteTrigger and the matching MCP tools). A prompt or message that is only an
#             approval word is refused (exit 2): an approval is the human's own message. Any other prompt is saved as one
#             this session scheduled, so it is known as soon as it is scheduled.
# An approval counts only in the session that registered the summary: record-watch.sh stamps a summary from the call that
# registered it, with that call's session_id, and a subagent's summary (the call had an agent_id) is never approved.
#
# What the hooks receive (a probe in the Claude desktop app's Code tab on Windows, 2026-11-11, logging every hook's input
# while each kind of message arrived once):
#   a typed message, and a button of the app's next-step box: UserPromptSubmit, with the text in prompt; the app sometimes
#     puts <system-reminder> blocks and blank lines in front of it, and the same message at another moment has none.
#   a question dialog's answer: no UserPromptSubmit. PostToolUse on AskUserQuestion has tool_response.answers (and the
#     same map in tool_input.answers), from each question's text to the chosen option's label.
#   a message typed while a dialog is open: PostToolUse on AskUserQuestion with an answer that begins
#     "[User did not answer this question", then UserPromptSubmit with the typed text.
#   a background subagent's report: UserPromptSubmit with prompt <agent-message from="...">...</agent-message>; a message
#     from another session: prompt <cross-session-message from="..." from-name="...">.
#   a scheduled prompt (ScheduleWakeup) as it fires: UserPromptSubmit with prompt equal to the scheduled text, plain, and
#     no field that tells it from a typed message. The Stop input lists the pending ones in session_crons.
#   inside a subagent, every PreToolUse and PostToolUse input has agent_id and agent_type; the main conversation's don't.
#     Every input has session_id.
#   Stop has last_assistant_message only when the turn ended with text.
# Limits: a hook can't see whether the assistant showed the human the summary's lines before they approved (Stop's
# last_assistant_message is missing when a turn ends on a tool call); a scheduled prompt is told apart only by its text
# (a long one by its first 200 bytes), so the hook refuses to schedule an approval word and ignores a prompt equal to one
# this session scheduled; an approval forged on purpose from the same account (writing the state by hand outside the
# assistant) can't be ruled out; and other clients (the terminal, the IDE extensions) weren't probed.
#
# It stores the approvals (through records.sh), and under .app-director/state/records/claude/ the stamps, each session's
# previous-message mark (the summary counter at the human's previous message, not a time), its summaries and its scheduled
# prompts: never the text of a human's message. Context reaches the assistant as plain text on stdout (prompt, exit 0) or
# on stderr with exit 2 (dialog, outgoing), as Claude Code's hooks pass it.
# Cost: the input is read by bash (a prompt's first 64 KB only), and a long message costs no more than a short one: only
# its first bytes are looked at (one cat drains the rest of a longer one). A message or a dialog answer starts no process
# while this session has no summary approved (one mkdir, once, for the state folder), and prints something only about a
# summary of this session withdrawn or registered since the previous message; with one approved, it starts one
# bash tools/records.sh withdraw. A short one-word message starts bash tools/records.sh word only when it names an id or
# this session has an unapproved summary that at most the previous message passed over, and an approval word then starts
# records.sh status and approve. stop starts none; outgoing starts records.sh word only for a one-word prompt. Bash 3.2
# and BSD tools run it.

mode="${1:-}"
LC_ALL=C
# bash reads a pipe a byte at a time (about 4 s for 600 KB on Windows), so a prompt is read no further than its first 64 KB:
# the session_id, the prompt's start and the reminders in front of the message are there, and a message that goes on past
# them is a long one.
# The rest of a longer input is drained (cat, a process only then), so the writer never gets a broken pipe. A prompt whose
# session_id isn't in its first 64 KB can't be tied to a session: every open approval is withdrawn, the safe side.
more=0
if [ "$mode" = prompt ]; then IFS= read -r -d '' -n 65536 input && more=1
else IFS= read -r -d '' input || true; fi
[ "$more" -eq 1 ] && cat > /dev/null
sid_re='"session_id"[[:space:]]*:[[:space:]]*"([A-Za-z0-9_-]{1,100})"'
if ! [[ $input =~ $sid_re ]]; then
  [ "$more" -eq 1 ] && cd "${CLAUDE_PROJECT_DIR:-.}" 2>/dev/null && [ -f tools/records.sh ] && bash tools/records.sh withdraw >/dev/null 2>&1
  exit 0
fi
sid="${BASH_REMATCH[1]}"
cd "${CLAUDE_PROJECT_DIR:-.}" 2>/dev/null || exit 0
[ -f tools/records.sh ] || exit 0
rs=".app-director/state/records"
cs="$rs/claude"
nl='
'
x5=$'\005'                       # no JSON text holds it raw, so it marks a place in one
ws_re='^([[:space:]]|\\[nrt])+'  # white space, raw or as a JSON escape
close='</system-reminder>'

# after <ERE> <text>: REPLY the text after the first match. The match is looked for in the first 8 KB, where a key of the
# hook's input is, with a substring for the rest (linear); only past that does a capture read the whole text.
after() {
  local w="${2:0:8192}" t re
  if [[ $w =~ $1 ]]; then t="${w#*"${BASH_REMATCH[0]}"}"; REPLY="${2:${#w}-${#t}}"; return 0; fi
  [ "${#2}" -gt 8192 ] || return 1
  re="$1(.*)\$"
  [[ $2 =~ $re ]] || return 1
  REPLY="${BASH_REMATCH[${#BASH_REMATCH[@]}-1]}"
}
# jbody <text after an opening quote>: REPLY the body up to the closing quote (one not escaped), JREST the rest.
# Called on short text only (a window of a message, a dialog's question and answer).
jbody() {
  local rest="$1" chunk out="" t n
  while [[ $rest == *\"* ]]; do
    chunk="${rest%%\"*}"; rest="${rest#*\"}"
    t="$chunk"; n=0
    while [[ $t == *\\ ]]; do t="${t%\\}"; n=$((n + 1)); done
    if [ $((n % 2)) -eq 0 ]; then REPLY="$out$chunk"; JREST="$rest"; return 0; fi
    out="$out$chunk\""
  done
  return 1
}
# u8 <code point>: REPLY the character in UTF-8, made by printf from octal escapes (no process).
u8() {
  local n=$1 f
  if [ "$n" -lt 128 ]; then printf -v f '\\%03o' "$n"
  elif [ "$n" -lt 2048 ]; then printf -v f '\\%03o\\%03o' $((192 | n >> 6)) $((128 | (n & 63)))
  elif [ "$n" -lt 65536 ]; then printf -v f '\\%03o\\%03o\\%03o' $((224 | n >> 12)) $((128 | (n >> 6 & 63))) $((128 | (n & 63)))
  else printf -v f '\\%03o\\%03o\\%03o\\%03o' $((240 | n >> 18)) $((128 | (n >> 12 & 63))) $((128 | (n >> 6 & 63))) $((128 | (n & 63)))
  fi
  printf -v REPLY "$f"
}
# jdec <JSON string body>: REPLY the text it stands for (\n, \t, \", \\, \/, \uXXXX and surrogate pairs).
jdec() {
  local s="$1" out="" c h n lo
  while [[ $s == *\\* ]]; do
    out="$out${s%%\\*}"; s="${s#*\\}"
    c="${s:0:1}"; s="${s:1}"
    case "$c" in
      n) out="$out$nl" ;;
      t) out="$out	" ;;
      r|b|f) ;;
      u)
        h="${s:0:4}"
        [[ $h =~ ^[0-9A-Fa-f]{4}$ ]] || { out="$out?"; continue; }
        s="${s:4}"; n=$((16#$h))
        if [ "$n" -ge 55296 ] && [ "$n" -le 56319 ] && [[ ${s:0:6} =~ ^\\u[Dd][C-Fc-f][0-9A-Fa-f]{2}$ ]]; then
          lo=$((16#${s:2:4})); s="${s:6}"; n=$((65536 + ((n - 55296) << 10) + (lo - 56320)))
        fi
        if [ "$n" -eq 0 ]; then out="$out?"; else u8 "$n"; out="$out$REPLY"; fi ;;
      *) out="$out$c" ;;
    esac
  done
  REPLY="$out$s"
}
# skip_lead <raw text from a string's start>: REPLY the text after the white space and the <system-reminder> blocks in
# front. Each step reads a window and cuts with a substring, so a long text costs one copy a step. A block whose end is
# more than 64 KB in stays (the text is then a long message).
skip_lead() {
  local r="$1" w t i=0 re="^[^$x5]*"
  while [ "$i" -lt 32 ]; do
    i=$((i + 1))
    [[ ${r:0:4096} =~ $ws_re ]] && r="${r:${#BASH_REMATCH[0]}}"
    [ "${r:0:17}" = "<system-reminder>" ] || break
    w="${r:0:65536}"; t="${w/"$close"/$x5}"
    [ "$t" = "$w" ] && break
    [[ $t =~ $re ]]; r="${r:${#BASH_REMATCH[0]}+18}"
  done
  REPLY="$r"
}
# short_body <raw text from a string's start>: SHORT=1 and BODY (white space at its end taken off) when the string ends
# within 200 bytes; SHORT=0 for a longer one, which is never decoded.
short_body() {
  local s
  SHORT=0; BODY=""
  jbody "${1:0:201}" || return 1
  s="$REPLY"
  while :; do
    case "$s" in
      *[[:space:]]) s="${s%?}" ;;
      *'\n'|*'\t'|*'\r') s="${s%??}" ;;
      *) break ;;
    esac
  done
  SHORT=1; BODY="$s"
}
# word_id <text>: W the word and ID the summary id (empty without one) when the text is one word, with one . or ! after
# the word or after the id, and an optional id (S7); returns 1 otherwise. Whether W is an approval word is records.sh's.
word_id() {
  local m="$1" p1="" p2=""
  W=""; ID=""
  if [[ $m =~ ^([^[:space:]]+)[[:space:]]+[Ss]([0-9]{1,9})([.!]?)$ ]]; then
    W="${BASH_REMATCH[1]}"; ID="S$((10#${BASH_REMATCH[2]}))"; p2="${BASH_REMATCH[3]}"
  elif [[ $m =~ ^[^[:space:]]+$ ]]; then W="$m"
  else return 1; fi
  case "$W" in *[.!]) p1=1; W="${W%?}" ;; esac
  if [ -n "$p1" ] && [ -n "$p2" ] || [ -z "$W" ]; then W=""; ID=""; return 1; fi
  return 0
}
# shaped <raw text from a string's start>: whether it is a short message of one word (and an id); sets W and ID. No process.
shaped() {
  W=""; ID=""
  skip_lead "$1"; short_body "$REPLY" || return 1
  jdec "$BODY"; word_id "$REPLY"
}
is_word() { bash tools/records.sh word "$1" >/dev/null 2>&1; }
ensure_cs() { [ -d "$cs" ] || mkdir -p "$cs" 2>/dev/null; }
# sched_entry <raw text from a string's start>: REPLY the line a scheduled prompt is kept as: =<body> for a short one,
# ~<its first 200 bytes> for a long one ("" for an empty one).
sched_entry() {
  skip_lead "$1"
  if short_body "$REPLY"; then REPLY="="; [ -n "$BODY" ] && REPLY="=$BODY"; [ "$REPLY" = "=" ] && REPLY=""
  else REPLY="~${REPLY:0:200}"; fi
}

case "$mode" in
  stop)
    after '"session_crons"[[:space:]]*:[[:space:]]*\[' "$input" || exit 0
    r="$REPLY"; buf=""; i=0
    while [ "$i" -lt 50 ] && after '"prompt"[[:space:]]*:[[:space:]]*"' "$r"; do
      r="$REPLY"; i=$((i + 1))
      sched_entry "$r"; [ -n "$REPLY" ] && buf="$buf$REPLY$nl"
    done
    if [ -n "$buf" ]; then ensure_cs && printf '%s' "$buf" > "$cs/$sid.sched"
    elif [ -s "$cs/$sid.sched" ]; then : > "$cs/$sid.sched"; fi
    exit 0 ;;
  outgoing)
    after '"tool_input"[[:space:]]*:[[:space:]]*\{' "$input" || exit 0
    ti="$REPLY"
    for key in prompt message; do
      after "\"$key\"[[:space:]]*:[[:space:]]*\"" "$ti" || continue
      v="$REPLY"
      if shaped "$v" && is_word "$W"; then
        echo "App Director: blocked: this $key is only the approval word \"$W\". An approval is the human's own message, so it can't be scheduled or sent; show the human the summary's lines and wait for their answer." >&2
        exit 2
      fi
      if [ "$key" = prompt ]; then
        sched_entry "$v"
        [ -n "$REPLY" ] && ensure_cs && printf '%s\n' "$REPLY" >> "$cs/$sid.sched"
      fi
    done
    exit 0 ;;
  prompt|dialog) ;;
  *) exit 0 ;;
esac

# The summaries: cur the counter (the newest id), mark this session's counter at the human's previous message.
cur=0; [ -f "$rs/counter" ] && read -r cur < "$rs/counter"
case "$cur" in ''|*[!0-9]*) cur=0 ;; esac
# mark0 the counter at the human's message before that one: a summary at or below it was passed over by two messages.
mark=0; mark0=0; [ -f "$cs/$sid.mark" ] && read -r mark mark0 < "$cs/$sid.mark"
case "$mark" in ''|*[!0-9]*) mark=0 ;; esac
case "$mark0" in ''|*[!0-9]*) mark0=0 ;; esac
[ "$cur" -lt "$mark" ] && cur="$mark"   # a counter read lower than the mark (another run mid-write): the mark never moves back
set_mark() { [ -d "$rs" ] || return 0; ensure_cs && printf '%s %s\n' "$cur" "$mark" > "$cs/$sid.mark"; }
pending=""
[ -s "$cs/$sid.pending" ] && while read -r n; do case "$n" in ''|*[!0-9]*) ;; *) pending="$pending $n" ;; esac; done < "$cs/$sid.pending"

# stamp_ok <id>: 0 when this session registered the summary, not a subagent; WHY says why not.
stamp_ok() {
  local line=""
  WHY=""
  [ -f "$cs/$1.stamp" ] && read -r line < "$cs/$1.stamp"
  case "$line" in
    "$sid") return 0 ;;
    "$sid agent") WHY="$1 was registered by a subagent, and a subagent never writes records: register the lines in this session and show them to the human" ;;
    "") WHY="$1 isn't a summary this session registered" ;;
    *) WHY="$1 was registered in another session, and an approval counts only in the session that registered its summary" ;;
  esac
  return 1
}
# states: STATES holds " S<n>=<state>" for each summary bash tools/records.sh status lists (none used up), and this
# session's list keeps only the registered and approved ones.
states() {
  local id h st r keep="" out
  STATES=" "
  out="$(bash tools/records.sh status 2>/dev/null)" || return 0   # couldn't run: the list stays as it was
  while read -r id h st r; do
    [ -n "$id" ] || continue
    STATES="$STATES$id=$st "
  done <<< "$out"
  for id in $pending; do
    case "$STATES" in *" S$id=registered "*|*" S$id=approved "*) keep="$keep$id$nl" ;; esac
  done
  [ -f "$cs/$sid.pending" ] && printf '%s' "$keep" > "$cs/$sid.pending"
}
state_of() { local s="${STATES#* $1=}"; [ "$s" != "$STATES" ] || { REPLY=""; return; }; REPLY="${s%% *}"; }
# open_ids: OPEN, this session's summaries with no approval file (registered and not approved), read without a process.
open_ids() {
  local n
  OPEN=""
  for n in $pending; do [ -f "$rs/S$n.approval" ] || OPEN="$OPEN $n"; done
}

approve() { # approve <id> <word> <by>: records it and tells the assistant
  local out
  out="$(bash tools/records.sh approve "$1" --hook --word "$2" --by "$3" 2>&1)"
  if [ $? -ne 0 ]; then
    REPLY="App Director: the human answered \"$2\" for summary $1, and it couldn't be recorded as an approval, so nothing of $1 may be written:$nl$out"
    return 1
  fi
  # Back on this session's list (a withdrawn one leaves it), so the human's next message withdraws it again.
  case " $pending " in *" ${1#S} "*) ;; *) printf '%s\n' "${1#S}" >> "$cs/$sid.pending"; pending="$pending ${1#S}" ;; esac
  REPLY="App Director: the human approved summary $1 (\"$2\"). Write exactly its lines, nothing more, and commit them in one change now; the commit message needs this line:$nl${out##*$nl}"
}
# human_message: a message from the human that approves nothing. The approvals of this session's summaries are withdrawn
# (one bash tools/records.sh withdraw, which says which it withdrew; those leave this session's list), a summary the
# human's two previous messages both passed over leaves the list too, and the assistant is told about each summary
# withdrawn or registered since the previous message. REPLY the text ("" when there is none). Starts no process while
# this session has nothing approved.
human_message() {
  local n ap="" new="" keep="" out w="" all id changed=0
  REPLY=""
  for n in $pending; do
    if [ -f "$rs/S$n.approval" ]; then ap="$ap S$n"; changed=1
    elif [ "$n" -le "$mark0" ]; then changed=1
    else keep="$keep$n$nl"; [ "$n" -gt "$mark" ] && new="$new S$n"; fi
  done
  if [ -n "$ap" ]; then
    out="$(bash tools/records.sh withdraw $ap 2>/dev/null)"
    case "$out" in *"withdrawn:"*) w="${out##*withdrawn:}" ;; esac
  fi
  [ "$changed" -eq 1 ] && printf '%s' "$keep" > "$cs/$sid.pending"
  all=""; for id in $w $new; do all="$all, $id"; done
  all="${all#, }"
  [ -n "$all" ] || return 0
  REPLY="App Director: summary $all was waiting for the human's approval, and this answer is not an approval of it (an approval is a message that is only an approval word, such as \"ok\", or the word and the id, \"ok $id\")."
  [ -n "$w" ] && REPLY="$REPLY Its approval is withdrawn."
  REPLY="$REPLY Nothing of it may be written. Read the human's message as a scope change and reassess (.app-director/rules.md › The human decides)."
}

if [ "$mode" = prompt ]; then
  after '"prompt"[[:space:]]*:[[:space:]]*"' "$input" || exit 0
  skip_lead "$REPLY"; r="$REPLY"
  case "${r:0:32}" in
    '<agent-message '*|'<cross-session-message '*|'<task-notification'*|'<side-sessions-event'*|'<ci-monitor-event'*) exit 0 ;;
  esac
  # A prompt this session scheduled: the same text (=, short) or the same first 200 bytes (~, long).
  if [ -s "$cs/$sid.sched" ]; then
    while IFS= read -r e; do
      case "$e" in
        "="?*) b="${e#=}"; case "$r" in "$b"*) [[ ${r:${#b}:256} =~ ^([[:space:]]|\\[nrt])*\" ]] && exit 0 ;; esac ;;
        "~"?*) b="${e#\~}"; case "$r" in "$b"*) exit 0 ;; esac ;;
      esac
    done < "$cs/$sid.sched"
  fi
  W=""; ID=""
  if short_body "$r"; then jdec "$BODY"; word_id "$REPLY"; fi
  open_ids
  # The word matters only with an id, or while a summary of this session is open that the human's previous message didn't
  # pass over already, or passed over alone (one registered after the message before it).
  need=0
  if [ -n "$W" ]; then
    if [ -n "$ID" ]; then need=1; else for n in $OPEN; do [ "$n" -gt "$mark0" ] && need=1; done; fi
  fi
  if [ "$need" -eq 1 ] && is_word "$W"; then
    word="$W"; id="$ID"
    if [ -z "$id" ]; then
      cand=""
      for n in $OPEN; do [ "$n" -gt "$mark" ] && cand="$cand $n"; done
      if [ -n "$cand" ]; then
        states
        for n in $cand; do state_of "S$n"; [ "$REPLY" = registered ] && stamp_ok "S$n" && id="S$n"; done
      fi
      if [ -z "$id" ]; then
        # No summary registered since the previous message: an ordinary message. The hint, too, when the previous message
        # alone passed over one of this session's summaries: the human asked about it and now writes the word.
        hint=0
        for n in $OPEN; do [ "$n" -gt "$mark0" ] && [ "$n" -le "$mark" ] && hint=1; done
        human_message
        [ -n "$REPLY" ] && printf '%s\n' "$REPLY"
        [ "$hint" -eq 1 ] && echo "App Director: the human's message is the approval word \"$word\", but no summary was registered in this session since their previous message, so nothing was approved and nothing may be written to the records. Show the waiting summary's lines again and ask the human to answer with the word and its id (\"$word S<n>\")."
        set_mark
        exit 0
      fi
    elif ! stamp_ok "$id"; then
      set_mark
      echo "App Director: the human answered \"$word $id\", and nothing was approved: $WHY. Nothing of $id may be written."
      exit 0
    fi
    approve "$id" "$word" prompt
    printf '%s\n' "$REPLY"
    set_mark
    exit 0
  fi
  human_message
  [ -n "$REPLY" ] && printf '%s\n' "$REPLY"
  set_mark
  exit 0
fi

# dialog: the answers of a question dialog in the main conversation.
re='"agent_id"[[:space:]]*:'
[[ $input =~ $re ]] && exit 0
src="$input"
after '"tool_response"[[:space:]]*:' "$input" && src="$REPLY"
after '"answers"[[:space:]]*:[[:space:]]*\{' "$src" || after '"answers"[[:space:]]*:[[:space:]]*\{' "$input" || exit 0
rest="$REPLY"
out=""; approved=0; human=0
pair_re='^[[:space:]]*,?[[:space:]]*"'
sep_re='^[[:space:]]*:[[:space:]]*"'
while [[ $rest =~ $pair_re ]]; do
  jbody "${rest:${#BASH_REMATCH[0]}}" || break
  q="$REPLY"; rest="$JREST"
  [[ $rest =~ $sep_re ]] || break
  jbody "${rest:${#BASH_REMATCH[0]}}" || break
  a="$REPLY"; rest="$JREST"
  # The summary ids the question names, as whole words; one of them, and a summary by that id, or none.
  jdec "$q"; qt="$REPLY"; ids=" "
  while [[ $qt =~ (^|[^A-Za-z0-9_])S([0-9]{1,9})([^A-Za-z0-9_]|$) ]]; do
    s="S$((10#${BASH_REMATCH[2]}))"
    case "$ids" in *" $s "*) ;; *) ids="$ids$s " ;; esac
    qt="${qt#*"${BASH_REMATCH[0]}"}"
  done
  set -- $ids
  id=""; [ "$#" -eq 1 ] && [ -f "$rs/$1.meta" ] && id="$1"
  skip_lead "$a"; a="$REPLY"
  case "$a" in
    '[User did not answer this question'*)
      [ -n "$id" ] && stamp_ok "$id" && out="${out}App Director: the human didn't answer the question about summary $id: that is no approval, whatever the tool result says, so nothing of $id may be written. The message they sent instead is read on its own.$nl"
      continue ;;
  esac
  if [ -n "$id" ] && shaped "$a\"" && { [ -z "$ID" ] || [ "$ID" = "$id" ]; } && is_word "$W"; then
    if stamp_ok "$id"; then
      approve "$id" "$W" dialog && approved=1
      out="$out$REPLY$nl"
      continue
    fi
    out="${out}App Director: the human chose \"$W\" for $id, and nothing was approved: $WHY.$nl"
  fi
  human=1
done
if [ "$approved" -eq 0 ] && [ "$human" -eq 1 ]; then
  human_message
  [ -n "$REPLY" ] && out="$out$REPLY$nl"
fi
[ "$approved" -eq 1 ] || [ "$human" -eq 1 ] && set_mark
[ -n "$out" ] || exit 0
printf '%s' "$out" >&2
exit 2
