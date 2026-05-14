if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T          = require("lib.test.assert")
local png_mod    = require("lib.png")
local tar_mod    = require("lib.tar")
local base64_mod = require("lib.base64")
local compress   = require("lib.compress")
local json_mod   = require("lib.format.json")
local ci_mod     = require("lib.platform.caps.create_instance")

-- ── Helpers ─────────────────────────────────────────────────────────────────

-- Minimal 1x1 PNG.
local MINIMAL_PNG = "\137PNG\r\n\26\n"
	.. "\0\0\0\rIHDR\0\0\0\1\0\0\0\1\8\2\0\0\0\144wS\222"
	.. "\0\0\0\12IDAT\8\215c\248\207\192\0\0\0\2\0\1\226!\188\51"
	.. "\0\0\0\0IEND\174B`\130"

-- Build a fake installed-app PNG containing an embedded tarball with
-- manifest.json + the given runtime files in its `lua` iTXt chunk.
local function build_app_png(runtime_manifest, runtime_files)
	local entries = {
		{ name = "manifest.json", data = json_mod.encode(runtime_manifest), mode = 420, mtime = 0, typeflag = "0" },
	}
	for _, rf in ipairs(runtime_files) do
		entries[#entries + 1] = { name = rf.name, data = rf.data, mode = 420, mtime = 0, typeflag = "0" }
	end
	local tardata = assert(tar_mod.write(entries))
	local gz = assert(compress.deflate(tardata, { format = "gzip" }))
	local b64 = base64_mod.encode(gz)
	local chunks = assert(png_mod.read(MINIMAL_PNG))
	chunks = png_mod.set_itxt(chunks, "lua", b64, { language_tag = "" })
	return png_mod.write(chunks)
end

-- Write a string to a temp file and return its path.
local function write_temp(bytes, suffix)
	local path = os.tmpname()
	if suffix then path = path .. suffix end
	local f = assert(io.open(path, "wb"))
	f:write(bytes)
	f:close()
	return path
end

-- Build a fake index_obj with :list() returning a single row whose path
-- matches `installed_path`, so the cap can resolve the new app id.
local function make_mock_index(installed_path)
	return {
		list = function() return { { id = 7, path = installed_path } } end,
		install = function() return 7 end,
	}
end

-- Build a fake import_card that records its input and reports back a path.
local function make_fake_import(out_path)
	local calls = {}
	local fn = function(opts)
		calls[#calls + 1] = opts
		return out_path, { name = "fake" }
	end
	return fn, calls
end

-- ── extract_runtime ─────────────────────────────────────────────────────────

T.describe("create_instance._extract_runtime", function()
	T.it("reads runtime_files + manifest from a PNG-wrapped app", function()
		local manifest = { name = "x", entry = { server = { main = "server.lua" } } }
		local png_bytes = build_app_png(manifest, { { name = "server.lua", data = "return {}" } })
		local app_path = write_temp(png_bytes, ".png")
		local files, mf = ci_mod._extract_runtime(app_path)
		os.remove(app_path)
		T.ok(files ~= nil, "extract_runtime returned nil")
		T.eq(#files, 1)
		T.eq(files[1].name, "server.lua")
		T.eq(files[1].data, "return {}")
		T.eq(mf.name, "x")
	end)

	T.it("reads runtime from a raw .tar.gz app", function()
		local manifest = { name = "y" }
		local entries = {
			{ name = "manifest.json", data = json_mod.encode(manifest), mode = 420, mtime = 0, typeflag = "0" },
			{ name = "init.lua", data = "return 1", mode = 420, mtime = 0, typeflag = "0" },
		}
		local tardata = assert(tar_mod.write(entries))
		local gz = assert(compress.deflate(tardata, { format = "gzip" }))
		local app_path = write_temp(gz, ".tar.gz")
		local files, mf = ci_mod._extract_runtime(app_path)
		os.remove(app_path)
		T.ok(files ~= nil)
		T.eq(#files, 1)
		T.eq(files[1].name, "init.lua")
		T.eq(mf.name, "y")
	end)

	T.it("errors on a file that is neither PNG nor gzip", function()
		local app_path = write_temp("not a real app", ".bin")
		local files, err = ci_mod._extract_runtime(app_path)
		os.remove(app_path)
		T.eq(files, nil)
		T.ok(tostring(err):find("unrecognized") ~= nil, "expected unrecognized format error, got: " .. tostring(err))
	end)
end)

-- ── create_instance_cap ─────────────────────────────────────────────────────

T.describe("create_instance_cap", function()
	-- Helper: set up a cap wired to a fake import + index.
	local function setup(opts)
		opts = opts or {}
		local manifest = { name = "ccv2", entry = { server = { main = "server.lua" } } }
		local png_bytes = build_app_png(manifest, { { name = "server.lua", data = "return {}" } })
		local app_path = write_temp(png_bytes, ".png")
		local installed = opts.installed_path or "/tmp/fake-installed.png"
		local index_obj = make_mock_index(installed)
		local audit_events = {}
		local audit_log = {
			append = function(self, event, data)
				audit_events[#audit_events + 1] = { event = event, data = data }
			end,
		}
		local cap, revoke = ci_mod.create_instance_cap(
			{ path = app_path },
			{
				apps_dir  = "/tmp",
				write_fn  = function() return true end,
				index_obj = index_obj,
				time_fn   = function() return 123 end,
				audit_log = audit_log,
			})
		local fake_import, calls = make_fake_import(installed)
		cap._set_import_card(fake_import)
		return cap, revoke, calls, audit_events, app_path
	end

	T.it("returns (cap_table, revoke_fn) with create + _type", function()
		local cap, revoke = setup()
		T.eq(cap._type, "create_instance")
		T.ok(type(cap.create) == "function")
		T.ok(type(revoke) == "function")
	end)

	T.it("create(bytes) invokes import and returns (app_id, launch_url)", function()
		local cap, _, calls, audit, app_path = setup({ installed_path = "/tmp/inst-7.png" })
		local id, launch = cap.create("\x89PNG\r\n\26\n payload")
		os.remove(app_path)
		T.eq(id, 7)
		T.eq(launch, "/launch/7")
		T.eq(#calls, 1)
		T.eq(calls[1].png_bytes, "\x89PNG\r\n\26\n payload")
		T.eq(calls[1].apps_dir, "/tmp")
		T.eq(calls[1].timestamp, 123)
		T.eq(#audit, 1)
		T.eq(audit[1].event, "app_install")
		T.eq(audit[1].data.via_cap, "create_instance")
	end)

	T.it("revoked cap returns (nil, 'capability revoked')", function()
		local cap, revoke, _, _, app_path = setup()
		revoke()
		local id, err = cap.create("\x89PNG payload")
		os.remove(app_path)
		T.eq(id, nil)
		T.eq(err, "capability revoked")
	end)

	T.it("invalid bytes (too short / non-string) return an error", function()
		local cap, _, _, _, app_path = setup()
		local id, err = cap.create("abc")
		T.eq(id, nil)
		T.ok(tostring(err):find("bytes required") ~= nil)
		local id2, err2 = cap.create(nil)
		T.eq(id2, nil)
		T.ok(tostring(err2):find("bytes required") ~= nil)
		os.remove(app_path)
	end)

	T.it("import failure surfaces an error", function()
		local cap, _, _, _, app_path = setup()
		cap._set_import_card(function() return nil, "fake import boom" end)
		local id, err = cap.create("\x89PNG payload")
		os.remove(app_path)
		T.eq(id, nil)
		T.ok(tostring(err):find("fake import boom") ~= nil)
	end)
end)
