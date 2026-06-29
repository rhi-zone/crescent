-- lib/type/v9/engine/engine.lua
-- THE engine: a domain-agnostic monotone worklist fixpoint over lattice cells.
--
-- It is parameterized ENTIRELY by a `Graph` = (lattice, rules). It contains ZERO
-- domain vocabulary: no atom, no "live"/"dead", no type, no direction. It knows
-- only cells (OPAQUE `unknown` values), a lattice (bottom/join/equal), and rules
-- (reads/writes/apply). Type inference, liveness, and constant-propagation are
-- all just different `Graph`s fed to this one `solve`.
--
-- The loop: seed the worklist with every rule. Pop a rule, run its `apply`,
-- JOIN each proposed value into its target cell, and — if a cell changed —
-- re-schedule every rule that READS that cell. Monotone join + an ascending
-- chain condition on the lattice guarantee termination. A step budget turns a
-- non-monotone domain (a bug) into an HONEST `(nil, errmsg)` rather than a hang.
--
-- The engine is a PURE FUNCTION of its graph: all mutation (`cells`, `work`) is
-- solve-local scratch, never a cross-call coordination channel. No singleton,
-- no message bus, no stateful solver instance.

--:: require "lib.type.v9.engine.defs"

local M = {}

-- Rule + Graph constructors (convenience; rules/graphs are plain data).
--: ({ [integer]: string }, { [integer]: string }, ((string) -> unknown) -> { [string]: unknown }) -> Rule
function M.rule(reads, writes, apply)
    return { reads = reads, writes = writes, apply = apply }
end

--: (Lattice, { [integer]: Rule }) -> Graph
function M.graph(lattice, rules)
    return { lattice = lattice, rules = rules }
end

-- Default fixpoint budget: generous multiple of the rule count. Exceeding it
-- means the lattice is not a terminating ascending chain (a domain bug), which
-- we surface as data, never as an infinite loop.
local BUDGET_FACTOR = 1000

--: (Graph) -> (Solution | nil, string | nil)
function M.solve(graph)
    local lattice = graph.lattice
    local rules = graph.rules

    -- cell-id -> current lattice value; cell-id -> list of rule indices reading it.
    local cells = {} --: { [string]: unknown }
    local readers = {} --: { [string]: { [integer]: integer } }

    --: (string) -> nil
    local function ensure(id)
        if cells[id] == nil then cells[id] = lattice.bottom() end
        return nil
    end

    for i = 1, #rules do
        local r = rules[i]
        for j = 1, #r.reads do
            local c = r.reads[j]
            ensure(c)
            local rs = readers[c] or {}
            rs[#rs + 1] = i
            readers[c] = rs
        end
        for j = 1, #r.writes do
            ensure(r.writes[j])
        end
    end

    -- worklist of rule indices; seed with all rules. `queued` uses false for
    -- "not queued" (never nil) so its element type stays a plain boolean.
    local work = {} --: { [integer]: integer }
    local queued = {} --: { [integer]: boolean }
    for i = 1, #rules do
        work[i] = i
        queued[i] = true
    end

    local head = 0
    local steps = 0
    local budget = #rules * BUDGET_FACTOR + 1

    while head < #work do
        head = head + 1
        local idx = work[head]
        queued[idx] = false
        steps = steps + 1
        if steps > budget then
            return nil, "engine: fixpoint budget exceeded (non-monotone lattice or non-terminating transfer)"
        end

        local rule = rules[idx]
        local proposed = rule.apply(function(id)
            local v = cells[id]
            if v == nil then return lattice.bottom() end
            return v
        end)

        for cellid, val in pairs(proposed) do
            local old = cells[cellid]
            if old == nil then old = lattice.bottom() end
            local merged = lattice.join(old, val)
            if not lattice.equal(old, merged) then
                cells[cellid] = merged
                local rs = readers[cellid]
                if rs ~= nil then
                    for k = 1, #rs do
                        local ri = rs[k]
                        if not queued[ri] then
                            work[#work + 1] = ri
                            queued[ri] = true
                        end
                    end
                end
            end
        end
    end

    return { values = cells, steps = steps }, nil
end

return M
