-- lib/platform/caps/fs.lua
-- fs_cap(opts) -> capability table
-- Scoped filesystem access. All paths are relative to opts.root.
-- Path traversal (../, absolute paths) is blocked at the cap level.
--
-- opts.root        : (required) base directory
-- opts.allow_write : boolean, default false
--
-- Capability API (passed to sandbox as caps.fs):
--   cap.read(path)           -> string | nil, err
--   cap.write(path, content) -> true  | nil, err   (only if allow_write)
--   cap.list(path?)          -> string[] | nil, err (filenames, not full paths)
--
-- NOTE: list() uses io.popen("ls") — Linux/macOS only. A proper readdir FFI
-- binding is tracked in TODO.md (lib/fs or lib/socket layer rewrite).

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

-- Resolve path relative to root; reject traversal and absolute paths.
--: (string, string | nil) -> string | nil, string | nil
local function resolve(root, path)
	if not path then return nil, "fs: nil path" end
	if path:find("^/") then return nil, "fs: absolute path not allowed" end
	-- Block any component that is ".." (with optional surrounding slashes)
	if path:find("^%.%.$") or path:find("^%.%./") or path:find("/%.%.$") or path:find("/%.%./") then
		return nil, "fs: path traversal not allowed"
	end
	return root .. "/" .. path
end

-- fs_cap(opts) -> {read, write, list}
function M.fs_cap(opts)
	opts = opts or {}
	local root = opts.root
	if not root then error("fs_cap: opts.root is required") end
	root = root:gsub("/$", "")  -- strip trailing slash
	local allow_write = opts.allow_write or false

	return {
		read = function (path)
			local full, err = resolve(root, path)
			if not full then return nil, err end
			local f, ferr = io.open(full, "rb")
			if not f then return nil, "fs: cannot read " .. tostring(path) .. ": " .. tostring(ferr) end
			local content = f:read("*a")
			f:close()
			return content
		end,

		write = function (path, content)
			if not allow_write then return nil, "fs: write not granted" end
			local full, err = resolve(root, path)
			if not full then return nil, err end
			local f, ferr = io.open(full, "wb")
			if not f then return nil, "fs: cannot write " .. tostring(path) .. ": " .. tostring(ferr) end
			f:write(content)
			f:close()
			return true
		end,

		-- list(path?) -> string[] of filenames in that directory
		list = function (path)
			local dir = path and path ~= "" and path or "."
			local full, err = resolve(root, dir)
			if not full then return nil, err end
			-- TODO: replace with native readdir FFI when lib/fs exists (Linux/macOS popen for now)
			local cmd = "ls -1 " .. full .. " 2>&1"
			local p, perr = io.popen(cmd)
			if not p then return nil, "fs: list failed: " .. tostring(perr) end
			local result = {}
			for line in p:lines() do result[#result + 1] = line end
			p:close()
			return result
		end,
	}
end

return M
