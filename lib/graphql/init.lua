-- lib/graphql/init.lua
-- GraphQL query parser, schema DSL, and executor (pure Lua, LuaJIT).
-- Supports: queries, mutations, subscriptions, fragments, variables,
--           aliases, arguments, directives, inline fragments, __typename.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

local byte, sub, find, match, gmatch = string.byte, string.sub, string.find, string.match, string.gmatch
local concat = table.concat
local type, tostring, pairs, ipairs = type, tostring, pairs, ipairs
local floor = math.floor

-- ── Lexer ─────────────────────────────────────────────────────────────────────

local TK = {
	NAME        = "NAME",
	INT         = "INT",
	FLOAT       = "FLOAT",
	STRING      = "STRING",
	BANG        = "!",
	DOLLAR      = "$",
	LPAREN      = "(",
	RPAREN      = ")",
	ELLIPSIS    = "...",
	COLON       = ":",
	EQUALS      = "=",
	AT          = "@",
	LBRACKET    = "[",
	RBRACKET    = "]",
	LBRACE      = "{",
	RBRACE      = "}",
	PIPE        = "|",
	AMP         = "&",
	EOF         = "EOF",
}

local KEYWORDS = {
	["true"] = true, ["false"] = true, ["null"] = true,
	["query"] = true, ["mutation"] = true, ["subscription"] = true,
	["fragment"] = true, ["on"] = true, ["schema"] = true,
	["type"] = true, ["interface"] = true, ["union"] = true,
	["scalar"] = true, ["enum"] = true, ["input"] = true,
	["extend"] = true, ["directive"] = true, ["implements"] = true,
	["repeatable"] = true,
}

