-- lib/path: cross-platform filesystem path manipulation (pure string ops, no I/O)
if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

M._tier = "pure"

-- Platform detection via package.config (first char is dir separator)
local _plat_sep = (package.config --[[:! string]]):sub(1, 1)
M.sep     = _plat_sep
M.altsep  = _plat_sep == "\\" and "/" or nil
M.pathsep = _plat_sep == "\\" and ";" or ":"
M.devnull = _plat_sep == "\\" and "nul" or "/dev/null"

-- Normalize input: treat both / and \ as separators (always use / internally)
--: (string) -> string
local function norm_seps(s)
	local r, _ = s:gsub("\\", "/"); return r
end

-- Convert output back to platform sep
--: (string) -> string
local function to_native(s)
	if M.sep == "/" then return s
	else
		local r, _ = s:gsub("/", "\\"); return r
	end
end

-- Split a normalized (forward-slash) path into drive and rest.
-- On Unix, drive is always "".
-- On Windows, drive can be "C:" for drive-letter paths.
--: (string) -> (string, string)
local function splitdrive(p)
	if p:match("^%a:/") or p:match("^%a:$") then
		return p:sub(1, 2), p:sub(3)
	end
	return "", p
end

-- Check if path is absolute (internal, uses normalized forward slashes).
--: (string) -> boolean
local function is_abs_norm(n)
	if n:sub(1, 1) == "/" then return true end
	-- Windows: C:/ or UNC //
	if n:match("^%a:/") then return true end
	if n:sub(1, 2) == "//" then return true end
	return false
end

---Check if path is absolute.
--: (string) -> boolean
M.is_absolute = function(p)
	if p == nil or p == "" then return false end
	return is_abs_norm(norm_seps(p))
end

---Join path components. An absolute component resets the path.
--: (...string) -> string
M.join = function(...)
	local args = { ... }
	local result = ""
	for _, p in ipairs(args) do
		if p ~= nil and p ~= "" then
			if is_abs_norm(norm_seps(p)) then
				result = p
			elseif result == "" then
				result = p
			else
				-- strip trailing sep from result
				local r = norm_seps(result):gsub("/+$", "")
				result = r .. "/" .. norm_seps(p)
			end
		end
	end
	return to_native(result)
end

---Split path into (dir, file) pair.
--: (string) -> (string, string)
M.split = function(p)
	local n = norm_seps(p)
	-- Find last slash
	local i = #n
	while i > 0 and n:sub(i, i) ~= "/" do
		i = i - 1
	end
	if i == 0 then
		return ".", n
	end
	local dir = n:sub(1, i):gsub("/+$", "")
	local file = n:sub(i + 1)
	if dir == "" then dir = "/" end
	return to_native(dir), file
end

---Get the last component (filename). Strips trailing separators.
--: (string) -> string
M.basename = function(p)
	local n = norm_seps(p):gsub("/+$", "")
	if n == "" then return "" end
	local i = #n
	while i > 0 and n:sub(i, i) ~= "/" do
		i = i - 1
	end
	return n:sub(i + 1)
end

---Get directory component of path.
--: (string) -> string
M.dirname = function(p)
	local dir, _ = M.split(p)
	return dir
end

---Split extension from path. Returns (root, ext).
--- Dotfiles like ".bashrc" have no extension.
--: (string) -> (string, string)
M.splitext = function(p)
	local n = norm_seps(p)
	-- Find the basename start position
	local slash = 0
	for i = #n, 1, -1 do
		if n:sub(i, i) == "/" then
			slash = i
			break
		end
	end
	local base = n:sub(slash + 1)
	local prefix = n:sub(1, slash)  -- everything up to and including last slash

	-- Find last dot in basename, skipping a leading dot
	local start = 1
	if base:sub(1, 1) == "." then start = 2 end

	local dot_pos = nil
	for i = #base, start, -1 do
		if base:sub(i, i) == "." then
			dot_pos = i
			break
		end
	end

	if dot_pos == nil then
		return to_native(p), ""
	end

	local root = prefix .. base:sub(1, dot_pos - 1)
	local ext = base:sub(dot_pos)
	return to_native(root), ext
end

---Get file extension (last dot suffix).
--: (string) -> string
M.ext = function(p)
	local _, e = M.splitext(p)
	return e
end

