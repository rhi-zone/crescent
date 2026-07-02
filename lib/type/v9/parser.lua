-- lib/type/v9/parser.lua
-- Parser -> IR seam. Source -> s-expression surface AST -> de-Bruijn IR.
-- Proof oracle: the lowering TARGET is `tm` (typing.v) — a de-Bruijn core.
--
-- FENCE (proof-oracle only): this s-expr frontend exists solely for the
-- proof-parity path (slice_test.lua / parity_test.lua against the Coq `tm`
-- core). It is NOT the Lua-language frontend and must not grow toward Lua.
-- Lua source is parsed by `lib/type/v9/frontend/` (the proven full-Lua parser
-- behind the v9 seam); checking real files goes through lib/type/v9/check.lua.
--
-- Surface syntax (Lisp-style, deliberately tiny):
--   42  "str"  true  false  nil        -- literals
--   x                                   -- variable (resolved to de-Bruijn)
--   (lambda (x T) body)                 -- T parsed by parse_type
--   (let (x e1) e2)
--   (f a b ...)                         -- application, left-associative
-- Types: Int Num Float Str Bool Nil Top Bot   (-> A B ...)  -- arrow, right-assoc
--
-- Names are carried into the IR as metadata only (`names.source`); resolution to
-- a de-Bruijn index is what makes typing alpha-stable. Errors are `(nil, msg)`.

--:: require "lib.type.v9.type_defs"

local M = {}
M.name = "sexpr"

