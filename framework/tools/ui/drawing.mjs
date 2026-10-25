// Screen drawings: the reader and the starter drawing · framework-owned: replaced on upgrade.
//
// The reader turns a drawing the human made in Excalidraw into drawing.json, which is small and
// holds no image (the raw .excalidraw embeds the screenshot as base64, so never read it):
//   node tools/ui/drawing.mjs director/ui/<id>.excalidraw product/ui/captures/<id>.drawing.json [<id>]
// An id limits the reading to the frames of that screen. The format and the rules are in
// .app-director/procedures/ui-design.md › Reading a drawing. To tell what a box overlaps, it reads
// the element map of the frame's state and size (`<id>[.<state>]@<W>x<H>.elements.json`) from the
// folder it writes to, when that file is there.
//
// The starter drawing is what the human draws over. tools/ui/capture.mjs calls starterText() for the
// default state at the default size; this writes the same from a capture's files:
//   node tools/ui/drawing.mjs starter product/ui/captures/<id>@<W>x<H> <out>.excalidraw
// Everything in the starter that isn't the human's carries customData.ddd, and the reader skips it,
// except a grey `existing` box the human moved or resized (see Reading a drawing in ui-design.md).
//
// The same reader runs in every framework of the family (Godot Director's tools/ui_drawing.gd): the
// same drawing gives the same drawing.json, byte for byte. Its geometry is computed in 32-bit floats,
// as Godot's Vector2 and Rect2 are, its rounding is half away from zero, and dump() writes JSON as
// Godot does (sorted keys, floats with a decimal point).
//
// Exit codes: 0 done · 1 the file couldn't be read or written, or holds no frame.

import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, posix } from "node:path";
import process from "node:process";
import console from "node:console";
import { Buffer } from "node:buffer";
import { pathToFileURL } from "node:url";

const { join } = posix;

export const SCHEMA = 1;
const USAGE = "usage: node tools/ui/drawing.mjs <drawing.excalidraw> <drawing.json> [<screen>]  |  starter <capture without extension> <out.excalidraw>";
// A free note this close to a box (as a multiple of its own height) is a comment on that box.
const COMMENT_DISTANCE = 1.5;
// Matches in the element map are listed above this overlap (intersection over union).
const OVERLAP_MIN = 0.2;
// An arrow's end is on a note or a box when it is within this many pixels of it.
const ARROW_REACH = 10.0;
// A grey `existing` box counts as moved or resized when its position or size differs from the
// rectangle it was drawn at by more than this many capture pixels.
const MOVE_TOLERANCE = 2.0;
// Keys a box may use; anything else in its text stays in `text`.
const KEYS = ["shows", "does", "click", "key", "size", "stick", "scroll", "empty", "hidden when"];
// Excalidraw's stroke colours (and the shades of the same families) by what they say.
const INTENTS = {
  "#2f9e44": "new", "#2b8a3e": "new", "#37b24d": "new", "#40c057": "new",
  "#1971c2": "keep", "#1864ab": "keep", "#1c7ed6": "keep", "#228be6": "keep",
  "#e03131": "remove", "#c92a2a": "remove", "#f03e3e": "remove", "#fa5252": "remove",
  "#f08c00": "unsure", "#e67700": "unsure", "#fd7e14": "unsure", "#f76707": "unsure",
  "#e8590c": "unsure", "#d9480f": "unsure",
};
const DIGITS = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
const LEGEND = [
  "Draw over the screenshot, then save as director/ui/<screen>.excalidraw",
  "One rectangle per thing you care about: its name on the first line, details below.",
  "Details the agent understands: shows: does: click: key: size: stick: scroll: empty: hidden when:",
  "Colour says what changes: green new, blue keep but move or resize,",
  "red remove (or a red X), orange not sure, black as it should be.",
  "Drag or resize a grey box to move that element.",
  "A box inside a box means it contains it.",
  "An arrow from a note to a box is a comment; from a box to a box, a flow.",
  "Text outside the frame is notes for the whole screen (mode: replace keeps only what you drew).",
  "Delete this text when you like.",
];

// --- numbers as Godot has them ------------------------------------------------------------------

const f32 = Math.fround;
const CMP_EPSILON = 0.00001;

// A float in the output: written with a decimal point (`50.0`), as Godot writes a float.
export class GdFloat {
  constructor(value) { this.value = value; }
  toJSON() { return this.value; }
}

// Godot's round(): half away from zero.
function roundHalfAway(value) {
  return value < 0 ? -Math.round(-value) : Math.round(value);
}

function isEqualApprox(a, b) {
  if (a === b) return true;
  let tolerance = CMP_EPSILON * Math.abs(a);
  if (tolerance < CMP_EPSILON) tolerance = CMP_EPSILON;
  return Math.abs(a - b) < tolerance;
}

