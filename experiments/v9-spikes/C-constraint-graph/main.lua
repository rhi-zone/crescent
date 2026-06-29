-- v9 spike C driver: lower the fixed program into ONE engine, two domains,
-- solve to fixpoint, print inferred types + liveness facts.
--
-- Run:  bin/cr experiments/v9-spikes/C-constraint-graph/main.lua

local here = (debug.getinfo(1, "S").source:gsub("^@", "")):gsub("[^/]+$", "")
if here == "" then here = "./" end
package.path = here .. "?.lua;" .. package.path

local Engine = require("engine")
local Set    = require("lattice")
local ast    = require("ast")
local types  = require("type_domain")
local live   = require("liveness_domain")

-- Both domains share the set-union lattice, so a single engine instance hosts
-- both. Cells are namespaced ("T:" vs "L:"); constraints never cross domains.
local eng = Engine.new(Set)
local tinfo = types.lower(eng, ast)
local linfo = live.lower(eng, ast)
local steps = eng:solve()

print("=== v9 spike C: constraint-graph (MLsub-flavored) ===")
print(("engine: %d cells, %d constraints, solved in %d propagation steps")
  :format((function() local n = 0; for _ in pairs(eng.cells) do n = n + 1 end; return n end)(),
          #eng.constraints, steps))

print("\n--- TYPE domain (inferred, zero annotations) ---")
print("  type of x at return : " .. Set.tostring(eng:value(tinfo.version["x"])))
print("  type of y           : " .. Set.tostring(eng:value(tinfo.version["y"])))
print("  inferred return type: " .. Set.tostring(eng:value(tinfo.result)))

print("\n--- LIVENESS domain (same engine) ---")
-- A definition is DEAD if the variable is not live on the way out of its node.
for i, node in ipairs(linfo.nodes) do
  if next(node.kill) then
    local out = eng:value(linfo.outC(i))
    for name in pairs(node.kill) do
      local status = out[name] and "LIVE" or "DEAD/unused"
      print(("  def of %-3s at [%s] : %s"):format(name, node.label, status))
    end
  end
end
-- A variable is USED if it ever appears in some in-set.
local usedAnywhere = {}
for i in ipairs(linfo.nodes) do
  for name in pairs(eng:value(linfo.inC(i))) do usedAnywhere[name] = true end
end
print("  variables ever used : " .. Set.tostring(usedAnywhere, ", "))
print("  is `c` used?         : " .. tostring(usedAnywhere["c"] == true))
print("  is `y` used?         : " .. tostring(usedAnywhere["y"] == true))

print("\n(no type annotations appear in ast.lua; types above are inferred.)")
