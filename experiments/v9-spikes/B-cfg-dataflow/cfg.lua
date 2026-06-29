-- v9 spike B: a tiny Lua-ish surface AST and its lowering to a CFG of basic
-- blocks. Surface subset: local decl, assignment, if/else, literals, var use,
-- print call, return.
--
-- AST node forms (statements):
--   { s="local",  name, value=<expr> }
--   { s="assign", name, value=<expr> }
--   { s="if",     cond=<expr>, then_={stmt...}, else_={stmt...} }
--   { s="print",  arg=<expr> }
--   { s="return", value=<expr> }
-- Expr forms:
--   { e="num" } { e="str" } { e="bool" } { e="nil" } { e="var", name=... }
--
-- A basic block = { id, stmts={...}, cond=<expr or nil>, succs={id...}, preds={id...} }
-- A block's `cond` (if present) is the branch test evaluated AFTER its stmts;
-- succs[1] is the true target, succs[2] the false target.

local function lower(stmts)
  local blocks, byid, nextid = {}, {}, 0
  local function nb()
    local b = { id = nextid, stmts = {}, cond = nil, succs = {}, preds = {} }
    nextid = nextid + 1
    blocks[#blocks + 1] = b
    byid[b.id] = b
    return b
  end

  local entry = nb()

  -- build a straight-line / if-structured region into `cur`, returning the
  -- block that control falls through to afterwards.
  local function build(list, cur)
    for _, s in ipairs(list) do
      if s.s == "if" then
        cur.cond = s.cond
        local tb, fb, merge = nb(), nb(), nb()
        cur.succs = { tb.id, fb.id }                  -- [true, false]
        local te = build(s.then_, tb); te.succs = { merge.id }
        local fe = build(s.else_, fb); fe.succs = { merge.id }
        cur = merge                                   -- subsequent stmts land in merge
      else
        cur.stmts[#cur.stmts + 1] = s
      end
    end
    return cur
  end

  local last = build(stmts, entry)

  -- derive predecessors from successors
  for _, b in ipairs(blocks) do
    for _, sid in ipairs(b.succs) do
      local t = byid[sid]
      t.preds[#t.preds + 1] = b.id
    end
  end

  return { blocks = blocks, byid = byid, entry = entry.id, exit = last.id }
end

-- The fixed target program, as AST:
--   local x = 1
--   if c then x = "s" else x = 2 end
--   print(x)
--   local y = 3      -- never used
--   return x
local program = {
  { s = "local",  name = "x", value = { e = "num", v = 1 } },
  { s = "if",     cond = { e = "var", name = "c" },
    then_ = { { s = "assign", name = "x", value = { e = "str", v = "s" } } },
    else_ = { { s = "assign", name = "x", value = { e = "num", v = 2 } } } },
  { s = "print",  arg = { e = "var", name = "x" } },
  { s = "local",  name = "y", value = { e = "num", v = 3 } },
  { s = "return", value = { e = "var", name = "x" } },
}

-- collect variable names referenced by an expression (for liveness "use" sets)
local function expr_vars(e, acc)
  acc = acc or {}
  if e and e.e == "var" then acc[e.name] = true end
  return acc
end

return { lower = lower, program = program, expr_vars = expr_vars }