// Vector2 and Rect2 with real_t = 32-bit float.
function vec(x, y) { return { x: f32(x), y: f32(y) }; }
function rect(x, y, w, h) { return { x: f32(x), y: f32(y), w: f32(w), h: f32(h) }; }
const ZERO_RECT = rect(0, 0, 0, 0);
function endX(r) { return f32(r.x + r.w); }
function endY(r) { return f32(r.y + r.h); }
function area(r) { return f32(r.w * r.h); }
function center(r) { return vec(r.x + f32(r.w * 0.5), r.y + f32(r.h * 0.5)); }
function grow(r, by) { return rect(r.x - by, r.y - by, r.w + by * 2, r.h + by * 2); }
function hasPoint(r, p) {
  return !(p.x < r.x || p.y < r.y || p.x >= endX(r) || p.y >= endY(r));
}
function encloses(outer, inner) {
  return inner.x >= outer.x && inner.y >= outer.y && endX(inner) <= endX(outer) && endY(inner) <= endY(outer);
}
function intersects(a, b) {
  return !(a.x >= endX(b) || endX(a) <= b.x || a.y >= endY(b) || endY(a) <= b.y);
}
function intersection(a, b) {
  if (!intersects(a, b)) return ZERO_RECT;
  const x = Math.max(b.x, a.x);
  const y = Math.max(b.y, a.y);
  return rect(x, y, f32(Math.min(endX(b), endX(a)) - x), f32(Math.min(endY(b), endY(a)) - y));
}
function merge(a, b) {
  const x = Math.min(a.x, b.x);
  const y = Math.min(a.y, b.y);
  return rect(x, y, f32(Math.max(endX(a), endX(b)) - x), f32(Math.max(endY(a), endY(b)) - y));
}
function expandTo(r, p) {
  let bx = r.x, by = r.y, ex = endX(r), ey = endY(r);
  if (p.x < bx) bx = p.x;
  if (p.y < by) by = p.y;
  if (p.x > ex) ex = p.x;
  if (p.y > ey) ey = p.y;
  return rect(bx, by, f32(ex - bx), f32(ey - by));
}
function absRect(r) {
  return rect(r.x + Math.min(r.w, 0), r.y + Math.min(r.h, 0), Math.abs(r.w), Math.abs(r.h));
}

// Geometry2D.segment_intersects_segment, as a yes or no.
function segmentsCross(a0, a1, b0, b1) {
  const B = vec(a1.x - a0.x, a1.y - a0.y);
  let C = vec(b0.x - a0.x, b0.y - a0.y);
  let D = vec(b1.x - a0.x, b1.y - a0.y);
  const abLength = f32(f32(B.x * B.x) + f32(B.y * B.y));
  if (abLength <= 0) return false;
  const Bn = vec(B.x / abLength, B.y / abLength);
  C = vec(f32(C.x * Bn.x) + f32(C.y * Bn.y), f32(C.y * Bn.x) - f32(C.x * Bn.y));
  D = vec(f32(D.x * Bn.x) + f32(D.y * Bn.y), f32(D.y * Bn.x) - f32(D.x * Bn.y));
  if ((C.y < -CMP_EPSILON && D.y < -CMP_EPSILON) || (C.y > CMP_EPSILON && D.y > CMP_EPSILON)) return false;
  if (isEqualApprox(C.y, D.y)) return false;
  const position = f32(D.x + f32(f32(f32(C.x - D.x) * D.y) / f32(D.y - C.y)));
  return !(position < 0 || position > 1);
}

// --- the reader ---------------------------------------------------------------------------------

function isDict(value) { return value !== null && typeof value === "object" && !Array.isArray(value); }

// Godot's str() of a value read from JSON: numbers are floats there.
function godotStr(value) {
  if (typeof value === "number") return formatFloat(value);
  if (typeof value === "boolean") return value ? "true" : "false";
  if (value === null || value === undefined) return "<null>";
  if (typeof value === "string") return value;
  return JSON.stringify(value);
}

function text(element, key) {
  const value = element[key];
  return value === null || value === undefined ? "" : godotStr(value);
}

function number(element, key) {
  const value = element[key];
  return typeof value === "number" ? value : 0.0;
}

// Godot's strip_edges(): whitespace and control characters at both ends.
function strip(value) {
  let start = 0;
  let end = value.length;
  while (start < end && value.charCodeAt(start) <= 32) start++;
  while (end > start && value.charCodeAt(end - 1) <= 32) end--;
  return value.substring(start, end);
}

function noteText(element) {
  const original = text(element, "originalText");
  return strip(original !== "" ? original : text(element, "text"));
}

function points(element) {
  const result = [];
  if (Array.isArray(element.points)) {
    for (const item of element.points) {
      if (Array.isArray(item) && item.length >= 2) {
        result.push(vec(number(element, "x") + Number(item[0]), number(element, "y") + Number(item[1])));
      }
    }
  }
  return result;
}

function bounds(element) {
  const list = points(element);
  if (list.length > 0) {
    let r = rect(list[0].x, list[0].y, 0, 0);
    for (const point of list) r = expandTo(r, point);
    return r;
  }
  return absRect(rect(number(element, "x"), number(element, "y"), number(element, "width"), number(element, "height")));
}

function ours(element) {
  const data = element.customData;
  return isDict(data) && data.ddd !== undefined && data.ddd !== null ? godotStr(data.ddd) : "";
}

function isOurs(element) { return ours(element) !== ""; }

function intent(stroke) { return INTENTS[stroke.toLowerCase()] || "default"; }

function describe(kind) {
  switch (kind) {
    case "freedraw": return "a freehand line";
    case "ellipse": return "an ellipse";
    case "diamond": return "a diamond";
    case "image": return "an image";
    case "line": return "a line";
    case "arrow": return "an arrow";
    case "rectangle": return "a rectangle";
    case "text": return "a text";
  }
  return `an element of type ${kind}`;
}

function toUnit(r, origin) {
  return rect(f32(r.x - origin.x) / origin.w, f32(r.y - origin.y) / origin.h, r.w / origin.w, r.h / origin.h);
}

