-- main.lua — wire it together and print the required outputs.
--   run with:  bin/luajit experiments/v9-spikes/A-term-core/main.lua
-- (the script fixes package.path to its own directory, so cwd doesn't matter).

local here = (arg and arg[0] or "main.lua"):gsub("[^/]+$", "")
if here == "" then here = "./" end
package.path = here .. "?.lua;" .. package.path

local Engine    = require("engine")
local Lower     = require("lower")
local Types     = require("domain_types")
local Liveness  = require("domain_liveness")

local function line() print(string.rep("-", 60)) end

print("SPIKE A — term-core + unified worklist")
line()

local prog = Lower.target_program()

-- ---- TYPE domain (forward, flow-sensitive) -------------------------------
local tfinal = Engine.run(Types, prog)
print("[types]  type of x at return : " .. Types.show(tfinal.env["x"]))
print("[types]  program result type : " .. Types.show(tfinal.env["$return"]))
print("[types]  type of c           : " .. Types.show(tfinal.env["c"]))
if #tfinal.errors == 0 then
  print("[types]  errors              : none")
else
  for _, e in ipairs(tfinal.errors) do print("[types]  ERROR: " .. e) end
end

line()

-- ---- LIVENESS domain (backward) ------------------------------------------
local lfinal = Engine.run(Liveness, prog)
local function setstr(s) local k = {}; for n in pairs(s) do k[#k+1]=n end; table.sort(k); return table.concat(k, ", ") end
print("[live]   live at entry       : " .. (setstr(lfinal.live) ~= "" and setstr(lfinal.live) or "(none)"))
print("[live]   vars read (used)    : " .. setstr(lfinal.used))
print("[live]   never-used vars     : " .. (table.concat(Liveness.never_used(lfinal), ", ")))
print("[live]   dead stores         : " .. (table.concat(lfinal.deadstore, " ; ")))

line()

-- ---- type mismatch demonstration -----------------------------------------
local mfinal = Engine.run(Types, Lower.mismatch_program())
print("[types]  mismatch program    : " .. (#mfinal.errors > 0 and mfinal.errors[1] or "(no error?!)"))

line()
print("expected: x:int|str, return int|str, c:bool; y never-used; x=1 dead store; mismatch flagged")
