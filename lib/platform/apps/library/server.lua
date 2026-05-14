-- lib/platform/apps/library/server.lua
-- Library app BFF server — serves the app browser UI + API for installed apps.
--
-- Endpoints:
--   GET /              — HTML page
--   GET /app.js        — JavaScript
--   GET /style.css     — Stylesheet
--   GET /api/apps      — paginated JSON list of installed apps
--                        query params: ?tag=X&q=SEARCH&limit=N&offset=N
--                        response: { total, limit, offset, apps: [...] }
--   GET /api/sources   — list registered source adapters
--                        response: { sources: [{ id, name }] }
--   GET /api/sources/:id/discover
--                      — proxy to a source adapter's /discover endpoint
--                        query params: same as source's GET /discover
--                        response: source's discover response shape
--   GET /api/sources/:id/thumb/:entry_id
--                      — proxy thumbnail request to source handler (binary)
--
-- Caps:
--   caps.index_db — readonly SQLite database (app index)
--   caps.sources  — optional array of { id, name, discover(params)->resp }
--   caps.self     — app metadata (optional, for reading static files)

if package and not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local json    = require("lib.format.json")
local service = require("lib.platform.service")

local M = {}

-- ── Static files ───────────────────────────────────────────────────────────
-- Embedded as strings so the server is self-contained (no filesystem access
-- needed at runtime). For development, these could be read from static/.

local STATIC = {}

STATIC["index.html"] = [[<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Library</title>
<link rel="stylesheet" href="/glassmorphism.css">
<link rel="stylesheet" href="/style.css">
<script type="module" src="/theme.js"></script>
</head>
<body>
<div id="app">
  <header class="header glass-panel">
    <h1>Library</h1>
    <div class="search-bar">
      <input type="text" id="search" class="glass-input" placeholder="Search apps..." autocomplete="off">
    </div>
    <button class="import-btn glass-button" id="import-btn">Import</button>
    <input type="file" id="import-file" accept="image/png,.png,.tar.gz,.tgz,application/gzip,application/x-tar" multiple hidden>
  </header>
  <div class="import-error" id="import-error" hidden></div>
  <div class="tag-bar" id="tag-bar"></div>
  <main class="grid" id="grid"></main>
  <div class="empty empty--filtered" id="empty-filtered" hidden>
    <div class="empty-msg">No apps match your filters.</div>
    <button class="clear-filters-btn" id="clear-filters-btn" type="button">Clear filters</button>
  </div>
  <div class="empty empty--welcome" id="empty-welcome" hidden>
    <div class="welcome-title">Welcome to your library</div>
    <div class="welcome-sub">Drag an app file anywhere on this page, or click <strong>Import</strong> above.</div>
    <div class="welcome-hint">Supported: <code>.png</code>, <code>.tar.gz</code>, <code>.tgz</code></div>
    <div class="welcome-sources" id="welcome-sources" hidden></div>
    <div class="welcome-arrow" aria-hidden="true">&uarr; Import is up there</div>
  </div>
</div>
<script src="/app.js"></script>
</body>
</html>]]

