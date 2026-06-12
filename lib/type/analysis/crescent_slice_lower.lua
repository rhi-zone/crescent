-- lib/type/analysis/crescent_slice_lower.lua
--
-- The STATEMENT-LOWERING FRONTEND for `crescent.slice.v1`
-- (docs/agnostic-static-analysis-crescent-slice.md §5, §8 Pass 5). This is the
-- missing driver that turns a REAL Lua source file into the slice's artifact +
-- claim/evidence graph end-to-end — the piece the survey pass
-- (docs/slice-survey-v1.md) exposed as absent (the corpus_test hand-built the
-- derivations; this module GENERATES them from source text).
--
-- Given (source, filename) it produces a `LowerResult`:
--   { state, requested, observations, expected, markers }
-- ready for the substrate's CheckRequest (A.check). It lowers EXACTLY §5's syntax
-- subset:
--   - local decls with optional `--:` annotations (single / multi-assignment)
--   - function defs (module `function M.f`, `M.f = function`, `local function`)
--   - calls, multi-returns
--   - table constructors
--   - field/index access + assignment
--   - if/elseif/else with the five guard forms (flow-narrowing, §4)
--   - for-in pairs/ipairs, numeric-for, while/repeat
--   - `--::` aliases, checked casts `--[[: T]]`, force casts `--[[:! T]]`
--
-- OUT-OF-SUBSET statements never get silently skipped (silent skips manufacture
-- false CLEAN verdicts, §10). Each is recorded as a construct-tagged
-- out-of-subset MARKER, consistent with the survey's tags. A file with any marker
-- is OUT-OF-SUBSET.
--
-- PARSER-REUSE DECISION (the prompt asks for this explicitly): the production Lua
-- parser `lib/type/static/parse.lua` is NOT reused. It emits flat bit-packed
-- ASTNode records into an FFI arena keyed by `defs`/`intern`/`lex` machinery, and
-- carries `--:`/`--::` annotations on a SEPARATE comment stream — consuming it
-- read-only would import all of that coupling (arena, intern pool, node `data[]`
-- bit layout, the annotation-attachment pass) for a syntax subset far smaller than
-- full Lua. The low-coupling choice (CLAUDE.md "Keep coupling low") is a focused
-- statement lexer+parser in the slice namespace producing the slice node grammar
-- DIRECTLY, reusing the slice's own annotation parser (`parse_type_ann`,
-- `declare_alias`) and guard recognizer (`recognize_guard`). No legacy checker
-- semantics enter; only the §5 syntax is reproduced.
--
-- Errors are (nil, errmsg) returns; the lowering never throws for malformed input.

local A = require("lib.type.analysis")
local G = require("lib.type.analysis.slice_ty")
local TA = require("lib.type.analysis.slice_ty_arg")
local SUB = require("lib.type.analysis.slice_subtype")
local NAR = require("lib.type.analysis.slice_narrow")
local P = require("lib.type.analysis.crescent_slice_parse")
local S = require("lib.type.analysis.crescent_slice")
local XM = require("lib.type.analysis.crescent_slice_xmodule")

local M = {}

-- ── A LowerResult ────────────────────────────────────────────────────────────
--
--   state         : AnalysisState with all artifacts/claims/evidence/trust added.
--   requested     : Id[]   the load-bearing claims to request from A.check.
--   observations  : { kind, ... }[]  the --: / --:: annotations (recorded as
--                   `annotation` observations; data, surfaced for traceability).
--   expected      : "CLEAN" | "OUT-OF-SUBSET" | "FINDINGS"  the file's verdict
--                   class (CLEAN = in-subset and every requested claim must
--                   accept; OUT-OF-SUBSET = at least one construct-tagged marker;
--                   FINDINGS = a parse/lowering defect with no construct tag).
--   markers       : { line, construct, text }[]  the out-of-subset markers.
--:: LowerMarker = { line: integer, construct: string, text: string }
--:: ImportRecord = { module: string, path: string, names: string[], form: string }
--:: LowerResult = { state: AnalysisState, requested: Id[], observations: { [integer]: unknown }, expected: string, markers: { [integer]: LowerMarker }, aliases: AliasEnv, signatures: { [string]: Ty }, imports: { [integer]: ImportRecord }, dependencies: { [integer]: Dependency } }

-- ════════════════════════════════════════════════════════════════════════════
-- §1. The statement lexer (a focused Lua tokenizer over the v1 subset)
-- ════════════════════════════════════════════════════════════════════════════
--
-- A tiny self-contained Lua lexer. It tokenizes one source string into a flat
-- token list, tracking line numbers and STRIPPING comments — EXCEPT cast comments
-- `--[[: T]]` / `--[[:! T]]`, which are emitted as `cast` tokens (the v1 cast
-- syntax rides a block comment). `--:` / `--::` line annotations are NOT in the
-- token stream; they are scanned separately by line (the adapter's
-- `scan_annotation`), because a signature attaches to the FOLLOWING statement.

--:: LTok = { kind: string, text: string, line: integer, force?: boolean }

local KEYWORDS = {
	["and"] = true, ["break"] = true, ["do"] = true, ["else"] = true,
	["elseif"] = true, ["end"] = true, ["false"] = true, ["for"] = true,
	["function"] = true, ["goto"] = true, ["if"] = true, ["in"] = true,
	["local"] = true, ["nil"] = true, ["not"] = true, ["or"] = true,
	["repeat"] = true, ["return"] = true, ["then"] = true, ["true"] = true,
	["until"] = true, ["while"] = true,
}

