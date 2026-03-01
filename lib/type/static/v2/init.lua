-- lib/type/static/v2/init.lua
-- v2 typechecker: FFI-backed flat data structures, lexer, parser, annotations.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local defs   = require("lib.type.static.v2.defs")
local intern = require("lib.type.static.v2.intern")
local arena  = require("lib.type.static.v2.arena")
local lex    = require("lib.type.static.v2.lex")
local parse  = require("lib.type.static.v2.parse")
local ann    = require("lib.type.static.v2.ann")

return {
    defs   = defs,
    intern = intern,
    arena  = arena,
    lex    = lex,
    parse  = parse,
    ann    = ann,
}
