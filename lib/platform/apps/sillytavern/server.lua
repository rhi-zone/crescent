-- lib/platform/apps/sillytavern/server.lua
-- SillyTavern source adapter — exposes GET /discover for the library's
-- per-source section model.
--
-- Reads ~/SillyTavern/public/characters/ in place; no import or conversion.
-- For each PNG file the entry id is the filename, the name is the filename
-- without the .png suffix. No metadata parsing in this stub — a later
-- iteration can read CCv2 iTXt chunks for description/tags/thumbnails.
--
-- Discovery protocol (GET /discover):
--   Query params: q (substring search), limit (default 200, max 500),
--                 offset (default 0)
--   Response: { source_name, total, limit, offset, entries: [entry] }
--   entry: { id, name, description, tags, thumb_url }
--
-- Caps:
--   caps.characters — readonly fs (root = ~/SillyTavern/public/characters)
--   caps.http_server (wired externally; handler is returned, not started here)

if package and not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local json = require("lib.format.json")

local M = {}

-- ── Query string parser ────────────────────────────────────────────────────

--: (string | nil) -> { [string]: string }
local function parse_query(qs)
	local params = {} --: { [string]: string }
	if not qs or qs == "" then return params end
	for kv in qs:gmatch("[^&]+") do
		local k, v = kv:match("^([^=]+)=?(.*)")
		if k then
			v = v:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
			v = v:gsub("+", " ")
			params[k] = v
		end
	end
	return params
end

-- ── Helpers ────────────────────────────────────────────────────────────────

--: (string) -> string
local function name_from_file(filename)
	-- Strip any extension (e.g. "alice.png" → "alice", "bob.card.png" → "bob.card").
	return filename:match("^(.+)%.[^.]+$") or filename
end

--: (string, string | nil) -> boolean
local function matches(name, q)
	if not q or q == "" then return true end
	return name:lower():find(q:lower(), 1, true) ~= nil
end

--: (http_res, number, string) -> nil
local function plain(res, status, body)
	res.status = status
	res.headers["Content-Type"] = { "text/plain; charset=utf-8" }
	res.body = body
end

--: (http_res, unknown) -> true
local function json_ok(res, data)
	res.status = 200
	res.headers["Content-Type"] = { "application/json" }
	res.body = json.encode(data)
	return true
end

-- ── Handler ────────────────────────────────────────────────────────────────

function M.create(caps)
	local fs = caps.characters

	--: (http_req, http_res) -> nil
	local function handler(req, res)
		local path   = req.path   or "/"
		local method = req.method or "GET"

		if method ~= "GET" then
			plain(res, 405, "method not allowed")
			return
		end

		if not path:find("^/discover") then
			plain(res, 404, "not found")
			return
		end

		local qs = req.query or path:match("%?(.+)$")
		local params = parse_query(qs)
		local q       = params.q
		local limit   = math.max(1, math.min(500, tonumber(params.limit)  or 200))
		local offset  = math.max(0,               tonumber(params.offset) or 0)

		-- List the characters directory. Returns filenames only.
		local files, err = fs.list(".")
		if not files then
			json_ok(res, {
				source_name = "SillyTavern",
				total = 0, limit = limit, offset = offset, entries = {},
				error = "characters directory unavailable: " .. tostring(err),
			})
			return
		end

		-- Filter to PNG/WEBP/JPEG character card files and apply search.
		local matched = {} --: { [integer]: { id: string, name: string } }
		for i = 1, #files do
			local f = files[i]
			-- Accept .png / .webp / .jpeg / .jpg (CCv2 allows all image types)
			local ext = f:lower():match("%.([^.]+)$")
			if ext == "png" or ext == "webp" or ext == "jpeg" or ext == "jpg" then
				local name = name_from_file(f)
				if matches(name, q) then
					matched[#matched + 1] = { id = f, name = name }
				end
			end
		end

		-- Stable alphabetical order so pagination is consistent.
		table.sort(matched, function(a, b)
			return a.name:lower() < b.name:lower()
		end)

		local total = #matched

		-- Slice the page.
		local entries = {} --: { [integer]: unknown }
		local stop = math.min(offset + limit, total)
		for i = offset + 1, stop do
			local e = matched[i]
			entries[#entries + 1] = {
				id          = e.id,
				name        = e.name,
				description = nil,
				tags        = {},
				thumb_url   = nil,
			}
		end

		json_ok(res, {
			source_name = "SillyTavern",
			total   = total,
			limit   = limit,
			offset  = offset,
			entries = entries,
		})
	end

	return { handler = handler }
end

-- Expose for testing.
M._parse_query   = parse_query
M._name_from_file = name_from_file
M._matches        = matches

return M
