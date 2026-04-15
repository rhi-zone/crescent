-- lib/platform/apps/shell/server.lua
-- Shell app BFF backend.
--
-- Discovers character card PNGs in a configured directory and serves
-- a browseable grid. The frontend is a dumb terminal — all logic here.
--
-- Capabilities (injected via caps table):
--   caps.fs.list(path?)          -> string[] of filenames
--   caps.fs.read(path)           -> string | nil, err
--   caps.config.get(key)         -> value | nil (optional)

if package and not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local json = require("lib.format.json")
local png = require("lib.png")
local base64 = require("lib.base64")

local M = {}

-- ── Helpers ─────────────────────────────────────────────────────────────────

local function parse_query(qs)
	local params = {}
	if not qs then return params end
	for kv in qs:gmatch("[^&]+") do
		local eq = kv:find("=", 1, true)
		if eq then
			params[kv:sub(1, eq - 1)] = kv:sub(eq + 1)
		else
			params[kv] = ""
		end
	end
	return params
end

local function json_ok(res, data)
	res.status = 200
	res.headers["Content-Type"] = "application/json"
	res.body = json.encode(data)
	return true
end

local function json_err(res, status, msg)
	res.status = status
	res.headers["Content-Type"] = "application/json"
	res.body = json.encode({ error = msg })
	return true
end

local function read_json_body(req)
	if not req.body or #req.body == 0 then return {} end
	local ok, val = pcall(json.decode, req.body)
	if not ok then return nil end
	return val
end

-- url_decode: decode percent-encoded strings (e.g. %20 -> space).
local function url_decode(s)
	return s:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end)
end

-- ── Card extraction ─────────────────────────────────────────────────────────

-- extract_card_meta(png_bytes) -> table | nil
-- Reads a PNG's chara tEXt chunk, base64 decodes it, parses the JSON,
-- and returns a summary table with name, description, tags, has_lorebook.
local function extract_card_meta(png_bytes)
	local chunks, err = png.read(png_bytes)
	if not chunks then return nil end

	local raw = png.get_text(chunks, "chara")
	if not raw then return nil end

	-- chara chunk is base64-encoded JSON
	local decoded, b64err = base64.decode(raw)
	if not decoded then return nil end

	local ok, card = pcall(json.decode, decoded)
	if not ok or type(card) ~= "table" then return nil end

	-- CCv2 wraps data under .data; some formats use top-level
	local data = card.data or card

	return {
		name = data.name or "",
		description = data.description or "",
		tags = data.tags or {},
		has_lorebook = data.character_book ~= nil and data.character_book ~= false,
	}
end

-- ── API routes ──────────────────────────────────────────────────────────────

-- GET /api/cards — scan directory and return card metadata
local function api_get_cards(caps, _params, _body, res)
	local files, err = caps.fs.list()
	if not files then
		return json_err(res, 500, "failed to list directory: " .. tostring(err))
	end

	local cards = {}
	for _, filename in ipairs(files) do
		if filename:match("%.png$") or filename:match("%.PNG$") then
			local bytes, rerr = caps.fs.read(filename)
			if bytes then
				local meta = extract_card_meta(bytes)
				if meta then
					meta.filename = filename
					cards[#cards + 1] = meta
				end
			end
		end
	end

	return json_ok(res, { cards = cards })
end

-- GET /api/card/thumbnail?filename=X — return raw PNG
local function api_get_thumbnail(caps, params, _body, res)
	local filename = params.filename
	if not filename then
		return json_err(res, 400, "missing filename parameter")
	end
	filename = url_decode(filename)

	-- Reject path traversal
	if filename:find("/") or filename:find("\\") or filename:find("%.%.") then
		return json_err(res, 400, "invalid filename")
	end

	local bytes, err = caps.fs.read(filename)
	if not bytes then
		return json_err(res, 404, "file not found: " .. tostring(err))
	end

	res.status = 200
	res.headers["Content-Type"] = "image/png"
	res.body = bytes
	return true
end

-- POST /api/launch — return launch info for a card
local function api_post_launch(caps, _params, body, res)
	if not body or not body.filename then
		return json_err(res, 400, "missing filename in body")
	end

	local filename = body.filename
	-- Reject path traversal
	if filename:find("/") or filename:find("\\") or filename:find("%.%.") then
		return json_err(res, 400, "invalid filename")
	end

	-- Verify the file exists
	local bytes, err = caps.fs.read(filename)
	if not bytes then
		return json_err(res, 404, "file not found: " .. tostring(err))
	end

	return json_ok(res, {
		app = "card",
		card_path = filename,
		port = 7861,
	})
end

-- ── Router ──────────────────────────────────────────────────────────────────

local routes = {
	["GET /api/cards"]          = api_get_cards,
	["GET /api/card/thumbnail"] = api_get_thumbnail,
	["POST /api/launch"]        = api_post_launch,
}

-- MIME type guessing (minimal, for static serving).
local mime_types = {
	html = "text/html", css = "text/css", js = "application/javascript",
	json = "application/json", png = "image/png", jpg = "image/jpeg",
	svg = "image/svg+xml", ico = "image/x-icon", txt = "text/plain",
}

local function guess_mime(path)
	local ext = path:match("%.([^%.]+)$")
	return ext and mime_types[ext:lower()] or "application/octet-stream"
end

function M.create(caps, opts)
	opts = opts or {}

	local function handler(req, res)
		local req_path = req.path or "/"
		local params = parse_query(req.query)
		local key = req.method .. " " .. req_path
		local route = routes[key]
		if route then
			local body = read_json_body(req)
			return route(caps, params, body, res)
		end
		-- Static files via caps.self (no raw filesystem access).
		if caps.self then
			local asset_path = "static" .. req_path
			if req_path == "/" then asset_path = "static/index.html" end
			local content = caps.self.entry(asset_path)
			if content then
				res.status = 200
				res.headers["Content-Type"] = guess_mime(asset_path)
				res.body = content
				return true
			end
		end
	end

	return { handler = handler }
end

return M
