if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T    = require("lib.test.assert")
local orch = require("lib.orchestration")

-- ── 1. Echo task ─────────────────────────────────────────────────────────────

T.describe("echo task", function()
	T.it("returns input verbatim", function()
		local out = orch.run(
			{ type = "echo", input = { msg = "hello" } },
			{ executors = { echo = function(t, _) return t.input end } }
		)
		T.eq(out.msg, "hello")
	end)
end)

-- ── 2. Spawn + result ─────────────────────────────────────────────────────────

T.describe("spawn + result", function()
	T.it("parent uses child output", function()
		local executors = {
			parent = function(t, ctx)
				local id = ctx:spawn({ type = "child", input = { x = t.input.x } })
				local res = ctx:result(id)
				return { doubled = res.val }
			end,
			child = function(t, _) return { val = t.input.x * 2 } end,
		}
		local out = orch.run({ type = "parent", input = { x = 7 } }, { executors = executors })
		T.eq(out.doubled, 14)
	end)
end)

-- ── 3. Graph lineage ──────────────────────────────────────────────────────────

T.describe("graph lineage", function()
	T.it("records parent_id and spawned list", function()
		local executors = {
			root = function(t, ctx)
				local id = ctx:spawn({ type = "leaf", input = {} })
				ctx:result(id)
				return {}
			end,
			leaf = function(_, _) return {} end,
		}
		local _, g = orch.run({ type = "root", input = {} }, { executors = executors })
		local root = g.tasks[g.root]
		T.eq(#root.spawned, 1)
		local child_id = root.spawned[1]
		local child = g.tasks[child_id]
		T.eq(child.parent_id, g.root)

		-- count tasks: root + leaf = 2
		local count = 0
		for _ in orch.graph.tasks(g) do count = count + 1 end
		T.eq(count, 2)
	end)
end)

-- ── 4. Error propagation ──────────────────────────────────────────────────────

T.describe("error propagation", function()
	T.it("executor error → task.status = error", function()
		local _, g = pcall(orch.run,
			{ type = "boom", input = {} },
			{ executors = { boom = function() error("kaboom") end } }
		)
		-- pcall swallows the error; inspect graph via a wrapper
		local captured_g
		pcall(function()
			local function boom_exec() error("kaboom") end
			local exec_mod = require("lib.orchestration.exec")
			local graph_mod = require("lib.orchestration.graph")
			local gr = graph_mod.new()
			local id = graph_mod.add(gr, { type = "boom", input = {} }, nil)
			gr.root = id
			exec_mod.run_task(gr, { boom = boom_exec }, {}, id)
			captured_g = gr
		end)
		local task = captured_g.tasks[captured_g.root]
		T.eq(task.status, "error")
		T.ok(task.error ~= nil)
	end)

	T.it("ctx:result re-raises child error", function()
		local executors = {
			parent = function(_, ctx)
				local id = ctx:spawn({ type = "boom", input = {} })
				ctx:result(id)  -- should raise
				return {}
			end,
			boom = function() error("inner error") end,
		}
		local ok, err = pcall(orch.run, { type = "parent", input = {} }, { executors = executors })
		T.fail(ok)
		T.ok(err:find("inner error"))
	end)
end)

-- ── 5. Inline executors via opts ──────────────────────────────────────────────

T.describe("inline executors", function()
	T.it("opts.executors override global registry", function()
		orch.register("greet", function() return { msg = "global" } end)
		local out = orch.run(
			{ type = "greet", input = {} },
			{ executors = { greet = function() return { msg = "local" } end } }
		)
		T.eq(out.msg, "local")
	end)
end)

-- ── 6. Combinator: map ────────────────────────────────────────────────────────

T.describe("combinator: map", function()
	T.it("spawns N tasks and collects results", function()
		local executors = {
			double = function(t, _) return { val = t.input.n * 2 } end,
		}
		local out = orch.run(
			{
				type = "map",
				input = {
					tasks = {
						{ type = "double", input = { n = 1 } },
						{ type = "double", input = { n = 2 } },
						{ type = "double", input = { n = 3 } },
					},
				},
			},
			{ executors = executors }
		)
		T.eq(#out.results, 3)
		T.eq(out.results[1].val, 2)
		T.eq(out.results[2].val, 4)
		T.eq(out.results[3].val, 6)
	end)
end)

-- ── 7. Combinator: retry ──────────────────────────────────────────────────────

T.describe("combinator: retry", function()
	T.it("retries a failing task up to max times", function()
		local attempts = 0
		local executors = {
			flaky = function()
				attempts = attempts + 1
				if attempts < 3 then error("not yet") end
				return { ok = true }
			end,
		}
		local out = orch.run(
			{ type = "retry", input = { task = { type = "flaky", input = {} }, max = 3 } },
			{ executors = executors }
		)
		T.eq(out.ok, true)
		T.eq(attempts, 3)
	end)

	T.it("errors after exhausting retries", function()
		local executors = {
			always_fail = function() error("nope") end,
		}
		local ok, err = pcall(orch.run,
			{ type = "retry", input = { task = { type = "always_fail", input = {} }, max = 2 } },
			{ executors = executors }
		)
		T.fail(ok)
		T.ok(err:find("retry exhausted"))
	end)
end)

-- ── 8. Combinator: refine ─────────────────────────────────────────────────────

T.describe("combinator: refine", function()
	T.it("pipes first task output as input to second", function()
		local executors = {
			upper = function(t, _) return { text = t.input.text:upper() } end,
			wrap  = function(t, _) return { result = "[" .. t.input.text .. "]" } end,
		}
		local out = orch.run(
			{
				type = "refine",
				input = {
					task      = { type = "upper", input = { text = "hello" } },
					then_task = { type = "wrap",  input = {} },
				},
			},
			{ executors = executors }
		)
		T.eq(out.result, "[HELLO]")
	end)
end)

-- ── 9. on_task hook ───────────────────────────────────────────────────────────

T.describe("on_task hook", function()
	T.it("fires for every completed task", function()
		local fired = {}
		local executors = {
			root = function(_, ctx)
				local id = ctx:spawn({ type = "leaf", input = {} })
				ctx:result(id)
				return {}
			end,
			leaf = function() return {} end,
		}
		orch.run(
			{ type = "root", input = {} },
			{
				executors = executors,
				on_task   = function(t) fired[#fired + 1] = t.type end,
			}
		)
		-- leaf completes first (depth-first), then root
		T.eq(#fired, 2)
		T.eq(fired[1], "leaf")
		T.eq(fired[2], "root")
	end)
end)

-- ── 10. LLM executor (mocked) ─────────────────────────────────────────────────

T.describe("llm executor (mocked)", function()
	T.it("llm.complete returns text and usage", function()
		-- patch lib/ai.generate for the duration of this test
		local ai = require("lib.ai")
		local orig_gen = ai.generate
		ai.generate = function(_req)
			return { text = "mock response", usage = { input = 10, output = 5 } }
		end

		local ai_exec = require("lib.orchestration.executor.ai")
		local out = orch.run(
			{
				type  = "llm.complete",
				input = { messages = { { role = "user", content = "hi" } }, model = "test" },
			},
			{ executors = ai_exec.executors }
		)
		T.eq(out.text, "mock response")
		T.eq(out.usage.input, 10)

		ai.generate = orig_gen
	end)

	T.it("llm.tool_loop spawns subtasks for tool calls", function()
		local ai = require("lib.ai")
		local orig_gen = ai.generate
		local call_count = 0
		ai.generate = function(_req)
			call_count = call_count + 1
			if call_count == 1 then
				-- first call returns a tool call
				return {
					text = "",
					tool_calls = { { name = "add", id = "tc1", arguments = { a = 3, b = 4 } } },
				}
			else
				-- second call returns final text
				return { text = "the answer is 7", tool_calls = {} }
			end
		end

		local ai_exec = require("lib.orchestration.executor.ai")
		local executors = {
			add     = function(t, _) return { result = t.input.a + t.input.b } end,
		}
		for k, v in pairs(ai_exec.executors) do executors[k] = v end

		local out, g = orch.run(
			{
				type  = "llm.tool_loop",
				input = {
					messages = { { role = "user", content = "3+4?" } },
					model    = "test",
					tools    = { { name = "add", description = "add two numbers", handler_type = "add" } },
				},
			},
			{ executors = executors }
		)
		T.eq(out.text, "the answer is 7")
		T.eq(out.tool_calls, 1)

		-- verify subtask lineage: there should be an "add" task in the graph
		local found_add = false
		for t in orch.graph.tasks(g) do
			if t.type == "add" then found_add = true end
		end
		T.ok(found_add)

		ai.generate = orig_gen
	end)
end)
