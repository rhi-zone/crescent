if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local json = require("lib.format.json")
local presets = require("lib.platform.apps.card.presets")

-- ── Mock kv ────────────────────────────────────────────────────────────────

local function make_kv()
	local store = {}
	return {
		get = function(key) return store[key] end,
		set = function(key, val) store[key] = val end,
		_store = store,
	}
end

-- ── Defaults ───────────────────────────────────────────────────────────────

T.describe("presets.get_defaults", function()
	T.it("returns all three preset types", function()
		local d = presets.get_defaults()
		T.ok(#d.connections > 0, "has connections")
		T.ok(#d.generations > 0, "has generations")
		T.ok(#d.prompts > 0, "has prompts")
	end)

	T.it("defaults have names", function()
		local d = presets.get_defaults()
		for _, c in ipairs(d.connections) do
			T.ok(c.name and #c.name > 0, "connection has name")
		end
		for _, g in ipairs(d.generations) do
			T.ok(g.name and #g.name > 0, "generation has name")
		end
		for _, p in ipairs(d.prompts) do
			T.ok(p.name and #p.name > 0, "prompt has name")
		end
	end)

	T.it("returns copies (mutation safe)", function()
		local d1 = presets.get_defaults()
		local d2 = presets.get_defaults()
		d1.connections[1].name = "MUTATED"
		T.neq(d1.connections[1].name, d2.connections[1].name)
	end)
end)

-- ── load_all ───────────────────────────────────────────────────────────────

T.describe("presets.load_all", function()
	T.it("returns defaults when kv is empty", function()
		local kv = make_kv()
		local all = presets.load_all(kv)
		T.ok(#all.connections > 0, "has default connections")
		T.ok(#all.generations > 0, "has default generations")
		T.ok(#all.prompts > 0, "has default prompts")
		T.eq(all.active.connection, nil)
		T.eq(all.active.generation, nil)
		T.eq(all.active.prompt, nil)
	end)

	T.it("returns stored presets when present", function()
		local kv = make_kv()
		local custom = { { name = "Custom" } }
		kv.set("presets:connection", json.encode(custom))
		local all = presets.load_all(kv)
		T.eq(#all.connections, 1)
		T.eq(all.connections[1].name, "Custom")
	end)
end)

-- ── CRUD: connection presets ───────────────────────────────────────────────

T.describe("presets.save (connection)", function()
	T.it("saves a new connection preset", function()
		local kv = make_kv()
		local ok, err = presets.save(kv, "connection", "My Server", {
			endpoint = "http://myserver:5000",
			model = "llama",
		})
		T.ok(ok, "save succeeded")
		T.eq(err, nil)

		local all = presets.load_all(kv)
		T.eq(#all.connections, 1)
		T.eq(all.connections[1].name, "My Server")
		T.eq(all.connections[1].endpoint, "http://myserver:5000")
	end)

	T.it("updates an existing preset by name", function()
		local kv = make_kv()
		presets.save(kv, "connection", "Server", { endpoint = "http://a:1" })
		presets.save(kv, "connection", "Server", { endpoint = "http://b:2" })

		local all = presets.load_all(kv)
		T.eq(#all.connections, 1)
		T.eq(all.connections[1].endpoint, "http://b:2")
	end)

	T.it("rejects invalid type", function()
		local kv = make_kv()
		local ok, err = presets.save(kv, "bogus", "x", {})
		T.eq(ok, nil)
		T.ok(err:find("invalid"), "error mentions invalid")
	end)

	T.it("rejects empty name", function()
		local kv = make_kv()
		local ok, err = presets.save(kv, "connection", "", {})
		T.eq(ok, nil)
		T.ok(err:find("name"), "error mentions name")
	end)
end)

-- ── CRUD: generation presets ──────────────────────────────────────────────

T.describe("presets.save (generation)", function()
	T.it("saves and retrieves generation preset", function()
		local kv = make_kv()
		presets.save(kv, "generation", "Hot", {
			temperature = 1.5,
			top_p = 0.8,
			max_tokens = 1024,
		})
		local all = presets.load_all(kv)
		T.eq(#all.generations, 1)
		T.eq(all.generations[1].temperature, 1.5)
	end)
end)

-- ── CRUD: prompt presets ──────────────────────────────────────────────────

T.describe("presets.save (prompt)", function()
	T.it("saves and retrieves prompt preset", function()
		local kv = make_kv()
		presets.save(kv, "prompt", "Roleplay", {
			system_prompt = "You are {{char}}.",
			context_order = { "system_prompt", "history" },
		})
		local all = presets.load_all(kv)
		T.eq(#all.prompts, 1)
		T.eq(all.prompts[1].system_prompt, "You are {{char}}.")
		T.eq(#all.prompts[1].context_order, 2)
	end)
end)

-- ── Delete ─────────────────────────────────────────────────────────────────

T.describe("presets.delete", function()
	T.it("deletes an existing preset", function()
		local kv = make_kv()
		presets.save(kv, "connection", "A", { endpoint = "http://a" })
		presets.save(kv, "connection", "B", { endpoint = "http://b" })

		local ok, err = presets.delete(kv, "connection", "A")
		T.ok(ok, "delete succeeded")

		local all = presets.load_all(kv)
		T.eq(#all.connections, 1)
		T.eq(all.connections[1].name, "B")
	end)

	T.it("returns error for nonexistent preset", function()
		local kv = make_kv()
		local ok, err = presets.delete(kv, "connection", "nope")
		T.eq(ok, nil)
		T.ok(err:find("not found"), "error mentions not found")
	end)

	T.it("clears active if deleted preset was active", function()
		local kv = make_kv()
		presets.save(kv, "generation", "X", { temperature = 1.0 })
		presets.set_active(kv, "generation", "X")
		T.eq(kv.get("presets:active:generation"), "X")

		presets.delete(kv, "generation", "X")
		T.eq(kv.get("presets:active:generation"), nil)
	end)
end)

-- ── Active preset ──────────────────────────────────────────────────────────

T.describe("presets.set_active / get_active", function()
	T.it("sets and gets active preset", function()
		local kv = make_kv()
		presets.save(kv, "connection", "Srv", { endpoint = "http://srv" })

		local ok = presets.set_active(kv, "connection", "Srv")
		T.ok(ok, "set_active succeeded")

		local active = presets.get_active(kv, "connection")
		T.ok(active ~= nil, "active preset returned")
		T.eq(active.name, "Srv")
		T.eq(active.endpoint, "http://srv")
	end)

	T.it("returns nil when no active set", function()
		local kv = make_kv()
		local active = presets.get_active(kv, "connection")
		T.eq(active, nil)
	end)

	T.it("rejects nonexistent preset name", function()
		local kv = make_kv()
		local ok, err = presets.set_active(kv, "connection", "nope")
		T.eq(ok, nil)
		T.ok(err:find("not found"), "error mentions not found")
	end)

	T.it("can activate a default preset without saving first", function()
		local kv = make_kv()
		local defaults = presets.get_defaults()
		local name = defaults.connections[1].name

		local ok = presets.set_active(kv, "connection", name)
		T.ok(ok, "set_active succeeded for default")

		local active = presets.get_active(kv, "connection")
		T.ok(active ~= nil, "active default returned")
		T.eq(active.name, name)
	end)

	T.it("load_all includes active names", function()
		local kv = make_kv()
		presets.save(kv, "connection", "Srv", { endpoint = "http://srv" })
		presets.set_active(kv, "connection", "Srv")

		local all = presets.load_all(kv)
		T.eq(all.active.connection, "Srv")
	end)
end)

-- ── Import / Export ────────────────────────────────────────────────────────

T.describe("presets.import_preset / export_preset", function()
	T.it("round-trips a preset through export/import", function()
		local original = {
			name = "Test Preset",
			temperature = 0.9,
			top_p = 0.85,
			max_tokens = 600,
		}
		local exported = presets.export_preset(original)
		T.ok(type(exported) == "string", "export returns string")

		local imported, err = presets.import_preset(exported)
		T.ok(imported ~= nil, "import succeeded")
		T.eq(imported.name, "Test Preset")
		T.eq(imported.temperature, 0.9)
		T.eq(imported.top_p, 0.85)
		T.eq(imported.max_tokens, 600)
	end)

	T.it("import rejects empty input", function()
		local val, err = presets.import_preset("")
		T.eq(val, nil)
		T.ok(err:find("empty"), "error mentions empty")
	end)

	T.it("import rejects invalid JSON", function()
		local val, err = presets.import_preset("{bad json")
		T.eq(val, nil)
		T.ok(err:find("invalid JSON") or err:find("JSON"), "error mentions JSON")
	end)

	T.it("import rejects preset without name", function()
		local val, err = presets.import_preset(json.encode({ temperature = 1.0 }))
		T.eq(val, nil)
		T.ok(err:find("name"), "error mentions name")
	end)
end)

-- ── Full workflow ──────────────────────────────────────────────────────────

T.describe("presets workflow", function()
	T.it("save, activate, export, import, delete cycle", function()
		local kv = make_kv()

		-- Save
		presets.save(kv, "generation", "MyGen", {
			temperature = 0.8,
			top_p = 0.95,
			max_tokens = 256,
		})

		-- Activate
		presets.set_active(kv, "generation", "MyGen")
		local active = presets.get_active(kv, "generation")
		T.eq(active.name, "MyGen")

		-- Export
		local exported = presets.export_preset(active)
		T.ok(type(exported) == "string")

		-- Import
		local imported = presets.import_preset(exported)
		T.eq(imported.name, "MyGen")
		T.eq(imported.temperature, 0.8)

		-- Save imported under new name
		imported.name = "MyGen Copy"
		presets.save(kv, "generation", "MyGen Copy", imported)

		local all = presets.load_all(kv)
		T.eq(#all.generations, 2)

		-- Delete original
		presets.delete(kv, "generation", "MyGen")
		all = presets.load_all(kv)
		T.eq(#all.generations, 1)
		T.eq(all.generations[1].name, "MyGen Copy")
	end)
end)
