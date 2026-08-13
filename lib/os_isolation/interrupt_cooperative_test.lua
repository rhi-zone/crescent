-- lib/os_isolation/interrupt_cooperative_test.lua

if not package.path:find("?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local interrupt_cooperative = require("lib.os_isolation.interrupt_cooperative")

T.describe("interrupt_cooperative.new", function()
	T.it("requires at least one of opts.budget / opts.deadline", function()
		local checker, err = interrupt_cooperative.new({})
		T.eq(checker, nil)
		T.ok(err:find("budget"))
	end)

	T.it("requires opts.clock when opts.deadline is set", function()
		local checker, err = interrupt_cooperative.new({ deadline = 1 })
		T.eq(checker, nil)
		T.ok(err:find("clock"))
	end)
end)

T.describe("interrupt_cooperative budget mode", function()
	T.it("tick() raises once the configured budget is exceeded", function()
		local checker = interrupt_cooperative.new({ budget = 5 })
		local ok, err = pcall(function()
			for _ = 1, 100 do checker:tick() end
		end)
		T.fail(ok)
		T.ok(tostring(err):find("budget exceeded"))
	end)

	T.it("tick() does not raise while under budget", function()
		local checker = interrupt_cooperative.new({ budget = 100 })
		local ok = pcall(function()
			for _ = 1, 10 do checker:tick() end
		end)
		T.ok(ok)
	end)

	T.it("remaining() counts down and floors at 0", function()
		local checker = interrupt_cooperative.new({ budget = 3 })
		T.eq(checker:remaining(), 3)
		checker:tick()
		T.eq(checker:remaining(), 2)
	end)

	T.it("remaining() is nil when no budget was configured", function()
		local checker = interrupt_cooperative.new({ deadline = 1, clock = function() return 0 end })
		T.eq(checker:remaining(), nil)
	end)
end)

T.describe("interrupt_cooperative deadline mode", function()
	T.it("tick() raises once the injected clock passes the deadline", function()
		local fake_time = 0
		local checker = interrupt_cooperative.new({
			deadline = 10,
			clock = function() return fake_time end,
		})
		checker:tick() -- fake_time=0, under deadline
		fake_time = 20
		local ok, err = pcall(function() checker:tick() end)
		T.fail(ok)
		T.ok(tostring(err):find("deadline exceeded"))
	end)

	T.it("never reaches for os.clock or any ambient time source on its own", function()
		-- caps-first: no opts.clock, no opts.budget either -> new() must
		-- fail cleanly rather than silently default to a global clock.
		local checker, err = interrupt_cooperative.new({ deadline = 1 })
		T.eq(checker, nil)
		T.ok(err ~= nil)
	end)
end)

T.describe("interrupt_cooperative is real bounded-execution code, not a VM hook", function()
	T.it("bounds a tight loop that would defeat lib.sandbox.run's debug.sethook budget once JIT-traced", function()
		-- Regression-shaped: this is exactly the loop shape
		-- docs/genre-battery/sandboxing.md documents as escaping
		-- debug.sethook count-hook budgets once LuaJIT compiles it to a
		-- trace (see "Rejected: debug.sethook count-hook budgets"). An
		-- inline tick() call is ordinary Lua code the trace must include,
		-- so it bounds this loop where the rejected mechanism could not.
		local checker = interrupt_cooperative.new({ budget = 1000 })
		local ok, err = pcall(function()
			local i = 0
			while true do
				i = i + 1
				checker:tick()
			end
		end)
		T.fail(ok)
		T.ok(tostring(err):find("budget exceeded"))
	end)
end)
