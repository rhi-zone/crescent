-- lib/platform/caps/ws_server_test.lua

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T      = require("lib.test.assert")
local ws_srv = require("lib.platform.caps.ws_server")

T.describe("ws_server_cap", function()

	T.describe("factory", function()
		T.it("returns cap table and revoke function in standalone mode", function()
			local cap, revoke = ws_srv.ws_server_cap({ port = 19900 })
			T.ok(cap, "cap should not be nil")
			T.eq(type(revoke), "function")
		end)

		T.it("returns nil + error when port is missing in standalone mode", function()
			local cap, err = ws_srv.ws_server_cap({})
			T.eq(cap, nil)
			T.ok(err:find("port"), "error should mention port")
		end)

		T.it("returns nil + error when opts is nil", function()
			local cap, err = ws_srv.ws_server_cap(nil)
			T.eq(cap, nil)
			T.ok(err:find("opts"), "error should mention opts")
		end)
	end)

	T.describe("cap fields", function()
		T.it("has serve function and _type", function()
			local cap = ws_srv.ws_server_cap({ port = 19901 })
			T.eq(type(cap.serve), "function")
			T.eq(cap._type, "ws_server")
		end)
	end)

	T.describe("handler validation", function()
		T.it("rejects non-table handler", function()
			local cap = ws_srv.ws_server_cap({ port = 19902 })
			local ok, err = cap.serve("not a table")
			T.eq(ok, nil)
			T.ok(err:find("table"), "error should mention table")
		end)

		T.it("rejects handler without ws function", function()
			local cap = ws_srv.ws_server_cap({ port = 19903 })
			local ok, err = cap.serve({ ws_accept = function() end })
			T.eq(ok, nil)
			T.ok(err:find("ws"), "error should mention ws")
		end)

		T.it("rejects handler with non-function ws_accept", function()
			local cap = ws_srv.ws_server_cap({ port = 19904 })
			local ok, err = cap.serve({ ws = function() end, ws_accept = "bad" })
			T.eq(ok, nil)
			T.ok(err:find("ws_accept"), "error should mention ws_accept")
		end)

		T.it("accepts handler with ws only (no ws_accept)", function()
			-- This would block in standalone mode (binds a socket), so test
			-- validation only through daemon mode.
			local captured
			local cap = ws_srv.ws_server_cap({
				daemon = true,
				--: (unknown) -> nil
				on_serve = function(h) captured = h end,
			})
			local ht = { ws = function() end }
			local ok = cap.serve(ht)
			T.eq(ok, true)
			T.eq(captured, ht)
		end)

		T.it("accepts handler with both ws and ws_accept", function()
			local captured
			local cap = ws_srv.ws_server_cap({
				daemon = true,
				--: (unknown) -> nil
				on_serve = function(h) captured = h end,
			})
			local ht = { ws = function() end, ws_accept = function() return true end }
			local ok = cap.serve(ht)
			T.eq(ok, true)
			T.eq(captured, ht)
		end)
	end)

	T.describe("revocation", function()
		T.it("serve returns error after revocation in standalone mode", function()
			local cap, revoke = ws_srv.ws_server_cap({ port = 19905 })
			T.eq(type(revoke), "function")
			if type(revoke) == "function" then revoke() end
			local ok, err = cap.serve({ ws = function() end })
			T.eq(ok, nil)
			T.ok(err:find("revoked"), "error should mention revoked")
		end)

		T.it("serve returns error after revocation in daemon mode", function()
			--: (unknown) -> nil
			local function noop(_h) end
			local cap, revoke = ws_srv.ws_server_cap({
				daemon = true,
				on_serve = noop,
			})
			T.eq(type(revoke), "function")
			if type(revoke) == "function" then revoke() end
			local ok, err = cap.serve({ ws = function() end })
			T.eq(ok, nil)
			T.ok(err:find("revoked"), "error should mention revoked")
		end)
	end)

	T.describe("daemon mode", function()
		T.it("returns cap and revoke function", function()
			--: (unknown) -> nil
			local function noop2(_h) end
			local cap, revoke = ws_srv.ws_server_cap({
				daemon = true,
				on_serve = noop2,
			})
			T.ok(cap, "cap should not be nil")
			T.eq(type(revoke), "function")
			T.eq(cap._type, "ws_server")
		end)

		T.it("cap.serve registers handler via on_serve and returns true", function()
			local captured
			local cap = ws_srv.ws_server_cap({
				daemon = true,
				--: (unknown) -> nil
				on_serve = function(h) captured = h end,
			})
			local ht = { ws = function() end, ws_accept = function() return true end }
			local ok = cap.serve(ht)
			T.eq(ok, true)
			T.eq(captured, ht, "registered handler table matches")
		end)

		T.it("on_serve not called until serve() invoked", function()
			local called = false
			ws_srv.ws_server_cap({
				daemon = true,
				--: (unknown) -> nil
				on_serve = function(_h) called = true end,
			})
			T.ok(not called, "on_serve should not be called before serve()")
		end)

		T.it("requires opts.on_serve", function()
			local cap, err = ws_srv.ws_server_cap({ daemon = true })
			T.eq(cap, nil)
			T.ok(err:find("on_serve"), "error mentions on_serve")
		end)
	end)

	T.describe("risk", function()
		T.it("returns high severity", function()
			local r = ws_srv.risk({})
			T.eq(r.severity, "high")
			T.ok(r.text:find("WebSocket"), "text should mention WebSocket")
		end)
	end)

end)
