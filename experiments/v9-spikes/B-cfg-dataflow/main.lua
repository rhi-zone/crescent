-- v9 spike B: driver. Lowers the fixed program to a CFG, runs the ONE engine
-- twice — once with the forward type domain, once with the backward liveness
-- domain — and prints the required outputs.
--
-- Run:  bin/luajit experiments/v9-spikes/B-cfg-dataflow/main.lua
--   (or from the dir:  ../../../bin/luajit main.lua)

-- make sibling modules require-able regardless of cwd
local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/?.lua;" .. package.path

local engine    = require("engine")
local cfg       = require("cfg")
local type_dom  = require("domain_type")
local live_dom  = require("domain_liveness")

local graph = cfg.lower(cfg.program)

print("=== CFG ===")
for _, b in ipairs(graph.blocks) do
  local kinds = {}
  for _, s in ipairs(b.stmts) do kinds[#kinds + 1] = s.s end
  print(string.format("  B%d  stmts=[%s]%s  -> {%s}",
    b.id, table.concat(kinds, ", "),
    b.cond and "  cond=if" or "",
    table.concat(b.succs, ", ")))
end
print(string.format("  entry=B%d exit=B%d", graph.entry, graph.exit))

-- ---- forward type analysis (abstract interpretation) ----
print("\n=== TYPE domain (forward abstract interpretation) ===")
local tr = engine.solve(graph, type_dom.domain)
-- type of x at `return` = x in the env entering the exit block (the post-if merge)
local exit_env = tr.flow_in[graph.exit]
print(string.format("  fixpoint reached in %d block-visits", tr.steps))
print("  type of x at return : " .. type_dom.typeset_str(exit_env.x or {}))
print("  overall result type : " .. type_dom.typeset_str(exit_env.x or {}))
print("  (this union is the lattice join of B1's {str} and B2's {int} at merge block B"
  .. graph.exit .. ")")

-- ---- backward liveness analysis ----
print("\n=== LIVENESS domain (backward dataflow) ===")
local lr = engine.solve(graph, live_dom.domain)
print(string.format("  fixpoint reached in %d block-visits", lr.steps))
local live_at_entry = lr.flow_out[graph.entry]   -- backward: flow_out = live-IN
local function live_str(set)
  local ks = {}; for k in pairs(set) do ks[#ks + 1] = k end
  table.sort(ks); return "{" .. table.concat(ks, ", ") .. "}"
end
print("  live-in at entry     : " .. live_str(live_at_entry))
print("  c used (free var live at entry)? " .. tostring(live_at_entry.c == true))
local rep = live_dom.find_unused(graph, lr)
local us = {}; for k in pairs(rep.unused_vars) do us[#us + 1] = k end; table.sort(us)
print("  unused variables      : {" .. table.concat(us, ", ") .. "}")
print("  x live (used)?        : " .. tostring(rep.unused_vars.x ~= true))
print("  y dead (unused)?      : " .. tostring(rep.unused_vars.y == true))
print("  dead stores (bonus, per-def, flow-sensitive):")
for _, d in ipairs(rep.dead_stores) do
  print(string.format("    - def of '%s' in B%d is never read before overwrite/end", d.var, d.block))
end
