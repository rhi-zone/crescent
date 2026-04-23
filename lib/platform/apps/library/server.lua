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
<link rel="stylesheet" href="/style.css">
</head>
<body>
<div id="app">
  <header class="header">
    <h1>Library</h1>
    <div class="search-bar">
      <input type="text" id="search" placeholder="Search apps..." autocomplete="off">
    </div>
    <button class="import-btn" id="new-card-btn">New Card</button>
    <button class="import-btn" id="import-btn">Import Card</button>
    <input type="file" id="import-file" accept="image/png,.png" hidden>
  </header>
  <div class="import-error" id="import-error" hidden></div>
  <div class="tag-bar" id="tag-bar"></div>
  <main class="grid" id="grid"></main>
  <div class="empty" id="empty" hidden>No apps found.</div>
</div>
<script src="/app.js"></script>
</body>
</html>]]

STATIC["style.css"] = [[*{margin:0;padding:0;box-sizing:border-box}
body{font-family:system-ui,-apple-system,sans-serif;background:#1a1a2e;color:#e0e0e0;min-height:100vh}
.header{padding:1rem 1.5rem;display:flex;align-items:center;gap:1rem;background:#16213e;border-bottom:1px solid #0f3460}
.header h1{font-size:1.25rem;white-space:nowrap}
.search-bar{flex:1;max-width:400px}
.search-bar input{width:100%;padding:.5rem .75rem;border-radius:6px;border:1px solid #0f3460;background:#1a1a2e;color:#e0e0e0;font-size:.875rem}
.search-bar input:focus{outline:none;border-color:#e94560}
.tag-bar{padding:.5rem 1.5rem;display:flex;gap:.5rem;flex-wrap:wrap;background:#16213e;border-bottom:1px solid #0f3460}
.tag-btn{padding:.25rem .75rem;border-radius:999px;border:1px solid #0f3460;background:transparent;color:#e0e0e0;font-size:.75rem;cursor:pointer;transition:all .15s}
.tag-btn:hover,.tag-btn.active{background:#e94560;border-color:#e94560;color:#fff}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(220px,1fr));gap:1rem;padding:1.5rem}
.card{position:relative;background:#16213e;border-radius:8px;padding:1rem;border:1px solid #0f3460;cursor:pointer;transition:border-color .15s,transform .15s}
.card:hover{border-color:#e94560;transform:translateY(-2px)}
.card-delete{position:absolute;top:.35rem;right:.35rem;background:none;border:none;color:#606070;font-size:.9rem;cursor:pointer;padding:.15rem .3rem;border-radius:3px;line-height:1}
.card-delete:hover{background:#e94560;color:#fff}
.card-import{position:absolute;bottom:.5rem;left:.5rem;padding:.2rem .5rem;border-radius:4px;border:1px solid #4a4a8a;background:transparent;color:#8888cc;font-size:.75rem;cursor:pointer;z-index:1}
.card-import:hover{background:#4a4a8a;color:#fff}
.card-thumb{width:100%;height:120px;object-fit:cover;border-radius:4px;margin-bottom:.5rem;display:block;background:#0f1728}
.card-name{font-weight:600;font-size:.95rem;margin-bottom:.35rem}
.card-desc{font-size:.8rem;color:#a0a0b0;margin-bottom:.5rem;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden}
.card-tags{display:flex;flex-wrap:wrap;gap:.25rem}
.tag{font-size:.65rem;padding:.125rem .4rem;border-radius:4px;background:#0f3460;color:#a0a0b0}
.empty{text-align:center;padding:3rem;color:#a0a0b0;font-size:.9rem}
.import-btn{padding:.4rem .85rem;border-radius:6px;border:1px solid #0f3460;background:transparent;color:#e0e0e0;font-size:.875rem;cursor:pointer;white-space:nowrap;flex-shrink:0}
.import-btn:hover{border-color:#e94560;color:#e94560}
.import-error{padding:.5rem 1.5rem;background:#3a1020;color:#ff8099;font-size:.85rem;word-break:break-word;border-bottom:1px solid #6a2040}
.source-section{border-top:1px solid #0f3460;padding-top:.5rem}
.source-header{padding:.5rem 1.5rem;font-size:.8rem;font-weight:600;color:#a0a0b0;letter-spacing:.05em;text-transform:uppercase}
.source-count{font-weight:400;color:#606070;margin-left:.5rem}
.source-more{display:block;margin:.25rem 1.5rem 1rem;padding:.35rem .75rem;border-radius:6px;border:1px solid #0f3460;background:transparent;color:#a0a0b0;font-size:.75rem;cursor:pointer}
.source-more:hover{border-color:#e94560;color:#e94560}]]

STATIC["app.js"] = [=[const grid = document.getElementById("grid");
const search = document.getElementById("search");
const tagBar = document.getElementById("tag-bar");
const empty = document.getElementById("empty");
const appEl = document.getElementById("app");

let activeTag = null;

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
    var img = document.createElement("img");
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
    tags.forEach(function(t) {
      const tag = document.createElement("span");
      tag.className = "tag";
      tag.textContent = t;
      tagsEl.appendChild(tag);
    });
    card.appendChild(tagsEl);
  }

  if (onDelete) {
    var del = document.createElement("button");
    del.className = "card-delete";
    del.title = "Uninstall";
    del.textContent = "\xD7";
    del.onclick = function(e) { e.stopPropagation(); onDelete(); };
    card.appendChild(del);
  }

  if (onImport) {
    var imp = document.createElement("button");
    imp.className = "card-import";
    imp.title = "Open in conversation";
    imp.textContent = "Open";
    imp.onclick = function(e) {
      e.stopPropagation();
      imp.disabled = true;
      imp.textContent = "…";
      onImport(function(err) {
        imp.disabled = false;
        imp.textContent = err ? "!" : "Open";
        if (err) imp.title = "Error: " + err;
      });
    };
    card.appendChild(imp);
  }

  return card;
}

// ── Installed section ─────────────────────────────────────────────────────

function renderApps(apps) {
  grid.innerHTML = "";
  empty.hidden = apps.length > 0;
  apps.forEach(function(app) {
    grid.appendChild(makeCard(
      app,
      function() { if (app.id) window.location.href = "/launch/" + encodeURIComponent(app.id); },
      function() {
        if (!confirm("Uninstall \u201c" + (app.name || "this app") + "\u201d?")) return;
        fetch("/api/apps/" + encodeURIComponent(app.id), { method: "DELETE" })
          .then(function(r) { if (r.ok) refresh(); else r.text().then(function(t) { alert("Uninstall failed: " + t); }); });
      }
    ));
  });
}

function renderTagBar(apps) {
  const tags = {};
  apps.forEach(function(app) {
    (app.tags || []).forEach(function(t) { tags[t] = (tags[t] || 0) + 1; });
  });
  tagBar.innerHTML = "";
  var btn = document.createElement("button");
  btn.className = "tag-btn" + (activeTag === null ? " active" : "");
  btn.textContent = "All";
  btn.onclick = function() { activeTag = null; refresh(); };
  tagBar.appendChild(btn);
  Object.keys(tags).sort().forEach(function(t) {
    var b = document.createElement("button");
    b.className = "tag-btn" + (activeTag === t ? " active" : "");
    b.textContent = t + " (" + tags[t] + ")";
    b.onclick = function() { activeTag = (activeTag === t) ? null : t; refresh(); };
    tagBar.appendChild(b);
  });
}

function refresh() {
  var q = search.value.trim();
  var url = "/api/apps";
  var params = [];
  if (activeTag) params.push("tag=" + encodeURIComponent(activeTag));
  if (q) params.push("q=" + encodeURIComponent(q));
  if (params.length) url += "?" + params.join("&");

  fetch(url).then(function(r) { return r.json(); }).then(function(data) {
    renderApps(data.apps || []);
    if (!q && !activeTag) renderTagBar(data.apps || []);
  });
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

  var offset = 0;
  var total = 0;
  var generation = 0;
  var LIMIT = 200;

  function loadPage(q) {
    var gen = generation;
    var url = "/api/sources/" + encodeURIComponent(src.id) + "/discover?limit=" + LIMIT + "&offset=" + offset;
    if (q) url += "&q=" + encodeURIComponent(q);
    fetch(url).then(function(r) { return r.json(); }).then(function(data) {
      if (gen !== generation) return;
      total = data.total || 0;
      var entries = data.entries || [];
      entries.forEach(function(e) {
        var launchUrl = "/launch/" + encodeURIComponent(src.id) + "?entry=" + encodeURIComponent(e.id);
        var importUrl = "/api/import-card?source=" + encodeURIComponent(src.id) + "&entry=" + encodeURIComponent(e.id);
        sgrid.appendChild(makeCard(e, function() { window.location.href = launchUrl; }, null, function(done) {
          fetch(importUrl, { method: "POST" }).then(function(r) { return r.json(); }).then(function(data) {
            if (data.launch_url) { window.location.href = data.launch_url; }
            else { done(data.error || "unknown error"); }
          }).catch(function(err) { done(String(err)); });
        }));
      });
      offset += entries.length;
      count.textContent = "(" + offset + " of " + total + ")";
      more.hidden = offset >= total;
      more.textContent = "Load more \u2014 " + (total - offset) + " remaining";
    });
  }

  more.onclick = function() { loadPage(search.value.trim()); };

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

var sourceSections = [];

function loadSources() {
  fetch("/api/sources").then(function(r) { return r.json(); }).then(function(data) {
    (data.sources || []).forEach(function(src) {
      var sec = makeSourceSection(src);
      sourceSections.push(sec);
      appEl.appendChild(sec.el);
      sec.loadPage("");
    });
  });
}

function refreshAll() {
  var q = search.value.trim();
  refresh();
  sourceSections.forEach(function(sec) { sec.reset(q); });
}

// ── File import (button + drag-drop) ──────────────────────────────────────

const newCardBtn = document.getElementById("new-card-btn");
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

function uploadPng(file, onDone) {
  file.arrayBuffer().then(function(buf) {
    return fetch("/api/import-card/upload", {
      method: "POST",
      headers: { "Content-Type": "image/png" },
      body: buf,
    });
  }).then(function(r) {
    return r.json().then(function(data) { return { ok: r.ok, data: data }; });
  }).then(function(result) {
    if (result.ok && result.data.launch_url) {
      clearImportError();
      onDone(null);
      refresh();
    } else {
      onDone(result.data.error || "Import failed");
    }
  }).catch(function(err) {
    onDone(String(err));
  });
}

function importFiles(files) {
  clearImportError();
  var pngs = [];
  for (var i = 0; i < files.length; i++) {
    var f = files[i];
    if (f.type === "image/png" || f.name.slice(-4).toLowerCase() === ".png") {
      pngs.push(f);
    }
  }
  if (!pngs.length) { showImportError("No PNG files found in the dropped items."); return; }
  var errors = [];
  var remaining = pngs.length;
  pngs.forEach(function(f) {
    uploadPng(f, function(err) {
      if (err) errors.push(f.name + ": " + err);
      remaining--;
      if (remaining === 0 && errors.length) {
        showImportError(errors.join(" | "));
      }
    });
  });
}

newCardBtn.addEventListener("click", function() {
  clearImportError();
  newCardBtn.disabled = true;
  newCardBtn.textContent = "Creating…";
  fetch("/api/new-card", { method: "POST" })
    .then(function(r) { return r.json().then(function(d) { return { ok: r.ok, data: d }; }); })
    .then(function(result) {
      newCardBtn.disabled = false;
      newCardBtn.textContent = "New Card";
      if (result.ok && result.data.launch_url) {
        window.location.href = result.data.launch_url;
      } else {
        showImportError(result.data.error || "Failed to create card");
      }
    })
    .catch(function(err) {
      newCardBtn.disabled = false;
      newCardBtn.textContent = "New Card";
      showImportError(String(err));
    });
});

importBtn.addEventListener("click", function() {
  clearImportError();
  importFile.value = "";
  importFile.click();
});

importFile.addEventListener("change", function() {
  if (importFile.files && importFile.files.length) {
    importFiles(importFile.files);
  }
});

document.addEventListener("dragover", function(e) { e.preventDefault(); });

document.addEventListener("drop", function(e) {
  e.preventDefault();
  if (e.dataTransfer && e.dataTransfer.files && e.dataTransfer.files.length) {
    importFiles(e.dataTransfer.files);
  }
});

search.addEventListener("input", refreshAll);
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

local function serve_static(req, res)
	local path = req.path or "/"
	local name, ext
	if path == "/" then
		name, ext = "index.html", "html"
	elseif path == "/app.js" then
		name, ext = "app.js", "js"
	elseif path == "/style.css" then
		name, ext = "style.css", "css"
	else
		return nil
	end
	local content = STATIC[name]
	if not content then return nil end
	res.status = 200
	res.headers["Content-Type"] = { CONTENT_TYPES[ext] or "application/octet-stream" }
	res.body = content
	return true
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
	return '"' .. q:gsub('"', '""') .. '"'
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
	if has_q and has_tag then args[1] = tag;          args[2] = fts_phrase(q); return FROM_Q_TAG, args end
	if has_q            then args[1] = fts_phrase(q);                         return FROM_Q,     args end
	if has_tag          then args[1] = tag;                                   return FROM_TAG,   args end
	return FROM_NONE, args
end

local function collect_rows(iter)
	if not iter then return {} end
	local results = {}
	while true do
		local id, name, path, manifest_json, tags_json, installed_at = iter()
		if not id then break end
		local tags = json.decode(tags_json) or {}
		local manifest = json.decode(manifest_json) or {}
		local meta = manifest.meta or {}
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
		local c = citer()
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
		if k then
			-- Minimal percent-decode for common characters.
			v = v:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
			v = v:gsub("+", " ")
			params[k] = v
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
local function get_source_discover(caps, source_id, q, limit, offset)
	local source_map = caps._source_map
	-- Percent-decode the source id from the path segment.
	local decoded_id = source_id:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
	local src = source_map[decoded_id]
	if not src then
		return nil, { status = 404, message = "source not found: " .. decoded_id }
	end
	local params = { q = q, limit = limit, offset = offset }
	local resp = src.discover(params)
	-- Rewrite thumb_url entries to route through this server's thumb proxy.
	if src.handler and resp and resp.entries then
		local encoded_src_id = decoded_id:gsub("[^%w%-_%.~]",
			function(c) return ("%%%02X"):format(c:byte()) end)
		for _, entry in ipairs(resp.entries) do
			if entry.id then
				local encoded_entry_id = tostring(entry.id):gsub("[^%w%-_%.~]",
					function(c) return ("%%%02X"):format(c:byte()) end)
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
	local stdout_cap = caps.stdout
	local stderr_cap = caps.stderr
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

	local svc = service.create(caps_ext, methods, descriptors)

	-- ── Thumb proxy ────────────────────────────────────────────────────────
	-- Binary passthrough — cannot use the service JSON layer.
	-- Path: GET /api/sources/:source_id/thumb/:entry_id
	local function handle_thumb(req, res)
		local path = req.path or ""
		local thumb_src_id, thumb_entry_id = path:match("^/api/sources/([^/]+)/thumb/(.+)$")
		if not thumb_src_id then return nil end
		thumb_src_id   = thumb_src_id:gsub("%%(%x%x)",   function(h) return string.char(tonumber(h, 16)) end)
		thumb_entry_id = thumb_entry_id:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
		local src = source_map[thumb_src_id]
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
			if serve_static(req, res) then return true end
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
