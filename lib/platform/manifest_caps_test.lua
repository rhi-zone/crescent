if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T  = require("lib.test.assert")
local MC = require("lib.platform.manifest_caps")

--:: require "lib.platform.platform_types"

-- ── merge_cap_declarations (daemon caps) ──────────────────────────────────

T.describe("manifest_caps.merge_cap_declarations", function ()
	T.it("expands top-level shorthand 'required' to a full decl with required=true", function ()
		local manifest = { name = "t", caps = { db = "required" } }
		local decls = MC.merge_cap_declarations(manifest, "server")
		T.ok(decls.db ~= nil, "db decl present")
		T.eq(decls.db.type, "db")
		T.eq(decls.db.required, true)
	end)

	T.it("expands top-level shorthand 'optional' to required=false", function ()
		local manifest = { caps = { kv = "optional" } }
		local decls = MC.merge_cap_declarations(manifest, "server")
		T.eq(decls.kv.required, false)
		T.eq(decls.kv.type, "kv")
	end)

	T.it("merges per-entrypoint caps on top of top-level", function ()
		local manifest = {
			caps  = { self = { type = "self" }, time = { type = "time" } },
			entry = {
				server = {
					main = "server.lua",
					caps = { server = { type = "http_server" } },
				},
			},
		}
		local decls = MC.merge_cap_declarations(manifest, "server")
		T.ok(decls.self   ~= nil, "top-level self kept")
		T.ok(decls.time   ~= nil, "top-level time kept")
		T.ok(decls.server ~= nil, "per-entry server merged in")
		T.eq(decls.server.type, "http_server")
	end)

	T.it("returns empty table for nil/empty manifest", function ()
		local decls = MC.merge_cap_declarations({}, "server")
		T.eq(next(decls), nil)
	end)
end)

-- ── merge_browser_cap_declarations ────────────────────────────────────────

T.describe("manifest_caps.merge_browser_cap_declarations", function ()
	T.it("expands shorthand 'required' / 'optional' the same way daemon caps do", function ()
		local manifest = {
			browser_caps = {
				toast      = "required",
				kv_read    = "optional",
			},
		}
		local decls = MC.merge_browser_cap_declarations(manifest, "main")
		T.eq(decls.toast.type, "toast")
		T.eq(decls.toast.required, true)
		T.eq(decls.kv_read.type, "kv_read")
		T.eq(decls.kv_read.required, false)
	end)

	T.it("accepts full-table declarations with arbitrary kind-specific config", function ()
		local manifest = {
			browser_caps = {
				fetch_api = {
					type = "fetch_api",
					allowed_origins = { "https://api.example" },
					timeout_ms = 5000,
				},
			},
		}
		local decls = MC.merge_browser_cap_declarations(manifest, "main")
		T.eq(decls.fetch_api.type, "fetch_api")
		T.eq(decls.fetch_api.timeout_ms, 5000)
	end)

	T.it("merges per-entrypoint browser_caps over top-level", function ()
		local manifest = {
			browser_caps = { toast = { type = "toast" } },
			entry = {
				server = {
					main = "server.lua",
					browser_caps = { dialog = { type = "dialog" } },
				},
			},
		}
		local decls = MC.merge_browser_cap_declarations(manifest, "server")
		T.ok(decls.toast  ~= nil, "top-level toast kept")
		T.ok(decls.dialog ~= nil, "per-entry dialog merged in")
	end)

	T.it("returns empty table when manifest has no browser_caps", function ()
		local decls = MC.merge_browser_cap_declarations({ caps = { db = "required" } }, "main")
		T.eq(next(decls), nil)
	end)
end)

-- ── validate_browser_caps ─────────────────────────────────────────────────

T.describe("manifest_caps.validate_browser_caps", function ()
	T.it("accepts a manifest with no browser_caps", function ()
		local ok, err = MC.validate_browser_caps({ caps = { db = "required" } })
		T.ok(ok, tostring(err))
	end)

	T.it("accepts every day-zero kind", function ()
		local top = {}
		for kind in pairs(MC.BROWSER_CAP_KINDS) do
			top[kind] = "required"
		end
		local ok, err = MC.validate_browser_caps({ browser_caps = top })
		T.ok(ok, tostring(err))
	end)

	T.it("accepts shorthand 'required' and 'optional'", function ()
		local ok, err = MC.validate_browser_caps({
			browser_caps = { toast = "required", kv_read = "optional" },
		})
		T.ok(ok, tostring(err))
	end)

	T.it("rejects unknown browser-cap kind", function ()
		local ok, err = MC.validate_browser_caps({
			browser_caps = { weird = { type = "not_a_real_kind" } },
		})
		T.ok(not ok)
		T.ok(err ~= nil and err:find("not_a_real_kind"), "err mentions bad kind: " .. tostring(err))
	end)

	T.it("rejects shorthand other than required/optional", function ()
		local ok, err = MC.validate_browser_caps({
			browser_caps = { toast = "maybe" },
		})
		T.ok(not ok)
		T.ok(err ~= nil and err:find("required") and err:find("optional"))
	end)

	T.it("rejects non-table browser_caps section", function ()
		local ok, err = MC.validate_browser_caps({ browser_caps = "oops" })
		T.ok(not ok)
		T.ok(err ~= nil and err:find("must be a table"))
	end)

	T.it("rejects non-string / non-table decl values", function ()
		local ok, err = MC.validate_browser_caps({
			browser_caps = { toast = 42 },
		})
		T.ok(not ok)
		T.ok(err ~= nil and err:find("must be a string or table"))
	end)

	T.it("validates per-entrypoint browser_caps too", function ()
		local ok, err = MC.validate_browser_caps({
			entry = {
				main = {
					main = "main.lua",
					browser_caps = { x = { type = "bogus_kind" } },
				},
			},
		})
		T.ok(not ok)
		T.ok(err ~= nil and err:find("bogus_kind"))
		T.ok(err ~= nil and err:find("entry"), "err mentions entry context")
	end)
end)
