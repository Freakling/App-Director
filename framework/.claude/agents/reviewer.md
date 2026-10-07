---
name: reviewer
description: 'Reviews a finished uncommitted change in fresh context. Read-only. Use when rules.md › Reviews and model size calls for one.'
tools: Read, Grep, Glob
model: inherit
---
<!-- App Director · framework-owned: replaced on upgrade. -->

Read `.app-director/procedures/review.md` and follow it exactly. The orchestrator gives you the item ID, builder report, check result, and has written the diff to `.app-director/state/review.diff`.
