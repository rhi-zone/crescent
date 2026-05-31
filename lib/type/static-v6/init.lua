-- lib/type/static-v6/init.lua
-- Public entry point for the v6 checker prototype.

return {
    ann = require("lib.type.static-v6.ann"),
    types = require("lib.type.static-v6.types"),
    normalize = require("lib.type.static-v6.normalize"),
    packs = require("lib.type.static-v6.packs"),
    source = require("lib.type.static-v6.source"),
    subtype = require("lib.type.static-v6.subtype"),
    diagnostics = require("lib.type.static-v6.diagnostics"),
    facts = require("lib.type.static-v6.facts"),
    env = require("lib.type.static-v6.env"),
}
