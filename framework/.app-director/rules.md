<!-- App Director · framework-owned: replaced on upgrade. Project-specific rules go in
AGENTS.md › Project rules, and win over these defaults. -->
# App Director workflow rules

These rules apply to any AI assistant working in this project. For each of these requests, follow the procedure in `.app-director/procedures/`:
- **next-task.md:** do the next task(s), or a named item (T12, B3, R2). The build itself is `build.md`.
- **design.md:** brainstorm, open design questions, change the design.
- **research.md:** research a question in a fresh context and save a dated note in `product/research/`, for a design call or a decision about stacks, libraries, licences or app-store requirements. It informs; the human decides. Domain reference: `.app-director/research-domain.md`.
- **acceptance.md:** prepare or process an acceptance check.
- **align.md:** check the docs and tasks are aligned.
- **drift-reset.md:** a design drift reset, or its postmortem. Only the human starts one; never run it on your own.
- **prune.md:** prune the task list.
- **review.md:** review a finished change.
- **release.md:** release to an environment or platform.
- **security.md:** a security assessment (`/security`): the tools, then a fresh reader through the OWASP checklist in `.app-director/reference/owasp.md`; findings become bug items, people and process items go to the human, and a dated report goes in `product/security/`. It runs on request, before a release is proposed, and when `next-task.md` finds one due.
- **ui-design.md:** capture the screens (`/ui-design`): a PNG per screen, state and size of the web app on this machine, with an element map, a numbered map image, layout lint and a starter drawing; process the human's Excalidraw drawing of a screen into a screen spec and items; verify a built screen against its spec and write compare images; list the screens in the catalog.
- **refresh-model-sizing.md:** set or update the model sizing block in AGENTS.md › Project rules.

