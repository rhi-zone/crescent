-- lib/type/static/v2/init.lua
-- v2 typechecker: FFI-backed flat data structures, lexer, parser, annotations, checker.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local defs   = require("lib.type.static.v2.defs")
local intern = require("lib.type.static.v2.intern")
local arena  = require("lib.type.static.v2.arena")
local lex    = require("lib.type.static.v2.lex")
local parse  = require("lib.type.static.v2.parse")
local ann    = require("lib.type.static.v2.ann")
local types  = require("lib.type.static.v2.types")
local env    = require("lib.type.static.v2.env")
local unify  = require("lib.type.static.v2.unify")
local errors = require("lib.type.static.v2.errors")
local match  = require("lib.type.static.v2.match")
local narrow = require("lib.type.static.v2.narrow")
local infer  = require("lib.type.static.v2.infer")
local check  = require("lib.type.static.v2.check")

return {
    defs   = defs,
    intern = intern,
    arena  = arena,
    lex    = lex,
    parse  = parse,
    ann    = ann,
    types  = types,
    env    = env,
    unify  = unify,
    errors = errors,
    match  = match,
    narrow = narrow,
    infer  = infer,
    check  = check,
}
