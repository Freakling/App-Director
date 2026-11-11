#!/usr/bin/env bash
# App Director records gate · framework-owned: replaced on upgrade.
#
# The human decides what the records say (.app-director/rules.md › The human decides), and a commit holds the
# assistant to it: the assistant registers the exact lines a summary adds and removes, the human's approval is recorded
# against a hash of those lines, and the pre-commit hook refuses a commit whose protected record lines no approval covers.
#
#   bash tools/records.sh summary <file>     registers a summary and prints its id, its hash and its lines, to be shown to
#                                            the human word for word. Nothing is written until they approve it
#   bash tools/records.sh approve <id>       the human, in their own terminal: shows the summary and records the approval
#                                            word they type. Without a terminal it refuses (an assistant's shell has none)
#   bash tools/records.sh approve --staged   the human, in their own terminal, for an edit of their own: prints the
#                                            protected lines staged, registers them as a summary and asks for the word
#   bash tools/records.sh approve <id> --hook --word <word> --by <prompt|dialog>
#                                            records an approval an assistant adapter's own hook saw the human give, in a
#                                            prompt or a question dialog. The adapter must stop the assistant from running
#                                            this itself, and from writing under .app-director/state/records/
#   bash tools/records.sh withdraw           withdraws every approval no commit has used yet
#   bash tools/records.sh status             one line per summary not used up: <id> <hash> <state> <registered, epoch>,
#                                            the state registered, approved, withdrawn or invalid
#   bash tools/records.sh open <path>        exit 0 when an approved summary no commit has used has lines for <path>
#   bash tools/records.sh check [--staged|--worktree]
#                                            the gate: the protected changes no approval covers, in the index (the default)
#                                            or the working tree, against HEAD; exit 1 when there are any
#   bash tools/records.sh trailer            the Approved: line or lines the staged commit's message needs
#   bash tools/records.sh message <file>     the commit-msg hook: refuses a message that lacks one of them
#   bash tools/records.sh report [<since>]   the Approved: lines of the commits in <since>..HEAD (the last 20 by default),
#                                            and the proposed items
#
# A summary file: "## <path>" names a record file, "+ <line>" adds the rest of the line as it stands, "- <line>" removes
# it (the line must be in the file at HEAD); blank lines are ignored. The record files are [records] brief, decisions,
# stories and tasks in tools/check.cfg (product/brief.md, product/decisions.md, product/user-stories.md and TASKS.md by
# default), and tools/check.cfg itself. The settings are read from HEAD's tools/check.cfg, so an uncommitted edit of them
# changes nothing.
#
# Protected, each line needing an approval with that line and sign: every added or removed line of the brief and the
# decisions; a story row whose Confirmed cell isn't unconfirmed, and a changed Last validated value; in the tasks file,
# every line but Note: lines of an item added or moved on from proposed, unless it is proposed or a bug [records] bugs
# frees (cited by default: its Brief: names a heading of the brief outside Open Questions, or its Stories: a confirmed
# story; all; none), a changed Done when, Repro or Question, an item moved back to proposed, and an item removed that
# isn't done; every line of the [records] and [approval] sections of tools/check.cfg. In the brief and the stories a line
# is placed by the path of headings above it: a line whose text stays but whose path changed is a move (removed and
# added). A plain rename (one heading changed, same place and level, nothing else in the headings changed) moves
# nothing; any other change to the headings lists every line it re-homes. Status changes, sizes, other fields, Note: and PRs: lines, the Next IDs line, a moved item and an unconfirmed
# story are free. An item heading is a heading of any level whose text starts with T, B or R and digits, followed by
# anything but a letter or a digit; it reads ID · title · status · size · owner (a bug adds · severity), or in the older
# form ID · title · size · status, and one that reads neither way has no status and counts as not proposed. An item runs
# to the next item heading or heading of level 1 or 2. A heading is # to ###### after up to three spaces, or a setext
# heading. During a merge the index is judged against HEAD, and a change is free only as often as another parent
# brought it: the same change (file, sign and text; a removed item by its ID) is in that parent against each of its
# merge bases with HEAD. With no common ancestor, or when the other commit is an ancestor of HEAD, nothing is free.
# An approval binds a line's file and text, not its place in the file.
#
# An approval covers a commit while its summary's stored text still has the approved hash (of the text, the id and the
# registration time), the approval is no older than the summary, it isn't withdrawn, and it isn't used: no commit
# reachable from HEAD names its hash in an Approved: line (Approved: <id> <date> "<word>" <hash>, which the commit-msg hook
# asks for), and its lines aren't already committed (every + line in its file at HEAD, every - line gone). Approvals apply
# whole: the largest first, each that has all its lines in the commit's change takes them, one summary line per line of
# the commit; any other covers nothing in this commit.
# State: .app-director/state/records/.
# Limits: the gate judges commits made with git commit. Commands that commit without the pre-commit hook (git cherry-pick,
# git revert, git rebase, git am), a commit made with --no-verify and a prototype checkout aren't judged, nor is a merge
# git merge or git pull completes by itself (no pre-commit hook runs; whatever -X theirs or a merge=union attribute chose
# passes). A merge trusts the commits it brings: lines in a commit made without the hooks (a stash, for one) pass when it
# is merged. It is a safety
# net, not a lock: the state lives in the working copy, so an approval forged on purpose from the same account can't be
# ruled out.
# Exit codes: 0 = passes or done · 1 = refused (the reason is printed) · 3 = couldn't run

set -u
orig_pwd="$PWD"
case "$0" in */*) cd "${0%/*}/.." || exit 3 ;; *) cd .. || exit 3 ;; esac

state=".app-director/state/records"
nl='
'
tab='	'
cr="$(printf '\r')"
tmp=""

say() { printf 'records: %s\n' "$*"; }
refuse() { printf 'records: %s\n' "$*"; exit 1; }
usage() { sed -n '/^#   bash tools\/records.sh summary/,/^#$/p' "$0"; exit 3; }

# The repository: gitdir, and has_head (0 when there is no commit yet). One git call.
repo_out="$(git rev-parse --git-dir --verify -q HEAD 2>/dev/null)"
gitdir="${repo_out%%"$nl"*}"
[ -n "$gitdir" ] || { echo "records: not a git repository" >&2; exit 3; }
has_head=0; [ "$gitdir" != "$repo_out" ] && has_head=1

# The other parents of the commit being made: mheads, the MERGE_HEAD commits, space-separated. Read by bash, no process.
mheads=""
if [ -f "$gitdir/MERGE_HEAD" ]; then
  while IFS= read -r _m || [ -n "$_m" ]; do
    _m="${_m%"$cr"}"
    [ -n "$_m" ] && mheads="$mheads $_m"
  done < "$gitdir/MERGE_HEAD"
fi

tmp_init() {
  [ -n "$tmp" ] && return 0
  mkdir -p "$state" || exit 3
  tmp="$state/.tmp-$$"
  trap 'rm -f "$tmp".*' EXIT
}

abs_path() { # a path given on the command line, from the folder it was given in
  case "$1" in /*|[A-Za-z]:*) printf '%s' "$1" ;; *) printf '%s' "$orig_pwd/$1" ;; esac
}

norm_path() { # a record path as git prints it: no leading ./, forward slashes, no trailing slash
  local v="$1"
  v="${v//\\//}"
  while :; do case "$v" in ./*) v="${v#./}" ;; *) break ;; esac; done
  while :; do case "$v" in */) v="${v%/}" ;; *) break ;; esac; done
  printf '%s' "$v"
}

