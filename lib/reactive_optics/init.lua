-- lib/reactive_optics/init.lua
-- Signals composed with optics from lib.fp.optics.
-- Thin composition layer: re-exports focused/narrowed from lib.reactive
-- with friendlier names and convenience constructors.
--
-- Depends on: lib.reactive, lib.fp.optics.lens, lib.fp.optics.prism

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local R    = require("lib.reactive")
local Lens = require("lib.fp.optics.lens")
local Prism = require("lib.fp.optics.prism")

local M = {}

-- Re-export core signal constructors for convenience.
M.signal   = R.signal
M.computed = R.computed
M.effect   = R.effect
M.batch    = R.batch

-- focus(signal, lens) -> Signal b
-- Read/write through a Lens. Same as signal.focus(lens).
M.focus = R.focused

-- narrow(signal, prism) -> Signal (b|nil)
-- Prism-focused signal for sum types. Same as signal.narrow(prism).
M.narrow = R.narrowed

-- field(signal, name) -> Signal signal_type[name]
-- Shorthand: focus on a single named field.
function M.field(sig, name)
	return R.focused(sig, Lens.field(name))
end

-- compose_focus(signal, lens1, lens2, ...) -> Signal T
-- Focus through a chain of lenses in one call.
function M.compose_focus(sig, ...)
	local lenses = {...}
	local lens = lenses[1]
	for i = 2, #lenses do
		lens = Lens.compose(lens, lenses[i])
	end
	return R.focused(sig, lens)
end

return M
