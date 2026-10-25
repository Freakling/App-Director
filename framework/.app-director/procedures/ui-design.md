<!-- App Director · framework-owned: replaced on upgrade. -->
# UI design

The human designs screens by drawing over screenshots of the running app; you capture the screens, read the drawings through a reader, record each screen's layout once in a screen spec, and report what you find. This procedure covers listing and capturing the screens, processing a drawing, and verifying a built screen against its spec. The human decides; you propose. Every step has a text path, for an assistant that can't view images: it is named in the step, and gathered under "If you can't view images" at the end.

Requests:
- `list`: the screens in the catalog.
- `capture [screen|all]` (default `all`).
- `process <screen>`: read the human's drawing of a screen and record it.
- `verify <screen>`: check the built screen against its spec, and write the compare images.
- No argument: `list`, then ask which screen.

## The catalog
`tools/ui/screens.mjs` (project-owned) lists every screen: an `id`, a `title`, the `route` capture opens, and optionally `states` (such as `default` and `empty`), `auth` (a test account's saved sign-in in the gitignored `tools/ui/.auth/`), `source` (the file that renders it) and `animate` (for a screen whose animations can't be stopped). The entry format and the state functions are documented at the top of the file. A state seeds its data through the app's public API (the `api` helper it is given), never real user data; it can open the screen itself and prepare it, such as opening a dialog. If the screen you're asked about has no entry, add one first (`rules.md` › Architecture defaults › UI layer). Sizes, the seed, the lint thresholds, the app to open and screens never captured are in `tools/ui_capture.cfg`.

`tools/ui_capture.sh` runs Node and Playwright, kept apart from the app in `tools/ui/` (its own `package.json`). It needs Node 18 or newer, and once per clone: `cd tools/ui && npm install && npx playwright install chromium`. The app's own check never needs them.

Capture opens only the app on this machine: `tools/ui_capture.cfg` › `[web] base_url` (or `baseUrl` in the catalog), which must be `localhost`, `127.0.0.1` or a host in `[web] allow_hosts`; it refuses any other, so it never opens a deployed site. `[web] start_command` starts the app when nothing answers (its output goes to `.app-director/state/ui_app.log`), and capture stops it afterwards; if a capture was killed before it could, the next capture stops that app first. An app with no web UI (native Flutter, mobile or desktop) leaves `base_url` empty: capture isn't available for it yet, while `list`, `process` and verify's check of the spec's names still work.

## list
1. Run `bash tools/ui_capture.sh --list`. Each line has a screen's id, title, states, the route it opens, and whether a drawing (`director/ui/<id>.excalidraw`) and a spec (`product/ui/<id>.md`) exist.
2. Run `bash tools/ui_capture.sh --missing`. It lists the files in the UI folders (`tools/check.cfg` › `[ui] dirs`) that look like screens (in a `pages`, `screens`, `views`, `routes` or `app` folder, or named like `OrdersPage.tsx` or `orders_screen.dart`) that no catalog entry names as its `source` and that `[capture] skip` doesn't name, as `missing:` lines. It only lists: it never fails. Add an entry for each (with its `source`), or add the file to `skip` when it isn't a screen. With no UI folders set it says so and lists nothing.
3. Show it as a short table. A `FAIL` line is a catalog entry with a problem (an unknown key, a duplicate id, no title, a route that isn't a path, a state that isn't a function): fix the entry.

## capture
1. Run `bash tools/ui_capture.sh <screen>`, or `--all`. `--state <name>` narrows it; `--size <W>x<H>` captures one size, listed in `tools/ui_capture.cfg` or not. Chromium runs headless, so no display is needed.
   - Exit 3: say capture couldn't run and why, and stop. The causes: no Node 18, Playwright or Chromium not installed in `tools/ui` (it prints the command), no web app to open (`base_url` empty), a host that isn't this machine, or the app that didn't start. It wrote nothing.
   - Exit 1: something failed, and the run went on with everything else. The causes, each named in a `FAIL` line:
     - a screen's page threw an error (it is still captured, with the error at the top of its `.lint.txt`), its route answered with an error, its state threw, or it didn't finish within `[capture] setup_timeout` seconds (the error is its whole `.lint.txt`);
     - a catalog entry has a problem, or `tools/ui/screens.mjs` doesn't load (when you capture one screen, a problem in another entry is only noted);
     - the page changed while it was being mapped, such as a reload when an element got the focus;
     - the screen or state named doesn't exist, an option is unknown, or `tools/ui_capture.cfg` has a size that isn't `WxH`.

     Fix what's in the catalog, the settings or the screen; report the rest.
