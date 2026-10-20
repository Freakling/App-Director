// Screen capture runner (Playwright) · framework-owned: replaced on upgrade.
//
// Run it with `bash tools/ui_capture.sh` (.app-director/procedures/ui-design.md). For every screen in
// the catalog (tools/ui/screens.mjs), state and size in tools/ui_capture.cfg, it opens the app on
// this machine in headless Chromium and writes to product/ui/captures/ `<id>[.<state>]@<W>x<H>`
// .png (the screenshot of the viewport), .elements.json (the element map), .map.png (the screenshot
// with every element outlined and numbered) and .lint.txt (layout lint findings, empty when clean).
// The default state at the default size (the first of [sizes] list) also gets
// `<id>.starter.excalidraw`, the drawing the human draws over (tools/ui/drawing.mjs).
//
// Arguments: <screen id> or --all, --state <name>, --size <W>x<H> (listed in tools/ui_capture.cfg or
// not), --list (print the catalog), --missing (list the UI files that look like screens and that no
// catalog entry names as its source; it never fails).
//
// It opens only this machine (localhost, 127.0.0.1) or a host in [web] allow_hosts, never a deployed
// site, and each screen and state in a fresh browser context, so nothing is kept between screens.
// States seed their data through the app's public API (the `api` helper), never real user data.
// Exit codes: 0 done (lint findings don't count) · 1 a screen failed · 3 couldn't run (no web app to
// open, a host that isn't local, no Playwright or Chromium, the app didn't start).

