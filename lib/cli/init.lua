if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

--: module
local M = {}

-- ── Command (shared metatable for app and subcommands) ─────────────────────

local Command = {}
Command.__index = Command

--: (string, string?) -> Command
local function new_command(name, desc)
	return setmetatable({
		_name = name,
		_desc = desc or "",
		_version = nil,
		_flags = {},       -- {name = {short=, desc=}}
		_options = {},     -- {name = {short=, desc=, default=, type=, array=}}
		_positionals = {}, -- {{name=, desc=, required=}}
		_commands = {},    -- {name = Command}
		_command_order = {},
		_action_fn = nil,
		_flag_order = {},
		_option_order = {},
		_short_to_flag = {},
		_short_to_option = {},
	}, Command)
end

--: (string) -> Command
function Command:version(v)
	self._version = v
	return self
end

--: (string, {short: string?, desc: string?}) -> Command
function Command:flag(name, opts)
	opts = opts or {}
	self._flags[name] = { short = opts.short, desc = opts.desc or "" }
	self._flag_order[#self._flag_order + 1] = name
	if opts.short then
		self._short_to_flag[opts.short] = name
	end
	return self
end

--: (string, {short: string?, desc: string?, default: unknown?, type: string?, array: boolean?}) -> Command
function Command:option(name, opts)
	opts = opts or {}
	self._options[name] = {
		short = opts.short,
		desc = opts.desc or "",
		default = opts.default,
		type = opts.type,
		array = opts.array or false,
	}
	self._option_order[#self._option_order + 1] = name
	if opts.short then
		self._short_to_option[opts.short] = name
	end
	return self
end

--: (string, {desc: string?, required: boolean?}) -> Command
function Command:positional(name, opts)
	opts = opts or {}
	self._positionals[#self._positionals + 1] = {
		name = name,
		desc = opts.desc or "",
		required = opts.required or false,
	}
	return self
end

--: (string, string?) -> Command
function Command:command(name, desc)
	local cmd = new_command(name, desc)
	self._commands[name] = cmd
	self._command_order[#self._command_order + 1] = name
	return cmd
end

--: ((table) -> unknown) -> Command
function Command:action(fn)
	self._action_fn = fn
	return self
end

-- ── Help text generation ───────────────────────────────────────────────────

--: (Command, string?) -> string
local function generate_help(cmd, program_name)
	local parts = {}
	local pname = program_name or cmd._name

	-- Header
	if cmd._desc ~= "" then
		parts[#parts + 1] = pname .. " - " .. cmd._desc
	else
		parts[#parts + 1] = pname
	end
	parts[#parts + 1] = ""

	-- Usage line
	local usage = "Usage: " .. pname
	if #cmd._flag_order > 0 or #cmd._option_order > 0 then
		usage = usage .. " [options]"
	end
	if #cmd._command_order > 0 then
		usage = usage .. " [command]"
	end
	for i = 1, #cmd._positionals do
		local p = cmd._positionals[i]
		if p.required then
			usage = usage .. " <" .. p.name .. ">"
		else
			usage = usage .. " [" .. p.name .. "]"
		end
	end
	parts[#parts + 1] = usage
	parts[#parts + 1] = ""

	-- Positionals
	if #cmd._positionals > 0 then
		parts[#parts + 1] = "Arguments:"
		for i = 1, #cmd._positionals do
			local p = cmd._positionals[i]
			local line = "  <" .. p.name .. ">"
			if p.desc ~= "" then
				-- pad to column 17
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
	for i = 1, #cmd._flag_order do
		local name = cmd._flag_order[i]
		local f = cmd._flags[name]
		local left
		if f.short then
			left = "  -" .. f.short .. ", --" .. name
		else
			left = "      --" .. name
		end
		local pad = 17 - #left
		if pad < 2 then pad = 2 end
		local line = left .. string.rep(" ", pad) .. f.desc
		parts[#parts + 1] = line
	end
	for i = 1, #cmd._option_order do
		local name = cmd._option_order[i]
		local o = cmd._options[name]
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
	-- Built-in help
	parts[#parts + 1] = "  -h, --help     Show this help"
	if cmd._version then
		parts[#parts + 1] = "      --version  Show version"
	end
	parts[#parts + 1] = ""

	-- Commands
	if #cmd._command_order > 0 then
		parts[#parts + 1] = "Commands:"
		for i = 1, #cmd._command_order do
			local cname = cmd._command_order[i]
			local c = cmd._commands[cname]
			local left = "  " .. cname
			local pad = 17 - #left
			if pad < 2 then pad = 2 end
			parts[#parts + 1] = left .. string.rep(" ", pad) .. c._desc
		end
		parts[#parts + 1] = ""
	end

	return table.concat(parts, "\n")
end

-- ── Coerce value by type ───────────────────────────────────────────────────

--: (string, string?) -> (unknown, string?)
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

-- ── Parse argv against a command ───────────────────────────────────────────

--: (Command, string[], string?) -> (table?, string?)
local function parse_command(cmd, argv, program_name)
	local args = {}
	local pos_index = 1
	local dashdash = false
	local i = 1
	local pname = program_name or cmd._name

	-- Apply defaults
	for name, o in pairs(cmd._options) do
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
			-- Everything after -- is positional
			if pos_index <= #cmd._positionals then
				args[cmd._positionals[pos_index].name] = a
				pos_index = pos_index + 1
			end
			i = i + 1
		elseif a == "--" then
			dashdash = true
			i = i + 1
		elseif a == "--help" or a == "-h" then
			return nil, generate_help(cmd, pname)
		elseif a == "--version" and cmd._version then
			return nil, cmd._version
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

			if cmd._flags[name] then
				args[name] = (args[name] or 0) + 1
				i = i + 1
			elseif cmd._options[name] then
				if not value then
					i = i + 1
					if i > #argv then
						return nil, "option --" .. name .. " requires a value"
					end
					value = argv[i]
				end
				local coerced, err = coerce(value, cmd._options[name].type)
				if not coerced and err then
					return nil, "option --" .. name .. ": " .. err
				end
				if cmd._options[name].array then
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

				if cmd._short_to_flag[ch] then
					local fname = cmd._short_to_flag[ch]
					args[fname] = (args[fname] or 0) + 1
					j = j + 1
				elseif cmd._short_to_option[ch] then
					local oname = cmd._short_to_option[ch]
					local value
					if j < #a then
						-- Rest of the arg is the value: -ofile
						value = a:sub(j + 1)
						j = #a + 1
					else
						-- Next arg is the value: -o file
						i = i + 1
						if i > #argv then
							return nil, "option -" .. ch .. " requires a value"
						end
						value = argv[i]
						j = j + 1
					end
					local coerced, err = coerce(value, cmd._options[oname].type)
					if not coerced and err then
						return nil, "option -" .. ch .. ": " .. err
					end
					if cmd._options[oname].array then
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
			-- Check for subcommand
			if #cmd._command_order > 0 and cmd._commands[a] then
				local subcmd = cmd._commands[a]
				args._command = a
				-- Parse remaining args with the subcommand
				local sub_argv = {}
				for k = i + 1, #argv do
					sub_argv[#sub_argv + 1] = argv[k]
				end
				local sub_args, err = parse_command(subcmd, sub_argv, pname .. " " .. a)
				if not sub_args then
					return nil, err
				end
				-- Merge subcommand args into parent
				for k, v in pairs(sub_args) do
					args[k] = v
				end
				return args, nil
			end

			-- Positional
			if pos_index <= #cmd._positionals then
				args[cmd._positionals[pos_index].name] = a
				pos_index = pos_index + 1
			end
			i = i + 1
		end
	end

	-- Check required positionals
	for idx = 1, #cmd._positionals do
		local p = cmd._positionals[idx]
		if p.required and args[p.name] == nil then
			return nil, "missing required argument: <" .. p.name .. ">"
		end
	end

	return args, nil
end

-- ── Public parse / run ─────────────────────────────────────────────────────

--: (string[]) -> (table?, string?)
function Command:parse(argv)
	return parse_command(self, argv, self._name)
end

--: (string[]) -> (unknown, string?)
function Command:run(argv)
	local args, err = self:parse(argv)
	if not args then
		return nil, err
	end

	-- If a subcommand matched and has an action, run it
	if args._command and self._commands[args._command] then
		local subcmd = self._commands[args._command]
		if subcmd._action_fn then
			return subcmd._action_fn(args)
		end
	end

	-- Otherwise run the app-level action
	if self._action_fn then
		return self._action_fn(args)
	end

	return args, nil
end

-- ── Shell completions ──────────────────────────────────────────────────────

--: (string) -> string
function Command:completions(shell)
	if shell == "bash" then
		return self:_completions_bash()
	elseif shell == "zsh" then
		return self:_completions_zsh()
	elseif shell == "fish" then
		return self:_completions_fish()
	end
	return ""
end

--: () -> string
function Command:_completions_bash()
	local parts = {}
	local name = self._name
	parts[#parts + 1] = "_" .. name .. "_completions() {"
	parts[#parts + 1] = "  local cur=${COMP_WORDS[COMP_CWORD]}"
	parts[#parts + 1] = "  local opts=\"--help"
	local opts = { "--help" }
	if self._version then opts[#opts + 1] = "--version" end
	for i = 1, #self._flag_order do
		opts[#opts + 1] = "--" .. self._flag_order[i]
	end
	for i = 1, #self._option_order do
		opts[#opts + 1] = "--" .. self._option_order[i]
	end
	for i = 1, #self._command_order do
		opts[#opts + 1] = self._command_order[i]
	end
	parts[3] = "  local opts=\"" .. table.concat(opts, " ") .. "\""
	parts[#parts + 1] = "  COMPREPLY=( $(compgen -W \"$opts\" -- \"$cur\") )"
	parts[#parts + 1] = "}"
	parts[#parts + 1] = "complete -F _" .. name .. "_completions " .. name
	parts[#parts + 1] = ""
	return table.concat(parts, "\n")
end

--: () -> string
function Command:_completions_zsh()
	local parts = {}
	local name = self._name
	parts[#parts + 1] = "#compdef " .. name
	parts[#parts + 1] = "_" .. name .. "() {"
	parts[#parts + 1] = "  _arguments \\"
	parts[#parts + 1] = "    '(-h --help)'{-h,--help}'[Show help]' \\"
	if self._version then
		parts[#parts + 1] = "    '--version[Show version]' \\"
	end
	for i = 1, #self._flag_order do
		local fname = self._flag_order[i]
		local f = self._flags[fname]
		local short = f.short and ("(-" .. f.short .. " --" .. fname .. ")'{-" .. f.short .. ",--" .. fname .. "}'") or ("'--" .. fname .. "'")
		parts[#parts + 1] = "    " .. short .. "[" .. f.desc .. "] \\"
	end
	for i = 1, #self._option_order do
		local oname = self._option_order[i]
		local o = self._options[oname]
		local short = o.short and ("(-" .. o.short .. " --" .. oname .. ")'{-" .. o.short .. ",--" .. oname .. "}'") or ("'--" .. oname .. "'")
		parts[#parts + 1] = "    " .. short .. "[" .. o.desc .. "]:value: \\"
	end
	if #self._command_order > 0 then
		parts[#parts + 1] = "    '1:command:(" .. table.concat(self._command_order, " ") .. ")'"
	end
	parts[#parts + 1] = "}"
	parts[#parts + 1] = ""
	return table.concat(parts, "\n")
end

--: () -> string
function Command:_completions_fish()
	local parts = {}
	local name = self._name
	parts[#parts + 1] = "complete -c " .. name .. " -s h -l help -d 'Show help'"
	if self._version then
		parts[#parts + 1] = "complete -c " .. name .. " -l version -d 'Show version'"
	end
	for i = 1, #self._flag_order do
		local fname = self._flag_order[i]
		local f = self._flags[fname]
		local line = "complete -c " .. name
		if f.short then line = line .. " -s " .. f.short end
		line = line .. " -l " .. fname .. " -d '" .. f.desc .. "'"
		parts[#parts + 1] = line
	end
	for i = 1, #self._option_order do
		local oname = self._option_order[i]
		local o = self._options[oname]
		local line = "complete -c " .. name
		if o.short then line = line .. " -s " .. o.short end
		line = line .. " -l " .. oname .. " -r -d '" .. o.desc .. "'"
		parts[#parts + 1] = line
	end
	for i = 1, #self._command_order do
		local cname = self._command_order[i]
		local c = self._commands[cname]
		parts[#parts + 1] = "complete -c " .. name .. " -a " .. cname .. " -d '" .. c._desc .. "'"
	end
	parts[#parts + 1] = ""
	return table.concat(parts, "\n")
end

-- ── Constructor ────────────────────────────────────────────────────────────

--: (string, string?) -> Command
function M.app(name, desc)
	return new_command(name, desc)
end

return M
