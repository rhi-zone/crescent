// app.js — system_dashboard frontend entrypoint.
//
// Top-level page wiring (search palette, results list, modal, output panel,
// SSE consumer). Body rendering is delegated to the projection registry —
// every primitive shape goes through `project(value, ctx)`.
//
// Import order matters:
//   1. harden.js    — freezes built-in prototypes (defense-in-depth).
//   2. registry.js  — provides `project`.
//   3. index.js     — side-effect: registers all 33 projections.
//   4. dom.js       — sealed DOM constructors (used here only indirectly via
//                     projections; imported for symmetry / future use).

import "./harden.js";
import { project } from "./projections/registry.js";
import "./projections/index.js";
import { dom } from "./dom.js";

void dom; // imported for symmetry with the projection contract.

const searchEl = document.getElementById("search");
const resultsEl = document.getElementById("results");
const packInfoEl = document.getElementById("pack-info");
const outputPanelEl = document.getElementById("output-panel");
const outputLabelEl = document.getElementById("output-label");
const outputBodyEl = document.getElementById("output-body");
const outputCiteEl = document.getElementById("output-cite");
const modalEl = document.getElementById("confirm-modal");
const modalTitleEl = document.getElementById("modal-title");
const modalCommandEl = document.getElementById("modal-command");
const modalCapsEl = document.getElementById("modal-caps");
const modalCapsListEl = document.getElementById("modal-caps-list");
const modalCancelEl = document.getElementById("modal-cancel");
const modalExecuteEl = document.getElementById("modal-execute");

let debounceTimer = null;
let selectedIndex = -1;
let currentResults = [];

// --- Fetch helpers ---

async function fetchCapInfo(aliasId, actionIndex) {
  const url = "/api/cap_info?alias=" + encodeURIComponent(aliasId) + "&action=" + actionIndex;
  const res = await fetch(url);
  if (!res.ok) throw new Error("HTTP " + res.status);
  return res.json();
}

async function fetchResults(query) {
  const url = "/api/search?q=" + encodeURIComponent(query);
  const res = await fetch(url);
  if (!res.ok) throw new Error("HTTP " + res.status);
  return res.json();
}

async function fetchPacks() {
  const res = await fetch("/api/packs");
  if (!res.ok) throw new Error("HTTP " + res.status);
  return res.json();
}

async function postExecute(aliasId, actionIndex) {
  const res = await fetch("/api/execute", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ alias_id: aliasId, action_index: actionIndex }),
  });
  return res.json();
}

// Action dispatch used by `ctx.action`. Reused by button/confirm/action_menu/
// panel.actions projections via the closure returned by `makeActionHandle`.
// On any failure, an err envelope is synthesized so the caller renders
// uniformly.
function executeAlias(aliasId, args, onEnvelope) {
  fetch("/api/execute", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ alias_id: aliasId, action_index: 0, args: args || null }),
  }).then((res) => res.json())
    .then((env) => onEnvelope && onEnvelope(env))
    .catch((err) => {
      onEnvelope && onEnvelope({
        ok: false,
        error: "request failed: " + (err && err.message ? err.message : "network error"),
      });
    });
}

// Build a click handler suitable for `ctx.action`. Projections invoke
// `ctx.action(alias_id, args, onResult)` and bind the result to a button's
// onClick. The handler swallows the event, fires the alias, and forwards
// the result envelope to the projection's `onResult` callback.
function makeActionHandle(alias_id, args, onResult) {
  return function clickHandler(ev) {
    if (ev && typeof ev.preventDefault === "function") ev.preventDefault();
    executeAlias(alias_id, args, (env) => {
      if (typeof onResult === "function") onResult(env);
    });
  };
}

// --- SSE streaming consumer ---
//
// postExecuteWithStream(aliasId, actionIndex, lastEventId?) -> Promise that
// resolves with one of:
//   { kind: "json",   env: <envelope> }
//   { kind: "stream", reader, abort }
async function postExecuteWithStream(aliasId, actionIndex, lastEventId) {
  const ac = new AbortController();
  const headers = { "Content-Type": "application/json" };
  if (lastEventId != null) headers["Last-Event-ID"] = String(lastEventId);
  const res = await fetch("/api/execute", {
    method: "POST",
    headers,
    body: JSON.stringify({ alias_id: aliasId, action_index: actionIndex }),
    signal: ac.signal,
  });
  const ct = (res.headers.get("Content-Type") || "").toLowerCase();
  if (ct.indexOf("text/event-stream") === 0) {
    return { kind: "stream", reader: res.body.getReader(), abort: () => ac.abort() };
  }
  const env = await res.json();
  return { kind: "json", env };
}