STATIC["style.css"] = [[*{margin:0;padding:0;box-sizing:border-box}
body{min-height:100vh}
.header{padding:1rem 1.5rem;display:flex;align-items:center;gap:1rem;border-bottom:1px solid var(--glass-border)}
.header h1{font-size:var(--font-size-xl);white-space:nowrap}
.search-bar{flex:1;max-width:400px}
.search-bar input{width:100%;padding:.5rem .75rem;font-size:.875rem}
.tag-bar{padding:.5rem 1.5rem;display:flex;gap:.5rem;flex-wrap:wrap;background:var(--glass-bg);border-bottom:1px solid var(--glass-border)}
.tag-btn{padding:.25rem .75rem;border-radius:999px;border:1px solid var(--glass-border);background:transparent;color:var(--fg);font-size:.75rem;cursor:pointer;transition:all .15s}
.tag-btn:hover,.tag-btn.active{background:var(--primary);border-color:var(--primary-hover);color:#fff}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(220px,1fr));gap:1rem;padding:1.5rem}
.card{position:relative;background:var(--glass-bg);border-radius:var(--radius-md);padding:1rem;border:1px solid var(--glass-border);border-top-color:var(--glass-border-light);border-left-color:var(--glass-border-light);border-bottom-color:var(--glass-border-dark);border-right-color:var(--glass-border-dark);cursor:pointer;transition:border-color .15s,transform .15s,background .15s;backdrop-filter:blur(12px);-webkit-backdrop-filter:blur(12px)}
.card:hover{border-color:var(--primary);background:var(--glass-hover);transform:translateY(-2px)}
.card-delete{position:absolute;top:.35rem;right:.35rem;background:none;border:none;color:var(--fg-muted);font-size:.9rem;cursor:pointer;padding:.15rem .3rem;border-radius:3px;line-height:1}
.card-delete:hover{background:var(--error);color:#fff}
.card-import{position:absolute;bottom:.5rem;left:.5rem;padding:.2rem .5rem;border-radius:var(--radius-sm);border:1px solid var(--glass-border);background:transparent;color:var(--fg-muted);font-size:.75rem;cursor:pointer;z-index:1}
.card-import:hover{background:var(--primary);color:#fff;border-color:var(--primary-hover)}
.card-thumb{width:100%;height:120px;object-fit:cover;border-radius:var(--radius-sm);margin-bottom:.5rem;display:block;background:var(--glass-bg)}
.card-name{font-weight:600;font-size:.95rem;margin-bottom:.35rem}
.card-desc{font-size:.8rem;color:var(--fg-muted);margin-bottom:.5rem;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden}
.card-tags{display:flex;flex-wrap:wrap;gap:.25rem}
.tag{font-size:.65rem;padding:.125rem .4rem;border-radius:var(--radius-sm);background:var(--glass-bg);color:var(--fg-muted);border:1px solid var(--glass-border)}
.empty{text-align:center;padding:3rem;color:var(--fg-muted);font-size:.9rem}
.empty--filtered{display:flex;flex-direction:column;align-items:center;gap:.75rem}
.clear-filters-btn{padding:.4rem .85rem;border-radius:var(--radius-md);border:1px solid var(--glass-border);background:transparent;color:var(--fg);font-size:.85rem;cursor:pointer}
.clear-filters-btn:hover{border-color:var(--primary);color:var(--primary)}
.empty--welcome{padding:4rem 1.5rem;max-width:560px;margin:0 auto}
.welcome-title{font-size:1.4rem;font-weight:600;color:var(--fg);margin-bottom:.75rem}
.welcome-sub{font-size:1rem;color:var(--fg);margin-bottom:.75rem;line-height:1.5}
.welcome-hint{font-size:.8rem;color:var(--fg-muted);margin-bottom:1.25rem}
.welcome-hint code{background:var(--glass-bg);padding:.1rem .3rem;border-radius:3px;color:var(--fg-muted)}
.welcome-sources{font-size:.9rem;color:var(--fg);margin-top:1rem;padding-top:1rem;border-top:1px solid var(--glass-border)}
.welcome-arrow{margin-top:1.5rem;font-size:.8rem;color:var(--primary);letter-spacing:.05em}
@keyframes import-pulse{0%,100%{box-shadow:0 0 0 0 rgba(59,130,246,.55)}50%{box-shadow:0 0 0 6px rgba(59,130,246,0)}}
.import-btn{padding:.4rem .85rem;font-size:.875rem;white-space:nowrap;flex-shrink:0}
.import-btn:hover{border-color:var(--primary);color:var(--primary)}
.import-btn--pulse{border-color:var(--primary);color:var(--primary);animation:import-pulse 1.6s ease-out infinite}
.import-error{padding:.5rem 1.5rem;background:rgba(239,68,68,.15);color:var(--error);font-size:.85rem;word-break:break-word;border-bottom:1px solid var(--error)}
.source-section{border-top:1px solid var(--glass-border);padding-top:.5rem}
.source-header{padding:.5rem 1.5rem;font-size:.8rem;font-weight:600;color:var(--fg-muted);letter-spacing:.05em;text-transform:uppercase}
.source-count{font-weight:400;color:var(--fg-muted);margin-left:.5rem;opacity:.7}
.source-more{display:block;margin:.25rem 1.5rem 1rem;padding:.35rem .75rem;border-radius:var(--radius-md);border:1px solid var(--glass-border);background:transparent;color:var(--fg-muted);font-size:.75rem;cursor:pointer}
.source-more:hover{border-color:var(--primary);color:var(--primary)}]]

STATIC["app.js"] = [=[const grid = document.getElementById("grid");
const search = document.getElementById("search");
const tagBar = document.getElementById("tag-bar");
const emptyFiltered = document.getElementById("empty-filtered");
const emptyWelcome  = document.getElementById("empty-welcome");
const welcomeSources = document.getElementById("welcome-sources");
const clearFiltersBtn = document.getElementById("clear-filters-btn");
const appEl = document.getElementById("app");

let activeTag = null;
let sourceNames = [];

// ── Card rendering ────────────────────────────────────────────────────────

// Build one card element. app/entry must have: id, name, description, tags.
// onLaunch: function() — called when card is clicked.
// onDelete: function() | null — if non-null, shows × button.
// onImport: function() | null — if non-null, shows "Open" import button.
function makeCard(item, onLaunch, onDelete, onImport) {
  const card = document.createElement("div");
  card.className = "card";
  card.onclick = onLaunch;

  if (item.thumb_url) {
    const img = document.createElement("img");
    img.className = "card-thumb";
    img.src = item.thumb_url;
    img.alt = item.name || "";
    img.loading = "lazy";
    card.appendChild(img);
  }

  const name = document.createElement("div");
  name.className = "card-name";
  name.textContent = item.name || "Untitled";
  card.appendChild(name);

  if (item.description) {
    const desc = document.createElement("div");
    desc.className = "card-desc";
    desc.textContent = item.description;
    card.appendChild(desc);
  }

  const tags = item.tags || [];
  if (tags.length) {
    const tagsEl = document.createElement("div");
    tagsEl.className = "card-tags";
    tags.forEach(t => {
      const tag = document.createElement("span");
      tag.className = "tag";
      tag.textContent = t;
      tagsEl.appendChild(tag);
    });
    card.appendChild(tagsEl);
  }

  if (onDelete) {
    const del = document.createElement("button");
    del.className = "card-delete";
    del.title = "Uninstall";
    del.setAttribute("aria-label", "Uninstall");
    del.textContent = "\xD7";
    del.onclick = e => { e.stopPropagation(); onDelete(); };
    card.appendChild(del);
  }

  if (onImport) {
    const imp = document.createElement("button");
    imp.className = "card-import";
    imp.title = "Open in conversation";
    imp.textContent = "Open";
    imp.onclick = e => {
      e.stopPropagation();
      imp.disabled = true;
      imp.textContent = "…";
      onImport(err => {
        imp.disabled = false;
        imp.textContent = err ? "!" : "Open";
        if (err) imp.title = `Error: ${err}`;
      });
    };
    card.appendChild(imp);
  }

  return card;
}

// ── Installed section ─────────────────────────────────────────────────────

function renderApps(apps, total) {
  grid.innerHTML = "";
  const hasFilter = !!(search.value.trim() || activeTag);
  const totalApps = typeof total === "number" ? total : apps.length;
  // Welcome state: zero apps anywhere in the index (ignore filter — if total is 0, there's nothing to filter).
  // Filtered-out state: apps exist in index, but the current filter produced zero results.
  const showWelcome = totalApps === 0 && !hasFilter;
  const showFiltered = apps.length === 0 && !showWelcome;
  emptyWelcome.hidden = !showWelcome;
  emptyFiltered.hidden = !showFiltered;
  updateImportPulse(showWelcome);
  updateWelcomeSources();
  apps.forEach(app => {
    grid.appendChild(makeCard(
      app,
      () => { if (app.id) window.location.href = `/launch/${encodeURIComponent(app.id)}`; },
      async () => {
        if (!confirm(`Uninstall \u201c${app.name || "this app"}\u201d?`)) return;
        const r = await fetch(`/api/apps/${encodeURIComponent(app.id)}`, { method: "DELETE" });
        if (r.ok) { refresh(); } else { alert(`Uninstall failed: ${await r.text()}`); }
      }
    ));
  });
}

function renderTagBar(apps) {
  const tags = {};
  apps.forEach(app => {
    (app.tags || []).forEach(t => { tags[t] = (tags[t] || 0) + 1; });
  });
  tagBar.innerHTML = "";
  const btn = document.createElement("button");
  btn.className = `tag-btn${activeTag === null ? " active" : ""}`;
  btn.setAttribute("aria-pressed", activeTag === null ? "true" : "false");
  btn.textContent = "All";
  btn.onclick = () => { activeTag = null; refresh(); };
  tagBar.appendChild(btn);
  Object.keys(tags).sort().forEach(t => {
    const b = document.createElement("button");
    const pressed = activeTag === t;
    b.className = `tag-btn${pressed ? " active" : ""}`;
    b.setAttribute("aria-pressed", pressed ? "true" : "false");
    b.textContent = `${t} (${tags[t]})`;
    b.onclick = () => { activeTag = (activeTag === t) ? null : t; refresh(); };
    tagBar.appendChild(b);
  });
}

async function refresh() {
  const q = search.value.trim();
  let url = "/api/apps";
  const params = [];
  if (activeTag) params.push(`tag=${encodeURIComponent(activeTag)}`);
  if (q) params.push(`q=${encodeURIComponent(q)}`);
  if (params.length) url += `?${params.join("&")}`;

  const data = await fetch(url).then(r => r.json());
  renderApps(data.apps || [], data.total);
  if (!q && !activeTag) renderTagBar(data.apps || []);
}

function updateImportPulse(on) {
  if (!importBtn) return;
  importBtn.classList.toggle("import-btn--pulse", !!on);
}

function updateWelcomeSources() {
  if (!welcomeSources) return;
  if (!sourceNames.length) { welcomeSources.hidden = true; welcomeSources.textContent = ""; return; }
  const list = sourceNames.length === 1
    ? sourceNames[0]
    : `${sourceNames.slice(0, -1).join(", ")} and ${sourceNames[sourceNames.length - 1]}`;
  welcomeSources.textContent = `Or browse your ${list} ${sourceNames.length === 1 ? "characters" : "sources"} below.`;
  welcomeSources.hidden = false;
}

function clearFilters() {
  search.value = "";
  activeTag = null;
  refreshAll();
}

// ── Source adapter sections ────────────────────────────────────────────────

// Build a source section UI. Returns { el, loadPage }.
function makeSourceSection(src) {
  const section = document.createElement("div");
  section.className = "source-section";

  const header = document.createElement("div");
  header.className = "source-header";
  const label = document.createElement("span");
  label.textContent = src.name;
  const count = document.createElement("span");
  count.className = "source-count";
  header.appendChild(label);
  header.appendChild(count);
  section.appendChild(header);

  const sgrid = document.createElement("div");
  sgrid.className = "grid";
  section.appendChild(sgrid);

  const more = document.createElement("button");
  more.className = "source-more";
  more.hidden = true;
  section.appendChild(more);

  let offset = 0;
  let total = 0;
  let generation = 0;
  const LIMIT = 200;

  async function loadPage(q) {
    const gen = generation;
    let url = `/api/sources/${encodeURIComponent(src.id)}/discover?limit=${LIMIT}&offset=${offset}`;
    if (q) url += `&q=${encodeURIComponent(q)}`;
    const data = await fetch(url).then(r => r.json());
    if (gen !== generation) return;
    total = data.total || 0;
    const entries = data.entries || [];
    entries.forEach(e => {
      const launchUrl = `/launch/${encodeURIComponent(src.id)}?entry=${encodeURIComponent(e.id)}`;
      const importUrl = `/api/apps?source=${encodeURIComponent(src.id)}&entry=${encodeURIComponent(e.id)}`;
      sgrid.appendChild(makeCard(e, () => { window.location.href = launchUrl; }, null, async done => {
        try {
          const r = await fetch(importUrl, { method: "POST" });
          const data = await r.json();
          if (data.launch_url) { window.location.href = data.launch_url; }
          else { done(data.error || "unknown error"); }
        } catch (err) { done(String(err)); }
      }));
    });
    offset += entries.length;
    count.textContent = `(${offset} of ${total})`;
    more.hidden = offset >= total;
    more.textContent = `Load more \u2014 ${total - offset} remaining`;
  }

  more.onclick = () => { loadPage(search.value.trim()); };

  function reset(q) {
    generation++;
    offset = 0;
    total = 0;
    sgrid.innerHTML = "";
    more.hidden = true;
    loadPage(q);
  }

  return { el: section, loadPage: loadPage, reset: reset };
}

const sourceSections = [];

async function loadSources() {
  const data = await fetch("/api/sources").then(r => r.json());
  const list = data.sources || [];
  sourceNames = list.map(s => s.name).filter(Boolean);
  updateWelcomeSources();
  list.forEach(src => {
    const sec = makeSourceSection(src);
    sourceSections.push(sec);
    appEl.appendChild(sec.el);
    sec.loadPage("");
  });
}

function refreshAll() {
  const q = search.value.trim();
  refresh();
  sourceSections.forEach(sec => { sec.reset(q); });
}

// ── File import (button + drag-drop) ──────────────────────────────────────

const importBtn  = document.getElementById("import-btn");
const importFile = document.getElementById("import-file");
const importErr  = document.getElementById("import-error");

function showImportError(msg) {
  importErr.textContent = msg;
  importErr.hidden = false;
}

function clearImportError() {
  importErr.hidden = true;
  importErr.textContent = "";
}

async function uploadApp(file, onDone) {
  try {
    const buf = await file.arrayBuffer();
    const r = await fetch("/api/apps", {
      method: "POST",
      headers: { "Content-Type": file.type || "application/octet-stream" },
      body: buf,
    });
    const data = await r.json();
    if (r.ok && data.launch_url) {
      clearImportError();
      onDone(null);
      refresh();
    } else {
      onDone(data.error || "Import failed");
    }
  } catch (err) {
    onDone(String(err));
  }
}

const isImportable = f => {
  if (f.type === "image/png" || f.name.slice(-4).toLowerCase() === ".png") return true;
  const name = f.name.toLowerCase();
  if (name.slice(-7) === ".tar.gz" || name.slice(-4) === ".tgz") return true;
  return false;
};

function importFiles(files) {
  clearImportError();
  const apps = [];
  for (let i = 0; i < files.length; i++) {
    if (isImportable(files[i])) apps.push(files[i]);
  }
  if (!apps.length) { showImportError("No importable files found. Supported: .png, .tar.gz, .tgz"); return; }
  const errors = [];
  let remaining = apps.length;
  apps.forEach(f => {
    uploadApp(f, err => {
      if (err) errors.push(`${f.name}: ${err}`);
      remaining--;
      if (remaining === 0 && errors.length) {
        showImportError(errors.join(" | "));
      }
    });
  });
}

importBtn.addEventListener("click", () => {
  clearImportError();
  importFile.value = "";
  importFile.click();
});

importFile.addEventListener("change", () => {
  if (importFile.files && importFile.files.length) {
    importFiles(importFile.files);
  }
});

document.addEventListener("dragover", e => { e.preventDefault(); });

document.addEventListener("drop", e => {
  e.preventDefault();
  if (e.dataTransfer && e.dataTransfer.files && e.dataTransfer.files.length) {
    importFiles(e.dataTransfer.files);
  }
});

search.addEventListener("input", refreshAll);
if (clearFiltersBtn) clearFiltersBtn.addEventListener("click", clearFilters);
refresh();
loadSources();
]=]

-- ── Helpers ────────────────────────────────────────────────────────────────

local CONTENT_TYPES = {
	html = "text/html; charset=utf-8",
	css  = "text/css; charset=utf-8",
	js   = "application/javascript; charset=utf-8",
	json = "application/json",
}

-- Tarball-bundled static entries (e.g. glassmorphism.css, theme.js).
-- Served via caps.self.entry("static/<name>") when caps.self is present.
-- Falls back to nothing if caps.self is unavailable (e.g. in unit tests
-- without a full sandbox).
local BUNDLED = {
	["/glassmorphism.css"] = { entry = "static/glassmorphism.css", ext = "css" },
	["/theme.js"] = { entry = "static/theme.js", ext = "js" },
}

local function serve_static(caps, req, res)
	local path = req.path or "/"
	local name, ext
	if path == "/" then
		name, ext = "index.html", "html"
	elseif path == "/app.js" then
		name, ext = "app.js", "js"
	elseif path == "/style.css" then
		name, ext = "style.css", "css"
	end
	if name then
		local content = STATIC[name]
		if not content then return nil end
		res.status = 200
		res.headers["Content-Type"] = { CONTENT_TYPES[ext] or "application/octet-stream" }
		res.body = content
		return true
	end
	local bundle = BUNDLED[path]
	if bundle then
		local entry_fn = caps and caps.self and caps.self.entry
		if entry_fn then
			local content = entry_fn(bundle.entry)
			if content then
				res.status = 200
				res.headers["Content-Type"] = { CONTENT_TYPES[bundle.ext] or "application/octet-stream" }
				res.body = content
				return true
			end
		end
		-- caps.self unavailable or entry missing — serve empty stylesheet/script
		-- so the missing-file 404 doesn't break the page. Apps without the
		-- glassmorphism bundle still get usable (un-themed) UI.
		res.status = 200
		res.headers["Content-Type"] = { CONTENT_TYPES[bundle.ext] or "application/octet-stream" }
		res.body = ""
		return true
	end
	return nil
end

-- ── Index DB queries ───────────────────────────────────────────────────────
-- Uses the same schema as lib/platform/index.lua.
--
-- Pagination is end-to-end: the server executes one SELECT with LIMIT/OFFSET
-- and one COUNT query, then returns only the requested page. The full list is
-- never materialized on the server or the wire. This is the core of the
-- anti-ST perf discipline — at 23k apps, the list view must ship ~20 KB per
-- page, not 45 MB of everything.
--
-- Tag filter uses the app_tags join; search uses apps_fts (trigram). Both
-- are indexed — no json_each scans, no LIKE '%q%' full-table scans.

local SELECT_COLS = "a.id, a.name, a.path, a.manifest_json, a.tags_json, a.installed_at"

-- Double-quote an FTS5 MATCH phrase so special chars are literal trigrams.
--: (string) -> string
local function fts_phrase(q)
	local s = q:gsub('"', '""')
	return '"' .. s .. '"'
end

-- FROM + JOIN + WHERE fragments keyed by (has_q, has_tag). Each variant
-- keeps the same alias (`a`) for `apps` so SELECT_COLS is reusable.
--
-- For FTS-filtered variants the MATCH predicate MUST live in a subquery,
-- not a JOIN. Joining apps_fts directly lets SQLite pick a plan that
-- re-evaluates MATCH per row of the outer loop (100x slower at 20k
-- rows — see docs/perf/library_index.lua). `a.id IN (SELECT rowid FROM
-- apps_fts WHERE apps_fts MATCH ?)` evaluates FTS once then filters.
local FROM_NONE  = " FROM apps a"
local FROM_TAG   = " FROM apps a JOIN app_tags at ON at.app_id = a.id JOIN tags t ON t.id = at.tag_id WHERE t.name = ?"
local FROM_Q     = " FROM apps a WHERE a.id IN (SELECT rowid FROM apps_fts WHERE apps_fts MATCH ?)"
local FROM_Q_TAG = " FROM apps a JOIN app_tags at ON at.app_id = a.id JOIN tags t ON t.id = at.tag_id WHERE t.name = ? AND a.id IN (SELECT rowid FROM apps_fts WHERE apps_fts MATCH ?)"

--: (string | nil, string | nil) -> (string, { [integer]: unknown })
local function build_from(q, tag)
	local has_q   = q   and q   ~= ""
	local has_tag = tag and tag ~= ""
	local args = {} --: { [integer]: unknown }
	if has_q and has_tag then args[1] = tag;          args[2] = fts_phrase(q --[[:! string]]); return FROM_Q_TAG, args end
	if has_q            then args[1] = fts_phrase(q --[[:! string]]);                         return FROM_Q,     args end
	if has_tag          then args[1] = tag;                                   return FROM_TAG,   args end
	return FROM_NONE, args
end

--: (iter: unknown) -> { [integer]: unknown }
local function collect_rows(iter)
	local iter_fn = iter --[[:! (() -> (string | nil, string | nil, string | nil, string | nil, string | nil, integer | nil)) | nil]]
	if not iter_fn then return {} end
	local results = {}
	while true do
		local id, name, path, manifest_json, tags_json, installed_at = iter_fn()
		if not id then break end
		local tags = json.decode(tags_json --[[:! string]]) or {}
		local manifest = json.decode(manifest_json --[[:! string]]) or {}
		local meta = (manifest --[[:! { meta: { description: string | nil, ... } | nil, ... }]]).meta or {}
		results[#results + 1] = {
			id = id,
			name = name,
			description = meta.description or "",
			path = path,
			tags = tags,
			installed_at = installed_at,
		}
	end
	return results
end

-- query_apps(db, tag, q, limit, offset) -> rows, total
-- Returns the page of rows plus the total matching count (used by the UI for
-- "200 of 23,412" and for the "load more" button).
local function query_apps(db, tag, q, limit, offset)
	if not db then return {}, 0 end

	local from, args = build_from(q, tag)

	-- Total count for the merged UI indicator. Runs against the same
	-- filter, without the LIMIT/OFFSET.
	local count_sql = "SELECT COUNT(*)" .. from
	local citer = db:query(count_sql, unpack(args))
	local total = 0
	if citer then
		local c = (citer --[[:! () -> integer]])()
		if c then total = c end
	end

	-- Page query. ORDER BY name ASC is the current default; a sort param
	-- can be threaded through here later.
	local select_sql = "SELECT " .. SELECT_COLS .. from
		.. " ORDER BY a.name ASC LIMIT ? OFFSET ?"
	args[#args + 1] = limit
	args[#args + 1] = offset
	local iter = db:query(select_sql, unpack(args))
	return collect_rows(iter), total
end

-- ── Query string parser ────────────────────────────────────────────────────

--: (string | nil) -> { [string]: string }
local function parse_query(qs)
	local params = {} --: { [string]: string }
	if not qs or qs == "" then return params end
	for kv in qs:gmatch("[^&]+") do
		local k, v = kv:match("^([^=]+)=?(.*)")
		if k and v then
			-- Minimal percent-decode for common characters.
			local v2 = (v:gsub("%%(%x%x)", function(h)
				local n = tonumber(h, 16)
				return n and string.char(n) or h
			end):gsub("+", " "))
			params[k] = v2
		end
	end
	return params
end

-- ── Sources index ──────────────────────────────────────────────────────────
-- Build a lookup map from id → source_entry for O(1) dispatch.
-- caps.sources is optional (nil or empty → no source sections).
--: ({ [integer]: unknown } | nil) -> { [string]: unknown }
local function build_source_map(sources)
	local map = {} --: { [string]: unknown }
	if not sources then return map end
	for i = 1, #sources do
		local s = sources[i]
		if type(s) == "table" and s.id then
			map[s.id] = s
		end
	end
	return map
end

-- ── Service methods ────────────────────────────────────────────────────────
-- Each method takes caps as first arg followed by named parameters.
-- These are pure business-logic functions; routing/dispatch is handled by
-- lib.platform.service.

-- list_apps: GET /api/apps?tag=X&q=X&limit=N&offset=N
local function list_apps(caps, tag, q, limit, offset)
	local db = caps.index_db
	local limit_raw  = tonumber(limit)  or 200
	local offset_raw = tonumber(offset) or 0
	local lim = math.max(1, math.min(500, limit_raw))
	local off = math.max(0, offset_raw)
	local apps, total = query_apps(db, tag, q, lim, off)
	return {
		total  = total,
		limit  = lim,
		offset = off,
		apps   = apps,
	}
end

-- list_sources: GET /api/sources
local function list_sources(caps)
	local sources_list = caps.sources or {}
	local list = {}
	for i = 1, #sources_list do
		local s = sources_list[i]
		list[i] = { id = s.id, name = s.name }
	end
	return { sources = list }
end

-- get_source_discover: GET /api/sources/:source_id/discover?q=X&limit=N&offset=N
-- Proxies to a source adapter's discover function, then rewrites thumb_url
-- entries to route through this server's thumb proxy (same-origin, CSP-safe).
--: (caps: { _source_map: { [string]: { discover: (unknown) -> unknown, handler: unknown, ... }, ... }, ... }, source_id: string, q: unknown, limit: unknown, offset: unknown) -> (unknown, { status: integer, message: string } | nil)
local function get_source_discover(caps, source_id, q, limit, offset)
	local source_map = caps._source_map
	-- Percent-decode the source id from the path segment.
	local decoded_id_raw, _ = source_id:gsub("%%(%x%x)", function(h)
		local n = tonumber(h, 16)
		return n and string.char(n) or h
	end)
	local decoded_id = decoded_id_raw
	local src = source_map[decoded_id]
	if not src then
		return nil, { status = 404, message = "source not found: " .. decoded_id }
	end
	local params = { q = q, limit = limit, offset = offset }
	local resp = src.discover(params) --[[:! { entries: { [integer]: { id: unknown, thumb_url: string | nil, ... } } | nil, ... }]]
	-- Rewrite thumb_url entries to route through this server's thumb proxy.
	if src.handler and resp and resp.entries then
		local encoded_src_id = decoded_id:gsub("[^%w%-_%.~]",
			function(c) return ("%%%02X"):format((c --[[:! string]]):byte()) end)
		for _, entry in ipairs(resp.entries) do
			if entry.id then
				local encoded_entry_id = tostring(entry.id):gsub("[^%w%-_%.~]",
					function(c) return ("%%%02X"):format((c --[[:! string]]):byte()) end)
				entry.thumb_url = "/api/sources/" .. encoded_src_id
					.. "/thumb/" .. encoded_entry_id
			end
		end
	end
	return resp
end

-- ── Router ─────────────────────────────────────────────────────────────────

function M.create(caps)
	local source_map = build_source_map(caps.sources)

	-- Injected I/O for the CLI handler — use caps when present, fall back to
	-- globals only when the caller has not provided them (e.g. in tests).
	local stdout_cap = caps.stdout --[[:! { write: (string) -> unknown, ... } | nil]]
	local stderr_cap = caps.stderr --[[:! { write: (string) -> unknown, ... } | nil]]
	local stdout_write = stdout_cap and stdout_cap.write or function(s) io.write(s) end
	local stderr_write = stderr_cap and stderr_cap.write or function(s) io.stderr:write(s) end

	-- Augment caps with derived lookup so service methods can access it.
	-- A shallow copy is used to avoid mutating the caller's caps table.
	local caps_ext = {}
	for k, v in pairs(caps) do caps_ext[k] = v end
	caps_ext._source_map = source_map

	local methods = {
		list_apps             = list_apps,
		list_sources          = list_sources,
		get_source_discover   = get_source_discover,
	}

	local descriptors = {
		list_apps = {
			method = "GET",
			path   = "/api/apps",
			help   = "List/search installed apps (tag=, q=, limit=, offset=)",
		},
		list_sources = {
			method = "GET",
			path   = "/api/sources",
			help   = "List registered source adapters",
		},
		get_source_discover = {
			method = "GET",
			path   = "/api/sources/:source_id/discover",
			help   = "Proxy discover to a source adapter (q=, limit=, offset=)",
		},
	}

	local svc = service.create(caps_ext, methods, descriptors) --[[:! { handler: (unknown, unknown) -> unknown, cli: (unknown) -> unknown, ... }]]

	-- ── Thumb proxy ────────────────────────────────────────────────────────
	-- Binary passthrough — cannot use the service JSON layer.
	-- Path: GET /api/sources/:source_id/thumb/:entry_id
	local function handle_thumb(req, res)
		local path = req.path or ""
		local thumb_src_id, thumb_entry_id = path:match("^/api/sources/([^/]+)/thumb/(.+)$")
		if not thumb_src_id then return nil end
		thumb_src_id   = (thumb_src_id:gsub("%%(%x%x)",   function(h) return string.char(tonumber(h, 16) --[[:! integer]]) end)) --[[: unknown]]
		local thumb_entry_id_raw, _ = thumb_entry_id:gsub("%%(%x%x)", function(h)
			local n = tonumber(h, 16)
			return n and string.char(n) or h
		end)
		thumb_entry_id = thumb_entry_id_raw
		local src = source_map[thumb_src_id] --[[:! { handler: ((unknown, unknown) -> unknown) | nil, ... } | nil]]
		if not src or not src.handler then
			res.status = 404
			res.headers["Content-Type"] = { "text/plain; charset=utf-8" }
			res.body = "thumb not available"
			return true
		end
		local thumb_req = { method = "GET", path = "/thumb/" .. thumb_entry_id, headers = {} }
		src.handler(thumb_req, res)
		return true
	end

	-- ── Composed handler ───────────────────────────────────────────────────
	-- Priority: static files → thumb proxy (binary) → service API routes.
	-- Static files are checked first so "/" doesn't fall into the 404 path.
	-- Thumb proxy is before service because service has no binary response support.
	-- service.handler returns nil on no-match, enabling clean fallthrough.
	local function handler(req, res)
		local method = (req.method or "GET"):upper()
		if method == "GET" then
			if serve_static(caps, req, res) then return true end
			if handle_thumb(req, res) then return true end
		end
		return svc.handler(req, res)
	end

	-- cli(args) -> nil
	-- CLI handler: invoked when 'cr run <app> -- [args...]' is used.
	-- Subcommands: list, list --json, search <query>, search --json <query>
	-- Implemented via service CLI projection (subcommand: list-apps, list-sources).
	-- The original 'list'/'search' aliases are preserved as wrappers so existing
	-- usage isn't broken.
	local svc_cli = svc.cli

	local function cli(args)
		-- Translate legacy 'list' and 'search' subcommands to service form.
		-- 'list'          → 'list-apps'
		-- 'search <q>'    → 'list-apps <q>'  (q positional, not named param)
		-- 'list --json'   → 'list-apps --json'
		-- 'search --json' → 'list-apps --json'
		-- All other args are forwarded as-is to the service CLI dispatcher.
		local translated = {}
		local first = nil
		for _, a in ipairs(args) do
			if first == nil and a:sub(1, 1) ~= "-" then
				first = a
			end
		end

		if first == "list" or first == "search" then
			-- Build translated args: replace first positional with 'list-apps'.
			-- For 'search', the remaining positionals become the 'q' value but
			-- the service CLI passes positionals by position, so we join them.
			local want_json = false
			local positional = {}
			for _, a in ipairs(args) do
				if a == "--json" then
					want_json = true
				elseif a ~= "--help" and a ~= "-h" then
					positional[#positional + 1] = a
				end
			end
			-- positional[1] is "list" or "search"; skip it.
			if first == "search" and #positional < 2 then
				stderr_write("error: 'search' requires a query argument\n")
				return
			end
			-- The list_apps method signature: (caps, tag, q, limit, offset).
			-- CLI positional args map left-to-right after caps.
			-- For 'search', pass q as third positional (tag slot = nil).
			-- We use the raw svc.cli with constructed arg list.
			local new_args = { "list-apps" }
			if want_json then new_args[#new_args + 1] = "--json" end
			if first == "search" then
				-- q is positional #3 after tag (#2). Pass empty string for tag,
				-- then join remaining positionals as q.
				local parts = {}
				for i = 2, #positional do parts[#parts + 1] = positional[i] end
				new_args[#new_args + 1] = ""  -- tag (empty = no filter)
				new_args[#new_args + 1] = table.concat(parts, " ")  -- q
			end
			return svc_cli(new_args)
		end

		-- Not a legacy alias — check for --help or pass directly.
		for _, a in ipairs(args) do
			if a == "--help" or a == "-h" then
				stdout_write("usage:\n")
				stdout_write("  cr run <app> -- list                   List installed apps\n")
				stdout_write("  cr run <app> -- list --json            Output as JSON array\n")
				stdout_write("  cr run <app> -- search <query>         Search apps by name/tag\n")
				stdout_write("  cr run <app> -- search --json <query>  Search output as JSON array\n")
				stdout_write("  cr run <app> -- --help                 This help text\n")
				return
			end
		end

		return svc_cli(args)
	end

	return { handler = handler, cli = cli }
end

-- Expose for testing.
M._parse_query = parse_query
M._STATIC = STATIC

return M