# The settings, with their defaults: [records] in HEAD's tools/check.cfg (the working copy's while there is no commit).
# Read like tools/check.sh reads it: comments and carriage returns cut in bash, no process per line. The awk judge reads
# the sections by the same rule (cfgsec): a line is cut at its first ;, then trimmed.
read_settings() {
  bugs=cited; p_brief=product/brief.md; p_decisions=product/decisions.md; p_stories=product/user-stories.md; p_tasks=TASKS.md
  words="godkänt, godkänd, approve, approved, ok, ja, yes, kör"
  local text="" line section="" k v
  if [ "$has_head" -eq 1 ]; then
    text="$(git show HEAD:tools/check.cfg 2>/dev/null)"
  elif [ -f tools/check.cfg ]; then
    text="$(cat tools/check.cfg)"
  fi
  [ -n "$text" ] || return 0
  while IFS= read -r line; do
    line="${line%"$cr"}"
    line="${line%%;*}"
    line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
    case "$line" in
      "") continue ;;
      "["*"]") section="${line#[}"; section="${section%]}"; continue ;;
    esac
    case "$section" in records|approval) ;; *) continue ;; esac
    case "$line" in *=*) ;; *) continue ;; esac
    k="${line%%=*}"; v="${line#*=}"
    k="${k%"${k##*[![:space:]]}"}"; v="${v#"${v%%[![:space:]]*}"}"
    [ -n "$v" ] || continue
    case "$section.$k" in
      records.bugs) bugs="$v" ;;
      records.brief) p_brief="$(norm_path "$v")" ;;
      records.decisions) p_decisions="$(norm_path "$v")" ;;
      records.stories) p_stories="$(norm_path "$v")" ;;
      records.tasks) p_tasks="$(norm_path "$v")" ;;
      approval.words) words="$v" ;;
    esac
  done <<< "$text"
}

# A checkout `bash tools/prototype.sh here` calls a prototype. Asked only on a proto/ branch with PROTOTYPE.md, so an
# ordinary commit starts no process for it.
in_prototype() {
  local head=""
  [ -f PROTOTYPE.md ] && [ -f tools/prototype.sh ] || return 1
  read -r head 2>/dev/null < "$gitdir/HEAD"
  case "$head" in "ref: refs/heads/proto/"*) ;; *) return 1 ;; esac
  bash tools/prototype.sh here >/dev/null 2>&1
}

