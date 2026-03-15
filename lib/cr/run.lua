-- lib/cr/run.lua
-- `cr run <file>` — run a Lua file with lib/ on package.path.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

--- Run a Lua file with the project's lib/ available via require.
-- argv[1] is the file to run; remaining argv are passed as script args.
function M.main(argv)
	local file = argv and argv[1]
	if not file then
		io.stderr:write("usage: cr run <file>\n")
		os.exit(1)
	end

	-- Ensure ./?.lua and ./?/init.lua are on path so user scripts can require
	-- lib/ packages relative to cwd.
	local cwd_lua   = "./?.lua"
	local cwd_init  = "./?/init.lua"
	if not package.path:find(cwd_lua, 1, true) then
		package.path = cwd_lua .. ";" .. package.path
	end
	if not package.path:find(cwd_init, 1, true) then
		package.path = cwd_init .. ";" .. package.path
	end

	dofile(file)
end

return M
