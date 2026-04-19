-- lib/type/static/prelude_luajit.lua
-- LuaJIT-specific prelude additions: installs FFI cdef hooks.
-- Ptr<T> and Arr<T> are declared in stdlib_types.lua, not here.

local M = {}

local cdef_mod = require("lib.type.static.cdef")

function M.populate(ctx)
    -- Install FFI hooks so ffi.cdef() calls are picked up during inference.
    ctx.ffi_hooks = {
        init    = cdef_mod.init,
        process = cdef_mod.process,
    }
    -- Run init immediately to allocate ctx.T_FFI_C and ctx.cdef_typedefs.
    cdef_mod.init(ctx)
end

return M
