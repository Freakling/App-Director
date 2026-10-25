<!-- App Director · framework-owned: replaced on upgrade. -->
# Review

Review a finished, uncommitted change against its TASKS.md item and the rules, with fresh eyes. You didn't write this change. **Read only**: never edit files or run commands that change anything.

You're given:
- the item ID;
- the builder's report;
- the check result;
- the diff, including new files, in `.app-director/state/review.diff`.

The records (TASKS.md, AGENTS.md) are already updated in it. Read the item, the diff and the code the diff calls into. That's enough to judge correctness; don't read the whole project.

For an item with `UI:`, also read the screen spec, `product/ui/captures/<id>.drawing.json`, the latest `<id>.compare@<W>x<H>.png` and `<id>.lint.txt` (their `.elements.json` and the table `bash tools/ui_capture.sh <id> --verify` prints, if you can't view images). Don't capture yourself: this review is read only. If the builder's report has no `Screen:` line, or the compare image is older than the screen's files, say so as a finding.

Check, most important first:
1. **Correctness.** Does each `(test)` and `(check)` outcome hold, and is each `(demo)` outcome implemented? Look at edge cases, empty and null states, missing error handling, and data that doesn't round-trip correctly.
2. **Rules** (`.app-director/rules.md`):
   - No imports from data-layer folders in UI-layer files.
   - No secrets, API keys, passwords, or hard-coded credentials in source.
   - Code is statically typed; no casts that hide a type error.
   - No hard-coded IDs, user data, or environment-specific values in source.
3. **OWASP baseline** (`.app-director/rules.md` › Architecture defaults). For each change that handles input, authentication, authorization, sessions, secrets, data access, file or network access, or dependencies, check it against the OWASP Top 10 (2025), and the OWASP API Security Top 10 (2023) when it serves an API. Report each finding with the OWASP item it falls under (such as Injection). A deviation with no accepted decision in `product/decisions.md` that names the item is a finding; one with it is not. The check covers only secrets and UI purity, so a clean check says nothing about the rest.
4. **Screens** (an item with `UI:`). Does the built screen match its spec: every element named by its `data-testid`, where the spec puts it (within `[verify] tolerance_pct`), reachable by keyboard, lint-clean at every configured size? Does it use flex or grid rather than pixel positions? Report each deviation ranked with the other findings, with the element, what the spec says and what the capture shows.
5. **Scope.** Changed files missing from `Touches`, unless the report's `Touches:` line explains them. Listed files left untouched (is the work incomplete?), and unrelated changes mixed in.
6. **Records.** AGENTS.md › Architecture matches the report's `Systems:` line, and every `(test)` outcome has a test.
7. **Simpler.** Code that could be deleted beats adding a safeguard.

Report findings most severe first. Give each one `file:line`, what's wrong, a concrete way it fails, and whether it's in the code or the records. Skip style remarks while correctness problems remain. If there's nothing to report, say "no findings". If the item was clearly sized wrong, say so.
