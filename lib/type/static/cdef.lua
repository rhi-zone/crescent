-- lib/type/static/cdef.lua
-- Converts C declaration descriptors (from cdecl_parse) into TypeSlots in the
-- checker arena. Manages ctx.T_FFI_C, the open table representing ffi.C.
--
-- Usage:
--   cdef.init(ctx)         -- allocate ctx.T_FFI_C, ctx.cdef_typedefs
--   cdef.process(ctx, str) -- parse C string and register decls into ctx

local M = {}

local defs        = require("lib.type.static.defs")
local types_mod   = require("lib.type.static.types")
local env_mod     = require("lib.type.static.env")
local intern_mod  = require("lib.type.static.intern")
local cdecl_parse = require("lib.type.static.cdecl_parse")

local TAG_ANY          = defs.TAG_ANY
local TAG_TABLE        = defs.TAG_TABLE

---------------------------------------------------------------------------
-- c_type_to_tid: map a C type descriptor to a TypeSlot ID in ctx
---------------------------------------------------------------------------

local function c_type_to_tid(ctx, ctype)
    local k = ctype.k

    if k == "void"  then return ctx.T_NIL end
    if k == "bool"  then return ctx.T_BOOLEAN end
    if k == "int"   then return ctx.T_INTEGER end
    if k == "float" then return ctx.T_NUMBER end
    if k == "char"  then return ctx.T_INTEGER end  -- char as integer
    if k == "enum"  then return ctx.T_INTEGER end

    if k == "ptr" then
        local to = ctype.to
        if to then
            local tok = to.k
            if tok == "char"  then return ctx.T_STRING  end  -- char* → string
            if tok == "void"  then return ctx.T_ANY     end  -- void* → any
            if tok == "func"  then
                -- function pointer → same as the function type itself
                return c_type_to_tid(ctx, to)
            end
            if tok == "struct" then
                if to.fields and #to.fields > 0 then
                    -- Build the struct table type.
                    local inner = c_type_to_tid(ctx, to)
                    -- Ptr<T> = T & { [integer]: T } for [0] dereference.
                    local deref_tbl = types_mod.make_table(ctx, {}, {ctx.T_INTEGER, inner}, -1, {})
                    return types_mod.make_intersection(ctx, {inner, deref_tbl})
                end
            end
        end
        -- Opaque pointer.
        return types_mod.alloc_type(ctx, defs.TAG_CDATA)
    end

    if k == "arr" then
        -- Arrays treated as opaque for now.
        return types_mod.alloc_type(ctx, defs.TAG_CDATA)
    end

    if k == "union" then
        -- Unions are complex; treat as any.
        return ctx.T_ANY
    end

    if k == "struct" then
        if not ctype.fields or #ctype.fields == 0 then
            -- Opaque struct (forward declaration or no body).
            return types_mod.alloc_type(ctx, defs.TAG_CDATA)
        end
        -- Build a closed table type with one field per struct field.
        local field_ids = {}
        for _, sf in ipairs(ctype.fields) do
            if sf.name_id then
                local ftid = c_type_to_tid(ctx, sf.type)
                field_ids[#field_ids + 1] = types_mod.make_field(ctx, sf.name_id, ftid, false)
            end
        end
        return types_mod.make_table(ctx, field_ids, {}, -1, {})
    end

    if k == "func" then
        -- Map params.
        local param_tids = {}
        if ctype.params then
            for _, p in ipairs(ctype.params) do
                param_tids[#param_tids + 1] = c_type_to_tid(ctx, p.type)
            end
        end
        -- Map return type.
        local ret_tids = {}
        if ctype.ret and ctype.ret.k ~= "void" then
            ret_tids[1] = c_type_to_tid(ctx, ctype.ret)
        end
        -- Vararg.
        local vararg_tid = ctype.vararg and ctx.T_ANY or nil
        return types_mod.make_func(ctx, param_tids, ret_tids, vararg_tid, {})
    end

    if k == "name" then
        -- Typedef reference: look up in cdef_typedefs by intern ID.
        local tid = ctx.cdef_typedefs and ctx.cdef_typedefs[ctype.id]
        if tid then return tid end
        return ctx.T_ANY
    end

    return ctx.T_ANY
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

-- Initialize FFI support on ctx.
-- Allocates ctx.T_FFI_C (open table accumulating C namespace symbols)
-- and ctx.cdef_typedefs (intern_id → type_id for typedef names).
-- Registers ffi_C as a type alias in the module-level scope.
function M.init(ctx)
    -- Open table with row variable: fields accumulate via table_add_field as ffi.cdef runs.
    ctx.T_FFI_C = types_mod.make_table(ctx, {}, {}, types_mod.make_rowvar(ctx, 0), {})
    ctx.cdef_typedefs = {}

    -- Register as type alias so annotation code can reference "ffi_C" by name.
    local ffi_C_id = intern_mod.intern(ctx.pool, "ffi_C")
    env_mod.bind_type(ctx.scope, ffi_C_id, { body = ctx.T_FFI_C })
end

-- Parse a C declaration string and register its symbols into ctx.T_FFI_C.
function M.process(ctx, c_string)
    if not ctx.T_FFI_C then return end

    local infer_mod = require("lib.type.static.infer")
    local ok, decls = pcall(cdecl_parse.parse, c_string, ctx.pool)
    if not ok then return end

    for _, d in ipairs(decls) do
        local name_id = d.name_id
        if not name_id then goto continue end

        if d.decl == "func" or d.decl == "var" then
            local tid = c_type_to_tid(ctx, d.type)
            infer_mod.table_add_field(ctx, ctx.T_FFI_C, name_id, tid)

        elseif d.decl == "typedef" then
            local tid = c_type_to_tid(ctx, d.type)
            ctx.cdef_typedefs[name_id] = tid
            -- Also register as a type alias in scope for annotation-side resolution.
            local alias = { body = tid }
            env_mod.bind_type(ctx.scope, name_id, alias)

        elseif d.decl == "struct" then
            local tid = c_type_to_tid(ctx, d.type)
            local t = ctx.types:get(types_mod.find(ctx, tid))
            if t.tag == TAG_TABLE then
                env_mod.bind_type(ctx.scope, name_id, { body = tid })
            end

        elseif d.decl == "enum_val" then
            -- Enum constants are integers accessible via ffi.C.
            infer_mod.table_add_field(ctx, ctx.T_FFI_C, name_id, ctx.T_INTEGER)
        end

        ::continue::
    end
end

return M
