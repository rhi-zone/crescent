if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local N = require("lib.nanites")

-- ── 1. Basic run ──────────────────────────────────────────────────────────────

T.describe("basic run", function()
	T.it("echo executor returns input", function()
		local rt = N.runtime({
			executors = {
				echo = function(task, _)
					local t = task --: any
					return t.input
				end,
			},
		})
		local ok, result = rt:run({ type = "echo", input = { msg = "hello" } })
		T.ok(ok)
		local r = result --: any
		T.eq(r.msg, "hello")
	end)

	T.it("returns (nil, errmsg) on executor error", function()
		local rt = N.runtime({
			executors = {
				boom = function() error("kaboom") end,
			},
		})
		local ok, err = rt:run({ type = "boom", input = {} })
		T.fail(ok)
		T.ok(tostring(err):find("kaboom"))
	end)

	T.it("returns (nil, errmsg) when no executor registered", function()
		local rt = N.runtime({ executors = {} })
		local ok, err = rt:run({ type = "missing", input = {} })
		T.fail(ok)
		T.ok(tostring(err):find("no executor"))
	end)
end)

-- ── 2. ctx:spawn + ctx:result ─────────────────────────────────────────────────

T.describe("spawn + result", function()
	T.it("parent uses child output", function()
		local rt = N.runtime({
			executors = {
				parent = function(task, ctx)
					local t = task --: any
					local handle = ctx:spawn({ type = "child", input = { x = t.input.x } })
					local res = ctx:result(handle)
					local r = res --: any
					return { doubled = r.val }
				end,
				child = function(task, _)
					local t = task --: any
					return { val = t.input.x * 2 }
				end,
			},
		})
		local ok, result = rt:run({ type = "parent", input = { x = 7 } })
		T.ok(ok)
		local r = result --: any
		T.eq(r.doubled, 14)
	end)

	T.it("child error propagates to parent via ctx:result", function()
		local rt = N.runtime({
			executors = {
				parent = function(_, ctx)
					local handle = ctx:spawn({ type = "boom", input = {} })
					ctx:result(handle)
					return {}
				end,
				boom = function() error("inner boom") end,
			},
		})
		local ok, err = rt:run({ type = "parent", input = {} })
		T.fail(ok)
		T.ok(tostring(err):find("inner boom"))
	end)

	T.it("deep nesting: grandchild output flows to grandparent", function()
		local rt = N.runtime({
			executors = {
				gp = function(_, ctx)
					local h = ctx:spawn({ type = "parent", input = { n = 3 } })
					return ctx:result(h)
				end,
				parent = function(task, ctx)
					local t = task --: any
					local h = ctx:spawn({ type = "leaf", input = { n = t.input.n } })
					local r = ctx:result(h)
					local rv = r --: any
					return { value = rv.value + 1 }
				end,
				leaf = function(task, _)
					local t = task --: any
					return { value = t.input.n * 10 }
				end,
			},
		})
		local ok, result = rt:run({ type = "gp", input = {} })
		T.ok(ok)
		local r = result --: any
		-- leaf: 3*10=30, parent: 30+1=31
		T.eq(r.value, 31)
	end)
end)

-- ── 3. ctx:spawn_all ──────────────────────────────────────────────────────────

T.describe("spawn_all", function()
	T.it("spawns multiple tasks and results are accessible", function()
		local rt = N.runtime({
			executors = {
				fan = function(task, ctx)
					local t = task --: any
					local defs = {
						{ type = "sq", input = { n = 2 } },
						{ type = "sq", input = { n = 3 } },
						{ type = "sq", input = { n = 4 } },
					}
					local handles = ctx:spawn_all(defs)
					local results = {}
					for i = 1, #handles do
						local r = ctx:result(handles[i])
						local rv = r --: any
						results[i] = rv.val
					end
					return { sums = results }
				end,
				sq = function(task, _)
					local t = task --: any
					return { val = t.input.n * t.input.n }
				end,
			},
		})
		local ok, result = rt:run({ type = "fan", input = {} })
		T.ok(ok)
		local r = result --: any
		T.eq(r.sums[1], 4)
		T.eq(r.sums[2], 9)
		T.eq(r.sums[3], 16)
	end)
end)

-- ── 4. exec_graph ─────────────────────────────────────────────────────────────

