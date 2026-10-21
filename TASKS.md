# Tasks

This is App Director's own work queue, for developing the framework itself. It is fed by [Director-Driven Development](https://github.com/Freakling/Director-Driven-Development)'s orchestrator through pull requests. `project/TASKS.md` is a different file: the template shipped to adopters, which never receives these items.

Item format: `framework/.app-director/tasks.md`. Queue order is priority; reorder by moving items.

**Next IDs:** T17 · B8 · R1

## Queue

### T16 · Every subagent launch passes its model explicitly · done · S · agent
- Touches: framework/.app-director/procedures/next-task.md, framework/.app-director/rules.md, selftest.sh, CHANGELOG.md
- Done when: next-task.md says the orchestrator passes the builder's, reviewer's and researcher's model explicitly from the sizing table on every launch and never lets a subagent inherit the session's model, with the session model only when the table has no entry for the size (check) · the selftest checks that wording (check)
- Brief: -
- Source: Director-Driven-Development T149

### T13 · The README starts with writing your own product brief · done · S · agent
- Touches: README.md, project/product/director-brief.md, selftest.sh, CHANGELOG.md
- Done when: the README's Install section opens with a "Start here" step: write your product brief first, with a link to the template at the latest release tag, then install, and onboarding reads it and asks only what you left open (check) · the template's header carries the same link, at v<VERSION>, and the selftest checks both (check) · `bash selftest.sh` passes (check)
- Brief: -
- Source: Director-Driven-Development T155

### T14 · One git worktree per parallel building session · done · XS · agent
- Touches: framework/.app-director/rules.md, README.md, selftest.sh, CHANGELOG.md
- Done when: rules.md says that any two sessions building at once each use their own git worktree, since a shared checkout lets one session's half-written files fail the other's check and Stop hook, with the commands to make one and run tools/setup-clone.sh in it (check) · the README's day-to-day section points to that rule (check) · the selftest checks the rule exists with its reason (check)
- Brief: -
- Source: Director-Driven-Development T160

### T12 · An install from a development snapshot says so · done · S · agent
- Touches: install.sh, selftest.sh, CHANGELOG.md
- Done when: the manifest records the source commit, and an install from a source whose CHANGELOG.md has entries under Unreleased records `<version> + unreleased (<commit>)` and says so in its closing lines (test) · an install from a release records the plain version (test) · `bash selftest.sh` passes (check)
- Brief: -
- Source: Director-Driven-Development T134

### T7 · align checks the brief against reality · done · S · agent
- Touches: framework/.app-director/procedures/align.md, CHANGELOG.md
- Done when: align's item 6 is "Brief against reality", in place of the Decisions spot-check: it reads the whole brief, checks every statement of state against the built app, the done items and the latest releases, and checks every decision line since the last `docs: align` commit one by one (check)
- Brief: -
- Source: Director-Driven-Development T93

### T8 · The README says how to update the plugin · done · XS · agent
- Touches: README.md, CHANGELOG.md
- Done when: the README's Install section has an upgrade part that gives `/plugin marketplace update app-director` and `/plugin update app-director@app-director` and the restart, as Godot-Director's and SaaSAllTheThings' READMEs do (check)
- Brief: -
- Source: Director-Driven-Development T118

### T9 · The repository's own queue has a research counter · done · XS · agent
- Touches: TASKS.md
- Done when: `Next IDs` carries the `R` counter that `align.md` asks for, `· R1` (check)
- Brief: -
- Source: Director-Driven-Development T119

### T10 · Your own product brief, a template the human writes · done · S · agent
- Touches: project/product/director-brief.md (new), examples/todo-web/product/director-brief.md (new), ONBOARDING.md, README.md, selftest.sh, CHANGELOG.md
- Done when: every app has the director's product brief template as a seed (`product/director-brief.md`) for the human to fill in, and the example carries it too (check) · onboarding offers it before the interview, as an alternative or an addition to the chat interview, with a word on why it helps, and reads a filled one first for a new or an existing app to build the initial assessment and the design records, marking what it took `(from your brief)` and what it inferred `(inferred, please confirm)` (check) · the README mentions it (check) · the selftest fails when the seed, the example copy, onboarding's wiring or the README is missing, and checks that a new app and an upgraded app receive the seed (check)
- Brief: -
- Source: Director-Driven-Development T87

### T11 · The README says "an agreed placeholder" · done · XS · agent
- Touches: README.md, CHANGELOG.md
- Done when: the README's ownership line says human-owned areas get an agreed placeholder instead of generated content, in place of "a documented placeholder policy" (check)
- Brief: -
- Source: Director-Driven-Development T121

### T6 · The repository ignores OS metadata files · done · XS · agent
- Touches: .gitignore, CHANGELOG.md
- Done when: `.gitignore` lists `.DS_Store`, `Thumbs.db`, `desktop.ini` and `__MACOSX/` (check)
- Brief: -
- Source: Director-Driven-Development T100