function toPixels(r, origin, size) {
  const unit = toUnit(r, origin);
  return rect(unit.x * size.x, unit.y * size.y, unit.w * size.x, unit.h * size.y);
}

function pct(unit) {
  return new GdFloat(roundHalfAway(unit * 1000.0) / 10.0 + 0.0);
}

function iou(a, b) {
  const overlap = area(intersection(a, b));
  const union = area(a) + area(b) - overlap;
  return union > 0.0 ? overlap / union : 0.0;
}

function gap(a, b) {
  const dx = Math.max(0.0, Math.max(f32(a.x - endX(b)), f32(b.x - endX(a))));
  const dy = Math.max(0.0, Math.max(f32(a.y - endY(b)), f32(b.y - endY(a))));
  return Math.sqrt(dx * dx + dy * dy);
}

function nearRect(r, origin, size) {
  const c = center(toPixels(r, origin, size));
  return { x: roundHalfAway(c.x), y: roundHalfAway(c.y) };
}

function near(element, origin, size) { return nearRect(bounds(element), origin, size); }

function readMap(path) {
  const result = [];
  if (!existsSync(path)) return result;
  let json;
  try { json = JSON.parse(readFileSync(path, "utf8")); } catch { return result; }
  if (isDict(json) && Array.isArray(json.elements)) {
    for (const item of json.elements) {
      if (isDict(item) && (item.visible === undefined || Boolean(item.visible))) result.push(item);
    }
  }
  return result;
}

// Whether a grey `existing` box was dragged or resized: unlocked, visible, carrying the rectangle it
// was drawn at (customData.rect, capture pixels), and now differing from it by more than MOVE_TOLERANCE.
function greyMoved(element, pixels) {
  const data = element.customData;
  if (element.locked || hidden(element) || !Array.isArray(data.rect) || data.rect.length < 4) return false;
  const v = data.rect.map(Number);
  const delta = Math.max(Math.abs(pixels.x - v[0]), Math.abs(pixels.y - v[1]), Math.abs(pixels.w - v[2]), Math.abs(pixels.h - v[3]));
  return delta > MOVE_TOLERANCE;
}

// The map entry numbered n, or null.
function entryOf(mapped, n) {
  return mapped.find((entry) => entryNumber(entry) === n) || null;
}

// A box the human hid: fully transparent.
function hidden(element) {
  return element.opacity !== undefined && element.opacity !== null && number(element, "opacity") <= 0.0;
}

function mapRect(entry) {
  const values = Array.isArray(entry.rect) ? entry.rect : [0, 0, 0, 0];
  return rect(Number(values[0]), Number(values[1]), Number(values[2]), Number(values[3]));
}

function entryNumber(entry) { return Math.trunc(Number(entry.n === undefined ? 0 : entry.n)); }
function entryId(entry) { return entry.id === undefined ? "" : godotStr(entry.id); }

// The mapped element an X is over: the smallest one holding its centre, else the best overlap.
function elementUnder(pixels, mapped) {
  let best = null;
  for (const entry of mapped) {
    const r = mapRect(entry);
    if (hasPoint(r, center(pixels)) && (best === null || area(r) < area(mapRect(best)))) best = entry;
  }
  if (best !== null) return best;
  let bestIou = OVERLAP_MIN;
  for (const entry of mapped) {
    const value = iou(pixels, mapRect(entry));
    if (value > bestIou) { best = entry; bestIou = value; }
  }
  return best;
}

// What one end of an arrow touches: {kind: "text", el}, {kind: "box", box} or null.
function arrowEnd(binding, point, boxes, boxOf, free, byId) {
  if (isDict(binding) && byId.has(godotStr(binding.elementId === undefined ? "" : binding.elementId))) {
    const target = byId.get(godotStr(binding.elementId));
    const container = text(target, "containerId");
    if (boxOf.has(text(target, "id"))) return { kind: "box", box: boxOf.get(text(target, "id")) };
    if (boxOf.has(container)) return { kind: "box", box: boxOf.get(container) };
    if (free.includes(target)) return { kind: "text", el: target };
  }
  let best = null;
  let bestArea = Infinity;
  for (const element of free) {
    const r = bounds(element);
    if (hasPoint(grow(r, ARROW_REACH), point) && area(r) < bestArea) { best = { kind: "text", el: element }; bestArea = area(r); }
  }
  for (const box of boxes) {
    if (hasPoint(grow(box.rect, ARROW_REACH), point) && area(box.rect) < bestArea) { best = { kind: "box", box }; bestArea = area(box.rect); }
  }
  return best;
}

// "hero_room", "hero_room.exhausted", "hero_room@2560x1080" or both: the screen and the state.
export function frameName(name) {
  let head = strip(name);
  const at = head.lastIndexOf("@");
  if (at >= 0) {
    const tail = head.substring(at + 1);
    if (tail.toLowerCase().includes("x") && /^[+-]?\d+$/.test(tail.replace(/x/g, "").replace(/X/g, ""))) head = head.substring(0, at);
  }
  const dot = head.indexOf(".");
  if (dot > 0) return { screen: head.substring(0, dot), state: head.substring(dot + 1) };
  return { screen: head, state: "default" };
}