---Normalize: resolve . and .., collapse multiple separators.
--: (string) -> string
M.normalize = function(p)
	local n = norm_seps(p)
	local drive, rest = splitdrive(n)
	local is_abs = rest:sub(1, 1) == "/"
	local prefix = drive .. (is_abs and "/" or "")

	local parts = {}
	for part in rest:gmatch("[^/]+") do
		parts[#parts + 1] = part
	end

	local stack = {} --: { [integer]: string }
	for _, part in ipairs(parts) do
		if part == "." then
			-- skip
		elseif part == ".." then
			if #stack > 0 and stack[#stack] ~= ".." then
				stack[#stack] = nil --[[: unknown]]
			elseif not is_abs then
				stack[#stack + 1] = ".."
			end
			-- absolute: silently ignore going above root
		else
			stack[#stack + 1] = part
		end
	end

	local result
	if #stack == 0 then
		result = prefix ~= "" and prefix or "."
	else
		result = prefix .. table.concat(stack, "/")
	end

	return to_native(result)
end

---Split path into all components.
--: (string) -> { [number]: string }
M.parts = function(p)
	local n = norm_seps(p)
	local drive, rest = splitdrive(n)
	local is_abs = rest:sub(1, 1) == "/"
	local result = {}

	if is_abs then
		result[#result + 1] = to_native(drive .. "/")
	elseif drive ~= "" then
		result[#result + 1] = drive
	end

	for part in rest:gmatch("[^/]+") do
		result[#result + 1] = part
	end

	return result
end

---Compute relative path from `start` to `path`.
--: (string, string) -> string
M.relative = function(path, start)
	local p = norm_seps(M.normalize(path))
	local s = norm_seps(M.normalize(start))

	local function split_parts(str)
		local t = {}
		for part in str:gmatch("[^/]+") do
			t[#t + 1] = part
		end
		return t
	end

	local p_parts = split_parts(p)
	local s_parts = split_parts(s)

	local common = 0
	local min_len = math.min(#p_parts, #s_parts)
	for i = 1, min_len do
		if p_parts[i] == s_parts[i] then
			common = i
		else
			break
		end
	end

	local result = {}
	for _ = 1, #s_parts - common do
		result[#result + 1] = ".."
	end
	for i = common + 1, #p_parts do
		result[#result + 1] = p_parts[i]
	end

	if #result == 0 then return "." end
	return to_native(table.concat(result, "/"))
end

---Find common path prefix of a list of paths.
--: ({ [number]: string }) -> string
M.commonpath = function(paths)
	if not paths or #paths == 0 then return "" end

	local all_parts = {} --: { [integer]: { [integer]: string } }
	for _, path in ipairs(paths) do
		local n = norm_seps(M.normalize(path))
		local t = {} --: { [integer]: string }
		for part in n:gmatch("[^/]+") do
			t[#t + 1] = part
		end
		all_parts[#all_parts + 1] = t
	end

	local ap1 = all_parts[1] --[[:! { [integer]: string }]]
	local min_len = #ap1
	for i = 2, #all_parts do
		local api = all_parts[i] --[[:! { [integer]: string }]]
		if #api < min_len then min_len = #api end
	end

	local common = {} --: { [integer]: string }
	for i = 1, min_len do
		local val = ap1[i]
		local matched = true
		for j = 2, #all_parts do
			local apj = all_parts[j] --[[:! { [integer]: string }]]
			if apj[i] ~= val then
				matched = false
				break
			end
		end
		if matched then
			common[#common + 1] = val
		else
			break
		end
	end

	if #common == 0 then return "" end
	return to_native(table.concat(common, "/"))
end

---Resolve a relative path against a base directory, rejecting traversal above base.
---Returns nil if the resolved path escapes the base (via .. or absolute path).
--: (string, string) -> string | nil
M.safe_resolve = function(base, rel)
	if rel == nil or rel == "" then return nil end
	-- Reject absolute paths.
	if is_abs_norm(norm_seps(rel)) then return nil end
	local joined = M.join(base, rel)
	local resolved = M.normalize(joined)
	local norm_base = M.normalize(base)
	-- Ensure resolved starts with base (no traversal escape).
	local rb = norm_seps(resolved)
	local nb = norm_seps(norm_base)
	if nb:sub(-1) ~= "/" then nb = nb .. "/" end
	if rb == norm_seps(norm_base) then return resolved end
	if rb:sub(1, #nb) ~= nb then return nil end
	return resolved
end

---Expand leading ~ to home directory.
--: (string, string) -> string
M.expanduser = function(p, home)
	if type(home) ~= "string" then
		error("expanduser: home directory string is required")
	end
	if p:sub(1, 1) ~= "~" then return p end
	if p == "~" then return home end
	local rest = p:sub(2):gsub("^[/\\]", "")
	if home == "" then
		return to_native("~/" .. rest)
	end
	return M.join(home, rest)
end

return M
