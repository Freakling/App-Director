# App Director onboarding (for the AI assistant)

Follow these steps to install App Director into an app project, or upgrade it. Work from a session opened in the app's root folder. You need bash; on Windows, Git Bash.

The human makes every design and ownership decision; you gather, propose and write. Ask choices as multiple-choice questions when your tool supports them.

`$ADIR` below is the App Director folder (the folder this file is in, usually `App-Director/` next to your app).

## 1. Preconditions and mode

1. **Git.** The project must be a git repository. If it isn't, ask to run `git init`.
2. **App Director folder exclusion.** If `$ADIR` is inside the project, add its relative path to the file `git rev-parse --git-path info/exclude` names. Do it now, before any commit.
3. **Clean tree.** A new repository with files in it: commit them as they are first, so the install is one reviewable diff. Otherwise there must be no uncommitted changes (apart from the App Director folder itself); ask the human to commit or stash them first.
4. **Mode.** Tell the human which mode you detected, and let them confirm:
   - **upgrade:** `.app-director/manifest` exists.
   - **existing app:** source code and config files exist, without App Director.
   - **fresh start:** an empty folder, or a folder with only an init commit.
5. **Upgrade mode:** tell the human the version being upgraded from and to, then summarise in one sentence each what the relevant changelog entries change. Then ask:

   > **Fast or full upgrade?**
   > - **Fast** (default for routine upgrades): applies the changelog steps, which cover both framework files and any app-owned file updates. Takes a few minutes.
   > - **Full**: does everything fast does, then re-checks all project files against the current standards (same thoroughness as a fresh install). Choose this after many versions have accumulated, for a new machine or contributor, or when you want a complete review.

   Then:
   1. Read the entries in `$ADIR/CHANGELOG.md` newer than the old version. Carry out each **Upgrade steps** section in order.
   2. If full, carry out steps 3-8 below.
   3. Run step 2 only if `bash tools/check.sh` exits 3 (fast) or run it again now (full).
   4. **Screens.** If the app has a web UI, ask for the address of its dev server on this machine and write it to `tools/ui_capture.cfg` › `[web] base_url` (and `start_command`, if capture should start it). With Node available, run `bash tools/ui_capture.sh --missing` (the Screens checks of `.app-director/procedures/align.md`) and tell the human which screens the catalog doesn't cover yet. It lists them; it never fails the upgrade. Offer to add the entries now or leave them for the next item that touches a screen. An upgrade keeps the app's own `AGENTS.md` and `tools/check.cfg`; the layout lint never runs in the check.
   5. Summarise what changed. Go to step 9.

   Fresh installs (fresh start, existing app) always run all steps.

## 2. Install the files

Run `bash "$ADIR/install.sh" .`. Then read its report.

- **`CONFLICTS`** (`<file>.adir-new`) mean the project already had its own version of a framework file. Show the human the difference and ask which to keep, or help them merge. Delete each `.adir-new` file once it's resolved.
- **"project files kept"** means the project already had that file. In that case, bring each one into the shape of `$ADIR/project/<same file>`:
  - `CLAUDE.md` must contain the line `@AGENTS.md`, at the top.
  - `AGENTS.md` keeps its content, gains the missing sections, and gets the line pointing to `.app-director/rules.md`.
  - `TASKS.md` converts to the seed format, keeping content.

## 3. Toolchain check

Run `bash tools/setup-clone.sh`. It checks that the configured stack tool is available (node, flutter, python), verifies gitleaks is installed at the minimum version, and installs the pre-commit hook. Report what it printed. If gitleaks is missing, stop and tell the human which install command to use for their OS (macOS: `brew install gitleaks`; Linux: download binary from the releases page; Windows: `winget install gitleaks`).

