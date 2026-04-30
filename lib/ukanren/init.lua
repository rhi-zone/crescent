if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}

--:: Var = { __var: true, id: integer, name: string | nil }
--:: Pair = { __pair: true, car: unknown, cdr: unknown }
--:: Sub = { [integer]: unknown }
--:: Goal = (Sub) -> unknown

-- Variable counter for unique ids
local _next_id = 0

-- Logic variables: {__var=true, id=n, name=s}
--: (name: (string | nil)) -> Var
function M.var(name)
  _next_id = _next_id + 1
  return { __var = true, id = _next_id, name = name }
end

--: (v: unknown) -> boolean
function M.is_var(v)
  return type(v) == "table" and v.__var == true
end

-- Cons pairs: {__pair=true, car=a, cdr=b}
--: (a: unknown, b: unknown) -> Pair
function M.cons(a, b)
  return { __pair = true, car = a, cdr = b }
end

--: (v: unknown) -> boolean
function M.is_pair(v)
  return type(v) == "table" and v.__pair == true
end

--: (p: Pair) -> unknown
function M.car(p) return p.car end

--: (p: Pair) -> unknown
function M.cdr(p) return p.cdr end

-- Build a linked list from values
--: (...unknown) -> (Pair | nil)
function M.list(...)
  local args = { ... }
  local n = select("#", ...)
  local l = nil
  for i = n, 1, -1 do
    l = M.cons(args[i], l)
  end
  return l
end

-- Walk: resolve a variable through substitution chain
--: (v: unknown, sub: Sub) -> unknown
local function walk(v, sub)
  while M.is_var(v) and sub[v.id] ~= nil do
    v = sub[v.id]
  end
  return v
end
M.walk = walk

-- Deep walk: recursively resolve all variables in a value
local function walk_deep(v, sub)
  v = walk(v, sub)
  if M.is_pair(v) then
    return M.cons(walk_deep(v.car, sub), walk_deep(v.cdr, sub))
  end
  return v
end
M.walk_deep = walk_deep

-- Unify: returns extended substitution or nil
--: (u: unknown, v: unknown, sub: Sub) -> Sub | nil
local function unify(u, v, sub)
  u = walk(u, sub)
  v = walk(v, sub)
  if M.is_var(u) and M.is_var(v) and u.id == v.id then
    return sub
  elseif M.is_var(u) then
    local s = {}
    for k, val in pairs(sub) do s[k] = val end
    s[u.id] = v
    return s
  elseif M.is_var(v) then
    local s = {}
    for k, val in pairs(sub) do s[k] = val end
    s[v.id] = u
    return s
  elseif M.is_pair(u) and M.is_pair(v) then
    local s = unify(u.car, v.car, sub)
    if s then return unify(u.cdr, v.cdr, s) end
    return nil
  elseif u == v then
    return sub
  else
    return nil
  end
end
M.unify = unify

-- Stream operations
-- Streams are: nil (empty), {head, tail} (mature), function (thunk/immature)

-- mplus: interleaving merge of two streams
local function mplus(s1, s2)
  if s1 == nil then return s2 end
  if type(s1) == "function" then
    return function() return mplus(s2, s1()) end
  end
  return { s1[1], mplus(s1[2], s2) }
end
M.mplus = mplus

-- bind: flatmap a goal over a stream
local function bind(s, g)
  if s == nil then return nil end
  if type(s) == "function" then
    return function() return bind(s(), g) end
  end
  return mplus(g(s[1]), bind(s[2], g))
end
M.bind = bind

-- Collect up to n results from a stream (nil n = all)
local function take(n, s)
  local results = {}
  local count = 0
  local max_steps = 100000
  local steps = 0
  while s ~= nil and (n == nil or count < n) do
    steps = steps + 1
    if steps > max_steps then break end
    if type(s) == "function" then
      s = s()
    else
      count = count + 1
      results[count] = s[1]
      s = s[2]
    end
  end
  return results
end
M.take = take

-- Goals

-- eq: unification goal
--: (u: unknown, v: unknown) -> Goal
function M.eq(u, v)
  return function(sub)
    local s = unify(u, v, sub)
    if s then return { s, nil } else return nil end
  end
end

-- Inverse-eta delay: wrap a goal thunk for fair search with recursive relations
-- Usage: uk.delay(function() return recursive_goal(...) end)
--: (thunk: () -> Goal) -> Goal
function M.delay(thunk)
  return function(sub)
    return function() return thunk()(sub) end
  end
end

-- conj: AND combinator
--: (g1: Goal, g2: Goal) -> Goal
function M.conj(g1, g2)
  return function(sub) return bind(g1(sub), g2) end
end

