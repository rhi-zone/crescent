-- lib/type/v9/lower.lua
-- TOTAL lowering: decoded full-Lua AST -> the v9 checkable representation
-- (an engine constraint Graph + post-solve Obligations + structural Diags).
--
-- TOTALITY IS THE CONTRACT. Every one of the parser's 30 node kinds is
-- recognized and routed — either into the supported v0 discipline or into an
-- honest structured `unsupported:<construct>` diagnostic with line/col. No
-- crashes on any construct, no silent passes. The unsupported set IS the
-- explicit dynamism/coverage boundary; shrinking it is the roadmap
-- ("total on semantics, bounded on dynamism").
--
-- UNIFORMITY: one constraint shape. Each construct contributes ONE lowering
-- rule that emits engine `Rule`s (seed / flow / truthy-falsy filter) and/or
-- one `Obligation` (a post-solve upper-bound check). There is NO bespoke
-- solver logic per construct — the engine stays domain-blind, and the only
-- flow operations are the lattice's truthy/falsy:
--
--   if x then …      then-branch x : truthy(x), else-branch x : falsy(x)
--   a and b          : falsy(a) | type(b)   } derived from the SAME two ops,
--   a or  b          : truthy(a) | type(b)  } never a hardcoded case
--
-- Flow-sensitivity is SSA-style versioning: assignments rebind a variable's
-- cell; `if` merges make phi cells that receive each branch version as a
-- separate proposal — the engine's monotone join IS the union at the merge.
--
-- Unsupported statements with bodies (loops, in v0) are not silently
-- skipped: the subtree is scanned so (a) reads keep outer locals from false
-- "unused" reports and (b) assigned outer locals are HAVOCED to unknown —
-- the supported discipline stays sound around the boundary.
--
-- Diag severities are stamped by the POLICY in check.lua, not here — the
-- power dial is the owner's, and it lives in one named place.