2. The outputs are in `product/ui/captures/` (gitignored), per screen, state and size, named `<id>[.<state>]@<W>x<H>` (no state for `default`):
   - `.png`: the screenshot of the viewport, as a user sees the window at that size.
   - `.elements.json`: the element map. Each mapped element has a number `n`, its `id` (the `data-testid` when `stable` is true, else its role and name), `path` (a CSS selector), `kind` (its role), its accessible name, `rect` in pixels and `rect_pct` in percent of the capture, `focusable` and `focus_order` (its place in Tab order from the default focus, `null` when Tab never reaches it), `overflow`, `min_size` (the size its content needs), and the tag, tabindex, `aria-` attributes and selector under `native`.
   - `.map.png`: the screenshot with every element outlined and numbered, so you and the human can say "element 4".
   - `.lint.txt`: one finding per line, `<rule> element <n> <path>: <message>`; empty when clean. `note: blocked requests to <host>` lines name the hosts the page tried to reach that aren't this machine: tell the human, since the screen may lack what those would have loaded.
   - `<id>.starter.excalidraw`: the drawing to draw over, written with the images for the default state at the default size (the first of `[sizes] list`).
3. Look at each `.png` and its `.lint.txt`; if you can't view images, use `.elements.json`. Report what you find in one line each. The lint rules:

   | Rule | Finding |
   |---|---|
   | `squeezed-text` | Wrapping text narrower than `min_label_chars` average characters, or text wider than its box with no ellipsis |
   | `stretched-control` | A button or link taller than `max_button_height_ratio` times its content height, padding and border |
   | `off-screen` | An element leaving the viewport sideways, or its `overflow: hidden` parent (content below the fold, and content a parent scrolls, such as a carousel, are fine) |
   | `overlap` | Two focusable siblings overlapping where the upper one takes the clicks |
   | `unreachable` | An enabled focusable element that Tab never reaches from the default focus (also everything after a focus trap; what an open modal dialog covers is fine) |
   | `no-default-focus` | An open dialog with focusable elements and the focus outside it (a plain page is fine without focus) |
   | `hard-coded-position` | `position: absolute` or `fixed` with `left` or `top` in pixels inside a flex or grid container (a warning) |

   Lint findings never change the exit code. A finding that is a real bug becomes a `B` item once the human agrees (at once inside a `/next-task` run).

4. Tell the human, in these words: "Nothing to install. Open excalidraw.com in Chrome, Edge or another browser: no account is needed, and Excalidraw+ isn't. Open `product/ui/captures/<id>.starter.excalidraw` from the menu's Open, or drag it onto the page, and draw over the screenshot. To save, use Save to… (Ctrl+S saves over the file you opened), and save it as `director/ui/<id>.excalidraw`: Chrome and Edge let you pick that folder; other browsers save to Downloads, so move the file there and rename it. Your drawing stays on this computer unless you use Live collaboration or a shareable link. Tell me when it's saved." Point at `product/ui/README.md` the first time. You never write in `director/`: if `director/ui/` doesn't exist, ask the human to create it.

A capture keeps every screen on this machine: each request and WebSocket the page makes to another host is blocked and noted, redirects are followed only while they stay here, and the `api` helper follows none. A dev server whose page calls a hosted backend is captured without that backend's data. A capture opens each screen and state in a fresh browser context: clean storage, the test account's saved sign-in when the entry names one, and nothing kept from the screen before. Animations and transitions are stopped, the clock is fixed, `Math.random` is seeded, and the locale (`en-US`) and time zone (UTC) are fixed, so two captures of the same state and size on the same machine give the same element map and image. A capture changes no source file and commits nothing; it writes only in `product/ui/captures/`.

## The lint and the check
The layout lint runs in capture, in verify and in a build's Screens step, never in `bash tools/check.sh`: it needs a browser and a running app, and the check needs neither. A finding is fixed in the item that touches the screen, or filed.

