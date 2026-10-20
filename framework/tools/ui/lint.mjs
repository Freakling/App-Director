// Element map and layout lint for screen captures · framework-owned: replaced on upgrade.
//
// mapScreen() lists what is on screen (the element map of .app-director/procedures/ui-design.md)
// and lints it, one line per finding: `<rule> element <n> <path>: <message>`. It reads the page
// Chromium shows: the DOM, the computed styles and boxes, and the accessibility tree through the
// Chrome DevTools Protocol (Accessibility.getFullAXTree, joined to the DOM by backendDOMNodeId).
// Focus order comes from pressing Tab. tools/ui/capture.mjs calls it after the screenshot, so the
// focus it moves is not in the image. Thresholds are in tools/ui_capture.cfg › [lint].

/* global document, getComputedStyle, Node, NodeFilter */

// The rules, in the order findings are listed for an element. hard-coded-position is a warning.
export const RULES = [
  "squeezed-text", "stretched-control", "off-screen", "overlap", "unreachable",
  "no-default-focus", "hard-coded-position",
];
export const WARNINGS = ["hard-coded-position"];
const NAME_LENGTH = 24;
const MARK = "data-ddd-i";
// Roles that say nothing about what an element is.
const PLAIN_ROLES = ["", "generic", "none", "presentation", "StaticText", "InlineTextBox", "LineBreak", "RootWebArea", "WebArea"];

// --- in the page --------------------------------------------------------------------------------

// Every visible element in tree order, marked with data-ddd-i so the accessibility tree and focus
// can be joined to it. Runs in the page.
function collect() {
  const SKIP = ["SCRIPT", "STYLE", "HEAD", "META", "LINK", "TEMPLATE", "NOSCRIPT", "BR", "TITLE"];
  const items = [];
  const width = document.documentElement.clientWidth;
  const height = document.documentElement.clientHeight;
  const isFocusable = (el, style) => {
    if (el.disabled || el.closest("[inert]") || style.visibility !== "visible") return false;
    const tabindex = el.getAttribute("tabindex");
    if (tabindex !== null && Number(tabindex) < 0) return false;
    if (tabindex !== null && Number(tabindex) >= 0) return true;
    const tag = el.tagName;
    if (tag === "A" || tag === "AREA") return el.hasAttribute("href");
    if (tag === "INPUT") return el.type !== "hidden";
    if (["BUTTON", "SELECT", "TEXTAREA", "IFRAME", "SUMMARY"].includes(tag)) return true;
    if (tag === "AUDIO" || tag === "VIDEO") return el.hasAttribute("controls");
    return el.isContentEditable && (!el.parentElement || !el.parentElement.isContentEditable);
  };
  const ownText = (el) => {
    let text = "";
    for (const child of el.childNodes) if (child.nodeType === Node.TEXT_NODE) text += child.textContent;
    if (el.tagName === "INPUT" && ["button", "submit", "reset"].includes(el.type)) text += el.value;
    return text.replace(/\s+/g, " ").trim();
  };
  const walk = (root) => {
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT);
    for (let el = walker.nextNode(); el; el = walker.nextNode()) {
      if (SKIP.includes(el.tagName)) continue;
      const style = getComputedStyle(el);
      const box = el.getBoundingClientRect();
      const shown = box.width > 0 && box.height > 0 && style.visibility === "visible"
        && (typeof el.checkVisibility !== "function" || el.checkVisibility({ opacityProperty: true, visibilityProperty: true }));
      if (shown) {
        el.setAttribute("data-ddd-i", String(items.length));
        items.push({
          i: items.length, tag: el.tagName.toLowerCase(), testid: el.getAttribute("data-testid") || "",
          text: ownText(el), focusable: isFocusable(el, style),
          parent: el.parentElement && el.parentElement.hasAttribute("data-ddd-i") ? Number(el.parentElement.getAttribute("data-ddd-i")) : -1,
          parentTestid: el.parentElement ? el.parentElement.getAttribute("data-testid") || "" : "",
        });
      }
      if (el.shadowRoot) walk(el.shadowRoot);
    }
  };
  for (const el of document.querySelectorAll("[data-ddd-i]")) el.removeAttribute("data-ddd-i");
  walk(document.body || document.documentElement);
  let active = document.activeElement;
  while (active && active.shadowRoot && active.shadowRoot.activeElement) active = active.shadowRoot.activeElement;
  const activeIndex = active && active.hasAttribute && active.hasAttribute("data-ddd-i") ? Number(active.getAttribute("data-ddd-i")) : -1;
  return { items, activeIndex, width, height };
}

