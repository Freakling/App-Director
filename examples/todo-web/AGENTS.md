# To-Do Web

A minimal to-do list web app. Demonstrates the App Director workflow with the `none` stack (no
compiler or test runner required — only UI purity and secrets checks run).

## Product brief
See `product/brief.md`.

## Architecture

| System | Description | Key files |
|---|---|---|
| UI | Renders the task list and the add-task form | `src/ui/` |
| Services | Business logic: add, toggle, remove | `src/services/TodoService.ts` |
| Store | In-memory state for the current session | `src/store/TodoStore.ts` |

**Rule:** UI components receive a `TodoService` instance. They never import from `src/store/`
directly. The `check.cfg` enforces this: UI files that reach across to the store layer fail the
UI purity check.

## Ownership

| Area | Owner | Placeholder policy |
|---|---|---|
| Code | agent | — |
| HTML / CSS | human | `<!-- PLACEHOLDER: apply visual design -->` |

## Project rules
- Model sizing: on
  - XS: claude-haiku-4-5-20251001
  - S:  claude-haiku-4-5-20251001
  - M:  claude-sonnet-5-5
  - L:  claude-opus-5-5
  - XL: claude-opus-5-5
