-- lib/type/static-v6/init.lua
-- Public entry point for the v6 checker prototype.

return {
    types = require("lib.type.static-v6.types"),
    normalize = require("lib.type.static-v6.normalize"),
    subtype = require("lib.type.static-v6.subtype"),
    diagnostics = require("lib.type.static-v6.diagnostics"),
    facts = require("lib.type.static-v6.facts"),
    env = require("lib.type.static-v6.env"),
}
