-- lib/type/static/v2/init.lua
-- v2 typechecker foundation: FFI-backed flat data structures and lexer.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local defs   = require("lib.type.static.v2.defs")
local intern = require("lib.type.static.v2.intern")
local arena  = require("lib.type.static.v2.arena")
local lex    = require("lib.type.static.v2.lex")

return {
    defs   = defs,
    intern = intern,
    arena  = arena,
    lex    = lex,
}
