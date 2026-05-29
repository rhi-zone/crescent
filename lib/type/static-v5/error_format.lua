-- lib/type/static-v5/error_format.lua
-- v4-style formatter for v5 OpSemError.  Builds v4 errors.lua's DiagEntry/
-- ErrCtx shape from v5 errors and delegates to v4's format_plain/format_ansi.
-- v5 OpSemError gains optional `prov` (file/line/col) and `details` (ADT).
-- When `details` is present, a per-tag prose renderer produces a user-readable
-- message; otherwise we fall back to the raw `msg` plus the rule tag in [].
--
-- Decision: delegate to v4's errors.lua rather than port.  v4's renderer takes
-- a plain Lua table shape (no v4-FFI dependencies in format_plain/format_ansi),
-- so building an ErrCtx is a few lines.  Porting would duplicate ~150 lines.

-- ── v4 errors.lua interface contract ────────────────────────────────────────
-- Explicit type declarations for the v4 shapes v5 depends on.  If errors.lua
-- renames a field or changes a function signature, bin/cr check on this file
-- will surface a type error (loud) instead of silently producing malformed
-- diagnostic tables at runtime.  v5-side only; v4 is untouched.
--
--:: V4DiagNote  = { filename: string, line: integer, col: integer, msg: string }
--:: V4DiagFixEdit = { byte_start: integer, byte_end: integer, replacement: string }
--:: V4DiagFix     = { edits: { [integer]: V4DiagFixEdit, ... }, kind: string, rule: string }
--:: V4DiagEntry = { kind: string, filename: string, line: integer, col: integer, msg: string, notes: { [integer]: V4DiagNote, ... }, fix?: V4DiagFix }
--:: V4ErrCtx    = { errors: { [integer]: V4DiagEntry, ... }, warnings: { [integer]: V4DiagEntry, ... }, source_lines: { [string]: { [integer]: string, ... }, ... } }
--:: V4ErrorsIface = { new_ctx: () -> V4ErrCtx, set_source: (V4ErrCtx, string, string | nil) -> (), error: (V4ErrCtx, string, integer, integer, string) -> V4DiagEntry, format_plain: (V4ErrCtx) -> string, format_ansi: (V4ErrCtx) -> string }
--: V4ErrorsIface
local errors_v4 = require("lib.type.static.errors")
-- The require pulls the typedefs (V5Type, Provenance, ErrorDetails, OpSemError)
-- into scope; we don't use the modules' values directly here.
local _types_mod      = require("lib.type.experiments.v5_perf.types")
local _subst_mod      = require("lib.type.experiments.v5_perf.subst")
local _constraint_mod = require("lib.type.experiments.v5_perf.constraint")
local _op_sem_mod     = require("lib.type.static-v5.op_sem")
local _ = _types_mod; _ = _subst_mod; _ = _constraint_mod; _ = _op_sem_mod

local M = {}

--:: FormatOpts = { color: boolean }

-- ── Type pretty-printer (minimal) ───────────────────────────────────────────
-- v5 has no existing pretty-printer; this is the smallest one that produces
-- readable output for the prose templates.  It is not a general printer; it
-- handles the cases that flow through error details: const, arrow, record,
-- union, intersection, app, uvar.

--: (V5Type | nil) -> string
local function show(ty)
    if ty == nil then return "?" end
    local tag = ty.tag
    if tag == "const" then
        return tostring(ty.name)
    elseif tag == "literal" then
        -- A TLiteral renders as its inhabitant (strings quoted).
        if ty.base == "string" then return "\"" .. tostring(ty.value) .. "\"" end
        return tostring(ty.value)
    elseif tag == "uvar" then
        return "?" .. tostring(ty.id)
    elseif tag == "var" then
        return "$" .. tostring(ty.i)
    elseif tag == "arrow" then
        local args = ty.args
        local parts = {} --[[: { [integer]: string } ]]
        if args ~= nil then
            for i = 1, #args do
                parts[i] = show(args[i])
            end
        end
        return "(" .. table.concat(parts, ", ") .. ") -> " .. show(ty.ret)
    elseif tag == "record" then
        -- Three-region: named fields (with optional/readonly modifiers) then
        -- index signatures.
        local parts = {} --[[: { [integer]: string } ]]
        local n = 0
        local fields = ty.fields
        if fields ~= nil then
            for k, v in pairs(fields) do
                n = n + 1
                local pre = v.readonly and "readonly " or ""
                local opt = v.optional and "?" or ""
                parts[n] = pre .. tostring(k) .. opt .. ": " .. show(v.type)
            end
        end
        local idxs = ty.indexes
        if idxs ~= nil then
            for i = 1, #idxs do
                local ix = idxs[i]
                if ix ~= nil then
                    n = n + 1
                    local pre = ix.readonly and "readonly " or ""
                    parts[n] = pre .. "[" .. show(ix.key) .. "]: " .. show(ix.value)
                end
            end
        end
        local body = table.concat(parts, ", ")
        if ty.row ~= nil then body = body .. (n > 0 and ", ..." or "...") end
        return "{ " .. body .. " }"
    elseif tag == "union" then
        local xs = ty.xs
        local parts = {} --[[: { [integer]: string } ]]
        if xs ~= nil then
            for i = 1, #xs do parts[i] = show(xs[i]) end
        end
        table.sort(parts)
        return table.concat(parts, " | ")
    elseif tag == "intersection" then
        local pts = ty.parts
        local parts = {} --[[: { [integer]: string } ]]
        if pts ~= nil then
            for i = 1, #pts do parts[i] = show(pts[i]) end
        end
        table.sort(parts)
        return table.concat(parts, " & ")
    elseif tag == "app" then
        return show(ty.f) .. "<" .. show(ty.a) .. ">"
    end
    return tostring(tag)
