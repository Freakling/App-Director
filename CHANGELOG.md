# Changelog

Each entry lists what changed. **Upgrade steps** at the end of an entry cover both framework fixes and app-owned file updates (AGENTS.md, TASKS.md, product/brief.md), so every project reaches the same capability level after upgrading. Onboarding carries them out; the fast upgrade mode runs only these steps, and the full mode also re-checks everything as if newly installed.

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
