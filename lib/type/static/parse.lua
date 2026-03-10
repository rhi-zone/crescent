-- lib/type/static/parse.lua
-- Recursive descent parser for Lua 5.1/LuaJIT.
-- Emits flat ASTNode entries directly into an arena — no intermediate tables.
--
-- List pool discipline: any list whose items come from parse calls (which may
-- internally push to the list pool) must collect results into a Lua table
-- first, then push them contiguously. Only lists of simple values (intern IDs)
-- that complete before any nested parsing can use mark/push/since directly.

local ffi = require("ffi")
local bit = require("bit")
local defs = require("lib.type.static.defs")
local lex_mod = require("lib.type.static.lex")
local arena_mod = require("lib.type.static.arena")
local intern_mod = require("lib.type.static.intern")

local rshift = bit.rshift
local band = bit.band
local bor = bit.bor
local format = string.format

local M = {}

-- Token type → binary operator code
local tk_to_binop = {}
tk_to_binop[defs.TK_PLUS]    = defs.OP_ADD
tk_to_binop[defs.TK_MINUS]   = defs.OP_SUB
tk_to_binop[defs.TK_STAR]    = defs.OP_MUL
tk_to_binop[defs.TK_SLASH]   = defs.OP_DIV
tk_to_binop[defs.TK_PERCENT] = defs.OP_MOD
tk_to_binop[defs.TK_CARET]   = defs.OP_POW
tk_to_binop[defs.TK_CONCAT]  = defs.OP_CONCAT
tk_to_binop[defs.TK_EQ]      = defs.OP_EQ
tk_to_binop[defs.TK_NE]      = defs.OP_NE
tk_to_binop[defs.TK_LT]      = defs.OP_LT
tk_to_binop[defs.TK_LE]      = defs.OP_LE
tk_to_binop[defs.TK_GT]      = defs.OP_GT
tk_to_binop[defs.TK_GE]      = defs.OP_GE
tk_to_binop[defs.TK_AND]     = defs.OP_AND
tk_to_binop[defs.TK_OR]      = defs.OP_OR

local UNARY_PREC = 8