// The index of the frame an element is in: the one it names, else the one holding its centre. A
// text bound to a rectangle goes where the rectangle goes. -1 when it is in none.
function frameOf(element, frames, byId, depth) {
  const container = text(element, "containerId");
  if (container !== "" && byId.has(container) && depth < 3) return frameOf(byId.get(container), frames, byId, depth + 1);
  const named = text(element, "frameId");
  for (let index = 0; index < frames.length; index++) {
    if (named !== "" && text(frames[index].el, "id") === named) return index;
  }
  for (let index = 0; index < frames.length; index++) {
    if (hasPoint(bounds(frames[index].el), center(bounds(element)))) return index;
  }
  return -1;
}

// Reads an Excalidraw file's text. Returns {drawing, warnings}, or {error} when the text isn't
// JSON, isn't an Excalidraw file or has no frame. `screen` limits the reading to that screen's
// frames; capturesDir is where the element maps are.
export function readDrawing(source, path, sha1, screen, capturesDir) {
  let document;
  try { document = JSON.parse(source); } catch { document = null; }
  if (!isDict(document)) return { error: `${path} isn't valid JSON` };
  if (godotStr(document.type === undefined ? "" : document.type) !== "excalidraw" || !Array.isArray(document.elements)) {
    return { error: `${path} isn't an Excalidraw file (it needs "type": "excalidraw" and a list of elements)` };
  }
  const elements = [];
  const byId = new Map();
  for (const item of document.elements) {
    if (isDict(item) && !item.isDeleted) {
      item._order = elements.length;
      elements.push(item);
      byId.set(text(item, "id"), item);
    }
  }
  const files = isDict(document.files) ? document.files : {};
  const frames = [];
  for (const element of elements) {
    if (text(element, "type") === "frame") {
      const named = frameName(text(element, "name"));
      if (screen === "" || named.screen === screen) frames.push({ ...named, el: element });
    }
  }
  if (frames.length === 0) {
    if (screen === "") return { error: `${path} has no frame (the starter drawing has one, named after the screen)` };
    return { error: `${path} has no frame named ${screen} (or ${screen}.<state>, or with @<W>x<H>)` };
  }
  const allFrames = elements.filter((element) => text(element, "type") === "frame").map((element) => ({ el: element }));
  // Texts outside every frame are notes for the whole screen; other elements out there are reported.
  const fileNotes = [];
  const outside = [];
  for (const element of elements) {
    const kind = text(element, "type");
    if (kind === "frame" || frameOf(element, allFrames, byId, 0) >= 0) continue;
    if (ours(element) === "existing" && kind === "rectangle" && !element.locked && !hidden(element) && Array.isArray(element.customData.rect)) {
      outside.push([element._order, `grey box ${entryNumber(element.customData)} moved outside the frame`]);
      continue;
    }
    if (isOurs(element)) continue;
    if (kind === "text" && text(element, "containerId") === "") {
      const note = noteText(element);
      if (note !== "") fileNotes.push(note);
    } else if (kind !== "text") {
      const c = center(bounds(element));
      outside.push([element._order, `${describe(kind)} outside the frame near canvas (${roundHalfAway(c.x)}, ${roundHalfAway(c.y)})`]);
    }
  }
  const warnings = [];
  const readFrames = [];
  for (const frame of frames) {
    const index = allFrames.findIndex((candidate) => candidate.el === frame.el);
    const members = elements.filter((element) => element !== frame.el && frameOf(element, allFrames, byId, 0) === index);
    readFrames.push(readFrame(frame, members, byId, files, fileNotes, outside, capturesDir, warnings));
  }
  return { drawing: { schema: SCHEMA, source: path, sha1, frames: readFrames }, warnings };
}

