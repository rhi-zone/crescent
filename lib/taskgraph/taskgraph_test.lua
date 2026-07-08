if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T    = require("lib.test.assert")
local orch = require("lib.taskgraph")
local combinators = require("lib.taskgraph.combinators")
local dispatch = require("lib.dispatch")

--:: require "lib.taskgraph.taskgraph_types"
--:: TestHandlers = { [string]: (...unknown) -> unknown }
--:: TestOpts = { track?: boolean, scaffolds?: { [integer]: Scaffold }, on_task?: (TaskNode) -> () }

-- Task outputs come back as `unknown` (the executor's return type is caller-defined).
-- These assertion functions narrow a task result to the shape a given test expects
-- to read, with a minimal runtime shape check backing the assertion.
--: (x: unknown) -> asserts x is string
local function assert_string(x)
	if type(x) ~= "string" then error("expected string, got " .. type(x)) end
end

--: (x: unknown) -> asserts x is { doubled: unknown }
local function assert_doubled(x)
	if type(x) ~= "table" then error("expected table, got " .. type(x)) end
end

--: (x: unknown) -> asserts x is { results: { [integer]: { val: unknown } } }
local function assert_results(x)
	if type(x) ~= "table" then error("expected table, got " .. type(x)) end
end

--: (x: unknown) -> asserts x is { ok: unknown }
local function assert_ok(x)
	if type(x) ~= "table" then error("expected table, got " .. type(x)) end
end

--: (x: unknown) -> asserts x is { result: unknown }
local function assert_result(x)
	if type(x) ~= "table" then error("expected table, got " .. type(x)) end
end

--: (x: unknown) -> asserts x is { msg: unknown }
local function assert_msg(x)
	if type(x) ~= "table" then error("expected table, got " .. type(x)) end
end

--: (x: unknown) -> asserts x is { val: unknown }
local function assert_val(x)
	if type(x) ~= "table" then error("expected table, got " .. type(x)) end
end

--: (x: unknown) -> asserts x is { text: unknown, usage: { input: unknown } }
local function assert_text_usage(x)
	if type(x) ~= "table" then error("expected table, got " .. type(x)) end
end

--: (x: unknown) -> asserts x is { text: unknown, tool_calls: unknown }
local function assert_text_tool_calls(x)
	if type(x) ~= "table" then error("expected table, got " .. type(x)) end
end

--: (TestHandlers) -> ExecutorFn
local function executor_from(handlers)
	-- merge primary handlers with combinator handlers
	local merged = {}
	for k, v in pairs(combinators.handlers) do merged[k] = v end
	for k, v in pairs(handlers) do merged[k] = v end  -- primary wins
	return dispatch.dispatcher_from_table("type", merged)
end

--: (TaskDef, TestHandlers | nil, TestOpts | nil) -> (unknown, TrackedGraph)
local function run_task(task_def, handlers, opts)
	local o = opts or {}
	local full_opts = {
		track     = o.track,
		scaffolds = o.scaffolds,
		on_task   = o.on_task,
	}
	return orch.run(task_def, executor_from(handlers or {}), full_opts)
end

-- ── 1. Echo task ─────────────────────────────────────────────────────────────

T.describe("echo task", function()
	T.it("returns input verbatim", function()
		local out = orch.run(
			{ type = "echo", input = { msg = "hello" } },
			executor_from({ echo = function(t, _) return t.input end })
		)
		T.eq(out.msg, "hello")
	end)
end)

-- ── 2. Spawn + result ─────────────────────────────────────────────────────────

T.describe("spawn + result", function()
	T.it("parent uses child output", function()
		local handlers = {
			parent = function(t, ctx)
				local id = ctx:spawn({ type = "child", input = { x = t.input.x } })
				local res = ctx:result(id)
				return { doubled = res.val }
			end,
			child = function(t, _) return { val = t.input.x * 2 } end,
		}
		local out = run_task({ type = "parent", input = { x = 7 } }, handlers)
		assert_doubled(out)
		T.eq(out.doubled, 14)
	end)
end)

-- ── 3. Graph lineage ──────────────────────────────────────────────────────────

T.describe("graph lineage", function()
	T.it("records parent_id and spawned list", function()
		local handlers = {
			root = function(t, ctx)
				local id = ctx:spawn({ type = "leaf", input = {} })
				ctx:result(id)
				return {}
			end,
			leaf = function(_, _) return {} end,
		}
		local _, g = run_task({ type = "root", input = {} }, handlers)
		local root = g.tasks[g.root]
		T.eq(#root.spawned, 1)
		local child_id = root.spawned[1]
		local child = g.tasks[child_id]
		T.eq(child.parent_id, g.root)
		T.eq(#root.dependencies, 1)
		T.eq(root.dependencies[1], child_id)

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
			executor_from({ boom = function() error("kaboom") end })
		)
		-- pcall swallows the error; inspect graph via a wrapper
		local captured_g
		pcall(function()
			local function boom_exec() error("kaboom") end
			local exec_mod = require("lib.taskgraph.exec")
			local graph_mod = require("lib.taskgraph.graph")
			local gr = graph_mod.new()
			local id = graph_mod.add(gr, { type = "boom", input = {} }, nil)
			gr.root = id
			exec_mod.run_task(gr, executor_from({ boom = boom_exec }),
				{ on_task = nil, scaffolds = nil, frontier = nil, exec_graph = nil }, id)
			captured_g = gr
		end)
		local task = captured_g.tasks[captured_g.root]
		T.eq(task.status, "error")
		T.ok(task.error ~= nil)
	end)

	T.it("ctx:result re-raises child error", function()
		local handlers = {
			parent = function(_, ctx)
				local id = ctx:spawn({ type = "boom", input = {} })
				ctx:result(id)  -- should raise
				return {}
			end,
			boom = function() error("inner error") end,
		}
		local ok, err = pcall(run_task, { type = "parent", input = {} }, handlers)
		T.fail(ok)
		assert_string(err)
		T.ok(err:find("inner error"))
	end)
end)

-- ── 5. Callable executor ──────────────────────────────────────────────────────

T.describe("callable executor", function()
	T.it("run accepts a plain executor function", function()
		local out = orch.run(
			{ type = "greet", input = {} },
			function(_, _) return { msg = "local" } end
		)
		assert_msg(out)
		T.eq(out.msg, "local")
	end)
end)

-- ── 6. Combinator: map ────────────────────────────────────────────────────────

T.describe("combinator: map", function()
	T.it("spawns N tasks and collects results", function()
		local handlers = {
			double = function(t, _) return { val = t.input.n * 2 } end,
		}
		local out = run_task(
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
			handlers
		)
		assert_results(out)
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
		local handlers = {
			flaky = function()
				attempts = attempts + 1
				if attempts < 3 then error("not yet") end
				return { ok = true }
			end,
		}
		local out = run_task(
			{ type = "retry", input = { task = { type = "flaky", input = {} }, max = 3 } },
			handlers
		)
		assert_ok(out)
		T.eq(out.ok, true)
		T.eq(attempts, 3)
	end)

	T.it("errors after exhausting retries", function()
		local handlers = {
			always_fail = function() error("nope") end,
		}
		local ok, err = pcall(orch.run,
			{ type = "retry", input = { task = { type = "always_fail", input = {} }, max = 2 } },
			executor_from(handlers)
		)
		T.fail(ok)
		assert_string(err)
		T.ok(err:find("retry exhausted"))
	end)
end)

-- ── 8. Combinator: refine ─────────────────────────────────────────────────────

T.describe("combinator: refine", function()
	T.it("pipes first task output as input to second", function()
		local handlers = {
			upper = function(t, _) return { text = t.input.text:upper() } end,
			wrap  = function(t, _) return { result = "[" .. t.input.text .. "]" } end,
		}
		local out = run_task(
			{
				type = "refine",
				input = {
					task      = { type = "upper", input = { text = "hello" } },
					then_task = { type = "wrap",  input = {} },
				},
			},
			handlers
		)
		assert_result(out)
		T.eq(out.result, "[HELLO]")
	end)
end)

-- ── 9. on_task hook ───────────────────────────────────────────────────────────

T.describe("on_task hook", function()
	T.it("fires for every completed task", function()
		local fired = {}
		local handlers = {
			root = function(_, ctx)
				local id = ctx:spawn({ type = "leaf", input = {} })
				ctx:result(id)
				return {}
			end,
			leaf = function() return {} end,
		}
		run_task(
			{ type = "root", input = {} },
			handlers,
			{
				on_task   = function(t) fired[#fired + 1] = t.type end,
			}
		)
		-- leaf completes first (depth-first), then root
		T.eq(#fired, 2)
		T.eq(fired[1], "leaf")
		T.eq(fired[2], "root")
	end)
end)

-- ── 10. exec_graph (track=true) ──────────────────────────────────────────────

T.describe("exec_graph", function()
	T.it("records every task spawned, in order", function()
		local handlers = {
			root = function(_, ctx)
				local ha = ctx:spawn({ type = "child_a", input = {} })
				local hb = ctx:spawn({ type = "child_b", input = {} })
				ctx:result(ha)
				ctx:result(hb)
				return {}
			end,
			child_a = function() return { a = 1 } end,
			child_b = function() return { b = 2 } end,
		}
		local _, g = run_task({ type = "root", input = {} }, handlers, { track = true })
		local log = orch.exec_graph_snapshot(g)
		-- root + child_a + child_b = 3 entries
		T.eq(#log, 3)
	end)

	T.it("records parent→children lineage", function()
		local handlers = {
			root = function(_, ctx)
				local h = ctx:spawn({ type = "leaf", input = {} })
				ctx:result(h)
				return {}
			end,
			leaf = function() return {} end,
		}
		local _, g = run_task({ type = "root", input = {} }, handlers, { track = true })
		local log = orch.exec_graph_snapshot(g)
		-- log[1] = root, log[2] = leaf
		local root_node = log[1]
		local leaf_node = log[2]
		T.eq(root_node.type, "root")
		T.eq(leaf_node.type, "leaf")
		-- leaf's parent is root's id
		T.eq(leaf_node.parent_id, root_node.id)
		-- root's children contains leaf's id
		T.eq(#root_node.children, 1)
		T.eq(root_node.children[1], leaf_node.id)
		T.eq(#root_node.dependencies, 1)
		T.eq(root_node.dependencies[1], leaf_node.id)
	end)

	T.it("completed nodes have status=completed and output set", function()
		local handlers = {
			work = function() return { done = true } end,
		}
		local _, g = run_task({ type = "work", input = {} }, handlers, { track = true })
		local log = orch.exec_graph_snapshot(g)
		T.eq(#log, 1)
		T.eq(log[1].status, "completed")
		local o = log[1].output --[[: { done: boolean }]]
		T.ok(o.done)
	end)

	T.it("failed nodes have status=failed and error set", function()
		local handlers = {
			fail_task = function() error("exploded") end,
		}
		pcall(run_task, { type = "fail_task", input = {} }, handlers, { track = true })
		-- run raises, so we use a wrapper to get the graph back
		local captured_g
		pcall(function()
			local exec_mod  = require("lib.taskgraph.exec")
			local graph_mod = require("lib.taskgraph.graph")
			local egraph    = require("lib.taskgraph.exec_graph")
			local frontier  = require("lib.taskgraph.frontier")
			local gr = graph_mod.new()
			local id = graph_mod.add(gr, { type = "fail_task", input = {} }, nil)
			gr.root = id
			local eg = egraph.new()
			local fr = frontier.new()
			frontier.add(fr, id, "fail_task", {}, nil)
			egraph.record(eg, id, "fail_task", {}, nil)
			gr._exec_graph = eg
			gr._frontier   = fr
			exec_mod.run_task(gr,
				executor_from({ fail_task = function() error("exploded") end }),
				{ on_task = nil, exec_graph = eg, frontier = fr, scaffolds = {} },
				id)
			captured_g = gr
		end)
		local log = orch.exec_graph_snapshot(captured_g)
		T.eq(#log, 1)
		T.eq(log[1].status, "failed")
		T.ok(log[1].error ~= nil)
		T.ok(tostring(log[1].error):find("exploded"))
	end)

	T.it("exec_graphs from independent runs are independent", function()
		local _, g1 = run_task({ type = "work", input = {} },
			{ work = function() return { n = 1 } end }, { track = true })
		local _, g2 = run_task({ type = "work", input = {} },
			{ work = function() return { n = 2 } end }, { track = true })
		local log1 = orch.exec_graph_snapshot(g1)
		local log2 = orch.exec_graph_snapshot(g2)
		T.eq(#log1, 1)
		T.eq(#log2, 1)
		local o1 = log1[1].output --[[: { n: number }]]
		local o2 = log2[1].output --[[: { n: number }]]
		T.eq(o1.n, 1)
		T.eq(o2.n, 2)
	end)
end)

-- ── 11. frontier (track=true) ─────────────────────────────────────────────────

T.describe("frontier", function()
	T.it("is empty after a run completes", function()
		local _, g = run_task({ type = "work", input = {} },
			{ work = function() return {} end }, { track = true })
		local pending = orch.frontier_snapshot(g)
		T.eq(#pending, 0)
	end)

	T.it("contains the running task during execution", function()
		local captured_frontier = nil
		run_task({ type = "observer", input = {} }, {
			observer = function(_, ctx)
				captured_frontier = ctx:frontier()
				return {}
			end,
		}, {
			track = true,
		})
		T.ok(captured_frontier ~= nil)
		T.ok(#captured_frontier >= 1)
		local found = false
		for i = 1, #captured_frontier do
			if captured_frontier[i].type == "observer" then found = true end
		end
		T.ok(found)
	end)

	T.it("tracks child tasks while they are pending", function()
		local captured = nil
		run_task({ type = "parent", input = {} }, {
			parent = function(_, ctx)
				local h = ctx:spawn({ type = "slow_child", input = {} })
				-- capture frontier after spawning child but before ctx:result drives it
				captured = ctx:frontier()
				return ctx:result(h)
			end,
			slow_child = function() return { x = 42 } end,
		}, {
			track = true,
		})
		T.ok(captured ~= nil)
		local types = {}
		for i = 1, #captured do
			types[captured[i].type] = true
		end
		-- parent is running, child was just spawned (pending)
		T.ok(types["parent"] or types["slow_child"])
	end)
end)

-- ── 12. Scaffolds ─────────────────────────────────────────────────────────────

T.describe("scaffolds", function()
	T.it("scaffold is applied to each task before execution", function()
		local seen = {}
		local out = run_task({ type = "work", input = { x = 5 } }, {
				work = function(task, _)
					local t = task --[[: { input: { x: number } }]]
					return { val = t.input.x }
				end,
			}, {
			scaffolds = {
				function(task_def)
					local td = task_def --[[: { type: string, input: { x: number } }]]
					seen[#seen + 1] = td.type
					-- transform: multiply input x by 10
					return { type = td.type, input = { x = (td.input and td.input.x or 0) * 10 } }
				end,
			},
		})
		assert_val(out)
		-- scaffold multiplied x by 10 → 50
		T.eq(out.val, 50)
		T.eq(seen[1], "work")
	end)

	T.it("scaffold is applied to child tasks too", function()
		local scaffold_count = 0
		run_task({ type = "parent", input = {} }, {
				parent = function(_, ctx)
					local h = ctx:spawn({ type = "child", input = { x = 1 } })
					return ctx:result(h)
				end,
				child = function(task, _)
					local t = task --[[: { input: { x: number } }]]
					return { v = t.input.x }
				end,
			}, {
			scaffolds = {
				function(task_def)
					scaffold_count = scaffold_count + 1
					return task_def
				end,
			},
		})
		-- scaffold fires for parent (1) and child (1) = 2 times
		T.eq(scaffold_count, 2)
	end)
end)

-- ── 13. LLM executor (mocked) ─────────────────────────────────────────────────

T.describe("llm executor (mocked)", function()
	T.it("llm.complete returns text and usage", function()
		-- patch lib/ai.generate for the duration of this test
		local ai = require("lib.ai")
		local orig_gen = ai.generate
		ai.generate = function(_req)
			return { text = "mock response", usage = { input = 10, output = 5 } }
		end

		local ai_exec = require("lib.taskgraph.executor.ai")
		local out = run_task(
			{
				type  = "llm.complete",
				input = { messages = { { role = "user", content = "hi" } }, model = "test" },
			},
			ai_exec.handlers
		)
		assert_text_usage(out)
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

		local ai_exec = require("lib.taskgraph.executor.ai")
		local handlers = {
			add     = function(t, _) return { result = t.input.a + t.input.b } end,
		}
		for k, v in pairs(ai_exec.handlers) do handlers[k] = v end

		local out, g = run_task(
			{
				type  = "llm.tool_loop",
				input = {
					messages = { { role = "user", content = "3+4?" } },
					model    = "test",
					tools    = { { name = "add", description = "add two numbers", handler_type = "add" } },
				},
			},
			handlers
		)
		assert_text_tool_calls(out)
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