# --- awk -------------------------------------------------------------------------------------------
# Shared functions. loadblobs reads `git cat-file --batch` output (blobf) for the names in reqf, in order, into
# L[name, i] and N[name]. Run in the C locale, so a length is in bytes, as the batch's sizes are, and the separators
# " · " and "›" are split on as literal strings (lsplit), never as a regular expression.
awk_lib='
function rs(s) { sub(/[ \t\r]+$/, "", s); return s }
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
function loadblobs(   r, hdr, f, size, got, line, n) {
  if (reqf == "" || blobf == "") return
  split("", f)
  while ((getline r < reqf) > 0) {
    if ((getline hdr < blobf) <= 0) break
    if (hdr !~ /^[0-9a-f]+ blob [0-9]+$/) { N[r] = 0; continue }
    split(hdr, f, " "); size = f[3] + 0; got = 0; n = 0
    while (got < size && (getline line < blobf) > 0) { got += length(line) + 1; L[r, ++n] = line }
    N[r] = n; HAS[r] = 1
    if (got == size) getline line < blobf
  }
}
function loadfile(k, path,   line, n) {
  n = 0
  while ((getline line < path) > 0) L[k, ++n] = line
  close(path); N[k] = n; if (n > 0) HAS[k] = 1
}
function copy(k, A,   i, n) { split("", A); n = (k in N) ? N[k] + 0 : 0; for (i = 1; i <= n; i++) A[i] = L[k, i]; return n }
function lsplit(s, A, sep,   n, i) {
  split("", A); n = 0
  while ((i = index(s, sep)) > 0) { A[++n] = substr(s, 1, i - 1); s = substr(s, i + length(sep)) }
  A[++n] = s
  return n
}
# bulletish: the first line of a list item (-, *, + or a number and a dot, after optional spaces).
function bulletish(t) { return (t ~ /^[ \t]*([-*+]|[0-9]+\.)([ \t]|$)/) }
# hlevels: every heading test goes through here. LV[i] is the level of line i when it is a heading: # to ###### after
# up to three spaces, or a setext heading (a text line that is not a bullet, a table row or a heading, with a line of
# only = (level 1) or only - (level 2) under it, after up to three spaces); -1 for that underline; 0 otherwise.
function atx(t,   u) {
  match(t, /^ */); if (RLENGTH > 3) return 0
  u = substr(t, RLENGTH + 1)
  if (u !~ /^#+([ \t]|$)/) return 0
  match(u, /^#+/); return RLENGTH
}
function underline(t,   u) {
  match(t, /^ */); if (RLENGTH > 3) return 0
  u = substr(t, RLENGTH + 1); sub(/[ \t\r]+$/, "", u)
  if (u ~ /^=+$/) return 1
  if (u ~ /^-+$/) return 2
  return 0
}
function hlevels(A, n, LV,   i, t, u) {
  split("", LV)
  for (i = 1; i <= n; i++) {
    t = rs(A[i]); LV[i] = atx(t)
    if (LV[i] > 0 || i == n || trim(t) == "" || bulletish(t) || t ~ /^[ \t]*\|/) continue
    u = underline(A[i + 1])
    if (u > 0) { LV[i] = u; LV[i + 1] = -1; i++ }
  }
}
# itemid: the ID of an item heading (any level; text starting T, B or R and digits, then anything but a letter or a
# digit, or nothing), else "".
function itemid(t,   s) {
  s = trim(t); sub(/^#+[ \t]+/, "", s)
  if (!match(s, /^[TBR][0-9]+/)) return ""
  if (substr(s, RLENGTH + 1, 1) ~ /[A-Za-z0-9]/) return ""
  return substr(s, 1, RLENGTH)
}
function stword(v) {
  if (v == "proposed" || v == "todo" || v == "done") return v
  if (v ~ /^done [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) return "done"
  if (v ~ /^in-progress [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) return "in-progress"
  return ""
}
function sizeword(v) { return (v == "-" || v ~ /^(XS|S|M|L|XL)( \(escalated from (XS|S|M|L|XL)\))?$/) }
# status_of: ID · title · status · size · owner [· severity], or the older ID · title · size · status; "none" otherwise.
function status_of(h,   F, n, i, v, s) {
  split("", F)
  h = trim(h); sub(/^#+[ \t]+/, "", h); n = lsplit(h, F, " · ")
  if (n < 4 || trim(F[1]) != itemid(h)) return "none"
  i = n; v = trim(F[i])
  if (v == "high" || v == "med" || v == "low") { i--; v = trim(F[i]) }
  if ((v == "agent" || v == "human") && i >= 5 && sizeword(trim(F[i - 1]))) { s = stword(trim(F[i - 2])); if (s != "") return s }
  if (sizeword(trim(F[n - 1]))) { s = stword(trim(F[n])); if (s != "") return s }
  return "none"
}
'

# The approvals: one line per registered summary, in id order, tab-separated: id, state (approved, registered,
# withdrawn, invalid or used), why it covers nothing, approval date, word, the 12-character hash, registration epoch; an
# empty value is "-", since read joins the tabs around an empty field. A summary's .txt starts with "# <id> registered
# <epoch>", so the hash covers the id and the time with the text.
appr_prog='
function z(s) { return s == "" ? "-" : s }
BEGIN {
  FS = "\t"; cur = ""
  loadblobs()
  for (r in N) if (substr(r, 1, 5) == "HEAD:") { hp = substr(r, 6); HB[hp] = 1; for (i = 1; i <= N[r]; i++) HH[hp, rs(L[r, i])] = 1 }
  while ((getline line < usedf) > 0) {
    if (substr(line, 1, 1) == "\001") { cur = substr(line, 2); continue }
    if (line ~ /^Approved: /) {
      line = rs(line); n = split(line, w, " "); h = w[n]
      if (length(h) == 12 && h !~ /[^0-9a-f]/ && !(h in usedby)) usedby[h] = cur
    }
  }
  n = 0
  while ((getline line < idsf) > 0) {
    split(line, f, "\t"); n++; id[n] = f[1]; num[n] = substr(f[1], 2) + 0
    if (f[2] == 1) { if ((getline hh < hashf) > 0) cur_hash[f[1]] = hh }
  }
  for (i = 2; i <= n; i++) { t = id[i]; tn = num[i]; for (j = i - 1; j >= 1 && num[j] > tn; j--) { id[j + 1] = id[j]; num[j + 1] = num[j] }; id[j + 1] = t; num[j + 1] = tn }
  for (i = 1; i <= n; i++) {
    s = id[i]; reg = ""; mhash = ""; ahash = ""; atime = ""; adate = ""; aword = ""; wd = 0; eff = 1
    file = dir "/" s ".meta"
    while ((getline line < file) > 0) {
      line = rs(line)
      if (line ~ /^registered=/) reg = substr(line, 12); else if (line ~ /^hash=/) mhash = substr(line, 6); else if (line == "effect=0") eff = 0
    }
    close(file)
    file = dir "/" s ".approval"
    while ((getline line < file) > 0) {
      line = rs(line)
      if (line ~ /^hash=/) ahash = substr(line, 6)
      else if (line ~ /^time=/) atime = substr(line, 6)
      else if (line ~ /^date=/) adate = substr(line, 6)
      else if (line ~ /^word=/) aword = substr(line, 6)
      else if (line ~ /^withdrawn=/) wd = 1
    }
    close(file)
    h = (ahash != "") ? ahash : mhash; h12 = substr(h, 1, 12)
    # The registration time is the one in the text (the hash covers it); the effect test: every + line in its file at
    # HEAD and every - line gone.
    done_ = 0
    if (!(h12 != "" && (h12 in usedby))) {
      file = dir "/" s ".txt"; cp = ""; nl_ = 0; done_ = (eff && has_head)
      while ((getline line < file) > 0) {
        line = rs(line)
        if (line ~ /^# S[0-9]+ registered [0-9]+$/) { split(line, w, " "); reg = w[4]; continue }
        if (line ~ /^## /) { cp = substr(line, 4); continue }
        if (line !~ /^[+-] /) continue
        nl_++; tx = substr(line, 3)
        if (substr(line, 1, 1) == "+") { if (!((cp, tx) in HH)) done_ = 0 } else if ((cp, tx) in HH) done_ = 0
      }
      close(file)
      if (nl_ == 0) done_ = 0
    }
    if (h12 != "" && (h12 in usedby)) { st = "used"; why = s " is already used in commit " usedby[h12] }
    else if (done_) { st = "used"; why = s " is already used: its lines are already committed" }
    else if (ahash == "") { st = "registered"; why = s " is registered but not approved yet" }
    else if (wd) { st = "withdrawn"; why = s " was approved, then withdrawn" }
    else if (cur_hash[s] != ahash) { st = "invalid"; why = "the text of " s " differs from the summary the human approved" }
    else if (atime + 0 < reg + 0) { st = "invalid"; why = "the approval of " s " is older than its summary" }
    else { st = "approved"; why = "" }
    print s "\t" st "\t" z(why) "\t" z(adate) "\t" z(aword) "\t" z(h12) "\t" z(reg)
  }
}
'

# The judgement of the record changes. The index (or the working tree) is judged against HEAD. During a merge, each
# MERGE_HEAD commit P is also judged against its merge base with HEAD (the pairs in revf), and a change against HEAD is
# free when the same change is in one of those, as often as it is there. mode: check, trailer, message or collect (the
# uncovered lines as a summary). scope: staged or worktree.
judge_prog='
function newk(p) { return (scope == "staged" ? ":" : "WT:") p }
function ctxof(k) { return substr(k, 1, index(k, "\034") - 1) }
function textof(k) { return substr(k, index(k, "\034") + 1) }
# keyed: the lines of A as keys "\034<text>", blank lines left out.
function keyed(A, n, K,   i, t, m) {
  split("", K); m = 0
  for (i = 1; i <= n; i++) { t = rs(A[i]); if (t != "") K[++m] = "\034" t }
  return m
}
function mdiff(KO, ko, KN, kn,   C, i, s) {
  split("", C); split("", ADD); split("", REM); na = 0; nr = 0
  for (i = 1; i <= ko; i++) C[KO[i]]++
  for (i = 1; i <= kn; i++) { s = KN[i]; if ((s in C) && C[s] > 0) C[s]--; else ADD[++na] = s }
  for (i = 1; i <= ko; i++) { s = KO[i]; if ((s in C) && C[s] > 0) { C[s]--; REM[++nr] = s } }
}
# lines: the lines of A (story rows only when rowsonly), each with the path of headings above it, into T[i] and H[i].
# A heading is a line of the brief, not of the stories. In the paths, heading number RI reads RNAME (a plain rename).
# (Not RT: gawk keeps that name for itself.)
function lines(A, n, T, H, rowsonly, RI, RNAME,   i, t, lvl, j, m, S, top, path, LV, h) {
  split("", T); split("", H); split("", S); split("", LV); m = 0; top = 0; h = 0
  hlevels(A, n, LV)
  for (i = 1; i <= n; i++) {
    t = rs(A[i])
    if (t == "") continue
    lvl = LV[i]
    if (lvl > 0) {
      h++
      path = ""; for (j = 1; j < lvl && j <= top; j++) if (S[j] != "") path = path (path == "" ? "" : " › ") S[j]
      if (!rowsonly) { T[++m] = t; H[m] = path }
      for (j = lvl; j <= top; j++) S[j] = ""
      S[lvl] = (h == RI) ? RNAME : t; top = lvl
      continue
    }
    if (rowsonly && t !~ /^[ \t]*\|[ \t]*US-/) continue
    path = ""; for (j = 1; j <= top; j++) if (S[j] != "") path = path (path == "" ? "" : " › ") S[j]
    T[++m] = t; H[m] = path
  }
  return m
}
function hseq(A, n, HX, HV,   LV, i, c) {
  split("", LV); hlevels(A, n, LV); c = 0
  for (i = 1; i <= n; i++) if (LV[i] > 0) { c++; HX[c] = rs(A[i]); HV[c] = LV[i] }
  return c
}
# placed: ADD and REM ("<path>\034<text>") for a file whose lines are placed by their headings. First by text: a text
# that is in one version more often than in the other is added or removed. Then, among the lines whose text is in
# both, a line whose heading path changed is a move (removed and added). The one exception is a plain rename: the same
# number of headings, exactly one of them different, at the same place and level; the old paths are read through it.
function placed(rowsonly,   OT, OH, NT, NH, on_, nn_, i, j, t, CNT, OL, NLs, ON, NN, TL, nt_, q, Ad, Rm, a_, r_, pr, OX, OV, NX, NV, oc, ncc, d, di, RI, RNAME) {
  split("", ADD); split("", REM); na = 0; nr = 0
  split("", OT); split("", OH); split("", NT); split("", NH); split("", OX); split("", OV); split("", NX); split("", NV)
  oc = hseq(OA, on, OX, OV); ncc = hseq(NA, nn, NX, NV); RI = 0; RNAME = ""
  if (oc == ncc) {
    d = 0; for (i = 1; i <= oc; i++) if (OX[i] != NX[i]) { d++; di = i }
    if (d == 1 && OV[di] == NV[di]) { RI = di; RNAME = NX[di] }
  }
  on_ = lines(OA, on, OT, OH, rowsonly, RI, RNAME); nn_ = lines(NA, nn, NT, NH, rowsonly, 0, "")
  split("", ON); split("", NN); split("", OL); split("", NLs); split("", TL); nt_ = 0
  for (i = 1; i <= nn_; i++) { t = NT[i]; if (!(t in NN) && !(t in ON)) TL[++nt_] = t; NLs[t, ++NN[t]] = NH[i] }
  for (i = 1; i <= on_; i++) { t = OT[i]; if (!(t in NN) && !(t in ON)) TL[++nt_] = t; OL[t, ++ON[t]] = OH[i] }
  for (q = 1; q <= nt_; q++) {
    t = TL[q]; split("", CNT); split("", Ad); split("", Rm); a_ = 0; r_ = 0
    for (j = 1; j <= ON[t]; j++) CNT[OL[t, j]]++
    for (j = 1; j <= NN[t]; j++) { if (CNT[NLs[t, j]] > 0) CNT[NLs[t, j]]--; else Ad[++a_] = NLs[t, j] }
    for (j = 1; j <= ON[t]; j++) if (CNT[OL[t, j]] > 0) { CNT[OL[t, j]]--; Rm[++r_] = OL[t, j] }
    pr = (a_ < r_) ? a_ : r_
    for (j = 1; j <= pr; j++) { REM[++nr] = Rm[j] "\034" t; ADD[++na] = Ad[j] "\034" t }
    for (j = pr + 1; j <= a_; j++) ADD[++na] = Ad[j] "\034" t
    for (j = pr + 1; j <= r_; j++) REM[++nr] = Rm[j] "\034" t
  }
}
# pc: one protected change of run R (1: the index against HEAD; 2 and on: a merge parent against one of its bases).
# The runs are compared by ck: file, sign and text (with the section in tools/check.cfg), and for a removed item its
# ID (CMPOVR), so a heading path or a status the other side changed does not make it another change.
function pc(p, sign, text, ctx, why,   k, ck) {
  k = p SUBSEP sign SUBSEP text SUBSEP ctx
  if (CMPOVR != "") ck = p SUBSEP sign SUBSEP CMPOVR
  else if (p == p_brief || p == p_stories) ck = p SUBSEP sign SUBSEP text
  else ck = k
  if (R == 1) { if (!((1, k) in PC)) { PK[1, ++PN[1]] = k; WHY[k] = why; CK[k] = ck }; PC[1, k]++ }
  else PCF[R, ck]++
}
function emit(p, why,   i) {
  for (i = 1; i <= na; i++) pc(p, "+", textof(ADD[i]), ctxof(ADD[i]), why)
  for (i = 1; i <= nr; i++) pc(p, "-", textof(REM[i]), ctxof(REM[i]), why)
}
# rawc: every changed line of the file against HEAD, by text: the change an approval must find all its lines in.
function rawc(p, isplaced,   KO, KN, ko, kn, i) {
  if (isplaced) placed(0)
  else { split("", KO); split("", KN); ko = keyed(OA, on, KO); kn = keyed(NA, nn, KN); mdiff(KO, ko, KN, kn) }
  for (i = 1; i <= na; i++) RAW[p SUBSEP "+" SUBSEP textof(ADD[i])]++
  for (i = 1; i <= nr; i++) RAW[p SUBSEP "-" SUBSEP textof(REM[i])]++
}
function textfile(p, isplaced, why,   KO, KN, ko, kn) {
  if (isplaced) placed(0)
  else { split("", KO); split("", KN); ko = keyed(OA, on, KO); kn = keyed(NA, nn, KN); mdiff(KO, ko, KN, kn) }
  emit(p, why)
}
function cells(s, C,   n) { s = rs(s); sub(/^[ \t]*\|/, "", s); sub(/\|$/, "", s); return split(s, C, "|") }
function lastcell(s,   C, n) { split("", C); n = cells(s, C); return trim(C[n]) }
function firstcell(s,   C) { split("", C); cells(s, C); return trim(C[1]) }
function lv(A, n,   i) { for (i = 1; i <= n; i++) if (index(A[i], "**Last validated:**")) return rs(A[i]); return "" }
function lvval(s) { return trim(substr(s, index(s, "**Last validated:**") + 19)) }
function stories(p,   i, ol, nw) {
  placed(1)
  for (i = 1; i <= na; i++) if (lastcell(textof(ADD[i])) != "unconfirmed") pc(p, "+", textof(ADD[i]), ctxof(ADD[i]), "a confirmed story")
  for (i = 1; i <= nr; i++) if (lastcell(textof(REM[i])) != "unconfirmed") pc(p, "-", textof(REM[i]), ctxof(REM[i]), "a confirmed story")
  ol = lv(OA, on); nw = lv(NA, nn)
  if (nw != "" && (ol == "" || lvval(ol) != lvval(nw))) pc(p, "+", nw, "", "the Last validated line")
  if (ol != "" && (nw == "" || lvval(ol) != lvval(nw))) pc(p, "-", ol, "", "the Last validated line")
}
# cfgsec: the lines of [records] and [approval], keyed by their section. A line is cut at its first ; and trimmed to
# find a section header, as read_settings does.
function cfgsec(A, n, B,   i, t, sec, m) {
  sec = ""; m = 0
  for (i = 1; i <= n; i++) {
    t = A[i]; sub(/;.*$/, "", t); t = trim(t)
    if (t ~ /^\[.*\]$/) { sec = substr(t, 2, length(t) - 2); continue }
    if ((sec == "records" || sec == "approval") && trim(A[i]) != "") B[++m] = "[" sec "]\034" rs(A[i])
  }
  return m
}
function cfg(p,   RO, RN, ro, rn, i) {
  split("", RO); split("", RN)
  ro = cfgsec(OA, on, RO); rn = cfgsec(NA, nn, RN)
  mdiff(RO, ro, RN, rn)
  for (i = 1; i <= na; i++) pc(p, "+", textof(ADD[i]), ctxof(ADD[i]), "a " ctxof(ADD[i]) " setting")
  for (i = 1; i <= nr; i++) pc(p, "-", textof(REM[i]), ctxof(REM[i]), "a " ctxof(REM[i]) " setting")
}
# fname: the field a line starts, lowered ("done when"), found loosely: leading spaces, "-" or "*", optional bold.
function fname(t,   s, c) {
  s = t; sub(/^[ \t]+/, "", s)
  if (s ~ /^[-*+][ \t]/) { s = substr(s, 2); sub(/^[ \t]+/, "", s) }
  if (substr(s, 1, 2) == "**") s = substr(s, 3)
  if (!match(s, /^[A-Za-z][A-Za-z ]*(:|\*\*:)/)) return ""
  s = substr(s, 1, RLENGTH); sub(/(\*\*)?:$/, "", s); s = trim(s)
  return tolower(s)
}
function fval(t,   s) { s = substr(t, index(t, ":") + 1); sub(/^\*\*/, "", s); return trim(s) }
# parse: the items of A under label P. An item runs from its heading to the next item heading or heading of level 1
# or 2; a deeper heading inside it is one of its lines. A list item starts a field (or none, when it names no field), a
# line with no indent that names a field starts it, and any other line continues the field above it, colon or not.
function parse(A, n, P,   i, t, id, cur, fl, cont, j, LV, lvl) {
  split("", LV); hlevels(A, n, LV)
  cur = ""; cont = ""
  for (i = 1; i <= n; i++) {
    t = rs(A[i]); lvl = LV[i]
    if (lvl > 0) {
      id = itemid(t)
      if (id != "") { OCC[P, id]++; cur = id "#" OCC[P, id]; IT[P, ++IN[P]] = cur; HD[P, cur] = t; ST[P, cur] = status_of(t); LNN[P, cur] = 0; cont = ""; continue }
      if (lvl <= 2) { cur = ""; cont = ""; continue }
      if (cur == "") continue
      cont = ""; j = ++LNN[P, cur]; LN[P, cur, j] = t; LK[P, cur, j] = ""
      continue
    }
    if (cur == "" || trim(t) == "") continue
    if (lvl < 0) { j = ++LNN[P, cur]; LN[P, cur, j] = t; LK[P, cur, j] = ""; continue }
    fl = ""
    if (bulletish(t)) { fl = fname(t); cont = fl }
    else if (t !~ /^[ \t]/ && (fl = fname(t)) != "") cont = fl
    j = ++LNN[P, cur]; LN[P, cur, j] = t; LK[P, cur, j] = cont
    if (fl == "brief") BRV[P, cur] = fval(t)
    if (fl == "stories") STV[P, cur] = fval(t)
  }
}
# citations: the headings of the brief (HT text, HLV level, HP parent, HOK citable: not the title, not Open Questions or
# under it) and the story rows (SC: ID to Confirmed cell), from the version being committed.
function citations(   k, i, h, t, lvl, j, s, BA, bn, LV) {
  if (cited_loaded) return
  cited_loaded = 1; nh = 0
  k = newk(p_brief); split("", BA); split("", LV)
  bn = copy(k, BA); hlevels(BA, bn, LV)
  for (i = 1; i <= bn; i++) {
    lvl = LV[i]
    if (lvl <= 0) continue
    h = rs(BA[i])
    t = trim(h); sub(/^#+[ \t]*/, "", t); sub(/[ \t]+#+$/, "", t); t = trim(t)
    nh++; HT[nh] = t; HLV[nh] = lvl
    j = nh - 1; while (j > 0 && HLV[j] >= lvl) j = HP[j]
    HP[nh] = j
    UOQ[nh] = (tolower(t) == "open questions") || (j > 0 && UOQ[j])
    HOK[nh] = (lvl > 1 && !UOQ[nh])
  }
  k = newk(p_stories)
  for (i = 1; i <= N[k]; i++) {
    s = L[k, i]
    if (s ~ /^[ \t]*\|[ \t]*US-[0-9]+[ \t]*\|/) SC[firstcell(s)] = lastcell(s)
  }
}
# cites: whether a Brief: value (one heading, or a path A › B) names citable headings, each under the one before it.
function cites(v,   P, m, q, j, x, ok) {
  split("", P)
  m = lsplit(v, P, "›")
  for (q = 1; q <= m; q++) { P[q] = trim(P[q]); if (P[q] == "") return 0 }
  for (j = 1; j <= nh; j++) {
    if (HT[j] != P[m] || !HOK[j]) continue
    x = j; ok = 1
    for (q = m - 1; q >= 1; q--) {
      x = HP[x]; while (x > 0 && HT[x] != P[q]) x = HP[x]
      if (x == 0 || !HOK[x]) { ok = 0; break }
    }
    if (ok) return 1
  }
  return 0
}
function bugfree(k,   id, v, parts, n, i, T) {
  id = k; sub(/#[0-9]+$/, "", id)
  if (id !~ /^B/) return 0
  if (bugs == "all") return 1
  if (bugs == "none") return 0
  citations()
  v = BRV[NL, k]; gsub(/`/, "", v)
  if (v != "" && v != "-" && v != "none") {
    split("", parts); n = split(v, parts, ",")
    for (i = 1; i <= n; i++) if (cites(parts[i])) return 1
  }
  v = STV[NL, k]; gsub(/[`,;]/, " ", v)
  split("", T); n = split(v, T, " ")
  for (i = 1; i <= n; i++) if (T[i] ~ /^US-[0-9]+$/ && (T[i] in SC) && SC[T[i]] != "unconfirmed" && SC[T[i]] != "") return 1
  return 0
}
function whole(p, k, why,   j) {
  pc(p, "+", HD[NL, k], "", why)
  for (j = 1; j <= LNN[NL, k]; j++) if (LK[NL, k, j] != "note") pc(p, "+", LN[NL, k, j], "", why)
}
function dqlines(P, k, D,   j, m, c) {
  split("", D); m = 0
  for (j = 1; j <= LNN[P, k]; j++) { c = LK[P, k, j]; if (c == "done when" || c == "repro" || c == "question") D[++m] = "\034" LN[P, k, j] }
  return m
}
function dq(p, k, P,   DO, DN, o, m) {
  split("", DO); split("", DN)
  o = dqlines(P, k, DO); m = dqlines(NL, k, DN)
  mdiff(DO, o, DN, m); emit(p, "a changed `Done when`, `Repro` or `Question`")
}
function items(p,   i, k, os, ns, P) {
  P = "o" R; NL = "n" R
  parse(NA, nn, NL); parse(OA, on, P)
  for (i = 1; i <= IN[NL]; i++) {
    k = IT[NL, i]; ns = ST[NL, k]
    if (!((P, k) in ST)) {
      if (ns != "proposed" && !bugfree(k)) whole(p, k, "a new item that isn\047t `proposed`")
      continue
    }
    os = ST[P, k]
    if (os == "proposed") {
      if (ns != "proposed" && !bugfree(k)) whole(p, k, "a `proposed` item moved on")
      continue
    }
    dq(p, k, P)
    if (ns == "proposed") pc(p, "+", HD[NL, k], "", "an item moved back to `proposed`")
  }
  for (i = 1; i <= IN[P]; i++) {
    k = IT[P, i]
    if (!((NL, k) in ST)) { os = ST[P, k]; if (os != "done" && os != "proposed") { CMPOVR = "item " k; pc(p, "-", HD[P, k], "", "an item removed that isn\047t `done`"); CMPOVR = "" } }
  }
}
BEGIN {
  FS = "\t"; split("", OA); split("", NA); split("", f)
  loadblobs()
  # The runs: 1 is the index (or working tree) against HEAD; each merge pair "P<tab>B<tab>G" adds one, P against B,
  # where G numbers the MERGE_HEAD commit P (one run per merge base).
  np = 1; ROLD[1] = "HEAD:"; RNEW[1] = ""; ng = 0
  while ((getline line < revf) > 0) if (line != "") { split(line, f, "\t"); np++; RNEW[np] = f[1] ":"; ROLD[np] = f[2] ":"; GR[np] = f[3] + 0; if (GR[np] > ng) ng = GR[np] }
  nc = 0
  while ((getline line < chf) > 0) { split(line, f, "\t"); nc++; CS[nc] = f[1]; CP[nc] = f[2] }
  if (scope == "worktree") {
    for (i = 1; i <= nc; i++) loadfile("WT:" CP[i], CP[i])
    loadfile("WT:" p_brief, p_brief); loadfile("WT:" p_stories, p_stories)
  }
  # The approvals: an approved one gives its lines (LEFT[a, k] counts, ALK[a, j] the distinct ones in order); any other
  # gives the reason it covers nothing (NOTE, the latest summary with the line).
  nA = 0
  while ((getline line < apprf) > 0) {
    split(line, f, "\t"); a = f[1]; ast = f[2]
    AID[++nA] = a; AST[a] = ast; ADATE[a] = f[4]; AWORD[a] = f[5]; AH[a] = f[6]; ALN[a] = 0
    file = dir "/" a ".txt"; cp = ""
    while ((getline t < file) > 0) {
      t = rs(t)
      if (t ~ /^## /) { cp = substr(t, 4); continue }
      if (t !~ /^[+-] /) continue
      k = cp SUBSEP substr(t, 1, 1) SUBSEP substr(t, 3)
      if (ast == "approved") {
        if (!((a, k) in AC)) { ALK[a, ++ALN[a]] = k; AC[a, k] = 0 }
        AC[a, k]++; ALT[a]++; HASL[k] = a
        if (!(cp in APATH)) APATH[cp] = a
      } else NOTE[k] = f[3]
    }
    close(file)
  }
  for (c = 1; c <= nc; c++) {
    p = CP[c]
    for (R = 1; R <= np; R++) {
      if (R == 1) { if (CS[c] == "D" && scope == "staged") { split("", NA); nn = 0 } else nn = copy(newk(p), NA) }
      else nn = copy(RNEW[R] p, NA)
      on = copy(ROLD[R] p, OA)
      if (R == 1) rawc(p, (p == p_brief || p == p_stories))
      if (p == p_tasks) items(p)
      else if (p == p_stories) stories(p)
      else if (p == p_brief) textfile(p, 1, "brief text")
      else if (p == p_decisions) textfile(p, 0, "a decision line")
      else if (p == "tools/check.cfg") cfg(p)
    }
  }
  # The protected changes: those against HEAD, less the ones another parent brought. A parent brought a change as often
  # as it is in that parent against each of its merge bases (the fewest); the parent that brought it most frees it.
  nu = 0
  for (i = 1; i <= PN[1]; i++) {
    k = PK[1, i]; ck = CK[k]
    if (!(ck in FREE)) {
      fr = 0
      for (gg = 1; gg <= ng; gg++) {
        mn = -1
        for (r = 2; r <= np; r++) if (GR[r] == gg) { c2 = ((r, ck) in PCF) ? PCF[r, ck] : 0; if (mn < 0 || c2 < mn) mn = c2 }
        if (mn > fr) fr = mn
      }
      FREE[ck] = fr
    }
    fr = FREE[ck]; if (fr > PC[1, k]) fr = PC[1, k]
    FREE[ck] -= fr
    cnt = PC[1, k] - fr
    split(k, g, SUBSEP)
    for (j = 1; j <= cnt; j++) { nu++; UP[nu] = g[1]; US[nu] = g[2]; UT[nu] = g[3]; UC[nu] = g[4]; UW[nu] = WHY[k] }
  }
  for (i = 1; i <= nu; i++) PCNT[UP[i] SUBSEP US[i] SUBSEP UT[i]]++
  # Coverage, whole summaries only: the approved ones largest first (the later one first on a tie). One is applied when
  # every line of it is still in the change (each changed line once), and then takes those lines.
  for (k in RAW) AV[k] = RAW[k]
  for (k in PCNT) if (!(k in AV) || PCNT[k] > AV[k]) AV[k] = PCNT[k]
  no_ = 0
  for (j = nA; j >= 1; j--) if (AST[AID[j]] == "approved") OR_[++no_] = AID[j]
  for (i = 2; i <= no_; i++) { t = OR_[i]; for (j = i - 1; j >= 1 && ALT[OR_[j]] < ALT[t]; j--) OR_[j + 1] = OR_[j]; OR_[j + 1] = t }
  for (i = 1; i <= no_; i++) {
    a = OR_[i]; whole_ = 1; LN_[a] = 0
    for (q = 1; q <= ALN[a]; q++) {
      k = ALK[a, q]; have = (k in AV) ? AV[k] : 0
      if (have < AC[a, k]) { whole_ = 0; for (m = have + 1; m <= AC[a, k]; m++) LACK[a, ++LN_[a]] = k }
    }
    if (!whole_) continue
    USE[a] = 1
    for (q = 1; q <= ALN[a]; q++) { k = ALK[a, q]; AV[k] -= AC[a, k]; TAKE[k] += AC[a, k] }
  }
  nun = 0
  for (i = 1; i <= nu; i++) {
    k = UP[i] SUBSEP US[i] SUBSEP UT[i]
    if ((k in TAKE) && TAKE[k] > 0) TAKE[k]--; else UNC[++nun] = i
  }
  if (mode == "collect") {
    no = 0
    for (i = 1; i <= nun; i++) { u = UNC[i]; if (!(UP[u] in GOT)) { GOT[UP[u]] = 1; ORD[++no] = UP[u] } }
    for (j = 1; j <= no; j++) { print "## " ORD[j]; for (i = 1; i <= nun; i++) { u = UNC[i]; if (UP[u] == ORD[j]) print US[u] " " UT[u] } }
    exit 0
  }
  nt = 0
  for (i = 1; i <= nA; i++) {
    a = AID[i]
    if ((a in USE) && !(AH[a] in HS)) { HS[AH[a]] = 1; TR[++nt] = "Approved: " a " " ADATE[a] " \"" AWORD[a] "\" " AH[a] }
  }
  if (mode == "trailer") { for (i = 1; i <= nt; i++) print TR[i]; exit 0 }
  if (mode == "message") {
    while ((getline t < msgf) > 0) { t = rs(t); if (t !~ /^#/) MS[t] = 1 }
    miss = 0
    for (i = 1; i <= nt; i++) if (!(TR[i] in MS)) miss++
    if (miss == 0) exit 0
    print "records: this commit carries record lines the human approved, and its message doesn\047t name the approval, so it is refused."
    print "records: add this line to the message (one line per approval), then commit again:"
    for (i = 1; i <= nt; i++) if (!(TR[i] in MS)) print "  " TR[i]
    print "records: `bash tools/records.sh trailer` prints the lines a staged commit needs."
    exit 1
  }
  if (nun == 0) exit 0
  where = (scope == "staged") ? "staged record changes" : "changes to the records"
  print "records: these " where " need the human\047s approval, and no approval covers them, so they can\047t be committed:"
  npart = 0
  for (i = 1; i <= nun; i++) {
    u = UNC[i]
    print "  " UP[u] ": " US[u] " " UT[u]
    k = UP[u] SUBSEP US[u] SUBSEP UT[u]
    note = ""
    if ((k in HASL) && !(HASL[k] in USE)) {
      a = HASL[k]; note = "summary " a " has this line, but the commit doesn\047t apply all of " a " (below)"
      if (!(a in PSHOWN)) { PSHOWN[a] = 1; PART[++npart] = a }
    }
    else if (k in NOTE) note = NOTE[k]
    else if (UP[u] in APATH) note = "the approved summary " APATH[UP[u]] " has lines for " UP[u] ", but not this one: the text differs from the summary"
    under = ((UP[u] == p_brief || UP[u] == p_stories) && UC[u] != "") ? " under `" UC[u] "`" : ""
    print "      (" UW[u] under (note != "" ? "; " note : "") ")"
  }
  for (j = 1; j <= npart; j++) {
    a = PART[j]
    print "records: the commit applies only part of summary " a ", so " a " covers none of its lines; the lines of " a " the " (scope == "staged" ? "staged change" : "change") " lacks:"
    for (m = 1; m <= LN_[a]; m++) { split(LACK[a, m], g, SUBSEP); print "  " g[1] ": " g[2] " " g[3] }
  }
  print "records: to go on:"
  print "  an assistant: register these lines with `bash tools/records.sh summary <file>`, show the human its output word for word, and commit once they approve it, with the line `bash tools/records.sh trailer` prints in the message (.app-director/rules.md › The human decides). Or unstage the lines."
  print "  the human, committing an edit of your own: run `bash tools/records.sh approve --staged` in your own terminal, then commit again."
  if (npart > 0) print "  or stage the rest of the summary\047s lines, so the commit applies all of it."
  exit 1
}
'

# approvals_data [<request file> <blob file>]: $tmp.appr, from the state folder; empty when nothing is registered. The
# blobs hold HEAD's record files, for the test whether an approval's lines are already committed; without them they are
# read here, in one git call.
approvals_data() {
  local areq="${1:-}" ablobs="${2:-}" m t
  tmp_init
  : > "$tmp.appr"
  set -- "$state"/S*.meta
  [ -e "$1" ] || return 0
  : > "$tmp.ids"; : > "$tmp.txts"
  for m in "$@"; do
    t="${m%.meta}.txt"; m="${m##*/}"
    if [ -f "$t" ]; then printf '%s\t1\n' "${m%.meta}" >> "$tmp.ids"; printf '%s\n' "$t" >> "$tmp.txts"
    else printf '%s\t0\n' "${m%.meta}" >> "$tmp.ids"; fi
  done
  : > "$tmp.hashes"
  [ -s "$tmp.txts" ] && git hash-object --no-filters --stdin-paths < "$tmp.txts" > "$tmp.hashes" 2>/dev/null
  : > "$tmp.used"
  if [ "$has_head" -eq 1 ]; then
    # shellcheck disable=SC2086
    git log --format='%x01%h%n%B' --grep='^Approved: ' HEAD $mheads > "$tmp.used" 2>/dev/null
    if [ -z "$areq" ]; then
      areq="$tmp.areq"; ablobs="$tmp.ablobs"
      printf 'HEAD:%s\n' "$p_brief" "$p_decisions" "$p_stories" "$p_tasks" tools/check.cfg > "$areq"
      git cat-file --batch < "$areq" > "$ablobs" 2>/dev/null
    fi
  else
    areq=""; ablobs=""
  fi
  LC_ALL=C awk -v dir="$state" -v idsf="$tmp.ids" -v hashf="$tmp.hashes" -v usedf="$tmp.used" -v has_head="$has_head" \
    -v reqf="$areq" -v blobf="$ablobs" "$awk_lib$appr_prog" > "$tmp.appr"
}

# analyse <mode> <scope>: judges the record files changed against HEAD; during a merge, also each MERGE_HEAD commit
# against each of its merge bases with HEAD (git merge-base --all; none when there is no base or the commit is an
# ancestor of HEAD), for the changes that parent brought. Prints for the mode, returns 1 when refused.
analyse() {
  local mode="$1" scope="$2" names st p req="" changes="" m b g bases pairs="" pm pb pg
  if [ "$scope" = staged ]; then
    names="$(git -c core.quotePath=false diff --cached --name-status --no-renames HEAD -- "$p_brief" "$p_decisions" "$p_stories" "$p_tasks" tools/check.cfg 2>/dev/null)"
  else
    names="$(git -c core.quotePath=false diff --name-status --no-renames HEAD -- "$p_brief" "$p_decisions" "$p_stories" "$p_tasks" tools/check.cfg 2>/dev/null)"
  fi
  [ -n "$names" ] || return 0
  g=0
  for m in $mheads; do
    bases="$(git merge-base --all HEAD "$m" 2>/dev/null)"
    [ -n "$bases" ] || continue
    case "$nl$bases$nl" in *"$nl$m$nl"*) continue ;; esac   # m is an ancestor of HEAD
    g=$((g + 1))
    while IFS= read -r b; do [ -n "$b" ] && pairs="$pairs$m$tab$b$tab$g$nl"; done <<< "$bases"
  done
  while IFS="$tab" read -r st p; do
    case "$st" in A|"") continue ;; esac   # a record file HEAD doesn't have isn't judged
    changes="$changes$st$tab$p$nl"
    req="${req}HEAD:$p$nl"
    [ "$scope" = staged ] && [ "$st" != D ] && req="$req:$p$nl"
    while IFS="$tab" read -r pm pb pg; do [ -n "$pm" ] && req="$req$pm:$p$nl$pb:$p$nl"; done <<< "$pairs"
  done <<< "$names"
  [ -n "$changes" ] || return 0
  [ "$scope" = staged ] && req="$req:$p_brief$nl:$p_stories$nl"
  tmp_init
  set -- "$state"/S*.meta
  [ -e "$1" ] && req="${req}HEAD:$p_brief${nl}HEAD:$p_decisions${nl}HEAD:$p_stories${nl}HEAD:$p_tasks${nl}HEAD:tools/check.cfg$nl"
  printf '%s' "$req" > "$tmp.req"; printf '%s' "$changes" > "$tmp.changes"; printf '%s' "$pairs" > "$tmp.revs"
  git cat-file --batch < "$tmp.req" > "$tmp.blobs" 2>/dev/null
  approvals_data "$tmp.req" "$tmp.blobs"
  : > "$tmp.msg"; [ -n "${msg_file:-}" ] && msg_arg="$msg_file" || msg_arg="$tmp.msg"
  LC_ALL=C awk -v mode="$mode" -v scope="$scope" -v dir="$state" -v reqf="$tmp.req" -v blobf="$tmp.blobs" \
    -v revf="$tmp.revs" -v chf="$tmp.changes" -v apprf="$tmp.appr" -v msgf="$msg_arg" -v bugs="$bugs" -v p_brief="$p_brief" \
    -v p_decisions="$p_decisions" -v p_stories="$p_stories" -v p_tasks="$p_tasks" "$awk_lib$judge_prog"
}

# summary_prog: checks a summary file and writes its canonical text to out, and to eff whether its effect is already at
# HEAD (effect=0: every line is an addition already there, so committed lines can't show it was used). The record paths
# are a1..a5.
summary_prog='
function err(s) { print "records: line " NR " of the summary: " s; bad = 1 }
BEGIN {
  OK[a1] = 1; OK[a2] = 1; OK[a3] = 1; OK[a4] = 1; OK[a5] = 1
  loadblobs()
  for (r in N) { p = substr(r, 6); for (i = 1; i <= N[r]; i++) HL[p, rs(L[r, i])] = 1 }
  cp = ""; n = 0; there = 1
}
{
  t = rs($0)
  if (t == "") next
  if (t ~ /^## /) {
    cp = trim(substr(t, 4))
    if (!(cp in OK)) err(cp " isn\047t a record file (" a1 ", " a2 ", " a3 ", " a4 " or " a5 ")")
    next
  }
  if (t ~ /^[+-] /) {
    if (cp == "") { err("a line before any `## <path>`: " t); next }
    sg = substr(t, 1, 1); tx = substr(t, 3)
    if (trim(tx) == "") { err("a blank line needs no approval: " t); next }
    if (sg == "-" && !((cp, tx) in HL)) { err("the line removed isn\047t in " cp " at HEAD: " t); next }
    if (sg == "-" || !((cp, tx) in HL)) there = 0
    n++; SP[n] = cp; SL[n] = t
    next
  }
  err("not `## <path>`, `+ <line>` or `- <line>`: " t)
}
END {
  if (!bad && n == 0) { print "records: the summary has no lines"; bad = 1 }
  if (bad) exit 1
  last = ""
  for (i = 1; i <= n; i++) { if (SP[i] != last) { print "## " SP[i] > out; last = SP[i] }; print SL[i] > out }
  close(out)
  print "effect=" (there ? 0 : 1) > eff
  close(eff)
}
'

# register <summary file>: checks it, stores it as S<n> (its first line "# S<n> registered <epoch>") and sets reg_id and
# reg_hash.
register() {
  local f="$1" line p req="" n=0 now eff="effect=1"
  tmp_init
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%"$cr"}"
    case "$line" in "## "*) p="${line#\#\# }"; p="${p%"${p##*[![:space:]]}"}"; p="${p#"${p%%[![:space:]]*}"}"; req="${req}HEAD:$p$nl" ;; esac
  done < "$f"
  printf '%s' "$req" > "$tmp.req"; : > "$tmp.blobs"
  [ "$has_head" -eq 1 ] && [ -n "$req" ] && git cat-file --batch < "$tmp.req" > "$tmp.blobs" 2>/dev/null
  [ -f "$state/counter" ] && read -r n < "$state/counter"
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  n=$((n + 1))
  while [ -e "$state/S$n.meta" ] || [ -e "$state/S$n.txt" ]; do n=$((n + 1)); done
  if ! LC_ALL=C awk -v reqf="$tmp.req" -v blobf="$tmp.blobs" -v out="$tmp.canon" -v eff="$tmp.eff" -v a1="$p_brief" \
      -v a2="$p_decisions" -v a3="$p_stories" -v a4="$p_tasks" -v a5="tools/check.cfg" "$awk_lib$summary_prog" < "$f"; then
    exit 1
  fi
  [ "$has_head" -eq 1 ] && read -r eff < "$tmp.eff"
  now="$(date +%s)"
  printf '# S%s registered %s\n' "$n" "$now" > "$state/S$n.txt"
  while IFS= read -r line; do printf '%s\n' "$line" >> "$state/S$n.txt"; done < "$tmp.canon"
  printf '%s\n' "$n" > "$state/counter"
  reg_hash="$(git hash-object --no-filters "$state/S$n.txt")"
  printf 'registered=%s\nhash=%s\n%s\n' "$now" "$reg_hash" "${eff:-effect=1}" > "$state/S$n.meta"
  reg_id="S$n"
}

show_summary() { # show_summary <id> <hash>: the summary's lines, without its first line
  local line
  say "summary $1 · ${2:0:12}"
  while IFS= read -r line; do case "$line" in "# S"*) ;; *) printf '%s\n' "$line" ;; esac; done < "$state/$1.txt"
}

is_word() { # is_word <word>: one of [approval] words, whole, ASCII letters and Å, Ä, Ö in any case. The ASCII letters are
  # lowered by hand: tolower in some C locales changes the bytes of a UTF-8 letter too.
  LC_ALL=C awk -v w="$1" -v list="$words" '
    function norm(s,   i, c, p, out) {
      gsub(/Å/, "å", s); gsub(/Ä/, "ä", s); gsub(/Ö/, "ö", s); sub(/^[ \t]+/, "", s); sub(/[ \t\r]+$/, "", s); out = ""
      for (i = 1; i <= length(s); i++) { c = substr(s, i, 1); p = index("ABCDEFGHIJKLMNOPQRSTUVWXYZ", c); out = out (p ? substr("abcdefghijklmnopqrstuvwxyz", p, 1) : c) }
      return out
    }
    BEGIN { w = norm(w); if (w == "") exit 1; split("", a); n = split(list, a, ","); for (i = 1; i <= n; i++) if (norm(a[i]) == w) exit 0; exit 1 }'
}

cmd_summary() {
  [ -n "${1:-}" ] || usage
  local f; f="$(abs_path "$1")"
  [ -f "$f" ] || refuse "no summary file $1"
  read_settings
  register "$f"
  show_summary "$reg_id" "$reg_hash"
  say "show the human these lines word for word, with the id $reg_id. Nothing is written until they approve it."
}

cmd_approve() {
  local id="" staged=0 hook=0 word="" by="terminal" meta_hash="" line cur now date sid sst swhy sd sw sh sr
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --staged) staged=1 ;;
      --hook) hook=1 ;;
      --word) shift; word="${1:-}" ;;
      --by) shift; by="${1:-}" ;;
      -*) usage ;;
      *) id="$1" ;;
    esac
    shift
  done
  read_settings
  if [ "$hook" -eq 1 ]; then
    [ -n "$id" ] && [ "$staged" -eq 0 ] || usage
    case "$by" in prompt|dialog) ;; *) refuse "--by takes prompt or dialog" ;; esac
    is_word "$word" || refuse "'$word' isn't an approval word ([approval] words in tools/check.cfg: $words)"
  else
    [ "$by" = terminal ] || usage
    if [ "$staged" -eq 1 ]; then
      [ -z "$id" ] || usage
      [ "$has_head" -eq 1 ] || refuse "there is no commit yet, so nothing staged is judged"
      tmp_init
      analyse collect staged > "$tmp.collect"
      [ -s "$tmp.collect" ] || { say "nothing staged needs an approval"; exit 0; }
      say "the staged lines that need an approval:"
      while IFS= read -r line; do printf '%s\n' "$line"; done < "$tmp.collect"
    fi
    if [ ! -t 0 ] || [ ! -t 1 ]; then
      refuse "approve needs the human's own terminal: run 'bash tools/records.sh approve ${id:---staged}' in your own terminal, not through an assistant. Nothing was registered or approved."
    fi
    if [ "$staged" -eq 1 ]; then
      register "$tmp.collect"
      id="$reg_id"
    fi
    [ -n "$id" ] || usage
  fi
  [ -f "$state/$id.meta" ] && [ -f "$state/$id.txt" ] || refuse "no summary $id (bash tools/records.sh status lists them)"
  while IFS= read -r line; do
    case "$line" in hash=*) meta_hash="${line#hash=}" ;; esac
  done < "$state/$id.meta"
  cur="$(git hash-object --no-filters "$state/$id.txt")"
  [ "$cur" = "$meta_hash" ] || refuse "the text of $id changed since it was registered, so it can't be approved: register the summary again"
  approvals_data
  while IFS="$tab" read -r sid sst swhy sd sw sh sr; do
    [ "$sid" = "$id" ] && [ "$sst" = used ] && refuse "$swhy; register a new summary for further lines"
  done < "$tmp.appr"
  if [ "$hook" -eq 0 ]; then
    show_summary "$id" "$meta_hash"
    printf 'records: type an approval word (%s) to approve these lines, or anything else to leave them unapproved: ' "$words"
    IFS= read -r word || word=""
    word="${word%"$cr"}"; word="${word#"${word%%[![:space:]]*}"}"; word="${word%"${word##*[![:space:]]}"}"
    is_word "$word" || refuse "not approved: '$word' isn't an approval word ([approval] words in tools/check.cfg)"
  fi
  now="$(date '+%s %Y-%m-%d')"; date="${now#* }"; now="${now%% *}"
  printf 'hash=%s\ntime=%s\ndate=%s\nword=%s\nby=%s\n' "$meta_hash" "$now" "$date" "$word" "$by" > "$state/$id.approval"
  say "$id approved ($by, \"$word\"). The commit that writes these lines names it with this line in its message:"
  printf 'Approved: %s %s "%s" %s\n' "$id" "$date" "$word" "${meta_hash:0:12}"
}

