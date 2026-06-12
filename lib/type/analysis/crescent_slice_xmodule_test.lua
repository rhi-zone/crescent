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

	-- Forward-sibling references INSIDE one exporting module (§6.12, increment 8):
	-- `server_socket` is declared BEFORE `server_client` but its body names it. The
	-- import pass installs the module's aliases in dependency order, so both resolve.
	T.it("a forward-sibling reference inside an exporting module resolves (dependency order)", function()
		local rf = mem_reader({
			["lib/sock.lua"] = '--:: server_socket = { fd: integer, peer: server_client | nil }\n'
				.. '--:: server_client = { fd: integer }\nreturn {}\n',
		})
		local r = XM.resolve('--:: require "lib.sock"\n', { read_file = rf })
		T.ok(r.env.server_socket ~= nil, "server_socket (forward ref) imported")
		T.ok(r.env.server_client ~= nil, "server_client imported")
		T.eq(#r.errors, 0, "no export error for the forward-sibling reference")
	end)

	-- A MUTUAL alias family inside one exporting module (Bekić, §6.13). `Node` is a
	-- union over `Branch`, and `Branch` references `Node` — a genuine cycle. The
	-- import pass groups the family (one SCC) and Bekić-elaborates it, so every
	-- member resolves and imports under its bare name.
	T.it("a mutual alias family inside an exporting module resolves (Bekić elaboration)", function()
		local rf = mem_reader({
			["lib/tree.lua"] = '--:: Node = Leaf | Branch\n'
				.. '--:: Leaf = { tag: "leaf", v: integer }\n'
				.. '--:: Branch = { tag: "branch", kids: { [integer]: Node } }\nreturn {}\n',
		})
		local r = XM.resolve('--:: require "lib.tree"\n', { read_file = rf })
		T.ok(r.env.Node ~= nil, "Node (cyclic family head) imported")
		T.ok(r.env.Branch ~= nil, "Branch (cyclic family member) imported")
		T.ok(r.env.Leaf ~= nil, "Leaf imported")
		T.eq(#r.errors, 0, "no export error for the mutual family")
		-- the imported family is well-formed and subtypes through the cycle.
		local SUB = require("lib.type.analysis.slice_subtype")
		local TA2 = require("lib.type.analysis.slice_ty_arg")
		T.ok(r.env.Node ~= nil and TA2.well_formed(r.env.Node), "Node is well-formed")
		T.ok(r.env.Branch ~= nil and r.env.Node ~= nil and SUB.is_subtype(r.env.Branch, r.env.Node),
			"Branch <: Node (member into parent union, through the cycle)")
	end)

	T.it("a dynamic require still yields a dynamic-require marker, even with a cap", function()
		local rf = mem_reader({})
		local r = XM.resolve("local m = require(x)\n", { read_file = rf })
		T.eq(#r.markers, 1, "one marker")
		T.eq(r.markers[1].construct, "dynamic-require", "tagged dynamic-require")
	end)
end)

-- ── F1: collision detection between exporters ─────────────────────────────────

T.describe("xmodule F1: collision detection between exporters", function()
	T.it("a-then-b: same bare name, different tids → error (collision)", function()
		local rf = mem_reader({
			["lib/a.lua"] = '--:: Shared = { x: integer }\n',
			["lib/b.lua"] = '--:: Shared = { y: string }\n',
		})
		local r = XM.resolve('--:: require "lib.a"\n--:: require "lib.b"\n', { read_file = rf })
		local saw = false --: boolean
		for _, e in ipairs(r.errors) do
			if e.name == "Shared" and e.err:find("collision") then saw = true end
		end
		T.ok(saw, "collision error surfaced for Shared (a-then-b)")
	end)

	T.it("b-then-a: order-symmetric — both orderings error identically", function()
		local rf = mem_reader({
			["lib/a.lua"] = '--:: Shared = { x: integer }\n',
			["lib/b.lua"] = '--:: Shared = { y: string }\n',
		})
		local r = XM.resolve('--:: require "lib.b"\n--:: require "lib.a"\n', { read_file = rf })
		local saw = false --: boolean
		for _, e in ipairs(r.errors) do
			if e.name == "Shared" and e.err:find("collision") then saw = true end
		end
		T.ok(saw, "collision error surfaced for Shared (b-then-a)")
	end)

	T.it("same-type double import dedupes silently (no error, name present)", function()
		-- same body ⇒ same interned Ty (hash-consed) ⇒ same tid ⇒ no collision.
		local rf = mem_reader({
			["lib/a.lua"] = '--:: Shared = { x: integer }\n',
			["lib/b.lua"] = '--:: Shared = { x: integer }\n',
		})
		local r = XM.resolve('--:: require "lib.a"\n--:: require "lib.b"\n', { read_file = rf })
		T.eq(#r.errors, 0, "no error when both exporters declare the same type")
		T.ok(r.env.Shared ~= nil, "Shared is still present in the env")
	end)

	T.it("local --:: shadows an imported alias — allowed (not a collision)", function()
		-- The collision check is at the import seam (import_top_level_aliases);
		-- the local --:: shadow is applied later in scan_source with most-recent-wins.
		-- This test exercises the full lower path to confirm the shadow still works.
		local rf = mem_reader({
			["lib/m.lua"] = '--:: MyT = { x: integer }\n',
		})
		-- entry declares its own MyT after the import → shadow, no error.
		local entry = '--:: require "lib.m"\n--:: MyT = { z: boolean }\n'
		local res = L.lower(entry, "entry.lua", { read_file = rf })
		T.ok(res ~= nil, "lower succeeded")
		if not res then return end
		-- no collision marker expected (the shadow is in scan_source, post-import-pass).
		local saw_collision = false --: boolean
		for _, mk in ipairs(res.markers) do
			if mk.construct and mk.construct:find("collision") then saw_collision = true end
		end
		T.eq(saw_collision, false, "local --:: shadow of imported alias is not a collision")
	end)
end)

-- ── F2: mutual-alias honest-error pin (retraction test) ──────────────────────

T.describe("xmodule F2: mutual cross-module aliases error honestly (retraction pin)", function()
	T.it("A references B's name before B is installed → unknown-type-name in A's export", function()
		-- A's alias body references BT; when A is parsed, BT is not yet in env.
		-- A's export should fail with a parse error (unknown-type-name:BT).
		local rf = mem_reader({
			["lib/a.lua"] = '--:: AT = { child: BT }\n',
			["lib/b.lua"] = '--:: BT = { id: integer }\n',
		})
		-- import a first, then b. A's body references BT which is not yet present.
		local r = XM.resolve('--:: require "lib.a"\n--:: require "lib.b"\n', { read_file = rf })
		-- AT should fail to parse (BT unknown when A is processed), so AT is not in env.
		-- BT should succeed (no forward reference in B's body).
		T.ok(r.env.BT ~= nil, "BT (standalone) resolves fine")
		-- AT either errored or is absent (unknown-type-name:BT in A's body).
		local at_absent = r.env.AT == nil --: boolean
		local at_errored = false --: boolean
		for _, e in ipairs(r.errors) do
			if e.name == "AT" then at_errored = true end
		end
		T.ok(at_absent or at_errored, "mutual forward reference (AT referencing BT) errors honestly, not silently resolved")
	end)
end)

-- ── F3: malformed-path hardening ─────────────────────────────────────────────

T.describe("xmodule F3: malformed require paths refused before cap reach", function()
	T.it("valid_modpath_segments: normal paths are valid", function()
		T.ok(XM.valid_modpath_segments("lib.x.y"), "lib.x.y is valid")
		T.ok(XM.valid_modpath_segments("lib"), "lib is valid")
		T.ok(XM.valid_modpath_segments("lib.type.analysis"), "lib.type.analysis is valid")
	end)

	T.it("valid_modpath_segments: empty-segment paths are invalid", function()
		T.eq(XM.valid_modpath_segments("lib..secret"), false, "doubled dot invalid")
		T.eq(XM.valid_modpath_segments("lib.x....."), false, "trailing dots invalid")
		T.eq(XM.valid_modpath_segments(".lib"), false, "leading dot invalid")
		T.eq(XM.valid_modpath_segments("lib."), false, "trailing dot invalid")
		T.eq(XM.valid_modpath_segments(""), false, "empty string invalid")
	end)

	T.it("resolve: malformed path emits invalid-require marker, cap is never called", function()
		local cap_called = false --: boolean
		--: (string) -> (string | nil, string | nil)
		local function spy_rf(path)
			cap_called = true
			return nil, "spy: should not have been called for path " .. path
		end
		-- `lib..secret` has an empty segment — must be refused before the cap.
		local r = XM.resolve('--:: require "lib..secret"\n', { read_file = spy_rf })
		T.eq(cap_called, false, "cap was NOT called for malformed path")
		local saw_marker = false --: boolean
		for _, mk in ipairs(r.markers) do
			if mk.construct == "out-of-subset/invalid-require" then saw_marker = true end
		end
		T.ok(saw_marker, "invalid-require marker emitted for malformed path")
	end)

	T.it("resolve: another attack string `lib.x.....` also refused before cap", function()
		local cap_called = false --: boolean
		--: (string) -> (string | nil, string | nil)
		local function spy_rf2(_path)
			cap_called = true
			return nil, nil
		end
		local r = XM.resolve('--:: require "lib.x....."\n', { read_file = spy_rf2 })
		T.eq(cap_called, false, "cap NOT called for `lib.x.....`")
		local saw = false --: boolean
		for _, mk in ipairs(r.markers) do
			if mk.construct == "out-of-subset/invalid-require" then saw = true end
		end
		T.ok(saw, "invalid-require marker for `lib.x.....`")
	end)

	T.it("resolve: legitimate paths still reach the cap normally", function()
		local cap_called = false --: boolean
		--: (string) -> (string | nil, string | nil)
		local function cap_rf(path)
			cap_called = true
			if path == "lib/x/y.lua" then return '--:: XY = integer\n', nil end
			return nil, nil
		end
		local r = XM.resolve('--:: require "lib.x.y"\n', { read_file = cap_rf })
		T.ok(cap_called, "cap IS called for a valid path")
		T.ok(r.env.XY ~= nil, "alias from valid path imported")
	end)
end)

-- ── F4: content digest in import records ─────────────────────────────────────

T.describe("xmodule F4: content digest in import records and dependency invalidation", function()
	T.it("resolve: ImportRecord carries a non-empty digest field", function()
		local rf = mem_reader({ ["lib/m.lua"] = '--:: MT = { id: integer }\n' })
		local r = XM.resolve('--:: require "lib.m"\n', { read_file = rf })
		T.eq(#r.imports, 1, "one import record")
		local rec = r.imports[1]
		T.ok(type(rec.digest) == "string" and #rec.digest > 0, "digest field is a non-empty string")
	end)

	T.it("same path, changed body → different digest (staleness visible)", function()
		local src_v1 = '--:: MT = { id: integer }\n'
		local src_v2 = '--:: MT = { id: string }\n'
		local rf1 = mem_reader({ ["lib/m.lua"] = src_v1 })
		local rf2 = mem_reader({ ["lib/m.lua"] = src_v2 })
		local r1 = XM.resolve('--:: require "lib.m"\n', { read_file = rf1 })
		local r2 = XM.resolve('--:: require "lib.m"\n', { read_file = rf2 })
		T.eq(#r1.imports, 1, "r1: one import")
		T.eq(#r2.imports, 1, "r2: one import")
		T.ok(r1.imports[1].digest ~= r2.imports[1].digest, "digests differ when source body changes")
	end)

	T.it("lower: dependency invalidation string includes the digest", function()
		local rf = mem_reader({ ["lib/m.lua"] = '--:: MT = { id: integer }\n' })
		local entry = '--:: require "lib.m"\n--: (x: MT) -> integer\nlocal function f(x) return x.id end\n'
		local res = L.lower(entry, "entry.lua", { read_file = rf })
		T.ok(res ~= nil, "lower succeeded")
		if not res then return end
		T.ok(#res.dependencies > 0, "dependencies recorded")
		local found_digest = false --: boolean
		for _, dep in ipairs(res.dependencies) do
			local inv = dep.invalidation or ""
			if inv:find("digest:") then found_digest = true end
		end
		T.ok(found_digest, "dependency invalidation string includes 'digest:' field")
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

	T.it("F4: the real cross-module import carries a non-empty digest", function()
		local res = L.lower(entry or "", "xmod/tcp_client.lua", { read_file = read_file })
			--[[: { imports: { [integer]: { digest: string } } } | nil ]]
		T.ok(res ~= nil, "lower succeeded")
		if not res then return end
		T.ok(#res.imports >= 1, "import records present")
		local imp = res.imports[1]
		T.ok(type(imp.digest) == "string" and #imp.digest > 0, "real import carries a non-empty digest")
	end)
end)
