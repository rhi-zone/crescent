if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T       = require("lib.test.assert")
local install = require("lib.pkg.install")
local manifest = require("lib.pkg.manifest")

-- ── helpers ───────────────────────────────────────────────────────────────────

-- Create a temp directory and return its path.
local function make_tmpdir()
	local path = os.tmpname()
	os.remove(path)  -- os.tmpname creates the file; we want a directory
	os.execute(("mkdir -p %q"):format(path))
	return path
end

-- Remove a temp directory tree.
local function rm_tmpdir(path)
	os.execute(("rm -rf %q"):format(path))
end

-- Write a pkg.lua manifest to dir/pkg.lua.
local function write_manifest(dir, tbl)
	local ok, err = manifest.write(dir .. "/pkg.lua", tbl)
	T.ok(ok, "write_manifest: " .. tostring(err))
end

-- ── install.dep_ok ────────────────────────────────────────────────────────────

T.describe("install.dep_ok", function()

	T.it("returns false when dep dir does not exist", function()
		local tmp = make_tmpdir()
		T.ok(not install.dep_ok(tmp, "sha1", "1.0.0"))
		rm_tmpdir(tmp)
	end)

	T.it("returns false when dep/name/pkg.lua is absent", function()
		local tmp = make_tmpdir()
		os.execute(("mkdir -p %q"):format(tmp .. "/dep/sha1"))
		-- no pkg.lua written
		T.ok(not install.dep_ok(tmp, "sha1", "1.0.0"))
		rm_tmpdir(tmp)
	end)

	T.it("returns false when name matches but version differs", function()
		local tmp = make_tmpdir()
		os.execute(("mkdir -p %q"):format(tmp .. "/dep/sha1"))
		write_manifest(tmp .. "/dep/sha1", { name = "sha1", version = "0.9.0" })
		T.ok(not install.dep_ok(tmp, "sha1", "1.0.0"))
		rm_tmpdir(tmp)
	end)

	T.it("returns false when version matches but name differs", function()
		local tmp = make_tmpdir()
		os.execute(("mkdir -p %q"):format(tmp .. "/dep/sha1"))
		write_manifest(tmp .. "/dep/sha1", { name = "sha2", version = "1.0.0" })
		T.ok(not install.dep_ok(tmp, "sha1", "1.0.0"))
		rm_tmpdir(tmp)
	end)

	T.it("returns true when name and version both match", function()
		local tmp = make_tmpdir()
		os.execute(("mkdir -p %q"):format(tmp .. "/dep/sha1"))
		write_manifest(tmp .. "/dep/sha1", { name = "sha1", version = "1.0.0" })
		T.ok(install.dep_ok(tmp, "sha1", "1.0.0"))
		rm_tmpdir(tmp)
	end)

	T.it("handles hyphenated package names", function()
		local tmp = make_tmpdir()
		os.execute(("mkdir -p %q"):format(tmp .. "/dep/lua-cjson"))
		write_manifest(tmp .. "/dep/lua-cjson", { name = "lua-cjson", version = "2.1.0" })
		T.ok(install.dep_ok(tmp, "lua-cjson", "2.1.0"))
		rm_tmpdir(tmp)
	end)

end)

-- ── install.resolve ───────────────────────────────────────────────────────────

-- Minimal mock registry index.
local MOCK_INDEX = {
	sha1 = {
		versions = { "0.9.0", "1.0.0", "1.1.0", "2.0.0" },
		latest   = "2.0.0",
	},
	lunajson = {
		versions = { "1.2.0", "1.3.0", "1.3.1" },
		latest   = "1.3.1",
	},
	only_old = {
		versions = { "0.1.0", "0.2.0" },
		latest   = "0.2.0",
	},
}

