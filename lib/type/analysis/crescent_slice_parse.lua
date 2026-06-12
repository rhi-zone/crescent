-- lib/type/analysis/crescent_slice_parse.lua
--
-- The parser-frontend ADAPTER for `crescent.slice.v1`
-- (docs/agnostic-static-analysis-crescent-slice.md §5, §8 Pass 2). It converts
-- Crescent/Lua source in v1's syntax subset into slice ARTIFACTS (syntax_tree
-- nodes) and OBSERVATIONS (`--:` / `--::` annotations), plus the alias
-- environment (`--::` aliases resolved to the portable Ty grammar, recursive
-- aliases → μ). It produces DATA the evidence methods consume; it does NOT pull
-- legacy checker semantics in (the static checker's arena/intern/solver
-- machinery is untouched — low coupling, per the project principle).
--
-- Scope is the v1 annotation type grammar ONLY (§5.1): primitives, literals,
-- functions `(P) -> R` incl. multi-return and vararg, records `{ f: T, ... }`,
-- index signatures `{ [K]: V }`, unions `A | B`, intersections `A & B`, named
-- aliases, recursive aliases → μ. The `...`-vs-indexer distinction is preserved
-- structurally (open `rows` vs an `indexer` node), per CLAUDE.md.
--
-- This module's primary, load-bearing export is the ANNOTATION TYPE PARSER
-- (`parse_type_ann`): a focused recursive-descent over the v1 type grammar that
-- yields an interned slice Ty. The expression/statement lowering
-- (`lower_*`) builds the node grammar of crescent_slice.lua. Parse errors are
-- returned as (nil, errmsg); the adapter never throws for malformed input.

local G = require("lib.type.analysis.slice_ty")
local TA = require("lib.type.analysis.slice_ty_arg")

local M = {}

-- ── Annotation type lexer ────────────────────────────────────────────────────
--
-- A tiny tokenizer over a single-line type annotation string (§9.3 finding 5:
-- `--::` declarations are single-line). Tokens: identifiers, string/number
-- literals, and the punctuation the v1 type grammar uses.

--:: TyTok = { kind: string, text: string }

