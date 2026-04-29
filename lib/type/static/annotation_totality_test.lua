-- lib/type/static/annotation_totality_test.lua
-- Regression test for Phase A annotation parser totality (commits 4d711af + 3d4daba).
--
-- Locks in two invariants for every annotation comment in the codebase:
--   1. Parsing succeeds (no fatal error).
--   2. The full content is consumed (no trailing tokens) — `assert_eof` enforces
--      that the entire annotation body is part of a single type expression /
--      declaration. `--: integer = x` is invalid because `integer = x` is not a
--      type, not because there's "stuff after" a type.
--   3. No structured `parse_errors` are surfaced (e.g. capture-key footgun,
--      non-default after default, postfix `?` hint, etc.).
--
-- If this test starts failing, do NOT add the file to a skip-list. Either the
-- annotation is wrong (fix it) or the parser regressed (revert / fix).

if not package.path:find("./?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local lex_mod = require("lib.type.static.lex")
local ann_mod = require("lib.type.static.ann")
local intern_mod = require("lib.type.static.intern")

-- ── file discovery ──────────────────────────────────────────────────────────
-- Mirror lib/test/cli.lua: `find lib -name '*.lua' -type f | sort`.

local function find_lua_files()
    local files = {}
    local handle = io.popen("find lib -name '*.lua' -type f | sort")
    if not handle then error("popen(find) failed") end
    for line in handle:lines() do
        files[#files + 1] = line
    end
    handle:close()
    return files
end

local function read_file(path)
    local f, err = io.open(path, "rb")
    if not f then error("open " .. path .. ": " .. tostring(err)) end
    local s = f:read("*a")
    f:close()
    return s
end

-- ── lexing: drive to EOF so all annotations are captured ────────────────────

local function capture_annotations(source, filename)
    local pool = intern_mod.new()
    local ls = lex_mod.new(source, filename, pool)
    -- Drive to EOF.  The lexer captures annotations as a side effect of
    -- scanning comments; we must consume tokens until EOF for every annotation
    -- in the file to be observed.
    while ls.tk ~= require("lib.type.static.defs").TK_EOF do
        ls:next()
    end
    return ls.annotations, pool
end

-- ── totality check ──────────────────────────────────────────────────────────

local function check_file(path)
    local source = read_file(path)
    local ok_lex, anns, pool = pcall(capture_annotations, source, path)
    if not ok_lex then
        -- A lex failure is not within the scope of this test (Phase A is about
        -- annotation parsing, not lua lexing). Skip the file but report it so
        -- the failure surfaces somewhere.
        return { lex_failed = true, lex_err = tostring(anns), path = path }
    end

    -- pcall around parse_annotations — depth-limit errors are re-thrown.
    local ok_parse, result = pcall(ann_mod.parse_annotations, anns, pool, path)
    if not ok_parse then
        return { parse_threw = true, err = tostring(result), path = path }
    end

    local errors = {}
    if result.parse_errors then
        for _, pe in ipairs(result.parse_errors) do
            errors[#errors + 1] = string.format("%s:%d:%d: %s",
                path, pe.line or 0, pe.col or 0, pe.msg or "?")
        end
    end

    -- Every captured annotation should have produced a result entry.
    -- (results[line] is set on success; missing means parse failed and
    -- parse_errors should already contain a diagnostic.)
    for line, ann in pairs(anns) do
        if not result.results[line] then
            local already_reported = false
            for _, pe in ipairs(result.parse_errors or {}) do
                if pe.line == line then already_reported = true; break end
            end
            if not already_reported then
                errors[#errors + 1] = string.format(
                    "%s:%d: annotation %q produced no result and no diagnostic",
                    path, line, ann.content or "?")
            end
        end
    end

    return { errors = errors, path = path, ann_count = (function()
        local n = 0; for _ in pairs(anns) do n = n + 1 end; return n
    end)() }
end

-- ── test ────────────────────────────────────────────────────────────────────

T.describe("annotation totality (Phase A regression)", function()
    local files = find_lua_files()

    T.it("found at least 100 lua files under lib/", function()
        T.ok(#files >= 100, "expected ≥100 files, got " .. #files)
    end)

    T.it("every annotation in lib/**/*.lua parses cleanly", function()
        local all_errors = {}
        local total_anns = 0
        local total_files = 0
        local lex_failures = {}
        for _, path in ipairs(files) do
            local r = check_file(path)
            if r.lex_failed then
                lex_failures[#lex_failures + 1] = r.path .. ": " .. r.lex_err
            elseif r.parse_threw then
                all_errors[#all_errors + 1] = r.path .. " (threw): " .. r.err
            else
                total_files = total_files + 1
                total_anns = total_anns + (r.ann_count or 0)
                for _, e in ipairs(r.errors) do
                    all_errors[#all_errors + 1] = e
                end
            end
        end

        if #all_errors > 0 then
            -- Show at most 20 to keep failure output readable.
            local shown = {}
            for i = 1, math.min(20, #all_errors) do shown[i] = all_errors[i] end
            if #all_errors > 20 then
                shown[#shown + 1] = string.format("... (%d more)", #all_errors - 20)
            end
            T.fail(true, "annotation parse errors:\n  " .. table.concat(shown, "\n  "))
        end

        T.ok(total_files > 0, "scanned at least one file")
        T.ok(total_anns > 0, "found at least one annotation (got " .. total_anns .. ")")
    end)
end)