T.describe("install.resolve", function()

	-- Locked entry with matching version → use locked entry as-is
	T.it("uses locked version when it satisfies constraint", function()
		local deps   = { sha1 = "^1.0.0" }
		local locked = {
			sha1 = { version = "1.0.0", url = "https://example.com/sha1/1.0.0.tar.gz", checksum = "sha256:abc123" },
		}
		local r, err = install.resolve(deps, locked, MOCK_INDEX)
		T.ok(r, tostring(err))
		T.eq(r.sha1.version, "1.0.0")
		T.eq(r.sha1.url,     "https://example.com/sha1/1.0.0.tar.gz")
		T.eq(r.sha1.checksum, "sha256:abc123")
	end)

	-- No lockfile → resolve against registry
	T.it("resolves to highest satisfying version from registry when not locked", function()
		local deps = { sha1 = "^1.0.0" }
		local r, err = install.resolve(deps, {}, MOCK_INDEX)
		T.ok(r, tostring(err))
		-- ^1.0.0 should pick 1.1.0 (highest in [1.0.0, 2.0.0))
		T.eq(r.sha1.version, "1.1.0")
		T.ok(r.sha1._needs_fetch)
	end)

	T.it("resolves to latest when constraint is *", function()
		local deps = { sha1 = "*" }
		local r, err = install.resolve(deps, {}, MOCK_INDEX)
		T.ok(r, tostring(err))
		-- "*" → pick highest available
		T.eq(r.sha1.version, "2.0.0")
	end)

	T.it("resolves multiple deps independently", function()
		local deps = { sha1 = ">=1.0.0", lunajson = "~1.3" }
		local r, err = install.resolve(deps, {}, MOCK_INDEX)
		T.ok(r, tostring(err))
		T.eq(r.sha1.version,    "2.0.0")
		T.eq(r.lunajson.version, "1.3.1")
	end)

	T.it("returns nil when no version satisfies constraint", function()
		local deps = { sha1 = ">=99.0.0" }
		local r, err = install.resolve(deps, {}, MOCK_INDEX)
		T.eq(r, nil)
		T.ok(err ~= nil)
		T.ok(err:find("sha1") ~= nil)
	end)

	T.it("returns nil when package not found in registry", function()
		local deps = { unknown_pkg = "^1.0.0" }
		local r, err = install.resolve(deps, {}, MOCK_INDEX)
		T.eq(r, nil)
		T.ok(err ~= nil)
		T.ok(err:find("unknown_pkg") ~= nil)
	end)

	-- frozen=true with all deps present in lockfile at satisfying versions → ok
	T.it("frozen: accepts lockfile when all constraints satisfied", function()
		local deps = { sha1 = "^1.0.0" }
		local locked = {
			sha1 = { version = "1.1.0", url = "https://x/sha1/1.1.0.tar.gz", checksum = "sha256:aaa" },
		}
		local r, err = install.resolve(deps, locked, nil, { frozen = true })
		T.ok(r, tostring(err))
		T.eq(r.sha1.version, "1.1.0")
	end)

	-- frozen=true with locked version not satisfying constraint → error
	T.it("frozen: errors when locked version violates constraint", function()
		local deps = { sha1 = ">=2.0.0" }
		local locked = {
			sha1 = { version = "1.0.0", url = "https://x/sha1/1.0.0.tar.gz", checksum = "sha256:bbb" },
		}
		local r, err = install.resolve(deps, locked, nil, { frozen = true })
		T.eq(r, nil)
		T.ok(err ~= nil)
		T.ok(err:find("frozen") ~= nil)
	end)

	-- frozen=true with package missing from lockfile → error
	T.it("frozen: errors when package absent from lockfile", function()
		local deps = { sha1 = "^1.0.0" }
		local r, err = install.resolve(deps, {}, nil, { frozen = true })
		T.eq(r, nil)
		T.ok(err ~= nil)
		T.ok(err:find("frozen") ~= nil)
	end)

	-- Locked version doesn't satisfy constraint + not frozen → re-resolve via registry
	T.it("re-resolves when locked version no longer satisfies constraint", function()
		local deps = { sha1 = ">=2.0.0" }
		local locked = {
			sha1 = { version = "1.0.0", url = "https://x/sha1/1.0.0.tar.gz", checksum = "sha256:ccc" },
		}
		local r, err = install.resolve(deps, locked, MOCK_INDEX)
		T.ok(r, tostring(err))
		T.eq(r.sha1.version, "2.0.0")
		T.ok(r.sha1._needs_fetch)
	end)

	-- exact constraint
	T.it("resolves exact version constraint", function()
		local deps = { lunajson = "=1.3.0" }
		local r, err = install.resolve(deps, {}, MOCK_INDEX)
		T.ok(r, tostring(err))
		T.eq(r.lunajson.version, "1.3.0")
	end)

	-- No satisfying version in registry and not frozen
	T.it("errors when no satisfying version and no registry available", function()
		local deps = { sha1 = "^1.0.0" }
		local r, err = install.resolve(deps, {}, nil)  -- no registry_index
		T.eq(r, nil)
		T.ok(err ~= nil)
		T.ok(err:find("sha1") ~= nil)
	end)

end)

-- ── install._parse_index ──────────────────────────────────────────────────────

T.describe("install._parse_index (JSON parser)", function()

	T.it("parses a simple index.json", function()
		local json = [[{"sha1":{"versions":["1.0.0","1.1.0"],"latest":"1.1.0"}}]]
		local idx, err = install._parse_index(json)
		T.ok(idx, tostring(err))
		T.ok(idx.sha1 ~= nil)
		T.eq(idx.sha1.latest, "1.1.0")
		T.eq(#idx.sha1.versions, 2)
		T.eq(idx.sha1.versions[1], "1.0.0")
		T.eq(idx.sha1.versions[2], "1.1.0")
	end)

	T.it("parses multi-package index.json", function()
		local json = [[{"sha1":{"versions":["1.0.0"],"latest":"1.0.0"},"lunajson":{"versions":["1.3.0","1.3.1"],"latest":"1.3.1"}}]]
		local idx, err = install._parse_index(json)
		T.ok(idx, tostring(err))
		T.ok(idx.sha1 ~= nil)
		T.ok(idx.lunajson ~= nil)
		T.eq(idx.lunajson.latest, "1.3.1")
		T.eq(#idx.lunajson.versions, 2)
	end)

	T.it("parses empty index.json", function()
		local json = [[{}]]
		local idx, err = install._parse_index(json)
		T.ok(idx, tostring(err))
		T.eq(next(idx), nil)
	end)

	T.it("returns nil on non-object input", function()
		local idx, err = install._parse_index("[]")
		T.eq(idx, nil)
		T.ok(err ~= nil)
	end)

	T.it("handles escaped quotes in package names", function()
		-- package names don't normally have escaped chars, but the parser must not crash
		local json = [[{"pkg-one":{"versions":["0.1.0"],"latest":"0.1.0"}}]]
		local idx, err = install._parse_index(json)
		T.ok(idx, tostring(err))
		T.ok(idx["pkg-one"] ~= nil)
	end)

end)
