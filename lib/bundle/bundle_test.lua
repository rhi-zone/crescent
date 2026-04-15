-- lib/bundle/bundle_test.lua — tests for lib/bundle/init.lua

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local bundle = require("lib.bundle")

-- ── helpers ──────────────────────────────────────────────────────────────────

--- Build a resolver from a table of { [module_name] = source_string }.
local function make_resolver(modules)
	return function(name)
		return modules[name]
	end
end

--- Load and execute a bundled string, returning the result.
local function exec(code, desc)
	local fn, err = load(code, desc or "bundle")
	if not fn then return nil, err end
	return pcall(fn)
end

-- ── extract_requires ─────────────────────────────────────────────────────────

T.describe("extract_requires", function()
	T.it("finds double-quoted require", function()
		local deps = bundle._extract_requires('local x = require("foo")')
		T.eq(#deps, 1)
		T.eq(deps[1], "foo")
	end)

	T.it("finds single-quoted require", function()
		local deps = bundle._extract_requires("local x = require('bar')")
		T.eq(#deps, 1)
		T.eq(deps[1], "bar")
	end)

	T.it("finds dotted module names", function()
		local deps = bundle._extract_requires('require("lib.foo.bar")')
		T.eq(#deps, 1)
		T.eq(deps[1], "lib.foo.bar")
	end)

	T.it("finds multiple requires", function()
		local src = [[
local a = require("mod_a")
local b = require("mod_b")
local c = require("mod_c")
]]
		local deps = bundle._extract_requires(src)
		T.eq(#deps, 3)
		T.eq(deps[1], "mod_a")
		T.eq(deps[2], "mod_b")
		T.eq(deps[3], "mod_c")
	end)

	T.it("deduplicates repeated requires", function()
		local src = [[
local a = require("dup")
local b = require("dup")
]]
		local deps = bundle._extract_requires(src)
		T.eq(#deps, 1)
		T.eq(deps[1], "dup")
	end)

	T.it("returns empty table when no requires", function()
		local deps = bundle._extract_requires("local x = 42")
		T.eq(#deps, 0)
	end)

	T.it("finds require with spaces around parens", function()
		local deps = bundle._extract_requires('require ( "spaced" )')
		T.eq(#deps, 1)
		T.eq(deps[1], "spaced")
	end)

	T.it("finds require inside a function body", function()
		local src = [[
local function init()
	local m = require("nested")
	return m
end
]]
		local deps = bundle._extract_requires(src)
		T.eq(#deps, 1)
		T.eq(deps[1], "nested")
	end)
end)

-- ── bundle_string — single module ────────────────────────────────────────────

T.describe("bundle_string — single module", function()
	T.it("inlines a single dependency", function()
		local modules = {
			["mymod"] = "local M = {} M.value = 42 return M",
		}
		local entry = 'local m = require("mymod")\nreturn m.value'
		local out, err = bundle.bundle_string(entry, { resolve = make_resolver(modules) })
		T.ok(out, "should produce output")
		T.eq(err, nil)
		-- Output should contain the module wrapper
		T.ok(out:find('__modules%["mymod"%]'), "should contain module definition")
	end)

	T.it("output is valid and executable Lua", function()
		local modules = {
			["mymod"] = "local M = {} M.value = 42 return M",
		}
		local entry = 'local m = require("mymod")\nreturn m.value'
		local out = bundle.bundle_string(entry, { resolve = make_resolver(modules) })
		local ok, result = exec(out)
		T.ok(ok, "should execute without error")
		T.eq(result, 42)
	end)

	T.it("module loaded only once even if required twice", function()
		local modules = {
			["counter"] = "local M = {} M.count = 0 M.count = M.count + 1 return M",
		}
		local entry = [[
local a = require("counter")
local b = require("counter")
return a.count == b.count and a == b
]]
		local out = bundle.bundle_string(entry, { resolve = make_resolver(modules) })
		local ok, result = exec(out)
		T.ok(ok, "should execute")
		T.eq(result, true, "same cached instance returned")
	end)
end)

-- ── bundle_string — transitive dependencies ──────────────────────────────────

T.describe("bundle_string — transitive deps", function()
	T.it("resolves A -> B -> C", function()
		local modules = {
			["mod_c"] = "return { name = 'C' }",
			["mod_b"] = 'local c = require("mod_c")\nreturn { name = "B", child = c }',
			["mod_a"] = 'local b = require("mod_b")\nreturn { name = "A", child = b }',
		}
		local entry = 'local a = require("mod_a")\nreturn a.child.child.name'
		local out = bundle.bundle_string(entry, { resolve = make_resolver(modules) })
		local ok, result = exec(out)
		T.ok(ok, "should execute")
		T.eq(result, "C")
	end)

	T.it("deep chain: D -> C -> B -> A", function()
		local modules = {
			["a"] = "return 1",
			["b"] = 'return require("a") + 1',
			["c"] = 'return require("b") + 1',
			["d"] = 'return require("c") + 1',
		}
		local entry = 'return require("d")'
		local out = bundle.bundle_string(entry, { resolve = make_resolver(modules) })
		local ok, result = exec(out)
		T.ok(ok, "should execute")
		T.eq(result, 4)
	end)

	T.it("diamond dependency: A requires B and C, both require D", function()
		local modules = {
			["d"] = "return { n = 0 }",
			["b"] = 'local d = require("d") d.n = d.n + 1 return d',
			["c"] = 'local d = require("d") d.n = d.n + 10 return d',
		}
		local entry = [[
local b = require("b")
local c = require("c")
return b.n
]]
		local out = bundle.bundle_string(entry, { resolve = make_resolver(modules) })
		local ok, result = exec(out)
		T.ok(ok, "should execute")
		-- D is loaded once; B adds 1 (n=1), then C adds 10 (n=11).
		-- b and c reference the same D instance.
		T.eq(result, 11)
	end)
end)

-- ── bundle_string — circular dependencies ────────────────────────────────────

T.describe("bundle_string — circular deps", function()
	T.it("handles simple circular reference gracefully", function()
		-- In real Lua, circular requires return the partial module table.
		-- Our bundler visits each module once (visited set), so circular
		-- requires just reference the cached (possibly partial) value.
		local modules = {
			["circ_a"] = 'local b = require("circ_b")\nreturn { a = true, b_ref = b }',
			["circ_b"] = 'local a = require("circ_a")\nreturn { b = true, a_ref = a }',
		}
		local entry = 'local a = require("circ_a")\nreturn a.a'
		local out, err = bundle.bundle_string(entry, { resolve = make_resolver(modules) })
		T.ok(out, "should produce output even with circular deps")
		T.eq(err, nil)
		-- The output should be loadable — circular require returns `true` (cache sentinel)
		local ok, result = exec(out)
		T.ok(ok, "should execute")
		T.eq(result, true)
	end)
end)

-- ── bundle_string — unresolvable modules ─────────────────────────────────────

T.describe("bundle_string — unresolvable modules", function()
	T.it("unresolved require falls through to real require in output", function()
		local entry = 'local m = require("nonexistent_xyz")\nreturn true'
		local out = bundle.bundle_string(entry, { resolve = make_resolver({}) })
		T.ok(out, "should produce output")
		-- The output should NOT have a __modules entry for nonexistent_xyz
		T.ok(not out:find('__modules%["nonexistent_xyz"%]'), "no module wrapper for unresolved")
		-- The output still references the real require as fallback
		T.ok(out:find("require(name)", 1, true), "fallback to real require")
	end)

	T.it("mix of resolved and unresolved", function()
		local modules = {
			["found"] = "return 99",
		}
		local entry = [[
local a = require("found")
local b = require("missing")
return a
]]
		local out = bundle.bundle_string(entry, { resolve = make_resolver(modules) })
		T.ok(out:find('__modules%["found"%]'), "resolved module present")
		T.ok(not out:find('__modules%["missing"%]'), "unresolved module absent")
	end)
end)

-- ── bundle_string — shebang option ───────────────────────────────────────────

T.describe("bundle_string — shebang", function()
	T.it("prepends shebang when specified", function()
		local entry = "return 1"
		local out = bundle.bundle_string(entry, {
			resolve = make_resolver({}),
			shebang = "#!/usr/bin/env luajit",
		})
		T.ok(out:sub(1, 2) == "#!", "starts with shebang")
		T.ok(out:find("#!/usr/bin/env luajit\n", 1, true), "exact shebang line")
	end)

	T.it("no shebang by default", function()
		local entry = "return 1"
		local out = bundle.bundle_string(entry, { resolve = make_resolver({}) })
		T.ok(out:sub(1, 5) == "local", "starts with local (no shebang)")
	end)
end)

-- ── bundle_string — module returning nil/false ───────────────────────────────

T.describe("bundle_string — edge cases", function()
	T.it("module returning nil gets cached as true", function()
		local modules = {
			["nilmod"] = "-- does nothing, returns nil implicitly",
		}
		local entry = [[
local a = require("nilmod")
local b = require("nilmod")
return a == b
]]
		local out = bundle.bundle_string(entry, { resolve = make_resolver(modules) })
		local ok, result = exec(out)
		T.ok(ok, "should execute")
		T.eq(result, true, "both references get same cached value (true sentinel)")
	end)

	T.it("module returning false gets cached as false", function()
		local modules = {
			["falsemod"] = "return false",
		}
		-- Unlike standard Lua's require (which stores true for false returns),
		-- our bundler preserves the actual return value. The sentinel (true) is
		-- only used when the loader returns nil.
		local entry = 'return require("falsemod")'
		local out = bundle.bundle_string(entry, { resolve = make_resolver(modules) })
		local ok, result = exec(out)
		T.ok(ok, "should execute")
		T.eq(result, false)
	end)

	T.it("module returning a table", function()
		local modules = {
			["tblmod"] = "return { x = 1, y = 2 }",
		}
		local entry = 'local t = require("tblmod")\nreturn t.x + t.y'
		local out = bundle.bundle_string(entry, { resolve = make_resolver(modules) })
		local ok, result = exec(out)
		T.ok(ok, "should execute")
		T.eq(result, 3)
	end)

	T.it("module returning a string", function()
		local modules = {
			["strmod"] = 'return "hello"',
		}
		local entry = 'return require("strmod")'
		local out = bundle.bundle_string(entry, { resolve = make_resolver(modules) })
		local ok, result = exec(out)
		T.ok(ok, "should execute")
		T.eq(result, "hello")
	end)

	T.it("module returning a number", function()
		local modules = {
			["nummod"] = "return 3.14",
		}
		local entry = 'return require("nummod")'
		local out = bundle.bundle_string(entry, { resolve = make_resolver(modules) })
		local ok, result = exec(out)
		T.ok(ok, "should execute")
		T.eq(result, 3.14)
	end)

	T.it("empty source string", function()
		local out, err = bundle.bundle_string("", { resolve = make_resolver({}) })
		T.ok(out, "should produce output for empty source")
		T.eq(err, nil)
		local ok = exec(out)
		T.ok(ok, "empty bundle should be loadable")
	end)
end)

-- ── analyze_string ───────────────────────────────────────────────────────────

T.describe("analyze_string", function()
	T.it("returns direct dependencies in order", function()
		local modules = {
			["alpha"] = "return 1",
			["beta"] = "return 2",
		}
		local entry = 'require("alpha")\nrequire("beta")'
		local deps = bundle.analyze_string(entry, { resolve = make_resolver(modules) })
		T.eq(#deps, 2)
		T.eq(deps[1], "alpha")
		T.eq(deps[2], "beta")
	end)

	T.it("returns transitive dependencies (leaves first)", function()
		local modules = {
			["leaf"] = "return 1",
			["mid"] = 'require("leaf") return 2',
			["top"] = 'require("mid") return 3',
		}
		local entry = 'require("top")'
		local deps = bundle.analyze_string(entry, { resolve = make_resolver(modules) })
		T.eq(#deps, 3)
		T.eq(deps[1], "leaf")
		T.eq(deps[2], "mid")
		T.eq(deps[3], "top")
	end)

	T.it("skips unresolvable modules", function()
		local modules = {
			["real"] = "return 1",
		}
		local entry = 'require("real")\nrequire("fake")'
		local deps = bundle.analyze_string(entry, { resolve = make_resolver(modules) })
		T.eq(#deps, 1)
		T.eq(deps[1], "real")
	end)

	T.it("no duplicates in output", function()
		local modules = {
			["shared"] = "return {}",
			["a"] = 'require("shared") return 1',
			["b"] = 'require("shared") return 2',
		}
		local entry = 'require("a")\nrequire("b")'
		local deps = bundle.analyze_string(entry, { resolve = make_resolver(modules) })
		-- shared appears once (from a's recursion), a, then b
		T.eq(#deps, 3)
		T.eq(deps[1], "shared")
		T.eq(deps[2], "a")
		T.eq(deps[3], "b")
	end)

	T.it("empty source returns empty list", function()
		local deps = bundle.analyze_string("", { resolve = make_resolver({}) })
		T.eq(#deps, 0)
	end)
end)

-- ── bundle_string — error cases ──────────────────────────────────────────────

T.describe("bundle_string — errors", function()
	T.it("returns nil and error for non-string source", function()
		local out, err = bundle.bundle_string(123)
		T.eq(out, nil)
		T.ok(err:find("string"), "error mentions string")
	end)

	T.it("returns nil and error for nil source", function()
		local out, err = bundle.bundle_string(nil)
		T.eq(out, nil)
		T.ok(err, "should have error message")
	end)
end)

-- ── bundle_string — output structure ─────────────────────────────────────────

T.describe("bundle_string — output structure", function()
	T.it("output has preamble, module defs, and entry", function()
		local modules = {
			["m1"] = "return 1",
		}
		local entry = 'return require("m1")'
		local out = bundle.bundle_string(entry, { resolve = make_resolver(modules) })
		-- Check structural elements
		T.ok(out:find("local __modules = {}"), "has __modules decl")
		T.ok(out:find("local __cache = {}"), "has __cache decl")
		T.ok(out:find("local __require = function"), "has __require decl")
		T.ok(out:find('__modules%["m1"%] = function'), "has module definition")
		T.ok(out:find("local require = __require"), "entry uses custom require")
	end)

	T.it("each module gets local require = __require", function()
		local modules = {
			["inner"] = "return 1",
		}
		local entry = 'return require("inner")'
		local out = bundle.bundle_string(entry, { resolve = make_resolver(modules) })
		-- Count occurrences of "local require = __require"
		local count = 0
		for _ in out:gmatch("local require = __require") do
			count = count + 1
		end
		-- One inside the module wrapper + one for the entry point
		T.eq(count, 2, "two local require rebindings")
	end)
end)

-- ── bundle_string — complex scenarios ────────────────────────────────────────

T.describe("bundle_string — complex scenarios", function()
	T.it("module with multiline source preserves structure", function()
		local modules = {
			["multi"] = "local M = {}\nfunction M.add(a, b)\n\treturn a + b\nend\nreturn M",
		}
		local entry = 'local m = require("multi")\nreturn m.add(3, 4)'
		local out = bundle.bundle_string(entry, { resolve = make_resolver(modules) })
		local ok, result = exec(out)
		T.ok(ok, "should execute")
		T.eq(result, 7)
	end)

	T.it("module using closures and upvalues", function()
		local modules = {
			["closure"] = [[
local count = 0
local M = {}
function M.inc() count = count + 1 return count end
return M
]],
		}
		local entry = [[
local c = require("closure")
c.inc()
c.inc()
return c.inc()
]]
		local out = bundle.bundle_string(entry, { resolve = make_resolver(modules) })
		local ok, result = exec(out)
		T.ok(ok, "should execute")
		T.eq(result, 3)
	end)

	T.it("mixed resolved/unresolved in execution", function()
		-- string module is a builtin, so require("string") should work
		local modules = {
			["helper"] = 'return { greet = function(name) return "hi " .. name end }',
		}
		local entry = [[
local h = require("helper")
return h.greet("world")
]]
		local out = bundle.bundle_string(entry, { resolve = make_resolver(modules) })
		local ok, result = exec(out)
		T.ok(ok, "should execute")
		T.eq(result, "hi world")
	end)

	T.it("five modules in a chain produce correct result", function()
		local modules = {
			["e"] = "return 1",
			["d"] = 'return require("e") * 2',
			["c"] = 'return require("d") * 2',
			["b"] = 'return require("c") * 2',
			["a"] = 'return require("b") * 2',
		}
		local entry = 'return require("a")'
		local out = bundle.bundle_string(entry, { resolve = make_resolver(modules) })
		local ok, result = exec(out)
		T.ok(ok, "should execute")
		T.eq(result, 16, "1 * 2^4 = 16")
	end)

	T.it("require with single quotes works identically", function()
		local modules = {
			["sq"] = "return 'single'",
		}
		local entry = "return require('sq')"
		local out = bundle.bundle_string(entry, { resolve = make_resolver(modules) })
		local ok, result = exec(out)
		T.ok(ok, "should execute")
		T.eq(result, "single")
	end)

	T.it("require inside conditional branch", function()
		local modules = {
			["cond"] = "return 77",
		}
		local entry = [[
local x
if true then
	x = require("cond")
end
return x
]]
		local out = bundle.bundle_string(entry, { resolve = make_resolver(modules) })
		local ok, result = exec(out)
		T.ok(ok, "should execute")
		T.eq(result, 77)
	end)

	T.it("require inside loop body", function()
		local modules = {
			["loopmod"] = "local M = { n = 0 } function M.bump() M.n = M.n + 1 end return M",
		}
		local entry = [[
for i = 1, 5 do
	require("loopmod").bump()
end
return require("loopmod").n
]]
		local out = bundle.bundle_string(entry, { resolve = make_resolver(modules) })
		local ok, result = exec(out)
		T.ok(ok, "should execute")
		T.eq(result, 5)
	end)

	T.it("module with package.path manipulation is inlined as-is", function()
		-- The package.path line in the module becomes dead code inside the wrapper,
		-- but it shouldn't cause errors.
		local modules = {
			["pathmod"] = [[
if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end
local M = {}
M.ok = true
return M
]],
		}
		local entry = 'return require("pathmod").ok'
		local out = bundle.bundle_string(entry, { resolve = make_resolver(modules) })
		local ok, result = exec(out)
		T.ok(ok, "should execute")
		T.eq(result, true)
	end)
end)

-- ── bundle — error on missing entry file ─────────────────────────────────────

T.describe("bundle — file-based", function()
	local function read_fn(path)
		local f = io.open(path, "r")
		if not f then return nil end
		local content = f:read("*a")
		f:close()
		return content
	end

	T.it("returns error for nonexistent entry file", function()
		local out, err = bundle.bundle("/nonexistent/path/to/entry.lua", { read_fn = read_fn })
		T.eq(out, nil)
		T.ok(err:find("cannot read"), "error mentions cannot read")
	end)
end)

-- ── analyze — error on missing entry file ────────────────────────────────────

T.describe("analyze — file-based", function()
	local function read_fn(path)
		local f = io.open(path, "r")
		if not f then return nil end
		local content = f:read("*a")
		f:close()
		return content
	end

	T.it("returns error for nonexistent entry file", function()
		local deps, err = bundle.analyze("/nonexistent/path/to/entry.lua", { read_fn = read_fn })
		T.eq(deps, nil)
		T.ok(err:find("cannot read"), "error mentions cannot read")
	end)
end)
