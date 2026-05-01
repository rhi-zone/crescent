if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

-- ============================================================
-- TERM REPRESENTATION
-- ============================================================
-- Atoms:    { kind="atom", name=string }
-- Numbers:  { kind="num",  value=number }
-- Vars:     { kind="var",  name=string }
-- Compound: { kind="comp", functor=string, args={term,...} }
-- List:     sugar, desugared to compound '.'(H,T) at parse time
-- _:        anonymous var, { kind="var", name="_N" } with unique N

local _anon_id = 0
local function anon_var()
  _anon_id = _anon_id + 1
  return { kind = "var", name = "_" .. _anon_id }
end

--:: PrologTerm = { kind: string, ... }
local function mk_atom(n)  return { kind = "atom", name = n } end
local function mk_num(v)   return { kind = "num",  value = v } end
local function mk_var(n)   return { kind = "var",  name = n } end
--: (string, { [integer]: PrologTerm }) -> PrologTerm
local function mk_comp(f, args) return { kind = "comp", functor = f, args = args } end

local NIL_ATOM = mk_atom("[]")

local function mk_list(elems, tail)
  local t = tail or NIL_ATOM
  for i = #elems, 1, -1 do
    t = mk_comp(".", { elems[i], t })
  end
  return t
end

-- ============================================================
-- PARSER
-- ============================================================
-- Parses Prolog-like terms/clauses from strings.
-- Supports: atoms, numbers, variables, compound f(a,b), lists [H|T],
-- operator notation for :- , ; (in terms only).

local function parse_error(msg, src, pos)
  return nil, ("parse error at position %d (%q): %s"):format(pos, src:sub(pos, pos+10), msg)
end