### B7 · The protected-space guard blocks absolute paths · done · S · agent · high
- Touches: framework/.claude/hooks/guard-protected.sh, selftest.sh
- Repro: with the project at `<root>`, Claude Code writes to `<root>/director/x` (absolute), or `C:\...\director\x` on Windows → expected: the hook blocks it / actual: the hook allows it, because it matched `director/*` only against the path as written
- Found in: Director-Driven-Development T85
- Brief: -

## Queue

### T15 · /ui-design with Playwright capture · done · L · agent
- Touches: framework/.app-director/procedures/ui-design.md (new), framework/.claude/skills/ui-design/SKILL.md (new), framework/tools/ui_capture.sh (new), framework/tools/ui/capture.mjs (new), framework/tools/ui/lint.mjs (new), framework/tools/ui/drawing.mjs (new), framework/tools/ui/overlay.mjs (new), framework/tools/ui/verify.mjs (new), framework/tools/ui/common.mjs (new), framework/tools/ui/package.json (new), framework/tools/ui/.npmrc (new), project/tools/ui/screens.mjs (new), project/tools/ui_capture.cfg (new), project/product/ui/README.md (new), project/AGENTS.md, framework/.app-director/rules.md, framework/.app-director/tasks.md, framework/.app-director/procedures/build.md, framework/.app-director/procedures/review.md, framework/.app-director/procedures/acceptance.md, framework/.app-director/procedures/align.md, framework/.app-director/procedures/design.md, framework/.claude/settings.json, install.sh, ONBOARDING.md, README.md, tests/ui-drawing/ (new), tests/ui-web/ (new), selftest.sh, CHANGELOG.md
- Done when: `/ui-design list` prints the catalog and `capture` writes a PNG, element map, map image and lint file per catalog screen, state and size of a web app on this machine, the same twice, and refuses a host that isn't local (test) · the lint catches each of its seven rules on a fixture page built to break it and reports nothing on a clean one, and a page with a known Tab order and one trap gives that order and exactly one unreachable element (test) · the reader gives the same `drawing.json` as Godot Director's for the shared fixtures, the same percentages with the image moved and scaled, and a starter that reads back empty (test) · `verify` reports no deviation on a page built as its spec says and exactly the element moved 10% (test) · without Node, Playwright or a web app, capture exits 3 with the reason and writes nothing, and the check doesn't need them (test)
- Brief: -
- Source: Director-Driven-Development T84

### T5 · The research assistant · done · M · agent
- Touches: framework/.app-director/procedures/research.md (new), framework/.app-director/research-domain.md (new), framework/.claude/agents/researcher.md (new), framework/.claude/skills/research/SKILL.md (new), framework/.claude/settings.json, framework/.app-director/tasks.md, framework/.app-director/rules.md, framework/.app-director/procedures/next-task.md, framework/.app-director/procedures/design.md, framework/.app-director/procedures/align.md, project/TASKS.md (+R counter), project/product/research/README.md (new), examples/todo-web/TASKS.md, examples/todo-web/product/research/README.md (new), examples/scenarios.md, README.md, ONBOARDING.md, selftest.sh, CHANGELOG.md
- Done when: `research.md`, `research-domain.md`, the `researcher` subagent and the `/research` skill exist, and `rules.md`, `next-task.md`, `design.md`, `tasks.md`, the README and ONBOARDING.md name or use them (check) · the `researcher` has `Read, Grep, Glob, WebSearch, WebFetch` and no edit, write or shell tool, and `settings.json` allows web search and fetch (check) · `project/TASKS.md` carries an `R` counter on its `Next IDs` line, and the installer ships the procedure, the domain file, the note folder and the Claude adapter files (check) · a commit with only a research note doesn't run the project check (check)
- Brief: -
- Source: Director-Driven-Development T33 (product/anchors/research.md)

### T4 · The manual install clones the latest release · done · XS · agent
- Touches: README.md, CHANGELOG.md
- Done when: the manual install option in README.md clones the release tag `v<version>` instead of `main`, with the tag left as a placeholder found on the Releases page (check) · the manual upgrade wording still holds (check)
- Brief: -
- Source: Director-Driven-Development T65

### T3 · The install paths get the latest release · done · M · agent
- Touches: SKILL.md, skills/app-director/SKILL.md, package.json, scripts/fetch-app-director.sh, .claude-plugin/marketplace.json, CLAUDE.md, README.md, selftest.sh, CHANGELOG.md
- Done when: both `SKILL.md` files, the fetch script and the marketplace's plugin entry name the release tag `v<version>`, and the version in `SKILL.md`, `skills/app-director/SKILL.md`, `package.json` and the marketplace agrees with `VERSION` (check) · a folder left by an earlier fetch moves to the script's release tag (test) · `CLAUDE.md` › For a release lists every file that carries the version and says each release is tagged `v<version>` (check)
- Brief: -
- Source: Director-Driven-Development T39