import { spawn, spawnSync } from "node:child_process";
import { closeSync, existsSync, mkdirSync, openSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import { request as httpRequest } from "node:http";
import { request as httpsRequest } from "node:https";
import { posix, relative } from "node:path";
import process from "node:process";
import console from "node:console";
import { setTimeout as sleep } from "node:timers/promises";
import { URL } from "node:url";
import {
  AUTH_DIR, CAPTURES, DRAWINGS, INSTALL_HINT, SPECS, captureName, loadCatalog, localHost, parseSize,
  readCheckConfig, readConfig,
} from "./common.mjs";
import { starterText } from "./drawing.mjs";
import { mapScreen } from "./lint.mjs";
import { drawMap } from "./overlay.mjs";

const { join } = posix;

const FIXED_TIME = "2026-01-01T12:00:00Z";
const STILL_CSS = "*, *::before, *::after { animation-duration: 0s !important; animation-delay: 0s !important; "
  + "transition-duration: 0s !important; transition-delay: 0s !important; scroll-behavior: auto !important; caret-color: transparent !important; }";

const say = (text) => console.log(`ui_capture: ${text}`);
const fail = (text) => console.log(`ui_capture: FAIL: ${text}`);
// Exit 3: capture couldn't run. Nothing is written.
class CannotRun extends Error {}

function parseArgs(args) {
  const options = { screen: "", state: "", size: "", list: false, missing: false, problems: [] };
  for (let index = 0; index < args.length; index++) {
    const arg = args[index];
    if (arg === "--all" || arg === "all") options.screen = "";
    else if (arg === "--list") options.list = true;
    else if (arg === "--missing") { options.list = true; options.missing = true; }
    else if (arg === "--state" || arg === "--size") {
      if (index + 1 >= args.length) options.problems.push(`${arg} needs a value`);
      else if (arg === "--state") options.state = args[++index];
      else if (!parseSize(args[index + 1])) { options.problems.push("--size takes WxH, such as 1920x1080"); index++; }
      else options.size = args[++index];
    } else if (arg.startsWith("-")) options.problems.push(`unknown option ${arg}`);
    else options.screen = arg;
  }
  return options;
}

// --- list and missing ---------------------------------------------------------------------------

function printList(entries, config) {
  for (const entry of entries) {
    say(`${entry.id} · ${entry.title} · states: ${Object.keys(entry.states).join(", ")} · opens ${entry.route} · drawing: ${existsSync(join(DRAWINGS, entry.id + ".excalidraw")) ? "yes" : "no"} · spec: ${existsSync(join(SPECS, entry.id + ".md")) ? "yes" : "no"}${config.skip.includes(entry.id) ? " · skipped (tools/ui_capture.cfg)" : ""}`);
  }
  if (entries.length === 0) say("(the catalog lists no screens)");
}

const SCREEN_FOLDERS = ["pages", "screens", "views", "routes", "app"];
const SCREEN_FILE = /(^page\.|^\+page\.|Page\.|Screen\.|View\.|_page\.|_screen\.|_view\.)/;
const SOURCE_FILE = /\.(tsx|jsx|ts|js|mjs|vue|svelte|astro|html|dart|py)$/;

// The UI files (tools/check.cfg › [ui] dirs) that look like screens: in a folder named pages,
// screens, views, routes or app, or named like page.tsx, OrdersPage.tsx or orders_screen.dart. One
// that no catalog entry names as its `source`, and that [capture] skip doesn't name, is listed.
function printMissing(entries, config) {
  const check = readCheckConfig();
  if (check.uiDirs.length === 0) {
    say("note: no UI folders set (tools/check.cfg › [ui] dirs), so the files that are screens can't be told");
    return;
  }
  const found = [];
  const visit = (dir) => {
    let names;
    try { names = readdirSync(dir).sort(); } catch { return; }
    for (const name of names) {
      const path = join(dir, name).replace(/\\/g, "/");
      if (name.startsWith(".") || check.skip.includes(name)) continue;
      let stats;
      try { stats = statSync(path); } catch { continue; }
      if (stats.isDirectory()) visit(path);
      else if (SOURCE_FILE.test(name) && !/\.(test|spec)\./.test(name)
        && (SCREEN_FILE.test(name) || path.split("/").slice(0, -1).some((part) => SCREEN_FOLDERS.includes(part)))) found.push(path);
    }
  };
  for (const dir of check.uiDirs) visit(dir.replace(/\/$/, ""));
  const covered = entries.map((entry) => entry.source.replace(/^\.\//, ""));
  let missing = 0;
  for (const path of [...new Set(found)].sort()) {
    const stem = path.split("/").pop().replace(/\.[^.]+$/, "");
    if (covered.includes(path) || config.skip.includes(path) || config.skip.includes(stem)) continue;
    missing++;
    console.log(`missing: ${path}`);
  }
  say(`note: ${found.length} screen file${found.length === 1 ? "" : "s"} found, ${missing} without a catalog entry (source) or a skip`);
}

// --- the app ------------------------------------------------------------------------------------

function probe(url) {
  return new Promise((done) => {
    let parsed;
    try { parsed = new URL(url); } catch { done(0); return; }
    const request = (parsed.protocol === "https:" ? httpsRequest : httpRequest)(parsed, { method: "GET", timeout: 3000 }, (response) => {
      response.resume();
      done(response.statusCode || 0);
    });
    request.on("error", () => done(0));
    request.on("timeout", () => { request.destroy(); done(0); });
    request.end();
  });
}

const STATE_DIR = ".app-director/state";
const APP_LOG = ".app-director/state/ui_app.log";
// The app a capture started, and the capture's own process: "<app pid> <capture pid>". It is
// removed when the capture stops the app; one left behind means a capture was killed before it
// could, and the next capture stops that app before it looks for a running one.
const APP_PID = ".app-director/state/ui_app.pid";
const windows = process.platform === "win32";

function alive(pid) {
  try { process.kill(pid, 0); return true; } catch { return false; }
}

// The processes whose parent is pid (Windows), even when that parent has exited.
function childrenOf(pid) {
  const listed = spawnSync("powershell", ["-NoProfile", "-NonInteractive", "-Command",
    `Get-CimInstance Win32_Process -Filter 'ParentProcessId=${Number(pid)}' | ForEach-Object { $_.ProcessId }`],
  { encoding: "utf8", windowsHide: true });
  return String(listed.stdout || "").split(/\s+/).map(Number).filter((child) => Number.isInteger(child) && child > 0 && child !== pid);
}

// Stops the process tree (Windows) or the process group (elsewhere) of a started app: SIGTERM,
// a short wait, then SIGKILL for whatever is left. The group is signalled even when the shell
// has exited, since the server it started may still run in it.
async function stopTree(pid) {
  if (windows) {
    const killed = spawnSync("taskkill", ["/pid", String(pid), "/T", "/F"], { stdio: "ignore", windowsHide: true });
    // The shell may be gone (its capture was killed), leaving the server it started: find what
    // still names it as its parent, and stop that tree.
    if (killed.status !== 0) for (const child of childrenOf(pid)) await stopTree(child);
    return;
  }
  const group = (signal) => { try { process.kill(-pid, signal); return true; } catch { return false; } };
  if (!group("SIGTERM")) return;
  for (let waited = 0; waited < 3000; waited += 100) {
    if (!group(0)) return;
    await sleep(100);
  }
  group("SIGKILL");
}

// An app an interrupted capture left running: stop it, so it isn't taken for one the human started.
async function stopLeftover() {
  if (!existsSync(APP_PID)) return;
  const [appPid, capturePid] = readFileSync(APP_PID, "utf8").trim().split(/\s+/).map(Number);
  if (Number.isInteger(capturePid) && capturePid !== process.pid && alive(capturePid)) return;   // another capture is running
  rmSync(APP_PID, { force: true });
  if (Number.isInteger(appPid) && appPid > 0) {
    say(`stopping the app an interrupted capture left running (pid ${appPid})`);
    await stopTree(appPid);
  }
}

// Starts [web] start_command when the app isn't answering, and waits for [web] ready_url. Returns a
// function that stops what it started. Its output goes to .app-director/state/ui_app.log.
async function startApp(config, baseUrl) {
  const ready = config.readyUrl || baseUrl;
  const answering = async () => { const status = await probe(ready); return status > 0 && status < 500; };
  await stopLeftover();
  if (await answering()) return async () => undefined;
  if (config.startCommand === "") {
    throw new CannotRun(`nothing answers at ${ready}. Start the app (its dev or test server), or set tools/ui_capture.cfg › [web] start_command so capture starts it`);
  }
  mkdirSync(STATE_DIR, { recursive: true });
  const log = openSync(APP_LOG, "w");
  const child = spawn(config.startCommand, { shell: true, detached: !windows, stdio: ["ignore", log, log], windowsHide: true });
  closeSync(log);
  writeFileSync(APP_PID, `${child.pid} ${process.pid}\n`);
  let stopped = false;
  const stop = async () => {
    if (stopped) return;
    stopped = true;
    await stopTree(child.pid);
    rmSync(APP_PID, { force: true });
  };
  say(`starting the app: ${config.startCommand} (its output: ${APP_LOG})`);
  const started = Date.now();
  while (Date.now() - started < config.startTimeout * 1000) {
    if (await answering()) return stop;
    if (child.exitCode !== null) break;
    await sleep(500);
  }
  const code = child.exitCode;
  await stop();
  if (code !== null) {
    throw new CannotRun(`'${config.startCommand}' ([web] start_command) ended with exit ${code} before the app answered at ${ready} (its output: ${APP_LOG})`);
  }
  throw new CannotRun(`the app didn't answer at ${ready} within ${config.startTimeout} seconds of '${config.startCommand}' ([web] start_timeout; its output: ${APP_LOG})`);
}

// The `api` helper a state seeds data with: requests to the app's API on this machine, in the
// screen's browser context (so they share its sign-in). A response that isn't OK throws, and so
// does a redirect: it isn't followed, so it can't lead off this machine.
function makeApi(context, apiBase, allowHosts) {
  const call = async (method, path, options = {}) => {
    const url = new URL(path, apiBase).href;
    const host = localHost(url, allowHosts);
    if (!host.ok) throw new Error(`api: ${host.reason}`);
    const response = await context.request.fetch(url, { method, ...options, maxRedirects: 0 });
    if (!response.ok()) throw new Error(`api: ${method} ${url} answered ${response.status()}`);
    return response;
  };
  return {
    fetch: call,
    get: (path, options) => call("GET", path, options),
    post: (path, data, options) => call("POST", path, { ...options, data }),
    put: (path, data, options) => call("PUT", path, { ...options, data }),
    patch: (path, data, options) => call("PATCH", path, { ...options, data }),
    delete: (path, options) => call("DELETE", path, options),
  };
}

// Keeps a screen on this machine: every request and WebSocket the page makes comes through here. A
// request to a host that isn't local is aborted, and the host noted in `blocked`. Redirects are
// followed here, one hop at a time, and each hop is checked, so none can lead off this machine
// either. data: and blob: URLs never leave the browser.
const REDIRECTS = [301, 302, 303, 307, 308];
async function guard(context, allowHosts, blocked) {
  const allowed = (url) => {
    if (/^(data|blob):/i.test(url)) return true;
    const host = localHost(url, allowHosts);
    if (!host.ok) {
      let name;
      try { name = new URL(url).host || url; } catch { name = url; }
      if (!blocked.includes(name)) blocked.push(name);
    }
    return host.ok;
  };
  await context.route("**/*", async (route) => {
    let url = route.request().url();
    if (!allowed(url)) { await route.abort("blockedbyclient").catch(() => undefined); return; }
    try {
      let method = route.request().method();
      let response = await route.fetch({ maxRedirects: 0 });
      for (let hop = 0; hop < 20 && REDIRECTS.includes(response.status()) && response.headers().location; hop++) {
        const next = new URL(response.headers().location, url).href;
        if (!allowed(next)) { await route.abort("blockedbyclient"); return; }
        if (response.status() === 303 || ((response.status() === 301 || response.status() === 302) && method === "POST")) method = "GET";
        response = await route.fetch({ url: next, method, maxRedirects: 0 });
        url = next;
      }
      await route.fulfill({ response });
    } catch {
      await route.abort().catch(() => undefined);
    }
  });
  await context.routeWebSocket(() => true, (socket) => {
    if (allowed(socket.url())) socket.connectToServer();
    else socket.close({ code: 1008, reason: "capture opens only this machine" });
  });
}

function seededRandom(seed) {
  return `(() => { let s = ${seed >>> 0}; Math.random = function () { s = (s + 0x6D2B79F5) >>> 0; let t = s;
    t = Math.imul(t ^ (t >>> 15), t | 1); t ^= t + Math.imul(t ^ (t >>> 7), t | 61); return ((t ^ (t >>> 14)) >>> 0) / 4294967296; }; })();`;
}

function stillScript() {
  return `(() => { const add = () => { const style = document.createElement("style"); style.setAttribute("data-ddd", "still");
    style.textContent = ${JSON.stringify(STILL_CSS)}; (document.head || document.documentElement).appendChild(style); };
    if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", add); else add(); })();`;
}

// The data-testid values the screen's spec names, so their direct children are mapped.
function specNames(id) {
  const path = join(SPECS, id + ".md");
  if (!existsSync(path)) return [];
  const names = [];
  let inLayout = false;
  for (const line of readFileSync(path, "utf8").replace(/\r/g, "").split("\n")) {
    if (line.startsWith("#")) { inLayout = line.startsWith("## Layout"); continue; }
    if (!inLayout || !line.trim().startsWith("|")) continue;
    const cells = line.trim().replace(/^\|/, "").replace(/\|$/, "").split("|").map((cell) => cell.replace(/`/g, "").trim());
    if (cells.length >= 4 && cells[0] !== "#" && !/^:?-/.test(cells[0]) && cells[2] !== "" && cells[2] !== "-") names.push(cells[2].replace(/^%/, ""));
  }
  return names;
}

function withTimeout(promise, seconds, message) {
  let timer;
  const limit = new Promise((_, reject) => { timer = globalThis.setTimeout(() => reject(new Error(message)), seconds * 1000); });
  return Promise.race([promise, limit]).finally(() => globalThis.clearTimeout(timer));
}

// --- one capture --------------------------------------------------------------------------------

async function captureOne(browser, run, entry, state, setup, size) {
  const { config, baseUrl, apiUrl } = run;
  const base = captureName(entry.id, state, size);
  const path = join(CAPTURES, base);
  const errors = [];
  const contextOptions = {
    viewport: { width: size.x, height: size.y }, deviceScaleFactor: 1, locale: "en-US", timezoneId: "UTC",
    reducedMotion: "reduce", colorScheme: "light", baseURL: baseUrl, serviceWorkers: "block",
  };
  if (entry.auth !== "") {
    const saved = join(AUTH_DIR, entry.auth + ".json");
    if (!existsSync(saved)) {
      return finishFailed(path, base, `no saved sign-in ${saved}: sign in once as the test account and save it (npx playwright codegen --save-storage=${saved} ${baseUrl}); never a real user's account`);
    }
    contextOptions.storageState = saved;
  }
  const context = await browser.newContext(contextOptions);
  const blocked = [];
  try {
    await guard(context, config.allowHosts, blocked);
    await context.clock.setFixedTime(new Date(FIXED_TIME));
    await context.addInitScript(seededRandom(config.seed));
    if (!entry.animate) await context.addInitScript(stillScript());
    const page = await context.newPage();
    page.on("pageerror", (error) => errors.push(`a page error: ${String(error && error.message ? error.message : error).split("\n")[0]}`));
    const url = new URL(entry.route, baseUrl).href;
    let opened = false;
    const open = async () => {
      opened = true;
      const response = await page.goto(url, { waitUntil: "load" });
      if (response && !response.ok()) throw new Error(`${entry.route} answered ${response.status()}`);
    };
    say(`begin ${base}`);
    try {
      await withTimeout((async () => {
        if (setup) await setup(page, makeApi(context, apiUrl, config.allowHosts), { id: entry.id, state, route: entry.route, url, open });
        if (!opened) await open();
      })(), config.setupTimeout, `the setup didn't finish within ${config.setupTimeout} seconds ([capture] setup_timeout)`);
      await page.waitForLoadState("load");
      await page.waitForLoadState("networkidle", { timeout: 10000 }).catch(() => undefined);
      await page.evaluate(() => globalThis.document.fonts.ready.then(() => undefined));
      await page.evaluate((frames) => new Promise((done) => {
        let count = 0;
        const step = () => { count++; if (count >= frames) done(); else globalThis.requestAnimationFrame(step); };
        globalThis.requestAnimationFrame(step);
      }), config.settleFrames);
    } catch (error) {
      return finishFailed(path, base, String(error && error.message ? error.message : error).split("\n")[0], blocked);
    }
    let png;
    let result;
    let mapImage;
    try {
      png = await page.screenshot({ animations: entry.animate ? "allow" : "disabled", caret: "hide", scale: "css" });
      result = await mapScreen(page, {
        size, maxElements: config.maxElements, minLabelChars: config.minLabelChars,
        maxButtonHeightRatio: config.maxButtonHeightRatio, specNames: specNames(entry.id),
      });
      mapImage = await drawMap(browser, png, result.elements);
    } catch (error) {
      return finishFailed(path, base, `the page changed while it was mapped: ${String(error && error.message ? error.message : error).split("\n")[0]}`, blocked);
    }
    writeFileSync(path + ".png", png);
    writeFileSync(path + ".elements.json", elementMap(entry, state, size, result));
    const top = errors.map((line) => `error: ${line}\n`).join("") + blockedNotes(blocked);
    writeFileSync(path + ".lint.txt", top + (result.findings.length > 0 ? result.findings.join("\n") + "\n" : ""));
    writeFileSync(path + ".map.png", mapImage);
    if (blocked.length > 0) say(`note: ${base}: blocked requests to ${blocked.join(", ")} (not this machine; noted in its lint file)`);
    if (state === "default" && size.x === config.sizes[0].x && size.y === config.sizes[0].y) {
      writeFileSync(join(CAPTURES, entry.id + ".starter.excalidraw"), starterText(entry.id, size, png, result.elements));
    }
    if (errors.length > 0) {
      fail(`${base}: the page printed errors (top of ${path}.lint.txt)`);
      say(`end ${base} · failed`);
      return { ok: false, findings: result.findings.length };
    }
    const count = result.elements.length;
    say(`end ${base} · ${count} element${count === 1 ? "" : "s"} · ${result.findings.length} lint finding${result.findings.length === 1 ? "" : "s"}`);
    return { ok: true, findings: result.findings.length };
  } finally {
    await context.close();
  }
}

// note: lines for the hosts a screen's page tried to reach, which capture blocked.
function blockedNotes(blocked) {
  return blocked.map((host) => `note: blocked requests to ${host}: not this machine, so capture never sends them\n`).join("");
}

function finishFailed(path, base, message, blocked = []) {
  fail(`${base}: ${message}`);
  writeFileSync(path + ".lint.txt", `error: ${message}\n` + blockedNotes(blocked));
  for (const extension of [".png", ".elements.json", ".map.png"]) rmSync(path + extension, { force: true });
  say(`end ${base} · failed`);
  return { ok: false, findings: 0 };
}

function elementMap(entry, state, size, result) {
  const lines = [
    "{",
    "  \"schema\": 1, \"adapter\": \"playwright\",",
    `  "screen": ${JSON.stringify(entry.id)}, "state": ${JSON.stringify(state)}, "size": [${size.x}, ${size.y}],`,
    `  "source": ${JSON.stringify(entry.route)},`,
    `  "capped": ${result.capped},`,
    "  \"elements\": [" + (result.elements.length === 0 ? "" : "\n" + result.elements.map((row) => "    " + JSON.stringify(row)).join(",\n") + "\n  ") + "]",
    "}",
  ];
  return lines.join("\n") + "\n";
}

// --- the run ------------------------------------------------------------------------------------

async function run(args) {
  const options = parseArgs(args);
  const config = readConfig();
  const problems = [...config.problems, ...options.problems];
  if (problems.length > 0) {
    for (const problem of problems) fail(problem);
    return 1;
  }
  const catalog = await loadCatalog();
  // A problem in another entry doesn't fail the capture of the one screen asked for.
  const scoped = !options.list && options.screen !== "" && catalog.entries.some((entry) => entry.id === options.screen);
  for (const error of catalog.errors) {
    if (scoped) say(`note: another entry in tools/ui/screens.mjs has a problem: ${error}`);
    else fail(error);
  }
  const failedCatalog = !scoped && catalog.errors.length > 0;
  if (options.list) {
    if (options.missing) printMissing(catalog.entries, config);
    else printList(catalog.entries, config);
    return failedCatalog ? 1 : 0;
  }

  // What to capture.
  const selected = [];
  for (const entry of catalog.entries) {
    if (options.screen !== "" && entry.id !== options.screen) continue;
    if (config.skip.includes(entry.id)) { say(`note: ${entry.id} is in tools/ui_capture.cfg › [capture] skip`); continue; }
    if (options.state !== "" && !Object.prototype.hasOwnProperty.call(entry.states, options.state)) {
      if (options.screen !== "") { fail(`${entry.id} has no state '${options.state}' (it has ${Object.keys(entry.states).join(", ")})`); return 1; }
      continue;
    }
    selected.push(entry);
  }
  if (options.screen !== "" && selected.length === 0 && !config.skip.includes(options.screen)) {
    fail(`no screen '${options.screen}' in tools/ui/screens.mjs; run bash tools/ui_capture.sh --list`);
    return 1;
  }

  // Whether it can run: a web app on this machine, Playwright and Chromium.
  const baseUrl = catalog.baseUrl || config.baseUrl;
  if (baseUrl === "") {
    const stack = readCheckConfig().stack;
    throw new CannotRun(`capture isn't available for this ${stack !== "" ? stack + " " : ""}app yet: it opens a web app (Flutter web included) in a browser, and tools/ui_capture.cfg › [web] base_url is empty. Native Flutter, mobile and desktop capture come later; list and process work without it, and verify checks the spec's names in the source`);
  }
  for (const [what, url] of [["base_url", baseUrl], ["api_url", config.apiUrl], ["ready_url", config.readyUrl]]) {
    if (url === "") continue;
    const host = localHost(url, config.allowHosts);
    if (!host.ok) throw new CannotRun(`refusing [web] ${what}: ${host.reason}`);
  }
  let chromium;
  try {
    ({ chromium } = await import("playwright"));
  } catch {
    throw new CannotRun(`Playwright isn't installed in tools/ui. Install it once (it needs Node 18 or newer): ${INSTALL_HINT}`);
  }
  if (!existsSync(chromium.executablePath())) {
    throw new CannotRun(`Playwright's Chromium isn't installed. Install it once: ${INSTALL_HINT}`);
  }
  if (selected.length === 0) {
    say("note: nothing to capture: tools/ui/screens.mjs lists no screen that matches");
    return failedCatalog ? 1 : 0;
  }

  const stopApp = await startApp(config, baseUrl);
  let browser = null;
  let captures = 0;
  let withFindings = 0;
  let failed = failedCatalog;
  // Interrupted (Ctrl+C, or the process is told to stop): stop the app it started first.
  const interrupted = async (signal) => {
    console.error(`ui_capture: interrupted (${signal}); stopping the app it started`);
    if (browser) await browser.close().catch(() => undefined);
    await stopApp();
    process.exit(130);
  };
  const signals = windows ? ["SIGINT", "SIGTERM", "SIGBREAK"] : ["SIGINT", "SIGTERM", "SIGHUP"];
  for (const signal of signals) process.once(signal, interrupted);
  try {
    try {
      browser = await chromium.launch();
    } catch (error) {
      throw new CannotRun(`Chromium didn't start: ${String(error && error.message ? error.message : error).split("\n")[0]}. ${INSTALL_HINT}`);
    }
    mkdirSync(CAPTURES, { recursive: true });
    const sizes = options.size !== "" ? [parseSize(options.size)] : config.sizes;
    const runState = { config, baseUrl, apiUrl: config.apiUrl || baseUrl };
    for (const size of sizes) {
      for (const entry of selected) {
        for (const [state, setup] of Object.entries(entry.states)) {
          if (options.state !== "" && options.state !== state) continue;
          const result = await captureOne(browser, runState, entry, state, setup, size);
          captures++;
          if (!result.ok) failed = true;
          if (result.findings > 0) withFindings++;
        }
      }
    }
  } finally {
    for (const signal of signals) process.removeListener(signal, interrupted);
    if (browser) await browser.close().catch(() => undefined);
    await stopApp();
  }
  say(`${captures} capture${captures === 1 ? "" : "s"} in ${relative(".", CAPTURES).replace(/\\/g, "/")} · ${withFindings} with lint findings${failed ? " · some screens failed" : ""}`);
  return failed ? 1 : 0;
}

try {
  process.exitCode = await run(process.argv.slice(2));
} catch (error) {
  if (error instanceof CannotRun) {
    console.error(`ui_capture: ${error.message}`);
    process.exitCode = 3;
  } else {
    console.error(`ui_capture: FAIL: ${error && error.stack ? error.stack : error}`);
    process.exitCode = 1;
  }
}
