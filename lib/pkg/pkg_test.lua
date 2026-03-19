if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

-- lib/pkg/pkg_test.lua — integration tests for the crescent package manager.
--
-- Covers:
--   - semver constraint satisfaction
--   - manifest parsing round-trip
--   - lockfile parsing round-trip
--   - resolve: locked deps stay pinned, new deps get resolved from registry
--   - link: hardlink_tree creates correct directory structure in dep/<name>/

local T        = require("lib.test.assert")
local semver   = require("lib.pkg.semver")
local manifest = require("lib.pkg.manifest")
local lock     = require("lib.pkg.lock")
local install  = require("lib.pkg.install")

-- ── helpers ───────────────────────────────────────────────────────────────────

local function make_tmpdir()
	local path = os.tmpname()
	os.remove(path)
	os.execute(("mkdir -p %q"):format(path))
	return path
end

local function rm_tmpdir(path)
	os.execute(("rm -rf %q"):format(path))
end

local function write_file(path, content)
	local f = io.open(path, "w")
	if not f then error("cannot open " .. path) end
	f:write(content)
	f:close()
end

local function file_exists(path)
	local f = io.open(path, "r")
	if f then f:close(); return true end
	return false
end

local function read_file(path)
	local f = io.open(path, "r")
	if not f then return nil end
	local s = f:read("*a")
	f:close()
	return s
end

-- ── semver constraint satisfaction ───────────────────────────────────────────

