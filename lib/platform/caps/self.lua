-- lib/platform/caps/self.lua
-- self_cap(app, opts?) -> cap_table, revoke_fn
-- Gives a sandboxed app read-only access to its own package contents:
-- image metadata chunks and tarball entries.
--
-- Capability API (passed to sandbox as caps.self):
--   cap.metadata(keyword)  -> string | nil
--   cap.entries()           -> string[]    (list of tarball entry paths)
--   cap.entry(path)         -> string | nil (tarball entry content by path)

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local png = require("lib.png")
local tar = require("lib.tar")

local M = {}

-- self_cap(app, opts?) -> cap_table, revoke_fn
--: ({ path: string, chunks: { type: string, data: string }[] | nil, entries: { name: string, data: string }[], manifest: table }, table?) -> (table, () -> nil)
function M.self_cap(app, opts)
	local revoked = false

	local function check_revoked()
		if revoked then return nil, "capability revoked" end
	end

	local cap = {
		metadata = function(keyword)
			local err_nil, err_msg = check_revoked()
			if err_msg then return err_nil, err_msg end
			if not app.chunks then return nil end
			return png.get_text(app.chunks, keyword)
		end,

		entries = function()
			local err_nil, err_msg = check_revoked()
			if err_msg then return err_nil, err_msg end
			local paths = {}
			for i = 1, #app.entries do
				paths[i] = app.entries[i].name
			end
			return paths
		end,

		entry = function(path)
			local err_nil, err_msg = check_revoked()
			if err_msg then return err_nil, err_msg end
			return tar.get(app.entries, path)
		end,
	}

	local function revoke()
		revoked = true
	end

	return cap, revoke
end

return M
