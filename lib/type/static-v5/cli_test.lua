-- lib/type/static-v5/cli_test.lua
-- Unit tests for cli.lua.
--
-- expand_dotted was removed (refactor: stdlib_types.lua now emits nested
-- records directly; no expansion step is needed).  The unit tests that
-- targeted expand_dotted's malformed-key guards and the dotted→record
-- conversion have been removed along with the function.
--
-- Integration coverage for the cli pipeline lives in cli_e2e_test.lua.

if not package.path:find("./?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local T   = require("lib.test.assert")
local cli = require("lib.type.static-v5.cli") --[[: unknown]]

-- Silence the unused-require warning: cli is loaded to confirm it loads
-- cleanly after the expand_dotted removal.
local _ = cli

T.describe("cli", function()
    T.it("module loads without error", function()
        T.ok(cli ~= nil, "cli module loaded")
    end)
end)
