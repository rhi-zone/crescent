if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

-- Parse a flag spec line into a flag entry.
-- Handles forms:
--   -s, --long <arg>   description
--       --long <arg>   description
--   -s                 description
--       --long         description
--: (string) -> { short: string | nil, long: string | nil, arg: string | nil, description: string } | nil
local function parse_flag_line(line)
	-- Flags start with at least 2 spaces of indentation followed by - or --
	local indent, rest = line:match("^(%s%s+)(%-.*)")
	if not indent or not rest then return nil end

	local short, long, arg, desc

	-- Try "-s, --long <arg>  desc" or "-s, --long  desc"
	local s, l, a, d = rest:match("^(%-[^-,%s]),%s+(%-%-[^%s<]+)%s+<([^>]+)>%s+(.+)$")
	if s then short, long, arg, desc = s, l, a, d
	else
		s, l, d = rest:match("^(%-[^-,%s]),%s+(%-%-[^%s]+)%s+(.+)$")
		if s then short, long, desc = s, l, d
		else
			-- Try "    --long <arg>  desc" or "    --long  desc"
			l, a, d = rest:match("^(%-%-[^%s<]+)%s+<([^>]+)>%s+(.+)$")
			if l then long, arg, desc = l, a, d
			else
				l, d = rest:match("^(%-%-[^%s]+)%s+(.+)$")
				if l then long, desc = l, d
				else
					-- Try "-s  desc" (short only, no long)
					s, d = rest:match("^(%-[^-,%s])%s+(.+)$")
					if s then short, desc = s, d end
				end
			end
		end
	end

	if not (short or long) then return nil end

	return {
		short = short,
		long = long,
		arg = arg,
		description = desc and desc:match("^%s*(.-)%s*$") or "",
	}
end

-- Determine the indent level of a line (number of leading spaces).
--: (string) -> number
local function indent_of(line)
	local spaces = line:match("^(%s*)")
	return #spaces
end

-- Parse raw --help text into a schema table.
--:: HelpFlag       = { short: string | nil, long: string | nil, arg: string | nil, description: string }
--:: HelpPositional = { name: string, required: boolean }
--:: HelpSubcommand = { name: string, description: string }
--:: HelpSchema     = { name: string | nil, description: string | nil, usage: string | nil, subcommands: HelpSubcommand[], flags: HelpFlag[], positional: HelpPositional[] }
--: (string) -> HelpSchema
function M.parse(text)
	--: HelpSchema
	local schema = {
		name = nil,
		description = nil,
		usage = nil,
		subcommands = {},
		flags = {},
		positional = {},
	}

	local lines = {}
	for line in (text .. "\n"):gmatch("([^\n]*)\n") do
		lines[#lines + 1] = line
	end

	-- First non-empty line is usually the description (no leading spaces).
	local i = 1
	while i <= #lines and lines[i]:match("^%s*$") do i = i + 1 end
	if i <= #lines then
		local first = lines[i]
		if not first:match("^%s") then
			schema.description = first:match("^%s*(.-)%s*$")
			i = i + 1
		end
	end

	-- Find Usage line to extract command name.
	for _, line in ipairs(lines) do
		local usage = line:match("^Usage:%s+(.+)$")
		if usage then
			schema.usage = usage
			schema.name = usage:match("^(%S+)")
			break
		end
	end

	-- Section-based parse.
	local section = nil -- "commands" | "arguments" | "options" | nil
	local section_indent = nil

	i = 1
	while i <= #lines do
		local line = lines[i]

		-- Detect section headers (no or minimal indent, end with colon).
		local hdr = line:match("^(%u%a+):$") or line:match("^(%u%a+%s%a+):$")
		if hdr then
			local lc = hdr:lower()
			if lc == "commands" or lc:find("commands") then
				section = "commands"
				section_indent = nil
			elseif lc == "arguments" then
				section = "arguments"
				section_indent = nil
			elseif lc == "options" then
				section = "options"
				section_indent = nil
			else
				section = nil
			end
			i = i + 1
		elseif section == "commands" then
			-- Command entries: "  name   description"
			local name, desc = line:match("^%s%s+(%S+)%s%s+(.+)$")
			if name and name ~= "help" then
				schema.subcommands[#schema.subcommands + 1] = {
					name = name,
					description = desc:match("^%s*(.-)%s*$"),
				}
			elseif line:match("^%s*$") or (not line:match("^%s%s")) then
				-- Blank line or de-dented line ends section.
				if line:match("^%s*$") then section = nil end
			end
			i = i + 1
		elseif section == "arguments" then
			-- Positional entries: "  [name]  desc" (optional) or "  <name>  desc" (required)
			local optional_name = line:match("^%s%s+%[([^%]]+)%]")
			local required_name = line:match("^%s%s+<([^>]+)>")
			if optional_name then
				schema.positional[#schema.positional + 1] = {
					name = optional_name,
					required = false,
				}
			elseif required_name then
				schema.positional[#schema.positional + 1] = {
					name = required_name,
					required = true,
				}
			elseif line:match("^%s*$") then
				section = nil
			end
			i = i + 1
		elseif section == "options" then
			local flag = parse_flag_line(line)
			if flag then
				schema.flags[#schema.flags + 1] = flag
				-- Peek ahead: continuation lines have greater indentation than flag line,
				-- and don't look like a new flag. Append to description.
				local flag_indent = indent_of(line)
				while i + 1 <= #lines do
					local next_line = lines[i + 1]
					if next_line:match("^%s*$") then break end
					local ni = indent_of(next_line)
					if ni <= flag_indent then break end
					-- Must not start a new flag entry (not a leading dash after spaces)
					if next_line:match("^%s%s+%-") then break end
					local cont = next_line:match("^%s*(.-)%s*$")
					if cont and cont ~= "" then
						flag.description = flag.description .. " " .. cont
					end
					i = i + 1
				end
			elseif line:match("^%s*$") then
				-- blank line ends options section
				section = nil
			end
			i = i + 1
		else
			i = i + 1
		end
	end

	return schema
end

-- Run cmd --help (merging stderr) via opts.popen and parse the output.
-- opts.popen  fn  io.popen-compatible injected function (required)
--: (string, { popen: (string, string) -> (File | nil, string | nil) }) -> HelpSchema | nil, string | nil
function M.fetch(cmd, opts)
	local exec = require("lib.exec")
	local out, err = exec.run(cmd, { "--help" }, {
		popen = opts.popen,
		stderr = "merge",
	})
	if not out then
		return nil, err
	end
	return M.parse(out or "")
end

return M
