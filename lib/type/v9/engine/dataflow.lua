-- lib/type/v9/engine/dataflow.lua
-- Flow-analysis adapter: lowers a `FlowDomain` over a `Cfg` into a plain `Graph`
-- the engine can solve. This is the ONLY place the forward/backward distinction
-- exists in the whole system, and it is a single predecessors-vs-successors SWAP
-- (per spike B), never a special-case branch in the engine.
--
-- For each block it emits:
--   out[b] = transfer(b, in[b])                  (the block transfer)
--   in[b] <- out[s]   for every SOURCE s         (one proposal per source)
--   in[boundary] <- boundary value               (the boundary seed)
-- where SOURCES = preds (forward) or succs (backward). The merge needs no fold:
-- the engine's monotone join over the per-source proposals IS the least-upper-
-- bound. The boundary value seeds the entry block (forward) / exit block
-- (backward).
--
-- This module names CFG vocabulary (block / preds / succs / in / out) but ZERO
-- analysis vocabulary: no type, no "live", no constant. Both flow domains plug
-- through it unchanged.

--:: require "lib.type.v9.engine.defs"

local M = {}

--: (integer) -> string
local function in_cell(id) return "in:" .. id end
--: (integer) -> string
local function out_cell(id) return "out:" .. id end
M.in_cell = in_cell
M.out_cell = out_cell

-- A one-element cell-id list, typed as a general array so rules with differently
-- shaped read/write lists share a single element type.
--: (string) -> { [integer]: string }
local function list1(a)
    local t = {} --: { [integer]: string }
    t[1] = a
    return t
end

--: (Cfg, FlowDomain) -> Graph
function M.to_graph(cfg, dom)
    local forward = dom.direction == "forward"
    local boundary_id = forward and cfg.entry or cfg.exit

    local rules = {} --: { [integer]: Rule }
    local none = {} --: { [integer]: string }

    for bi = 1, #cfg.blocks do
        local block = cfg.blocks[bi]
        local incell = in_cell(block.id)
        local outcell = out_cell(block.id)
        -- THE direction swap: who feeds this block's IN value.
        local sources = forward and block.preds or block.succs

        -- transfer rule: out[b] = transfer(b, in[b])
        rules[#rules + 1] = { reads = list1(incell), writes = list1(outcell), apply = function(get)
            return { [outcell] = dom.transfer(block, get(incell)) }
        end }

        -- boundary seed: in[boundary] receives the boundary value.
        if block.id == boundary_id then
            rules[#rules + 1] = { reads = none, writes = list1(incell), apply = function(get)
                return { [incell] = dom.boundary }
            end }
        end

        -- one proposal per source: in[b] receives out[s]; the engine joins them.
        for k = 1, #sources do
            local outk = out_cell(sources[k])
            rules[#rules + 1] = { reads = list1(outk), writes = list1(incell), apply = function(get)
                return { [incell] = get(outk) }
            end }
        end
    end

    return { lattice = dom.lattice, rules = rules }
end

return M
