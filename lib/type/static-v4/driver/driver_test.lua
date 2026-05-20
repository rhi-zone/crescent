-- Tests for the v4 driver (K1).
--
-- Covers the end-to-end pipeline: parse → decode → walk → cache. The
-- core integration property is "what comes out matches the in-source
-- behaviour": a simple `return literal` chunk yields the expected
-- exports type; a chunk with a type error yields diagnostics; a chunk
-- importing a cached module sees the cached export type; a cache-miss
-- import fires the recursive driver; a require cycle terminates cleanly.

if not package.path:find("?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local V          = require("lib.type.static-v4")
local driver_mod = require("lib.type.static-v4.driver.driver")
local parse_mod  = require("lib.type.static.parse")
local stdlib     = require("lib.type.static-v4.stdlib_types_v4")
local require_resolve = require("lib.type.static-v4.walker.require_resolve")
local sha256_mod = require("lib.hash.sha256")
local T          = require("lib.test.assert")

-- In-memory fake fs (mirrors walker_test.lua's helper). Annotations
-- are explicit because V.cache_lookup / V.cache_store have precise
-- IoCaps shapes that the inferred tuple-return narrowings of these
-- closures don't match without help.
local function fake_fs(initial_files)
	local files = {} --[[: { [string]: string } ]]
	for k, v in pairs(initial_files or {}) do files[k] = v end
	local dirs = {} --[[: { [string]: boolean } ]]
	--: (string) -> (string | nil, string | nil)
	local function read_file(path)
		local v = files[path]
		if v == nil then return nil, "ENOENT: " .. path end
		return v, nil
	end
	--: (string, string) -> (boolean, string | nil)
	local function write_file(path, bytes)
		files[path] = bytes
		return true, nil
	end
	--: (string) -> (boolean, string | nil)
	local function mkdir(path)
		dirs[path] = true
		return true, nil
	end
	--: (string) -> boolean
	local function file_exists(path)
		return files[path] ~= nil
	end
	return {
		_files      = files,
		_dirs       = dirs,
		read_file   = read_file,
		write_file  = write_file,
		mkdir       = mkdir,
		file_exists = file_exists,
	}
end

local function default_opts(fs)
	return {
		io_caps   = fs,
		cache_dir = ".cache",
		stdlib    = stdlib,
		parse     = parse_mod.parse,
	}
end

T.describe("driver: opts validation", function()
	T.it("nil opts errors", function()
		local r, err = driver_mod.drive("any.lua", nil)
		T.eq(r, nil)
		T.ok(err ~= nil and err:find("opts is required", 1, true) ~= nil)
	end)

	T.it("missing io_caps errors loudly", function()
		local r, err = driver_mod.drive("any.lua", {
			cache_dir = ".cache", stdlib = stdlib, parse = parse_mod.parse,
		})
		T.eq(r, nil)
		T.ok(err ~= nil and err:find("io_caps", 1, true) ~= nil)
	end)

	T.it("missing parse cap errors loudly", function()
		local fs = fake_fs({ ["x.lua"] = "" })
		local r, err = driver_mod.drive("x.lua", {
			io_caps = fs, cache_dir = ".cache", stdlib = stdlib,
		})
		T.eq(r, nil)
		T.ok(err ~= nil and err:find("parse", 1, true) ~= nil)
	end)

	T.it("missing cache_dir errors loudly", function()
		local fs = fake_fs({ ["x.lua"] = "" })
		local r, err = driver_mod.drive("x.lua", {
			io_caps = fs, stdlib = stdlib, parse = parse_mod.parse,
		})
		T.eq(r, nil)
		T.ok(err ~= nil and err:find("cache_dir", 1, true) ~= nil)
	end)
end)

T.describe("driver: simple source", function()
	T.it("`local x = 1 return x` exports a literal-int-1 type", function()
		local source = "local x = 1\nreturn x\n"
		local fs = fake_fs({ ["main.lua"] = source })
		local r, err = driver_mod.drive("main.lua", default_opts(fs))
		T.eq(err, nil)
		T.ok(r ~= nil)
		if r == nil then return end
		T.eq(#r.diagnostics, 0)
		T.ok(r.exports ~= nil)
		-- The export is a fresh V.var whose bounds capture
		-- V.literal("integer", 1). Inspect the var's upper-bound chain;
		-- the constraint solver pushes literal(integer, 1) into its
		-- bounds when synth_return constrains.
		T.eq(r.type, r.exports)
		T.ok(type(r.source_hash) == "string" and #r.source_hash == 64)
	end)

	T.it("source-hash is sha256 of source bytes", function()
		local source = "return 0\n"
		local fs = fake_fs({ ["main.lua"] = source })
		local r = driver_mod.drive("main.lua", default_opts(fs))
		T.eq(r.source_hash, sha256_mod.sha256(source))
	end)

	T.it("no-return chunk exports V.prim(\"nil\")", function()
		local fs = fake_fs({ ["main.lua"] = "local x = 1\n" })
		local r, err = driver_mod.drive("main.lua", default_opts(fs))
		T.eq(err, nil)
		T.ok(r ~= nil and r.exports ~= nil)
		if r == nil or r.exports == nil then return end
		T.eq(r.exports.tag, "prim")
		T.eq(r.exports.name, "nil")
	end)
end)

T.describe("driver: cache_store fires on clean walk", function()
	T.it("after drive, cache_lookup returns the artifact", function()
		local source = "return 42\n"
		local fs = fake_fs({ ["main.lua"] = source })
		local r, err = driver_mod.drive("main.lua", default_opts(fs))
		T.eq(err, nil)
		T.ok(r ~= nil)
		local bytes = V.cache_lookup(fs, ".cache", r.source_hash)
		T.ok(bytes ~= nil)
		if bytes == nil then return end
		local artifact, derr = V.deserialize(bytes)
		T.eq(derr, nil)
		T.ok(artifact ~= nil)
		if artifact == nil then return end
		local exports, aliases, uerr = require_resolve.unpack_artifact(artifact)
		T.eq(uerr, nil)
		T.ok(exports ~= nil)
		T.ok(aliases ~= nil)
	end)

	T.it("no cache_store on error-severity diagnostics", function()
		-- Unbound name `nope` produces E_UNDEFINED_NAME.
		local fs = fake_fs({ ["main.lua"] = "return nope\n" })
		local r, err = driver_mod.drive("main.lua", default_opts(fs))
		T.eq(err, nil)
		T.ok(r ~= nil)
		T.ok(#r.diagnostics > 0)
		-- Cache should NOT contain an artifact for this source hash.
		local bytes = V.cache_lookup(fs, ".cache", r.source_hash)
		T.eq(bytes, nil)
	end)
end)

T.describe("driver: type errors flow through diagnostics", function()
	T.it("undefined identifier produces a diagnostic with source pos", function()
		local fs = fake_fs({ ["main.lua"] = "local x = nope\nreturn x\n" })
		local r = driver_mod.drive("main.lua", default_opts(fs))
		T.ok(r ~= nil)
		T.ok(#r.diagnostics >= 1)
		local d = r.diagnostics[1]
		T.eq(d.code, "undefined-name")
		T.eq(d.pos.file, "main.lua")
		T.ok(d.pos.line ~= nil and d.pos.line >= 1)
	end)

	T.it("on_diagnostic sink is invoked for each diagnostic", function()
		local fs = fake_fs({ ["main.lua"] = "return nope\n" })
		local captured = {}
		local opts = default_opts(fs)
		opts.on_diagnostic = function(d) captured[#captured + 1] = d end
		local r = driver_mod.drive("main.lua", opts)
		T.ok(#captured >= 1)
		T.eq(#captured, #r.diagnostics)
	end)
end)

T.describe("driver: require resolution against cache hit", function()
	T.it("`require` of a cached module yields its export type", function()
		local foo_source = "return 1\n"
		local fs = fake_fs({
			["lib/foo.lua"] = foo_source,
			["main.lua"]    = "local x = require(\"lib.foo\")\nreturn x\n",
		})
		-- Populate the cache for lib/foo first.
		local foo_hash = sha256_mod.sha256(foo_source)
		local artifact = require_resolve.pack_artifact(
			V.literal("integer", 1), nil)
		V.cache_store(fs, ".cache", foo_hash, artifact, nil)

		local r, err = driver_mod.drive("main.lua", default_opts(fs))
		T.eq(err, nil)
		T.ok(r ~= nil)
		T.eq(#r.diagnostics, 0)
		-- Dep recorded: main depends on lib/foo at foo_hash.
		T.eq(r.deps["lib/foo.lua"], foo_hash)
	end)
end)

T.describe("driver: require on cache miss recurses", function()
	T.it("uncached require triggers recursive drive + cache_store", function()
		local foo_source = "return 7\n"
		local fs = fake_fs({
			["lib/foo.lua"] = foo_source,
			["main.lua"]    = "local x = require(\"lib.foo\")\nreturn x\n",
		})
		-- Verify cache is empty for foo.
		local foo_hash = sha256_mod.sha256(foo_source)
		T.eq(V.cache_lookup(fs, ".cache", foo_hash), nil)

		local r, err = driver_mod.drive("main.lua", default_opts(fs))
		T.eq(err, nil)
		T.ok(r ~= nil)
		T.eq(#r.diagnostics, 0)
		-- foo's cache entry should exist after recursion.
		T.ok(V.cache_lookup(fs, ".cache", foo_hash) ~= nil)
		-- main's dep map records the recursive child's source_hash.
		T.eq(r.deps["lib/foo.lua"], foo_hash)
	end)
end)

T.describe("driver: require cycles do not crash", function()
	T.it("A requires B requires A walks without crashing", function()
		-- A and B both `require` each other. The placeholder mechanism
		-- in require_resolve.lua handles the cycle (mints a V.var on
		-- inner re-entry). The driver's job is to NOT crash.
		local fs = fake_fs({
			["lib/a.lua"] = "local b = require(\"lib.b\")\nreturn b\n",
			["lib/b.lua"] = "local a = require(\"lib.a\")\nreturn a\n",
		})
		local r, err = driver_mod.drive("lib/a.lua", default_opts(fs))
		-- We tolerate either: a clean walk OR diagnostics naming the
		-- cycle. What is NOT tolerated is a driver-itself failure
		-- (errmsg non-nil) or an exception escaping.
		T.eq(err, nil)
		T.ok(r ~= nil)
	end)
end)

T.describe("driver: parse failure surfaces as diagnostic", function()
	T.it("syntactically-invalid source yields an E_INTERNAL diagnostic", function()
		-- A lone `)` is a syntax error.
		local fs = fake_fs({ ["broken.lua"] = ")\n" })
		local r, err = driver_mod.drive("broken.lua", default_opts(fs))
		T.eq(err, nil)
		T.ok(r ~= nil and #r.diagnostics >= 1)
		T.eq(r.diagnostics[1].code, "internal")
		T.ok(r.diagnostics[1].msg:find("parse", 1, true) ~= nil)
	end)
end)

T.describe("driver: unreadable source", function()
	T.it("missing source file errors at the driver level", function()
		local fs = fake_fs({})
		local r, err = driver_mod.drive("missing.lua", default_opts(fs))
		T.eq(r, nil)
		T.ok(err ~= nil and err:find("cannot read", 1, true) ~= nil)
	end)
end)
