# Changelog

Each entry lists what changed. **Upgrade steps** at the end of an entry cover both framework fixes and app-owned file updates (AGENTS.md, TASKS.md, product/brief.md), so every project reaches the same capability level after upgrading. Onboarding carries them out; the fast upgrade mode runs only these steps, and the full mode also re-checks everything as if newly installed.

## Unreleased

- **Sessions that build at the same time each get their own git worktree.** The sessions rule in `rules.md` now applies to any two sessions that build, not only design and coding, and says why: a shared checkout lets one session's half-written files fail the other's check and Stop hook, and both queue on the same build artefacts. The commands stay the same (`git worktree add`, then `bash tools/setup-clone.sh` there). The README's day-to-day section points to the rule, and the selftest checks that it names the rule and its reason.
  - **Upgrade steps:** none. The rules file is framework-owned and arrives on upgrade.

## 1.7.1 (2026-10-18)

- **An install from a development snapshot says so.** An install from a source whose `CHANGELOG.md` has entries under `## Unreleased` records `# app-director <version> + unreleased (<commit>)` as the manifest's first line, and its closing lines say it is a development snapshot, not a release, with where the latest release is listed. `VERSION` stays at the last release until a release is cut, so the manifest tells the truth. The commit comes from the source's git checkout (a release zip has none) and goes on a `# source <commit>` line, which release installs get too. An install from a release records the plain version. Upgrades read the old version without the suffix, so an upgrade from a snapshot works.
  - **Upgrade steps:** none needed. The next upgrade rewrites the manifest.

## 1.7.0 (2026-10-16)

- **New: your own product brief, a template to fill in, in your own words** (`product/director-brief.md`). Every app gets the template, for a new app or one already underway. Onboarding offers it before the interview, as an alternative to the chat interview or an addition to it, and says why it helps: a written brief gives the agent your intent and its context, and sets the stage for the design sessions and builds that follow. Fill it before onboarding, during it or later.
  - **How it relates to the brief.** `product/brief.md` stays the design record the agent maintains. Your brief is input that stays as you wrote it: the agent reads it, never edits it, and writes the current design into the brief's own sections, so each fact lives in one place.
  - **Onboarding reads a filled one first.** For a new app it takes the interview's answers from it and asks only what it leaves open. For an existing app it builds the initial assessment (Architecture rows, brief sections, first items) from it together with the code and the existing documents. It marks what it took `(from your brief)` and what it worked out itself `(inferred, please confirm)`, records decisions with `why: from your brief`, and turns the undecided into open questions. Tell the agent when the brief changes and it brings `product/brief.md` in line.
  - **Structure.** The template is the director's own: executive summary, problem statement, goals and metrics, audience, value proposition and features, user experience, technical and operations considerations, launch strategy, risks and assumptions, and open questions. The example (`examples/todo-web`) carries the blank template too.
  - **Selftest** checks that the seed and the example copy match and keep the director's structure, that onboarding and the README present it, and that a new app and an upgraded app receive it.
  - **Upgrade steps:** the installer adds `product/director-brief.md` when the app doesn't have it (project seeds are copied once and never overwritten). After the upgrade, tell the human it exists, where, and why writing it helps; if they fill it, read it as `ONBOARDING.md` › "Your own product brief" describes and bring `product/brief.md` in line, marking what you inferred. Nothing else in the app changes.
- **The repository ignores OS metadata files.** `.gitignore` keeps `.DS_Store`, `Thumbs.db`, `desktop.ini` and `__MACOSX/` out of the repository, as the Claude plugin directory's scanner requires. No upgrade steps: the file belongs to the App Director repository, not to apps.
- **Fix: the protected-space guard blocks absolute paths.** `framework/.claude/hooks/guard-protected.sh` matched `file_path` only as written, so a write to `director/` sent as an absolute path (`<project>/director/x`, or Windows `C:\...\director\x`) got through. The hook now resolves the path against the project root (`$CLAUDE_PROJECT_DIR`, else the current directory) before matching: Windows, Git Bash and POSIX forms, `..` segments and case-insensitive matching on Windows. Paths outside the project root, and folders named `director` elsewhere in it, are still allowed. The selftest covers each form.
  - **Upgrade steps:** none. The hook is framework-owned and arrives on upgrade.