function parseSseFrames(buf, handlers) {
  let idx;
  while ((idx = buf.indexOf("\n\n")) >= 0) {
    const raw = buf.slice(0, idx);
    buf = buf.slice(idx + 2);
    let ev = "message", id = null, data = "";
    const lines = raw.split("\n");
    for (let li = 0; li < lines.length; li++) {
      const line = lines[li];
      if (line.indexOf("event:") === 0)      ev   = line.slice(6).trim();
      else if (line.indexOf("id:") === 0)    id   = line.slice(3).trim();
      else if (line.indexOf("data:") === 0)  data = line.slice(5).trim();
    }
    handlers.onFrame(ev, id, data);
  }
  return buf;
}

async function consumeStream(reader, handlers) {
  const dec = new TextDecoder("utf-8");
  let buf = "";
  while (true) {
    const step = await reader.read();
    if (step.done) {
      if (buf.length > 0) buf = parseSseFrames(buf + "\n\n", handlers);
      handlers.onDone();
      return;
    }
    buf += dec.decode(step.value, { stream: true });
    buf = parseSseFrames(buf, handlers);
  }
}

// --- Output panel ---

// Build a projection ctx. `project` recurses through the registry; `action`
// returns a click handler bound to /api/execute via `makeActionHandle`.
function makeCtx() {
  const ctx = {
    project: null,    // bound below (self-reference)
    action:  makeActionHandle,
  };
  ctx.project = (v) => project(v, ctx);
  return ctx;
}

function renderCite(citeArr) {
  outputCiteEl.textContent = "";
  if (!citeArr || !citeArr.length) return;
  const ul = document.createElement("ul");
  ul.className = "cite-list";
  for (let i = 0; i < citeArr.length; i++) {
    const entry = citeArr[i];
    const li = document.createElement("li");
    const kindSpan = document.createElement("span");
    kindSpan.className = "cite-kind";
    kindSpan.textContent = entry.kind || "?";
    li.appendChild(kindSpan);
    let detail = "";
    if (entry.path) detail = entry.path;
    else if (entry.url) detail = (entry.method ? entry.method + " " : "") + entry.url;
    else if (entry.href) detail = entry.href;
    else if (entry.argv) detail = (entry.argv || []).join(" ");
    else if (entry.query) detail = entry.query;
    else if (entry.name) detail = entry.name;
    else if (entry.text) detail = entry.text;
    if (detail) {
      const detailSpan = document.createElement("span");
      detailSpan.className = "cite-detail";
      detailSpan.textContent = " " + detail;
      li.appendChild(detailSpan);
    }
    ul.appendChild(li);
  }
  outputCiteEl.appendChild(ul);
}

// Mount an envelope into the output panel. Returns the stream consumer iff
// the projection produced one; otherwise null.
function renderEnvelope(label, env) {
  outputLabelEl.textContent = label;
  const isError = !env || env.ok === false;
  outputLabelEl.className = "output-label" + (isError ? " output-error" : "");
  outputBodyEl.textContent = "";
  let consumer = null;
  if (env && env.body !== undefined && env.body !== null) {
    const ctx = makeCtx();
    const result = project(env.body, ctx);
    if (result && result.__stream === true) {
      outputBodyEl.appendChild(result.el);
      consumer = result;
    } else if (result instanceof Element) {
      outputBodyEl.appendChild(result);
    } else if (result != null) {
      // Defensive: a projection returned something non-DOM. Render as text.
      const div = document.createElement("div");
      div.className = "prim-text style-muted";
      div.textContent = String(result);
      outputBodyEl.appendChild(div);
    }
  } else if (env && env.error) {
    const errEl = document.createElement("div");
    errEl.className = "prim-text style-error";
    const errPre = document.createElement("pre");
    errPre.textContent = String(env.error);
    errEl.appendChild(errPre);
    outputBodyEl.appendChild(errEl);
  } else {
    const emptyEl = document.createElement("div");
    emptyEl.className = "prim-text style-muted";
    emptyEl.textContent = "(no output)";
    outputBodyEl.appendChild(emptyEl);
  }
  renderCite(env && env.cite);
  outputPanelEl.style.display = "block";
  outputPanelEl.scrollIntoView({ block: "nearest" });
  return consumer;
}

function hideOutput() {
  outputPanelEl.style.display = "none";
  outputBodyEl.textContent = "";
  outputCiteEl.textContent = "";
}

// --- Results list ---

