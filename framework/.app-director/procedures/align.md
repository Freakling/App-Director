<!-- App Director · framework-owned: replaced on upgrade. -->
# Align

A consistency pass across the brief, decisions, TASKS.md, AGENTS.md and check config. Check everything below, fix what's mechanical, and list what needs the human, with a recommendation for each. Never change design.

1. **Placeholders.** No `{{…}}` left in AGENTS.md, TASKS.md, `product/` or `validation/TEMPLATE.md` (`git grep -n "{{" -- AGENTS.md TASKS.md product validation/TEMPLATE.md`). The template's flow sections may wait until the core flows are decided, but only if an item for filling them exists.
2. **Entry files.**
   - AGENTS.md points to `.app-director/rules.md`.
   - In Claude Code, CLAUDE.md contains `@AGENTS.md`.
   - No `*.adir-new` files are left unmerged: `git ls-files -o -i --exclude-standard -- '*.adir-new' | grep '\.adir-new$'` (the grep drops nested clones, which `ls-files` lists as directories).
3. **Items.**
   - IDs are unique and below `Next IDs`, which has a counter for each of `T`, `B` and `R` (add `· R1` to a line that lacks one), and every `Depends on` exists, in TASKS.md or the archive.
   - No `done` item depends on a `todo` one.
   - Every `agent` item has a Size, `Touches`, tagged `Done when` outcomes (or a Repro, for bugs; a research item has a `Question:` and an `Informs:` instead of both) and a `Brief:` value. That value is an existing heading, or `-` for items that aren't about the product design.
   - Every open question an item that isn't done names, in `Done when` or `Informs:`, is still in brief › Open Questions. If it's been answered, update the item.
   - Every done research item has a note in `product/research/` whose second line starts with its ID (`grep -l "^R3 · " product/research/*.md`).
   - Items follow `.app-director/tasks.md`.
   - Report `in-progress` items claimed before today.
4. **Coverage.** Every flow in the brief is either built (a done item), planned (a todo item), or reported to the human as a gap. Only report the gaps; the human decides which ones become items.
5. **Architecture.**
   - Every significant system has a row in AGENTS.md › Architecture.
   - Every row points at something that exists in the codebase.
   - The `[ui] dirs` and `[data] dirs` in `tools/check.cfg` match the actual folder layout.
6. **Brief against reality.** For this step only, read the whole brief, not sections by heading.
   - Read `product/brief.md` from its first line to its last.
   - For every statement of state, check it against what exists: the built app, the done items (`TASKS.md` and `TASKS-archive.md`) and, where the project tracks them, the latest releases (the app's deploys, where a release is a release tag and its contents are the done items since the last tag; see `release.md`). A statement of state is a section marked later or planned, a count, a list of what exists, a line saying work waits on something, and "once X exists". Fix a stale statement as mechanical drift when the fact is settled (the item is done, the page exists). Report it to the human when the fix is a design call.
   - Check every line added to `product/decisions.md` since the last `docs: align` commit (`git log --grep="^docs: align"` for the last one; all lines if there is none) against the brief, one by one and not a sample. Each is reflected in it, and no older text contradicts it.
   - Report what was fixed and what needs the human, naming each stale statement, so the next align can tell a repeat.
7. **Setup.**
   - `bash tools/check.sh` passes.
   - The `.gitignore` and `.gitattributes` lines that install.sh adds are still there (among them `/product/ui/captures/`, `/tools/ui/node_modules/` and `/tools/ui/.auth/`).
8. **Screens** (skip it when the app has no `tools/ui/screens.mjs`). Report what is missing; none of it fails the pass. The first two need Node; without it, say they weren't checked.
   - `bash tools/ui_capture.sh --missing` lists the files in the UI folders (`tools/check.cfg` › `[ui] dirs`) that look like screens, with no catalog entry naming them as its `source` and not in `tools/ui_capture.cfg` › `[capture] skip`. With no UI folders set it says so, and nothing is listed.
   - Every `product/ui/<screen>.md` names a catalog entry that exists, and every name its Layout table lists is in the source: `node tools/ui/verify.mjs <screen> --static` prints where each is found (it exits 3 by design: no capture).
   - Every `director/ui/<screen>.excalidraw` has a spec whose recorded sha1 matches the file (`sha1sum`, or `shasum` on macOS). A newer drawing: report "drawing changed since it was processed".
   - Every item's `UI:` points at an existing spec.
   - On an upgrade, this is the check that lists the app's screens the catalog doesn't cover yet.
9. **Report.** Say what you fixed and what needs the human. Commit the fixes as `docs: align` after the human approves, naming the conflicts that need the human in the commit body so the next align can tell a repeat; during onboarding they go into the install commit instead.
10. **Recommend a reset when patching won't hold.** If a conflict you report has come up before (an earlier `docs: align` commit body names it, or `product/decisions.md` already settled it), or one conflict involves several brief principles, recommend `/drift-reset` (`drift-reset.md`) in the report instead of a patch. Never start it yourself.
