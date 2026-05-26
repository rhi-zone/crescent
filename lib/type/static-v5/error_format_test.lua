-- lib/type/static-v5/error_format_test.lua
-- Snapshot tests for the v5 error formatter.
--
-- Each case drives cli.run with a source string that triggers one error rule,
-- then snapshots the plain-text output (no ANSI).  Snapshot files live under
-- lib/type/static-v5/__snapshots__/.  Run with UPDATE_SNAPSHOTS=1 to
-- regenerate after intentional message changes.
--
-- For rules where constructing a minimal end-to-end source fixture is
-- straightforward, we use cli.run (parse → constrain → solve → format).
-- For rules that are hard to trigger from user source (e.g. they require
-- type-level constructs not yet emittable from the gen-pass), we call
-- error_format.render_prose directly with hand-built details and snapshot
-- the prose string.  Each such fallback is marked "# prose-only" below.

if not package.path:find("./?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local T       = require("lib.test.assert")
local fixture = require("lib.test.fixture")
local cli     = require("lib.type.static-v5.cli")
local ef      = require("lib.type.static-v5.error_format")

local SNAP_DIR = "lib/type/static-v5/__snapshots__"

-- ── Helpers ───────────────────────────────────────────────────────────────────

-- Run source through cli.run with a fake caps table that captures output.
-- Returns plain-text error output (what was written to write_out).
--: (string, string) -> string
local function run_plain(source, filename)
    local out_buf = {} --[[: { [integer]: string } ]]
    --: V5CliCaps
    local caps = {
        --: (string) -> (string | nil, string | nil)
        read_file = function(_path) return source, nil end,
        --: (string) -> nil
        write_out = function(msg) out_buf[#out_buf + 1] = msg end,
        --: (string) -> nil
        write_err = function(_msg) end,
        --: (unknown) -> boolean
        is_tty = function(_fd) return false end,
    }
    cli.run({ filename or "test.lua" }, caps)
    return table.concat(out_buf)
end

-- Register a snapshot test.
-- The snapshot is stored at SNAP_DIR/name.expected.
-- On first run (UPDATE_SNAPSHOTS=1), creates the file.
-- On subsequent runs, asserts output matches the snapshot.
--: (string, () -> string) -> nil
local function snap(name, producer)
    local snap_path = SNAP_DIR .. "/" .. name .. ".expected"
    T.it(name, function()
        local actual = producer()
        local update = os.getenv("UPDATE_SNAPSHOTS") == "1"
        if update then
            local fw, ferr = io.open(snap_path, "wb")
            if fw == nil then error("cannot write snapshot: " .. snap_path .. ": " .. tostring(ferr)) end
            fw:write(actual)
            fw:close()
            return  -- pass in update mode
        end
        local fr = io.open(snap_path, "rb")
        if fr == nil then
            error("no snapshot at " .. snap_path .. "\nrun with UPDATE_SNAPSHOTS=1 to create it\nActual output:\n" .. actual)
        end
        local expected = fr:read("*all")
        fr:close()
        if actual ~= expected then
            -- Build a simple diff hint.
            local msg = "snapshot mismatch: " .. snap_path .. "\n"
            local diff = fixture.diff(expected or "", actual)
            if #diff > 0 then
                msg = msg .. table.concat(diff, "\n")
            else
                msg = msg .. "(outputs differ but diff is empty)"
            end
            error(msg)
        end
    end)
end

-- ── E2E snapshot cases ────────────────────────────────────────────────────────

T.describe("v5 error_format snapshots", function()

    -- T-CIntersectionMember-Direct / S-Quiesce-CIntersectionMember
    -- THE F2 trigger: annotated pure function calls io.write.
    -- This is the primary user-cited rule (F2 in the design).
    snap("T-CIntersectionMember-Direct__F2_pure_io_write", function()
        local src = "--: () -> nil\nlocal function f() io.write('x') end"
        return run_plain(src, "f2_io_write.lua")
    end)

    -- T-CIntersectionMember-Direct / direct case: intersection present but missing effect.
    -- Annotated with !io but body calls error() (!throw not in annotation).
    snap("T-CIntersectionMember-Direct__effect_not_in_intersection", function()
        local src = "--: () -> nil & !io\nlocal function f() error('boom') end"
        return run_plain(src, "f2_missing_throw.lua")
    end)

    -- T-CEq-Const (const mismatch): annotating a number variable as string.
    snap("T-CEq-Const__const_mismatch", function()
        local src = "--: string\nlocal x = 42"
        return run_plain(src, "const_mismatch.lua")
    end)

    -- T-CSub-Record-Width (missing field): record subtype is missing a required field.
    snap("T-CSub-Record-Width__missing_field", function()
        local src = [[
--: { x: number, y: number }
local v = { x = 1 }
]]
        return run_plain(src, "missing_field.lua")
    end)

    -- T-CSub-Mismatch (kind mismatch): function annotated as returning string, body returns number.
    snap("T-CSub-Mismatch__kind_mismatch", function()
        local src = "--: () -> string\nlocal function f() return 42 end"
        return run_plain(src, "kind_mismatch.lua")
    end)

    -- T-CSub-Arrow (arity mismatch): annotated 2-arg function given 1-arg call shape.
    snap("T-CSub-Arrow-Arity__arity_mismatch", function()
        local src = "--: (number, number) -> number\nlocal function f(x) return x end"
        return run_plain(src, "arity_mismatch.lua")
    end)

    -- T-CSub-Union-R (no matching branch): value type not in union.
    -- Achieved by annotating a variable as boolean | nil but assigning a number.
    snap("T-CSub-Union-R__no_matching_branch", function()
        local src = "--: boolean\nlocal x = 42"
        return run_plain(src, "union_r.lua")
    end)

    -- ── Prose-only cases (rules not yet reachable from surface syntax) ──────────
    -- These call render_prose directly.  Marked prose-only.

    snap("prose-only__occurs_check", function()
        --: ErrorDetails
        local det = { tag = "occurs_check", a_name = "?1" }
        return ef.render_prose("T-CEq-Occurs", det, "occurs check failed") .. "\n"
    end)

    snap("prose-only__intersection_arity_mismatch", function()
        --: ErrorDetails
        local det = { tag = "intersection_arity_mismatch", expected = 3, got = 2 }
        return ef.render_prose("T-CIntersectionEq-Canonical", det, "intersection arity mismatch") .. "\n"
    end)

    snap("prose-only__all_parts_unresolved", function()
        --: ErrorDetails
        local det = { tag = "all_parts_unresolved" }
        return ef.render_prose("T-CSub-Intersection-Decomp", det, "all parts unresolved") .. "\n"
    end)

    snap("prose-only__sealed_field_set", function()
        --: ErrorDetails
        local det = { tag = "sealed_field_set", field = "count" }
        return ef.render_prose("T-CTSet-Sealed-Reject", det, "sealed reject") .. "\n"
    end)

    snap("prose-only__missing_method", function()
        --: ErrorDetails
        local det = { tag = "missing_method", method = "push" }
        return ef.render_prose("T-CMCall-Sealed-Missing", det, "no method push") .. "\n"
    end)

    snap("prose-only__not_a_record", function()
        --: ErrorDetails
        local det = { tag = "not_a_record", found_tag = "const" }
        return ef.render_prose("T-CRowExtend", det, "not a record") .. "\n"
    end)

    snap("prose-only__ambiguous_constructor", function()
        --: ErrorDetails
        local det = { tag = "ambiguous_constructor" }
        return ef.render_prose("T-HOUnify-Stuck", det, "ambiguous constructor") .. "\n"
    end)

    snap("prose-only__effect_not_permitted__pure", function()
        local types_mod = require("lib.type.experiments.v5_perf.types")
        --: ErrorDetails
        local det = {
            tag = "effect_not_permitted",
            effect = types_mod.const("!io"),
            container = types_mod.const("nil"),
        }
        return ef.render_prose("T-CIntersectionMember-Direct", det, "effect not permitted") .. "\n"
    end)

    snap("prose-only__effect_not_permitted__intersection", function()
        local types_mod = require("lib.type.experiments.v5_perf.types")
        local eff_io    = types_mod.const("!io")
        local eff_throw = types_mod.const("!throw") --[[: V5Type ]]
        local parts     = { eff_throw } --[[: V5Type[] ]]
        --: ErrorDetails
        local det = {
            tag = "effect_not_permitted",
            effect = eff_io,
            container = types_mod.intersection(parts),
        }
        return ef.render_prose("T-CIntersectionMember-Direct", det, "effect not permitted") .. "\n"
    end)

    snap("prose-only__effect_not_permitted__quiescence", function()
        local types_mod = require("lib.type.experiments.v5_perf.types")
        --: ErrorDetails
        local det = {
            tag = "effect_not_permitted",
            effect = types_mod.const("!io"),
            container = nil,
        }
        return ef.render_prose("S-Quiesce-CIntersectionMember", det, "effect not permitted") .. "\n"
    end)

    snap("prose-only__closed_extend", function()
        --: ErrorDetails
        local det = { tag = "closed_extend", field = "z" }
        return ef.render_prose("T-CRowExtend-Closed", det, "closed extend") .. "\n"
    end)

    snap("prose-only__row_already_contains", function()
        --: ErrorDetails
        local det = { tag = "row_already_contains", field = "x" }
        return ef.render_prose("T-CRowLacks-Closed-Fail", det, "row already contains") .. "\n"
    end)

    snap("prose-only__show_sort_union", function()
        -- Verify union rendering is lexically sorted (deterministic).
        local types_mod = require("lib.type.experiments.v5_perf.types")
        local u = types_mod.union({
            types_mod.const("string"),
            types_mod.const("boolean"),
            types_mod.const("nil"),
            types_mod.const("integer"),
        })
        return ef.show(u) .. "\n"
    end)

    snap("prose-only__show_sort_intersection", function()
        -- Verify intersection rendering is lexically sorted (deterministic).
        local types_mod = require("lib.type.experiments.v5_perf.types")
        local i = types_mod.intersection({
            types_mod.const("!throw"),
            types_mod.const("!io"),
            types_mod.const("!yield"),
        })
        return ef.show(i) .. "\n"
    end)

end)
