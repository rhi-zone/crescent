-- lib/platform/apps/system_dashboard/output_test.lua
-- Tests for the pack output envelope schema.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local O = require("lib.platform.apps.system_dashboard.output")

T.describe("output: atomic constructors", function()
	T.it("text", function()
		local p = O.text("hello", "muted")
		T.eq(p.type, "text")
		T.eq(p.text, "hello")
		T.eq(p.style, "muted")
		T.ok(O.validate_primitive(p))
	end)

	T.it("status_badge", function()
		local p = O.status_badge("Tailscale", "ok")
		T.ok(O.validate_primitive(p))
	end)

	T.it("rejects bad badge state", function()
		local p = { type = "status_badge", label = "x", state = "bogus" }
		local ok, err = O.validate_primitive(p)
		T.eq(ok, nil)
		T.ok(err and err:find("badge state"))
	end)
end)

T.describe("output: cite channel", function()
	T.it("registry kind", function()
		local c = O.cite_registry("HKCU\\Foo", "Bar")
		T.eq(c.kind, "registry")
		T.eq(c.path, "HKCU\\Foo")
	end)

	T.it("http kind", function()
		local c = O.cite_http("GET", "http://example/")
		T.eq(c.kind, "http")
	end)

	T.it("validates known kind", function()
		T.ok(O.validate_cite({ O.cite_url("https://x") }))
	end)

	T.it("rejects unknown kind", function()
		local ok, err = O.validate_cite({ { kind = "telepathy", thought = "x" } })
		T.eq(ok, nil)
		T.ok(err and err:find("not a known cite kind"))
	end)

	T.it("rejects malformed cite (missing kind)", function()
		local ok, err = O.validate_cite({ { path = "x" } })
		T.eq(ok, nil)
		T.ok(err and err:find("kind"))
	end)
end)

T.describe("output: envelope", function()
	T.it("ok envelope round-trips", function()
		local env = O.ok(O.text("up"), { cite = { O.cite_command({ "uname", "-a" }) } })
		T.eq(env.ok, true)
		T.ok(O.validate(env))
	end)

	T.it("err envelope", function()
		local env = O.err("network down")
		T.eq(env.ok, false)
		T.ok(O.validate(env))
	end)

	T.it("rejects ok envelope with no body", function()
		local ok, err = O.validate({ ok = true })
		T.eq(ok, nil)
		T.ok(err and err:find("body"))
	end)

	T.it("rejects unknown primitive type", function()
		local ok, err = O.validate({ ok = true, body = { type = "vortex", spin = 5 } })
		T.eq(ok, nil)
		T.ok(err and err:find("not a known primitive"))
	end)

	T.it("rejects missing required field", function()
		local ok, err = O.validate({ ok = true, body = { type = "table", columns = {} } })
		T.eq(ok, nil)
		T.ok(err and err:find("rows"))
	end)

	T.it("rejects malformed cite", function()
		local ok, err = O.validate({
			ok = true,
			body = O.text("x"),
			cite = { { kind = "ouija" } },
		})
		T.eq(ok, nil)
		T.ok(err and err:find("not a known cite kind"))
	end)
end)