if not package.path:find("?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

--:: require "lib.type.v9.engine.defs"

local defs = require("lib.type.static.defs")
local engine = require("lib.type.v9.engine.engine")
local lattice = require("lib.type.v9.lattice")
local frontend = require("lib.type.v9.frontend")

--:: Ast = { tag: integer, line: integer, col: integer, ... }
--:: Diag = { code: string, severity: string, message: string, line: integer, col: integer }
--:: Obligation = { cell: string, allow: { [string]: boolean }, code: string, what: string, line: integer, col: integer }
--:: LowerResult = { graph: Graph, obligations: { [integer]: Obligation }, diags: { [integer]: Diag }, vars: { [string]: string } }
--:: Decl = { id: string, name: string, line: integer, col: integer, read: boolean, cell: string }
--:: Scope = { map: { [string]: Decl }, order: { [integer]: Decl } }

local M = {}

--: (x: unknown) -> x is Ast
local function is_node(x) return type(x) == "table" end

--: (x: unknown) -> x is { [integer]: Ast }
local function is_list(x) return type(x) == "table" end

--: (x: unknown) -> x is { [string]: unknown }
local function is_tbl(x) return type(x) == "table" end

-- Operand upper bounds (shared AtomSet constants; never mutated).
local NUM = lattice.single("number")
local NUMSTR = lattice.of({ "number", "string" })
local LENABLE = lattice.of({ "string", "table" })
local FUNC = lattice.single("function")

-- The binary-operator discipline as DATA: op -> (operand bound | nil,
-- result atom | nil, derive | nil). `derive` marks the two operators whose
-- result is DERIVED from the lattice's truthy/falsy (and/or) instead of a
-- fixed result atom. An unrecognized op returns (nil, nil, nil).
--: (string) -> ({ [string]: boolean } | nil, string | nil, string | nil)
local function binop_rule(op)
    if op == "+" or op == "-" or op == "*" or op == "/" or op == "%" or op == "^" then
        return NUM, "number", nil
    elseif op == ".." then
        return NUMSTR, "string", nil
    elseif op == "<" or op == "<=" or op == ">" or op == ">=" then
        return NUMSTR, "boolean", nil
    elseif op == "==" or op == "~=" then
        return nil, "boolean", nil
    elseif op == "and" then
        return nil, nil, "falsy"
    elseif op == "or" then
        return nil, nil, "truthy"
    end
    return nil, nil, nil
end

-- The unary-operator discipline: op -> (operand bound | nil, result atom |
-- nil). Unrecognized op returns (nil, nil).
--: (string) -> ({ [string]: boolean } | nil, string | nil)
local function unop_rule(op)
    if op == "-" then
        return NUM, "number"
    elseif op == "not" then
        return nil, "boolean"
    elseif op == "#" then
        return LENABLE, "number"
    end
    return nil, nil
end

-- Lower a decoded chunk. Returns the constraint graph (engine-solvable), the
-- obligations to evaluate against the solution, and the structural
-- diagnostics gathered during the walk. Never throws on any construct.
--: (Ast) -> LowerResult
function M.lower(chunk)
    local rules = {} --: { [integer]: Rule }
    local obligations = {} --: { [integer]: Obligation }
    local diags = {} --: { [integer]: Diag }
    local counter = 0

    -- Lexical scopes (depth-indexed, never nil'd) + SSA versions: decl.cell
    -- is the CURRENT cell of the variable; branches snapshot/restore it.
    local scopes = {} --: { [integer]: Scope }
    local depth = 0
    -- Return-target cells, one per enclosing function (innermost = top).
    local ret_cells = {} --: { [integer]: string }
    local ret_depth = 0

    --: (string) -> string
    local function fresh(tag)
        counter = counter + 1
        return "c:" .. tag .. "#" .. counter
    end

    --: (string, { [string]: boolean }) -> nil
    local function seed(cell, atoms)
        rules[#rules + 1] = engine.rule({}, { cell }, function(get)
            return { [cell] = atoms }
        end)
        return nil
    end

    --: (string, string) -> nil
    local function flow(src, dst)
        rules[#rules + 1] = engine.rule({ src }, { dst }, function(get)
            return { [dst] = get(src) }
        end)
        return nil
    end

    -- The ONE narrowing transfer: dst receives truthy(src) or falsy(src).
    --: (string, string, string) -> nil
    local function filter_flow(src, dst, mode)
        if mode == "truthy" then
            rules[#rules + 1] = engine.rule({ src }, { dst }, function(get)
                return { [dst] = lattice.truthy(get(src)) }
            end)
        else
            rules[#rules + 1] = engine.rule({ src }, { dst }, function(get)
                return { [dst] = lattice.falsy(get(src)) }
            end)
        end
        return nil
    end

    --: (string) -> string
    local function unknown_cell(tag)
        local c = fresh(tag)
        seed(c, lattice.single("unknown"))
        return c
    end

    --: (string) -> string
    local function atom_cell(atom)
        local c = fresh(atom)
        seed(c, lattice.single(atom))
        return c
    end

    --: (code: string, line: integer, col: integer, message: string) -> nil
    local function diag(code, line, col, message)
        -- severity is stamped by the policy in check.lua.
        diags[#diags + 1] = { code = code, severity = "warn", line = line, col = col, message = message }
        return nil
    end

    --: (Ast, string) -> nil
    local function unsupported(n, what)
        diag("unsupported:" .. what, n.line, n.col,
            "`" .. what .. "` is outside the v0 checked subset (honest boundary; not checked)")
        return nil
    end

    --: (Ast, string) -> nil
    local function internal(n, msg)
        diag("internal", n.line, n.col, "lowering invariant violated: " .. msg)
        return nil
    end

    --: (cell: string, allow: { [string]: boolean }, code: string, what: string, line: integer, col: integer) -> nil
    local function obligate(cell, allow, code, what, line, col)
        obligations[#obligations + 1] =
            { cell = cell, allow = allow, code = code, what = what, line = line, col = col }
        return nil
    end

    -- ── scopes / versions ──────────────────────────────────────────────────

    --: () -> nil
    local function push_scope()
        depth = depth + 1
        local s = { map = {}, order = {} } --: Scope
        scopes[depth] = s
        return nil
    end

    --: () -> nil
    local function pop_scope()
        local s = scopes[depth]
        depth = depth - 1
        for i = 1, #s.order do
            local d = s.order[i]
            if not d.read and d.name:sub(1, 1) ~= "_" then
                diag("unused-local", d.line, d.col, "local '" .. d.name .. "' is never read")
            end
        end
        return nil
    end

    --: (name: string, line: integer, col: integer, cell: string, read: boolean) -> Decl
    local function declare(name, line, col, cell, read)
        counter = counter + 1
        local d = { id = name .. "#" .. counter, name = name, line = line, col = col, read = read, cell = cell } --: Decl
        local s = scopes[depth]
        s.map[name] = d
        s.order[#s.order + 1] = d
        return d
    end

    --: (string) -> Decl | nil
    local function resolve(name)
        for i = depth, 1, -1 do
            local d = scopes[i].map[name]
            if d ~= nil then return d end
        end
        return nil
    end

    -- All visible decls (innermost shadowing outer), for branch snapshots.
    --: () -> { [integer]: Decl }
    local function visible()
        local seen = {} --: { [string]: boolean }
        local out = {} --: { [integer]: Decl }
        for i = depth, 1, -1 do
            local s = scopes[i]
            for j = 1, #s.order do
                local d = s.order[j]
                if not seen[d.name] then
                    seen[d.name] = true
                    out[#out + 1] = d
                end
            end
        end
        return out
    end

    --: ({ [integer]: Decl }) -> { [string]: string }
    local function snapshot(vis)
        local r = {} --: { [string]: string }
        for i = 1, #vis do r[vis[i].id] = vis[i].cell end
        return r
    end

    --: ({ [integer]: Decl }, { [string]: string }) -> nil
    local function restore(vis, snap)
        for i = 1, #vis do
            local d = vis[i]
            local c = snap[d.id]
            if c ~= nil then d.cell = c end
        end
        return nil
    end

    -- ── forward declarations (mutual recursion: exprs contain bodies).
    -- Unannotated on purpose: the checker types them at their assignment
    -- sites below (annotated there), same idiom as parse.lua.
    local lower_expr, lower_stmts

    -- ── havoc scan (soundness fence around unsupported subtrees) ──────────
    -- Marks identifier reads (no false "unused"), and havocs outer locals
    -- assigned inside the unchecked region to `unknown`.
    --: (unknown) -> nil
    local function havoc_scan(x)
        if not is_tbl(x) then return nil end
        local tag = x.tag
        if type(tag) == "number" then
            if tag == defs.NODE_IDENTIFIER then
                local nm = x.name
                if type(nm) == "string" then
                    local d = resolve(nm)
                    if d ~= nil then d.read = true end
                end
            elseif tag == defs.NODE_ASSIGN_STMT then
                local targets = x.targets
                if is_tbl(targets) then
                    for _, t in pairs(targets) do
                        if is_tbl(t) then
                            local tt = t.tag
                            local nm = t.name
                            if type(tt) == "number" and tt == defs.NODE_IDENTIFIER and type(nm) == "string" then
                                local d = resolve(nm)
                                if d ~= nil then d.cell = unknown_cell("havoc-" .. nm) end
                            end
                        end
                    end
                end
            elseif tag == defs.NODE_FUNC_DECL then
                local name_node = x.name
                if is_tbl(name_node) then
                    local tt = name_node.tag
                    local nm = name_node.name
                    if type(tt) == "number" and tt == defs.NODE_IDENTIFIER and type(nm) == "string" then
                        local d = resolve(nm)
                        if d ~= nil then d.cell = unknown_cell("havoc-" .. nm) end
                    end
                end
            end
        end
        for _, v in pairs(x) do
            if is_tbl(v) then havoc_scan(v) end
        end
        return nil
    end

    -- ── shared construct pieces (each used by exactly the constructs whose
    --    semantics share them — not solver branches) ───────────────────────

    -- A function body: fresh scope, params bound (unknown until annotations
    -- land), returns flow into this function's ret cell. Value : function.
    --: (Ast) -> string
    local function lower_function(n)
        push_scope()
        ret_depth = ret_depth + 1
        ret_cells[ret_depth] = fresh("ret")
        local params = n.params
        if is_list(params) then
            for i = 1, #params do
                local nm = params[i].name
                if type(nm) == "string" then
                    -- params are exempt from unused-local (read = true):
                    -- callbacks legitimately ignore params.
                    declare(nm, n.line, n.col, unknown_cell("param-" .. nm), true)
                end
            end
        end
        local body = n.body
        if is_list(body) then lower_stmts(body) end
        ret_depth = ret_depth - 1
        pop_scope()
        return atom_cell("function")
    end

    -- Lower an expression list into `want` source cells: extra targets take
    -- `unknown` when the last expression can multi-return (call / method /
    -- vararg), else `nil` (Lua pads with nil).
    --: ({ [integer]: Ast }, integer) -> { [integer]: string }
    local function lower_value_list(exprs, want)
        local cells = {} --: { [integer]: string }
        local nexpr = #exprs
        for i = 1, nexpr do
            cells[i] = lower_expr(exprs[i])
        end
        if want > nexpr then
            local spread = false
            if nexpr > 0 then
                local t = exprs[nexpr].tag
                spread = t == defs.NODE_CALL_EXPR or t == defs.NODE_METHOD_CALL
                    or t == defs.NODE_VARARG_EXPR
            end
            for i = nexpr + 1, want do
                if spread then
                    cells[i] = unknown_cell("spread")
                else
                    cells[i] = atom_cell("nil")
                end
            end
        end
        return cells
    end

    -- If `cond` is narrowable in v0 (a bare local, or `not <local>`), return
    -- its decl and whether the sense is negated. Richer guards (type(x) ==
    -- "...", comparisons) are a later increment of the SAME mechanism.
    --: (Ast) -> (Decl | nil, boolean)
    local function cond_target(cond)
        if cond.tag == defs.NODE_IDENTIFIER then
            local nm = cond.name
            if type(nm) == "string" then return resolve(nm), false end
        elseif cond.tag == defs.NODE_UNARY_EXPR then
            local op = cond.op
            local operand = cond.operand
            if op == "not" and is_node(operand) and operand.tag == defs.NODE_IDENTIFIER then
                local nm = operand.name
                if type(nm) == "string" then return resolve(nm), true end
            end
        end
        return nil, false
    end

    -- ── expressions ────────────────────────────────────────────────────────

    --: (Ast) -> string
    lower_expr = function(n)
        local tag = n.tag
        if tag == defs.NODE_LITERAL then
            local k = n.lit_kind
            if type(k) == "number" then
                if k == defs.LIT_NIL then return atom_cell("nil") end
                if k == defs.LIT_BOOLEAN then return atom_cell("boolean") end
                if k == defs.LIT_INTEGER or k == defs.LIT_NUMBER then return atom_cell("number") end
                if k == defs.LIT_STRING then return atom_cell("string") end
            end
            unsupported(n, "opaque-key-literal")
            return unknown_cell("opaque")
        elseif tag == defs.NODE_IDENTIFIER then
            local nm = n.name
            if type(nm) ~= "string" then
                internal(n, "identifier without a name")
                return unknown_cell("bad-ident")
            end
            local d = resolve(nm)
            if d ~= nil then
                d.read = true
                return d.cell
            end
            diag("undeclared-global", n.line, n.col,
                "undeclared global '" .. nm .. "' (crescent has no ambient globals; its type is unknown here)")
            return unknown_cell("g-" .. nm)
        elseif tag == defs.NODE_UNARY_EXPR then
            local operand = n.operand
            local op = n.op
            local oc = "" --: string
            if is_node(operand) then
                oc = lower_expr(operand)
            else
                internal(n, "unary without operand")
                oc = unknown_cell("unop")
            end
            if type(op) ~= "string" then
                internal(n, "unary without op")
                return unknown_cell("unop")
            end
            local bound, result = unop_rule(op)
            if result == nil then
                internal(n, "unknown unary op '" .. op .. "'")
                return unknown_cell("unop")
            end
            if bound ~= nil then
                obligate(oc, bound, "op-mismatch", "operand of unary '" .. op .. "'", n.line, n.col)
            end
            return atom_cell(result)
        elseif tag == defs.NODE_BINARY_EXPR then
            local lhs = n.lhs
            local rhs = n.rhs
            local op = n.op
            if not is_node(lhs) or not is_node(rhs) or type(op) ~= "string" then
                internal(n, "malformed binary expression")
                return unknown_cell("binop")
            end
            local lc = lower_expr(lhs)
            local rc = lower_expr(rhs)
            local bound, result, derive = binop_rule(op)
            if derive ~= nil then
                -- and/or: DERIVED from the lattice's falsy/truthy — the
                -- result cell joins filter(lhs) with type(rhs). No special
                -- case; the same transfer narrowing uses.
                local c = fresh(op)
                filter_flow(lc, c, derive)
                flow(rc, c)
                return c
            end
            if result == nil then
                internal(n, "unknown binary op '" .. op .. "'")
                return unknown_cell("binop")
            end
            if bound ~= nil then
                obligate(lc, bound, "op-mismatch", "left operand of '" .. op .. "'", lhs.line, lhs.col)
                obligate(rc, bound, "op-mismatch", "right operand of '" .. op .. "'", rhs.line, rhs.col)
            end
            return atom_cell(result)
        elseif tag == defs.NODE_CALL_EXPR then
            -- shallow v0: callee must be a function; the result is unknown
            -- (function TYPES — params/returns — are the next domain upgrade).
            local callee = n.callee
            local cc = "" --: string
            if is_node(callee) then
                cc = lower_expr(callee)
            else
                internal(n, "call without callee")
                cc = unknown_cell("callee")
            end
            local args = n.args
            if is_list(args) then
                for i = 1, #args do lower_expr(args[i]) end
            end
            obligate(cc, FUNC, "call-non-function", "called value", n.line, n.col)
            return unknown_cell("call")
        elseif tag == defs.NODE_METHOD_CALL then
            local recv = n.receiver
            if is_node(recv) then lower_expr(recv) end
            local args = n.args
            if is_list(args) then
                for i = 1, #args do lower_expr(args[i]) end
            end
            unsupported(n, "method-call")
            return unknown_cell("mcall")
        elseif tag == defs.NODE_FIELD_EXPR then
            local target = n.target
            if is_node(target) then lower_expr(target) end
            unsupported(n, "field-expr")
            return unknown_cell("field")
        elseif tag == defs.NODE_INDEX_EXPR then
            local target = n.target
            local key = n.key
            if is_node(target) then lower_expr(target) end
            if is_node(key) then lower_expr(key) end
            unsupported(n, "index-expr")
            return unknown_cell("index")
        elseif tag == defs.NODE_FUNC_EXPR then
            return lower_function(n)
        elseif tag == defs.NODE_TABLE_EXPR then
            -- the VALUE is soundly `table` (the table top); the FIELDS are
            -- beyond v0 (no record types yet) — flagged, still traversed.
            unsupported(n, "table-constructor")
            local fields = n.fields
            if is_list(fields) then
                for i = 1, #fields do
                    local f = fields[i]
                    local v = f.value
                    if is_node(v) then lower_expr(v) end
                    local k = f.key
                    if is_node(k) then lower_expr(k) end
                end
            end
            return atom_cell("table")
        elseif tag == defs.NODE_VARARG_EXPR then
            unsupported(n, "vararg")
            return unknown_cell("vararg")
        elseif tag == defs.NODE_CAST_EXPR then
            local inner = n.expr
            if is_node(inner) then lower_expr(inner) end
            -- the annotation string is not parsed yet (ann.lua is fenced
            -- legacy); the cast's asserted type cannot be checked, so the
            -- result is unknown — honest, sound, and loud.
            unsupported(n, "cast-annotation")
            return unknown_cell("cast")
        elseif tag == defs.NODE_MATCH_EXPR then
            -- walker-only synthetic; never parser-emitted. Routed anyway.
            unsupported(n, "match-expr")
            return unknown_cell("match")
        end
        internal(n, "node kind '" .. frontend.node_name(tag) .. "' in expression position")
        return unknown_cell("unexpected")
    end

    -- ── statements ─────────────────────────────────────────────────────────

    -- `if`/`elseif`/`else` with truthiness narrowing and join-at-merge.
    -- Clause i's else-path IS clauses i+1.. (+ else block) — one recursion,
    -- so elseif chains get the same narrowing/merge as plain if/else.
    --: ({ [integer]: Ast }, integer, { [integer]: Ast } | nil) -> nil
    local function lower_if_from(clauses, i, else_body)
        local clause = clauses[i]
        local cond = clause.cond
        if not is_node(cond) then
            internal(clause, "if-clause without condition")
            return nil
        end
        lower_expr(cond)
        local vis = visible()
        local pre = snapshot(vis)
        local d, negated = cond_target(cond)

        -- then-arm: cond is truthy (falsy when the condition is `not x`).
        if d ~= nil then
            local nc = fresh(d.name .. "-then")
            if negated then filter_flow(d.cell, nc, "falsy") else filter_flow(d.cell, nc, "truthy") end
            d.cell = nc
        end
        local body = clause.body
        if is_list(body) then
            push_scope()
            lower_stmts(body)
            pop_scope()
        end
        local then_snap = snapshot(vis)
        restore(vis, pre)

        -- else-arm: the complementary filter, then the rest of the chain.
        if d ~= nil then
            local ec = fresh(d.name .. "-else")
            if negated then filter_flow(d.cell, ec, "truthy") else filter_flow(d.cell, ec, "falsy") end
            d.cell = ec
        end
        if i < #clauses then
            lower_if_from(clauses, i + 1, else_body)
        elseif else_body ~= nil then
            push_scope()
            lower_stmts(else_body)
            pop_scope()
        end
        local else_snap = snapshot(vis)
        restore(vis, pre)

        -- merge: differing branch versions meet at a phi cell; the engine's
        -- join produces the union. Identical versions pass through.
        for k = 1, #vis do
            local dk = vis[k]
            local t = then_snap[dk.id]
            local e = else_snap[dk.id]
            if t ~= nil and e ~= nil then
                if t == e then
                    dk.cell = t
                else
                    local phi = fresh(dk.name .. "-phi")
                    flow(t, phi)
                    flow(e, phi)
                    dk.cell = phi
                end
            end
        end
        return nil
    end

    --: (Ast) -> nil
    local function lower_stmt(n)
        local tag = n.tag
        if tag == defs.NODE_LOCAL_STMT then
            local names = n.names
            local exprs = n.exprs
            if not is_list(names) then
                internal(n, "local without names")
                return nil
            end
            local cells = {} --: { [integer]: string }
            if is_list(exprs) then
                cells = lower_value_list(exprs, #names)
            end
            for i = 1, #names do
                local nm = names[i].name
                if type(nm) == "string" then
                    local c = cells[i]
                    if c == nil then c = atom_cell("nil") end
                    declare(nm, n.line, n.col, c, false)
                end
            end
            return nil
        elseif tag == defs.NODE_ASSIGN_STMT then
            local targets = n.targets
            local exprs = n.exprs
            if not is_list(targets) or not is_list(exprs) then
                internal(n, "malformed assignment")
                return nil
            end
            local cells = lower_value_list(exprs, #targets)
            for i = 1, #targets do
                local t = targets[i]
                if t.tag == defs.NODE_IDENTIFIER then
                    local nm = t.name
                    if type(nm) == "string" then
                        local d = resolve(nm)
                        if d ~= nil then
                            local c = cells[i]
                            if c ~= nil then d.cell = c end
                        else
                            diag("global-write", t.line, t.col,
                                "write to undeclared global '" .. nm .. "'")
                        end
                    end
                elseif t.tag == defs.NODE_FIELD_EXPR or t.tag == defs.NODE_INDEX_EXPR then
                    local target = t.target
                    if is_node(target) then lower_expr(target) end
                    local key = t.key
                    if is_node(key) then lower_expr(key) end
                    unsupported(t, "field-assign")
                else
                    internal(t, "unexpected assignment target")
                end
            end
            return nil
        elseif tag == defs.NODE_EXPR_STMT then
            local e = n.expr
            if is_node(e) then lower_expr(e) end
            return nil
        elseif tag == defs.NODE_DO_STMT then
            local body = n.body
            if is_list(body) then
                push_scope()
                lower_stmts(body)
                pop_scope()
            end
            return nil
        elseif tag == defs.NODE_IF_STMT then
            local clauses = n.clauses
            if is_list(clauses) and #clauses >= 1 then
                local else_body = n.else_body
                if is_list(else_body) then
                    lower_if_from(clauses, 1, else_body)
                else
                    lower_if_from(clauses, 1, nil)
                end
            else
                internal(n, "if without clauses")
            end
            return nil
        elseif tag == defs.NODE_RETURN_STMT then
            local exprs = n.exprs
            if is_list(exprs) then
                for i = 1, #exprs do
                    local c = lower_expr(exprs[i])
                    if ret_depth >= 1 then flow(c, ret_cells[ret_depth]) end
                end
            end
            return nil
        elseif tag == defs.NODE_FUNC_DECL then
            local name_node = n.name
            if is_node(name_node) and name_node.tag == defs.NODE_IDENTIFIER then
                local nm = name_node.name
                if type(nm) == "string" then
                    if n.is_local == true then
                        -- bind BEFORE the body: `local function f` sees
                        -- itself (recursion).
                        local d = declare(nm, n.line, n.col, atom_cell("function"), false)
                        local c = lower_function(n)
                        d.cell = c
                    else
                        -- `function f() end`: assignment to f (a local if one
                        -- is visible, else an undeclared-global write).
                        local c = lower_function(n)
                        local d = resolve(nm)
                        if d ~= nil then
                            d.cell = c
                        else
                            diag("global-write", n.line, n.col,
                                "write to undeclared global '" .. nm .. "'")
                        end
                    end
                    return nil
                end
            end
            -- `function M.f()` / `function M:f()`: the VALUE is still checked
            -- (body lowered); the field-target write is beyond v0.
            if is_node(name_node) then lower_expr(name_node) end
            lower_function(n)
            unsupported(n, "field-assign")
            return nil
        elseif tag == defs.NODE_WHILE_STMT or tag == defs.NODE_REPEAT_STMT
            or tag == defs.NODE_FOR_NUM or tag == defs.NODE_FOR_IN then
            unsupported(n, frontend.node_name(tag))
            havoc_scan(n)
            return nil
        elseif tag == defs.NODE_BREAK_STMT then
            unsupported(n, "break-stmt")
            return nil
        elseif tag == defs.NODE_GOTO_STMT then
            unsupported(n, "goto-stmt")
            return nil
        elseif tag == defs.NODE_LABEL_STMT then
            unsupported(n, "label-stmt")
            return nil
        elseif tag == defs.NODE_CHUNK or tag == defs.NODE_IF_CLAUSE or tag == defs.NODE_TABLE_FIELD then
            internal(n, "container node '" .. frontend.node_name(tag) .. "' in statement position")
            return nil
        end
        -- expression kind in statement position (parser never emits this) —
        -- routed defensively, still total.
        internal(n, "node kind '" .. frontend.node_name(tag) .. "' in statement position")
        return nil
    end

    --: ({ [integer]: Ast }) -> nil
    lower_stmts = function(list)
        for i = 1, #list do
            lower_stmt(list[i])
        end
        return nil
    end

    -- ── entry: the chunk ───────────────────────────────────────────────────
    -- `vars` maps each top-level local to its FINAL cell — the readout for
    -- callers/tests that want inferred types by name.
    local vars = {} --: { [string]: string }
    if chunk.tag == defs.NODE_CHUNK then
        push_scope()
        ret_depth = 1
        ret_cells[1] = fresh("chunk-ret")
        local body = chunk.body
        if is_list(body) then lower_stmts(body) end
        local top = scopes[1]
        for i = 1, #top.order do
            local d = top.order[i]
            vars[d.name] = d.cell
        end
        pop_scope()
    else
        internal(chunk, "root is not a chunk")
    end

    return {
        graph = { lattice = lattice.lattice, rules = rules },
        obligations = obligations,
        diags = diags,
        vars = vars,
    }
end

-- The totality roster: every parser node kind and how it is routed —
-- "checked" (in the v0 discipline), "boundary" (honest unsupported
-- diagnostic), or "container" (only ever reached via its parent construct).
-- Tests assert this table covers all 30 kinds; the whole-lib smoke run is
-- the no-crash evidence.
local ROUTE = {} --: { [integer]: string }
ROUTE[defs.NODE_LITERAL] = "checked"
ROUTE[defs.NODE_IDENTIFIER] = "checked"
ROUTE[defs.NODE_UNARY_EXPR] = "checked"
ROUTE[defs.NODE_BINARY_EXPR] = "checked"
ROUTE[defs.NODE_INDEX_EXPR] = "boundary"
ROUTE[defs.NODE_FIELD_EXPR] = "boundary"
ROUTE[defs.NODE_METHOD_CALL] = "boundary"
ROUTE[defs.NODE_CALL_EXPR] = "checked"
ROUTE[defs.NODE_FUNC_EXPR] = "checked"
ROUTE[defs.NODE_TABLE_EXPR] = "boundary"
ROUTE[defs.NODE_TABLE_FIELD] = "container"
ROUTE[defs.NODE_VARARG_EXPR] = "boundary"
ROUTE[defs.NODE_ASSIGN_STMT] = "checked"
ROUTE[defs.NODE_LOCAL_STMT] = "checked"
ROUTE[defs.NODE_DO_STMT] = "checked"
ROUTE[defs.NODE_WHILE_STMT] = "boundary"
ROUTE[defs.NODE_REPEAT_STMT] = "boundary"
ROUTE[defs.NODE_IF_STMT] = "checked"
ROUTE[defs.NODE_IF_CLAUSE] = "container"
ROUTE[defs.NODE_FOR_NUM] = "boundary"
ROUTE[defs.NODE_FOR_IN] = "boundary"
ROUTE[defs.NODE_RETURN_STMT] = "checked"
ROUTE[defs.NODE_BREAK_STMT] = "boundary"
ROUTE[defs.NODE_GOTO_STMT] = "boundary"
ROUTE[defs.NODE_LABEL_STMT] = "boundary"
ROUTE[defs.NODE_EXPR_STMT] = "checked"
ROUTE[defs.NODE_FUNC_DECL] = "checked"
ROUTE[defs.NODE_CHUNK] = "checked"
ROUTE[defs.NODE_CAST_EXPR] = "boundary"
ROUTE[defs.NODE_MATCH_EXPR] = "boundary"
M.ROUTE = ROUTE

return M
