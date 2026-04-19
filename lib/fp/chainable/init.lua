-- lib/fp/chainable/init.lua
-- Chainable typeclass: bind :: m a -> (a -> m b) -> m b
-- Extends Applicable. Also provides then_ and join as derived operations.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

--:: ChainableKey = $Opaque

local Chainable = {}

-- A fresh table used purely as an identity token for dispatch.
Chainable.key = {} --: ChainableKey

-- bind: sequence a chainable action, threading the inner value into f
function Chainable.bind(ma, f)
	return ma[Chainable.key].bind(ma, f)
end

-- then_: sequence two chainable actions, discard left result
function Chainable.then_(ma, mb)
	return Chainable.bind(ma, function(_) return mb end)
end

-- join: flatten m (m a) -> m a
function Chainable.join(mma)
	return Chainable.bind(mma, function(ma) return ma end)
end

return Chainable
