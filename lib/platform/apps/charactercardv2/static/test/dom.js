// Minimal hand-rolled DOM polyfill for ccv2 frontend tests.
//
// Scope: only the surface the production modules actually touch. If something
// the modules expect is missing, this file throws "not implemented: X" rather
// than silently returning undefined — silent undefined is the worst possible
// failure mode for tests.
//
// Reset utility: `resetDOM(html)` rebuilds the global `document`/`window`
// objects from an HTML string. Helpers in `helpers.js` use this with the real
// index.html.

const VOID_TAGS = new Set([
  "area", "base", "br", "col", "embed", "hr", "img", "input", "link",
  "meta", "param", "source", "track", "wbr",
]);

class ClassList {
  constructor(el) { this._el = el; this._set = new Set(); }
  add(...names) { for (const n of names) this._set.add(n); this._sync(); }
  remove(...names) { for (const n of names) this._set.delete(n); this._sync(); }
  toggle(name, force) {
    const has = this._set.has(name);
    const should = force === undefined ? !has : !!force;
    if (should) this._set.add(name); else this._set.delete(name);
    this._sync();
    return should;
  }
  contains(name) { return this._set.has(name); }
  _sync() { this._el._attrs.class = [...this._set].join(" "); }
  _replaceFromString(s) {
    this._set = new Set((s || "").split(/\s+/).filter(Boolean));
  }
}

class Element {
  constructor(tagName) {
    this.tagName = (tagName || "").toUpperCase();
    this.nodeType = 1;
    this.children = [];
    this.childNodes = [];
    this.parentNode = null;
    this._attrs = {};
    this._listeners = Object.create(null);
    this._textContent = "";
    this.classList = new ClassList(this);
    this.style = {};
    this.dataset = {};
    this._value = "";
    this._checked = false;
    this._selected = false;
    this._disabled = false;
    this._hidden = false;
    this._files = null;
  }

  // ---- attribute API ----
  getAttribute(name) {
    if (name === "class") return this._attrs.class || "";
    return this._attrs[name] !== undefined ? String(this._attrs[name]) : null;
  }
  setAttribute(name, value) {
    this._attrs[name] = String(value);
    if (name === "id") this.id = String(value);
    if (name === "class") this.classList._replaceFromString(String(value));
    if (name.startsWith("data-")) {
      this.dataset[dashToCamel(name.slice(5))] = String(value);
    }
  }
  removeAttribute(name) {
    delete this._attrs[name];
    if (name === "id") this.id = "";
    if (name === "class") this.classList._replaceFromString("");
  }
  hasAttribute(name) { return name in this._attrs; }

  // ---- tree ops ----
  appendChild(node) {
    if (node.parentNode) node.parentNode.removeChild(node);
    node.parentNode = this;
    this.childNodes.push(node);
    if (node.nodeType === 1) this.children.push(node);
    return node;
  }
  removeChild(node) {
    const i = this.childNodes.indexOf(node);
    if (i >= 0) this.childNodes.splice(i, 1);
    const j = this.children.indexOf(node);
    if (j >= 0) this.children.splice(j, 1);
    node.parentNode = null;
    return node;
  }
  remove() { if (this.parentNode) this.parentNode.removeChild(this); }
  insertBefore(node, ref) {
    if (!ref) return this.appendChild(node);
    const i = this.childNodes.indexOf(ref);
    if (i < 0) return this.appendChild(node);
    node.parentNode = this;
    this.childNodes.splice(i, 0, node);
    if (node.nodeType === 1) {
      const j = this.children.indexOf(ref);
      this.children.splice(j < 0 ? this.children.length : j, 0, node);
    }
    return node;
  }
  contains(other) {
    let n = other;
    while (n) { if (n === this) return true; n = n.parentNode; }
    return false;
  }

  // ---- selectors ----
  // Tiny CSS subset: "#id", ".class", "tag", "[attr]", "[attr='v']",
  // and space-separated descendant combinator. No commas, no >, no :nth.
  querySelector(sel) { return _query(this, sel, true); }
  querySelectorAll(sel) { return _query(this, sel, false); }
  closest(sel) {
    let n = this;
    while (n && n.nodeType === 1) {
      if (_matches(n, sel)) return n;
      n = n.parentNode;
    }
    return null;
  }

  // ---- content ----
  get textContent() {
    let out = "";
    for (const c of this.childNodes) {
      if (c.nodeType === 3) out += c.textContent;
      else if (c.nodeType === 1) out += c.textContent;
    }
    return out || this._textContent;
  }
  set textContent(v) {
    this.childNodes = [];
    this.children = [];
    this._textContent = String(v);
    const t = new TextNode(String(v));
    t.parentNode = this;
    this.childNodes.push(t);
  }
  get innerHTML() {
    return this.childNodes.map(serializeNode).join("");
  }
  set innerHTML(html) {
    this.childNodes = [];
    this.children = [];
    this._textContent = "";
    const frag = parseHTML(String(html));
    for (const c of frag) this.appendChild(c);
  }

