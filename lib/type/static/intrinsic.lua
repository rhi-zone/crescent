-- lib/type/static/intrinsic.lua
-- Expansion logic for TAG_INTRINSIC type-level operations.
-- Called from constrain.lua's resolve_annotation_type when a TAG_TYPE_CALL
-- has a TAG_INTRINSIC callee.
--
-- Supported intrinsics:
--   $Keys<T>         — string literal union of field names in T
--   $EachUnion<T, F> — apply F to each member of union T, re-union results
--   $EachField<T, F> — apply F to each field descriptor of T, collect into table

local defs      = require("lib.type.static.defs")
local types_mod = require("lib.type.static.types")
local intern_mod = require("lib.type.static.intern")
local band       = require("bit").band

local TAG_TABLE        = defs.TAG_TABLE
local TAG_UNION        = defs.TAG_UNION
local TAG_MATCH_TYPE   = defs.TAG_MATCH_TYPE
local TAG_NAMED        = defs.TAG_NAMED
local TAG_ANY          = defs.TAG_ANY
local TAG_LITERAL      = defs.TAG_LITERAL

local LIT_STRING  = defs.LIT_STRING
local LIT_BOOLEAN = defs.LIT_BOOLEAN

local FLAG_OPTIONAL = defs.FLAG_OPTIONAL
local FLAG_READONLY = defs.FLAG_READONLY

local M = {}