end

M.show = show

-- ── Prose rendering per ErrorDetails variant ────────────────────────────────

--: (string) -> string
local function tag_label(t)
    if t == "const" then return "a primitive type"
    elseif t == "literal" then return "a literal type"
    elseif t == "arrow" then return "a function"
    elseif t == "record" then return "a record"
    elseif t == "union" then return "a union"
    elseif t == "intersection" then return "an intersection"
    elseif t == "app" then return "a type application"
    elseif t == "uvar" then return "an unresolved type variable"
    end
    return t
end

--: (string, ErrorDetails | nil, string) -> string
function M.render_prose(rule, details, fallback_msg)
    if details == nil then
        return "[" .. rule .. "] " .. fallback_msg
    end
    local t = details.tag
    -- Narrowing through `details.tag` doesn't yet restrict the union to a
    -- single variant — tostring() bridges the residual `string | nil`.
    if t == "const_mismatch" then
        return "expected type `" .. tostring(details.b_name) .. "`, got `" .. tostring(details.a_name) .. "`"
    elseif t == "missing_field" then
        return "missing field `" .. tostring(details.field) .. "`"
    elseif t == "extra_field" then
        return "unexpected field `" .. tostring(details.field) .. "`"
    elseif t == "effect_not_permitted" then
        local eff = show(details.effect)
        local cont = details.container
        if cont == nil then
            -- Quiescence path: function has no annotation to permit the effect.
            return "effect `" .. eff .. "` escapes from function with no annotation to permit it"
        elseif cont.tag == "intersection" then
            -- Annotated with an intersection (e.g. () -> nil & !io): effect missing from set.
            return "function's annotation does not permit effect `" .. eff ..
                "`; annotation effects: `" .. show(cont) .. "`"
        else
            -- Annotated as a plain non-intersection type (pure): effect forbidden.
            return "function annotated as pure cannot perform effect `" .. eff .. "`"
        end
    elseif t == "kind_mismatch" then
        return "cannot use " .. tag_label(tostring(details.a_tag)) ..
            " where " .. tag_label(tostring(details.b_tag)) .. " is required"
    elseif t == "no_matching_branch" then
        return "type `" .. show(details.value_ty) ..
            "` does not match any branch of `" .. show(details.union_ty) .. "`"
    elseif t == "arrow_arity_mismatch" then
        return "function expects " .. tostring(details.expected) ..
            " arguments, got " .. tostring(details.got)
    elseif t == "record_arity_mismatch" then
        return "tuple expects " .. tostring(details.expected) ..
            " elements, got " .. tostring(details.got)
    elseif t == "head_mismatch" then
        return "expected type constructor `" .. tostring(details.b_name) ..
            "`, got `" .. tostring(details.a_name) .. "`"
    elseif t == "closed_extend" then
        return "cannot add field `" .. tostring(details.field) .. "` to a closed record"
    elseif t == "row_already_contains" then
        return "record already contains field `" .. tostring(details.field) .. "`"
    elseif t == "occurs_check" then
        return "circular type: type variable appears in its own definition"
    elseif t == "intersection_arity_mismatch" then
        return "intersection expects " .. tostring(details.expected) ..
            " parts, got " .. tostring(details.got)
    elseif t == "all_parts_unresolved" then
        return "cannot determine subtype: all intersection parts are still unresolved type variables"
    elseif t == "sealed_field_set" then
        return "cannot assign field `" .. tostring(details.field) .. "` on a sealed value"
    elseif t == "missing_method" then
        return "value has no method `" .. tostring(details.method) .. "`"
    elseif t == "not_a_record" then
        return "expected a record type, got " .. tag_label(tostring(details.found_tag))
    elseif t == "ambiguous_constructor" then
        return "ambiguous type constructor: could not determine its shape from context"
    elseif t == "hkt_arity_mismatch" then
        return "type constructor expects " .. tostring(details.expected) ..
            " arguments, got " .. tostring(details.got)
    end
    -- details is non-nil but no arm matched: a new ErrorDetails variant was added
    -- to op_sem.lua without a corresponding case here.  Include the tag name so
    -- the omission is visible in output rather than silently generic.
    -- (details == nil falls through to the plain "[rule] msg" path above.)
    return "[" .. rule .. ": " .. tostring(t) .. "] " .. fallback_msg
end

-- ── Main entry ──────────────────────────────────────────────────────────────
--
-- Builds an ErrCtx in v4's shape, populates source_lines, appends one DiagEntry
-- per v5 error, then calls format_plain or format_ansi.

--: (OpSemError[], { [string]: string }, FormatOpts) -> string
function M.format(v5_errors, sources_by_path, opts)
    local ctx = errors_v4.new_ctx()
    for path, src in pairs(sources_by_path) do
        errors_v4.set_source(ctx, path, src)
    end
    for _, e in ipairs(v5_errors) do
        local prose = M.render_prose(e.rule, e.details, e.msg)
        local path = "<input>"
        local line = 0
        local col = 0
        if e.prov ~= nil then
            local p = e.prov
            path = p.file or path
            line = p.line or 0
            col = p.col or 0
        end
        errors_v4.error(ctx, path, line, col, prose)
    end
    if opts and opts.color then
        return errors_v4.format_ansi(ctx)
    end
    return errors_v4.format_plain(ctx)
end

return M