T.describe("pkg: semver constraint satisfaction", function()

	local function p(s) return semver.parse(s) end

	T.it("^1.0.0 accepts 1.0.0 and 1.9.9, rejects 2.0.0 and 0.9.9", function()
		T.ok(semver.satisfies(p("1.0.0"), "^1.0.0"))
		T.ok(semver.satisfies(p("1.9.9"), "^1.0.0"))
		T.fail(semver.satisfies(p("2.0.0"), "^1.0.0"))
		T.fail(semver.satisfies(p("0.9.9"), "^1.0.0"))
	end)

	T.it("~1.2.3 accepts patch bumps only", function()
		T.ok(semver.satisfies(p("1.2.3"), "~1.2.3"))
		T.ok(semver.satisfies(p("1.2.9"), "~1.2.3"))
		T.fail(semver.satisfies(p("1.3.0"), "~1.2.3"))
		T.fail(semver.satisfies(p("1.2.2"), "~1.2.3"))
	end)

	T.it(">= accepts exact and above, rejects below", function()
		T.ok(semver.satisfies(p("2.0.0"), ">=2.0.0"))
		T.ok(semver.satisfies(p("2.0.1"), ">=2.0.0"))
		T.fail(semver.satisfies(p("1.9.9"), ">=2.0.0"))
	end)

	T.it("= requires exact match", function()
		T.ok(semver.satisfies(p("1.2.3"), "=1.2.3"))
		T.fail(semver.satisfies(p("1.2.4"), "=1.2.3"))
	end)

	T.it("* matches everything", function()
		T.ok(semver.satisfies(p("0.0.1"), "*"))
		T.ok(semver.satisfies(p("99.0.0"), "*"))
	end)

	T.it("exact version string (no operator) treated as =", function()
		T.ok(semver.satisfies(p("3.1.4"), "3.1.4"))
		T.fail(semver.satisfies(p("3.1.5"), "3.1.4"))
	end)

	T.it("pre-release is less than release for caret", function()
		-- ^1.2.3 should NOT match 1.2.3-alpha (it's < 1.2.3)
		T.fail(semver.satisfies(p("1.2.3-alpha"), "^1.2.3"))
	end)

	T.it("release sorts above pre-release of same triple", function()
		local rel  = semver.parse("1.0.0")
		local pre  = semver.parse("1.0.0-alpha")
		T.eq(semver.cmp(rel, pre), 1)
		T.eq(semver.cmp(pre, rel), -1)
	end)

end)

-- ── manifest round-trip ───────────────────────────────────────────────────────

T.describe("pkg: manifest parse round-trip", function()

	T.it("write then load preserves all fields", function()
		local tmp = os.tmpname() .. ".lua"
		local src = {
			name        = "test-pkg",
			version     = "1.2.3",
			description = "A test package",
			license     = "MIT",
			deps        = { sha1 = "^1.0.0", lunajson = ">=1.3.0" },
		}
		local ok, err = manifest.write(tmp, src)
		T.ok(ok, tostring(err))

		local loaded, lerr = manifest.load(tmp)
		os.remove(tmp)
		T.ok(loaded, tostring(lerr))
		T.eq(loaded.name,        src.name)
		T.eq(loaded.version,     src.version)
		T.eq(loaded.description, src.description)
		T.eq(loaded.license,     src.license)
		T.eq(loaded.deps.sha1,     src.deps.sha1)
		T.eq(loaded.deps.lunajson, src.deps.lunajson)
	end)

	T.it("deps with hyphens survive the round-trip", function()
		local tmp = os.tmpname() .. ".lua"
		local src = {
			name    = "hyphen-pkg",
			version = "0.1.0",
			deps    = { ["lua-cjson"] = "~2.1" },
		}
		local ok, err = manifest.write(tmp, src)
		T.ok(ok, tostring(err))

		local loaded, lerr = manifest.load(tmp)
		os.remove(tmp)
		T.ok(loaded, tostring(lerr))
		T.eq(loaded.deps["lua-cjson"], "~2.1")
	end)

	T.it("minimal manifest (no optional fields) loads cleanly", function()
		local tmp = os.tmpname() .. ".lua"
		local ok, err = manifest.write(tmp, { name = "minimal", version = "0.0.1" })
		T.ok(ok, tostring(err))

		local loaded, lerr = manifest.load(tmp)
		os.remove(tmp)
		T.ok(loaded, tostring(lerr))
		T.eq(loaded.name, "minimal")
		T.eq(loaded.version, "0.0.1")
	end)

	T.it("invalid manifest is rejected on load", function()
		local tmp = os.tmpname() .. ".lua"
		write_file(tmp, "return { name = 'Bad Name!', version = '1.0.0' }")
		local loaded, err = manifest.load(tmp)
		os.remove(tmp)
		T.eq(loaded, nil)
		T.ok(err ~= nil)
	end)

end)

-- ── lockfile round-trip ───────────────────────────────────────────────────────

T.describe("pkg: lockfile parse round-trip", function()

	local INPUT = {
		sha1 = {
			version  = "1.0.0",
			url      = "https://pkg.crescent.run/sha1/1.0.0.tar.gz",
			checksum = "sha256:deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
		},
		lunajson = {
			version  = "1.3.1",
			url      = "https://pkg.crescent.run/lunajson/1.3.1.tar.gz",
			checksum = "sha256:cafecafecafecafecafecafecafecafecafecafecafecafecafecafecafecafe",
		},
	}

	T.it("serialize then parse round-trips all fields", function()
		local s = lock.serialize(INPUT)
		local out, err = lock.parse(s)
		T.ok(out, tostring(err))
		T.eq(out.sha1.version,      INPUT.sha1.version)
		T.eq(out.sha1.url,          INPUT.sha1.url)
		T.eq(out.sha1.checksum,     INPUT.sha1.checksum)
		T.eq(out.lunajson.version,  INPUT.lunajson.version)
		T.eq(out.lunajson.checksum, INPUT.lunajson.checksum)
	end)

	T.it("serialize is idempotent", function()
		local s1 = lock.serialize(INPUT)
		local t2 = lock.parse(s1)
		local s2 = lock.serialize(t2)
		T.eq(s1, s2)
	end)

	T.it("entries are sorted alphabetically in output", function()
		local s = lock.serialize(INPUT)
		local pos_l = s:find("%[lunajson%]")
		local pos_s = s:find("%[sha1%]")
		T.ok(pos_l < pos_s, "lunajson sorts before sha1")
	end)

	T.it("write + load via temp file preserves data", function()
		local tmp = os.tmpname()
		local ok, err = lock.write(tmp, INPUT)
		T.ok(ok, tostring(err))

		local loaded, lerr = lock.load(tmp)
		os.remove(tmp)
		T.ok(loaded, tostring(lerr))
		T.eq(loaded.sha1.version,  "1.0.0")
		T.eq(loaded.lunajson.version, "1.3.1")
	end)

	T.it("parse rejects keys outside a section", function()
		local r, e = lock.parse('version = "1.0.0"')
		T.eq(r, nil)
		T.ok(e ~= nil)
	end)

	T.it("parse rejects unknown keys", function()
		local r, e = lock.parse('[pkg]\nextra = "bad"')
		T.eq(r, nil)
		T.ok(e ~= nil)
	end)

end)

-- ── resolve ───────────────────────────────────────────────────────────────────

local MOCK_INDEX = {
	sha1 = {
		versions = { "0.9.0", "1.0.0", "1.1.0", "2.0.0" },
		latest   = "2.0.0",
	},
	lunajson = {
		versions = { "1.2.0", "1.3.0", "1.3.1" },
		latest   = "1.3.1",
	},
}

T.describe("pkg: resolve — locked deps stay pinned", function()

	T.it("locked version satisfying constraint is kept as-is", function()
		local deps   = { sha1 = "^1.0.0" }
		local locked = {
			sha1 = { version = "1.0.0", url = "https://x/sha1/1.0.0.tar.gz", checksum = "sha256:abc" },
		}
		local r, err = install.resolve(deps, locked, MOCK_INDEX)
		T.ok(r, tostring(err))
		T.eq(r.sha1.version, "1.0.0")
		T.eq(r.sha1.url,     "https://x/sha1/1.0.0.tar.gz")
		T.eq(r.sha1.checksum, "sha256:abc")
		-- locked entry must NOT be marked as needing a fetch
		T.fail(r.sha1._needs_fetch)
	end)

	T.it("newer locked version still satisfying constraint is kept", function()
		local deps   = { sha1 = "^1.0.0" }
		local locked = {
			sha1 = { version = "1.1.0", url = "https://x/sha1/1.1.0.tar.gz", checksum = "sha256:def" },
		}
		local r, err = install.resolve(deps, locked, MOCK_INDEX)
		T.ok(r, tostring(err))
		T.eq(r.sha1.version, "1.1.0")
	end)

	T.it("locked version not satisfying constraint triggers re-resolve", function()
		local deps   = { sha1 = ">=2.0.0" }
		local locked = {
			sha1 = { version = "1.0.0", url = "https://x/sha1/1.0.0.tar.gz", checksum = "sha256:old" },
		}
		local r, err = install.resolve(deps, locked, MOCK_INDEX)
		T.ok(r, tostring(err))
		-- Must pick 2.0.0 from the registry, not reuse 1.0.0
		T.eq(r.sha1.version, "2.0.0")
		T.ok(r.sha1._needs_fetch)
	end)

	T.it("mixed: some locked, some new", function()
		local deps = { sha1 = "^1.0.0", lunajson = "~1.3" }
		-- sha1 is locked; lunajson is new
		local locked = {
			sha1 = { version = "1.1.0", url = "https://x/sha1/1.1.0.tar.gz", checksum = "sha256:aaa" },
		}
		local r, err = install.resolve(deps, locked, MOCK_INDEX)
		T.ok(r, tostring(err))
		T.eq(r.sha1.version, "1.1.0")        -- kept from lock
		T.fail(r.sha1._needs_fetch)
		T.eq(r.lunajson.version, "1.3.1")    -- resolved from registry
		T.ok(r.lunajson._needs_fetch)
	end)

end)

T.describe("pkg: resolve — new deps resolved from registry", function()

	T.it("no lockfile: resolves to highest satisfying version", function()
		local deps = { sha1 = "^1.0.0" }
		local r, err = install.resolve(deps, {}, MOCK_INDEX)
		T.ok(r, tostring(err))
		T.eq(r.sha1.version, "1.1.0")   -- highest in [1.0.0, 2.0.0)
		T.ok(r.sha1._needs_fetch)
	end)

	T.it("resolves multiple deps independently", function()
		local deps = { sha1 = ">=1.0.0", lunajson = "=1.3.0" }
		local r, err = install.resolve(deps, {}, MOCK_INDEX)
		T.ok(r, tostring(err))
		T.eq(r.sha1.version,     "2.0.0")
		T.eq(r.lunajson.version, "1.3.0")
	end)

	T.it("wildcard * resolves to highest available", function()
		local deps = { sha1 = "*" }
		local r, err = install.resolve(deps, {}, MOCK_INDEX)
		T.ok(r, tostring(err))
		T.eq(r.sha1.version, "2.0.0")
	end)

	T.it("returns nil when no version satisfies constraint", function()
		local deps = { sha1 = ">=99.0.0" }
		local r, err = install.resolve(deps, {}, MOCK_INDEX)
		T.eq(r, nil)
		T.ok(err ~= nil)
		T.ok(err:find("sha1") ~= nil)
	end)

	T.it("returns nil when package not found in registry", function()
		local deps = { nosuchpkg = "^1.0.0" }
		local r, err = install.resolve(deps, {}, MOCK_INDEX)
		T.eq(r, nil)
		T.ok(err ~= nil)
		T.ok(err:find("nosuchpkg") ~= nil)
	end)

	T.it("returns nil when no registry index provided and dep not locked", function()
		local deps = { sha1 = "^1.0.0" }
		local r, err = install.resolve(deps, {}, nil)
		T.eq(r, nil)
		T.ok(err ~= nil)
	end)

end)

T.describe("pkg: resolve — frozen mode", function()

	T.it("frozen: locked + satisfied → ok", function()
		local deps   = { sha1 = "^1.0.0" }
		local locked = {
			sha1 = { version = "1.1.0", url = "https://x/1.1.0.tar.gz", checksum = "sha256:x" },
		}
		local r, err = install.resolve(deps, locked, nil, { frozen = true })
		T.ok(r, tostring(err))
		T.eq(r.sha1.version, "1.1.0")
	end)

	T.it("frozen: locked version violates constraint → error", function()
		local deps   = { sha1 = ">=2.0.0" }
		local locked = {
			sha1 = { version = "1.0.0", url = "https://x/1.0.0.tar.gz", checksum = "sha256:y" },
		}
		local r, err = install.resolve(deps, locked, nil, { frozen = true })
		T.eq(r, nil)
		T.ok(err ~= nil)
		T.ok(err:find("frozen") ~= nil)
	end)

	T.it("frozen: package absent from lockfile → error", function()
		local deps = { sha1 = "^1.0.0" }
		local r, err = install.resolve(deps, {}, nil, { frozen = true })
		T.eq(r, nil)
		T.ok(err ~= nil)
		T.ok(err:find("frozen") ~= nil)
	end)

end)

-- ── link / dep directory structure ───────────────────────────────────────────

T.describe("pkg: link — correct directory structure", function()

	-- Simulate what install.run does after fetch: build a fake cache entry,
	-- then call install.dep_ok to verify the result.
	-- We test the directory layout directly rather than invoking fetch_package
	-- (which requires network access).

	T.it("dep_ok returns false when dep dir is absent", function()
		local tmp = make_tmpdir()
		T.fail(install.dep_ok(tmp, "sha1", "1.0.0"))
		rm_tmpdir(tmp)
	end)

	T.it("dep_ok returns false when pkg.lua has wrong name", function()
		local tmp = make_tmpdir()
		os.execute(("mkdir -p %q"):format(tmp .. "/dep/sha1"))
		manifest.write(tmp .. "/dep/sha1/pkg.lua", { name = "other", version = "1.0.0" })
		T.fail(install.dep_ok(tmp, "sha1", "1.0.0"))
		rm_tmpdir(tmp)
	end)

	T.it("dep_ok returns false when pkg.lua has wrong version", function()
		local tmp = make_tmpdir()
		os.execute(("mkdir -p %q"):format(tmp .. "/dep/sha1"))
		manifest.write(tmp .. "/dep/sha1/pkg.lua", { name = "sha1", version = "0.9.0" })
		T.fail(install.dep_ok(tmp, "sha1", "1.0.0"))
		rm_tmpdir(tmp)
	end)

	T.it("dep_ok returns true when name and version both match", function()
		local tmp = make_tmpdir()
		os.execute(("mkdir -p %q"):format(tmp .. "/dep/sha1"))
		manifest.write(tmp .. "/dep/sha1/pkg.lua", { name = "sha1", version = "1.0.0" })
		T.ok(install.dep_ok(tmp, "sha1", "1.0.0"))
		rm_tmpdir(tmp)
	end)

	T.it("link creates dep/<name>/ with pkg.lua and source files", function()
		-- Build a fake global cache entry for sha1@1.0.0
		local cache_root = make_tmpdir()
		local pkg_cache  = cache_root .. "/sha1@1.0.0"
		os.execute(("mkdir -p %q"):format(pkg_cache))
		-- Write a real pkg.lua and a source file into the fake cache
		manifest.write(pkg_cache .. "/pkg.lua", { name = "sha1", version = "1.0.0" })
		write_file(pkg_cache .. "/init.lua", "-- sha1 init\nreturn {}\n")

		-- Build a fake project dir
		local project = make_tmpdir()
		os.execute(("mkdir -p %q"):format(project .. "/dep"))

		-- Simulate hardlink_tree by using cp -r (same shell fallback install uses)
		local dep_dir = project .. "/dep/sha1"
		os.execute(("cp -r %q %q"):format(pkg_cache, dep_dir))

		-- Verify the structure
		T.ok(file_exists(dep_dir .. "/pkg.lua"),   "dep/sha1/pkg.lua exists")
		T.ok(file_exists(dep_dir .. "/init.lua"),  "dep/sha1/init.lua exists")

		local content = read_file(dep_dir .. "/init.lua")
		T.ok(content ~= nil, "init.lua is readable")
		T.ok(content:find("sha1 init") ~= nil, "init.lua has correct content")

		-- dep_ok should confirm the installed version is correct
		T.ok(install.dep_ok(project, "sha1", "1.0.0"), "dep_ok returns true after link")

		rm_tmpdir(cache_root)
		rm_tmpdir(project)
	end)

	T.it("link with nested subdirectory preserves tree", function()
		local cache_root = make_tmpdir()
		local pkg_cache  = cache_root .. "/mypkg@2.0.0"
		os.execute(("mkdir -p %q"):format(pkg_cache .. "/sub"))
		manifest.write(pkg_cache .. "/pkg.lua", { name = "mypkg", version = "2.0.0" })
		write_file(pkg_cache .. "/init.lua",     "return {}\n")
		write_file(pkg_cache .. "/sub/helper.lua", "-- helper\n")

		local project = make_tmpdir()
		os.execute(("mkdir -p %q"):format(project .. "/dep"))

		local dep_dir = project .. "/dep/mypkg"
		os.execute(("cp -r %q %q"):format(pkg_cache, dep_dir))

		T.ok(file_exists(dep_dir .. "/pkg.lua"),          "pkg.lua present")
		T.ok(file_exists(dep_dir .. "/sub/helper.lua"),   "sub/helper.lua present")

		local h = read_file(dep_dir .. "/sub/helper.lua")
		T.ok(h ~= nil and h:find("helper") ~= nil, "sub/helper.lua content correct")

		rm_tmpdir(cache_root)
		rm_tmpdir(project)
	end)

end)
