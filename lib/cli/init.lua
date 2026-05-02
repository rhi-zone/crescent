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

--:: FlagSpec = { short: string|nil, desc: string, ... }
--:: OptionSpec = { short: string|nil, desc: string, default: unknown, type: string|nil, array: boolean|nil, ... }
--:: PosSpec = { name: string, desc: string, required: boolean|false, ... }
--:: CmdSpec = { name: string, desc: string|nil, flags: { [string]: FlagSpec }|nil, options: { [string]: OptionSpec }|nil, positionals: { [integer]: PosSpec }|nil, commands: { [string]: CmdSpec }|nil, action: ((any) -> any)|nil, _flag_order: { [integer]: string }, _option_order: { [integer]: string }, _command_order: { [integer]: string }, _short_to_flag: { [string]: string }, _short_to_option: { [string]: string }, version: string|nil, ... }

-- ── Spec normalization ────────────────────────────────────────────────────

-- Build lookup tables from a spec table. Mutates spec in place, adding
-- _flag_order, _option_order, _short_to_flag, _short_to_option,
-- _command_order, and normalized positionals/commands.
local normalize --: ((CmdSpec) -> nil) | nil
--: (CmdSpec) -> nil
normalize = function(spec)
	local spec_ = spec --[[:! CmdSpec]]
	spec_.name = spec_.name or "app"
	spec_.desc = spec_.desc or ""
	local flags_ = spec_.flags or {} --[[:! { [string]: FlagSpec }]]
	local options_ = spec_.options or {} --[[:! { [string]: OptionSpec }]]
	local positionals_ = spec_.positionals or {} --[[:! { [integer]: PosSpec }]]
	local commands_ = spec_.commands or {} --[[:! { [string]: CmdSpec }]]
	spec_.flags = flags_
	spec_.options = options_
	spec_.positionals = positionals_
	spec_.commands = commands_

	-- Sorted iteration order for flags/options (deterministic help output).
	local flag_order = {} --: { [integer]: string }
	local option_order = {} --: { [integer]: string }
	local command_order = {} --: { [integer]: string }

	for name in pairs(flags_) do
		flag_order[#flag_order + 1] = name
	end
	table.sort(flag_order)
	spec_._flag_order = flag_order

	for name in pairs(options_) do
		option_order[#option_order + 1] = name
	end
	table.sort(option_order)
	spec_._option_order = option_order

	for name in pairs(commands_) do
		command_order[#command_order + 1] = name
	end
	table.sort(command_order)
	spec_._command_order = command_order

	-- Short-flag/option reverse maps.
	local s2f = {} --: { [string]: string }
	local s2o = {} --: { [string]: string }
	for name, f in pairs(flags_) do
		local f_ = f --[[:! FlagSpec]]
		f_.desc = f_.desc or ""
		if f_.short then s2f[f_.short] = name end
	end
	for name, o in pairs(options_) do
		local o_ = o --[[:! OptionSpec]]
		o_.desc = o_.desc or ""
		if o_.short then s2o[o_.short] = name end
	end
	spec_._short_to_flag = s2f
	spec_._short_to_option = s2o

	-- Normalize positionals (ensure each has .name, .desc, .required).
	for i = 1, #positionals_ do
		local p = positionals_[i] --[[:! PosSpec]]
		p.desc = p.desc or ""
		p.required = p.required or false
	end

	-- Recursively normalize subcommands.
	for name, cmd in pairs(commands_) do
		local cmd_ = cmd --[[:! CmdSpec]]
		cmd_.name = name
		local norm_ = normalize --[[:! (CmdSpec) -> nil]]
		norm_(cmd_)
	end
end

-- ── Help text generation ──────────────────────────────────────────────────

--: (CmdSpec, string|nil) -> string
local function generate_help(spec, program_name)
	local spec_ = spec --[[:! CmdSpec]]
	local flags_ = spec_.flags or {} --[[:! { [string]: FlagSpec }]]
	local options_ = spec_.options or {} --[[:! { [string]: OptionSpec }]]
	local positionals_ = spec_.positionals or {} --[[:! { [integer]: PosSpec }]]
	local commands_ = spec_.commands or {} --[[:! { [string]: CmdSpec }]]
	local parts = {} --: { [integer]: string }
	local pname = program_name or spec_.name

	-- Header
	if spec_.desc ~= "" then
		parts[#parts + 1] = pname .. " - " .. (spec_.desc or "")
	else
		parts[#parts + 1] = pname
	end
	parts[#parts + 1] = ""

	-- Usage line
	local usage = "Usage: " .. pname
	if #spec_._flag_order > 0 or #spec_._option_order > 0 then
		usage = usage .. " [options]"
	end
	if #spec_._command_order > 0 then
		usage = usage .. " [command]"
	end
	for i = 1, #positionals_ do
		local p = positionals_[i]
		if p.required then
			usage = usage .. " <" .. p.name .. ">"
		else
			usage = usage .. " [" .. p.name .. "]"
		end
	end
	parts[#parts + 1] = usage
	parts[#parts + 1] = ""

	-- Positionals
	if #positionals_ > 0 then
		parts[#parts + 1] = "Arguments:"
		for i = 1, #positionals_ do
			local p = positionals_[i]
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
	for i = 1, #spec_._flag_order do
		local name = spec_._flag_order[i]
		local f = flags_[name] --[[:! FlagSpec]]
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
	for i = 1, #spec_._option_order do
		local name = spec_._option_order[i]
		local o = options_[name] --[[:! OptionSpec]]
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
	if spec_.version then
		parts[#parts + 1] = "      --version  Show version"
	end
	parts[#parts + 1] = ""

	-- Commands
	if #spec_._command_order > 0 then
		parts[#parts + 1] = "Commands:"
		for i = 1, #spec_._command_order do
			local cname = spec_._command_order[i]
			local c = commands_[cname]
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

--: (CmdSpec, { [integer]: string }, string|nil) -> ({ [string]: unknown }|nil, string|nil)
local function parse_spec(spec, argv, program_name)
	local spec_ = spec --[[:! CmdSpec]]
	local flags_ = spec_.flags or {} --[[:! { [string]: FlagSpec }]]
	local options_ = spec_.options or {} --[[:! { [string]: OptionSpec }]]
	local positionals_ = spec_.positionals or {} --[[:! { [integer]: PosSpec }]]
	local commands_ = spec_.commands or {} --[[:! { [string]: CmdSpec }]]
	local args = {} --: { [string]: unknown }
	local pos_index = 1
	local dashdash = false
	local i = 1
	local pname = program_name or spec_.name

	-- Apply defaults
	for name, o in pairs(options_) do
		local o_ = o --[[:! OptionSpec]]
		if o_.default ~= nil then
			args[name] = o_.default
		end
		if o_.array then
			args[name] = args[name] or {}
		end
	end

	while i <= #argv do
		local a = argv[i]

		if dashdash then
			if pos_index <= #positionals_ then
				args[positionals_[pos_index].name] = a
				pos_index = pos_index + 1
			end
			i = i + 1
		elseif a == "--" then
			dashdash = true
			i = i + 1
		elseif a == "--help" or a == "-h" then
			return nil, generate_help(spec_, pname)
		elseif a == "--version" and spec_.version then
			return nil, spec_.version
		elseif a:sub(1, 2) == "--" then
			-- Long flag/option
			local eq_pos = a:find("=", 3, true)
			local name, value --: string|nil
			if eq_pos then
				local eq_ = eq_pos --[[:! integer]]
				name = a:sub(3, eq_ - 1)
				value = a:sub(eq_ + 1)
			else
				name = a:sub(3)
			end
			local name_ = name --[[:! string]]

			if flags_[name_] then
				local cur = args[name_]
				args[name_] = (type(cur) == "number" and (cur --[[:! number]]) or 0) + 1
				i = i + 1
			elseif options_[name_] then
				if not value then
					i = i + 1
					if i > #argv then
						return nil, "option --" .. name_ .. " requires a value"
					end
					value = argv[i]
				end
				local value_ = value --[[:! string]]
				local coerced, err = coerce(value_, options_[name_].type)
				if not coerced and err then
					return nil, "option --" .. name_ .. ": " .. err
				end
				if options_[name_].array then
					local arr = args[name_]
					if type(arr) ~= "table" then arr = {} end
					local arr_ = arr --[[:! { [integer]: unknown }]]
					arr_[#arr_ + 1] = coerced
					args[name_] = arr_
				else
					args[name_] = coerced
				end
				i = i + 1
			else
				return nil, "unknown option: --" .. name_
			end
		elseif a:sub(1, 1) == "-" and #a > 1 then
			-- Short flags/options
			local j = 2
			while j <= #a do
				local ch = a:sub(j, j)

				if spec_._short_to_flag[ch] then
					local fname = spec_._short_to_flag[ch]
					local cur = args[fname]
					args[fname] = (type(cur) == "number" and (cur --[[:! number]]) or 0) + 1
					j = j + 1
				elseif spec_._short_to_option[ch] then
					local oname = spec_._short_to_option[ch]
					local value --: string|nil
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
					local value_ = value --[[:! string]]
					local coerced, err = coerce(value_, options_[oname].type)
					if not coerced and err then
						return nil, "option -" .. ch .. ": " .. err
					end
					if options_[oname].array then
						local arr = args[oname]
						if type(arr) ~= "table" then arr = {} end
						local arr_ = arr --[[:! { [integer]: unknown }]]
						arr_[#arr_ + 1] = coerced
						args[oname] = arr_
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
			if commands_[a] then
				local subcmd = commands_[a]
				local cmd_key = "_command" --: string
			args[cmd_key] = a
				local sub_argv = {} --: { [integer]: string }
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
			if pos_index <= #positionals_ then
				args[positionals_[pos_index].name] = a
				pos_index = pos_index + 1
			end
			i = i + 1
		end
	end

	-- Check required positionals
	for idx = 1, #positionals_ do
		local p = positionals_[idx]
		if p.required and args[p.name] == nil then
			return nil, "missing required argument: <" .. p.name .. ">"
		end
	end

	return args, nil
end

-- ── Shell completions ─────────────────────────────────────────────────────

--: (CmdSpec) -> string
local function completions_bash(spec)
	local spec_ = spec --[[:! CmdSpec]]
	local name = spec_.name
	local opts = { "--help" } --: { [integer]: string }
	if spec_.version then opts[#opts + 1] = "--version" end
	for i = 1, #spec_._flag_order do
		opts[#opts + 1] = "--" .. spec_._flag_order[i]
	end
	for i = 1, #spec_._option_order do
		opts[#opts + 1] = "--" .. spec_._option_order[i]
	end
	for i = 1, #spec_._command_order do
		opts[#opts + 1] = spec_._command_order[i]
	end
	local parts = {
		"_" .. name .. "_completions() {",
		"  local cur=${COMP_WORDS[COMP_CWORD]}",
		"  local opts=\"" .. table.concat(opts, " ") .. "\"",
		"  COMPREPLY=( $(compgen -W \"$opts\" -- \"$cur\") )",
		"}",
		"complete -F _" .. name .. "_completions " .. name,
		"",
	} --: { [integer]: string }
	return table.concat(parts, "\n")
end

--: (CmdSpec) -> string
local function completions_zsh(spec)
	local spec_ = spec --[[:! CmdSpec]]
	local flags_ = spec_.flags or {} --[[:! { [string]: FlagSpec }]]
	local options_ = spec_.options or {} --[[:! { [string]: OptionSpec }]]
	local commands_ = spec_.commands or {} --[[:! { [string]: CmdSpec }]]
	local name = spec_.name
	local parts = {
		"#compdef " .. name,
		"_" .. name .. "() {",
		"  _arguments \\",
		"    '(-h --help)'{-h,--help}'[Show help]' \\",
	} --: { [integer]: string }
	if spec_.version then
		parts[#parts + 1] = "    '--version[Show version]' \\"
	end
	for i = 1, #spec_._flag_order do
		local fname = spec_._flag_order[i]
		local f = flags_[fname] --[[:! FlagSpec]]
		local short = f.short
			and ("(-" .. f.short .. " --" .. fname .. ")'{-" .. f.short .. ",--" .. fname .. "}'")
			or ("'--" .. fname .. "'")
		parts[#parts + 1] = "    " .. short .. "[" .. f.desc .. "] \\"
	end
	for i = 1, #spec_._option_order do
		local oname = spec_._option_order[i]
		local o = options_[oname] --[[:! OptionSpec]]
		local short = o.short
			and ("(-" .. o.short .. " --" .. oname .. ")'{-" .. o.short .. ",--" .. oname .. "}'")
			or ("'--" .. oname .. "'")
		parts[#parts + 1] = "    " .. short .. "[" .. o.desc .. "]:value: \\"
	end
	if #spec_._command_order > 0 then
		parts[#parts + 1] = "    '1:command:(" .. table.concat(spec_._command_order, " ") .. ")'"
	end
	parts[#parts + 1] = "}"
	parts[#parts + 1] = ""
	return table.concat(parts, "\n")
end

--: (CmdSpec) -> string
local function completions_fish(spec)
	local spec_ = spec --[[:! CmdSpec]]
	local flags_ = spec_.flags or {} --[[:! { [string]: FlagSpec }]]
	local options_ = spec_.options or {} --[[:! { [string]: OptionSpec }]]
	local commands_ = spec_.commands or {} --[[:! { [string]: CmdSpec }]]
	local name = spec_.name
	local parts = {
		"complete -c " .. name .. " -s h -l help -d 'Show help'",
	} --: { [integer]: string }
	if spec_.version then
		parts[#parts + 1] = "complete -c " .. name .. " -l version -d 'Show version'"
	end
	for i = 1, #spec_._flag_order do
		local fname = spec_._flag_order[i]
		local f = flags_[fname] --[[:! FlagSpec]]
		local line = "complete -c " .. name
		if f.short then line = line .. " -s " .. f.short end
		line = line .. " -l " .. fname .. " -d '" .. f.desc .. "'"
		parts[#parts + 1] = line
	end
	for i = 1, #spec_._option_order do
		local oname = spec_._option_order[i]
		local o = options_[oname] --[[:! OptionSpec]]
		local line = "complete -c " .. name
		if o.short then line = line .. " -s " .. o.short end
		line = line .. " -l " .. oname .. " -r -d '" .. o.desc .. "'"
		parts[#parts + 1] = line
	end
	for i = 1, #spec_._command_order do
		local cname = spec_._command_order[i]
		local c = commands_[cname] --[[:! CmdSpec]]
		parts[#parts + 1] = "complete -c " .. name .. " -a " .. cname .. " -d '" .. (c.desc or "") .. "'"
	end
	parts[#parts + 1] = ""
	return table.concat(parts, "\n")
end

-- ── Public API ────────────────────────────────────────────────────────────

-- Parse argv against a declarative spec.
-- Returns (args_table, nil) on success, (nil, errmsg_or_help) on failure/help/version.
--: ({ [integer]: string }, CmdSpec) -> ({ [string]: unknown }|nil, string|nil)
function M.parse(argv, spec)
	local spec_ = (spec or {}) --[[:! CmdSpec]]
	normalize(spec_)
	return parse_spec(spec_, argv)
end

-- Parse + invoke action. If the matched (sub)command has an action field,
-- call it with the parsed args. Returns action result or (nil, errmsg).
--: ({ [integer]: string }, CmdSpec) -> (unknown, string|nil)
function M.run(argv, spec)
	local spec_ = (spec or {}) --[[:! CmdSpec]]
	normalize(spec_)
	local args, err = parse_spec(spec_, argv)
	if not args then
		return nil, err
	end

	local cmd = args["_command"]
	if cmd ~= nil then
		local commands_ = spec_.commands or {} --[[:! { [string]: CmdSpec }]]
		local cmd_ = cmd --[[:! string]]
		local subcmd = commands_[cmd_]
		if subcmd and subcmd.action then
			return subcmd.action(args)
		end
	end

	if spec_.action then
		return spec_.action(args)
	end

	return args, nil
end

-- Generate shell completions for a spec.
--: (CmdSpec, string) -> string
function M.completions(spec, shell)
	local spec_ = spec --[[:! CmdSpec]]
	normalize(spec_)
	if shell == "bash" then return completions_bash(spec_) end
	if shell == "zsh" then return completions_zsh(spec_) end
	if shell == "fish" then return completions_fish(spec_) end
	return ""
end

-- Generate help text for a spec.
--: (CmdSpec) -> string
function M.help(spec)
	local spec_ = spec --[[:! CmdSpec]]
	normalize(spec_)
	return generate_help(spec_)
end

return M
