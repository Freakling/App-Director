# App Director onboarding (for the AI assistant)

Follow these steps to install App Director into an app project, or upgrade it. Work from a session opened in the app's root folder. You need bash; on Windows, Git Bash.

The human makes every design and ownership decision; you gather, propose and write. Ask choices as multiple-choice questions when your tool supports them.

`$ADIR` below is the App Director folder — the folder this file is in, usually `App-Director/` next to your app.

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
   > - **Full**: does everything fast does, then re-checks all project files against the current standards — same thoroughness as a fresh install. Choose this after many versions have accumulated, for a new machine or contributor, or when you want a complete review.

   Then:
   1. Read the entries in `$ADIR/CHANGELOG.md` newer than the old version. Carry out each **Upgrade steps** section in order.
   2. If full, carry out steps 3–8 below.
   3. Run step 2 only if `bash tools/check.sh` exits 3 (fast) or run it again now (full).
   4. Summarise what changed. Go to step 9.

   Fresh installs (fresh start, existing app) always run all steps.

## 2. Install the files

Run `bash "$ADIR/install.sh" .`. Then read its report.

- **`CONFLICTS`** (`<file>.adir-new`) mean the project already had its own version of a framework file. Show the human the difference and ask which to keep, or help them merge. Delete each `.adir-new` file once it's resolved.
- **"project files kept"** means the project already had that file. In that case, bring each one into the shape of `$ADIR/project/<same file>`:
  - `CLAUDE.md` must contain the line `@AGENTS.md`, at the top.
  - `AGENTS.md` keeps its content, gains the missing sections, and gets the line pointing to `.app-director/rules.md`.
  - `TASKS.md` converts to the seed format, keeping content.

## 3. Toolchain check

Run `bash tools/setup-clone.sh`. It checks that the configured stack tool is available (node, flutter, python) and installs the pre-commit hook. Report what it printed.

Then run `bash tools/check.sh` once and keep the result. An existing app often fails at first; that's information, not a blocker. The pre-commit hook is installed at the end (step 9), so the install commit isn't blocked.

## 4. Scan the project (existing app only)

- **Layout:** what folders hold UI, logic, data, tests. Count files per folder.
- **Entry points:** the main file, router, or manifest.
- **Existing tests:** which framework, where the files live.
- **Existing docs:** README, any design documents, TODO lists.
- **`TODO`, `FIXME`, `HACK` comments**, with file and line.
- **UI files with data-layer imports:** any screen or page that directly imports from storage or API code.

## 5. Product interview (fresh) or fill brief from existing code

### Fresh start
1. **A short product interview**, in short rounds. For each question, give options with a recommendation and let the human pick:
   1. Pitch: what the app does, who it's for, and the feeling it should give.
   2. Core flows: the 3–5 things a user actually does (not screens, but actions with an outcome).
   3. Platforms and constraints: web, mobile, desktop, or a mix; offline support; auth required.
2. **Record it.** Write the answers into `product/brief.md` as the current design. Anything undecided becomes an Open Question.
3. **Seed TASKS.md:** folder layout, first passing check, first working screen for the primary flow. Each item with Size, `Touches` and tagged `Done when`.

### Existing app
1. **AGENTS.md › Architecture:** one row per significant system. Take "Owns" from public exports and module boundaries, not from guesses.
2. **product/brief.md:** fill each section from the existing code and any docs. Mark anything inferred `(inferred — please confirm)`, and turn anything unknown into an Open Question.
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

## 8. Ownership and project rules

Walk the human through the defaults. Record only the differences, in AGENTS.md › Project rules.
- The human owns product vision, design and priorities.
- The agent owns code, tests and the records.
- Commits: the agent proposes and the human approves.
- Model sizing (Claude Code only): **ask the human, and recommend on.** When on, the `builder` subagent uses Haiku for `XS` and `S` items and the session model for everything else.
- Reviews: by default after `L` and `XL` items, and after `M` items that change stored data schemas or public API contracts.

## 9. Validation template

Fill `validation/TEMPLATE.md`: replace each `{{FLOW_N}}` with one section per core flow from the brief (usually 3–5 flows). Each section gets a fixed description, a Works/Broken checkbox pair, and a notes line. Keep the wording stable: changing it makes earlier results incomparable.

If the flows aren't decided yet, leave the placeholders and add an agent item "Fill the validation template's flow sections" that depends on the core-flow question.

## 10. Verify and commit

1. Run `bash tools/check.sh` and report the result.
2. Search for `{{` with `git grep -n "{{" -- '*.md'`. Only postponed template flows may remain, and only if an item exists for them. `git ls-files -o -i --exclude-standard -- '*.adir-new'` must print nothing.
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
   - how to use it: "do the next task", "let's design…", "prepare an acceptance check", "check the docs are aligned" (in Claude Code also `/next-task`, `/design`, `/acceptance`, `/align`, `/prune`, `/release`);
   - with the Claude adapter: to restart Claude Code, because skills, hooks and permissions load at session start;
   - that every new clone needs `bash tools/setup-clone.sh`.