function readFrame(frame, members, byId, files, fileNotes, outside, capturesDir, warnings) {
  const frameRect = bounds(frame.el);
  const screen = frame.screen;
  const state = frame.state;
  // The background image: what every position is measured against.
  let background = null;
  let natural = { x: 0, y: 0 };
  for (const element of members) {
    if (text(element, "type") !== "image" || !Object.prototype.hasOwnProperty.call(files, text(element, "fileId"))) continue;
    const tagged = ours(element) === "background";
    if (background === null || tagged || (ours(background) !== "background" && area(bounds(element)) > area(bounds(background)))) {
      background = element;
      if (tagged) break;
    }
  }
  let origin = frameRect;
  if (background !== null) {
    origin = bounds(background);
    natural = naturalSize(files[text(background, "fileId")]);
  }
  if (natural.x === 0 && natural.y === 0) {
    if (background !== null) warnings.push(`${screen}: the background image can't be decoded; positions use its size on the canvas`);
    else warnings.push(`${screen}: the frame holds no background image; positions are measured against the frame`);
    natural = { x: roundHalfAway(origin.w), y: roundHalfAway(origin.h) };
  }
  const size = vec(natural.x, natural.y);
  const mapName = `${screen}${state === "default" ? "" : "." + state}@${natural.x}x${natural.y}.elements.json`;
  const mapped = readMap(join(capturesDir, mapName));
  const unparsed = outside.slice();

  // Sort what is in the frame.
  const boxes = [];
  const boxOf = new Map();
  const texts = [];
  const linears = [];
  let warnedNoMap = false;
  for (const element of members) {
    let moved = null;
    if (ours(element) === "existing" && text(element, "type") === "rectangle" && greyMoved(element, toPixels(bounds(element), origin, size))) {
      const greyN = entryNumber(element.customData);
      moved = entryOf(mapped, greyN);
      if (mapped.length === 0) {
        if (!warnedNoMap) {
          warnedNoMap = true;
          warnings.push(`${screen}: no element map ${mapName}, so the moved grey boxes are ignored`);
        }
      } else if (moved === null) {
        warnings.push(`${screen}: grey box ${greyN} isn't in the element map`);
      }
    }
    if (isOurs(element) && moved === null) continue;
    const kind = text(element, "type");
    if (kind === "rectangle") {
      const box = { el: element, rect: bounds(element), id: `b${boxes.length + 1}`, comments: [], flows_to: [], labelEl: null, moved };
      boxes.push(box);
      boxOf.set(text(element, "id"), box);
    } else if (kind === "text") {
      texts.push(element);
    } else if (kind === "line" || kind === "arrow") {
      linears.push(element);
    } else if (!(kind === "image" && element === background)) {
      const at = near(element, origin, size);
      unparsed.push([element._order, `${describe(kind)} near (${at.x}, ${at.y})`]);
    }
  }
  const free = [];
  for (const element of texts) {
    const container = text(element, "containerId");
    if (container === "") free.push(element);
    else if (boxOf.has(container)) boxOf.get(container).labelEl = element;
    else if (byId.has(container) && text(byId.get(container), "type") === "arrow") free.push(element);
  }

  // Boxes: label, keys, intent, parent, overlaps.
  for (const box of boxes) {
    const full = box.labelEl !== null ? noteText(box.labelEl) : "";
    const lines = full.split("\n");
    const keys = {};
    for (let line = 1; line < lines.length; line++) {
      const colon = lines[line].indexOf(":");
      if (colon > 0) {
        const key = strip(lines[line].substring(0, colon)).toLowerCase();
        if (KEYS.includes(key)) keys[key] = strip(lines[line].substring(colon + 1));
      }
    }
    box.label = strip(lines[0]);
    box.text = full;
    box.keys = keys;
    box.intent = intent(text(box.el, "strokeColor"));
    if (box.moved !== null) {
      box.label = entryId(box.moved);
      box.intent = "keep";
    }
    let parent = null;
    for (const other of boxes) {
      if (other !== box && area(other.rect) > area(box.rect) && encloses(grow(other.rect, 0.5), box.rect)) {
        if (parent === null || area(other.rect) < area(parent.rect)) parent = other;
      }
    }
    box.parent = parent === null ? null : parent.id;
    const overlaps = [];
    const pixels = toPixels(box.rect, origin, size);
    for (const entry of mapped) {
      const value = iou(pixels, mapRect(entry));
      if (value > OVERLAP_MIN) overlaps.push({ n: entryNumber(entry), name: entryId(entry), iou: new GdFloat(roundHalfAway(value * 100.0) / 100.0) });
    }
    overlaps.sort((a, b) => (b.iou.value - a.iou.value) || (a.n - b.n));
    box.overlaps = overlaps;
  }

  // A red X: two red strokes crossing. It removes the element it is over.
  const removed = [];
  const used = new Set();
  const strokes = linears.filter((element) => intent(text(element, "strokeColor")) === "remove" && points(element).length === 2
    && (element.startBinding === null || element.startBinding === undefined) && (element.endBinding === null || element.endBinding === undefined));
  for (let first = 0; first < strokes.length; first++) {
    for (let second = first + 1; second < strokes.length; second++) {
      if (used.has(first) || used.has(second)) continue;
      const a = points(strokes[first]);
      const b = points(strokes[second]);
      if (!segmentsCross(a[0], a[1], b[0], b[1])) continue;
      used.add(first);
      used.add(second);
      const xRect = merge(bounds(strokes[first]), bounds(strokes[second]));
      const hit = elementUnder(toPixels(xRect, origin, size), mapped);
      if (hit === null) {
        const at = nearRect(xRect, origin, size);
        unparsed.push([strokes[first]._order, `a red X near (${at.x}, ${at.y}) over no element in the element map`]);
      } else {
        const entry = { n: entryNumber(hit), name: entryId(hit), by: "red-x" };
        if (!removed.some((other) => other.n === entry.n && other.name === entry.name)) removed.push(entry);
      }
    }
  }
  removed.sort((a, b) => a.n - b.n);
  // One element claimed twice: a moved grey box, a blue box named after it, a red X.
  const claims = new Map();
  const claim = (n, name, way) => {
    if (!claims.has(n)) claims.set(n, [name, []]);
    claims.get(n)[1].push(way);
  };
  for (const box of boxes) {
    let byMap = box.moved;
    let way = "a moved grey box";
    if (byMap === null && box.intent === "keep") {
      way = "a blue box named after it";
      byMap = mapped.find((entry) => entryId(entry) === box.label) || null;
    }
    if (byMap !== null) claim(entryNumber(byMap), entryId(byMap), way);
  }
  for (const entry of removed) claim(entry.n, entry.name, "a red X");
  for (const n of [...claims.keys()].sort((a, b) => a - b)) {
    const [name, ways] = claims.get(n);
    if (ways.length > 1) warnings.push(`${screen}: element ${n} (${name}) is claimed by ${ways.join(" and ")}`);
  }

  // Other strokes: an arrow joining a note and a box is a comment, one joining two boxes is a flow.
  const consumed = new Set();
  const comments = [];
  for (const element of linears) {
    const strokeIndex = strokes.indexOf(element);
    if (strokeIndex >= 0 && used.has(strokeIndex)) continue;
    const list = points(element);
    if (text(element, "type") !== "arrow" || list.length < 2) {
      const at = near(element, origin, size);
      unparsed.push([element._order, `${describe(text(element, "type"))} near (${at.x}, ${at.y})`]);
      continue;
    }
    const fromEnd = arrowEnd(element.startBinding, list[0], boxes, boxOf, free, byId);
    const toEnd = arrowEnd(element.endBinding, list[list.length - 1], boxes, boxOf, free, byId);
    const kinds = `${fromEnd ? fromEnd.kind : ""}+${toEnd ? toEnd.kind : ""}`;
    if (kinds === "text+box" || kinds === "box+text") {
      const noteEnd = fromEnd.kind === "text" ? fromEnd : toEnd;
      const boxEnd = fromEnd.kind === "text" ? toEnd : fromEnd;
      consumed.add(text(noteEnd.el, "id"));
      comments.push([noteEnd.el._order, boxEnd.box, noteText(noteEnd.el)]);
    } else if (kinds === "box+box" && fromEnd.box !== toEnd.box) {
      if (!fromEnd.box.flows_to.includes(toEnd.box.id)) fromEnd.box.flows_to.push(toEnd.box.id);
    } else {
      const at = near(element, origin, size);
      unparsed.push([element._order, `an arrow near (${at.x}, ${at.y}) that doesn't join a note and a box, or two boxes`]);
    }
  }

  // Free text: a comment on a box close to it, otherwise a note for the frame.
  const notes = [];
  for (const element of free) {
    if (consumed.has(text(element, "id"))) continue;
    const note = noteText(element);
    if (note === "") continue;
    const r = bounds(element);
    let nearest = null;
    let nearestGap = 0.0;
    for (const box of boxes) {
      const distance = gap(r, box.rect);
      if (distance <= COMMENT_DISTANCE * r.h && (nearest === null || distance < nearestGap || (distance === nearestGap && area(box.rect) < area(nearest.rect)))) {
        nearest = box;
        nearestGap = distance;
      }
    }
    if (nearest === null) notes.push(note);
    else comments.push([element._order, nearest, note]);
  }
  comments.sort((a, b) => a[0] - b[0]);
  for (const comment of comments) comment[1].comments.push(comment[2]);
  notes.push(...fileNotes);
  let mode = "patch";
  for (const note of notes) {
    for (const line of note.split("\n")) {
      const cleaned = strip(line).toLowerCase();
      if (cleaned === "mode: replace" || cleaned === "mode: patch") mode = strip(cleaned.substring("mode:".length));
    }
  }

  unparsed.sort((a, b) => a[0] - b[0]);
  const boxRows = boxes.map((box) => {
    const unit = toUnit(box.rect, origin);
    const row = {
      id: box.id, label: box.label, text: box.text, keys: box.keys, intent: box.intent,
      rect_pct: [pct(unit.x), pct(unit.y), pct(unit.w), pct(unit.h)],
      parent: box.parent, comments: box.comments, flows_to: box.flows_to, overlaps: box.overlaps,
    };
    if (box.moved !== null) {
      row.from = "existing";
      row.n = entryNumber(box.moved);
    }
    return row;
  });
  return {
    name: screen, state, size: [natural.x, natural.y], mode,
    notes, boxes: boxRows, removed, unparsed: unparsed.map((item) => item[1]),
  };
}

