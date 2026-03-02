-- lib/type/static/v2/types.lua
-- Type arena operations for the v2 typechecker.
-- Types are flat FFI TypeSlot entries accessed via integer IDs.
-- Union-find is used for type variables: TAG_VAR.data[2] is the parent
-- type_id (-1 = unbound root, >= 0 = bound to that ID).

local ffi = require("ffi")
local defs = require("lib.type.static.v2.defs")
local arena_mod = require("lib.type.static.v2.arena")
local intern_mod = require("lib.type.static.v2.intern")

local TAG_NIL          = defs.TAG_NIL
local TAG_BOOLEAN      = defs.TAG_BOOLEAN
local TAG_NUMBER       = defs.TAG_NUMBER
local TAG_STRING       = defs.TAG_STRING
local TAG_ANY          = defs.TAG_ANY
local TAG_NEVER        = defs.TAG_NEVER
local TAG_INTEGER      = defs.TAG_INTEGER
local TAG_LITERAL      = defs.TAG_LITERAL
local TAG_FUNCTION     = defs.TAG_FUNCTION
local TAG_TABLE        = defs.TAG_TABLE
local TAG_UNION        = defs.TAG_UNION
local TAG_INTERSECTION = defs.TAG_INTERSECTION
local TAG_VAR          = defs.TAG_VAR
local TAG_ROWVAR       = defs.TAG_ROWVAR
local TAG_TUPLE        = defs.TAG_TUPLE
local TAG_NOMINAL      = defs.TAG_NOMINAL
local TAG_MATCH_TYPE   = defs.TAG_MATCH_TYPE
local TAG_INTRINSIC    = defs.TAG_INTRINSIC
local TAG_TYPE_CALL    = defs.TAG_TYPE_CALL
local TAG_FORALL       = defs.TAG_FORALL
local TAG_SPREAD       = defs.TAG_SPREAD
local TAG_NAMED        = defs.TAG_NAMED
local TAG_CDATA        = defs.TAG_CDATA

local LIT_STRING  = defs.LIT_STRING
local LIT_NUMBER  = defs.LIT_NUMBER
local LIT_BOOLEAN = defs.LIT_BOOLEAN
local LIT_NIL     = defs.LIT_NIL

local FLAG_GENERIC = defs.FLAG_GENERIC

local M = {}

