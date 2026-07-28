-- tooling/grammar_gen/luaparse.lua
--
-- An independent Lua 5.1/LuaJIT recursive-descent parser, producing a plain
-- nested-table AST (not the arena/FFI-encoded representation in
-- lib/type/static/parse.lua).
--
-- Why a second parser instead of reusing lib/type/static/parse.lua: that
-- parser emits flat ASTNode records into an FFI arena, addressed by integer
-- index, with node "kind" as a numeric code and children reached through a
-- list-pool + intern-pool pair designed for typechecker throughput. Reusing
-- it here would mean either depending on its arena/intern machinery just to
-- walk trees (import cost + coupling to typechecking internals this tool has
-- no need of), or re-flattening its output back into a tree shape before any
-- of the canonicalization work below could run. This tool's whole job is
-- shape comparison (is this if/else the same shape as that ternary?), which
-- wants ordinary tagged tables it can pattern-match and rewrite in place.
-- lib/type/static/parse.lua remains the right choice for the typechecker;
-- it is simply the wrong shape for this job. See
-- docs/design/codebase-as-grammar.md for the fuller writeup of this decision.
--
-- Deliberately NOT a complete Lua grammar: no attribute names (`<const>`,
-- Lua 5.4), no bitwise operators (LuaJIT doesn't have them; crescent uses
-- the `bit` library). goto/labels ARE supported (parsed as opaque
-- statements) since a few real lib/ files use them and a parse failure
-- would silently shrink the corpus.
--
-- Error handling: M.parse returns (ast, nil) on success, (nil, errmsg) on
-- failure, per this repo's error convention — never throws for a parse
-- error in caller-supplied source (a syntactically-broken or exotic file is
-- a data condition, not a bug in this tool).

local M = {}

-- Every AST node (expression or statement) is one of these open records,
-- distinguished at runtime by `.tag`. An index signature is the honest
-- type for this: the whole point of the parser is producing a dynamically-
-- tagged union whose exact member set canon.lua pattern-matches on, not a
-- closed struct any single local variable holds one shape of throughout
-- its lifetime (see e.g. parse_suffixed_expr below, where the same local
-- is reassigned across index/call/methodcall shapes as suffixes accumulate).
--:: Node = { [string]: unknown }

-- ═══════════════════════════ lexer ═══════════════════════════

local KEYWORDS = {}
for _, k in ipairs({
  "and","break","do","else","elseif","end","false","for","function","goto",
  "if","in","local","nil","not","or","repeat","return","then","true",
  "until","while",
}) do KEYWORDS[k] = true end

