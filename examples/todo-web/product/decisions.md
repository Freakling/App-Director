# Decisions

| Date | From | Decision |
|---|---|---|
| 2026-10-07 | brief | Stack: `none` — no compiler or test runner; UI purity and secrets checks only. |
| 2026-10-07 | brief | Architecture: three-layer — UI renders, services hold logic, store holds state. UI never touches the store directly. |
| 2026-10-07 | brief | Persistence: session-only for now. Q1 tracks the localStorage / backend decision. |