## process
`process <screen>` reads `director/ui/<screen>.excalidraw`. If the screen has no drawing, say so and point at its starter drawing (capture it first if it isn't there).
1. **Read.** Run the reader (it needs Node, not Playwright): `node tools/ui/drawing.mjs director/ui/<id>.excalidraw product/ui/captures/<id>.drawing.json <id>`. Then read `<id>.drawing.json`. Never read the raw `.excalidraw`: it embeds the screenshot as base64. Exit 1 means it isn't valid JSON, isn't an Excalidraw file or has no frame: say which, and stop. To tell what a box overlaps, the reader uses the element map of the frame's state and size in `product/ui/captures/`, so capture the screen first when it's missing.
2. **Also read** the current spec if there is one, the screen's latest `.elements.json`, the brief sections the screen implements and the related lines in `product/decisions.md`.
3. **Brief the human**, as `design.md` does: what the screen is for, what the drawing changes, element by element, such as:
   - `Gear list (new): a scrolling list on the right third, under the portrait; shows each slot and its item; clicking a row opens Change.`
   - `Belt row (moved): was beside the slots, now its own row above them.`
   - `Repair button (removed).`

   Include what the drawing leaves ambiguous, every `unparsed` entry, and anything it conflicts with: recorded rules, project rules, other screens' specs (Back in the same place).
4. **Confirm the reading** ("Is this what you drew?"). Then, for each open point, offer 2-4 options with a recommendation, as `design.md` › For each question does. Typical open points: what a box does at another size (a phone, a wide screen), what happens when a list is empty or overflows, the keyboard focus order, which element has focus when a dialog opens, the keys for new actions.
5. **Record in one change**, once the human has settled the points:
   - `product/ui/<id>.md` (the template below), replacing superseded content.
   - `product/decisions.md`: one line per real decision, in its format, with `from: drawing director/ui/<id>.excalidraw`.
   - The brief only when the drawing changed what the screen does (a new action, a removed feature); layout lives in the spec. A point left undecided becomes an open question (`Q<n>`, bump the counter), and the spec's Open section names it.
   - `TASKS.md`: one item per screen (split an `L`), with `UI: product/ui/<id>.md`, `Touches`, a tagged `Done when` and the `Brief:` line. The usual outcomes: every element in the spec exists under its `data-testid` and the screen opens without errors `(test)` · the capture is lint-clean at every configured size and matches the spec within tolerance `(check)` · the screen reads as drawn and works by mouse, touch and keyboard where the app supports them `(demo)`.
6. **Commit** as `docs: ui <id>` once the human approves, then suggest a fresh session before the next screen (`design.md` › Finish).

## verify
`verify <screen>` checks the built screen against `product/ui/<id>.md`, and writes the compare images. It needs the spec; if there is none, say so and point at `process`.
1. Run `bash tools/ui_capture.sh <id> --verify`. It captures the screen (every state and size), then reads the spec, the element maps and the lint files and prints the result. Exit 0: no deviations. Exit 1: deviations, or the capture failed. Exit 3: it couldn't capture (as `capture`), or there is no spec or no capture to check. When it couldn't capture, it still prints whether each name in the spec's Layout table is in the source (the UI folders), and the item's `(check)` outcome about the capture stays unverified: say so plainly.
2. Read the table it prints, one row per element of the spec's Layout table, against the capture at the size in the table's heading (`## Layout (at 1920x1080)`):

   | Check | Deviation when |
   |---|---|
   | Present | no visible element has that `data-testid` |
   | Where | an edge of the element's `rect_pct` is more than `[verify] tolerance_pct` (default 4.0, percent of the screen) from the spec's Where |
   | Reachable | the element is focusable and its `focus_order` is `null` |
   | Lint-clean | a lint finding names the element (a `hard-coded-position` warning is listed, not a deviation) |

   It also lists the elements with a `data-testid` that the spec does not, the lint findings in the screen's other states and sizes, and a drawn box whose element has since moved away from it (with both rectangles; this needs `<id>.drawing.json`).
3. Compare the focus order with the spec's Navigation section: the table shows that an element is reachable, and `.elements.json` gives each element's `focus_order`. Check it against the order the spec writes down.
4. With a drawing processed, `product/ui/captures/<id>[.<state>].compare@<W>x<H>.png` is written for every captured size: the screenshot the drawing was made over on the left, the new capture on the right with the drawing's boxes outlined, labelled `b1`, `b2` ... as in `<id>.drawing.json` and coloured by intent (green new, blue keep, red remove, orange unsure, dark default). Look at it if you can; the table says the same in text.
5. Report the deviations as a short table (element, expected, found, verdict). Fix the in-scope ones in the same item, and file the rest as `B` items once the human agrees (at once inside a `/next-task` run). A build item reports it as its `Screen:` line.

`node tools/ui/overlay.mjs compare product/ui/captures/<id>@<W>x<H>` redraws one compare image without a capture.

### Reading a drawing
The conventions the human follows are in `product/ui/README.md`. The reader (`tools/ui/drawing.mjs`, a port of Godot Director's reader that gives the same `drawing.json` for the same drawing) turns them into `<id>.drawing.json` (`"schema": 1`), with one entry per frame:
- Frames are named `<id>`, `<id>.<state>` or `<id>@<W>x<H>`. `name` is the screen, `state` defaults to `default`, and `size` is the background image's size in pixels.
- `boxes`: one per rectangle, `id` being `b1`, `b2` ... in the file's order. The text bound to the rectangle is its `text`; its first line is the `label`, and `keys` holds the lines that start with `shows`, `does`, `click`, `key`, `size`, `stick`, `scroll`, `empty` or `hidden when`.
- `intent` comes from the stroke colour: `new` (green), `keep` (blue), `remove` (red), `unsure` (orange), else `default`.
- The grey `existing` boxes of the starter (`customData.ddd` is `existing`; `customData.n` is the element's number in the element map, `customData.rect` the rectangle it was drawn at, in capture pixels) are skipped while they still sit at that rectangle, when they are deleted, hidden or locked, and when they carry no `rect` (an older starter). One the human dragged or resized by more than 2 pixels in position or size, compared with its own `rect` and never with the current map, so a screen recaptured since changes nothing, is read as a box with `intent` `keep`, as if the human had drawn a blue box over that element: its `label` is the element's name (the map's `id`), its `rect_pct` is the new place, and what the human typed into it is read for keys as in any box (a first line that differs from the name stays in `text`). It has two extra fields, `"from": "existing"` and `n`, so `process` can say "you moved 4 (Gear list)". Without the element map for the frame's state and size, or when the map no longer has that element, a moved grey box is skipped and the reader prints a note. One dragged outside every frame is listed in `unparsed`. The reader also prints a note when one element is claimed twice: by a moved grey box, a blue box named after it, or a red X. The number labels are never read.
- `rect_pct` is `[x, y, w, h]` in percent of the background image, to 0.1: the layout at the capture's size, the same wherever the image sits and however it is scaled.
- `parent` is the smallest box that fully contains it. `flows_to` lists the boxes an arrow leads to. `overlaps` lists the mapped elements it covers, when their intersection over union is above 0.2, as `{"n", "name", "iou"}`: how you tell a new box from one drawn over an existing element.
- `comments`: free text within 1.5 times its own height of a box, or joined to it by an arrow. Other text in the frame is a frame note, and text outside every frame is a note for every frame. `mode` is `patch` (what the human didn't touch stays) unless a note says `mode: replace`.
- `removed`: the mapped element a red X is over, as `{"n", "name", "by": "red-x"}`.
- `unparsed`: what the reader didn't understand, such as a freehand line, an ellipse or a red line that isn't part of an X. Ask about each; never guess.

### The screen spec
`product/ui/<id>.md` is the one place a screen's layout is recorded. The percentages guide the layout system and aren't positions: build with flex or grid, never pixel positions. `Name` is the `data-testid` the build must give the element (`gear-list`), and the Layout table is what verifying the screen checks.

```markdown
# Hero room
**Opens:** /heroes/:id · **Catalog:** hero_room (default, exhausted)
**Drawing:** director/ui/hero_room.excalidraw (sha1 3f2a..., processed 2026-10-16) · **Brief:** Heroes and Staff › Hero rooms

## Purpose
One or two lines: what the user does here.

## Layout (at 1920x1080)
| # | Element | Name | Where (x, y, w, h %) | Shows | Does | Size |
|---|---|---|---|---|---|---|
| 1 | Hero sheet | hero-sheet | 1, 11, 20, 70 | stats, morale, backstory | - | fixed width, fills height |
| 2 | Gear list | gear-list | 62, 12, 34, 60 | each slot and its item | click: Change | fill, scrolls |

## Navigation
Default focus · focus order · Back · keys for each action.

## Other sizes
Wide, laptop, tablet or phone: what grows, what moves, what hides.

## States
Empty, loading, error, signed out: what differs.

## Open
Undecided points, each with its `Q<n>` if it went to the open questions.
```

## If you can't view images
Each step has a text path; none needs a picture.

| Step | Read instead |
|---|---|
| `capture` | `<id>@<W>x<H>.elements.json` (every element's position, name, focus order and overflow) and `.lint.txt` |
| the starter drawing | nothing to read: it is for the human to draw over |
| `process` | `<id>.drawing.json`, the spec, and `.elements.json` for what the boxes cover |
| `verify` | the table `bash tools/ui_capture.sh <id> --verify` prints, and `.elements.json` for the focus order; the compare image repeats it |
| a `UI:` item's build, review and acceptance check | the same table and lint output, in the builder's `Screen:` line |