function renderResults(results) {
  currentResults = results;
  selectedIndex = -1;
  hideOutput();

  if (results.length === 0) {
    resultsEl.innerHTML = '<div class="result-error">No results found.</div>';
    return;
  }

  let html = "";
  for (let i = 0; i < results.length; i++) {
    const r = results[i];
    html += '<div class="result" data-index="' + i + '" data-id="' + escapeAttr(r.id) + '">';
    html += '<div class="result-title">' + escapeHtml(r.title) + "</div>";
    if (r.description) {
      html += '<div class="result-desc">' + escapeHtml(r.description) + "</div>";
    }
    if (r.actions && r.actions.length > 0) {
      html += '<div class="result-actions">';
      for (let j = 0; j < r.actions.length; j++) {
        const a = r.actions[j];
        html +=
          '<button class="action-btn"' +
          ' data-alias-id="' + escapeAttr(r.id) + '"' +
          ' data-action-index="' + j + '"' +
          ' data-command="' + escapeAttr(a.command) + '"' +
          ' data-label="' + escapeAttr(a.label) + '"' +
          (a.cap ? ' data-cap="' + escapeAttr(a.cap) + '"' : "") +
          ">" +
          escapeHtml(a.label) +
          "</button>";
      }
      html += "</div>";
    }
    if (r.tags && r.tags.length > 0) {
      html += '<div class="result-tags">';
      for (let k = 0; k < r.tags.length; k++) {
        html += '<span class="tag">' + escapeHtml(r.tags[k]) + "</span>";
      }
      html += "</div>";
    }
    html += "</div>";
  }

  resultsEl.innerHTML = html;

  const btns = resultsEl.querySelectorAll(".action-btn");
  for (let b = 0; b < btns.length; b++) {
    btns[b].addEventListener("click", onActionClick);
  }
}

function showError(msg) {
  currentResults = [];
  selectedIndex = -1;
  resultsEl.innerHTML = '<div class="result-error">' + escapeHtml(msg) + "</div>";
  hideOutput();
}

function clearResults() {
  currentResults = [];
  selectedIndex = -1;
  resultsEl.innerHTML = "";
  hideOutput();
}

// --- Selection ---

function setSelected(index) {
  const items = resultsEl.querySelectorAll(".result");
  if (selectedIndex >= 0 && selectedIndex < items.length) {
    items[selectedIndex].classList.remove("selected");
  }
  selectedIndex = index;
  if (selectedIndex >= 0 && selectedIndex < items.length) {
    items[selectedIndex].classList.add("selected");
    items[selectedIndex].scrollIntoView({ block: "nearest" });
  }
}

function moveSelection(delta) {
  const items = resultsEl.querySelectorAll(".result");
  if (items.length === 0) return;
  let next = selectedIndex + delta;
  if (next < 0) next = 0;
  if (next >= items.length) next = items.length - 1;
  setSelected(next);
}

function activateSelected() {
  if (selectedIndex < 0) return;
  const items = resultsEl.querySelectorAll(".result");
  if (selectedIndex >= items.length) return;
  const firstBtn = items[selectedIndex].querySelector(".action-btn");
  if (firstBtn) firstBtn.click();
}

// --- Confirmation modal ---

let pendingAction = null;

function renderCapCard(cap) {
  const severity = (cap.risk && cap.risk.severity) || "";
  const cardClass = "cap-card" + (severity ? " severity-" + escapeAttr(severity) : "");
  let html = '<div class="' + cardClass + '">';
  html += '<div class="cap-card-header">' + escapeHtml(cap.name);
  if (cap.type && cap.type !== cap.name) {
    html += '<span class="cap-card-type">' + escapeHtml(cap.type) + "</span>";
  }
  html += "</div>";
  if (cap.reason) {
    html += '<div class="cap-reason">' + escapeHtml(cap.reason) +
      ' <span style="color:#555;font-style:normal;">(stated by pack)</span></div>';
  }
  if (cap.risk && cap.risk.text) {
    const riskClass = "cap-risk" + (severity ? " severity-" + escapeAttr(severity) : "");
    html += '<div class="' + riskClass + '">' + escapeHtml(cap.risk.text) + "</div>";
  }
  html += "</div>";
  return html;
}

function showModal(label, command, capInfo) {
  modalTitleEl.textContent = label;
  modalCommandEl.textContent = command;
  if (capInfo && capInfo.caps && capInfo.caps.length > 0) {
    let html = "";
    for (let i = 0; i < capInfo.caps.length; i++) {
      html += renderCapCard(capInfo.caps[i]);
    }
    modalCapsListEl.innerHTML = html;
    modalCapsEl.style.display = "";
  } else {
    modalCapsEl.style.display = "none";
    modalCapsListEl.innerHTML = "";
  }
  modalEl.style.display = "flex";
  modalCancelEl.focus();
}

