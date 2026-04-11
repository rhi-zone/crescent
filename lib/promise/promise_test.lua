-- lib/promise/promise_test.lua

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local promise = require("lib.promise")

---------------------------------------------------------------------------
-- resolve / reject basics
---------------------------------------------------------------------------
T.describe("promise.resolve", function()
	T.it("creates a fulfilled promise", function()
		local p = promise.resolve(42)
		T.eq(p:state(), "fulfilled")
		T.eq(p:value(), 42)
		T.eq(p:reason(), nil)
	end)

	T.it("resolves with nil value", function()
		local p = promise.resolve(nil)
		T.eq(p:state(), "fulfilled")
		T.eq(p:value(), nil)
	end)

	T.it("resolves with a string", function()
		local p = promise.resolve("hello")
		T.eq(p:value(), "hello")
	end)

	T.it("resolves with a table", function()
		local t = {1, 2, 3}
		local p = promise.resolve(t)
		T.eq(p:value(), t)
	end)
end)

T.describe("promise.reject", function()
	T.it("creates a rejected promise", function()
		local p = promise.reject("err")
		T.eq(p:state(), "rejected")
		T.eq(p:reason(), "err")
		T.eq(p:value(), nil)
	end)

	T.it("rejects with a table reason", function()
		local r = {code = 404}
		local p = promise.reject(r)
		T.eq(p:reason(), r)
	end)
end)

---------------------------------------------------------------------------
-- promise.new
---------------------------------------------------------------------------
T.describe("promise.new", function()
	T.it("resolves via executor", function()
		local p = promise.new(function(resolve)
			resolve(10)
		end)
		T.eq(p:state(), "fulfilled")
		T.eq(p:value(), 10)
	end)

	T.it("rejects via executor", function()
		local p = promise.new(function(_, reject)
			reject("bad")
		end)
		T.eq(p:state(), "rejected")
		T.eq(p:reason(), "bad")
	end)

	T.it("executor error rejects the promise", function()
		local p = promise.new(function()
			error("boom")
		end)
		T.eq(p:state(), "rejected")
		T.ok(p:reason():find("boom"))
	end)

	T.it("second resolve is ignored", function()
		local p = promise.new(function(resolve)
			resolve(1)
			resolve(2)
		end)
		T.eq(p:value(), 1)
	end)

	T.it("reject after resolve is ignored", function()
		local p = promise.new(function(resolve, reject)
			resolve(1)
			reject("err")
		end)
		T.eq(p:state(), "fulfilled")
		T.eq(p:value(), 1)
	end)
end)

---------------------------------------------------------------------------
-- and_then
---------------------------------------------------------------------------
T.describe("and_then", function()
	T.it("maps the fulfilled value", function()
		local p = promise.resolve(5):and_then(function(v) return v * 2 end)
		T.eq(p:value(), 10)
	end)

	T.it("chains multiple and_then calls", function()
		local p = promise.resolve(1)
			:and_then(function(v) return v + 1 end)
			:and_then(function(v) return v + 1 end)
			:and_then(function(v) return v + 1 end)
		T.eq(p:value(), 4)
	end)

	T.it("skips and_then on rejected promise", function()
		local called = false
		local p = promise.reject("err"):and_then(function()
			called = true
			return 99
		end)
		T.eq(called, false)
		T.eq(p:state(), "rejected")
		T.eq(p:reason(), "err")
	end)

	T.it("handler error rejects the child", function()
		local p = promise.resolve(1):and_then(function()
			error("handler fail")
		end)
		T.eq(p:state(), "rejected")
		T.ok(p:reason():find("handler fail"))
	end)

	T.it("unwraps nested promise from handler", function()
		local p = promise.resolve(1):and_then(function(v)
			return promise.resolve(v + 10)
		end)
		T.eq(p:state(), "fulfilled")
		T.eq(p:value(), 11)
	end)

	T.it("unwraps nested rejected promise from handler", function()
		local p = promise.resolve(1):and_then(function()
			return promise.reject("inner err")
		end)
		T.eq(p:state(), "rejected")
		T.eq(p:reason(), "inner err")
	end)
end)

