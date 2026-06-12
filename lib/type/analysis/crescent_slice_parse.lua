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
	local parse_return --[[: () -> { fixed: Ty[], vararg?: Ty } | nil ]]

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
		-- `{ T }` LIST SHORTHAND (§6.5.4) — a single BARE type (no `key:`, no `[K]:`,
		-- no `...`) followed by `}` desugars to `{ [integer]: T }` = the IDENTICAL
		-- target as `T[]` (§6.5.3): one canonical list form. Detect it by lookahead:
		-- the body does NOT start with `[` or `...`, and is NOT an `ident`/`string`
		-- immediately followed by `:` or `?` (which would be a named field).
		do
			local t0, t1 = toks[pos], toks[pos + 1]
			local starts_field = t0 ~= nil and (t0.kind == "ident" or t0.kind == "string")
				and t1 ~= nil and (t1.kind == ":" or t1.kind == "?")
			local starts_index = t0 ~= nil and (t0.kind == "[" or t0.kind == "ellipsis")
			if t0 ~= nil and not starts_field and not starts_index then
				local elem = parse_union()
				if not elem then return nil end
				if accept("}") then
					-- single bare type → list. (A multi-element `{ A, B }` is rejected:
					-- not a record, not a v1 tuple-type — tuples live only in fn
					-- param/return position, §6.5.4.)
					return G.indexer(G.integer(), elem)
				end
				return fail("`{ T }` list shorthand must be a single type; `{ A, B }` is not a v1 table type")
			end
		end
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

	-- Parse a parameter/return tuple inside `(...)`. Returns { fixed, vararg, names }.
	-- NAMED PARAMETERS (`name: T`, incl. `self: T`) are now IN v1 (§6.5.1/§6.5.2):
	-- the name rides `names` (positional, parallel to `fixed`) and is interner-
	-- invisible — subtyping ignores it. `self` is an ordinary named first param,
	-- no special case. A slot may be named or bare; a bare slot's name is nil.
	--: () -> { fixed: Ty[], vararg?: Ty, names?: { [integer]: string | nil } } | nil
	local function parse_tuple()
		local fixed = {} --[[: Ty[] ]]
		local names = {} --[[: { [integer]: string | nil } ]]
		local any_name = false --: boolean
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
			-- named parameter `name: T`: consume `ident :` then the type. Disambiguate
			-- from a record-type atom `{...}` or a grouped type — a leading `ident`
			-- directly followed by `:` is a parameter name (a bare type never has a
			-- top-level `:` here).
			local pname --: string | nil
			do
				local t0, t1 = toks[pos], toks[pos + 1]
				if t0 and t0.kind == "ident" and t1 and t1.kind == ":" then
					pname = t0.text
					bump() -- ident
					bump() -- ':'
					any_name = true
				end
			end
			local ty = parse_union()
			if not ty then return nil end
			fixed[#fixed + 1] = ty
			names[#fixed] = pname
			if accept(")") then break end
			if not accept(",") then fail("expected `,` or `)` in tuple"); return nil end
		end
		local out = { fixed = fixed } --[[: { fixed: Ty[], vararg?: Ty, names?: { [integer]: string | nil } } ]]
		if vararg ~= nil then out.vararg = vararg end
		if any_name then out.names = names end
		return out
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
				local rtup = parse_return()
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
		-- `T[]` ARRAY SHORTHAND (§6.5.3) — desugars to `{ [integer]: T }` =
		-- `indexer(integer, T)`, the single canonical array form post-parse. `T[][]`
		-- nests. This is pure grammar sugar; no new constructor, no subtype rule.
		while true do
			local t0, t1 = toks[pos], toks[pos + 1]
			if t0 and t0.kind == "[" and t1 and t1.kind == "]" then
				bump() -- '['
				bump() -- ']'
				a = G.indexer(G.integer(), a)
			else
				break
			end
		end
		-- a `?` may also follow the array postfix (`T[]?`).
		while accept("?") do a = G.union({ a, G.nil_() }) end
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

	-- Parse a function RETURN position (after `->`). This is the one place a
	-- multi-element tuple may appear as a UNION MEMBER (§6.5.5): the value-or-error
	-- idiom `(A, B) | (nil, string)`. A return is a `|`-separated list of return
	-- MEMBERS; each member is either a parenthesized return-shape `( T1, T2, ... )`
	-- (≥2 elements ⇒ a `tuple`; exactly 1 ⇒ that type; 0 ⇒ the empty `()` return)
	-- or a bare type (`parse_inter`, so the member binds tighter than the `|`).
	--
	-- A single member that is a bare multi-element parenthesized tuple keeps the
	-- legacy simple multi-return shape `{ fixed = {T1, T2} }` (so existing call-site
	-- slot inference is unchanged). Any union of members collapses to a single
	-- return value `{ fixed = { union([...]) } }` whose members are tuples/types.
	--:: RetMember = { is_simple: boolean, tup?: { fixed: Ty[], vararg?: Ty, names?: { [integer]: string | nil } }, ty?: Ty }
	--: () -> RetMember | nil
	local function parse_return_member()
		-- a parenthesized return-shape.
		if accept("(") then
			local tup = parse_tuple()
			if not tup then return nil end
			-- normalize: 1 fixed, no vararg ⇒ the element itself; else a tuple/empty.
			if #tup.fixed == 1 and not tup.vararg then
				local only = tup.fixed[1] --[[: Ty ]]
				return { is_simple = false, ty = only } --[[: RetMember ]]
			end
			return { is_simple = true, tup = tup } --[[: RetMember ]]
		end
		local t = parse_inter()
		if not t then return nil end
		return { is_simple = false, ty = t } --[[: RetMember ]]
	end

	--: () -> { fixed: Ty[], vararg?: Ty } | nil
	parse_return = function()
		local first = parse_return_member()
		if not first then return nil end
		-- single member, no `|`: keep the legacy shape (a return position carries no
		-- parameter names, so drop any `names` the tuple parser attached).
		if not (peek() and peek().kind == "|") then
			local ftup = first.tup
			if first.is_simple and ftup ~= nil then
				local out = { fixed = ftup.fixed } --[[: { fixed: Ty[], vararg?: Ty } ]]
				local fv = ftup.vararg
				if fv ~= nil then out.vararg = fv end
				return out
			end
			local ty0 = first.ty or G.never() --[[: Ty ]]
			return { fixed = { ty0 } }
		end
		-- a union of return members: each member becomes a Ty (a multi-element tuple
		-- member is the `tuple` constructor), unioned into one return value.
		--: (RetMember) -> Ty
		local function member_ty(m)
			if m.is_simple and m.tup ~= nil then
				local tp = m.tup
				return G.tuple(tp.fixed, tp.vararg)
			end
			return m.ty or G.never()
		end
		local members = { member_ty(first) } --[[: Ty[] ]]
		while accept("|") do
			local m = parse_return_member()
			if not m then return nil end
			members[#members + 1] = member_ty(m)
		end
		return { fixed = { G.union(members) } }
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

-- ── Dependency-ordered batch alias declaration (forward-sibling refs, §6.12) ──
--
-- `scan_source` / the cross-module import pass declare a file's `--::` aliases
-- ONE AT A TIME in SOURCE order. That resolves a backward reference (a later alias
-- naming an earlier one) but FAILS a FORWARD-sibling reference — an alias whose
-- body names a sibling declared LATER in the same batch (`server_socket.accept ->
-- server_client`, `Expr = ExprCall | ...` with `ExprCall` below it). Measured
-- demand: 63 pure-forward (acyclic) references across 16 `lib/` files (the §9.8 /
-- §9.11 two-phase deferral's now-fired trigger).
--
-- THE DERIVED WHOLE (no special-casing). Source order is just ONE valid order; the
-- strictly-correct generalization is to declare each alias AFTER the siblings it
-- references — a topological order over the intra-batch dependency graph. This is
-- pure graph topology, not a name-keyed handler: an acyclic dependency set is
-- reordered so every forward reference resolves.
--
-- A GENUINE cycle (a mutually-recursive family `A` body names `B`, `B` body names
-- `A`) is no longer left to error: it is resolved at DECLARATION time by BEKIĆ
-- ELABORATION into nested single-binder μ (§6.13, increment 9). Bekić's theorem
-- says a system of simultaneous recursive equations reduces to nested single
-- fixpoints — so the EXISTING single-binder μ suffices with no grammar, codec, or
-- subtype-relation change. The SCCs of the dependency graph ARE the Bekić families;
-- each member elaborates to a closed nested-μ Ty (see `elaborate_family`). The de
-- Bruijn hash-consing makes alpha-equivalent unfoldings share a tid, so two
-- references to the same family member from different elaboration paths intern to
-- the SAME tid (equirecursive identity — the load-bearing property, verified in
-- increment-9.md). Self-reference (`A` names `A`) is a single-binder μ already
-- handled by `declare_alias`, so it is a size-1 SCC, not a family.
--
-- Topo order is computed by DFS post-order over the CONDENSATION (each SCC is one
-- node): independent aliases and acyclic dependencies keep source order (a batch
-- with no cycle reproduces today's byte-for-byte behavior); a cyclic SCC is
-- elaborated as a unit when its turn comes (after the acyclic siblings it depends
-- on are in scope).

--:: AliasDecl = { name: string, body: string }

-- The intra-batch dependency edges: input index → list of input indices it
-- references (sibling names in its body, EXCLUDING self — a self-reference is the
-- single-binder μ `declare_alias` already binds, so it is a size-1 SCC, never a
-- family edge). Shared by the order pass and the SCC pass so the edge set is
-- defined in exactly one place.
--: (AliasDecl[]) -> ({ [integer]: integer[] }, { [string]: integer })
local function batch_edges(decls)
	local n = #decls
	-- declared name → FIRST input index (source-order, first wins, matching the
	-- most-recent-wins shadowing rule which keeps the earliest slot).
	local idx_of = {} --[[: { [string]: integer } ]]
	for i = 1, n do
		local nm = decls[i].name
		if idx_of[nm] == nil then idx_of[nm] = i end
	end
	local deps = {} --[[: { [integer]: integer[] } ]]
	for i = 1, n do
		local d = decls[i]
		local seen = {} --[[: { [string]: boolean } ]]
		local list = {} --[[: integer[] ]]
		for tok in d.body:gmatch("[%a_][%w_]*") do
			local j = idx_of[tok]
			if j ~= nil and tok ~= d.name and not seen[tok] then
				seen[tok] = true
				list[#list + 1] = j
			end
		end
		deps[i] = list
	end
	return deps, idx_of
end

-- The pure DEPENDENCY ORDER over a batch of alias decls: returns the input indices
-- in an order where each alias follows the (acyclic) siblings it references. A
-- cycle member keeps its source position. Retained for callers that need a flat
-- order (the previous behavior); SCC-aware callers use `alias_decl_groups`.
--: (AliasDecl[]) -> integer[]
function M.alias_decl_order(decls)
	local n = #decls
	local deps = batch_edges(decls)
	-- DFS post-order with on-stack detection. `state`: nil=unvisited, 1=on-stack,
	-- 2=done. A back-edge (dependency currently on-stack) is not recursed through,
	-- so a cycle member keeps its source position; tie-break is source order.
	local order = {} --[[: integer[] ]]
	local state = {} --[[: { [integer]: integer } ]]
	--: (integer) -> nil
	local function visit(i)
		if state[i] == 2 then return end
		if state[i] == 1 then return end
		state[i] = 1
		local dl = deps[i]
		for k = 1, #dl do visit(dl[k]) end
		state[i] = 2
		order[#order + 1] = i
	end
	for i = 1, n do visit(i) end
	return order
end

-- The DEPENDENCY ORDER over the CONDENSATION: returns a list of GROUPS, each group
-- a list of input indices forming one strongly-connected component, the groups in
-- topological order (a group follows the acyclic siblings it depends on). A size-1
-- group is an ordinary alias (or a self-recursive single-binder μ); a size-≥2 group
-- is a Bekić family (`elaborate_family`). Computed by Tarjan's SCC algorithm, which
-- emits components in reverse-topological order; we reverse to dependency order.
-- Within a group, indices are kept in source order (the tie-break that reproduces
-- today's flat order for an acyclic batch). Self-edges are already excluded from
-- the edge set, so a non-cyclic batch yields all size-1 groups.
--: (AliasDecl[]) -> integer[][]
function M.alias_decl_groups(decls)
	local n = #decls
	local deps = batch_edges(decls)
	-- Tarjan's strongly-connected-components.
	local index = {} --[[: { [integer]: integer } ]]
	local low = {} --[[: { [integer]: integer } ]]
	local onstack = {} --[[: { [integer]: boolean } ]]
	local stack = {} --[[: integer[] ]]
	-- stack pointer (top index); avoids nil-assignment to clear the stack.
	local sp = 0 --: integer
	local counter = 0 --: integer
	local comps = {} --[[: integer[][] ]] -- reverse-topological order
	--: (integer) -> nil
	local function strong(v)
		counter = counter + 1
		index[v] = counter
		low[v] = counter
		sp = sp + 1
		stack[sp] = v
		onstack[v] = true
		local dl = deps[v]
		for k = 1, #dl do
			local w = dl[k]
			if index[w] == nil then
				strong(w)
				if low[w] < low[v] then low[v] = low[w] end
			elseif onstack[w] then
				if index[w] < low[v] then low[v] = index[w] end
			end
		end
		if low[v] == index[v] then
			local comp = {} --[[: integer[] ]]
			while true do
				local w = stack[sp]
				sp = sp - 1
				onstack[w] = false
				comp[#comp + 1] = w
				if w == v then break end
			end
			-- sort component by source order (ascending input index).
			for a = 2, #comp do
				local key = comp[a]
				local b = a - 1
				while b >= 1 and comp[b] > key do comp[b + 1] = comp[b]; b = b - 1 end
				comp[b + 1] = key
			end
			comps[#comps + 1] = comp
		end
	end
	for i = 1, n do if index[i] == nil then strong(i) end end
	-- Tarjan finishes a component only AFTER the components it depends on, so its
	-- natural emission order IS dependency order (a sink — no dependencies — is
	-- emitted first). That is exactly the declaration order we want, so no reversal.
	return comps
end

-- ── Bekić family elaboration (mutual-recursive alias families → nested μ, §6.13) ─
--
-- A mutually-recursive family (SCC of size ≥2) is resolved into nested single-
-- binder μ by Bekić's theorem: each member's solution is a μ over its body, with
-- every sibling reference replaced by ITS solution (recursively), and a reference
-- to a member whose binder is already OPEN (on the elaboration path) bound to that
-- binder's variable. This is a pure declaration-time elaboration — the grammar,
-- codec, and subtype relation are byte-for-byte unchanged.
--
-- `elaborate(name, open)` where `open` maps an in-scope (binder-open) family member
-- name to its placeholder tyvar:
--   - if `name` is already open → return its placeholder (the back-edge: bind to
--     the enclosing binder's variable);
--   - else build a μ binding `name`; inside, parse `name`'s body with an alias env
--     where every family member resolves via `elaborate(member, open ∪ {name})`
--     and non-family names resolve via `ambient`.
-- The recursion terminates: each step either hits an open member (base case) or
-- opens a new one, and the family is finite. The de Bruijn interner shares
-- alpha-equivalent unfoldings, so the same member reached via different paths
-- interns to the SAME tid (equirecursive identity).
--
-- A nested member binder may be VACUOUS (its variable never occurs — e.g.
-- `HamtInterior` is reachable only FROM `HamtNode`, never recursively from itself).
-- A non-occurring μ is ill-formed (`well_formed` (b)) and denotes its body, so it
-- COLLAPSES: drop the binder and shift free tyvars down a level (`G.shift_free`).
-- This collapse is also what keeps a STAR family (`Expr = A | B | … ` where each
-- member references only `Expr`) LINEAR rather than exponential — each member's
-- inner binder is vacuous and folds away, leaving one μ.
--
-- Returns (env | nil, per-name result map). The result map is keyed by member NAME
-- → { ok, err?, construct? }. On success each member is installed into `env`.

-- Does the de-Bruijn body reference its OWN (outermost) binder? Walks tracking the
-- binders crossed; a `tyvar(idx)` with idx == crossed + 1 is the binder itself.
--: (Ty) -> boolean
local function binder_occurs(body)
	local found = false --: boolean
	local walk --[[: (Ty, integer) -> nil ]]
	--: (Ty, integer) -> nil
	walk = function(ty, crossed)
		if found then return end
		local k = ty.kind
		if k == "tyvar" then
			if (ty.idx or 1) == crossed + 1 then found = true end
		elseif k == "mu" then
			walk(ty.body or G.never(), crossed + 1)
		elseif k == "union" or k == "inter" then
			local ms = ty.members or {}
			for i = 1, #ms do walk(ms[i], crossed) end
		elseif k == "rec" or k == "rec_with_indexer" then
			local fs = ty.fields or {}
			for i = 1, #fs do walk(fs[i].ty, crossed) end
			if k == "rec_with_indexer" then
				walk(ty.key or G.never(), crossed)
				walk(ty.val or G.never(), crossed)
			end
		elseif k == "indexer" then
			walk(ty.key or G.never(), crossed)
			walk(ty.val or G.never(), crossed)
		elseif k == "fn" then
			local p = ty.params or ({ fixed = {} } --[[: Params ]])
			local r = ty.ret or ({ fixed = {} } --[[: Ret ]])
			for i = 1, #p.fixed do walk(p.fixed[i], crossed) end
			if p.vararg ~= nil then walk(p.vararg, crossed) end
			for i = 1, #r.fixed do walk(r.fixed[i], crossed) end
			if r.vararg ~= nil then walk(r.vararg, crossed) end
		elseif k == "tuple" then
			local fx = ty.fixed or {}
			for i = 1, #fx do walk(fx[i], crossed) end
			if ty.vararg ~= nil then walk(ty.vararg, crossed) end
		end
	end
	walk(body, 0)
	return found
end

-- Elaborate one family member as a μ, collapsing a vacuous binder. `build` is the
-- μ body builder (`G.mu`'s callback). Returns the member's Ty.
--: (string, (Ty) -> Ty) -> Ty
local function mu_or_collapse(name, build)
	local probe = G.mu(name, build)
	-- probe is a μ; its body is de Bruijn over THIS binder (index 1). If the binder
	-- never occurs, the μ is vacuous: drop it and shift free tyvars down a level.
	local body = probe.body or G.never() --[[: Ty ]]
	if binder_occurs(body) then return probe end
	return G.shift_free(body, -1)
end

-- The Bekić family-size bound. Bekić elaboration nests one μ per member, so for a
-- DENSE family (many members cross-referencing many others) the elaborated TYPE is
-- exponentially large even though the elaboration does only O(N²) parse calls — the
-- distinct nestings do not share in the interner. The corpus's real families are all
-- SPARSE (stars/chains) and small: the max in-file family is N=12 (`v5_perf/types`,
-- a star that collapses to one μ); every acceptance-corpus family is N≤3. A family
-- ABOVE this bound is left as the honest forward-reference error (the pre-increment
-- behavior — these never resolved before either), so termination is guaranteed and
-- no real corpus family is affected. Un-defer for very-large dense families: an
-- iterative/vector-μ elaboration whose type size is polynomial (§9.21).
local BEKIC_FAMILY_MAX = 16 --: integer

-- Elaborate a mutual-recursive family into `env`. `members` is the family's decls
-- (in source order); `ambient` is the alias env for non-family names. Returns the
-- per-name result map; on a parse/well-formedness failure of any member, that
-- member's result carries the error (and the member is NOT installed). A family
-- larger than `BEKIC_FAMILY_MAX` is left as an honest forward-reference error.
--: (AliasEnv, AliasDecl[]) -> { [string]: { ok: boolean, err?: string, construct?: string } }
function M.elaborate_family(env, members)
	-- name → decl (first wins, matching the shadowing rule).
	local by_name = {} --[[: { [string]: AliasDecl } ]]
	local order = {} --[[: string[] ]]
	for i = 1, #members do
		local m = members[i]
		if by_name[m.name] == nil then
			by_name[m.name] = m
			order[#order + 1] = m.name
		end
	end
	-- Over-size families: keep the honest forward-reference error (termination bound).
	if #order > BEKIC_FAMILY_MAX then
		local results = {} --[[: { [string]: { ok: boolean, err?: string, construct?: string } } ]]
		for i = 1, #order do
			local name = order[i]
			if name ~= nil then
				results[name] = { ok = false, construct = "unknown-type-name",
					err = "mutual alias family of size " .. tostring(#order) .. " exceeds the Bekić elaboration bound ("
						.. tostring(BEKIC_FAMILY_MAX) .. "); forward reference left unresolved (§9.21)" }
			end
		end
		return results
	end
	-- For each member, the SET of family siblings it actually references in its body
	-- (so a body's elaboration touches only the members it names, not all N — the
	-- difference between linear and blow-up on a sparse family). Computed once.
	local refs_of = {} --[[: { [string]: string[] } ]]
	for i = 1, #order do
		local nm = order[i]
		if nm ~= nil then
			local decl = by_name[nm]
			local seen = {} --[[: { [string]: boolean } ]]
			local list = {} --[[: string[] ]]
			if decl ~= nil then
				for tok in decl.body:gmatch("[%a_][%w_]*") do
					if by_name[tok] ~= nil and not seen[tok] then
						seen[tok] = true
						list[#list + 1] = tok
					end
				end
			end
			refs_of[nm] = list
		end
	end

	local fail_name --: string | nil
	local fail_err --: string | nil
	local fail_construct --: string | nil
	-- Elaborate ONE member as the root of its own nested-μ solution. `open` maps an
	-- on-stack member name → its open binder's placeholder; a reference to an on-stack
	-- member is a true back-edge (the equirecursive cycle) and resolves to that
	-- placeholder. A reference to an off-stack member nests a fresh μ for it.
	--
	-- Termination + polynomiality: within ONE root elaboration, `seen` memoizes each
	-- member's sub-solution so it is built at most ONCE per root (placeholders held by
	-- a cached subtree stay sentinels until their binder closes, so reuse at a deeper
	-- nesting re-interns the de Bruijn indices correctly — `close_over` rewrites by
	-- depth at each enclosing μ). A body recurses only into the siblings it NAMES
	-- (`refs_of`). Per-root work is O(N · body-size); across N roots, O(N²). The
	-- elaborated TYPE can still be large for a dense family, which is why
	-- `BEKIC_FAMILY_MAX` bounds the family size up front.
	local root_elaborate --[[: (string) -> Ty ]]
	--: (string, { [string]: Ty | nil }, { [string]: Ty }) -> Ty
	local function elaborate(name, open, seen)
		local bound = open[name]
		if bound ~= nil then return bound end -- on-stack: back-edge to the open binder
		local hit = seen[name]
		if hit ~= nil then return hit end
		local result = mu_or_collapse(name, function(placeholder)
			open[name] = placeholder
			-- the alias env the parser sees for THIS member's body: only the siblings it
			-- references resolve (on-stack → their open binder, else a nested elaboration);
			-- everything else comes from ambient. A fresh table per body.
			local aenv = {} --[[: AliasEnv ]]
			for k, v in pairs(env) do aenv[k] = v end
			local rs = refs_of[name] or {}
			for r = 1, #rs do
				local fam = rs[r] --: string
				aenv[fam] = elaborate(fam, open, seen)
			end
			local decl = by_name[name] --[[: AliasDecl | nil ]]
			local dbody = decl ~= nil and decl.body or "never" --: string
			local ty, e, c = M.parse_type_ann(dbody, aenv)
			open[name] = nil
			if not ty then
				if fail_name == nil then fail_name = name; fail_err = e; fail_construct = c end
				return G.never()
			end
			return ty
		end)
		seen[name] = result
		return result
	end
	--: (string) -> Ty
	root_elaborate = function(name) return elaborate(name, {}, {}) end
	local results = {} --[[: { [string]: { ok: boolean, err?: string, construct?: string } } ]]
	-- elaborate each member from a fresh (empty) open set: a member used as a TOP-
	-- LEVEL name is the full nested-μ solution for that member.
	local solved = {} --[[: { [string]: Ty } ]]
	for i = 1, #order do
		local name = order[i]
		if name ~= nil then solved[name] = root_elaborate(name) end
	end
	-- a parse failure in ANY member taints the whole family (the bodies are mutually
	-- dependent): report the failure on the offending member, mark every member
	-- failed (none installed), so the caller's per-line attribution still lands.
	if fail_name ~= nil then
		local fn = fail_name --: string
		for i = 1, #order do
			local name = order[i]
			if name ~= nil then
				local res = { ok = false } --[[: { ok: boolean, err?: string, construct?: string } ]]
				if name == fn then
					res.err = fail_err or "family member parse failed"
					if fail_construct ~= nil then res.construct = fail_construct end
				else
					res.err = "mutual family member '" .. name .. "' unresolved: sibling '"
						.. fn .. "' failed to parse"
				end
				results[name] = res
			end
		end
		return results
	end
	-- well-formedness gate (same precondition as `declare_alias`): a degenerate
	-- elaboration (non-contractive) is rejected, never silently bound.
	for i = 1, #order do
		local name = order[i]
		local ty = name ~= nil and solved[name] or nil --[[: Ty | nil ]]
		if name ~= nil and ty ~= nil then
			if not TA.well_formed(ty) then
				results[name] = { ok = false,
					err = "mutual alias family member '" .. name .. "' is not well-formed (non-contractive μ)" }
			else
				env[name] = ty
				results[name] = { ok = true }
			end
		end
	end
	return results
end

-- Declare a batch of aliases into `env`, resolving forward-sibling references by
-- dependency order and MUTUAL-RECURSIVE families by Bekić elaboration (§6.13).
-- Returns, per INPUT index, `{ ok, err?, construct? }` so the caller attributes a
-- failure to the right source line. The env is mutated in place. Acyclic references
-- (backward and forward) resolve via topo order; a cyclic SCC is elaborated as a
-- family. A batch with no cycle reproduces the previous flat-order behavior.
--: (AliasEnv, AliasDecl[]) -> { [integer]: { ok: boolean, err?: string, construct?: string } }
function M.declare_aliases_ordered(env, decls)
	local groups = M.alias_decl_groups(decls)
	local results = {} --[[: { [integer]: { ok: boolean, err?: string, construct?: string } } ]]
	for g = 1, #groups do
		local group = groups[g]
		if #group == 1 then
			local i = group[1]
			local d = decls[i]
			local r, e, c = M.declare_alias(env, d.name, d.body)
			local res = { ok = r ~= nil } --[[: { ok: boolean, err?: string, construct?: string } ]]
			if e ~= nil then res.err = e end
			if c ~= nil then res.construct = c end
			results[i] = res
		else
			-- a mutual-recursive family: Bekić-elaborate as a unit.
			local members = {} --[[: AliasDecl[] ]]
			for k = 1, #group do members[#members + 1] = decls[group[k]] end
			local byname = M.elaborate_family(env, members)
			for k = 1, #group do
				local i = group[k]
				results[i] = byname[decls[i].name] or { ok = false, err = "family elaboration produced no result" }
			end
		end
	end
	return results
end

-- ── Annotation line scanning (`--:` / `--::`) ────────────────────────────────
--
-- Pull annotation directives out of a source line. Returns one of:
--   { kind = "alias", name, body }   for `--:: Name = T`
--   { kind = "import", module }       for `--:: require "lib.x"` (type-only import)
--   { kind = "sig", body }           for `--: T`   (preceding-line signature)
--   nil                              if the line carries no annotation directive
--
-- The `import` form (§6.6) is a TYPE-ONLY import directive: it brings the named
-- module's top-level `--::` aliases into the current file's annotation scope under
-- their bare declared names. It carries no runtime value and never reaches the
-- type-grammar parser; the cross-module resolver (in the lowering/survey import
-- pass) consumes it.
--
--:: AnnDirective = { kind: string, name?: string, body?: string, module?: string }

--: (string) -> AnnDirective | nil
function M.scan_annotation(line)
	-- `--::` alias declaration or type-only import directive.
	local adecl = line:match("^%s*%-%-::%s*(.+)$")
	if adecl then
		local name, body = adecl:match("^([%a_][%w_]*)%s*=%s*(.+)$")
		if name then return { kind = "alias", name = name, body = body } end
		-- `--:: require "lib.x"` — a type-only cross-module import (§6.6.2).
		local mod = adecl:match([[^require%s+"([^"]+)"%s*$]])
			or adecl:match([[^require%s+'([^']+)'%s*$]])
		if mod then return { kind = "import", module = mod } end
		-- any other `--::` form without `=` (e.g. `declare`/`augment`) is outside v1.
		return nil
	end
	-- `--:` signature (single colon, not `--::`).
	local sig = line:match("^%s*%-%-:%s+(.+)$")
	if sig and not line:match("^%s*%-%-::") then
		return { kind = "sig", body = sig }
	end
	return nil
end

-- Bracket-balance of a type-body fragment: (opens − closes) over `{`/`}`/`(`/`)`,
-- ignoring brackets inside string literals. A positive balance means the directive
-- continues on the next line (§6.5.6 multi-line `--::`).
--: (string) -> integer
local function bracket_balance(s)
	local bal = 0 --: integer
	local i = 1 --: integer
	local n = #s
	while i <= n do
		local c = s:sub(i, i)
		if c == '"' or c == "'" then
			local q = c
			i = i + 1
			while i <= n and s:sub(i, i) ~= q do i = i + 1 end
		elseif c == "{" or c == "(" then
			bal = bal + 1
		elseif c == "}" or c == ")" then
			bal = bal - 1
		end
		i = i + 1
	end
	return bal
end

-- Strip the leading `--::` / `--:` directive marker from a CONTINUATION line,
-- returning just the body fragment (or nil if the line is not a `--`-annotation
-- continuation). Used to join wrapped multi-line aliases.
--: (string) -> string | nil
local function continuation_body(line)
	local b = line:match("^%s*%-%-::%s?(.*)$")
	if b ~= nil then return b end
	b = line:match("^%s*%-%-:%s?(.*)$")
	if b ~= nil then return b end
	return nil
end

-- Scan an annotation directive starting at `lines[idx]`, JOINING multi-line `--::`
-- (or `--:`) continuations when the directive's body has unbalanced brackets
-- (§6.5.6). Returns (directive | nil, lines_consumed): a single-line directive
-- consumes 1; a wrapped one consumes the continuation lines too. The joined body
-- is what `parse_type_ann` / `declare_alias` always expected — the type grammar
-- parser is unchanged; this is purely a frontend tokenization reach.
--: ({ [integer]: string }, integer) -> (AnnDirective | nil, integer)
function M.scan_annotation_at(lines, idx)
	local first = lines[idx]
	if type(first) ~= "string" then return nil, 1 end
	local d = M.scan_annotation(first)
	if d == nil then return nil, 1 end
	local body = d.body
	if type(body) ~= "string" then return d, 1 end
	-- already balanced (or no opening bracket) → single line.
	if bracket_balance(body) <= 0 then return d, 1 end
	-- consume continuation lines until the brackets balance.
	local joined = body --: string
	local consumed = 1 --: integer
	local j = idx + 1 --: integer
	while j <= #lines and bracket_balance(joined) > 0 do
		local frag = continuation_body(lines[j])
		if frag == nil then break end -- not a continuation; stop (leaves unbalanced)
		joined = joined .. " " .. frag
		consumed = consumed + 1
		j = j + 1
	end
	if d.kind == "alias" then
		local out = { kind = "alias", body = joined } --[[: AnnDirective ]]
		local nm = d.name
		if nm ~= nil then out.name = nm end
		return out, consumed
	end
	return { kind = "sig", body = joined }, consumed
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

-- A depth-1 field-path target `x.f` (an `index` over a bare `var`) → the path
-- string `"x.f"` (the opaque refinement-target NAME, §6.11.1). The narrowing core
-- treats this exactly as a variable name; the lowering binds it as a synthetic Γ
-- entry and synthesizes its pre-type via index_result. Depth >1 (`x.f.g`) returns
-- nil — the §6.11.1 depth-1 bound (depth-2 is a §9.18 deferral). Returns nil for a
-- non-index node or a non-bare-var base.
--: (unknown) -> string | nil
local function path_of(node)
	if type(node) ~= "table" then return nil end
	if node.t ~= "index" then return nil end
	local field = node.field
	if type(field) ~= "string" then return nil end
	local obj = node.obj
	if type(obj) ~= "table" then return nil end
	local oname = obj.name
	if obj.t ~= "var" or type(oname) ~= "string" then return nil end
	return oname .. "." .. field
end

M.path_of = path_of

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

	-- `x.f == nil` / `x.f ~= nil` (field-path nil-eq, §6.11): the refinement target is
	-- the PATH `"x.f"` (an opaque name), not the object `x`. A nil literal is
	-- unambiguous — it is never a tag discriminant — so a nil comparison against a
	-- depth-1 path is always a path nil-eq, refining the path itself.
	do
		local p = path_of(a)
		if p and is_nil_lit(b) then return { g = "nil_eq", var = p, eq = is_eq } end
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
	-- bare field-path truthy `if x.f` (§6.11): refine the PATH `"x.f"` (opaque name).
	-- This is the dominant corpus idiom (`if node.left`, `if opts_t.title and …`).
	if t == "index" then
		local p = path_of(expr)
		if p then return { g = "truthy", var = p } end
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
			if op == "and" then
				-- For `and`, a conjunct that is not a recognized guard shape contributes
				-- no refinement for any variable. Dropping it is SOUND: in the truthy
				-- branch of `a and b`, everything `a` (or `b`) implies still holds —
				-- we merely lose the refinement we cannot decode. This lets a BARE
				-- VARIABLE left-hand side (`if x and <complex>`) narrow `x` even when
				-- the right operand is not a guard-recognized form (audit round 4 fix).
				if not l and not r then return nil end
				if not r then return l end
				if not l then return r end
			else
				-- For `or`, dropping a conjunct would be unsound (a guard that holds on
				-- one branch and not the other cannot be trusted independently). Require
				-- BOTH sides to be recognized.
				if not l or not r then return nil end
			end
			return { g = op, left = l, right = r }
		end
		return nil
	end
	return nil
end

M.recognize_guard = recognize_guard

return M
