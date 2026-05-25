-- lib/type/static-v5/stdlib_types.lua
-- v5 standard-library type declarations.
--
-- Exports a single function:
--   M.decls() -> { [string]: V5Type }
--
-- The returned table maps (possibly dotted) names to V5Types and is passed to
-- M.generate via opts.decls.  Dotted names ("io.write") must be handled by
-- callers that wish to inject them into a record-based scope; the gen-pass
-- currently binds only the full dotted string as a flat name.  Phase 5.D will
-- elaborate this into proper record bindings.
--
-- Effect arities are registered in the ann module as a side effect of calling
-- M.register_effects(), which must be called once before any parse_annotation
-- call that references effect types.
--
-- Implementation choice: syntactic special-case in the gen-pass for pcall and
-- coroutine.create (not generic stdlib declarations), because the
-- discriminated-tuple-union return of pcall and the Coroutine<Y,S,R>
-- parameterisation of coroutine.create require type machinery (match arms,
-- type-level application) not yet wired into the v5 gen-pass.  The stdlib
-- declarations here give these functions conservative types (fresh-uvar
-- returns) so callers compile; the special-case handling is the semantic layer.

local types_mod = require("lib.type.experiments.v5_perf.types")
local ann_mod   = require("lib.type.static-v5.ann")

local M = {}

-- ── Effect arity registration ─────────────────────────────────────────────────

-- Register canonical effect arities once.  Idempotent.
--: () -> nil
function M.register_effects()
    ann_mod.declare_effect("io",    0)   -- !io     — I/O side effect (arity 0)
    ann_mod.declare_effect("os",    0)   -- !os     — OS/process side effect
    ann_mod.declare_effect("throw", 1)   -- !throw<E> — raises exception of type E
    ann_mod.declare_effect("yield", 2)   -- !yield<Y,R> — yields Y, receives R
end

-- ── Type constructors ─────────────────────────────────────────────────────────

-- Shorthand constructors.
--: (string) -> V5Type
local function tc(name)   return types_mod.const(name)  end
--: (string) -> V5Type
local function eff(name)  return types_mod.effect(name) end

--: (string, V5Type) -> V5Type
local function eff_apply1(name, arg)
    --: V5Type
    local eff_head = types_mod.effect(name)
    local args = {} --[[: V5Type[] ]]
    args[1] = arg
    return types_mod.effect_apply(eff_head, args)
end