-- disj: OR combinator
--: (g1: Goal, g2: Goal) -> Goal
function M.disj(g1, g2)
  return function(sub) return mplus(g1(sub), g2(sub)) end
end

-- conj_all: AND all goals
--: (...Goal) -> Goal
function M.conj_all(...)
  local goals = { ... }
  local n = select("#", ...)
  if n == 0 then
    return function(sub) return { sub, nil } end
  end
  local g = goals[1]
  for i = 2, n do
    g = M.conj(--[[: any]] g, --[[: any]] goals[i])
  end
  return g
end

-- disj_all: OR all goals
--: (...Goal) -> Goal
function M.disj_all(...)
  local goals = { ... }
  local n = select("#", ...)
  if n == 0 then
    return function() return nil end
  end
  local g = goals[1]
  for i = 2, n do
    g = M.disj(--[[: any]] g, --[[: any]] goals[i])
  end
  return g
end

-- fresh: create N fresh variables and pass to fn
--: (fn: (...Var) -> Goal) -> Goal
function M.fresh(fn)
  local info = debug.getinfo(fn, "u")
  local nparams = info.nparams
  return function(sub)
    local vars = {}
    for i = 1, nparams do
      vars[i] = M.var()
    end
    local goal = fn(unpack(vars))
    return goal(sub)
  end
end

-- conde: each clause is a list of goals (conjunction), clauses are disjoined
--: (...{Goal}) -> Goal
function M.conde(...)
  local clauses = { ... }
  local n = select("#", ...)
  local goals = {}
  for i = 1, n do
    local clause = clauses[i]
    if #clause == 0 then
      goals[i] = function(sub) return { sub, nil } end
    else
      goals[i] = M.conj_all(unpack(clause))
    end
  end
  return M.disj_all(unpack(goals))
end

-- run: execute a goal, collect up to n results
--: (goal: Goal, n: (number | nil)) -> { Sub }
function M.run(goal, n)
  local stream = goal({})
  return take(n, stream)
end

-- run_fresh: create fresh variables, run, extract named bindings
--: (n: (number | nil), fn: (...Var) -> Goal) -> { { [string]: unknown } }
function M.run_fresh(n, fn)
  local info = debug.getinfo(fn, "u")
  local nparams = info.nparams
  local vars = {}
  for i = 1, nparams do
    vars[i] = M.var("_q" .. i)
  end
  local goal = fn(unpack(vars))
  local subs = M.run(goal, n)
  local results = {}
  for i, sub in ipairs(subs) do
    local r = {}
    for _, v in ipairs(vars) do
      r[v.name] = walk_deep(v, sub)
    end
    results[i] = r
  end
  return results
end

-- succeed: goal that always succeeds
--: Goal
function M.succeed(sub)
  return { sub, nil }
end

-- fail_goal: goal that always fails
--: Goal
function M.fail_goal()
  return nil
end

-- neq: disequality constraint
-- Checks ground disequality: if u and v are already equal under
-- the current substitution, fail. If they can't unify, succeed.
-- If they could become equal (free variables remain), succeed for now.
-- (A full CLP(Tree) would propagate constraints on free variables.)
--: (u: unknown, v: unknown) -> Goal
function M.neq(u, v)
  return function(sub)
    local s = unify(u, v, sub)
    if s == nil then
      -- Can't unify, constraint trivially satisfied
      return { sub, nil }
    end
    -- Check if the substitution was extended
    local extended = false
    for k, _ in pairs(s) do
      if sub[k] == nil then
        extended = true
        break
      end
    end
    if not extended then
      -- Already equal under current sub, constraint fails
      return nil
    end
    -- Not yet equal but could become so — succeed for now
    return { sub, nil }
  end
end

-- membero: relational membership
--: (x: unknown, lst: {unknown}) -> Goal
function M.membero(x, lst)
  if type(lst) == "table" and not lst.__pair and not lst.__var then
    -- Lua array: convert to disjunction
    local goals = {}
    for i = 1, #lst do
      goals[i] = M.eq(x, lst[i])
    end
    return M.disj_all(unpack(goals))
  end
  -- Pair list
  return M.conde(
    { M.eq(x, M.car(lst)) },
    { M.membero(x, M.cdr(lst)) }
  )
end

-- appendo: append relation on cons-lists
-- appendo(l, s, out) means l ++ s = out
--: (l: unknown, s: unknown, out: unknown) -> Goal
function M.appendo(l, s, out)
  return M.conde(
    { M.eq(l, nil), M.eq(s, out) },
    { M.fresh(function(a, d, res)
        return M.conj_all(
          M.eq(l, M.cons(a, d)),
          M.eq(out, M.cons(a, res)),
          M.delay(function() return M.appendo(d, s, res) end)
        )
      end) }
  )
end

return M
