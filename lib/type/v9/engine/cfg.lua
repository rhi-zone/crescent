-- lib/type/v9/engine/cfg.lua
-- Lowering: a surface statement list -> a CFG of basic blocks. This is the
-- lowering target for FLOW analyses (liveness, constant propagation); the type
-- domain walks the surface directly instead. A block accumulates straight-line
-- statements; an `if` ends the current block with a `cond` and forks into a
-- then/else pair that re-join at a fresh merge block. `succs[1]` is the
-- branch-true target, `succs[2]` the branch-false target.
--
-- The CFG is a DAG for this surface (no loops yet); when `while`/`for` land, the
-- back-edge is just another entry in `succs`/`preds` and the worklist engine
-- already handles iteration — nothing in the engine changes.

--:: require "lib.type.v9.engine.defs"

local M = {}

--: (Program) -> Cfg
function M.lower(stmts)
    local blocks = {} --: { [integer]: Block }
    local byid = {} --: { [integer]: Block }
    local nextid = 0

    --: () -> Block
    local function nb()
        local b = { id = nextid, stmts = {}, cond = nil, succs = {}, preds = {} } --: Block
        nextid = nextid + 1
        blocks[#blocks + 1] = b
        byid[b.id] = b
        return b
    end

    local entry = nb()

    -- Build a straight-line / if-structured region into `cur`; return the block
    -- control falls through to afterwards.
    --: ({ [integer]: Stmt }, Block) -> Block
    local function build(list, cur)
        for i = 1, #list do
            local s = list[i]
            if s.s == "if" then
                cur.cond = s.cond
                local tb = nb()
                local fb = nb()
                local merge = nb()
                cur.succs = { tb.id, fb.id } -- [true, false]
                local te = build(s.then_, tb)
                te.succs = { merge.id }
                local fe = build(s.else_, fb)
                fe.succs = { merge.id }
                cur = merge -- subsequent stmts land in the merge block
            else
                cur.stmts[#cur.stmts + 1] = s
            end
        end
        return cur
    end

    local last = build(stmts, entry)

    -- Derive predecessors from successors.
    for i = 1, #blocks do
        local b = blocks[i]
        for k = 1, #b.succs do
            local t = byid[b.succs[k]]
            t.preds[#t.preds + 1] = b.id
        end
    end

    return { blocks = blocks, byid = byid, entry = entry.id, exit = last.id }
end

-- Collect the variable names USED (read) by an expression, into `acc`.
--: (Expr, { [string]: boolean }) -> { [string]: boolean }
function M.expr_uses(e, acc)
    if e.e == "var" then
        acc[e.name] = true
    elseif e.e == "add" then
        M.expr_uses(e.lhs, acc)
        M.expr_uses(e.rhs, acc)
    end
    return acc
end

return M
