-- lib/check_kind/init.lua
-- Checker #1: the value/kind checker.
--
-- This is the FIRST of crescent's many small, single-purpose typecheckers.
-- It is standalone — it does NOT use or extend the v5 typechecker's solver,
-- op_sem, or constrain machinery. See docs/checkers/value-kind.md for the
-- derivation and the governing "one checker per question" principle.
--
-- The one question it answers:
--   "Is every value used as the KIND that the operation requires?"
--
-- It catches kind-level misuse before runtime: calling a non-function,
-- indexing a non-table, arithmetic/concat on the wrong atom, using a
-- possibly-nil value where non-nil is required, and passing the wrong kind
-- to a function or operator.
--
-- It reuses the existing lexer (lib.type.static.lex) and Lua parser
-- (lib.type.static.parse) for the AST, and the existing annotation grammar
-- parser (lib.type.static.ann) for `--:` / `--::` type expressions. It does
-- NOT invent new annotation syntax and does NOT write its own Lua parser.
--
-- Error style follows docs/conventions.md: data errors are returned as a list
-- of diagnostics via `(result, errs)`; the function never throws on bad input
-- Lua (parse errors are returned as diagnostics, not raised).

if not package.path:find("?/init.lua", 1, true) then
    package.path = package.path .. ";./?/init.lua"
end

local band       = require("bit").band

local defs       = require("lib.type.static.defs")
local parse_mod  = require("lib.type.static.parse")
local ann_mod    = require("lib.type.static.ann")
local intern_mod = require("lib.type.static.intern")
local types_mod  = require("lib.type.static.types")

local kinds   = require("lib.check_kind.kinds")
local lower   = require("lib.check_kind.lower")

local M = {}

-- Short names for the value-model constructors (see kinds.lua).
local K       = kinds  -- kinds.boolean, kinds.number, ... constructors & singletons
local NIL     = kinds.NIL
local UNKNOWN = kinds.UNKNOWN
local NEVER   = kinds.NEVER

---------------------------------------------------------------------------
-- Built-in operator arrows (operators are arrows too — the propagation
-- engine is the same for functions and operators).
---------------------------------------------------------------------------

-- Arithmetic: (number, number) -> number. `..` is (string|number,...) -> string
-- but for v1 we require both operands to be string (concat). Comparisons that
-- are kind-checked: < <= > >= require (number, number) OR (string, string);
-- we accept number,number for simplicity in v1 (note: string ordering DEFERRED).
local ARITH_OPS = {
    [defs.OP_ADD] = true, [defs.OP_SUB] = true, [defs.OP_MUL] = true,
    [defs.OP_DIV] = true, [defs.OP_MOD] = true, [defs.OP_POW] = true,
}
local ORDER_OPS = {
    [defs.OP_LT] = true, [defs.OP_LE] = true,
    [defs.OP_GT] = true, [defs.OP_GE] = true,
}

---------------------------------------------------------------------------
-- Checker state
---------------------------------------------------------------------------