-- Worked examples from docs/system_dashboard_primitives.md
T.describe("output: worked examples", function()
	T.it("Tailscale card", function()
		local env = O.ok(
			O.card({
				title = "Tailscale",
				body = O.grid({
					columns = 2,
					cells = {
						O.single_stat({ label = "State",     value = "Running",  state = "ok" }),
						O.single_stat({ label = "Exit node", value = "us-nyc-01" }),
						O.key_value({
							{ key = "IPv4",  value = O.text("100.64.0.5") },
							{ key = "Peers", value = O.text("12") },
						}),
						O.button({ label = "Toggle exit node", alias = "tailscale.toggle_exit",
							confirm = true, style = "primary" }),
					},
				}),
			}),
			{ cite = { O.cite_http("GET", "http://localhost:41112/v0/status") } }
		)
		local ok, err = O.validate(env)
		T.ok(ok, err)
	end)

	T.it("ps live_table", function()
		local env = O.ok(
			O.live_table({
				columns = {
					{ key = "pid", label = "PID", type = "number",   sortable = true },
					{ key = "cmd", label = "Cmd", type = "string" },
					{ key = "cpu", label = "CPU", type = "number",   align = "right" },
					{ key = "mem", label = "Mem", type = "bytes",    align = "right" },
				},
				key = "pid",
				row_actions = { "proc.kill", "proc.signal" },
			}),
			{
				stream = "<iter>",
				cite = { O.cite_exec({ "ps", "axo", "pid,comm,%cpu,rss" }) },
			}
		)
		local ok, err = O.validate(env)
		T.ok(ok, err)
	end)

	T.it("regedit hack", function()
		local env = O.ok(
			O.key_value({
				{
					key   = "MenuShowDelay",
					value = O.single_stat({ value = 0, unit = "ms" }),
				},
			}),
			{ cite = { O.cite_registry("HKCU\\Control Panel\\Desktop\\MenuShowDelay") } }
		)
		local ok, err = O.validate(env)
		T.ok(ok, err)
	end)
end)

T.describe("output: composite recursion", function()
	T.it("validates nested card->grid->card", function()
		local env = O.ok(O.card({
			title = "Outer",
			body = O.grid({
				cells = {
					O.card({ title = "Inner", body = O.text("x") }),
					O.text("y"),
				},
			}),
		}))
		T.ok(O.validate(env))
	end)

	T.it("rejects nested invalid primitive", function()
		local env = O.ok(O.card({
			title = "Outer",
			body  = { type = "card", title = "missing-body" }, -- card requires body
		}))
		local ok, err = O.validate(env)
		T.eq(ok, nil)
		T.ok(err and err:find("body"))
	end)

	T.it("validates tabs", function()
		local env = O.ok(O.tabs({
			{ label = "A", body = O.text("aaa") },
			{ label = "B", body = O.code("{}", "json") },
		}))
		T.ok(O.validate(env))
	end)
end)

T.describe("output: streaming primitives", function()
	T.it("log_stream", function()
		T.ok(O.validate_primitive(O.log_stream()))
	end)
	T.it("event_stream", function()
		T.ok(O.validate_primitive(O.event_stream()))
	end)
	T.it("rejects log_stream with bad frame_type", function()
		local ok, err = O.validate_primitive({ type = "log_stream", frame_type = "table" })
		T.eq(ok, nil)
		T.ok(err and err:find("frame_type"))
	end)
end)

T.describe("output: additional atomic primitives", function()
	T.it("markdown", function()
		local p = O.markdown("# hello\n\ntext")
		T.eq(p.type, "markdown")
		T.ok(O.validate(O.ok(p)))
	end)

	T.it("link", function()
		local p = O.link("https://example/", "Example")
		T.eq(p.type, "link")
		T.eq(p.href, "https://example/")
		T.eq(p.label, "Example")
		T.ok(O.validate(O.ok(p)))
	end)

	T.it("icon", function()
		local p = O.icon("check", "ok")
		T.eq(p.type, "icon")
		T.eq(p.name, "check")
		T.ok(O.validate(O.ok(p)))
	end)

	T.it("kbd", function()
		local p = O.kbd({ "Ctrl", "C" })
		T.eq(p.type, "kbd")
		T.ok(O.validate(O.ok(p)))
	end)
end)

