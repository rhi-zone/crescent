-- lib/cr/run.lua
-- `cr run <file>` — run a Lua file with package.path relative to the script.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

--- Derive the directory containing a file path.
-- Returns "." for bare filenames with no directory separator.
local function script_dir(path)
	return path:match("^(.*[/\\])") or "."
end

--- Prepend a directory to package.path if not already present.
local function prepend_path(dir)
	local lua_pat  = dir .. "/?.lua"
	local init_pat = dir .. "/?/init.lua"
	if not package.path:find(init_pat, 1, true) then
		package.path = init_pat .. ";" .. package.path
	end
	if not package.path:find(lua_pat, 1, true) then
		package.path = lua_pat .. ";" .. package.path
	end
end

--- Run a Lua file with package.path set relative to the script's directory.
-- argv[1] is the file to run; remaining argv are passed as script args via `arg`.
function M.main(argv)
	local file = argv and argv[1]
	if not file then
		io.stderr:write("usage: cr run <file> [args...]\n")
		os.exit(1)
	end

	-- Set package.path to include both the script's own directory and cwd.
	local dir = script_dir(file)
	prepend_path(dir)
	-- Also keep cwd available so that lib/ packages can require each other.
	prepend_path(".")

	-- Set arg to standard Lua convention: arg[0] = script, arg[1..n] = rest.
	arg = { [0] = file }
	for i = 2, #argv do
		arg[i - 1] = argv[i]
	end

	local chunk, err = loadfile(file)
	if not chunk then
		io.stderr:write("cr run: " .. tostring(err) .. "\n")
		os.exit(1)
	end
	--: () -> nil
	local chunk_ = chunk --[[:! () -> nil]]

	local ok, run_err = pcall(chunk_)
	if not ok then
		io.stderr:write("cr run: " .. tostring(run_err) .. "\n")
		os.exit(1)
	end
end

return M