-- Build an arrow type: (arg_types...) -> (return_base & effects...).
-- effects is a list of effect V5Types.  When effects is empty the return
-- type is just return_base.
--: (V5Type[], V5Type, V5Type[]) -> V5Type
local function effectful_fn(arg_types, return_base, effects)
    --: V5Type
    local ret_ty = return_base
    if #effects == 0 then
        -- ret_ty already = return_base
    else
        local parts = {} --[[: V5Type[] ]]
        parts[1] = return_base
        for i = 1, #effects do
            local e = effects[i]
            if e ~= nil then parts[#parts + 1] = e end
        end
        --: V5Type
        local ity = types_mod.intersection(parts)
        ret_ty = ity
    end
    local rets = {} --[[: V5Type[] ]]
    rets[1] = ret_ty
    return types_mod.arrow(arg_types, rets)
end

-- ── Canonical V5Type values ───────────────────────────────────────────────────

local T_NIL     = tc("nil")
local T_BOOL    = tc("boolean")
local T_STR     = tc("string")
local T_NUM     = tc("number")
local T_INT     = tc("integer")
local T_UNKNOWN = tc("unknown")
local T_NEVER   = tc("never")

local EFF_IO  = eff("io")
local EFF_OS  = eff("os")

-- ── Declaration table builder ─────────────────────────────────────────────────

--: () -> { [string]: V5Type, ... }
function M.decls()
    M.register_effects()

    --: { [string]: V5Type, ... }
    local d = {} --[[: { [string]: V5Type, ... } ]]

    -- ── print / tostring / tonumber / type ─────────────────────────────────

    -- print(...) -> nil & !io  (produces I/O)
    d["print"] = effectful_fn({ T_UNKNOWN }, T_NIL, { EFF_IO })

    -- tostring(val) -> string  (pure)
    d["tostring"] = effectful_fn({ T_UNKNOWN }, T_STR, {})

    -- tonumber(val, base?) -> number | nil  (pure)
    --: V5Type
    local t_num_or_nil = types_mod.union({ T_NUM, T_NIL })
    d["tonumber"] = effectful_fn({ T_UNKNOWN, T_INT }, t_num_or_nil, {})

    -- type(val) -> string  (pure)
    d["type"] = effectful_fn({ T_UNKNOWN }, T_STR, {})

    -- error(msg, level?) -> never  (raises !throw<string>)
    -- Declared with 1 arg so T-CSub-Arrow arity check matches the common
    -- 1-arg call site.  The optional level arg is variadic at runtime but
    -- the v5 gen-pass does not model optional args.
    --: V5Type
    local eff_throw_str = eff_apply1("throw", T_STR)
    d["error"] = effectful_fn({ T_UNKNOWN }, T_NEVER, { eff_throw_str })

    -- assert(val) -> val  (raises !throw<string> on failure)
    d["assert"] = effectful_fn({ T_UNKNOWN }, T_UNKNOWN, { eff_throw_str })

    -- pcall(fn, ...) -> (true, result) | (false, string)
    -- Conservative: returns unknown (full discriminated-union requires 5.D).
    -- Syntactically special-cased in gen-pass to suppress !throw propagation.
    -- Declared with 1 arg (the function) so the arity check in T-CSub-Arrow
    -- matches single-arg call sites; extra args are passed through at runtime
    -- but the v5 gen-pass does not model variadic function types.
    --: V5Type
    local pcall_ret = types_mod.union({ T_BOOL, T_UNKNOWN })
    d["pcall"] = effectful_fn({ T_UNKNOWN }, pcall_ret, {})

    -- xpcall(fn, handler, ...) — same conservative return; 2 declared args.
    d["xpcall"] = effectful_fn({ T_UNKNOWN, T_UNKNOWN }, pcall_ret, {})

    -- ── io library ─────────────────────────────────────────────────────────

    -- io.write(...) -> nil & !io
    --: V5Type
    local io_write = effectful_fn({ T_UNKNOWN }, T_NIL, { EFF_IO })
    -- io.read(...) -> string | nil  & !io
    --: V5Type
    local t_str_or_nil = types_mod.union({ T_STR, T_NIL })
    --: V5Type
    local io_read  = effectful_fn({ T_UNKNOWN }, t_str_or_nil, { EFF_IO })
    -- io.lines(filename?) -> function & !io  (returns iterator)
    --: V5Type
    local io_lines = effectful_fn({ T_STR }, T_UNKNOWN, { EFF_IO })
    -- io.open(filename, mode?) -> file | nil, string? & !io
    --: V5Type
    local io_open  = effectful_fn({ T_STR, T_STR }, T_UNKNOWN, { EFF_IO })

    d["io.write"] = io_write
    d["io.read"]  = io_read
    d["io.lines"] = io_lines
    d["io.open"]  = io_open

    -- io table record (for field-access lookup "io")
    --: { [string]: V5Type }
    local io_fields = {
        write = io_write,
        read  = io_read,
        lines = io_lines,
        open  = io_open,
    }
    d["io"] = types_mod.record(io_fields)

    -- ── os library ─────────────────────────────────────────────────────────

    -- os.exit([code]) -> never & !os
    --: V5Type
    local os_exit  = effectful_fn({ T_INT }, T_NEVER, { EFF_OS })
    -- os.time([t]) -> integer & !os
    --: V5Type
    local os_time  = effectful_fn({ T_UNKNOWN }, T_INT, { EFF_OS })
    -- os.clock() -> number & !os
    --: V5Type
    local os_clock = effectful_fn({}, T_NUM, { EFF_OS })
    -- os.date([fmt, time?]) -> string & !os
    --: V5Type
    local os_date  = effectful_fn({ T_STR, T_INT }, T_STR, { EFF_OS })

    d["os.exit"]  = os_exit
    d["os.time"]  = os_time
    d["os.clock"] = os_clock
    d["os.date"]  = os_date

    --: { [string]: V5Type }
    local os_fields = {
        exit  = os_exit,
        time  = os_time,
        clock = os_clock,
        date  = os_date,
    }
    d["os"] = types_mod.record(os_fields)

    -- ── coroutine library ───────────────────────────────────────────────────
    -- Conservative types: full !yield<Y,R> parameterisation requires 5.D.
    -- coroutine.create(fn) -> thread  — syntactically special-cased in gen-pass.
    --: V5Type
    local T_THREAD = tc("thread")
    --: V5Type
    local coro_create = effectful_fn({ T_UNKNOWN }, T_THREAD, {})
    -- coroutine.resume(co, ...) -> (boolean, unknown) & !yield
    --: V5Type
    local eff_yield = eff("yield")
    --: V5Type
    local coro_resume = effectful_fn({ T_THREAD, T_UNKNOWN }, T_UNKNOWN, { eff_yield })
    -- coroutine.yield(...) -> unknown & !yield
    --: V5Type
    local coro_yield = effectful_fn({ T_UNKNOWN }, T_UNKNOWN, { eff_yield })
    -- coroutine.wrap(fn) -> function
    --: V5Type
    local coro_wrap = effectful_fn({ T_UNKNOWN }, T_UNKNOWN, {})
    -- coroutine.status(co) -> string
    --: V5Type
    local coro_status = effectful_fn({ T_THREAD }, T_STR, {})

    d["coroutine.create"] = coro_create
    d["coroutine.resume"] = coro_resume
    d["coroutine.yield"]  = coro_yield
    d["coroutine.wrap"]   = coro_wrap
    d["coroutine.status"] = coro_status

    --: { [string]: V5Type }
    local coro_fields = {
        create = coro_create,
        resume = coro_resume,
        yield  = coro_yield,
        wrap   = coro_wrap,
        status = coro_status,
    }
    d["coroutine"] = types_mod.record(coro_fields)

    return d
end

return M
