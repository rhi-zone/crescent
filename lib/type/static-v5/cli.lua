-- lib/type/static-v5/cli.lua
-- v5 typechecker CLI entry point.
--
-- Invoked via `bin/cr check --v5 [--summary] <file>...`
-- (bin/cr-check.lua dispatches here when `--v5` is present in argv).
--
-- Pipeline:
--   Read file -> parse.lua -> constrain.lua (opts.decls = stdlib decls)
--   -> op_sem.lua -> format errors -> exit code.
--
-- All I/O is via injected caps; no global io/os references in the library.

if not package.path:find("?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local constrain_mod = require("lib.type.static-v5.constrain")
local op_sem        = require("lib.type.static-v5.op_sem")
local stdlib_mod    = require("lib.type.static-v5.stdlib_types")

local M = {}

-- ── Dotted-name expansion ────────────────────────────────────────────────────
--
-- Given { ["io.write"] = T1, ["io.read"] = T2, foo = T3 } produce
-- { io = TRecord{ write=T1, read=T2 }, foo = T3 }.
-- Flat dotted entries are removed; the synthesized records are injected.
-- If stdlib_types.lua already built an "io" record entry, the flat "io.write"
-- etc. keys are redundant; this function is idempotent w.r.t. those records.
-- Handles one level of dotting (a.b) — nested (a.b.c) follows the same logic.
--
-- Implementation: two parallel tables keyed by top-level name —
--   leaves:   { [string]: V5Type }    — plain (non-dotted) names
--   subtrees: { [string]: { [string]: V5Type } } — per-prefix field maps
-- After scanning, subtrees are converted to TRecord.
--
--: ({ [string]: V5Type }) -> { [string]: V5Type }
function M.expand_dotted(decls)
    local types_mod = require("lib.type.experiments.v5_perf.types")

    -- dotted_prefixes: set of top-level names that have dotted children.
    --   These keys should NOT be emitted as plain leaves even if present.
    --: { [string]: boolean }
    local dotted_prefixes = {}

    -- subtree_fields: for each dotted prefix, the accumulated sub-map.
    --   Stored as parallel string arrays to avoid index-signature type issues.
    --   keys_by_prefix[prefix][i]   = field name
    --   vals_by_prefix[prefix][i]   = V5Type
    --: { [string]: { [integer]: string } }
    local keys_by_prefix = {}
    --: { [string]: { [integer]: V5Type } }
    local vals_by_prefix = {}

    for k, v in pairs(decls) do
        local dot = k:find(".", 1, true)
        if dot ~= nil then
            local prefix = k:sub(1, dot - 1)
            local rest   = k:sub(dot + 1)
            dotted_prefixes[prefix] = true
            --: { [integer]: string } | nil
            local ks = keys_by_prefix[prefix]
            --: { [integer]: V5Type } | nil
            local vs = vals_by_prefix[prefix]
            if ks == nil then
                --: { [integer]: string }
                local new_ks = {}
                keys_by_prefix[prefix] = new_ks
                ks = new_ks
            end
            if vs == nil then
                --: { [integer]: V5Type }
                local new_vs = {}
                vals_by_prefix[prefix] = new_vs
                vs = new_vs
            end
            local n = #ks + 1
            ks[n] = rest
            vs[n] = v
        end
    end

    --: { [string]: V5Type }
    local out = {}

    -- Emit plain leaves (skip any that have dotted children — records win).
    for k, v in pairs(decls) do
        if k:find(".", 1, true) == nil and not dotted_prefixes[k] then
            out[k] = v
        end
    end

    -- Emit synthesized records for dotted prefixes (recursive for a.b.c).
    for prefix, ks in pairs(keys_by_prefix) do
        --: { [integer]: V5Type } | nil
        local vs = vals_by_prefix[prefix]
        if vs ~= nil then
            -- Build a sub-decls map and recurse so a.b.c is handled.
            --: { [string]: V5Type }
            local sub_decls = {}
            for i = 1, #ks do
                local field_name = ks[i]
                local field_ty   = vs[i]
                if field_name ~= nil and field_ty ~= nil then
                    sub_decls[field_name] = field_ty
                end
            end
            --: { [string]: V5Type }
            local expanded = M.expand_dotted(sub_decls)
            --: V5Type
            local rec = types_mod.record(expanded)
            out[prefix] = rec
        end
    end

    return out
end

-- ── Run one file through the v5 pipeline ────────────────────────────────────
--
-- caps.read_file  : (string) -> (string | nil, string | nil)
-- caps.write_out  : (string) -> nil   — stdout
-- caps.write_err  : (string) -> nil   — stderr
--
-- Returns an integer exit code (0 = clean, 1 = errors, 2 = bad invocation).

--:: V5CliCaps = { read_file: (path: string) -> (string | nil, string | nil), write_out: (msg: string) -> nil, write_err: (msg: string) -> nil }

--: (string, V5CliCaps) -> { errors: { rule: string, msg: string }[], gen_errors: string[] }
local function check_one(path, caps)
    local source, ferr = caps.read_file(path)
    if source == nil then
        return { errors = { { rule = "io", msg = "cannot read file: " .. (ferr or path) } }, gen_errors = {} }
    end

    -- Register stdlib effects before generating constraints.
    stdlib_mod.register_effects()

    -- Expand dotted stdlib names into records.
    local raw_decls = stdlib_mod.decls()
    local decls = M.expand_dotted(raw_decls)

    -- Generate constraints.
    local constraints, gen_errors = constrain_mod.generate(source, path, { decls = decls })

    -- Solve.
    --: OpSemState
    local st = op_sem.new_state()
    for _, c in ipairs(constraints) do
        op_sem.emit(st, c)
    end
    op_sem.run(st)

    return { errors = st.errors, gen_errors = gen_errors }
end

-- ── Format a single error for display ───────────────────────────────────────

--: (string, { rule: string, msg: string }) -> string
local function format_solver_error(path, e)
    return path .. ": [" .. (e.rule or "?") .. "] " .. (e.msg or "?")
end

-- ── Argv parsing ─────────────────────────────────────────────────────────────

--:: V5CliOpts = { files: string[], summary: boolean }

--: (string[]) -> (V5CliOpts | nil, string | nil)
local function parse_argv(argv)
    --: V5CliOpts
    local opts = { files = {} --[[: string[] ]], summary = false }
    local end_of_flags = false
    for i = 1, #argv do
        local a = argv[i]
        if end_of_flags then
            opts.files[#opts.files + 1] = a
        elseif a == "--" then
            end_of_flags = true
        elseif a == "--v5" then
            -- Already-consumed flag; tolerated here too.
        elseif a == "--summary" then
            opts.summary = true
        elseif a:sub(1, 2) == "--" then
            return nil, "cr check --v5: unknown flag " .. a
        else
            opts.files[#opts.files + 1] = a
        end
    end
    if #opts.files == 0 then
        return nil, "cr check --v5: at least one file is required"
    end
    return opts, nil
end

-- ── Main entry (caps-injected) ───────────────────────────────────────────────

--: (string[], V5CliCaps) -> integer
function M.run(argv, caps)
    local opts, perr = parse_argv(argv)
    if opts == nil then
        caps.write_err(tostring(perr) .. "\n")
        return 2
    end

    local any_error = false
    local lines = {} --[[: { [integer]: string } ]]

    for _, path in ipairs(opts.files) do
        local result = check_one(path, caps)

        -- Gen-pass errors (annotation parse, etc.) are always printed.
        for _, ge in ipairs(result.gen_errors) do
            lines[#lines + 1] = ge
            any_error = true
        end

        -- Solver errors.
        for _, se in ipairs(result.errors) do
            lines[#lines + 1] = format_solver_error(path, se)
            any_error = true
        end
    end

    if #lines > 0 then
        caps.write_out(table.concat(lines, "\n") .. "\n")
    end

    return any_error and 1 or 0
end

-- ── Main entry (real I/O, for bin/cr-check.lua) ──────────────────────────────

--: (string[]) -> integer
function M.main(argv)
    --: V5CliCaps
    local caps = {
        --: (string) -> (string | nil, string | nil)
        read_file = function(path)
            local f, oerr = io.open(path, "rb")
            if f == nil then return nil, tostring(oerr) end
            local bytes = f:read("*a")
            f:close()
            if bytes == nil then return nil, "read failed: " .. path end
            return bytes, nil
        end,
        --: (string) -> nil
        write_out = function(msg) io.stdout:write(msg) end,
        --: (string) -> nil
        write_err = function(msg) io.stderr:write(msg) end,
    }
    return M.run(argv, caps)
end

return M
