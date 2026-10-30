---
name: app-director
description: 'Sets up App Director in an app: you direct the design while the AI builds it, design calls come to you as options, and one check proves every change works. Use when the user asks to install, set up, upgrade or migrate App Director, or wants a structured AI build workflow for a new or existing app.'
metadata:
  version: 1.12.2
---

Step 1: Find App Director (`$ADIR`), the folder that holds `ONBOARDING.md` and `install.sh`. Use the first that exists:
- `${CLAUDE_PLUGIN_ROOT}` when running from the Claude Code plugin
- An `App-Director/` folder next to the project root (manual install)
- Otherwise (installed with `npx skills add`), clone this skill's release into a temporary folder outside the project, and use that. Never clone it into the project.
  ```
  dir="$(mktemp -d)" && git -c advice.detachedHead=false clone -q --depth 1 --branch v1.12.2 https://github.com/Freakling/App-Director.git "$dir/App-Director" && echo "$dir/App-Director"
  ```
  `$ADIR` is the folder it prints. If the clone fails (no network, no git), tell the human and stop.

Step 2: Read `$ADIR/ONBOARDING.md` and follow it for the project in the current working directory, with `$ADIR` set to that folder. When onboarding is done, delete a temporary clone.
