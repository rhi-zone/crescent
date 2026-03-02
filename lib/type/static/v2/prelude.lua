-- lib/type/static/v2/prelude.lua
-- Lua 5.1 / LuaJIT stdlib type bindings for the v2 typechecker.
-- Call M.populate(ctx) after creating a checker context to add stdlib types
-- to ctx.scope. Types are allocated into ctx's own arena so IDs are valid.

local intern_mod = require("lib.type.static.v2.intern")
local types_mod  = require("lib.type.static.v2.types")
local env_mod    = require("lib.type.static.v2.env")

local M = {}

-- Intern a name and bind a type_id to ctx.scope.
local function bind(ctx, name, tid)
    local name_id = intern_mod.intern(ctx.pool, name)
    env_mod.bind(ctx.scope, name_id, tid)
end

-- Intern a name and bind a function type.
-- params, returns: arrays of type_ids; vararg: type_id or nil
local function bind_func(ctx, name, params, returns, vararg)
    local fn_tid = types_mod.make_func(ctx, params, returns, vararg)
    bind(ctx, name, fn_tid)
    return fn_tid
end

-- Build a { name = type, ... } table type from a list of {name, tid} pairs.
local function make_ns(ctx, entries)
    local field_ids = {}
    for _, e in ipairs(entries) do
        local name_id = intern_mod.intern(ctx.pool, e[1])
        field_ids[#field_ids + 1] = types_mod.make_field(ctx, name_id, e[2], false)
    end
    return types_mod.make_table(ctx, field_ids, {}, -1, {})
end

-- Populate ctx.scope with Lua 5.1 / LuaJIT stdlib bindings.
function M.populate(ctx)
    local T_ANY     = ctx.T_ANY
    local T_NIL     = ctx.T_NIL
    local T_BOOLEAN = ctx.T_BOOLEAN
    local T_NUMBER  = ctx.T_NUMBER
    local T_STRING  = ctx.T_STRING
    local T_INTEGER = ctx.T_INTEGER

    -- print(...) -> ()
    bind_func(ctx, "print", {}, {}, T_ANY)
    -- tostring(any) -> string
    bind_func(ctx, "tostring", {T_ANY}, {T_STRING})
    -- tonumber(any[, base]) -> number?
    bind_func(ctx, "tonumber", {T_ANY}, {types_mod.make_optional(ctx, T_NUMBER)}, T_ANY)
    -- type(any) -> string
    bind_func(ctx, "type", {T_ANY}, {T_STRING})
    -- error(msg[, level])
    bind_func(ctx, "error", {T_ANY}, {}, T_ANY)
    -- assert(v[, msg, ...]) -> v, ...
    bind_func(ctx, "assert", {T_ANY}, {T_ANY}, T_ANY)
    -- pcall(f, ...) -> boolean, ...
    bind_func(ctx, "pcall", {T_ANY}, {T_BOOLEAN, T_ANY}, T_ANY)
    -- xpcall(f, msgh, ...) -> boolean, ...
    bind_func(ctx, "xpcall", {T_ANY, T_ANY}, {T_BOOLEAN, T_ANY}, T_ANY)

    -- pairs(t) -> (iter_fn, t, nil)
    local pairs_iter = types_mod.make_func(ctx, {T_ANY, T_ANY}, {T_ANY, T_ANY})
    bind_func(ctx, "pairs", {T_ANY}, {pairs_iter, T_ANY, T_NIL})
    -- ipairs(t) -> (iter_fn, t, 0)
    local ipairs_iter = types_mod.make_func(ctx, {T_ANY, T_INTEGER}, {T_INTEGER, T_ANY})
    bind_func(ctx, "ipairs", {T_ANY}, {ipairs_iter, T_ANY, T_INTEGER})
    -- next(t[, k]) -> (k, v)?
    bind_func(ctx, "next", {T_ANY, T_ANY}, {T_ANY, T_ANY})

    -- require(modname) -> any
    bind_func(ctx, "require", {T_STRING}, {T_ANY})

    -- setmetatable(t, mt) -> t
    bind_func(ctx, "setmetatable", {T_ANY, T_ANY}, {T_ANY})
    -- getmetatable(obj) -> table?
    bind_func(ctx, "getmetatable", {T_ANY}, {T_ANY})
    -- rawget / rawset / rawequal / rawlen
    bind_func(ctx, "rawget",   {T_ANY, T_ANY}, {T_ANY})
    bind_func(ctx, "rawset",   {T_ANY, T_ANY, T_ANY}, {T_ANY})
    bind_func(ctx, "rawequal", {T_ANY, T_ANY}, {T_BOOLEAN})
    bind_func(ctx, "rawlen",   {T_ANY}, {T_INTEGER})

    -- select("#"|n, ...) -> any
    bind_func(ctx, "select", {T_ANY}, {T_ANY}, T_ANY)
    -- unpack(t[, i[, j]]) -> ...
    bind_func(ctx, "unpack", {T_ANY, T_ANY, T_ANY}, {}, T_ANY)

    -- load / loadstring / loadfile / dofile
    bind_func(ctx, "load",       {T_ANY, T_ANY, T_ANY, T_ANY}, {T_ANY, T_ANY})
    bind_func(ctx, "loadstring", {T_STRING, T_ANY}, {T_ANY, T_ANY})
    bind_func(ctx, "loadfile",   {T_ANY}, {T_ANY, T_ANY})
    bind_func(ctx, "dofile",     {T_ANY}, {T_ANY}, T_ANY)

    -- collectgarbage / gcinfo
    bind_func(ctx, "collectgarbage", {T_ANY, T_ANY}, {T_ANY})
    bind_func(ctx, "gcinfo", {}, {T_INTEGER})

    -- print helpers
    bind_func(ctx, "rawprint", {T_ANY}, {})

    -- ipairs/pairs helpers already done; add some misc
    bind_func(ctx, "newproxy",   {T_ANY}, {T_ANY})

    -- _VERSION
    bind(ctx, "_VERSION", T_STRING)

    -- _G (open table)
    local rv = types_mod.make_rowvar(ctx, 0)
    bind(ctx, "_G", types_mod.make_table(ctx, {}, {}, rv, {}))

    ---------------------------------------------------------------------------
    -- string table
    ---------------------------------------------------------------------------
    local str_t = make_ns(ctx, {
        {"format",  types_mod.make_func(ctx, {T_STRING}, {T_STRING}, T_ANY)},
        {"len",     types_mod.make_func(ctx, {T_STRING}, {T_INTEGER})},
        {"sub",     types_mod.make_func(ctx, {T_STRING, T_INTEGER, T_ANY}, {T_STRING})},
        {"find",    types_mod.make_func(ctx, {T_STRING, T_STRING, T_ANY, T_ANY}, {T_ANY, T_ANY}, T_ANY)},
        {"match",   types_mod.make_func(ctx, {T_STRING, T_STRING, T_ANY}, {T_ANY}, T_ANY)},
        {"gmatch",  types_mod.make_func(ctx, {T_STRING, T_STRING}, {T_ANY})},
        {"gsub",    types_mod.make_func(ctx, {T_STRING, T_STRING, T_ANY, T_ANY}, {T_STRING, T_INTEGER})},
        {"rep",     types_mod.make_func(ctx, {T_STRING, T_INTEGER, T_ANY}, {T_STRING})},
        {"byte",    types_mod.make_func(ctx, {T_STRING, T_ANY, T_ANY}, {}, T_INTEGER)},
        {"char",    types_mod.make_func(ctx, {}, {T_STRING}, T_INTEGER)},
        {"upper",   types_mod.make_func(ctx, {T_STRING}, {T_STRING})},
        {"lower",   types_mod.make_func(ctx, {T_STRING}, {T_STRING})},
        {"reverse", types_mod.make_func(ctx, {T_STRING}, {T_STRING})},
        {"dump",    types_mod.make_func(ctx, {T_ANY, T_ANY}, {T_STRING})},
    })
    bind(ctx, "string", str_t)

    ---------------------------------------------------------------------------
    -- table table
    ---------------------------------------------------------------------------
    local tbl_t = make_ns(ctx, {
        {"insert",  types_mod.make_func(ctx, {T_ANY, T_ANY}, {}, T_ANY)},
        {"remove",  types_mod.make_func(ctx, {T_ANY, T_ANY}, {T_ANY})},
        {"concat",  types_mod.make_func(ctx, {T_ANY, T_ANY, T_ANY, T_ANY}, {T_STRING})},
        {"sort",    types_mod.make_func(ctx, {T_ANY, T_ANY}, {})},
        {"unpack",  types_mod.make_func(ctx, {T_ANY, T_ANY, T_ANY}, {}, T_ANY)},
        {"move",    types_mod.make_func(ctx, {T_ANY, T_INTEGER, T_INTEGER, T_INTEGER, T_ANY}, {T_ANY})},
        {"maxn",    types_mod.make_func(ctx, {T_ANY}, {T_INTEGER})},
    })
    bind(ctx, "table", tbl_t)

    ---------------------------------------------------------------------------
    -- math table
    ---------------------------------------------------------------------------
    local math_t = make_ns(ctx, {
        {"floor",      types_mod.make_func(ctx, {T_NUMBER}, {T_INTEGER})},
        {"ceil",       types_mod.make_func(ctx, {T_NUMBER}, {T_INTEGER})},
        {"abs",        types_mod.make_func(ctx, {T_NUMBER}, {T_NUMBER})},
        {"sqrt",       types_mod.make_func(ctx, {T_NUMBER}, {T_NUMBER})},
        {"max",        types_mod.make_func(ctx, {T_NUMBER}, {T_NUMBER}, T_NUMBER)},
        {"min",        types_mod.make_func(ctx, {T_NUMBER}, {T_NUMBER}, T_NUMBER)},
        {"random",     types_mod.make_func(ctx, {}, {T_NUMBER}, T_NUMBER)},
        {"randomseed", types_mod.make_func(ctx, {T_NUMBER}, {})},
        {"sin",        types_mod.make_func(ctx, {T_NUMBER}, {T_NUMBER})},
        {"cos",        types_mod.make_func(ctx, {T_NUMBER}, {T_NUMBER})},
        {"tan",        types_mod.make_func(ctx, {T_NUMBER}, {T_NUMBER})},
        {"asin",       types_mod.make_func(ctx, {T_NUMBER}, {T_NUMBER})},
        {"acos",       types_mod.make_func(ctx, {T_NUMBER}, {T_NUMBER})},
        {"atan",       types_mod.make_func(ctx, {T_NUMBER}, {T_NUMBER})},
        {"atan2",      types_mod.make_func(ctx, {T_NUMBER, T_NUMBER}, {T_NUMBER})},
        {"exp",        types_mod.make_func(ctx, {T_NUMBER}, {T_NUMBER})},
        {"log",        types_mod.make_func(ctx, {T_NUMBER, T_ANY}, {T_NUMBER})},
        {"log10",      types_mod.make_func(ctx, {T_NUMBER}, {T_NUMBER})},
        {"pow",        types_mod.make_func(ctx, {T_NUMBER, T_NUMBER}, {T_NUMBER})},
        {"fmod",       types_mod.make_func(ctx, {T_NUMBER, T_NUMBER}, {T_NUMBER})},
        {"modf",       types_mod.make_func(ctx, {T_NUMBER}, {T_NUMBER, T_NUMBER})},
        {"frexp",      types_mod.make_func(ctx, {T_NUMBER}, {T_NUMBER, T_INTEGER})},
        {"ldexp",      types_mod.make_func(ctx, {T_NUMBER, T_INTEGER}, {T_NUMBER})},
        {"huge",       T_NUMBER},
        {"pi",         T_NUMBER},
        {"max_integer", T_INTEGER},
        {"min_integer", T_INTEGER},
    })
    bind(ctx, "math", math_t)

    ---------------------------------------------------------------------------
    -- io table
    ---------------------------------------------------------------------------
    local io_t = make_ns(ctx, {
        {"open",   types_mod.make_func(ctx, {T_STRING, T_ANY}, {T_ANY, T_ANY})},
        {"close",  types_mod.make_func(ctx, {T_ANY}, {T_ANY})},
        {"write",  types_mod.make_func(ctx, {}, {T_ANY}, T_ANY)},
        {"read",   types_mod.make_func(ctx, {T_ANY}, {T_ANY}, T_ANY)},
        {"lines",  types_mod.make_func(ctx, {T_ANY, T_ANY}, {T_ANY}, T_ANY)},
        {"popen",  types_mod.make_func(ctx, {T_STRING, T_ANY}, {T_ANY, T_ANY})},
        {"tmpfile",types_mod.make_func(ctx, {}, {T_ANY})},
        {"stdin",  T_ANY},
        {"stdout", T_ANY},
        {"stderr", T_ANY},
    })
    bind(ctx, "io", io_t)

    ---------------------------------------------------------------------------
    -- os table
    ---------------------------------------------------------------------------
    local os_t = make_ns(ctx, {
        {"time",     types_mod.make_func(ctx, {T_ANY}, {T_INTEGER})},
        {"clock",    types_mod.make_func(ctx, {}, {T_NUMBER})},
        {"date",     types_mod.make_func(ctx, {T_ANY, T_ANY}, {T_ANY})},
        {"exit",     types_mod.make_func(ctx, {T_ANY, T_ANY}, {})},
        {"getenv",   types_mod.make_func(ctx, {T_STRING}, {types_mod.make_optional(ctx, T_STRING)})},
        {"difftime", types_mod.make_func(ctx, {T_NUMBER, T_NUMBER}, {T_NUMBER})},
        {"rename",   types_mod.make_func(ctx, {T_STRING, T_STRING}, {T_BOOLEAN, T_ANY})},
        {"remove",   types_mod.make_func(ctx, {T_STRING}, {T_BOOLEAN, T_ANY})},
        {"tmpname",  types_mod.make_func(ctx, {}, {T_STRING})},
        {"execute",  types_mod.make_func(ctx, {T_ANY}, {T_ANY, T_ANY, T_INTEGER})},
    })
    bind(ctx, "os", os_t)

    ---------------------------------------------------------------------------
    -- coroutine table
    ---------------------------------------------------------------------------
    local co_t = make_ns(ctx, {
        {"create",  types_mod.make_func(ctx, {T_ANY}, {T_ANY})},
        {"resume",  types_mod.make_func(ctx, {T_ANY}, {T_BOOLEAN, T_ANY}, T_ANY)},
        {"yield",   types_mod.make_func(ctx, {}, {T_ANY}, T_ANY)},
        {"wrap",    types_mod.make_func(ctx, {T_ANY}, {T_ANY})},
        {"status",  types_mod.make_func(ctx, {T_ANY}, {T_STRING})},
        {"running", types_mod.make_func(ctx, {}, {T_ANY, T_BOOLEAN})},
        {"isyieldable", types_mod.make_func(ctx, {}, {T_BOOLEAN})},
    })
    bind(ctx, "coroutine", co_t)

    ---------------------------------------------------------------------------
    -- debug table (minimal)
    ---------------------------------------------------------------------------
    local debug_t = make_ns(ctx, {
        {"getinfo",      types_mod.make_func(ctx, {T_ANY, T_ANY}, {T_ANY})},
        {"traceback",    types_mod.make_func(ctx, {T_ANY, T_ANY, T_ANY}, {T_STRING})},
        {"sethook",      types_mod.make_func(ctx, {T_ANY, T_ANY, T_ANY}, {})},
        {"getlocal",     types_mod.make_func(ctx, {T_ANY, T_INTEGER}, {T_STRING, T_ANY})},
        {"setlocal",     types_mod.make_func(ctx, {T_ANY, T_INTEGER, T_ANY}, {T_STRING})},
        {"getmetatable", types_mod.make_func(ctx, {T_ANY}, {T_ANY})},
        {"setmetatable", types_mod.make_func(ctx, {T_ANY, T_ANY}, {T_ANY})},
    })
    bind(ctx, "debug", debug_t)

    ---------------------------------------------------------------------------
    -- LuaJIT-specific (opaque stubs)
    ---------------------------------------------------------------------------
    bind(ctx, "ffi", T_ANY)
    bind(ctx, "bit", T_ANY)
    bind(ctx, "jit", T_ANY)
end

return M
