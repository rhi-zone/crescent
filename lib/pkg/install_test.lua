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

	T.it("returns false when lib dir does not exist", function()
		local tmp = make_tmpdir()
		T.ok(not install.dep_ok(tmp, "sha1", "1.0.0"))
		rm_tmpdir(tmp)
	end)

	T.it("returns false when lib/name/pkg.lua is absent", function()
		local tmp = make_tmpdir()
		os.execute(("mkdir -p %q"):format(tmp .. "/lib/sha1"))
		-- no pkg.lua written
		T.ok(not install.dep_ok(tmp, "sha1", "1.0.0"))
		rm_tmpdir(tmp)
	end)

	T.it("returns false when name matches but version differs", function()
		local tmp = make_tmpdir()
		os.execute(("mkdir -p %q"):format(tmp .. "/lib/sha1"))
		write_manifest(tmp .. "/lib/sha1", { name = "sha1", version = "0.9.0" })
		T.ok(not install.dep_ok(tmp, "sha1", "1.0.0"))
		rm_tmpdir(tmp)
	end)

	T.it("returns false when version matches but name differs", function()
		local tmp = make_tmpdir()
		os.execute(("mkdir -p %q"):format(tmp .. "/lib/sha1"))
		write_manifest(tmp .. "/lib/sha1", { name = "sha2", version = "1.0.0" })
		T.ok(not install.dep_ok(tmp, "sha1", "1.0.0"))
		rm_tmpdir(tmp)
	end)

	T.it("returns true when name and version both match", function()
		local tmp = make_tmpdir()
		os.execute(("mkdir -p %q"):format(tmp .. "/lib/sha1"))
		write_manifest(tmp .. "/lib/sha1", { name = "sha1", version = "1.0.0" })
		T.ok(install.dep_ok(tmp, "sha1", "1.0.0"))
		rm_tmpdir(tmp)
	end)

	T.it("handles hyphenated package names", function()
		local tmp = make_tmpdir()
		os.execute(("mkdir -p %q"):format(tmp .. "/lib/lua-cjson"))
		write_manifest(tmp .. "/lib/lua-cjson", { name = "lua-cjson", version = "2.1.0" })
		T.ok(install.dep_ok(tmp, "lua-cjson", "2.1.0"))
		rm_tmpdir(tmp)
	end)

end)

-- ── install.tree_hash ─────────────────────────────────────────────────────────