T.describe("output: numeric/scalar primitives", function()
	T.it("single_stat", function()
		local p = O.single_stat({ value = 47, unit = "%", label = "CPU", delta = "+2", state = "warn" })
		T.eq(p.type, "single_stat")
		T.ok(O.validate(O.ok(p)))
	end)

	T.it("gauge", function()
		local p = O.gauge({
			value = 75, min = 0, max = 100, unit = "%",
			thresholds = { { at = 80, state = "warn" }, { at = 95, state = "error" } },
		})
		T.eq(p.type, "gauge")
		T.ok(O.validate(O.ok(p)))
	end)

	T.it("progress_bar", function()
		local p = O.progress_bar({ value = 30, max = 100, label = "Working" })
		T.eq(p.type, "progress_bar")
		T.ok(O.validate(O.ok(p)))
	end)

	T.it("sparkline", function()
		local p = O.sparkline({ 1, 2, 3, 4, 3, 2, 5 }, "ms")
		T.eq(p.type, "sparkline")
		T.ok(O.validate(O.ok(p)))
	end)
end)

T.describe("output: list primitive", function()
	T.it("list", function()
		local p = O.list({
			{ title = "First",  subtitle = "one",   trailing = "1" },
			{ title = "Second", subtitle = "two",   trailing = "2" },
		})
		T.eq(p.type, "list")
		T.ok(O.validate(O.ok(p)))
	end)
end)

T.describe("output: time-series primitives", function()
	T.it("top_list", function()
		local p = O.top_list({
			items = {
				{ label = "ads.example",  value = 1234, unit = "" },
				{ label = "tracking.com", value = 567 },
			},
			max = 2000,
		})
		T.eq(p.type, "top_list")
		T.ok(O.validate(O.ok(p)))
	end)

	T.it("line_chart", function()
		local p = O.line_chart({
			series = {
				{ name = "cpu", points = { { t = 0, v = 10 }, { t = 1, v = 25 } } },
			},
			unit = "%",
		})
		T.ok(O.validate(O.ok(p)))
	end)

	T.it("heatmap", function()
		local p = O.heatmap({ x_bins = 2, y_bins = 2, values = { { 0.1, 0.5 }, { 0.7, 1.0 } } })
		T.ok(O.validate(O.ok(p)))
	end)
end)

T.describe("output: hierarchical primitives", function()
	T.it("tree", function()
		local p = O.tree({
			label = "/", children = {
				{ label = "etc", children = { { label = "hosts", value = "127.0.0.1" } } },
				{ label = "tmp" },
			},
		})
		T.ok(O.validate(O.ok(p)))
	end)

	T.it("json_view", function()
		local p = O.json_view({ a = 1, b = { 2, 3 } }, 2)
		T.ok(O.validate(O.ok(p)))
	end)

	T.it("diff", function()
		local p = O.diff("foo\nbar", "foo\nbaz")
		T.ok(O.validate(O.ok(p)))
	end)
end)

T.describe("output: composite/action stubs", function()
	T.it("panel", function()
		local p = O.panel({
			title = "Status",
			body  = O.text("ok"),
			actions = { "do.thing" },
		})
		T.ok(O.validate(O.ok(p)))
	end)

	T.it("split", function()
		local p = O.split("row", { O.text("L"), O.text("R") })
		T.ok(O.validate(O.ok(p)))
	end)

	T.it("confirm", function()
		local p = O.confirm({ prompt = "Sure?", alias = "do.it", danger = true })
		T.ok(O.validate(O.ok(p)))
	end)

	T.it("action_menu", function()
		local p = O.action_menu({
			{ label = "Kill", alias = "proc.kill" },
			{ label = "Stop", alias = "proc.stop" },
		})
		T.ok(O.validate(O.ok(p)))
	end)
end)

T.describe("output: form / action_menu", function()
	T.it("form validates field types", function()
		local p = O.form({
			submit_alias = "x.submit",
			fields = {
				{ name = "host", label = "Host", type = "host", required = true },
				{ name = "pw",   label = "Pass", type = "password" },
			},
		})
		T.ok(O.validate_primitive(p))
	end)
	T.it("form rejects unknown field type", function()
		local ok, err = O.validate_primitive({
			type = "form", submit_alias = "a",
			fields = { { name = "x", label = "X", type = "weirdo" } },
		})
		T.eq(ok, nil)
		T.ok(err and err:find("field type"))
	end)
end)
