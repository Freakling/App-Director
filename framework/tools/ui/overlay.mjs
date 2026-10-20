// Overlay images for screen captures · framework-owned: replaced on upgrade.
//
// Draws on a capture in a Chromium page (a canvas, so no image library is needed):
//   node tools/ui/overlay.mjs map product/ui/captures/<id>@<W>x<H>
// writes <id>@<W>x<H>.map.png from that capture's .png and .elements.json: every mapped element
// outlined and numbered, the numbers being the element map's `n`. tools/ui/capture.mjs calls
// drawMap() itself.
//   node tools/ui/overlay.mjs compare product/ui/captures/<id>@<W>x<H>
// writes <id>.compare@<W>x<H>.png (<id>.<state>.compare@... for another state): the screenshot the
// human's drawing was made over on the left, and the new capture on the right with the drawing's boxes
// outlined and labelled (b1, b2 ... in drawing.json's order), coloured by intent: green new, blue keep,
// red remove, orange unsure, dark default. tools/ui/verify.mjs draws it too.
// Labels use the small bitmap font of Godot Director's overlay, so the images look the same.

/* global document, Image */

import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { basename, dirname, posix } from "node:path";
import process from "node:process";
import console from "node:console";
import { Buffer } from "node:buffer";
import { pathToFileURL } from "node:url";
import { backgroundImage, imageSize } from "./drawing.mjs";

const { join } = posix;

const OUTLINE = "rgb(255,0,217)";
const INTENT_COLORS = { new: "#2f9e44", keep: "#1971c2", remove: "#e03131", unsure: "#f08c00", default: "#212529" };
const GAP = 8;
// 5 x 7 glyphs, row by row; "1" is a lit pixel.
const GLYPHS = {
  0: "01110100011001110101110011000101110", 1: "00100011000010000100001000010001110",
  2: "01110100010000100010001000100011111", 3: "11110000010000101110000010000111110",
  4: "00010001100101010010111110001000010", 5: "11111100001111000001000011000101110",
  6: "00110010001000011110100011000101110", 7: "11111000010001000100010000100001000",
  8: "01110100011000101110100011000101110", 9: "01110100011000101111000010001001100",
  b: "10000100001011011001100011000111110",
};

// Runs in the page: draws the layers on a canvas and returns the PNG as a data URL.
async function paint(job) {
  const SCALE = 3;
  const load = (url) => new Promise((done, fail) => {
    const image = new Image();
    image.onload = () => done(image);
    image.onerror = () => fail(new Error("the image doesn't load"));
    image.src = url;
  });
  const canvas = document.createElement("canvas");
  canvas.width = job.width;
  canvas.height = job.height;
  const context = canvas.getContext("2d");
  context.fillStyle = job.background;
  context.fillRect(0, 0, job.width, job.height);
  for (const layer of job.images) {
    const image = await load(layer.url);
    context.imageSmoothingEnabled = layer.smooth;
    context.drawImage(image, layer.x, layer.y, layer.w, layer.h);
  }
  const clip = (x, y, w, h, area) => {
    const left = Math.max(x, area.x);
    const top = Math.max(y, area.y);
    const right = Math.min(x + w, area.x + area.w);
    const bottom = Math.min(y + h, area.y + area.h);
    return right > left && bottom > top ? [left, top, right - left, bottom - top] : null;
  };
  const fill = (color, x, y, w, h, area) => {
    const shown = clip(x, y, w, h, area);
    if (shown) { context.fillStyle = color; context.fillRect(shown[0], shown[1], shown[2], shown[3]); }
  };
  for (const box of job.boxes) {
    const { area } = box;
    const [x, y, w, h] = box.rect.map((value, index) => value + (index === 0 ? area.x : index === 1 ? area.y : 0));
    fill(box.color, x, y, w, 2, area);
    fill(box.color, x, y + h - 2, w, 2, area);
    fill(box.color, x, y, 2, h, area);
    fill(box.color, x + w - 2, y, 2, h, area);
    const labelW = box.label.length * 6 * SCALE + SCALE * 2;
    const labelH = 9 * SCALE;
    const lx = Math.max(area.x, Math.min(x, area.x + area.w - labelW));
    const ly = Math.max(area.y, Math.min(y, area.y + area.h - labelH));
    fill(box.color, lx, ly, labelW, labelH, area);
    let cx = lx + SCALE * 2;
    for (const character of box.label) {
      const rows = job.glyphs[character] || "";
      for (let pixel = 0; pixel < rows.length; pixel++) {
        if (rows[pixel] === "1") fill("#ffffff", cx + (pixel % 5) * SCALE, ly + SCALE + Math.floor(pixel / 5) * SCALE, SCALE, SCALE, area);
      }
      cx += 6 * SCALE;
    }
  }
  return canvas.toDataURL("image/png");
}

async function render(browser, job) {
  const page = await browser.newPage({ viewport: { width: 64, height: 64 }, deviceScaleFactor: 1 });
  try {
    const url = await page.evaluate(paint, { ...job, glyphs: GLYPHS });
    return Buffer.from(url.substring(url.indexOf(",") + 1), "base64");
  } finally {
    await page.close();
  }
}

function pngUrl(bytes) {
  return "data:image/png;base64," + Buffer.from(bytes).toString("base64");
}

