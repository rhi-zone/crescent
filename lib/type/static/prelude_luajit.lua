-- lib/type/static/prelude_luajit.lua
-- LuaJIT-specific prelude additions.
-- Installs FFI hooks (cdef.lua) and registers Ptr<T> as a generic type alias.
-- Call M.populate(ctx) after prelude.populate(ctx) to add LuaJIT-specific bindings.
-- This is opt-in; prelude.lua is unchanged and targets all Lua versions.

local M = {}

local defs        = require("lib.type.static.defs")
local types_mod   = require("lib.type.static.types")
local env_mod     = require("lib.type.static.env")
local intern_mod  = require("lib.type.static.intern")
local cdef_mod    = require("lib.type.static.cdef")

-- Register Ptr<T> = T & { [0]: T } as a generic type alias.
-- The alias body references T via TAG_NAMED; env.substitute replaces it when applied.
-- [0] dereference is modelled as a single-integer-key indexer (key type T_INTEGER,
-- value type T_ref), giving both direct struct field access (via T itself) and
-- explicit dereference syntax (ptr[0].field).
local function register_ptr(ctx)
    local T_name_id   = intern_mod.intern(ctx.pool, "T")
    local Ptr_name_id = intern_mod.intern(ctx.pool, "Ptr")

    -- TAG_NAMED node for T (no args)
    local T_ref = types_mod.alloc_type(ctx, defs.TAG_NAMED)
    local t_ref_slot = ctx.types:get(T_ref)
    t_ref_slot.data[0] = T_name_id
    t_ref_slot.data[1] = 0  -- args_start
    t_ref_slot.data[2] = 0  -- args_len

    -- { [integer]: T }  (indexer: integer → T_ref) for [0] dereference
    local deref_tbl = types_mod.make_table(ctx, {}, {ctx.T_INTEGER, T_ref}, -1, {})

    -- Ptr<T> = T & { [integer]: T }
    -- Member 1: T itself (struct fields accessible directly via intersection)
    -- Member 2: { [integer]: T } for explicit [0] dereference
    local body = types_mod.make_intersection(ctx, {T_ref, deref_tbl})

    env_mod.bind_type(ctx.scope, Ptr_name_id, {
        body   = body,
        params = { T_name_id },
    })
end

-- Register Arr<T> = { [integer]: T } as a generic type alias.
-- Array pointer: any integer index returns T.
local function register_arr(ctx)
    local T_name_id   = intern_mod.intern(ctx.pool, "T")
    local Arr_name_id = intern_mod.intern(ctx.pool, "Arr")

    -- TAG_NAMED node for T (no args)
    local T_ref = types_mod.alloc_type(ctx, defs.TAG_NAMED)
    local t_ref_slot = ctx.types:get(T_ref)
    t_ref_slot.data[0] = T_name_id
    t_ref_slot.data[1] = 0
    t_ref_slot.data[2] = 0

    -- Arr<T> = { [integer]: T }
    local body = types_mod.make_table(ctx, {}, {ctx.T_INTEGER, T_ref}, -1, {})

    env_mod.bind_type(ctx.scope, Arr_name_id, {
        body   = body,
        params = { T_name_id },
    })
end

-- Install FFI hooks and populate LuaJIT-specific type bindings.
function M.populate(ctx)
    -- Install FFI hooks so ffi.cdef() calls are picked up during inference.
    ctx.ffi_hooks = {
        init    = cdef_mod.init,
        process = cdef_mod.process,
    }

    -- Run init immediately to allocate ctx.T_FFI_C and ctx.cdef_typedefs.
    cdef_mod.init(ctx)

    -- Register Ptr<T> and Arr<T> generic aliases.
    register_ptr(ctx)
    register_arr(ctx)
end

return M
