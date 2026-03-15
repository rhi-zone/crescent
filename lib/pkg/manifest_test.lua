if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local manifest = require("lib.pkg.manifest")

-- ── validate ─────────────────────────────────────────────────────────────────

T.describe("manifest.validate", function()

	T.it("accepts a minimal valid manifest", function()
		local ok, err = manifest.validate({ name = "mylib", version = "1.0.0" })
		T.ok(ok, err)
	end)

	T.it("accepts a full valid manifest", function()
		local ok, err = manifest.validate({
			name        = "sha1",
			version     = "2.3.4",
			description = "SHA-1 in pure Lua",
			license     = "MIT",
			deps        = { lunajson = "^1.3.0", mylib = ">=0.2.0" },
		})
		T.ok(ok, err)
	end)

	T.it("accepts a manifest with empty deps table", function()
		local ok, err = manifest.validate({ name = "pkg", version = "0.0.1", deps = {} })
		T.ok(ok, err)
	end)

	T.it("accepts name with hyphens and underscores", function()
		local ok, err = manifest.validate({ name = "my-pkg_2", version = "1.0.0" })
		T.ok(ok, err)
	end)

	T.it("rejects non-table input", function()
		local ok, err = manifest.validate("not a table")
		T.fail(ok)
		T.ok(err)
	end)

	T.it("rejects missing name", function()
		local ok, err = manifest.validate({ version = "1.0.0" })
		T.fail(ok)
		T.ok(err:find("name"))
	end)

	T.it("rejects non-string name", function()
		local ok, err = manifest.validate({ name = 42, version = "1.0.0" })
		T.fail(ok)
		T.ok(err:find("name"))
	end)

	T.it("rejects empty name", function()
		local ok, err = manifest.validate({ name = "", version = "1.0.0" })
		T.fail(ok)
		T.ok(err:find("name"))
	end)

	T.it("rejects name with uppercase letters", function()
		local ok, err = manifest.validate({ name = "MyLib", version = "1.0.0" })
		T.fail(ok)
		T.ok(err:find("name"))
	end)

	T.it("rejects name with spaces", function()
		local ok, err = manifest.validate({ name = "my lib", version = "1.0.0" })
		T.fail(ok)
		T.ok(err:find("name"))
	end)

	T.it("rejects missing version", function()
		local ok, err = manifest.validate({ name = "mylib" })
		T.fail(ok)
		T.ok(err:find("version"))
	end)

	T.it("rejects non-string version", function()
		local ok, err = manifest.validate({ name = "mylib", version = 100 })
		T.fail(ok)
		T.ok(err:find("version"))
	end)

	T.it("rejects version without patch component", function()
		local ok, err = manifest.validate({ name = "mylib", version = "1.0" })
		T.fail(ok)
		T.ok(err:find("version"))
	end)

	T.it("rejects version with pre-release suffix", function()
		-- Full semver pre-release (1.0.0-alpha) is not accepted by the simple pattern
		local ok, err = manifest.validate({ name = "mylib", version = "1.0.0-alpha" })
		T.fail(ok)
		T.ok(err:find("version"))
	end)

	T.it("rejects non-string description", function()
		local ok, err = manifest.validate({ name = "mylib", version = "1.0.0", description = true })
		T.fail(ok)
		T.ok(err:find("description"))
	end)

	T.it("rejects non-string license", function()
		local ok, err = manifest.validate({ name = "mylib", version = "1.0.0", license = 42 })
		T.fail(ok)
		T.ok(err:find("license"))
	end)

	T.it("rejects non-table deps", function()
		local ok, err = manifest.validate({ name = "mylib", version = "1.0.0", deps = "bad" })
		T.fail(ok)
		T.ok(err:find("deps"))
	end)

	T.it("rejects deps with non-string values", function()
		local ok, err = manifest.validate({ name = "mylib", version = "1.0.0", deps = { foo = 123 } })
		T.fail(ok)
		T.ok(err:find("deps"))
	end)

end)

-- ── load ──────────────────────────────────────────────────────────────────────