-- Lexer
--:: PrologToken = { type: string, value: string | number | nil, pos: integer }
--: (string) -> { [integer]: PrologToken }
local function lex(src)
  --: { [integer]: PrologToken }
  local tokens = {}
  local i = 1
  local n = #src
  while i <= n do
    -- skip whitespace and comments
    local ws = src:match("^%s+", i)
    if ws then i = i + #ws end
    if i > n then break end
    -- line comment
    if src:sub(i, i+1) == "/*" then
      local e = src:find("%*/", i+2)
      if not e then i = n + 1 else i = e + 2 end
    elseif src:sub(i, i) == "%" then
      local e = src:find("\n", i+1)
      if not e then i = n + 1 else i = e + 1 end
    -- quoted atom
    elseif src:sub(i, i) == "'" then
      local j = i + 1
      local chars = {}
      while j <= n do
        local c = src:sub(j, j)
        if c == "'" then
          if src:sub(j+1, j+1) == "'" then
            chars[#chars+1] = "'"
            j = j + 2
          else
            j = j + 1
            break
          end
        else
          chars[#chars+1] = c
          j = j + 1
        end
      end
      tokens[#tokens+1] = { type = "atom", value = table.concat(chars), pos = i }
      i = j
    -- numbers (integer or float) — only bare digits; unary minus handled by parser
    elseif src:match("^%d", i) then
      local num_str = src:match("^%d+%.%d+", i) or src:match("^%d+", i)
      tokens[#tokens+1] = { type = "num", value = tonumber(num_str), pos = i }
      i = i + #num_str
    -- lowercase atom or functor
    elseif src:match("^[a-z]", i) then
      local word = src:match("^[a-zA-Z0-9_]+", i)
      tokens[#tokens+1] = { type = "atom", value = word, pos = i }
      i = i + #word
    -- variable (uppercase or _)
    elseif src:match("^[A-Z_]", i) then
      local word = src:match("^[a-zA-Z0-9_]+", i)
      tokens[#tokens+1] = { type = "var", value = word, pos = i }
      i = i + #word
    -- operator-like tokens
    elseif src:sub(i, i+2) == "\\==" then
      tokens[#tokens+1] = { type = "op", value = "\\==", pos = i }
      i = i + 3
    elseif src:sub(i, i+1) == ":-" then
      tokens[#tokens+1] = { type = "op", value = ":-", pos = i }
      i = i + 2
    elseif src:sub(i, i+1) == "==" then
      tokens[#tokens+1] = { type = "op", value = "==", pos = i }
      i = i + 2
    elseif src:sub(i, i+1) == "=<" then
      tokens[#tokens+1] = { type = "op", value = "=<", pos = i }
      i = i + 2
    elseif src:sub(i, i+1) == ">=" then
      tokens[#tokens+1] = { type = "op", value = ">=", pos = i }
      i = i + 2
    elseif src:sub(i, i+1) == "\\+" then
      tokens[#tokens+1] = { type = "op", value = "\\+", pos = i }
      i = i + 2
    elseif src:find("^[+%-%*/^<>=!,;.|\\%(%)%[%]{}]", i) then
      local c = src:sub(i, i)
      tokens[#tokens+1] = { type = "op", value = c, pos = i }
      i = i + 1
    else
      i = i + 1  -- skip unknown char
    end
  end
  return tokens
end

-- Recursive descent parser
-- Returns (term, next_pos) or (nil, err)
local parse_term  -- forward declaration

-- parse a primary term (no operators)
local function parse_primary(toks, pos)
  local tok = toks[pos]
  if not tok then return nil, "unexpected end of input" end

  -- anonymous variable
  if tok.type == "var" and tok.value == "_" then
    return anon_var(), pos + 1
  end

  -- variable
  if tok.type == "var" then
    return mk_var(tok.value), pos + 1
  end

  -- number
  if tok.type == "num" then
    return mk_num(tok.value), pos + 1
  end

  -- negative number: unary minus before num
  if tok.type == "op" and tok.value == "-" then
    local next = toks[pos+1]
    if next and next.type == "num" then
      return mk_num(-next.value), pos + 2
    end
    -- unary minus as atom/functor
    return mk_atom("-"), pos + 1
  end

  -- list syntax [...]
  if tok.type == "op" and tok.value == "[" then
    pos = pos + 1
    -- empty list
    if toks[pos] and toks[pos].type == "op" and toks[pos].value == "]" then
      return NIL_ATOM, pos + 1
    end
    -- parse elements
    local elems = {}
    local tail = NIL_ATOM
    while true do
      local elem, np = parse_term(toks, pos, 999)
      if not elem then return nil, np end
      elems[#elems+1] = elem
      pos = np
      local t2 = toks[pos]
      if not t2 then return nil, "unterminated list" end
      if t2.value == "]" then
        pos = pos + 1
        break
      elseif t2.value == "|" then
        pos = pos + 1
        local tl, np2 = parse_term(toks, pos, 999)
        if not tl then return nil, np2 end
        tail = tl
        pos = np2
        if not toks[pos] or toks[pos].value ~= "]" then
          return nil, "expected ] after list tail"
        end
        pos = pos + 1
        break
      elseif t2.value == "," then
        pos = pos + 1
      else
        return nil, "expected , or ] or | in list"
      end
    end
    return mk_list(elems, tail), pos
  end

  -- parenthesized term
  if tok.type == "op" and tok.value == "(" then
    local t, np = parse_term(toks, pos + 1, 1200)
    if not t then return nil, np end
    if not toks[np] or toks[np].value ~= ")" then
      return nil, "expected ) after term"
    end
    return t, np + 1
  end

  -- atom, possibly followed by (args)
  if tok.type == "atom" then
    local name = tok.value
    pos = pos + 1
    -- compound term?
    if toks[pos] and toks[pos].type == "op" and toks[pos].value == "(" then
      pos = pos + 1
      local args = {}
      if toks[pos] and toks[pos].value == ")" then
        -- zero-arg compound (treated as atom)
        return mk_atom(name), pos + 1
      end
      while true do
        local arg, np = parse_term(toks, pos, 999)
        if not arg then return nil, np end
        args[#args+1] = arg
        pos = np
        local sep = toks[pos]
        if not sep then return nil, "unterminated compound" end
        if sep.value == ")" then
          pos = pos + 1
          break
        elseif sep.value == "," then
          pos = pos + 1
        else
          return nil, "expected , or ) in compound, got: " .. tostring(sep.value)
        end
      end
      return mk_comp(name, args), pos
    end
    return mk_atom(name), pos
  end

  -- operator token used as atom (e.g. "!" as atom)
  if tok.type == "op" then
    local v = tok.value
    if v == "!" then return mk_atom("!"), pos + 1 end
  end

  return nil, "unexpected token: " .. tostring(tok.type) .. " " .. tostring(tok.value)
end

-- Operator precedence table (priority, type)
-- type: xfx yfx xfy etc.  left-assoc = yfx, right-assoc = xfy, non-assoc = xfx
local INFIX_OPS = {
  [":-"]  = { 1200, "xfx" },
  [";"]   = { 1100, "xfy" },
  [","]   = { 1000, "xfy" },
  ["is"]  = {  700, "xfx" },
  ["=="]  = {  700, "xfx" },
  ["\\=="] = { 700, "xfx" },
  ["<"]   = {  700, "xfx" },
  [">"]   = {  700, "xfx" },
  ["=<"]  = {  700, "xfx" },
  [">="]  = {  700, "xfx" },
  ["="]   = {  700, "xfx" },
  ["+"]   = {  500, "yfx" },
  ["-"]   = {  500, "yfx" },
  ["*"]   = {  400, "yfx" },
  ["/"]   = {  400, "yfx" },
  ["mod"] = {  400, "yfx" },
  ["^"]   = {  200, "xfy" },
}

local PREFIX_OPS = {
  ["not"]  = { 900, "fy" },
  ["\\+"]  = { 900, "fy" },
  ["-"]    = { 200, "fy" },
}

-- parse_term: Pratt-style operator-precedence parser
-- maxprec: the maximum precedence of operators to consume at this level
parse_term = function(toks, pos, maxprec)
  maxprec = maxprec or 1200
  local lhs, np

  -- Try prefix operator
  local tok = toks[pos]
  if tok then
    local pfx = PREFIX_OPS[tok.value]
    if pfx and pfx[1] <= maxprec then
      local rprec = pfx[2] == "fy" and pfx[1] or pfx[1] - 1
      local rhs, np2 = parse_term(toks, pos + 1, rprec)
      if rhs then
        lhs = mk_comp(tok.value, { rhs })
        np = np2
      else
        -- not a prefix, fall through to primary
        lhs, np = parse_primary(toks, pos)
        if not lhs then return nil, np end
      end
    else
      lhs, np = parse_primary(toks, pos)
      if not lhs then return nil, np end
    end
  else
    return nil, "unexpected end of input"
  end

  -- consume infix operators
  while true do
    local t = toks[np]
    if not t then break end
    -- infix operator?
    local op = t.value
    -- "is", "mod" come as atom tokens
    if t.type == "atom" and INFIX_OPS[op] then
      -- ok
    elseif t.type == "op" and INFIX_OPS[op] then
      -- ok
    else
      break
    end
    local info = INFIX_OPS[op]
    local prec = info[1]
    local assoc = info[2]
    if prec > maxprec then break end
    -- determine right-hand side max prec
    local rprec
    if assoc == "yfx" then
      rprec = prec - 1
    elseif assoc == "xfy" then
      rprec = prec
    else -- xfx
      rprec = prec - 1
    end
    local rhs, np2 = parse_term(toks, np + 1, rprec)
    if not rhs then break end
    lhs = mk_comp(op, { lhs, rhs })
    np = np2
  end

  return lhs, np
end

-- Parse a clause string into (head, body_list) or (nil, err)
-- body_list is an array of terms (goals)
-- A fact: head.   or just head
-- A rule: head :- goal1, goal2, ...
local function parse_clause(src)
  src = src:gsub("%.%s*$", "")  -- strip trailing dot
  local toks = lex(src)
  if #toks == 0 then return nil, "empty clause" end
  local term, np = parse_term(toks, 1, 1200)
  if not term then return nil, np end

  -- Split on :-
  if term.kind == "comp" and term.functor == ":-" then
    local head = term.args[1]
    local body_term = term.args[2]
    -- flatten comma conjunction
    local goals = {}
    local function flatten_conj(t)
      if t.kind == "comp" and t.functor == "," then
        flatten_conj(t.args[1])
        flatten_conj(t.args[2])
      else
        goals[#goals+1] = t
      end
    end
    flatten_conj(body_term)
    return head, goals
  else
    return term, {}
  end
end

-- Parse a goal string into a list of goals
local function parse_goals(src)
  src = src:gsub("%.%s*$", "")
  local toks = lex(src)
  if #toks == 0 then return {} end
  local term, np = parse_term(toks, 1, 1200)
  if not term then return nil, np end
  local goals = {}
  local function flatten_conj(t)
    if t.kind == "comp" and t.functor == "," then
      flatten_conj(t.args[1])
      flatten_conj(t.args[2])
    else
      goals[#goals+1] = t
    end
  end
  flatten_conj(term)
  return goals
end

-- ============================================================
-- TERM UTILITIES
-- ============================================================

-- Deep-copy a term, renaming variables with a fresh prefix
local function copy_term(term, mapping)
  mapping = mapping or {}
  local k = term.kind
  if k == "var" then
    if not mapping[term.name] then
      _anon_id = _anon_id + 1
      mapping[term.name] = { kind = "var", name = term.name .. "_" .. _anon_id }
    end
    return mapping[term.name]
  elseif k == "atom" or k == "num" then
    return term
  elseif k == "comp" then
    local args = {}
    for i = 1, #term.args do
      args[i] = copy_term(term.args[i], mapping)
    end
    return { kind = "comp", functor = term.functor, args = args }
  end
  return term
end

-- Walk a variable through the substitution environment
local function walk(env, t)
  while t.kind == "var" do
    local val = env[t.name]
    if val == nil then break end
    t = val
  end
  return t
end

-- Deep walk: substitute all variables recursively
local function deref(env, t)
  t = walk(env, t)
  if t.kind == "comp" then
    local args = {}
    for i = 1, #t.args do
      args[i] = deref(env, t.args[i])
    end
    return { kind = "comp", functor = t.functor, args = args }
  end
  return t
end

-- Unification
local function unify(env, t1, t2)
  t1 = walk(env, t1)
  t2 = walk(env, t2)

  if t1.kind == "var" and t2.kind == "var" and t1.name == t2.name then
    return env
  end
  if t1.kind == "var" then
    -- bind t1 → t2
    local e2 = {}
    for k, v in pairs(env) do e2[k] = v end
    e2[t1.name] = t2
    return e2
  end
  if t2.kind == "var" then
    local e2 = {}
    for k, v in pairs(env) do e2[k] = v end
    e2[t2.name] = t1
    return e2
  end
  if t1.kind == "atom" and t2.kind == "atom" and t1.name == t2.name then
    return env
  end
  if t1.kind == "num" and t2.kind == "num" and t1.value == t2.value then
    return env
  end
  if t1.kind == "comp" and t2.kind == "comp"
    and t1.functor == t2.functor
    and #t1.args == #t2.args then
    local e = env
    for i = 1, #t1.args do
      e = unify(e, t1.args[i], t2.args[i])
      if not e then return nil end
    end
    return e
  end
  return nil
end

-- Convert a term back to a string (for display)
local function term_to_string(env, t)
  t = deref(env, t)
  if t.kind == "var" then
    -- Strip the _N suffix added by copy_term to show original name
    return t.name:match("^([^_]+)") or t.name
  elseif t.kind == "atom" then
    return t.name
  elseif t.kind == "num" then
    local v = t.value
    if v == math.floor(v) then return tostring(math.floor(v)) else return tostring(v) end
  elseif t.kind == "comp" then
    -- List display
    if t.functor == "." and #t.args == 2 then
      local elems = {}
      local cur = t
      while cur.kind == "comp" and cur.functor == "." and #cur.args == 2 do
        elems[#elems+1] = term_to_string(env, cur.args[1])
        cur = deref(env, cur.args[2])
      end
      if cur.kind == "atom" and cur.name == "[]" then
        return "[" .. table.concat(elems, ",") .. "]"
      else
        return "[" .. table.concat(elems, ",") .. "|" .. term_to_string(env, cur) .. "]"
      end
    end
    local args = {}
    for i = 1, #t.args do
      args[i] = term_to_string(env, t.args[i])
    end
    return t.functor .. "(" .. table.concat(args, ",") .. ")"
  end
  return "?"
end

-- Evaluate an arithmetic expression term to a number
local function eval_arith(env, t)
  t = deref(env, t)
  if t.kind == "num" then return t.value end
  if t.kind == "var" then
    return nil, "unbound variable in arithmetic: " .. t.name
  end
  if t.kind == "atom" then
    local n = tonumber(t.name)
    if n then return n end
    return nil, "non-numeric atom in arithmetic: " .. t.name
  end
  if t.kind == "comp" then
    local f = t.functor
    if f == "+" and #t.args == 2 then
      local a, e1 = eval_arith(env, t.args[1])
      if not a then return nil, e1 end
      local b, e2 = eval_arith(env, t.args[2])
      if not b then return nil, e2 end
      return a + b
    elseif f == "-" and #t.args == 2 then
      local a, e1 = eval_arith(env, t.args[1])
      if not a then return nil, e1 end
      local b, e2 = eval_arith(env, t.args[2])
      if not b then return nil, e2 end
      return a - b
    elseif f == "-" and #t.args == 1 then
      local a, e1 = eval_arith(env, t.args[1])
      if not a then return nil, e1 end
      return -a
    elseif f == "*" and #t.args == 2 then
      local a, e1 = eval_arith(env, t.args[1])
      if not a then return nil, e1 end
      local b, e2 = eval_arith(env, t.args[2])
      if not b then return nil, e2 end
      return a * b
    elseif f == "/" and #t.args == 2 then
      local a, e1 = eval_arith(env, t.args[1])
      if not a then return nil, e1 end
      local b, e2 = eval_arith(env, t.args[2])
      if not b then return nil, e2 end
      return a / b
    elseif f == "mod" and #t.args == 2 then
      local a, e1 = eval_arith(env, t.args[1])
      if not a then return nil, e1 end
      local b, e2 = eval_arith(env, t.args[2])
      if not b then return nil, e2 end
      return a % b
    elseif f == "^" and #t.args == 2 then
      local a, e1 = eval_arith(env, t.args[1])
      if not a then return nil, e1 end
      local b, e2 = eval_arith(env, t.args[2])
      if not b then return nil, e2 end
      return a ^ b
    elseif f == "abs" and #t.args == 1 then
      local a, e1 = eval_arith(env, t.args[1])
      if not a then return nil, e1 end
      return math.abs(a)
    elseif f == "max" and #t.args == 2 then
      local a, e1 = eval_arith(env, t.args[1])
      if not a then return nil, e1 end
      local b, e2 = eval_arith(env, t.args[2])
      if not b then return nil, e2 end
      return math.max(a, b)
    elseif f == "min" and #t.args == 2 then
      local a, e1 = eval_arith(env, t.args[1])
      if not a then return nil, e1 end
      local b, e2 = eval_arith(env, t.args[2])
      if not b then return nil, e2 end
      return math.min(a, b)
    end
  end
  return nil, "cannot evaluate as arithmetic: " .. term_to_string({}, t)
end

-- Extract the predicate key from a term: "functor/arity"
local function pred_key(t)
  if t.kind == "atom" then return t.name .. "/0" end
  if t.kind == "comp" then return t.functor .. "/" .. #t.args end
  return nil
end

-- ============================================================
-- DATABASE
-- ============================================================

local CUT = {}  -- sentinel for cut

local DB = {}
DB.__index = DB

function M.database()
  local self = setmetatable({}, DB)
  self._clauses = {}  -- predicate_key -> { {head=term, body={term,...}}, ... }
  self._write_fn = nil
  return self
end

function DB:set_write_fn(write_fn)
  self._write_fn = write_fn
end

-- Add a clause (parsed head + body goals)
local function db_add_clause(self, head, body)
  local key = pred_key(head)
  if not key then return nil, "invalid head" end
  if not self._clauses[key] then
    self._clauses[key] = {}
  end
  local clauses = self._clauses[key]
  clauses[#clauses+1] = { head = head, body = body }
  return true
end

-- Assert a clause from string
function DB:assert(clause_str)
  local head, body = parse_clause(clause_str)
  if not head then return nil, body end
  return db_add_clause(self, head, body)
end

-- Retract matching clause (first match)
function DB:retract(clause_str)
  local head, body = parse_clause(clause_str)
  if not head then return nil, body end
  local key = pred_key(head)
  local clauses = self._clauses[key]
  if not clauses then return nil, "no clauses for " .. key end
  -- find first clause whose head unifies with the given head
  for i = 1, #clauses do
    local clause = clauses[i]
    local mapping = {}
    local head_copy = copy_term(clause.head, mapping)
    local env = unify({}, head_copy, head)
    if env then
      -- also check body if provided
      local body_match = true
      if #body > 0 and #clause.body ~= #body then
        body_match = false
      elseif #body > 0 then
        for j = 1, #body do
          local body_copy = copy_term(clause.body[j], mapping)
          env = unify(env, body_copy, body[j])
          if not env then body_match = false break end
        end
      end
      if body_match then
        table.remove(clauses, i)
        return true
      end
    end
  end
  return nil, "no matching clause for " .. clause_str
end

-- ============================================================
-- SOLVER
-- ============================================================
-- Backtracking solver using Lua coroutines.
-- Yields each substitution environment that satisfies the goals.
-- Cut is implemented by throwing CUT sentinel.

local solve  -- forward declaration

-- Resolve a goal list against the database, yielding solutions (envs)
-- `depth` is used to detect infinite recursion (safety limit)
solve = function(db, goals, env, depth)
  depth = depth or 0
  if depth > 50000 then
    error("maximum recursion depth exceeded")
  end

  if #goals == 0 then
    coroutine.yield(env)
    return
  end

  local goal = goals[1]
  local rest = {}
  for i = 2, #goals do rest[i-1] = goals[i] end

  goal = deref(env, goal)

  local functor, arity
  if goal.kind == "atom" then
    functor = goal.name
    arity = 0
  elseif goal.kind == "comp" then
    functor = goal.functor
    arity = #goal.args
  else
    -- Goal is not callable
    error("not a callable goal: " .. term_to_string(env, goal))
  end

  -- ---- Built-in predicates ----

  -- true/0
  if functor == "true" and arity == 0 then
    solve(db, rest, env, depth + 1)
    return
  end

  -- fail/0 or false/0
  if (functor == "fail" or functor == "false") and arity == 0 then
    return  -- no solutions
  end

  -- !/0 (cut)
  if functor == "!" and arity == 0 then
    solve(db, rest, env, depth + 1)
    error(CUT)  -- signal cut to the clause-choice loop
  end

  -- write/1
  if functor == "write" and arity == 1 then
    if not db._write_fn then error("prolog: write/1 requires set_write_fn()") end
    db._write_fn(term_to_string(env, goal.args[1]))
    solve(db, rest, env, depth + 1)
    return
  end

  -- nl/0
  if functor == "nl" and arity == 0 then
    if not db._write_fn then error("prolog: nl/0 requires set_write_fn()") end
    db._write_fn("\n")
    solve(db, rest, env, depth + 1)
    return
  end

  -- is/2: Y is Expr
  if functor == "is" and arity == 2 then
    local val, err = eval_arith(env, goal.args[2])
    if not val then error(err) end
    local new_env = unify(env, goal.args[1], mk_num(val))
    if new_env then
      solve(db, rest, new_env, depth + 1)
    end
    return
  end

  -- ==/2: strict equality (no unification, just check)
  if functor == "==" and arity == 2 then
    local t1 = deref(env, goal.args[1])
    local t2 = deref(env, goal.args[2])
    -- structural equality
    local function term_eq(a, b)
      if a.kind ~= b.kind then return false end
      if a.kind == "atom" then return a.name == b.name end
      if a.kind == "num" then return a.value == b.value end
      if a.kind == "var" then return a.name == b.name end
      if a.kind == "comp" then
        if a.functor ~= b.functor or #a.args ~= #b.args then return false end
        for i = 1, #a.args do
          if not term_eq(a.args[i], b.args[i]) then return false end
        end
        return true
      end
      return false
    end
    if term_eq(t1, t2) then
      solve(db, rest, env, depth + 1)
    end
    return
  end

  -- \==/2: strict inequality
  if functor == "\\==" and arity == 2 then
    local t1 = deref(env, goal.args[1])
    local t2 = deref(env, goal.args[2])
    local function term_eq(a, b)
      if a.kind ~= b.kind then return false end
      if a.kind == "atom" then return a.name == b.name end
      if a.kind == "num" then return a.value == b.value end
      if a.kind == "var" then return a.name == b.name end
      if a.kind == "comp" then
        if a.functor ~= b.functor or #a.args ~= #b.args then return false end
        for i = 1, #a.args do
          if not term_eq(a.args[i], b.args[i]) then return false end
        end
        return true
      end
      return false
    end
    if not term_eq(t1, t2) then
      solve(db, rest, env, depth + 1)
    end
    return
  end

  -- =/2: unification
  if functor == "=" and arity == 2 then
    local new_env = unify(env, goal.args[1], goal.args[2])
    if new_env then
      solve(db, rest, new_env, depth + 1)
    end
    return
  end

  -- arithmetic comparison predicates
  local ARITH_CMP = {
    ["<"]  = function(a, b) return a < b end,
    [">"]  = function(a, b) return a > b end,
    ["=<"] = function(a, b) return a <= b end,
    [">="] = function(a, b) return a >= b end,
  }
  if ARITH_CMP[functor] and arity == 2 then
    local a, e1 = eval_arith(env, goal.args[1])
    if not a then error(e1) end
    local b, e2 = eval_arith(env, goal.args[2])
    if not b then error(e2) end
    if ARITH_CMP[functor](a, b) then
      solve(db, rest, env, depth + 1)
    end
    return
  end

  -- not/1 or \+/1: negation as failure
  if (functor == "not" or functor == "\\+") and arity == 1 then
    local subgoal = goal.args[1]
    local found = false
    -- wrap in coroutine to check if any solution exists
    local co = coroutine.create(function()
      solve(db, { subgoal }, env, depth + 1)
    end)
    local ok2, val = coroutine.resume(co)
    if ok2 and coroutine.status(co) ~= "dead" then
      -- got at least one yield → subgoal succeeded
      found = true
    elseif ok2 and coroutine.status(co) == "dead" then
      -- coroutine finished without yielding
      found = false
    end
    if not found then
      solve(db, rest, env, depth + 1)
    end
    return
  end

  -- functor/3: functor(Term, Name, Arity)
  if functor == "functor" and arity == 3 then
    local term_arg = deref(env, goal.args[1])
    local name_arg = goal.args[2]
    local arity_arg = goal.args[3]
    local tname, tarity
    if term_arg.kind == "atom" then
      tname = term_arg.name; tarity = 0
    elseif term_arg.kind == "num" then
      tname = term_arg.value; tarity = 0
    elseif term_arg.kind == "comp" then
      tname = term_arg.functor; tarity = #term_arg.args
    else
      -- term is unbound — build compound from name/arity (not implemented)
      error("functor/3: term must be bound")
    end
    local e2 = unify(env, name_arg, mk_atom(tostring(tname)))
    if e2 then
      e2 = unify(e2, arity_arg, mk_num(tarity))
      if e2 then
        solve(db, rest, e2, depth + 1)
      end
    end
    return
  end

  -- arg/3: arg(N, Term, Arg)
  if functor == "arg" and arity == 3 then
    local n_term = deref(env, goal.args[1])
    local comp_term = deref(env, goal.args[2])
    if n_term.kind ~= "num" then error("arg/3: first argument must be a number") end
    if comp_term.kind ~= "comp" then error("arg/3: second argument must be compound") end
    local idx = math.floor(n_term.value)
    local arg = comp_term.args[idx]
    if arg then
      local e2 = unify(env, goal.args[3], arg)
      if e2 then solve(db, rest, e2, depth + 1) end
    end
    return
  end

  -- assert/1, assertz/1: dynamic assert
  if (functor == "assert" or functor == "assertz") and arity == 1 then
    local clause_term = deref(env, goal.args[1])
    local head2, body2
    if clause_term.kind == "comp" and clause_term.functor == ":-" then
      head2 = clause_term.args[1]
      local goals2 = {}
      local function flatten_c(t)
        if t.kind == "comp" and t.functor == "," then
          flatten_c(t.args[1]); flatten_c(t.args[2])
        else goals2[#goals2+1] = t end
      end
      flatten_c(clause_term.args[2])
      body2 = goals2
    else
      head2 = clause_term
      body2 = {}
    end
    db_add_clause(db, head2, body2)
    solve(db, rest, env, depth + 1)
    return
  end

  -- retract/1: dynamic retract
  if functor == "retract" and arity == 1 then
    local clause_term = deref(env, goal.args[1])
    local head2, body2
    if clause_term.kind == "comp" and clause_term.functor == ":-" then
      head2 = clause_term.args[1]
      local goals2 = {}
      local function flatten_c(t)
        if t.kind == "comp" and t.functor == "," then
          flatten_c(t.args[1]); flatten_c(t.args[2])
        else goals2[#goals2+1] = t end
      end
      flatten_c(clause_term.args[2])
      body2 = goals2
    else
      head2 = clause_term
      body2 = {}
    end
    -- find and remove clause
    local key2 = pred_key(head2)
    local clauses2 = db._clauses[key2]
    if clauses2 then
      for i = 1, #clauses2 do
        local cl = clauses2[i]
        local mapping2 = {}
        local hc = copy_term(cl.head, mapping2)
        local e2 = unify(env, hc, head2)
        if e2 then
          table.remove(clauses2, i)
          solve(db, rest, e2, depth + 1)
          return
        end
      end
    end
    return  -- fail if no clause matched
  end

  -- number_codes/2, atom_codes/2 (basic)
  if functor == "number_codes" and arity == 2 then
    local num_t = deref(env, goal.args[1])
    if num_t.kind == "num" then
      local s = tostring(math.floor(num_t.value) == num_t.value and math.floor(num_t.value) or num_t.value)
      local codes = {}
      for ci = 1, #s do codes[ci] = mk_num(s:byte(ci)) end
      local list_term = mk_list(codes)
      local e2 = unify(env, goal.args[2], list_term)
      if e2 then solve(db, rest, e2, depth + 1) end
    end
    return
  end

  if functor == "atom_codes" and arity == 2 then
    local atom_t = deref(env, goal.args[1])
    if atom_t.kind == "atom" then
      local s = atom_t.name
      local codes = {}
      for ci = 1, #s do codes[ci] = mk_num(s:byte(ci)) end
      local list_term = mk_list(codes)
      local e2 = unify(env, goal.args[2], list_term)
      if e2 then solve(db, rest, e2, depth + 1) end
    end
    return
  end

  -- ---- User-defined predicates (clauses) ----
  local key2 = functor .. "/" .. arity
  local clauses = db._clauses[key2]
  if not clauses or #clauses == 0 then
    -- No clauses: silently fail (standard Prolog behavior for unknown predicates)
    return
  end

  for i = 1, #clauses do
    local clause = clauses[i]
    -- Rename variables in clause to avoid collisions
    local mapping = {}
    local head_copy = copy_term(clause.head, mapping)
    local body_copy = {}
    for j = 1, #clause.body do
      body_copy[j] = copy_term(clause.body[j], mapping)
    end
    -- Try to unify goal with clause head
    local new_env = unify(env, goal, head_copy)
    if new_env then
      -- Build new goal list: body_copy ++ rest
      local new_goals = {}
      for j = 1, #body_copy do new_goals[j] = body_copy[j] end
      for j = 1, #rest do new_goals[#body_copy + j] = rest[j] end
      -- Solve with cut-handling
      local ok2, err = pcall(solve, db, new_goals, new_env, depth + 1)
      if not ok2 then
        if err == CUT then
          -- cut: stop trying more clauses for this predicate
          return
        else
          error(err, 0)  -- re-raise
        end
      end
    end
  end
end

-- ============================================================
-- QUERY API
-- ============================================================

-- Extract variable bindings from env for the original query variables
-- Returns a table mapping user-visible variable names to string values.
local function extract_bindings(env, query_vars)
  local result = {}
  for name, term in pairs(query_vars) do
    local val = deref(env, term)
    result[name] = term_to_string(env, val)
  end
  return result
end

-- Collect the variable names from a list of goal terms
local function collect_vars(goals)
  local vars = {}
  local seen = {}
  local function collect(t)
    if t.kind == "var" then
      -- Skip anonymous vars
      if not t.name:match("^_") and not seen[t.name] then
        seen[t.name] = true
        vars[t.name] = t
      end
    elseif t.kind == "comp" then
      for i = 1, #t.args do collect(t.args[i]) end
    end
  end
  for i = 1, #goals do collect(goals[i]) end
  return vars
end

-- db:query(goal_str) → coroutine-based iterator of substitution tables
function DB:query(goal_str)
  local goals, err = parse_goals(goal_str)
  if not goals then return nil, err end
  if #goals == 0 then return nil, "empty query" end

  local query_vars = collect_vars(goals)

  local co = coroutine.create(function()
    solve(self, goals, {}, 0)
  end)

  return function()
    if coroutine.status(co) == "dead" then return nil end
    local ok2, val = coroutine.resume(co)
    if not ok2 then
      if val == CUT then return nil end
      error(val)
    end
    if coroutine.status(co) == "dead" and val == nil then
      -- coroutine finished without yielding a value
      return nil
    end
    if val == nil then return nil end
    -- val is the environment that was yielded
    return extract_bindings(val, query_vars)
  end
end

-- db:query_all(goal_str) → array of substitution tables
function DB:query_all(goal_str)
  local iter, err = self:query(goal_str)
  if not iter then return nil, err end
  local results = {}
  for sol in iter do
    results[#results+1] = sol
  end
  return results
end

-- db:query_one(goal_str) → first substitution table or nil
function DB:query_one(goal_str)
  local iter, err = self:query(goal_str)
  if not iter then return nil, err end
  return iter()
end

-- db:satisfiable(goal_str) → bool
function DB:satisfiable(goal_str)
  local sol = self:query_one(goal_str)
  return sol ~= nil
end

return M
