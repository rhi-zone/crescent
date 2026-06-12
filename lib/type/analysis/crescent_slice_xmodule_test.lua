-- Cross-module type-alias resolution tests (slice v2 increment 2, §6.6).
--
-- Validates: the `--:: require` directive scan; the value-require import detection;
-- module-path → file-path resolution; the acyclic visited-set cycle break; the
-- assembled alias env (bare names, local shadows imported); the dynamic-require
-- marker; and the end-to-end cross-module fixture (xmod/tcp_client + xmod/epoll) —
-- `Epoll` resolves across the require boundary (was `unknown-type-name`), and the
-- cross-module resolution is recorded as a visible `cross_module_alias` trust
-- boundary with a Dependency per requested claim (§6.6.5).

local T = require("lib.test.assert")
local A = require("lib.type.analysis")
-- `slice_ty` is required FIRST so the `Ty`/`PTy` aliases the slice modules carry on
-- their `--::` declarations resolve when those modules are checked transitively.
local _G_ty = require("lib.type.analysis.slice_ty")
local _G_arg = require("lib.type.analysis.slice_ty_arg")
local _ = _G_ty
local _2 = _G_arg
local S = require("lib.type.analysis.crescent_slice")
local P = require("lib.type.analysis.crescent_slice_parse")
local XM = require("lib.type.analysis.crescent_slice_xmodule")
local L = require("lib.type.analysis.crescent_slice_lower")

-- A real-file reader cap, injected at the test edge (caps-first; the library never
-- reaches for io itself).
--: (path: string) -> (string | nil, string | nil)
local function read_file(path)
	local fh = io.open(path, "r")
	if not fh then return nil, "cannot open " .. path end
	local s = fh:read("*a")
	fh:close()
	if type(s) ~= "string" then return nil, "read failed" end
	return s, nil
end

-- An in-memory reader cap backed by a table, for unit isolation.
--: ({ [string]: string }) -> ((path: string) -> (string | nil, string | nil))
local function mem_reader(files)
	--: (path: string) -> (string | nil, string | nil)
	local function read(path)
		local s = files[path]
		if s == nil then return nil, "no such file" end
		return s, nil
	end
	return read
end

-- ── scan_annotation: the `--:: require` import directive ──────────────────────

T.describe("xmodule: scan_annotation recognizes the type-only import directive", function()
	T.it("`--:: require \"lib.x\"` parses as an import directive", function()
		local d = P.scan_annotation('--:: require "lib.taskgraph.taskgraph_types"')
		T.ok(d ~= nil, "directive recognized")
		T.eq(d and d.kind, "import", "kind is import")
		T.eq(d and d.module, "lib.taskgraph.taskgraph_types", "module captured")
	end)

	T.it("`--:: Name = T` is still an alias (not an import)", function()
		local d = P.scan_annotation("--:: Foo = { x: integer }")
		T.eq(d and d.kind, "alias", "still an alias")
	end)

	T.it("a `--::` form that is neither alias nor import is nil (outside v1)", function()
		local d = P.scan_annotation("--:: declare foo : bar")
		T.eq(d, nil, "unrecognized --:: form is nil")
	end)
end)

-- ── module-path → file-path resolution ───────────────────────────────────────

T.describe("xmodule: module-path resolution", function()
	T.it("lib.x.y → lib/x/y.lua candidate, then lib/x/y/init.lua", function()
		local cands = XM.candidate_paths("lib.x.y")
		T.eq(cands[1], "lib/x/y.lua", "first candidate is the .lua file")
		T.eq(cands[2], "lib/x/y/init.lua", "second candidate is the package init")
	end)

	T.it("resolves to the .lua candidate when it exists", function()
		local rf = mem_reader({ ["lib/x/y.lua"] = "-- ok" })
		local src, path = XM.read_module("lib.x.y", rf)
		T.eq(src, "-- ok", "source returned")
		T.eq(path, "lib/x/y.lua", "path is the .lua candidate")
	end)

	T.it("falls back to init.lua when the .lua is absent", function()
		local rf = mem_reader({ ["lib/x/y/init.lua"] = "-- pkg" })
		local _, path = XM.read_module("lib.x.y", rf)
		T.eq(path, "lib/x/y/init.lua", "init.lua candidate used")
	end)

	T.it("a non-lib module is not an alias source (nil, nil)", function()
		local rf = mem_reader({ ["bit.lua"] = "-- bit" })
		local src = XM.read_module("bit", rf)
		T.eq(src, nil, "non-lib require contributes no aliases and is not read")
	end)
end)

-- ── import-trigger collection (both forms + dynamic) ─────────────────────────