### B3 · The secrets check reports a scan that can't run as credentials found · done · S · agent · med
- Touches: framework/tools/check.sh, selftest.sh
- Repro: install gitleaks 8.19.0, then run `bash tools/check.sh` on a clean tree → expected: the check says gitleaks couldn't scan (exit 3) and hints at an upgrade / actual: "gitleaks found credentials in the working tree", because every scan command fails with "flag accessed but not defined: source" and the check reads that failure as a finding; its comment wrongly says 8.19.0 scans with `detect`, and the selftest's real-gitleaks checks run on 8.19.0 and fail
- Found in: Director-Driven-Development T50

### B4 · The setup and the README accept gitleaks 8.19.0, which can't scan · done · XS · agent · low
- Touches: framework/tools/setup-clone.sh, README.md
- Repro: install gitleaks 8.19.0, then run `bash tools/setup-clone.sh` → expected: the setup says 8.19.0 can't scan, asks for 8.19.1 or later and exits 3 / actual: "found gitleaks 8.19.0 (>= 8.18.0)" and the pre-commit hook is installed; the README's requirement, ≥ 8.18.0 with no exception, doesn't warn about 8.19.0 either
- Found in: Director-Driven-Development T52
- Brief: -

### B5 · The fast check doesn't notice a removed or changed gitleaks · done · S · agent · low
- Touches: framework/tools/check.sh, selftest.sh
- Repro: pass `bash tools/check.sh`, then remove gitleaks (or downgrade it to 8.19.0) and run `bash tools/check.sh --if-changed` without changing a file → expected: the secrets step runs again, and the check exits 3 (gitleaks not found, or can't scan on 8.19.0) / actual: "check: PASS (nothing changed since the last passing run)" with exit 0, because the cached pass ignores gitleaks until a file changes
- Found in: Director-Driven-Development T53
- Brief: -

### B6 · The selftest's pre-commit check doesn't expect setup-clone's 8.19.0 refusal · done · XS · agent · low
- Touches: selftest.sh
- Repro: put gitleaks 8.19.0 first on PATH, then run `bash selftest.sh` → expected: the "setup-clone installs the pre-commit hook" check expects setup-clone to refuse 8.19.0 (exit 3, no hook installed), and a stand-in 8.19.0 proves the refusal / actual: the check passes only because the selftest's 8.18.0 passthrough stand-in hides the 8.19.0, so setup-clone never sees it and no test runs its refusal
- Found in: Director-Driven-Development T57
- Brief: -

### T2 · The pre-commit hook names the file with a secret · done · S · agent
- Touches: framework/.githooks/pre-commit, selftest.sh
- Done when: a staged secret blocks the commit, the hook names the file and doesn't print the secret (test) · a scan that gitleaks can't run (8.19.0) is reported as that, not as a finding (test) · `bash selftest.sh` passes (check)
- Brief: -
- Source: Director-Driven-Development T49

### B2 · The secrets check names the file and works with gitleaks 8.18 and 8.30 · done · S · agent · med
- Touches: framework/tools/check.sh, selftest.sh
- Repro: plant a credential in a project file, then run `bash tools/check.sh` with gitleaks 8.30.1 → expected: the output names the file, and an allowlisted fingerprint passes / actual: the output names no file, and the selftest's "names the file with the secret" and "allowlisted fingerprint passes" checks fail (the fingerprint pattern expects `"Fingerprint":"` with no space, which gitleaks doesn't write); with gitleaks 8.18 every scan fails, because `gitleaks dir` doesn't exist there
- Found in: Director-Driven-Development T47
- Brief: -

### B1 · The upgrade-file check ignores nested clones · done · S · agent · med
- Touches: framework/.githooks/pre-commit, framework/.app-director/procedures/align.md, ONBOARDING.md, selftest.sh
- Repro: clone a repository into an ignored folder (such as `work/`), with no upgrade file present, then commit → expected: the commit goes ahead / actual: "unmerged App Director upgrade files (*.adir-new) exist", listing the clone's folder, because `git ls-files` lists a nested repository in an ignored folder as a directory
- Found in: Director-Driven-Development B2
- Brief: -

### T1 · "Grab tasks until you're blocked" starts a run · done · S · agent
- Touches: framework/.app-director/procedures/next-task.md, framework/.claude/skills/next-task/SKILL.md, README.md, examples/scenarios.md, CHANGELOG.md
- Done when: `next-task.md` names "grab tasks until you're blocked" next to "the next N tasks" and "work through the queue", in the request list and in step 7 (check) · the skill description, the README's day-to-day table and the behaviour scenarios name it too (check)
- Brief: -
- Source: Director-Driven-Development T35 (the shared commit model)

## Notes
