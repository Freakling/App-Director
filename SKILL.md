---
name: app-director
description: 'Sets up App Director in an app: you direct the design while the AI builds it, design calls come to you as options, and one check proves every change works. Use when the user asks to install, set up, upgrade or migrate App Director, or wants a structured AI build workflow for a new or existing app.'
license: MIT
compatibility: 'Any app with a git repository. Needs bash (Git Bash on Windows) and network access to fetch App Director from GitHub unless it is already present.'
metadata:
  author: Freakling
  version: 1.0.0
  repository: https://github.com/Freakling/App-Director
---

Step 1 — Find App Director (`$ADIR`), the folder that holds `ONBOARDING.md` and `install.sh`. Use the first that exists:
- `${CLAUDE_PLUGIN_ROOT}` when running from the Claude Code plugin
- An `App-Director/` folder next to the project root (manual install)
- Otherwise, run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/fetch-app-director.sh"` and use the path it prints as `$ADIR`.

Step 2 — Read `$ADIR/ONBOARDING.md` and follow it for the project in the current working directory, with `$ADIR` set to that folder.