**For existing apps only (git history scan):** run a one-time full scan of the commit history:
```
gitleaks git --redact .
```
Report every finding to the human. For each finding, state:
- Which rule matched, in which file, and at which commit.
- That any committed secret is compromised and must be rotated, even if the commit was later removed from the branch, the data may have been cloned, cached, or mirrored.
- That you will not rewrite history and will not rotate the credential. Both are the human's actions, outside this workflow.

Do not open TASKS.md items for credential rotation.

Then run `bash tools/check.sh` once and keep the result. An existing app often fails at first; that's information, not a blocker. The pre-commit hook is installed at the end (step 9), so the install commit isn't blocked.

## 4. Scan the project (existing app only)

- **Layout:** what folders hold UI, logic, data, tests. Count files per folder.
- **Entry points:** the main file, router, or manifest.
- **Existing tests:** which framework, where the files live.
- **Existing docs:** README, any design documents, TODO lists.
- **`TODO`, `FIXME`, `HACK` comments**, with file and line.
- **UI files with data-layer imports:** any screen or page that directly imports from storage or API code.

## 5. Product interview (fresh) or fill brief from existing code

### Your own product brief (fresh start and existing app; before the interview or the brief)
Every project has `product/director-brief.md`: the human's own product brief template, in their own words. It is the human's file: you read it and never edit it. `product/brief.md` stays the design record you maintain, so each fact lives in one place; the human's brief is input that stays as they wrote it.
1. **Is it filled?** It is still the template while its title reads `# Product Brief: [App Name]` and its sections hold only the prompts. If the human points to another document (notes, a spec, or a file in `director/`), read that instead.
2. **If it is blank, offer it** before the interview, as an alternative to the chat interview or an addition to it:
   - what it is: the template for describing the app, what it should be, who it's for and what it must do, in their own words;
   - where it is: `product/director-brief.md`;
   - why it helps: a written brief gives you their intent and the context behind it, adds value that a chat interview alone doesn't, and sets the stage for later development, since every design session and build starts from it;
   - when: it can be filled before onboarding, now (you wait), or later, for a new app or one already underway; and the interview works without it.

   Ask which they prefer: fill it now, interview only, or both (interview first, brief later). Never fill it in for them. If they fill it later, the next session reads it as below.
3. **If it is filled, read it first.**
   - Fresh start: take the interview's answers from it (step 1 of Fresh start below). Show each answer taken, marked `(from your brief)`, and ask only what it leaves open. An answer you worked out from the brief without it saying so is `(inferred, please confirm)`.
   - Existing app: read it with the existing documents and the code, and use it to build the initial assessment: Architecture rows, `product/brief.md` sections and the first TASKS.md items. Mark each statement it supplied `(from your brief)` and each you inferred `(inferred, please confirm)`.
   - Both: where the brief and the code or the earlier docs disagree, say so and let the human decide.
4. **Record it.** Write the `product/brief.md` sections from it, and a `product/decisions.md` line for each decision (`why: from your brief` when that is the reason). Anything the brief leaves undecided becomes an Open Question (`Q<n>`). Don't copy the brief wholesale into `product/brief.md`; write the current design in the brief's own sections.
5. **Upgrade.** On an upgrade the installer adds `product/director-brief.md` when it is missing; offer it as above. Later, when the human says the brief changed, read it again and bring `product/brief.md` in line, marking what you inferred.

### Fresh start
1. **A short product interview**, in short rounds, after reading the human's brief if they filled one (above): ask only what it leaves open, and confirm what you took from it. For each question, give options with a recommendation and let the human pick:
   1. Pitch: what the app does, who it's for, and the feeling it should give.
   2. Core flows: the 3-5 things a user actually does (not screens, but actions with an outcome).
   3. Platforms and constraints: web, mobile, desktop, or a mix; offline support; auth required.
2. **Record it.** Write the answers into `product/brief.md` as the current design. Anything undecided becomes an Open Question.
3. **Seed TASKS.md:** folder layout, first passing check, first working screen for the primary flow. Each item with Size, `Touches` and tagged `Done when`.

