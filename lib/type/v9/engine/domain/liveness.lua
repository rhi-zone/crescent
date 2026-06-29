-- lib/type/v9/engine/domain/liveness.lua
-- DOMAIN 1: live-variable analysis. A backward, 2-point (live/dead) per-variable
-- lattice lifted to the set of live names; transfer is classic gen/kill. It runs
-- through the SAME engine as every other domain, via the dataflow adapter with
-- `direction = "backward"` (the predecessors/successors swap).
--
-- Cell orientation (dataflow names cells relative to the analysis direction):
--   out_cell(b) = live-IN of b   (transfer output, the program-before value)
--   in_cell(b)  = live-OUT of b  (the value entering along the backward flow)
--
-- The engine shuttles values as opaque `unknown`; this domain NARROWS them to
-- its concrete `LiveSet` at its boundary via the `as_live` type predicate (no
-- force casts). It imports only domain-agnostic substrate (defs/cfg/dataflow/
-- engine) and references NOTHING from the type or constant domains.

--:: require "lib.type.v9.engine.defs"

local cfg = require("lib.type.v9.engine.cfg")
local dataflow = require("lib.type.v9.engine.dataflow")
local engine = require("lib.type.v9.engine.engine")

-- Membership = presence-with-`true`; a KILL marks `false` (treated as absent),
-- so the set never needs nil-deletion of a non-nil field.
--:: LiveSet = { [string]: boolean }

local M = {}

-- Narrows an opaque cell value to a LiveSet at the domain boundary.
--: (x: unknown) -> x is LiveSet
local function as_live(x) return type(x) == "table" end

--: (LiveSet) -> LiveSet
local function copy(s)
    local r = {} --: LiveSet
    for k, v in pairs(s) do if v then r[k] = true end end
    return r
end

-- The set-union lattice over live-variable names (opaque-facing).
--: () -> unknown
local function bottom()
    local e = {} --: LiveSet
    return e
end
--: (unknown, unknown) -> unknown
local function join(a, b)
    if as_live(a) and as_live(b) then
        local r = copy(a)
        for k, v in pairs(b) do if v then r[k] = true end end
        return r
    end
    return bottom()
end
--: (unknown, unknown) -> boolean
local function equal(a, b)
    if as_live(a) and as_live(b) then
        for k, v in pairs(a) do if v and not b[k] then return false end end
        for k, v in pairs(b) do if v and not a[k] then return false end end
        return true
    end
    return false
end

local lattice = { bottom = bottom, join = join, equal = equal } --: Lattice

-- Backward block transfer: live_in = (live_out \ defs) U uses, walking the
-- block's statements bottom-to-top; the branch `cond` (if any) is a use at the
-- block's end.
--: (Block, unknown) -> unknown
local function transfer(block, live_out)
    if not as_live(live_out) then return bottom() end
    local live = copy(live_out)
    local cond = block.cond
    if cond ~= nil then cfg.expr_uses(cond, live) end
    for i = #block.stmts, 1, -1 do
        local s = block.stmts[i]
        if s.s == "local" or s.s == "assign" then
            live[s.name] = false -- def kills (false = absent)
            cfg.expr_uses(s.value, live) -- rhs uses gen
        elseif s.s == "call" then
            for k = 1, #s.args do cfg.expr_uses(s.args[k], live) end
        elseif s.s == "return" then
            cfg.expr_uses(s.value, live)
        end
    end
    return live
end

-- The FlowDomain this analysis plugs into the engine as.
local domain = { lattice = lattice, direction = "backward", boundary = bottom(), transfer = transfer } --: FlowDomain
M.domain = domain

-- Collect every variable NAME defined (local/assign) anywhere in a program.
--: ({ [integer]: Stmt }, { [string]: boolean }) -> { [string]: boolean }
local function collect_defs(stmts, acc)
    for i = 1, #stmts do
        local s = stmts[i]
        if s.s == "local" or s.s == "assign" then
            acc[s.name] = true
        elseif s.s == "if" then
            collect_defs(s.then_, acc)
            collect_defs(s.else_, acc)
        end
    end
    return acc
end

-- Fold a (possibly nil / opaque) cell value's live names into `acc`.
--: (unknown, LiveSet) -> nil
local function add_live(v, acc)
    if as_live(v) then
        for k, present in pairs(v) do if present then acc[k] = true end end
    end
    return nil
end

-- Run liveness end-to-end and distill the facts the tests assert on:
--   live_at_entry : variables live entering the program (free vars like `cond`).
--   unused        : variables defined but never read anywhere.
--:: LivenessFacts = { live_at_entry: LiveSet, unused: LiveSet, steps: integer }
--: (Program) -> (LivenessFacts | nil, string | nil)
function M.analyze(program)
    local graph = cfg.lower(program)
    local g = dataflow.to_graph(graph, domain)
    local sol, err = engine.solve(g)
    if sol == nil then return nil, err end

    -- live-IN of the entry block = out_cell(entry).
    local live_at_entry = {} --: LiveSet
    add_live(sol.values[dataflow.out_cell(graph.entry)], live_at_entry)

    -- A variable is USED iff it appears in some live set anywhere.
    local used = {} --: LiveSet
    for i = 1, #graph.blocks do
        local b = graph.blocks[i]
        add_live(sol.values[dataflow.in_cell(b.id)], used)
        add_live(sol.values[dataflow.out_cell(b.id)], used)
    end

    local defs = collect_defs(program, {})
    local unused = {} --: LiveSet
    for name in pairs(defs) do
        if not used[name] then unused[name] = true end
    end

    return { live_at_entry = live_at_entry, unused = unused, steps = sol.steps }, nil
end

return M