---------------------------------------------------------------------------
-- catch
---------------------------------------------------------------------------
T.describe("catch", function()
	T.it("handles rejection", function()
		local p = promise.reject("err"):catch(function(r)
			return "recovered from " .. r
		end)
		T.eq(p:state(), "fulfilled")
		T.eq(p:value(), "recovered from err")
	end)

	T.it("skips catch on fulfilled promise", function()
		local called = false
		local p = promise.resolve(42):catch(function()
			called = true
			return "nope"
		end)
		T.eq(called, false)
		T.eq(p:value(), 42)
	end)

	T.it("catch handler error rejects", function()
		local p = promise.reject("err"):catch(function()
			error("catch fail")
		end)
		T.eq(p:state(), "rejected")
		T.ok(p:reason():find("catch fail"))
	end)

	T.it("and_then after catch receives recovered value", function()
		local p = promise.reject("err")
			:catch(function() return "ok" end)
			:and_then(function(v) return v .. "!" end)
		T.eq(p:value(), "ok!")
	end)
end)

---------------------------------------------------------------------------
-- finally
---------------------------------------------------------------------------
T.describe("finally", function()
	T.it("runs on fulfilled promise", function()
		local ran = false
		local p = promise.resolve(42):finally(function() ran = true end)
		T.eq(ran, true)
		T.eq(p:value(), 42)
	end)

	T.it("runs on rejected promise", function()
		local ran = false
		local p = promise.reject("err"):finally(function() ran = true end)
		T.eq(ran, true)
		T.eq(p:state(), "rejected")
		T.eq(p:reason(), "err")
	end)

	T.it("passes through value", function()
		local p = promise.resolve(99):finally(function() end)
		T.eq(p:value(), 99)
	end)
end)

---------------------------------------------------------------------------
-- await
---------------------------------------------------------------------------
T.describe("await", function()
	T.it("returns value on fulfilled", function()
		local val, err = promise.resolve(7):await()
		T.eq(val, 7)
		T.eq(err, nil)
	end)

	T.it("returns nil and reason on rejected", function()
		local val, err = promise.reject("fail"):await()
		T.eq(val, nil)
		T.eq(err, "fail")
	end)
end)

