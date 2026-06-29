-- v9 spike B: the LIVENESS domain. Classic backward gen/kill dataflow.
--
-- Lattice element = a SET of live variable names (the 2-point per-variable
-- lattice live>dead, lifted to the set of vars). join = set union. Backward.
--
-- A backward block transfer computes live-IN from live-OUT:
--   live_in = (live_out \ defs) U uses
-- where the branch condition (block.cond) is a USE at the very end of the block.
--
-- Like the type domain, this references nothing about types and nothing about
-- the engine internals.

local cfg = require("cfg")

local function copy(s)
  local r = {}; for k in pairs(s) do r[k] = true end; return r
end

local function add_uses_of(expr, live)
  for v in pairs(cfg.expr_vars(expr)) do live[v] = true end
end

local domain = {
  direction = "backward",
  init   = {},   -- exit: nothing live after the program
  bottom = {},   -- empty live set

  join = function(a, b)
    local r = copy(a)
    for v in pairs(b) do r[v] = true end
    return r
  end,

  equal = function(a, b)
    for v in pairs(a) do if not b[v] then return false end end
    for v in pairs(b) do if not a[v] then return false end end
    return true
  end,

  -- input = live-OUT of the block; returns live-IN.
  transfer = function(block, input)
    local live = copy(input)
    if block.cond then add_uses_of(block.cond, live) end  -- branch test used at block end
    for i = #block.stmts, 1, -1 do
      local s = block.stmts[i]
      if s.s == "local" or s.s == "assign" then
        live[s.name] = nil                  -- def kills
        add_uses_of(s.value, live)          -- rhs uses gen
      elseif s.s == "print" then
        add_uses_of(s.arg, live)
      elseif s.s == "return" then
        add_uses_of(s.value, live)
      end
    end
    return live
  end,
}

-- Report layer. We re-walk each block from its live-OUT (= result.flow_in,
-- since this is a backward analysis) so we can inspect the live set immediately
-- after each individual definition. From that we distill two findings:
--   * dead_stores : a SPECIFIC def whose value is never read before being
--                   overwritten / falling off the end (per-def, flow-sensitive).
--   * unused_vars : a variable that is dead after EVERY one of its defs, i.e.
--                   it is never read anywhere at all (per-variable).
-- (`local x = 1` is a dead store — both if-branches overwrite x before any use —
--  yet x the variable is still used, so it is NOT an unused var. y is both.)
local function find_unused(graph, result)
  local dead_stores = {}          -- list of { var, block }
  local def_count, live_def = {}, {}
  for _, block in ipairs(graph.blocks) do
    local live = copy(result.flow_in[block.id])     -- live-out of the block
    if block.cond then add_uses_of(block.cond, live) end
    for i = #block.stmts, 1, -1 do
      local s = block.stmts[i]
      if s.s == "local" or s.s == "assign" then
        def_count[s.name] = (def_count[s.name] or 0) + 1
        -- `live` currently holds the live set immediately AFTER this stmt
        if live[s.name] then
          live_def[s.name] = true
        else
          dead_stores[#dead_stores + 1] = { var = s.name, block = block.id }
        end
        live[s.name] = nil
        add_uses_of(s.value, live)
      elseif s.s == "print" then
        add_uses_of(s.arg, live)
      elseif s.s == "return" then
        add_uses_of(s.value, live)
      end
    end
  end
  local unused_vars = {}
  for var in pairs(def_count) do
    if not live_def[var] then unused_vars[var] = true end
  end
  return { dead_stores = dead_stores, unused_vars = unused_vars }
end

return { domain = domain, find_unused = find_unused }
