if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local json = require("lib.format.json")
local card_mod = require("lib.formats.ccv2.card")
local server = require("lib.platform.apps.charactercardv2.import")

-- ── Test helpers ────────────────────────────────────────────────────────────

local function make_req(method, target, body)
	return { method = method, target = target, body = body }
end

local function make_res()
	return { status = nil, headers = {}, body = nil }
end

local function call(app, method, target, body)
	local req = make_req(method, target, body)
	local res = make_res()
	app.handler(req, res)
	return res, res.body and json.decode(res.body)
end

-- ── Setup ───────────────────────────────────────────────────────────────────

local caps = {}
local app = server.create(caps)

-- ── Test data ───────────────────────────────────────────────────────────────

local VALID_CARD_JSON = json.encode({
	spec = "chara_card_v2",
	spec_version = "2.0",
	data = {
		name = "TestChar",
		description = "A test character",
		personality = "Friendly",
		scenario = "",
		first_mes = "Hello!",
		mes_example = "",
	},
})

-- ── Import JSON tests ───────────────────────────────────────────────────────

T.describe("charactercardv2 import: POST /api/import/json", function()
	T.it("imports a valid V2 card", function()
		local res, body = call(app, "POST", "/api/import/json", VALID_CARD_JSON)
		T.eq(res.status, 200)
		T.ok(body.card)
		T.eq(body.card.name, "TestChar")
		T.eq(body.card.description, "A test character")
		T.eq(body.lorebook_count, 0)
	end)

	T.it("imports a V1 card", function()
		local v1 = json.encode({ name = "OldChar", description = "V1 format" })
		local res, body = call(app, "POST", "/api/import/json", v1)
		T.eq(res.status, 200)
		T.eq(body.card.name, "OldChar")
		T.eq(body.lorebook_count, 0)
	end)

	T.it("errors on empty body", function()
		local res, body = call(app, "POST", "/api/import/json", "")
		T.eq(res.status, 400)
		T.ok(body.error)
	end)

	T.it("errors on invalid JSON", function()
		local res, body = call(app, "POST", "/api/import/json", "not json{{{")
		T.eq(res.status, 422)
		T.ok(body.error)
	end)

	T.it("errors on card with no name", function()
		local bad = json.encode({ spec = "chara_card_v2", spec_version = "2.0", data = { description = "no name" } })
		local res, body = call(app, "POST", "/api/import/json", bad)
		T.eq(res.status, 422)
		T.ok(body.error)
	end)
end)

-- ── Import PNG tests ────────────────────────────────────────────────────────

T.describe("charactercardv2 import: POST /api/import/png", function()
	T.it("imports a valid PNG with chara chunk", function()
		local card_data = { name = "PngChar", description = "From PNG", first_mes = "Hi" }
		local png_bytes = card_mod.to_png(card_data)
		T.ok(png_bytes)

		local res, body = call(app, "POST", "/api/import/png", png_bytes)
		T.eq(res.status, 200)
		T.ok(body.card)
		T.eq(body.card.name, "PngChar")
		T.eq(body.card.description, "From PNG")
		T.eq(body.lorebook_count, 0)
	end)

	T.it("errors on empty body", function()
		local res, body = call(app, "POST", "/api/import/png", "")
		T.eq(res.status, 400)
		T.ok(body.error)
	end)

	T.it("errors on invalid PNG", function()
		local res, body = call(app, "POST", "/api/import/png", "not a png file")
		T.eq(res.status, 422)
		T.ok(body.error)
	end)
end)

-- ── Unknown route ───────────────────────────────────────────────────────────

T.describe("charactercardv2 import: unknown routes", function()
	T.it("returns nil for unknown routes", function()
		local req = make_req("GET", "/api/unknown", nil)
		local res = make_res()
		local handled = app.handler(req, res)
		T.eq(handled, nil)
	end)
end)
