# Security assessment fixtures

Two copies of a small Node notes server (plain JavaScript, no build) for the security assessment (`framework/.app-director/procedures/security.md`, `/security`):
- `vulnerable/` is seeded with four flaws;
- `clean/` is its twin with each flaw fixed.

The manifests are stored as `package.fixture.json` and `package-lock.fixture.json`, and the credential in `vulnerable/src/payments.js` is a marker (`__SEEDED_SECRET__`), so this repository's dependency and secret scanning don't flag a seeded flaw. The selftest copies each fixture to a temporary folder, renames the manifests to `package.json` and `package-lock.json`, and replaces the marker with a token it assembles at run time.

## The seeded flaws

| # | Flaw | Where | OWASP item | Found by |
|---|---|---|---|---|
| 1 | SQL built by concatenating the search text and the user ID | `vulnerable/src/server.js`, `GET /notes` (the `query(` call) | A05:2025 Injection | the reviewer pass; Semgrep, when installed, may flag it |
| 2 | `DELETE /notes/:id` checks neither the session nor the note's owner | `vulnerable/src/server.js`, the `DELETE` route | A01:2025 Broken Access Control; API1:2023 and API5:2023 for the API | the reviewer pass |
| 3 | A payment key in source | `vulnerable/src/payments.js:2` | A07:2025 Authentication Failures | `tools/security.sh` (the check's gitleaks scan) |
| 4 | `lodash` 4.17.15, which has known advisories | `vulnerable/package.fixture.json` | A03:2025 Software Supply Chain Failures | `tools/security.sh` (`npm audit --omit=dev`) |

`clean/` uses parameters in both queries, checks the session and the owner before a delete, reads the key from `PAYMENT_API_KEY` in the environment, and has no dependencies.

## What the selftest proves
`bash selftest.sh` (section "security assessment"):
- the procedure, the checklist, the skill, `tools/security.sh` and the settings entry exist and name each other, and the release, next-task, rules and reviewer files are wired to them;
- the checklist has a section for each of A01-A10 and API1-API10, and every check is marked code, config or people;
- on the vulnerable copy, `tools/security.sh` reports the credential with its OWASP item and file (needs gitleaks 8.18.0 or later, otherwise skipped with a note) and, where `npm` is installed and the registry answers, the `lodash` advisory under A03 (otherwise skipped with a note);
- with stand-in tools, it labels a dependency audit's findings A03, passes Semgrep's findings through with their file and line, and skips a tool that isn't installed with a note;
- the clean copy gets neither finding and exits 0;
- `tools/security.sh --due` counts built items since the newest report's commit against `[security] every`.

## Manual acceptance check
The reviewer pass needs an agent, so it is checked by hand after a change to the procedure, the checklist or the reviewer:
1. Make a seeded copy: `KEEP=1 bash selftest.sh` prints the temporary folder it keeps; the copy is `security/vulnerable` inside it, with App Director's `tools/` in place. Install the rest with `bash install.sh <that folder>` from this repository, then open the folder in Claude Code.
2. Run `/security`.
3. Expect, in the report at `product/security/<today>.md` and as bug items in TASKS.md:
   - flaw 1 under A05:2025 Injection, severity high, citing `src/server.js` at the `query(` line, with a fix that passes the search text and the user ID as parameters;
   - flaw 2 under A01:2025 Broken Access Control (and API1:2023 in the API section), severity high, citing the `DELETE` route, with a fix that checks the session and adds the owner to the `DELETE`;
   - flaw 3 under A07:2025, severity high, from the tool step, with a human item to rotate the key;
   - flaw 4 under A03:2025, from the tool step when npm reached the registry, otherwise listed under Skipped;
   - the high items at the top of the queue, each `Found in:` the report;
   - a "For the director" list (access reviews, incident response and on-call, key rotation, multi-factor authentication) and the question which to track;
   - a line per category, none marked verified only because a tool passed, and the section "What a clean run doesn't prove".
4. Do the same with `security/clean`: expect no finding for flaws 1-4, A01, A03, A05 and A07 marked verified or with other findings that are real, and the same closing section.