-- TypeSlot data layouts:
--
-- TAG_VAR / TAG_ROWVAR:
--   data[0] = unique var ID (for occurs check)
--   data[1] = level (for generalization)
--   data[2] = parent type_id (-1 = unbound root, >=0 = bound)
--   flags: FLAG_GENERIC if generalized
--
-- TAG_LITERAL:
--   data[0] = LIT_STRING/LIT_NUMBER/LIT_BOOLEAN/LIT_NIL
--   data[1] = for string/number: intern_id of value string
--             for boolean: 1=true, 0=false
--
-- TAG_FUNCTION:
--   data[0] = params_start (list pool)
--   data[1] = params_len (type_ids)
--   data[2] = returns_start (list pool)
--   data[3] = returns_len (type_ids)
--   data[4] = vararg_type_id (-1 = none)
--
-- TAG_TABLE:
--   data[0] = fields_start  (list pool, field_arena IDs)
--   data[1] = fields_len
--   data[2] = indexers_start (list pool, interleaved pairs: key_id, val_id, ...)
--   data[3] = indexers_len   (count of type_ids, so #pairs = len/2)
--   data[4] = row_var_id     (-1 = none)
--   data[5] = meta_start     (list pool, field_arena IDs for meta slots)
--   data[6] = meta_len
--
-- TAG_UNION / TAG_INTERSECTION / TAG_TUPLE:
--   data[0] = members_start
--   data[1] = members_len
--
-- TAG_NOMINAL:
--   data[0] = name_id (intern)
--   data[1] = identity (unique int)
--   data[2] = underlying type_id
--
-- TAG_NAMED:
--   data[0] = name_id (intern)
--   data[1] = args_start (type args in list pool)
--   data[2] = args_len
--
-- TAG_MATCH_TYPE:
--   data[0] = param type_id
--   data[1] = arms_start (pairs: pattern_id, result_id)
--   data[2] = arms_len
--
-- TAG_FORALL:
--   data[0] = type_params_start (name_ids)
--   data[1] = type_params_len
--   data[2] = body type_id
--
-- TAG_SPREAD:
--   data[0] = inner type_id
--
-- TAG_INTRINSIC:
--   data[0] = name_id
--
-- TAG_TYPE_CALL:
--   data[0] = callee_id
--   data[1] = args_start
--   data[2] = args_len

-- Singleton IDs (pre-allocated at fixed positions)
M.T_NIL     = 0
M.T_BOOLEAN = 1
M.T_NUMBER  = 2
M.T_STRING  = 3
M.T_ANY     = 4
M.T_NEVER   = 5
M.T_INTEGER = 6

local function alloc_zero(types, tag)
    local i = types:alloc()
    local t = types:get(i)
    t.tag = tag
    t.flags = 0
    t.reserved = 0
    t.data[0] = 0; t.data[1] = 0; t.data[2] = 0
    t.data[3] = 0; t.data[4] = 0; t.data[5] = 0; t.data[6] = 0
    return i
end

-- Create a new checker context.
-- pool: shared intern pool (from parse result)
function M.new_ctx(pool)
    local types  = arena_mod.new_type_arena(512)
    local fields = arena_mod.new_field_arena(256)
    local lists  = arena_mod.new_list_pool(1024)

    -- Pre-allocate singletons at fixed IDs 0-6
    alloc_zero(types, TAG_NIL)      -- 0
    alloc_zero(types, TAG_BOOLEAN)  -- 1
    alloc_zero(types, TAG_NUMBER)   -- 2
    alloc_zero(types, TAG_STRING)   -- 3
    alloc_zero(types, TAG_ANY)      -- 4
    alloc_zero(types, TAG_NEVER)    -- 5
    alloc_zero(types, TAG_INTEGER)  -- 6
    -- data[2] for singletons: -1 means "no parent" (they are concrete types, not vars)
    -- but we never call find() expecting to follow them, so it's fine to leave as 0

    local ctx = {
        types        = types,
        fields       = fields,
        lists        = lists,
        pool         = pool,
        var_counter  = 0,
        nominal_id   = 0,
        level        = 0,
        -- Singleton shortcuts
        T_NIL     = M.T_NIL,
        T_BOOLEAN = M.T_BOOLEAN,
        T_NUMBER  = M.T_NUMBER,
        T_STRING  = M.T_STRING,
        T_ANY     = M.T_ANY,
        T_NEVER   = M.T_NEVER,
        T_INTEGER = M.T_INTEGER,
    }
    return ctx
end

-- Allocate and zero-initialize a TypeSlot. Returns type_id.
function M.alloc_type(ctx, tag)
    return alloc_zero(ctx.types, tag)
end

-- Union-find with path compression.
-- For TAG_VAR / TAG_ROWVAR: follow data[2] chain until root.
-- For all other tags: return tid directly.
function M.find(ctx, tid)
    local types = ctx.types
    -- Find root
    local root = tid
    while true do
        local t = types:get(root)
        if t.tag ~= TAG_VAR and t.tag ~= TAG_ROWVAR then break end
        local parent = t.data[2]
        if parent == -1 then break end  -- unbound root
        root = parent
    end
    -- Path compression
    local cur = tid
    while cur ~= root do
        local t = types:get(cur)
        if t.tag ~= TAG_VAR and t.tag ~= TAG_ROWVAR then break end
        local parent = t.data[2]
        if parent == -1 then break end
        t.data[2] = root
        cur = parent
    end
    return root
end

-- Make a fresh type variable at the given level.
function M.make_var(ctx, level)
    ctx.var_counter = ctx.var_counter + 1
    local id = alloc_zero(ctx.types, TAG_VAR)
    local t = ctx.types:get(id)
    t.data[0] = ctx.var_counter    -- unique ID
    t.data[1] = level or ctx.level -- scope level
    t.data[2] = -1                 -- unbound
    return id
end

-- Make a fresh row variable at the given level.
function M.make_rowvar(ctx, level)
    ctx.var_counter = ctx.var_counter + 1
    local id = alloc_zero(ctx.types, TAG_ROWVAR)
    local t = ctx.types:get(id)
    t.data[0] = ctx.var_counter
    t.data[1] = level or ctx.level
    t.data[2] = -1
    return id
end

-- Make a literal type.
-- kind: LIT_STRING/LIT_NUMBER/LIT_BOOLEAN/LIT_NIL
-- val: intern_id (for string/number) or 1/0 (for boolean)
function M.make_literal(ctx, kind, val)
    local id = alloc_zero(ctx.types, TAG_LITERAL)
    local t = ctx.types:get(id)
    t.data[0] = kind
    t.data[1] = val or 0
    return id
end

-- Make a function type.
-- params, returns: Lua arrays of type_ids
-- vararg_id: type_id or -1 for no vararg
function M.make_func(ctx, params, returns, vararg_id)
    local m = ctx.lists:mark()
    for i = 1, #params do ctx.lists:push(params[i]) end
    local ps, pl = ctx.lists:since(m)
    m = ctx.lists:mark()
    for i = 1, #returns do ctx.lists:push(returns[i]) end
    local rs, rl = ctx.lists:since(m)
    local id = alloc_zero(ctx.types, TAG_FUNCTION)
    local t = ctx.types:get(id)
    t.data[0] = ps
    t.data[1] = pl
    t.data[2] = rs
    t.data[3] = rl
    t.data[4] = vararg_id ~= nil and vararg_id or -1
    return id
end

-- Make a FieldEntry and return its arena ID.
function M.make_field(ctx, name_id, type_id, optional)
    local fid = ctx.fields:alloc()
    local fe = ctx.fields:get(fid)
    fe.name_id = name_id
    fe.type_id = type_id
    fe.optional = optional and 1 or 0
    return fid
end

-- Make a table type.
-- field_ids: Lua array of field_arena IDs
-- indexer_pairs: flat Lua array of type_ids [key0, val0, key1, val1, ...]
-- row_var_id: type_id or -1
-- meta_field_ids: Lua array of field_arena IDs for __meta slots
function M.make_table(ctx, field_ids, indexer_pairs, row_var_id, meta_field_ids)
    field_ids    = field_ids    or {}
    indexer_pairs = indexer_pairs or {}
    meta_field_ids = meta_field_ids or {}

    local fs, fl = 0, 0
    if #field_ids > 0 then
        local m = ctx.lists:mark()
        for _, fid in ipairs(field_ids) do ctx.lists:push(fid) end
        fs, fl = ctx.lists:since(m)
    end
    local is, il = 0, 0
    if #indexer_pairs > 0 then
        local m = ctx.lists:mark()
        for _, tid in ipairs(indexer_pairs) do ctx.lists:push(tid) end
        is, il = ctx.lists:since(m)
    end
    local ms, ml = 0, 0
    if #meta_field_ids > 0 then
        local m = ctx.lists:mark()
        for _, fid in ipairs(meta_field_ids) do ctx.lists:push(fid) end
        ms, ml = ctx.lists:since(m)
    end

    local id = alloc_zero(ctx.types, TAG_TABLE)
    local t = ctx.types:get(id)
    t.data[0] = fs
    t.data[1] = fl
    t.data[2] = is
    t.data[3] = il
    t.data[4] = row_var_id ~= nil and row_var_id or -1
    t.data[5] = ms
    t.data[6] = ml
    return id
end

-- Make a union type. Flattens nested unions, removes never, short-circuits on any.
-- member_ids: Lua array of type_ids
function M.make_union(ctx, member_ids)
    local flat = {}
    local seen = {}
    for i = 1, #member_ids do
        local rtid = M.find(ctx, member_ids[i])
        local t = ctx.types:get(rtid)
        if t.tag == TAG_ANY then return ctx.T_ANY end
        if t.tag == TAG_UNION then
            local s, l = t.data[0], t.data[1]
            for j = s, s + l - 1 do
                local mid = ctx.lists:get(j)
                if not seen[mid] then seen[mid] = true; flat[#flat + 1] = mid end
            end
        elseif t.tag ~= TAG_NEVER then
            if not seen[rtid] then seen[rtid] = true; flat[#flat + 1] = rtid end
        end
    end
    if #flat == 0 then return ctx.T_NEVER end
    if #flat == 1 then return flat[1] end
    local m = ctx.lists:mark()
    for _, id in ipairs(flat) do ctx.lists:push(id) end
    local ms, ml = ctx.lists:since(m)
    local id = alloc_zero(ctx.types, TAG_UNION)
    local t = ctx.types:get(id)
    t.data[0] = ms
    t.data[1] = ml
    return id
end

-- Make an intersection type.
function M.make_intersection(ctx, member_ids)
    local flat = {}
    for i = 1, #member_ids do
        local rtid = M.find(ctx, member_ids[i])
        local t = ctx.types:get(rtid)
        if t.tag == TAG_INTERSECTION then
            local s, l = t.data[0], t.data[1]
            for j = s, s + l - 1 do
                flat[#flat + 1] = ctx.lists:get(j)
            end
        elseif t.tag ~= TAG_ANY then
            flat[#flat + 1] = rtid
        end
    end
    if #flat == 0 then return ctx.T_ANY end
    if #flat == 1 then return flat[1] end
    local m = ctx.lists:mark()
    for _, id in ipairs(flat) do ctx.lists:push(id) end
    local ms, ml = ctx.lists:since(m)
    local id = alloc_zero(ctx.types, TAG_INTERSECTION)
    local t = ctx.types:get(id)
    t.data[0] = ms
    t.data[1] = ml
    return id
end

-- Make a tuple type.
function M.make_tuple(ctx, elem_ids)
    local m = ctx.lists:mark()
    for i = 1, #elem_ids do ctx.lists:push(elem_ids[i]) end
    local es, el = ctx.lists:since(m)
    local id = alloc_zero(ctx.types, TAG_TUPLE)
    local t = ctx.types:get(id)
    t.data[0] = es
    t.data[1] = el
    return id
end

-- Make a nominal type.
function M.make_nominal(ctx, name_id, identity, underlying_id)
    local id = alloc_zero(ctx.types, TAG_NOMINAL)
    local t = ctx.types:get(id)
    t.data[0] = name_id
    t.data[1] = identity
    t.data[2] = underlying_id
    return id
end

-- T? = T | nil
function M.make_optional(ctx, tid)
    return M.make_union(ctx, { tid, ctx.T_NIL })
end

-- T[] = { [number]: T }
function M.make_array(ctx, elem_tid)
    return M.make_table(ctx, {}, { ctx.T_NUMBER, elem_tid }, -1, {})
end

-- Widen literal type to base type.
function M.widen(ctx, tid)
    tid = M.find(ctx, tid)
    local t = ctx.types:get(tid)
    if t.tag ~= TAG_LITERAL then return tid end
    local kind = t.data[0]
    if kind == LIT_STRING  then return ctx.T_STRING end
    if kind == LIT_NUMBER  then return ctx.T_NUMBER end
    if kind == LIT_BOOLEAN then return ctx.T_BOOLEAN end
    if kind == LIT_NIL     then return ctx.T_NIL end
    return tid
end

-- Check structural equality of two types (shallow, no binding).
function M.types_equal(ctx, a, b)
    a = M.find(ctx, a)
    b = M.find(ctx, b)
    if a == b then return true end
    local ta = ctx.types:get(a)
    local tb = ctx.types:get(b)
    if ta.tag ~= tb.tag then return false end
    local tag = ta.tag
    if tag == TAG_NIL or tag == TAG_BOOLEAN or tag == TAG_NUMBER
      or tag == TAG_INTEGER or tag == TAG_STRING
      or tag == TAG_ANY or tag == TAG_NEVER then
        return true  -- same tag = equal for primitives
    end
    if tag == TAG_LITERAL then
        return ta.data[0] == tb.data[0] and ta.data[1] == tb.data[1]
    end
    if tag == TAG_NOMINAL then
        return ta.data[1] == tb.data[1]  -- identity-based
    end
    return false  -- reference inequality for complex types
end

-- Look up a named field in a table type. Returns (FieldEntry*, field_arena_id) or nil.
function M.table_field(ctx, tbl_tid, name_id)
    local t = ctx.types:get(tbl_tid)  -- caller must have called find()
    for i = t.data[0], t.data[0] + t.data[1] - 1 do
        local fid = ctx.lists:get(i)
        local fe = ctx.fields:get(fid)
        if fe.name_id == name_id then return fe, fid end
    end
    return nil
end

-- Look up a named field in the meta slots of a table type.
function M.table_meta_field(ctx, tbl_tid, name_id)
    local t = ctx.types:get(tbl_tid)
    for i = t.data[5], t.data[5] + t.data[6] - 1 do
        local fid = ctx.lists:get(i)
        local fe = ctx.fields:get(fid)
        if fe.name_id == name_id then return fe, fid end
    end
    return nil
end

-- Subtract a type from a union (remove members matching exclude).
function M.subtract(ctx, tid, exclude_tid)
    tid = M.find(ctx, tid)
    exclude_tid = M.find(ctx, exclude_tid)
    local t = ctx.types:get(tid)
    if t.tag ~= TAG_UNION then
        if M.types_equal(ctx, tid, exclude_tid) then return ctx.T_NEVER end
        return tid
    end
    local remaining = {}
    for i = t.data[0], t.data[0] + t.data[1] - 1 do
        local mid = M.find(ctx, ctx.lists:get(i))
        if not M.types_equal(ctx, mid, exclude_tid) then
            remaining[#remaining + 1] = mid
        end
    end
    if #remaining == 0 then return ctx.T_NEVER end
    if #remaining == 1 then return remaining[1] end
    return M.make_union(ctx, remaining)
end

-- Narrow a union by field discriminant. positive=true: keep members where field COULD be lit_intern_id.
function M.narrow_by_field(ctx, tid, field_name_id, lit_intern_id, positive)
    tid = M.find(ctx, tid)
    local t = ctx.types:get(tid)
    if t.tag ~= TAG_UNION then
        -- Single type: check if field definitely doesn't/does match
        if t.tag == TAG_TABLE then
            local fe = M.table_field(ctx, tid, field_name_id)
            if fe then
                local frt = M.find(ctx, fe.type_id)
                local ft = ctx.types:get(frt)
                if ft.tag == TAG_LITERAL and ft.data[0] == LIT_STRING then
                    local definite = (ft.data[1] == lit_intern_id)
                    if positive and not definite then return ctx.T_NEVER end
                    if not positive and definite then return ctx.T_NEVER end
                end
            end
        end
        return tid
    end
    local result = {}
    for i = t.data[0], t.data[0] + t.data[1] - 1 do
        local mid = M.find(ctx, ctx.lists:get(i))
        local mt = ctx.types:get(mid)
        local definite_match = false
        local possible_match = true
        if mt.tag == TAG_TABLE then
            local fe = M.table_field(ctx, mid, field_name_id)
            if fe then
                local frt = M.find(ctx, fe.type_id)
                local ft = ctx.types:get(frt)
                if ft.tag == TAG_LITERAL and ft.data[0] == LIT_STRING then
                    definite_match = (ft.data[1] == lit_intern_id)
                    possible_match = definite_match
                end
            end
        elseif mt.tag ~= TAG_ANY and mt.tag ~= TAG_VAR then
            possible_match = false
        end
        if positive then
            if possible_match then result[#result + 1] = mid end
        else
            if not definite_match then result[#result + 1] = mid end
        end
    end
    if #result == 0 then return ctx.T_NEVER end
    if #result == 1 then return result[1] end
    return M.make_union(ctx, result)
end

-- Display a type as a human-readable string (cold path).
function M.display(ctx, tid, seen)
    if type(tid) ~= "number" then return "?" end
    tid = M.find(ctx, tid)
    local t = ctx.types:get(tid)
    local tag = t.tag

    if tag == TAG_NIL      then return "nil" end
    if tag == TAG_BOOLEAN  then return "boolean" end
    if tag == TAG_NUMBER   then return "number" end
    if tag == TAG_STRING   then return "string" end
    if tag == TAG_ANY      then return "any" end
    if tag == TAG_NEVER    then return "never" end
    if tag == TAG_INTEGER  then return "integer" end
    if tag == TAG_CDATA    then return "cdata" end

    if tag == TAG_VAR then
        if t.flags ~= 0 and (t.flags % 2) == 1 then  -- FLAG_GENERIC
            return "'" .. tostring(t.data[0])
        end
        return "'" .. tostring(t.data[0])
    end
    if tag == TAG_ROWVAR then
        return "...'" .. tostring(t.data[0])
    end

    if tag == TAG_LITERAL then
        local kind = t.data[0]
        if kind == LIT_NIL     then return "nil" end
        if kind == LIT_BOOLEAN then return t.data[1] == 1 and "true" or "false" end
        if kind == LIT_STRING  then
            local s = intern_mod.get(ctx.pool, t.data[1])
            return s and ('"' .. s .. '"') or '"?"'
        end
        if kind == LIT_NUMBER  then
            return intern_mod.get(ctx.pool, t.data[1]) or "number"
        end
    end

    if tag == TAG_FUNCTION then
        local parts = {}
        for i = t.data[0], t.data[0] + t.data[1] - 1 do
            parts[#parts + 1] = M.display(ctx, ctx.lists:get(i), seen)
        end
        if t.data[4] >= 0 then
            parts[#parts + 1] = "..." .. M.display(ctx, t.data[4], seen)
        end
        local rl = t.data[3]
        local ret
        if rl == 0 then
            ret = "()"
        elseif rl == 1 then
            ret = M.display(ctx, ctx.lists:get(t.data[2]), seen)
        else
            local rs = {}
            for i = t.data[2], t.data[2] + rl - 1 do
                rs[#rs + 1] = M.display(ctx, ctx.lists:get(i), seen)
            end
            ret = "(" .. table.concat(rs, ", ") .. ")"
        end
        return "(" .. table.concat(parts, ", ") .. ") -> " .. ret
    end

    if tag == TAG_TABLE then
        seen = seen or {}
        if seen[tid] then return "{...}" end
        seen[tid] = true
        local parts = {}
        -- fields
        local field_names = {}
        for i = t.data[0], t.data[0] + t.data[1] - 1 do
            local fid = ctx.lists:get(i)
            local fe = ctx.fields:get(fid)
            local name = intern_mod.get(ctx.pool, fe.name_id) or "?"
            field_names[#field_names + 1] = { name = name, fe = fe }
        end
        table.sort(field_names, function(a, b) return a.name < b.name end)
        for _, nf in ipairs(field_names) do
            local opt = nf.fe.optional == 1 and "?" or ""
            parts[#parts + 1] = nf.name .. opt .. ": " .. M.display(ctx, nf.fe.type_id, seen)
        end
        -- indexers
        local is, il = t.data[2], t.data[3]
        local i = is
        while i < is + il - 1 do
            local kt = M.display(ctx, ctx.lists:get(i), seen)
            local vt = M.display(ctx, ctx.lists:get(i + 1), seen)
            parts[#parts + 1] = "[" .. kt .. "]: " .. vt
            i = i + 2
        end
        -- meta
        local meta_names = {}
        for j = t.data[5], t.data[5] + t.data[6] - 1 do
            local fid = ctx.lists:get(j)
            local fe = ctx.fields:get(fid)
            local name = intern_mod.get(ctx.pool, fe.name_id) or "?"
            meta_names[#meta_names + 1] = { name = name, fe = fe }
        end
        table.sort(meta_names, function(a, b) return a.name < b.name end)
        for _, nf in ipairs(meta_names) do
            local opt = nf.fe.optional == 1 and "?" or ""
            parts[#parts + 1] = "#" .. nf.name .. opt .. ": " .. M.display(ctx, nf.fe.type_id, seen)
        end
        seen[tid] = nil
        if #parts == 0 then return "{}" end
        return "{ " .. table.concat(parts, ", ") .. " }"
    end

    if tag == TAG_UNION then
        local parts = {}
        for i = t.data[0], t.data[0] + t.data[1] - 1 do
            parts[#parts + 1] = M.display(ctx, ctx.lists:get(i), seen)
        end
        return table.concat(parts, " | ")
    end

    if tag == TAG_INTERSECTION then
        local parts = {}
        for i = t.data[0], t.data[0] + t.data[1] - 1 do
            parts[#parts + 1] = M.display(ctx, ctx.lists:get(i), seen)
        end
        return table.concat(parts, " & ")
    end

    if tag == TAG_TUPLE then
        local parts = {}
        for i = t.data[0], t.data[0] + t.data[1] - 1 do
            parts[#parts + 1] = M.display(ctx, ctx.lists:get(i), seen)
        end
        return "(" .. table.concat(parts, ", ") .. ")"
    end

    if tag == TAG_SPREAD then
        return "..." .. M.display(ctx, t.data[0], seen)
    end

    if tag == TAG_NOMINAL then
        return intern_mod.get(ctx.pool, t.data[0]) or "nominal"
    end

    if tag == TAG_NAMED then
        local name = intern_mod.get(ctx.pool, t.data[0]) or "?"
        local al = t.data[2]
        if al > 0 then
            local parts = {}
            for i = t.data[1], t.data[1] + al - 1 do
                parts[#parts + 1] = M.display(ctx, ctx.lists:get(i), seen)
            end
            return name .. "<" .. table.concat(parts, ", ") .. ">"
        end
        return name
    end

    if tag == TAG_MATCH_TYPE then
        return "match ... { ... }"
    end

    if tag == TAG_INTRINSIC then
        return "$" .. (intern_mod.get(ctx.pool, t.data[0]) or "?")
    end

    if tag == TAG_TYPE_CALL then
        local parts = {}
        for i = t.data[1], t.data[1] + t.data[2] - 1 do
            parts[#parts + 1] = M.display(ctx, ctx.lists:get(i), seen)
        end
        return M.display(ctx, t.data[0], seen) .. "(" .. table.concat(parts, ", ") .. ")"
    end

    if tag == TAG_FORALL then
        local parts = {}
        for i = t.data[0], t.data[0] + t.data[1] - 1 do
            parts[#parts + 1] = intern_mod.get(ctx.pool, ctx.lists:get(i)) or "?"
        end
        return "<" .. table.concat(parts, ", ") .. "> " .. M.display(ctx, t.data[2], seen)
    end

    return "?"
end

-- Map from Lua type() string to type_id singleton
function M.typeof_to_id(ctx, s)
    if s == "nil"      then return ctx.T_NIL end
    if s == "boolean"  then return ctx.T_BOOLEAN end
    if s == "number"   then return ctx.T_NUMBER end
    if s == "string"   then return ctx.T_STRING end
    if s == "table"    then return ctx.T_ANY end   -- unknown table type
    if s == "function" then return ctx.T_ANY end   -- unknown function type
    return ctx.T_ANY
end

return M
