# Screen designs

Your drawings and the agent's records of each screen. You draw; the agent reads your drawing, asks about what it can't tell, and builds the screen.

## How to draw a screen
1. Ask the agent to capture the screens (`/ui-design capture`). It writes `product/ui/captures/<screen>.starter.excalidraw` for each screen: the screenshot, locked inside a frame named after the screen.
2. Open that file in [Excalidraw](https://excalidraw.com) (in a browser, or as the desktop app; no account needed) and draw over the screenshot.
3. Save it as `director/ui/<screen>.excalidraw` (create `director/ui/` if it isn't there).
4. Ask the agent to process it (`/ui-design process <screen>`). It tells you how it read your drawing and asks you about the open points. The result is `product/ui/<screen>.md`, the one place the screen's layout is written down.

## What to draw
- **One rectangle per thing you care about.** Double-click the box to type inside it. The first line is its name (`Gear list`); the next lines are anything about it, in plain words. These keys are understood when you use them, and never required:
  - `shows:` what it displays · `does:` or `click:` what using it does · `key:` the keyboard input
  - `size:` `fixed`, `fill` or `fit` · `stick:` `top-left`, `bottom`, `right` ... · `scroll:` `yes`
  - `empty:` what it shows with nothing in it · `hidden when:` ...
- **Colour says what changes** (the stroke colour, from Excalidraw's default palette):
  - green: new · blue: keep, but move or resize · red: remove (or a red X over the old element) · orange: not sure, let's talk · black: this is how it should be (the agent works out whether it is new or already there)
- **Boxes inside boxes** mean one contains the other, such as a panel holding a list.
- **Arrows:** from a note to a box is a comment on that box. From one box to another is a flow ("clicking this opens that").
- **Text outside the frame** is notes for the whole screen. Write `mode: replace` there if the screen should hold only what you drew; otherwise anything you didn't touch stays (`mode: patch`).
- **Exact pixel sizes don't matter; proportions and arrangement do.** Say `size: fixed` or `stick:` when a box must keep its size or its corner.
- **Another state or size of the same screen:** add another frame in the same file, named `<screen>.<state>` or `<screen>@1280x720`.

The faint grey boxes with numbers in the starter drawing are what the screen has now, numbered as in the `.map.png` next to it. Hide or delete them whenever you like, and delete the legend text beside the frame once you know it.

This file is yours: annotate it as you like.
