-- lib/reactive_optics/reactive_optics_test.lua

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T  = require("lib.test.assert")
local RO = require("lib.reactive_optics")
local Lens = require("lib.fp.optics.lens")
local Prism = require("lib.fp.optics.prism")
local Maybe = require("lib.fp.maybe")

T.describe("reactive_optics.field", function()
	T.it("get extracts named field", function()
		local s = RO.signal({name = "alice", age = 30})
		local sname = RO.field(s, "name")
		T.eq(sname.get(), "alice")
	end)

	T.it("set updates named field", function()
		local s = RO.signal({name = "alice", age = 30})
		local sname = RO.field(s, "name")
		sname.set("bob")
		T.eq(s.get().name, "bob")
		T.eq(s.get().age, 30)
	end)
end)

T.describe("reactive_optics.compose_focus", function()
	T.it("focuses through multiple lenses", function()
		local s = RO.signal({a = {b = {c = 42}}})
		local sc = RO.compose_focus(s, Lens.field("a"), Lens.field("b"), Lens.field("c"))
		T.eq(sc.get(), 42)
		sc.set(99)
		T.eq(s.get().a.b.c, 99)
	end)
end)

T.describe("reactive_optics.focus / narrow roundtrip", function()
	local shape_prism = Prism.new(
		function(s)
			if type(s) == "table" and s.kind == "circle" then
				return Maybe.just(s.radius)
			end
			return Maybe.nothing
		end,
		function(r)
			return {kind = "circle", radius = r}
		end
	)

	T.it("narrow then field-update roundtrips through source", function()
		local s = RO.signal({kind = "circle", radius = 5})
		local sr = RO.narrow(s, shape_prism)
		T.eq(sr.get(), 5)
		sr.set(10)
		T.eq(s.get().kind, "circle")
		T.eq(s.get().radius, 10)
	end)

	T.it("narrow returns nil for non-matching variant", function()
		local s = RO.signal({kind = "square", side = 4})
		local sr = RO.narrow(s, shape_prism)
		T.eq(sr.get(), nil)
	end)
end)
