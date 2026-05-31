-- lib/type/static-v6/cli_test.lua
-- v6 CLI tests.

if not package.path:find("./?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")

local cli = require("lib.type.static-v6.cli")

--: ({ [string]: string }) -> V6CliCaps
local function caps_for(files)
    local out = {}
    local err = {}
    return {
        read_file = function(path)
            local src = files[path]
            if src == nil then return nil, "missing " .. path end
            return src, nil
        end,
        write_out = function(msg) out[#out + 1] = msg end,
        write_err = function(msg) err[#err + 1] = msg end,
        is_tty = function(_fd) return false end,
        _out = out,
        _err = err,
    }
end

T.describe("v6 CLI", function()
    T.it("requires at least one file", function()
        local caps = caps_for({})
        local code = cli.run({ "--v6" }, caps)
        T.eq(code, 2)
        T.eq(caps._err[1], "cr check --v6: at least one file is required\n")
    end)

    T.it("checks clean files", function()
        local caps = caps_for({ ["ok.lua"] = "--: number\nlocal x = 1\n" })
        local code = cli.run({ "ok.lua" }, caps)
        T.eq(code, 0)
        T.eq(#caps._out, 0)
        T.eq(#caps._err, 0)
    end)

    T.it("formats source diagnostics", function()
        local caps = caps_for({ ["bad.lua"] = "--: number\nlocal x = 's'\n" })
        local code = cli.run({ "bad.lua" }, caps)
        T.eq(code, 1)
        T.eq(caps._out[1], "bad.lua:2:1: TYPE_MISMATCH: \"s\" is not a subtype of number\n")
    end)

    T.it("reports read errors as diagnostics", function()
        local caps = caps_for({})
        local code = cli.run({ "missing.lua" }, caps)
        T.eq(code, 1)
        T.eq(caps._out[1], "missing.lua: IO_ERROR: cannot read file: missing missing.lua\n")
    end)
end)