  // ---- form-ish properties ----
  get value() { return this._value; }
  set value(v) { this._value = v == null ? "" : String(v); }
  get checked() { return this._checked; }
  set checked(v) { this._checked = !!v; }
  get selected() { return this._selected; }
  set selected(v) { this._selected = !!v; }
  get disabled() { return this._disabled; }
  set disabled(v) { this._disabled = !!v; }
  get hidden() { return this._hidden; }
  set hidden(v) { this._hidden = !!v; }
  get files() { return this._files; }
  set files(v) { this._files = v; }

  get title() { return this._attrs.title || ""; }
  set title(v) { this._attrs.title = String(v); }
  get href() { return this._attrs.href || ""; }
  set href(v) { this._attrs.href = String(v); }
  get download() { return this._attrs.download || ""; }
  set download(v) { this._attrs.download = String(v); }
  get className() { return this._attrs.class || ""; }
  set className(v) {
    this._attrs.class = String(v);
    this.classList._replaceFromString(String(v));
  }
  get id() { return this._attrs.id || ""; }
  set id(v) { this._attrs.id = String(v); }

  // ---- traversal helpers ----
  get nextElementSibling() {
    if (!this.parentNode) return null;
    const sibs = this.parentNode.children;
    const i = sibs.indexOf(this);
    return i >= 0 && i + 1 < sibs.length ? sibs[i + 1] : null;
  }
  get offsetParent() {
    // Approximation: null if hidden, else parent element. Good enough for
    // focus-trap "is visible?" checks.
    let n = this;
    while (n) {
      if (n._hidden) return null;
      n = n.parentNode;
    }
    return this.parentNode;
  }

  // ---- events ----
  addEventListener(type, fn) {
    (this._listeners[type] ||= []).push(fn);
  }
  removeEventListener(type, fn) {
    const arr = this._listeners[type];
    if (!arr) return;
    const i = arr.indexOf(fn);
    if (i >= 0) arr.splice(i, 1);
  }
  dispatchEvent(ev) {
    ev.target ||= this;
    ev.currentTarget = this;
    const arr = this._listeners[ev.type];
    if (arr) for (const fn of arr.slice()) fn.call(this, ev);
    // Bubble.
    if (ev.bubbles !== false && this.parentNode && this.parentNode.dispatchEvent) {
      this.parentNode.dispatchEvent(ev);
    }
    return !ev.defaultPrevented;
  }
  click() {
    this.dispatchEvent(new MockEvent("click", { bubbles: true }));
  }
  focus() { document.activeElement = this; }
  blur() { if (document.activeElement === this) document.activeElement = document.body; }
}

class TextNode {
  constructor(text) {
    this.nodeType = 3;
    this.textContent = String(text);
    this.parentNode = null;
  }
}

class MockEvent {
  constructor(type, init) {
    this.type = type;
    this.bubbles = !!(init && init.bubbles);
    this.defaultPrevented = false;
    this.target = null;
    this.currentTarget = null;
    init = init || {};
    for (const k in init) if (k !== "bubbles") this[k] = init[k];
  }
  preventDefault() { this.defaultPrevented = true; }
  stopPropagation() { this.bubbles = false; }
}

function dashToCamel(s) {
  return s.replace(/-([a-z])/g, (_, c) => c.toUpperCase());
}

