-- lib/platform/apps/export_ccv2/server.lua
-- CCv2 export app — HTTP wrappers around lib/formats/ccv2/adapters/export.lua.
--
-- Endpoints:
--   POST /api/export/json — {card, lorebook?} → CCv2 JSON envelope
--   POST /api/export/png  — {card, lorebook?, source_png?} → base64 PNG with chara chunk

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local json = require("lib.format.json")
local base64 = require("lib.encode.base64")
local export = require("lib.formats.ccv2.adapters.export")

local M = {}

-- ── Helpers ─────────────────────────────────────────────────────────────────

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
	if not req.body or #req.body == 0 then return nil end
	local ok, val = pcall(json.decode, req.body)
	if not ok then return nil end
	return val
end

-- ── Endpoints ───────────────────────────────────────────────────────────────

local function api_export_json(_caps, req, res)
	local body = read_json_body(req)
	if not body or not body.card then
		return json_err(res, 400, "card required")
	end
	local result, err = export.to_json(body.card, body.lorebook)
	if not result then
		return json_err(res, 422, err)
	end
	return json_ok(res, { json = result })
end

local function api_export_png(_caps, req, res)
	local body = read_json_body(req)
	if not body or not body.card then
		return json_err(res, 400, "card required")
	end
	-- Decode source PNG from base64 if provided
	local source_png
	if body.source_png then
		local decoded, b64_err = base64.decode(body.source_png)
		if not decoded then
			return json_err(res, 400, "invalid source_png base64: " .. tostring(b64_err))
		end
		source_png = decoded
	end
	local result, err = export.to_png(body.card, body.lorebook, source_png)
	if not result then
		return json_err(res, 422, err)
	end
	-- Return the PNG as base64
	return json_ok(res, { png = base64.encode(result) })
end

-- ── Router ──────────────────────────────────────────────────────────────────

local routes = {
	["POST /api/export/json"] = api_export_json,
	["POST /api/export/png"]  = api_export_png,
}

function M.create(caps)
	local function handler(req, res)
		local key = req.method .. " " .. req.target
		local route = routes[key]
		if route then
			return route(caps, req, res)
		end
	end
	return { handler = handler }
end

return M
