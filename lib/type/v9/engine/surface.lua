-- lib/type/v9/engine/surface.lua
-- The surface AST — the pinned cell/op vocabulary (fork 1), with constructors
-- and ONE shared sample program every domain runs on. This is the lowering
-- INPUT: the type domain walks it directly (SSA), the flow domains lower it to a
-- CFG first (cfg.lua). The vocabulary grows toward full Lua; new formers are a
-- local addition here plus a transfer arm in each interested domain.

--:: require "lib.type.v9.engine.defs"

local M = {}

--: (number) -> Expr
function M.int(value) return { e = "int", value = value } end
--: (string) -> Expr
function M.str(value) return { e = "str", value = value } end
--: (boolean) -> Expr
function M.bool(value) return { e = "bool", value = value } end
--: () -> Expr
function M.nil_() return { e = "nil" } end
--: (string) -> Expr
function M.var(name) return { e = "var", name = name } end
--: (Expr, Expr) -> Expr
function M.add(lhs, rhs) return { e = "add", lhs = lhs, rhs = rhs } end

--: (string, Expr) -> Stmt
function M.local_(name, value) return { s = "local", name = name, value = value } end
--: (string, Expr) -> Stmt
function M.assign(name, value) return { s = "assign", name = name, value = value } end
--: (Expr, { [integer]: Stmt }, { [integer]: Stmt }) -> Stmt
function M.if_(cond, then_, else_) return { s = "if", cond = cond, then_ = then_, else_ = else_ } end
--: (string, { [integer]: Expr }) -> Stmt
function M.call(fn, args) return { s = "call", fn = fn, args = args } end
--: (Expr) -> Stmt
function M.return_(value) return { s = "return", value = value } end

-- The ONE shared program (no type annotations — inference is genuine):
--
--   local x = 1
--   local y = x + 1            -- const-folds to 2 ; type int
--   if cond then
--     x = "s"                  -- type str ; const ⊤ (non-numeric)
--   else
--     x = 2                    -- type int ; const Num(2)
--   end
--   print(x)                   -- a call; uses x
--   local dead = 9             -- never read
--   return x                   -- type int | str ; const ⊤
--
-- Outcomes exercised: union inference (x : int|str with zero annotations), an
-- unused variable (dead) for liveness, and a non-set-union lattice with a real ⊤
-- plus constant folding (y = 2) for constant propagation.
--: () -> Program
function M.program()
    return {
        M.local_("x", M.int(1)),
        M.local_("y", M.add(M.var("x"), M.int(1))),
        M.if_(M.var("cond"),
            { M.assign("x", M.str("s")) },
            { M.assign("x", M.int(2)) }),
        M.call("print", { M.var("x") }),
        M.local_("dead", M.int(9)),
        M.return_(M.var("x")),
    }
end

return M
