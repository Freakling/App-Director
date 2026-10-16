<!-- App Director · framework-owned: replaced on upgrade. -->
# Build one item

Build one TASKS.md item that has already been claimed, and report back briefly. Until you've written the report, don't pick items, don't edit TASKS.md, AGENTS.md or `product/`, and don't commit. Whoever handed you the item does that; if that's you, carry on with `next-task.md` afterwards.

1. **Read what the item needs.** You have the item's ID and full text, and on a rebuild also the previous report and the human's instructions. Read its `Touches`, the AGENTS.md › Architecture rows involved, and the brief sections under `Brief:` (`grep -n "^#" product/brief.md` lists the headings). Follow references from there, reading by heading or line range.
2. **Open questions.** If `Done when` names a question still listed in brief › Open Questions, build the rest and stand in for the answer:
   - a missing value becomes a `PLACEHOLDER` default with a comment citing the question;
   - a missing behaviour stays as it is, behind a named constant or flag with a comment.
3. **Stop and report `blocked` instead of guessing** when:
   - you hit a design call the brief doesn't settle (give 2-4 options and a recommendation);
   - the item needs something it doesn't describe;
   - it would touch much more than its `Touches`.
4. **Build** by `.app-director/rules.md` › Architecture defaults. Write a test for every `(test)` outcome, and a regression test for a bug when it can have one. Stay inside the item.
5. **Screens** (an item with `UI:`; skip it otherwise). The screen spec is the layout; follow `procedures/ui-design.md`.
   - Read the spec and `product/ui/captures/<id>.drawing.json` (never the raw `.excalidraw`: it embeds the screenshot). Without a drawing the spec alone is enough.
   - Build with flex or grid, never pixel positions. Give every element the spec names its `data-testid` (`gear-list`).
   - Add or update the screen's catalog entry (`tools/ui/screens.mjs`), with a state for each state the spec lists.
   - Run `bash tools/ui_capture.sh <id> --verify`. Look at the capture and its `.lint.txt` (or `.elements.json`, if you can't view images), then read the table it prints. The layout lint runs here, not in the check.
   - Fix the deviations that are in scope; report the rest in the `Screen:` line.
   - If it exits 3, the `(check)` outcome about the capture stays unverified: say so plainly in the report, as for the check's exit 3.
6. **Verify** with `bash tools/check.sh` (foreground, long timeout), until it exits 0.
   - After two failed attempts at the same problem, stop and report.
   - A failure in files the item doesn't touch, which was there before you started, isn't yours: report `failed: pre-existing` with its lines.
   - Exit 3 means the check couldn't run; report that.
7. **Report** in at most about 20 lines. It's all the caller keeps, so no file dumps:
   ```
   Result: done | blocked: <question, options, recommendation> | failed: <last check lines> | failed: pre-existing: <lines>
   Files: <changed and new files>
   Done when: <each outcome → the test that proves it | the command and its result | what a human should look at>
   Systems: <systems added, removed or re-scoped, with a one-line "owns" | none>
   API/saves: <public API contracts or stored data schemas changed | none>
   Screen: <for a `UI:` item: `hero_room verified at 3 sizes; 0 lint; 1 deviation: Gear list 6% left of the spec`, or `unverified: capture exit 3, <why>` | omit>
   Placeholders: <new PLACEHOLDER values | none>
   For the human: <questions or decisions | none>
   Found: <work outside this item, one line each | none>
   Touches: <files changed that aren't listed, and listed files not needed | same>
   ```
