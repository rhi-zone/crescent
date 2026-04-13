-- lib/formats/ccv2/adapters/import_test.lua

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local import = require("lib.formats.ccv2.adapters.import")
local card_mod = require("lib.formats.ccv2.card")
local json = require("lib.format.json")

-- ── helpers ──────────────────────────────────────────────────────────────────

local function make_v2_json(overrides)
	local data = {
		spec = "chara_card_v2",
		spec_version = "2.0",
		data = {
			name = "Alice",
			description = "A test character",
			personality = "friendly",
			scenario = "testing",
			first_mes = "Hello!",
			mes_example = "",
		},
	}
	if overrides then
		for k, v in pairs(overrides) do data.data[k] = v end
	end
	return json.encode(data)
end

T.describe("import: from_json", function()
	T.it("extracts card data", function()
		local result, err = import.from_json(make_v2_json())
		T.ok(result, err)
		T.eq(result.card.name, "Alice")
		T.eq(result.card.description, "A test character")
	end)

	T.it("returns nil lorebook when no character_book", function()
		local result = assert(import.from_json(make_v2_json()))
		T.eq(result.lorebook, nil)
	end)

	T.it("extracts lorebook from character_book", function()
		local result = assert(import.from_json(make_v2_json({
			character_book = {
				entries = {
					{ keys = { "dragon" }, content = "Dragons breathe fire." },
					{ keys = { "elf" }, content = "Elves live long." },
				},
			},
		})))
		T.ok(result.lorebook)
		T.eq(#result.lorebook, 2)
		T.eq(result.lorebook[1].content, "Dragons breathe fire.")
	end)

	T.it("normalizes lorebook entries", function()
		local result = assert(import.from_json(make_v2_json({
			character_book = {
				entries = {
					{ keys = { "sword" }, content = "Sharp." },
				},
			},
		})))
		local e = result.lorebook[1]
		T.eq(e.enabled, true)
		T.eq(e.caseSensitive, false)
		T.eq(type(e.uid), "string")
	end)

	T.it("errors on invalid JSON", function()
		local result, err = import.from_json("{bad")
		T.fail(result)
		T.ok(err)
	end)

	T.it("errors on missing name", function()
		local result, err = import.from_json(json.encode({
			spec = "chara_card_v2", spec_version = "2.0",
			data = { description = "no name" },
		}))
		T.fail(result)
		T.ok(err)
	end)
end)

T.describe("import: from_png", function()
	T.it("round-trips through PNG", function()
		local card_data = { name = "PngCard", description = "from png" }
		local png_bytes = assert(card_mod.to_png(card_data))
		local result, err = import.from_png(png_bytes)
		T.ok(result, err)
		T.eq(result.card.name, "PngCard")
		T.eq(result.card.description, "from png")
	end)

	T.it("errors on invalid PNG", function()
		local result, err = import.from_png("not a png")
		T.fail(result)
		T.ok(err)
	end)
end)
