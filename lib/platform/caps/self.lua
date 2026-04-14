-- lib/platform/caps/self.lua
-- self_cap(app) -> capability table
-- Provides the app access to its own manifest and tarball entries.
--
-- Capability API (passed to sandbox as caps.self):
--   cap.manifest()     -> table  (parsed manifest.json, read-only copy)
--   cap.name()         -> string
--   cap.version()      -> string
--   cap.entry_names()  -> string[] (keys of manifest.entry)

local M = {}

-- self_cap(app) -> {manifest, name, version, entry_names}
function M.self_cap(app)
	local manifest = app.manifest or {}
	return {
		manifest = function()
			-- Return a shallow copy to prevent mutation
			local copy = {}
			for k, v in pairs(manifest) do copy[k] = v end
			return copy
		end,
		name = function() return manifest.name end,
		version = function() return manifest.version end,
		entry_names = function()
			local names = {}
			if manifest.entry then
				for k in pairs(manifest.entry) do
					names[#names + 1] = k
				end
			end
			return names
		end,
	}
end

return M
