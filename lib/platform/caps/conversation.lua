-- lib/platform/caps/conversation.lua
-- conversation_cap(opts) -> cap, revoke_fn | nil, err
--
-- opts.path     : string — path to SQLite file (":memory:" for tests)
-- opts.time_fn  : () -> integer (optional, defaults to os.time)
--
-- Exposes lib/conversation as a platform cap. The returned cap IS the
-- conv_db handle (create_session, get_session, add_message, etc.) plus
-- a revoke() that closes the underlying db.
--
-- Usage in sandbox: caps.conversations:create_session(app_id)

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local conversation = require("lib.conversation")

local M = {}

-- conversation_cap(opts) -> cap, revoke | nil, err
function M.conversation_cap(opts)
	opts = opts or {}
	local path = opts.path or ":memory:"
	local time_fn = opts.time_fn or os.time

	local conv_db, err = conversation.open(path, time_fn)
	if not conv_db then return nil, err end

	local revoked = false

	local function revoke()
		if not revoked then
			revoked = true
			-- Close the underlying SQLite db if it has a close method.
			if conv_db._db and type(conv_db._db.close) == "function" then
				conv_db._db:close()
			end
		end
	end

	-- The cap IS the conv_db handle: same metatable, same methods.
	-- We wrap it in a proxy that checks revocation on each call.
	-- Pre-declare cap so the __index closure captures the local slot (not nil).
	-- (In Lua, local x = expr does not put x in scope inside expr.)
	local cap
	cap = setmetatable({}, {
		__index = function(_, k)
			local fn = conv_db[k]
			if type(fn) ~= "function" then return fn end
			return function(self_or_first, ...)
				if revoked then error("conversation: capability revoked", 2) end
				-- Methods use colon syntax (self = cap), forward as conv_db:method(...)
				if self_or_first == cap then
					return fn(conv_db, ...)
				end
				return fn(self_or_first, ...)
			end
		end,
	})

	return cap, revoke
end

return M
