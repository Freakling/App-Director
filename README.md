# App Director

**Make the app you designed, with AI doing the building and you staying the director.**

A workflow for small apps — web, mobile and desktop — new or already in development. You decide what the app does, how it should feel and what gets built next. The AI builds, tests and keeps the records. Built for Claude Code, and usable with any AI coding assistant that reads `AGENTS.md`. Everything lives in your app's own git repository.

## Why

AI writes app code fast. Without structure, that speed goes wrong in familiar ways:

- **The design drifts.** The AI quietly decides a flow or a behaviour you never agreed to. With App Director, design calls come to you as 2–4 options with a recommendation. Only your choice is written down, and anything undecided goes on an open-questions list instead of being guessed.
- **"Done" means "it compiled".** One check defines "works": types pass, tests pass, and the architecture rules hold. It runs before every commit that touches code, and in Claude Code also before the AI ends its turn.
- **Rules end up in the wrong layer.** Business logic lives in a testable logic layer; UI screens only display state. The check fails when a screen fetches data directly or calls storage.
- **Context gets lost between sessions.** A few plain files hold everything: the product brief, a decision log, the task queue and an architecture table. Each fact has one home, so any session picks up where the last one stopped.

## How to use it

**Manual install (for now):** put this repository next to your app as `App-Director/`, or anywhere you like, then ask your assistant:

> Read App-Director/ONBOARDING.md and follow it to install App Director into this project.

Onboarding works out whether this is a new app, an existing app or an upgrade. It then:
1. installs the files and sets up the toolchain;
2. interviews you (new app) or reads the existing code;
3. agrees with you who owns what;
4. ends with one commit for you to approve.

Afterwards, restart Claude Code so the new commands load. Each new clone later needs one command: `bash tools/setup-clone.sh`.

### Day to day

| Say | What happens |
|---|---|
| "Do the next task" (`/next-task`) | Builds the next ready item (high-severity bugs first), proves it with the check, updates the records, and asks you to approve the commit. |
| "Do the next 3 tasks", "Work through the queue" | The same, item after item, until one needs you. |
| "Which open questions block development?" (`/design questions`) | Ranks the open questions by what they unblock, with options and a recommendation for each. |
| "Let's design {topic}" (`/design {topic}`) | A design session. Your decisions become brief text, decision-log lines and task items. |
| "Prepare an acceptance check", "Process the acceptance check" (`/acceptance`) | A checklist of what's been built since the last round and needs a human eye; you tick Works or Broken. |
| "Check the docs are aligned" (`/align`) | A consistency pass. Drift gets fixed; gaps and conflicts come to you. |
| "Prune the task list" (`/prune`) | Moves done items to `TASKS-archive.md`. |
| "Release to production" (`/release`) | Runs the check, builds for the target platform, and walks you through the deploy. |

```
you use the app, or have an idea
        │
        ▼
design session ── options + a recommendation ── you decide ──► brief + decisions.md + TASKS.md items
        │
        ▼
next task ── builds the next ready item ── tests ── bash tools/check.sh ──► commit (you approve)
        │
        ▼
acceptance check (does each built rule work in the running app?)
        │
        ▼
bugs and design proposals ── you decide ── repeat
```

---

## What this is

### Who does what
| | Responsible for |
|---|---|
| **You** | Product vision, design, priorities; testing the running app; approving commits. You have the final say on everything. |
| **The AI assistant** | Code, tests, running the check and git, keeping the records true. |

### What gets installed in your app
```
your-app/
│  yours: never overwritten
├── AGENTS.md                   for every assistant: project facts, layout, architecture, ownership, project rules
├── CLAUDE.md                   "@AGENTS.md", for Claude Code
├── TASKS.md                    milestones and the queue (tasks and bugs)
├── product/brief.md            what the app should be, and Open Questions
├── product/decisions.md        why: one line per design decision
├── tools/check.cfg             check settings: stack, UI and data folders
├── validation/TEMPLATE.md      acceptance check template, one section per core flow
│
│  App Director's, tool-neutral: updated on upgrade
├── .app-director/rules.md        the workflow rules, loaded through AGENTS.md
├── .app-director/tasks.md        the TASKS.md item format, read when items are written
├── .app-director/procedures/     next-task · build · design · review · align · prune · release · acceptance
├── tools/check.sh              the check (UI purity, secrets, stack, custom)
├── tools/setup-clone.sh        per clone: checks toolchain, installs the pre-commit hook
├── tools/stacks/               typescript.sh · flutter.sh · python.sh · none.sh
├── .githooks/pre-commit        runs the check before commits that touch code
│
│  App Director's, Claude Code adapter: updated on upgrade
├── .claude/skills/             /next-task and the rest: each points to its procedure
├── .claude/agents/             builder (builds each item in a fresh context) · reviewer (read-only)
├── .claude/hooks/              runs the check before a turn ends; blocks risky git commands
└── .claude/settings.json       permissions, hooks, timeouts
```
Machine-local and gitignored: `.app-director/state/` (check cache) and `.claude/settings.local.json`.

