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
--
-- Caps:
--   caps.index_db — readonly SQLite database (app index)
--   caps.sources  — optional array of { id, name, discover(params)->resp }
--   caps.self     — app metadata (optional, for reading static files)

if package and not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local json = require("lib.format.json")

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
  </header>
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
  var loading = false;
  var LIMIT = 200;

  function loadPage(q) {
    if (loading) return;
    loading = true;
    var url = "/api/sources/" + encodeURIComponent(src.id) + "/discover?limit=" + LIMIT + "&offset=" + offset;
    if (q) url += "&q=" + encodeURIComponent(q);
    fetch(url).then(function(r) { return r.json(); }).then(function(data) {
      loading = false;
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

  return { el: section, loadPage: loadPage };
}

function loadSources() {
  fetch("/api/sources").then(function(r) { return r.json(); }).then(function(data) {
    (data.sources || []).forEach(function(src) {
      var sec = makeSourceSection(src);
      appEl.appendChild(sec.el);
      sec.loadPage("");
    });
  });
}

search.addEventListener("input", refresh);
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

local function serve_static(res, name, ext)
	local content = STATIC[name]
	if not content then return false end
	res.status = 200
	res.headers["Content-Type"] = { CONTENT_TYPES[ext] or "application/octet-stream" }
	res.body = content
	return true
end

local function json_ok(res, data)
	res.status = 200
	res.headers["Content-Type"] = { CONTENT_TYPES.json }
	res.body = json.encode(data)
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

-- ── Router ─────────────────────────────────────────────────────────────────

function M.create(caps)
	local db = caps.index_db
	local source_map = build_source_map(caps.sources)
	local sources_list = caps.sources or {}

	local function handler(req, res)
		local path = req.path or "/"
		local method = req.method or "GET"

		-- Static files.
		if method == "GET" then
			if path == "/" then return serve_static(res, "index.html", "html") end
			if path == "/app.js" then return serve_static(res, "app.js", "js") end
			if path == "/style.css" then return serve_static(res, "style.css", "css") end
		end

		-- API: list/search apps. Paginated (server-side LIMIT/OFFSET + COUNT).
		-- Client supplies ?limit & ?offset; server clamps limit to DEFAULT/MAX
		-- so a bad client can't request "limit=1000000" and force a full scan.
		if method == "GET" and path:find("^/api/apps") then
			local qs = req.query or path:match("%?(.+)$")
			local params = parse_query(qs)
			local limit_raw = tonumber(params.limit) or 200
			local offset_raw = tonumber(params.offset) or 0
			local limit  = math.max(1, math.min(500, limit_raw))
			local offset = math.max(0, offset_raw)
			local apps, total = query_apps(db, params.tag, params.q, limit, offset)
			return json_ok(res, {
				total = total,
				limit = limit,
				offset = offset,
				apps = apps,
			})
		end

		-- API: list registered source adapters.
		if method == "GET" and path == "/api/sources" then
			local list = {}
			for i = 1, #sources_list do
				local s = sources_list[i]
				list[i] = { id = s.id, name = s.name }
			end
			return json_ok(res, { sources = list })
		end

		-- API: proxy /discover to a source adapter.
		-- Path: /api/sources/<id>/discover[?params]
		if method == "GET" then
			local src_id = path:match("^/api/sources/([^/]+)/discover")
			if src_id then
				-- Percent-decode the source id from the path.
				src_id = src_id:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
				local src = source_map[src_id]
				if not src then
					res.status = 404
					res.headers["Content-Type"] = { "text/plain; charset=utf-8" }
					res.body = "source not found: " .. src_id
					return true
				end
				local qs = req.query or path:match("%?(.+)$")
				local params = parse_query(qs)
				local resp = src.discover(params)
				return json_ok(res, resp)
			end
		end
	end

	return { handler = handler }
end

-- Expose for testing.
M._parse_query = parse_query
M._STATIC = STATIC

return M
