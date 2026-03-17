if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T       = require("lib.test.assert")
local publish = require("lib.pkg.publish")
local manifest = require("lib.pkg.manifest")

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
	local fh = assert(io.open(path, "w"))
	fh:write(content)
	fh:close()
end

local function write_manifest(dir, tbl)
	local ok, err = manifest.write(dir .. "/pkg.lua", tbl)
	T.ok(ok, "write_manifest: " .. tostring(err))
end

-- ── publish.collect_files ─────────────────────────────────────────────────────

T.describe("publish.collect_files — explicit files list", function()

	T.it("uses manifest.files when present", function()
		local tmp = make_tmpdir()
		write_manifest(tmp, { name = "mypkg", version = "1.0.0" })
		write_file(tmp .. "/init.lua",  "return {}")
		write_file(tmp .. "/util.lua",  "return {}")
		-- Declare explicit files list
		local m = { name = "mypkg", version = "1.0.0", files = { "init.lua", "pkg.lua" } }
		local files, err = publish.collect_files(tmp, m)
		T.ok(files, tostring(err))
		T.eq(#files, 2)
		-- sorted: init.lua, pkg.lua
		T.eq(files[1], "init.lua")
		T.eq(files[2], "pkg.lua")
		rm_tmpdir(tmp)
	end)

	T.it("strips leading ./ from explicit paths", function()
		local tmp = make_tmpdir()
		write_manifest(tmp, { name = "mypkg", version = "1.0.0" })
		write_file(tmp .. "/init.lua", "return {}")
		local m = { name = "mypkg", version = "1.0.0", files = { "./init.lua", "./pkg.lua" } }
		local files, err = publish.collect_files(tmp, m)
		T.ok(files, tostring(err))
		T.eq(files[1], "init.lua")
		T.eq(files[2], "pkg.lua")
		rm_tmpdir(tmp)
	end)

	T.it("returns error when files entry is not a string", function()
		local tmp = make_tmpdir()
		write_manifest(tmp, { name = "mypkg", version = "1.0.0" })
		local m = { name = "mypkg", version = "1.0.0", files = { 42 } }
		local files, err = publish.collect_files(tmp, m)
		T.eq(files, nil)
		T.ok(err ~= nil)
		rm_tmpdir(tmp)
	end)

end)

T.describe("publish.collect_files — default exclusion rules", function()

	T.it("collects .lua files and excludes *_test.lua", function()
		local tmp = make_tmpdir()
		write_manifest(tmp, { name = "mypkg", version = "1.0.0" })
		write_file(tmp .. "/init.lua",       "return {}")
		write_file(tmp .. "/util.lua",       "return {}")
		write_file(tmp .. "/init_test.lua",  "-- test")
		local m = manifest.load(tmp .. "/pkg.lua")
		T.ok(m)
		local files, err = publish.collect_files(tmp, m)
		T.ok(files, tostring(err))
		-- Should include init.lua, util.lua, pkg.lua; exclude init_test.lua
		local set = {}
		for _, f in ipairs(files) do set[f] = true end
		T.ok(set["init.lua"],      "init.lua should be included")
		T.ok(set["util.lua"],      "util.lua should be included")
		T.ok(set["pkg.lua"],       "pkg.lua should be included")
		T.ok(not set["init_test.lua"], "init_test.lua should be excluded")
		rm_tmpdir(tmp)
	end)

	T.it("excludes bench.lua", function()
		local tmp = make_tmpdir()
		write_manifest(tmp, { name = "mypkg", version = "1.0.0" })
		write_file(tmp .. "/init.lua",  "return {}")
		write_file(tmp .. "/bench.lua", "-- bench")
		local m = manifest.load(tmp .. "/pkg.lua")
		T.ok(m)
		local files, err = publish.collect_files(tmp, m)
		T.ok(files, tostring(err))
		local set = {}
		for _, f in ipairs(files) do set[f] = true end
		T.ok(not set["bench.lua"], "bench.lua should be excluded")
		rm_tmpdir(tmp)
	end)

	T.it("excludes fixtures/ directory", function()
		local tmp = make_tmpdir()
		write_manifest(tmp, { name = "mypkg", version = "1.0.0" })
		write_file(tmp .. "/init.lua", "return {}")
		os.execute(("mkdir -p %q"):format(tmp .. "/fixtures"))
		write_file(tmp .. "/fixtures/sample.lua", "-- fixture")
		local m = manifest.load(tmp .. "/pkg.lua")
		T.ok(m)
		local files, err = publish.collect_files(tmp, m)
		T.ok(files, tostring(err))
		local set = {}
		for _, f in ipairs(files) do set[f] = true end
		T.ok(not set["fixtures/sample.lua"], "fixtures/sample.lua should be excluded")
		rm_tmpdir(tmp)
	end)

	T.it("excludes docs/ directory", function()
		local tmp = make_tmpdir()
		write_manifest(tmp, { name = "mypkg", version = "1.0.0" })
		write_file(tmp .. "/init.lua", "return {}")
		os.execute(("mkdir -p %q"):format(tmp .. "/docs"))
		write_file(tmp .. "/docs/readme.lua", "-- doc")
		local m = manifest.load(tmp .. "/pkg.lua")
		T.ok(m)
		local files, err = publish.collect_files(tmp, m)
		T.ok(files, tostring(err))
		local set = {}
		for _, f in ipairs(files) do set[f] = true end
		T.ok(not set["docs/readme.lua"], "docs/readme.lua should be excluded")
		rm_tmpdir(tmp)
	end)

	T.it("result is sorted", function()
		local tmp = make_tmpdir()
		write_manifest(tmp, { name = "mypkg", version = "1.0.0" })
		write_file(tmp .. "/z.lua", "")
		write_file(tmp .. "/a.lua", "")
		write_file(tmp .. "/m.lua", "")
		local m = manifest.load(tmp .. "/pkg.lua")
		T.ok(m)
		local files, err = publish.collect_files(tmp, m)
		T.ok(files, tostring(err))
		for i = 2, #files do
			T.ok(files[i-1] <= files[i], "files should be sorted")
		end
		rm_tmpdir(tmp)
	end)

end)

-- ── publish.build_tarball ─────────────────────────────────────────────────────

T.describe("publish.build_tarball", function()

	T.it("creates a non-empty tarball", function()
		local tmp = make_tmpdir()
		write_manifest(tmp, { name = "mypkg", version = "1.0.0" })
		write_file(tmp .. "/init.lua", "return {}")

		local dest = os.tmpname() .. ".tar.gz"
		local ok, err = publish.build_tarball(tmp, { "pkg.lua", "init.lua" }, dest)
		T.ok(ok, tostring(err))

		-- Verify file exists and is non-empty
		local fh = io.open(dest, "rb")
		T.ok(fh, "tarball file should exist")
		local content = fh:read("*a")
		fh:close()
		T.ok(#content > 0, "tarball should be non-empty")

		os.remove(dest)
		rm_tmpdir(tmp)
	end)

	T.it("tarball contains expected files", function()
		local tmp = make_tmpdir()
		write_manifest(tmp, { name = "mypkg", version = "1.0.0" })
		write_file(tmp .. "/init.lua", "return {}")

		local dest = os.tmpname() .. ".tar.gz"
		local ok, err = publish.build_tarball(tmp, { "pkg.lua", "init.lua" }, dest)
		T.ok(ok, tostring(err))

		-- List tarball contents
		local fh = io.popen(("tar -tzf %q 2>&1"):format(dest), "r")
		T.ok(fh, "tar -tzf should work")
		local listing = fh:read("*a")
		fh:close()
		T.ok(listing:find("init%.lua"),  "tarball should contain init.lua")
		T.ok(listing:find("pkg%.lua"),   "tarball should contain pkg.lua")

		os.remove(dest)
		rm_tmpdir(tmp)
	end)

	T.it("returns error for empty files list", function()
		local tmp = make_tmpdir()
		local dest = os.tmpname() .. ".tar.gz"
		local ok, err = publish.build_tarball(tmp, {}, dest)
		T.eq(ok, nil)
		T.ok(err ~= nil)
		rm_tmpdir(tmp)
	end)

end)

-- ── publish.sha256_file ───────────────────────────────────────────────────────

T.describe("publish.sha256_file", function()

	T.it("returns a 64-char hex string for a known file", function()
		local tmp = os.tmpname()
		local fh = assert(io.open(tmp, "wb"))
		fh:write("hello\n")
		fh:close()
		local hex, err = publish.sha256_file(tmp)
		T.ok(hex, tostring(err))
		T.eq(#hex, 64)
		T.ok(hex:match("^%x+$"), "hex must be hex digits")
		os.remove(tmp)
	end)

	T.it("returns deterministic checksum for same content", function()
		local tmp = os.tmpname()
		local fh = assert(io.open(tmp, "wb"))
		fh:write("crescent package manager")
		fh:close()
		local hex1 = publish.sha256_file(tmp)
		local hex2 = publish.sha256_file(tmp)
		T.eq(hex1, hex2)
		os.remove(tmp)
	end)

end)

-- ── publish.run (dry_run) ─────────────────────────────────────────────────────

T.describe("publish.run dry_run", function()

	T.it("returns ok=true with name/version/checksum in dry_run mode", function()
		local tmp = make_tmpdir()
		write_manifest(tmp, { name = "mypkg", version = "2.3.4" })
		write_file(tmp .. "/init.lua", "return {}")
		local result = publish.run(tmp, { dry_run = true })
		T.ok(result.ok,     "dry_run should succeed")
		T.eq(result.name,    "mypkg")
		T.eq(result.version, "2.3.4")
		T.ok(result.checksum ~= nil, "checksum should be set")
		T.ok(result.checksum:match("^sha256:%x+"), "checksum should be sha256:hex")
		-- Temp tarball should be cleaned up... actually dry_run keeps it; clean manually.
		if result.tarball then
			os.remove(result.tarball)
		end
		rm_tmpdir(tmp)
	end)

	T.it("returns ok=false when pkg.lua is absent", function()
		local tmp = make_tmpdir()
		local result = publish.run(tmp, { dry_run = true })
		T.ok(not result.ok)
		T.ok(result.error ~= nil)
		rm_tmpdir(tmp)
	end)

	T.it("returns ok=false when manifest is invalid", function()
		local tmp = make_tmpdir()
		-- Write a broken pkg.lua (no name)
		write_file(tmp .. "/pkg.lua", "return { version = '1.0.0' }")
		local result = publish.run(tmp, { dry_run = true })
		T.ok(not result.ok)
		T.ok(result.error ~= nil)
		rm_tmpdir(tmp)
	end)

	T.it("returns ok=false when no .lua files are found", function()
		local tmp = make_tmpdir()
		-- Write a valid pkg.lua only — but the test files are excluded by default
		-- and there are no other .lua files.  However pkg.lua itself is included,
		-- so we need a slightly different setup: manifest with explicit empty files.
		write_file(tmp .. "/pkg.lua", "return { name='empty', version='0.0.1', files={} }")
		-- files={} is not a valid manifest field (manifest.validate doesn't know it),
		-- so load via loadfile directly to bypass validate.
		-- Actually manifest.validate will pass (unknown fields are ignored).
		-- The files list is empty → build_tarball returns error.
		local result = publish.run(tmp, { dry_run = true })
		T.ok(not result.ok)
		T.ok(result.error ~= nil)
		rm_tmpdir(tmp)
	end)

end)

-- ── cli integration: publish command ─────────────────────────────────────────

T.describe("cli parse_args publish flags", function()
	local cli = require("lib.pkg.cli")

	T.it("publish command parsed correctly", function()
		local r = cli.parse_args({ "publish" })
		T.eq(r.command,  "publish")
		T.eq(r.dry_run,  false)
	end)

	T.it("--dry-run flag parsed", function()
		local r = cli.parse_args({ "publish", "--dry-run" })
		T.eq(r.command,  "publish")
		T.eq(r.dry_run,  true)
	end)

	T.it("publish with --registry flag", function()
		local r = cli.parse_args({ "publish", "--registry=https://myreg.example.com" })
		T.eq(r.command,  "publish")
		T.eq(r.registry, "https://myreg.example.com")
	end)
end)
