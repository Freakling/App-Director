# Changelog

Each entry lists what changed. **Upgrade steps** at the end of an entry cover both framework fixes and app-owned file updates (AGENTS.md, TASKS.md, product/brief.md), so every project reaches the same capability level after upgrading. Onboarding carries them out; the fast upgrade mode runs only these steps, and the full mode also re-checks everything as if newly installed.

## 1.0.3 (2026-10-07)

- **Role terminology aligned.** "Main session", "director and orchestrator", and "developer (builder subagent)" replaced with canonical terms: orchestrator (main session), builder (builder subagent). Affected: README.md (Context and token use section), `framework/.claude/agents/builder.md` description, `framework/.claude/agents/reviewer.md` body.
- **README model sizing updated.** The two-tier description (Haiku for XS/S, session model for M–XL) replaced with the five-tier description introduced in 1.0.2.

**Upgrade steps:** None required. Existing AGENTS.md files may keep old role labels; updating them is optional.

## 1.0.2 (2026-10-07)

- **Five-tier model sizing.** The model sizing feature now maps each task size (XS, S, M, L, XL) to its own model ID stored in AGENTS.md › Project rules. Previously XS and S used Haiku while M, L and XL all used the session model — L and XL were never escalated to a stronger model. Defaults for Claude Code: Haiku for XS and S, Sonnet for M, Opus for L and XL.
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
   (Or run `/refresh-model-sizing` — it will write the block interactively.)
2. In `.app-director/procedures/next-task.md`, step 3.2, update to: read the model ID for the item's size from the AGENTS.md block and pass it as `model:`; fall back to the session model if no entry exists.
3. In `.app-director/rules.md` › Reviews and model size, replace the two-row table with the five-entry block description.

## 1.0.1 (2026-10-06)

- **Autonomous commit mode.** `next-task.md` step 7 no longer pauses for approval when the human has said to work autonomously ("do the next N tasks", "work through the queue"). Commits proceed without interruption and are listed in the final report instead.
- **Release checklist in CLAUDE.md.** Every GitHub release must open with a How to install section covering all three install paths and the upgrade path.

**Upgrade steps:** In `framework/.app-director/procedures/next-task.md`, in step 7, update the Commit line to: `Pause for approval unless the human has said to work autonomously ("do the next N tasks", "work through the queue"), in which case commit without pausing and include all commits in the final report.`

## 1.0.0 (2026-10-05)

Initial public release.

- **Claude Code plugin.** A `.claude-plugin/plugin.json` manifest makes App Director a first-class Claude Code plugin, installable from the marketplace with `/plugin install app-director`. `skills/app-director/SKILL.md` is the bootstrap skill; a root `SKILL.md` covers the standalone `~/.claude/skills/` use case. `package.json` enables npm/npx distribution.
- **Protected workspace (`director/`).** The human's personal space — mockups, brand assets, reference images, notes, third-party API specs. The agent reads files there for context but is blocked from creating, modifying or deleting anything inside it. Edit and Write tool hooks enforce this in Claude Code.
- **Ownership interview in onboarding.** Step 8 goes through every work area (frontend, business logic, backend, database schema, visual design, copy, testing, infrastructure) and asks who owns each. Human-owned areas get a documented placeholder policy. AGENTS.md has an `## Ownership` table to record the result.
- **Full workflow.** Design sessions, build-check-commit loop, acceptance checks, alignment pass, archive, release — each as a skill command in Claude Code.