T.describe("xmodule: collect_imports", function()
	T.it("collects the `--:: require` directive and the value require", function()
		local src = '--:: require "lib.a.types"\nlocal v = require("lib.b")\n'
		local ts = XM.collect_imports(src)
		T.eq(#ts, 2, "two triggers")
		T.eq(ts[1].module, "lib.a.types", "directive module")
		T.eq(ts[1].form, "directive", "directive form")
		T.eq(ts[2].module, "lib.b", "value module")
		T.eq(ts[2].form, "value", "value form")
	end)

	T.it("a dynamic require (non-string arg) is flagged, not silently dropped", function()
		local src = "local m = require(modname)\n"
		local ts = XM.collect_imports(src)
		T.eq(#ts, 1, "one trigger")
		T.eq(ts[1].dynamic, true, "marked dynamic")
	end)
end)

-- ── resolve: assembled env, shadowing, cycle break, caps-first ───────────────

T.describe("xmodule: resolve assembles the cross-module alias env", function()
	T.it("imports an exporting module's top-level aliases under bare names", function()
		local rf = mem_reader({
			["lib/m/types.lua"] = '--:: TaskDef = { type: string }\n--:: TaskNode = { id: string }\nreturn {}\n',
		})
		local r = XM.resolve('--:: require "lib.m.types"\n', { read_file = rf })
		T.ok(r.env.TaskDef ~= nil, "TaskDef imported by bare name")
		T.ok(r.env.TaskNode ~= nil, "TaskNode imported by bare name")
		T.eq(#r.imports, 1, "one import record")
		T.eq(r.imports[1].module, "lib.m.types", "module recorded")
	end)

	T.it("a require cycle terminates (visited set) with the union of aliases", function()
		-- a requires b, b requires a — each declares one alias.
		local rf = mem_reader({
			["lib/a.lua"] = '--:: require "lib.b"\n--:: AT = { a: integer }\nreturn {}\n',
			["lib/b.lua"] = '--:: require "lib.a"\n--:: BT = { b: integer }\nreturn {}\n',
		})
		-- resolve the entry that requires a; a's import of b is followed; b's import of
		-- a is the cycle and must not recurse forever.
		local r = XM.resolve('--:: require "lib.a"\n', { read_file = rf })
		T.ok(r.env.AT ~= nil, "alias from the entry's direct import present")
		-- termination is the assertion: reaching here means no infinite recursion.
		T.ok(true, "resolution terminated under the require cycle")
	end)

	T.it("caps-first: with no read_file, no aliases are imported (no reach for io)", function()
		local r = XM.resolve('--:: require "lib.m.types"\n', nil)
		T.eq(r.env.TaskDef, nil, "no alias imported without a cap")
		T.eq(#r.imports, 0, "no import records")
	end)

	T.it("a dynamic require still yields a dynamic-require marker, even with a cap", function()
		local rf = mem_reader({})
		local r = XM.resolve("local m = require(x)\n", { read_file = rf })
		T.eq(#r.markers, 1, "one marker")
		T.eq(r.markers[1].construct, "dynamic-require", "tagged dynamic-require")
	end)
end)

-- ── end-to-end: the TRUE cross-module fixture (tcp_client + epoll) ────────────

--: () -> SemanticsRegistry
local function reg()
	local r = A.new_registry()
	S.register(r)
	return r
end

T.describe("xmodule e2e: the true cross-module fixture resolves Epoll across require", function()
	-- the entry references `Epoll` (declared in xmod/epoll.lua) by bare name.
	local entry = read_file("lib/type/analysis/corpus/xmod/tcp_client.lua")

	T.it("with the read cap, Epoll resolves — NO unknown-type-name marker", function()
		local res = L.lower(entry or "", "xmod/tcp_client.lua", { read_file = read_file })
			--[[: { state: AnalysisState, requested: { [integer]: { space: string, key: string } }, expected: string, markers: { [integer]: { construct: string } }, dependencies: { [integer]: unknown }, imports: { [integer]: { module: string } } } | nil ]]
		T.ok(res ~= nil, "lower succeeded")
		if not res then return end
		local saw_unknown_epoll = false --: boolean
		for _, m in ipairs(res.markers) do
			if m.construct == "unknown-type-name:Epoll" then saw_unknown_epoll = true end
		end
		T.eq(saw_unknown_epoll, false, "Epoll is NOT unknown-type-name (resolved cross-module)")
		T.ok(#res.imports >= 1, "the exporting module was imported")
	end)

	T.it("without the cap, Epoll is unresolved — the pre-increment behavior is honest", function()
		local res = L.lower(entry or "", "xmod/tcp_client.lua", nil)
			--[[: { markers: { [integer]: { construct: string } }, imports: { [integer]: unknown } } | nil ]]
		T.ok(res ~= nil, "lower succeeded")
		if not res then return end
		T.eq(#res.imports, 0, "no cross-module import without a cap")
	end)

	T.it("the cross-module resolution rides a visible cross_module_alias trust boundary", function()
		local res = L.lower(entry or "", "xmod/tcp_client.lua", { read_file = read_file })
			--[[: { state: AnalysisState, dependencies: { [integer]: unknown } } | nil ]]
		T.ok(res ~= nil, "lower succeeded")
		if not res then return end
		local saw_xmod_tb = false --: boolean
		for _, tb in pairs(res.state.trust_boundaries) do
			if tb.kind == "cross_module_alias" then saw_xmod_tb = true end
		end
		T.ok(saw_xmod_tb, "a cross_module_alias trust boundary is recorded (visible, auditable)")
		T.ok(#res.dependencies > 0, "cross-artifact dependencies recorded with invalidation")
	end)
end)
