if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local json = require("lib.format.json")
local png_mod = require("lib.png")
local base64 = require("lib.base64")

-- ── Mock PNG builder ───────────────────────────────────────────────────────

-- Build a minimal valid PNG with a chara tEXt chunk containing base64-encoded
-- CCv2 JSON. The image data is a 1x1 pixel RGBA placeholder.
local function make_card_png(card_data)
	local card_json = json.encode({
		spec = "chara_card_v2",
		data = card_data,
	})
	local encoded = base64.encode(card_json)
	local chunks = {
		{ type = "IHDR", data = "\0\0\0\1\0\0\0\1\8\6\0\0\0" },  -- 1x1 RGBA
		{ type = "IDAT", data = "\0" },  -- placeholder
		{ type = "tEXt", data = png_mod.build_text("chara", encoded) },
		{ type = "IEND", data = "" },
	}
	return png_mod.write(chunks)
end

-- ── Mock fs cap ────────────────────────────────────────────────────────────

local function make_mock_fs(file_map)
	return {
		list = function(path)
			local result = {}
			for name, _ in pairs(file_map) do
				result[#result + 1] = name
			end
			table.sort(result)
			return result
		end,
		read = function(path)
			local content = file_map[path]
			if not content then return nil, "file not found: " .. tostring(path) end
			return content
		end,
	}
end

-- ── Request/response helpers ───────────────────────────────────────────────

local function make_req(method, target, body)
	-- Simulate the http_server cap's request shape: path + query, not target.
	local path, query = target, nil
	local qpos = target:find("?", 1, true)
	if qpos then
		path = target:sub(1, qpos - 1)
		query = target:sub(qpos + 1)
	end
	local req = { method = method, path = path, query = query, headers = {} }
	if body then
		req.body = json.encode(body)
		req.headers["content-type"] = { "application/json" }
	end
	return req
end

local function make_res()
	return { headers = {} }
end

local function call(app, method, target, body)
	local req = make_req(method, target, body)
	local res = make_res()
	app.handler(req, res)
	local data
	if res.body and res.headers["Content-Type"] == "application/json" then
		local ok, val = pcall(json.decode, res.body)
		if ok then data = val end
	end
	return res.status, data, res
end

-- ── Tests ──────────────────────────────────────────────────────────────────

local server = require("lib.platform.apps.shell.server")

T.describe("shell server — GET /api/cards", function()
	T.it("returns discovered cards", function()
		local card_bytes = make_card_png({
			name = "TestChar",
			description = "A test character for testing.",
			tags = { "fantasy", "test" },
			character_book = { entries = {} },
		})
		local fs = make_mock_fs({
			["character.png"] = card_bytes,
		})
		local app = server.create({ fs = fs }, { no_static = true })
		local status, data = call(app, "GET", "/api/cards")
		T.eq(status, 200)
		T.ok(data.cards, "cards array exists")
		T.eq(#data.cards, 1)
		T.eq(data.cards[1].filename, "character.png")
		T.eq(data.cards[1].name, "TestChar")
		T.eq(data.cards[1].description, "A test character for testing.")
		T.eq(data.cards[1].tags[1], "fantasy")
		T.eq(data.cards[1].tags[2], "test")
		T.eq(data.cards[1].has_lorebook, true)
	end)

	T.it("handles empty directory", function()
		local fs = make_mock_fs({})
		local app = server.create({ fs = fs }, { no_static = true })
		local status, data = call(app, "GET", "/api/cards")
		T.eq(status, 200)
		T.ok(data.cards, "cards array exists")
		T.eq(#data.cards, 0)
	end)

	T.it("skips non-PNG files", function()
		local card_bytes = make_card_png({
			name = "ValidCard",
			description = "Valid",
			tags = {},
		})
		local fs = make_mock_fs({
			["readme.txt"] = "not a png",
			["card.png"] = card_bytes,
			["data.json"] = "{}",
		})
		local app = server.create({ fs = fs }, { no_static = true })
		local status, data = call(app, "GET", "/api/cards")
		T.eq(status, 200)
		T.eq(#data.cards, 1)
		T.eq(data.cards[1].filename, "card.png")
	end)

	T.it("skips invalid PNGs", function()
		local valid = make_card_png({
			name = "GoodCard",
			description = "Works",
			tags = {},
		})
		local fs = make_mock_fs({
			["good.png"] = valid,
			["bad.png"] = "not a real png file",
		})
		local app = server.create({ fs = fs }, { no_static = true })
		local status, data = call(app, "GET", "/api/cards")
		T.eq(status, 200)
		T.eq(#data.cards, 1)
		T.eq(data.cards[1].filename, "good.png")
		T.eq(data.cards[1].name, "GoodCard")
	end)

	T.it("skips PNGs without chara chunk", function()
		-- PNG with no tEXt chunk
		local chunks = {
			{ type = "IHDR", data = "\0\0\0\1\0\0\0\1\8\6\0\0\0" },
			{ type = "IDAT", data = "\0" },
			{ type = "IEND", data = "" },
		}
		local no_chara = png_mod.write(chunks)
		local fs = make_mock_fs({
			["nochara.png"] = no_chara,
		})
		local app = server.create({ fs = fs }, { no_static = true })
		local status, data = call(app, "GET", "/api/cards")
		T.eq(status, 200)
		T.eq(#data.cards, 0)
	end)

	T.it("handles card without character_book", function()
		local card_bytes = make_card_png({
			name = "NoBook",
			description = "No lorebook",
			tags = {},
		})
		local fs = make_mock_fs({
			["nobook.png"] = card_bytes,
		})
		local app = server.create({ fs = fs }, { no_static = true })
		local status, data = call(app, "GET", "/api/cards")
		T.eq(status, 200)
		T.eq(#data.cards, 1)
		T.eq(data.cards[1].has_lorebook, false)
	end)
end)

T.describe("shell server — GET /api/card/thumbnail", function()
	T.it("returns raw PNG data", function()
		local card_bytes = make_card_png({
			name = "Thumb",
			description = "test",
			tags = {},
		})
		local fs = make_mock_fs({
			["thumb.png"] = card_bytes,
		})
		local app = server.create({ fs = fs }, { no_static = true })
		local status, _, res = call(app, "GET", "/api/card/thumbnail?filename=thumb.png")
		T.eq(status, 200)
		T.eq(res.headers["Content-Type"], "image/png")
		T.eq(res.body, card_bytes)
	end)

	T.it("returns 400 for missing filename", function()
		local fs = make_mock_fs({})
		local app = server.create({ fs = fs }, { no_static = true })
		local status, data = call(app, "GET", "/api/card/thumbnail")
		T.eq(status, 400)
		T.ok(data.error:find("missing"), "error mentions missing")
	end)

	T.it("returns 404 for nonexistent file", function()
		local fs = make_mock_fs({})
		local app = server.create({ fs = fs }, { no_static = true })
		local status, data = call(app, "GET", "/api/card/thumbnail?filename=gone.png")
		T.eq(status, 404)
	end)

	T.it("rejects path traversal", function()
		local fs = make_mock_fs({})
		local app = server.create({ fs = fs }, { no_static = true })
		local status, data = call(app, "GET", "/api/card/thumbnail?filename=../etc/passwd")
		T.eq(status, 400)
		T.ok(data.error:find("invalid"), "error mentions invalid")
	end)
end)

T.describe("shell server — POST /api/launch", function()
	T.it("returns launch info", function()
		local card_bytes = make_card_png({
			name = "LaunchMe",
			description = "test",
			tags = {},
		})
		local fs = make_mock_fs({
			["launch.png"] = card_bytes,
		})
		local app = server.create({ fs = fs }, { no_static = true })
		local status, data = call(app, "POST", "/api/launch", { filename = "launch.png" })
		T.eq(status, 200)
		T.eq(data.app, "card")
		T.eq(data.card_path, "launch.png")
		T.eq(data.port, 7861)
	end)

	T.it("returns 400 for missing filename", function()
		local fs = make_mock_fs({})
		local app = server.create({ fs = fs }, { no_static = true })
		local status, data = call(app, "POST", "/api/launch", {})
		T.eq(status, 400)
	end)

	T.it("returns 404 for nonexistent file", function()
		local fs = make_mock_fs({})
		local app = server.create({ fs = fs }, { no_static = true })
		local status, data = call(app, "POST", "/api/launch", { filename = "missing.png" })
		T.eq(status, 404)
	end)

	T.it("rejects path traversal in filename", function()
		local fs = make_mock_fs({})
		local app = server.create({ fs = fs }, { no_static = true })
		local status, data = call(app, "POST", "/api/launch", { filename = "../../secret.png" })
		T.eq(status, 400)
	end)
end)