-- ---------------------------------------------------------------------------
-- $Keys<T>
-- ---------------------------------------------------------------------------
-- Produce a string literal union of the named field names of T.
-- If T is not a table, returns T_NEVER.
local function expand_keys(ctx, arg_ids)
    if #arg_ids ~= 1 then
        return ctx.T_NEVER
    end
    local t_tid = types_mod.find(ctx, arg_ids[1])
    local t = ctx.types:get(t_tid)
    if t.tag ~= TAG_TABLE then
        return ctx.T_NEVER
    end
    local members = {}
    for i = t.data[0], t.data[0] + t.data[1] - 1 do
        local fid = ctx.lists:get(i)
        local fe  = ctx.fields:get(fid)
        if fe.name_id >= 0 then  -- skip spread markers (name_id == -1)
            local lit = types_mod.make_literal(ctx, LIT_STRING, fe.name_id)
            members[#members + 1] = lit
        end
    end
    if #members == 0 then return ctx.T_NEVER end
    return types_mod.make_union(ctx, members)
end

-- ---------------------------------------------------------------------------
-- $EachUnion<T, F>
-- ---------------------------------------------------------------------------
-- Apply type-level function F to each member of union T.  Re-union results.
-- F must be a TAG_MATCH_TYPE or a TAG_NAMED alias.
-- For TAG_MATCH_TYPE: wrap each arm as a new match with just that member as param.
-- For TAG_NAMED: apply with one arg (the member).
local function apply_type_fn(ctx, fn_tid, member_tid)
    fn_tid = types_mod.find(ctx, fn_tid)
    local ft = ctx.types:get(fn_tid)

    if ft.tag == TAG_MATCH_TYPE then
        -- Build a new TAG_MATCH_TYPE with param=member_tid, same arms
        local id = types_mod.alloc_type(ctx, TAG_MATCH_TYPE)
        local mtt = ctx.types:get(id)
        mtt.data[0] = member_tid
        mtt.data[1] = ft.data[1]
        mtt.data[2] = ft.data[2]
        local match_mod = require("lib.type.static.match")
        return match_mod.evaluate(ctx, id)
    end

    if ft.tag == TAG_NAMED then
        local env_mod = require("lib.type.static.env")
        local resolved = env_mod.resolve_named_type(ctx, ctx.scope, ft.data[0], { member_tid })
        if resolved then return resolved end
    end

    -- Unknown function form — return T_NEVER for this arm
    return ctx.T_NEVER
end

local function expand_each_union(ctx, arg_ids)
    if #arg_ids ~= 2 then
        return ctx.T_NEVER
    end
    local union_tid = types_mod.find(ctx, arg_ids[1])
    local fn_tid    = arg_ids[2]
    local ut = ctx.types:get(union_tid)

    local results = {}
    if ut.tag == TAG_UNION then
        for i = ut.data[0], ut.data[0] + ut.data[1] - 1 do
            local member = types_mod.find(ctx, ctx.lists:get(i))
            results[#results + 1] = apply_type_fn(ctx, fn_tid, member)
        end
    else
        -- Single type — apply once
        results[1] = apply_type_fn(ctx, fn_tid, union_tid)
    end

    if #results == 0 then return ctx.T_NEVER end
    return types_mod.make_union(ctx, results)
end

-- ---------------------------------------------------------------------------
-- $EachField<T, F>
-- ---------------------------------------------------------------------------
-- Apply F to each field descriptor of table T.
-- F receives a table type: { key: "fieldname", value: V, optional: boolean, readonly: boolean }
-- F must return a table type with the same structure.
-- The output is a new table type assembled from F's results.
--
-- Field descriptor table type (synthesised per field):
--   { key: LIT_STRING(name), value: field_type, optional: LIT_BOOLEAN, readonly: LIT_BOOLEAN }
local function make_field_descriptor(ctx, fe)
    -- key: string literal of field name
    local key_id = types_mod.make_literal(ctx, LIT_STRING, fe.name_id)

    -- value: the field's type
    local val_id = types_mod.find(ctx, fe.type_id)

    -- optional: boolean literal
    local opt_val  = band(fe.flags, FLAG_OPTIONAL) ~= 0 and 1 or 0
    local opt_id   = types_mod.make_literal(ctx, LIT_BOOLEAN, opt_val)

    -- readonly: boolean literal
    local ro_val   = band(fe.flags, FLAG_READONLY) ~= 0 and 1 or 0
    local ro_id    = types_mod.make_literal(ctx, LIT_BOOLEAN, ro_val)

    local key_name_id     = intern_mod.intern(ctx.pool, "key")
    local val_name_id     = intern_mod.intern(ctx.pool, "value")
    local opt_name_id     = intern_mod.intern(ctx.pool, "optional")
    local ro_name_id      = intern_mod.intern(ctx.pool, "readonly")

    local fids = {
        types_mod.make_field(ctx, key_name_id, key_id,  0),
        types_mod.make_field(ctx, val_name_id, val_id,  0),
        types_mod.make_field(ctx, opt_name_id, opt_id,  0),
        types_mod.make_field(ctx, ro_name_id,  ro_id,   0),
    }
    return types_mod.make_table(ctx, fids, {}, -1, {})
end

-- Extract a field from a descriptor table result.
-- Returns the type_id for the named slot, or nil.
local function descriptor_field(ctx, tbl_tid, slot_name)
    tbl_tid = types_mod.find(ctx, tbl_tid)
    local t = ctx.types:get(tbl_tid)
    if t.tag ~= TAG_TABLE then return nil end
    local name_id = intern_mod.intern(ctx.pool, slot_name)
    local fe = types_mod.table_field(ctx, tbl_tid, name_id)
    if fe then return types_mod.find(ctx, fe.type_id) end
    return nil
end

local function expand_each_field_table(ctx, tbl_tid, fn_tid)
    local tt = ctx.types:get(tbl_tid)
    if tt.tag ~= TAG_TABLE then
        return ctx.T_NEVER
    end

    local out_fields = {}

    for i = tt.data[0], tt.data[0] + tt.data[1] - 1 do
        local fid = ctx.lists:get(i)
        local fe  = ctx.fields:get(fid)
        if fe.name_id >= 0 then  -- skip spreads
            -- Build descriptor table for this field
            local desc_tid = make_field_descriptor(ctx, fe)

            -- Apply F to the descriptor
            local result_tid = apply_type_fn(ctx, fn_tid, desc_tid)

            -- Extract key/value/optional/readonly from result
            -- (F is expected to return a compatible descriptor)
            local key_tid   = descriptor_field(ctx, result_tid, "key")
            local val_tid   = descriptor_field(ctx, result_tid, "value")
            local opt_tid   = descriptor_field(ctx, result_tid, "optional")
            local ro_tid    = descriptor_field(ctx, result_tid, "readonly")

            -- Determine output field name from key slot
            -- Expect a LIT_STRING result; fall back to original name
            local out_name_id = fe.name_id
            if key_tid then
                local kt = ctx.types:get(key_tid)
                if kt.tag == defs.TAG_LITERAL and kt.data[0] == LIT_STRING then
                    out_name_id = kt.data[1]
                end
            end

            -- Determine output field type
            local out_val_tid = val_tid or types_mod.find(ctx, fe.type_id)

            -- Determine flags
            local out_flags = 0
            if opt_tid then
                local ot = ctx.types:get(opt_tid)
                if ot.tag == defs.TAG_LITERAL and ot.data[0] == LIT_BOOLEAN and ot.data[1] == 1 then
                    out_flags = out_flags + FLAG_OPTIONAL
                end
            end
            if ro_tid then
                local rt = ctx.types:get(ro_tid)
                if rt.tag == defs.TAG_LITERAL and rt.data[0] == LIT_BOOLEAN and rt.data[1] == 1 then
                    out_flags = out_flags + FLAG_READONLY
                end
            end

            out_fields[#out_fields + 1] = types_mod.make_field(ctx, out_name_id, out_val_tid, out_flags)
        end
    end

    return types_mod.make_table(ctx, out_fields, {}, -1, {})
end

local function expand_each_field(ctx, arg_ids)
    if #arg_ids ~= 2 then
        return ctx.T_NEVER
    end
    local tbl_tid = types_mod.find(ctx, arg_ids[1])
    local fn_tid  = arg_ids[2]
    local tt = ctx.types:get(tbl_tid)

    -- any input -> any output (no field iteration possible)
    if tt.tag == TAG_ANY then
        return ctx.T_ANY
    end

    -- union input -> distribute over each arm and union results
    if tt.tag == TAG_UNION then
        local arms = {}
        for i = tt.data[0], tt.data[0] + tt.data[1] - 1 do
            local member_tid = types_mod.find(ctx, ctx.lists:get(i))
            arms[#arms + 1] = expand_each_field_table(ctx, member_tid, fn_tid)
        end
        if #arms == 0 then return ctx.T_NEVER end
        return types_mod.make_union(ctx, arms)
    end

    -- single table input
    return expand_each_field_table(ctx, tbl_tid, fn_tid)
end

-- ---------------------------------------------------------------------------
-- $Require<T>
-- ---------------------------------------------------------------------------
-- Type-level require: given a string literal type T, look up the declared
-- module type for that module name.  Returns the declared type if found,
-- T_UNKNOWN otherwise.
--
-- Used by the generic function declaration:
--   declare require: <T: string>(module: T) -> $Require<T>
-- When T is bound to LIT_STRING("mod.name"), $Require<T> evaluates to the
-- type declared via --:: module "mod.name": { ... }.
local function expand_require(ctx, arg_ids)
    if #arg_ids ~= 1 then return ctx.T_UNKNOWN end
    local T_tid = types_mod.find(ctx, arg_ids[1])
    local T_t = ctx.types:get(T_tid)
    if T_t.tag == TAG_LITERAL and T_t.data[0] == LIT_STRING then
        local module_name = intern_mod.get(ctx.pool, T_t.data[1])
        if module_name and ctx.module_types then
            local declared = ctx.module_types[module_name]
            if declared then return declared end
        end
    end
    return ctx.T_UNKNOWN
end

-- ---------------------------------------------------------------------------
-- $Opaque<T>
-- ---------------------------------------------------------------------------
-- Produces a TAG_NOMINAL type with a unique identity per (call site, T).
-- The identity is a content hash of (stable_id, T_fingerprint), making it
-- deterministic across check runs for the same source file — unlike a
-- per-run counter which is unstable once multiple nominal types exist.
--
-- stable_id: an int32 content hash of "filename:ann_tid" stored in
--   TAG_TYPE_CALL.data[3] by constrain.lua. This is stable for the same
--   source content (annotation parser is deterministic) and globally unique
--   due to the filename prefix.
--
-- T_fingerprint: a stable integer derived from T's structure. Primitive
--   types use their tag. TAG_NOMINAL uses its own stable identity. Complex
--   structural types fall back to tag*0x1000+T (per-run, but at least unique
--   within a run). This means Schema<{x:integer}> is not cross-run stable,
--   but Schema<integer>, Schema<string>, etc. are.

local fnv31   = defs.fnv31
local TAG_NOMINAL_I = defs.TAG_NOMINAL

local function T_fingerprint(ctx, T)
    local t = ctx.types:get(T)
    local tag = t.tag
    if tag == defs.TAG_INTEGER  then return 1 end
    if tag == defs.TAG_NUMBER   then return 2 end
    if tag == defs.TAG_STRING   then return 3 end
    if tag == defs.TAG_BOOLEAN  then return 4 end
    if tag == defs.TAG_NIL      then return 5 end
    if tag == defs.TAG_ANY      then return 6 end
    if tag == defs.TAG_NEVER    then return 7 end
    if tag == TAG_NOMINAL_I     then return t.data[1] end  -- recursive: its own stable id
    return tag * 0x1000 + T  -- structural types: per-run unique, not cross-run stable
end

local function expand_opaque(ctx, arg_ids, stable_id)
    if #arg_ids < 1 or #arg_ids > 2 then return ctx.T_NEVER end
    local T = types_mod.find(ctx, arg_ids[1])
    -- Derive a deterministic nominal identity from call site + T type.
    -- If stable_id is 0 (legacy / unset), fall back to per-run counter.
    local nominal_id
    if stable_id ~= 0 then
        nominal_id = fnv31(tostring(stable_id) .. ":" .. tostring(T_fingerprint(ctx, T)))
    else
        ctx.nominal_id = ctx.nominal_id + 1
        nominal_id = ctx.nominal_id
    end
    -- Cache to avoid allocating duplicate TAG_NOMINAL nodes per run.
    if not ctx._opaque_cache then ctx._opaque_cache = {} end
    local cached = ctx._opaque_cache[nominal_id]
    if cached then return cached end
    local opaque_name_id = intern_mod.intern(ctx.pool, "Opaque")
    local result = types_mod.make_nominal(ctx, opaque_name_id, nominal_id, T)
    ctx._opaque_cache[nominal_id] = result
    -- Track which nominal_ids were produced by $Opaque (vs --:: newtype).
    -- solve.lua uses this to block field access on opaque types.
    if not ctx._opaque_nominals then ctx._opaque_nominals = {} end
    ctx._opaque_nominals[nominal_id] = true

    -- Two-arg form: $Opaque<T, U> — U is the exposed structural view.
    -- Validate that U is a structural subtype of T (all fields in U exist in T
    -- with compatible types), then store U in the side table.
    if #arg_ids >= 2 then
        local U_tid = types_mod.find(ctx, arg_ids[2])
        local ut = ctx.types:get(U_tid)
        local t  = ctx.types:get(T)
        -- Only validate when U is a table type and T is a table type.
        if ut.tag == TAG_TABLE and t.tag == TAG_TABLE then
            local unify_mod = require("lib.type.static.unify")
            local errors_mod = require("lib.type.static.errors")
            for i = ut.data[0], ut.data[0] + ut.data[1] - 1 do
                local fid = ctx.lists:get(i)
                local ufe = ctx.fields:get(fid)
                if ufe.name_id >= 0 then
                    local tfe = types_mod.table_field(ctx, T, ufe.name_id)
                    local fname = intern_mod.get(ctx.pool, ufe.name_id) or "?"
                    if not tfe then
                        errors_mod.error(ctx.err, ctx.filename, 0, 0,
                            "$Opaque<T, U>: exposed field `" .. fname
                            .. "` does not exist in inner type T")
                    else
                        -- U's field type must be compatible with T's field type.
                        if not unify_mod.try_unify(ctx, types_mod.find(ctx, ufe.type_id),
                                                        types_mod.find(ctx, tfe.type_id), {}) then
                            errors_mod.error(ctx.err, ctx.filename, 0, 0,
                                "$Opaque<T, U>: exposed field `" .. fname
                                .. "` has incompatible type in inner type T")
                        end
                    end
                end
            end
        end
        if not ctx._opaque_view then ctx._opaque_view = {} end
        ctx._opaque_view[nominal_id] = U_tid
    end

    return result
end

-- ---------------------------------------------------------------------------
-- Public entry point
-- ---------------------------------------------------------------------------

-- expand(ctx, name_id, arg_ids, stable_id) -> type_id
-- Called when a TAG_TYPE_CALL has a TAG_INTRINSIC callee.
-- name_id:   intern ID of the intrinsic name (string)
-- arg_ids:   Lua array of resolved type_ids (the type arguments)
-- stable_id: fnv31(filename:ann_tid) stored in TAG_TYPE_CALL.data[3];
--            0 means not set (legacy cri or non-deferred path without filename)
function M.expand(ctx, name_id, arg_ids, stable_id)
    local name = intern_mod.get(ctx.pool, name_id) or ""

    if name == "Keys" then
        return expand_keys(ctx, arg_ids)
    end

    if name == "EachUnion" then
        return expand_each_union(ctx, arg_ids)
    end

    if name == "EachField" then
        return expand_each_field(ctx, arg_ids)
    end

    if name == "Opaque" then
        return expand_opaque(ctx, arg_ids, stable_id)
    end

    if name == "Require" then
        return expand_require(ctx, arg_ids)
    end

    -- Unknown intrinsic: return T_NEVER so downstream errors are informative
    return ctx.T_NEVER
end

return M
