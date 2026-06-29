-- domain_types.lua — a minimal FLOW-SENSITIVE type domain.
--
-- Lattice: atoms {int, str, bool, nil}, plus finite unions of atoms. `sub` is the
-- subtype relation (atom ≤ itself, atom ≤ any union containing it, union ≤ union
-- by subset). `join` (the lattice ⊔ used at control-flow merges) is set union of
-- atoms — this is exactly what makes the analysis flow-sensitive: an `if` that
-- assigns different atoms in its branches yields their union AFTER the if, with
-- ZERO special-casing in the engine. The engine just calls `dom.join` on the two
-- branch states; the union falls out.
--
-- This domain references NOTHING in the liveness domain. It is forward.

local M = {}
M.name = "types"
M.dir = "fwd"

-- ---- type representation -------------------------------------------------
-- a type is { set = { int=true, str=true, ... } }  (a non-empty atom set)
local ATOMS = { int = true, str = true, bool = true, nil_ = true }

local function atom(name) return { set = { [name] = true } } end
local function show(t)
  if t == nil then return "<undef>" end
  local ks = {}
  for a in pairs(t.set) do ks[#ks + 1] = (a == "nil_") and "nil" or a end
  table.sort(ks)
  return table.concat(ks, " | ")
end
local function tunion(a, b)
  local s = {}
  for k in pairs(a.set) do s[k] = true end
  for k in pairs(b.set) do s[k] = true end
  return { set = s }
end
-- sub: is a ≤ b ? (every atom of a is in b)
local function sub(a, b)
  for k in pairs(a.set) do if not b.set[k] then return false end end
  return true
end
M.atom, M.show, M.sub = atom, show, sub

-- map a literal tag onto an atom
local function tag_atom(tag) return atom(tag == "nil" and "nil_" or tag) end

-- ---- state ---------------------------------------------------------------
-- state = { env = {name -> type}, result = type|nil, errors = {string,...} }
-- `result` is the "result register": the type of the most-recently-walked
-- expression. The engine cannot return it (it is type-specific), so it rides in
-- the state. This is the load-bearing awkwardness of the term-core paradigm.

function M.init()
  -- `c` is a free external boolean; seed it so `if c` typechecks.
  return { env = { c = atom("bool") }, result = nil, errors = {} }
end

local function copy_env(e) local n = {}; for k, v in pairs(e) do n[k] = v end; return n end
function M.copy(s)
  return { env = copy_env(s.env), result = s.result, errors = s.errors } -- errors shared (append-only log)
end

function M.join(s1, s2)
  local env = {}
  local names = {}
  for k in pairs(s1.env) do names[k] = true end
  for k in pairs(s2.env) do names[k] = true end
  for k in pairs(names) do
    local a, b = s1.env[k], s2.env[k]
    if a and b then env[k] = tunion(a, b)
    else env[k] = a or b end          -- declared on only one path: keep it
  end
  return { env = env, result = nil, errors = s1.errors }
end

function M.equal(s1, s2)
  for k, v in pairs(s1.env) do
    local w = s2.env[k]
    if not w or not (sub(v, w) and sub(w, v)) then return false end
  end
  for k in pairs(s2.env) do if not s1.env[k] then return false end end
  return true
end

-- ---- transfer ------------------------------------------------------------
M.transfer = {}

function M.transfer.lit(node, st)
  st.result = tag_atom(node.tag)
  return st
end

function M.transfer.var(node, st)
  st.result = st.env[node.name]   -- nil if undeclared; show() prints <undef>
  return st
end

function M.transfer.localdecl(node, st, recur)
  st = recur(node.expr, st)
  local got = st.result
  if node.annot then
    local want = atom(node.annot)
    if not sub(got, want) then
      st.errors[#st.errors + 1] =
        ("type mismatch: local %s : %s = <%s>"):format(node.name, show(want), show(got))
    end
    st.env[node.name] = want
  else
    st.env[node.name] = got        -- INFERENCE: no annotation needed
  end
  return st
end

function M.transfer.assign(node, st, recur)
  st = recur(node.expr, st)
  st.env[node.name] = st.result    -- flow-sensitive: rebinds the var's current type
  return st
end

function M.transfer.call(node, st, recur)
  for _, a in ipairs(node.args) do st = recur(a, st) end
  st.result = atom("nil_")          -- print returns nil
  return st
end

function M.transfer.ret(node, st, recur)
  st = recur(node.expr, st)
  st.env["$return"] = st.result     -- stash the program's return type in the env
  return st
end

return M