// --- images -------------------------------------------------------------------------------------

function dataUrlBytes(file) {
  const url = isDict(file) ? godotStr(file.dataURL === undefined ? "" : file.dataURL) : "";
  const marker = url.indexOf("base64,");
  if (marker < 0) return null;
  return { url, bytes: Buffer.from(url.substring(marker + 7), "base64") };
}

// The size of an image from its header: PNG, JPEG or WebP. {x: 0, y: 0} when it can't be read.
export function imageSize(bytes) {
  if (bytes.length >= 24 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47) {
    return { x: bytes.readUInt32BE(16), y: bytes.readUInt32BE(20) };
  }
  if (bytes.length > 4 && bytes[0] === 0xff && bytes[1] === 0xd8) {
    let at = 2;
    while (at + 9 < bytes.length) {
      if (bytes[at] !== 0xff) { at++; continue; }
      const marker = bytes[at + 1];
      if (marker === 0xd8 || marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7)) { at += 2; continue; }
      const length = bytes.readUInt16BE(at + 2);
      if (marker >= 0xc0 && marker <= 0xcf && marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc) {
        return { x: bytes.readUInt16BE(at + 7), y: bytes.readUInt16BE(at + 5) };
      }
      at += 2 + length;
    }
    return { x: 0, y: 0 };
  }
  if (bytes.length >= 30 && bytes.toString("ascii", 0, 4) === "RIFF" && bytes.toString("ascii", 8, 12) === "WEBP") {
    const chunk = bytes.toString("ascii", 12, 16);
    if (chunk === "VP8X") return { x: 1 + bytes.readUIntLE(24, 3), y: 1 + bytes.readUIntLE(27, 3) };
    if (chunk === "VP8 ") return { x: bytes.readUInt16LE(26) & 0x3fff, y: bytes.readUInt16LE(28) & 0x3fff };
    if (chunk === "VP8L") {
      const bits = bytes.readUInt32LE(21);
      return { x: (bits & 0x3fff) + 1, y: ((bits >> 14) & 0x3fff) + 1 };
    }
  }
  return { x: 0, y: 0 };
}

// The size of the image a file entry holds.
function naturalSize(file) {
  const data = dataUrlBytes(file);
  return data === null ? { x: 0, y: 0 } : imageSize(data.bytes);
}