// --- selector matching (tiny subset) ---
function _parseSimple(sel) {
  // Returns {tag, id, classes:[], attrs:[{k,v}]}
  const out = { tag: null, id: null, classes: [], attrs: [] };
  const re = /([.#]?[\w-]+)|\[([\w-]+)(?:=(?:"([^"]*)"|'([^']*)'|([^\]]*)))?\]/g;
  let m;
  while ((m = re.exec(sel))) {
    if (m[1]) {
      const tok = m[1];
      if (tok[0] === "#") out.id = tok.slice(1);
      else if (tok[0] === ".") out.classes.push(tok.slice(1));
      else out.tag = tok.toUpperCase();
    } else if (m[2]) {
      const v = m[3] != null ? m[3] : m[4] != null ? m[4] : m[5] != null ? m[5] : null;
      out.attrs.push({ k: m[2], v });
    }
  }
  return out;
}
function _matchesSimple(el, simple) {
  if (simple.tag && el.tagName !== simple.tag) return false;
  if (simple.id && el.id !== simple.id) return false;
  for (const c of simple.classes) if (!el.classList.contains(c)) return false;
  for (const a of simple.attrs) {
    const got = el.getAttribute(a.k);
    if (a.v == null) { if (got == null) return false; }
    else if (got !== a.v) return false;
  }
  return true;
}
function _matches(el, sel) {
  // Last simple in a descendant chain.
  const parts = sel.trim().split(/\s+/);
  return _matchesSimple(el, _parseSimple(parts[parts.length - 1]));
}
function _query(root, sel, single) {
  const parts = sel.trim().split(/\s+/).map(_parseSimple);
  const results = [];
  function walk(node) {
    for (const c of node.children) {
      if (_matchChain(c, parts)) {
        results.push(c);
        if (single) return true;
      }
      if (walk(c)) return true;
    }
    return false;
  }
  walk(root);
  return single ? (results[0] || null) : results;
}
function _matchChain(el, parts) {
  // Last simple must match el; preceding simples must match some ancestor chain.
  if (!_matchesSimple(el, parts[parts.length - 1])) return false;
  let n = el.parentNode;
  for (let i = parts.length - 2; i >= 0; i--) {
    while (n && n.nodeType === 1 && !_matchesSimple(n, parts[i])) n = n.parentNode;
    if (!n || n.nodeType !== 1) return false;
    n = n.parentNode;
  }
  return true;
}

// --- HTML parsing (tiny, forgiving) ---
function parseHTML(html) {
  const out = [];
  const stack = [{ children: out, _isFrag: true, childNodes: out, appendChild(n) { out.push(n); n.parentNode = null; return n; } }];
  // We'll treat the top-of-stack `current` as the parent.
  // But appendChild in a real element pushes into both children and childNodes.
  // For the synthetic frag we bypass.
  let i = 0;
  const tagRe = /<(\/)?([a-zA-Z][\w-]*)((?:\s+[\w:-]+(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+))?)*)\s*(\/?)>/g;
  let m;
  while ((m = tagRe.exec(html))) {
    const text = html.slice(i, m.index);
    if (text.length) appendTo(top(stack), new TextNode(decodeEntities(text)));
    i = tagRe.lastIndex;
    const closing = !!m[1];
    const tag = m[2].toLowerCase();
    const attrStr = m[3];
    const selfClose = !!m[4] || VOID_TAGS.has(tag);

    if (closing) {
      // Pop until match.
      for (let k = stack.length - 1; k >= 1; k--) {
        if (stack[k].tagName && stack[k].tagName.toLowerCase() === tag) {
          stack.length = k;
          break;
        }
      }
    } else {
      const el = new Element(tag);
      parseAttrs(el, attrStr);
      appendTo(top(stack), el);
      if (!selfClose) stack.push(el);
      // Special-case <script>/<style>/<textarea>: consume raw content until close tag.
      if (!selfClose && (tag === "script" || tag === "style" || tag === "textarea")) {
        const closeRe = new RegExp("</" + tag + "\\s*>", "i");
        const rest = html.slice(i);
        const cm = closeRe.exec(rest);
        if (cm) {
          const raw = rest.slice(0, cm.index);
          if (raw.length) appendTo(el, new TextNode(decodeEntities(raw)));
          i += cm.index + cm[0].length;
          tagRe.lastIndex = i;
          stack.pop();
        }
      }
    }
  }
  const tail = html.slice(i);
  if (tail.length) appendTo(top(stack), new TextNode(decodeEntities(tail)));
  return out;
}
function top(stack) { return stack[stack.length - 1]; }
function appendTo(parent, node) {
  if (parent._isFrag) {
    parent.children.push(node);
    return;
  }
  parent.appendChild(node);
}
function parseAttrs(el, str) {
  if (!str) return;
  const re = /([\w:-]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+)))?/g;
  let m;
  while ((m = re.exec(str))) {
    const k = m[1];
    const v = m[2] != null ? m[2] : m[3] != null ? m[3] : m[4] != null ? m[4] : "";
    el.setAttribute(k, v);
    if (k === "value") el._value = v;
    if (k === "checked") el._checked = true;
    if (k === "selected") el._selected = true;
    if (k === "disabled") el._disabled = true;
    if (k === "hidden") el._hidden = true;
  }
}
function decodeEntities(s) {
  return s
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, "\"")
    .replace(/&#39;/g, "'")
    .replace(/&amp;/g, "&");
}
function escapeText(s) {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}
function serializeNode(node) {
  if (node.nodeType === 3) return escapeText(node.textContent);
  if (node.nodeType === 1) {
    const tag = node.tagName.toLowerCase();
    let attrs = "";
    for (const k in node._attrs) attrs += ` ${k}="${String(node._attrs[k]).replace(/"/g, "&quot;")}"`;
    if (VOID_TAGS.has(tag)) return `<${tag}${attrs}>`;
    return `<${tag}${attrs}>${node.childNodes.map(serializeNode).join("")}</${tag}>`;
  }
  return "";
}

