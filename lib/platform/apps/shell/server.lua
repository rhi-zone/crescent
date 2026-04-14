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

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local json = require("lib.format.json")
local png = require("lib.png")
local base64 = require("lib.base64")

local M = {}

-- ── Helpers ─────────────────────────────────────────────────────────────────

local function parse_target(target)
	local qpos = target:find("?", 1, true)
	if not qpos then return target, {} end
	local path = target:sub(1, qpos - 1)
	local qs = target:sub(qpos + 1)
	local params = {}
	for kv in qs:gmatch("[^&]+") do
		local eq = kv:find("=", 1, true)
		if eq then
			params[kv:sub(1, eq - 1)] = kv:sub(eq + 1)
		else
			params[kv] = ""
		end
	end
	return path, params
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

function M.create(caps, opts)
	opts = opts or {}

	-- Static file serving.
	local ok_static, static_serve = false, nil
	if not opts.no_static then
		local static_dir = opts.static_dir or "static"
		ok_static, static_serve = pcall(function()
			return require("lib.http.router.static").router(static_dir)
		end)
	end

	local function handler(req, res)
		local req_path, params = parse_target(req.target)
		local key = req.method .. " " .. req_path
		local route = routes[key]
		if route then
			local body = read_json_body(req)
			return route(caps, params, body, res)
		end
		-- Static files.
		if ok_static then
			req.path = req_path
			return static_serve(req, res)
		end
	end

	return { handler = handler }
end

function M.start(caps, opts)
	opts = opts or {}
	local app = M.create(caps, opts)
	local http_server = require("lib.http.server")
	local port = opts.port or 7862
	return http_server.server(app.handler, port)
end

return M