function M.parse(source, filename, pool)
    pool = pool or intern_mod.new()
    filename = filename or "?"
    local L = lex_mod.new(source, filename, pool)
    local nodes = arena_mod.new_node_arena(256)
    local lists = arena_mod.new_list_pool(512)

    -- Allocate a node with position
    local function mknode(kind, line, col)
        local i = nodes:alloc()
        local n = nodes:get(i)
        n.kind = kind
        n.flags = 0
        n.line = line or L._tk_line_out
        n.col = col or L._tk_col_out
        n.data[0] = 0; n.data[1] = 0; n.data[2] = 0
        n.data[3] = 0; n.data[4] = 0; n.data[5] = 0
        return i
    end

    local function parse_error(msg)
        error(format("%s:%d:%d: %s", filename,
            L._tk_line_out or L.line, L._tk_col_out or L.col, msg), 0)
    end

    -- Push a collected Lua array into the list pool contiguously.
    -- Returns (start, len) pair.
    local function flush_list(items)
        local m = lists:mark()
        for i = 1, #items do lists:push(items[i]) end
        return lists:since(m)
    end

    -- Forward declarations for mutually recursive functions
    local parse_expr, parse_block, parse_stmt
    local parse_suffixed_expr, parse_table_expr

    -------------------------------------------------------------------
    -- Helper: parse parameter list, body, and closing 'end'.
    -- Params are intern IDs (safe for direct mark/push/since).
    -------------------------------------------------------------------

    local function parse_params_and_body(has_self)
        L:expect(defs.TK_LPAREN)
        local pm = lists:mark()
        if has_self then
            lists:push(intern_mod.intern(pool, "self"))
        end
        local has_vararg = false
        if L.tk ~= defs.TK_RPAREN then
            if L.tk == defs.TK_DOTS then
                has_vararg = true
                L:next()
            else
                lists:push(L.val)
                L:expect(defs.TK_NAME)
                while L:opt(defs.TK_COMMA) do
                    if L.tk == defs.TK_DOTS then
                        has_vararg = true
                        L:next()
                        break
                    end
                    lists:push(L.val)
                    L:expect(defs.TK_NAME)
                end
            end
        end
        local ps, pl = lists:since(pm)
        L:expect(defs.TK_RPAREN)
        local bs, bl = parse_block()
        local lastline = L._tk_line_out
        L:expect(defs.TK_END)
        return ps, pl, bs, bl, lastline, has_vararg
    end

    -------------------------------------------------------------------
    -- Expression parsing
    -------------------------------------------------------------------

    local function parse_expr_list()
        local items = { parse_expr(0) }
        while L:opt(defs.TK_COMMA) do
            items[#items + 1] = parse_expr(0)
        end
        return flush_list(items)
    end

    local function parse_call_args()
        if L.tk == defs.TK_LPAREN then
            L:next()
            if L.tk == defs.TK_RPAREN then
                L:next()
                return lists:mark(), 0
            end
            local items = { parse_expr(0) }
            while L:opt(defs.TK_COMMA) do
                items[#items + 1] = parse_expr(0)
            end
            L:expect(defs.TK_RPAREN)
            return flush_list(items)
        elseif L.tk == defs.TK_STRING then
            local n = mknode(defs.NODE_LITERAL)
            local nd = nodes:get(n)
            nd.data[0] = defs.LIT_STRING
            nd.data[1] = L.val
            L:next()
            local m = lists:mark()
            lists:push(n)
            return lists:since(m)
        elseif L.tk == defs.TK_LBRACE then
            local tbl = parse_table_expr()
            local m = lists:mark()
            lists:push(tbl)
            return lists:since(m)
        else
            parse_error("function arguments expected")
        end
    end

    -- Table constructor: { field, field, ... }
    parse_table_expr = function()
        local line, col = L._tk_line_out, L._tk_col_out
        L:next()  -- skip '{'
        local fields = {}
        while L.tk ~= defs.TK_RBRACE do
            local fline, fcol = L._tk_line_out, L._tk_col_out
            local fn
            if L.tk == defs.TK_LBRACKET then
                -- [expr] = expr
                L:next()
                local key = parse_expr(0)
                L:expect(defs.TK_RBRACKET)
                L:expect(defs.TK_ASSIGN)
                local val = parse_expr(0)
                fn = mknode(defs.NODE_TABLE_FIELD, fline, fcol)
                local fnd = nodes:get(fn)
                fnd.data[0] = key
                fnd.data[1] = val
                fnd.flags = defs.FLAG_COMPUTED
            elseif L.tk == defs.TK_NAME and L:lookahead() == defs.TK_ASSIGN then
                -- name = expr
                local key_id = L.val
                L:next()  -- consume name
                L:next()  -- consume '='
                local val = parse_expr(0)
                local key_node = mknode(defs.NODE_LITERAL, fline, fcol)
                nodes:get(key_node).data[0] = defs.LIT_STRING
                nodes:get(key_node).data[1] = key_id
                fn = mknode(defs.NODE_TABLE_FIELD, fline, fcol)
                nodes:get(fn).data[0] = key_node
                nodes:get(fn).data[1] = val
            else
                -- positional value
                local val = parse_expr(0)
                fn = mknode(defs.NODE_TABLE_FIELD, fline, fcol)
                nodes:get(fn).data[0] = -1
                nodes:get(fn).data[1] = val
            end
            fields[#fields + 1] = fn
            if not (L:opt(defs.TK_COMMA) or L:opt(defs.TK_SEMICOLON)) then
                break
            end
        end
        L:expect(defs.TK_RBRACE)
        local fs, fl = flush_list(fields)
        local n = mknode(defs.NODE_TABLE_EXPR, line, col)
        nodes:get(n).data[0] = fs
        nodes:get(n).data[1] = fl
        return n
    end

    -- Suffixed expression: Name or '(' expr ')' followed by . [] : () suffixes
    parse_suffixed_expr = function()
        local line, col = L._tk_line_out, L._tk_col_out
        local expr
        if L.tk == defs.TK_NAME then
            expr = mknode(defs.NODE_IDENTIFIER, line, col)
            nodes:get(expr).data[0] = L.val
            L:next()
        elseif L.tk == defs.TK_LPAREN then
            L:next()
            expr = parse_expr(0)
            L:expect(defs.TK_RPAREN)
        else
            parse_error("unexpected symbol " .. (defs.token_name[L.tk] or "?"))
        end
        while true do
            if L.tk == defs.TK_DOT then
                local dl, dc = L._tk_line_out, L._tk_col_out
                L:next()
                local field_id = L.val
                L:expect(defs.TK_NAME)
                local n = mknode(defs.NODE_FIELD_EXPR, dl, dc)
                nodes:get(n).data[0] = expr
                nodes:get(n).data[1] = field_id
                expr = n
            elseif L.tk == defs.TK_LBRACKET then
                local bl, bc = L._tk_line_out, L._tk_col_out
                L:next()
                local index = parse_expr(0)
                L:expect(defs.TK_RBRACKET)
                local n = mknode(defs.NODE_INDEX_EXPR, bl, bc)
                nodes:get(n).data[0] = expr
                nodes:get(n).data[1] = index
                expr = n
            elseif L.tk == defs.TK_COLON then
                local cl, cc = L._tk_line_out, L._tk_col_out
                L:next()
                local method_id = L.val
                L:expect(defs.TK_NAME)
                local as, al = parse_call_args()
                local n = mknode(defs.NODE_METHOD_CALL, cl, cc)
                local nd = nodes:get(n)
                nd.data[0] = expr
                nd.data[1] = method_id
                nd.data[2] = as
                nd.data[3] = al
                expr = n
            elseif L.tk == defs.TK_LPAREN or L.tk == defs.TK_STRING
                or L.tk == defs.TK_LBRACE then
                local cl, cc = L._tk_line_out, L._tk_col_out
                local as, al = parse_call_args()
                local n = mknode(defs.NODE_CALL_EXPR, cl, cc)
                local nd = nodes:get(n)
                nd.data[0] = expr
                nd.data[1] = as
                nd.data[2] = al
                expr = n
            else
                break
            end
        end
        return expr
    end

    -- Simple expression: atoms and prefix expressions
    local function parse_simple_expr()
        local line, col = L._tk_line_out, L._tk_col_out
        local tk = L.tk
        if tk == defs.TK_NUMBER then
            local n = mknode(defs.NODE_LITERAL, line, col)
            nodes:get(n).data[0] = defs.LIT_NUMBER
            nodes:get(n).data[1] = L.val
            L:next()
            return n
        elseif tk == defs.TK_STRING then
            local n = mknode(defs.NODE_LITERAL, line, col)
            nodes:get(n).data[0] = defs.LIT_STRING
            nodes:get(n).data[1] = L.val
            L:next()
            return n
        elseif tk == defs.TK_NIL then
            local n = mknode(defs.NODE_LITERAL, line, col)
            nodes:get(n).data[0] = defs.LIT_NIL
            L:next()
            return n
        elseif tk == defs.TK_TRUE then
            local n = mknode(defs.NODE_LITERAL, line, col)
            nodes:get(n).data[0] = defs.LIT_BOOLEAN
            nodes:get(n).data[1] = 1
            L:next()
            return n
        elseif tk == defs.TK_FALSE then
            local n = mknode(defs.NODE_LITERAL, line, col)
            nodes:get(n).data[0] = defs.LIT_BOOLEAN
            nodes:get(n).data[1] = 0
            L:next()
            return n
        elseif tk == defs.TK_DOTS then
            local n = mknode(defs.NODE_VARARG_EXPR, line, col)
            L:next()
            return n
        elseif tk == defs.TK_FUNCTION then
            L:next()
            local ps, pl, bs, bl, lastline, has_vararg =
                parse_params_and_body(false)
            local n = mknode(defs.NODE_FUNC_EXPR, line, col)
            local nd = nodes:get(n)
            nd.data[0] = ps
            nd.data[1] = pl
            nd.data[2] = bs
            nd.data[3] = bl
            nd.data[4] = lastline
            if has_vararg then nd.flags = defs.FLAG_VARARG end
            return n
        elseif tk == defs.TK_LBRACE then
            return parse_table_expr()
        else
            return parse_suffixed_expr()
        end
    end

    -- Unary expression
    local function parse_unary_expr()
        local op
        local tk = L.tk
        if tk == defs.TK_MINUS then op = defs.OP_UNM
        elseif tk == defs.TK_NOT then op = defs.OP_NOT
        elseif tk == defs.TK_HASH then op = defs.OP_LEN
        end
        if op then
            local line, col = L._tk_line_out, L._tk_col_out
            L:next()
            local operand = parse_expr(UNARY_PREC)
            local n = mknode(defs.NODE_UNARY_EXPR, line, col)
            nodes:get(n).data[0] = op
            nodes:get(n).data[1] = operand
            return n
        end
        return parse_simple_expr()
    end

    -- Binary expression (Pratt parser)
    parse_expr = function(min_prec)
        local left = parse_unary_expr()
        while true do
            local op = tk_to_binop[L.tk]
            if not op then break end
            local prio = defs.binop_priority[op]
            local left_prec = rshift(prio, 8)
            if left_prec < min_prec then break end
            local right_prec = band(prio, 0xFF)
            local line, col = L._tk_line_out, L._tk_col_out
            L:next()
            local right = parse_expr(right_prec + 1)
            local n = mknode(defs.NODE_BINARY_EXPR, line, col)
            nodes:get(n).data[0] = op
            nodes:get(n).data[1] = left
            nodes:get(n).data[2] = right
            left = n
        end
        return left
    end

    -------------------------------------------------------------------
    -- Statement parsing
    -------------------------------------------------------------------

    local function is_block_end()
        local tk = L.tk
        return tk == defs.TK_END or tk == defs.TK_ELSE
            or tk == defs.TK_ELSEIF or tk == defs.TK_UNTIL
            or tk == defs.TK_EOF
    end

    parse_block = function()
        local stmts = {}
        while not is_block_end() do
            if L.tk == defs.TK_RETURN then
                stmts[#stmts + 1] = parse_stmt()
                break
            end
            local s = parse_stmt()
            if s then stmts[#stmts + 1] = s end
        end
        return flush_list(stmts)
    end

    local function parse_if_stmt()
        local line, col = L._tk_line_out, L._tk_col_out
        L:next()  -- skip 'if'
        local clauses = {}
        -- First clause (if)
        local test = parse_expr(0)
        L:expect(defs.TK_THEN)
        local bs, bl = parse_block()
        local clause = mknode(defs.NODE_IF_CLAUSE, line, col)
        local cnd = nodes:get(clause)
        cnd.data[0] = test
        cnd.data[1] = bs
        cnd.data[2] = bl
        clauses[1] = clause
        -- elseif clauses
        while L.tk == defs.TK_ELSEIF do
            local eline, ecol = L._tk_line_out, L._tk_col_out
            L:next()
            test = parse_expr(0)
            L:expect(defs.TK_THEN)
            bs, bl = parse_block()
            clause = mknode(defs.NODE_IF_CLAUSE, eline, ecol)
            cnd = nodes:get(clause)
            cnd.data[0] = test
            cnd.data[1] = bs
            cnd.data[2] = bl
            clauses[#clauses + 1] = clause
        end
        -- else clause
        if L.tk == defs.TK_ELSE then
            local eline, ecol = L._tk_line_out, L._tk_col_out
            L:next()
            bs, bl = parse_block()
            clause = mknode(defs.NODE_IF_CLAUSE, eline, ecol)
            cnd = nodes:get(clause)
            cnd.data[0] = -1
            cnd.data[1] = bs
            cnd.data[2] = bl
            clauses[#clauses + 1] = clause
        end
        L:expect(defs.TK_END)
        local cs, cl = flush_list(clauses)
        local n = mknode(defs.NODE_IF_STMT, line, col)
        nodes:get(n).data[0] = cs
        nodes:get(n).data[1] = cl
        return n
    end

    local function parse_while_stmt()
        local line, col = L._tk_line_out, L._tk_col_out
        L:next()  -- skip 'while'
        local test = parse_expr(0)
        L:expect(defs.TK_DO)
        local bs, bl = parse_block()
        local lastline = L._tk_line_out
        L:expect(defs.TK_END)
        local n = mknode(defs.NODE_WHILE_STMT, line, col)
        local nd = nodes:get(n)
        nd.data[0] = test
        nd.data[1] = bs
        nd.data[2] = bl
        nd.data[3] = lastline
        return n
    end

    local function parse_repeat_stmt()
        local line, col = L._tk_line_out, L._tk_col_out
        L:next()  -- skip 'repeat'
        local bs, bl = parse_block()
        L:expect(defs.TK_UNTIL)
        local test = parse_expr(0)
        local n = mknode(defs.NODE_REPEAT_STMT, line, col)
        local nd = nodes:get(n)
        nd.data[0] = test
        nd.data[1] = bs
        nd.data[2] = bl
        return n
    end

    local function parse_for_stmt()
        local line, col = L._tk_line_out, L._tk_col_out
        L:next()  -- skip 'for'
        local name_id = L.val
        L:expect(defs.TK_NAME)
        if L.tk == defs.TK_ASSIGN then
            -- Numeric for: for name = init, limit [, step] do ... end
            L:next()
            local init = parse_expr(0)
            L:expect(defs.TK_COMMA)
            local limit = parse_expr(0)
            local step = -1
            if L:opt(defs.TK_COMMA) then
                step = parse_expr(0)
            end
            L:expect(defs.TK_DO)
            local bs, bl = parse_block()
            L:expect(defs.TK_END)
            local n = mknode(defs.NODE_FOR_NUM, line, col)
            local nd = nodes:get(n)
            nd.data[0] = name_id
            nd.data[1] = init
            nd.data[2] = limit
            nd.data[3] = step
            nd.data[4] = bs
            nd.data[5] = bl
            return n
        else
            -- Generic for: for name1, name2, ... in exprlist do ... end
            -- Names are intern IDs — safe for direct push
            local nm = lists:mark()
            lists:push(name_id)
            while L:opt(defs.TK_COMMA) do
                lists:push(L.val)
                L:expect(defs.TK_NAME)
            end
            local ns, nl = lists:since(nm)
            L:expect(defs.TK_IN)
            local es, el = parse_expr_list()
            L:expect(defs.TK_DO)
            local bs, bl = parse_block()
            L:expect(defs.TK_END)
            local n = mknode(defs.NODE_FOR_IN, line, col)
            local nd = nodes:get(n)
            nd.data[0] = ns
            nd.data[1] = nl
            nd.data[2] = es
            nd.data[3] = el
            nd.data[4] = bs
            nd.data[5] = bl
            return n
        end
    end

    local function parse_do_stmt()
        local line, col = L._tk_line_out, L._tk_col_out
        L:next()  -- skip 'do'
        local bs, bl = parse_block()
        local lastline = L._tk_line_out
        L:expect(defs.TK_END)
        local n = mknode(defs.NODE_DO_STMT, line, col)
        local nd = nodes:get(n)
        nd.data[0] = bs
        nd.data[1] = bl
        nd.data[2] = lastline
        return n
    end

    local function parse_return_stmt()
        local line, col = L._tk_line_out, L._tk_col_out
        L:next()  -- skip 'return'
        local rs, rl = 0, 0
        if not is_block_end() and L.tk ~= defs.TK_SEMICOLON then
            rs, rl = parse_expr_list()
        end
        L:opt(defs.TK_SEMICOLON)
        local n = mknode(defs.NODE_RETURN_STMT, line, col)
        nodes:get(n).data[0] = rs
        nodes:get(n).data[1] = rl
        return n
    end

    local function parse_local_stmt()
        local line, col = L._tk_line_out, L._tk_col_out
        L:next()  -- skip 'local'
        if L.tk == defs.TK_FUNCTION then
            -- local function name(...) ... end
            local fline, fcol = L._tk_line_out, L._tk_col_out
            L:next()  -- skip 'function'
            local name_id = L.val
            L:expect(defs.TK_NAME)
            local name_node = mknode(defs.NODE_IDENTIFIER, fline, fcol)
            nodes:get(name_node).data[0] = name_id
            local ps, pl, bs, bl, lastline, has_vararg =
                parse_params_and_body(false)
            local n = mknode(defs.NODE_FUNC_DECL, line, col)
            local nd = nodes:get(n)
            nd.data[0] = name_node
            nd.data[1] = ps
            nd.data[2] = pl
            nd.data[3] = bs
            nd.data[4] = bl
            nd.data[5] = lastline
            nd.flags = defs.FLAG_LOCAL
            if has_vararg then nd.flags = bor(nd.flags, defs.FLAG_VARARG) end
            return n
        end
        -- local name1, name2, ... [= expr1, expr2, ...]
        -- Names are intern IDs — safe for direct push
        local nm = lists:mark()
        lists:push(L.val)
        L:expect(defs.TK_NAME)
        while L:opt(defs.TK_COMMA) do
            lists:push(L.val)
            L:expect(defs.TK_NAME)
        end
        local ns, nl = lists:since(nm)
        local es, el = 0, 0
        if L:opt(defs.TK_ASSIGN) then
            es, el = parse_expr_list()
        end
        local n = mknode(defs.NODE_LOCAL_STMT, line, col)
        local nd = nodes:get(n)
        nd.data[0] = ns
        nd.data[1] = nl
        nd.data[2] = es
        nd.data[3] = el
        return n
    end

    local function parse_func_decl()
        local line, col = L._tk_line_out, L._tk_col_out
        L:next()  -- skip 'function'
        -- Parse function name: Name {'.' Name} [':' Name]
        local nline, ncol = L._tk_line_out, L._tk_col_out
        local name_node = mknode(defs.NODE_IDENTIFIER, nline, ncol)
        nodes:get(name_node).data[0] = L.val
        L:expect(defs.TK_NAME)
        local is_method = false
        while L.tk == defs.TK_DOT do
            local dl, dc = L._tk_line_out, L._tk_col_out
            L:next()
            local field_id = L.val
            L:expect(defs.TK_NAME)
            local n = mknode(defs.NODE_FIELD_EXPR, dl, dc)
            nodes:get(n).data[0] = name_node
            nodes:get(n).data[1] = field_id
            name_node = n
        end
        if L.tk == defs.TK_COLON then
            local dl, dc = L._tk_line_out, L._tk_col_out
            L:next()
            local method_id = L.val
            L:expect(defs.TK_NAME)
            local n = mknode(defs.NODE_FIELD_EXPR, dl, dc)
            nodes:get(n).data[0] = name_node
            nodes:get(n).data[1] = method_id
            name_node = n
            is_method = true
        end
        local ps, pl, bs, bl, lastline, has_vararg =
            parse_params_and_body(is_method)
        local n = mknode(defs.NODE_FUNC_DECL, line, col)
        local nd = nodes:get(n)
        nd.data[0] = name_node
        nd.data[1] = ps
        nd.data[2] = pl
        nd.data[3] = bs
        nd.data[4] = bl
        nd.data[5] = lastline
        if has_vararg then nd.flags = defs.FLAG_VARARG end
        return n
    end

    local function parse_expr_or_assign()
        local line, col = L._tk_line_out, L._tk_col_out
        local first = parse_suffixed_expr()
        if L.tk == defs.TK_COMMA or L.tk == defs.TK_ASSIGN then
            -- Assignment: collect targets, then parse RHS
            local targets = { first }
            while L:opt(defs.TK_COMMA) do
                targets[#targets + 1] = parse_suffixed_expr()
            end
            L:expect(defs.TK_ASSIGN)
            local ts, tl = flush_list(targets)
            local es, el = parse_expr_list()
            local n = mknode(defs.NODE_ASSIGN_STMT, line, col)
            local nd = nodes:get(n)
            nd.data[0] = ts
            nd.data[1] = tl
            nd.data[2] = es
            nd.data[3] = el
            return n
        else
            -- Expression statement (function call)
            local n = mknode(defs.NODE_EXPR_STMT, line, col)
            nodes:get(n).data[0] = first
            return n
        end
    end

    parse_stmt = function()
        while L:opt(defs.TK_SEMICOLON) do end
        local tk = L.tk
        if tk == defs.TK_IF then return parse_if_stmt()
        elseif tk == defs.TK_WHILE then return parse_while_stmt()
        elseif tk == defs.TK_DO then return parse_do_stmt()
        elseif tk == defs.TK_FOR then return parse_for_stmt()
        elseif tk == defs.TK_REPEAT then return parse_repeat_stmt()
        elseif tk == defs.TK_FUNCTION then return parse_func_decl()
        elseif tk == defs.TK_LOCAL then return parse_local_stmt()
        elseif tk == defs.TK_RETURN then return parse_return_stmt()
        elseif tk == defs.TK_BREAK then
            local n = mknode(defs.NODE_BREAK_STMT)
            L:next()
            return n
        elseif tk == defs.TK_GOTO then
            local gl, gc = L._tk_line_out, L._tk_col_out
            L:next()
            local label_id = L.val
            L:expect(defs.TK_NAME)
            local n = mknode(defs.NODE_GOTO_STMT, gl, gc)
            nodes:get(n).data[0] = label_id
            return n
        elseif tk == defs.TK_LABEL then
            local ll, lc = L._tk_line_out, L._tk_col_out
            L:next()  -- skip '::'
            local label_id = L.val
            L:expect(defs.TK_NAME)
            L:expect(defs.TK_LABEL)  -- closing '::'
            local n = mknode(defs.NODE_LABEL_STMT, ll, lc)
            nodes:get(n).data[0] = label_id
            return n
        else
            return parse_expr_or_assign()
        end
    end

    -------------------------------------------------------------------
    -- Parse chunk (top-level)
    -------------------------------------------------------------------

    local bs, bl = parse_block()
    if L.tk ~= defs.TK_EOF then
        parse_error("expected <eof>")
    end
    local root = mknode(defs.NODE_CHUNK, 1, 1)
    local nd = nodes:get(root)
    nd.data[0] = bs
    nd.data[1] = bl
    nd.data[2] = intern_mod.intern(pool, filename)
    nd.data[3] = L.line

    return {
        nodes = nodes,
        lists = lists,
        pool = pool,
        root = root,
        lexer = L,
    }
end

return M
