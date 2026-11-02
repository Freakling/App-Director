<!-- App Director · framework-owned: replaced on upgrade. -->
# Prototype

Try a change fast, such as a flow or a screen, so the human can feel how it works before it's built against the product. A prototype runs in its own session, in a git worktree beside the project on a `proto/<name>` branch, outside the loop in `rules.md`: no items, no records, no builder, no reviews and no check on its commits. What's worth keeping reaches main only through the harvest, as decisions, user stories and items that are built from main like any other. `bash tools/prototype.sh` does the git steps; it never pushes, merges or deletes a branch. Prototypes start from, and are compared with, the `main` branch.

- `<name>`: start a prototype (Start).
- `list`: `bash tools/prototype.sh list` shows each `proto/` branch, its worktree folder (or `no worktree`) and its commits since main.
- `harvest <name>`: turn one into decisions, user stories and items, then offer to remove it (Harvest).
- `remove <name>`: remove one without a harvest, when the human asks (Harvest, step 3).

## Start
In the main session; a prototype session doesn't start another.
1. **Name.** Lowercase letters, digits and dashes, such as `quick-add`. When the human gave none, propose one from what they want to try.
2. **Create it:** `bash tools/prototype.sh start <name>`.
   - It refuses an invalid name, and a name whose branch (`proto/<name>`) or folder already exists: say which, and ask for another name. An existing prototype goes on in its own session, or is harvested.
   - It also refuses, creating nothing, when a prototype's only gates aren't in place: main without the committed hooks and `tools/prototype.sh` (commit the App Director upgrade first), this clone without App Director's pre-commit and pre-push hooks (run `bash tools/setup-clone.sh` here), or no gitleaks on PATH (setup-clone says how to install it). Say which, and start again once it's fixed.
   - Exit 5: `origin/main`, as last fetched, has commits `main` doesn't, so it created nothing. Tell the human, and offer to bring main up to date first, with this checkout on main, by `git pull --ff-only` (they approve it), or to start from main as it is: `bash tools/prototype.sh start <name> --as-is`.
   - Otherwise it creates the worktree `../<project folder>-proto-<name>` on the new branch `proto/<name>` from `main` as this checkout has it, with no upstream, runs `bash tools/setup-clone.sh` there, and writes and commits its `PROTOTYPE.md`: the human's notes, under What we're trying, How it felt and What to keep. Uncommitted changes in this checkout don't go with it.
   - Exit 4: the prototype exists, but setup-clone or the first commit needs attention; show its lines. Don't open its session (step 4) until `bash tools/setup-clone.sh` passes in the new folder and `PROTOTYPE.md` is committed there.
3. **Before captures.** Where the app has a web UI (`tools/ui_capture.cfg` › `[web] base_url` is set), offer to capture the screens the prototype will change, now and in this checkout, as the before (`ui-design.md` › capture). A capture opens whatever answers at `base_url`, so no other checkout's app may be running there.
4. **Open its session,** once setup-clone has passed there. Start a session in the new folder where the tool can. Otherwise tell the human how: in Claude Code, open a new terminal there and run `claude`. Tell them too:
   - gitignored files aren't in the worktree: if the app needs its `.env` to run, they copy it there themselves (you never read or copy it), and dependencies are installed as in any new clone;
   - notes go in its `PROTOTYPE.md` as they try things;
   - the harvest is back in this session: `/prototype harvest <name>` in Claude Code.

## In a prototype session
A session in a checkout that `bash tools/prototype.sh here` calls a prototype: a linked worktree on a `proto/` branch with `PROTOTYPE.md` at its root. Here the loop in `rules.md` is off:
- **No loop.** No items, claims or records (TASKS.md, AGENTS.md, `product/`), no builder and no reviews; a request for one belongs in the main session. Change what the human wants to try, directly and quickly: the smallest change that lets them feel it beats a complete one, since only what the harvest takes forward is built for real.
- **Commits need no approval.** Commit as often as helps, as `proto: <what changed>`. The pre-commit hook skips the project check in a prototype and still scans the staged changes for secrets; a finding blocks the commit, as anywhere, and so does a missing gitleaks or a `.gitleaksignore` or `.gitleaks.toml` that differs from main's, since the scan is the only gate here. Allowlisting a secret goes through the human in the main session, as `rules.md` › Secrets says. Run the check yourself when it helps; it gates nothing here.
- **Still on:** the guard, the secrets rules and scan (`rules.md` › Architecture defaults › Secrets) and Protected space.
- **Nothing is pushed or merged.** Never push a `proto/` branch or its commits under another name (the pre-push hook refuses both), merge it into another or merge another into it.
- **Notes.** `PROTOTYPE.md` holds what was tried, how it felt and what to keep, in the human's words. Write down what they say there when they tell you, and commit it with the work; the harvest reads it.
- **After captures.** Where the app has a web UI, offer to capture the screens the prototype changed (`ui-design.md` › capture) when the human wants to compare: they land in this worktree's `product/ui/captures/` under the same names as the before in the main checkout's. A capture opens whatever answers at `base_url`, so the main checkout's app, or any other, may not be running there.
- **Done.** When the human has seen enough, commit everything, ask them to stop the prototype's app and close this session, and send them back to the main session for the harvest.

## Harvest
In the main session, `harvest <name>`:
1. **Read.** `bash tools/prototype.sh harvest <name>` prints the commits, the files changed since main with the command for the diff, the worktree's uncommitted changes and its `PROTOTYPE.md`; it changes nothing. The diff leaves out what isn't committed: ask the human to commit it in the prototype session first, or to harvest without it. Then read the diff it names, `git diff main...proto/<name>` (three dots: what the prototype changed, not what main gained since), file by file (`-- <path>`) when it's large. Show the after captures next to the before when both exist.
2. **Design.** Run `design.md` on them, as its Harvest a prototype section says: options, a recommendation, and the human decides. It proposes the decisions, user stories and items, each naming the prototype. Nothing is filed without the human's answer.
3. **Remove.** Then offer to remove the prototype, and do only what the human says yes to:
   - **The worktree:** first ask the human to stop the prototype's app and close its session, since a folder in use can't be removed. Say that the folder goes with everything in it, ignored files too: a copied `.env`, installed dependencies such as `node_modules`, and the after captures. Then run `bash tools/prototype.sh remove <name>`. It runs `git worktree remove`, which refuses a worktree with uncommitted or untracked changes; when it fails, show its lines, and ask the human to commit or delete those changes in the prototype session, or to free the folder. Never force it: `--force` discards them, and the guard blocks it. The branch keeps the commits, so an item's builder can still read the prototype's code.
   - **The branch:** a prototype is never merged, so `git branch -d` refuses it and deleting it takes `git branch -D`, which discards its commits; the guard leaves that to the human. Ask them in these words: "To delete the prototype's branch and its commits, run this in a terminal in the project folder: `git branch -D proto/<name>`." While an item that names the prototype isn't built yet, say that its builder can read the prototype's code only while the branch is kept.
