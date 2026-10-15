<!-- App Director · framework-owned: replaced on upgrade. -->
# Next task

Pick the next ready item in `TASKS.md` (or the one the human named), have it built, prove it with the check, update the records, and commit it with the human's approval.

The build runs in a fresh context wherever the tool allows it; in Claude Code that's the `builder` subagent. This session keeps only the item, the builder's short report and the bookkeeping, so its context stays small however many items it gets through.

A research item (`R<n>`) isn't built. It goes to the `researcher` instead, and what gets committed is its note: see Research items.

The request can be:
- empty: the next ready item;
- an item ID (T12, B3, R2): that item;
- "the next N tasks", "work through the queue" or "grab tasks until you're blocked": see Several items.

## 1. Pick
1. **Find items without reading the whole file.** `grep -n '^### ' TASKS.md` lists every heading; then read only the candidates.
2. **Is the tree clean?** If uncommitted changes from another item are in the working tree, don't start a new one. Ask the human whether to finish that item, commit it, or set it aside with `git stash push -- <paths>`.
3. **Does the check pass now?** Run `bash tools/check.sh --if-changed`; it's instant after a passing commit. If it fails, say so, and offer the items that would fix it. Build others only if the human says to, telling the builder the failure was there before. A research item changes no code, so skip this for one.
4. **Items already `in-progress`:**
   - **Claimed today:** another session may be working on it right now, so ask before touching it.
   - **Older:** a session probably ended mid-task. Read its `Note:`, look at `git status` and `git diff`, then resume it or set it back to `todo`, and say which.
5. **Candidates** are `agent` items with status `todo` whose `Depends on` items are all `done`, research items included. IDs missing from TASKS.md are in `TASKS-archive.md`.
6. **Order:** `high` bugs first, then everything else in file order. File order is the human's priority, so don't reorder.
7. **Nothing ready?** Report what's blocked and on what (dependencies, `human` items, open questions), and stop.

## 2. Claim
Set the item to `in-progress YYYY-MM-DD` (today).

## 3. Build
A research item goes to Research items instead, and skips steps 4 and 6.

- **In Claude Code,** give the `builder` subagent the item's ID and full text. Run it in the foreground (`run_in_background: false`), and never run two builders at once: they would edit, and check, each other's files.
  1. Before starting it, create the file `.app-director/state/building`. Delete it when the report arrives; while it exists, the Stop hook leaves the half-built files alone.
  2. If AGENTS.md › Project rules has model sizing on, read the model ID for the item's size from that block (e.g. `- XS: claude-haiku-4-5-20251001`) and pass it as `model:`. If no entry exists for the size, use the session model.
- **Other tools:** follow `build.md` yourself, or in a subagent if your tool has them.
- **A rebuild** (after a failure, a blocked report or review findings) gets the previous report, anything the human said about the item, and word that the earlier attempt's edits are still in the tree to continue from.
- **Report `blocked`:** the report brings the question with options and a recommendation. Put it to the human.
  - If the answer is a design decision, record it following `design.md` › Record each decision before rebuilding. It's committed with the item.
  - Then rebuild, including the answer.
- **Report `failed`:**
  - If the item is not `XL` and has not already been escalated, retry once using the next size's model entry (XS→S, S→M, M→L, L→XL; or the session model if no entry exists). Update the item label to `<next-size> (escalated from <original-size>)`, e.g. `M (escalated from S)`.
  - If the item is `XL`, or the retry also fails, add a `Note:` to the item and bring the check output to the human.
- **Report `failed: pre-existing`:** the failure was there before the build. Tell the human.

## 4. Verify
Run `bash tools/check.sh --if-changed`. It passes at once if the files are as the builder left them.

## 5. Update the records
From the report:
- Set the item to `done`, and delete its `Note:` if it has one.
- `Systems:` → AGENTS.md › Architecture.
- A milestone finished or changed → its row in TASKS.md › Milestones.
- `Found:` → new items, in the format in `.app-director/tasks.md` (IDs from `Next IDs`, then bump it).
- Name any difference from `Touches` in your report to the human.

## 6. Review
Only when `rules.md` › Reviews and model size calls for one, judged from the item's size and the report's `API/saves:` line.
1. Make new files show up in the diff with `git add -N <new files>`, then write it: `git diff HEAD > .app-director/state/review.diff`.
2. Ask for a review following `review.md`; in Claude Code, that's the `reviewer` subagent. Give it the item ID, the builder's report and the check result.
3. Code findings that are in scope: rebuild with the findings. Record findings: fix them yourself. Everything else becomes new items.
4. Review again only if the fixes were substantial.

## 7. Commit and report
- **Commit** as `rules.md` › Git describes: one commit for the item's paths, including its records. A research item's paths are its note and TASKS.md, and its message is `docs: <summary> (R3)`. Pause for approval unless the human has said to work autonomously ("do the next N tasks", "work through the queue", "grab tasks until you're blocked"), in which case commit without pausing and include all commits in the final report.
- **Report** in a few lines: what changed, the check result, placeholders added, and anything waiting on the human. Mention that `(demo)` outcomes, or a bug fix without a regression test, will be in the next acceptance check.
- **After the commit,** the records hold everything about the item. A new item can start in a fresh session, or after `/clear` in Claude Code, without losing anything.

## Research items
A research item (format in `.app-director/tasks.md`) is a candidate like any other, in file order. It changes no code, so there's no check to run (Pick step 3, Verify), no review, and no `building` marker: the researcher writes nothing.
1. **Claim** it as in step 2.
2. **Run it** in a fresh context.
   - In Claude Code, give the `researcher` subagent the item's ID and full text, in the foreground (`run_in_background: false`). If AGENTS.md › Project rules has model sizing on, pass the model for the item's size, as for a build; otherwise use the session model.
   - Other tools: follow `research.md` in a fresh context, or a subagent if your tool has them.
   - The researcher never asks the human. It states assumptions in the note and carries on.
3. **Write the note.** The report is the note. Write it to `product/research/YYYY-MM-DD-<slug>.md`, with today's date and a short kebab-case slug of the topic, creating the folder if needed. The researcher never writes the file.
4. **Update the records.** Set the item to `done` and delete its `Note:`. Follow-ups the note names become new items (IDs from `Next IDs`, then bump it). The note doesn't change the brief, `product/decisions.md` or Open Questions.
5. **Informs.** When the item has `Informs: Q<n>`, say that Q<n> is ready for a design call, and offer a design session with the note as input. The question stays in Open Questions until the human decides, and tasks that need the decision stay gated by it.
6. **Escalate** a note that says the question needs more than its size allows: rerun it once on the next size's model and label the item `M (escalated from S)`. An `XL` note that says so comes to the human.
7. **Commit** the note and the records as step 7 describes.

## Several items
Repeat steps 1-7 for each item, skipping `human` items as step 1 does. Report one line per finished item, and don't re-read files you've already seen. Stop early when:
- an item is blocked on something only the human can answer;
- a build fails;
- the human declines a commit.

A finished research item doesn't stop the run: it goes on with the next candidate.

End with the list of items done, the questions that research has made ready for a design call, and what's next.

## Stopping partway through
If you must stop before the item is done, add `- Note: <where it stands, what's next>` to the item.
