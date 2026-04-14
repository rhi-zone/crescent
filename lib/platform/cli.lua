-- lib/platform/cli.lua
-- CLI entry point for launching a crescent platform app.
--
-- Usage:
--   luajit lib/platform/cli.lua <app_dir> [options]
--
-- Options:
--   --port=N          HTTP port (default 7860)
--   --user=NAME       User display name (default "User")
--   --data-dir=PATH   Directory for persistent data (default ~/.crescent/data)
--   --card=PATH       Card PNG for self.metadata (default: first .png in app dir)
--   --endpoint=URL    LLM endpoint URL (default http://localhost:8000)
--   --model=NAME      LLM model name (default "default")
--   --api-key=KEY     LLM API key (optional)
--   --db=PATH         SQLite DB path for conversations (default <data-dir>/conversations.db)
--
-- Currently supports directory mode only (for development).
-- The app directory must contain a server.lua that exports M.create(caps, opts).

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

-- ── Arg parsing ────────────────────────────────────────────────────────────

local function parse_args(args)
	local opts = {
		port = 7860,
		user = "User",
		data_dir = nil,
		card = nil,
		endpoint = "http://localhost:8000",
		model = "default",
		api_key = nil,
		db = nil,
	}
	local positional = nil

	for i = 1, #args do
		local a = args[i]
		local key, val = a:match("^%-%-([^=]+)=(.*)")
		if key then
			if key == "port" then
				opts.port = tonumber(val) or opts.port
			elseif key == "user" then
				opts.user = val
			elseif key == "data-dir" then
				opts.data_dir = val
			elseif key == "card" then
				opts.card = val
			elseif key == "endpoint" then
				opts.endpoint = val
			elseif key == "model" then
				opts.model = val
			elseif key == "api-key" then
				opts.api_key = val
			elseif key == "db" then
				opts.db = val
			else
				io.stderr:write("unknown option: --" .. key .. "\n")
				os.exit(1)
			end
		elseif a:sub(1, 1) ~= "-" then
			if positional then
				io.stderr:write("unexpected positional argument: " .. a .. "\n")
				os.exit(1)
			end
			positional = a
		else
			io.stderr:write("unknown flag: " .. a .. "\n")
			os.exit(1)
		end
	end

	if not positional then
		io.stderr:write("usage: luajit lib/platform/cli.lua <app_dir> [options]\n")
		os.exit(1)
	end

	opts.app_dir = positional
	return opts
end

-- ── Helpers ────────────────────────────────────────────────────────────────

local function expand_home(path)
	if path:sub(1, 1) == "~" then
		local home = os.getenv("HOME") or ""
		return home .. path:sub(2)
	end
	return path
end

local function is_dir(path)
	local f = io.open(path .. "/.", "r")
	if f then f:close(); return true end
	return false
end

local function file_exists(path)
	local f = io.open(path, "rb")
	if f then f:close(); return true end
	return false
end

local function read_file(path)
	local f, err = io.open(path, "rb")
	if not f then return nil, err end
	local content = f:read("*a")
	f:close()
	return content
end

-- Find the first .png file in a directory. Returns path or nil.
local function find_card_png(dir)
	-- Use ls via popen to list files (cross-platform enough for dev mode).
	local p = io.popen('ls -1 "' .. dir .. '" 2>/dev/null')
	if not p then return nil end
	for name in p:lines() do
		if name:match("%.png$") then
			p:close()
			return dir .. "/" .. name
		end
	end
	p:close()
	return nil
end

-- List files recursively under a directory, returning relative paths.
local function list_files(dir, prefix)
	prefix = prefix or ""
	local results = {}
	local p = io.popen('ls -1 "' .. dir .. '" 2>/dev/null')
	if not p then return results end
	for name in p:lines() do
		local full = dir .. "/" .. name
		local rel = prefix == "" and name or (prefix .. "/" .. name)
		if is_dir(full) then
			local sub = list_files(full, rel)
			for i = 1, #sub do
				results[#results + 1] = sub[i]
			end
		else
			results[#results + 1] = rel
		end
	end
	p:close()
	return results
end

-- ── Self capability (directory mode) ───────────────────────────────────────

local function make_dir_self_cap(app_dir, card_path)
	local png_mod = require("lib.png")

	-- Load card PNG chunks lazily.
	local chunks_cache
	local function get_chunks()
		if chunks_cache then return chunks_cache end
		if not card_path or not file_exists(card_path) then return nil end
		local bytes, err = read_file(card_path)
		if not bytes then return nil end
		local chunks, perr = png_mod.read(bytes)
		if not chunks then return nil end
		chunks_cache = chunks
		return chunks
	end

	return {
		metadata = function(keyword)
			local chunks = get_chunks()
			if not chunks then return nil end
			return png_mod.get_text(chunks, keyword)
		end,

		entries = function()
			return list_files(app_dir)
		end,

		entry = function(path)
			local full = app_dir .. "/" .. path
			return read_file(full)
		end,
	}
end

-- ── Main ───────────────────────────────────────────────────────────────────

local opts = parse_args(arg)

if not is_dir(opts.app_dir) then
	io.stderr:write("error: " .. opts.app_dir .. " is not a directory\n")
	io.stderr:write("(PNG mode is not yet implemented; pass an app directory)\n")
	os.exit(1)
end

-- Resolve data directory.
local data_dir = expand_home(opts.data_dir or "~/.crescent/data")
os.execute('mkdir -p "' .. data_dir .. '"')

-- Resolve card PNG.
local card_path = opts.card or find_card_png(opts.app_dir)

-- Resolve DB path.
local db_path = opts.db or (data_dir .. "/conversations.db")

-- Determine the server module path from the app directory.
-- Convert "lib/platform/apps/card" -> "lib.platform.apps.card.server"
local mod_path = opts.app_dir:gsub("/$", ""):gsub("/", ".") .. ".server"
local ok, server_mod = pcall(require, mod_path)
if not ok then
	io.stderr:write("error: could not load server module: " .. tostring(server_mod) .. "\n")
	os.exit(1)
end

if not server_mod.create then
	io.stderr:write("error: server module has no create() function\n")
	os.exit(1)
end

-- Build capabilities.
local self_cap = make_dir_self_cap(opts.app_dir, card_path)

local llm_mod = require("lib.platform.caps.llm")
local llm_cap = llm_mod.llm_cap({
	endpoint = opts.endpoint,
	model = opts.model,
	api_key = opts.api_key,
})

local kv_mod = require("lib.platform.caps.kv")
local app_name = opts.app_dir:gsub("/$", ""):match("[^/]+$") or "app"
local kv_path = data_dir .. "/" .. app_name .. "_kv.db"
local kv_cap = kv_mod.kv_cap(kv_path)

local time_mod = require("lib.platform.caps.time")
local time_cap = time_mod.time_cap()

local caps = {
	self = self_cap,
	llm = llm_cap,
	kv = kv_cap,
	time = time_cap,
}

-- Create the app.
local result = server_mod.create(caps, {
	user_name = opts.user,
	db_path = db_path,
})

if not result or not result.handler then
	io.stderr:write("error: server.create() did not return a handler\n")
	os.exit(1)
end

-- Serve via the http_server capability (reuses the SSE-aware server logic).
local http_server_mod = require("lib.platform.caps.http_server")
local server_cap, _ = http_server_mod.http_server_cap({ port = opts.port })

local url = "http://localhost:" .. tostring(opts.port)
io.write(url .. "\n")
io.flush()

-- This blocks until the server is stopped.
server_cap.serve(result.handler)
