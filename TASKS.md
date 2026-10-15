# Tasks

This is App Director's own work queue, for developing the framework itself. It is fed by [Director-Driven Development](https://github.com/Freakling/Director-Driven-Development)'s orchestrator through pull requests. `project/TASKS.md` is a different file: the template shipped to adopters, which never receives these items.

Item format: `framework/.app-director/tasks.md`. Queue order is priority; reorder by moving items.

**Next IDs:** T2 · B2

## Queue

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