// The screenshot a drawing was made over: the data URL of the background image of the frame for
// the given screen and state. null when the frame or its image isn't there.
export function backgroundImage(source, screen, state) {
  let document;
  try { document = JSON.parse(source); } catch { return null; }
  if (!isDict(document) || !Array.isArray(document.elements)) return null;
  const files = isDict(document.files) ? document.files : {};
  let frame = null;
  const images = [];
  for (const element of document.elements) {
    if (!isDict(element) || element.isDeleted) continue;
    const kind = text(element, "type");
    if (kind === "frame") {
      const named = frameName(text(element, "name"));
      if (frame === null && named.screen === screen && named.state === state) frame = element;
    } else if (kind === "image" && Object.prototype.hasOwnProperty.call(files, text(element, "fileId"))) {
      images.push(element);
    }
  }
  if (frame === null) return null;
  const frameRect = bounds(frame);
  let best = null;
  for (const element of images) {
    const inside = text(element, "frameId") === text(frame, "id") || hasPoint(frameRect, center(bounds(element)));
    if (!inside) continue;
    if (best === null || ours(element) === "background" || (ours(best) !== "background" && area(bounds(element)) > area(bounds(best)))) best = element;
  }
  if (best === null) return null;
  const data = dataUrlBytes(files[text(best, "fileId")]);
  if (data === null || !data.url.includes(";base64,")) return null;
  return data.url;
}

// --- the starter drawing ------------------------------------------------------------------------

// The starter drawing for a screen's default state: a frame named after the screen, exactly the size
// of the capture, with the capture locked inside as the background; a faint group of the
// mapped elements (`existing`, numbered as in the map image) that can be dragged, resized, hidden or deleted; and a
// legend outside the frame. Valid current-format Excalidraw JSON, deterministic for the same input.
export function starterText(screen, size, png, mapped) {
  const fileId = createHash("sha1").update(png).digest("hex");
  const frameId = "ddd-frame";
  const items = [];
  const background = base("ddd-background", "image", items.length, 0, 0, size.x, size.y, frameId);
  background.locked = true;
  background.fileId = fileId;
  background.status = "saved";
  background.scale = [1, 1];
  background.crop = null;
  background.customData = { ddd: "background" };
  items.push(background);
  for (const entry of mapped) {
    if (!isDict(entry)) continue;
    const r = mapRect(entry);
    const at = { x: Math.trunc(r.x), y: Math.trunc(r.y), w: Math.trunc(r.w), h: Math.trunc(r.h) };
    const n = entryNumber(entry);
    const outline = base(`ddd-existing-${n}`, "rectangle", items.length, at.x, at.y, Math.max(at.w, 1), Math.max(at.h, 1), frameId);
    outline.strokeColor = "#868e96";
    outline.strokeWidth = 1;
    outline.opacity = 25;
      outline.groupIds = ["ddd-existing"];
    outline.customData = { ddd: "existing", n, rect: [at.x, at.y, Math.max(at.w, 1), Math.max(at.h, 1)] };
    items.push(outline);
    const label = textElement(`ddd-existing-label-${n}`, items.length, at.x + 2, at.y + 1, String(n), 14, frameId);
    label.strokeColor = "#868e96";
    label.opacity = 25;
    label.groupIds = ["ddd-existing"];
    label.customData = { ddd: "existing", n };
    items.push(label);
  }
  const frame = base(frameId, "frame", items.length, 0, 0, size.x, size.y, "");
  frame.strokeColor = "#bbbbbb";
  frame.strokeWidth = 1;
  frame.name = screen;
  items.push(frame);
  const legend = textElement("ddd-legend", items.length, size.x + 60, 0, LEGEND.join("\n").replace("<screen>", screen), 20, "");
  legend.customData = { ddd: "legend" };
  items.push(legend);
  const document = {
    type: "excalidraw", version: 2, source: "https://excalidraw.com",
    elements: items,
    appState: { gridSize: null, viewBackgroundColor: "#ffffff" },
    files: { [fileId]: { mimeType: "image/png", id: fileId, dataURL: "data:image/png;base64," + Buffer.from(png).toString("base64"), created: 1, lastRetrieved: 1 } },
  };
  return dump(document) + "\n";
}

// The fields every Excalidraw element has (types.ts › _ExcalidrawElementBase).
function base(id, type, index, x, y, width, height, frameId) {
  return {
    id, type, x, y, width, height, angle: 0,
    strokeColor: "#1e1e1e", backgroundColor: "transparent", fillStyle: "solid",
    strokeWidth: 2, strokeStyle: "solid", roughness: 0, opacity: 100,
    groupIds: [], frameId: frameId === "" ? null : frameId,
    index: fractionalIndex(index), roundness: null,
    seed: 1000003 + index * 7919, version: 1, versionNonce: 2000003 + index * 104729,
    isDeleted: false, boundElements: null, updated: 1, link: null, locked: false, created: null,
  };
}

function textElement(id, index, x, y, content, fontSize, frameId) {
  const lines = content.split("\n");
  let longest = 0;
  for (const line of lines) longest = Math.max(longest, line.length);
  const element = base(id, "text", index, x, y, Math.ceil(longest * fontSize * 0.6), Math.ceil(lines.length * fontSize * 1.25), frameId);
  element.fontSize = fontSize;
  element.fontFamily = 5;
  element.baseFontSize = null;
  element.text = content;
  element.textAlign = "left";
  element.verticalAlign = "top";
  element.containerId = null;
  element.originalText = content;
  element.autoResize = true;
  element.lineHeight = new GdFloat(1.25);
  return element;
}

