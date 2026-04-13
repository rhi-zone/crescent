-- lib/formats/ccv2/init.lua
-- CCv2 (Character Card v2) format library.
-- Vendorable: apps copy this directory into their tarball.
--
-- Submodules:
--   ccv2.macro    — SillyTavern-compatible {{macro}} substitution
--   ccv2.lorebook — lorebook format conversion (CCv2 <-> ST) + trigger scanning

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

M.card     = require("lib.formats.ccv2.card")
M.macro    = require("lib.formats.ccv2.macro")
M.lorebook = require("lib.formats.ccv2.lorebook")

return M