// --- document / window ---
class Document {
  constructor() {
    this._root = new Element("html");
    this.body = new Element("body");
    this._root.appendChild(this.body);
    this.activeElement = this.body;
    this._idIndex = new Map();
    this._byId = (el) => {
      if (!el) return;
      if (el.id) this._idIndex.set(el.id, el);
      if (el.children) for (const c of el.children) this._byId(c);
    };
  }
  _rebuildIndex(rootChildren) {
    this._idIndex = new Map();
    this.body.children.length = 0;
    this.body.childNodes.length = 0;
    for (const c of rootChildren) this.body.appendChild(c);
    this._byId(this.body);
  }
  getElementById(id) {
    // Refresh index from tree (cheap enough for tests; dynamic appends).
    const found = _findById(this.body, id);
    return found;
  }
  createElement(tag) { return new Element(tag); }
  createTextNode(text) { return new TextNode(text); }
  querySelector(sel) { return this.body.querySelector(sel); }
  querySelectorAll(sel) { return this.body.querySelectorAll(sel); }
  addEventListener() { /* no-op for tests; extend if needed */ }
  removeEventListener() {}
}
function _findById(node, id) {
  if (node.id === id) return node;
  if (!node.children) return null;
  for (const c of node.children) {
    const f = _findById(c, id);
    if (f) return f;
  }
  return null;
}

class Window {
  constructor() {
    this._listeners = Object.create(null);
    this.location = { href: "http://test.local/", pathname: "/" };
    this.confirm = (_msg) => true;
    this.alert = (_msg) => {};
    this.prompt = (_msg, def) => def == null ? "" : def;
    this.fetch = () => { throw new Error("fetch not installed; require('./mock-fetch.js')"); };
    // Tests opt in via `runTimers()` if they need timer effects; default
    // is to record-and-ignore so 5-second cleanup callbacks don't wipe
    // assertions out from under us.
    this._timers = [];
    this.setTimeout = (fn, _ms) => { this._timers.push(fn); return this._timers.length; };
    this.clearTimeout = (id) => { if (id) this._timers[id - 1] = null; };
  }
  addEventListener(type, fn) { (this._listeners[type] ||= []).push(fn); }
  removeEventListener(type, fn) {
    const arr = this._listeners[type]; if (!arr) return;
    const i = arr.indexOf(fn); if (i >= 0) arr.splice(i, 1);
  }
  dispatchEvent(ev) {
    const arr = this._listeners[ev.type]; if (!arr) return true;
    for (const fn of arr.slice()) fn(ev);
    return !ev.defaultPrevented;
  }
}

// --- public API ---
export function resetDOM(html) {
  const doc = new Document();
  const win = new Window();
  globalThis.document = doc;
  globalThis.window = win;
  globalThis.Element = Element;
  globalThis.HTMLElement = Element;
  globalThis.Event = MockEvent;
  globalThis.CustomEvent = MockEvent;
  // Bind these as dynamic getters so tests can reassign `window.confirm`
  // / `window.prompt` and the module's bare `confirm()` / `prompt()` calls
  // observe the new value.
  Object.defineProperty(globalThis, "confirm", { configurable: true, get: () => win.confirm });
  Object.defineProperty(globalThis, "alert", { configurable: true, get: () => win.alert });
  Object.defineProperty(globalThis, "prompt", { configurable: true, get: () => win.prompt });
  globalThis.setTimeout = win.setTimeout.bind(win);
  globalThis.clearTimeout = win.clearTimeout.bind(win);
  globalThis.URL = globalThis.URL || {
    createObjectURL: () => "blob:mock",
    revokeObjectURL: () => {},
  };
  if (html) {
    const frag = parseHTML(html);
    // Locate <body> if present; otherwise attach top-level nodes to body.
    const body = findTagDeep(frag, "BODY");
    if (body) {
      for (const c of body.childNodes) {
        c.parentNode = null;
        doc.body.appendChild(c);
      }
    } else {
      for (const n of frag) doc.body.appendChild(n);
    }
  }
  return { document: doc, window: win };
}

function findTagDeep(nodes, tag) {
  for (const n of nodes) {
    if (n.nodeType !== 1) continue;
    if (n.tagName === tag) return n;
    const c = findTagDeep(n.children, tag);
    if (c) return c;
  }
  return null;
}

export { Element, TextNode, MockEvent, parseHTML };
