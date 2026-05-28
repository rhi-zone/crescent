-- lib/type/static-v5/cli.lua
-- v5 typechecker CLI entry point.
--
-- Invoked via `bin/cr check --v5 [--summary] <file>...`
-- (bin/cr-check.lua dispatches here when `--v5` is present in argv).
--
-- Pipeline:
--   Read file -> parse.lua -> constrain.lua (opts.decls = stdlib.decls())
--   -> op_sem.lua -> format errors -> exit code.
--
-- stdlib.decls() returns nested records directly (io, os, coroutine as TRecord).
-- No expansion step is needed.
--
-- All I/O is via injected caps; no global io/os references in the library.

if not package.path:find("?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local constrain_mod = require("lib.type.static-v5.constrain")
local op_sem        = require("lib.type.static-v5.op_sem")
local stdlib_mod    = require("lib.type.static-v5.stdlib_types")
local error_format  = require("lib.type.static-v5.error_format")
local ann_mod       = require("lib.type.static-v5.ann")

local M = {}

-- ── Run one file through the v5 pipeline ────────────────────────────────────
--
-- caps.read_file  : (string) -> (string | nil, string | nil)
-- caps.write_out  : (string) -> nil   — stdout
-- caps.write_err  : (string) -> nil   — stderr
--
-- Returns an integer exit code (0 = clean, 1 = errors, 2 = bad invocation).

--:: V5CliCaps = { read_file: (path: string) -> (string | nil, string | nil), write_out: (msg: string) -> nil, write_err: (msg: string) -> nil, is_tty: ((unknown) -> boolean) | nil }

--: (string, V5CliCaps) -> { errors: OpSemError[], gen_errors: string[], source: string | nil }
local function check_one(path, caps)
    local source, ferr = caps.read_file(path)
    if source == nil then
        return {
            errors = { { rule = "io", msg = "cannot read file: " .. (ferr or path), prov = nil, details = nil } } --[[: OpSemError[] ]],
            gen_errors = {} --[[: string[] ]],
            source = nil,
        }
    end

    -- Create a fresh per-file annotation state and register stdlib effects into it.
    -- This isolates row-var IDs and effect arities across multiple files checked
    -- in the same process (fixes R7 + R8).
    local ann_state = ann_mod.new_state()
    stdlib_mod.register_effects(ann_state)

    -- stdlib.decls() returns nested records directly.
    local decls = stdlib_mod.decls()

    -- Generate constraints, threading the ann_state so all annotation parsing
    -- within this file uses the same isolated state.
    local constraints, gen_errors = constrain_mod.generate(source, path, { decls = decls, ann_state = ann_state })

    -- Solve.
    --: OpSemState
    local st = op_sem.new_state()
    for _, c in ipairs(constraints) do
        op_sem.emit(st, c)
    end
    op_sem.run(st)

    return { errors = st.errors, gen_errors = gen_errors, source = source }
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
    --: OpSemError[]
    local all_solver = {}
    --: { [string]: string }
    local sources_by_path = {}

    for _, path in ipairs(opts.files) do
        local result = check_one(path, caps)

        local src = result.source
        if src ~= nil then
            sources_by_path[path] = src
        end

        -- Gen-pass errors (annotation parse, etc.) are always printed.
        for _, ge in ipairs(result.gen_errors) do
            lines[#lines + 1] = ge
            any_error = true
        end

        -- Solver errors: collect into a single batch.  When an error's
        -- provenance doesn't carry a file (e.g. io read failures), inject
        -- a synthetic prov so the formatter knows which file to attribute.
        for _, se in ipairs(result.errors) do
            if se.prov == nil then
                se.prov = { file = path, line = 0, col = 0, kind = "io" }
            end
            all_solver[#all_solver + 1] = se
            any_error = true
        end
    end

    if #all_solver > 0 then
        local color = false
        local tty_fn = caps.is_tty
        if tty_fn ~= nil then color = tty_fn(1) end
        local formatted = error_format.format(all_solver, sources_by_path, { color = color })
        lines[#lines + 1] = formatted
    end

    if #lines > 0 then
        caps.write_out(table.concat(lines, "\n") .. "\n")
    end

    return any_error and 1 or 0
end

return M
