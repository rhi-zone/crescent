-- lib/cli/init.lua
-- Declarative CLI argument parser.
--
-- Usage:
--   local cli = require("lib.cli")
--   local args, err = cli.parse(arg, {
--     name = "myapp", desc = "A tool", version = "1.0.0",
--     flags   = { verbose = { short = "v", desc = "Verbose" } },
--     options = { output  = { short = "o", desc = "Out file", default = "-" } },
--     positionals = { { name = "input", desc = "Input file", required = true } },
--     commands = { build = { desc = "Build", flags = { release = {} } } },
--   })

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

-- ── Spec normalization ────────────────────────────────────────────────────

-- Build lookup tables from a spec table. Mutates spec in place, adding
-- _flag_order, _option_order, _short_to_flag, _short_to_option,
-- _command_order, and normalized positionals/commands.
--: ({ [string]: unknown }) -> nil
local function normalize(spec)
	spec.name = spec.name or "app"
	spec.desc = spec.desc or ""
	spec.flags = spec.flags or {}
	spec.options = spec.options or {}
	spec.positionals = spec.positionals or {}
	spec.commands = spec.commands or {}

	-- Sorted iteration order for flags/options (deterministic help output).
	-- Use insertion order if the caller passes an array-like structure,
	-- otherwise sort alphabetically.
	local flag_order = {}
	local option_order = {}
	local command_order = {}

	for name in pairs(spec.flags) do
		flag_order[#flag_order + 1] = name
	end
	table.sort(flag_order)
	spec._flag_order = flag_order

	for name in pairs(spec.options) do
		option_order[#option_order + 1] = name
	end
	table.sort(option_order)
	spec._option_order = option_order

	for name in pairs(spec.commands) do
		command_order[#command_order + 1] = name
	end
	table.sort(command_order)
	spec._command_order = command_order

	-- Short-flag/option reverse maps.
	local s2f, s2o = {}, {}
	for name, f in pairs(spec.flags) do
		f.desc = f.desc or ""
		if f.short then s2f[f.short] = name end
	end
	for name, o in pairs(spec.options) do
		o.desc = o.desc or ""
		if o.short then s2o[o.short] = name end
	end
	spec._short_to_flag = s2f
	spec._short_to_option = s2o

	-- Normalize positionals (ensure each has .name, .desc, .required).
	for i = 1, #spec.positionals do
		local p = spec.positionals[i]
		p.desc = p.desc or ""
		p.required = p.required or false
	end

	-- Recursively normalize subcommands.
	for name, cmd in pairs(spec.commands) do
		cmd.name = name
		normalize(cmd)
	end
end

-- ── Help text generation ──────────────────────────────────────────────────

--: ({ [string]: unknown }, (string | nil)) -> string
local function generate_help(spec, program_name)
	local parts = {}
	local pname = program_name or spec.name

	-- Header
	if spec.desc ~= "" then
		parts[#parts + 1] = pname .. " - " .. spec.desc
	else
		parts[#parts + 1] = pname
	end
	parts[#parts + 1] = ""

	-- Usage line
	local usage = "Usage: " .. pname
	if #spec._flag_order > 0 or #spec._option_order > 0 then
		usage = usage .. " [options]"
	end
	if #spec._command_order > 0 then
		usage = usage .. " [command]"
	end
	for i = 1, #spec.positionals do
		local p = spec.positionals[i]
		if p.required then
			usage = usage .. " <" .. p.name .. ">"
		else
			usage = usage .. " [" .. p.name .. "]"
		end
	end
	parts[#parts + 1] = usage
	parts[#parts + 1] = ""

	-- Positionals
	if #spec.positionals > 0 then
		parts[#parts + 1] = "Arguments:"
		for i = 1, #spec.positionals do
			local p = spec.positionals[i]
			local line = "  <" .. p.name .. ">"
			if p.desc ~= "" then
				local pad = 17 - #line
				if pad < 2 then pad = 2 end
				line = line .. string.rep(" ", pad) .. p.desc
			end
			parts[#parts + 1] = line
		end
		parts[#parts + 1] = ""
	end

	-- Options
	parts[#parts + 1] = "Options:"
	for i = 1, #spec._flag_order do
		local name = spec._flag_order[i]
		local f = spec.flags[name]
		local left
		if f.short then
			left = "  -" .. f.short .. ", --" .. name
		else
			left = "      --" .. name
		end
		local pad = 17 - #left
		if pad < 2 then pad = 2 end
		parts[#parts + 1] = left .. string.rep(" ", pad) .. f.desc
	end
	for i = 1, #spec._option_order do
		local name = spec._option_order[i]
		local o = spec.options[name]
		local left
		if o.short then
			left = "  -" .. o.short .. ", --" .. name
		else
			left = "      --" .. name
		end
		local pad = 17 - #left
		if pad < 2 then pad = 2 end
		local line = left .. string.rep(" ", pad) .. o.desc
		if o.default ~= nil then
			line = line .. " (default: " .. tostring(o.default) .. ")"
		end
		parts[#parts + 1] = line
	end
	parts[#parts + 1] = "  -h, --help     Show this help"
	if spec.version then
		parts[#parts + 1] = "      --version  Show version"
	end
	parts[#parts + 1] = ""

	-- Commands
	if #spec._command_order > 0 then
		parts[#parts + 1] = "Commands:"
		for i = 1, #spec._command_order do
			local cname = spec._command_order[i]
			local c = spec.commands[cname]
			local left = "  " .. cname
			local pad = 17 - #left
			if pad < 2 then pad = 2 end
			parts[#parts + 1] = left .. string.rep(" ", pad) .. (c.desc or "")
		end
		parts[#parts + 1] = ""
	end

	return table.concat(parts, "\n")
end

-- ── Coerce value by type ──────────────────────────────────────────────────

--: (string, (string | nil)) -> (unknown, (string | nil))
local function coerce(value, typ)
	if typ == "number" then
		local n = tonumber(value)
		if not n then
			return nil, "expected number, got '" .. value .. "'"
		end
		return n, nil
	end
	return value, nil
end

-- ── Parse argv against a spec ─────────────────────────────────────────────

--: ({ [string]: unknown }, string[], (string | nil)) -> ((table | nil), (string | nil))
local function parse_spec(spec, argv, program_name)
	local args = {}
	local pos_index = 1
	local dashdash = false
	local i = 1
	local pname = program_name or spec.name

	-- Apply defaults
	for name, o in pairs(spec.options) do
		if o.default ~= nil then
			args[name] = o.default
		end
		if o.array then
			args[name] = args[name] or {}
		end
	end

	while i <= #argv do
		local a = argv[i]

		if dashdash then
			if pos_index <= #spec.positionals then
				args[spec.positionals[pos_index].name] = a
				pos_index = pos_index + 1
			end
			i = i + 1
		elseif a == "--" then
			dashdash = true
			i = i + 1
		elseif a == "--help" or a == "-h" then
			return nil, generate_help(spec, pname)
		elseif a == "--version" and spec.version then
			return nil, spec.version
		elseif a:sub(1, 2) == "--" then
			-- Long flag/option
			local eq_pos = a:find("=", 3, true)
			local name, value
			if eq_pos then
				name = a:sub(3, eq_pos - 1)
				value = a:sub(eq_pos + 1)
			else
				name = a:sub(3)
			end

			if spec.flags[name] then
				args[name] = (args[name] or 0) + 1
				i = i + 1
			elseif spec.options[name] then
				if not value then
					i = i + 1
					if i > #argv then
						return nil, "option --" .. name .. " requires a value"
					end
					value = argv[i]
				end
				local coerced, err = coerce(value, spec.options[name].type)
				if not coerced and err then
					return nil, "option --" .. name .. ": " .. err
				end
				if spec.options[name].array then
					local arr = args[name]
					arr[#arr + 1] = coerced
				else
					args[name] = coerced
				end
				i = i + 1
			else
				return nil, "unknown option: --" .. name
			end
		elseif a:sub(1, 1) == "-" and #a > 1 then
			-- Short flags/options
			local j = 2
			while j <= #a do
				local ch = a:sub(j, j)

				if spec._short_to_flag[ch] then
					local fname = spec._short_to_flag[ch]
					args[fname] = (args[fname] or 0) + 1
					j = j + 1
				elseif spec._short_to_option[ch] then
					local oname = spec._short_to_option[ch]
					local value
					if j < #a then
						value = a:sub(j + 1)
						j = #a + 1
					else
						i = i + 1
						if i > #argv then
							return nil, "option -" .. ch .. " requires a value"
						end
						value = argv[i]
						j = j + 1
					end
					local coerced, err = coerce(value, spec.options[oname].type)
					if not coerced and err then
						return nil, "option -" .. ch .. ": " .. err
					end
					if spec.options[oname].array then
						local arr = args[oname]
						arr[#arr + 1] = coerced
					else
						args[oname] = coerced
					end
				else
					return nil, "unknown option: -" .. ch
				end
			end
			i = i + 1
		else
			-- Subcommand?
			if spec.commands[a] then
				local subcmd = spec.commands[a]
				args._command = a
				local sub_argv = {}
				for k = i + 1, #argv do
					sub_argv[#sub_argv + 1] = argv[k]
				end
				local sub_args, err = parse_spec(subcmd, sub_argv, pname .. " " .. a)
				if not sub_args then
					return nil, err
				end
				for k, v in pairs(sub_args) do
					args[k] = v
				end
				return args, nil
			end

			-- Positional
			if pos_index <= #spec.positionals then
				args[spec.positionals[pos_index].name] = a
				pos_index = pos_index + 1
			end
			i = i + 1
		end
	end

	-- Check required positionals
	for idx = 1, #spec.positionals do
		local p = spec.positionals[idx]
		if p.required and args[p.name] == nil then
			return nil, "missing required argument: <" .. p.name .. ">"
		end
	end

	return args, nil
end

-- ── Shell completions ─────────────────────────────────────────────────────

--: ({ [string]: unknown }) -> string
local function completions_bash(spec)
	local name = spec.name
	local opts = { "--help" }
	if spec.version then opts[#opts + 1] = "--version" end
	for i = 1, #spec._flag_order do
		opts[#opts + 1] = "--" .. spec._flag_order[i]
	end
	for i = 1, #spec._option_order do
		opts[#opts + 1] = "--" .. spec._option_order[i]
	end
	for i = 1, #spec._command_order do
		opts[#opts + 1] = spec._command_order[i]
	end
	local parts = {
		"_" .. name .. "_completions() {",
		"  local cur=${COMP_WORDS[COMP_CWORD]}",
		"  local opts=\"" .. table.concat(opts, " ") .. "\"",
		"  COMPREPLY=( $(compgen -W \"$opts\" -- \"$cur\") )",
		"}",
		"complete -F _" .. name .. "_completions " .. name,
		"",
	}
	return table.concat(parts, "\n")
end

--: ({ [string]: unknown }) -> string
local function completions_zsh(spec)
	local name = spec.name
	local parts = {
		"#compdef " .. name,
		"_" .. name .. "() {",
		"  _arguments \\",
		"    '(-h --help)'{-h,--help}'[Show help]' \\",
	}
	if spec.version then
		parts[#parts + 1] = "    '--version[Show version]' \\"
	end
	for i = 1, #spec._flag_order do
		local fname = spec._flag_order[i]
		local f = spec.flags[fname]
		local short = f.short
			and ("(-" .. f.short .. " --" .. fname .. ")'{-" .. f.short .. ",--" .. fname .. "}'")
			or ("'--" .. fname .. "'")
		parts[#parts + 1] = "    " .. short .. "[" .. f.desc .. "] \\"
	end
	for i = 1, #spec._option_order do
		local oname = spec._option_order[i]
		local o = spec.options[oname]
		local short = o.short
			and ("(-" .. o.short .. " --" .. oname .. ")'{-" .. o.short .. ",--" .. oname .. "}'")
			or ("'--" .. oname .. "'")
		parts[#parts + 1] = "    " .. short .. "[" .. o.desc .. "]:value: \\"
	end
	if #spec._command_order > 0 then
		parts[#parts + 1] = "    '1:command:(" .. table.concat(spec._command_order, " ") .. ")'"
	end
	parts[#parts + 1] = "}"
	parts[#parts + 1] = ""
	return table.concat(parts, "\n")
end

--: ({ [string]: unknown }) -> string
local function completions_fish(spec)
	local name = spec.name
	local parts = {
		"complete -c " .. name .. " -s h -l help -d 'Show help'",
	}
	if spec.version then
		parts[#parts + 1] = "complete -c " .. name .. " -l version -d 'Show version'"
	end
	for i = 1, #spec._flag_order do
		local fname = spec._flag_order[i]
		local f = spec.flags[fname]
		local line = "complete -c " .. name
		if f.short then line = line .. " -s " .. f.short end
		line = line .. " -l " .. fname .. " -d '" .. f.desc .. "'"
		parts[#parts + 1] = line
	end
	for i = 1, #spec._option_order do
		local oname = spec._option_order[i]
		local o = spec.options[oname]
		local line = "complete -c " .. name
		if o.short then line = line .. " -s " .. o.short end
		line = line .. " -l " .. oname .. " -r -d '" .. o.desc .. "'"
		parts[#parts + 1] = line
	end
	for i = 1, #spec._command_order do
		local cname = spec._command_order[i]
		local c = spec.commands[cname]
		parts[#parts + 1] = "complete -c " .. name .. " -a " .. cname .. " -d '" .. (c.desc or "") .. "'"
	end
	parts[#parts + 1] = ""
	return table.concat(parts, "\n")
end

-- ── Public API ────────────────────────────────────────────────────────────

-- Parse argv against a declarative spec.
-- Returns (args_table, nil) on success, (nil, errmsg_or_help) on failure/help/version.
--: (string[], { [string]: unknown }) -> ((table | nil), (string | nil))
function M.parse(argv, spec)
	spec = spec or {}
	normalize(spec)
	return parse_spec(spec, argv)
end

-- Parse + invoke action. If the matched (sub)command has an action field,
-- call it with the parsed args. Returns action result or (nil, errmsg).
--: (string[], { [string]: unknown }) -> (unknown, (string | nil))
function M.run(argv, spec)
	spec = spec or {}
	normalize(spec)
	local args, err = parse_spec(spec, argv)
	if not args then
		return nil, err
	end

	if args._command and spec.commands[args._command] then
		local subcmd = spec.commands[args._command]
		if subcmd.action then
			return subcmd.action(args)
		end
	end

	if spec.action then
		return spec.action(args)
	end

	return args, nil
end

-- Generate shell completions for a spec.
--: ({ [string]: unknown }, string) -> string
function M.completions(spec, shell)
	normalize(spec)
	if shell == "bash" then return completions_bash(spec) end
	if shell == "zsh" then return completions_zsh(spec) end
	if shell == "fish" then return completions_fish(spec) end
	return ""
end

-- Generate help text for a spec.
--: ({ [string]: unknown }) -> string
function M.help(spec)
	normalize(spec)
	return generate_help(spec)
end

return M
