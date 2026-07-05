-- lib/declc/kernel_test.lua
-- Tests for the certificate kernel: verdict constructors, opacity, and the
-- minimal "was this minted by the kernel" check.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T      = require("lib.test.assert")
local kernel = require("lib.declc.kernel")

T.describe("kernel: constructors mint verdicts of the right kind", function()
	T.it("proved(cert) is a verdict of kind proved", function()
		local v = kernel.proved({ invariant = "x >= 0" })
		T.ok(kernel.is_verdict(v))
		local k, err = kernel.kind(v)
		T.eq(k, "proved")
		T.eq(err, nil)
	end)

	T.it("refuted(trace) is a verdict of kind refuted", function()
		local v = kernel.refuted({ events = { "a", "b" } })
		T.ok(kernel.is_verdict(v))
		local k = kernel.kind(v)
		T.eq(k, "refuted")
	end)

	T.it("open(receipt) is a verdict of kind open", function()
		local v = kernel.open({ reason = "budget exhausted" })
		T.ok(kernel.is_verdict(v))
		local k = kernel.kind(v)
		T.eq(k, "open")
	end)
end)

T.describe("kernel: payload accessors are kind-gated", function()
	T.it("cert() returns the payload for a Proved verdict", function()
		local v = kernel.proved("the-cert")
		local c, err = kernel.cert(v)
		T.eq(c, "the-cert")
		T.eq(err, nil)
	end)

	T.it("cert() errors on a non-Proved verdict", function()
		local v = kernel.refuted("the-trace")
		local c, err = kernel.cert(v)
		T.eq(c, nil)
		T.ok(err ~= nil)
	end)

	T.it("trace() returns the payload for a Refuted verdict", function()
		local v = kernel.refuted("the-trace")
		local tr, err = kernel.trace(v)
		T.eq(tr, "the-trace")
		T.eq(err, nil)
	end)

	T.it("trace() errors on a non-Refuted verdict", function()
		local v = kernel.open("the-receipt")
		local tr, err = kernel.trace(v)
		T.eq(tr, nil)
		T.ok(err ~= nil)
	end)

	T.it("receipt() returns the payload for an Open verdict", function()
		local v = kernel.open("the-receipt")
		local r, err = kernel.receipt(v)
		T.eq(r, "the-receipt")
		T.eq(err, nil)
	end)

	T.it("receipt() errors on a non-Open verdict", function()
		local v = kernel.proved("the-cert")
		local r, err = kernel.receipt(v)
		T.eq(r, nil)
		T.ok(err ~= nil)
	end)
end)

T.describe("kernel: opacity -- verdicts cannot be forged", function()
	T.it("is_verdict rejects a hand-assembled table that merely looks like a verdict", function()
		local fake = { kind = "proved", payload = "forged" }
		T.fail(kernel.is_verdict(fake))
	end)

	T.it("is_verdict rejects non-table values", function()
		T.fail(kernel.is_verdict("proved"))
		T.fail(kernel.is_verdict(42))
		T.fail(kernel.is_verdict(nil))
		T.fail(kernel.is_verdict(true))
	end)

	T.it("kind() on a forged table returns an error, not a kind", function()
		local fake = { kind = "proved", payload = "forged" }
		local k, err = kernel.kind(fake)
		T.eq(k, nil)
		T.ok(err ~= nil)
	end)

	T.it("payload accessors on a forged table all error", function()
		local fake = { kind = "proved", payload = "forged" }
		local c, cerr = kernel.cert(fake)
		T.eq(c, nil); T.ok(cerr ~= nil)
		local tr, terr = kernel.trace(fake)
		T.eq(tr, nil); T.ok(terr ~= nil)
		local r, rerr = kernel.receipt(fake)
		T.eq(r, nil); T.ok(rerr ~= nil)
	end)
end)

T.describe("kernel: payload can be any value, including nil", function()
	T.it("a verdict may carry a nil payload", function()
		local v = kernel.open(nil)
		T.ok(kernel.is_verdict(v))
		local r, err = kernel.receipt(v)
		T.eq(r, nil)
		T.eq(err, nil)
	end)
end)
