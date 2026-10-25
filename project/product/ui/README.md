# Screen designs

This folder holds your drawings of the screens and the agent's records of them. You draw; the agent reads your drawing, asks about what it can't tell, and builds the screen.

## The workflow
1. **Capture.** Ask the agent to capture the screens (`/ui-design capture`). Capture needs Node 18 or newer, and once per clone: `cd tools/ui && npm install && npx playwright install chromium`. The screens it captures are the ones listed in `tools/ui/screens.mjs`; its sizes are in `tools/ui_capture.cfg`.
2. **Draw.** Open the starter file in Excalidraw (see "Excalidraw" below) and draw over the screenshot.
3. **Save.** Save it as `director/ui/<screen>.excalidraw`.
4. **Process.** Ask the agent to process it (`/ui-design process <screen>`). After the build, `/ui-design verify <screen>` checks the built screen against the spec.

## What a capture gives you
For each screen the capture writes `product/ui/captures/<screen>.starter.excalidraw`: the screenshot, locked inside a frame named after the screen. Beside it is the `.map.png`. In the starter you also get:
- **Faint grey numbered boxes.** These are the elements the screen has now, numbered as in the `.map.png`. You can drag or resize them (see "Re-arranging a screen"), and hide or delete them whenever you like.
- **Legend text** beside the frame. Delete it once you know it.

## Boxes
- **One rectangle per thing you care about.** Double-click the box to type inside it.
- **The first line is its name** (`Gear list`). The next lines are anything about it, in plain words.
- **Keys are understood when you use them, and never required:**
  - `shows:` what it displays · `does:` or `click:` what using it does · `key:` the keyboard input
  - `size:` `fixed`, `fill` or `fit` · `stick:` `top-left`, `bottom`, `right` ... · `scroll:` `yes`
  - `empty:` what it shows with nothing in it · `hidden when:` ...
- **Exact pixel sizes don't matter; proportions and arrangement do.** Say `size: fixed` or `stick:` when a box must keep its size or its corner.

## Colours
The stroke colour, from Excalidraw's default palette, says what changes:
- green: new
- blue: keep, but move or resize
- red: remove (or a red X over the old element)
- orange: not sure, let's talk
- black: this is how it should be (the agent works out whether it is new or already there)

## Containment, arrows and notes
- **Boxes inside boxes** mean one contains the other, such as a panel holding a list.
- **An arrow from a note to a box** is a comment on that box.
- **An arrow from one box to another** is a flow ("clicking this opens that").
- **Text outside the frame** is notes for the whole screen.

## Patch or replace
Anything you didn't touch stays (`mode: patch`). Write `mode: replace` outside the frame if the screen should hold only what you drew.

## Re-arranging a screen
Drag the grey box to where the element should sit, or resize it. Type keys into it (`size:`, `stick:` ...) if they change. A grey box you don't touch is ignored. A new blue box named after the element (the name from the map) works too.

## Other states and sizes
Add another frame in the same file, named `<screen>.<state>` or `<screen>@1280x720`.

## Processing and verifying
`/ui-design process <screen>` tells you how it read your drawing and asks you about the open points. The result is `product/ui/<screen>.md`, the one place the screen's layout is written down. After the build, `/ui-design verify <screen>` captures the built screen and lists its deviations from the spec, with a compare image.

## Excalidraw
Excalidraw is free and open source, and nothing needs installing. Open [excalidraw.com](https://excalidraw.com) in Chrome, Edge or another browser: no account is needed, and Excalidraw+ isn't. To open your starter, use the menu's Open, or drag the file onto the page. To save, use Save to… (Ctrl+S saves over the file you opened) and save it as `director/ui/<screen>.excalidraw`. Create `director/ui/` if it isn't there. Chrome and Edge let you pick that folder; other browsers save to Downloads, so move the file there and rename it. Your drawing stays on this computer unless you use Live collaboration or a shareable link. You can install Excalidraw as an app from Chrome's or Edge's address bar if you like; it's the same as the website.

## Files
| Path | What it is | Who writes it |
|---|---|---|
| `product/ui/captures/<screen>.starter.excalidraw` | The screenshot in a frame, to draw over | The agent, regenerated on capture |
| `product/ui/captures/<screen>.map.png` | The screen's current elements, numbered | The agent |
| `director/ui/<screen>.excalidraw` | Your drawing | You |
| `product/ui/<screen>.md` | The screen's spec | The agent, after process |
| `product/ui/README.md` | This file | Yours to annotate |

This file is yours: annotate it as you like.
