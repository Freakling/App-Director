<!-- App Director · framework-owned: replaced on upgrade. -->
# Build one item

Build one TASKS.md item that has already been claimed, and report back briefly. Until you've written the report, don't pick items, don't edit TASKS.md, AGENTS.md or `product/`, and don't commit. Whoever handed you the item does that; if that's you, carry on with `next-task.md` afterwards.

Shell commands follow `.app-director/rules.md` › Shell commands. Write files with the file tools (Write or Edit in Claude Code), never with a shell heredoc or an `echo` or `printf` redirect of multi-line content, since a heredoc can hang the shell; write a multi-line script to a file and run it from there. Keep every shell call one short command that finishes well inside the tool's timeout; only the check, a build and a host start run long, with an explicit long timeout.

1. **Read what the item needs.** You have the item's ID and full text, and on a rebuild also the previous report and the human's instructions. Read its `Touches`, the AGENTS.md › Architecture rows involved, the brief sections under `Brief:` (`grep -n "^#" product/brief.md` lists the headings), and the stories under `Stories:` (`grep -n "US-2 " product/user-stories.md`), which say who it's for and why. An item with `Prototype: proto/<name>` was tried there first: while that branch exists, read the prototype's diff for the item's paths (`git diff main...proto/<name> -- <path>`) as a reference for what was tried. Build to the item; never merge or cherry-pick the prototype. Follow references from there, reading by heading or line range.
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
6. **Verify** with `bash tools/check.sh --fast` (foreground, long timeout), until it exits 0. The fast tier runs UI purity, the secrets scan and the stack check on what the change needs: in a TypeScript app, tsc, eslint on the changed files and the tests related to the change, your new tests included.
   - Never run the full tier. An outcome that names the check is met here by the fast tier; the commit hook brings the full tier when it's due, and so do the end of a run and a push (`rules.md` › Running the check).
   - Never start a check beside a running one: the second waits for the first, and reuses its result when the files and the tier match.
   - After two failed attempts at the same problem, stop and report.
   - A failure in files the item doesn't touch, which was there before you started, isn't yours: report `failed: pre-existing` with its lines.
   - Exit 3 means the check couldn't run; report that.
7. **Stop background commands.** If the tool moved a command of yours to the background (it says so when the command outlives its timeout), stop it before you report: with the tool's own stop if it offers one, or else kill the process (`kill` or `taskkill` with its pid; `ps` lists it when the tool gives only a task ID). Never report while a background command of yours is still alive: until it ends, the caller sees you as running.
8. **Report** in at most about 20 lines. It's all the caller keeps, so no file dumps:
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
   Background: <each command moved to the background, and how it was stopped | none>
   ```
