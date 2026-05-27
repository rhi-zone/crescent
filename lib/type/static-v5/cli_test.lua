-- lib/type/static-v5/cli_test.lua
-- Unit tests for expand_dotted edge-case guards (Y7 fix).
--
-- The full expand_dotted integration is exercised in cli_e2e_test.lua (test #10).
-- This file focuses on the validation guards added in the Y7 fix: malformed keys
-- (empty segments) must raise, well-formed inputs must pass.
--
-- NOTE on prefix-vs-leaf: stdlib_types.lua intentionally adds both a leaf record
-- ("io") and dotted children ("io.write" etc.) for each stdlib namespace.  The
-- current expand_dotted behaviour treats dotted children as authoritative and
-- drops the leaf silently.  This is intentional redundancy, not a corruption
-- hazard: the leaf record and the synthesised record agree on fields.  The Y7
-- fix does NOT error on prefix-vs-leaf; that stop condition was triggered and
-- investigated — the data is correct.

if not package.path:find("./?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local T   = require("lib.test.assert")
local cli = require("lib.type.static-v5.cli")

-- ── Helpers ───────────────────────────────────────────────────────────────────

--: () -> V5Type
local function some_type()
    local types_mod = require("lib.type.experiments.v5_perf.types")
    return types_mod.const("string")
end

-- ── Tests ─────────────────────────────────────────────────────────────────────

T.describe("expand_dotted", function()

    -- Sanity: empty input.
    T.it("empty table produces empty table", function()
        local out = cli.expand_dotted({})
        local count = 0
        for _ in pairs(out) do count = count + 1 end
        T.eq(count, 0, "no keys in output")
    end)

    -- Sanity: dotted key becomes nested record.
    T.it("{[\"io.write\"] = T} becomes {io = {write = T}}", function()
        local T_STR = some_type()
        local T_NIL = some_type()
        local input = { ["io.write"] = T_STR, ["io.read"] = T_NIL }
        local out = cli.expand_dotted(input)
        T.ok(out["io"] ~= nil, "io key present")
        T.ok(out["io.write"] == nil, "dotted key absent")
        local io_rec = out["io"]
        if io_rec ~= nil then
            T.eq(io_rec.tag, "record", "io is a record")
            if io_rec.tag == "record" then
                T.ok(io_rec.fields["write"] ~= nil, "write field present")
            end
        end
    end)

    -- Malformed: solo dot.
    T.it("key \".\" errors", function()
        local v = some_type()
        T.throws(function()
            cli.expand_dotted({ ["."] = v })
        end, "key '.' must error")
    end)

    -- Malformed: empty string key.
    T.it("key \"\" errors", function()
        local v = some_type()
        T.throws(function()
            cli.expand_dotted({ [""] = v })
        end, "empty key must error")
    end)

    -- Malformed: leading dot.
    T.it("key \".foo\" errors", function()
        local v = some_type()
        T.throws(function()
            cli.expand_dotted({ [".foo"] = v })
        end, "key starting with '.' must error")
    end)

    -- Malformed: trailing dot.
    T.it("key \"foo.\" errors", function()
        local v = some_type()
        T.throws(function()
            cli.expand_dotted({ ["foo."] = v })
        end, "key ending with '.' must error")
    end)

    -- Malformed: consecutive dots.
    T.it("key \"foo..bar\" errors", function()
        local v = some_type()
        T.throws(function()
            cli.expand_dotted({ ["foo..bar"] = v })
        end, "key with '..' must error")
    end)

    -- Stop-condition check: prefix-vs-leaf is NOT an error.
    -- stdlib_types.lua passes both "io" (leaf record) and "io.write" etc.
    -- expand_dotted silently drops the leaf and uses the synthesised record.
    T.it("prefix-vs-leaf (\"foo\" leaf + \"foo.bar\" dotted) does NOT error", function()
        local T1 = some_type()
        local T2 = some_type()
        local input = { foo = T1, ["foo.bar"] = T2 }
        -- If this throws, the guard is too strict for stdlib usage.
        local out = cli.expand_dotted(input)
        -- The synthesised record wins; the leaf is dropped.
        T.ok(out["foo"] ~= nil, "foo key present (synthesised record)")
        T.ok(out["foo"].tag == "record", "foo is a record, not the plain leaf")
    end)

end)