-- ---- tokenizer -----------------------------------------------------------
--: (string) -> { [integer]: string }
local function tokenize(src)
    local toks = {} --: { [integer]: string }
    local i = 1
    local n = #src
    while i <= n do
        local c = string.sub(src, i, i)
        if c == "(" or c == ")" then
            toks[#toks + 1] = c
            i = i + 1
        elseif c == '"' then
            local j = i + 1
            while j <= n and string.sub(src, j, j) ~= '"' do j = j + 1 end
            toks[#toks + 1] = string.sub(src, i, j) -- keep quotes to mark a string literal
            i = j + 1
        elseif c:match("%s") then
            i = i + 1
        else
            local j = i
            while j <= n do
                local d = string.sub(src, j, j)
                if d == "(" or d == ")" or d == '"' or d:match("%s") then break end
                j = j + 1
            end
            toks[#toks + 1] = string.sub(src, i, j - 1)
            i = j
        end
    end
    return toks
end

-- ---- s-expression parser -------------------------------------------------
-- Returns (node, next_index) on success, or (nil, next_index, errmsg).
--: ({ [integer]: string }, integer) -> (SExpr | nil, integer, string | nil)
local function parse_at(toks, pos)
    local t = toks[pos]
    if t == nil then return nil, pos, "unexpected end of input" end
    if t == ")" then return nil, pos, "unexpected )" end
    if t == "(" then
        local items = {} --: { [integer]: SExpr }
        local p = pos + 1
        while toks[p] ~= nil and toks[p] ~= ")" do
            local node, np, err = parse_at(toks, p)
            if node == nil then return nil, np, err end
            items[#items + 1] = node
            p = np
        end
        if toks[p] ~= ")" then return nil, p, "missing )" end
        return { kind = "list", items = items }, p + 1, nil
    end
    return { kind = "atom", value = t }, pos + 1, nil
end

--: (string) -> (SExpr | nil, string | nil)
function M.parse(src)
    local toks = tokenize(src)
    local node, np, err = parse_at(toks, 1)
    if node == nil then return nil, err or "parse error" end
    if toks[np] ~= nil then return nil, "trailing tokens after expression" end
    return node, nil
end

-- ---- type interpretation -------------------------------------------------
local atom_names = {
    Int = "int", Num = "num", Float = "float", Str = "str", Bool = "bool", Nil = "nil",
} --: { [string]: string }

--: (TypeRep, SExpr, (TypeRep, SExpr) -> (Ty | nil, string | nil)) -> (Ty | nil, string | nil)
local function type_of(rep, s, rec)
    if s.kind == "atom" then
        local v = s.value
        if v == "Top" then return rep.top(), nil end
        if v == "Bot" then return rep.bot(), nil end
        local an = atom_names[v]
        if an == nil then return nil, "unknown type: " .. v end
        return rep.atom(an), nil
    end
    local items = s.items
    if #items == 0 then return nil, "empty type expression" end
    local head = items[1]
    if head.kind == "atom" and head.value == "->" then
        if #items < 3 then return nil, "arrow needs at least 2 operands" end
        -- right-associative fold: (-> A B C) = A -> (B -> C)
        local acc, accerr = rec(rep, items[#items])
        if acc == nil then return nil, accerr end
        local result = acc --: Ty
        for k = #items - 1, 2, -1 do
            local dom, derr = rec(rep, items[k])
            if dom == nil then return nil, derr end
            result = rep.arrow(dom, result)
        end
        return result, nil
    end
    return nil, "unsupported type expression"
end

--: (TypeRep, SExpr) -> (Ty | nil, string | nil)
local function type_of_sexpr(rep, s)
    return type_of(rep, s, type_of_sexpr)
end

--: (TypeRep, string) -> (Ty | nil, string | nil)
function M.parse_type(rep, src)
    local node, err = M.parse(src)
    if node == nil then return nil, err end
    return type_of_sexpr(rep, node)
end

-- ---- lowering: surface -> de-Bruijn IR -----------------------------------
local ir = require("lib.type.v9.ir")

-- Resolve a name to a de-Bruijn index over the scope stack (top = index 0).
--: ({ [integer]: string }, string) -> (integer | nil)
local function resolve(scope, name)
    for i = #scope, 1, -1 do
        if scope[i] == name then return #scope - i end
    end
    return nil
end

--: ({ [integer]: string }, string) -> { [integer]: string }
local function push_name(scope, name)
    local s = {} --: { [integer]: string }
    for i = 1, #scope do s[i] = scope[i] end
    s[#s + 1] = name
    return s
end

--: (TypeRep, SExpr, { [integer]: string }, (TypeRep, SExpr, { [integer]: string }) -> (IrNode | nil, string | nil)) -> (IrNode | nil, string | nil)
local function lower_at(rep, s, scope, rec)
    if s.kind == "atom" then
        local v = s.value
        if v:match("^%-?%d+$") then return ir.lit_int(v), nil end
        if string.sub(v, 1, 1) == '"' then
            return ir.lit_str(string.sub(v, 2, #v - 1), v), nil
        end
        if v == "true" then return ir.lit_bool(true, v), nil end
        if v == "false" then return ir.lit_bool(false, v), nil end
        if v == "nil" then return ir.lit_nil(v), nil end
        local idx = resolve(scope, v)
        if idx == nil then return nil, "unbound variable: " .. v end
        return ir.var(idx, v), nil
    end
    local items = s.items
    if #items == 0 then return nil, "empty expression" end
    local head = items[1]
    if head.kind == "atom" and head.value == "lambda" then
        if #items ~= 3 then return nil, "lambda needs (lambda (x T) body)" end
        local binder = items[2]
        if binder.kind ~= "list" or #binder.items ~= 2 then return nil, "lambda binder must be (x T)" end
        local name_node = binder.items[1]
        if name_node.kind ~= "atom" then return nil, "lambda parameter must be a name" end
        local pty, perr = type_of_sexpr(rep, binder.items[2])
        if pty == nil then return nil, perr end
        local body, berr = rec(rep, items[3], push_name(scope, name_node.value))
        if body == nil then return nil, berr end
        return ir.lam(pty, body, name_node.value), nil
    end
    if head.kind == "atom" and head.value == "let" then
        if #items ~= 3 then return nil, "let needs (let (x e1) e2)" end
        local binder = items[2]
        if binder.kind ~= "list" or #binder.items ~= 2 then return nil, "let binder must be (x e1)" end
        local name_node = binder.items[1]
        if name_node.kind ~= "atom" then return nil, "let binding must name a variable" end
        local value, verr = rec(rep, binder.items[2], scope)
        if value == nil then return nil, verr end
        local body, berr = rec(rep, items[3], push_name(scope, name_node.value))
        if body == nil then return nil, berr end
        return ir.let_(value, body, name_node.value), nil
    end
    -- application, left-associative: (f a b) = ((f a) b)
    local node, accerr = rec(rep, items[1], scope)
    if node == nil then return nil, accerr end
    for k = 2, #items do
        local arg, aerr = rec(rep, items[k], scope)
        if arg == nil then return nil, aerr end
        node = ir.app(node, arg)
    end
    return node, nil
end

--: (TypeRep, SExpr, { [integer]: string }) -> (IrNode | nil, string | nil)
local function lower_scoped(rep, s, scope)
    return lower_at(rep, s, scope, lower_scoped)
end

--: (TypeRep, SExpr) -> (IrNode | nil, string | nil)
function M.lower(rep, s)
    local empty = {} --: { [integer]: string }
    return lower_scoped(rep, s, empty)
end

return M