--: (source: string) -> ({ [integer]: { kind: string, text: string, line: integer } } | nil, string | nil)
local function lex(source)
  local toks = {} --: { [integer]: { kind: string, text: string, line: integer } }
  local i = 1
  local n = #source
  local line = 1

  --: (o: integer | nil) -> string
  local function peek(o) return source:sub(i + (o or 0), i + (o or 0)) end

  --: (kind: string, text: string) -> nil
  local function push(kind, text)
    toks[#toks + 1] = { kind = kind, text = text, line = line }
  end

  -- Try an anchored, single-capture pattern at position `from`. Returns the
  -- capture and the match's end position, or (nil, from) if it didn't
  -- match — factored out so callers can chain several candidate patterns
  -- without each `local s, e, cap = find(...)` reassignment widening `e`'s
  -- inferred type across branches (a real crescent typechecker limitation
  -- with this shape; see TODO.md).
  --: (from: integer, pattern: string) -> (string | nil, integer)
  local function match_at(from, pattern)
    local s, e, cap = source:find(pattern, from)
    if not e then return nil, from end
    return cap, e
  end

  while i <= n do
    local c = peek()
    if c == "\n" then
      line = line + 1
      i = i + 1
    elseif c == " " or c == "\t" or c == "\r" then
      i = i + 1
    elseif c == "-" and peek(1) == "-" then
      -- comment: long or line
      local rest = source:sub(i + 2)
      local eqs, rbrack = rest:match("^%[(=*)%[")
      if eqs then
        local close = "%]" .. eqs .. "%]"
        local s, e = source:find(close, i + 2 + 2 + #eqs)
        if not s then return nil, "unterminated long comment at line " .. line end
        for _ in source:sub(i, s):gmatch("\n") do line = line + 1 end
        i = e + 1
      else
        local nl = source:find("\n", i)
        if nl then i = nl else i = n + 1 end
      end
    elseif c:match("[%a_]") then
      local s, e, word = source:find("^([%a_][%w_]*)", i)
      i = e + 1
      if KEYWORDS[word] then push(word, word) else push("name", word) end
    elseif c:match("%d") or (c == "." and peek(1):match("%d")) then
      local num, e = match_at(i, "^(0[xX]%x+)")
      -- crescent's vendored LuaJIT fork accepts 0b binary literals.
      if not num then num, e = match_at(i, "^(0[bB][01]+)") end
      if not num then num, e = match_at(i, "^(%d+%.?%d*[eE]?[%+%-]?%d*)") end
      if not num then num, e = match_at(i, "^(%.%d+[eE]?[%+%-]?%d*)") end
      if not num then return nil, "bad number at line " .. line end
      i = e + 1
      -- LuaJIT cdata-literal suffixes: 0ULL, 123LL, 4.5i (complex), etc.
      local suffix, se = match_at(i, "^([ULil][ULil]?[ULil]?)")
      if suffix then
        num = num .. suffix
        i = se + 1
      end
      push("number", num)
    elseif c == "\"" or c == "'" then
      local quote = c
      local buf = {}
      local j = i + 1
      while true do
        if j > n then return nil, "unterminated string at line " .. line end
        local cj = source:sub(j, j)
        if cj == quote then j = j + 1; break end
        if cj == "\\" then
          buf[#buf + 1] = source:sub(j, j + 1)
          j = j + 2
        else
          if cj == "\n" then line = line + 1 end
          buf[#buf + 1] = cj
          j = j + 1
        end
      end
      push("string", table.concat(buf))
      i = j
    elseif c == "[" and (peek(1) == "[" or peek(1) == "=") then
      local rest = source:sub(i)
      local eqs = rest:match("^%[(=*)%[")
      if eqs then
        local close = "%]" .. eqs .. "%]"
        local start_content = i + 2 + #eqs
        if source:sub(start_content, start_content) == "\n" then
          start_content = start_content + 1
          line = line + 1
        end
        local s, e = source:find(close, start_content)
        if not s then return nil, "unterminated long string at line " .. line end
        local content = source:sub(start_content, s - 1)
        for _ in content:gmatch("\n") do line = line + 1 end
        push("string", content)
        i = e + 1
      else
        push("[", "[")
        i = i + 1
      end
    else
      local three = source:sub(i, i + 2)
      local two = source:sub(i, i + 1)
      if three == "..." then push("...", three); i = i + 3
      elseif two == ".." then push("..", two); i = i + 2
      elseif two == "==" then push("==", two); i = i + 2
      elseif two == "~=" then push("~=", two); i = i + 2
      elseif two == "<=" then push("<=", two); i = i + 2
      elseif two == ">=" then push(">=", two); i = i + 2
      elseif two == "::" then push("::", two); i = i + 2
      elseif c:match("[%+%-%*/%%%^#<>=%(%)%{%}%[%]:;,%.]") then
        push(c, c); i = i + 1
      else
        return nil, "unexpected character '" .. c .. "' at line " .. line
      end
    end
  end
  push("eof", "")
  return toks, nil
end

-- ═══════════════════════════ parser ═══════════════════════════

--: (toks: { [integer]: { kind: string, text: string, line: integer } }) -> ({ [string]: unknown } | nil, string | nil)
local function parse_tokens(toks)
  local pos = 1

  local function cur() return toks[pos] end
  local function at(kind) return cur().kind == kind end
  local function advance() local t = toks[pos]; pos = pos + 1; return t end

  local err = nil --: string | nil
  local function fail(msg)
    if not err then err = msg .. " (line " .. cur().line .. ", got '" .. cur().kind .. "')" end
    error({ __grammar_gen_parse_fail = true }, 0)
  end

  local function expect(kind)
    if not at(kind) then fail("expected '" .. kind .. "'") end
    return advance()
  end

  local parse_expr, parse_block, parse_stat, parse_table

  local function parse_namelist()
    local names = { expect("name").text }
    while at(",") do advance(); names[#names + 1] = expect("name").text end
    return names
  end

  local function parse_exprlist()
    local list = { parse_expr() }
    while at(",") do advance(); list[#list + 1] = parse_expr() end
    return list
  end

  local function parse_funcbody(is_method)
    expect("(")
    local params = {} --: { [integer]: string }
    local vararg = false
    if is_method then params[#params + 1] = "self" end
    if not at(")") then
      while true do
        if at("...") then advance(); vararg = true; break end
        params[#params + 1] = expect("name").text
        if at(",") then advance() else break end
      end
    end
    expect(")")
    local body = parse_block()
    expect("end")
    return { tag = "function", params = params, vararg = vararg, body = body }
  end

  local function parse_primary_expr()
    if at("(") then
      advance()
      local e = parse_expr()
      expect(")")
      return { tag = "paren", expr = e }
    elseif at("name") then
      return { tag = "name", name = advance().text }
    else
      fail("expected primary expression")
    end
  end

  --: () -> { [integer]: Node }
  local function parse_args()
    if at("(") then
      advance()
      local list = {} --: { [integer]: Node }
      if not at(")") then list = parse_exprlist() end
      expect(")")
      return list
    elseif at("string") then
      return { { tag = "string", value = advance().text } }
    elseif at("{") then
      return { parse_table() }
    else
      fail("expected call arguments")
    end
  end

  local function parse_suffixed_expr()
    local e = parse_primary_expr() --: Node
    while true do
      if at(".") then
        advance()
        local name = expect("name").text
        e = { tag = "index", obj = e, key = { tag = "string", value = name }, dot = true }
      elseif at("[") then
        advance()
        local k = parse_expr()
        expect("]")
        e = { tag = "index", obj = e, key = k, dot = false }
      elseif at(":") then
        advance()
        local name = expect("name").text
        local args = parse_args()
        e = { tag = "methodcall", obj = e, method = name, args = args }
      elseif at("(") or at("string") or at("{") then
        local args = parse_args()
        e = { tag = "call", fn = e, args = args }
      else
        break
      end
    end
    return e
  end

  local function parse_simple_expr()
    if at("number") then return { tag = "number", value = advance().text }
    elseif at("string") then return { tag = "string", value = advance().text }
    elseif at("nil") then advance(); return { tag = "nil" }
    elseif at("true") then advance(); return { tag = "true" }
    elseif at("false") then advance(); return { tag = "false" }
    elseif at("...") then advance(); return { tag = "vararg" }
    elseif at("{") then return parse_table()
    elseif at("function") then advance(); return parse_funcbody(false)
    else return parse_suffixed_expr()
    end
  end

  local UNOP = { ["not"] = true, ["-"] = true, ["#"] = true }
  local BINPREC = {
    ["or"] = 1, ["and"] = 2,
    ["<"] = 3, [">"] = 3, ["<="] = 3, [">="] = 3, ["~="] = 3, ["=="] = 3,
    [".."] = 5,
    ["+"] = 6, ["-"] = 6,
    ["*"] = 7, ["/"] = 7, ["%"] = 7,
    ["^"] = 10,
  }
  local RIGHT_ASSOC = { [".."] = true, ["^"] = true }
  local UNARY_PREC = 8

  local function parse_subexpr(limit)
    local e --: Node | nil
    if UNOP[cur().kind] then
      local op = advance().kind
      local operand = parse_subexpr(UNARY_PREC)
      e = { tag = "unop", op = op, expr = operand }
    else
      e = parse_simple_expr()
    end
    while BINPREC[cur().kind] and BINPREC[cur().kind] > limit do
      local op = advance().kind
      local next_limit = BINPREC[op]
      if not RIGHT_ASSOC[op] then next_limit = next_limit end
      local rhs = parse_subexpr(RIGHT_ASSOC[op] and next_limit - 1 or next_limit)
      e = { tag = "binop", op = op, lhs = e, rhs = rhs }
    end
    return e
  end

  parse_expr = function() return parse_subexpr(0) end

  parse_table = function()
    expect("{")
    local fields = {} --: { [integer]: Node }
    while not at("}") do
      if at("[") then
        advance()
        local k = parse_expr()
        expect("]")
        expect("=")
        local v = parse_expr()
        fields[#fields + 1] = { kind = "keyed", key = k, value = v }
      elseif at("name") and toks[pos + 1].kind == "=" then
        local name = advance().text
        advance() -- '='
        local v = parse_expr()
        fields[#fields + 1] = { kind = "named", name = name, value = v }
      else
        local v = parse_expr()
        fields[#fields + 1] = { kind = "positional", value = v }
      end
      if at(",") or at(";") then advance() else break end
    end
    expect("}")
    return { tag = "table", fields = fields }
  end

  --: () -> (Node, boolean)
  local function parse_funcname()
    local base = { tag = "name", name = expect("name").text } --: Node
    local is_method = false
    while at(".") do
      advance()
      base = { tag = "index", obj = base, key = { tag = "string", value = expect("name").text }, dot = true }
    end
    if at(":") then
      advance()
      base = { tag = "index", obj = base, key = { tag = "string", value = expect("name").text }, dot = true }
      is_method = true
    end
    return base, is_method
  end

  local BLOCK_END = { ["end"] = true, ["else"] = true, ["elseif"] = true, ["until"] = true, ["eof"] = true }

  parse_stat = function()
    if at(";") then advance(); return nil
    elseif at("if") then
      advance()
      local clauses = {}
      local cond = parse_expr()
      expect("then")
      local body = parse_block()
      clauses[#clauses + 1] = { cond = cond, body = body }
      while at("elseif") do
        advance()
        local c2 = parse_expr()
        expect("then")
        local b2 = parse_block()
        clauses[#clauses + 1] = { cond = c2, body = b2 }
      end
      local els = nil
      if at("else") then advance(); els = parse_block() end
      expect("end")
      return { tag = "if", clauses = clauses, orelse = els }
    elseif at("while") then
      advance()
      local cond = parse_expr()
      expect("do")
      local body = parse_block()
      expect("end")
      return { tag = "while", cond = cond, body = body }
    elseif at("do") then
      advance()
      local body = parse_block()
      expect("end")
      return { tag = "do", body = body }
    elseif at("for") then
      advance()
      local n1 = expect("name").text
      if at("=") then
        advance()
        local from = parse_expr()
        expect(",")
        local to = parse_expr()
        local step = nil
        if at(",") then advance(); step = parse_expr() end
        expect("do")
        local body = parse_block()
        expect("end")
        return { tag = "fornum", var = n1, from = from, to = to, step = step, body = body }
      else
        local names = { n1 }
        while at(",") do advance(); names[#names + 1] = expect("name").text end
        expect("in")
        local exprs = parse_exprlist()
        expect("do")
        local body = parse_block()
        expect("end")
        return { tag = "forin", names = names, exprs = exprs, body = body }
      end
    elseif at("repeat") then
      advance()
      local body = parse_block()
      expect("until")
      local cond = parse_expr()
      return { tag = "repeat", body = body, cond = cond }
    elseif at("function") then
      advance()
      local name, is_method = parse_funcname()
      local fn = parse_funcbody(is_method)
      return { tag = "assign", targets = { name }, values = { fn } }
    elseif at("local") then
      advance()
      if at("function") then
        advance()
        local name = expect("name").text
        local fn = parse_funcbody(false)
        return { tag = "localfunction", name = name, fn = fn }
      end
      local names = parse_namelist()
      local values = {}
      if at("=") then advance(); values = parse_exprlist() end
      return { tag = "local", names = names, values = values }
    elseif at("return") then
      advance()
      local exprs = {}
      if not BLOCK_END[cur().kind] and not at(";") then exprs = parse_exprlist() end
      if at(";") then advance() end
      return { tag = "return", exprs = exprs }
    elseif at("break") then
      advance()
      return { tag = "break" }
    elseif at("goto") then
      advance()
      local label = expect("name").text
      return { tag = "goto", label = label }
    elseif at("::") then
      advance()
      local label = expect("name").text
      expect("::")
      return { tag = "label", label = label }
    else
      local e = parse_suffixed_expr()
      if at("=") or at(",") then
        local targets = { e }
        while at(",") do advance(); targets[#targets + 1] = parse_suffixed_expr() end
        expect("=")
        local values = parse_exprlist()
        return { tag = "assign", targets = targets, values = values }
      else
        return { tag = "exprstat", expr = e }
      end
    end
  end

  parse_block = function()
    local stats = {} --: { [integer]: Node }
    while not BLOCK_END[cur().kind] do
      local start_line = cur().line
      local s = parse_stat()
      if s then
        s.line = start_line
        stats[#stats + 1] = s
      end
      if s and s.tag == "return" then break end
    end
    return { tag = "block", stats = stats }
  end

  local ok, result = pcall(function()
    local block = parse_block()
    expect("eof")
    return block
  end)

  if not ok then
    if type(result) == "table" and result.__grammar_gen_parse_fail then
      return nil, err or "parse error"
    end
    return nil, tostring(result)
  end
  return result, nil
end

--: (source: string, filename: string | nil) -> ({ [string]: unknown } | nil, string | nil)
function M.parse(source, filename)
  local toks, lex_err = lex(source)
  if not toks then
    return nil, (filename or "?") .. ": " .. (lex_err or "?")
  end
  local ast, perr = parse_tokens(toks)
  if not ast then
    return nil, (filename or "?") .. ": " .. (perr or "?")
  end
  return ast, nil
end

return M
