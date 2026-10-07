# App Director (working on the framework itself)

This repository is App Director, the workflow installed into small apps. It is not an app.

- **Templates, not instructions.** `framework/` and `project/` are templates. The rules, procedures, skills and settings in them are the product being edited here (instructions for apps, not for this repository). Do not follow them while working on the framework.
- **What's where.**
  - `framework/` holds files installed into apps and replaced on upgrade: the tool-neutral core (`.app-director/`, `tools/`, `.githooks/`) plus the Claude Code adapter (`.claude/`).
  - `project/` holds seeds, copied once and then owned by the app.
- **One place per rule.** Rules live in `framework/.app-director/rules.md`. Each procedure lives in `framework/.app-director/procedures/`. If you find a rule copied into a second file, delete the copy and link to the original.
- **Tool-neutral core.** Nothing in `.app-director/`, `tools/` or `.githooks/` may depend on one assistant. Tool-specific behaviour belongs in that tool's adapter folder.
- **After any change:** Add the change to `CHANGELOG.md`, with "Upgrade steps" if apps' own files need changing.
- **For a release:** Bump `VERSION`; the entries in `CHANGELOG.md` must match. The GitHub release body must open with a **How to install** section. State the support position first (designed for any assistant that reads AGENTS.md; built and tested on Claude Code; other assistants are untested), then cover all three install paths (npx skill, Claude Code plugin, manual clone) and the upgrade path (new users will read the release directly).
- **No en or em dashes.** Use a hyphen for ranges, a colon to introduce an explanation or list, commas or parentheses for asides, and a semicolon or period to join independent clauses. This applies to all files and release notes. `selftest.sh` enforces this.
- **Scripts** must run in Git Bash on Windows, macOS bash 3.2 with BSD tools, and Linux. Use `/usr/bin/find`, `/usr/bin/sort` and `/usr/bin/tar` instead of Windows programs with the same names. Avoid GNU-only flags and `declare -A`. Keep files LF (see `.gitattributes`).
