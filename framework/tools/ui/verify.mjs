// Verifies a built screen against its spec · framework-owned: replaced on upgrade.
//
// Run it with `bash tools/ui_capture.sh <screen> --verify` (.app-director/procedures/ui-design.md),
// which captures the screen first. This script reads:
//   product/ui/<id>.md                          the spec: its Layout table is what is checked
//   product/ui/captures/<id>@<W>x<H>.elements.json and .lint.txt   the latest capture
//   product/ui/captures/<id>.drawing.json       the human's drawing, when it has been processed
// and prints one row per spec element: present (an element with that data-testid is on screen),
// where (every edge of its rect_pct within [verify] tolerance_pct of the spec's Where), reachable
// (a focusable element has a focus_order) and lint-clean (no finding names it). It lists the
// elements with a data-testid that the spec doesn't, lint findings in the screen's other states and
// sizes, and drawn boxes whose element has moved away. When the drawing is there it also writes the
// compare image for each size captured (tools/ui/overlay.mjs).
//   node tools/ui/verify.mjs <screen> [--state <name>] [--size <W>x<H>]
//   node tools/ui/verify.mjs <screen> --static   no capture: is each name of the spec in the source?
// --static is what an app without web capture gets (and what align uses): it looks for each name
// the Layout table lists, quoted, in the UI folders (tools/check.cfg › [ui] dirs).
// Exit codes: 0 no deviations · 1 deviations · 3 nothing to check (no spec, or no capture), or --static.

import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import { posix } from "node:path";
import process from "node:process";
import console from "node:console";
import { CAPTURES, SPECS, isCaptureOf, n1, parseSize, readCheckConfig, readConfig } from "./common.mjs";
import { WARNINGS } from "./lint.mjs";

const { join } = posix;

const say = (text) => console.log(`ui_verify: ${text}`);
const stop = (message, code) => { console.error(`ui_verify: FAIL: ${message}`); return code; };

