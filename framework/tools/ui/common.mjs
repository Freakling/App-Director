// Screen capture: settings, the catalog and paths · framework-owned: replaced on upgrade.
//
// Shared by tools/ui/capture.mjs, verify.mjs and overlay.mjs. Paths are relative to the project
// root, which is the working directory (bash tools/ui_capture.sh changes to it).

import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { URL } from "node:url";

export const CONFIG_PATH = "tools/ui_capture.cfg";
export const CHECK_CONFIG_PATH = "tools/check.cfg";
export const CATALOG_PATH = "tools/ui/screens.mjs";
export const SPECS = "product/ui";
export const CAPTURES = "product/ui/captures";
export const DRAWINGS = "director/ui";
export const AUTH_DIR = "tools/ui/.auth";
export const INSTALL_HINT = "cd tools/ui && npm install && npx playwright install chromium";
// The hosts capture opens without being told: this machine only.
export const LOCAL_HOSTS = ["localhost", "127.0.0.1", "[::1]", "::1"];
export const CATALOG_KEYS = ["id", "title", "route", "states", "auth", "source", "animate"];

// An ini file as check.cfg reads it: `[section]`, `key = value`, `;` starts a comment.
export function readIni(path) {
  const result = {};
  if (!existsSync(path)) return null;
  let section = "";
  for (const raw of readFileSync(path, "utf8").split("\n")) {
    const line = raw.replace(/\r$/, "").replace(/\s*;.*$/, "");
    const header = /^\[(.+)\]\s*$/.exec(line);
    if (header) {
      section = header[1];
      result[section] = result[section] || {};
      continue;
    }
    const eq = line.indexOf("=");
    if (eq < 0 || section === "") continue;
    result[section][line.substring(0, eq).trim()] = line.substring(eq + 1).trim();
  }
  return result;
}

function get(ini, section, key, fallback) {
  const value = ini && ini[section] ? ini[section][key] : undefined;
  return value === undefined || value === "" ? fallback : value;
}

function list(value) {
  return String(value || "").split(/\s+/).filter((item) => item !== "");
}

export function parseSize(text) {
  const match = /^(\d+)x(\d+)$/.exec(String(text).trim().toLowerCase());
  if (!match) return null;
  const size = { x: Number(match[1]), y: Number(match[2]) };
  return size.x > 0 && size.y > 0 ? size : null;
}

// tools/ui_capture.cfg, with the defaults of a missing key. problems lists what isn't valid.
export function readConfig() {
  const ini = readIni(CONFIG_PATH);
  const problems = [];
  const sizes = [];
  for (const item of list(get(ini, "sizes", "list", "1920x1080 2560x1080 1280x720"))) {
    const size = parseSize(item);
    if (size) sizes.push(size);
    else problems.push(`tools/ui_capture.cfg › [sizes] list: '${item}' isn't WxH`);
  }
  const number = (section, key, fallback) => {
    const value = Number(get(ini, section, key, fallback));
    return Number.isFinite(value) ? value : fallback;
  };
  return {
    missing: ini === null,
    problems,
    sizes: sizes.length > 0 ? sizes : [{ x: 1920, y: 1080 }],
    seed: Math.trunc(number("capture", "seed", 12345)),
    settleFrames: Math.max(1, Math.trunc(number("capture", "settle_frames", 6))),
    maxElements: Math.max(1, Math.trunc(number("capture", "max_elements", 200))),
    setupTimeout: Math.max(1, number("capture", "setup_timeout", 60)),
    skip: list(get(ini, "capture", "skip", "")),
    baseUrl: get(ini, "web", "base_url", ""),
    apiUrl: get(ini, "web", "api_url", ""),
    allowHosts: list(get(ini, "web", "allow_hosts", "")),
    startCommand: get(ini, "web", "start_command", ""),
    readyUrl: get(ini, "web", "ready_url", ""),
    startTimeout: Math.max(1, number("web", "start_timeout", 120)),
    minLabelChars: number("lint", "min_label_chars", 6),
    maxButtonHeightRatio: number("lint", "max_button_height_ratio", 2.0),
    tolerance: number("verify", "tolerance_pct", 4.0),
  };
}

// tools/check.cfg: the stack, the UI folders and the folders to skip.
export function readCheckConfig() {
  const ini = readIni(CHECK_CONFIG_PATH);
  const stack = get(ini, "project", "stack", "");
  return {
    stack: stack.startsWith("{{") ? "" : stack,
    uiDirs: list(get(ini, "ui", "dirs", "")).filter((dir) => !dir.startsWith("{{")),
    skip: list(get(ini, "scan", "skip", "node_modules dist build .dart_tool __pycache__ .venv")),
  };
}

