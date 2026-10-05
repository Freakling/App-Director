# Changelog

Each entry lists what changed. **Upgrade steps** at the end of an entry cover both framework fixes and app-owned file updates (AGENTS.md, TASKS.md, product/brief.md), so every project reaches the same capability level after upgrading. Onboarding carries them out; the fast upgrade mode runs only these steps, and the full mode also re-checks everything as if newly installed.

## 1.1.0 (2026-10-05)

- **Protected workspace (`director/`).** The human's personal space — mockups, brand assets, reference images, notes, third-party API specs. The agent reads files there for context but is blocked from creating, modifying or deleting anything inside it. Edit and Write tool hooks enforce this in Claude Code.
- **Ownership interview in onboarding.** Step 8 now goes through every work area (frontend, business logic, backend, database schema, visual design, copy, testing, infrastructure) and asks who owns each. Human-owned areas get a documented placeholder policy. AGENTS.md now has an `## Ownership` table to record the result.

**Upgrade steps**
1. In AGENTS.md, add an `## Ownership` section (see `$ADIR/project/AGENTS.md` for the template). Fill it with the agreed ownership for each area.
2. If the human owns any area, consider creating `director/` as their protected workspace. Ask them.

## 1.0.0 (2026-10-05)

Initial release.