function hideModal() {
  modalEl.style.display = "none";
  pendingAction = null;
}

modalCancelEl.addEventListener("click", hideModal);
modalEl.addEventListener("click", (e) => {
  if (e.target === modalEl) hideModal();
});
document.addEventListener("keydown", (e) => {
  if (e.key === "Escape" && modalEl.style.display !== "none") {
    e.stopPropagation();
    hideModal();
  }
}, true);

// --- Streaming execute pump ---

let activeStream = null;

function abortActiveStream() {
  if (activeStream && activeStream.abort) {
    try { activeStream.abort(); } catch (_) { /* ignore */ }
  }
  if (activeStream && activeStream.consumer && typeof activeStream.consumer.dispose === "function") {
    try { activeStream.consumer.dispose(); } catch (_) { /* ignore */ }
  }
  activeStream = null;
}

const RECONNECT_DELAYS_MS = [250, 500, 1000, 2000, 5000];

// Drive an SSE-mode response into the output panel. lastEventId is null
// on first call, then carried across reconnect attempts.
function pumpStreamingExecute(action, lastEventId, attempt) {
  postExecuteWithStream(action.aliasId, action.actionIndex, lastEventId)
    .then((resp) => {
      if (resp.kind === "json") {
        const label = action.label + (resp.env && resp.env.ok === false ? " — error" : " — output");
        renderEnvelope(label, resp.env);
        return;
      }
      const streamCtx = { abort: resp.abort, lastId: lastEventId, stopped: false, consumer: null };
      activeStream = streamCtx;
      consumeStream(resp.reader, {
        onFrame: (ev, id, data) => {
          if (streamCtx.stopped) return;
          if (id != null) streamCtx.lastId = id;
          if (ev === "schema") {
            let schemaEnv;
            try { schemaEnv = JSON.parse(data); } catch (_) { schemaEnv = null; }
            if (!schemaEnv) return;
            streamCtx.consumer = renderEnvelope(action.label + " — streaming", schemaEnv);
            ensureStopButton(streamCtx);
          } else if (ev === "end") {
            if (streamCtx.consumer && typeof streamCtx.consumer.onEnd === "function") {
              streamCtx.consumer.onEnd();
            }
            streamCtx.stopped = true;
            clearStopButton();
          } else if (ev === "error") {
            let errEnv;
            try { errEnv = JSON.parse(data); } catch (_) { errEnv = null; }
            if (streamCtx.consumer && typeof streamCtx.consumer.onError === "function") {
              streamCtx.consumer.onError(errEnv || { ok: false, error: "stream error" });
            }
            if (errEnv) renderEnvelope(action.label + " — error", errEnv);
            streamCtx.stopped = true;
            clearStopButton();
          } else if (ev === "gap") {
            if (streamCtx.consumer && typeof streamCtx.consumer.onGap === "function") {
              streamCtx.consumer.onGap();
            }
          } else {
            // default "message": frame
            if (!streamCtx.consumer || typeof streamCtx.consumer.onFrame !== "function") return;
            let payload;
            try { payload = JSON.parse(data); } catch (_) { return; }
            if (payload && payload.type === "frame" && payload.frame) {
              streamCtx.consumer.onFrame(payload.frame);
            }
          }
        },
        onDone: () => {
          if (streamCtx.stopped) { activeStream = null; return; }
          if (activeStream !== streamCtx) return;
          const delay = RECONNECT_DELAYS_MS[Math.min(attempt || 0, RECONNECT_DELAYS_MS.length - 1)];
          setTimeout(() => {
            if (activeStream !== streamCtx) return;
            pumpStreamingExecute(action, streamCtx.lastId, (attempt || 0) + 1);
          }, delay);
        },
        onError: (err) => {
          const errEnv = { ok: false, error: "stream error: " + (err && err.message ? err.message : String(err)) };
          if (streamCtx.consumer && typeof streamCtx.consumer.onError === "function") {
            try { streamCtx.consumer.onError(errEnv); } catch (_) { /* ignore */ }
          }
          renderEnvelope(action.label + " — error", errEnv);
          streamCtx.stopped = true;
          activeStream = null;
          clearStopButton();
        },
      }).catch(() => {
        if (streamCtx.stopped) return;
        const delay = RECONNECT_DELAYS_MS[Math.min(attempt || 0, RECONNECT_DELAYS_MS.length - 1)];
        setTimeout(() => {
          if (activeStream !== streamCtx) return;
          pumpStreamingExecute(action, streamCtx.lastId, (attempt || 0) + 1);
        }, delay);
      });
    })
    .catch((err) => {
      const errEnv = {
        ok: false,
        error: "request failed: " + (err && err.message ? err.message : "network error"),
      };
      renderEnvelope(action.label + " — error", errEnv);
    });
}

