<!-- App Director · framework-owned: replaced on upgrade. -->
# TASKS.md items

Read this before adding or editing an item.

```
### T3 · Login screen validates email format · todo · S · agent
- Depends on: T1
- Touches: src/screens/LoginScreen.tsx, src/services/auth.ts, tests/auth.test.ts
- Done when: invalid email format is rejected before submit (test) · form shows inline error (demo)
- Brief: Authentication › Sign in
```

- **Heading.** It reads `ID · title · status · size · owner`, and a bug adds `· high|med|low`. New IDs (`T<n>`, `B<n>`) come from the `Next IDs` line, which you then bump. IDs are never reused.
- **Status.** `todo`, `in-progress YYYY-MM-DD` (the claim date) or `done`. "Ready" isn't stored: a `todo` item is ready when everything in `Depends on` is `done`.
- **Size.**
  - `XS`: a single value, label, copy change, or config line. No logic change and no new tests.
  - `S`: 1–2 files, a clear bug fix, or a small feature following an existing pattern.
  - `M`: 1–2 systems, or a feature that follows an established pattern.
  - `L`: 3+ systems, a new architecture concern, a stored data schema change, or a bug without a repro.
  - `XL`: a cross-cutting refactor, a complete subsystem redesign, or a change that touches most systems.

  When in doubt, pick the smaller size. Split an `L` or `XL` when you can. An item that needed more becomes `M (escalated from S)`.
- **Owner.** `agent` or `human`. Human items have size `—`.
- **`Touches`.** The files expected to change. Mark new files `(new)`.
- **`Done when`.** 1–3 observable outcomes, each tagged `(test)`, `(check)` or `(demo)` (see `rules.md` › Doing the work). Naming an open question means it gates the real behaviour.
- **`Brief:`.** The heading(s) the item implements, or `—` for items that aren't about the product design.
- **Bugs.** Instead of `Done when`, a bug has `Repro: steps → expected / actual` and `Found in:` (an acceptance check file, an item ID or `ad hoc`). It's done when the repro no longer happens.
- **`Note:`** (optional). An item paused partway through gets `- Note: <where it stands, what's next>`. Delete the note when the item is done.
- **Merge conflicts.** On a merge conflict in TASKS.md, keep both sides' items, give any duplicate ID a new number from `Next IDs`, and fix references to it.
