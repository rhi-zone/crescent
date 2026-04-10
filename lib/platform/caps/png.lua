-- lib/platform/caps/png.lua
-- png_cap(path, opts) -> capability table
-- Wraps lib/png with optional chunk keyword allowlist and lazy file I/O.
--
-- opts.allow: string[] allowlist of keywords (nil = unrestricted)
--
-- Capability API (passed to sandbox as caps.png):
--   cap.text(keyword)           -> string | nil
--   cap.set_text(keyword, val)  -> nil  (writes back to disk)

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local png = require("lib.png")

local M = {}

-- png_cap(path, opts?) -> {text, set_text}
function M.png_cap(path, opts)
	opts = opts or {}
	local allow = opts.allow  -- nil = unrestricted; string[] = allowlist

	local function check_allow(keyword)
		if not allow then return end
		for i = 1, #allow do
			if allow[i] == keyword then return end
		end
		error("png: chunk '" .. keyword .. "' not allowed", 3)
	end

	local chunks_cache = nil

	local function load_chunks()
		if chunks_cache then return chunks_cache end
		local f, err = io.open(path, "rb")
		if not f then error("png: cannot open " .. path .. ": " .. tostring(err), 3) end
		local bytes = f:read("*a")
		f:close()
		local chunks, perr = png.read(bytes)
		if not chunks then error("png: read failed: " .. tostring(perr), 3) end
		chunks_cache = chunks
		return chunks
	end

	return {
		text = function (keyword)
			check_allow(keyword)
			return png.get_text(load_chunks(), keyword)
		end,
		set_text = function (keyword, val)
			check_allow(keyword)
			local chunks = load_chunks()
			chunks_cache = png.set_text(chunks, keyword, val)
			local bytes = png.write(chunks_cache)
			local f, err = io.open(path, "wb")
			if not f then error("png: cannot write " .. path .. ": " .. tostring(err), 3) end
			f:write(bytes)
			f:close()
		end,
	}
end

return M
