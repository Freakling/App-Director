<!-- App Director · framework-owned: replaced on upgrade. -->
# Design drift reset

When a principle in the brief has been built two ways, patching one place makes the other worse. A reset rebuilds shared understanding instead: describe the app as built, map how each principle was interpreted, let the human rewrite the design, and plan the rebuild as ordinary items. It is the big counterpart to `align.md`: align often, reset when you have to.

**Only the human starts a reset.** Never run it on your own; `align.md` may recommend one. Nothing in a reset writes application code: the rebuild runs through `next-task.md` as normal.

The request is `reset` (the default) or `postmortem`.

## Safety
- Before step 1, recommend running the reset on its own branch (`git switch -c drift-reset-YYYY-MM-DD`) and wait for the human's answer.
- The working tree is clean before you start. If it isn't, ask the human what to do with the changes, as `next-task.md` › Pick does.
- Never use commands that discard work or rewrite history (`rules.md` › Git).
- Never delete or overwrite anything in a reset folder, including the old brief and the as-built analysis. A later reset gets its own folder.

## Reset folder
Everything a reset writes, apart from the brief, `product/decisions.md` and TASKS.md, goes in `product/resets/YYYY-MM-DD/` (today's date). If that folder already exists, add `-2`, `-3`.

## 1. Analyse as built (read only)
1. Split the project into areas, one per row in AGENTS.md › Architecture (merge tiny rows, split huge ones). List the areas to the human.
2. For each area, run Area analysis below in a fresh, read-only context wherever the tool allows it; in Claude Code that's the `reviewer` subagent, one per area. Give it the area's name, its Architecture row, its folders, and the brief's principles (heading and one line each). Analyses are read-only, so they may run in parallel.
3. Write the reports to `as-built.md`, one heading per area. Every claim names `file:line`.
4. Apart from `as-built.md`, change no code and no docs in this step.

### Area analysis
Read only: never edit files or run commands that change anything. For the area you're given, report:
- **What it does today:** the behaviour a user sees, the data it reads and writes, and the other areas it calls. Describe what the code does, not what the brief says it should do.
- **Principles:** for each brief principle the area touches, how this area interprets it, with `file:line`.
- **Logic in the UI layer:** files in `tools/check.cfg` › `[ui] dirs` that hold business rules, validation, calculations, or decisions about what the user may do. That logic belongs in the testable logic layer, and it is a common source of divergent interpretations. Name each with `file:line` and one line on what the logic is. Where to look, by `tools/check.cfg` › `[project] stack`:
  - **TypeScript:** components and pages that branch on domain data, validate inline, or compute in handlers and `useEffect` instead of calling a service or hook.
  - **Flutter:** `build()` methods and `State` classes that compute, validate or branch on domain rules instead of reading a provider, bloc or service.
  - **Python:** views, templates and route handlers that compute, validate or decide instead of calling a service function.
  - **Other stacks:** anything in a UI file that a test would need a running UI to reach.
- **Surprises:** behaviour that no brief section or TASKS.md item explains.

Keep the report under about 60 lines.

## 2. Map interpretations (read only)
1. List the brief's principles: its product principles and requirements, its core flows, and the rules stated in its sections. One line each, by heading.
2. For each principle, take from `as-built.md` how it was actually implemented, and where (`file:line`). Classify it:
   - **consistent:** built one way everywhere, matching the brief;
   - **divergent:** read two or more ways in different places;
   - **contradictory:** built in a way the brief rules out, or the brief contradicts itself or `product/decisions.md`.
3. Write `interpretations.md`: one section per principle with its class, each interpretation found, and its locations. For each divergent or contradictory principle, also record its **failure mode**: what went wrong, and what would have shown it earlier. The postmortem checks these.
4. Present the summary to the human: the count per class, then one line per divergent or contradictory principle. Change nothing else.
5. Commit `as-built.md` and `interpretations.md` as `docs: drift reset analysis YYYY-MM-DD` after the human approves.

## 3. Rewrite the design (the human decides)
1. For each divergent or contradictory principle, raise a design call the way `design.md` › For each question does. Start from what `interpretations.md` found, offer 2-4 options (usually including each interpretation found) with a recommendation, and offer the human the choice of writing their own answer. One principle at a time.
2. Record only what the human chose: one line per decision in `product/decisions.md`, in the format at the top of that file, with `drift reset YYYY-MM-DD` in the reason.
3. Copy the current brief to `brief-before.md` in the reset folder. Then draft the revised brief: write each decision into its section as the current design, replacing the text it supersedes (`rules.md` › Each fact lives in one place). Change nothing the human didn't decide.
4. If AGENTS.md › Ownership makes the brief human-owned, or a hook blocks the write, never work around it. Write the draft as `brief-proposal.md` in the reset folder and ask the human to apply it; continue once they have.
5. Show the human the changed sections. Commit the brief, `product/decisions.md` and the reset folder as `docs: drift reset design YYYY-MM-DD` after the human approves.

## 4. Plan the rebuild (no code changes)
1. Compare the approved brief against `as-built.md`. Every place that doesn't match is work: rewriting a losing interpretation, moving logic out of UI files into the logic layer, removing what is no longer wanted.
2. Write the work as TASKS.md items in the format in `.app-director/tasks.md`, with IDs from `Next IDs`. Each item has a Size, `Depends on`, `Touches` naming the exact files it may change, tagged `Done when` outcomes, and a `Brief:` heading. Split `L` and `XL` work where you can, and put items that remove contradictions before items that unify divergent readings.
3. Write `rebuild.md` in the reset folder: for each divergent or contradictory principle, the item IDs that rebuild it.
4. Commit TASKS.md and `rebuild.md` as `docs: drift reset plan YYYY-MM-DD` after the human approves. Tell the human the rebuild runs through `next-task.md` ("work through the queue").

## 5. Postmortem (`postmortem`)
Run after the rebuild items are done.
1. Use the latest reset folder, or the one the human names. If an item in its `rebuild.md` isn't `done`, list it and ask whether to go on.
2. Run `bash tools/check.sh` and report the result.
3. For each failure mode in `interpretations.md`, check whether the rebuilt system still shows it: run Area analysis on the affected areas, as in step 1, limited to that principle and its files.
4. Write `postmortem.md` in the reset folder: per principle, `fixed` or `still drifting` (with `file:line`), and what let the drift happen.
5. For each drift a script could catch next time (a forbidden import, a pattern in UI files, a value that must come from config, a file that must exist), propose a check rule as a design call: what it catches, the command, the false positives it may hit, and a recommendation. Rules the human chooses get a line in `product/decisions.md` and an item that adds them to `tools/check.local.sh` or `tools/check.cfg`. Directing scales by turning repeated judgment into checks.
6. A principle that is still drifting becomes an item, or a new design call if the brief itself is the problem.
7. Commit as `docs: drift reset postmortem YYYY-MM-DD` after the human approves.