--: (string, string | nil) -> { result: unknown, errs: unknown } | (nil, string)
function M.check_string(source, filename)
    filename = filename or "?"

    -- Parse the Lua source into the flat AST arena (reused parser).
    local ok, parsed = pcall(parse_mod.parse, source, filename)
    if not ok then
        -- A parse failure is a syntax error in the input, not a kind error.
        -- Surface it as a single diagnostic so callers get a uniform shape.
        return { result = nil, errs = { { line = 0, col = 0,
            msg = "parse error: " .. tostring(parsed) } } }
    end

    local nodes = parsed.nodes
    local lists = parsed.lists
    local pool  = parsed.pool
    local root  = parsed.root
    local L     = parsed.lexer

    -- Parse all captured annotations (reused annotation grammar parser), then
    -- lower the small slice we support into our value model.
    local ann_res = ann_mod.parse_annotations(L.annotations, pool, filename)

    -- Diagnostics accumulator.
    local errs = {}
    local function report(line, col, msg)
        errs[#errs + 1] = { line = line or 0, col = col or 0, msg = msg }
    end

    -- Surface annotation parse errors (e.g. malformed type expressions) as
    -- diagnostics rather than dropping them.
    for _, pe in ipairs(ann_res.parse_errors or {}) do
        report(pe.line, pe.col, "annotation: " .. pe.msg)
    end

    -- annotation type_id (in ann arena) -> our value-model type. We lower lazily.
    local lower_ctx = lower.new(ann_res, pool, types_mod, defs, kinds)

    -- Map: source line -> lowered annotation type (for ANN_TYPE) or
    -- { decl = name_id, ty = ... } for ANN_DECL. We index by the annotation's
    -- own line; a statement on line L consults its preceding line (L-1), since
    -- `--:` is a preceding-line annotation.
    local line_ann = {}        -- ann-line -> lowered type (preceding-line --: T)
    local decl_ann = {}        -- name_id -> lowered type (--:: declare Name = T)
    for line, res in pairs(ann_res.results) do
        if res.kind == defs.ANN_TYPE then
            local lty = lower_ctx.lower(res.type_id)
            if lty then line_ann[line] = lty end
        elseif res.kind == defs.ANN_DECL and res.decl_var and res.name_id then
            local lty = lower_ctx.lower(res.type_id)
            if lty then decl_ann[res.name_id] = lty end
        end
    end

    ----------------------------------------------------------------------
    -- Scope: maps intern id -> value-model type. Block-scoped via a chain.
    ----------------------------------------------------------------------
    local function new_scope(parent)
        return { vars = {}, parent = parent }
    end
    local function scope_lookup(scope, name_id)
        local s = scope
        while s do
            local v = s.vars[name_id]
            if v ~= nil then return v end
            s = s.parent
        end
        return nil
    end
    local function scope_set(scope, name_id, ty)
        scope.vars[name_id] = ty
    end

    -- Seed the top scope with `--:: declare Name = T` globals.
    local top = new_scope(nil)
    for name_id, ty in pairs(decl_ann) do
        top.vars[name_id] = ty
    end

    ----------------------------------------------------------------------
    -- Node access helpers.
    ----------------------------------------------------------------------
    local function n_get(nid) return nodes:get(nid) end
    local function list_at(start, i) return lists:get(start + i) end

    -- preceding_ann: the `--: T` annotation directly above a node at `line`.
    local function preceding_ann(line) return line_ann[line - 1] end

    -- Forward declarations.
    local infer_expr, check_block

    ----------------------------------------------------------------------
    -- Subtyping over the value model. Producer <: consumer.
    -- Sound and total: only the cheap, decidable relation. UNKNOWN is the top
    -- (everything is a subtype of it) but using an UNKNOWN value where a
    -- concrete kind is required is rejected at the *use site*, not here.
    ----------------------------------------------------------------------
    local is_subtype = kinds.is_subtype

    ----------------------------------------------------------------------
    -- Use-site requirement: demand that `ty` is usable as a non-nil value of
    -- the given kind tag. Returns true, or false + a legible reason.
    ----------------------------------------------------------------------

    -- Require that `ty` is non-nil (the value is present).
    local function require_present(ty, what, line, col)
        if kinds.is_nilable(ty) then
            report(line, col, what .. " requires a non-nil value, but the value may be nil ("
                .. kinds.tostr(ty) .. ")")
            return false
        end
        return true
    end

    -- Require that `ty` is a function we can call. Returns the function type
    -- (for return propagation) or nil.
    local function require_callable(ty, line, col)
        if not require_present(ty, "call", line, col) then return nil end
        if ty.k == kinds.K_UNKNOWN then
            report(line, col, "call requires a function, but the value's kind is `unknown` — annotate it")
            return nil
        end
        if ty.k ~= kinds.K_FUNCTION then
            report(line, col, "call requires a function, but got `" .. kinds.tostr(ty) .. "`")
            return nil
        end
        return ty
    end

    -- Require that `ty` is a table we can index.
    local function require_indexable(ty, line, col)
        if not require_present(ty, "index", line, col) then return false end
        if ty.k == kinds.K_UNKNOWN then
            report(line, col, "index requires a table, but the value's kind is `unknown` — annotate it")
            return false
        end
        if ty.k ~= kinds.K_TABLE then
            report(line, col, "index requires a table, but got `" .. kinds.tostr(ty) .. "`")
            return false
        end
        return true
    end

    -- Require that `ty` is usable as a number (for arithmetic / unary minus).
    local function require_number(ty, where, line, col)
        if not require_present(ty, where, line, col) then return false end
        if ty.k == kinds.K_UNKNOWN then
            report(line, col, where .. " requires a number, but the value's kind is `unknown` — annotate it")
            return false
        end
        if not (ty.k == kinds.K_NUMBER) then
            report(line, col, where .. " requires a number, but got `" .. kinds.tostr(ty) .. "`")
            return false
        end
        return true
    end

    -- Require that `ty` is usable as a string (for concat / length).
    local function require_string(ty, where, line, col)
        if not require_present(ty, where, line, col) then return false end
        if ty.k == kinds.K_UNKNOWN then
            report(line, col, where .. " requires a string, but the value's kind is `unknown` — annotate it")
            return false
        end
        if not (ty.k == kinds.K_STRING) then
            report(line, col, where .. " requires a string, but got `" .. kinds.tostr(ty) .. "`")
            return false
        end
        return true
    end

    ----------------------------------------------------------------------
    -- Expression inference. Returns a value-model type. Always terminates:
    -- the AST is finite and we recurse strictly into children.
    ----------------------------------------------------------------------
    infer_expr = function(nid, scope)
        local n = n_get(nid)
        local kind = n.kind
        local line, col = n.line, n.col

        if kind == defs.NODE_LITERAL then
            local lk = n.data[0]
            if lk == defs.LIT_NIL then return NIL end
            if lk == defs.LIT_BOOLEAN then return K.boolean() end
            if lk == defs.LIT_STRING then return K.string() end
            -- LIT_NUMBER / LIT_INTEGER both fold to the `number` atom (the
            -- integer/float distinction is DEFERRED).
            return K.number()

        elseif kind == defs.NODE_VARARG_EXPR then
            -- `...` — its element kinds are not locally decidable. Demand a
            -- decision elsewhere; treat as unknown here.
            return UNKNOWN

        elseif kind == defs.NODE_IDENTIFIER then
            local name_id = n.data[0]
            local ty = scope_lookup(scope, name_id)
            if ty == nil then
                -- An undeclared name. Under the no-ambient-globals assumption,
                -- its kind is not known; demand a decision (annotation/decl).
                return UNKNOWN
            end
            return ty

        elseif kind == defs.NODE_FUNC_EXPR then
            -- A function literal. Without a `--:` annotation we cannot cheaply
            -- infer the parameter kinds; record it as a function whose arrow is
            -- unknown (callable, but args/returns unknown). We still check the
            -- body with params bound to unknown.
            local fty = K.fn_unknown()
            -- Check the body so kind errors inside are still caught.
            local fscope = new_scope(scope)
            local ps, pl = n.data[0], n.data[1]
            for i = 0, pl - 1 do
                scope_set(fscope, list_at(ps, i), UNKNOWN)
            end
            check_block(n.data[2], n.data[3], fscope, nil)
            return fty

        elseif kind == defs.NODE_TABLE_EXPR then
            -- A table constructor. We model it minimally as the `table` kind.
            -- Field SHAPES are DEFERRED to a later checker, so we still infer
            -- the field value expressions (to catch kind errors inside them).
            local fs, fl = n.data[0], n.data[1]
            for i = 0, fl - 1 do
                local fnid = list_at(fs, i)
                local fn = n_get(fnid)
                if fn.data[2] == defs.TFIELD_COMPUTED then
                    infer_expr(fn.data[0], scope)
                end
                infer_expr(fn.data[1], scope)
            end
            return K.table()

        elseif kind == defs.NODE_FIELD_EXPR then
            -- obj.field — requires obj to be a table.
            local objty = infer_expr(n.data[0], scope)
            require_indexable(objty, line, col)
            -- Field SHAPES deferred: a read yields unknown, possibly absent.
            return kinds.as_nilable(UNKNOWN)

        elseif kind == defs.NODE_INDEX_EXPR then
            -- obj[key] — requires obj to be a table. (Key kind is unconstrained
            -- in v1; index-signature checking is DEFERRED.)
            local objty = infer_expr(n.data[0], scope)
            require_indexable(objty, line, col)
            infer_expr(n.data[1], scope)
            return kinds.as_nilable(UNKNOWN)

        elseif kind == defs.NODE_CALL_EXPR then
            local calleety = infer_expr(n.data[0], scope)
            local fty = require_callable(calleety, line, col)
            -- Infer + check arguments against the arrow's parameter kinds.
            local as, al = n.data[1], n.data[2]
            local argtys = {}
            for i = 0, al - 1 do
                argtys[i + 1] = infer_expr(list_at(as, i), scope)
            end
            if fty and fty.params then
                for i = 1, #fty.params do
                    local want = fty.params[i]
                    local got = argtys[i]
                    if got == nil then
                        -- Missing argument where a non-nil kind is required.
                        if not kinds.is_nilable(want) and want.k ~= kinds.K_UNKNOWN then
                            report(line, col, "argument #" .. i .. " is missing, but `"
                                .. kinds.tostr(want) .. "` is required")
                        end
                    elseif not is_subtype(got, want) then
                        report(line, col, "argument #" .. i .. " expects `"
                            .. kinds.tostr(want) .. "`, but got `" .. kinds.tostr(got) .. "`")
                    end
                end
            end
            if fty and fty.ret then return fty.ret end
            return UNKNOWN

        elseif kind == defs.NODE_METHOD_CALL then
            -- obj:m(...) — requires obj to be a table; method kind deferred.
            local objty = infer_expr(n.data[0], scope)
            require_indexable(objty, line, col)
            local as, al = n.data[2], n.data[3]
            for i = 0, al - 1 do infer_expr(list_at(as, i), scope) end
            return UNKNOWN

        elseif kind == defs.NODE_CAST_EXPR then
            -- `expr --[[: T]]` — a checked cast. We infer the inner expr (to
            -- catch errors), then adopt the cast's declared type. Full
            -- subtyping enforcement of the cast is DEFERRED; we trust the
            -- annotation as the demanded decision.
            infer_expr(n.data[0], scope)
            local cast_id = n.data[1]
            local res = ann_res.results[cast_id]
            if res and res.kind == defs.ANN_TYPE then
                local lty = lower_ctx.lower(res.type_id)
                if lty then return lty end
            end
            return UNKNOWN

        elseif kind == defs.NODE_UNARY_EXPR then
            local op = n.data[0]
            local operandty = infer_expr(n.data[1], scope)
            if op == defs.OP_UNM then
                require_number(operandty, "unary minus", line, col)
                return K.number()
            elseif op == defs.OP_LEN then
                -- `#x` requires a string or a table. v1: require string OR table.
                if not require_present(operandty, "length `#`", line, col) then
                    return K.number()
                end
                if operandty.k ~= kinds.K_STRING and operandty.k ~= kinds.K_TABLE
                    and operandty.k ~= kinds.K_UNKNOWN then
                    report(line, col, "length `#` requires a string or table, but got `"
                        .. kinds.tostr(operandty) .. "`")
                elseif operandty.k == kinds.K_UNKNOWN then
                    report(line, col, "length `#` requires a string or table, but the value's kind is `unknown` — annotate it")
                end
                return K.number()
            elseif op == defs.OP_NOT then
                -- `not x` accepts any value and yields boolean.
                return K.boolean()
            end
            return UNKNOWN

        elseif kind == defs.NODE_BINARY_EXPR then
            local op = n.data[0]
            local lty = infer_expr(n.data[1], scope)
            local rty = infer_expr(n.data[2], scope)
            if ARITH_OPS[op] then
                require_number(lty, "arithmetic", line, col)
                require_number(rty, "arithmetic", line, col)
                return K.number()
            elseif op == defs.OP_CONCAT then
                require_string(lty, "concat `..`", line, col)
                require_string(rty, "concat `..`", line, col)
                return K.string()
            elseif ORDER_OPS[op] then
                -- Ordered comparison. v1: require both numbers (string ordering
                -- DEFERRED). Result is boolean.
                require_number(lty, "comparison", line, col)
                require_number(rty, "comparison", line, col)
                return K.boolean()
            elseif op == defs.OP_EQ or op == defs.OP_NE then
                -- `==` / `~=` accept any two values; result boolean.
                return K.boolean()
            elseif op == defs.OP_AND then
                -- `a and b` : result is b's kind, or a's falsy kinds. Minimal
                -- join: union of (a narrowed false-ish) and b. We approximate
                -- with the join of both operand types (sound, may be loose).
                return kinds.join(lty, rty)
            elseif op == defs.OP_OR then
                -- `a or b` : a (truthy) joined with b. Approximate with join.
                return kinds.join(lty, rty)
            end
            return UNKNOWN
        end

        -- Unknown / unsupported expression node: demand nothing, yield unknown.
        return UNKNOWN
    end

    ----------------------------------------------------------------------
    -- Statement / block checking.
    -- `ret_ty`: the declared return type of the enclosing function (or nil).
    ----------------------------------------------------------------------
    local function check_stmt(nid, scope, ret_ty)
        local n = n_get(nid)
        local kind = n.kind
        local line, col = n.line, n.col

        if kind == defs.NODE_LOCAL_STMT then
            -- local n1, n2 = e1, e2 [with preceding --: T on the same line]
            local ns, nl = n.data[0], n.data[1]
            local es, el = n.data[2], n.data[3]
            -- A preceding-line annotation declares the kind of the first name.
            local ann = preceding_ann(line)
            for i = 0, nl - 1 do
                local name_id = list_at(ns, i)
                local val_ty
                if i < el then
                    val_ty = infer_expr(list_at(es, i), scope)
                else
                    -- No initializer: the value is absent (nil).
                    val_ty = NIL
                end
                if i == 0 and ann then
                    -- The annotation is the demanded decision; check the value
                    -- against it, then bind the variable at the annotated kind.
                    if val_ty and i < el and not is_subtype(val_ty, ann) then
                        report(line, col, "local binding expects `" .. kinds.tostr(ann)
                            .. "`, but the value is `" .. kinds.tostr(val_ty) .. "`")
                    end
                    scope_set(scope, name_id, ann)
                else
                    scope_set(scope, name_id, val_ty or UNKNOWN)
                end
            end
            -- Infer any extra initializers (for nested kind errors).
            for i = nl, el - 1 do infer_expr(list_at(es, i), scope) end

        elseif kind == defs.NODE_ASSIGN_STMT then
            local ts, tl = n.data[0], n.data[1]
            local es, el = n.data[2], n.data[3]
            for i = 0, el - 1 do
                local val_ty = infer_expr(list_at(es, i), scope)
                if i < tl then
                    local tnid = list_at(ts, i)
                    local tn = n_get(tnid)
                    if tn.kind == defs.NODE_IDENTIFIER then
                        local name_id = tn.data[0]
                        local cur = scope_lookup(scope, name_id)
                        if cur ~= nil and not is_subtype(val_ty, cur) then
                            report(tn.line, tn.col, "assignment to `"
                                .. (intern_mod.get(pool, name_id) or "?")
                                .. "` expects `" .. kinds.tostr(cur)
                                .. "`, but the value is `" .. kinds.tostr(val_ty) .. "`")
                        elseif cur == nil then
                            scope_set(scope, name_id, val_ty)
                        end
                    else
                        -- Target is a field/index — check the base is a table.
                        infer_expr(tnid, scope)
                    end
                end
            end

        elseif kind == defs.NODE_FUNC_DECL then
            -- function name(...) ... end  /  local function name(...) ... end
            local name_node = n_get(n.data[0])
            local fty
            local ann = preceding_ann(line)
            if ann and ann.k == kinds.K_FUNCTION then
                fty = ann
            else
                fty = K.fn_unknown()
            end
            -- Bind the name (so recursion & later refs see a function kind).
            if name_node.kind == defs.NODE_IDENTIFIER then
                scope_set(scope, name_node.data[0], fty)
            end
            -- Check the body with params bound to their declared kinds (if the
            -- annotation gives an arrow) or unknown otherwise.
            local fscope = new_scope(scope)
            local ps, pl = n.data[1], n.data[2]
            for i = 0, pl - 1 do
                local pty = UNKNOWN
                if fty.params and fty.params[i + 1] then pty = fty.params[i + 1] end
                scope_set(fscope, list_at(ps, i), pty)
            end
            check_block(n.data[3], n.data[4], fscope, fty.ret)

        elseif kind == defs.NODE_RETURN_STMT then
            local es, el = n.data[0], n.data[1]
            local first_ty
            for i = 0, el - 1 do
                local t = infer_expr(list_at(es, i), scope)
                if i == 0 then first_ty = t end
            end
            if ret_ty then
                if el == 0 then
                    if not kinds.is_nilable(ret_ty) and ret_ty.k ~= kinds.K_UNKNOWN
                        and ret_ty.k ~= kinds.K_NEVER then
                        report(line, col, "return expects `" .. kinds.tostr(ret_ty)
                            .. "`, but nothing is returned")
                    end
                elseif first_ty and not is_subtype(first_ty, ret_ty) then
                    report(line, col, "return expects `" .. kinds.tostr(ret_ty)
                        .. "`, but got `" .. kinds.tostr(first_ty) .. "`")
                end
            end

        elseif kind == defs.NODE_IF_STMT then
            -- Branch join (minimal narrowing): check each clause's block in its
            -- own child scope; we do not merge variable rebindings back (sound:
            -- a narrowing only ever makes a type more specific within a branch).
            local cs, cl = n.data[0], n.data[1]
            for i = 0, cl - 1 do
                local clause = n_get(list_at(cs, i))
                infer_expr(clause.data[0], scope)  -- test expr (any kind ok)
                local cscope = new_scope(scope)
                -- Minimal narrowing: `if x then` makes x non-nil in the block.
                local test = n_get(clause.data[0])
                if test.kind == defs.NODE_IDENTIFIER then
                    local cur = scope_lookup(scope, test.data[0])
                    if cur ~= nil then
                        scope_set(cscope, test.data[0], kinds.strip_nil(cur))
                    end
                end
                check_block(clause.data[1], clause.data[2], cscope, ret_ty)
            end
            -- else block (present iff FLAG_HAS_ELSE is set in n.flags).
            if band(n.flags, defs.FLAG_HAS_ELSE) ~= 0 then
                local escope = new_scope(scope)
                check_block(n.data[2], n.data[3], escope, ret_ty)
            end

        elseif kind == defs.NODE_WHILE_STMT then
            infer_expr(n.data[0], scope)
            check_block(n.data[1], n.data[2], new_scope(scope), ret_ty)

        elseif kind == defs.NODE_REPEAT_STMT then
            check_block(n.data[1], n.data[2], new_scope(scope), ret_ty)
            infer_expr(n.data[0], scope)

        elseif kind == defs.NODE_DO_STMT then
            check_block(n.data[0], n.data[1], new_scope(scope), ret_ty)

        elseif kind == defs.NODE_FOR_NUM then
            -- for name = init, limit [, step] do ... end. The control vars must
            -- be numbers; the loop name is a number.
            require_number(infer_expr(n.data[1], scope), "numeric `for` init", line, col)
            require_number(infer_expr(n.data[2], scope), "numeric `for` limit", line, col)
            if band(n.flags, defs.FLAG_HAS_STEP) ~= 0 then
                require_number(infer_expr(n.data[3], scope), "numeric `for` step", line, col)
            end
            local fscope = new_scope(scope)
            scope_set(fscope, n.data[0], K.number())
            check_block(n.data[4], n.data[5], fscope, ret_ty)

        elseif kind == defs.NODE_FOR_IN then
            local es, el = n.data[2], n.data[3]
            for i = 0, el - 1 do infer_expr(list_at(es, i), scope) end
            local fscope = new_scope(scope)
            local ns, nl = n.data[0], n.data[1]
            for i = 0, nl - 1 do scope_set(fscope, list_at(ns, i), UNKNOWN) end
            check_block(n.data[4], n.data[5], fscope, ret_ty)

        elseif kind == defs.NODE_EXPR_STMT then
            infer_expr(n.data[0], scope)

        -- BREAK / GOTO / LABEL : no kind obligations.
        end
    end

    check_block = function(start, len, scope, ret_ty)
        for i = 0, len - 1 do
            check_stmt(list_at(start, i), scope, ret_ty)
        end
    end

    ----------------------------------------------------------------------
    -- Drive the check from the chunk root.
    ----------------------------------------------------------------------
    local rn = n_get(root)
    check_block(rn.data[0], rn.data[1], top, nil)

    -- Stable ordering: by line then col.
    table.sort(errs, function(a, b)
        if a.line ~= b.line then return a.line < b.line end
        return a.col < b.col
    end)

    return { result = { errs = errs }, errs = errs }
end

-- check: convenience wrapper returning just the diagnostics list.
--: (string, string | nil) -> { [integer]: { line: integer, col: integer, msg: string }, ... }
function M.check(source, filename)
    local res = M.check_string(source, filename)
    return res.errs or {}
end

return M
