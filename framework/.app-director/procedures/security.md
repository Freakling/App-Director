<!-- App Director · framework-owned: replaced on upgrade. -->
# Security assessment

Validate what is built against the OWASP baseline (`rules.md` › Architecture defaults): run the tools, have a fresh reader go through the checklist in `.app-director/reference/owasp.md`, file what it finds as bug items, give the director the people and process items, and write a dated report. It informs the director; it never deploys, and it changes no code itself: fixes are built later as items.

It runs:
- on request ("run a security assessment"; `/security` in Claude Code);
- in `release.md`, before a release is proposed;
- when `next-task.md` proposes it, because `bash tools/security.sh --due` says one is due: no report yet, or enough items built since the last one (`tools/check.cfg` › `[security] every`, 10 by default); the human can decline.

## Ground rule: a secret is never quoted
Evidence, the report and bug items never quote a secret, token, key or password, nor the line that holds one. A secret is named only by `file:line` and its kind (such as "GitHub token" or "database password"). This applies to the reviewer's findings, the report's evidence and fix lines, a bug item's `Repro:` and `Found in:`, and the tool lines. A tool's output in `.app-director/state/security/` may contain one: cite it by file and line, never copy the value out of it.

## 1. Tools first
Run `bash tools/security.sh`. It never installs anything, and a tool that isn't installed is skipped with a note; never install one without asking the human. It runs:
- the dependency audit for the manifests it finds: `npm audit --omit=dev` (or `pnpm audit --prod`, or yarn's audit, by the lock file), `pip-audit` on a `requirements.txt` whose packages are all pinned with `==` (it is skipped otherwise, since resolving them would install packages and run their build code), `dotnet list package --vulnerable --include-transitive`, and `flutter pub outdated` as information only, since that one isn't a vulnerability audit;
- the check's secrets scan and UI purity step (`bash tools/check.sh --architecture`);
- Semgrep with the `p/owasp-top-ten` rules, when `semgrep` is installed.

Each tool gets one line: clean, FINDINGS (with the OWASP item, and the details below it), skipped, or couldn't run (with the reason). The full outputs are in `.app-director/state/security/`. A tool that couldn't run (no network, a missing lock file) is recorded like a skipped one, with its reason. Keep the lines for the report.

## 2. Reviewer pass
A reader in a fresh context goes through `.app-director/reference/owasp.md`, category by category: in Claude Code, the `reviewer` subagent; with other tools, the way `review.md` runs, in a subagent if the tool has them. Set its model as `next-task.md` section 3 says, using the `L` entry. Give it the tool lines from step 1, the commit (`git rev-parse --short HEAD`), and these instructions:
- Read only; change nothing.
- Never quote a secret, token, key or the line that holds one: give `file:line` and the kind of secret only (see the ground rule above).
- Read `rules.md` › OWASP baseline, the checklist's "Where to look" for the stack in `tools/check.cfg` › `[project] stack`, AGENTS.md › Architecture and Project facts, and the accepted deviations in `product/decisions.md` (lines that name an OWASP item).
- The OWASP API Security Top 10 (2023) applies when the app serves an API (Project facts › API, or routes in the code); otherwise each of its categories is not applicable.
- For each category, read the code and config each check concerns, and judge each `code` and `config` check: holds (cite where), broken (a finding), or not applicable (say what the app lacks). Skip `people` checks: they are step 4's. A tool's clean line is evidence for a check, never the whole answer: read the code too.
- Report each finding with: the OWASP item (such as A05:2025 Injection), a severity by the rubric below, the evidence (`file:line` and what the code does; for a secret, `file:line` and its kind only), a concrete way it fails, and a proposed fix. A deviation with an accepted decision isn't a finding; name the decision instead.
- End with one line per category: **verified** (each applicable check was read and holds), **findings** (one or more broken), **not checkable here** (what it depends on isn't in the repository, such as a backend in another repository or the hosting's settings), or **not applicable**.

Severity:
- **high:** exploitable by someone outside without special access, or exposes credentials or other people's data, or bypasses authentication or authorization. A committed credential is always high.
- **med:** exploitable only under conditions (a signed-in user, a particular config, a chained flaw), or a missing defence the checklist asks for on a path that handles sensitive data.
- **low:** hardening or defence in depth with no direct way to exploit it.

## 3. Findings become bug items
Each finding from step 1 or 2 becomes a bug item in TASKS.md, in the format of `.app-director/tasks.md` (an ID from `Next IDs`, then bump it):
- the heading's title names the OWASP item, such as `### B4 · Notes search builds SQL from input (A05:2025 Injection) · todo · S · agent · high`;
- `Repro:` the evidence as steps, expected and actual, with `file:line` (for a secret: `file:line` and its kind, never the value or its line);
- `Found in:` the report and the finding's number, such as `product/security/2026-10-25.md › F2`, where the proposed fix is.

A finding that already has an open item gets no second one; name the existing item in the report. Severity `high` items go at the top of the queue (and `next-task.md` picks `high` bugs first); the others go at the end of the queue unless the director places them. A committed credential also needs rotating, which is the human's action (`rules.md` › Secrets): add a `human` item for it.

## 4. People and process
The checklist's `people` checks (access reviews, incident response, alert routing and who is on call, key rotation, multi-factor authentication on accounts, the security officer's sign-off where the organisation has one, and the rest) can't be verified in the repository. List them for the director, each with what to do and why, grouped by category. Ask which to track: each one the director agrees to becomes a `human` item in TASKS.md (size `-`). Don't file them without that answer, and don't ask again in the next assessment for items the director declined: the report records the answer.

## 5. The report
Write `product/security/YYYY-MM-DD.md` (today's date; a second assessment the same day replaces that day's file, since git keeps the earlier one), creating the folder if needed:
```
# Security assessment YYYY-MM-DD

- Commit: `<short hash>`
- Ran: <each tool from step 1 that ran, with its result>
- Skipped: <each tool skipped or that couldn't run, and why>
- Reviewer: <subagent or tool, and model>

## Categories
- A01:2025 Broken Access Control: verified | findings (F1, F3) | not checkable here (<why>) | not applicable (<why>)
- ... one line for each of A01-A10, and API1-API10 (not applicable when the app serves no API)

## Findings
### F1 · <title> · <OWASP item> · high | med | low · <B-item>
- Evidence: <file:line, what the code does; for a secret, file:line and its kind only>
- Fails when: <how it is exploited or breaks>
- Fix: <the proposed fix>

## For the director
<step 4's list: each item, what to do and why, and whether it became a human item or was declined>

## What a clean run doesn't prove
<the categories marked verified hold only for the checks in the checklist, read in this commit; the tools find only known issues they have rules for; nothing here tests the running app, the hosting or the people and process items; a category not checkable here is unknown, not met>
```
A category is never marked verified from a tool passing alone: verified needs the reviewer to have read the code or config behind each applicable check. Keep the last section in every report, clean or not.

## 6. Commit and report
Commit the report and the TASKS.md items together, `docs: security assessment YYYY-MM-DD`, with the human's approval as `rules.md` › Git says. Tell the director, in a few lines: the findings by severity with their items, the categories not checkable here, the people and process list with the question from step 4, and the tools that were skipped, with how to install each if they want it next time.