- **Align checks the brief against reality.** `align.md`'s item 6 is now "Brief against reality", in place of the Decisions spot-check. It reads the whole brief, checks every statement of state (a section marked later or planned, a count, a list of what exists, a line saying work waits on something, "once X exists") against the built app, the done items and the latest releases, and checks every decision line since the last `docs: align` commit one by one, not a sample. Mechanical drift gets fixed; design calls are reported with the stale statement named. The numbering of the other items is unchanged.
  - **Upgrade steps:** none. The procedure is framework-owned and arrives on upgrade.
- **The README says how to update the plugin.** The Install section gets an Upgrade part, as Godot Director's and SaaSAllTheThings' READMEs have: `/plugin marketplace update app-director`, then `/plugin update app-director@app-director`, then a restart and a new session in the app, where `/app-director:app-director` upgrades it.
  - **Upgrade steps:** none. The README belongs to the App Director repository, not to apps.
- **The README says "an agreed placeholder".** Its ownership line says human-owned areas get an agreed placeholder instead of generated content, in place of "a documented placeholder policy". No upgrade steps: the README belongs to the App Director repository, not to apps.

## 1.6.0 (2026-10-16)

- **New: `/research`, the research assistant** (`.app-director/procedures/research.md`). When a design question depends on facts nobody has checked, or you ask for research, a read-only `researcher` subagent looks into it in a fresh context and reports a note. It informs; you decide: its recommendation is one option shown with its reason, and it never records a decision, edits the brief or `product/decisions.md`, answers an Open Question, or asks you anything. It states its assumptions in the note instead.
  - **Research is a task type.** Research items get their own IDs, `R<n>`, drawn from the `Next IDs` line like bugs. Instead of `Done when` they have `Question:` and, when they feed an open question, `Informs: Q<n>`. They are sized like any item, and the size picks the model. An item is done when its note exists.
  - **Two ways to start.** On the fly: a design session delegates a complex question, or you run `/research <question>`, and the item is created and run at once. For later: queue the item, and list it under `Depends on` of the tasks that need its findings. A task that needs the decision stays gated by the open question itself.
  - **The note.** One dated file per topic in `product/research/`, written by the orchestrator (the researcher writes no file): conclusion first, then options, a recommendation, sources with a tier and a confidence, and the date the claims were verified. A design session lists the notes on its topic before presenting options, and a decision that followed research ends its `product/decisions.md` line with the note's path.
  - **`research-domain.md`** adds what the researcher needs for apps: stacks and libraries (how a library is judged), licences, and app-store and platform requirements.
  - **`/next-task`** hands research items to the `researcher` instead of the builder. Research changes no code, so no check runs and no review follows; the note and the records are committed together. A run goes on after a research item and lists the questions now ready for a design call.
  - **`/align`** checks the `R` counter, the fields of research items, and that every done research item has a note.
  - **Web access applies to every session.** `settings.json` now allows `WebSearch` and `WebFetch`. Claude Code can't scope a permission to one subagent, so the allow covers every session in the app, not only the researcher; the researcher's own tool list (`Read, Grep, Glob, WebSearch, WebFetch`) is what keeps it read-only. The evidence rules keep confidential project text out of public search queries. To keep them asking, add both to the `ask` list in `.claude/settings.local.json`.
  - **`product/research/README.md`** seeds the note folder. The README, ONBOARDING.md, the example and the behaviour scenarios list the command, and `selftest.sh` checks that the files exist, that the researcher has only its read, search and fetch tools, that settings allow web search and fetch, that the procedures are wired to it, and that a commit with only a note skips the project check.

