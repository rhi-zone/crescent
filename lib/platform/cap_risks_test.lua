if not package.path:find("./?/init.lua", 1, true) then package.path = "./?/init.lua;" .. package.path end

local T = require("lib.test.assert")
local json = require("lib.format.json")
local cap_risks = require("lib.platform.cap_risks")

local MANIFEST_PATHS = {
	"lib/platform/apps/library/manifest.json",
	"lib/platform/apps/charactercardv2/manifest.json",
	"lib/platform/apps/sillytavern/manifest.json",
	"lib/platform/apps/system_dashboard/manifest.json",
}

local function read_file(path)
	local f, err = io.open(path, "r")
	if not f then return nil, err end
	local content = f:read("*a")
	f:close()
	return content
end

local function collect_cap_types(manifest)
	local types = {}
	local function scan(caps)
		if type(caps) ~= "table" then return end
		for _, decl in pairs(caps) do
			if type(decl) == "table" and decl.type then
				types[decl.type] = decl
			end
		end
	end
	if manifest.caps then scan(manifest.caps) end
	if manifest.entry then
		for _, entry in pairs(manifest.entry) do
			if entry.caps then scan(entry.caps) end
		end
	end
	return types
end

T.describe("cap_risks", function()
	T.describe("in-tree manifest cap types all have descriptions", function()
		local all_types = {}
		for _, path in ipairs(MANIFEST_PATHS) do
			local content, err = read_file(path)
			T.ok(content, "could not read " .. path .. ": " .. tostring(err))
			local manifest = json.decode(content)
			T.ok(manifest, "could not parse " .. path)
			local types = collect_cap_types(manifest)
			for t, decl in pairs(types) do
				all_types[t] = decl
			end
		end

		for t, decl in pairs(all_types) do
			T.describe("type=" .. t, function()
				local result = cap_risks.describe(decl)
				T.ok(result ~= nil, "describe returned nil for type=" .. t)
				T.ok(result.severity ~= nil, "missing severity for type=" .. t)
				T.ok(result.text ~= nil, "missing text for type=" .. t)
			end)
		end
	end)

	T.describe("fs varies by readonly", function()
		local rw = cap_risks.describe({ type = "fs", root = "/tmp/data" })
		T.eq(rw.severity, "high")
		local ro = cap_risks.describe({ type = "fs", root = "/tmp/data", readonly = true })
		T.eq(ro.severity, "medium")
		T.ok(ro.text:find("/tmp/data"), "readonly text includes root path")
		T.ok(rw.text:find("/tmp/data"), "writable text includes root path")
	end)

	T.describe("http_client varies by paths", function()
		local full = cap_risks.describe({ type = "http_client", host = "api.example.com" })
		T.eq(full.severity, "high")
		T.ok(full.text:find("api.example.com"), "text includes host")
		local scoped = cap_risks.describe({ type = "http_client", host = "api.example.com", paths = {"/v1"} })
		T.eq(scoped.severity, "medium")
		T.ok(scoped.text:find("api.example.com"), "scoped text includes host")
	end)

	T.describe("db varies by readonly", function()
		T.eq(cap_risks.describe({ type = "db" }).severity, "low")
		T.eq(cap_risks.describe({ type = "db", readonly = true }).severity, "low")
	end)

	T.describe("shared_db varies by readonly", function()
		T.eq(cap_risks.describe({ type = "shared_db" }).severity, "medium")
		T.eq(cap_risks.describe({ type = "shared_db", readonly = true }).severity, "low")
	end)

	T.describe("self varies by writable", function()
		T.eq(cap_risks.describe({ type = "self" }).severity, "low")
		T.eq(cap_risks.describe({ type = "self", writable = true }).severity, "medium")
	end)

	T.describe("registry varies by allow_write", function()
		T.eq(cap_risks.describe({ type = "registry" }).severity, "medium")
		T.eq(cap_risks.describe({ type = "registry", allow_write = false }).severity, "medium")
		T.eq(cap_risks.describe({ type = "registry", allow_write = true }).severity, "high")
	end)

	T.describe("shell is critical", function()
		T.eq(cap_risks.describe({ type = "shell" }).severity, "critical")
	end)

	T.describe("unknown type returns nil", function()
		T.ok(cap_risks.describe({ type = "nonexistent_future_cap" }) == nil)
	end)
end)
