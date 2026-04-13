-- lib/formats/ccv2/adapters/export_test.lua

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local import = require("lib.formats.ccv2.adapters.import")
local export = require("lib.formats.ccv2.adapters.export")
local json = require("lib.format.json")
local lorebook = require("lib.formats.ccv2.lorebook")

T.describe("export: to_json", function()
	T.it("produces valid CCv2 JSON", function()
		local card = { name = "Bob", description = "Test" }
		local str, err = export.to_json(card)
		T.ok(str, err)
		local parsed = json.decode(str)
		T.eq(parsed.spec, "chara_card_v2")
		T.eq(parsed.data.name, "Bob")
	end)

	T.it("attaches lorebook as character_book", function()
		local card = { name = "Bob" }
		local entries = {
			lorebook.normalize({ key = { "sword" }, content = "Sharp blade." }),
		}
		local str = assert(export.to_json(card, entries))
		local parsed = json.decode(str)
		T.ok(parsed.data.character_book)
		T.eq(#parsed.data.character_book.entries, 1)
		T.eq(parsed.data.character_book.entries[1].content, "Sharp blade.")
	end)

	T.it("omits character_book when no lorebook", function()
		local str = assert(export.to_json({ name = "Bob" }))
		local parsed = json.decode(str)
		T.eq(parsed.data.character_book, nil)
	end)

	T.it("does not mutate input table", function()
		local card = { name = "Bob", character_book = "original" }
		export.to_json(card)
		T.eq(card.character_book, "original")
	end)
end)

T.describe("export: to_png", function()
	T.it("produces valid PNG", function()
		local bytes, err = export.to_png({ name = "PngBob" })
		T.ok(bytes, err)
		T.eq(bytes:sub(1, 4), "\137PNG")
	end)

	T.it("round-trips through import", function()
		local entries = {
			lorebook.normalize({ key = { "magic" }, content = "Sparkles." }),
		}
		local bytes = assert(export.to_png({ name = "Round", description = "trip" }, entries))
		local result = assert(import.from_png(bytes))
		T.eq(result.card.name, "Round")
		T.eq(result.card.description, "trip")
		T.ok(result.lorebook)
		T.eq(#result.lorebook, 1)
		T.eq(result.lorebook[1].content, "Sparkles.")
	end)
end)

T.describe("export: JSON round-trip", function()
	T.it("import -> export -> import preserves data", function()
		local original_json = json.encode({
			spec = "chara_card_v2", spec_version = "2.0",
			data = {
				name = "Alice", description = "Original",
				personality = "kind", scenario = "forest",
				first_mes = "Hi!", mes_example = "",
				character_book = {
					entries = {
						{ keys = { "tree" }, content = "Tall oak." },
					},
				},
			},
		})
		local r1 = assert(import.from_json(original_json))
		T.eq(r1.card.name, "Alice")
		T.ok(r1.lorebook)
		local exported = assert(export.to_json(r1.card, r1.lorebook))
		local r2 = assert(import.from_json(exported))
		T.eq(r2.card.name, "Alice")
		T.eq(r2.card.description, "Original")
		T.ok(r2.lorebook)
		T.eq(r2.lorebook[1].content, "Tall oak.")
	end)
end)