// Stop button — injected into the output header while an SSE stream is live.
let stopBtnEl = null;
function ensureStopButton(streamCtx) {
  clearStopButton();
  stopBtnEl = document.createElement("button");
  stopBtnEl.className = "prim-btn style-default stream-stop";
  stopBtnEl.textContent = "Stop";
  stopBtnEl.addEventListener("click", () => {
    streamCtx.stopped = true;
    if (streamCtx.consumer && typeof streamCtx.consumer.dispose === "function") {
      try { streamCtx.consumer.dispose(); } catch (_) { /* ignore */ }
    }
    try { streamCtx.abort(); } catch (_) { /* ignore */ }
    activeStream = null;
    clearStopButton();
  });
  if (outputLabelEl && outputLabelEl.parentNode) {
    outputLabelEl.parentNode.appendChild(stopBtnEl);
  }
}
function clearStopButton() {
  if (stopBtnEl && stopBtnEl.parentNode) stopBtnEl.parentNode.removeChild(stopBtnEl);
  stopBtnEl = null;
}

modalExecuteEl.addEventListener("click", () => {
  if (!pendingAction) return;
  const action = pendingAction;
  hideModal();
  abortActiveStream();
  pumpStreamingExecute(action, null, 0);
});

// --- Action: show confirmation modal for shell commands ---

function onActionClick(e) {
  const btn = e.currentTarget;
  const aliasId = btn.getAttribute("data-alias-id");
  const actionIndex = parseInt(btn.getAttribute("data-action-index"), 10);
  const command = btn.getAttribute("data-command") || "";
  const label = btn.getAttribute("data-label") || "";
  if (!aliasId) return;

  pendingAction = { aliasId, actionIndex, command, label, btn };

  fetchCapInfo(aliasId, actionIndex).then((capInfo) => {
    const displayCommand = (capInfo && capInfo.exec_args) ? capInfo.exec_args : command;
    showModal(label, displayCommand, capInfo);
  }).catch(() => {
    showModal(label, command, null);
  });
}

// --- Search ---

async function doSearch(query) {
  try {
    const results = await fetchResults(query);
    renderResults(results);
  } catch (_) {
    showError("Search unavailable");
  }
}

function onSearchInput() {
  clearTimeout(debounceTimer);
  debounceTimer = setTimeout(() => doSearch(searchEl.value), 150);
}

// --- Keyboard navigation ---

function onKeyDown(e) {
  switch (e.key) {
    case "ArrowDown":
      e.preventDefault();
      moveSelection(1);
      break;
    case "ArrowUp":
      e.preventDefault();
      moveSelection(-1);
      break;
    case "Enter":
      e.preventDefault();
      activateSelected();
      break;
    case "Escape":
      e.preventDefault();
      if (outputPanelEl.style.display !== "none") {
        hideOutput();
      } else {
        searchEl.value = "";
        clearResults();
      }
      break;
  }
}

// --- Pack info ---

async function loadPackInfo() {
  try {
    const packs = await fetchPacks();
    if (!packs || packs.length === 0) return;
    let total = 0;
    for (let i = 0; i < packs.length; i++) {
      total += packs[i].alias_count || 0;
    }
    packInfoEl.textContent =
      total + " aliases from " + packs.length + " pack" + (packs.length === 1 ? "" : "s");
  } catch (_) {
    // Footer is non-critical; silently ignore.
  }
}

// --- Escape helpers (used by results-list and modal HTML construction) ---

function escapeHtml(str) {
  if (str == null) return "";
  return String(str)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function escapeAttr(str) {
  if (str == null) return "";
  return String(str).replace(/"/g, "&quot;").replace(/'/g, "&#39;");
}

// --- Init ---

// Reference postExecute / currentResults so the typechecker / future callers
// can find them; both are part of the historical export surface and may be
// reused by future tooling. (They have no side effects from being referenced.)
void postExecute; void currentResults;

searchEl.addEventListener("input", onSearchInput);
searchEl.addEventListener("keydown", onKeyDown);
searchEl.focus();

// Browse mode: load first batch immediately.
doSearch("");
loadPackInfo();
