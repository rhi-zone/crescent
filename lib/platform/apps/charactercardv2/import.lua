-- lib/platform/apps/charactercardv2/import.lua
-- CCv2 import entrypoint — HTTP wrappers around lib/formats/ccv2/adapters/import.lua.
--
-- Endpoints:
--   POST /api/import/png  — raw PNG body → parsed card + lorebook count
--   POST /api/import/json — raw JSON body → parsed card + lorebook count

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local json = require("lib.format.json")
local import = require("lib.formats.ccv2.adapters.import")

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

local function lorebook_count(result)
	if not result.lorebook then return 0 end
	return #result.lorebook
end

-- ── Endpoints ───────────────────────────────────────────────────────────────

local function api_import_png(_caps, req, res)
	if not req.body or #req.body == 0 then
		return json_err(res, 400, "empty body")
	end
	local result, err = import.from_png(req.body)
	if not result then
		return json_err(res, 422, err)
	end
	return json_ok(res, { card = result.card, lorebook_count = lorebook_count(result) })
end

local function api_import_json(_caps, req, res)
	if not req.body or #req.body == 0 then
		return json_err(res, 400, "empty body")
	end
	local result, err = import.from_json(req.body)
	if not result then
		return json_err(res, 422, err)
	end
	return json_ok(res, { card = result.card, lorebook_count = lorebook_count(result) })
end

-- ── Router ──────────────────────────────────────────────────────────────────

local routes = {
	["POST /api/import/png"]  = api_import_png,
	["POST /api/import/json"] = api_import_json,
}

function M.create(caps)
	local function handler(req, res)
		local key = req.method .. " " .. (req.path or "/")
		local route = routes[key]
		if route then
			return route(caps, req, res)
		end
	end
	return { handler = handler }
end

return M
