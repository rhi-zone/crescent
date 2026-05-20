-- Tests for K4 — summary/default rendering of v4 diagnostics.
--
-- The grouping primitive (`M.group`) is exercised independently of
-- rendering so the data-level taxonomy is testable without relying on
-- substring assertions over rendered text — that was the legacy mode's
-- failure shape (see ast-walker design audit) and is the specific thing
-- the v4 layer must avoid in BOTH the implementation and its tests.

if not package.path:find("?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local D = require("lib.type.static-v4.walker.diag")
local S = require("lib.type.static-v4.driver.summary")

-- Build a diagnostic table directly (no walker env construction needed —
-- the renderer is data-shape-only and does not consult the diag
-- metatable). Going through D.emit would force the walker.env alias
-- machinery into this test's check scope, which surfaces unrelated
-- cross-module alias resolution noise.
--:: TestDiag = { code: string, pos: { file: string, line: integer, col: integer, end_line: integer | nil, end_col: integer | nil } | nil, msg: string, severity: string, origin_kind: string | nil, module: string | nil }
--: (string, integer, integer, string, string, string | nil, string | nil) -> TestDiag
local function diag(file, line, col, code, msg, origin_kind, module)
	return {
		code        = code,
		msg         = msg,
		severity    = "error",
		pos         = { file = file, line = line, col = col, end_line = nil, end_col = nil },
		origin_kind = origin_kind,
		module      = module,
	}
end

T.describe("summary.group", function()
	T.it("empty stream produces empty groups", function()
		local g = S.group({})
		local any = false
		for _ in pairs(g) do any = true end
		T.eq(any, false)
	end)

	T.it("groups by category and code", function()
		local ds = {
			diag("a.lua", 1, 1, D.E_UNDEFINED_NAME, "x not defined"),
			diag("a.lua", 2, 1, D.E_UNDEFINED_NAME, "y not defined"),
			diag("a.lua", 3, 1, D.E_TYPE_MISMATCH, "string vs int"),
		}
		local g = S.group(ds)
		T.ok(g[S.CAT_UNDEFINED_NAMES] ~= nil)
		T.ok(g[S.CAT_TYPE_MISMATCHES] ~= nil)
		T.eq(#g[S.CAT_UNDEFINED_NAMES][D.E_UNDEFINED_NAME], 2)
		T.eq(#g[S.CAT_TYPE_MISMATCHES][D.E_TYPE_MISMATCH], 1)
	end)

	T.it("E_REQUIRE_UNRESOLVED is its own root-cause category", function()
		local d = diag("a.lua", 1, 1, D.E_REQUIRE_UNRESOLVED,
			"module 'foo' not found", nil, "foo")
		local g = S.group({ d })
		T.ok(g[S.CAT_UNRESOLVED_REQUIRES] ~= nil)
		T.eq(#g[S.CAT_UNRESOLVED_REQUIRES][D.E_REQUIRE_UNRESOLVED], 1)
	end)

	T.it("origin_kind = from-require routes a type-mismatch to the cascade category", function()
		local d = diag("a.lua", 5, 4, D.E_TYPE_MISMATCH,
			"unknown vs number", D.O_FROM_REQUIRE, "foo")
		local g = S.group({ d })
		-- It must NOT land in the plain type-mismatch bucket.
		T.eq(g[S.CAT_TYPE_MISMATCHES], nil)
		T.ok(g[S.CAT_FROM_REQUIRE_CASCADE] ~= nil)
		T.eq(#g[S.CAT_FROM_REQUIRE_CASCADE][D.E_TYPE_MISMATCH], 1)
	end)

	T.it("origin_kind = from-cast routes to the cast cascade category", function()
		local d = diag("a.lua", 1, 1, D.E_TYPE_MISMATCH,
			"cast overlap fail", D.O_FROM_CAST)
		local g = S.group({ d })
		T.ok(g[S.CAT_FROM_CAST] ~= nil)
		T.eq(#g[S.CAT_FROM_CAST][D.E_TYPE_MISMATCH], 1)
	end)

	T.it("no-origin diagnostic falls through to code-based category", function()
		local d = diag("a.lua", 1, 1, D.E_FIELD_MISSING, "no field x")
		local g = S.group({ d })
		T.ok(g[S.CAT_MISSING_FIELDS] ~= nil)
	end)

	T.it("E_REQUIRE_UNRESOLVED stays a root cause even with from-require origin_kind", function()
		-- The require-unresolved diagnostic itself often carries
		-- origin_kind = from-require (the placeholder it produced traces
		-- to itself). Root-cause discipline: the originating event is
		-- categorised by its OWN code, not by its origin chain.
		local d = diag("a.lua", 1, 1, D.E_REQUIRE_UNRESOLVED,
			"module 'foo' not found", D.O_FROM_REQUIRE, "foo")
		local g = S.group({ d })
		T.ok(g[S.CAT_UNRESOLVED_REQUIRES] ~= nil)
		T.eq(g[S.CAT_FROM_REQUIRE_CASCADE], nil)
	end)

	T.it("buckets are sorted by (file, line, col)", function()
		local ds = {
			diag("b.lua", 1, 1, D.E_UNDEFINED_NAME, "b"),
			diag("a.lua", 2, 1, D.E_UNDEFINED_NAME, "a2"),
			diag("a.lua", 1, 5, D.E_UNDEFINED_NAME, "a1c5"),
			diag("a.lua", 1, 1, D.E_UNDEFINED_NAME, "a1c1"),
		}
		local g = S.group(ds)
		local bucket = g[S.CAT_UNDEFINED_NAMES][D.E_UNDEFINED_NAME]
		T.eq(bucket[1].msg, "a1c1")
		T.eq(bucket[2].msg, "a1c5")
		T.eq(bucket[3].msg, "a2")
		T.eq(bucket[4].msg, "b")
	end)
end)

T.describe("summary.render_default", function()
	T.it("empty stream renders to empty string", function()
		T.eq(S.render_default({}), "")
	end)

	T.it("renders one line per diagnostic with code", function()
		local d = diag("a.lua", 3, 7, D.E_UNDEFINED_NAME, "x")
		local out = S.render_default({ d })
		T.ok(out:find("a.lua:3:7:", 1, true) ~= nil)
		T.ok(out:find(D.E_UNDEFINED_NAME, 1, true) ~= nil)
		T.ok(out:find("error:", 1, true) ~= nil)
	end)

	T.it("output is sorted by (file, line, col)", function()
		local ds = {
			diag("b.lua", 1, 1, D.E_UNDEFINED_NAME, "b1"),
			diag("a.lua", 2, 1, D.E_TYPE_MISMATCH,  "a2"),
			diag("a.lua", 1, 1, D.E_UNDEFINED_NAME, "a1"),
		}
		local out = S.render_default(ds)
		local p_a1 = out:find("a.lua:1:1:", 1, true) or 0
		local p_a2 = out:find("a.lua:2:1:", 1, true) or 0
		local p_b1 = out:find("b.lua:1:1:", 1, true) or 0
		T.ok(p_a1 > 0 and p_a2 > 0 and p_b1 > 0)
		T.ok(p_a1 < p_a2)
		T.ok(p_a2 < p_b1)
	end)
end)

T.describe("summary.render_summary", function()
	T.it("empty stream renders \"0 errors.\"", function()
		T.eq(S.render_summary({}), "0 errors.\n")
	end)

	T.it("emits header with total + category count", function()
		local ds = {
			diag("a.lua", 1, 1, D.E_UNDEFINED_NAME, "u"),
			diag("a.lua", 2, 1, D.E_TYPE_MISMATCH,  "t"),
		}
		local out = S.render_summary(ds)
		T.ok(out:find("2 errors in 2 categories.", 1, true) ~= nil)
	end)

	T.it("singular wording for 1 error / 1 category", function()
		local ds = { diag("a.lua", 1, 1, D.E_UNDEFINED_NAME, "u") }
		local out = S.render_summary(ds)
		T.ok(out:find("1 error in 1 category.", 1, true) ~= nil)
	end)

	T.it("each populated category appears with its heading", function()
		local ds = {
			diag("a.lua", 1, 1, D.E_REQUIRE_UNRESOLVED, "mod foo", nil, "foo"),
			diag("a.lua", 2, 1, D.E_TYPE_MISMATCH, "cascade1", D.O_FROM_REQUIRE, "foo"),
			diag("a.lua", 3, 1, D.E_TYPE_MISMATCH, "direct"),
		}
		local out = S.render_summary(ds)
		T.ok(out:find(S.CATEGORY_HEADING[S.CAT_UNRESOLVED_REQUIRES], 1, true) ~= nil)
		T.ok(out:find(S.CATEGORY_HEADING[S.CAT_FROM_REQUIRE_CASCADE], 1, true) ~= nil)
		T.ok(out:find(S.CATEGORY_HEADING[S.CAT_TYPE_MISMATCHES], 1, true) ~= nil)
	end)

	T.it("from-require cascade lists each member with file/line", function()
		local ds = {
			diag("a.lua", 5, 1, D.E_TYPE_MISMATCH, "x", D.O_FROM_REQUIRE, "foo"),
			diag("a.lua", 6, 1, D.E_FIELD_MISSING, "y", D.O_FROM_REQUIRE, "foo"),
		}
		local out = S.render_summary(ds)
		T.ok(out:find("a.lua:5:1:", 1, true) ~= nil)
		T.ok(out:find("a.lua:6:1:", 1, true) ~= nil)
		T.ok(out:find("[module=foo]", 1, true) ~= nil)
	end)

	T.it("root causes appear before cascades in rendered output", function()
		local ds = {
			diag("a.lua", 5, 1, D.E_TYPE_MISMATCH, "cascade", D.O_FROM_REQUIRE, "foo"),
			diag("a.lua", 1, 1, D.E_REQUIRE_UNRESOLVED, "root", nil, "foo"),
		}
		local out = S.render_summary(ds)
		local p_root = out:find(
			S.CATEGORY_HEADING[S.CAT_UNRESOLVED_REQUIRES], 1, true) or 0
		local p_casc = out:find(
			S.CATEGORY_HEADING[S.CAT_FROM_REQUIRE_CASCADE], 1, true) or 0
		T.ok(p_root > 0 and p_casc > 0 and p_root < p_casc)
	end)

	T.it("no-origin diagnostic categorises by code", function()
		local ds = { diag("a.lua", 1, 1, D.E_FIELD_MISSING, "no field x") }
		local out = S.render_summary(ds)
		T.ok(out:find(S.CATEGORY_HEADING[S.CAT_MISSING_FIELDS], 1, true) ~= nil)
	end)
end)
