-- lib/bundle/init.lua — Lua module bundler
-- Resolves static require() calls and inlines all dependencies into a single
-- self-contained Lua file. Computed requires fall through to the real require.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

-- Pattern to match static require calls with string literal arguments.
-- Captures the module name from require("mod") or require('mod').
local REQUIRE_PAT = "require%s*%(%s*([\"'])([^\"']+)%1%s*%)"

--- Extract all static require() module names from a source string.
--: (source: string) -> { string }
local function extract_requires(source)
	local deps = {}
	local seen = {}
	for _, name in source:gmatch(REQUIRE_PAT) do
		if not seen[name] then
			seen[name] = true
			deps[#deps + 1] = name
		end
	end
	return deps
end

--- Resolve a dotted module name to a file path using search_paths.
--- Tries: <search_path>/<mod_path>/init.lua, then <search_path>/<mod_path>.lua,
--- then top-level <mod_path>/init.lua and <mod_path>.lua.
--: (mod_name: string, read_fn: (string) -> string | nil, search_paths: { string } | nil) -> string | nil, string | nil
local function resolve_module(mod_name, read_fn, search_paths)
	local mod_path = mod_name:gsub("%.", "/")
	-- Candidate suffixes to try for each base directory
	local suffixes = { "/" .. mod_path .. "/init.lua", "/" .. mod_path .. ".lua" }
	-- Try each search path
	if search_paths then
		for i = 1, #search_paths do
			local base = search_paths[i]
			for j = 1, #suffixes do
				local path = base .. suffixes[j]
				local content = read_fn(path)
				if content then return path, content end
			end
		end
	end
	-- Try from working directory
	local top_suffixes = { mod_path .. "/init.lua", mod_path .. ".lua" }
	for j = 1, #top_suffixes do
		local path = top_suffixes[j]
		local content = read_fn(path)
		if content then return path, content end
	end
	return nil, nil
end

--- Recursively collect all dependencies starting from a source string.
--- Returns an ordered list of { name = mod_name, source = source_string }
--- in dependency order (leaves first), plus a set of module names.
--: (entry_source: string, resolve_fn: (name: string) -> string | nil, visited: { [string]: boolean } | nil, order: { { name: string, source: string } } | nil) -> { { name: string, source: string } }, { [string]: boolean }
local function collect_deps(entry_source, resolve_fn, visited, order)
	visited = visited or {}
	order = order or {}
	local deps = extract_requires(entry_source)
	for i = 1, #deps do
		local name = deps[i]
		if not visited[name] then
			visited[name] = true
			local src = resolve_fn(name)
			if src then
				-- Recurse into this module's dependencies first
				collect_deps(src, resolve_fn, visited, order)
				order[#order + 1] = { name = name, source = src }
			end
			-- If src is nil, the module is unresolvable and will fall through
			-- to the real require at runtime.
		end
	end
	return order, visited
end

--- Generate the bundled output string.
--: (modules: { { name: string, source: string } }, entry_source: string, opts: { shebang: string | nil } | nil) -> string
local function emit_bundle(modules, entry_source, opts)
	local parts = {}
	local n = 0
	local function add(s)
		n = n + 1
		parts[n] = s
	end
	-- Optional shebang
	if opts and opts.shebang then
		add(opts.shebang)
		add("\n")
	end
	-- Module loader preamble
	add("local __modules = {}\n")
	add("local __cache = {}\n")
	add("local __require = function(name)\n")
	add("\tif __cache[name] ~= nil then return __cache[name] end\n")
	add("\tlocal loader = __modules[name]\n")
	add("\tif not loader then return require(name) end\n")
	add("\t__cache[name] = true\n")
	add("\tlocal result = loader()\n")
	add("\tif result ~= nil then __cache[name] = result end\n")
	add("\treturn __cache[name]\n")
	add("end\n\n")
	-- Module definitions
	for i = 1, #modules do
		local mod = modules[i]
		add("__modules[\"")
		add(mod.name)
		add("\"] = function()\n")
		add("\tlocal require = __require\n")
		-- Indent each line of the module source
		local src = mod.source
		-- Remove trailing newline to avoid empty trailing line
		if src:sub(-1) == "\n" then src = src:sub(1, -2) end
		for line in (src .. "\n"):gmatch("([^\n]*)\n") do
			add("\t")
			add(line)
			add("\n")
		end
		add("end\n\n")
	end
	-- Entry point
	add("local require = __require\n")
	-- Inline entry source directly
	add(entry_source)
	if entry_source:sub(-1) ~= "\n" then
		add("\n")
	end
	return table.concat(parts)
end

--- Bundle a file and all its static require() dependencies into a single Lua string.
--: (entry_path: string, opts: { read_fn: (string) -> string | nil, search_paths: { string } | nil, shebang: string | nil }) -> string | nil, string | nil
function M.bundle(entry_path, opts)
	opts = opts or {}
	local read_fn = opts.read_fn
	if type(read_fn) ~= "function" then
		error("bundle: opts.read_fn function is required")
	end
	local entry_source = read_fn(entry_path)
	if not entry_source then
		return nil, "cannot read entry file: " .. entry_path
	end
	local search_paths = opts.search_paths
	local resolve_fn = function(mod_name)
		local _, content = resolve_module(mod_name, read_fn, search_paths)
		return content
	end
	local modules = collect_deps(entry_source, resolve_fn)
	return emit_bundle(modules, entry_source, opts), nil
end

--- Bundle from a source string with a custom resolver function.
--: (source: string, opts: { resolve: (name: string) -> string | nil, shebang: string | nil } | nil) -> string | nil, string | nil
function M.bundle_string(source, opts)
	if type(source) ~= "string" then
		return nil, "source must be a string"
	end
	opts = opts or {}
	local resolve_fn = opts.resolve or function() return nil end
	local modules = collect_deps(source, resolve_fn)
	return emit_bundle(modules, source, opts), nil
end

--- Analyze an entry file and return an ordered list of its transitive dependencies.
--: (entry_path: string, opts: { read_fn: (string) -> string | nil, search_paths: { string } | nil }) -> { string } | nil, string | nil
function M.analyze(entry_path, opts)
	opts = opts or {}
	local read_fn = opts.read_fn
	if type(read_fn) ~= "function" then
		error("analyze: opts.read_fn function is required")
	end
	local entry_source = read_fn(entry_path)
	if not entry_source then
		return nil, "cannot read entry file: " .. entry_path
	end
	local search_paths = opts.search_paths
	local resolve_fn = function(mod_name)
		local _, content = resolve_module(mod_name, read_fn, search_paths)
		return content
	end
	local modules = collect_deps(entry_source, resolve_fn)
	local result = {}
	for i = 1, #modules do
		result[i] = modules[i].name
	end
	return result, nil
end

--- Analyze a source string and return an ordered list of its transitive dependencies.
--: (source: string, opts: { resolve: (name: string) -> string | nil } | nil) -> { string }
function M.analyze_string(source, opts)
	opts = opts or {}
	local resolve_fn = opts.resolve or function() return nil end
	local modules = collect_deps(source, resolve_fn)
	local result = {}
	for i = 1, #modules do
		result[i] = modules[i].name
	end
	return result
end

-- Expose internals for testing
M._extract_requires = extract_requires

return M
