-- The fixed target program, as a surface AST. NOTE: there is not a single type
-- annotation anywhere -- every type below is INFERRED by the type domain.
--
--   local x = 1
--   if c then x = "s" else x = 2 end
--   print(x)
--   local y = 3        -- never used: liveness must flag it dead
--   return x

local function lit(ty, v) return { kind = "lit", ty = ty, v = v } end
local function var(name) return { kind = "var", name = name } end

return {
  { kind = "local",  name = "x", value = lit("int", 1) },
  { kind = "if",     cond = var("c"),
    body = { { kind = "assign", name = "x", value = lit("str", "s") } },
    els  = { { kind = "assign", name = "x", value = lit("int", 2) } } },
  { kind = "call",   fn = "print", args = { var("x") } },
  { kind = "local",  name = "y", value = lit("int", 3) },
  { kind = "return", value = var("x") },
}
