# {{APP_NAME}}

{{ONE_PARAGRAPH_DESCRIPTION}}

Instructions for AI assistants working on this app. The workflow is App Director: its rules are in `.app-director/rules.md`, which names the procedure for each kind of request. Read it before any work, unless your tool has already loaded it (Claude Code imports it: @.app-director/rules.md).

## Project facts
- Stack: {{STACK}} · {{PLATFORMS}}
- Storage: {{STORAGE}}
- API: {{API_OR_NONE}}

## Layout
<!-- The real folders of this project. Onboarding fills this in; keep it current when folders move. -->
| Folder | Holds |
|---|---|
| `src/screens/` or `src/pages/` | UI layer: screens and pages (display only, no data-layer imports) |
| `src/components/` | UI layer: shared display components |
| `src/services/` or `src/hooks/` | Logic layer: business logic, state management |
| `src/stores/` or `src/providers/` | Logic layer: state containers |
| `src/api/` or `src/data/` | Data layer: storage and network access |
| `src/repositories/` | Data layer: data-access abstractions |
| `tests/` | Tests |

## Architecture
One row per significant system: what it owns and where its boundary is.

| System | Owns | Where | Talks to |
|---|---|---|---|

## Project rules
<!-- Only where this project differs from App Director defaults, as agreed with the human.
Examples:
- Model sizing: on (recommended on; Claude Code only)
- No git remote: never push.
- The agent may generate copy and placeholder images; all other assets stay human-made.
-->