### Existing app
1. **AGENTS.md › Architecture:** one row per significant system. Take "Owns" from public exports and module boundaries, not from guesses.
2. **product/brief.md:** fill each section from the existing code, any docs, and the human's own brief if they filled one (above). Mark anything inferred `(inferred, please confirm)` and anything the brief supplied `(from your brief)`, and turn anything unknown into an Open Question.
3. **TASKS.md:** turn TODOs, known bugs and the human's priorities into items.
4. **UI files that break the layer rule.** Set `tools/check.cfg` › `[ui] dirs` to the UI folders. Each file that imports from data-layer folders directly gets its own `M` item "Decouple: <file>".
5. **Check failures** from step 3 become the first items. Crashes or data-loss bugs are `high`.

## 6. Choose stack

Ask the human which stack the project uses (or will use):
- **TypeScript** (React, React Native, Node): the check runs `tsc`, `eslint` and `vitest`/`jest`.
- **Flutter**: the check runs `flutter analyze` and `flutter test`.
- **Python**: the check runs `pyright`/`mypy` and `pytest`.
- **None / other**: only the UI purity and secrets checks run; write `tools/check.local.sh` for anything custom.

Record the answer in `tools/check.cfg` › `[project] stack`. Also set `[ui] dirs` and `[data] dirs` (see step 7).

## 7. Project facts

Fill in `AGENTS.md`:
- **Name and pitch:** one sentence.
- **Project facts:** stack, platforms, storage, API.
- **Layout table:** the real folders. UI layer (screens, pages, components), Logic layer (services, hooks, stores), Data layer (api, repositories, storage). Delete rows that don't apply.
- **Architecture table:** one row per significant system (from step 5).

Fill in `tools/check.cfg`:
- `[ui] dirs`: space-separated list of UI-layer folders (e.g. `src/screens src/pages src/components`).
- `[data] dirs`: space-separated list of data-layer folders (e.g. `src/api src/repositories src/storage`).
- `[scan] skip`: third-party folders, generated code (e.g. `node_modules dist build .dart_tool`).

Fill in `tools/ui_capture.cfg` › `[web]` when the app has a web UI (Flutter web included): `base_url`, the address of its dev or test server on this machine (such as `http://localhost:5173`), and `start_command` if capture should start it. Leave `base_url` empty for a native Flutter, mobile or desktop app: capture isn't available for those yet. The catalog (`tools/ui/screens.mjs`) starts with the root route; capture needs Node 18 and, once per clone, `cd tools/ui && npm install && npx playwright install chromium`. Offer that install; it is never needed for the check.

## 8. Ownership and project rules

### Work-area ownership interview
For each area below, state the default and ask the human whether they want to own it. Record the result in AGENTS.md › Ownership (create that section now with a table). A human-owned area means the agent uses placeholders when it needs something from there; it never makes the real thing.

| Area | Default | Agent placeholder when human owns it |
|---|---|---|
| **Frontend / UI code** | agent | minimal functional component, commented for redesign |
| **UI / screen layout** | agent, or `director designs (director/ui/), agent builds` | minimal functional component, commented for redesign |
| **Business logic / services** | agent | stub service returning hard-coded data with `// PLACEHOLDER` comment |
| **Backend / API** | agent | stub endpoint returning mock data, documented |
| **Database schema / migrations** | agent | schema with `// PLACEHOLDER` on new fields; migration stub |
| **Visual design / assets** | human | `<img src="placeholder.svg" alt="[PLACEHOLDER: describe asset]" />` or equivalent |
| **Copy / user-facing text** | agent | `"[PLACEHOLDER: describe the text]"` string constant |
| **Testing** | agent | tests written for every `(test)` outcome |
| **Infrastructure / deployment** | human | config stub with `# PLACEHOLDER` on values the human must set |