local function new_lexer(src)
	return { src = src, pos = 1, len = #src }
end

--:: GQLLex = { src: string, pos: integer, len: integer }
--: (GQLLex, string) -> (nil, string)
local function lex_error(lex, msg)
	local line = 1
	for _ in gmatch(sub(lex.src, 1, lex.pos), "\n") do line = line + 1 end
	return nil, ("GraphQL lexer error at line %d: %s"):format(line, msg)
end

-- Skip whitespace, commas (insignificant), and comments
--: (GQLLex) -> nil
local function skip_ignored(lex)
	local src, pos, len = lex.src, lex.pos, lex.len
	while pos <= len do
		local b = byte(src, pos)
		-- whitespace + comma
		if b == 0x20 or b == 0x09 or b == 0x0A or b == 0x0D or b == 0x2C then
			pos = pos + 1
		-- comment
		elseif b == 0x23 then -- '#'
			pos = pos + 1
			while pos <= len and byte(src, pos) ~= 0x0A do pos = pos + 1 end
		else
			break
		end
	end
	lex.pos = pos
end

--: (GQLLex) -> (string | nil, string | nil)
local function read_string(lex)
	local src, pos, len = lex.src, lex.pos, lex.len
	-- Check for block string """
	if sub(src, pos, pos + 2) == '"""' then
		pos = pos + 3
		local start = pos
		local parts = {}
		while pos <= len do
			if sub(src, pos, pos + 2) == '"""' then
				parts[#parts + 1] = sub(src, start, pos - 1)
				lex.pos = pos + 3
				return concat(parts)
			elseif byte(src, pos) == 0x5C and sub(src, pos, pos + 3) == '\\"""' then
				parts[#parts + 1] = sub(src, start, pos - 1)
				parts[#parts + 1] = '"""'
				pos = pos + 4
				start = pos
			else
				pos = pos + 1
			end
		end
		return lex_error(lex, "unterminated block string")
	end
	-- Regular string
	local parts = {}
	local start = pos
	while pos <= len do
		local b = byte(src, pos)
		if b == 0x22 then -- '"'
			parts[#parts + 1] = sub(src, start, pos - 1)
			lex.pos = pos + 1
			return concat(parts)
		elseif b == 0x5C then -- '\'
			parts[#parts + 1] = sub(src, start, pos - 1)
			pos = pos + 1
			local esc = byte(src, pos)
			if esc == 0x22 then parts[#parts + 1] = '"'
			elseif esc == 0x5C then parts[#parts + 1] = '\\'
			elseif esc == 0x2F then parts[#parts + 1] = '/'
			elseif esc == 0x62 then parts[#parts + 1] = '\b'
			elseif esc == 0x66 then parts[#parts + 1] = '\f'
			elseif esc == 0x6E then parts[#parts + 1] = '\n'
			elseif esc == 0x72 then parts[#parts + 1] = '\r'
			elseif esc == 0x74 then parts[#parts + 1] = '\t'
			elseif esc == 0x75 then -- \uXXXX
				local hex = sub(src, pos + 1, pos + 4)
				local cp_n = tonumber(hex, 16)
				if not cp_n then return lex_error(lex, "invalid unicode escape") end
				local cp = math.floor(cp_n + 0)
				-- encode as UTF-8
				if cp <= 0x7F then
					parts[#parts + 1] = string.char(cp)
				elseif cp <= 0x7FF then
					local b1 = math.floor(0xC0 + floor(cp / 64))
					local b2 = math.floor(0x80 + (cp % 64))
					parts[#parts + 1] = string.char(b1, b2)
				else
					local b1 = math.floor(0xE0 + floor(cp / 4096))
					local b2 = math.floor(0x80 + floor(cp / 64) % 64)
					local b3 = math.floor(0x80 + (cp % 64))
					parts[#parts + 1] = string.char(b1, b2, b3)
				end
				pos = pos + 4
			else
				return lex_error(lex, "unknown escape \\" .. string.char(esc))
			end
			pos = pos + 1
			start = pos
		elseif b == 0x0A or b == 0x0D then
			return lex_error(lex, "unterminated string literal")
		else
			pos = pos + 1
		end
	end
	return lex_error(lex, "unterminated string literal")
end

-- Returns token: { kind, value } or errors
local function next_token(lex)
	skip_ignored(lex)
	local src, pos, len = lex.src, lex.pos, lex.len
	if pos > len then
		return { kind = TK.EOF }
	end
	local b = byte(src, pos) or 0
	-- Punctuators
	if b == 0x21 then lex.pos = pos + 1; return { kind = TK.BANG }
	elseif b == 0x24 then lex.pos = pos + 1; return { kind = TK.DOLLAR }
	elseif b == 0x28 then lex.pos = pos + 1; return { kind = TK.LPAREN }
	elseif b == 0x29 then lex.pos = pos + 1; return { kind = TK.RPAREN }
	elseif b == 0x3A then lex.pos = pos + 1; return { kind = TK.COLON }
	elseif b == 0x3D then lex.pos = pos + 1; return { kind = TK.EQUALS }
	elseif b == 0x40 then lex.pos = pos + 1; return { kind = TK.AT }
	elseif b == 0x5B then lex.pos = pos + 1; return { kind = TK.LBRACKET }
	elseif b == 0x5D then lex.pos = pos + 1; return { kind = TK.RBRACKET }
	elseif b == 0x7B then lex.pos = pos + 1; return { kind = TK.LBRACE }
	elseif b == 0x7D then lex.pos = pos + 1; return { kind = TK.RBRACE }
	elseif b == 0x7C then lex.pos = pos + 1; return { kind = TK.PIPE }
	elseif b == 0x26 then lex.pos = pos + 1; return { kind = TK.AMP }
	-- Ellipsis
	elseif b == 0x2E then
		if sub(src, pos, pos + 2) == "..." then
			lex.pos = pos + 3; return { kind = TK.ELLIPSIS }
		end
		return lex_error(lex, "unexpected '.'")
	-- String
	elseif b == 0x22 then
		lex.pos = pos + 1
		local s, err = read_string(lex)
		if err then return nil, err end
		return { kind = TK.STRING, value = s }
	-- Number
	elseif b == 0x2D or (b >= 0x30 and b <= 0x39) then
		local _ws, _we = find(src, "^-?[0-9]+", pos)
		local e = _we or pos --: integer
		local is_float = false
		if byte(src, e + 1) == 0x2E then
			-- fraction
			local _, e2 = find(src, "^%.[0-9]+", e + 1)
			if e2 then e = e2 + 0; is_float = true end
		end
		if byte(src, e + 1) == 0x65 or byte(src, e + 1) == 0x45 then
			-- exponent
			local _, e3 = find(src, "^[eE][+%-]?[0-9]+", e + 1)
			if e3 then e = e3 + 0; is_float = true end
		end
		local raw = sub(src, pos, e)
		lex.pos = e + 1
		if is_float then
			return { kind = TK.FLOAT, value = raw }
		else
			return { kind = TK.INT, value = raw }
		end
	-- Name / keyword
	elseif (b >= 0x41 and b <= 0x5A) or (b >= 0x61 and b <= 0x7A) or b == 0x5F then
		local s, e = find(src, "^[_%a][_%w]*", pos)
		local name = sub(src, s or pos, e or pos)
		lex.pos = (e or pos) + 1
		return { kind = TK.NAME, value = name }
	end
	return lex_error(lex, ("unexpected character %q"):format(string.char(b or 0)))
end

-- ── Token stream ──────────────────────────────────────────────────────────────

--:: GQLToken = { kind: string, value?: string, ... }
--:: GQLParser = { lex: { src: string, pos: integer, len: integer }, current: GQLToken, errors: { [integer]: string } }
local function new_parser(src)
	local lex = new_lexer(src)
	local p = { lex = lex, current = { kind = TK.EOF } --[[: GQLToken]], errors = {} }
	-- pre-read first token
	local tok, err = next_token(lex)
	if err or not tok then p.errors[#p.errors + 1] = err or "no token"; tok = { kind = TK.EOF } end
	p.current = tok --[[: GQLToken]]
	return p
end

--: (GQLParser) -> GQLToken
local function advance(p)
	local tok, err = next_token(p.lex)
	if err or not tok then
		p.errors[#p.errors + 1] = err or "no token"
		tok = { kind = TK.EOF }
	end
	local tok_ = tok --[[: GQLToken]]
	p.current = tok_
	return tok_
end

--: (GQLParser) -> GQLToken
local function peek(p)
	return p.current
end

--: (GQLParser, string, string | nil) -> (GQLToken | nil, string | nil)
local function expect(p, kind, value)
	local tok = p.current
	if tok.kind ~= kind then
		local pos = p.lex.pos
		local line = 1
		for _ in gmatch(sub(p.lex.src, 1, pos), "\n") do line = line + 1 end
		local tv = tok.value
		local got_str = tok.kind .. (tv and ("(" .. tv .. ")") or "")
		local msg = ("GraphQL parse error at line %d: expected %s, got %s"):format(line, kind, got_str)
		p.errors[#p.errors + 1] = msg
		return nil, msg
	end
	if value and tok.value ~= value then
		local msg = ("GraphQL parse error: expected %s %q, got %q"):format(kind, value, tok.value or "")
		p.errors[#p.errors + 1] = msg
		return nil, msg
	end
	advance(p)
	return tok
end

--: (GQLParser, string | nil) -> (GQLToken | nil, string | nil)
local function expect_name(p, value)
	return expect(p, TK.NAME, value)
end

-- ── Parser helpers ────────────────────────────────────────────────────────────

local parse_value  -- forward declaration
local parse_type   -- forward declaration

-- Parse a type reference: NamedType | ListType | NonNullType
--:: GQLType = { kind: "ListType", type: any } | { kind: "NamedType", name: string | nil } | { kind: "NonNullType", type: any }
parse_type = function(p)
	local tok = peek(p)
	local t = nil --: GQLType | nil
	if tok.kind == TK.LBRACKET then
		advance(p)
		local inner, err = parse_type(p)
		if err then return nil, err end
		local rb, err2 = expect(p, TK.RBRACKET)
		if err2 then return nil, err2 end
		t = { kind = "ListType", type = inner }
	elseif tok.kind == TK.NAME then
		t = { kind = "NamedType", name = tok.value }
		advance(p)
	else
		return nil, "expected type name"
	end
	if peek(p).kind == TK.BANG then
		advance(p)
		t = { kind = "NonNullType", type = t }
	end
	return t
end

-- Parse variable: $name
local function parse_variable(p)
	local _, err = expect(p, TK.DOLLAR)
	if err then return nil, err end
	local name_tok, err2 = expect(p, TK.NAME)
	if err2 then return nil, err2 end
	return { kind = "Variable", name = name_tok.value }
end

-- Parse arguments: (name: value, ...)
local function parse_arguments(p)
	if peek(p).kind ~= TK.LPAREN then return {} end
	advance(p)
	local args = {}
	while peek(p).kind ~= TK.RPAREN and peek(p).kind ~= TK.EOF do
		local name_tok, err = expect(p, TK.NAME)
		if err then return nil, err end
		local _, err2 = expect(p, TK.COLON)
		if err2 then return nil, err2 end
		local val, err3 = parse_value(p)
		if err3 then return nil, err3 end
		args[#args + 1] = { kind = "Argument", name = name_tok.value, value = val }
	end
	local _, err = expect(p, TK.RPAREN)
	if err then return nil, err end
	return args
end

-- Parse directives: @name(args)
local function parse_directives(p)
	local dirs = {}
	while peek(p).kind == TK.AT do
		advance(p)
		local name_tok, err = expect(p, TK.NAME)
		if err then return nil, err end
		local args, err2 = parse_arguments(p)
		if err2 then return nil, err2 end
		dirs[#dirs + 1] = { kind = "Directive", name = name_tok.value, arguments = args }
	end
	return dirs
end

-- Parse a value (literal or variable)
parse_value = function(p)
	local tok = peek(p)
	if tok.kind == TK.DOLLAR then
		return parse_variable(p)
	elseif tok.kind == TK.INT then
		advance(p)
		return { kind = "IntValue", value = tok.value }
	elseif tok.kind == TK.FLOAT then
		advance(p)
		return { kind = "FloatValue", value = tok.value }
	elseif tok.kind == TK.STRING then
		advance(p)
		return { kind = "StringValue", value = tok.value }
	elseif tok.kind == TK.NAME then
		if tok.value == "true" then
			advance(p)
			return { kind = "BooleanValue", value = true }
		elseif tok.value == "false" then
			advance(p)
			return { kind = "BooleanValue", value = false }
		elseif tok.value == "null" then
			advance(p)
			return { kind = "NullValue" }
		else
			-- Enum value
			advance(p)
			return { kind = "EnumValue", value = tok.value }
		end
	elseif tok.kind == TK.LBRACKET then
		advance(p)
		local values = {}
		while peek(p).kind ~= TK.RBRACKET and peek(p).kind ~= TK.EOF do
			local v, err = parse_value(p)
			if err then return nil, err end
			values[#values + 1] = v
		end
		local _, err = expect(p, TK.RBRACKET)
		if err then return nil, err end
		return { kind = "ListValue", values = values }
	elseif tok.kind == TK.LBRACE then
		advance(p)
		local fields = {}
		while peek(p).kind ~= TK.RBRACE and peek(p).kind ~= TK.EOF do
			local name_tok, err = expect(p, TK.NAME)
			if err then return nil, err end
			local _, err2 = expect(p, TK.COLON)
			if err2 then return nil, err2 end
			local val, err3 = parse_value(p)
			if err3 then return nil, err3 end
			fields[#fields + 1] = { kind = "ObjectField", name = name_tok.value, value = val }
		end
		local _, err = expect(p, TK.RBRACE)
		if err then return nil, err end
		return { kind = "ObjectValue", fields = fields }
	end
	return nil, ("unexpected token in value: %s"):format(tok.kind .. (tok.value and "(" .. tok.value .. ")" or ""))
end

-- Forward declaration for selection set (mutually recursive with field parsing)
local parse_selection_set

-- Parse a single selection (field | fragment spread | inline fragment)
local function parse_selection(p)
	local tok = peek(p)
	if tok.kind == TK.ELLIPSIS then
		advance(p)
		local next_tok = peek(p)
		-- Inline fragment: ... on TypeName { ... }
		-- Fragment spread:  ... FragmentName
		if next_tok.kind == TK.NAME and next_tok.value == "on" then
			advance(p) -- consume "on"
			local type_tok, err = expect(p, TK.NAME)
			if err then return nil, err end
			local dirs, err2 = parse_directives(p)
			if err2 then return nil, err2 end
			local sel, err3 = parse_selection_set(p)
			if err3 then return nil, err3 end
			return {
				kind = "InlineFragment",
				typeCondition = { kind = "NamedType", name = type_tok.value },
				directives = dirs,
				selectionSet = sel,
			}
		elseif next_tok.kind == TK.NAME then
			local name = next_tok.value
			advance(p)
			local dirs, err = parse_directives(p)
			if err then return nil, err end
			return { kind = "FragmentSpread", name = name, directives = dirs }
		else
			-- Inline fragment without type condition
			local dirs, err = parse_directives(p)
			if err then return nil, err end
			local sel, err2 = parse_selection_set(p)
			if err2 then return nil, err2 end
			return {
				kind = "InlineFragment",
				typeCondition = nil,
				directives = dirs,
				selectionSet = sel,
			}
		end
	elseif tok.kind == TK.NAME then
		-- Field: [alias:] name [args] [directives] [selectionSet]
		local name = tok.value
		local alias = nil
		advance(p)
		-- Check for alias
		if peek(p).kind == TK.COLON then
			advance(p)
			alias = name
			local name_tok, err = expect(p, TK.NAME)
			if err then return nil, err end
			name = name_tok.value
		end
		local args, err = parse_arguments(p)
		if err then return nil, err end
		local dirs, err2 = parse_directives(p)
		if err2 then return nil, err2 end
		local sel = nil
		if peek(p).kind == TK.LBRACE then
			local s, err3 = parse_selection_set(p)
			if err3 then return nil, err3 end
			sel = s
		end
		return {
			kind = "Field",
			alias = alias,
			name = name,
			arguments = args,
			directives = dirs,
			selectionSet = sel,
		}
	end
	return nil, ("unexpected token in selection: %s"):format(tok.kind)
end

-- Parse { selection ... }
parse_selection_set = function(p)
	local _, err = expect(p, TK.LBRACE)
	if err then return nil, err end
	local selections = {}
	while peek(p).kind ~= TK.RBRACE and peek(p).kind ~= TK.EOF do
		local sel, err2 = parse_selection(p)
		if err2 then return nil, err2 end
		selections[#selections + 1] = sel
	end
	local _, err2 = expect(p, TK.RBRACE)
	if err2 then return nil, err2 end
	return { kind = "SelectionSet", selections = selections }
end

-- Parse variable definitions: ($var: Type = default, ...)
local function parse_variable_definitions(p)
	if peek(p).kind ~= TK.LPAREN then return {} end
	advance(p)
	local defs = {}
	while peek(p).kind ~= TK.RPAREN and peek(p).kind ~= TK.EOF do
		local _, err = expect(p, TK.DOLLAR)
		if err then return nil, err end
		local name_tok, err2 = expect(p, TK.NAME)
		if err2 then return nil, err2 end
		local _, err3 = expect(p, TK.COLON)
		if err3 then return nil, err3 end
		local t, err4 = parse_type(p)
		if err4 then return nil, err4 end
		local default = nil
		if peek(p).kind == TK.EQUALS then
			advance(p)
			local v, err5 = parse_value(p)
			if err5 then return nil, err5 end
			default = v
		end
		local dirs, err6 = parse_directives(p)
		if err6 then return nil, err6 end
		defs[#defs + 1] = {
			kind = "VariableDefinition",
			variable = { kind = "Variable", name = name_tok.value },
			type = t,
			defaultValue = default,
			directives = dirs,
		}
	end
	local _, err = expect(p, TK.RPAREN)
	if err then return nil, err end
	return defs
end

-- Parse an operation definition: query/mutation/subscription or shorthand
local function parse_operation_definition(p)
	local tok = peek(p)
	-- Shorthand: { ... }
	if tok.kind == TK.LBRACE then
		local sel, err = parse_selection_set(p)
		if err then return nil, err end
		return {
			kind = "OperationDefinition",
			operation = "query",
			name = nil,
			variableDefinitions = {},
			directives = {},
			selectionSet = sel,
		}
	end
	-- Named operation
	local op = tok.value
	if op ~= "query" and op ~= "mutation" and op ~= "subscription" then
		return nil, ("expected operation type, got %q"):format(op or "")
	end
	advance(p)
	local name = nil
	if peek(p).kind == TK.NAME and not KEYWORDS[peek(p).value] then
		name = peek(p).value
		advance(p)
	elseif peek(p).kind == TK.NAME and (peek(p).value ~= "query" and peek(p).value ~= "mutation" and peek(p).value ~= "subscription" and peek(p).value ~= "fragment") then
		-- Allow keyword-valued names like GetUser
		name = peek(p).value
		advance(p)
	end
	local var_defs, err = parse_variable_definitions(p)
	if err then return nil, err end
	local dirs, err2 = parse_directives(p)
	if err2 then return nil, err2 end
	local sel, err3 = parse_selection_set(p)
	if err3 then return nil, err3 end
	return {
		kind = "OperationDefinition",
		operation = op,
		name = name,
		variableDefinitions = var_defs,
		directives = dirs,
		selectionSet = sel,
	}
end

-- Parse fragment definition: fragment Name on TypeName { ... }
local function parse_fragment_definition(p)
	advance(p) -- consume "fragment"
	local name_tok, err = expect(p, TK.NAME)
	if err then return nil, err end
	local _, err2 = expect_name(p, "on")
	if err2 then return nil, err2 end
	local type_tok, err3 = expect(p, TK.NAME)
	if err3 then return nil, err3 end
	local dirs, err4 = parse_directives(p)
	if err4 then return nil, err4 end
	local sel, err5 = parse_selection_set(p)
	if err5 then return nil, err5 end
	return {
		kind = "FragmentDefinition",
		name = name_tok.value,
		typeCondition = { kind = "NamedType", name = type_tok.value },
		directives = dirs,
		selectionSet = sel,
	}
end

-- ── Schema SDL parser ─────────────────────────────────────────────────────────

-- Parse field definitions for SDL types: name(args): type
local function parse_input_value_definitions(p)
	local _, err = expect(p, TK.LPAREN)
	if err then return nil, err end
	local defs = {}
	while peek(p).kind ~= TK.RPAREN and peek(p).kind ~= TK.EOF do
		local name_tok, err2 = expect(p, TK.NAME)
		if err2 then return nil, err2 end
		local _, err3 = expect(p, TK.COLON)
		if err3 then return nil, err3 end
		local t, err4 = parse_type(p)
		if err4 then return nil, err4 end
		local default = nil
		if peek(p).kind == TK.EQUALS then
			advance(p)
			local v, err5 = parse_value(p)
			if err5 then return nil, err5 end
			default = v
		end
		defs[#defs + 1] = {
			kind = "InputValueDefinition",
			name = name_tok.value,
			type = t,
			defaultValue = default,
		}
	end
	local _, err = expect(p, TK.RPAREN)
	if err then return nil, err end
	return defs
end

local function parse_field_definitions(p)
	local _, err = expect(p, TK.LBRACE)
	if err then return nil, err end
	local fields = {}
	while peek(p).kind ~= TK.RBRACE and peek(p).kind ~= TK.EOF do
		local name_tok, err2 = expect(p, TK.NAME)
		if err2 then return nil, err2 end
		local args = {}
		if peek(p).kind == TK.LPAREN then
			local a, err3 = parse_input_value_definitions(p)
			if err3 or not a then return nil, err3 end
			args = a
		end
		local _, err4 = expect(p, TK.COLON)
		if err4 then return nil, err4 end
		local t, err5 = parse_type(p)
		if err5 then return nil, err5 end
		fields[#fields + 1] = {
			kind = "FieldDefinition",
			name = name_tok.value,
			arguments = args,
			type = t,
		}
	end
	local _, err = expect(p, TK.RBRACE)
	if err then return nil, err end
	return fields
end

-- Parse SDL type definition
local function parse_type_definition(p)
	local kw = peek(p).value
	advance(p)
	if kw == "type" or kw == "input" or kw == "interface" then
		local name_tok, err = expect(p, TK.NAME)
		if err then return nil, err end
		-- implements
		local interfaces = {}
		if peek(p).kind == TK.NAME and peek(p).value == "implements" then
			advance(p)
			while peek(p).kind == TK.NAME do
				interfaces[#interfaces + 1] = peek(p).value
				advance(p)
				if peek(p).kind == TK.AMP then advance(p) end
			end
		end
		local fields, err2 = parse_field_definitions(p)
		if err2 then return nil, err2 end
		return {
			kind = kw == "input" and "InputObjectTypeDefinition" or
			       kw == "interface" and "InterfaceTypeDefinition" or
			       "ObjectTypeDefinition",
			name = name_tok.value,
			interfaces = interfaces,
			fields = fields,
		}
	elseif kw == "enum" then
		local name_tok, err = expect(p, TK.NAME)
		if err then return nil, err end
		local _, err2 = expect(p, TK.LBRACE)
		if err2 then return nil, err2 end
		local values = {}
		while peek(p).kind ~= TK.RBRACE and peek(p).kind ~= TK.EOF do
			local v_tok, err3 = expect(p, TK.NAME)
			if err3 then return nil, err3 end
			values[#values + 1] = { kind = "EnumValueDefinition", name = v_tok.value }
		end
		local _, err3 = expect(p, TK.RBRACE)
		if err3 then return nil, err3 end
		return { kind = "EnumTypeDefinition", name = name_tok.value, values = values }
	elseif kw == "union" then
		local name_tok, err = expect(p, TK.NAME)
		if err then return nil, err end
		local _, err2 = expect(p, TK.EQUALS)
		if err2 then return nil, err2 end
		local members = {}
		members[#members + 1] = peek(p).value; advance(p)
		while peek(p).kind == TK.PIPE do
			advance(p)
			members[#members + 1] = peek(p).value; advance(p)
		end
		return { kind = "UnionTypeDefinition", name = name_tok.value, members = members }
	elseif kw == "scalar" then
		local name_tok, err = expect(p, TK.NAME)
		if err then return nil, err end
		return { kind = "ScalarTypeDefinition", name = name_tok.value }
	elseif kw == "schema" then
		local _, err = expect(p, TK.LBRACE)
		if err then return nil, err end
		local ops = {}
		while peek(p).kind ~= TK.RBRACE and peek(p).kind ~= TK.EOF do
			local op_tok, err2 = expect(p, TK.NAME)
			if err2 then return nil, err2 end
			local _, err3 = expect(p, TK.COLON)
			if err3 then return nil, err3 end
			local type_tok, err4 = expect(p, TK.NAME)
			if err4 then return nil, err4 end
			ops[#ops + 1] = { operation = op_tok.value, type = type_tok.value }
		end
		local _, err2 = expect(p, TK.RBRACE)
		if err2 then return nil, err2 end
		return { kind = "SchemaDefinition", operationTypes = ops }
	end
	return nil, ("unknown type keyword: %q"):format(kw)
end

-- ── Public parse API ──────────────────────────────────────────────────────────

-- Parse a GraphQL query document
function M.parse(src)
	local p = new_parser(src)
	local definitions = {}
	while peek(p).kind ~= TK.EOF do
		local tok = peek(p)
		local def, err
		if tok.kind == TK.NAME and tok.value == "fragment" then
			def, err = parse_fragment_definition(p)
		elseif tok.kind == TK.NAME and
		       (tok.value == "query" or tok.value == "mutation" or tok.value == "subscription") then
			def, err = parse_operation_definition(p)
		elseif tok.kind == TK.LBRACE then
			def, err = parse_operation_definition(p)
		else
			err = ("unexpected token: %s%s"):format(
				tok.kind, tok.value and ("(" .. tok.value .. ")") or "")
		end
		if err then
			if #p.errors > 0 then
				return nil, p.errors[1]
			end
			return nil, err
		end
		definitions[#definitions + 1] = def
	end
	if #p.errors > 0 then
		return nil, p.errors[1]
	end
	return { kind = "Document", definitions = definitions }
end

-- Parse a GraphQL SDL schema document
function M.parse_schema(src)
	local p = new_parser(src)
	local definitions = {}
	local SDL_KEYWORDS = {
		type = true, input = true, interface = true, enum = true,
		union = true, scalar = true, schema = true,
	}
	while peek(p).kind ~= TK.EOF do
		local tok = peek(p)
		-- skip "extend" keyword
		if tok.kind == TK.NAME and tok.value == "extend" then
			advance(p)
			tok = peek(p)
		end
		if tok.kind == TK.NAME and SDL_KEYWORDS[tok.value] then
			local def, err = parse_type_definition(p)
			if err then
				if #p.errors > 0 then return nil, p.errors[1] end
				return nil, err
			end
			definitions[#definitions + 1] = def
		else
			local err = ("unexpected token in schema: %s%s"):format(
				tok.kind, tok.value and ("(" .. tok.value .. ")") or "")
			return nil, err
		end
	end
	if #p.errors > 0 then
		return nil, p.errors[1]
	end
	return { kind = "Document", definitions = definitions }
end

-- ── Schema DSL ────────────────────────────────────────────────────────────────

-- Build an executable schema from a table definition.
-- Input: { TypeName = { fieldName = { type, args, resolve } } }
-- Returns a schema object used by execute().
function M.schema(def)
	local s = { types = {} }
	for type_name, fields in pairs(def) do
		local t = { name = type_name, fields = {} }
		for field_name, field_def in pairs(fields) do
			-- field_def can be { type, args, resolve } or just { type }
			if type(field_def) == "table" then
				local fd = field_def
				t.fields[field_name] = {
					type    = fd.type,
					args    = fd.args or {},
					resolve = fd.resolve,
				}
			end
		end
		s.types[type_name] = t
	end
	return s
end

-- ── Type helpers ──────────────────────────────────────────────────────────────

-- Parse a type string like "String", "[Post]", "[Post!]!", "ID!"
local function parse_type_string(s)
	if not s then return { named = "unknown", list = false, required = false } end
	local required = false
	if sub(s, -1) == "!" then s = sub(s, 1, -2); required = true end
	if sub(s, 1, 1) == "[" and sub(s, -1) == "]" then
		local inner = sub(s, 2, -2)
		local item_required = false
		if sub(inner, -1) == "!" then inner = sub(inner, 1, -2); item_required = true end
		return { named = inner, list = true, required = required, item_required = item_required }
	end
	return { named = s, list = false, required = required }
end

-- ── Executor ──────────────────────────────────────────────────────────────────

-- Resolve a variable from the variable map
local function resolve_value(val, variables)
	if not val then return nil end
	if val.kind == "Variable" then
		if not variables then return nil end
		return variables[val.name]
	elseif val.kind == "IntValue" then
		return tonumber(val.value)
	elseif val.kind == "FloatValue" then
		return tonumber(val.value)
	elseif val.kind == "StringValue" then
		return val.value
	elseif val.kind == "BooleanValue" then
		return val.value
	elseif val.kind == "NullValue" then
		return nil
	elseif val.kind == "EnumValue" then
		return val.value
	elseif val.kind == "ListValue" then
		local result = {}
		for i, v in ipairs(val.values) do
			result[i] = resolve_value(v, variables)
		end
		return result
	elseif val.kind == "ObjectValue" then
		local result = {}
		for _, f in ipairs(val.fields) do
			result[f.name] = resolve_value(f.value, variables)
		end
		return result
	end
	return nil
end

-- Collect arguments from AST into a Lua table
local function collect_args(arg_nodes, variables)
	local args = {}
	if not arg_nodes then return args end
	for _, arg in ipairs(arg_nodes) do
		args[arg.name] = resolve_value(arg.value, variables)
	end
	return args
end

-- Build a fragment map from document definitions
local function collect_fragments(definitions)
	local frags = {}
	for _, def in ipairs(definitions) do
		if def.kind == "FragmentDefinition" then
			frags[def.name] = def
		end
	end
	return frags
end

-- Execute a selection set against an object value
local function execute_selection_set(sel_set, obj, type_name, schema, variables, fragments, errors)
	if not sel_set then return {} end
	local result = {}

	for _, sel in ipairs(sel_set.selections) do
		if sel.kind == "Field" then
			local field_name = sel.name
			local response_key = sel.alias or field_name

			-- __typename introspection
			if field_name == "__typename" then
				result[response_key] = type_name
			else
				-- Look up field in schema type
				local schema_type = schema.types[type_name]
				local field_def = schema_type and schema_type.fields[field_name]

				if not field_def then
					errors[#errors + 1] = {
						message = ('field "%s" not found on type "%s"'):format(field_name, type_name or ""),
						locations = {},
					}
					result[response_key] = nil
				else
					-- Collect args
					local args = collect_args(sel.arguments, variables)

					-- Resolve field value
					local field_value
					if field_def.resolve then
						-- Custom resolver
						local ok, val_or_err = pcall(field_def.resolve, obj, args, variables and variables.__context or nil)
						if not ok then
							errors[#errors + 1] = {
								message = tostring(val_or_err),
								locations = {},
							}
							result[response_key] = nil
						else
							field_value = val_or_err
						end
					else
						-- Default resolver: obj[field_name]
						if type(obj) == "table" then
							field_value = obj[field_name]
						end
					end

					-- Recurse into sub-selection if there is one
					if sel.selectionSet and field_value ~= nil then
						local inner_type = parse_type_string(field_def.type)
						if inner_type.list and type(field_value) == "table" then
							-- List: resolve each element
							local list_result = {}
							for i, item in ipairs(field_value) do
								list_result[i] = execute_selection_set(
									sel.selectionSet, item, inner_type.named,
									schema, variables, fragments, errors)
							end
							result[response_key] = list_result
						else
							result[response_key] = execute_selection_set(
								sel.selectionSet, field_value, inner_type.named,
								schema, variables, fragments, errors)
						end
					elseif sel.selectionSet and field_value == nil then
						result[response_key] = nil
					elseif not sel.selectionSet then
						-- Leaf: return scalar value
						if field_def.type and parse_type_string(field_def.type).list and type(field_value) == "table" then
							result[response_key] = field_value
						else
							result[response_key] = field_value
						end
					end
				end
			end

		elseif sel.kind == "FragmentSpread" then
			local frag = fragments[sel.name]
			if not frag then
				errors[#errors + 1] = {
					message = ('unknown fragment "%s"'):format(sel.name),
					locations = {},
				}
			else
				local frag_result = execute_selection_set(
					frag.selectionSet, obj, type_name, schema, variables, fragments, errors)
				for k, v in pairs(frag_result) do
					result[k] = v
				end
			end

		elseif sel.kind == "InlineFragment" then
			-- Check type condition
			local applies = true
			if sel.typeCondition then
				applies = (sel.typeCondition.name == type_name)
			end
			if applies then
				local frag_result = execute_selection_set(
					sel.selectionSet, obj, type_name, schema, variables, fragments, errors)
				for k, v in pairs(frag_result) do
					result[k] = v
				end
			end
		end
	end

	return result
end

-- Execute a single operation
local function execute_operation(op, schema, variables, context, fragments, errors)
	-- Determine root type name
	local root_type_name
	if op.operation == "query" then
		root_type_name = "Query"
	elseif op.operation == "mutation" then
		root_type_name = "Mutation"
	elseif op.operation == "subscription" then
		root_type_name = "Subscription"
	end

	-- Inject context into variables table for resolver access
	local vars_with_ctx = variables or {}
	vars_with_ctx.__context = context

	-- Root object is a synthetic empty table; resolvers look things up via context
	local root = {}
	local data = execute_selection_set(
		op.selectionSet, root, root_type_name, schema, vars_with_ctx, fragments, errors)
	return data
end

-- Main execute entry point
function M.execute(schema, query, opts)
	opts = opts or {}
	local variables = opts.variables or {}
	local context = opts.context
	local operation_name = opts.operationName

	-- Parse the query
	local doc, err = M.parse(query)
	if not doc then
		return { data = nil, errors = {{ message = err or "parse error", locations = {} }} }
	end

	-- Find the target operation
	local op = nil
	local fragments = collect_fragments(doc.definitions)
	for _, def in ipairs(doc.definitions) do
		if def.kind == "OperationDefinition" then
			if not operation_name or def.name == operation_name then
				op = def
				break
			end
		end
	end
	if not op then
		return { data = nil, errors = {{ message = "no operation found", locations = {} }} }
	end

	-- Execute
	local errors = {}
	local data = execute_operation(op, schema, variables, context, fragments, errors)

	return {
		data   = data,
		errors = #errors > 0 and errors or nil,
	}
end

return M
