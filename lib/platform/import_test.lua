-- lib/platform/import_test.lua
if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local import = require("lib.platform.import")
local index = require("lib.platform.index")
local png = require("lib.png")
local base64 = require("lib.base64")
local json = require("lib.format.json")
local compress = require("lib.compress")
local tar = require("lib.tar")

-- import_card requires system-zlib for deflate (pure-lua has inflate only).
local has_deflate = compress._tier == "system-zlib"
local function skip_no_zlib()
	if not has_deflate then T.skip("system-zlib not available (deflate required)") end
end

-- Build a minimal valid PNG with a chara tEXt chunk.
local function make_card_png(card_data)
	local card_json = json.encode(card_data)
	local chara_b64 = base64.encode(card_json)
	-- Minimal 1x1 white PNG chunks.
	local chunks = {
		{ type = "IHDR", data = "\0\0\0\1\0\0\0\1\8\2\0\0\0" },
		{ type = "IDAT", data = "\x78\x01\x62\x60\x60\x60\x00\x00\x00\x04\x00\x01" },
		{ type = "tEXt", data = png.build_text("chara", chara_b64) },
		{ type = "IEND", data = "" },
	}
	return png.write(chunks)
end

-- Fake runtime files.
local RUNTIME_FILES = {
	{ name = "server.lua", data = "return { create = function() end }" },
	{ name = "dom.lua", data = "return {}" },
}

-- Base runtime manifest (from the card app template).
local RUNTIME_MANIFEST = {
	name = "Character Card v2",
	version = "0.1.0",
	meta = { tags = { "charactercardv2", "ai", "llm", "roleplay", "chat" } },
	default_entry = "server",
	caps = {
		self = { type = "self" },
		conversations = { type = "db" },
		kv = { type = "kv", required = false },
		time = { type = "time" },
	},
	entry = {
		server = {
			main = "server.lua",
			caps = {
				server = { type = "http_server" },
				llm_api = { type = "http_client", required = false },
			},
		},
	},
}

