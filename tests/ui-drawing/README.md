# Reader fixtures

Shared with Godot Director, whose reader the App Director reader (`framework/tools/ui/drawing.mjs`) ports. `selftest.sh` reads them.

- `fixture.excalidraw`, `fixture-scaled.excalidraw`, `fixture.elements.json`, `fixture.expected.json`, `fixture.png` and `starter.expected.excalidraw` are copies of Godot Director's `tests/ui-drawing/`.
- `fixture.godot.drawing.json` and `fixture-scaled.godot.drawing.json` are what Godot Director's reader (`framework/tools/ui_drawing.gd`) wrote for the two drawings, run with Godot 4.7.2 from a folder holding them as `drawing_fixtures/`. The selftest checks that this reader writes the same text.
- Source: Godot Director v4.3.0, commit 4b34da9 (`fixture-conflict.excalidraw` too). The two `.godot.drawing.json` files were written by that reader with Godot 4.7.2 and match this reader's output byte for byte. When Godot Director's reader changes after that, regenerate the two files from the new release and port the change, so the readers stay the same.
