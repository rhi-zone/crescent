-- lib/type/static-v5/cli_e2e_test.lua
-- End-to-end fixtures for the v5 CLI pipeline.
--
-- Drives `cli.run` with a fake caps table that captures output into strings;
-- does NOT touch the filesystem or real I/O.

if not package.path:find("./?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local T   = require("lib.test.assert")
local cli = require("lib.type.static-v5.cli")

-- ── Fake caps factory ─────────────────────────────────────────────────────────

--: (string) -> { caps: V5CliCaps, out: () -> string, err: () -> string }
local function fake_caps(source)
    local out_buf = {} --[[: { [integer]: string } ]]
    local err_buf = {} --[[: { [integer]: string } ]]
    --: V5CliCaps
    local caps = {
        --: (string) -> (string | nil, string | nil)
        read_file = function(_path)
            return source, nil
        end,
        --: (string) -> nil
        write_out = function(msg)
            out_buf[#out_buf + 1] = msg
        end,
        --: (string) -> nil
        write_err = function(msg)
            err_buf[#err_buf + 1] = msg
        end,
    }
    return {
        caps = caps,
        --: () -> string
        out  = function() return table.concat(out_buf) end,
        --: () -> string
        err  = function() return table.concat(err_buf) end,
    }
end

-- Run source through cli.run; return exit_code, stdout, stderr.
--: (string, string) -> (integer, string, string)
local function run(source, filename)
    local fc = fake_caps(source)
    local code = cli.run({ filename or "test.lua" }, fc.caps)
    return code, fc.out(), fc.err()
end

-- ── Tests ─────────────────────────────────────────────────────────────────────

T.describe("v5 cli e2e", function()

    -- 1. Pure annotated function — no effects.
    T.it("pure annotated function typechecks clean", function()
        local src = "--: (number) -> number\nlocal function f(x) return x + 1 end"
        local code, out, _err = run(src, "pure.lua")
        T.eq(code, 0, "exit 0")
        T.eq(out, "", "no output")
    end)

    -- 2. Unannotated function calling io.write — effects inferred, no error.
    T.it("unannotated io.write call has no error", function()
        local src = "local function f() io.write('x') end"
        local code, _out, _err = run(src, "unannotated_io.lua")
        -- Unannotated function: effects are accumulated and folded into inferred
        -- return type; no F2 enforcement (no annotation to check against).
        T.eq(code, 0, "exit 0 — effects accumulated silently for unannotated fn")
    end)

    -- 3. Annotated () -> nil body calls print (direct-bound !io) — !io NOT in annotation.
    --    This should surface an F2 error (CIntersectionMember stuck).
    --    print is a direct stdlib binding and propagates !io immediately.
    T.it("annotated () -> nil calling print surfaces F2 error", function()
        local src = "--: () -> nil\nlocal function f() print('x') end"
        local code, out, _err = run(src, "f2_io.lua")
        T.eq(code, 1, "exit 1 (F2 violation)")
        -- The solver emits a CIntersectionMember error for missing !io.
        T.ok(out ~= "", "error output produced")
    end)

    -- 3b. 5.F1 fix: annotated () -> nil body calls io.write (dotted callee).
    --     Previously silent (uvar at gen time); after fix, F2 fires.
    T.it("5.F1: annotated () -> nil calling io.write (dotted) surfaces F2 error", function()
        local src = "--: () -> nil\nlocal function f() io.write('x') end"
        local code, out, _err = run(src, "f2_io_write.lua")
        T.eq(code, 1, "exit 1 (F2 violation — dotted callee)")
        T.ok(out ~= "", "error output produced for io.write F2")
        -- The error message references CIntersectionMember (rule name in solver output).
        T.ok(out:find("CIntersectionMember") ~= nil or out:find("cint") ~= nil or out:find("!io") ~= nil,
            "error message references effect enforcement")
    end)

    -- 3c. 5.F1 negative: annotated () -> nil & !io calling io.write — should be clean.
    T.it("5.F1: annotated () -> nil & !io calling io.write is clean", function()
        local src = "--: () -> nil & !io\nlocal function f() io.write('x') end"
        local code, _out, _err = run(src, "f2_io_write_ok.lua")
        T.eq(code, 0, "exit 0 — !io in annotation satisfies F2")
    end)

    -- 4. Annotated function raises error() — !throw not in annotation.
    --    Should surface F2 error for !throw.
    T.it("annotated () -> nil calling error() surfaces F2 error", function()
        local src = "--: () -> nil\nlocal function f() error('boom') end"
        local code, out, _err = run(src, "f2_throw.lua")
        T.eq(code, 1, "exit 1 (F2 !throw)")
        T.ok(out ~= "", "error output produced")
    end)

    -- 5. pcall consuming a throwing function — !throw absorbed, outer fn is clean.
    T.it("pcall absorbs !throw from callee", function()
        local src = [[
--: () -> nil
local function safe()
    local ok, _ = pcall(function()
        error("boom")
    end)
    _ = ok
end
]]
        local code, _out, _err = run(src, "pcall_absorbs.lua")
        -- pcall is treated as an effect sink: the !throw from error() is
        -- not propagated out of pcall, so the outer annotation () -> nil is met.
        T.eq(code, 0, "exit 0 — pcall absorbs !throw")
    end)

    -- 5b. 5.F2: pcall on a throwing function — outer annotated pure fn is clean.
    --     Verifies pcall consumes !throw; outer () -> nil annotation satisfied.
    T.it("5.F2: pcall on throwing fn in annotated pure fn is clean", function()
        local src = [[
--: () -> nil
local function safe_div()
    local ok = pcall(function()
        error("oops")
    end)
    local _ = ok
end
]]
        local code, _out, _err = run(src, "pcall_f2.lua")
        T.eq(code, 0, "exit 0 — pcall consumes !throw, outer annotation satisfied")
    end)

    -- 5c. 5.F2: pcall return type is a union — can be used as unknown without error.
    --     Test via subtyping-via-annotation: annotate ok as unknown (should pass).
    T.it("5.F2: pcall return annotated as unknown typechecks", function()
        local src = [[
local function f()
    --: unknown
    local ok = pcall(function() end)
    local _ = ok
end
]]
        local code, _out, _err = run(src, "pcall_ret_unknown.lua")
        T.eq(code, 0, "exit 0 — pcall return is compatible with unknown")
    end)

    -- 5d. 5.F2: !throw NOT consumed without pcall — F2 fires as before.
    --     Verify the negative: plain error() in annotated pure fn still errors.
    T.it("5.F2 negative: error() in annotated pure fn still triggers F2", function()
        local src = "--: () -> nil\nlocal function f() error('x') end"
        local code, out, _err = run(src, "f2_throw_negative.lua")
        T.eq(code, 1, "exit 1 — error() without pcall still triggers F2")
        T.ok(out ~= "", "error output produced")
    end)

    -- 6. Mixed !throw & !io on one annotated function — both effects in
    --    annotation — typechecks clean.
    --    We exercise this by calling both io.write and error() in the body,
    --    but without an annotation (unannotated path; effects inferred).
    T.it("unannotated mixed !io + !throw call is clean", function()
        local src = [[
local function f(x)
    if x == nil then error("nil") end
    io.write(tostring(x))
end
]]
        local code, _out, _err = run(src, "mixed.lua")
        T.eq(code, 0, "exit 0 — unannotated mixed effects inferred")
    end)

    -- 7. No files argument returns exit code 2.
    T.it("no files argument returns exit 2", function()
        local fc = fake_caps("")
        local code = cli.run({}, fc.caps)
        T.eq(code, 2, "exit 2 — missing file argument")
    end)

    -- 8. Unknown flag returns exit 2.
    T.it("unknown flag returns exit 2", function()
        local fc = fake_caps("")
        local code = cli.run({ "--unknown-flag", "foo.lua" }, fc.caps)
        T.eq(code, 2, "exit 2 — unknown flag")
    end)

    -- 9. Unreadable file returns exit 1.
    T.it("unreadable file returns exit 1", function()
        --: V5CliCaps
        local caps = {
            --: (string) -> (string | nil, string | nil)
            read_file = function(_p) return nil, "no such file" end,
            --: (string) -> nil
            write_out = function(_m) end,
            --: (string) -> nil
            write_err = function(_m) end,
        }
        local code = cli.run({ "missing.lua" }, caps)
        T.eq(code, 1, "exit 1 — file not found")
    end)

    -- 10. expand_dotted helper: dotted keys become records.
    T.it("expand_dotted flattens dotted keys into records", function()
        local types_mod = require("lib.type.experiments.v5_perf.types")
        local T_STR = types_mod.const("string")
        local T_NIL = types_mod.const("nil")
        local raw = {
            ["io.write"] = T_NIL,
            ["io.read"]  = T_STR,
            foo          = T_STR,
        }
        local expanded = cli.expand_dotted(raw)
        T.ok(expanded["foo"] ~= nil, "plain key preserved")
        local io_rec = expanded["io"]
        T.ok(io_rec ~= nil, "io record synthesized")
        if io_rec ~= nil then
            T.eq(io_rec.tag, "record", "io is a record")
            if io_rec.tag == "record" then
                T.ok(io_rec.fields["write"] ~= nil, "io.write field present")
                T.ok(io_rec.fields["read"] ~= nil, "io.read field present")
            end
        end
        -- Dotted keys themselves should NOT appear.
        T.ok(expanded["io.write"] == nil, "dotted key absent from output")
    end)

end)