// Excalidraw's fractional indices ("a0", "a1" ... "aZ", "az", "b00" ...), in array order.
function fractionalIndex(position) {
  if (position < DIGITS.length) return "a" + DIGITS[position];
  const rest = position - DIGITS.length;
  return "b" + DIGITS[Math.floor(rest / DIGITS.length) % DIGITS.length] + DIGITS[rest % DIGITS.length];
}

// --- output -------------------------------------------------------------------------------------

// Godot's JSON number for a float: up to 14 significant digits, always with a decimal point.
export function formatFloat(value) {
  if (value === 0) return "0.0";
  if (!Number.isFinite(value)) return String(value);
  const magnitude = Math.log10(Math.abs(value));
  const precision = Math.max(1, 14 - Math.floor(magnitude));
  let out = value.toFixed(Math.min(precision, 100));
  if (out.includes(".")) out = out.replace(/0+$/, "").replace(/\.$/, "");
  if (!out.includes(".") && !out.includes("e")) out += ".0";
  return out;
}

// Godot's JSON string escapes.
function quote(value) {
  return "\"" + value.replace(/\\/g, "\\\\").split(String.fromCharCode(8)).join("\\b").replace(/\f/g, "\\f").replace(/\n/g, "\\n")
    .replace(/\r/g, "\\r").replace(/\t/g, "\\t").replace(/\v/g, "\\v").replace(/"/g, "\\\"") + "\"";
}

function scalar(value) {
  if (value instanceof GdFloat) return formatFloat(value.value);
  if (value === null || value === undefined) return "null";
  if (typeof value === "boolean") return value ? "true" : "false";
  if (typeof value === "number") return Number.isInteger(value) ? String(value) : formatFloat(value);
  return quote(String(value));
}

// JSON with sorted keys, one key per line and lists of plain values on one line, so the file reads
// and diffs well: the same text Godot Director's reader writes. A number is an integer unless it is
// a GdFloat or has a fraction.
export function dump(value, indent = 0) {
  const pad = "  ".repeat(indent + 1);
  const close = "  ".repeat(indent);
  if (isDict(value) && !(value instanceof GdFloat)) {
    const keys = Object.keys(value).sort();
    if (keys.length === 0) return "{}";
    return "{\n" + keys.map((key) => `${pad}${quote(key)}: ${dump(value[key], indent + 1)}`).join(",\n") + "\n" + close + "}";
  }
  if (Array.isArray(value)) {
    if (value.length === 0) return "[]";
    const flat = value.every((item) => !Array.isArray(item) && !(isDict(item) && !(item instanceof GdFloat)));
    if (flat) return "[" + value.map(scalar).join(", ") + "]";
    return "[\n" + value.map((item) => pad + dump(item, indent + 1)).join(",\n") + "\n" + close + "]";
  }
  return scalar(value);
}

// --- command line -------------------------------------------------------------------------------

function runRead(source, out, screen) {
  if (!existsSync(source)) {
    console.error(`ui_drawing: FAIL: no drawing at ${source}`);
    return 1;
  }
  const bytes = readFileSync(source);
  const sha1 = createHash("sha1").update(bytes).digest("hex");
  const result = readDrawing(bytes.toString("utf8"), source, sha1, screen, dirname(out));
  if (result.error) {
    console.error(`ui_drawing: FAIL: ${result.error}`);
    return 1;
  }
  for (const warning of result.warnings) console.log(`ui_drawing: note: ${warning}`);
  try {
    mkdirSync(dirname(out), { recursive: true });
    writeFileSync(out, dump(result.drawing) + "\n");
  } catch {
    console.error(`ui_drawing: FAIL: can't write ${out}`);
    return 1;
  }
  const frames = result.drawing.frames;
  const boxes = frames.reduce((sum, frame) => sum + frame.boxes.length, 0);
  console.log(`ui_drawing: read ${source}: ${frames.length} frame${frames.length === 1 ? "" : "s"}, ${boxes} box${boxes === 1 ? "" : "es"}`);
  return 0;
}

function runStarter(basePath, out) {
  let png = null;
  let map;
  try {
    png = readFileSync(basePath + ".png");
    map = JSON.parse(readFileSync(basePath + ".elements.json", "utf8"));
  } catch { map = null; }
  if (png === null || png.length === 0 || !isDict(map)) {
    console.error(`ui_drawing: FAIL: needs ${basePath}.png and ${basePath}.elements.json`);
    return 1;
  }
  const sizeValues = Array.isArray(map.size) ? map.size : [0, 0];
  const size = { x: Math.trunc(Number(sizeValues[0])), y: Math.trunc(Number(sizeValues[1])) };
  const content = starterText(map.screen === undefined ? "screen" : godotStr(map.screen), size, png, Array.isArray(map.elements) ? map.elements : []);
  try {
    mkdirSync(dirname(out), { recursive: true });
    writeFileSync(out, content);
  } catch {
    console.error(`ui_drawing: FAIL: can't write ${out}`);
    return 1;
  }
  return 0;
}

function main(args) {
  if (args.length === 3 && args[0] === "starter") return runStarter(args[1], args[2]);
  if (args.length === 2 || args.length === 3) return runRead(args[0], args[1], args.length === 3 ? args[2] : "");
  console.error(USAGE);
  return 1;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  process.exitCode = main(process.argv.slice(2));
}
