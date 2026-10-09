<!-- App Director · framework-owned: replaced on upgrade. -->
# Align

A consistency pass across the brief, decisions, TASKS.md, AGENTS.md and check config. Check everything below, fix what's mechanical, and list what needs the human, with a recommendation for each. Never change design.

1. **Placeholders.** No `{{…}}` left in AGENTS.md, TASKS.md, `product/` or `validation/TEMPLATE.md` (`git grep -n "{{" -- AGENTS.md TASKS.md product validation/TEMPLATE.md`). The template's flow sections may wait until the core flows are decided, but only if an item for filling them exists.
2. **Entry files.**
   - AGENTS.md points to `.app-director/rules.md`.
   - In Claude Code, CLAUDE.md contains `@AGENTS.md`.
   - No `*.adir-new` files are left unmerged: `git ls-files -o -i --exclude-standard -- '*.adir-new'`.
3. **Items.**
   - IDs are unique and below `Next IDs`, and every `Depends on` exists, in TASKS.md or the archive.
   - No `done` item depends on a `todo` one.
   - Every `agent` item has a Size, `Touches`, tagged `Done when` outcomes (or a Repro, for bugs) and a `Brief:` value. That value is an existing heading, or `-` for items that aren't about the product design.
   - Every open question an item names is still in brief › Open Questions. If it's been answered, update the item.
   - Items follow `.app-director/tasks.md`.
   - Report `in-progress` items claimed before today.
4. **Coverage.** Every flow in the brief is either built (a done item), planned (a todo item), or reported to the human as a gap. Only report the gaps; the human decides which ones become items.
5. **Architecture.**
   - Every significant system has a row in AGENTS.md › Architecture.
   - Every row points at something that exists in the codebase.
   - The `[ui] dirs` and `[data] dirs` in `tools/check.cfg` match the actual folder layout.
6. **Decisions.** Spot-check that recent lines in `product/decisions.md` are reflected in the brief, and that no older brief text contradicts them.
7. **Setup.**
   - `bash tools/check.sh` passes.
   - The `.gitignore` and `.gitattributes` lines that install.sh adds are still there.
8. **Report.** Say what you fixed and what needs the human. Commit the fixes as `docs: align` after the human approves, naming the conflicts that need the human in the commit body so the next align can tell a repeat; during onboarding they go into the install commit instead.
9. **Recommend a reset when patching won't hold.** If a conflict you report has come up before (an earlier `docs: align` commit body names it, or `product/decisions.md` already settled it), or one conflict involves several brief principles, recommend `/drift-reset` (`drift-reset.md`) in the report instead of a patch. Never start it yourself.