T.describe("manifest.load", function()

	T.it("loads a valid pkg.lua from disk", function()
		local tmp = os.tmpname() .. ".lua"
		local fh = io.open(tmp, "w")
		fh:write([[
return {
  name    = "testpkg",
  version = "1.2.3",
  license = "MIT",
  deps    = {},
}
]])
		fh:close()
		local tbl, err = manifest.load(tmp)
		os.remove(tmp)
		T.ok(tbl, err)
		T.eq(tbl.name, "testpkg")
		T.eq(tbl.version, "1.2.3")
		T.eq(tbl.license, "MIT")
	end)

	T.it("returns nil, err for a non-existent file", function()
		local tbl, err = manifest.load("/nonexistent/path/pkg.lua")
		T.fail(tbl)
		T.ok(err)
	end)

	T.it("returns nil, err for a file with syntax errors", function()
		local tmp = os.tmpname() .. ".lua"
		local fh = io.open(tmp, "w")
		fh:write("this is not valid lua !!!")
		fh:close()
		local tbl, err = manifest.load(tmp)
		os.remove(tmp)
		T.fail(tbl)
		T.ok(err)
	end)

	T.it("returns nil, err for a file that returns an invalid manifest", function()
		local tmp = os.tmpname() .. ".lua"
		local fh = io.open(tmp, "w")
		fh:write("return { name = 'BadName!', version = '1.0.0' }")
		fh:close()
		local tbl, err = manifest.load(tmp)
		os.remove(tmp)
		T.fail(tbl)
		T.ok(err)
	end)

	T.it("returns nil, err for a file that returns nil", function()
		local tmp = os.tmpname() .. ".lua"
		local fh = io.open(tmp, "w")
		fh:write("return nil")
		fh:close()
		local tbl, err = manifest.load(tmp)
		os.remove(tmp)
		T.fail(tbl)
		T.ok(err)
	end)

end)

-- ── write ─────────────────────────────────────────────────────────────────────

T.describe("manifest.write", function()

	T.it("writes a manifest and round-trips through load", function()
		local tmp = os.tmpname() .. ".lua"
		local src = {
			name        = "roundtrip",
			version     = "3.2.1",
			description = "Round-trip test",
			license     = "Apache-2.0",
			deps        = { lunajson = "^1.3.0", zlib = ">=1.2.0" },
		}
		local ok, err = manifest.write(tmp, src)
		T.ok(ok, err)

		local loaded, load_err = manifest.load(tmp)
		os.remove(tmp)
		T.ok(loaded, load_err)
		T.eq(loaded.name, src.name)
		T.eq(loaded.version, src.version)
		T.eq(loaded.description, src.description)
		T.eq(loaded.license, src.license)
		T.eq(loaded.deps.lunajson, src.deps.lunajson)
		T.eq(loaded.deps.zlib, src.deps.zlib)
	end)

	T.it("writes a minimal manifest (no optional fields)", function()
		local tmp = os.tmpname() .. ".lua"
		local ok, err = manifest.write(tmp, { name = "minimal", version = "0.1.0" })
		T.ok(ok, err)

		local loaded, load_err = manifest.load(tmp)
		os.remove(tmp)
		T.ok(loaded, load_err)
		T.eq(loaded.name, "minimal")
		T.eq(loaded.version, "0.1.0")
	end)

	T.it("returns nil, err for an invalid manifest", function()
		local tmp = os.tmpname() .. ".lua"
		local ok, err = manifest.write(tmp, { name = "Bad Name!", version = "1.0.0" })
		os.remove(tmp)
		T.fail(ok)
		T.ok(err)
	end)

	T.it("produces valid Lua source", function()
		local tmp = os.tmpname() .. ".lua"
		manifest.write(tmp, {
			name    = "luasrc",
			version = "1.0.0",
			deps    = { dep1 = "^0.1.0" },
		})
		-- The output should be loadable as a Lua chunk
		local chunk, load_err = loadfile(tmp)
		os.remove(tmp)
		T.ok(chunk, load_err)
	end)

	T.it("sorts deps keys deterministically", function()
		local tmp = os.tmpname() .. ".lua"
		manifest.write(tmp, {
			name    = "sorted",
			version = "1.0.0",
			deps    = { zzz = "1.0.0", aaa = "2.0.0", mmm = "3.0.0" },
		})
		local fh = io.open(tmp, "r")
		local content = fh:read("*a")
		fh:close()
		os.remove(tmp)
		-- aaa should appear before mmm which should appear before zzz
		local pos_aaa = content:find("aaa")
		local pos_mmm = content:find("mmm")
		local pos_zzz = content:find("zzz")
		T.ok(pos_aaa < pos_mmm)
		T.ok(pos_mmm < pos_zzz)
	end)

end)