### The rules, briefly
The full rules are in `.app-director/rules.md`, and the assistant reads them every session.
- **You decide design.** The assistant offers options and a recommendation. It never picks values (new values are marked `PLACEHOLDER`), and never answers an open question itself.
- **Areas you own are never generated.** Onboarding asks who owns visual design, assets, copy and infrastructure. Human-owned areas get a documented placeholder policy instead of generated content. `director/` is an optional protected workspace — the AI reads it for context but never creates, modifies or deletes anything inside it.
- **Each fact lives in one place,** and is updated in the same change that makes it untrue.
- **Logic lives in the logic layer, not the UI.** Screens display state and call services. They never fetch data directly or hold business logic. The check fails when they do.
- **No secrets in source.** Credentials live in `.env` files (gitignored) and platform secrets. The check fails on anything that looks like a key or password in source.
- **Done means the check passes,** and the work is committed only with your approval.
- **Guarded git:** in Claude Code, force-push, `reset --hard`, `--no-verify` and other work-destroying commands are blocked by a hook.

### Context and token use

The director (main session) and the developer (builder subagent) are deliberately separate contexts.

**The main session — director and orchestrator**
- **Small at the start.** A session starts with about 10 KB of instructions (AGENTS.md and the rules). Each procedure loads only when it's used.
- **Stays small across items.** The main session picks items, records decisions, updates TASKS.md, and approves commits. It never reads the files being changed. After it hands an item to the builder and the report comes back, its context holds only that ~20-line report.
- **Nothing to hand off between sessions.** TASKS.md, the commits, AGENTS.md and the brief hold everything. Once an item is committed, a new session (or `/clear` in Claude Code) loses nothing.
- **Design sessions: clear after each commit.** Once a design session's commit lands, the conversation has no value left — every decision is in the brief and decisions.md. `/clear` before the next topic.

**The builder subagent — developer with a fresh context**
- **Fresh context per item.** Each build runs as a separate `builder` subagent. It reads only what the item needs: the files in `Touches`, the relevant Architecture rows, and the brief sections the item names.
- **The report is the only channel.** The builder's report fields give the main session exactly what it needs to update the records — no more.

**Model sizing** (recommended on): `XS` and `S` items run the builder on a smaller model (Haiku in Claude Code); `M` through `XL` use the session model. Onboarding asks you to choose; record it in AGENTS.md › Project rules.

### The check
`bash tools/check.sh` runs four steps:
1. **UI purity:** scans UI-layer files for imports from data-layer folders. Fails if found.
2. **Secrets:** scans all source for patterns that look like keys, passwords, or tokens. Fails if found.
3. **Stack check:** runs the appropriate `tools/stacks/<stack>.sh` (type check, lint, tests).
4. **Custom:** runs `tools/check.local.sh`, if the app has one.

It exits 0 on pass, 1 on fail, and 3 when it can't run. It caches the last passing state so hooks don't re-run it when nothing has changed.

### This repository
| Path | |
|---|---|
| `ONBOARDING.md` | what the assistant follows to install or upgrade |
| `install.sh` | copies files deterministically, keeps your edits, writes a manifest |
| `framework/` | installed into each app: the tool-neutral core, plus `.claude/` for Claude Code |
| `project/` | seeds for the app's own files, copied only when missing |
| `CHANGELOG.md` | what changed, and the upgrade steps for apps |
| `CLAUDE.md` | instructions for an assistant working on App Director itself |

## License

MIT © 2026 Vikingur Saemundsson. You may use, fork and change App Director, including in commercial apps, as long as the copyright notice and the license stay with it. Installed apps carry a copy in `.app-director/LICENSE`.
