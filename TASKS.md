# Tasks

This is App Director's own work queue, for developing the framework itself. It is fed by [Director-Driven Development](https://github.com/Freakling/Director-Driven-Development)'s orchestrator through pull requests. `project/TASKS.md` is a different file: the template shipped to adopters, which never receives these items.

Item format: `framework/.app-director/tasks.md`. Queue order is priority; reorder by moving items.

**Next IDs:** T3 · B4

## Queue

### B3 · The secrets check reports a scan that can't run as credentials found · done · S · agent · med
- Touches: framework/tools/check.sh, selftest.sh
- Repro: install gitleaks 8.19.0, then run `bash tools/check.sh` on a clean tree → expected: the check says gitleaks couldn't scan (exit 3) and hints at an upgrade / actual: "gitleaks found credentials in the working tree", because every scan command fails with "flag accessed but not defined: source" and the check reads that failure as a finding; its comment wrongly says 8.19.0 scans with `detect`, and the selftest's real-gitleaks checks run on 8.19.0 and fail
- Found in: Director-Driven-Development T50
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
