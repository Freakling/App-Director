---
name: app-director
description: 'Sets up App Director in an app: you direct the design while the AI builds it, design calls come to you as options, and one check proves every change works. Use when the user asks to install, set up, upgrade or migrate App Director, or wants a structured AI build workflow for a new or existing app.'
---

Step 1 — Find App Director (`$ADIR`), the folder that holds `ONBOARDING.md` and `install.sh`. Use the first that exists:
- `${CLAUDE_PLUGIN_ROOT}` when running from the Claude Code plugin
- An `App-Director/` folder next to the project root (manual install)
- Otherwise, fetch it outside the project:
  ```bash
  ADIR="${TMPDIR:-/tmp}/app-director"
  if [ -d "$ADIR/.git" ]; then git -C "$ADIR" pull --ff-only; else git clone --depth 1 https://github.com/Freakling/App-Director.git "$ADIR"; fi
  ```

Step 2 — Read `$ADIR/ONBOARDING.md` and follow it for the project in the current working directory, with `$ADIR` set to that folder.
