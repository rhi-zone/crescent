if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

-- Strip leading nix noise lines (download progress, warnings, etc.)
-- before the first recognizable help-like line.
--: (string) -> string
local function strip_nix_noise(text)
	local lines = {}
	for line in (text .. "\n"):gmatch("([^\n]*)\n") do
		lines[#lines + 1] = line
	end

	-- Patterns that indicate nix noise lines to skip (checked case-insensitively).
	local noise_pats = {
		"^%s*$",              -- blank
		"^warning:",
		"^downloading",
		"^copying path",
		"^this path will be",
		"^  /nix/store/",
		"^fetching",
		"^unpacking",
		"^building",
	}

	local start = 1
	for idx, line in ipairs(lines) do
		local low = line:lower()
		local is_noise = false
		for _, pat in ipairs(noise_pats) do
			if low:match(pat) then
				is_noise = true
				break
			end
		end
		if not is_noise then
			start = idx
			break
		end
	end

	local result = {}
	for idx = start, #lines do
		result[#result + 1] = lines[idx]
	end
	return table.concat(result, "\n")
end

-- Map of normalized (lowercase, no trailing colon) header strings to section names.
local SECTION_MAP = {
	-- options
	["options"]               = "options",
	["option"]                = "options",
	["flags"]                 = "options",
	["command options"]       = "options",
	["available options"]     = "options",
	["available options are"] = "options",
	-- subcommands
	["commands"]              = "commands",
	["subcommands"]           = "commands",
	-- arguments
	["arguments"]             = "arguments",
	["args"]                  = "arguments",
	["positional arguments"]  = "arguments",
	["positional args"]       = "arguments",
}

-- Compound header classification: headers ending in OPTIONS/FLAGS/SUBCOMMANDS/ARGUMENTS etc.
-- Handles e.g. "INPUT OPTIONS:", "SEARCH OPTIONS:", "OUTPUT MODES:".
-- Only matches short ALL-CAPS or all-lowercase headers (no mixed-case prose sentences).
-- hdr_lower is already lowercased and trailing-colon-stripped.
--: (string) -> string | nil
local function classify_compound_header(hdr_lower)
	-- Restrict to headers that are short (≤40 chars) and consist only of
	-- word characters and spaces — not sentences with punctuation, prepositions, etc.
	if #hdr_lower > 40 then return nil end
	if hdr_lower:match("[^%a%s]") then return nil end  -- reject if any non-alpha non-space char
	if hdr_lower:match("options?$") or hdr_lower:match("flags?$") then
		return "options"
	elseif hdr_lower:match("subcommands?$") or hdr_lower:match("commands?$") then
		return "commands"
	elseif hdr_lower:match("arguments?$") or hdr_lower:match("args?$") then
		return "arguments"
	end
	return nil
end

-- Parse a flag spec line into a flag entry.
-- Handles forms:
--   -s, --long <arg>   description
--       --long <arg>   description
--   -s                 description
--       --long         description
--   -s arg             description   (short-only with metavar)
-- Requires at least 1 leading whitespace character (tabs or spaces).
--: (string) -> { short: string | nil, long: string | nil, arg: string | nil, description: string } | nil
local function parse_flag_line(line)
	-- Must have at least 1 whitespace of indentation followed by - or --
	local indent, rest = line:match("^(%s+)(%-.*)")
	if not indent or not rest then return nil end

	local short, long, arg, desc

	-- Try "-s, --long <arg>  desc" or "-s, --long  desc" or "-s, --long" (no desc)
	local s, l, a, d = rest:match("^(%-[^-,%s]),%s+(%-%-[^%s<]+)%s+<([^>]+)>%s+(.+)$")
	if s then short, long, arg, desc = s, l, a, d
	else
		s, l, d = rest:match("^(%-[^-,%s]),%s+(%-%-[^%s]+)%s+(.+)$")
		if s then short, long, desc = s, l, d
		else
			-- "-s, --long" alone (description may be on continuation lines)
			s, l = rest:match("^(%-[^-,%s]),%s+(%-%-[^%s,]+)$")
			if s then short, long = s, l end
		end
		if not (short or long) then
			-- Try "    --long <arg>  desc" or "    --long  desc" or "    --long" alone
			l, a, d = rest:match("^(%-%-[^%s<=]+)%s+<([^>]+)>%s+(.+)$")
			if l then long, arg, desc = l, a, d
			else
				l, d = rest:match("^(%-%-[^%s=]+)%s+(.+)$")
				if l then long, desc = l, d
				else
					l = rest:match("^(%-%-[^%s=]+)$")
					if l then long = l
					else
						-- Try "-s <arg>  desc" or "-s arg  desc" (short-only with metavar)
						-- Metavar is followed by 2+ spaces before description.
						-- e.g. "-e chunk  Execute string 'chunk'."
						s, a, d = rest:match("^(%-[^-,%s])%s+(%S+)%s%s+(.+)$")
						if s then short, arg, desc = s, a, d
						else
							-- Try "-s  desc" (short only, no long, no arg)
							s, d = rest:match("^(%-[^-,%s])%s+(.+)$")
							if s then short, desc = s, d end
						end
					end
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

-- Determine the indent level of a line (number of leading whitespace chars).
--: (string) -> number
local function indent_of(line)
	local spaces = line:match("^(%s*)")
	return #spaces
end

-- Check whether a line looks like a command entry: indented, followed by name + description.
-- Returns name, description or nil.
--: (string) -> string | nil, string | nil
local function try_command_line(line)
	local name, desc = line:match("^%s%s+(%S+)%s%s+(.+)$")
	return name, desc
end

-- Parse raw --help text into a schema table.
--:: HelpFlag       = { short: string | nil, long: string | nil, arg: string | nil, description: string }
--:: HelpPositional = { name: string, required: boolean }
--:: HelpSubcommand = { name: string, description: string, flags: HelpFlag[], positional: HelpPositional[], subcommands: { [string]: HelpSubcommand } }
--:: HelpSchema     = { name: string | nil, description: string | nil, usage: string | nil, subcommands: { [string]: HelpSubcommand }, flags: HelpFlag[], positional: HelpPositional[] }
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

	-- Strip leading nix download noise before parsing.
	text = strip_nix_noise(text)

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
	-- Case-insensitive: "Usage:", "USAGE:", "usage:" — handles both inline and
	-- standalone formats ("USAGE:\n    cmd args" as well as "Usage: cmd args").
	for idx, line in ipairs(lines) do
		-- Inline: "Usage: cmd args" or "USAGE: cmd args"
		local usage = line:match("^[Uu][Ss][Aa][Gg][Ee]:%s+(.+)$")
		if usage then
			schema.usage = usage
			schema.name = usage:match("^(%S+)")
			break
		end
		-- Standalone: "USAGE:" alone on a line, content is on next indented line(s).
		if line:match("^[Uu][Ss][Aa][Gg][Ee]:%s*$") then
			-- Look ahead for indented content.
			local next_idx = idx + 1
			while next_idx <= #lines and lines[next_idx]:match("^%s*$") do
				next_idx = next_idx + 1
			end
			if next_idx <= #lines then
				local content = lines[next_idx]:match("^%s+(.+)$")
				if content then
					schema.usage = content
					schema.name = content:match("^(%S+)")
				end
			end
			break
		end
	end

	-- Section-based parse.
	local section = nil -- "commands" | "arguments" | "options" | "flags_inline" | nil
	local section_indent = nil

	i = 1
	while i <= #lines do
		local line = lines[i]
		local line_indent = indent_of(line)
		local trimmed = line:match("^%s*(.-)%s*$") or ""

		-- Detect section headers.
		-- A header: minimal indentation (≤1), non-empty, looks like a header.
		-- Strip trailing colon and lowercase to normalize.
		local detected_section = nil

		if line_indent <= 1 and trimmed ~= "" then
			-- Strip trailing colon for lookup.
			local hdr_norm = trimmed:lower():match("^(.-)%s*:?%s*$") or trimmed:lower()

			-- Direct lookup.
			if SECTION_MAP[hdr_norm] then
				detected_section = SECTION_MAP[hdr_norm]
			else
				-- Compound lookup: "INPUT OPTIONS:", "SEARCH OPTIONS:", "OUTPUT MODES:", etc.
				detected_section = classify_compound_header(hdr_norm)
			end

			-- If no known section detected and line has zero indent, check if it looks like
			-- an unlabeled commands section (e.g. git's "start a working area").
			-- Heuristic: zero-indent non-blank prose line followed by command-pattern lines
			-- (2+ space indent, name followed by 2+ spaces and description).
			if not detected_section and line_indent == 0 then
				-- Peek ahead: skip blank lines, check if next content line looks like a command.
				local peek = i + 1
				while peek <= #lines and lines[peek]:match("^%s*$") do peek = peek + 1 end
				if peek <= #lines then
					local pname, pdesc = try_command_line(lines[peek])
					if pname and pdesc and not pname:match("^%-") then
						-- Looks like command entries follow — treat as commands section.
						detected_section = "commands"
					end
				end
			end
		end

		if detected_section then
			section = detected_section
			section_indent = nil
			i = i + 1
		elseif section == "commands" then
			local name, desc = try_command_line(line)
			if name and name ~= "help" and not name:match("^%-") then
				schema.subcommands[name] = {
					name = name,
					description = desc:match("^%s*(.-)%s*$"),
					flags = {},
					positional = {},
					subcommands = {},
				}
			elseif line:match("^%s*$") then
				-- Blank line ends commands section.
				section = nil
			elseif line_indent == 0 and trimmed ~= "" then
				-- Unindented non-blank line — could be a new section header or prose.
				-- Let the next iteration re-evaluate it as a potential header.
				section = nil
				-- Don't advance i — re-process this line.
				goto continue
			end
			i = i + 1
		elseif section == "arguments" then
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
				-- Peek ahead: continuation lines have greater indentation.
				local flag_indent = indent_of(line)
				while i + 1 <= #lines do
					local next_line = lines[i + 1]
					if next_line:match("^%s*$") then break end
					local ni = indent_of(next_line)
					if ni <= flag_indent then break end
					-- Must not start a new flag entry.
					if next_line:match("^%s+%-") then break end
					local cont = next_line:match("^%s*(.-)%s*$")
					if cont and cont ~= "" then
						flag.description = flag.description .. " " .. cont
					end
					i = i + 1
				end
			elseif line:match("^%s*$") then
				section = nil
			end
			i = i + 1
		else
			-- Outside any section: check for inline flags (curl-style: flags directly
			-- below Usage with no "Options:" header). If the line looks like a flag
			-- with any indentation, parse it.
			local flag = parse_flag_line(line)
			if flag then
				schema.flags[#schema.flags + 1] = flag
			end
			i = i + 1
		end

		::continue::
	end

	return schema
end

-- Run cmd --help (merging stderr) via opts.popen and parse the output.
-- opts.popen     fn   io.popen-compatible injected function (required)
-- opts.max_depth num  maximum subcommand recursion depth (default 4)
--: (string, { popen: (string, string) -> (File | nil, string | nil), max_depth: number | nil }) -> HelpSchema | nil, string | nil
function M.fetch(cmd, opts)
	local exec = require("lib.exec")
	local max_depth = opts.max_depth or 4

	-- Recursive helper: prefix_args is a list of strings e.g. {"normalize","edit"}
	--: (string[], number) -> HelpSchema | nil, string | nil
	local function fetch_recursive(prefix_args, depth)
		local args = {}
		for j = 2, #prefix_args do args[#args + 1] = prefix_args[j] end
		args[#args + 1] = "--help"

		local out, err = exec.run(prefix_args[1], args, {
			popen = opts.popen,
			stderr = "merge",
		})
		if not out then
			return nil, err
		end

		local schema = M.parse(out or "")

		if depth < max_depth then
			for name, sub in pairs(schema.subcommands) do
				local sub_prefix = {}
				for _, v in ipairs(prefix_args) do sub_prefix[#sub_prefix + 1] = v end
				sub_prefix[#sub_prefix + 1] = name

				local sub_schema, sub_err = fetch_recursive(sub_prefix, depth + 1)
				if sub_schema then
					-- Merge fetched schema into stub, preserving name+description from parent.
					sub.flags      = sub_schema.flags
					sub.positional = sub_schema.positional
					sub.subcommands = sub_schema.subcommands
				else
					-- Keep stub on failure; warn is intentionally suppressed per spec.
					_ = sub_err
				end
			end
		end

		return schema
	end

	return fetch_recursive({ cmd }, 0)
end

return M
