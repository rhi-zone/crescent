if not package.path:find("./?/init.lua", 1, true) then package.path = "./?/init.lua;" .. package.path end

local T = require("lib.test.assert")
local json = require("lib.format.json")
local cap_dispatch = require("lib.platform.cap_dispatch")

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

T.describe("cap_dispatch", function()
	T.describe("in-tree manifest cap types all have risk descriptions", function()
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
				local result = cap_dispatch.risk(decl)
				T.ok(result ~= nil, "risk returned nil for type=" .. t)
				T.ok(result.severity ~= nil, "missing severity for type=" .. t)
				T.ok(result.text ~= nil, "missing text for type=" .. t)
			end)
		end
	end)

	T.describe("unknown type returns nil", function()
		T.ok(cap_dispatch.risk({ type = "nonexistent_future_cap" }) == nil)
	end)
end)