**Upgrade steps:**
1. In `TASKS.md`, add an `R` counter to the `Next IDs` line: `**Next IDs:** T<n> · B<n> · R1`.
2. Create `product/research/` with the seed `README.md` (the installer copies it when missing).
3. Restart Claude Code so the `/research` skill, the `researcher` agent and the changed `settings.json` load.

## 1.5.0 (2026-10-15)

- **The manual install clones the latest release.** The README's manual option cloned `main`, the integration branch, so a manual install got unreleased changes. It now clones the release tag (`git clone --branch <tag> --depth 1`), and says the tag is `v` followed by the version and where the latest one is listed. The manual upgrade wording still holds: put the new folder in and ask for ONBOARDING.md again.
- **The selftest expects setup-clone's refusal of gitleaks 8.19.0.** `tools/setup-clone.sh` refuses gitleaks 8.19.0 before it installs the pre-commit hook. The selftest's check for the installed hook now expects that refusal (exit 3, no hook) when the gitleaks on PATH is 8.19.0, and still expects the hook otherwise. A stand-in gitleaks 8.19.0 test proves the refusal in a fresh repository on any machine. The selftest's passthrough stand-in had hidden a real 8.19.0 from the check, so the check never reached the refusal.
- **Every install path gets the latest release.** The skill, the fetch script and the Claude Code plugin now install the release tagged `v<version>`; `main` is where changes are integrated, not what people install. Both `SKILL.md` files clone `--branch v<version>` into a fresh temporary folder, the way SaaSAllTheThings does, and delete it after onboarding. They no longer call `scripts/fetch-app-director.sh`, whose path (`${CLAUDE_PLUGIN_ROOT}/scripts/...`) doesn't exist outside the plugin. The fetch script fetches its own release tag, and a folder left by an earlier run moves to it instead of pulling `main`. The marketplace names the plugin as a `github` source with `ref` `v<version>`, because Claude Code's relative-path source (`./`) can't pin a ref. The root `SKILL.md` and `package.json` said 1.0.0, and `skills/app-director/SKILL.md` carried no version; all now follow `VERSION`. `CLAUDE.md` › For a release lists every file that carries the version and says each release is tagged `v<version>` once its pull request is merged. `selftest.sh` checks that they all agree with `VERSION`, and that the fetch script moves a reused folder to a new tag (a local repository stands in for GitHub).
- **The marketplace's `owner` is an object.** `.claude-plugin/marketplace.json` had `"owner": "Freakling"`, which `claude plugin validate` rejects (`expected object, received string`). It is now `{ "name": "Freakling" }`, as in the other two frameworks.

**Upgrade steps:** None required for existing installs.

## 1.4.0 (2026-10-15)