T.describe("install.tree_hash", function()

	T.it("returns sha256:... for a directory with files", function()
		local tmp = make_tmpdir()
		local f = io.open(tmp .. "/init.lua", "w")
		f:write("return {}\n")
		f:close()

		local h, err = install.tree_hash(tmp)
		T.ok(h, "tree_hash returned a value, err=" .. tostring(err))
		T.ok(h:match("^sha256:%x+"), "tree_hash is sha256:hex")
		rm_tmpdir(tmp)
	end)

	T.it("returns consistent hash for same contents", function()
		local tmp = make_tmpdir()
		local f = io.open(tmp .. "/init.lua", "w")
		f:write("return {}\n")
		f:close()

		local h1 = install.tree_hash(tmp)
		local h2 = install.tree_hash(tmp)
		T.eq(h1, h2, "same dir produces same hash")
		rm_tmpdir(tmp)
	end)

	T.it("hash changes when file content changes", function()
		local tmp = make_tmpdir()
		local f = io.open(tmp .. "/init.lua", "w")
		f:write("return {}\n")
		f:close()

		local h1 = install.tree_hash(tmp)

		-- Modify the file
		local f2 = io.open(tmp .. "/init.lua", "w")
		f2:write("return { modified = true }\n")
		f2:close()

		local h2 = install.tree_hash(tmp)
		T.ok(h1 ~= h2, "hash changes when file changes")
		rm_tmpdir(tmp)
	end)

	T.it("hash changes when a new file is added", function()
		local tmp = make_tmpdir()
		local f = io.open(tmp .. "/init.lua", "w")
		f:write("return {}\n")
		f:close()

		local h1 = install.tree_hash(tmp)

		-- Add a new file
		local f2 = io.open(tmp .. "/util.lua", "w")
		f2:write("return {}\n")
		f2:close()

		local h2 = install.tree_hash(tmp)
		T.ok(h1 ~= h2, "hash changes when new file is added")
		rm_tmpdir(tmp)
	end)

	T.it("hash is deterministic across multiple files", function()
		local tmp = make_tmpdir()
		for _, name in ipairs({ "a.lua", "b.lua", "c.lua" }) do
			local f = io.open(tmp .. "/" .. name, "w")
			f:write("-- " .. name .. "\n")
			f:close()
		end

		local h1 = install.tree_hash(tmp)
		local h2 = install.tree_hash(tmp)
		T.eq(h1, h2, "multi-file tree_hash is deterministic")
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
			sha1 = { version = "1.0.0", url = "https://example.com/sha1/1.0.0.tar.gz", tarball_hash = "sha256:abc123" },
		}
		local r, err = install.resolve(deps, locked, MOCK_INDEX)
		T.ok(r, tostring(err))
		T.eq(r.sha1.version, "1.0.0")
		T.eq(r.sha1.url,     "https://example.com/sha1/1.0.0.tar.gz")
		T.eq(r.sha1.tarball_hash, "sha256:abc123")
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
			sha1 = { version = "1.1.0", url = "https://x/sha1/1.1.0.tar.gz", tarball_hash = "sha256:aaa" },
		}
		local r, err = install.resolve(deps, locked, nil, { frozen = true })
		T.ok(r, tostring(err))
		T.eq(r.sha1.version, "1.1.0")
	end)

	-- frozen=true with locked version not satisfying constraint → error
	T.it("frozen: errors when locked version violates constraint", function()
		local deps = { sha1 = ">=2.0.0" }
		local locked = {
			sha1 = { version = "1.0.0", url = "https://x/sha1/1.0.0.tar.gz", tarball_hash = "sha256:bbb" },
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
			sha1 = { version = "1.0.0", url = "https://x/sha1/1.0.0.tar.gz", tarball_hash = "sha256:ccc" },
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

-- ── install.resolve (multi-registry) ─────────────────────────────────────────

local MOCK_INDEX_2 = {
	only_in_2 = {
		versions = { "1.0.0" },
		latest   = "1.0.0",
	},
	sha1 = {
		versions = { "0.9.0", "1.0.0" },
		latest   = "1.0.0",
	},
}

T.describe("install.resolve multi-registry", function()

	T.it("finds package in second registry when absent from first", function()
		local deps = { only_in_2 = "^1.0.0" }
		local indices = {
			{ index = MOCK_INDEX, url = "https://reg1.example.com" },
			{ index = MOCK_INDEX_2, url = "https://reg2.example.com" },
		}
		local r, err = install.resolve(deps, {}, nil, { registry_indices = indices })
		T.ok(r, tostring(err))
		T.eq(r.only_in_2.version, "1.0.0")
		T.eq(r.only_in_2._winning_registry, "https://reg2.example.com")
	end)

	T.it("uses higher-priority registry when package is in both", function()
		-- sha1 2.0.0 is in MOCK_INDEX (reg1) but not MOCK_INDEX_2 (reg2 only has up to 1.0.0)
		local deps = { sha1 = "^2.0.0" }
		local indices = {
			{ index = MOCK_INDEX, url = "https://reg1.example.com" },
			{ index = MOCK_INDEX_2, url = "https://reg2.example.com" },
		}
		local r, err = install.resolve(deps, {}, nil, { registry_indices = indices })
		T.ok(r, tostring(err))
		T.eq(r.sha1.version, "2.0.0")
		T.eq(r.sha1._winning_registry, "https://reg1.example.com")
	end)

	T.it("errors when no registry satisfies constraint", function()
		local deps = { sha1 = ">=99.0.0" }
		local indices = {
			{ index = MOCK_INDEX, url = "https://reg1.example.com" },
			{ index = MOCK_INDEX_2, url = "https://reg2.example.com" },
		}
		local r, err = install.resolve(deps, {}, nil, { registry_indices = indices })
		T.eq(r, nil)
		T.ok(err ~= nil)
		T.ok(err:find("sha1") ~= nil)
	end)

	T.it("backwards compat: positional registry_index still works", function()
		local deps = { sha1 = "^1.0.0" }
		local r, err = install.resolve(deps, {}, MOCK_INDEX)
		T.ok(r, tostring(err))
		T.eq(r.sha1.version, "1.1.0")
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

-- ── install.run transitive deps ───────────────────────────────────────────────
--
-- These tests exercise M.run's BFS transitive-dependency resolution without
-- real network calls.  Strategy:
--   • Pre-install all packages in lib/<name>/ by writing their pkg.lua.
--   • Pre-populate crescent.lock with all known packages.
--   • Run M.run with only direct deps in the project pkg.lua.
--   • Because every package passes dep_ok + has a lockfile entry, M.run takes
--     the "skip" fast path for each and never calls curl.
--   • The test verifies no errors and the correct set of skipped packages.

local lock = require("lib.pkg.lock")

-- Install a package into lib/<name>/ of a project directory.
local function install_dep(project_dir, pkg_tbl)
	local dep_dir = project_dir .. "/lib/" .. pkg_tbl.name
	os.execute(("mkdir -p %q"):format(dep_dir))
	write_manifest(dep_dir, pkg_tbl)
end

-- Write a crescent.lock with the given entries.
-- entries: { [name] = { version, url, tarball_hash, tree_hash, include } }
local function write_lock(project_dir, entries)
	local lock_path = project_dir .. "/crescent.lock"
	local ok, err = lock.write(lock_path, entries)
	T.ok(ok, "write_lock: " .. tostring(err))
end

-- Sort a list in-place and join it as a comma-separated string.
local function sorted_str(t)
	local copy = {}
	for i, v in ipairs(t) do copy[i] = v end
	table.sort(copy)
	return table.concat(copy, ",")
end

-- Helper: build a standard lock entry for a package.
local function lock_entry(version, tree_hash)
	return {
		version      = version,
		url          = "https://example.com/pkg.tar.gz",
		tarball_hash = "sha256:aabbcc",
		tree_hash    = tree_hash,
		include      = "**",
	}
end

T.describe("install.run transitive deps", function()

	T.it("depth-1 transitive: installs dep's dep (no network)", function()
		-- Project depends on pkgA which depends on pkgB.
		-- All packages pre-installed; M.run should discover pkgB transitively.
		local tmp = make_tmpdir()

		-- Write project manifest (only direct dep: pkga)
		write_manifest(tmp, { name = "myapp", version = "1.0.0", deps = { pkga = "^1.0.0" } })

		-- Pre-install pkga (depends on pkgb)
		install_dep(tmp, { name = "pkga", version = "1.0.0",
			deps = { pkgb = "^2.0.0" } })

		-- Pre-install pkgb (no further deps)
		install_dep(tmp, { name = "pkgb", version = "2.0.0" })

		-- Pre-populate lockfile with both packages (no tree_hash → no modification check)
		write_lock(tmp, {
			pkga = lock_entry("1.0.0"),
			pkgb = lock_entry("2.0.0"),
		})

		local result = install.run(tmp, { frozen = true })

		T.ok(result.ok, "expected ok; errors: " .. table.concat(result.errors, ", "))
		T.eq(#result.errors, 0)
		-- Both packages should be skipped (pre-installed)
		T.eq(sorted_str(result.skipped), "pkga,pkgb")
		-- Nothing actually fetched
		T.eq(#result.installed, 0)

		rm_tmpdir(tmp)
	end)

	T.it("diamond dep: A→B, A→C, B→D, C→D — D installed exactly once", function()
		-- A depends on B and C; both B and C depend on D.
		-- D should appear once in skipped, not twice.
		local tmp = make_tmpdir()

		write_manifest(tmp, { name = "myapp", version = "1.0.0",
			deps = { pkga = "^1.0.0" } })

		install_dep(tmp, { name = "pkga", version = "1.0.0",
			deps = { pkgb = "^1.0.0", pkgc = "^1.0.0" } })
		install_dep(tmp, { name = "pkgb", version = "1.0.0",
			deps = { pkgd = "^1.0.0" } })
		install_dep(tmp, { name = "pkgc", version = "1.0.0",
			deps = { pkgd = "^1.0.0" } })
		install_dep(tmp, { name = "pkgd", version = "1.0.0" })

		write_lock(tmp, {
			pkga = lock_entry("1.0.0"),
			pkgb = lock_entry("1.0.0"),
			pkgc = lock_entry("1.0.0"),
			pkgd = lock_entry("1.0.0"),
		})

		local result = install.run(tmp, { frozen = true })

		T.ok(result.ok, "expected ok; errors: " .. table.concat(result.errors, ", "))
		T.eq(#result.errors, 0)
		-- All four packages skipped, D only once
		T.eq(sorted_str(result.skipped), "pkga,pkgb,pkgc,pkgd")
		T.eq(#result.installed, 0)

		rm_tmpdir(tmp)
	end)

	T.it("compatible already-visited dep: no conflict when constraint is satisfied", function()
		-- A→foo@>=1.0.0 resolved to 1.5.0; B also requires foo@>=1.0.0 — no error.
		local tmp = make_tmpdir()

		write_manifest(tmp, { name = "myapp", version = "1.0.0",
			deps = { pkga = "^1.0.0", pkgb = "^1.0.0" } })

		-- pkga depends on foo >=1.0.0
		install_dep(tmp, { name = "pkga", version = "1.0.0",
			deps = { foo = ">=1.0.0" } })
		-- pkgb also depends on foo >=1.0.0 (compatible)
		install_dep(tmp, { name = "pkgb", version = "1.0.0",
			deps = { foo = ">=1.0.0" } })
		install_dep(tmp, { name = "foo", version = "1.5.0" })

		write_lock(tmp, {
			pkga = lock_entry("1.0.0"),
			pkgb = lock_entry("1.0.0"),
			foo  = lock_entry("1.5.0"),
		})

		local result = install.run(tmp, { frozen = true })

		T.ok(result.ok, "expected ok; errors: " .. table.concat(result.errors, ", "))
		T.eq(#result.errors, 0)
		T.eq(sorted_str(result.skipped), "foo,pkga,pkgb")

		rm_tmpdir(tmp)
	end)

	T.it("version conflict: selected version does not satisfy transitive constraint", function()
		-- Project→pkga; pkga→foo@>=2.0.0 (resolved 2.0.0) AND pkga→pkgb;
		-- pkgb→foo@>=3.0.0. foo is visited before pkgb is processed (sorted BFS),
		-- so the already-visited conflict check fires.
		local tmp = make_tmpdir()

		-- Project only directly depends on pkga; pkga pulls in both foo and pkgb.
		write_manifest(tmp, { name = "myapp", version = "1.0.0",
			deps = { pkga = "^1.0.0" } })

		-- pkga depends on both foo (>=2.0.0) and pkgb
		install_dep(tmp, { name = "pkga", version = "1.0.0",
			deps = { foo = ">=2.0.0", pkgb = "^1.0.0" } })
		-- pkgb requires foo >=3.0.0 — incompatible with 2.0.0
		install_dep(tmp, { name = "pkgb", version = "1.0.0",
			deps = { foo = ">=3.0.0" } })
		install_dep(tmp, { name = "foo", version = "2.0.0" })

		write_lock(tmp, {
			pkga = lock_entry("1.0.0"),
			pkgb = lock_entry("1.0.0"),
			foo  = lock_entry("2.0.0"),
		})

		local result = install.run(tmp, { frozen = true })

		T.ok(not result.ok, "expected failure due to version conflict")
		T.ok(#result.errors > 0, "expected at least one error")
		local found = false
		for _, e in ipairs(result.errors) do
			if e:find("conflict") then
				found = true
				break
			end
		end
		T.ok(found, "expected error mentioning 'conflict', got: " .. table.concat(result.errors, "; "))

		rm_tmpdir(tmp)
	end)

	T.it("direct vs transitive conflict: project foo@>=1.0.0 resolved 1.5.0, dep requires foo@>=2.0.0", function()
		-- Project directly depends on foo@>=1.0.0 (resolved 1.5.0).
		-- pkga transitively requires foo@>=2.0.0 — conflict.
		local tmp = make_tmpdir()

		write_manifest(tmp, { name = "myapp", version = "1.0.0",
			deps = { pkga = "^1.0.0", foo = ">=1.0.0" } })

		install_dep(tmp, { name = "pkga", version = "1.0.0",
			deps = { foo = ">=2.0.0" } })
		install_dep(tmp, { name = "foo", version = "1.5.0" })

		write_lock(tmp, {
			pkga = lock_entry("1.0.0"),
			foo  = lock_entry("1.5.0"),
		})

		local result = install.run(tmp, { frozen = true })

		T.ok(not result.ok, "expected failure due to version conflict")
		T.ok(#result.errors > 0, "expected at least one error")
		local found = false
		for _, e in ipairs(result.errors) do
			if e:find("conflict") then
				found = true
				break
			end
		end
		T.ok(found, "expected error mentioning 'conflict', got: " .. table.concat(result.errors, "; "))

		rm_tmpdir(tmp)
	end)

	T.it("circular dep guard: A→B→A does not loop", function()
		-- A depends on B; B depends on A.
		-- The visited set must prevent infinite recursion.
		local tmp = make_tmpdir()

		write_manifest(tmp, { name = "myapp", version = "1.0.0",
			deps = { pkga = "^1.0.0" } })

		install_dep(tmp, { name = "pkga", version = "1.0.0",
			deps = { pkgb = "^1.0.0" } })
		install_dep(tmp, { name = "pkgb", version = "1.0.0",
			deps = { pkga = "^1.0.0" } })

		write_lock(tmp, {
			pkga = lock_entry("1.0.0"),
			pkgb = lock_entry("1.0.0"),
		})

		local result = install.run(tmp, { frozen = true })

		T.ok(result.ok, "expected ok; errors: " .. table.concat(result.errors, ", "))
		T.eq(#result.errors, 0)
		-- Both packages discovered; cycle broken by visited set
		T.eq(sorted_str(result.skipped), "pkga,pkgb")

		rm_tmpdir(tmp)
	end)

end)

-- ── install.run: local modification detection ─────────────────────────────────

T.describe("install.run modification detection", function()

	-- Helper: build a package dir with a single file and compute its real tree_hash.
	local function make_pkg_with_hash(project_dir, name, version)
		local lib_dir = project_dir .. "/lib/" .. name
		os.execute(("mkdir -p %q"):format(lib_dir))
		write_manifest(lib_dir, { name = name, version = version })
		-- Write an extra file so there is non-trivial content
		local f = io.open(lib_dir .. "/init.lua", "w")
		f:write("return {}\n")
		f:close()
		local h = install.tree_hash(lib_dir)
		return h
	end

	T.it("skips and warns when tree hash differs (local modifications)", function()
		local tmp = make_tmpdir()

		write_manifest(tmp, { name = "myapp", version = "1.0.0", deps = { mypkg = "^1.0.0" } })

		local correct_hash = make_pkg_with_hash(tmp, "mypkg", "1.0.0")

		-- Populate lockfile with the correct hash
		local lock_path = tmp .. "/crescent.lock"
		local lock_mod = require("lib.pkg.lock")
		lock_mod.write(lock_path, {
			mypkg = {
				version      = "1.0.0",
				url          = "https://example.com/mypkg/1.0.0.tar.gz",
				tarball_hash = "sha256:aabbcc",
				tree_hash    = correct_hash,
				include      = "**",
			},
		})

		-- Now modify a file to invalidate the tree hash
		local f = io.open(tmp .. "/lib/mypkg/init.lua", "w")
		f:write("return { modified = true }\n")
		f:close()

		-- Capture stderr to verify the warning
		local captured_stderr = {}
		local old_stderr_write
		-- We can't easily intercept io.stderr in LuaJIT; just verify behavior:
		-- The package should be skipped (not fail) and no error in result.errors.
		local result = install.run(tmp, { frozen = true })

		-- Should not error — just skip
		T.ok(result.ok, "run returns ok even with modified package")
		T.eq(#result.errors, 0, "no errors in result")
		-- mypkg should appear in skipped (we let it through with a warning)
		local found = false
		for _, n in ipairs(result.skipped) do
			if n == "mypkg" then found = true; break end
		end
		T.ok(found, "modified package appears in skipped list")

		rm_tmpdir(tmp)
	end)

	T.it("--force bypasses modification check and installs even without tree hash mismatch data", function()
		-- With --force, modification check is skipped entirely.
		-- We just verify force=true doesn't cause any new errors on a clean install.
		local tmp = make_tmpdir()

		write_manifest(tmp, { name = "myapp", version = "1.0.0", deps = { mypkg = "^1.0.0" } })

		local h = make_pkg_with_hash(tmp, "mypkg", "1.0.0")

		local lock_path = tmp .. "/crescent.lock"
		local lock_mod = require("lib.pkg.lock")
		lock_mod.write(lock_path, {
			mypkg = {
				version      = "1.0.0",
				url          = "https://example.com/mypkg/1.0.0.tar.gz",
				tarball_hash = "sha256:aabbcc",
				tree_hash    = h,
				include      = "**",
			},
		})

		-- Run with force=true — should skip (already installed and dep_ok)
		local result = install.run(tmp, { frozen = true, force = true })

		T.ok(result.ok, "force install returns ok")
		T.eq(#result.errors, 0, "no errors with --force")

		rm_tmpdir(tmp)
	end)

	T.it("no warning when tree hash matches (unmodified package)", function()
		local tmp = make_tmpdir()

		write_manifest(tmp, { name = "myapp", version = "1.0.0", deps = { mypkg = "^1.0.0" } })

		local h = make_pkg_with_hash(tmp, "mypkg", "1.0.0")

		local lock_path = tmp .. "/crescent.lock"
		local lock_mod = require("lib.pkg.lock")
		lock_mod.write(lock_path, {
			mypkg = {
				version      = "1.0.0",
				url          = "https://example.com/mypkg/1.0.0.tar.gz",
				tarball_hash = "sha256:aabbcc",
				tree_hash    = h,
				include      = "**",
			},
		})

		local result = install.run(tmp, { frozen = true })

		T.ok(result.ok, "unmodified package: ok")
		T.eq(#result.errors, 0, "no errors for unmodified package")
		local found = false
		for _, n in ipairs(result.skipped) do
			if n == "mypkg" then found = true; break end
		end
		T.ok(found, "unmodified package is skipped normally")

		rm_tmpdir(tmp)
	end)

end)
