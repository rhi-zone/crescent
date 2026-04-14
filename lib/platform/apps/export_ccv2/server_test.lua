if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local json = require("lib.format.json")
local base64 = require("lib.encode.base64")
local card_mod = require("lib.formats.ccv2.card")
local server = require("lib.platform.apps.export_ccv2.server")

-- ── Test helpers ────────────────────────────────────────────────────────────

local function make_req(method, target, body)
	return { method = method, target = target, body = body }
end

local function make_res()
	return { status = nil, headers = {}, body = nil }
end

local function call(app, method, target, body_table)
	local req = make_req(method, target, body_table and json.encode(body_table))
	local res = make_res()
	app.handler(req, res)
	return res, res.body and json.decode(res.body)
end

-- ── Setup ───────────────────────────────────────────────────────────────────

local caps = {}
local app = server.create(caps)

-- ── Test data ───────────────────────────────────────────────────────────────

local CARD = {
	name = "ExportChar",
	description = "A character to export",
	personality = "Bold",
	scenario = "",
	first_mes = "Greetings!",
	mes_example = "",
}

-- ── Export JSON tests ───────────────────────────────────────────────────────

T.describe("export_ccv2: POST /api/export/json", function()
	T.it("exports a card to CCv2 JSON envelope", function()
		local res, body = call(app, "POST", "/api/export/json", { card = CARD })
		T.eq(res.status, 200)
		T.ok(body.json)
		-- Parse the returned JSON string to verify it's a proper V2 envelope
		local envelope = json.decode(body.json)
		T.eq(envelope.spec, "chara_card_v2")
		T.eq(envelope.spec_version, "2.0")
		T.eq(envelope.data.name, "ExportChar")
		T.eq(envelope.data.description, "A character to export")
	end)

	T.it("errors when card is missing", function()
		local res, body = call(app, "POST", "/api/export/json", { something = "else" })
		T.eq(res.status, 400)
		T.ok(body.error)
	end)

	T.it("errors on empty body", function()
		local req = make_req("POST", "/api/export/json", "")
		local res = make_res()
		app.handler(req, res)
		T.eq(res.status, 400)
	end)
end)

-- ── Export PNG tests ────────────────────────────────────────────────────────

T.describe("export_ccv2: POST /api/export/png", function()
	T.it("exports a card to PNG (no source)", function()
		local res, body = call(app, "POST", "/api/export/png", { card = CARD })
		T.eq(res.status, 200)
		T.ok(body.png)
		-- Decode the base64 PNG and verify it round-trips
		local png_bytes = base64.decode(body.png)
		T.ok(png_bytes)
		T.eq(png_bytes:sub(1, 4), "\137PNG")
		-- Parse it back
		local parsed, err = card_mod.from_png(png_bytes)
		T.ok(parsed, err)
		T.eq(parsed.name, "ExportChar")
	end)

	T.it("exports with a source PNG", function()
		-- Create a source PNG first
		local source_data = { name = "Original", first_mes = "Old" }
		local source_png = card_mod.to_png(source_data)
		T.ok(source_png)
		local source_b64 = base64.encode(source_png)

		local res, body = call(app, "POST", "/api/export/png", {
			card = CARD,
			source_png = source_b64,
		})
		T.eq(res.status, 200)
		T.ok(body.png)
		local png_bytes = base64.decode(body.png)
		local parsed, err = card_mod.from_png(png_bytes)
		T.ok(parsed, err)
		T.eq(parsed.name, "ExportChar") -- New card data, not "Original"
	end)

	T.it("errors on invalid source_png base64", function()
		local res, body = call(app, "POST", "/api/export/png", {
			card = CARD,
			source_png = "!!!not-base64!!!",
		})
		T.eq(res.status, 400)
		T.ok(body.error)
	end)

	T.it("errors when card is missing", function()
		local res, body = call(app, "POST", "/api/export/png", { source_png = "AAAA" })
		T.eq(res.status, 400)
		T.ok(body.error)
	end)
end)

-- ── Unknown route ───────────────────────────────────────────────────────────

T.describe("export_ccv2: unknown routes", function()
	T.it("returns nil for unknown routes", function()
		local req = make_req("GET", "/api/unknown", nil)
		local res = make_res()
		local handled = app.handler(req, res)
		T.eq(handled, nil)
	end)
end)