// The details and the lint of the mapped elements. Runs in the page; `mapped` is [{i, n}].
function inspect(args) {
  const { mapped, minLabelChars, maxButtonHeightRatio } = args;
  const SAMPLE = "The quick brown fox jumps over the lazy dog";
  const byIndex = new Map();
  for (const el of document.querySelectorAll("[data-ddd-i]")) byIndex.set(Number(el.getAttribute("data-ddd-i")), el);
  const width = document.documentElement.clientWidth;
  const height = document.documentElement.clientHeight;
  const canvas = document.createElement("canvas").getContext("2d");
  const measure = (style, text) => {
    canvas.font = `${style.fontStyle} ${style.fontWeight} ${style.fontSize} ${style.fontFamily}`;
    let widest = 0;
    for (const line of text.split("\n")) widest = Math.max(widest, canvas.measureText(line).width);
    return widest;
  };
  const px = (value) => parseFloat(value) || 0;
  const round = (r) => {
    const x = Math.round(r.left);
    const y = Math.round(r.top);
    return [x, y, Math.round(r.right) - x, Math.round(r.bottom) - y];
  };
  const show = (r) => `(${Math.round(r.left)}, ${Math.round(r.top)}, ${Math.round(r.width)}, ${Math.round(r.height)})`;
  const cssEscape = (value) => value.replace(/["\\]/g, "\\$&");
  const selector = (el) => {
    const parts = [];
    for (let node = el; node && node.nodeType === Node.ELEMENT_NODE; node = node.parentElement) {
      const testid = node.getAttribute("data-testid");
      if (testid) { parts.unshift(`[data-testid="${cssEscape(testid)}"]`); break; }
      if (node.id && /^[A-Za-z][\w-]*$/.test(node.id)) { parts.unshift(`#${node.id}`); break; }
      const tag = node.tagName.toLowerCase();
      if (tag === "body" || tag === "html") { parts.unshift(tag); break; }
      let position = 1;
      let same = 0;
      for (const sibling of node.parentElement ? node.parentElement.children : []) {
        if (sibling.tagName === node.tagName) { same++; if (sibling === node) position = same; }
      }
      parts.unshift(same > 1 ? `${tag}:nth-of-type(${position})` : tag);
    }
    return parts.join(" > ");
  };
  const ownText = (el) => {
    let text = "";
    for (const child of el.childNodes) if (child.nodeType === Node.TEXT_NODE) text += child.textContent;
    return text.replace(/[ \t\r\n]+/g, " ").trim();
  };
  const wraps = (style) => !["nowrap", "pre"].includes(style.whiteSpace) && style.textWrap !== "nowrap" && style.textWrapMode !== "nowrap";
  const isButton = (el) => el.tagName === "BUTTON" || el.tagName === "A" || el.getAttribute("role") === "button"
    || (el.tagName === "INPUT" && ["button", "submit", "reset"].includes(el.type));
  const scrolls = (style) => ["auto", "scroll"].includes(style.overflowX) || ["auto", "scroll"].includes(style.overflowY);
  const clips = (style) => ["hidden", "clip"].includes(style.overflowX) || ["hidden", "clip"].includes(style.overflowY);
  const pixelRules = (el) => {
    const found = [];
    for (const side of ["left", "top"]) if (/px$/.test(el.style[side]) && px(el.style[side]) !== 0) found.push(side);
    for (const sheet of document.styleSheets) {
      let rules;
      try { rules = sheet.cssRules; } catch { continue; }
      for (const rule of rules || []) {
        if (!rule.selectorText || !rule.style) continue;
        let matches;
        try { matches = el.matches(rule.selectorText); } catch { matches = false; }
        if (!matches) continue;
        for (const side of ["left", "top"]) if (/px$/.test(rule.style[side]) && px(rule.style[side]) !== 0 && !found.includes(side)) found.push(side);
      }
    }
    return found;
  };

  const rows = [];
  const elements = mapped.map((item) => byIndex.get(item.i));
  // An open modal dialog: what is outside it can't be reached, by design.
  const modals = [...document.querySelectorAll("dialog, [aria-modal=true]")]
    .filter((dialog) => (dialog.tagName !== "DIALOG" || dialog.matches(":modal")) && dialog.getBoundingClientRect().width > 0);
  const numberOf = new Map();
  mapped.forEach((item, index) => numberOf.set(elements[index], item.n));
  for (let index = 0; index < mapped.length; index++) {
    const el = elements[index];
    const style = getComputedStyle(el);
    const box = el.getBoundingClientRect();
    const findings = {};
    const text = ownText(el);
    const textWraps = wraps(style);
    const contentWidth = el.clientWidth - px(style.paddingLeft) - px(style.paddingRight);
    const clipped = (el.scrollWidth > el.clientWidth + 1 || el.scrollHeight > el.clientHeight + 1) && clips(style) && style.textOverflow !== "ellipsis";
    // squeezed-text
    if (text !== "" && style.display !== "inline" && el.clientWidth > 0) {
      const needed = measure(style, text);
      if (textWraps) {
        const average = measure(style, SAMPLE) / SAMPLE.length;
        const wanted = Math.min(needed, average * minLabelChars);
        if (contentWidth + 1 < wanted) {
          findings["squeezed-text"] = `wrapping text is ${Math.round(contentWidth)} px wide, under ${minLabelChars} average characters (${Math.round(wanted)} px)`;
        }
      } else if (needed > contentWidth + 1 && style.textOverflow !== "ellipsis") {
        findings["squeezed-text"] = `the text needs ${Math.round(needed)} px but the box is ${Math.round(contentWidth)} px, and it isn't shortened with an ellipsis`;
      }
    }
    // stretched-control
    if (isButton(el) && style.display !== "inline") {
      const range = document.createRange();
      range.selectNodeContents(el);
      let content = range.getBoundingClientRect().height;
      if (!(content > 0)) content = px(style.lineHeight) || px(style.fontSize) * 1.2;
      const natural = content + px(style.paddingTop) + px(style.paddingBottom) + px(style.borderTopWidth) + px(style.borderBottomWidth);
      if (natural > 0 && box.height > natural * maxButtonHeightRatio) {
        findings["stretched-control"] = `the button is ${Math.round(box.height)} px tall, ${(box.height / natural).toFixed(1)} times its content height (${Math.round(natural)} px); something beside it grew`;
      }
    }
    // off-screen: the nearest scrolling or clipping parent decides. Content a parent scrolls (a
    // carousel, a wide table) is fine; out of a clipping parent, or of the viewport sideways, isn't.
    let container = null;
    for (let parent = el.parentElement; parent && parent !== document.body && container === null; parent = parent.parentElement) {
      const parentStyle = getComputedStyle(parent);
      if (scrolls(parentStyle) || clips(parentStyle)) container = { parent, scrolled: scrolls(parentStyle) };
    }
    if (container === null) {
      if (box.left < -1 || box.right > width + 1) findings["off-screen"] = `its rect ${show(box)} leaves the screen (${width} x ${height})`;
    } else if (!container.scrolled) {
      const outer = container.parent.getBoundingClientRect();
      if (box.left < outer.left - 1 || box.top < outer.top - 1 || box.right > outer.right + 1 || box.bottom > outer.bottom + 1) {
        findings["off-screen"] = `its rect ${show(box)} leaves its clipping parent ${selector(container.parent)} ${show(outer)}`;
      }
    }
    // hard-coded-position: absolute or fixed with pixel left or top inside a flex or grid container.
    if (["absolute", "fixed"].includes(style.position) && el.parentElement) {
      const display = getComputedStyle(el.parentElement).display;
      if (/flex|grid/.test(display)) {
        const sides = pixelRules(el);
        if (sides.length > 0) {
          findings["hard-coded-position"] = `it is placed with position: ${style.position} and ${sides.join(" and ")} in pixels, but its parent ${selector(el.parentElement)} lays it out with ${display} (warning)`;
        }
      }
    }
    const aria = {};
    for (const attribute of el.attributes) if (attribute.name.startsWith("aria-")) aria[attribute.name.substring(5)] = attribute.value;
    rows.push({
      rect: round(box), path: selector(el), findings, clipped, wraps: textWraps,
      min: [el.scrollWidth, el.scrollHeight], tabindex: el.tabIndex, disabled: Boolean(el.disabled) || el.getAttribute("aria-disabled") === "true", aria,
      outsideModal: modals.length > 0 && !modals.some((dialog) => dialog.contains(el)),
    });
  }
  // overlap: focusable siblings, where the one on top takes the clicks.
  for (let lower = 0; lower < mapped.length; lower++) {
    if (!mapped[lower].focusable) continue;
    for (let upper = lower + 1; upper < mapped.length; upper++) {
      if (!mapped[upper].focusable || elements[upper].parentElement !== elements[lower].parentElement) continue;
      const a = elements[lower].getBoundingClientRect();
      const b = elements[upper].getBoundingClientRect();
      const w = Math.min(a.right, b.right) - Math.max(a.left, b.left);
      const h = Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top);
      if (w <= 1 || h <= 1) continue;
      const hit = document.elementFromPoint(Math.max(a.left, b.left) + w / 2, Math.max(a.top, b.top) + h / 2);
      if (!hit) continue;
      let blocked = -1;
      let above = -1;
      if (elements[upper].contains(hit)) { blocked = lower; above = upper; } else if (elements[lower].contains(hit)) { blocked = upper; above = lower; }
      if (blocked >= 0 && !rows[blocked].findings.overlap) {
        rows[blocked].findings.overlap = `element ${mapped[above].n} (${mapped[above].label}) covers ${Math.round(w)} x ${Math.round(h)} px of it and takes its clicks`;
      }
    }
  }
  // no-default-focus: an open dialog with focusable content and the focus outside it.
  let active = document.activeElement;
  while (active && active.shadowRoot && active.shadowRoot.activeElement) active = active.shadowRoot.activeElement;
  for (const dialog of document.querySelectorAll("dialog[open], [role=dialog][aria-modal=true], [role=alertdialog], [aria-modal=true]")) {
    if (dialog.getBoundingClientRect().width <= 0 || (active && dialog.contains(active))) continue;
    const first = mapped.findIndex((item, index) => item.focusable && !rows[index].disabled && dialog.contains(elements[index]));
    if (first >= 0) rows[first].findings["no-default-focus"] = "nothing in the dialog has focus when it opens; give this or another element focus";
  }
  return rows;
}

// The data-ddd-i of the focused element, or -1. Runs in the page.
function focused() {
  let active = document.activeElement;
  while (active && active.shadowRoot && active.shadowRoot.activeElement) active = active.shadowRoot.activeElement;
  return active && active.hasAttribute && active.hasAttribute("data-ddd-i") ? Number(active.getAttribute("data-ddd-i")) : -1;
}

function unmark() {
  for (const el of document.querySelectorAll("[data-ddd-i]")) el.removeAttribute("data-ddd-i");
}

// --- in Node ------------------------------------------------------------------------------------

// backendDOMNodeId -> data-ddd-i, from the DOM tree the protocol reports.
function marks(root) {
  const result = new Map();
  const stack = [root];
  while (stack.length > 0) {
    const node = stack.pop();
    if (Array.isArray(node.attributes)) {
      for (let at = 0; at + 1 < node.attributes.length; at += 2) {
        if (node.attributes[at] === MARK) result.set(node.backendNodeId, Number(node.attributes[at + 1]));
      }
    }
    for (const key of ["children", "shadowRoots"]) if (Array.isArray(node[key])) stack.push(...node[key]);
    if (node.contentDocument) stack.push(node.contentDocument);
  }
  return result;
}

function short(text) {
  const flat = text.replace(/\n/g, " ").trim();
  return flat.length > NAME_LENGTH ? flat.substring(0, NAME_LENGTH - 3) + "..." : flat;
}

function percent(value, total) {
  return Math.round((1000 * value) / total) / 10;
}

// Maps and lints the page. specNames: the data-testid values the screen's spec names (their direct
// children are mapped too). Returns {elements, findings, capped}.
export async function mapScreen(page, options) {
  const { size, maxElements, minLabelChars, maxButtonHeightRatio, specNames } = options;
  const seen = await page.evaluate(collect);
  const cdp = await page.context().newCDPSession(page);
  const roles = new Map();
  try {
    const { root } = await cdp.send("DOM.getDocument", { depth: -1, pierce: true });
    const byBackend = marks(root);
    const { nodes } = await cdp.send("Accessibility.getFullAXTree");
    for (const node of nodes) {
      if (node.ignored || node.backendDOMNodeId === undefined || !byBackend.has(node.backendDOMNodeId)) continue;
      const index = byBackend.get(node.backendDOMNodeId);
      if (roles.has(index)) continue;
      roles.set(index, { role: node.role && node.role.value ? String(node.role.value) : "", name: node.name && node.name.value ? String(node.name.value) : "" });
    }
  } finally {
    await cdp.detach().catch(() => undefined);
  }

  // Which elements are mapped: focusable, with text, with a meaningful role and a name, with a
  // data-testid, or a direct child of a container the spec names.
  const containers = new Set(specNames);
  const mapped = [];
  let capped = false;
  for (const item of seen.items) {
    const ax = roles.get(item.i) || { role: "", name: "" };
    const meaningful = !PLAIN_ROLES.includes(ax.role) && ax.name.trim() !== "";
    if (!(item.focusable || item.text !== "" || meaningful || item.testid !== "" || containers.has(item.parentTestid) && item.parentTestid !== "")) continue;
    if (mapped.length >= maxElements) { capped = true; break; }
    const kind = ax.role && !["none", "presentation"].includes(ax.role) ? ax.role : "generic";
    const label = short(ax.name.trim() !== "" ? ax.name : item.text);
    mapped.push({ i: item.i, n: mapped.length + 1, focusable: item.focusable, testid: item.testid, kind, label });
  }
  const details = await page.evaluate(inspect, { mapped, minLabelChars, maxButtonHeightRatio });

  // Focus order: the default focus, then Tab until a repeat (a trap, or the end of the round).
  const position = new Map();
  const visits = [];
  if (seen.activeIndex >= 0) visits.push(seen.activeIndex);
  const focusables = mapped.filter((item) => item.focusable).length;
  for (let press = 0; press < focusables + 10 && focusables > 0; press++) {
    await page.keyboard.press("Tab");
    const index = await page.evaluate(focused);
    if (index < 0) continue;
    if (visits.includes(index)) break;
    visits.push(index);
  }
  visits.forEach((index, at) => position.set(index, at + 1));
  await page.evaluate(unmark).catch(() => undefined);

  const elements = [];
  const findings = [];
  mapped.forEach((item, index) => {
    const detail = details[index];
    const order = position.has(item.i) ? position.get(item.i) : null;
    if (item.focusable && !detail.disabled && !detail.outsideModal && order === null) detail.findings.unreachable = "Tab never reaches it from the default focus";
    const native = { tag: seen.items[item.i].tag, tabindex: detail.tabindex, aria: detail.aria, disabled: detail.disabled, selector: detail.path };
    const [x, y, w, h] = detail.rect;
    elements.push({
      n: item.n,
      id: item.testid !== "" ? item.testid : (item.label !== "" ? `${item.kind} "${item.label}"` : detail.path),
      stable: item.testid !== "",
      path: detail.path,
      kind: item.kind,
      name: item.label,
      rect: detail.rect,
      rect_pct: [percent(x, size.x), percent(y, size.y), percent(w, size.x), percent(h, size.y)],
      visible: true,
      focusable: item.focusable,
      focus_order: order,
      overflow: { clipped: detail.clipped, wraps: detail.wraps },
      min_size: detail.min,
      native,
    });
    for (const rule of RULES) {
      if (detail.findings[rule]) findings.push(`${rule} element ${item.n} ${detail.path}: ${detail.findings[rule]}`);
    }
  });
  return { elements, findings, capped };
}
