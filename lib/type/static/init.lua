-- lib/type/static/init.lua
-- typechecker: FFI-backed flat data structures, lexer, parser, annotations, checker.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local defs   = require("lib.type.static.defs")
local intern = require("lib.type.static.intern")
local arena  = require("lib.type.static.arena")
local lex    = require("lib.type.static.lex")
local parse  = require("lib.type.static.parse")
local ann    = require("lib.type.static.ann")
local types  = require("lib.type.static.types")
local env    = require("lib.type.static.env")
local unify  = require("lib.type.static.unify")
local errors = require("lib.type.static.errors")
local match  = require("lib.type.static.match")
local narrow = require("lib.type.static.narrow")
local infer  = require("lib.type.static.infer")
local check  = require("lib.type.static.check")

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
