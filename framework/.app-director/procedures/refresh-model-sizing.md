<!-- App Director · framework-owned: replaced on upgrade. -->
# Refresh model sizing

Set or update the Model sizing block in AGENTS.md › Project rules so that each task size maps to a specific model ID.

## 0. Capability check
Before writing anything, verify both:
- You can spawn subagents (the `builder` agent definition exists in `.claude/agents/`).
- You can pass a different `model:` per subagent call.

If either is missing, tell the human and stop — do not write any block to the project rules.

## 1. Propose defaults
For Claude Code, propose:
```
- Model sizing: on
  - XS: claude-haiku-4-5-20251001
  - S:  claude-haiku-4-5-20251001
  - M:  claude-sonnet-5-5
  - L:  claude-opus-5-5
  - XL: claude-opus-5-5
```
(`claude-fable-5-1` is an alternative for `XL` when using Claude platform credits.)

For other tools, apply the same tier logic — fast/cheap for XS and S, balanced for M, most capable for L and XL — using that tool's available model IDs.

Show the proposed block and ask the human whether to accept or change any entry.

## 2. Write the block
In AGENTS.md › Project rules, replace any existing `Model sizing` lines with the agreed five-entry block. If model sizing was off, set it to on.

## 3. Confirm
Report the written block and note that `/refresh-model-sizing` can update it at any time.