---------------------------------------------------------------------------
-- promise.all
---------------------------------------------------------------------------
T.describe("promise.all", function()
	T.it("resolves when all resolve", function()
		local p = promise.all({
			promise.resolve(1),
			promise.resolve(2),
			promise.resolve(3),
		})
		T.eq(p:state(), "fulfilled")
		local v = p:value()
		T.eq(v[1], 1)
		T.eq(v[2], 2)
		T.eq(v[3], 3)
	end)

	T.it("rejects on first rejection", function()
		local p = promise.all({
			promise.resolve(1),
			promise.reject("bad"),
			promise.resolve(3),
		})
		T.eq(p:state(), "rejected")
		T.eq(p:reason(), "bad")
	end)

	T.it("resolves empty array immediately", function()
		local p = promise.all({})
		T.eq(p:state(), "fulfilled")
		T.eq(#p:value(), 0)
	end)

	T.it("preserves order", function()
		local p = promise.all({
			promise.resolve("a"),
			promise.resolve("b"),
			promise.resolve("c"),
		})
		local v = p:value()
		T.eq(v[1], "a")
		T.eq(v[2], "b")
		T.eq(v[3], "c")
	end)
end)

---------------------------------------------------------------------------
-- promise.race
---------------------------------------------------------------------------
T.describe("promise.race", function()
	T.it("resolves with first fulfilled", function()
		local p = promise.race({
			promise.resolve("first"),
			promise.resolve("second"),
		})
		T.eq(p:state(), "fulfilled")
		T.eq(p:value(), "first")
	end)

	T.it("rejects with first rejected", function()
		local p = promise.race({
			promise.reject("err"),
			promise.resolve("ok"),
		})
		T.eq(p:state(), "rejected")
		T.eq(p:reason(), "err")
	end)

	T.it("empty array stays pending", function()
		local p = promise.race({})
		T.eq(p:state(), "pending")
	end)
end)

---------------------------------------------------------------------------
-- promise.all_settled
---------------------------------------------------------------------------
T.describe("promise.all_settled", function()
	T.it("collects all results", function()
		local p = promise.all_settled({
			promise.resolve(1),
			promise.reject("err"),
			promise.resolve(3),
		})
		T.eq(p:state(), "fulfilled")
		local v = p:value()
		T.eq(v[1].status, "fulfilled")
		T.eq(v[1].value, 1)
		T.eq(v[2].status, "rejected")
		T.eq(v[2].reason, "err")
		T.eq(v[3].status, "fulfilled")
		T.eq(v[3].value, 3)
	end)

	T.it("empty array resolves immediately", function()
		local p = promise.all_settled({})
		T.eq(p:state(), "fulfilled")
		T.eq(#p:value(), 0)
	end)
end)

---------------------------------------------------------------------------
-- promise.any
---------------------------------------------------------------------------
T.describe("promise.any", function()
	T.it("resolves with first fulfilled", function()
		local p = promise.any({
			promise.reject("a"),
			promise.resolve(42),
			promise.resolve(99),
		})
		T.eq(p:state(), "fulfilled")
		T.eq(p:value(), 42)
	end)

	T.it("rejects if all reject", function()
		local p = promise.any({
			promise.reject("a"),
			promise.reject("b"),
		})
		T.eq(p:state(), "rejected")
		local errors = p:reason()
		T.eq(errors[1], "a")
		T.eq(errors[2], "b")
	end)

	T.it("empty array rejects", function()
		local p = promise.any({})
		T.eq(p:state(), "rejected")
		T.eq(p:reason(), "All promises were rejected")
	end)
end)

---------------------------------------------------------------------------
-- Error propagation through chains
---------------------------------------------------------------------------
T.describe("error propagation", function()
	T.it("rejection passes through and_then to catch", function()
		local caught = nil
		promise.reject("deep err")
			:and_then(function(v) return v end)
			:and_then(function(v) return v end)
			:catch(function(r) caught = r end)
		T.eq(caught, "deep err")
		-- Verify the catch promise resolves with handler's return value
		local p = promise.reject("deep err")
			:and_then(function(v) return v end)
			:and_then(function(v) return v end)
			:catch(function(r) return "caught: " .. r end)
		T.eq(p:state(), "fulfilled")
		T.eq(p:value(), "caught: deep err")
	end)

	T.it("and_then error mid-chain propagates", function()
		local p = promise.resolve(1)
			:and_then(function(v) return v + 1 end)
			:and_then(function() error("mid") end)
			:and_then(function(v) return v + 1 end)
			:catch(function(r) return r end)
		T.eq(p:state(), "fulfilled")
		T.ok(p:value():find("mid"))
	end)
end)

---------------------------------------------------------------------------
-- Long chains
---------------------------------------------------------------------------
T.describe("long chains", function()
	T.it("handles 100-step chain", function()
		local p = promise.resolve(0)
		for _ = 1, 100 do
			p = p:and_then(function(v) return v + 1 end)
		end
		T.eq(p:value(), 100)
	end)

	T.it("handles chain of nested promises", function()
		local p = promise.resolve(0)
		for _ = 1, 20 do
			p = p:and_then(function(v)
				return promise.resolve(v + 1)
			end)
		end
		T.eq(p:value(), 20)
	end)
end)

---------------------------------------------------------------------------
-- state inspection
---------------------------------------------------------------------------
T.describe("state inspection", function()
	T.it("pending promise has nil value and reason", function()
		local p = promise.new(function() end)
		T.eq(p:state(), "pending")
		T.eq(p:value(), nil)
		T.eq(p:reason(), nil)
	end)

	T.it("await on pending returns error", function()
		local p = promise.new(function() end)
		local val, err = p:await()
		T.eq(val, nil)
		T.eq(err, "promise is pending")
	end)
end)
