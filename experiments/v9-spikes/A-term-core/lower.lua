-- lower.lua — tiny lowering from a fixed Lua-ish surface subset into the term core.
--
-- The surface subset: locals, reassignment, if/else, literals, variable use, a
-- `print` call, and `return`. We do NOT parse text (out of scope for a spike); we
-- hand-build the surface AST and lower it. The lowering is deliberately trivial —
-- which is the point: it shows where the surface/core impedance is (statement
-- block -> seq; `local` -> localdecl; `=` -> assign).

local T = require("term")

local M = {}

-- The fixed target program, as a surface AST:
--
--   local x = 1
--   if c then x = "s" else x = 2 end
--   print(x)
--   local y = 3        -- y never used
--   return x
--
-- `c` is a free (undeclared) variable — an external boolean, modelling input.
function M.target_program()
  return T.seq({
    T.localdecl("x", T.lit("int", 1)),
    T.ifelse(
      T.var("c"),
      T.seq({ T.assign("x", T.lit("str", "s")) }),
      T.seq({ T.assign("x", T.lit("int", 2)) })
    ),
    T.call("print", { T.var("x") }),
    T.localdecl("y", T.lit("int", 3)),
    T.ret(T.var("x")),
  })
end

-- A second program purely to exercise the type domain's mismatch flag:
--   local z : int = "s"   -- annotated int, assigned str  => mismatch
function M.mismatch_program()
  return T.seq({
    T.localdecl("z", T.lit("str", "s"), "int"),
    T.ret(T.var("z")),
  })
end

return M