### Designing screens by drawing
Ask once, in the UI / screen layout row of the table above: do they want to design screens by drawing over screenshots of the running app (`/ui-design`; free Excalidraw, no account)?
- **Yes:** the row becomes `director designs (director/ui/), agent builds`, with the same placeholder. Offer `director/` (below) with `director/ui/`, and tell them the loop: `/ui-design capture` writes a starter drawing per screen, they draw and save it as `director/ui/<screen>.excalidraw`, and `/ui-design process <screen>` turns it into the screen's spec.
- **No:** the row stays `agent` and nothing else changes. Capture, the layout lint and the catalog still work. No open question and no item is added: drawing is optional, never a prerequisite.

### Protected workspace
If the human owns any area, or wants a space the agent will never touch: offer to create `director/`. The agent reads files there for context (mockups, brand assets, reference images, notes, third-party API specs) but never creates, modifies or deletes anything inside it.

If they want it:
1. Create `director/` and `director/README.md` explaining what it is and that the agent won't touch it.
2. Ask whether to gitignore it (for large binary assets) or commit it (for design docs and notes). Update `.gitignore` accordingly.
3. Add a row to AGENTS.md › Ownership: `director/ (human's workspace, read-only for the agent)`.
4. If they want to design screens by drawing over screenshots (`/ui-design`), also create `director/ui/`.

### Workflow defaults
- Commits: the agent proposes and the human approves.
- Model sizing: **recommend on.** Follow `refresh-model-sizing.md`: it checks whether the assistant supports per-subagent model selection, presents the defaults, asks the director to confirm or adjust, and writes the five-entry block. If the assistant can't select models per subagent, it says so and skips the block. The director can run `/refresh-model-sizing` at any time to update the entries.
- Reviews: by default after `L` and `XL` items, and after `M` items that change stored data schemas or public API contracts.

## 9. Validation template

Fill `validation/TEMPLATE.md`: replace each `{{FLOW_N}}` with one section per core flow from the brief (usually 3-5 flows). Each section gets a fixed description, a Works/Broken checkbox pair, and a notes line. Keep the wording stable: changing it makes earlier results incomparable.

If the flows aren't decided yet, leave the placeholders and add an agent item "Fill the validation template's flow sections" that depends on the core-flow question.

## 10. Verify and commit

1. Run `bash tools/check.sh` and report the result.
2. Search for `{{` with `git grep -n "{{" -- '*.md'`. Only postponed template flows may remain, and only if an item exists for them. `git ls-files -o -i --exclude-standard -- '*.adir-new' | grep '\.adir-new$'` must print nothing (the grep drops nested clones, which `ls-files` lists as directories).
3. Walk through the checks in `.app-director/procedures/align.md`. Its fixes go into the install commit.
4. List every file created, changed or deleted (`git status`).
5. **Commit it all in one commit, after the human approves.**
   - Stage the files: `git add` only the files created or changed.
   - Mark scripts executable: `git add --chmod=+x -- tools/*.sh .githooks/pre-commit .claude/hooks/*.sh`.
   - Use the message `chore: install App Director <version>` (or `upgrade to`).
6. **The pre-commit hook.**
   - If the check passes, run `bash tools/setup-clone.sh`, which installs it.
   - If the check fails, leave the hook off and add an item: "Install the pre-commit hook once the check passes (`bash tools/setup-clone.sh`)".
7. **Tell the human:**
   - what needs their confirmation (inferred decisions, open questions);
   - how to use it: "do the next task", "let's design…", "prepare an acceptance check", "check the docs are aligned", "research which library fits…", "capture the screens" (in Claude Code also `/next-task`, `/design`, `/research`, `/ui-design`, `/acceptance`, `/align`, `/drift-reset`, `/prune`, `/release`);
   - align often, and reset when you have to: a drift reset ("run a design drift reset") is for when the same conflict keeps coming back, and only they start one;
   - with the Claude adapter: to restart Claude Code, because skills, hooks and permissions load at session start;
   - that every new clone needs `bash tools/setup-clone.sh`.
