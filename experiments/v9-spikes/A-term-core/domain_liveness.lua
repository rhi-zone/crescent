-- domain_liveness.lua — a minimal BACKWARD live-variable domain.
--
-- Chosen to be maximally UNLIKE the type domain: 2-point lattice (live/dead) per
-- variable, BACKWARD direction, produces no "value", detects dead stores and
-- never-used variables. If the same engine + same domain interface expresses both
-- this and flow-sensitive typing, the interface is genuinely general.
--
-- Lattice per variable: dead ⊑ live. State = the set of currently-live variables.
-- `join` at a control-flow merge is set UNION (a var live on EITHER path is live).
--
-- This domain references NOTHING in the type domain.

local M = {}
M.name = "liveness"
M.dir = "bwd"

-- state = {
--   live      = { name -> true },      -- vars live at the current program point
--   used      = { name -> true },      -- vars read ANYWHERE (for never-used report)
--   declared  = { name -> true },      -- vars introduced by localdecl
--   deadstore = { "name@desc", ... },  -- def sites whose value is overwritten unread
-- }

function M.init()
  return { live = {}, used = {}, declared = {}, deadstore = {} }
end

local function copyset(s) local n = {}; for k in pairs(s) do n[k] = true end; return n end
function M.copy(s)
  return {
    live = copyset(s.live), used = s.used, declared = s.declared, deadstore = s.deadstore,
  } -- used/declared/deadstore are append-only logs, shared across branches
end

function M.join(s1, s2)
  local live = copyset(s1.live)
  for k in pairs(s2.live) do live[k] = true end
  return { live = live, used = s1.used, declared = s1.declared, deadstore = s1.deadstore }
end

function M.equal(s1, s2)
  for k in pairs(s1.live) do if not s2.live[k] then return false end end
  for k in pairs(s2.live) do if not s1.live[k] then return false end end
  return true
end

M.transfer = {}

function M.transfer.lit(_, st) return st end

function M.transfer.var(node, st)
  st.live[node.name] = true     -- a use makes the var live (backward)
  st.used[node.name] = true
  return st
end

-- a definition: if the var is not live in the after-state, its value is dead
-- (overwritten / never read). Then it is killed, then the rhs's uses are added.
local function def(node, st, recur, isdecl)
  if isdecl then st.declared[node.name] = true end
  if not st.live[node.name] then
    st.deadstore[#st.deadstore + 1] = node.name .. " (= " .. M.descr(node.expr) .. ")"
  end
  st.live[node.name] = nil      -- kill
  return recur(node.expr, st)   -- uses in the rhs become live
end

function M.transfer.localdecl(node, st, recur) return def(node, st, recur, true) end
function M.transfer.assign(node, st, recur)     return def(node, st, recur, false) end

function M.transfer.call(node, st, recur)
  for i = #node.args, 1, -1 do st = recur(node.args[i], st) end
  return st
end

function M.transfer.ret(node, st, recur) return recur(node.expr, st) end

-- tiny pretty-printer for a def's rhs (for dead-store messages)
function M.descr(e)
  if e.kind == "lit" then return tostring(e.v) end
  if e.kind == "var" then return e.name end
  return e.kind
end

-- report: vars declared but never read anywhere
function M.never_used(final)
  local out = {}
  for name in pairs(final.declared) do
    if not final.used[name] then out[#out + 1] = name end
  end
  table.sort(out)
  return out
end

return M
