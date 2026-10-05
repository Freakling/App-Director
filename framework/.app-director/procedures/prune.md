<!-- App Director · framework-owned: replaced on upgrade. -->
# Prune

Keep the queue short to read.

1. Move every `done` item, with its heading and fields unchanged, from TASKS.md to the end of `TASKS-archive.md`. If the archive doesn't exist yet, create it with the heading `# Tasks archive` and the line "Done items, moved here unchanged. IDs are never reused." Items that still depend on an archived ID are fine, because the next-task procedure looks in the archive.
2. Delete lines under TASKS.md › Notes that are no longer true.
3. Leave `Next IDs` and the milestones unchanged.
4. Commit as `docs: prune tasks` after the human approves.
