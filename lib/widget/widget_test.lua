-- lib/widget/widget_test.lua
-- Tests for lib.widget

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T      = require("lib.test.assert")
local W      = require("lib.widget")
local R      = require("lib.reactive")
local Lens   = require("lib.fp.optics.lens")
local Prism  = require("lib.fp.optics.prism")
local Maybe  = require("lib.fp.maybe")

-- ── with_scope / register ─────────────────────────────────────────────────────

T.describe("with_scope", function()
	T.it("returns fn result", function()
		local result, _ = W.with_scope(function() return 42 end)
		T.eq(result, 42)
	end)

	T.it("cleanup fires all registered callbacks", function()
		local log = {}
		local _, cleanup = W.with_scope(function()
			W.register(function() log[#log + 1] = "a" end)
			W.register(function() log[#log + 1] = "b" end)
			W.register(function() log[#log + 1] = "c" end)
		end)
		T.eq(#log, 0)
		cleanup()
		T.eq(#log, 3)
		T.eq(log[1], "c")
		T.eq(log[2], "b")
		T.eq(log[3], "a")
	end)

	T.it("cleanup fires in reverse order (LIFO)", function()
		local order = {}
		local _, cleanup = W.with_scope(function()
			W.register(function() order[#order + 1] = 1 end)
			W.register(function() order[#order + 1] = 2 end)
			W.register(function() order[#order + 1] = 3 end)
		end)
		cleanup()
		T.eq(order[1], 3)
		T.eq(order[2], 2)
		T.eq(order[3], 1)
	end)

	T.it("cleanup is idempotent (no-op on second call)", function()
		local count = 0
		local _, cleanup = W.with_scope(function()
			W.register(function() count = count + 1 end)
		end)
		cleanup()
		cleanup()
		T.eq(count, 1)
	end)

	T.it("nested scopes are independent", function()
		local outer_log = {}
		local inner_log = {}

		local _, outer_cleanup = W.with_scope(function()
			W.register(function() outer_log[#outer_log + 1] = "outer" end)
			local _, inner_cleanup = W.with_scope(function()
				W.register(function() inner_log[#inner_log + 1] = "inner" end)
			end)
			inner_cleanup()
		end)

		T.eq(#inner_log, 1)
		T.eq(inner_log[1], "inner")
		T.eq(#outer_log, 0)
		outer_cleanup()
		T.eq(#outer_log, 1)
		T.eq(outer_log[1], "outer")
	end)
end)

T.describe("register", function()
	T.it("errors outside a scope", function()
		T.throws(function()
			W.register(function() end)
		end)
	end)
end)

-- ── subscribe_now ─────────────────────────────────────────────────────────────

T.describe("subscribe_now", function()
	T.it("fires handler immediately with current value", function()
		local sig = R.signal(10)
		local received = {}
		local _, cleanup = W.with_scope(function()
			W.subscribe_now(sig, function(v) received[#received + 1] = v end)
		end)
		T.eq(#received, 1)
		T.eq(received[1], 10)
		cleanup()
	end)

	T.it("fires handler on subsequent changes", function()
		local sig = R.signal("hello")
		local received = {}
		local _, cleanup = W.with_scope(function()
			W.subscribe_now(sig, function(v) received[#received + 1] = v end)
		end)
		sig.set("world")
		sig.set("!")
		T.eq(#received, 3)
		T.eq(received[1], "hello")
		T.eq(received[2], "world")
		T.eq(received[3], "!")
		cleanup()
	end)

	T.it("unsubscribes after cleanup", function()
		local sig = R.signal(1)
		local received = {}
		local _, cleanup = W.with_scope(function()
			W.subscribe_now(sig, function(v) received[#received + 1] = v end)
		end)
		-- Recorded the initial value.
		cleanup()
		-- After cleanup, no more notifications.
		sig.set(99)
		T.eq(#received, 1)
		T.eq(received[1], 1)
	end)
end)

-- ── dynamic ───────────────────────────────────────────────────────────────────

T.describe("dynamic", function()
	T.it("child receives combined {state, value}", function()
		local sig = R.signal("external")
		local received = {}

		local widget = W.dynamic("init_state", function(combined_sig)
			received[#received + 1] = combined_sig.get()
			return "node"
		end)

		local _, cleanup = W.with_scope(function()
			widget(sig)
		end)
		T.eq(#received, 1)
		T.eq(received[1].state, "init_state")
		T.eq(received[1].value, "external")
		cleanup()
	end)

	T.it("local state changes do not propagate to parent signal", function()
		local sig = R.signal(100)
		local combined_ref
		local _, cleanup = W.with_scope(function()
			local widget = W.dynamic(0, function(combined_sig)
				combined_ref = combined_sig
				return "node"
			end)
			widget(sig)
		end)

		-- Update local state.
		combined_ref.set_state(42)
		-- Parent signal is unchanged.
		T.eq(sig.get(), 100)
		-- Combined reflects new local state.
		T.eq(combined_ref.get().state, 42)
		T.eq(combined_ref.get().value, 100)
		cleanup()
	end)

	T.it("external signal changes update combined value", function()
		local sig = R.signal("a")
		local combined_ref
		local _, cleanup = W.with_scope(function()
			local widget = W.dynamic("s", function(combined_sig)
				combined_ref = combined_sig
				return "node"
			end)
			widget(sig)
		end)

		sig.set("b")
		T.eq(combined_ref.get().value, "b")
		T.eq(combined_ref.get().state, "s")
		cleanup()
	end)

	T.it("update_state applies function to current state", function()
		local sig = R.signal(0)
		local combined_ref
		local _, cleanup = W.with_scope(function()
			local widget = W.dynamic(10, function(combined_sig)
				combined_ref = combined_sig
				return "node"
			end)
			widget(sig)
		end)

		combined_ref.update_state(function(s) return s + 5 end)
		T.eq(combined_ref.get().state, 15)
		cleanup()
	end)
end)

-- ── show ──────────────────────────────────────────────────────────────────────

T.describe("show", function()
	T.it("returns show_node with visible signal matching predicate", function()
		local sig = R.signal(5)
		local _, cleanup = W.with_scope(function()
			local wrapped = W.show(
				function(_s) return "inner_node" end,
				function(v) return v > 3 end
			)
			local result = wrapped(sig)
			T.eq(result.node, "inner_node")
			T.ok(result.visible.get())
		end)
		cleanup()
	end)

	T.it("visible is false when predicate returns false", function()
		local sig = R.signal(1)
		local _, cleanup = W.with_scope(function()
			local wrapped = W.show(
				function(_s) return "inner_node" end,
				function(v) return v > 3 end
			)
			local result = wrapped(sig)
			T.ok(not result.visible.get())
		end)
		cleanup()
	end)

	T.it("visible signal updates when outer signal changes", function()
		local sig = R.signal(1)
		local result
		local _, cleanup = W.with_scope(function()
			local wrapped = W.show(
				function(_s) return "node" end,
				function(v) return v > 3 end
			)
			result = wrapped(sig)
		end)

		T.ok(not result.visible.get())
		sig.set(10)
		T.ok(result.visible.get())
		sig.set(2)
		T.ok(not result.visible.get())
		cleanup()
	end)

	T.it("inner widget stays mounted after hide", function()
		local sig = R.signal(10)
		local mount_count = 0
		local _, cleanup = W.with_scope(function()
			local wrapped = W.show(
				function(_s) mount_count = mount_count + 1; return "node" end,
				function(v) return v > 3 end
			)
			wrapped(sig)
			sig.set(1)
			sig.set(5)
		end)
		-- Widget was only mounted once.
		T.eq(mount_count, 1)
		cleanup()
	end)
end)

-- ── focus ─────────────────────────────────────────────────────────────────────

T.describe("focus", function()
	T.it("child receives focused signal value", function()
		local sig = R.signal({ x = 10, y = 20 })
		local x_lens = Lens.field("x")
		local _, cleanup = W.with_scope(function()
			local wrapped = W.focus(
				function(focused_sig)
					T.eq(focused_sig.get(), 10)
					return "node"
				end,
				x_lens
			)
			wrapped(sig)
		end)
		cleanup()
	end)

	T.it("child can write back through lens", function()
		local sig = R.signal({ x = 1, y = 2 })
		local x_lens = Lens.field("x")
		local focused_ref
		local _, cleanup = W.with_scope(function()
			local wrapped = W.focus(
				function(focused_sig) focused_ref = focused_sig; return "node" end,
				x_lens
			)
			wrapped(sig)
		end)

		focused_ref.set(99)
		T.eq(sig.get().x, 99)
		T.eq(sig.get().y, 2)
		cleanup()
	end)

	T.it("focused signal updates when parent changes", function()
		local sig = R.signal({ score = 0 })
		local score_lens = Lens.field("score")
		local values = {}
		local _, cleanup = W.with_scope(function()
			local wrapped = W.focus(
				function(focused_sig)
					W.subscribe_now(focused_sig, function(v) values[#values + 1] = v end)
					return "node"
				end,
				score_lens
			)
			wrapped(sig)
		end)

		sig.set({ score = 5 })
		sig.set({ score = 10 })
		T.eq(#values, 3)
		T.eq(values[1], 0)
		T.eq(values[2], 5)
		T.eq(values[3], 10)
		cleanup()
	end)
end)

-- ── narrow ────────────────────────────────────────────────────────────────────

T.describe("narrow", function()
	T.it("returns nil when prism does not match", function()
		local sig = R.signal({ tag = "circle", r = 5 })
		-- Prism that only matches {tag="rect", ...}
		local rect_prism = Prism.new(
			function(s)
				if s.tag == "rect" then return Maybe.just(s) end
				return Maybe.nothing
			end,
			function(a) return a end
		)
		local result
		local _, cleanup = W.with_scope(function()
			local wrapped = W.narrow(
				function(_s) return "rect_node" end,
				rect_prism
			)
			result = wrapped(sig)
		end)
		T.eq(result, nil)
		cleanup()
	end)

	T.it("calls child widget when prism matches", function()
		local sig = R.signal({ tag = "rect", w = 10, h = 20 })
		local rect_prism = Prism.new(
			function(s)
				if s.tag == "rect" then return Maybe.just(s) end
				return Maybe.nothing
			end,
			function(a) return a end
		)
		local received
		local _, cleanup = W.with_scope(function()
			local wrapped = W.narrow(
				function(narrowed_sig) received = narrowed_sig.get(); return "rect_node" end,
				rect_prism
			)
			local result = wrapped(sig)
			T.eq(result, "rect_node")
		end)
		T.eq(received.tag, "rect")
		cleanup()
	end)
end)
