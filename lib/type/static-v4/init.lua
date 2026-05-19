-- Public entry point for the v4 typechecker foundation (phase 4a).
--
-- See README.md for module layout and scope. This file re-exports the type
-- constructors and the subtyping primitive in a single namespace.

if not package.path:find("?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T  = require("lib.type.static-v4.types")
local ST = require("lib.type.static-v4.subtype")
local IX = require("lib.type.static-v4.index")
local MA = require("lib.type.static-v4.match")

local M = {}

-- Type constructors.
M.top     = T.top
M.bot     = T.bot
M.prim    = T.prim
M.literal = T.literal
M.fn      = T.fn
M.rec     = T.rec
M.indexer = T.indexer
M.union   = T.union
M.inter   = T.inter
M.neg     = T.neg
M.var     = T.var
M.fix     = T.fix
M.mu      = T.mu
M.show    = T.show

-- Convenience primitive shortcuts (so tests don't all say M.prim("number")).
M.number  = T.prim("number")
M.integer = T.prim("integer")
M.string_ = T.prim("string")
M.boolean = T.prim("boolean")
M.nil_    = T.prim("nil")
M.cdata   = T.prim("cdata")

-- Subtyping.
M.new_solver = ST.new_solver
M.constrain  = ST.constrain
M.subtype    = ST.subtype

-- Indexed access (Phase 4b.2).
M.index   = IX.index

-- Match types (Phase 4d).
M.match            = MA.match
M.match_forward    = MA.forward
M.match_backward   = MA.backward
M.arm              = MA.arm

-- Test affordances.
M._reset_var_ids = T._reset_var_ids
M._reset_mu_ids  = T._reset_mu_ids

return M