T.describe("platform import", function()

	T.describe("extract_card_meta", function()
		T.it("extracts name, description, and tags", function()
			local png_bytes = make_card_png({
				data = {
					name = "Alice",
					description = "A friendly AI assistant",
					tags = { "helpful", "friendly" },
				},
			})
			local meta, chunks = import._extract_card_meta(png_bytes)
			T.ok(meta, "meta should not be nil")
			T.eq(meta.name, "Alice")
			T.eq(meta.description, "A friendly AI assistant")
			T.eq(#meta.tags, 2)
			T.eq(meta.tags[1], "helpful")
			T.eq(meta.tags[2], "friendly")
		end)

		T.it("handles missing tags gracefully", function()
			local png_bytes = make_card_png({
				data = { name = "Bob" },
			})
			local meta = import._extract_card_meta(png_bytes)
			T.ok(meta)
			T.eq(meta.name, "Bob")
			T.eq(#meta.tags, 0)
		end)

		T.it("handles top-level card format (no .data wrapper)", function()
			local png_bytes = make_card_png({
				name = "Charlie",
				description = "Top-level format",
			})
			local meta = import._extract_card_meta(png_bytes)
			T.ok(meta)
			T.eq(meta.name, "Charlie")
		end)

		T.it("returns error for non-PNG", function()
			local meta, err = import._extract_card_meta("not a png")
			T.ok(not meta)
			T.ok(err:find("PNG"))
		end)

		T.it("returns error for PNG without chara chunk", function()
			local chunks = {
				{ type = "IHDR", data = "\0\0\0\1\0\0\0\1\8\2\0\0\0" },
				{ type = "IDAT", data = "\x78\x01\x62\x60\x60\x60\x00\x00\x00\x04\x00\x01" },
				{ type = "IEND", data = "" },
			}
			local meta, err = import._extract_card_meta(png.write(chunks))
			T.ok(not meta)
			T.ok(err:find("chara"))
		end)
	end)

	T.describe("import_card", function()
		T.it("produces a valid app PNG with lua and lua-manifest chunks", function()
			skip_no_zlib()
			local written = {}
			local write_fn = function(path, data)
				written[path] = data
				return true
			end

			local png_bytes = make_card_png({
				data = {
					name = "Test Card",
					description = "A test",
					tags = { "test" },
				},
			})

			local app_path, manifest = import.import_card({
				png_bytes = png_bytes,
				runtime_files = RUNTIME_FILES,
				runtime_manifest = RUNTIME_MANIFEST,
				apps_dir = "/tmp/apps",
				write_fn = write_fn,
				timestamp = 1000000,
			})

			T.ok(app_path, "app_path should not be nil")
			T.ok(app_path:find("Test_Card"), "path should contain sanitized name: " .. app_path)
			T.ok(manifest)
			T.eq(manifest.name, "Test Card")
			T.eq(manifest.meta.name, "Test Card")
			T.eq(manifest.meta.description, "A test")

			-- Check tags: runtime tags + card tags, deduplicated.
			local tags = manifest.meta.tags
			T.ok(#tags >= 6, "should have runtime + card tags: " .. #tags)

			-- Verify the written PNG has lua and lua-manifest chunks.
			local out_bytes = written[app_path]
			T.ok(out_bytes, "file should have been written")
			local out_chunks = png.read(out_bytes)
			T.ok(out_chunks)

			-- lua-manifest chunk should be valid JSON matching the manifest.
			local lua_manifest_str = png.get_itxt(out_chunks, "lua-manifest")
			T.ok(lua_manifest_str, "lua-manifest chunk should exist")
			local lua_manifest = json.decode(lua_manifest_str)
			T.eq(lua_manifest.name, "Test Card")

			-- lua chunk should be base64(gzip(tar)).
			local lua_data = png.get_itxt(out_chunks, "lua")
			T.ok(lua_data, "lua chunk should exist")
			local gz = base64.decode(lua_data)
			T.ok(gz, "base64 decode should succeed")
			local tardata = compress.inflate(gz, { format = "gzip" })
			T.ok(tardata, "gzip decompress should succeed")
			local entries = tar.read(tardata)
			T.ok(entries, "tar read should succeed")

			-- Tarball should contain manifest.json + runtime files.
			local found_manifest = tar.get(entries, "manifest.json")
			T.ok(found_manifest, "tarball should contain manifest.json")
			local found_server = tar.get(entries, "server.lua")
			T.ok(found_server, "tarball should contain server.lua")
			local found_dom = tar.get(entries, "dom.lua")
			T.ok(found_dom, "tarball should contain dom.lua")

			-- Original chara chunk should be preserved.
			local chara = png.get_text(out_chunks, "chara")
			T.ok(chara, "chara chunk should be preserved")
		end)

		T.it("indexes the app when index is provided", function()
			skip_no_zlib()
			local written = {}
			local write_fn = function(path, data) written[path] = data; return true end
			local idx = index.open(":memory:")

			local png_bytes = make_card_png({
				data = { name = "Indexed Card", tags = { "indexed" } },
			})

			local app_path = import.import_card({
				png_bytes = png_bytes,
				runtime_files = RUNTIME_FILES,
				runtime_manifest = RUNTIME_MANIFEST,
				apps_dir = "/tmp/apps",
				write_fn = write_fn,
				timestamp = 2000000,
				index = idx,
			})

			T.ok(app_path)
			local all = idx:list()
			T.eq(#all, 1)
			T.eq(all[1].name, "Indexed Card")
			T.eq(all[1].path, app_path)
			idx:close()
		end)

		T.it("deduplicates tags from runtime and card", function()
			skip_no_zlib()
			local written = {}
			local write_fn = function(path, data) written[path] = data; return true end

			-- Card has a tag that overlaps with runtime.
			local png_bytes = make_card_png({
				data = { name = "Dupe Tags", tags = { "ai", "custom" } },
			})

			local _, manifest = import.import_card({
				png_bytes = png_bytes,
				runtime_files = RUNTIME_FILES,
				runtime_manifest = RUNTIME_MANIFEST,
				apps_dir = "/tmp/apps",
				write_fn = write_fn,
				timestamp = 3000000,
			})

			-- "ai" appears in both runtime and card tags — should appear once.
			local tag_count = {}
			for _, t in ipairs(manifest.meta.tags) do
				tag_count[t] = (tag_count[t] or 0) + 1
			end
			T.eq(tag_count["ai"], 1, "ai should appear exactly once")
			T.eq(tag_count["custom"], 1, "custom should appear exactly once")
		end)

		T.it("returns error for missing opts", function()
			local _, err = import.import_card()
			T.ok(err:find("opts"))
		end)

		T.it("returns error for missing png_bytes", function()
			local _, err = import.import_card({ runtime_files = {}, runtime_manifest = {}, apps_dir = "/x", write_fn = function() end, timestamp = 1 })
			T.ok(err:find("png_bytes"))
		end)
	end)

end)