-- Returns (toks, nil, nil) or (nil, errmsg, construct_tag | nil). The construct
-- tag classifies a recognizable out-of-subset lexeme (`$`-intrinsic) so the
-- survey histogram ranks it; nil for an ordinary lexer error.
--: (string) -> (TyTok[] | nil, string | nil, string | nil)
local function lex_type(src)
	local toks = {} --[[: TyTok[] ]]
	local i = 1 --: integer
	local n = #src
	while i <= n do
		local c = src:sub(i, i)
		if c == " " or c == "\t" then
			i = i + 1
		elseif c:match("[%a_]") then
			local j = i
			while j <= n and src:sub(j, j):match("[%w_]") do j = j + 1 end
			toks[#toks + 1] = { kind = "ident", text = src:sub(i, j - 1) }
			i = j
		elseif c:match("[%d]") or (c == "-" and src:sub(i + 1, i + 1):match("[%d]")) then
			local j = i
			if c == "-" then j = j + 1 end
			while j <= n and src:sub(j, j):match("[%d%.]") do j = j + 1 end
			toks[#toks + 1] = { kind = "number", text = src:sub(i, j - 1) }
			i = j
		elseif c == '"' or c == "'" then
			local q = c
			local j = i + 1
			while j <= n and src:sub(j, j) ~= q do j = j + 1 end
			if j > n then return nil, "unterminated string literal in type", nil end
			toks[#toks + 1] = { kind = "string", text = src:sub(i + 1, j - 1) }
			i = j + 1
		elseif src:sub(i, i + 1) == "->" then
			toks[#toks + 1] = { kind = "arrow", text = "->" }
			i = i + 2
		elseif src:sub(i, i + 2) == "..." then
			toks[#toks + 1] = { kind = "ellipsis", text = "..." }
			i = i + 3
		else
			local punct = "(){}[]|&,:?<>" --: string
			if punct:find(c, 1, true) then
				toks[#toks + 1] = { kind = c, text = c }
				i = i + 1
			elseif c == "$" then
				-- a `$`-intrinsic (type-level intrinsic: `$Require<T>`, `$PairsReturn`,
				-- …) — an out-of-subset construct (§1.4 type-expression forms).
				return nil, "type-level `$`-intrinsic outside v1", "intrinsic-dollar"
			else
				return nil, "unexpected character in type: '" .. c .. "'", nil
			end
		end
	end
	return toks
end

M.lex_type = lex_type

-- ── Annotation type parser ───────────────────────────────────────────────────
--
-- Recursive descent. `aliases` maps a named-type to its interned Ty (the `--::`
-- environment). A name not in `aliases` and not a primitive is an error UNLESS it
-- is the name currently being declared recursively (handled by the caller binding
-- a placeholder via the μ mechanism).
--
-- Grammar (precedence low→high): union (`|`) > inter (`&`) > postfix (`?`,
-- `[K]`) > atom. Functions `(P) -> R` are atoms beginning with `(`.

--:: AliasEnv = { [string]: Ty }

local PRIMS = {
	["nil"] = true, boolean = true, number = true, integer = true,
	string = true, ["function"] = true, unknown = true, never = true,
}

-- Names that are well-known type-grammar constructs OUTSIDE the v1 subset. When
-- the parser rejects an annotation, it classifies the blocking construct so the
-- survey (slice_survey.lua) can build a demand-ranked histogram. This is
-- error-reporting instrumentation ONLY — it never changes what the parser
-- ACCEPTS; an out-of-subset name still rejects, it is merely TAGGED on the way
-- out. (docs/agnostic-static-analysis-crescent-slice.md §1.4 deferral list.)
local OUT_OF_SUBSET_NAMES = {
	-- forbidden / absent value-or-lattice kinds (§1.4)
	["any"] = "any (forbidden)",
	["table"] = "bare-table (use a record/indexer)",
	["fn"] = "bare-fn-name (use `function` or `(P)->R`)",
	["cdata"] = "cdata",
	["userdata"] = "userdata",
	["thread"] = "thread",
	-- type-expression forms with no v1 constructor (§1.4)
	["typeof"] = "typeof",
	["keyof"] = "keyof",
}

-- Parser state is a closure over the token list and a cursor.
--: (TyTok[], AliasEnv) -> { parse: () -> (Ty | nil, string | nil, string | nil) }
local function new_type_parser(toks, aliases)
	local pos = 1 --: integer
	local err --: string | nil
	local construct --: string | nil

	--: () -> TyTok | nil
	local function peek() return toks[pos] end
	--: () -> nil
	local function bump() pos = pos + 1 end
	--: (string) -> boolean
	local function accept(kind)
		local t = toks[pos]
		if t and t.kind == kind then pos = pos + 1; return true end
		return false
	end

	local parse_union --[[: () -> Ty | nil ]]

	--: () -> Ty | nil
	local function fail(m) err = m; return nil end
	-- fail AND record the blocking out-of-subset construct tag (first one wins).
	--: (string, string) -> Ty | nil
	local function fail_c(m, c)
		if not construct then construct = c end
		err = m
		return nil
	end

	-- Parse a record/index-signature body after `{`. Distinguishes `{ [K]: V }`
	-- (index signature → indexer) from `{ f: T, ... }` (record, open if `...`).
	--: () -> Ty | nil
	local function parse_table_type()
		-- after the opening `{` is consumed.
		local fields = {} --[[: Field[] ]]
		local rows = "closed" --: string
		local idx_key --: Ty | nil
		local idx_val --: Ty | nil
		if accept("}") then return G.rec(fields, "closed") end
		while true do
			local t = peek()
			if not t then return fail("unterminated table type") end
			if t.kind == "ellipsis" then
				bump()
				rows = "open"
				if not accept("}") then return fail("`...` must be the last table entry") end
				break
			elseif t.kind == "[" then
				-- index signature `[K]: V`
				bump()
				local kty = parse_union()
				if not kty then return nil end
				if not accept("]") then return fail("expected `]` in index signature") end
				if not accept(":") then return fail("expected `:` in index signature") end
				local vty = parse_union()
				if not vty then return nil end
				idx_key = kty
				idx_val = vty
			elseif t.kind == "ident" or t.kind == "string" then
				-- named field `key: T` (key may be quoted)
				bump()
				local key = t.text
				local optional = false --: boolean
				if accept("?") then optional = true end
				if not accept(":") then return fail("expected `:` after field name '" .. key .. "'") end
				local fty = parse_union()
				if not fty then return nil end
				fields[#fields + 1] = { key = key, ty = fty, optional = optional, readonly = false }
			else
				return fail("unexpected token in table type: '" .. t.text .. "'")
			end
			if accept("}") then break end
			if not accept(",") then return fail("expected `,` or `}` in table type") end
			if accept("}") then break end
		end
		if idx_key and idx_val then
			if #fields == 0 then return G.indexer(idx_key, idx_val) end
			return G.rec_with_indexer(fields, rows, { key = idx_key, val = idx_val })
		end
		return G.rec(fields, rows)
	end

	-- Parse a parameter/return tuple inside `(...)`. Returns { fixed, vararg }.
	--: () -> { fixed: Ty[], vararg?: Ty } | nil
	local function parse_tuple()
		local fixed = {} --[[: Ty[] ]]
		local vararg --: Ty | nil
		if accept(")") then return { fixed = fixed } end
		while true do
			if accept("ellipsis") then
				local vt = parse_union()
				if not vt then return nil end
				vararg = vt
				if not accept(")") then fail("expected `)` after vararg"); return nil end
				break
			end
			-- NAMED PARAMETER (`name: T`, incl. `self: T`) — an out-of-subset form:
			-- v1 params are positional. Detect `ident :` lookahead and tag.
			do
				local t0, t1 = toks[pos], toks[pos + 1]
				if t0 and t0.kind == "ident" and t1 and t1.kind == ":" then
					if t0.text == "self" then
						fail_c("named/self parameter outside v1: '" .. t0.text .. ":'", "named-param-self")
						return nil
					end
					fail_c("named parameter outside v1: '" .. t0.text .. ":'", "named-param")
					return nil
				end
			end
			local ty = parse_union()
			if not ty then return nil end
			fixed[#fixed + 1] = ty
			if accept(")") then break end
			if not accept(",") then fail("expected `,` or `)` in tuple"); return nil end
		end
		if vararg ~= nil then return { fixed = fixed, vararg = vararg } end
		return { fixed = fixed }
	end

	-- Atom: primitives, literals, named aliases, `( ... )` (group / function
	-- params), `{ ... }` table types.
	--: () -> Ty | nil
	local function parse_atom()
		local t = peek()
		if not t then return fail("unexpected end of type") end
		if t.kind == "number" then
			bump()
			local num = tonumber(t.text) or 0 --: number
			if t.text:find("%.") then return G.lit_num(num) end
			local li = G.lit_int(num)
			if not li then return fail("integer literal in type is not integer-valued: '" .. t.text .. "'") end
			return li
		end
		if t.kind == "string" then
			bump()
			return G.lit_str(t.text)
		end
		if t.kind == "{" then
			bump()
			return parse_table_type()
		end
		if t.kind == "(" then
			bump()
			local tup = parse_tuple()
			if not tup then return nil end
			-- a `( ... ) -> R` function, or a parenthesized group / return tuple.
			if accept("arrow") then
				-- return: either `( ... )` tuple or a single type.
				local rtup --: { fixed: Ty[], vararg?: Ty } | nil
				if accept("(") then
					rtup = parse_tuple()
				else
					local rt = parse_union()
					if not rt then return nil end
					rtup = { fixed = { rt } }
				end
				if not rtup then return nil end
				return G.fn(tup, rtup)
			end
			-- a parenthesized group: single element, or a bare return-tuple used as
			-- a type is not valid outside a function; treat single as the group.
			if #tup.fixed == 1 and not tup.vararg then return tup.fixed[1] end
			return fail("a multi-element tuple is only valid as function params/return")
		end
		if t.kind == "ident" then
			bump()
			local name = t.text
			if PRIMS[name] then
				if name == "nil" then return G.nil_() end
				if name == "boolean" then return G.boolean() end
				if name == "number" then return G.number() end
				if name == "integer" then return G.integer() end
				if name == "string" then return G.string() end
				if name == "function" then return G.func() end
				if name == "unknown" then return G.unknown() end
				return G.never()
			end
			if name == "true" then return G.lit_bool(true) end
			if name == "false" then return G.lit_bool(false) end
			-- GENERIC APPLICATION `Name<...>` — an out-of-subset form (no v1 type
			-- constructor for parametric instantiation in annotations, §1.4).
			if peek() and peek().kind == "<" then
				return fail_c("generic type application outside v1: '" .. name .. "<...>'", "generic-application")
			end
			local a = aliases[name]
			if a then return a end
			local oos = OUT_OF_SUBSET_NAMES[name]
			if oos then
				return fail_c("type construct outside v1: " .. oos, oos)
			end
			return fail_c("unknown type name: '" .. name .. "'", "unknown-type-name:" .. name)
		end
		return fail("unexpected token in type: '" .. t.text .. "'")
	end

	-- Postfix `?` makes `T?` = `T | nil`.
	--: () -> Ty | nil
	local function parse_postfix()
		local a = parse_atom()
		if not a then return nil end
		while accept("?") do a = G.union({ a, G.nil_() }) end
		-- `T[]` ARRAY SHORTHAND — an out-of-subset form. v1 spells arrays as the
		-- index signature `{ [integer]: T }`, not `T[]` (§5.1). Detect `[ ]` (empty
		-- brackets) after a type and tag it.
		local t0, t1 = toks[pos], toks[pos + 1]
		if t0 and t0.kind == "[" and t1 and t1.kind == "]" then
			return fail_c("`T[]` array shorthand outside v1 (use `{ [integer]: T }`)", "array-postfix")
		end
		return a
	end

	-- Intersection: `A & B`.
	--: () -> Ty | nil
	local function parse_inter()
		local a = parse_postfix()
		if not a then return nil end
		if peek() and peek().kind == "&" then
			local members = { a } --[[: Ty[] ]]
			while accept("&") do
				local b = parse_postfix()
				if not b then return nil end
				members[#members + 1] = b
			end
			return G.inter(members)
		end
		return a
	end

	-- Union: `A | B`.
	--: () -> Ty | nil
	parse_union = function()
		local a = parse_inter()
		if not a then return nil end
		if peek() and peek().kind == "|" then
			local members = { a } --[[: Ty[] ]]
			while accept("|") do
				local b = parse_inter()
				if not b then return nil end
				members[#members + 1] = b
			end
			return G.union(members)
		end
		return a
	end

	return {
		--: () -> (Ty | nil, string | nil, string | nil)
		parse = function()
			local r = parse_union()
			if not r then return nil, err or "type parse failed", construct end
			if pos <= #toks then
				-- trailing tokens: classify a few recognizable out-of-subset tails.
				local t = toks[pos]
				if t and t.kind == "<" then
					return nil, "trailing tokens in type (generic application)", "generic-application"
				end
				if t and t.kind == ":" then
					return nil, "trailing tokens in type (named element)", "named-param"
				end
				return nil, "trailing tokens in type", "trailing-tokens"
			end
			return r
		end,
	}
end

-- Parse a v1 type annotation string into an interned Ty, given the alias
-- environment. Returns (Ty, nil) or (nil, errmsg).
-- Returns (Ty, nil, nil) on success, or (nil, errmsg, construct_tag | nil) on
-- failure. `construct_tag` is the out-of-subset construct that blocked the parse
-- (named-param, generic-application, cdata, …) when the failure is a recognizable
-- v1-subset boundary; nil for an ordinary malformed-annotation error.
--: (string, AliasEnv) -> (Ty | nil, string | nil, string | nil)
function M.parse_type_ann(src, aliases)
	local toks, lerr, lconstruct = lex_type(src)
	if not toks then return nil, lerr, lconstruct end
	local p = new_type_parser(toks, aliases or {})
	return p.parse()
end

-- ── Alias declarations (`--:: Name = T`, incl. recursive → μ) ─────────────────
--
-- A `--::` declaration `Name = <type>` adds `Name` to the alias environment. A
-- RECURSIVE alias — one whose body references `Name` — is parsed as an
-- equirecursive μ: we bind `Name` to the μ binder's placeholder while parsing the
-- body, so a self-reference resolves to the bound variable (§5.1). Whether the
-- alias is recursive is detected by a textual occurrence of `Name` in the body;
-- non-recursive aliases bind directly.
--
-- Returns the updated alias environment (mutated in place and returned), or
-- (nil, errmsg).

-- A name occurs in `body` as a standalone identifier token?
--: (string, string) -> boolean
local function name_occurs(body, name)
	for tok in body:gmatch("[%a_][%w_]*") do
		if tok == name then return true end
	end
	return false
end

--: (AliasEnv, string, string) -> (AliasEnv | nil, string | nil, string | nil)
function M.declare_alias(aliases, name, body)
	if name_occurs(body, name) then
		-- recursive: bind Name to the μ binder while parsing the body.
		local perr --: string | nil
		local pconstruct --: string | nil
		local mu = G.mu(name, function(placeholder)
			local prev = aliases[name]
			aliases[name] = placeholder
			local ty, e, c = M.parse_type_ann(body, aliases)
			aliases[name] = prev
			if not ty then perr = e; pconstruct = c; return G.never() end
			return ty
		end)
		if perr then return nil, perr, pconstruct end
		-- well-formedness is a hard precondition of admitting an alias (audit round 1,
		-- finding 1): a non-contractive recursive alias (`T = number | T`, `T = T?`,
		-- `T = T`) reads as top in the subtype relation and must be rejected at the
		-- declaration site, per the (nil, errmsg) convention — never silently bound.
		if not TA.well_formed(mu) then
			return nil, "recursive alias '" .. name .. "' is not well-formed: its variable occurs unguarded (non-contractive μ)", nil
		end
		aliases[name] = mu
		return aliases
	end
	local ty, e, c = M.parse_type_ann(body, aliases)
	if not ty then return nil, e, c end
	if not TA.well_formed(ty) then
		return nil, "alias '" .. name .. "' is not well-formed (non-contractive or degenerate μ)", nil
	end
	aliases[name] = ty
	return aliases
end

-- ── Annotation line scanning (`--:` / `--::`) ────────────────────────────────
--
-- Pull annotation directives out of a source line. Returns one of:
--   { kind = "alias", name, body }   for `--:: Name = T`
--   { kind = "sig", body }           for `--: T`   (preceding-line signature)
--   nil                              if the line carries no annotation directive
--
--:: AnnDirective = { kind: string, name?: string, body?: string }

--: (string) -> AnnDirective | nil
function M.scan_annotation(line)
	-- `--::` alias declaration.
	local adecl = line:match("^%s*%-%-::%s*(.+)$")
	if adecl then
		local name, body = adecl:match("^([%a_][%w_]*)%s*=%s*(.+)$")
		if name then return { kind = "alias", name = name, body = body } end
		-- a `--::` form without `=` (e.g. `declare`/`augment`) is outside v1.
		return nil
	end
	-- `--:` signature (single colon, not `--::`).
	local sig = line:match("^%s*%-%-:%s+(.+)$")
	if sig and not line:match("^%s*%-%-::") then
		return { kind = "sig", body = sig }
	end
	return nil
end

-- ── Guard recognition (the flow-narrowing layer's frontend, §4.1) ────────────
--
-- `recognize_guard(expr)` maps an if/elseif/while test EXPRESSION node into a
-- portable Guard node (slice_narrow.lua's grammar) that the `narrow_guard`
-- evidence method consumes — or nil if the expression is not one of the five v1
-- guard forms (or their and/or/not composition). Guards ride artifacts as
-- portable data, so each comparison literal is emitted as a PTy (TA.encode).
--
-- The expression node grammar this recognizer reads (a small comparison subset of
-- the slice node grammar — the adapter lowers if/elseif tests into it):
--   { t="var",  name }
--   { t="lit",  lit, v }                                 -- as in crescent_slice.lua
--   { t="index", obj, field }                            -- x.field (static key)
--   { t="call", fn={t="var",name="type"}, args={ x } }   -- type(x)
--   { t="cmp",  op="eq"|"ne", left, right }              -- a == b / a ~= b
--   { t="andor", op="and"|"or"|"not", left, right? }     -- composition
--
-- Recognized forms (target variable is the var operand):
--   truthy   : a bare `var`           → { g="truthy", var }
--   nil-eq   : `var == nil` / `~= nil` → { g="nil_eq", var, eq }
--   type-eq  : `type(var) == "string"` → { g="type_eq", var, tyname }
--   lit-eq   : `var == <literal>`      → { g="lit_eq", var, lit=PTy }
--   tag-eq   : `var.field == <literal>`→ { g="tag_eq", var, field, lit=PTy }
--   not g    : `not <guard>`           → { g="not", inner }
--   g and h  : `<guard> and <guard>`   → { g="and", left, right }
--   g or h   : `<guard> or <guard>`    → { g="or", left, right }
-- Either operand of a comparison may be the variable (the literal side is
-- symmetric: `0 == x` recognizes the same as `x == 0`).

-- A literal expression node → its singleton Ty (for PTy emission), or nil.
--: (unknown) -> Ty | nil
local function lit_node_to_ty(node)
	if type(node) ~= "table" then return nil end
	if node.t ~= "lit" then return nil end
	local lit, v = node.lit, node.v
	if lit == "nil" then return G.nil_() end
	if lit == "bool" and type(v) == "boolean" then return G.lit_bool(v) end
	if lit == "int" and type(v) == "number" then return (G.lit_int(v)) end
	if lit == "num" and type(v) == "number" then return G.lit_num(v) end
	if lit == "str" and type(v) == "string" then return G.lit_str(v) end
	return nil
end

-- Is `node` the literal `nil`?
--: (unknown) -> boolean
local function is_nil_lit(node)
	if type(node) ~= "table" then return false end
	if node.t ~= "lit" then return false end
	return node.lit == "nil"
end

-- A `type(x)` call → the variable name x, or nil.
--: (unknown) -> string | nil
local function type_call_var(node)
	if type(node) ~= "table" then return nil end
	if node.t ~= "call" then return nil end
	local fn = node.fn
	if type(fn) ~= "table" then return nil end
	if fn.t ~= "var" or fn.name ~= "type" then return nil end
	local args = node.args
	if type(args) ~= "table" then return nil end
	if #args ~= 1 then return nil end
	local a = args[1]
	if type(a) ~= "table" then return nil end
	if a.t ~= "var" then return nil end
	local nm = a.name
	if type(nm) ~= "string" then return nil end
	return nm
end

local recognize_guard --[[: (unknown) -> unknown ]]

-- Recognize a comparison `op` (eq/ne) of `lhs`/`rhs` as an atomic guard, or nil.
-- `eq_truthy` is true when the comparison being TRUE makes the predicate hold
-- (`==` for the truthy reading; `~=` flips it to a `not` of the `==` guard).
--: (unknown, unknown, boolean) -> unknown
local function recognize_cmp(lhs, rhs, is_eq)
	-- normalize so the "interesting" operand (var / index / type-call) is `a`.
	--: (unknown) -> integer
	local function rank(n)
		if type(n) ~= "table" then return 0 end
		if n.t == "var" or n.t == "index" or n.t == "call" then return 2 end
		return 1 -- literal
	end
	local a, b = lhs, rhs
	if rank(b) > rank(a) then a, b = rhs, lhs end

	-- `type(x) == "string"` (b must be a string literal naming the runtime type).
	local tv = type_call_var(a)
	if tv and type(b) == "table" and b.t == "lit" and b.lit == "str" and type(b.v) == "string" then
		local g = { g = "type_eq", var = tv, tyname = b.v } --[[: unknown ]]
		if is_eq then return g end
		return { g = "not", inner = g }
	end

	-- `x == nil` / `x ~= nil` (nil-eq: the one form whose falsy branch is positive).
	if type(a) == "table" and a.t == "var" and type(a.name) == "string" and is_nil_lit(b) then
		-- is_eq=true ⇒ `x == nil` ⇒ nil_eq with eq=true; is_eq=false ⇒ `x ~= nil`.
		return { g = "nil_eq", var = a.name, eq = is_eq }
	end

	-- `x.field == <literal>` (tag-field discriminant).
	if type(a) == "table" and a.t == "index" and type(a.field) == "string" then
		local obj = a.obj
		if type(obj) == "table" and obj.t == "var" and type(obj.name) == "string" then
			local lit = lit_node_to_ty(b)
			if lit then
				local g = { g = "tag_eq", var = obj.name, field = a.field, lit = TA.encode(lit) } --[[: unknown ]]
				if is_eq then return g end
				return { g = "not", inner = g }
			end
		end
	end

	-- `x == <literal>` (literal-eq singleton narrowing).
	if type(a) == "table" and a.t == "var" and type(a.name) == "string" then
		local lit = lit_node_to_ty(b)
		if lit and not is_nil_lit(b) then
			local g = { g = "lit_eq", var = a.name, lit = TA.encode(lit) } --[[: unknown ]]
			if is_eq then return g end
			return { g = "not", inner = g }
		end
	end

	return nil
end

--: (unknown) -> unknown
recognize_guard = function(expr)
	if type(expr) ~= "table" then return nil end
	local t = expr.t
	if t == "var" and type(expr.name) == "string" then
		return { g = "truthy", var = expr.name }
	end
	if t == "cmp" then
		local op = expr.op
		if op == "eq" then return recognize_cmp(expr.left, expr.right, true) end
		if op == "ne" then return recognize_cmp(expr.left, expr.right, false) end
		return nil
	end
	if t == "andor" then
		local op = expr.op
		if op == "not" then
			local inner = recognize_guard(expr.left)
			if not inner then return nil end
			return { g = "not", inner = inner }
		end
		if op == "and" or op == "or" then
			local l = recognize_guard(expr.left)
			local r = recognize_guard(expr.right)
			if not l or not r then return nil end
			return { g = op, left = l, right = r }
		end
		return nil
	end
	return nil
end

M.recognize_guard = recognize_guard

return M
