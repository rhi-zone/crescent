-- engine.lua — the ONE unified, domain-agnostic engine.
--
-- It is an abstract-interpreter / dataflow driver over the term tree. It knows
-- ONLY the IR's control-flow shape (seq ordering, if-branch split + join, leaf
-- delegation). It contains NO type lattice, NO liveness lattice, NO mention of
-- "int" / "live" / "dead". Everything semantic is delegated to a `domain`.
--
-- Domain interface (the plug-in seam being stress-tested):
--   dom.dir            : "fwd" | "bwd"   -- traversal direction
--   dom.init()         -> state          -- entry/exit state
--   dom.copy(state)    -> state          -- so branches don't alias
--   dom.join(s1, s2)   -> state          -- merge at control-flow joins (the lattice ⊔)
--   dom.equal(s1, s2)  -> bool           -- fixpoint convergence test
--   dom.transfer[kind] : fn(node, state, recur) -> state
--                                        -- per-constructor transfer; `recur`
--                                        -- re-enters the engine on subterms.
--
-- The engine handles `seq` and `ifelse` structurally (because their control-flow
-- meaning is direction-driven and domain-independent); every other constructor is
-- pure delegation. NOTE: the value a forward domain "produces" for an expression
-- (e.g. the type of a literal) is NOT returned by the engine — domains stash it in
-- their own state (a "result register"). See NOTES for why that is the load-
-- bearing awkwardness of this paradigm.

local M = {}

local function walk(dom, node, state)
  local k = node.kind
  if k == "seq" then
    local s = node.stmts
    if dom.dir == "fwd" then
      for i = 1, #s do state = walk(dom, s[i], state) end
    else
      for i = #s, 1, -1 do state = walk(dom, s[i], state) end
    end
    return state
  elseif k == "ifelse" then
    if dom.dir == "fwd" then
      state = walk(dom, node.cond, state)
      local s1 = walk(dom, node.thenS, dom.copy(state))
      local s2 = walk(dom, node.elseS, dom.copy(state))
      return dom.join(s1, s2)
    else -- backward: branches first (from the after-state), join, then cond
      local s1 = walk(dom, node.thenS, dom.copy(state))
      local s2 = walk(dom, node.elseS, dom.copy(state))
      return walk(dom, node.cond, dom.join(s1, s2))
    end
  else
    local tf = dom.transfer[k]
    if not tf then error("domain " .. tostring(dom.name) .. " has no transfer for kind '" .. k .. "'") end
    local recur = function(child, st) return walk(dom, child, st) end
    return tf(node, state, recur)
  end
end

-- run to a fixpoint. For this loop-free surface a single pass converges, but we
-- iterate anyway to honour the "worklist/fixpoint" claim and to surface what
-- loops WOULD need (see NOTES: this whole-program re-run is NOT a real worklist).
function M.run(dom, term)
  local state = walk(dom, term, dom.init())
  local guard = 0
  while true do
    local next_state = walk(dom, term, dom.init())
    guard = guard + 1
    if dom.equal(state, next_state) or guard > 1000 then return next_state end
    state = next_state
  end
end

return M
