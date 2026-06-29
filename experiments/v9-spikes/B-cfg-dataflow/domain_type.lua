-- v9 spike B: the TYPE domain as an abstract interpretation over the CFG.
--
-- Lattice element = a per-variable map { var -> typeset } where a typeset is a
-- set of atoms over {int,str,bool,nil}. A union type is just a typeset with >1
-- atom. `join` is pointwise set-union; this is exactly the flow-sensitive merge
-- we want at the post-if block.
--
-- This domain references NOTHING about liveness and NOTHING about the engine's
-- internals; it only provides the lattice + transfer the engine asks for.

local cfg = require("cfg")

local ATOMS = { "int", "str", "bool", "nil" }

local function typeset_eq(a, b)
  for _, k in ipairs(ATOMS) do
    if (a[k] or false) ~= (b[k] or false) then return false end
  end
  return true
end

local function typeset_str(t)
  local parts = {}
  for _, k in ipairs(ATOMS) do if t[k] then parts[#parts + 1] = k end end
  if #parts == 0 then return "<bottom>" end
  return table.concat(parts, " | ")
end

-- type of an expression under a state (var lookups consult the state)
local function expr_type(e, state)
  if e.e == "num"  then return { int = true }
  elseif e.e == "str"  then return { str = true }
  elseif e.e == "bool" then return { bool = true }
  elseif e.e == "nil"  then return { ["nil"] = true }
  elseif e.e == "var"  then
    return state[e.name] or { ["nil"] = true }   -- undeclared reads as nil
  end
  error("unknown expr " .. tostring(e.e))
end

local function copy_state(s)
  local r = {}
  for k, v in pairs(s) do
    local t = {}
    for a in pairs(v) do t[a] = true end
    r[k] = t
  end
  return r
end

local domain = {
  direction = "forward",
  init   = {},   -- entry: nothing bound yet
  bottom = {},   -- empty per-var map

  join = function(a, b)
    local r = copy_state(a)
    for var, ts in pairs(b) do
      r[var] = r[var] or {}
      for atom in pairs(ts) do r[var][atom] = true end
    end
    return r
  end,

  equal = function(a, b)
    for var in pairs(a) do if not b[var] then return false end end
    for var, ts in pairs(b) do
      if not a[var] then return false end
      if not typeset_eq(a[var], ts) then return false end
    end
    return true
  end,

  transfer = function(block, input)
    local st = copy_state(input)
    for _, s in ipairs(block.stmts) do
      if s.s == "local" or s.s == "assign" then
        st[s.name] = expr_type(s.value, st)
      end
      -- print / return: no effect on the type environment
    end
    return st
  end,
}

return { domain = domain, typeset_str = typeset_str, expr_type = expr_type }
