-- lib/exec/make_api.lua
-- Generate a fluent typed API table from a HelpSchema.
-- Does NOT perform any I/O. Schema must be pre-fetched by the caller.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

--:: require "lib.caps.types"
--:: require "lib.exec.help"

local exec = require("lib.exec")

local M = {}

-- Bitflags for node shape detection.
local CALLABLE        = 0x1
local HAS_SUBCOMMANDS = 0x2

-- Detect the kind of a node (HelpSchema or HelpSubcommand).
-- `any` — node is HelpSchema | HelpSubcommand; typechecker has no union field access,
-- so we opt out and access the shared fields directly.
--: (any) -> integer
local function node_kind(node)
	local kind = 0
	if #node.flags > 0 or #node.positional > 0 then
		kind = kind + CALLABLE
	end
	if next(node.subcommands) ~= nil then
		kind = kind + HAS_SUBCOMMANDS
	end
	-- A node with neither flag is still callable (leaf with no declared inputs).
	if kind == 0 then
		kind = CALLABLE
	end
	return kind
end

-- Expand a flags table to CLI arg strings.
-- Returns a list of strings, or nil + errmsg on unknown key.
-- flag_idents: { [string]: integer }
-- flags_list:  HelpFlag[]
--: (any, { [string]: integer }, HelpFlag[]) -> string[] | nil, string | nil
local function expand_flags(flags_tbl, flag_idents, flags_list)
	local args = {}
	for key, val in pairs(flags_tbl) do
		--: string
		local skey = tostring(key)
		local idx = flag_idents[skey]
		if not idx then
			return nil, "unknown flag: " .. skey
		end
		if val == nil then
			-- omit
		else
			local flag = flags_list[idx]
			local is_boolean_pair = flag.arg == "boolean"
			-- Determine the CLI flag token (--long or -short).
			--: string | nil
			local flong = flag.long
			--: string | nil
			local fshort = flag.short
			--: string
			local token
			if flong then
				token = flong
			elseif fshort then
				token = fshort
			else
				token = "--" .. skey
			end

			if val == true then
				args[#args + 1] = token
			elseif val == false then
				if is_boolean_pair and flong then
					-- --no-flag form
					local bare = flong:match("^%-%-(.+)$") or flong
					args[#args + 1] = "--no-" .. bare
				end
				-- else: simple boolean false → omit
			else
				-- string or number value
				local sval = tostring(val)
				args[#args + 1] = token
				args[#args + 1] = sval
			end
		end
	end
	return args
end

-- Build a callable function for a leaf/both node.
-- cmd:         binary name (string)
-- path_args:   list of raw subcommand names (strings) to prepend as args
-- node:        HelpSchema or HelpSubcommand (any — either shape is valid here)
-- opts:        MakeApiOpts (popen, stderr)
--: (string, string[], any, MakeApiOpts) -> function
local function make_leaf_fn(cmd, path_args, node, opts)
	return function(...)
		local varargs = { ... }
		-- If called via __call on a "both" node, self is the first arg — skip it.
		-- Detect: first arg is the table itself (metatable present with __call).
		local start = 1
		if type(varargs[1]) == "table" and getmetatable(varargs[1]) and
		   getmetatable(varargs[1]).__call then
			start = 2
		end

		local n_pos = #node.positional
		-- Collect positional args from varargs.
		local pos_args = {}
		for i = start, start + n_pos - 1 do
			pos_args[#pos_args + 1] = varargs[i]
		end

		-- Optional trailing flags table.
		local flags_tbl = varargs[start + n_pos]

		-- Build arg list: path_args + positionals + flags.
		local args = {}
		for _, v in ipairs(path_args) do
			args[#args + 1] = v
		end
		for _, v in ipairs(pos_args) do
			if v ~= nil then
				args[#args + 1] = tostring(v)
			end
		end
		if flags_tbl ~= nil then
			if type(flags_tbl) ~= "table" then
				return nil, "flags argument must be a table"
			end
			local flag_args, ferr = expand_flags(flags_tbl, node.flag_idents, node.flags)
			if not flag_args then
				return nil, ferr
			end
			for _, v in ipairs(flag_args) do
				args[#args + 1] = v
			end
		end

		return exec.run(cmd, args, {
			popen  = opts.popen,
			stderr = opts.stderr,
		})
	end
end

-- Recursively build the API table for a node.
-- cmd:       binary name
-- path_args: raw subcommand names up to (not including) this node
-- node:      HelpSchema or HelpSubcommand (any)
-- opts:      MakeApiOpts
--: (string, string[], any, MakeApiOpts) -> any
local function build_node(cmd, path_args, node, opts)
	local kind = node_kind(node)
	local callable = (kind % 2 == 1)          -- CALLABLE bit
	local has_sub  = (kind >= HAS_SUBCOMMANDS) -- HAS_SUBCOMMANDS bit

	-- Build subcommand child nodes.
	local children = {}
	if has_sub then
		for ident, raw_name in pairs(node.subcommand_idents) do
			local sub = node.subcommands[raw_name]
			if sub then
				-- sub.subcommand_idents may be nil if it was never populated.
				if not sub.subcommand_idents then
					sub.subcommand_idents = {}
				end
				if not sub.flag_idents then
					sub.flag_idents = {}
				end
				local sub_path = {}
				for _, v in ipairs(path_args) do sub_path[#sub_path + 1] = v end
				sub_path[#sub_path + 1] = raw_name
				children[ident] = build_node(cmd, sub_path, sub, opts)
			end
		end
	end

	if callable and not has_sub then
		-- Leaf: plain function.
		return make_leaf_fn(cmd, path_args, node, opts)
	elseif not callable and has_sub then
		-- Namespace: plain table, no __call.
		return children
	else
		-- Both: table with __call metamethod.
		local fn = make_leaf_fn(cmd, path_args, node, opts)
		return setmetatable(children, {
			__call = function(self, ...)
				return fn(self, ...)
			end,
		})
	end
end

-- PascalCase a path like {"normalize","view"} → "NormalizeView".
--: (string[]) -> string
local function pascal_case(parts)
	local out = {}
	for _, p in ipairs(parts) do
		out[#out + 1] = p:sub(1,1):upper() .. p:sub(2)
	end
	return table.concat(out)
end

-- Generate --:: declarations for a node tree.
-- Appends declaration lines to `out`.
-- name_path: list of raw name parts for PascalCase generation (starts with cmd).
-- node:      HelpSchema or HelpSubcommand (any)
-- used_names: { [string]: boolean } for collision avoidance
-- out:       string[] accumulator
--: (string[], any, { [string]: boolean }, string[]) -> nil
local function gen_decls(name_path, node, used_names, out)
	local base = pascal_case(name_path)

	-- Collision avoidance: find a free name.
	--: (string) -> string
	local function unique_name(n)
		if not used_names[n] then
			used_names[n] = true
			return n
		end
		local i = 2
		while used_names[n .. "_" .. tostring(i)] do
			i = i + 1
		end
		local result = n .. "_" .. tostring(i)
		used_names[result] = true
		return result
	end

	local kind = node_kind(node)
	local callable = (kind % 2 == 1)
	local has_sub  = (kind >= HAS_SUBCOMMANDS)

	-- Recursively generate child decls first (so names are defined before use).
	if has_sub then
		for ident, raw_name in pairs(node.subcommand_idents) do
			local sub = node.subcommands[raw_name]
			if sub then
				if not sub.subcommand_idents then sub.subcommand_idents = {} end
				if not sub.flag_idents       then sub.flag_idents = {} end
				local child_path = {}
				for _, v in ipairs(name_path) do child_path[#child_path + 1] = v end
				child_path[#child_path + 1] = tostring(ident)
				gen_decls(child_path, sub, used_names, out)
			end
		end
	end

	-- Flags type declaration.
	--: string | nil
	local flags_type_name = nil
	if #node.flags > 0 then
		flags_type_name = unique_name(base .. "Flags")
		local parts = {}
		for _, f in ipairs(node.flags) do
			--: string
			local fident = tostring(f.ident)
			--: string
			local farg = tostring(f.arg or "")
			local t
			if farg == "boolean" or farg == "" then
				t = "boolean | nil"
			else
				t = "string | nil"
			end
			parts[#parts + 1] = fident .. ": " .. t
		end
		--: string
		local fname = flags_type_name
		out[#out + 1] = "--:: " .. fname .. " = { " .. table.concat(parts, ", ") .. " }"
	end

	-- Function type declaration (callable nodes).
	--: string | nil
	local fn_type_name = nil
	if callable then
		fn_type_name = unique_name(base)
		local sig_parts = {}
		for _, p in ipairs(node.positional) do
			--: string
			local pident = tostring(p.ident)
			sig_parts[#sig_parts + 1] = pident .. ": string"
		end
		if flags_type_name ~= nil then
			--: string
			local ftn = flags_type_name
			sig_parts[#sig_parts + 1] = "flags: " .. ftn .. " | nil"
		end
		local sig = table.concat(sig_parts, ", ")
		--: string
		local ftn2 = fn_type_name
		out[#out + 1] = "--:: " .. ftn2 .. " = (" .. sig .. ") -> string | nil, string | nil"
	end

	-- Namespace / both node type declaration.
	if has_sub then
		local tbl_name = unique_name(base)
		local fields = {}
		for ident, raw_name in pairs(node.subcommand_idents) do
			local sub = node.subcommands[raw_name]
			if sub then
				local child_parts = {}
				for _, v in ipairs(name_path) do child_parts[#child_parts + 1] = v end
				child_parts[#child_parts + 1] = tostring(ident)
				local child_base = pascal_case(child_parts)
				-- Reference the child by its base PascalCase name — the exact emitted name
				-- may differ (collision suffix), but base is the best documentation guess.
				fields[#fields + 1] = tostring(ident) .. ": " .. child_base
			end
		end
		if callable and fn_type_name ~= nil then
			--: string
			local ftn3 = fn_type_name
			fields[#fields + 1] = "#__call: " .. ftn3
		end
		-- Sort fields for determinism.
		table.sort(fields)
		out[#out + 1] = "--:: " .. tbl_name .. " = { " .. table.concat(fields, ", ") .. " }"
	end
end

-- Generate a fluent typed API table from a HelpSchema.
--
-- schema  HelpSchema    pre-fetched schema from lib.exec.help.parse / fetch
-- cmd     string        binary name used to invoke the command
-- opts    MakeApiOpts   caps table: opts.popen required, opts.stderr optional
--
-- Returns api_table, decls_string.
--:: MakeApiOpts = { popen: POpenFn, stderr: string | nil }
--: (HelpSchema, string, MakeApiOpts) -> any, string
function M.make(schema, cmd, opts)
	-- Ensure field_idents are present (root schema always has them; be defensive).
	if not schema.flag_idents then
		schema.flag_idents = {}
	end
	if not schema.subcommand_idents then
		schema.subcommand_idents = {}
	end

	local api = build_node(cmd, {}, schema, opts)

	-- Generate type declarations.
	local decl_lines = {}
	local used_names = {}
	gen_decls({ cmd }, schema, used_names, decl_lines)

	local decls_string = table.concat(decl_lines, "\n")
	if #decl_lines > 0 then
		decls_string = decls_string .. "\n"
	end

	return api, decls_string
end

return M
