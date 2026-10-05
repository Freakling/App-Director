<!-- App Director · framework-owned: replaced on upgrade. -->
# Acceptance check

Prepare or process an acceptance check: a human walks through the running app, flow by flow, and ticks whether each built behaviour works. `(test)` outcomes are proven by tests and `(check)` outcomes by commands the agent ran, so an acceptance check covers the rest: `(demo)` outcomes, and bug fixes that have no regression test.

The request is `prepare` (the default), `process`, or `all` (a full regression round).

## Prepare
1. Run `bash tools/check.sh`. If it fails, say so and stop: the build isn't worth checking by hand.
2. Collect the `(demo)` outcomes of `done` items in TASKS.md and TASKS-archive.md.
3. Keep those that haven't been ticked (Works or Broken) in an earlier `validation/*-acceptance.md`. Add done bugs without a regression test whose fix hasn't been ticked yet, with the outcome "the repro no longer happens".
4. **`all`:** keep every `(demo)` outcome, plus one item for each core flow in the brief that no done item covers. That second part picks up behaviour the app had before App Director.
5. Write `validation/YYYY-MM-DD-acceptance.md`:
   ```
   # Acceptance check YYYY-MM-DD
   **Build:** <git rev-parse --short HEAD> · **Environment:** <local | staging | prod> · **Covers:** T12, T14, B3
   Tick one box per item; leave both empty if you didn't check it. Say what went wrong in Notes.

   ## Sign in
   - **T12** Signing in with a valid account opens the home screen. *How:* use the test account; do not use a real user account.
     - [ ] Works   - [ ] Broken / missing
     - Notes:
   ```
   - Group items by brief section (core flow).
   - Write each item as what the user sees, not as an implementation detail.
   - Add a *How:* hint: which environment, which test account, any prerequisite state.
   - Leave nothing for the tester to copy or format.

## Process
1. **Works:** nothing to record; the ticked file is the record.
2. **Broken:** make a `B` item.
   - Take the repro from the notes, and set `Found in:` to the file.
   - Judge the severity from the notes: `high` if it loses data, blocks a core flow, or crashes; `low` if it's cosmetic; `med` otherwise.
   - If the notes say the behaviour itself should change, it's a design question instead: offer options following `design.md`, or add an Open Question.
3. **Not ticked:** leave it. It comes back in the next round.
4. **Finish:** under the header, add `**Processed:** YYYY-MM-DD → B7, Q4`. Commit the file and the new items as `docs: process acceptance check YYYY-MM-DD` after the human approves.