// The spec's Layout table: {size, rows: [{element, name, where}]}. The size is the one in the
// heading, `## Layout (at 1920x1080)`; null when it names none.
export function readSpec(path) {
  let size = null;
  const rows = [];
  let inLayout = false;
  for (const line of readFileSync(path, "utf8").replace(/\r/g, "").split("\n")) {
    if (line.startsWith("#")) {
      inLayout = line.startsWith("## Layout");
      if (inLayout) {
        const found = /(\d+)\s*[xX]\s*(\d+)/.exec(line);
        if (found) size = { x: Number(found[1]), y: Number(found[2]) };
      }
      continue;
    }
    if (!inLayout || !line.trim().startsWith("|")) continue;
    const cells = line.trim().replace(/^\|/, "").replace(/\|$/, "").split("|").map((cell) => cell.replace(/`/g, "").trim());
    if (cells.length < 4 || cells[0] === "#" || /^:?-/.test(cells[0])) continue;
    rows.push({ element: cells[1], name: cells[2].replace(/^%/, ""), where: cells[3] });
  }
  return { size, rows };
}

// The lint file as {byElement: Map(n -> [rules]), errors: [lines a failed capture left on top],
// notes: [the hosts capture blocked]}.
function readLint(path) {
  const byElement = new Map();
  const errors = [];
  const notes = [];
  if (!existsSync(path)) return { byElement, errors, notes };
  for (const line of readFileSync(path, "utf8").replace(/\r/g, "").split("\n")) {
    if (line.startsWith("error:")) { errors.push(line); continue; }
    if (line.startsWith("note:")) { notes.push(line); continue; }
    const found = /^(\S+) element (\d+) /.exec(line);
    if (found) {
      const number = Number(found[2]);
      if (!byElement.has(number)) byElement.set(number, []);
      byElement.get(number).push(found[1]);
    }
  }
  return { byElement, errors, notes };
}

function numbers(text) {
  return text.replace(/%/g, "").split(",").map((part) => part.trim()).filter((part) => part !== "" && Number.isFinite(Number(part))).map(Number);
}

const rectText = (rect) => rect.map((value) => n1(Number(value))).join(", ");

function moved(box, element, tolerance) {
  const edges = [
    [Number(box[0]), Number(element[0])], [Number(box[1]), Number(element[1])],
    [Number(box[0]) + Number(box[2]), Number(element[0]) + Number(element[2])],
    [Number(box[1]) + Number(box[3]), Number(element[1]) + Number(element[3])],
  ];
  return edges.some(([a, b]) => Math.abs(a - b) > tolerance);
}

// --static: each name of the spec, quoted in a UI file.
function staticCheck(screen, spec) {
  const check = readCheckConfig();
  const dirs = check.uiDirs.length > 0 ? check.uiDirs : ["."];
  const files = [];
  const visit = (dir) => {
    let names;
    try { names = readdirSync(dir); } catch { return; }
    for (const name of names) {
      if (name.startsWith(".") || check.skip.includes(name) || name === "node_modules") continue;
      const path = join(dir, name);
      let stats;
      try { stats = statSync(path); } catch { continue; }
      if (stats.isDirectory()) { if (!(dir === "." && ["product", "director", "tools", "tests", "test"].includes(name))) visit(path); }
      else if (/\.(tsx|jsx|ts|js|mjs|vue|svelte|astro|html|dart|py)$/.test(name) && stats.size < 2000000) files.push(path);
    }
  };
  for (const dir of dirs) visit(dir.replace(/\/$/, ""));
  const sources = files.map((path) => ({ path: path.replace(/\\/g, "/"), text: readFileSync(path, "utf8") }));
  say(`${screen}: the names in product/ui/${screen}.md, looked for in the source (no capture, so where and focus are unverified)`);
  say("| Element | Name | In the source |");
  say("|---|---|---|");
  let absent = 0;
  for (const row of spec.rows) {
    if (row.name === "" || row.name === "-") continue;
    const quoted = [`"${row.name}"`, `'${row.name}'`, `\`${row.name}\``];
    const hit = sources.find((source) => quoted.some((form) => source.text.includes(form)));
    if (!hit) absent++;
    say(`| ${row.element} | ${row.name} | ${hit ? hit.path : "not found"} |`);
  }
  say(`${absent} name${absent === 1 ? "" : "s"} not found in ${dirs.join(" ")}`);
  return 3;
}

async function compareImages(screen, drawing) {
  let names;
  try { names = readdirSync(CAPTURES); } catch { return; }
  const stems = names.filter((file) => file.endsWith(".png") && !file.includes(".map.") && !file.includes(".compare@")
    && isCaptureOf(file.replace(/\.png$/, ""), screen)).map((file) => file.replace(/\.png$/, "")).sort();
  if (stems.length === 0) { say("no compare image: the capture has no .png"); return; }
  const wanted = stems.filter((stem) => {
    const head = stem.split("@")[0];
    const stemState = head.length > screen.length ? head.substring(screen.length + 1) : "default";
    return (drawing.frames || []).some((frame) => frame.name === screen && (frame.state || "default") === stemState);
  });
  if (wanted.length === 0) return;
  let chromium;
  try { ({ chromium } = await import("playwright")); } catch { say("no compare image: Playwright isn't installed in tools/ui"); return; }
  const browser = await chromium.launch();
  try {
    const { compareFiles } = await import("./overlay.mjs");
    for (const stem of wanted) {
      const result = await compareFiles(browser, join(CAPTURES, stem).replace(/\\/g, "/"));
      if (!result.ok) { say(result.message); continue; }
      say(`compare image: ${result.path.replace(/\\/g, "/")}`);
      if (result.message !== "") say(result.message);
    }
  } finally {
    await browser.close();
  }
}

async function run(args) {
  let screen = "";
  let state = "default";
  let sizeOption = "";
  let staticOnly = false;
  for (let index = 0; index < args.length; index++) {
    if (args[index] === "--state") state = args[++index] || "default";
    else if (args[index] === "--size") sizeOption = args[++index] || "";
    else if (args[index] === "--static") staticOnly = true;
    else if (!args[index].startsWith("-")) screen = args[index];
  }
  if (screen === "") return stop("usage: node tools/ui/verify.mjs <screen> [--state <name>] [--size <W>x<H>] [--static]", 1);
  const config = readConfig();
  const specPath = join(SPECS, screen + ".md");
  if (!existsSync(specPath)) return stop(`no spec at product/ui/${screen}.md; /ui-design process ${screen} writes it from the drawing`, 3);
  const spec = readSpec(specPath);
  if (spec.rows.length === 0) return stop(`product/ui/${screen}.md has no Layout table (## Layout (at WxH), with a row per element)`, 3);
  if (staticOnly) return staticCheck(screen, spec);
  let size = spec.size || config.sizes[0];
  if (sizeOption !== "") {
    size = parseSize(sizeOption);
    if (!size) return stop("--size takes WxH, such as 1920x1080", 1);
  }
  const prefix = state === "default" ? screen : `${screen}.${state}`;
  const base = `${prefix}@${size.x}x${size.y}`;
  const mapPath = join(CAPTURES, base + ".elements.json");
  if (!existsSync(mapPath)) return stop(`no capture ${base}.elements.json; run bash tools/ui_capture.sh ${screen} first`, 3);
  let map;
  try { map = JSON.parse(readFileSync(mapPath, "utf8")); } catch { map = null; }
  if (!map || !Array.isArray(map.elements)) return stop(`product/ui/captures/${base}.elements.json isn't an element map`, 3);

  const byName = new Map();
  for (const element of map.elements) if (element.stable && !byName.has(String(element.id))) byName.set(String(element.id), element);
  const lint = readLint(join(CAPTURES, base + ".lint.txt"));
  const tolerance = config.tolerance;
  let deviations = 0;

  say(`${base} against product/ui/${screen}.md (tolerance ${n1(tolerance)}% per edge)`);
  say("| Element | Name | Expected (x, y, w, h %) | Found | Verdict |");
  say("|---|---|---|---|---|");
  const listed = [];
  const reported = new Map();
  let checked = 0;
  for (const row of spec.rows) {
    if (row.name === "" || row.name === "-") {
      say(`| ${row.element} | - | ${row.where} | - | skipped: no data-testid in the spec |`);
      continue;
    }
    checked++;
    listed.push(row.name);
    const where = numbers(row.where);
    const problems = [];
    let found = "-";
    if (where.length !== 4) problems.push("the spec's Where isn't x, y, w, h");
    const element = byName.get(row.name);
    if (!element) problems.push(`missing: no visible element with data-testid "${row.name}"`);
    else {
      const rect = Array.isArray(element.rect_pct) ? element.rect_pct.map(Number) : [0, 0, 0, 0];
      found = rectText(rect);
      if (where.length === 4) {
        const edges = [["left", where[0], rect[0]], ["top", where[1], rect[1]], ["right", where[0] + where[2], rect[0] + rect[2]], ["bottom", where[1] + where[3], rect[1] + rect[3]]];
        const off = edges.filter(([, expected, actual]) => Math.abs(expected - actual) > tolerance)
          .map(([edge, expected, actual]) => `${edge} edge ${n1(actual)}, expected ${n1(expected)}`);
        if (off.length > 0) problems.push("moved: " + off.join("; "));
      }
      const own = lint.byElement.get(Number(element.n)) || [];
      if (element.focusable && element.focus_order === null && !own.includes("unreachable")) problems.push("unreachable: focusable, but Tab never gets there");
      for (const rule of own) if (!WARNINGS.includes(rule)) problems.push("lint: " + rule);
    }
    reported.set(row.name, problems.length > 0);
    if (problems.length > 0) deviations++;
    say(`| ${row.element} | ${row.name} | ${row.where} | ${found} | ${problems.length === 0 ? "ok" : problems.join(", ")} |`);
  }

  // Elements with a data-testid that the spec doesn't list.
  for (const [name, element] of byName) {
    if (!listed.includes(name)) say(`not in the spec: ${name} at ${rectText(element.rect_pct || [0, 0, 0, 0])}`);
  }

  // The capture's own errors, and findings in the screen's other states and sizes.
  for (const line of lint.errors) { deviations++; say("capture error: " + line); }
  for (const line of lint.notes) say("capture " + line);
  let files;
  try { files = readdirSync(CAPTURES); } catch { files = []; }
  for (const file of files.filter((name) => name.endsWith(".lint.txt") && name !== base + ".lint.txt" && isCaptureOf(name.replace(/\.lint\.txt$/, ""), screen)).sort()) {
    for (const line of readFileSync(join(CAPTURES, file), "utf8").replace(/\r/g, "").split("\n")) {
      if (line.trim() === "") continue;
      const first = line.split(" ")[0];
      if (!WARNINGS.includes(first) && first !== "note:") deviations++;
      say(`lint in ${file.replace(/\.lint\.txt$/, "")}: ${line}`);
    }
  }

  // The drawing: boxes whose element moved away, and the compare images.
  let drawing;
  try { drawing = JSON.parse(readFileSync(join(CAPTURES, screen + ".drawing.json"), "utf8")); } catch { drawing = null; }
  if (drawing && typeof drawing === "object") {
    for (const frame of drawing.frames || []) {
      if (frame.name !== screen || (frame.state || "default") !== state) continue;
      for (const box of frame.boxes || []) {
        if (box.intent === "remove") continue;
        for (const overlap of box.overlaps || []) {
          const name = String(overlap.name || "");
          if (!byName.has(name) || reported.get(name)) continue;
          const elementRect = byName.get(name).rect_pct || [0, 0, 0, 0];
          if (moved(box.rect_pct || [0, 0, 0, 0], elementRect, tolerance)) {
            reported.set(name, true);
            deviations++;
            say(`moved from the drawing: ${name}, box ${box.id || "?"} (${box.label || ""}) was drawn at ${rectText(box.rect_pct || [0, 0, 0, 0])} and is now at ${rectText(elementRect)}`);
          }
        }
      }
    }
    await compareImages(screen, drawing);
  } else {
    say(`no ${screen}.drawing.json, so no compare image (process the drawing first)`);
  }

  say(`${checked} element${checked === 1 ? "" : "s"} checked, ${deviations} deviation${deviations === 1 ? "" : "s"}`);
  return deviations === 0 ? 0 : 1;
}

process.exitCode = await run(process.argv.slice(2));
