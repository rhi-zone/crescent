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
--:: ImportRecord = { module: string, path: string, names: string[], form: string, digest: string }
--:: LowerResult = { state: AnalysisState, requested: Id[], observations: { [integer]: unknown }, expected: string, markers: { [integer]: LowerMarker }, aliases: AliasEnv, signatures: { [string]: Ty }, imports: { [integer]: ImportRecord }, dependencies: { [integer]: Dependency }, module_ret_ty?: Ty }

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
				-- method call o:m(args) desugars to o.m(o, args) (§6.7.5). We build a
				-- `methodcall` node carrying the receiver, method name, and args; the
				-- synth layer prepends the receiver as the first argument.
				advance()
				local nm = peek()
				if nm.kind ~= "name" then return oos("method-call", s.line, ":") end
				advance()
				local recv = base --[[: unknown ]]
				-- the call arguments. Lua method calls always carry an arg list (or a
				-- single string/table arg).
				local mn = peek()
				local margs = {} --[[: { [integer]: unknown } ]]
				if mn.kind == "(" then
					advance()
					if not check(")") then
						while true do
							margs[#margs + 1] = parse_expr()
							if not accept(",") then break end
						end
					end
					if not accept(")") then return oos("method-call", s.line, "(") end
				elseif mn.kind == "string" then
					advance(); margs[1] = { k = "str", v = mn.text }
				elseif mn.kind == "{" then
					margs[1] = parse_table()
				else
					return oos("method-call", s.line, ":" .. nm.text)
				end
				base = { k = "methodcall", recv = recv, method = nm.text, args = margs }
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
			if type(first) == "table" and (first.k == "call" or first.k == "methodcall") then
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

-- §6.7.2 M-table accumulation: rebind `obj_name` to its record extended with field
-- `field : fty` (replacing an existing field of the same name). Only fires when
-- `obj_name`'s current binding is a `rec` (the module-table-local convention
-- `local M = {} ... function M.f`). When it is not a rec (`M` not a known table),
-- this is a no-op and returns false — the caller falls back to the ordinary binding.
-- The rebinding appends a fresh, shadowing ctx entry (most-recent-wins), so the
-- accumulated module type is what a later `return M` / cross-module require reads.
-- §9.14 F3 (simple alias): when `mod_table_aliases` maps `obj_name → orig`, the
-- field accumulation is ALSO applied to `orig` (e.g. `local A = M; A.f = …`
-- propagates to M so `return M` includes `f`). Only the trivially-trackable single-
-- direct-alias form is covered; conditional/nested alias analysis is a deferral.
--: (SliceCtx, string, string, Ty, ({ [string]: string }) | nil) -> boolean
local function ctx_set_field(ctx, obj_name, field, fty, mod_table_aliases)
	local cur = ctx_get(ctx, obj_name)
	if not cur or cur.kind ~= "rec" then return false end
	local fields = {} --[[: { [integer]: { key: string, ty: Ty, optional: boolean, readonly: boolean } } ]]
	local replaced = false --: boolean
	for _, f in ipairs(cur.fields or {}) do
		if f.key == field then
			fields[#fields + 1] = { key = field, ty = fty, optional = false, readonly = false }
			replaced = true
		else
			fields[#fields + 1] = { key = f.key, ty = f.ty, optional = f.optional, readonly = f.readonly }
		end
	end
	if not replaced then
		fields[#fields + 1] = { key = field, ty = fty, optional = false, readonly = false }
	end
	local new_rec = G.rec(fields, cur.rows or "closed")
	ctx[#ctx + 1] = { name = obj_name, type = TA.encode(new_rec) }
	-- §9.14 F3 alias propagation: if obj_name is a direct alias of another rec-local,
	-- mirror the field accumulation onto the original name too.
	local orig = mod_table_aliases and mod_table_aliases[obj_name]
	if orig and type(orig) == "string" then
		local orig_cur = ctx_get(ctx, orig)
		if orig_cur and orig_cur.kind == "rec" then
			local orig_fields = {} --[[: { [integer]: { key: string, ty: Ty, optional: boolean, readonly: boolean } } ]]
			local orig_replaced = false --: boolean
			for _, f in ipairs(orig_cur.fields or {}) do
				if f.key == field then
					orig_fields[#orig_fields + 1] = { key = field, ty = fty, optional = false, readonly = false }
					orig_replaced = true
				else
					orig_fields[#orig_fields + 1] = { key = f.key, ty = f.ty, optional = f.optional, readonly = f.readonly }
				end
			end
			if not orig_replaced then
				orig_fields[#orig_fields + 1] = { key = field, ty = fty, optional = false, readonly = false }
			end
			ctx[#ctx + 1] = { name = orig, type = TA.encode(G.rec(orig_fields, orig_cur.rows or "closed")) }
		end
	end
	return true
end

-- The lowering result accumulators ride a `LC` (lowering context) table threaded
-- through the walk: builder, requested-claim list, marker list, alias env,
-- trusted-boundary id (one shared stdlib boundary), and the current SliceCtx.
--:: LC = { b: Builder, requested: { [integer]: Id }, markers: { [integer]: LowerMarker }, aliases: AliasEnv, stdlib_tb: Id, state: AnalysisState, return_premise_sink?: { [integer]: { [integer]: Id } }, func_depth?: integer, module_ret_ty?: Ty, resolve_module_type?: (string) -> (Ty | nil), mod_table_aliases?: { [string]: string } }

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
--::   test?: unknown, recv?: unknown, method?: string, operand?: unknown,
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

-- Forward declarations for the expression-position closure rules (§6.8). Defined
-- after `lower_block` (they lower a closure body). `synth_func_expr` is the
-- SYNTHESIS-mode rule (params `unknown`, return body-synthesized); `check_func_expr`
-- is the CHECK-mode rule (the expected fn type's param types are pushed onto the
-- closure params — bidirectionality's signature move). `check_expr` is the mode
-- switch: it routes a `func` node against an `fn` expected type into check-mode,
-- and everything else through synth + subtype.
local synth_func_expr --[[: (LC, SliceCtx, unknown) -> (Ty | nil, Id | nil) ]]
local check_func_expr --[[: (LC, SliceCtx, unknown, Ty) -> (Ty | nil, Id | nil) ]]
local check_expr --[[: (LC, SliceCtx, unknown, Ty) -> (Ty | nil, Id | nil) ]]

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
	-- §6.7.2 `require("lib.y")` recognition: a static string-literal require resolves
	-- to the required module's synthesized VALUE type (the M-table rec). This is a
	-- path-dependent type no fixed `fn` in Γ expresses, so the lowering resolves it at
	-- the call site (like the cross-module alias pass), recording a `cross_module_value`
	-- trust boundary. Only fires when `require` is NOT a local binding (an in-file
	-- `local require = ...` shadow stays the ordinary call). A dynamic/non-lib require
	-- falls through to the ordinary path (→ unbound-name / dynamic-require marker).
	do
		local fnv = view(fn)
		if fnv and fnv.k == "name" and fnv.name == "require" and not ctx_get(ctx, "require") then
			local args = v.args or {}
			local a1 = view(args[1])
			local a1v = a1 and a1.v
			if a1 and a1.k == "str" and type(a1v) == "string" and #args == 1 then
				local modpath = a1v --[[: string ]]
				local resolve = lc.resolve_module_type
				local modty --[[: Ty | nil ]]
				if resolve then modty = resolve(modpath) end
				if modty then
					local nid = lc.b.node({ t = "require", module = modpath })
					local cid = lc.b.fresh_claim("require")
					A.add_claim(lc.state, S.has_type_claim(cid, ctx, nid, modty))
					A.add_evidence(lc.state, A.evidence({ id = lc.b.fresh_ev("require"), claim = cid,
						method = "trusted_signature", result = { trust = lc.stdlib_tb } }))
					return modty, cid
				end
				-- a require that did not resolve to a slice module type (non-lib path,
				-- unreadable, cyclic, or its return type out-of-subset): fall through to
				-- the ordinary unbound-name path below — never a silent success.
			end
		end
	end
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
		local wp0 --[[: Ty | nil ]]
		if i <= #params.fixed then wp0 = params.fixed[i] else wp0 = params.vararg end
		if not wp0 then
			mark(lc, { line = 0, construct = "call-arity", text = "too many arguments" })
			return nil, nil
		end
		local want_param = wp0 --[[: Ty ]]
		-- CHECK-mode for a closure argument flowing into an annotated callback param
		-- (§6.8): `check_expr` routes a `func` node against the expected `fn` param
		-- type into check-mode (the param types are pushed inward). All other args go
		-- through the same `check_expr` (synth + subtype), so this is uniform.
		local _, caid = check_expr(lc, ctx, ae, want_param)
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

-- Lower a method call `o:m(a1..an)` by desugaring to `o.m(o, a1..an)` (§6.7.5).
-- The receiver `o` is synthesized once; the method `m` is read off `o`'s type
-- (synth_index), yielding the method's fn type whose first param is `self`; the
-- call then checks `o ⇐ self` and each `ai ⇐ Pi`. Returns (R.fixed[1], cid).
--: (LC, SliceCtx, unknown) -> (Ty | nil, Id | nil)
local function synth_methodcall_expr(lc, ctx, e)
	local v = view(e)
	if not v then return nil, nil end
	local method = v.method
	if type(method) ~= "string" then return nil, nil end
	-- desugar: o.m is an index node; the call prepends o as the first argument.
	local index_ast = { k = "index", obj = v.recv, field = method }
	local prepended = { v.recv } --[[: { [integer]: unknown } ]]
	for _, a in ipairs(v.args or {}) do prepended[#prepended + 1] = a end
	local call_ast = { k = "call", fn = index_ast, args = prepended }
	return synth_call_expr(lc, ctx, call_ast)
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
	if k == "methodcall" then return synth_methodcall_expr(lc, ctx, e) end
	if k == "table" then return synth_table_expr(lc, ctx, e) end
	if k == "unop" and v.op == "not" then return synth_andor_expr(lc, ctx, e) end
	if k == "binop" and (v.op == "and" or v.op == "or") then return synth_andor_expr(lc, ctx, e) end
	if k == "binop" then
		-- arithmetic / comparison / concat / equality (§6.7.1). The result kind is
		-- fixed by the operator + the operand kinds (metatable-free). A
		-- metatable-dependent operand is an out-of-subset DEFERRAL (operator-metamethod-*),
		-- never a type-error claim — v1 cannot know the metatable.
		local op = v.op or "?"
		local lty, lcid = synth_expr(lc, ctx, v.left)
		local rty, rcid = synth_expr(lc, ctx, v.right)
		if not lty or not rty or not lcid or not rcid then return nil, nil end
		local result = S.binop_result(op, lty, rty)
		if not result then
			-- operand outside the metatable-free core: deferral, tagged by family.
			local fam --[[: string ]]
			if op == ".." then fam = "concat"
			elseif op == "<" or op == "<=" or op == ">" or op == ">=" then fam = "compare"
			else fam = "arith" end
			mark(lc, { line = 0, construct = "operator-metamethod-" .. fam, text = op })
			return nil, nil
		end
		local lpc = lc.state.claims[A.idk(lcid)]
		local rpc = lc.state.claims[A.idk(rcid)]
		local lref = lpc and lpc.args and lpc.args.node --[[: unknown ]]
		local rref = rpc and rpc.args and rpc.args.node --[[: unknown ]]
		local nid = lc.b.node({ t = "binop", op = op, left = lref, right = rref })
		local cid = lc.b.fresh_claim("binop")
		A.add_claim(lc.state, S.has_type_claim(cid, ctx, nid, result))
		A.add_evidence(lc.state, A.evidence({ id = lc.b.fresh_ev("binop"), claim = cid,
			method = "synth_binop", inputs = { lcid, rcid } }))
		return result, cid
	end
	if k == "unop" and (v.op == "#" or v.op == "-") then
		-- unary length `#` / minus `-` (§6.7.1). `not` is handled by synth_andor_expr.
		local op = v.op
		local oty, ocid = synth_expr(lc, ctx, v.expr)
		if not oty or not ocid then return nil, nil end
		local result = S.unop_result(op, oty)
		if not result then
			local fam = op == "#" and "len" or "unm"
			mark(lc, { line = 0, construct = "operator-metamethod-" .. fam, text = op })
			return nil, nil
		end
		local opc = lc.state.claims[A.idk(ocid)]
		local oref = opc and opc.args and opc.args.node --[[: unknown ]]
		local nid = lc.b.node({ t = "unop", op = op, operand = oref })
		local cid = lc.b.fresh_claim("unop")
		A.add_claim(lc.state, S.has_type_claim(cid, ctx, nid, result))
		A.add_evidence(lc.state, A.evidence({ id = lc.b.fresh_ev("unop"), claim = cid,
			method = "synth_unop", inputs = { ocid } }))
		return result, cid
	end
	if k == "func" then
		-- an anonymous function in expression position (§6.8). SYNTHESIS mode: params
		-- bind `unknown` (the §6.7.3 unannotated-named rule extended to expression
		-- closures), the return is synthesized from the body. When this closure flows
		-- into an annotated slot, the caller routes it through `check_func_expr`
		-- (check-mode) instead, pushing the expected param types onto the params.
		return synth_func_expr(lc, ctx, e)
	end
	if k == "indexdyn" then
		-- dynamic-index READ `t[e]` (§6.9.2). Synthesize the object and the key, then
		-- resolve via `index_result(obj_ty, nil, key_ty)`: an indexer / rec-with-indexer
		-- yields its value type; an open-row rec yields `unknown`; a CLOSED rec yields
		-- `union(field-value-types) | nil`. A non-table object (or un-indexable shape)
		-- stays out-of-subset — the honest deferral, never a forged result.
		local oty, ocid = synth_expr(lc, ctx, v.obj)
		if not oty or not ocid then
			mark(lc, { line = 0, construct = "dynamic-index", text = "t[expr]" })
			return nil, nil
		end
		local key_ty, key_cid = synth_expr(lc, ctx, v.key)
		if not key_ty or not key_cid then
			mark(lc, { line = 0, construct = "dynamic-index", text = "t[expr]" })
			return nil, nil
		end
		local res = S.index_result(oty, nil, key_ty)
		if not res then
			mark(lc, { line = 0, construct = "dynamic-index", text = "t[expr]" })
			return nil, nil
		end
		local opc = lc.state.claims[A.idk(ocid)]
		local kpc = lc.state.claims[A.idk(key_cid)]
		local obj_ref = opc and opc.args and opc.args.node --[[: unknown ]]
		local key_ref = kpc and kpc.args and kpc.args.node --[[: unknown ]]
		local nid = lc.b.node({ t = "index", obj = obj_ref, key = key_ref })
		local cid = lc.b.fresh_claim("index")
		A.add_claim(lc.state, S.has_type_claim(cid, ctx, nid, res))
		A.add_evidence(lc.state, A.evidence({ id = lc.b.fresh_ev("index"), claim = cid,
			method = "synth_index", inputs = { ocid, key_cid } }))
		return res, cid
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
			-- For `and`: a conjunct that does not convert contributes no narrowing but
			-- we can still narrow from the other. Keeping the recognized side is SOUND:
			-- in the truthy branch of `a and b`, everything `a` (or `b`) implies still
			-- holds (audit round 4 fix — mirrors the recognize_guard change).
			-- For `or`: require BOTH (dropping a disjunct is unsound).
			if v.op == "and" then
				if not l and not r then return nil end
				if not r then return l end
				if not l then return r end
			else
				if not l or not r then return nil end
			end
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
-- For an `and` guard, extracts the left conjunct's variable (the chain narrows
-- via both conjuncts in sequence, and the left variable is the "primary" one —
-- audit round 4: `if x and <expr>` should narrow x). For an `or` guard, no
-- single variable can be inferred (the variable only holds from one disjunct).
--: (unknown) -> string | nil
local function guard_var(guard_node)
	local g = view(P.recognize_guard(guard_node))
	if not g then return nil end
	if type(g.var) == "string" then return g.var end
	-- a tag_eq's refined variable is the object var.
	local inner = view(g.inner)
	if g.g == "not" and inner and type(inner.var) == "string" then return inner.var end
	-- an `and` guard: recurse into both sub-guards to find a refinable variable.
	-- The left conjunct's variable is preferred (the chain applies left first).
	if g.g == "and" then
		local lv --[[: string | nil ]]
		local lguard = view(g.left)
		if lguard and type(lguard.var) == "string" then lv = lguard.var end
		if lv then return lv end
		local rguard = view(g.right)
		if rguard and type(rguard.var) == "string" then return rguard.var end
	end
	return nil
end

-- Flatten an RHS value list into positional slots (§6.7.4 width rule). Each value
-- 1..n-1 contributes ONE slot (its single-value type); the LAST value contributes
-- its full multi-return tuple when it is a call to a known multi-return fn (the
-- §6.5.5 Ret tuple), else one slot. Returns a slot array `{ { ty, cid? } }` (cid is
-- present for slots backed by a synthesized claim; tuple-expanded slots beyond
-- slot 1 carry only `ty`). Returns nil if any value is out-of-subset.
--: (LC, SliceCtx, { [integer]: unknown }) -> ({ [integer]: { ty: Ty, cid: Id | nil } }) | nil
local function flatten_values(lc, ctx, values)
	local slots = {} --[[: { [integer]: { ty: Ty, cid: Id | nil } } ]]
	local n = #values
	for i = 1, n do
		local val = values[i]
		local vv = view(val)
		local is_last = (i == n)
		-- the LAST value, when it is a call PRODUCING a multi-return tuple, expands to
		-- its Ret (§6.9.4). The producing function's `fn` type is recovered regardless
		-- of the call's syntactic form:
		--   - `f(...)`        — `f` a name bound to an `fn`-typed local
		--   - `o:m(...)`      — the method's `fn` type via the desugared `o.m` index
		--   - `t.f(...)`      — the field's `fn` type via `synth_index` on `t.f`
		-- Only when the recovered `Ret` has ≥2 fixed elements do we spread; otherwise
		-- the call contributes one slot (a single-value producer).
		if is_last and vv and (vv.k == "call" or vv.k == "methodcall") then
			-- recover the producing function's type, then its return tuple.
			local prod_fty --[[: Ty | nil ]]
			if vv.k == "call" then
				local fnv = view(vv.fn)
				local fname = fnv and fnv.name
				if type(fname) == "string" then
					prod_fty = ctx_get(ctx, fname)
				elseif fnv and fnv.k == "index" then
					-- `t.f(...)`: resolve the field's fn type via synth_index.
					prod_fty = synth_index_expr(lc, ctx, vv.fn)
				end
			else
				-- `o:m(...)`: the method's fn type is `synth_index(o, "m")`.
				local method = vv.method
				if type(method) == "string" then
					prod_fty = synth_index_expr(lc, ctx, { k = "index", obj = vv.recv, field = method })
				end
			end
			local rfixed --[[: Ty[] ]] = {}
			if prod_fty and prod_fty.kind == "fn" then
				local pf = prod_fty --[[: Ty ]]
				local ret = pf.ret or ({ fixed = {} } --[[: Ret ]])
				rfixed = ret.fixed
			end
			local vty, vcid = synth_expr(lc, ctx, val)
			if not vty or not vcid then return nil end
			if #rfixed >= 2 then
				slots[#slots + 1] = { ty = rfixed[1], cid = vcid }
				for j = 2, #rfixed do
					slots[#slots + 1] = { ty = rfixed[j], cid = nil }
				end
			else
				slots[#slots + 1] = { ty = vty, cid = vcid }
			end
			goto continue
		end
		do
			local vty, vcid = synth_expr(lc, ctx, val)
			if not vty or not vcid then return nil end
			slots[#slots + 1] = { ty = vty, cid = vcid }
		end
		::continue::
	end
	return slots
end

-- ── Expression-position closures (§6.8) ──────────────────────────────────────
--
-- Shared body-builder for an anonymous `function(p1..pn) ... end`. `param_tys` is
-- the per-parameter type list (each `unknown` in synthesis mode, or the expected
-- fn type's param type in check mode); `decl_ret` is the declared return tuple in
-- check mode, or nil for synthesis mode. Returns the closure's `fn` type and its
-- has_type claim id (with `synth_function` evidence, verified by the hosted checker:
-- node `t="function"`, params named, and each return checked against the return
-- slot under the param-extended Γ).
--
-- The closure's return type: in CHECK mode the declared return; in SYNTHESIS mode
-- `unknown` (the §6.7.3 fence-honest choice already used for unannotated NAMED
-- functions — a fresh inference variable would be the global solving the fence
-- excludes). The body's returns therefore check against `unknown` (always holds),
-- and the closure value's `fn(.. , unknown)` shape forces callers to narrow. The
-- precise body-synthesized JOIN (§6.8) is a deferral recorded in §9.13 — `unknown`
-- is sound and matches the existing named-unannotated treatment.
--: (LC, SliceCtx, unknown, { [integer]: Ty }, Ret | nil, Ty | nil) -> (Ty | nil, Id | nil)
local function build_closure(lc, ctx, e, param_tys, decl_ret, fty_override)
	local v = view(e)
	if not v then return nil, nil end
	-- the return slot the body's returns are checked against.
	local rty --[[: Ty ]] = G.unknown()
	if decl_ret then rty = decl_ret.fixed[1] or G.nil_() end
	-- the closure's fn type: param_tys as fixed params, rty as the single return slot.
	local fixed = {} --[[: { [integer]: Ty } ]]
	for i = 1, #(v.params or {}) do fixed[i] = param_tys[i] or G.unknown() end
	local fret --[[: Ret ]] = { fixed = { rty } }
	if decl_ret then fret = decl_ret end
	local params --[[: Params ]] = { fixed = fixed }
	if v.vararg then params.vararg = G.unknown() end
	-- §6.8.3 F2 fix: when check-mode supplies an override fn type (e.g. `want` from
	-- the expected slot), use it as the has_type claim's type. This makes the claim
	-- carry the EXPECTED fn type exactly, so the outer check_against wrapper emits
	-- subtype(want, want) which holds trivially and the substrate's check_against rule
	-- sees spr.type == sub.a == want (no mismatch). The substrate's synth_function
	-- verifier does not reject because it only iterates over params_node (the closure's
	-- DECLARED params), so under-declared params don't cause a pfixed[i] not-found.
	local fty = fty_override or G.fn(params, fret)
	-- the function node carries its named params so the checker can rebuild Γ_ext
	-- exactly (the `synth_function` contract: node.params is `{ {name}, ... }`).
	local pnodes = {} --[[: { [integer]: { name: string } } ]]
	-- body context: extend with the parameters (vararg params are not bound by name).
	local body_ctx = {} --[[: SliceCtx ]]
	for i = 1, #ctx do body_ctx[i] = ctx[i] end
	for i, p0 in ipairs(v.params or {}) do
		local pname = p0.name
		if type(pname) == "string" then
			local pty = param_tys[i] or G.unknown()
			pnodes[#pnodes + 1] = { name = pname }
			body_ctx[#body_ctx + 1] = { name = pname, type = TA.encode(pty) }
		end
	end
	-- lower the body with `ret_ty = rty`: each `return e` emits a
	-- `checks_against(Γ_ext, e, rty)` claim. A return-premise sink captures those
	-- claim ids so they become the `synth_function` evidence inputs (the contract:
	-- one return premise per return path, under the extended Γ).
	local stack = lc.return_premise_sink or ({} --[[: { [integer]: { [integer]: Id } } ]])
	lc.return_premise_sink = stack
	local sink = {} --[[: { [integer]: Id } ]]
	stack[#stack + 1] = sink
	lc.func_depth = (lc.func_depth or 0) + 1
	lower_block(lc, body_ctx, v.body, rty)
	lc.func_depth = (lc.func_depth or 1) - 1
	stack[#stack] = nil
	local nid = lc.b.node({ t = "function", params = pnodes,
		vararg = v.vararg and true or false })
	local cid = lc.b.fresh_claim("func")
	A.add_claim(lc.state, S.has_type_claim(cid, ctx, nid, fty))
	A.add_evidence(lc.state, A.evidence({ id = lc.b.fresh_ev("func"), claim = cid,
		method = "synth_function", inputs = sink }))
	return fty, cid
end

-- SYNTHESIS-mode closure: params bind `unknown`, the return is body-synthesized.
synth_func_expr = function(lc, ctx, e)
	local v = view(e)
	if not v then return nil, nil end
	local param_tys = {} --[[: { [integer]: Ty } ]]
	for i = 1, #(v.params or {}) do param_tys[i] = G.unknown() end
	return build_closure(lc, ctx, e, param_tys, nil)
end

-- CHECK-mode closure (§6.8): the expected `fn` type `want` pushes its param types
-- onto the closure's params (bidirectionality's signature move), and the body's
-- returns are checked against `want`'s return. The closure's fn type is `want`.
check_func_expr = function(lc, ctx, e, want)
	local v = view(e)
	if not v or want.kind ~= "fn" then return nil, nil end
	local wparams = want.params or ({ fixed = {} } --[[: Params ]])
	local wret = want.ret or ({ fixed = {} } --[[: Ret ]])
	local nparams = #(v.params or {})
	-- arity: the closure may declare FEWER params than expected (Lua ignores extra
	-- arguments) but not MORE fixed params than the expected type supplies (unless it
	-- has a vararg). A mismatch is an honest type-mismatch finding, not a crash.
	if nparams > #wparams.fixed and not (wparams.vararg) then
		mark(lc, { line = 0, construct = "type-mismatch", text = "closure expects more params than the annotated type supplies" })
		return nil, nil
	end
	local param_tys = {} --[[: { [integer]: Ty } ]]
	for i = 1, nparams do
		param_tys[i] = wparams.fixed[i] or wparams.vararg or G.unknown()
	end
	-- §6.8.3: the closure's VALUE TYPE is `want` exactly (the spec pin). Pass `want`
	-- as the fn-type override so build_closure emits has_type(ctx, node, want) — the
	-- check_against wrapper then emits subtype(want, want) which holds trivially, and
	-- the substrate's check_against rule sees spr.type == sub.a == want (no mismatch).
	-- The body is still verified under the closure's DECLARED params (body_ctx only
	-- binds the params the closure names); the synth_function verifier does not reject
	-- under-declared params because it only iterates over params_node's length.
	local fty, cid = build_closure(lc, ctx, e, param_tys, wret, want)
	if not fty or not cid then return nil, nil end
	return want, cid
end

-- The mode switch (§6.8 check-mode closure typing). To check `e ⇐ want`: when `e`
-- is a `func` node and `want` is an `fn` type, route into CHECK-mode closure typing
-- (push the expected param types inward). Otherwise synthesize `e` and require
-- `subtype(synth(e), want)` — the ordinary `check_against` boundary. Returns
-- (value_ty, claim_id) where claim_id is a checks_against claim (or the closure's
-- has_type for the check-mode closure path), or (nil, nil) with a marker.
check_expr = function(lc, ctx, e, want)
	local v = view(e)
	local scid --[[: Id | nil ]]
	local sty --[[: Ty | nil ]]
	if v and v.k == "func" and want.kind == "fn" then
		-- CHECK-mode closure: build it with the expected param types pushed inward.
		-- Its has_type is the synth premise; the check_against boundary below wraps it
		-- (subtype(want, want) holds trivially) so the result is a `checks_against`
		-- claim a caller (call-arg / local / return) can use uniformly.
		sty, scid = check_func_expr(lc, ctx, e, want)
	else
		sty, scid = synth_expr(lc, ctx, e)
	end
	if not sty or not scid then return nil, nil end
	local spc = lc.state.claims[A.idk(scid)]
	local sref = spc and spc.args and spc.args.node --[[: unknown ]]
	local caid = emit_check_against(lc, ctx, scid, sref, sty, want)
	if not caid then return nil, nil end
	return want, caid
end

M.check_expr = check_expr

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
			if decl_ty then
				local dt = decl_ty --[[: Ty ]]
				-- annotated local: CHECK value ⇐ decl_ty (inference boundary), bind decl_ty.
				-- `check_expr` routes a `func` value against an `fn` annotation into
				-- check-mode closure typing (§6.8); all other values go synth + subtype.
				local _, caid = check_expr(lc, ctx, val, dt)
				if caid then lc.requested[#lc.requested + 1] = caid end
				ctx[#ctx + 1] = { name = name, type = TA.encode(dt) }
				return
			end
			local vty, vcid = synth_expr(lc, ctx, val)
			if not vty or not vcid then
				-- value out-of-subset (unannotated): stop binding (name unbound).
				return
			end
			do
				-- unannotated: bind the synthesized type.
				lc.requested[#lc.requested + 1] = vcid
				ctx[#ctx + 1] = { name = name, type = TA.encode(vty) }
				-- §9.14 F3 (simple alias): detect `local A = M` where M is a rec-typed
				-- local. Record A → M in mod_table_aliases so ctx_set_field(A, f, …)
				-- propagates field accumulation onto M too (so `return M` includes fields
				-- set via `A.f = …`). Only the trivial single-direct-alias form; no alias
				-- chain, no conditional, no wrapped form — those stay §9.14 deferrals.
				local valv = view(val)
				local srcname = valv and valv.name
				if valv and valv.k == "name" and type(srcname) == "string"
					and vty.kind == "rec" and (lc.func_depth or 0) == 0 then
					if lc.mod_table_aliases == nil then lc.mod_table_aliases = {} end
					lc.mod_table_aliases[name] = srcname
				end
			end
			return
		end
		-- multi-name `local a, b = e1, e2` / `local a, b = f()` (§6.7.4): flatten the
		-- RHS value list into positional slots (the last value expands to its
		-- multi-return tuple), then bind each name to its slot type. Absent slots
		-- bind nil (the surplus-target rule). Values evaluated under the pre-decl Γ.
		if #values >= 1 then
			local slots = flatten_values(lc, ctx, values)
			if slots then
				for i = 1, #names do
					local nm = names[i]
					if type(nm) == "string" then
						local slot = slots[i]
						local sty = slot and slot.ty or G.nil_()
						if slot and slot.cid then lc.requested[#lc.requested + 1] = slot.cid end
						ctx[#ctx + 1] = { name = nm, type = TA.encode(sty) }
					end
				end
				return
			end
		end
		-- the RHS list had an out-of-subset value: bind nothing further.
		mark(lc, { line = 0, construct = "multi-assign", text = "local a, b = ..." })
		return

	elseif k == "localfunc" or k == "funcdecl" then
		-- a function definition. ANNOTATED (`--:`): params from the signature, body
		-- checked against the declared return. UNANNOTATED (§6.7.3): params synthesize
		-- as `unknown` (forcing narrowing per the posture), the return is synthesized
		-- from the body. A method def's implicit `self` is an ordinary first param
		-- (§6.7.5): from the signature's first param when annotated, else `unknown`.
		local fsig = sv.sig
		local annotated = type(fsig) == "string"
		local fty --[[: Ty | nil ]]
		-- the declared params (annotated) or synthesized `unknown` params (unannotated).
		local params --[[: Params ]] = { fixed = {} }
		local fret --[[: Ret ]] = { fixed = {} }
		if type(fsig) == "string" then
			local parsed = ann_type(lc, fsig, 0)
			if parsed == nil then return end
			local p = parsed --[[: Ty ]]
			if p.kind ~= "fn" then
				mark(lc, { line = 0, construct = "function-sig-not-fn", text = fsig })
				return
			end
			fty = p
			if p.params then params = p.params end
			if p.ret then fret = p.ret end
		end
		-- the declared `self` slot for a method (annotated sigs include `self: T`).
		local self_off = 0 --: integer
		if sv.is_method then self_off = 1 end
		-- bind the function name in the OUTER context (so later calls resolve). For
		-- the unannotated case, bind fn(unknown^n, unknown) — a usable conservative
		-- shape (callers get `unknown` results, forcing narrowing).
		local fname --[[: string | nil ]]
		-- a module-table member target `function M.f(...)`: `mod_member` carries the
		-- table-local name `M` and the field `f`. The function type is ACCUMULATED into
		-- `M`'s record (§6.7.2 M-table synthesis) rather than binding a global `f`.
		local mod_member --[[: { obj: string, field: string } | nil ]]
		local tgtv = view(sv.target)
		local svname = sv.name
		local tname = tgtv and tgtv.name
		local tfield = tgtv and tgtv.field
		if k == "localfunc" and type(svname) == "string" then fname = svname
		elseif tgtv and tgtv.k == "name" and type(tname) == "string" then fname = tname
		elseif tgtv and tgtv.k == "index" and type(tfield) == "string" then
			local tf = tfield --[[: string ]]
			fname = tf
			local objv = view(tgtv.obj)
			if objv and objv.k == "name" then
				local oname = objv.name
				if type(oname) == "string" then
					local on = oname --[[: string ]]
					mod_member = { obj = on, field = tf } --[[: { obj: string, field: string } ]]
				end
			end
		end
		-- build the body context extended with the params.
		local body_ctx = {} --[[: SliceCtx ]]
		for i = 1, #ctx do body_ctx[i] = ctx[i] end
		if sv.is_method then
			-- `self` is the first positional param (§6.7.5): annotated sig supplies its
			-- type as params.fixed[1]; unannotated ⇒ unknown.
			local self_ty --[[: Ty ]] = G.unknown()
			local p1 = params.fixed[1]
			if annotated and p1 then self_ty = p1 end
			body_ctx[#body_ctx + 1] = { name = "self", type = TA.encode(self_ty) }
		end
		for i, p0 in ipairs(sv.params or {}) do
			local pname = p0.name
			local pty --[[: Ty | nil ]]
			if annotated then pty = params.fixed[i + self_off] else pty = G.unknown() end
			if type(pname) ~= "string" then
				-- skip
			elseif annotated and not pty then
				mark(lc, { line = 0, construct = "param-arity", text = pname })
			else
				body_ctx[#body_ctx + 1] = { name = pname, type = TA.encode(pty or G.unknown()) }
			end
		end
		if fty ~= nil then
			local f = fty --[[: Ty ]]
			-- §6.7.2: a `function M.f` target accumulates field `f` into the module table
			-- `M`'s record (so a later `return M` exports it); a plain `function f` / a
			-- non-rec target binds the name directly.
			local accumulated = false --: boolean
			if mod_member then
				local mm = mod_member --[[: { obj: string, field: string } ]]
				accumulated = ctx_set_field(ctx, mm.obj, mm.field, f, lc.mod_table_aliases)
			end
			if fname and not accumulated then ctx[#ctx + 1] = { name = fname, type = TA.encode(f) } end
			-- `local function f` is in scope inside its OWN body (Lua's recursive
			-- binding: `local f; f = function...`); bind it in body_ctx too.
			if fname and k == "localfunc" then body_ctx[#body_ctx + 1] = { name = fname, type = TA.encode(f) } end
			-- the body's `ret_ty`: a SINGLE-value declared return passes `fixed[1]` (the
			-- single-return check checks `v <: fixed[1]`); a MULTI-value declared return
			-- (≥2 fixed or a vararg) passes the joint §6.5.5 `tuple`, so a multi-return
			-- statement checks `jtuple <: tuple(declared)` (§6.9.3). A single return
			-- against a multi-value declared tuple is then correctly `v <: tuple([A,B])`
			-- = false (a single value cannot satisfy a 2-value return).
			local rty --[[: Ty ]]
			if #fret.fixed >= 2 or fret.vararg ~= nil then
				rty = G.tuple(fret.fixed, fret.vararg)
			else
				local r0 = fret.fixed[1]
				if r0 then rty = r0 else rty = G.nil_() end
			end
			lc.func_depth = (lc.func_depth or 0) + 1
			lower_block(lc, body_ctx, sv.body, rty)
			lc.func_depth = (lc.func_depth or 1) - 1
		else
			-- unannotated: bind fn(unknown^n, unknown) in the outer ctx; lower the body
			-- in SYNTHESIS mode (ret_ty = nil) — returns request their value claims,
			-- not checked against a declared return (the return is body-synthesized).
			local pn = #(sv.params or {}) + self_off
			local pfixed = {} --[[: Ty[] ]]
			for i = 1, pn do pfixed[i] = G.unknown() end
			local ufty = G.fn({ fixed = pfixed }, { fixed = { G.unknown() } })
			local accumulated = false --: boolean
			if mod_member then
				local mm = mod_member --[[: { obj: string, field: string } ]]
				accumulated = ctx_set_field(ctx, mm.obj, mm.field, ufty, lc.mod_table_aliases)
			end
			if fname and not accumulated then ctx[#ctx + 1] = { name = fname, type = TA.encode(ufty) } end
			if fname and k == "localfunc" then body_ctx[#body_ctx + 1] = { name = fname, type = TA.encode(ufty) } end
			lc.func_depth = (lc.func_depth or 0) + 1
			lower_block(lc, body_ctx, sv.body, nil)
			lc.func_depth = (lc.func_depth or 1) - 1
		end
		return

	elseif k == "return" then
		local values = sv.values or {}
		if #values == 0 then return end
		-- a closure-body return sink (§6.8) captures the return-premise claim id.
		local sink = lc.return_premise_sink and lc.return_premise_sink[#lc.return_premise_sink]
		if #values > 1 then
			-- MULTI-RETURN statement (§6.9.3): build the joint §6.5.5 `tuple` from the
			-- value list (the last value spreads its multi-return tuple, §6.7.4 width
			-- rule), then — in check mode — check the tuple ⇐ ret_ty (via the §6.5.5
			-- tuple-subtype rule), or, at module top level, capture it as the module's
			-- exported value type. Surplus/short tuples are handled by tuple_sub.
			local slots = flatten_values(lc, ctx, values)
			if not slots then
				mark(lc, { line = 0, construct = "multi-return", text = "return a, b" })
				return
			end
			local fixed = {} --[[: Ty[] ]]
			local inputs = {} --[[: Id[] ]]
			local all_cids = true --: boolean
			for i = 1, #slots do
				local s = slots[i]
				if s then
					fixed[#fixed + 1] = s.ty
					if s.cid then inputs[#inputs + 1] = s.cid else all_cids = false end
				end
			end
			local jtuple = G.tuple(fixed, nil)
			-- the synth_tuple has_type claim needs one premise per slot. When the last
			-- value SPREAD into ≥2 slots (the `return f()` multi-spread), slots 2..n
			-- carry no per-slot claim — the synth_tuple premise contract cannot be met;
			-- that shape is the §9.15 deferral (a tuple-spread-premise mechanism). The
			-- per-value `return a, b` form (the dominant idiom) has a cid per slot.
			if not all_cids or #inputs ~= #fixed then
				-- still request the available value claims so their checks run, then mark.
				for i = 1, #inputs do lc.requested[#lc.requested + 1] = inputs[i] end
				mark(lc, { line = 0, construct = "multi-return", text = "return f() (spread)" })
				return
			end
			-- emit has_type(Γ, tuple_node, jtuple) via synth_tuple over the slot claims.
			local tnid = lc.b.node({ t = "tuple", n = #fixed })
			local tcid = lc.b.fresh_claim("tuple")
			A.add_claim(lc.state, S.has_type_claim(tcid, ctx, tnid, jtuple))
			A.add_evidence(lc.state, A.evidence({ id = lc.b.fresh_ev("tuple"), claim = tcid,
				method = "synth_tuple", inputs = inputs }))
			local rt = ret_ty
			if rt then
				-- check the synthesized tuple ⇐ ret_ty (the §6.5.5 tuple-subtype rule).
				local caid = emit_check_against(lc, ctx, tcid, tnid, jtuple, rt)
				if caid then
					lc.requested[#lc.requested + 1] = caid
					if sink then sink[#sink + 1] = caid end
				end
			else
				-- request the tuple claim; capture it as the module value type at top
				-- level (§6.7.2 — the FIRST top-level return wins).
				lc.requested[#lc.requested + 1] = tcid
				if (lc.func_depth or 0) == 0 and lc.module_ret_ty == nil then
					lc.module_ret_ty = jtuple
				end
			end
			return
		end
		-- single-return: check value ⇐ ret_ty.
		local vty, vcid = synth_expr(lc, ctx, values[1])
		if not vty or not vcid then
			return
		end
		local rt = ret_ty
		if rt then
			local vpc = lc.state.claims[A.idk(vcid)]
			local vref = vpc and vpc.args and vpc.args.node --[[: unknown ]]
			local caid = emit_check_against(lc, ctx, vcid, vref, vty, rt)
			if caid then
				lc.requested[#lc.requested + 1] = caid
				-- when this return is inside a closure body being built (§6.8), the
				-- return-premise sink captures the checks_against claim id so it becomes
				-- a `synth_function` evidence input (the return-premise contract).
				if sink then sink[#sink + 1] = caid end
			end
		else
			lc.requested[#lc.requested + 1] = vcid
			-- MODULE-VALUE-TYPE capture (§6.7.2): a `return <expr>` at the module top
			-- level (not inside ANY function body, func_depth == 0) fixes the module's
			-- exported value type — the type a consumer's `require("this")` binds. The
			-- FIRST top-level return wins (Lua modules return exactly once).
			if (lc.func_depth or 0) == 0 and lc.module_ret_ty == nil then
				lc.module_ret_ty = vty
			end
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
		-- a call/method-call in statement position: synth it (typecheck its args).
		local _, ccid = synth_expr(lc, ctx, sv.call)
		if ccid then lc.requested[#lc.requested + 1] = ccid end
		return

	elseif k == "assign" then
		-- field/index or variable assignment. v1 checks each write against the
		-- declared element/field type (flow-insensitive). For an in-subset record
		-- field write `t.f = v`, check v ⇐ field-type. Multi-target / dynamic-key
		-- writes are marked.
		local targets = sv.targets or {}
		local values = sv.values or {}
		-- a `--:` annotation on a `M.f = <expr>` assignment (the corpus convention for an
		-- annotated module-table member) gives the field's DECLARED type: check the value
		-- ⇐ the sig (check-mode, so a closure value flows the sig's params inward, §6.8)
		-- and accumulate the SIG type into the module rec (§6.7.2), not the synthesized
		-- one. Only for a single field-target with a parseable fn/Ty sig.
		local asig = sv.sig
		if #targets == 1 and #values == 1 and type(asig) == "string" then
			local tgt = view(targets[1])
			local tgt_field = tgt and tgt.field
			local objv = tgt and view(tgt.obj)
			local oname0 = objv and objv.name
			if tgt and tgt.k == "index" and type(tgt_field) == "string"
				and objv and objv.k == "name" and type(oname0) == "string" then
				local declared = ann_type(lc, asig, 0)
				if declared then
					local dt = declared --[[: Ty ]]
					local _, caid = check_expr(lc, ctx, values[1], dt)
					if caid then lc.requested[#lc.requested + 1] = caid end
					ctx_set_field(ctx, oname0 --[[: string ]], tgt_field --[[: string ]], dt, lc.mod_table_aliases)
					return
				end
			end
		end
		if #targets == 1 and #values == 1 then
			local tgt = view(targets[1])
			local vty, vcid = synth_expr(lc, ctx, values[1])
			if not vty or not vcid then return end
			local tgt_field = tgt and tgt.field
			if tgt and tgt.k == "index" and type(tgt_field) == "string" then
				local tfield2 = tgt_field --[[: string ]]
				local oty = synth_expr(lc, ctx, tgt.obj)
				if oty then
					local fty = S.index_result(oty, tfield2, nil)
					if fty then
						local vpc = lc.state.claims[A.idk(vcid)]
						local vref = vpc and vpc.args and vpc.args.node --[[: unknown ]]
						local caid = emit_check_against(lc, ctx, vcid, vref, vty, fty)
						if caid then lc.requested[#lc.requested + 1] = caid end
						return
					end
				end
				-- §6.7.2 M-table accumulation: `M.f = <expr>` where `M` is a table-local
				-- rec ADDS field `f : typeof <expr>` to the module type (the module table
				-- grows by assignment). Only when the object is a bare name bound to a rec.
				local objv2 = view(tgt.obj)
				local oname2 = objv2 and objv2.name
				if objv2 and objv2.k == "name" and type(oname2) == "string" then
					local oname = oname2 --[[: string ]]
					if ctx_set_field(ctx, oname, tfield2, vty, lc.mod_table_aliases) then
						lc.requested[#lc.requested + 1] = vcid
						return
					end
				end
				mark(lc, { line = 0, construct = "field-assign", text = "t.f = v" })
				return
			elseif tgt and tgt.k == "name" then
				-- reassigning a local: rebind the name to the RHS type so that a later
				-- `return M` (module-value-type capture) reads the POST-rebind type.
				-- F1 fix: `M = {}` after field accumulation must reset M's rec; the old
				-- accumulated fields must not survive into the module return.
				-- Care: this only fires for top-level (non-branch) stmts because
				-- lower_block passes body_ctx (a copy) for if/while/for bodies, so the
				-- rebind inside a branch stays local to that branch's copy — the parent
				-- ctx's M is unchanged (the conditional-rebind case; §9.14 deferral).
				lc.requested[#lc.requested + 1] = vcid
				local tname = tgt.name
				if type(tname) == "string" then
					ctx[#ctx + 1] = { name = tname, type = TA.encode(vty) }
				end
				return
			elseif tgt and tgt.k == "indexdyn" then
				-- dynamic-key write `t[e] = v` (§6.7.4 + §6.9.5). Over an indexer-typed
				-- table (`{ [K]: V }`), check `e ⇐ K` and `v ⇐ V`. Over a closed rec, the
				-- write target is `index_write_target` (the WRITE dual of `index_result`):
				-- a homogeneous closed rec ⇒ its single field type; a heterogeneous or
				-- empty closed rec stays out-of-subset (the §9.15 deferral).
				local oty = synth_expr(lc, ctx, tgt.obj)
				if oty then
					local key_ty, key_cid = synth_expr(lc, ctx, tgt.key)
					if key_ty and key_cid then
						local vty2 = S.index_write_target(oty, key_ty)
						if vty2 then
							local vpc = lc.state.claims[A.idk(vcid)]
							local vref = vpc and vpc.args and vpc.args.node --[[: unknown ]]
							local caid = emit_check_against(lc, ctx, vcid, vref, vty, vty2)
							if caid then lc.requested[#lc.requested + 1] = caid end
							return
						end
					end
				end
				mark(lc, { line = 0, construct = "dynamic-index-assign", text = "t[e] = v" })
				return
			end
		end
		-- multi-target assignment `a, b = e1, e2` / swap `a, b = b, a` (§6.7.4): the
		-- parallel rule — RHS values synthesized under the PRE-assignment Γ, zipped
		-- positionally to targets. v1 is flow-insensitive, so reassigning a local
		-- just requests the value claim; a field/indexer target checks the write.
		if #targets >= 1 and #values >= 1 then
			local slots = flatten_values(lc, ctx, values)
			if slots then
				for i = 1, #targets do
					local tgt = view(targets[i])
					local slot = slots[i]
					if slot and slot.cid then
						if tgt and tgt.k == "name" then
							lc.requested[#lc.requested + 1] = slot.cid
						elseif tgt and tgt.k == "index" and type(tgt.field) == "string" then
							local oty = synth_expr(lc, ctx, tgt.obj)
							local fty = oty and S.index_result(oty, tgt.field, nil) or nil
							if fty then
								local spc = lc.state.claims[A.idk(slot.cid)]
								local sref = spc and spc.args and spc.args.node --[[: unknown ]]
								local caid = emit_check_against(lc, ctx, slot.cid, sref, slot.ty, fty)
								if caid then lc.requested[#lc.requested + 1] = caid end
							else
								mark(lc, { line = 0, construct = "field-assign", text = "t.f = v" })
							end
						else
							mark(lc, { line = 0, construct = "assign-target", text = "complex target" })
						end
					end
				end
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
-- §6.7.2 Stdlib model (injected capability, NEVER a `_G`/`io` reach)
-- ════════════════════════════════════════════════════════════════════════════
--
-- A small, EXPLICIT stdlib-cap table: the handful of stdlib names the corpus's
-- checked syntax reaches, each as an ordinary `Ty` binding in the top-level Γ.
-- Caps-first (§6.7.2, CLAUDE.md "No ambient globals by default"): the stdlib model
-- is INJECTED via `opts.stdlib`; absent the cap, these names stay
-- `unbound-name:*`, never a silent global. `default_stdlib()` is the model a
-- caller (the survey, tests) may inject; the library never reads `_G`.
--
-- These are metatable-free, monomorphic signatures of the metatable-free core.
-- The generic stdlib callees (pairs/ipairs) are NOT here — they are the special
-- loop forms (§5.2). tonumber returns `number | nil` (the parse-failure union).
-- Builds in the CURRENT interner generation (no reset): the caller is responsible
-- for the generation (M.lower builds it after its own G.reset()).
--: () -> { [string]: Ty }
function M.default_stdlib()
	local num = G.number()
	local int = G.integer()
	local str = G.string()
	local num_or_nil = G.union({ num, G.nil_() })
	--: (Ty[], Ty) -> Ty
	local function fn1(params, ret) return G.fn({ fixed = params }, { fixed = { ret } }) end
	local str_or_nil = G.union({ str, G.nil_() })
	-- string.* (the subset the corpus reaches), each also callable as a method
	-- (`s:sub(...)`) since method-call desugars to `string.sub(s, ...)` — but the
	-- receiver-as-first-arg form means a method on a string value reads the field off
	-- the STRING type, not the `string` library table. v1 models string method calls
	-- via the `string` library table only (the `("x"):m()` receiver-field form is a
	-- metatable lookup, out-of-subset); these are the `string.m(...)` library calls.
	local string_rec = G.rec({
		{ key = "sub", ty = fn1({ str, int, int }, str), optional = false, readonly = false },
		{ key = "format", ty = G.fn({ fixed = { str }, vararg = G.unknown() }, { fixed = { str } }), optional = false, readonly = false },
		{ key = "rep", ty = fn1({ str, int }, str), optional = false, readonly = false },
		{ key = "lower", ty = fn1({ str }, str), optional = false, readonly = false },
		{ key = "upper", ty = fn1({ str }, str), optional = false, readonly = false },
		{ key = "len", ty = fn1({ str }, int), optional = false, readonly = false },
		{ key = "byte", ty = fn1({ str, int }, int), optional = false, readonly = false },
		{ key = "char", ty = G.fn({ fixed = {}, vararg = int }, { fixed = { str } }), optional = false, readonly = false },
		{ key = "find", ty = G.fn({ fixed = { str, str }, vararg = G.unknown() }, { fixed = { G.union({ int, G.nil_() }), G.union({ int, G.nil_() }) } }), optional = false, readonly = false },
		{ key = "match", ty = G.fn({ fixed = { str, str }, vararg = G.unknown() }, { fixed = { str_or_nil } }), optional = false, readonly = false },
		{ key = "gsub", ty = G.fn({ fixed = { str, str }, vararg = G.unknown() }, { fixed = { str, int } }), optional = false, readonly = false },
		{ key = "gmatch", ty = fn1({ str, str }, G.func()), optional = false, readonly = false },
		{ key = "reverse", ty = fn1({ str }, str), optional = false, readonly = false },
	}, "open")
	-- math.* subset: floor, ceil, abs, max, min, sqrt, huge.
	local math_rec = G.rec({
		{ key = "floor", ty = fn1({ num }, int), optional = false, readonly = false },
		{ key = "ceil", ty = fn1({ num }, int), optional = false, readonly = false },
		{ key = "abs", ty = fn1({ num }, num), optional = false, readonly = false },
		{ key = "sqrt", ty = fn1({ num }, num), optional = false, readonly = false },
		{ key = "max", ty = G.fn({ fixed = { num }, vararg = num }, { fixed = { num } }), optional = false, readonly = false },
		{ key = "min", ty = G.fn({ fixed = { num }, vararg = num }, { fixed = { num } }), optional = false, readonly = false },
		{ key = "random", ty = G.fn({ fixed = {}, vararg = int }, { fixed = { num } }), optional = false, readonly = false },
		{ key = "huge", ty = num, optional = false, readonly = false },
		{ key = "pi", ty = num, optional = false, readonly = false },
		{ key = "sin", ty = fn1({ num }, num), optional = false, readonly = false },
		{ key = "cos", ty = fn1({ num }, num), optional = false, readonly = false },
		{ key = "exp", ty = fn1({ num }, num), optional = false, readonly = false },
		{ key = "log", ty = G.fn({ fixed = { num }, vararg = num }, { fixed = { num } }), optional = false, readonly = false },
		{ key = "pow", ty = G.fn({ fixed = { num, num } }, { fixed = { num } }), optional = false, readonly = false },
		{ key = "fmod", ty = G.fn({ fixed = { num, num } }, { fixed = { num } }), optional = false, readonly = false },
	}, "open")
	-- ── globals that need out-of-fence features → soundest in-fence approximation ──
	-- Each is recorded in §9.13 with the precise type it should eventually have. The
	-- slice grammar has NO generics (no `forall`), NO match types, NO meta-spread, NO
	-- intersection-overload resolution at call sites, so the legacy signatures (which
	-- use all of these) are approximated by `unknown`-typed params/returns where the
	-- true type would refine. These are SOUND (the caller must narrow an `unknown`),
	-- never unsound: an over-narrow approximation would be the violation.
	local unk = G.unknown() --[[: Ty ]]
	local bool = G.boolean()
	local idx_str_unk = G.indexer(str, unk) --[[: Ty ]] -- { [string]: unknown }
	-- a callable top: any function value (used where a fn arg is variadic-generic).
	local anyfn = G.func()
	local function vfn(ret) return G.fn({ fixed = {}, vararg = unk }, { fixed = { ret } }) end
	-- package: an open record of the documented fields (in-fence: open rec + indexer).
	local package_rec = G.rec({
		{ key = "path", ty = str, optional = false, readonly = false },
		{ key = "cpath", ty = str, optional = false, readonly = false },
		{ key = "config", ty = str, optional = false, readonly = false },
		{ key = "loaded", ty = idx_str_unk, optional = false, readonly = false },
		{ key = "preload", ty = idx_str_unk, optional = false, readonly = false },
	}, "open")
	-- table.*: the generic element types collapse to `unknown` (no generics, §9.13).
	local table_rec = G.rec({
		{ key = "insert", ty = G.fn({ fixed = { unk }, vararg = unk }, { fixed = {} }), optional = false, readonly = false },
		{ key = "remove", ty = G.fn({ fixed = { unk }, vararg = int }, { fixed = { unk } }), optional = false, readonly = false },
		{ key = "concat", ty = G.fn({ fixed = { unk }, vararg = unk }, { fixed = { str } }), optional = false, readonly = false },
		{ key = "sort", ty = G.fn({ fixed = { unk }, vararg = anyfn }, { fixed = {} }), optional = false, readonly = false },
		{ key = "unpack", ty = G.fn({ fixed = { unk }, vararg = int }, { fixed = { unk } }), optional = false, readonly = false },
		{ key = "maxn", ty = fn1({ unk }, int), optional = false, readonly = false },
	}, "open")
	-- os.*: a cap-shaped surface declared as an injected model (caps-first, §9.13).
	local os_rec = G.rec({
		{ key = "time", ty = vfn(int), optional = false, readonly = false },
		{ key = "clock", ty = G.fn({ fixed = {} }, { fixed = { num } }), optional = false, readonly = false },
		{ key = "date", ty = G.fn({ fixed = {}, vararg = unk }, { fixed = { str } }), optional = false, readonly = false },
		{ key = "getenv", ty = fn1({ str }, str_or_nil), optional = false, readonly = false },
		{ key = "exit", ty = vfn(G.never()), optional = false, readonly = false },
	}, "open")
	-- io.*: a cap-shaped surface (the library NEVER reaches `io`; the model is the
	-- injected cap a caller supplies, §9.13).
	local io_rec = G.rec({
		{ key = "open", ty = G.fn({ fixed = { str }, vararg = str }, { fixed = { unk, str_or_nil } }), optional = false, readonly = false },
		{ key = "write", ty = vfn(unk), optional = false, readonly = false },
		{ key = "read", ty = vfn(str_or_nil), optional = false, readonly = false },
	}, "open")
	return {
		-- precise, in-fence
		tonumber = G.fn({ fixed = { unk }, vararg = int }, { fixed = { num_or_nil } }),
		tostring = fn1({ unk }, str),
		["type"] = fn1({ unk }, str),
		print = G.fn({ fixed = {}, vararg = unk }, { fixed = {} }),
		error = G.fn({ fixed = { unk }, vararg = int }, { fixed = { G.never() } }),
		rawequal = G.fn({ fixed = { unk, unk } }, { fixed = { bool } }),
		rawlen = fn1({ unk }, int),
		collectgarbage = G.fn({ fixed = {}, vararg = unk }, { fixed = { G.union({ num, bool }) } }),
		["string"] = string_rec,
		["math"] = math_rec,
		["package"] = package_rec,
		["table"] = table_rec,
		["os"] = os_rec,
		["io"] = io_rec,
		-- approximations (out-of-fence true type recorded in §9.13)
		assert = G.fn({ fixed = { unk }, vararg = unk }, { fixed = { unk } }),
		pcall = G.fn({ fixed = { anyfn }, vararg = unk }, { fixed = { bool, unk } }),
		xpcall = G.fn({ fixed = { anyfn, anyfn }, vararg = unk }, { fixed = { bool, unk } }),
		setmetatable = G.fn({ fixed = { unk, unk } }, { fixed = { unk } }),
		getmetatable = fn1({ unk }, unk),
		rawget = G.fn({ fixed = { unk, unk } }, { fixed = { unk } }),
		rawset = G.fn({ fixed = { unk, unk, unk } }, { fixed = { unk } }),
		select = G.fn({ fixed = { unk }, vararg = unk }, { fixed = { unk } }),
		next = G.fn({ fixed = { unk }, vararg = unk }, { fixed = { unk } }),
		unpack = G.fn({ fixed = { unk }, vararg = int }, { fixed = { unk } }),
	}
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
--:: LowerOpts = { read_file?: (string) -> (string | nil, string | nil), stdlib?: boolean | { [string]: Ty }, module_value?: boolean, _mod_visited?: { [string]: boolean }, _mod_depth?: integer, _mod_cache?: { [string]: PTy } }

-- §6.7.2 module-value-type precompute. For each statically-resolvable `lib.` value
-- require in `source`, recursively lower the exporting module and capture its
-- exported VALUE type (the M-table `rec` / the table it returns), encoded as a
-- PORTABLE PTy keyed by module path. This runs BEFORE the parent interns anything,
-- so the recursive lowers' own `G.reset()` cannot corrupt the parent generation;
-- the parent decodes each PTy in its own generation at the `require` call site.
--
-- CYCLES (§6.7.2): a `_mod_visited` set on `opts` breaks require cycles — a module
-- already on the resolution stack resolves to `unknown` (honest + terminating), the
-- documented cyclic-require tag. A depth cap (`_mod_depth`) bounds deep chains.
-- CAPS-FIRST: with no `read_file` cap, no module types are computed (returns {}).
--: (string, LowerOpts | nil) -> { [string]: PTy }
local function compute_module_types(source, opts)
	local out = {} --[[: { [string]: PTy } ]]
	local read_file = opts and opts.read_file --[[: ((string) -> (string | nil, string | nil)) | nil ]]
	if not read_file then return out end
	local depth = 0 --: integer
	if opts and opts._mod_depth then depth = opts._mod_depth end
	if depth >= 6 then return out end -- bound deep require chains (perf + termination)
	local visited = (opts and opts._mod_visited) or ({} --[[: { [string]: boolean } ]])
	-- PERF (§9.13 timeout root cause): a SHARED PTy cache keyed by module path, threaded
	-- through the whole recursion, so each distinct module's value type is computed at
	-- most ONCE per top-level entry. Without it, a diamond dependency re-lowers shared
	-- modules exponentially (the depth-6 fan-out), which timed out require-heavy files.
	local cache --[[: { [string]: PTy } ]] = {}
	if opts and opts._mod_cache then cache = opts._mod_cache end
	local triggers = XM.collect_imports(source)
	for _, t in ipairs(triggers) do
		local tmod = t.module --[[: string | nil ]]
		if tmod ~= nil and not t.dynamic and out[tmod] == nil
			and (tmod:sub(1, 4) == "lib." or tmod == "lib")
			and XM.valid_modpath_segments(tmod) then
			local cached = cache[tmod]
			if cached ~= nil then
				out[tmod] = cached
			elseif visited[tmod] then
				-- a require cycle: resolve the cyclic module's value type to `unknown`
				-- (honest + terminating), the documented cyclic-require tag.
				out[tmod] = TA.encode(G.unknown())
			else
				local rf = read_file --[[: (string) -> (string | nil, string | nil) ]]
				local msrc = XM.read_module(tmod, rf)
				if msrc ~= nil then
					local m2 = msrc --[[: string ]]
					local sub_visited = {} --[[: { [string]: boolean } ]]
					for k2 in pairs(visited) do sub_visited[k2] = true end
					sub_visited[tmod] = true
					local sub_opts = {
						read_file = read_file,
						module_value = true, _mod_visited = sub_visited,
						_mod_depth = depth + 1, _mod_cache = cache,
					} --[[: LowerOpts ]]
					if opts and opts.stdlib then sub_opts.stdlib = opts.stdlib end
					local sub = M.lower(m2, tmod, sub_opts)
					-- the exporting module's exported value type, re-encoded as portable
					-- PTy (a fresh interner generation produced it). When the module has
					-- no in-subset top-level return, no type is recorded (the require
					-- falls through to the unbound-name path — never a silent success).
					if sub ~= nil then
						local mrt = sub.module_ret_ty
						if mrt ~= nil then
							local p = TA.encode(mrt)
							out[tmod] = p
							cache[tmod] = p
						end
					end
				end
			end
		end
	end
	return out
end

--: (string, string, (LowerOpts | nil)) -> (LowerResult | nil, string | nil)
function M.lower(source, filename, opts)
	-- §6.7.2 module-value-type precompute (BEFORE the parent's G.reset()/interning):
	-- recursively resolve required modules' value types to portable PTy. The parent
	-- decodes each at the `require` call site, in its own generation.
	local mod_ptys = compute_module_types(source, opts)
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
	-- F4: the artifact id and dependency invalidation field include the content digest
	-- so a body change is visible as a different id/invalidation string even when the
	-- path is unchanged.
	local xmodule_tbs = {} --[[: { [integer]: Id } ]]
	for _, rec in ipairs(imp.imports) do
		local digest = rec.digest
		-- F4: the artifact id encodes both path AND digest so a body change produces a
		-- different artifact identity (cache-key correctness).
		local art_id = A.id("artifact", "xmod-src:" .. rec.path .. "@" .. digest)
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
	-- §6.7.2 `require("lib.y")` resolution: decode the precomputed module-value PTy in
	-- THIS generation. The closure is the only path the `require` recognizer uses, so
	-- absent a precomputed type (non-lib / unresolved / cyclic-unknown), the require
	-- falls through to the unbound-name path — never a silent success.
	lc.resolve_module_type = function(modpath)
		local pty = mod_ptys[modpath]
		if pty == nil then return nil end
		return TA.decode(pty)
	end
	-- §6.7.2 stdlib cap: when `opts.stdlib` is requested, seed the top-level Γ with
	-- the injected stdlib bindings (built AFTER this file's G.reset() so the tids are
	-- in the current interner generation). Caps-first: absent the opt, no globals.
	local top_ctx = {} --[[: SliceCtx ]]
	if opts and opts.stdlib then
		local sl = opts.stdlib
		local model --[[: { [string]: Ty } ]] = {}
		if sl == true then model = M.default_stdlib()
		elseif type(sl) == "table" then model = sl --[[: { [string]: Ty } ]] end
		-- re-intern under the current generation by encode→decode round-trip is not
		-- needed: default_stdlib() built them in this generation. A caller-supplied
		-- model must also be built in-generation; we encode each binding defensively.
		local names = {} --[[: { [integer]: string } ]]
		for n in pairs(model) do names[#names + 1] = n end
		table.sort(names)
		for _, n in ipairs(names) do
			top_ctx[#top_ctx + 1] = { name = n, type = TA.encode(model[n]) }
		end
	end
	-- carry the scan-phase + import-pass markers (alias errors, dynamic requires).
	for _, m2 in ipairs(scan.markers) do lc.markers[#lc.markers + 1] = m2 end
	for _, m3 in ipairs(imp.markers) do lc.markers[#lc.markers + 1] = m3 end
	for _, er in ipairs(imp.errors) do
		lc.markers[#lc.markers + 1] = { line = 0, construct = "xmodule-alias-error",
			text = er.module .. ":" .. er.name .. ": " .. er.err }
	end
	lower_block(lc, top_ctx, chunk, nil)

	-- 4b. cross-module dependency records (§6.6.3): every requested claim was checked
	--     under the cross-module alias env, so each rides the cross_module_alias trust
	--     boundary. Record the dependency with the correct invalidation field so an
	--     incremental/audit tool can reason about staleness (the v1 evaluation strategy
	--     is re-check-everything; the RECORDS are precise). Dependencies live on the
	--     driver-level LowerResult (the object model puts them in the CheckResult
	--     dependency graph, NOT on AnalysisState — the substrate shape is untouched).
	-- F4: the invalidation string includes the content digest so that a body change
	-- in the exporting module produces a visibly different invalidation token.
	local dependencies = {} --[[: { [integer]: Dependency } ]]
	for i, tbid in ipairs(xmodule_tbs) do
		local rec_i = imp.imports[i]
		local digest_i = (rec_i and rec_i.digest) or ""
		local path_i = (rec_i and rec_i.path) or ""
		for _, cid in ipairs(lc.requested) do
			dependencies[#dependencies + 1] = A.dependency({
				from_claim = cid, kind = A.DEP_TRUSTED_BOUNDARY, target = tbid,
				invalidation = "exporting module " .. path_i .. " body changed (digest:" .. digest_i .. ")",
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
	local mrt = lc.module_ret_ty
	if mrt ~= nil then result.module_ret_ty = mrt end
	return result
end

return M
