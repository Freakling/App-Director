# Tasks

## Milestones

| # | Name | Status |
|---|---|---|
| M1 | Core task management | done |

## Next IDs
T4 · B1

---

### T1 · Project scaffold · XS · done
Set up `src/` layout with `ui/`, `services/`, and `store/` layers. Add `tools/check.cfg` with
the `none` stack and purity rules. Confirm `bash tools/check.sh` passes.
Touches: src/, tools/check.cfg

### T2 · TodoStore · S · done
Implement `TodoStore`: `add`, `getAll`, `toggle`, `remove`. In-memory only.
Touches: src/store/TodoStore.ts

### T3 · TodoService and TodoList · S · done
Implement `TodoService` wrapping the store. Implement `renderTodoList` in the UI layer that
receives a `TodoService` instance; no direct store access.
Touches: src/services/TodoService.ts, src/ui/TodoList.ts

### Q1 · Persistence · human
Should completed tasks survive a page refresh?
Options: (a) localStorage: simple, no server; (b) REST API: needs a backend; (c) no persistence: session only.
Recommendation: (a) localStorage for now; add a backend when needed.
Depends on: -

### T4 · Add-task form rendering · XS · todo
Add `renderAddForm()` to `src/ui/TodoList.ts` that returns an HTML string with an input and an
Add button. No logic; just markup.
Touches: src/ui/TodoList.ts
Depends on: T3
Done when: (code) `renderAddForm` is exported from `src/ui/TodoList.ts` · (check) check passes
