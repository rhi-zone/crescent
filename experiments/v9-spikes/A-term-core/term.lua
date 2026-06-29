-- term.lua — the IR core for spike A.
--
-- Modelled on the proof-dev's `tm` (proof/typing.v:109): a small term language,
-- constructors only, no domain knowledge. The proof core is EXPRESSION-oriented
-- (tlet nests its body, tif is an expression whose type is a union). Our Lua-ish
-- surface is STATEMENT-oriented (mutation, sequencing, return), so this core adds
-- `seq`, `localdecl`, `assign`, `ret` alongside the proof-faithful `lit/var/if`.
-- That gap is itself a finding (see NOTES) — the proof's let-core does not have a
-- native notion of statement-level mutation; we had to graft it on.

local M = {}

-- expression nodes
function M.lit(tag, v)        return { kind = "lit", tag = tag, v = v } end   -- tag in {int,str,bool,nil}
function M.var(name)          return { kind = "var", name = name } end
function M.call(fn, args)     return { kind = "call", fn = fn, args = args } end

-- statement nodes
function M.localdecl(name, expr, annot)
  return { kind = "localdecl", name = name, expr = expr, annot = annot }
end
function M.assign(name, expr) return { kind = "assign", name = name, expr = expr } end
function M.ifelse(cond, thenS, elseS)
  return { kind = "ifelse", cond = cond, thenS = thenS, elseS = elseS }
end
function M.seq(stmts)         return { kind = "seq", stmts = stmts } end
function M.ret(expr)          return { kind = "ret", expr = expr } end

return M
