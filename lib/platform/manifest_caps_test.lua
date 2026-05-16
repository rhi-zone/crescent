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