- **The fast check notices a removed or changed gitleaks.** `tools/check.sh --if-changed` repeated the last result while the files were unchanged, so a gitleaks that was removed, or changed (such as to 8.19.0, which can't scan), went unnoticed until a file changed. The cached result now records gitleaks's version, or that it's missing, and a change to either runs the secrets step again. The fast path still makes one `gitleaks version` call. `selftest.sh` checks a reused pass, a changed version, the 8.19.0 downgrade, a removed gitleaks and a repeated failure with a stand-in gitleaks.
- **The secrets check says when gitleaks can't scan.** gitleaks 8.19.0 fails every scan command, which the check read as credentials found on a clean tree. `tools/check.sh` now exits 3 and says that gitleaks couldn't scan, with its own error line, and asks for gitleaks 8.19.1 or later. Any scan that fails with no finding in its report is reported that way, never as a finding. The minimum stays 8.18.0. `selftest.sh` checks 8.19.0 and a scan error with stand-in gitleaks binaries, and skips its real-gitleaks checks on 8.19.0.
- **setup-clone.sh and the README no longer accept gitleaks 8.19.0.** gitleaks 8.19.0 is above the 8.18.0 minimum but can't scan at all (every command fails), so `setup-clone.sh` reported it as found and installed the pre-commit hook on it. It now exits 3 with the hint "gitleaks 8.19.0 can't scan (every command fails). Upgrade to 8.19.1 or later.", and the README's requirement names 8.19.0 as the exception. The minimum stays 8.18.0.
- **The upgrade-file check ignores nested clones.** `git ls-files` lists a nested repository in an ignored folder (such as a clone in `work/`) as a directory, which blocked every commit while no upgrade file existed. The pre-commit hook, the `/align` check and onboarding now keep only paths that end in `.adir-new`, so a real upgrade file still blocks the commit.
- **selftest.sh** checks that a nested clone in an ignored folder doesn't block a commit, and that a real upgrade file still does.
- **A run can also be asked for as "grab tasks until you're blocked".** `next-task.md` (the request list and step 7), the `/next-task` skill description, the README's day-to-day table and the behaviour scenarios now name it next to "the next N tasks" and "work through the queue". Each task in a run commits without pausing; the run stops when an item is blocked on the human, a build fails, or the human declines a commit. A single `/next-task` still pauses for approval. `git commit` is already allowed in `settings.json`; pushing and deploying keep asking.
- **The secrets check names the file with a finding, and works with gitleaks 8.18 and 8.30.** The check printed only the report path, so the file with a secret wasn't named; it now lists each file with a finding (paths only; the values stay redacted). gitleaks 8.18 has no `dir` command, so the check scans with `gitleaks detect --no-git` there and with `gitleaks dir` from 8.19.1; 8.19.0 can't scan at all. `selftest.sh` checks both scan commands with a test double, and reads the allowlisted fingerprint from the report's indented `"Fingerprint": "..."` line, which gitleaks writes.
- **The pre-commit hook names the file with a secret.** When gitleaks finds a secret in the staged changes, the hook lists each file with a finding, as the secrets check does (paths only; the values stay redacted), and gives the report's path for the Fingerprint. A scan that can't run is no longer reported as a finding: gitleaks 8.19.0 can't scan at all, so the hook says so and asks for 8.19.1 or later. The staged scan (`gitleaks protect --staged --report-path`) works on the gitleaks releases checked from 8.18.0 to 8.30.1, all but 8.19.0. `selftest.sh` checks the blocked commit and the file name with a stand-in gitleaks, and with the real one when it's installed.

**Upgrade steps:** None required for existing installs. The framework files arrive on upgrade; restart Claude Code so the changed skill description loads.

## 1.3.1 (2026-10-09)

- **README: Part of Director-Driven Development.** A new section after the opening description links the Director-Driven Development article and the three frameworks built on it (Godot-Director, App-Director, SaaSAllTheThings).

**Upgrade steps:** None required for existing installs.

## 1.3.0 (2026-10-09)

- **`/drift-reset`: the design drift reset.** A new procedure (`drift-reset.md`) and Claude Code skill for when a brief principle has been built more than one way and patching would make it worse. Only the human starts it; the skill is not model-invocable. Steps: analyse the app as built with read-only `reviewer` subagents, one per Architecture area, including logic sitting in UI files (`as-built.md`); map each principle's interpretations as consistent, divergent or contradictory (`interpretations.md`); raise a design call per divergent or contradictory principle and revise the brief, archiving the old one (`brief-before.md`), or write `brief-proposal.md` when the brief is human-owned or hook-protected; plan the rebuild as sized TASKS.md items with exact `Touches` (`rebuild.md`). `/drift-reset postmortem` checks the rebuilt app against the recorded failure modes (`postmortem.md`) and proposes new check rules as design calls. Everything lands in `product/resets/YYYY-MM-DD/`, which is never deleted. The reset writes no application code, uses no destructive git commands, and recommends its own branch.
- **`/align` recommends a reset.** Align now names the conflicts it reports in its commit body, and recommends `/drift-reset` when a conflict comes back or one conflict involves several principles.
- **Reviewer agent** also runs drift-reset area analyses, still read-only.
- **rules.md routing** now lists `drift-reset.md` and the previously missing `refresh-model-sizing.md`. The one-place table gets a row for reset folders.
- **README, ONBOARDING:** `/drift-reset` added next to `/align`: align often, reset when you have to.
- **selftest.sh** checks that every procedure is routed in `rules.md`.

**Upgrade steps:** None required. The new procedure, skill and reviewer change arrive with the framework files on upgrade. Restart Claude Code afterwards so `/drift-reset` loads.

## 1.2.3 (2026-10-09)

- **Design sessions show context before options.** `design.md` › Prepare now has a step that surfaces the relevant brief sections and related `product/decisions.md` lines to the human director before any options are presented. The assistant quotes or paraphrases only the sections the topic touches; if neither file has anything relevant, it says so in one sentence.

**Upgrade steps:** None required for existing installs.

## 1.2.2 (2026-10-07)

- **No en or em dashes.** All en dashes (U+2013) and em dashes (U+2014) replaced across every tracked file: ranges use a hyphen, explanations use a colon, asides use commas or parentheses, and joined clauses use a semicolon or period. Affected files: README.md, ONBOARDING.md, CHANGELOG.md, CLAUDE.md, PRIVACY.md, SKILL.md, skills/, framework/ (rules, procedures, tasks, hooks, skills, check.sh, setup-clone.sh), project/ seeds, examples/.
- **Style rule added to CLAUDE.md.** The no-en/em-dash rule now appears in CLAUDE.md and covers release notes.
- **selftest.sh regression check.** `git grep -P '[\x{2013}\x{2014}]'` now runs as part of the framework tests; any match fails the selftest.

**Upgrade steps:** None required for existing installs.

## 1.2.1 (2026-10-07)

- **Canonical model sizing.** `rules.md` now defines the five tiers by capability (XS/S smallest capable, M balanced, L/XL most capable) so non-Claude assistants can map them to their own models. No model IDs in `rules.md`.
- **Generalized escalation rule.** A failed build retries once on the next size's model (XS→S, S→M, M→L, L→XL). An XL failure stops and comes to the director. Previously only XS/S escalated to M. Added to both `next-task.md` and `rules.md`.
- **Onboarding writes the model sizing block.** Step 7 now follows `refresh-model-sizing.md` directly: it checks capability, presents the five-entry defaults, asks the director to confirm or adjust, and writes the block. The "Claude Code only" qualifier is removed; any assistant that supports per-subagent model selection can use it.
- **Single source of truth for model IDs.** Default model IDs (`claude-haiku-4-5-20251001`, `claude-sonnet-5-5`, `claude-opus-5-5`) live only in `refresh-model-sizing.md`. README and ONBOARDING use human-readable tier names (Haiku, Sonnet, Opus) and reference the procedure.
- **README model sizing paragraph updated.** The verbatim paragraph in Context and token use now mentions escalation and the correct description of `/refresh-model-sizing`.
- **selftest.sh** asserts that model IDs appear only in `refresh-model-sizing.md`.

**Upgrade steps:** Run `/refresh-model-sizing` (or ask your assistant) to update the model sizing block in AGENTS.md › Project rules to the five-entry format.

## 1.2.0 (2026-10-07)

- **Gitleaks replaces regex secrets scan.** `check.sh` step 2 now runs `gitleaks dir --redact` on the working tree. Findings are written (redacted) to `.app-director/state/gitleaks.json`. If gitleaks is missing or below the minimum version, the check exits 3; it never falls back to regex and never passes silently.
- **Staged-changes scan in pre-commit hook.** `.githooks/pre-commit` now also runs `gitleaks protect --staged --redact` on staged changes, so a secret is caught before it enters history.
- **gitleaks version check in setup-clone.sh.** `bash tools/setup-clone.sh` now verifies gitleaks ≥ minimum version and stops with per-OS install instructions if it's missing.
- **Minimum version pinned in check.cfg.** `tools/check.cfg [gitleaks] min-version = 8.18.0`. Raise it after testing with a newer release.
- **Project-owned gitleaks config seeded.** `install.sh` seeds `.gitleaks.toml` (extends the default ruleset) and `.gitleaksignore` (empty allowlist with guidance) on first install. Both are project-owned and never overwritten on upgrade.
- **Allowlist rule in rules.md.** The AI may propose a `.gitleaksignore` fingerprint entry and a `product/decisions.md` reason, but never adds either without the human's approval.
- **Onboarding history scan for existing apps.** Step 3 now runs `gitleaks git --redact .` for existing apps and reports findings to the human, noting that any committed secret is compromised and must be rotated by the human.
- **settings.json deny rules.** `Read(.env)`, `Read(**/.env)`, `Read(*.pem)`, `Read(**/*.pem)`, `Read(*.key)`, `Read(**/*.key)` are denied. `.env.example` is not denied.
- **guard-commands.sh blocks .env reads.** Shell commands reading `.env`, `*.pem`, or `*.key` directly (`cat`, `head`, `tail`, `less`, `more`) are blocked. This is a guardrail, not a guarantee; indirect reads are not detected.
- **selftest.sh updated.** Secrets tests now use gitleaks (conditional skip if gitleaks is absent). New tests: planted secret fails, secret value not in output or state, missing gitleaks exits 3, allowlisted fingerprint passes. Stop-check and pre-commit tests use a fake passthrough gitleaks when the real one is absent.

**Upgrade steps:**
1. Install gitleaks ≥ 8.18.0: macOS `brew install gitleaks`; Linux download binary from [releases](https://github.com/gitleaks/gitleaks/releases); Windows `winget install gitleaks`.
2. Run `bash tools/setup-clone.sh` in every clone to verify the version and reinstall the pre-commit hook.
3. In `tools/check.cfg`, add:
   ```ini
   [gitleaks]
   min-version = 8.18.0
   ```
4. The new project-owned seeds (`.gitleaks.toml`, `.gitleaksignore`) will be created by `install.sh` if they don't exist yet.

## 1.1.1 (2026-10-07)

- **Canonical assistant-support wording.** All claims about AI assistant support now follow one position: "Designed to work with any AI coding assistant that reads `AGENTS.md`. Built and tested on Claude Code; other assistants are untested." The hedge "in theory" and the names Cursor and Codex are removed.
- **Capability note added to README.** Under the install options, a new paragraph states which features are tool-neutral (rules, procedures, check, pre-commit hook) and which require subagents and hooks (fresh-context builds, reviewer, model sizing, guard hooks).
- **npx skill description updated.** Option 1 now states only what the command does: installs the skill for the assistant you choose in the prompt; in Claude Code it becomes the `/app-director` slash command.
- **CLAUDE.md release rule updated.** The "How to install" section in releases must now open with the support position before listing install paths.

**Upgrade steps:** None required for existing installs.

## 1.1.0 (2026-10-07)

- **LICENSE.** Root `LICENSE` added (MIT, copyright 2026 Vikingur Saemundsson). `framework/.app-director/LICENSE` (the copy installed into apps) is identical; `selftest.sh` enforces this.
- **README: Privacy and License.** License section now opens with a Privacy line linking `PRIVACY.md`, matching Godot-Director.
- **`examples/todo-web/`.** Minimal worked example web app: AGENTS.md, TASKS.md, brief, decisions, source in `src/ui/`, `src/services/`, `src/store/`. Uses the `none` stack so no compiler or test runner is needed. Used by `selftest.sh`.
- **`examples/scenarios.md`.** Nine prompts that verify workflow behaviour (options-not-guesses, autonomous commit, guard hook, secrets refusal) after framework changes.
- **`selftest.sh`.** Automated self-test: framework consistency (version, LICENSE match, skills→procedures), installer (fresh install, idempotence, local-edit preservation, conflict file, retired-file removal), check (pass on clean example, fail on planted UI purity violation, fail on planted secret, exit 3 on missing stack), `guard-commands` hook, `guard-protected` hook, stop-check hook, pre-commit hook. No network access; no external tools.
- **README "This repository" table** updated to include examples and selftest.

**Upgrade steps:** None required for existing installs. The new files (`LICENSE`, `examples/`, `selftest.sh`) are in the App Director repository itself, not installed into apps.

## 1.0.3 (2026-10-07)

- **Role terminology aligned.** "Main session", "director and orchestrator", and "developer (builder subagent)" replaced with canonical terms: orchestrator (main session), builder (builder subagent). Affected: README.md (Context and token use section), `framework/.claude/agents/builder.md` description, `framework/.claude/agents/reviewer.md` body.
- **README model sizing updated.** The two-tier description (Haiku for XS/S, session model for M-XL) replaced with the five-tier description introduced in 1.0.2.

**Upgrade steps:** None required. Existing AGENTS.md files may keep old role labels; updating them is optional.

## 1.0.2 (2026-10-07)

- **Five-tier model sizing.** The model sizing feature now maps each task size (XS, S, M, L, XL) to its own model ID stored in AGENTS.md › Project rules. Previously XS and S used Haiku while M, L and XL all used the session model; L and XL were never escalated to a stronger model. Defaults for Claude Code: Haiku for XS and S, Sonnet for M, Opus for L and XL.
- **`/refresh-model-sizing` skill.** New procedure and Claude Code skill that does a capability check (subagents + per-call model), proposes defaults, and writes the five-entry block to AGENTS.md › Project rules. Run it after install or to update entries.

**Upgrade steps:**
1. In AGENTS.md › Project rules, replace `- Model sizing: on` (single line) with the five-entry block:
   ```
   - Model sizing: on
     - XS: claude-haiku-4-5-20251001
     - S:  claude-haiku-4-5-20251001
     - M:  claude-sonnet-5-5
     - L:  claude-opus-5-5
     - XL: claude-opus-5-5
   ```
   (Or run `/refresh-model-sizing`: it will write the block interactively.)
2. In `.app-director/procedures/next-task.md`, step 3.2, update to: read the model ID for the item's size from the AGENTS.md block and pass it as `model:`; fall back to the session model if no entry exists.
3. In `.app-director/rules.md` › Reviews and model size, replace the two-row table with the five-entry block description.

## 1.0.1 (2026-10-06)

- **Autonomous commit mode.** `next-task.md` step 7 no longer pauses for approval when the human has said to work autonomously ("do the next N tasks", "work through the queue"). Commits proceed without interruption and are listed in the final report instead.
- **Release checklist in CLAUDE.md.** Every GitHub release must open with a How to install section covering all three install paths and the upgrade path.

**Upgrade steps:** In `framework/.app-director/procedures/next-task.md`, in step 7, update the Commit line to: `Pause for approval unless the human has said to work autonomously ("do the next N tasks", "work through the queue"), in which case commit without pausing and include all commits in the final report.`

## 1.0.0 (2026-10-05)

Initial public release.

- **Claude Code plugin.** A `.claude-plugin/plugin.json` manifest makes App Director a first-class Claude Code plugin, installable from the marketplace with `/plugin install app-director`. `skills/app-director/SKILL.md` is the bootstrap skill; a root `SKILL.md` covers the standalone `~/.claude/skills/` use case. `package.json` enables npm/npx distribution.
- **Protected workspace (`director/`).** The human's personal space: mockups, brand assets, reference images, notes, third-party API specs. The agent reads files there for context but is blocked from creating, modifying or deleting anything inside it. Edit and Write tool hooks enforce this in Claude Code.
- **Ownership interview in onboarding.** Step 8 goes through every work area (frontend, business logic, backend, database schema, visual design, copy, testing, infrastructure) and asks who owns each. Human-owned areas get a documented placeholder policy. AGENTS.md has an `## Ownership` table to record the result.
- **Full workflow.** Design sessions, build-check-commit loop, acceptance checks, alignment pass, archive, release: each as a skill command in Claude Code.