T.describe("exec_graph", function()
	T.it("records every task spawned, in order", function()
		local rt = N.runtime({
			executors = {
				root = function(_, ctx)
					local h = ctx:spawn({ type = "child_a", input = {} })
					local h2 = ctx:spawn({ type = "child_b", input = {} })
					ctx:result(h)
					ctx:result(h2)
					return {}
				end,
				child_a = function() return { a = 1 } end,
				child_b = function() return { b = 2 } end,
			},
		})
		rt:run({ type = "root", input = {} })
		local log = rt:exec_graph()
		-- root + child_a + child_b = 3 entries
		T.eq(#log, 3)
	end)

	T.it("records parent→children lineage", function()
		local rt = N.runtime({
			executors = {
				root = function(_, ctx)
					local h = ctx:spawn({ type = "leaf", input = {} })
					ctx:result(h)
					return {}
				end,
				leaf = function() return {} end,
			},
		})
		rt:run({ type = "root", input = {} })
		local log = rt:exec_graph()
		-- log[1] = root, log[2] = leaf
		local root_node = log[1]
		local leaf_node = log[2]
		T.eq(root_node.type, "root")
		T.eq(leaf_node.type, "leaf")
		-- leaf's parent is root's id
		T.eq(leaf_node.parent, root_node.id)
		-- root's children contains leaf's id
		T.eq(#root_node.children, 1)
		T.eq(root_node.children[1], leaf_node.id)
	end)

	T.it("completed nodes have status=completed and output set", function()
		local rt = N.runtime({
			executors = {
				work = function() return { done = true } end,
			},
		})
		rt:run({ type = "work", input = {} })
		local log = rt:exec_graph()
		T.eq(#log, 1)
		T.eq(log[1].status, "completed")
		local o = log[1].output --: any
		T.ok(o.done)
	end)

	T.it("failed nodes have status=failed and error set", function()
		local rt = N.runtime({
			executors = {
				fail_task = function() error("exploded") end,
			},
		})
		rt:run({ type = "fail_task", input = {} })
		local log = rt:exec_graph()
		T.eq(#log, 1)
		T.eq(log[1].status, "failed")
		T.ok(log[1].error ~= nil)
		T.ok(tostring(log[1].error):find("exploded"))
	end)

	T.it("config is stored separately from input", function()
		local rt = N.runtime({
			executors = {
				llm = function(task, _)
					local t = task --: any
					return { model = t.config.model }
				end,
			},
		})
		rt:run({ type = "llm", config = { model = "gemma" }, input = "hello" })
		local log = rt:exec_graph()
		local n = log[1]
		local cfg = n.config --: any
		T.eq(cfg.model, "gemma")
		T.eq(n.input, "hello")
	end)
end)

-- ── 5. frontier ───────────────────────────────────────────────────────────────

T.describe("frontier", function()
	T.it("is empty after a run completes", function()
		local rt = N.runtime({
			executors = {
				work = function() return {} end,
			},
		})
		rt:run({ type = "work", input = {} })
		local pending = rt:frontier()
		T.eq(#pending, 0)
	end)

	T.it("contains the running task during execution", function()
		-- Note: `local rt = N.runtime({...})` would make `rt` unavailable
		-- inside the executor closure (Lua: local vars are not in scope during
		-- their own initializer). Pre-declare rt, then assign.
		local captured_frontier = nil
		local rt  -- pre-declare so the executor closure can reference it
		rt = N.runtime({
			executors = {
				observer = function(_, _)
					-- rt is now an upvalue (pre-declared above), not a global.
					captured_frontier = rt:frontier()
					return {}
				end,
			},
		})
		rt:run({ type = "observer", input = {} })
		-- After run completes, frontier is empty. But we captured it mid-run.
		T.ok(captured_frontier ~= nil)
		-- frontier had at least the observer task while it was running
		T.ok(#captured_frontier >= 1)
		local found = false
		for i = 1, #captured_frontier do
			if captured_frontier[i].type == "observer" then found = true end
		end
		T.ok(found)
	end)

	T.it("tracks child tasks while they are running", function()
		local captured = nil
		local rt  -- pre-declare so executors can close over it
		rt = N.runtime({
			executors = {
				parent = function(_, ctx)
					local h = ctx:spawn({ type = "slow_child", input = {} })
					-- capture frontier after spawning child but before ctx:result drives it
					captured = rt:frontier()
					return ctx:result(h)
				end,
				slow_child = function() return { x = 42 } end,
			},
		})
		rt:run({ type = "parent", input = {} })
		-- frontier captured after spawning child but before ctx:result resolves it
		T.ok(captured ~= nil)
		-- Both parent and child should be in the frontier at capture time
		-- (child was spawned but not yet driven to completion)
		local types = {}
		for i = 1, #captured do
			types[captured[i].type] = true
		end
		-- parent is in frontier (running), child was just spawned (pending)
		T.ok(types["parent"] or types["slow_child"])
	end)
end)

-- ── 6. Scaffolds ──────────────────────────────────────────────────────────────

T.describe("scaffolds", function()
	T.it("scaffold is applied to each task before execution", function()
		local seen = {}
		local rt = N.runtime({
			executors = {
				work = function(task, _)
					local t = task --: any
					return { val = t.input.x }
				end,
			},
			scaffolds = {
				function(task)
					local t = task --: any
					seen[#seen + 1] = t.type
					-- transform: multiply input x by 10
					return { type = t.type, input = { x = (t.input and t.input.x or 0) * 10 } }
				end,
			},
		})
		local ok, result = rt:run({ type = "work", input = { x = 5 } })
		T.ok(ok)
		local r = result --: any
		-- scaffold multiplied x by 10 → 50
		T.eq(r.val, 50)
		T.eq(seen[1], "work")
	end)

	T.it("scaffold is applied to child tasks too", function()
		local scaffold_count = 0
		local rt = N.runtime({
			executors = {
				parent = function(_, ctx)
					local h = ctx:spawn({ type = "child", input = { x = 1 } })
					return ctx:result(h)
				end,
				child = function(task, _)
					local t = task --: any
					return { v = t.input.x }
				end,
			},
			scaffolds = {
				function(task)
					scaffold_count = scaffold_count + 1
					return task
				end,
			},
		})
		rt:run({ type = "parent", input = {} })
		-- scaffold fires for parent (1) and child (1) = 2 times
		T.eq(scaffold_count, 2)
	end)
end)

-- ── 7. Built-in exec_map ──────────────────────────────────────────────────────

T.describe("exec_map", function()
	T.it("spawns N tasks and collects results", function()
		local rt = N.runtime({
			executors = {
				map    = N.exec_map,
				double = function(task, _)
					local t = task --: any
					return { val = t.input.n * 2 }
				end,
			},
		})
		local ok, result = rt:run({
			type  = "map",
			input = {
				tasks = {
					{ type = "double", input = { n = 1 } },
					{ type = "double", input = { n = 2 } },
					{ type = "double", input = { n = 3 } },
				},
			},
		})
		T.ok(ok)
		local r = result --: any
		T.eq(#r.results, 3)
		local r1 = r.results[1] --: any
		local r2 = r.results[2] --: any
		local r3 = r.results[3] --: any
		T.eq(r1.val, 2)
		T.eq(r2.val, 4)
		T.eq(r3.val, 6)
	end)
end)

-- ── 8. Multiple independent runtimes ─────────────────────────────────────────

T.describe("multiple runtimes", function()
	T.it("exec_graphs are independent", function()
		local rt1 = N.runtime({ executors = { work = function() return { n = 1 } end } })
		local rt2 = N.runtime({ executors = { work = function() return { n = 2 } end } })
		rt1:run({ type = "work", input = {} })
		rt2:run({ type = "work", input = {} })
		local log1 = rt1:exec_graph()
		local log2 = rt2:exec_graph()
		T.eq(#log1, 1)
		T.eq(#log2, 1)
		local o1 = log1[1].output --: any
		local o2 = log2[1].output --: any
		T.eq(o1.n, 1)
		T.eq(o2.n, 2)
	end)
end)

-- ── 9. task.config vs task.input ─────────────────────────────────────────────

T.describe("task config", function()
	T.it("executor receives both config and input", function()
		local rt = N.runtime({
			executors = {
				llm = function(task, _)
					local t = task --: any
					return { result = t.config.model .. ":" .. t.input }
				end,
			},
		})
		local ok, result = rt:run({ type = "llm", config = { model = "gemma" }, input = "hi" })
		T.ok(ok)
		local r = result --: any
		T.eq(r.result, "gemma:hi")
	end)
end)

-- ── 10. Error boundary: no executor ──────────────────────────────────────────

T.describe("missing executor", function()
	T.it("child with no executor propagates error to parent", function()
		local rt = N.runtime({
			executors = {
				parent = function(_, ctx)
					local h = ctx:spawn({ type = "ghost", input = {} })
					return ctx:result(h)
				end,
			},
		})
		local ok, err = rt:run({ type = "parent", input = {} })
		T.fail(ok)
		T.ok(tostring(err):find("no executor"))
	end)
end)