In Claude Code these are also slash commands, and builds, reviews (with the security assessment's reading pass) and research run as the `builder`, `reviewer` and `researcher` subagents.

## The human decides
- The human owns product vision, design and priorities. You build, keep the records, and propose.
- A design call is a feature behaviour, a flow, or anything the user experiences that `product/brief.md` doesn't settle. For one, give 2-4 options with one recommendation and a one-line reason, then wait. Write down only what was chosen, following `design.md` › Record each decision. If you had to interpret the answer, say how you read it.
- Never answer an Open Question in `product/brief.md` yourself. Work that depends on one gets a placeholder that names the question.
- Something that seems to contradict a stated goal is flagged, never reinterpreted.
- Research informs a design call and never makes it. The `researcher` records no decision, never edits the brief or `product/decisions.md`, never answers an Open Question, and never asks the human; its recommendation is shown as one option with its reason.

## Protected space
`director/` is the human's personal workspace: mockups, brand assets, reference images, notes, third-party API specs. Read files there for context when an item needs them, but never create, modify or delete anything inside it. If work depends on an asset the human owns, use the placeholder policy in AGENTS.md › Ownership instead of generating the real thing.

## Each fact lives in one place
| Fact | Only in |
|---|---|
| What the app should be | `product/brief.md`. List its sections with `grep -n "^#" product/brief.md` and read only the ones you need. |
| What's undecided | brief › Open Questions |
| Why a design decision was made | `product/decisions.md` (append-only) |
| The evidence behind a design call | `product/research/`, one dated note per topic; the decision line links to it |
| What the last security assessment found, and what it couldn't check | `product/security/YYYY-MM-DD.md`, one report per assessment (`procedures/security.md`) |
| How the app was built before a design drift reset, and what drifted | `product/resets/YYYY-MM-DD/` (never deleted) |
| Which systems exist and what each owns | `AGENTS.md` › Architecture |
| How each screen is laid out | `product/ui/<screen>.md`, one spec per screen (`procedures/ui-design.md`) |
| The human's screen drawings | `director/ui/` (Excalidraw files; read-only for you) |
| Work, bugs, research, milestones | `TASKS.md` (format: `.app-director/tasks.md`; done items: `TASKS-archive.md`) |
| Whether it works | `bash tools/check.sh` |

Update the owning place in the same change that makes it untrue. Replace superseded text; never strike it through or keep two versions. Refer to brief sections by heading ("Brief: Authentication › Sign in"), never by number.

## Architecture defaults
- **UI layer.** Screens, pages and components display state and call the logic layer. They never import from the data layer directly, never call `fetch`/`http` themselves, and hold no business logic. The check fails when a file in a configured UI folder imports from a configured data folder. Every screen has an entry in the catalog, `tools/ui/screens.mjs`; add or update it whenever you add or change a screen. Elements a screen spec names get a `data-testid` (`gear-list`) that the spec, element maps and tests share. Build layouts with flex or grid, never pixel positions. The catalog seeds a screen's state through the app's public API, as a client does, and never imports the data layer.
- **Logic layer.** Services, hooks, providers and stores hold business logic, state management, and calls to the data layer. This is what the UI calls and what tests exercise.
- **Data layer.** Repositories, API clients and storage modules handle network access and persistent storage only. No UI concerns.
- **Folder configuration.** `tools/check.cfg` › `[ui] dirs` lists the UI-layer folders; `[data] dirs` lists the data-layer folders. Update them when folders move.
- **New stored data fields.** When storage already holds data, a new required field needs a migration or a default. The check fails if it finds a new required field without one.
- **Secrets.** Never in source code. Use `.env` files (gitignored) locally; platform secrets (e.g. environment variables set in the deploy environment) in production. The check runs gitleaks on the working tree (this serves the OWASP baseline's Authentication Failures); the pre-commit hook also scans staged changes. Both fail when a credential is found. To allowlist a false positive: propose adding its `Fingerprint` (from `.app-director/state/gitleaks.json`) to `.gitleaksignore` and a reason to `product/decisions.md`; never add either without the human's approval. Any committed credential is compromised regardless of whether the commit is later removed; rotating it is the human's action, never the agent's.
- **No hard-coded IDs, user data or environment-specific values in source.** Use config or environment variables.
- **OWASP baseline.** The OWASP Top 10 (2025), and the OWASP API Security Top 10 (2023) for anything that serves an API, is the baseline every app meets. It is framework-owned: no project setting turns it off, and a project rule in AGENTS.md can't relax it. A deviation is only ever an accepted decision, a line in `product/decisions.md` that names the OWASP item and why; without one it is a finding in `review.md`. `design.md` states each option's effect on the baseline, `review.md` checks each change against it, `security.md` assesses everything built against it from time to time, and the check serves only two parts of it, with no claim to cover the rest: the secrets scan (credentials in source, Authentication Failures) and UI purity (no direct data access from UI code, Broken Access Control).
- **Statically typed.** TypeScript `strict` mode, Flutter with sound null safety, Python with type annotations. The check fails on `any` casts that hide a type error or missing annotations on public API surfaces.

## Doing the work
- **Where work comes from.** `TASKS.md`, or straight from the human. A direct request that won't be finished this session, or that turns up follow-up work, gets a TASKS.md item. Work you discover always becomes a new item; never do it silently as part of another.
- **Read what the work needs:** the item's `Touches`, the Architecture rows, and the brief sections it names. Read by heading or line range, not whole files. Quote only the relevant lines of logs.
- **Stay inside the item.** Prefer the smallest change, and delete dead code. Match existing patterns; a new pattern needs a reason in the commit message.
- **Tests.** Logic that can be tested without a running UI gets a test. A fixed bug gets a regression test when it can have one.
- **Outcome tags.** Each outcome in `Done when` is tagged:
  - `(test)`: a test in the test suite proves it;
  - `(check)`: a command you run and quote proves it, such as the check or a `grep`;
  - `(demo)`: a human verifies it in the next acceptance check.
- **Done** means every `(test)` and `(check)` outcome holds, every `(demo)` outcome is implemented, and `bash tools/check.sh` exits 0. Never report done otherwise, and show the output of a failing check. Exit 3 means the check couldn't run, so say the work is unverified.
- **Running the check.** Run it in the foreground with a long timeout (10 minutes or more), or start it with `run_in_background` and keep working until its completion notice.
- **Commands that may run long.** Give every command that may run long a time limit under five minutes (`timeout 240 ...`, at most 280 seconds), because a wait past five minutes lets the prompt cache expire and the next turn rewrites the whole context. Start a long check with `run_in_background` and keep working until its completion notice instead of polling it with `sleep` loops. Never probe for a tool with an empty heredoc (`python3 - <<'EOF'` followed by `EOF`): it waits for input and never returns, so use `python3 --version`. The command guard blocks these forms. `tools/check.sh` limits each test run to `[tests] timeout` in `tools/check.cfg` (600 seconds by default) and exits 3 when it hits the limit.
- **Two failed attempts.** After two failed attempts at the same problem, stop and report instead of guessing further.

## Git
- **One item, one commit.** The message is `<type>: <summary> (T12)`, with a body saying why; types are `feat fix refactor test docs data chore`. The item's paths are its code, tests, data, and the records the item changed (TASKS.md, AGENTS.md, and the brief and decisions for a decision made during the item). `git add` the new ones, then commit only those paths, `git commit -m "…" -- <paths>`, so another session's staged work stays out.
- **Approval.** Commit only with the human's approval. Push only when asked. Never get around the hooks (`--no-verify`, `core.hooksPath`).
- **Destructive commands.** Anything that discards uncommitted work or rewrites history needs the human.

## Sessions and context
- **New clone.** Run `bash tools/setup-clone.sh`. It checks that the stack tool is available and installs the pre-commit hook.
- **Any two sessions building at once** (say design and coding): each gets its own git worktree, since a shared checkout lets one session's half-written files fail the other's check and Stop hook, and both queue on the same build artefacts. Make one with `git worktree add ../app-design`, then run `bash tools/setup-clone.sh` there. A claim in TASKS.md protects only its own worktree. So only one session per project picks items; the others name the item they work on.
- **The records are the hand-off.** TASKS.md (what's done and what's next), commit messages (why), AGENTS.md and the brief carry everything between sessions. Once an item is committed, a fresh session, or `/clear` in Claude Code, loses nothing.

## Reviews and model size
- An `L` or `XL` item, or an `M` item that changes stored data schemas or public API contracts, gets an independent review (`review.md`) before its commit. Fix the findings that are in scope.
- A research item (`R<n>`) gets no check run and no review: it changes no code. Its size picks the `researcher`'s model the same way.
- **Model sizing** (when on in Project rules): match the build to the item's size. Five tiers by capability: XS and S use the smallest capable model (fast, cheap), M uses a balanced model, L and XL use the most capable model. The model ID for each size is stored in AGENTS.md › Project rules:
  ```
  - Model sizing: on
    - XS: <model-id>
    - S:  <model-id>
    - M:  <model-id>
    - L:  <model-id>
    - XL: <model-id>
  ```
  `next-task.md` passes the entry for the current item's size as an explicit model on every subagent launch: the builder, the reviewer and the researcher. A size without an entry, or model sizing off, passes the session model, also explicitly. Run `/refresh-model-sizing` to set or update these entries.
- **Escalation:** a failed build retries once on the next size's model. An XL failure stops and comes to the director.