// The host of a URL when capture may open it (this machine, or a host in [web] allow_hosts), else
// null with the reason.
export function localHost(url, allowHosts) {
  let parsed;
  try { parsed = new URL(url); } catch { return { ok: false, reason: `'${url}' isn't a URL` }; }
  if (parsed.protocol !== "http:" && parsed.protocol !== "https:") return { ok: false, reason: `'${url}' isn't http or https` };
  const host = parsed.hostname.toLowerCase();
  if (LOCAL_HOSTS.includes(host) || allowHosts.map((item) => item.toLowerCase()).includes(host)) return { ok: true, host };
  return { ok: false, reason: `${host} isn't this machine (localhost, 127.0.0.1) or a host in tools/ui_capture.cfg › [web] allow_hosts; capture never opens a deployed site` };
}

// The catalog: {baseUrl, entries, errors}. Each entry is {id, title, route, states: {name: fn|null},
// auth, source, animate}. An entry with a problem is left out and named in errors.
export async function loadCatalog() {
  if (!existsSync(CATALOG_PATH)) return { baseUrl: "", entries: [], errors: [`no ${CATALOG_PATH}; the installer creates it (rerun install.sh)`] };
  let module;
  try {
    module = await import(pathToFileURL(resolve(CATALOG_PATH)).href);
  } catch (error) {
    return { baseUrl: "", entries: [], errors: [`${CATALOG_PATH} doesn't load: ${error && error.message ? error.message : error}`] };
  }
  const catalog = module.default;
  if (!catalog || typeof catalog !== "object" || !Array.isArray(catalog.screens)) {
    return { baseUrl: "", entries: [], errors: [`${CATALOG_PATH} must export default { screens: [...] }`] };
  }
  const errors = [];
  const entries = [];
  const seen = new Set();
  catalog.screens.forEach((screen, index) => {
    const where = `${CATALOG_PATH} entry ${index + 1}`;
    if (!screen || typeof screen !== "object") { errors.push(`${where} isn't an object`); return; }
    const id = typeof screen.id === "string" ? screen.id : "";
    const problems = [];
    for (const key of Object.keys(screen)) if (!CATALOG_KEYS.includes(key)) problems.push(`unknown key '${key}' (keys: ${CATALOG_KEYS.join(", ")})`);
    if (!/^[A-Za-z0-9_-]+$/.test(id)) problems.push("its id must be letters, digits, _ or - (it names the files)");
    else if (seen.has(id)) problems.push(`the id '${id}' is used twice`);
    if (typeof screen.title !== "string" || screen.title.trim() === "") problems.push("it has no title");
    if (typeof screen.route !== "string" || !screen.route.startsWith("/")) problems.push("its route must be a path such as \"/orders\"");
    if (screen.auth !== undefined && (typeof screen.auth !== "string" || !/^[A-Za-z0-9_-]+$/.test(screen.auth))) problems.push("auth names a saved sign-in in tools/ui/.auth/ (letters, digits, _ or -)");
    if (screen.source !== undefined && typeof screen.source !== "string") problems.push("source is the file that renders the screen");
    let states = { default: null };
    if (screen.states !== undefined) {
      if (!screen.states || typeof screen.states !== "object" || Object.keys(screen.states).length === 0) problems.push("states must name at least one state");
      else {
        states = {};
        for (const [name, setup] of Object.entries(screen.states)) {
          if (!/^[A-Za-z0-9_-]+$/.test(name)) problems.push(`the state '${name}' must be letters, digits, _ or -`);
          else if (setup !== null && typeof setup !== "function") problems.push(`the state '${name}' must be a function (page, api, screen) or null`);
          else states[name] = setup;
        }
      }
    }
    if (id !== "") seen.add(id);
    if (problems.length > 0) {
      errors.push(`${id || where}: ${problems.join("; ")}`);
      return;
    }
    entries.push({ id, title: screen.title, route: screen.route, states, auth: screen.auth || "", source: screen.source || "", animate: Boolean(screen.animate) });
  });
  return { baseUrl: typeof catalog.baseUrl === "string" ? catalog.baseUrl : "", entries, errors };
}

// `<id>[.<state>]@<W>x<H>`: the name of a capture's files.
export function captureName(id, state, size) {
  return `${id}${state === "default" ? "" : "." + state}@${size.x}x${size.y}`;
}

// True for `<screen>@<W>x<H>` and `<screen>.<state>@<W>x<H>`, not for another screen whose id starts the same.
export function isCaptureOf(stem, screen) {
  if (!stem.startsWith(screen) || !stem.includes("@")) return false;
  const rest = stem.substring(screen.length);
  return rest.startsWith("@") || (rest.startsWith(".") && !rest.split("@")[0].substring(1).includes("."));
}

// A number as the reports write it: one decimal, without a trailing ".0".
export function n1(value) {
  const text = (Math.round(value * 10) / 10).toFixed(1);
  return text.endsWith(".0") ? text.slice(0, -2) : text;
}