-- Lex `src` into tokens. Returns (toks, nil) or (nil, errmsg).
--: (string) -> ({ [integer]: LTok } | nil, string | nil)
local function lex(src)
	local toks = {} --[[: { [integer]: LTok } ]]
	local i = 1 --: integer
	local n = #src
	local line = 1 --: integer

	--: (string) -> nil
	local function count_newlines(s)
		for _ in s:gmatch("\n") do line = line + 1 end
	end

	while i <= n do
		local c = src:sub(i, i)
		if c == "\n" then
			line = line + 1; i = i + 1
		elseif c == " " or c == "\t" or c == "\r" then
			i = i + 1
		elseif src:sub(i, i + 1) == "--" then
			-- a comment. Detect cast block comments `--[[: T]]` / `--[[:! T]]`.
			local cast = src:match("^%-%-%[%[:(!?)%s*(.-)%]%]", i)
			if src:sub(i + 2, i + 3) == "[[" then
				-- block comment. capture a cast `:` / `:!`.
				local close = src:find("]]", i + 4, true)
				if not close then return nil, "unterminated block comment at line " .. line end
				local body = src:sub(i + 4, close - 1)
				local bang, ctype = body:match("^:(!?)%s*(.+)$")
				if bang ~= nil then
					toks[#toks + 1] = { kind = "cast", text = ctype, line = line, force = bang == "!" }
				end
				count_newlines(src:sub(i, close + 1))
				i = close + 2
			else
				-- a line comment. skip to end of line (annotations handled by line scan).
				local nl = src:find("\n", i, true)
				if not nl then i = n + 1 else i = nl end
			end
			local _ = cast
		elseif c == "[" and (src:sub(i + 1, i + 1) == "[" or src:sub(i + 1, i + 1) == "=") then
			-- long-bracket string [[ ... ]] or [=[ ... ]=].
			local eqs = src:match("^%[(=*)%[", i)
			if eqs then
				local close = "]" .. eqs .. "]"
				local ce = src:find(close, i + #eqs + 2, true)
				if not ce then return nil, "unterminated long string at line " .. line end
				local body = src:sub(i + #eqs + 2, ce - 1)
				toks[#toks + 1] = { kind = "string", text = body, line = line }
				count_newlines(src:sub(i, ce + #close - 1))
				i = ce + #close
			else
				toks[#toks + 1] = { kind = "[", text = "[", line = line }; i = i + 1
			end
		elseif c:match("[%a_]") then
			local j = i
			while j <= n and src:sub(j, j):match("[%w_]") do j = j + 1 end
			local word = src:sub(i, j - 1)
			if KEYWORDS[word] then
				toks[#toks + 1] = { kind = word, text = word, line = line }
			else
				toks[#toks + 1] = { kind = "name", text = word, line = line }
			end
			i = j
		elseif c:match("%d") or (c == "." and src:sub(i + 1, i + 1):match("%d")) then
			local j = i
			-- hex / decimal / float / exponent — coarse but adequate for v1.
			if src:sub(i, i + 1):lower() == "0x" then
				j = i + 2
				while j <= n and src:sub(j, j):match("[%x%.pPeE%+%-]") do j = j + 1 end
			else
				while j <= n and src:sub(j, j):match("[%d%.eE%+%-]") do
					local ch = src:sub(j, j)
					if (ch == "+" or ch == "-") and not src:sub(j - 1, j - 1):match("[eE]") then break end
					j = j + 1
				end
			end
			toks[#toks + 1] = { kind = "number", text = src:sub(i, j - 1), line = line }
			i = j
		elseif c == '"' or c == "'" then
			local q = c
			local j = i + 1
			local buf = {} --[[: { [integer]: string } ]]
			while j <= n do
				local ch = src:sub(j, j)
				if ch == "\\" then
					buf[#buf + 1] = src:sub(j + 1, j + 1); j = j + 2
				elseif ch == q then
					break
				elseif ch == "\n" then
					return nil, "unterminated string at line " .. line
				else
					buf[#buf + 1] = ch; j = j + 1
				end
			end
			if j > n then return nil, "unterminated string at line " .. line end
			toks[#toks + 1] = { kind = "string", text = table.concat(buf), line = line }
			i = j + 1
		else
			-- multi-char operators, then single-char punctuation.
			local three = src:sub(i, i + 2)
			local two = src:sub(i, i + 1)
			if three == "..." then
				toks[#toks + 1] = { kind = "...", text = "...", line = line }; i = i + 3
			elseif two == ".." then
				toks[#toks + 1] = { kind = "..", text = "..", line = line }; i = i + 2
			elseif two == "==" or two == "~=" or two == "<=" or two == ">=" then
				toks[#toks + 1] = { kind = two, text = two, line = line }; i = i + 2
			else
				toks[#toks + 1] = { kind = c, text = c, line = line }; i = i + 1
			end
		end
	end
	toks[#toks + 1] = { kind = "eof", text = "<eof>", line = line }
	return toks
end

M.lex = lex

-- ════════════════════════════════════════════════════════════════════════════
-- §2. The statement parser (recursive descent over the §5 subset → an AST)
-- ════════════════════════════════════════════════════════════════════════════
--
-- The AST it produces is an intermediate tree (NOT yet the slice node grammar):
-- statements and expressions tagged by `k`. The LOWERING pass (§3) walks it and
-- emits the slice artifacts/claims. Out-of-subset constructs produce an
-- `{ k = "oos", construct, line, text }` node rather than failing the whole file.
--
-- Expression AST:
--   { k="num", v, int }                 number literal (int flags integer-valued)
--   { k="str", v }                      string literal
--   { k="bool", v } / { k="nil" }       bool / nil literal
--   { k="name", name }                  identifier
--   { k="vararg" }                      ...
--   { k="index", obj, field }           t.field / t["field"]  (static key)
--   { k="indexdyn", obj, key }          t[expr]               (dynamic key)
--   { k="call", fn, args }              f(a, b)
--   { k="method", obj, name, args }     o:m(a)               (out-of-subset → oos)
--   { k="table", entries=[{key?,value}], array=[expr] }
--   { k="func", params=[{name}], vararg, body }   anonymous function
--   { k="binop", op, left, right }      a + b / a == b / a and b ...
--   { k="unop", op, expr }              not a / -a / #a
--   { k="cast", expr, type, force }     e --[[: T]] / e --[[:! T]]
--   { k="oos", construct, line, text }  out-of-subset expression
--
-- Statement AST:
--   { k="local", names=[name], anns=[ann?], values=[expr] }
--   { k="assign", targets=[expr], values=[expr] }
--   { k="callstmt", call }
--   { k="funcdecl", target, params, vararg, body, self }
--   { k="localfunc", name, params, vararg, body }
--   { k="return", values=[expr] }
--   { k="if", clauses=[{ test, body }], else_body? }
--   { k="fornum", var, from, to, step?, body }
--   { k="forin", names=[name], iter, body }
--   { k="while", test, body }   { k="repeat", body, test }
--   { k="do", body }   { k="break" }
--   { k="oos", construct, line, text }

-- AST nodes are `unknown`: a heterogeneous, runtime-parsed tagged tree. Every
-- consumer narrows with `type(node) == "table"` before reading the string `k`
-- tag and dispatching — the parse-not-cast discipline crescent_slice.lua's
-- checker uses on its `unknown` syntax nodes. (The slice node grammar, by
-- contrast, rides interned `Ty` and IS a narrowed union.)

-- Construct a parser over a token list. The `anns_by_line` map gives the `--:`
-- signature whose body should attach to a statement STARTING on the next line.
--: ({ [integer]: LTok }, { [integer]: string }) -> { parse_chunk: () -> unknown }
local function new_parser(toks, anns_by_line)
	local pos = 1 --: integer

	-- the token list always ends with an eof token, so an index past the end
	-- still yields a valid LTok; the `EOF` constant is the typed fallback that
	-- makes the never-nil invariant visible to the typechecker.
	local EOF = { kind = "eof", text = "<eof>", line = 0 } --[[: LTok ]]
	--: (LTok | nil) -> LTok
	local function tok_or_eof(t) if t == nil then return EOF end return t end
	--: () -> LTok
	local function peek() return tok_or_eof(toks[pos]) end
	--: (integer) -> LTok
	local function peek_at(k) return tok_or_eof(toks[pos + k]) end
	--: () -> LTok
	local function advance()
		local t = tok_or_eof(toks[pos]) --[[: LTok ]]
		pos = pos + 1
		return t
	end
	--: (string) -> boolean
	local function check(kind)
		local t = toks[pos]
		if t == nil then return false end
		return t.kind == kind
	end
	--: (string) -> boolean
	local function accept(kind)
		if toks[pos] and toks[pos].kind == kind then pos = pos + 1; return true end
		return false
	end

	-- An out-of-subset marker node (carries the construct tag + source line).
	--: (string, integer, string) -> unknown
	local function oos(construct, line, text)
		return { k = "oos", construct = construct, line = line, text = text }
	end

	local parse_expr --[[: () -> unknown ]]
	local parse_block --[[: ({ [string]: boolean }) -> unknown ]]

	-- ── primary / suffixed expression ──
	--: () -> unknown
	local function parse_primary()
		local t = peek()
		if t.kind == "number" then
			advance()
			local txt = t.text
			local num = tonumber(txt) or 0 --: number
			local isint = not txt:find("[%.eEpP]") or (num == math.floor(num) and num == num)
			-- integer-valued iff no fractional/exponent marker OR value is whole.
			local int = (not txt:find("[%.]")) and (num == math.floor(num))
			local _ = isint
			return { k = "num", v = num, int = int }
		elseif t.kind == "string" then
			advance(); return { k = "str", v = t.text }
		elseif t.kind == "true" then
			advance(); return { k = "bool", v = true }
		elseif t.kind == "false" then
			advance(); return { k = "bool", v = false }
		elseif t.kind == "nil" then
			advance(); return { k = "nil" }
		elseif t.kind == "..." then
			advance(); return { k = "vararg" }
		elseif t.kind == "name" then
			advance(); return { k = "name", name = t.text }
		elseif t.kind == "(" then
			advance()
			local e = parse_expr()
			if not accept(")") then return oos("paren", t.line, "(") end
			return e
		elseif t.kind == "{" then
			return nil -- table handled in parse_suffixed via fallthrough below
		elseif t.kind == "function" then
			return nil -- anonymous function handled by caller
		end
		return oos("expr", t.line, t.text)
	end

	-- Parse a table constructor `{ ... }` (assumes `{` is current).
	--: () -> unknown
	local function parse_table()
		local line = peek().line
		advance() -- {
		local entries = {} --[[: { [integer]: unknown } ]]
		local array = {} --[[: { [integer]: unknown } ]]
		while not check("}") and not check("eof") do
			if check("[") then
				advance()
				-- [k] = v. v1 supports integer / string literal keys structurally;
				-- a dynamic key constructor is out-of-subset (no synth_table form).
				local kt = peek()
				if kt.kind == "string" then
					advance()
					if not accept("]") then return oos("table-key", line, "[") end
					if not accept("=") then return oos("table-key", line, "[k]") end
					local v = parse_expr()
					entries[#entries + 1] = { key = kt.text, value = v }
				elseif kt.kind == "number" then
					advance()
					if not accept("]") then return oos("table-key", line, "[") end
					if not accept("=") then return oos("table-key", line, "[k]") end
					local v = parse_expr()
					array[#array + 1] = v -- integer-keyed entry → array tail (v1)
				else
					return oos("table-dynamic-key", line, "[" .. kt.text)
				end
			elseif check("name") and peek_at(1).kind == "=" then
				local key = advance().text
				advance() -- =
				local v = parse_expr()
				entries[#entries + 1] = { key = key, value = v }
			else
				local v = parse_expr()
				array[#array + 1] = v
			end
			if not (accept(",") or accept(";")) then break end
		end
		if not accept("}") then return oos("table", line, "{") end
		return { k = "table", entries = entries, array = array }
	end

	-- Parse a function parameter list + body (assumes `(` current). Returns
	-- (params, vararg, body, has_self_oos). `has_self` flags a `self` first param
	-- via a method-style decl (handled by the caller).
	--: () -> unknown
	local function parse_func_rest()
		local line = peek().line
		if not accept("(") then return oos("func", line, "(") end
		local params = {} --[[: { [integer]: unknown } ]]
		local vararg = false --: boolean
		if not check(")") then
			while true do
				if accept("...") then vararg = true; break end
				local pt = peek()
				if pt.kind ~= "name" then return oos("func-param", pt.line, pt.text) end
				advance()
				params[#params + 1] = { name = pt.text }
				if not accept(",") then break end
			end
		end
		if not accept(")") then return oos("func", line, ")") end
		local body = parse_block({ ["end"] = true })
		if not accept("end") then return oos("func", line, "function") end
		return { k = "func", params = params, vararg = vararg, body = body }
	end

	-- ── suffixed expression (calls, indexing chained on a primary) ──
	--: () -> unknown
	local function parse_suffixed()
		local t = peek()
		local base --[[: unknown ]]
		if t.kind == "{" then
			base = parse_table()
		elseif t.kind == "function" then
			advance()
			base = parse_func_rest()
		else
			base = parse_primary()
		end
		if type(base) == "table" and base.k == "oos" then return base end
		while true do
			local s = peek()
			if s.kind == "." then
				advance()
				local nm = peek()
				if nm.kind ~= "name" then return oos("index", nm.line, nm.text) end
				advance()
				base = { k = "index", obj = base, field = nm.text }
			elseif s.kind == "[" then
				advance()
				local key = peek()
				if key.kind == "string" then
					advance()
					if not accept("]") then return oos("index", s.line, "[") end
					base = { k = "index", obj = base, field = key.text }
				else
					local ke = parse_expr()
					if not accept("]") then return oos("index", s.line, "[") end
					base = { k = "indexdyn", obj = base, key = ke }
				end
			elseif s.kind == ":" then
				-- method call o:m(...) — out-of-subset (no method-call synth in v1).
				advance()
				local nm = peek()
				if nm.kind == "name" then advance() end
				return oos("method-call", s.line, ":" .. (nm.text or ""))
			elseif s.kind == "(" then
				advance()
				local args = {} --[[: { [integer]: unknown } ]]
				if not check(")") then
					while true do
						args[#args + 1] = parse_expr()
						if not accept(",") then break end
					end
				end
				if not accept(")") then return oos("call", s.line, "(") end
				base = { k = "call", fn = base, args = args }
			elseif s.kind == "string" then
				-- call with a single string arg `f "x"` (no parens).
				advance()
				base = { k = "call", fn = base, args = { { k = "str", v = s.text } } }
			elseif s.kind == "{" then
				-- call with a single table arg `f {…}` (no parens).
				local tb = parse_table()
				base = { k = "call", fn = base, args = { tb } }
			else
				break
			end
		end
		return base
	end

	-- Binary-operator precedence climb. Casts `--[[: T]]` bind to the preceding
	-- expression (highest, postfix).
	local BINPREC = {
		["or"] = 1, ["and"] = 2,
		["<"] = 3, [">"] = 3, ["<="] = 3, [">="] = 3, ["=="] = 3, ["~="] = 3,
		[".."] = 5,
		["+"] = 6, ["-"] = 6,
		["*"] = 7, ["/"] = 7, ["%"] = 7,
		["^"] = 9,
	}

	--: () -> unknown
	local function parse_unary()
		local t = peek()
		if t.kind == "not" or t.kind == "-" or t.kind == "#" then
			advance()
			local e = parse_unary()
			return { k = "unop", op = t.kind, expr = e }
		end
		local e = parse_suffixed() --[[: unknown ]]
		-- postfix cast comments.
		while check("cast") do
			local ct = advance()
			e = { k = "cast", expr = e, type = ct.text, force = ct.force }
		end
		return e
	end

	--: (integer) -> unknown
	local function parse_binop(min_prec)
		local left --[[: unknown ]] = parse_unary()
		while true do
			local op = peek().kind
			local prec = BINPREC[op]
			if not prec or prec < min_prec then break end
			advance()
			local right_assoc = (op == "^" or op == "..")
			local next_min = right_assoc and prec or (prec + 1)
			local right = parse_binop(next_min)
			local node --[[: unknown ]] = { k = "binop", op = op, left = left, right = right }
			-- a cast may follow a binop result.
			while check("cast") do
				local ct = advance()
				node = { k = "cast", expr = node, type = ct.text, force = ct.force }
			end
			left = node
		end
		return left
	end

	parse_expr = function() return parse_binop(1) end

	-- ── statements ──

	-- Parse a dotted target `a.b.c` or a bare name; returns the expr + a flag.
	--: () -> unknown
	local function parse_target()
		local t = peek()
		if t.kind ~= "name" then return oos("target", t.line, t.text) end
		advance()
		local base --[[: unknown ]] = { k = "name", name = t.text }
		while true do
			if check(".") then
				advance()
				local nm = peek()
				if nm.kind ~= "name" then return oos("target", nm.line, nm.text) end
				advance()
				base = { k = "index", obj = base, field = nm.text }
			elseif check("[") then
				advance()
				local key = peek()
				if key.kind == "string" then
					advance()
					if not accept("]") then return oos("target", t.line, "[") end
					base = { k = "index", obj = base, field = key.text }
				else
					local ke = parse_expr()
					if not accept("]") then return oos("target", t.line, "[") end
					base = { k = "indexdyn", obj = base, key = ke }
				end
			else
				break
			end
		end
		return base
	end

	-- A `--:` signature attaching to a statement on `line`, or nil.
	--: (integer) -> string | nil
	local function sig_for(line)
		return anns_by_line[line]
	end

	--: () -> unknown
	local function parse_statement()
		local t = peek()
		local line = t.line
		if t.kind == "local" then
			advance()
			if accept("function") then
				local nm = peek()
				if nm.kind ~= "name" then return oos("localfunc", line, nm.text) end
				advance()
				local fr = parse_func_rest()
				if type(fr) ~= "table" then return oos("localfunc", line, "function") end
				if fr.k == "oos" then return fr end
				return { k = "localfunc", name = nm.text, params = fr.params, vararg = fr.vararg,
					body = fr.body, sig = sig_for(line) }
			end
			-- local a, b = e1, e2
			local names = {} --[[: { [integer]: string } ]]
			local anns = {} --[[: { [integer]: string } ]]
			while true do
				local nt = peek()
				if nt.kind ~= "name" then return oos("local", nt.line, nt.text) end
				advance()
				names[#names + 1] = nt.text
				-- an inline `--: T` cast comment after the name is the local annotation.
				-- (We approximate the inline `--: T` form as a cast token if present.)
				if not accept(",") then break end
			end
			local values = {} --[[: { [integer]: unknown } ]]
			if accept("=") then
				while true do
					values[#values + 1] = parse_expr()
					if not accept(",") then break end
				end
			end
			return { k = "local", names = names, anns = anns, values = values, sig = sig_for(line) }
		elseif t.kind == "function" then
			advance()
			-- function Name(.) / function M.f(.) / function o:m(.)
			local nm = peek()
			if nm.kind ~= "name" then return oos("funcdecl", line, nm.text) end
			advance()
			local target --[[: unknown ]] = { k = "name", name = nm.text }
			local is_method = false --: boolean
			while true do
				if check(".") then
					advance()
					local f = peek()
					if f.kind ~= "name" then return oos("funcdecl", line, f.text) end
					advance()
					target = { k = "index", obj = target, field = f.text }
				elseif check(":") then
					advance()
					local f = peek()
					if f.kind == "name" then advance() end
					is_method = true
					break
				else
					break
				end
			end
			local fr = parse_func_rest()
			if type(fr) ~= "table" then return oos("funcdecl", line, "function") end
			if fr.k == "oos" then return fr end
			return { k = "funcdecl", target = target, params = fr.params, vararg = fr.vararg,
				body = fr.body, is_method = is_method, sig = sig_for(line) }
		elseif t.kind == "return" then
			advance()
			local values = {} --[[: { [integer]: unknown } ]]
			if not (check("end") or check("eof") or check("else") or check("elseif")
				or check("until")) then
				while true do
					values[#values + 1] = parse_expr()
					if not accept(",") then break end
				end
			end
			accept(";")
			return { k = "return", values = values }
		elseif t.kind == "if" then
			advance()
			local clauses = {} --[[: { [integer]: unknown } ]]
			local test = parse_expr()
			if not accept("then") then return oos("if", line, "then") end
			local body = parse_block({ ["end"] = true, ["else"] = true, ["elseif"] = true })
			clauses[#clauses + 1] = { test = test, body = body }
			while check("elseif") do
				advance()
				local et = parse_expr()
				if not accept("then") then return oos("if", line, "elseif") end
				local eb = parse_block({ ["end"] = true, ["else"] = true, ["elseif"] = true })
				clauses[#clauses + 1] = { test = et, body = eb }
			end
			local else_body --[[: unknown ]]
			if accept("else") then
				else_body = parse_block({ ["end"] = true })
			end
			if not accept("end") then return oos("if", line, "end") end
			return { k = "if", clauses = clauses, else_body = else_body }
		elseif t.kind == "for" then
			advance()
			local nm = peek()
			if nm.kind ~= "name" then return oos("for", line, nm.text) end
			advance()
			if check("=") then
				advance()
				local from = parse_expr()
				if not accept(",") then return oos("fornum", line, ",") end
				local to = parse_expr()
				local step --[[: unknown ]]
				if accept(",") then step = parse_expr() end
				if not accept("do") then return oos("fornum", line, "do") end
				local body = parse_block({ ["end"] = true })
				if not accept("end") then return oos("fornum", line, "end") end
				return { k = "fornum", var = nm.text, from = from, to = to, step = step, body = body }
			end
			-- for-in
			local names = { nm.text } --[[: { [integer]: string } ]]
			while accept(",") do
				local n2 = peek()
				if n2.kind ~= "name" then return oos("forin", line, n2.text) end
				advance()
				names[#names + 1] = n2.text
			end
			if not accept("in") then return oos("forin", line, "in") end
			local iter = parse_expr()
			if not accept("do") then return oos("forin", line, "do") end
			local body = parse_block({ ["end"] = true })
			if not accept("end") then return oos("forin", line, "end") end
			return { k = "forin", names = names, iter = iter, body = body }
		elseif t.kind == "while" then
			advance()
			local test = parse_expr()
			if not accept("do") then return oos("while", line, "do") end
			local body = parse_block({ ["end"] = true })
			if not accept("end") then return oos("while", line, "end") end
			return { k = "while", test = test, body = body }
		elseif t.kind == "repeat" then
			advance()
			local body = parse_block({ ["until"] = true })
			if not accept("until") then return oos("repeat", line, "until") end
			local test = parse_expr()
			return { k = "repeat", body = body, test = test }
		elseif t.kind == "do" then
			advance()
			local body = parse_block({ ["end"] = true })
			if not accept("end") then return oos("do", line, "end") end
			return { k = "do", body = body }
		elseif t.kind == "break" then
			advance(); return { k = "break" }
		elseif t.kind == "goto" or t.kind == "::" then
			advance(); return oos("goto", line, t.text)
		else
			-- an expression statement: a call, or an assignment `targets = values`.
			local first = parse_suffixed()
			if type(first) == "table" and first.k == "oos" then return first end
			if check("=") or check(",") then
				local targets = { first } --[[: { [integer]: unknown } ]]
				while accept(",") do
					targets[#targets + 1] = parse_target()
				end
				if not accept("=") then return oos("assign", line, "=") end
				local values = {} --[[: { [integer]: unknown } ]]
				while true do
					values[#values + 1] = parse_expr()
					if not accept(",") then break end
				end
				return { k = "assign", targets = targets, values = values, sig = sig_for(line) }
			end
			if type(first) == "table" and (first.k == "call") then
				return { k = "callstmt", call = first }
			end
			return oos("exprstmt", line, t.text)
		end
	end

	-- Parse a block of statements until one of `stops` (a set of token kinds).
	--: ({ [string]: boolean }) -> unknown
	parse_block = function(stops)
		local stmts = {} --[[: { [integer]: unknown } ]]
		while true do
			local t = peek()
			if t.kind == "eof" or stops[t.kind] then break end
			accept(";")
			t = peek()
			if t.kind == "eof" or stops[t.kind] then break end
			-- PROGRESS GUARD (termination invariant). A statement that produces an
			-- out-of-subset marker (e.g. a method call `o:m(...)`) may return WITHOUT
			-- consuming the tokens that confused it. If parse_statement leaves `pos`
			-- unchanged, force-advance one token so the block loop always makes
			-- progress — otherwise a single unconsumed token spins forever (the
			-- lib/actor/init.lua `if not x:find(...) then` hang). The skipped token is
			-- folded into the marker the statement already emitted.
			local before = pos --: integer
			local s = parse_statement()
			stmts[#stmts + 1] = s
			if pos == before then advance() end
			-- A return must end a block (Lua rule); stop scanning after it.
			if type(s) == "table" and s.k == "return" then break end
		end
		return { k = "block", stmts = stmts }
	end

	return {
		--: () -> unknown
		parse_chunk = function()
			local blk = parse_block({})
			return blk
		end,
	}
end

M.new_parser = new_parser

-- ════════════════════════════════════════════════════════════════════════════
-- §3. Annotation scanning (signatures attach to the FOLLOWING statement)
-- ════════════════════════════════════════════════════════════════════════════
--
-- A `--:` signature on its own line attaches to the statement starting on the
-- NEXT line (the declaration it annotates). `--::` aliases populate the alias
-- env. We build:
--   aliases       : the alias env (declare_alias, recursive → μ).
--   anns_by_line  : line -> signature body, for the statement on that line.
--   observations  : annotation observation data (for traceability).
-- A `--:` whose type body is out-of-subset is recorded as a construct-tagged
-- marker — never silently dropped.

--:: ScanResult = { aliases: AliasEnv, anns_by_line: { [integer]: string }, observations: { [integer]: unknown }, markers: { [integer]: LowerMarker } }

-- `base_aliases`, when given, pre-populates the alias env with cross-module
-- imported aliases (§6.6) BEFORE the file's own `--::` aliases are declared, so a
-- local alias shadows an imported one (most-recent-wins, the standard lexical rule).
--: (string, (AliasEnv | nil)) -> ScanResult
local function scan_source(src, base_aliases)
	local aliases = {} --[[: AliasEnv ]]
	if base_aliases then
		for k, v in pairs(base_aliases) do aliases[k] = v end
	end
	local anns_by_line = {} --[[: { [integer]: string } ]]
	local observations = {} --[[: { [integer]: unknown } ]]
	local markers = {} --[[: { [integer]: LowerMarker } ]]

	-- Collect lines (1-indexed). A signature on line L attaches to the next
	-- NON-annotation, non-blank line.
	local lines = {} --[[: { [integer]: string } ]]
	for ln in (src .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = ln end

	-- First pass: declare aliases in source order (so a later alias can reference
	-- an earlier one). Record signature directives by line. Multi-line `--::`
	-- continuations are joined (§6.5.6); `consumed` is how many source lines the
	-- directive spanned, so they are not re-scanned as separate (failing) lines.
	local idx = 1 --: integer
	while idx <= #lines do
		local d, consumed = P.scan_annotation_at(lines, idx)
		local span = (consumed > 0 and consumed or 1) --: integer
		if d and d.kind == "alias" and d.name ~= nil and d.body ~= nil then
			local r, e, c = P.declare_alias(aliases, d.name, d.body)
			observations[#observations + 1] = { kind = "alias", name = d.name, body = d.body, line = idx }
			if not r then
				local txt = (lines[idx]:gsub("^%s+", "")) --[[: string ]]
				markers[#markers + 1] = { line = idx, construct = c or "alias-error", text = txt }
				local _ = e
			end
		elseif d and d.kind == "sig" and d.body ~= nil then
			-- attach to the next statement-bearing line (after this directive's span).
			local target = idx + span
			while target <= #lines do
				local nd = P.scan_annotation(lines[target])
				local blank = lines[target]:match("^%s*$")
				if nd == nil and not blank then break end
				target = target + 1
			end
			anns_by_line[target] = d.body
			observations[#observations + 1] = { kind = "sig", body = d.body, line = idx, attaches = target }
		end
		idx = idx + span
	end

	return { aliases = aliases, anns_by_line = anns_by_line, observations = observations, markers = markers }
end

M.scan_source = scan_source

-- ════════════════════════════════════════════════════════════════════════════
-- §4. The lowering pass: AST → claim/evidence graph
-- ════════════════════════════════════════════════════════════════════════════
--
-- The lowering walks the parsed chunk under a typing context (name → Ty),
-- synthesizing each in-subset expression's type and emitting the supporting
-- claim + evidence. It targets the EXISTING evidence methods of crescent_slice.lua
-- (synth_lit/var/call/index/table/and_or_not/function, check_against, check_cast,
-- subtype_witness, narrow_guard, synth_loop_var/numeric_for_var,
-- trusted_signature) — it adds NO new method. Out-of-subset nodes are recorded as
-- markers; the file's class becomes OUT-OF-SUBSET, but the in-subset claims are
-- still emitted (so the verdict reflects real checking up to the boundary).

-- The lowering builder collects state and hands out fresh ids.
--:: Builder = { node: (unknown) -> Id, fresh_claim: (string) -> Id, fresh_ev: (string) -> Id }
--: (AnalysisState) -> Builder
local function new_builder(state)
	local seq = 0 --: integer
	--: (string) -> Id
	local function fresh(prefix)
		seq = seq + 1
		return A.id("artifact", prefix .. "#" .. seq)
	end
	--: (string) -> Id
	local function fresh_claim(prefix)
		seq = seq + 1
		return A.id("claim", prefix .. "#" .. seq)
	end
	--: (string) -> Id
	local function fresh_ev(prefix)
		seq = seq + 1
		return A.id("ev", prefix .. "#" .. seq)
	end

	-- Add a syntax_tree artifact, returning its Id.
	--: (unknown) -> Id
	local function node(content)
		local id = fresh("node")
		A.add_artifact(state, A.artifact({ id = id, kind = "syntax_tree", content_ref = content }))
		return id
	end

	return {
		node = node,
		fresh_claim = fresh_claim,
		fresh_ev = fresh_ev,
	}
end

-- A typing context for the lowering: an ordered binding list as the slice's
-- SliceCtx (name → interned Ty). The lowering uses S.extend / S.empty_ctx.
-- ctx is the raw SliceCtx (portable types); for synthesis decisions the lowering
-- decodes a binding lazily via TA.decode.

-- Lookup a name's interned Ty in a SliceCtx (most-recent-wins).
--: (SliceCtx, string) -> Ty | nil
local function ctx_get(ctx, name)
	for i = #ctx, 1, -1 do
		if ctx[i].name == name then return TA.decode(ctx[i].type) end
	end
	return nil
end

-- The lowering result accumulators ride a `LC` (lowering context) table threaded
-- through the walk: builder, requested-claim list, marker list, alias env,
-- trusted-boundary id (one shared stdlib boundary), and the current SliceCtx.
--:: LC = { b: Builder, requested: { [integer]: Id }, markers: { [integer]: LowerMarker }, aliases: AliasEnv, stdlib_tb: Id, state: AnalysisState }

-- A typed VIEW over an AST node (`unknown` at the seam). Each consumer narrows
-- its `unknown` node to `LV` via the `view` helper, then reads concretely-typed
-- fields (string tags, sub-nodes as `unknown` for further narrowing). This is the
-- parse-not-cast discipline: `view` only succeeds on a table (the checked cast
-- requires the value already be a table-shaped `unknown`, which `view` asserts).
--:: LVEntry = { key?: string, value?: unknown }
--:: LVClause = { test?: unknown, body?: unknown }
--:: LVParam = { name?: string }
--:: LV = {
--::   k?: string, v?: unknown, int?: boolean, name?: string, op?: string,
--::   obj?: unknown, field?: string, key?: unknown, fn?: unknown, expr?: unknown,
--::   left?: unknown, right?: unknown, args?: { [integer]: unknown },
--::   entries?: { [integer]: LVEntry }, array?: { [integer]: unknown },
--::   params?: { [integer]: LVParam }, vararg?: boolean, body?: unknown,
--::   type?: string, force?: boolean, construct?: string, line?: integer,
--::   text?: string, stmts?: { [integer]: unknown }, names?: { [integer]: string },
--::   values?: { [integer]: unknown }, targets?: { [integer]: unknown },
--::   sig?: string, target?: unknown, is_method?: boolean,
--::   clauses?: { [integer]: LVClause }, var?: string, from?: unknown,
--::   to?: unknown, step?: unknown, iter?: unknown, call?: unknown,
--::   else_body?: unknown,
--::   g?: string, inner?: unknown, eq?: boolean, tyname?: string, lit?: unknown,
--::   test?: unknown,
--:: }

-- Narrow an `unknown` AST node to the typed `LV` view, or nil if not a table.
--: (unknown) -> LV | nil
local function view(node)
	if type(node) ~= "table" then return nil end
	return node --[[: LV ]]
end

-- Emit a marker (out-of-subset / finding) — never silently skip.
--: (LC, unknown) -> nil
local function mark(lc, n)
	local nv = view(n) or {} --[[: LV ]]
	lc.markers[#lc.markers + 1] = { line = nv.line or 0, construct = nv.construct or "unknown", text = nv.text or "" }
end

-- Parse a v1 annotation type body to an interned Ty under the alias env, or nil.
-- A failure is recorded as a marker (construct-tagged when the parser tags it).
--: (LC, string, integer) -> Ty | nil
--: (LC, string, integer) -> Ty | nil
local function ann_type(lc, body, line)
	local ty, e, c = P.parse_type_ann(body, lc.aliases)
	if not ty then
		lc.markers[#lc.markers + 1] = { line = line or 0, construct = c or "annotation-error", text = body }
		local _ = e
		return nil
	end
	return ty
end

-- Forward declaration: synthesize an expression's type, emitting the supporting
-- has_type claim. Returns (ty, claim_id) or (nil, nil) when out-of-subset (a
-- marker is emitted). `ctx` is the SliceCtx in scope.
local synth_expr --[[: (LC, SliceCtx, unknown) -> (Ty | nil, Id | nil) ]]

-- Lower a literal expression to a slice node + has_type claim. Returns
-- (ty, claim_id).
--: (LC, SliceCtx, unknown) -> (Ty | nil, Id | nil)
local function synth_lit_expr(lc, ctx, e)
	local v = view(e)
	if not v then return nil, nil end
	local raw = v.v
	local ty --[[: Ty | nil ]]
	local lnode --[[: unknown ]]
	if v.k == "num" and type(raw) == "number" then
		local nv = raw
		if v.int then
			ty = G.lit_int(nv)
			lnode = { t = "lit", lit = "int", v = nv }
		else
			ty = G.lit_num(nv)
			lnode = { t = "lit", lit = "num", v = nv }
		end
		if not ty then ty = G.number(); lnode = { t = "lit", lit = "num", v = nv } end
	elseif v.k == "str" and type(raw) == "string" then
		ty = G.lit_str(raw); lnode = { t = "lit", lit = "str", v = raw }
	elseif v.k == "bool" and type(raw) == "boolean" then
		ty = G.lit_bool(raw); lnode = { t = "lit", lit = "bool", v = raw }
	elseif v.k == "nil" then
		ty = G.nil_(); lnode = { t = "lit", lit = "nil" }
	end
	if not ty then return nil, nil end
	local nid = lc.b.node(lnode)
	local cid = lc.b.fresh_claim("lit")
	A.add_claim(lc.state, S.has_type_claim(cid, ctx, nid, ty))
	A.add_evidence(lc.state, A.evidence({ id = lc.b.fresh_ev("lit"), claim = cid, method = "synth_lit" }))
	return ty, cid
end

-- Lower a variable reference. Returns (ty, claim_id) or marks unbound/oos.
--: (LC, SliceCtx, unknown) -> (Ty | nil, Id | nil)
local function synth_var_expr(lc, ctx, e)
	local v = view(e)
	local name = v and v.name
	if type(name) ~= "string" then return nil, nil end
	local ty = ctx_get(ctx, name)
	if not ty then
		-- an unbound name (a module-local, a global, a stdlib function not modeled).
		mark(lc, { line = 0, construct = "unbound-name:" .. name, text = name })
		return nil, nil
	end
	local nid = lc.b.node({ t = "var", name = name })
	local cid = lc.b.fresh_claim("var")
	A.add_claim(lc.state, S.has_type_claim(cid, ctx, nid, ty))
	A.add_evidence(lc.state, A.evidence({ id = lc.b.fresh_ev("var"), claim = cid, method = "synth_var" }))
	return ty, cid
end

-- Lower a field/index access `t.field`. Returns (ty, claim_id).
--: (LC, SliceCtx, unknown) -> (Ty | nil, Id | nil)
local function synth_index_expr(lc, ctx, e)
	local v = view(e)
	local field = v and v.field
	if type(field) ~= "string" then return nil, nil end
	local oty, ocid = synth_expr(lc, ctx, v.obj)
	if not oty or not ocid then return nil, nil end
	-- the object node id is the artifact the premise claim references.
	local pc = lc.state.claims[A.idk(ocid)]
	if not pc then return nil, nil end
	local obj_ref = pc.args and pc.args.node --[[: unknown ]]
	local res = S.index_result(oty, field, nil)
	if not res then
		mark(lc, { line = 0, construct = "no-such-field:" .. field, text = field })
		return nil, nil
	end
	local nid = lc.b.node({ t = "index", obj = obj_ref, field = field })
	local cid = lc.b.fresh_claim("index")
	A.add_claim(lc.state, S.has_type_claim(cid, ctx, nid, res))
	A.add_evidence(lc.state, A.evidence({ id = lc.b.fresh_ev("index"), claim = cid,
		method = "synth_index", inputs = { ocid } }))
	return res, cid
end

-- Lower an `and`/`or`/`not` connective. Returns (ty, claim_id).
--: (LC, SliceCtx, unknown) -> (Ty | nil, Id | nil)
local function synth_andor_expr(lc, ctx, e)
	local v = view(e)
	if not v then return nil, nil end
	if v.k == "unop" and v.op == "not" then
		-- `not a` ⇒ boolean. We still synthesize the operand to keep it in-subset,
		-- but the rule needs no premise.
		local nid = lc.b.node({ t = "andor", op = "not" })
		local cid = lc.b.fresh_claim("not")
		A.add_claim(lc.state, S.has_type_claim(cid, ctx, nid, G.boolean()))
		A.add_evidence(lc.state, A.evidence({ id = lc.b.fresh_ev("not"), claim = cid, method = "synth_and_or_not" }))
		return G.boolean(), cid
	end
	-- binop and / or.
	local lty, lcid = synth_expr(lc, ctx, v.left)
	local rty, rcid = synth_expr(lc, ctx, v.right)
	if not lty or not rty or not lcid or not rcid then return nil, nil end
	local lpc = lc.state.claims[A.idk(lcid)]
	local rpc = lc.state.claims[A.idk(rcid)]
	local lref = lpc and lpc.args and lpc.args.node --[[: unknown ]]
	local rref = rpc and rpc.args and rpc.args.node --[[: unknown ]]
	local result --[[: Ty ]]
	if SUB.is_subtype(lty, G.boolean()) and SUB.is_subtype(rty, G.boolean()) then
		result = G.boolean()
	else
		result = G.union({ lty, rty })
	end
	local nid = lc.b.node({ t = "andor", op = v.op, left = lref, right = rref })
	local cid = lc.b.fresh_claim("andor")
	A.add_claim(lc.state, S.has_type_claim(cid, ctx, nid, result))
	A.add_evidence(lc.state, A.evidence({ id = lc.b.fresh_ev("andor"), claim = cid,
		method = "synth_and_or_not", inputs = { lcid, rcid } }))
	return result, cid
end

-- Lower a table constructor. Returns (ty, claim_id).
--: (LC, SliceCtx, unknown) -> (Ty | nil, Id | nil)
local function synth_table_expr(lc, ctx, e)
	local v = view(e)
	if not v then return nil, nil end
	local entries = {} --[[: { [integer]: unknown } ]]
	local arr = {} --[[: { [integer]: unknown } ]]
	local named = {} --[[: { [integer]: { key: string, ty: Ty } } ]]
	local arr_ty = {} --[[: { [integer]: Ty } ]]
	local inputs = {} --[[: { [integer]: Id } ]]
	for _, ent in ipairs(v.entries or {}) do
		local ekey = ent.key
		if type(ekey) ~= "string" then return nil, nil end
		local vty, vcid = synth_expr(lc, ctx, ent.value)
		if not vty or not vcid then return nil, nil end
		entries[#entries + 1] = { key = ekey }
		named[#named + 1] = { key = ekey, ty = vty }
		inputs[#inputs + 1] = vcid
	end
	for _, ae in ipairs(v.array or {}) do
		local vty, vcid = synth_expr(lc, ctx, ae)
		if not vty or not vcid then return nil, nil end
		arr[#arr + 1] = true
		arr_ty[#arr_ty + 1] = vty
		inputs[#inputs + 1] = vcid
	end
	local ty = S.synth_table_type(named, arr_ty)
	local nid = lc.b.node({ t = "table", entries = entries, array = arr })
	local cid = lc.b.fresh_claim("table")
	A.add_claim(lc.state, S.has_type_claim(cid, ctx, nid, ty))
	A.add_evidence(lc.state, A.evidence({ id = lc.b.fresh_ev("table"), claim = cid,
		method = "synth_table", inputs = inputs }))
	return ty, cid
end

-- check_against: emit checks_against(Γ, node, T) given the synth premise
-- (has_type(Γ, node, S)) + subtype(S, T). Returns the checks_against claim id, or
-- nil (and a marker) if S </: T. `scid` is the has_type premise, `node_ref` the
-- node, `sty` the synthesized type, `want` the expected type.
-- Read the node-ref Id out of a claim's args (the substrate ArgValue at args.node).
-- Returns the Id (space/key) or nil. The substrate stores args as `unknown`, so
-- this narrows defensively (parse-not-cast).
--: (LC, Id) -> Id | nil
local function node_ref_of(lc, claim_id)
	local c = lc.state.claims[A.idk(claim_id)]
	if not c then return nil end
	local args = c.args
	if type(args) ~= "table" then return nil end
	local n = args.node
	if type(n) ~= "table" then return nil end
	local space, key = n.space, n.key
	if type(space) ~= "string" or type(key) ~= "string" then return nil end
	return { space = space, key = key }
end

M.node_ref_of = node_ref_of

--: (LC, SliceCtx, Id, unknown, Ty, Ty) -> Id | nil
local function emit_check_against(lc, ctx, scid, node_ref, sty, want)
	if not SUB.is_subtype(sty, want) then
		mark(lc, { line = 0, construct = "type-mismatch", text = "value not a subtype of expected" })
		return nil
	end
	if type(node_ref) ~= "table" then return nil end
	local nspace, nkey = node_ref.space, node_ref.key
	if type(nspace) ~= "string" or type(nkey) ~= "string" then return nil end
	local subid = lc.b.fresh_claim("sub")
	A.add_claim(lc.state, S.subtype_claim(subid, sty, want))
	A.add_evidence(lc.state, A.evidence({ id = lc.b.fresh_ev("sub"), claim = subid, method = "subtype_witness" }))
	local caid = lc.b.fresh_claim("check")
	-- the checks_against claim must reference the SAME node id as the synth premise.
	local node_id = { space = nspace, key = nkey }
	A.add_claim(lc.state, S.checks_against_claim(caid, ctx, node_id, want))
	A.add_evidence(lc.state, A.evidence({ id = lc.b.fresh_ev("check"), claim = caid,
		method = "check_against", inputs = { scid, subid } }))
	return caid
end

M.emit_check_against = emit_check_against

-- Lower a function call `f(a1..an)`. Returns (ty, claim_id) for the call's
-- single-value result. The callee must synthesize to a concrete `fn` type
-- (annotated module/local functions, or a binding in Γ). Stdlib generic callees
-- (tonumber, string.sub, math.floor, pairs, ipairs) are NOT modeled as values in
-- Γ — calls to them are recorded as a trusted-signature boundary via
-- `stdlib_call` below; here we handle the in-file callee case.
--: (LC, SliceCtx, unknown) -> (Ty | nil, Id | nil)
local function synth_call_expr(lc, ctx, e)
	local v = view(e)
	if not v then return nil, nil end
	local fn = v.fn
	-- determine the callee type.
	local fty, fcid = synth_expr(lc, ctx, fn)
	if not fty or not fcid then return nil, nil end
	if fty.kind ~= "fn" then
		mark(lc, { line = 0, construct = "call-non-function", text = "callee is not a function type" })
		return nil, nil
	end
	local fpc = lc.state.claims[A.idk(fcid)]
	local fn_ref = fpc and fpc.args and fpc.args.node --[[: unknown ]]
	local params = fty.params or ({ fixed = {} } --[[: Params ]])
	local ret = fty.ret or ({ fixed = {} } --[[: Ret ]])
	local arg_refs = {} --[[: { [integer]: unknown } ]]
	local inputs = { fcid } --[[: { [integer]: Id } ]]
	for i, ae in ipairs(v.args or {}) do
		local aty, acid = synth_expr(lc, ctx, ae)
		if not aty or not acid then return nil, nil end
		local apc = lc.state.claims[A.idk(acid)]
		local aref = apc and apc.args and apc.args.node --[[: unknown ]]
		local wp0 --[[: Ty | nil ]]
		if i <= #params.fixed then wp0 = params.fixed[i] else wp0 = params.vararg end
		if not wp0 then
			mark(lc, { line = 0, construct = "call-arity", text = "too many arguments" })
			return nil, nil
		end
		local want_param = wp0 --[[: Ty ]]
		local caid = emit_check_against(lc, ctx, acid, aref, aty, want_param)
		if not caid then return nil, nil end
		arg_refs[#arg_refs + 1] = true
		inputs[#inputs + 1] = caid
	end
	local result --[[: Ty ]]
	if #ret.fixed >= 1 then result = ret.fixed[1] else result = G.nil_() end
	local nid = lc.b.node({ t = "call", fn = fn_ref, args = arg_refs })
	local cid = lc.b.fresh_claim("call")
	A.add_claim(lc.state, S.has_type_claim(cid, ctx, nid, result))
	A.add_evidence(lc.state, A.evidence({ id = lc.b.fresh_ev("call"), claim = cid,
		method = "synth_call", inputs = inputs }))
	return result, cid
end

-- Lower a cast expression. A checked cast `--[[: T]]` emits check_cast; a force
-- cast `--[[:! T]]` emits a trusted_signature boundary. Returns (T, claim_id).
--: (LC, SliceCtx, unknown) -> (Ty | nil, Id | nil)
local function synth_cast_expr(lc, ctx, e)
	local v = view(e)
	local vtype = v and v.type
	if type(vtype) ~= "string" then return nil, nil end
	local cast_ty = ann_type(lc, vtype, 0)
	if not cast_ty then return nil, nil end
	if v.force then
		-- force cast: a trusted boundary (never an inference source).
		local nid = lc.b.node({ t = "cast", force = true, type = TA.encode(cast_ty) })
		local cid = lc.b.fresh_claim("forcecast")
		A.add_claim(lc.state, S.has_type_claim(cid, ctx, nid, cast_ty))
		A.add_evidence(lc.state, A.evidence({ id = lc.b.fresh_ev("forcecast"), claim = cid,
			method = "trusted_signature", result = { trust = lc.stdlib_tb } }))
		return cast_ty, cid
	end
	-- checked cast `e --[[: T]]`: synth inner, then emit check_cast over a
	-- `cast` node producing a checks_against(Γ, cast_node, T) claim. The cast's
	-- VALUE type for downstream use is T. We additionally bind a has_type(cast, T)
	-- via the check_cast premise chain by surfacing the checks_against; since
	-- downstream consumers need a has_type, we re-synthesize T through a
	-- trusted-boundary has_type ONLY when the inner already checks (subtype holds).
	-- This keeps the checked cast a checking boundary (never inference) while
	-- giving the value a usable type.
	local sty, scid = synth_expr(lc, ctx, v.expr)
	if not sty or not scid then return nil, nil end
	local spc = lc.state.claims[A.idk(scid)]
	local inner_ref = spc and spc.args and spc.args.node --[[: unknown ]]
	if not SUB.is_subtype(sty, cast_ty) then
		mark(lc, { line = 0, construct = "checked-cast-fail", text = "inner not a subtype of cast type" })
		return nil, nil
	end
	-- subtype(inner, T) witness + check_cast (checks_against) for fidelity.
	local subid = lc.b.fresh_claim("castsub")
	A.add_claim(lc.state, S.subtype_claim(subid, sty, cast_ty))
	A.add_evidence(lc.state, A.evidence({ id = lc.b.fresh_ev("castsub"), claim = subid, method = "subtype_witness" }))
	local cast_node = lc.b.node({ t = "cast", force = false, type = TA.encode(cast_ty), expr = inner_ref })
	local ckid = lc.b.fresh_claim("castchk")
	A.add_claim(lc.state, S.checks_against_claim(ckid, ctx, cast_node, cast_ty))
	A.add_evidence(lc.state, A.evidence({ id = lc.b.fresh_ev("castchk"), claim = ckid,
		method = "check_cast", inputs = { scid, subid } }))
	lc.requested[#lc.requested + 1] = ckid
	return cast_ty, ckid
end

synth_expr = function(lc, ctx, e)
	local v = view(e)
	if not v then return nil, nil end
	local k = v.k
	if k == "oos" then mark(lc, e); return nil, nil end
	if k == "num" or k == "str" or k == "bool" or k == "nil" then
		return synth_lit_expr(lc, ctx, e)
	end
	if k == "name" then return synth_var_expr(lc, ctx, e) end
	if k == "index" then return synth_index_expr(lc, ctx, e) end
	if k == "cast" then return synth_cast_expr(lc, ctx, e) end
	if k == "call" then return synth_call_expr(lc, ctx, e) end
	if k == "table" then return synth_table_expr(lc, ctx, e) end
	if k == "unop" and v.op == "not" then return synth_andor_expr(lc, ctx, e) end
	if k == "binop" and (v.op == "and" or v.op == "or") then return synth_andor_expr(lc, ctx, e) end
	if k == "binop" then
		-- arithmetic / comparison / concat. Comparisons ⇒ boolean; arithmetic over
		-- numbers ⇒ number; concat ⇒ string. v1 models the result coarsely (no
		-- operator-metamethod dispatch, §1.4) — adequate for guards/returns.
		local op = v.op or "?"
		-- still synthesize operands so they stay in-subset (markers propagate).
		local _, lcid = synth_expr(lc, ctx, v.left)
		local _, rcid = synth_expr(lc, ctx, v.right)
		local _ = lcid; local _ = rcid
		if op == "==" or op == "~=" or op == "<" or op == ">" or op == "<=" or op == ">=" then
			-- a comparison result is boolean; emit it as a fresh boolean literal-like
			-- has_type via synth (no dedicated node) — we model it as a var-free
			-- boolean by an out-of-subset-free path: a `not`-style boolean node.
			local nid = lc.b.node({ t = "andor", op = "not" })
			local cid = lc.b.fresh_claim("cmp")
			A.add_claim(lc.state, S.has_type_claim(cid, ctx, nid, G.boolean()))
			A.add_evidence(lc.state, A.evidence({ id = lc.b.fresh_ev("cmp"), claim = cid, method = "synth_and_or_not" }))
			return G.boolean(), cid
		end
		if op == ".." then
			-- concat ⇒ string; model as a string literal-typed node is unsound, so
			-- record as out-of-subset (string from concat needs a synth rule v1
			-- lacks — operator typing is §1.4). Honest marker.
			mark(lc, { line = 0, construct = "operator-concat", text = ".." })
			return nil, nil
		end
		-- arithmetic. v1 has no numeric operator synth rule; mark it (honest).
		mark(lc, { line = 0, construct = "operator-arith:" .. op, text = op })
		return nil, nil
	end
	if k == "func" then
		-- a bare anonymous function used in an expression position WITHOUT a
		-- surrounding annotation cannot be synthesized in v1 (function synthesis
		-- requires the declared fn type, §7.1). Mark it.
		mark(lc, { line = 0, construct = "unannotated-closure", text = "function(...)" })
		return nil, nil
	end
	if k == "indexdyn" then
		mark(lc, { line = 0, construct = "dynamic-index", text = "t[expr]" })
		return nil, nil
	end
	if k == "vararg" then
		mark(lc, { line = 0, construct = "vararg-expr", text = "..." })
		return nil, nil
	end
	mark(lc, { line = 0, construct = "expr:" .. tostring(k), text = tostring(k) })
	return nil, nil
end

M.synth_expr = synth_expr

-- ════════════════════════════════════════════════════════════════════════════
-- §5. Statement lowering
-- ════════════════════════════════════════════════════════════════════════════
--
-- The statement walker threads a SliceCtx (returning the EXTENDED context after a
-- binding statement) and emits claims. `ret_ty` is the enclosing function's
-- declared return type (for checking `return` statements), or nil at top level.

local lower_block --[[: (LC, SliceCtx, unknown, Ty | nil) -> nil ]]

-- Recognize an if-test expression as a v1 guard over a single variable; returns
-- (var, Guard) or nil. Reuses the adapter's recognizer over a comparison-shaped
-- node. The lowering converts its binop AST into the recognizer's node grammar.
--: (unknown) -> unknown
local function ast_to_guard_node(e)
	local v = view(e)
	if not v then return nil end
	if v.k == "name" then return { t = "var", name = v.name } end
	if v.k == "num" then return { t = "lit", lit = v.int and "int" or "num", v = v.v } end
	if v.k == "str" then return { t = "lit", lit = "str", v = v.v } end
	if v.k == "bool" then return { t = "lit", lit = "bool", v = v.v } end
	if v.k == "nil" then return { t = "lit", lit = "nil" } end
	if v.k == "index" then
		local obj = ast_to_guard_node(v.obj)
		if not obj then return nil end
		return { t = "index", obj = obj, field = v.field }
	end
	if v.k == "call" then
		local fn = ast_to_guard_node(v.fn)
		local args = {} --[[: { [integer]: unknown } ]]
		for _, a in ipairs(v.args or {}) do
			local an = ast_to_guard_node(a)
			if not an then return nil end
			args[#args + 1] = an
		end
		return { t = "call", fn = fn, args = args }
	end
	if v.k == "unop" and v.op == "not" then
		local inner = ast_to_guard_node(v.expr)
		if not inner then return nil end
		return { t = "andor", op = "not", left = inner }
	end
	if v.k == "binop" then
		if v.op == "==" or v.op == "~=" then
			local l = ast_to_guard_node(v.left)
			local r = ast_to_guard_node(v.right)
			if not l or not r then return nil end
			return { t = "cmp", op = v.op == "==" and "eq" or "ne", left = l, right = r }
		end
		if v.op == "and" or v.op == "or" then
			local l = ast_to_guard_node(v.left)
			local r = ast_to_guard_node(v.right)
			if not l or not r then return nil end
			return { t = "andor", op = v.op, left = l, right = r }
		end
	end
	return nil
end

-- Build a narrows claim + narrow_guard evidence for guard `g` refining `var` whose
-- pre-guard type is `pre_ty` under `ctx`. Returns (T_true, T_false, claim_id) or
-- nil. The pre-guard has_type premise is built here (synth_var under ctx).
--: (LC, SliceCtx, unknown, string, Ty) -> (Ty | nil, Ty | nil, Id | nil)
local function emit_narrows(lc, ctx, guard_node, var, pre_ty)
	-- decode the guard via the adapter (operand-order symmetric, portable lits).
	local guard = P.recognize_guard(guard_node)
	if type(guard) ~= "table" then return nil, nil, nil end
	-- the pure refinement (decode lits back to Ty for NAR.refine).
	-- recognize_guard emits lits as PTy; decode them for NAR.refine.
	--: (unknown) -> unknown
	local function decode_guard(gn)
		local g = view(gn)
		if not g then return nil end
		local gk = g.g
		if gk == "not" then
			local inner = decode_guard(g.inner)
			if not inner then return nil end
			return { g = "not", inner = inner }
		end
		if gk == "and" or gk == "or" then
			local l = decode_guard(g.left)
			local r = decode_guard(g.right)
			if not l or not r then return nil end
			return { g = gk, left = l, right = r }
		end
		if gk == "truthy" then return { g = "truthy", var = g.var } end
		if gk == "nil_eq" then return { g = "nil_eq", var = g.var, eq = g.eq } end
		if gk == "type_eq" then return { g = "type_eq", var = g.var, tyname = g.tyname } end
		if gk == "lit_eq" then return { g = "lit_eq", var = g.var, lit = TA.decode(g.lit) } end
		if gk == "tag_eq" then return { g = "tag_eq", var = g.var, field = g.field, lit = TA.decode(g.lit) } end
		return nil
	end
	local dguard = decode_guard(guard)
	if type(dguard) ~= "table" then return nil, nil, nil end
	local t_true, t_false = NAR.refine(dguard --[[: Guard ]], var, pre_ty)
	if not t_true or not t_false then return nil, nil, nil end
	-- pre-guard premise: has_type(Γ, var_node, pre_ty).
	local var_node = lc.b.node({ t = "var", name = var })
	local preid = lc.b.fresh_claim("npre")
	A.add_claim(lc.state, S.has_type_claim(preid, ctx, var_node, pre_ty))
	A.add_evidence(lc.state, A.evidence({ id = lc.b.fresh_ev("npre"), claim = preid, method = "synth_var" }))
	-- the guard artifact (the recognizer's portable Guard, decode_guard re-interns).
	local gid = lc.b.node(guard)
	local nid = lc.b.fresh_claim("narrows")
	A.add_claim(lc.state, S.narrows_claim(nid, ctx, gid, var, t_true, t_false))
	A.add_evidence(lc.state, A.evidence({ id = lc.b.fresh_ev("narrows"), claim = nid,
		method = "narrow_guard", inputs = { preid } }))
	lc.requested[#lc.requested + 1] = nid
	return t_true, t_false, nid
end

M.emit_narrows = emit_narrows

-- The single variable a guard refines (for narrowing the if-body context), or nil.
--: (unknown) -> string | nil
local function guard_var(guard_node)
	local g = view(P.recognize_guard(guard_node))
	if not g then return nil end
	if type(g.var) == "string" then return g.var end
	-- a tag_eq's refined variable is the object var.
	local inner = view(g.inner)
	if g.g == "not" and inner and type(inner.var) == "string" then return inner.var end
	return nil
end

--: (LC, SliceCtx, unknown, Ty | nil) -> nil
local function lower_stmt(lc, ctx, s, ret_ty)
	local sv = view(s)
	if not sv then return end
	local k = sv.k
	if k == "oos" then mark(lc, s); return end

	if k == "local" then
		-- local a, b = e1, e2  (optionally annotated via `--:` on the decl line).
		local names = sv.names or {}
		local values = sv.values or {}
		local lsig = sv.sig
		local decl_ty = type(lsig) == "string" and ann_type(lc, lsig, 0) or nil --[[: Ty | nil ]]
		-- single-target case (the common one); multi-assignment from a multi-return
		-- call binds slots positionally — modeled below.
		if #names == 1 then
			local name = names[1]
			if type(name) ~= "string" then return end
			local val = values[1]
			if not val then
				-- `local x` with no initializer: binds nil (or the annotation).
				ctx[#ctx + 1] = { name = name, type = TA.encode(decl_ty or G.nil_()) }
				return
			end
			local vty, vcid = synth_expr(lc, ctx, val)
			if not vty or not vcid then
				-- value out-of-subset: bind the annotation if present (so later
				-- statements stay in-subset), else stop binding (name unbound).
				if decl_ty then
					local dt0 = decl_ty --[[: Ty ]]
					ctx[#ctx + 1] = { name = name, type = TA.encode(dt0) }
				end
				return
			end
			if decl_ty then
				local dt = decl_ty --[[: Ty ]]
				-- annotated local: CHECK value ⇐ decl_ty (inference boundary), bind decl_ty.
				local vpc = lc.state.claims[A.idk(vcid)]
				local vref = vpc and vpc.args and vpc.args.node --[[: unknown ]]
				local caid = emit_check_against(lc, ctx, vcid, vref, vty, dt)
				if caid then lc.requested[#lc.requested + 1] = caid end
				ctx[#ctx + 1] = { name = name, type = TA.encode(dt) }
			else
				-- unannotated: bind the synthesized type.
				lc.requested[#lc.requested + 1] = vcid
				ctx[#ctx + 1] = { name = name, type = TA.encode(vty) }
			end
			return
		end
		-- multi-assignment `local a, b = f()`: bind from the call's multi-return Ret.
		-- v1's synth_call returns slot 1; multi-slot binding is modeled by reading
		-- the callee's declared Ret for slot i. Only the single-call RHS form is
		-- handled; anything else marks out-of-subset.
		local call = view(values[1])
		if #values == 1 and call and call.k == "call" then
			-- synth the callee to read Ret.
			local fnv = view(call.fn)
			local fname = fnv and fnv.name
			local fty = type(fname) == "string" and ctx_get(ctx, fname) or nil
			if fty and fty.kind == "fn" then
				local ret = fty.ret or ({ fixed = {} } --[[: Ret ]])
				-- lower the call (slot 1) for evidence; bind each name from Ret slots.
				local _, ccid = synth_call_expr(lc, ctx, values[1])
				if ccid then lc.requested[#lc.requested + 1] = ccid end
				for i = 1, #names do
					local nm = names[i]
					if type(nm) == "string" then
						local slot = ret.fixed[i] or G.nil_()
						ctx[#ctx + 1] = { name = nm, type = TA.encode(slot) }
					end
				end
				return
			end
		end
		-- unmodeled multi-assignment.
		mark(lc, { line = 0, construct = "multi-assign", text = "local a, b = ..." })
		return

	elseif k == "localfunc" or k == "funcdecl" then
		-- a function definition. v1 requires the `--:` signature (§7.1). Without it,
		-- mark out-of-subset (unannotated function synthesis is the §10 edge).
		local fsig = sv.sig
		if type(fsig) ~= "string" then
			mark(lc, { line = 0, construct = "unannotated-function", text = "function " .. tostring(sv.name) })
			return
		end
		local fty = ann_type(lc, fsig, 0)
		if not fty or fty.kind ~= "fn" then
			if fty then mark(lc, { line = 0, construct = "function-sig-not-fn", text = sv.sig }) end
			return
		end
		-- bind the function name in the OUTER context (so later calls resolve).
		local fname --[[: string | nil ]]
		local tgtv = view(sv.target)
		local svname = sv.name
		local tname = tgtv and tgtv.name
		local tfield = tgtv and tgtv.field
		if k == "localfunc" and type(svname) == "string" then fname = svname
		elseif tgtv and tgtv.k == "name" and type(tname) == "string" then fname = tname
		elseif tgtv and tgtv.k == "index" and type(tfield) == "string" then fname = tfield end
		if fname then ctx[#ctx + 1] = { name = fname, type = TA.encode(fty) } end
		-- check the body under Γ extended with the params (each param : declared type).
		local params = fty.params or ({ fixed = {} } --[[: Params ]])
		if sv.is_method then
			-- a method def carries an implicit `self` first param — out-of-subset
			-- (v1 params are positional; the survey tags self separately).
			mark(lc, { line = 0, construct = "named-param-self", text = "self" })
		end
		local body_ctx = {} --[[: SliceCtx ]]
		for i = 1, #ctx do body_ctx[i] = ctx[i] end
		for i, p0 in ipairs(sv.params or {}) do
			local pname = p0.name
			local pty = params.fixed[i]
			if type(pname) ~= "string" then
				-- skip
			elseif not pty then
				mark(lc, { line = 0, construct = "param-arity", text = pname })
			else
				body_ctx[#body_ctx + 1] = { name = pname, type = TA.encode(pty) }
			end
		end
		local rty --[[: Ty ]]
		local ret = fty.ret or ({ fixed = {} } --[[: Ret ]])
		local r0 = ret.fixed[1]
		if r0 then rty = r0 else rty = G.nil_() end
		lower_block(lc, body_ctx, sv.body, rty)
		return

	elseif k == "return" then
		local values = sv.values or {}
		if #values == 0 then return end
		-- single-return: check value ⇐ ret_ty.
		local vty, vcid = synth_expr(lc, ctx, values[1])
		if not vty or not vcid then
			if #values > 1 then mark(lc, { line = 0, construct = "multi-return", text = "return a, b" }) end
			return
		end
		local rt = ret_ty
		if rt then
			local vpc = lc.state.claims[A.idk(vcid)]
			local vref = vpc and vpc.args and vpc.args.node --[[: unknown ]]
			local caid = emit_check_against(lc, ctx, vcid, vref, vty, rt)
			if caid then lc.requested[#lc.requested + 1] = caid end
		else
			lc.requested[#lc.requested + 1] = vcid
		end
		if #values > 1 then
			mark(lc, { line = 0, construct = "multi-return", text = "return a, b" })
		end
		return

	elseif k == "if" then
		-- each clause's test is a guard; the body is checked under refined Γ.
		-- We thread the simplest case: a single guard refining one variable, with
		-- the truthy refinement applied to the body context. elseif/else bodies
		-- are checked under the unrefined (sound-wider) context.
		for _, cl0 in ipairs(sv.clauses or {}) do
			local cl = view(cl0)
			local gnode = cl and ast_to_guard_node(cl.test) or nil
			local body_ctx = {} --[[: SliceCtx ]]
			for i = 1, #ctx do body_ctx[i] = ctx[i] end
			if gnode then
				local var = guard_var(gnode)
				if var then
					local pre = ctx_get(ctx, var)
					if pre then
						local t_true = emit_narrows(lc, ctx, gnode, var, pre)
						if t_true then
							-- refine the body context: var : T_true (shadowing).
							body_ctx[#body_ctx + 1] = { name = var, type = TA.encode(t_true) }
						end
					end
				end
			end
			lower_block(lc, body_ctx, cl and cl.body, ret_ty)
		end
		if sv.else_body then
			local ectx = {} --[[: SliceCtx ]]
			for i = 1, #ctx do ectx[i] = ctx[i] end
			lower_block(lc, ectx, sv.else_body, ret_ty)
		end
		return

	elseif k == "forin" then
		-- for-in pairs/ipairs only (§5.2). The iterator must be pairs(t)/ipairs(t).
		local iter = view(sv.iter)
		local ifn = iter and view(iter.fn)
		local iname = ifn and ifn.name
		if not iter or iter.k ~= "call" or not ifn or ifn.k ~= "name"
			or (iname ~= "pairs" and iname ~= "ipairs") then
			mark(lc, { line = 0, construct = "general-iterator", text = "for ... in <expr>" })
			return
		end
		local kind = iname
		local iargs = iter.args or {}
		local targ = iargs[1]
		local tty, tcid = synth_expr(lc, ctx, targ)
		if not tty or not tcid then return end
		local tpc = lc.state.claims[A.idk(tcid)]
		local tref = tpc and tpc.args and tpc.args.node --[[: unknown ]]
		local kv0 --[[: { key: Ty, val: Ty } | nil ]]
		if kind == "pairs" then kv0 = S.pairs_kv(tty) else kv0 = S.ipairs_kv(tty) end
		if not kv0 then
			mark(lc, { line = 0, construct = "iterate-non-table", text = kind })
			return
		end
		local kv = kv0 --[[: { key: Ty, val: Ty } ]]
		local names = sv.names or {}
		local body_ctx = {} --[[: SliceCtx ]]
		for i = 1, #ctx do body_ctx[i] = ctx[i] end
		for slot = 1, math.min(2, #names) do
			local bound --[[: Ty ]]
			if slot == 1 then bound = kv.key else bound = kv.val end
			local lvnode = lc.b.node({ t = "loop_var", iter = kind, table = tref, slot = slot })
			local lvcid = lc.b.fresh_claim("loopvar")
			A.add_claim(lc.state, S.has_type_claim(lvcid, ctx, lvnode, bound))
			A.add_evidence(lc.state, A.evidence({ id = lc.b.fresh_ev("loopvar"), claim = lvcid,
				method = "synth_loop_var", inputs = { tcid } }))
			lc.requested[#lc.requested + 1] = lvcid
			local lvname = names[slot]
			if type(lvname) == "string" and lvname ~= "_" then
				body_ctx[#body_ctx + 1] = { name = lvname, type = TA.encode(bound) }
			end
		end
		lower_block(lc, body_ctx, sv.body, ret_ty)
		return

	elseif k == "fornum" then
		local ivar = lc.b.node({ t = "numeric_for_var" })
		local icid = lc.b.fresh_claim("fornum")
		local IntNum = G.union({ G.integer(), G.number() })
		A.add_claim(lc.state, S.has_type_claim(icid, ctx, ivar, IntNum))
		A.add_evidence(lc.state, A.evidence({ id = lc.b.fresh_ev("fornum"), claim = icid, method = "synth_numeric_for_var" }))
		lc.requested[#lc.requested + 1] = icid
		local body_ctx = {} --[[: SliceCtx ]]
		for i = 1, #ctx do body_ctx[i] = ctx[i] end
		local fvar = sv.var
		if type(fvar) == "string" then
			body_ctx[#body_ctx + 1] = { name = fvar, type = TA.encode(IntNum) }
		end
		lower_block(lc, body_ctx, sv.body, ret_ty)
		return

	elseif k == "while" or k == "repeat" or k == "do" then
		local body_ctx = {} --[[: SliceCtx ]]
		for i = 1, #ctx do body_ctx[i] = ctx[i] end
		lower_block(lc, body_ctx, sv.body, ret_ty)
		return

	elseif k == "callstmt" then
		-- a call in statement position: synth it (effects/typecheck its args).
		local _, ccid = synth_call_expr(lc, ctx, sv.call)
		if ccid then lc.requested[#lc.requested + 1] = ccid end
		return

	elseif k == "assign" then
		-- field/index or variable assignment. v1 checks each write against the
		-- declared element/field type (flow-insensitive). For an in-subset record
		-- field write `t.f = v`, check v ⇐ field-type. Multi-target / dynamic-key
		-- writes are marked.
		local targets = sv.targets or {}
		local values = sv.values or {}
		if #targets == 1 and #values == 1 then
			local tgt = view(targets[1])
			local vty, vcid = synth_expr(lc, ctx, values[1])
			if not vty or not vcid then return end
			if tgt and tgt.k == "index" and type(tgt.field) == "string" then
				local oty = synth_expr(lc, ctx, tgt.obj)
				if oty then
					local fty = S.index_result(oty, tgt.field, nil)
					if fty then
						local vpc = lc.state.claims[A.idk(vcid)]
						local vref = vpc and vpc.args and vpc.args.node --[[: unknown ]]
						local caid = emit_check_against(lc, ctx, vcid, vref, vty, fty)
						if caid then lc.requested[#lc.requested + 1] = caid end
						return
					end
				end
				mark(lc, { line = 0, construct = "field-assign", text = "t.f = v" })
				return
			elseif tgt and tgt.k == "name" then
				-- reassigning a local: v1 is flow-insensitive; just request the value.
				lc.requested[#lc.requested + 1] = vcid
				return
			elseif tgt and tgt.k == "indexdyn" then
				mark(lc, { line = 0, construct = "dynamic-index-assign", text = "t[e] = v" })
				return
			end
		end
		mark(lc, { line = 0, construct = "multi-assign", text = "a, b = ..." })
		return

	elseif k == "break" then
		return
	end

	mark(lc, { line = 0, construct = "stmt:" .. tostring(k), text = tostring(k) })
end

-- Does a block UNCONDITIONALLY exit (its last statement is a return/break)?
-- Used to detect the `if not x then return end` post-guard-narrowing idiom (§6.1):
-- when the guard body exits, the fall-through path takes the guard's FALSY
-- refinement, applied to the rest of the enclosing block.
--: (unknown) -> boolean
local function block_exits(blk)
	local b = view(blk)
	if not b then return false end
	local stmts = b.stmts
	if not stmts then return false end
	local last = view(stmts[#stmts])
	if not last then return false end
	return last.k == "return" or last.k == "break"
end

M.block_exits = block_exits

lower_block = function(lc, ctx, blk, ret_ty)
	local b = view(blk)
	if not b then return end
	local stmts = b.stmts
	if not stmts then return end
	for _, s in ipairs(stmts) do
		-- post-guard narrowing: `if <guard> then <exiting body> end` (no elseif/else)
		-- narrows the REST of this block by the guard's FALSY refinement (§6.1). We
		-- mutate `ctx` in place so subsequent statements see the refined binding.
		local sv = view(s)
		local clauses --[[: { [integer]: unknown } ]] = {}
		if sv and sv.clauses then clauses = sv.clauses end
		local cl1 = view(clauses[1])
		if sv and sv.k == "if" and not sv.else_body and #clauses == 1
			and cl1 and block_exits(cl1.body) then
			local gnode = ast_to_guard_node(cl1.test)
			local var = gnode and guard_var(gnode) or nil
			-- lower the if (emits the truthy-body narrowing + body claims).
			lower_stmt(lc, ctx, s, ret_ty)
			if var and gnode then
				local pre = ctx_get(ctx, var)
				if pre then
					local _, t_false = emit_narrows(lc, ctx, gnode, var, pre)
					if t_false then
						ctx[#ctx + 1] = { name = var, type = TA.encode(t_false) }
					end
				end
			end
		else
			lower_stmt(lc, ctx, s, ret_ty)
		end
	end
end

-- ════════════════════════════════════════════════════════════════════════════
-- §6. Public entry: lower(source, filename) -> LowerResult
-- ════════════════════════════════════════════════════════════════════════════

-- `opts.read_file` (a `(path) -> (src | nil, err | nil)` cap) enables CROSS-MODULE
-- type-alias resolution (§6.6): the entry's `require`d `lib/` modules' top-level
-- `--::` aliases are imported into the alias env, and the cross-artifact records
-- (exporting Artifact + per-alias Observation + one `cross_module_alias`
-- TrustBoundary per module + a Dependency from each requested claim to that
-- boundary) are added to the state. CAPS-FIRST: with no `read_file`, cross-module
-- imports resolve to no aliases — never a reach for `io`.
--: (string, string, ({ read_file?: (string) -> (string | nil, string | nil) } | nil)) -> (LowerResult | nil, string | nil)
function M.lower(source, filename, opts)
	G.reset()
	local _ = filename
	-- 0. cross-module import pass (§6.6) — assemble the imported alias base env.
	local imp = XM.resolve(source, opts)
	-- 1. scan annotations (aliases + signatures + their markers), seeded with the
	--    imported cross-module aliases so a local alias shadows an imported one.
	local scan = scan_source(source, imp.env)
	-- 2. lex + parse the statements into the §5 AST.
	local toks, lerr = lex(source)
	if not toks then return nil, lerr end
	local parser = new_parser(toks, scan.anns_by_line)
	local chunk = parser.parse_chunk()
	-- 3. build the claim/evidence graph.
	local state = A.new_state()
	-- one shared trusted boundary for force casts / stdlib (visible in the summary).
	local tb = A.trust_boundary({ id = A.id("trust", "slice-stdlib"), kind = "stdlib_signature", issuer = "crescent.slice.v1" })
	A.add_trust_boundary(state, tb)
	-- cross-module records (§6.6.5/§6.6.6): one TrustBoundary per imported module,
	-- the exporting source_text Artifact, and a per-imported-alias Observation. The
	-- per-claim Dependency on the boundary is added after the claim graph is built.
	local xmodule_tbs = {} --[[: { [integer]: Id } ]]
	for _, rec in ipairs(imp.imports) do
		local art_id = A.id("artifact", "xmod-src:" .. rec.path)
		A.add_artifact(state, A.artifact({ id = art_id, kind = "source_text", content_ref = rec.path }))
		for _, name in ipairs(rec.names) do
			A.add_observation(state, A.observation({
				id = A.id("observation", "xmod-alias:" .. rec.path .. ":" .. name),
				predicate = "alias", args = { name = name, module = rec.module },
				source_artifacts = { art_id }, support = "trusted",
			}))
		end
		local xtb = A.trust_boundary({
			id = A.id("trust", "xmod:" .. rec.path),
			kind = "cross_module_alias", issuer = "crescent.slice.v1",
			covers = { module = rec.module, path = rec.path, names = rec.names },
			policy = "alias Ty admitted from exporting module's --:: declaration; the exporting module's parse is trusted, not re-checked",
		})
		A.add_trust_boundary(state, xtb)
		xmodule_tbs[#xmodule_tbs + 1] = xtb.id
	end
	local b = new_builder(state)
	local lc = { b = b, requested = {}, markers = {}, aliases = scan.aliases,
		stdlib_tb = tb.id, state = state } --[[: LC ]]
	-- carry the scan-phase + import-pass markers (alias errors, dynamic requires).
	for _, m2 in ipairs(scan.markers) do lc.markers[#lc.markers + 1] = m2 end
	for _, m3 in ipairs(imp.markers) do lc.markers[#lc.markers + 1] = m3 end
	for _, er in ipairs(imp.errors) do
		lc.markers[#lc.markers + 1] = { line = 0, construct = "xmodule-alias-error",
			text = er.module .. ":" .. er.name .. ": " .. er.err }
	end
	lower_block(lc, {}, chunk, nil)

	-- 4b. cross-module dependency records (§6.6.3): every requested claim was checked
	--     under the cross-module alias env, so each rides the cross_module_alias trust
	--     boundary. Record the dependency with the correct invalidation field so an
	--     incremental/audit tool can reason about staleness (the v1 evaluation strategy
	--     is re-check-everything; the RECORDS are precise). Dependencies live on the
	--     driver-level LowerResult (the object model puts them in the CheckResult
	--     dependency graph, NOT on AnalysisState — the substrate shape is untouched).
	local dependencies = {} --[[: { [integer]: Dependency } ]]
	for _, tbid in ipairs(xmodule_tbs) do
		for _, cid in ipairs(lc.requested) do
			dependencies[#dependencies + 1] = A.dependency({
				from_claim = cid, kind = A.DEP_TRUSTED_BOUNDARY, target = tbid,
				invalidation = "exporting module's --:: alias body changed",
			})
		end
	end

	-- 4. classify the verdict.
	local expected = "CLEAN" --: string
	local has_construct = false --: boolean
	local has_finding = false --: boolean
	for _, mk in ipairs(lc.markers) do
		-- a marker with a recognized construct tag ⇒ OUT-OF-SUBSET; an internal
		-- finding (type-mismatch / *-error) ⇒ FINDINGS.
		local c = mk.construct or ""
		if c:find("error$") or c == "type-mismatch" or c:find("%-fail$") then
			has_finding = true
		else
			has_construct = true
		end
	end
	if has_construct then expected = "OUT-OF-SUBSET"
	elseif has_finding then expected = "FINDINGS"
	else expected = "CLEAN" end

	local sigs = {} --[[: { [string]: Ty } ]]
	local imports_out = {} --[[: { [integer]: ImportRecord } ]]
	for _, r in ipairs(imp.imports) do imports_out[#imports_out + 1] = r end
	local result = {
		state = state,
		requested = lc.requested,
		observations = scan.observations,
		expected = expected,
		markers = lc.markers,
		aliases = scan.aliases,
		signatures = sigs,
		imports = imports_out,
		dependencies = dependencies,
	} --[[: LowerResult ]]
	return result
end

return M