// A copy of the capture with each element's rect outlined and labelled with its number.
export async function drawMap(browser, png, elements) {
  const size = imageSize(Buffer.from(png));
  const area = { x: 0, y: 0, w: size.x, h: size.y };
  const boxes = elements.map((entry) => ({ rect: entry.rect, label: String(entry.n), color: OUTLINE, area }));
  return render(browser, { width: size.x, height: size.y, background: "#000000", images: [{ url: pngUrl(png), x: 0, y: 0, w: size.x, h: size.y, smooth: false }], boxes });
}

// The comparison: the screenshot the drawing was made over (original data URL; a dark panel when
// null) on the left, the capture on the right with each drawing box outlined and labelled.
export async function drawCompare(browser, png, boxes, original) {
  const size = imageSize(Buffer.from(png));
  const right = { x: size.x + GAP, y: 0, w: size.x, h: size.y };
  const images = [];
  if (original) images.push({ url: original, x: 0, y: 0, w: size.x, h: size.y, smooth: true });
  images.push({ url: pngUrl(png), x: size.x + GAP, y: 0, w: size.x, h: size.y, smooth: false });
  const drawn = boxes.map((box) => {
    const p = Array.isArray(box.rect_pct) ? box.rect_pct.map(Number) : [0, 0, 0, 0];
    return {
      rect: [Math.round((p[0] / 100) * size.x), Math.round((p[1] / 100) * size.y), Math.round((p[2] / 100) * size.x), Math.round((p[3] / 100) * size.y)],
      label: String(box.id || ""), color: INTENT_COLORS[box.intent] || INTENT_COLORS.default, area: right,
    };
  });
  return render(browser, { width: size.x * 2 + GAP, height: size.y, background: "rgb(38,38,38)", images, boxes: drawn });
}

// Writes the comparison for a capture (`<folder>/<id>[.<state>]@<W>x<H>`, no extension) from its
// .png, the drawing's boxes in `<folder>/<id>.drawing.json` and the screenshot inside the drawing
// itself. Returns {ok, message, path}: ok with a message when it was drawn without the original,
// and not ok when there is no capture image or no reading of the drawing to compare with.
export async function compareFiles(browser, basePath) {
  const folder = dirname(basePath);
  const name = basename(basePath);
  const at = name.lastIndexOf("@");
  if (at < 0) return { ok: false, message: `ui_overlay: ${basePath} isn't <id>[.<state>]@<W>x<H>`, path: "" };
  const head = name.substring(0, at);
  const id = head.split(".")[0];
  const state = head.includes(".") ? head.substring(id.length + 1) : "default";
  if (!existsSync(basePath + ".png")) return { ok: false, message: `ui_overlay: no capture image ${basePath}.png`, path: "" };
  let reading;
  try { reading = JSON.parse(readFileSync(join(folder, id + ".drawing.json"), "utf8")); } catch { reading = null; }
  if (!reading || typeof reading !== "object") return { ok: false, message: `ui_overlay: no ${id}.drawing.json: process the drawing first`, path: "" };
  let boxes = [];
  for (const frame of Array.isArray(reading.frames) ? reading.frames : []) {
    if (frame && frame.name === id && (frame.state || "default") === state) boxes = Array.isArray(frame.boxes) ? frame.boxes : [];
  }
  const source = typeof reading.source === "string" ? reading.source : "";
  const original = source !== "" && existsSync(source) ? backgroundImage(readFileSync(source, "utf8"), id, state) : null;
  const note = original ? "" : `the drawing ${source} holds no screenshot to put beside the capture`;
  const out = join(folder, `${id}${state === "default" ? "" : "." + state}.compare${name.substring(at)}.png`);
  try {
    writeFileSync(out, await drawCompare(browser, readFileSync(basePath + ".png"), boxes, original));
  } catch (error) {
    return { ok: false, message: `ui_overlay: can't write ${out}: ${error && error.message ? error.message : error}`, path: out };
  }
  return { ok: true, message: note, path: out };
}

async function main(args) {
  if (args.length !== 2 || (args[0] !== "map" && args[0] !== "compare")) {
    console.error("usage: node tools/ui/overlay.mjs map|compare <capture without extension>");
    return 1;
  }
  let chromium;
  try {
    ({ chromium } = await import("playwright"));
  } catch {
    console.error("ui_overlay: needs Playwright: cd tools/ui && npm install && npx playwright install chromium");
    return 3;
  }
  const browser = await chromium.launch();
  try {
    const basePath = args[1].replace(/\.png$/, "");
    if (args[0] === "compare") {
      const result = await compareFiles(browser, basePath);
      if (result.message !== "") console.log((result.ok ? "ui_overlay: note: " : "ui_overlay: FAIL: ") + result.message);
      return result.ok ? 0 : 1;
    }
    let map;
    try { map = JSON.parse(readFileSync(basePath + ".elements.json", "utf8")); } catch { map = null; }
    if (!existsSync(basePath + ".png") || !map) {
      console.error(`ui_overlay: needs ${basePath}.png and ${basePath}.elements.json`);
      return 1;
    }
    writeFileSync(basePath + ".map.png", await drawMap(browser, readFileSync(basePath + ".png"), map.elements || []));
    return 0;
  } finally {
    await browser.close();
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  process.exitCode = await main(process.argv.slice(2));
}