cmd_withdraw() {
  local id st note d w h r list="" now
  read_settings
  approvals_data
  while IFS="$tab" read -r id st note d w h r; do
    case "$st" in approved|invalid) [ -f "$state/$id.approval" ] && list="$list $id" ;; esac
  done < "$tmp.appr"
  [ -n "$list" ] || { say "no approval to withdraw"; exit 0; }
  now="$(date +%s)"
  for id in $list; do printf 'withdrawn=%s\n' "$now" >> "$state/$id.approval"; done
  say "withdrawn:$list"
}

cmd_status() {
  local id st note d w h r
  read_settings
  approvals_data
  while IFS="$tab" read -r id st note d w h r; do
    [ "$st" = used ] || printf '%s %s %s %s\n' "$id" "$h" "$st" "$r"
  done < "$tmp.appr"
}

cmd_open() {
  [ -n "${1:-}" ] || usage
  local want="$1" id st note d w h r line root
  root="$(pwd)"; want="${want#"$root"/}"; want="${want#./}"
  read_settings
  approvals_data
  while IFS="$tab" read -r id st note d w h r; do
    [ "$st" = approved ] || continue
    while IFS= read -r line; do [ "$line" = "## $want" ] && exit 0; done < "$state/$id.txt"
  done < "$tmp.appr"
  exit 1
}

