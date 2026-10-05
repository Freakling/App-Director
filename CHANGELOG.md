# Changelog

Each entry lists what changed. **Upgrade steps** at the end of an entry cover both framework fixes and app-owned file updates (AGENTS.md, TASKS.md, product/brief.md), so every project reaches the same capability level after upgrading. Onboarding carries them out; the fast upgrade mode runs only these steps, and the full mode also re-checks everything as if newly installed.

## 1.0.0 (2026-10-05)

Initial public release.

- **Claude Code plugin.** A `.claude-plugin/plugin.json` manifest makes App Director a first-class Claude Code plugin, installable from the marketplace with `/plugin install app-director`. `skills/app-director/SKILL.md` is the bootstrap skill; a root `SKILL.md` covers the standalone `~/.claude/skills/` use case. `package.json` enables npm/npx distribution.
- **Protected workspace (`director/`).** The human's personal space — mockups, brand assets, reference images, notes, third-party API specs. The agent reads files there for context but is blocked from creating, modifying or deleting anything inside it. Edit and Write tool hooks enforce this in Claude Code.
- **Ownership interview in onboarding.** Step 8 goes through every work area (frontend, business logic, backend, database schema, visual design, copy, testing, infrastructure) and asks who owns each. Human-owned areas get a documented placeholder policy. AGENTS.md has an `## Ownership` table to record the result.
- **Full workflow.** Design sessions, build-check-commit loop, acceptance checks, alignment pass, archive, release — each as a skill command in Claude Code.
