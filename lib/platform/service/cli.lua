-- lib/platform/service/cli.lua
-- CLI projection for the service layer.
--
-- cli.create(caps, methods, descriptors) -> { cli }
--
-- Builds a subcommand dispatcher from a methods table at creation time.
-- Each method becomes a subcommand (method_name with underscores as-is,
-- or optionally with underscores replaced by hyphens).
--
-- Usage:
--   local cli = require("lib.platform.service.cli")
--   local srv  = cli.create(caps, methods, descriptors)
--   srv.cli(args)   -- args is { string, ... } e.g. { "get-card", "name" }
--
-- Flags available for every subcommand:
--   --json    Output result as JSON
--   --help    Show subcommand help
-- Top-level:
--   --help    List all subcommands

if package and not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local json = require("lib.format.json")

local M = {}

-- ── Helpers ────────────────────────────────────────────────────────────────

-- subcommand_name(method_name) -> string
-- Converts method_name to a CLI subcommand: underscores → hyphens.
--: (string) -> string
local function subcommand_name(method_name)
	local s = method_name:gsub("_", "-")
	return s
end

-- param_names_of(fn) -> { string, ... }
-- Introspect a function's parameter names via debug.getinfo.
-- Returns an empty table when not available. Skips first param (caps).
--: (unknown) -> { [integer]: string }
local function param_names_of(fn)
	if type(fn) ~= "function" then return {} end
	local info = debug.getinfo(fn, "u")
	if not info then return {} end
	local nparams = info.nparams or 0
	local params = {}
	for i = 2, nparams do
		local name = debug.getlocal(fn, i)
		if type(name) == "string" then
			params[#params + 1] = name
		end
	end
	return params
end

-- serialize_value(value) -> string
-- Recursively serializes a value to a human-readable string.
-- Tables: [v1, v2, ...] for arrays, {k=v, ...} for maps.
-- Other: tostring.
--: (unknown) -> string
local function serialize_value(value)
	if type(value) ~= "table" then
		return tostring(value)
	end
	local n = #value
	if n > 0 then
		local parts = {}
		for i = 1, n do
			parts[i] = serialize_value(value[i])
		end
		return "[" .. table.concat(parts, ", ") .. "]"
	else
		local parts = {}
		for k, v in pairs(value) do
			parts[#parts + 1] = tostring(k) .. "=" .. serialize_value(v)
		end
		return "{" .. table.concat(parts, ", ") .. "}"
	end
end

-- pretty_print(value, io_out)
-- Prints a value to io_out in a human-readable form.
-- Tables: key=value pairs, one per line (nested tables serialized inline).
-- Arrays: one value per line.
-- Other: tostring.
--: (unknown, unknown) -> nil
local function pretty_print(value, io_out)
	io_out = io_out or io.stdout
	if type(value) == "table" then
		-- Check if it looks like an array.
		local n = #value
		local is_array = n > 0
		if is_array then
			for i = 1, n do
				io_out:write(serialize_value(value[i]) .. "\n")
			end
		else
			for k, v in pairs(value) do
				io_out:write(tostring(k) .. "=" .. serialize_value(v) .. "\n")
			end
		end
	elseif value == nil then
		-- nothing to print
	else
		io_out:write(tostring(value) .. "\n")
	end
end

-- ── Dispatcher builder ─────────────────────────────────────────────────────

--: (unknown, { [string]: unknown }, { [string]: unknown } | nil) -> { cli: unknown, _dispatch: unknown }
function M.create(caps, methods, descriptors)
	descriptors = descriptors or {}

	-- Build a lookup: subcmd_name -> { fn, param_names, fn_name, help }
	local dispatch = {}
	local subcmd_order = {}  -- preserves a stable order for --help output

	for fn_name, fn in pairs(methods) do
		local desc = descriptors[fn_name] or {}
		local subcmd = subcommand_name(fn_name)
		local param_names = param_names_of(fn)
		dispatch[subcmd] = {
			fn          = fn,
			param_names = param_names,
			fn_name     = fn_name,
			help        = desc.help,
		}
		subcmd_order[#subcmd_order + 1] = subcmd
	end
	table.sort(subcmd_order)

	-- print_global_help() — list all subcommands.
	local function print_global_help(io_out)
		io_out = io_out or io.stdout
		io_out:write("subcommands:\n")
		for _, subcmd in ipairs(subcmd_order) do
			local entry = dispatch[subcmd]
			local params = entry.param_names
			local sig = subcmd
			if #params > 0 then
				sig = sig .. " <" .. table.concat(params, "> <") .. ">"
			end
			local help = entry.help and ("  " .. entry.help) or ""
			io_out:write(string.format("  %-40s%s\n", sig, help))
		end
		io_out:write("\nflags:\n")
		io_out:write("  --json     Output result as JSON\n")
		io_out:write("  --help     Show this help or subcommand help\n")
	end

	-- print_subcmd_help(entry, subcmd) — help for one subcommand.
	local function print_subcmd_help(entry, subcmd, io_out)
		io_out = io_out or io.stdout
		local params = entry.param_names
		local sig = subcmd
		if #params > 0 then
			sig = sig .. " <" .. table.concat(params, "> <") .. ">"
		end
		io_out:write("usage: " .. sig .. "\n")
		if entry.help then
			io_out:write(tostring(entry.help) .. "\n")
		end
		if #params > 0 then
			io_out:write("arguments:\n")
			for i, p in ipairs(params) do
				io_out:write(string.format("  %-20s  positional #%d\n", "<" .. p .. ">", i))
			end
		end
	end

	-- cli(args, opts) — main entry point.
	-- args: { string, ... }
	-- opts: optional { stdout, stderr } for testing
	local function cli(args, opts)
		opts = opts or {}
		local io_out = opts.stdout or io.stdout
		local io_err = opts.stderr or io.stderr

		-- Parse flags and positional args.
		local want_json = false
		local want_help = false
		local positional = {}

		for _, a in ipairs(args) do
			if a == "--json" then
				want_json = true
			elseif a == "--help" or a == "-h" then
				want_help = true
			else
				positional[#positional + 1] = a
			end
		end

		local subcmd = positional[1]

		-- Top-level --help or no subcommand.
		if want_help and not subcmd then
			print_global_help(io_out)
			return
		end
		if not subcmd then
			print_global_help(io_out)
			return
		end

		local entry = dispatch[subcmd]
		if not entry then
			io_err:write("error: unknown subcommand '" .. subcmd .. "'\n")
			print_global_help(io_err)
			return
		end

		-- Subcommand --help.
		if want_help then
			print_subcmd_help(entry, subcmd, io_out)
			return
		end

		-- Build call args: caps first, then positional[2..].
		local call_args = { caps }
		for i = 2, #positional do
			call_args[#call_args + 1] = positional[i]
		end

		local entry_fn = entry.fn
		local ok, result, err = pcall(function()
			if type(entry_fn) == "function" then
				return entry_fn(unpack(call_args))
			end
		end)

		if not ok then
			io_err:write("error: " .. tostring(result) .. "\n")
			return
		end

		if result == nil and err ~= nil then
			io_err:write("error: " .. tostring(err) .. "\n")
			return
		end

		if want_json then
			local encoded_s, _ = json.encode(result)
			io_out:write((encoded_s or "") .. "\n")
		else
			pretty_print(result, io_out)
		end
	end

	return { cli = cli, _dispatch = dispatch }
end

-- Exposed for testing.
M._subcommand_name  = subcommand_name
M._param_names_of   = param_names_of
M._pretty_print     = pretty_print
M._serialize_value  = serialize_value

return M