cmd_check() {
  local scope=staged
  case "${1:-}" in ""|--staged) ;; --worktree) scope=worktree ;; *) usage ;; esac
  [ "$has_head" -eq 1 ] || exit 0
  if in_prototype; then say "this checkout is a prototype, so its record lines aren't judged"; exit 0; fi
  read_settings
  analyse check "$scope"
  exit $?
}

cmd_trailer() {
  [ "$has_head" -eq 1 ] || exit 0
  read_settings
  analyse trailer staged
  exit 0
}

cmd_message() {
  [ -n "${1:-}" ] || usage
  [ "$has_head" -eq 1 ] || exit 0
  local x
  for x in CHERRY_PICK_HEAD REVERT_HEAD rebase-merge rebase-apply; do [ -e "$gitdir/$x" ] && exit 0; done
  in_prototype && exit 0
  msg_file="$(abs_path "$1")"
  read_settings
  analyse message staged
  exit $?
}

cmd_report() {
  local since="${1:-}" what
  [ "$has_head" -eq 1 ] || { echo "approvals used: none"; echo "proposed items: none"; exit 0; }
  read_settings
  tmp_init
  if [ -n "$since" ]; then
    what="since $since"
    git log --format='%x01%h %s%n%B' "$since..HEAD" > "$tmp.log" 2>/dev/null || refuse "no commit $since"
  else
    what="in the last 20 commits"
    git log -n 20 --format='%x01%h %s%n%B' HEAD > "$tmp.log" 2>/dev/null
  fi
  LC_ALL=C awk -v what="$what" -v tasks="$p_tasks" -v logf="$tmp.log" "$awk_lib"'
    BEGIN {
      print "approvals used " what ":"; n = 0
      while ((getline line < logf) > 0) {
        if (substr(line, 1, 1) == "\001") { cur = substr(line, 2); continue }
        if (line ~ /^Approved: /) { print "  " cur ": " rs(line); n++ }
      }
      if (n == 0) print "  none"
      print "proposed items in " tasks ":"; n = 0
      m = 0; split("", A); split("", LV)
      while ((getline line < tasks) > 0) A[++m] = rs(line)
      hlevels(A, m, LV)
      for (i = 1; i <= m; i++) if (LV[i] > 0 && itemid(A[i]) != "" && status_of(A[i]) == "proposed") { print "  " A[i]; n++ }
      if (n == 0) print "  none"
    }' < /dev/null
}

cmd="${1:-}"
[ "$#" -gt 0 ] && shift
case "$cmd" in
  summary) cmd_summary "$@" ;;
  approve) cmd_approve "$@" ;;
  withdraw) cmd_withdraw ;;
  status) cmd_status ;;
  open) cmd_open "$@" ;;
  check) cmd_check "$@" ;;
  trailer) cmd_trailer ;;
  message) cmd_message "$@" ;;
  report) cmd_report "$@" ;;
  *) usage ;;
esac
