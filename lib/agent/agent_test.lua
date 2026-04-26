if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T      = require("lib.test.assert")
local set    = require("lib.agent.set")
local render = require("lib.agent.render")
local leaf   = require("lib.agent.leaf")
local preset = require("lib.agent.preset")

-- ---------------------------------------------------------------------------
-- set
-- ---------------------------------------------------------------------------

T.describe("set.new", function()
	T.it("returns an empty table", function()
		local s = set.new()
		T.eq(next(s), nil)
	end)
end)

T.describe("set.note", function()
	T.it("adds a key", function()
		local s = set.new()
		local s2 = set.note(s, "foo", "bar")
		T.eq(set.get(s2, "foo"), "bar")
	end)

	T.it("does not mutate the original", function()
		local s = set.new()
		set.note(s, "foo", "bar")
		T.eq(set.get(s, "foo"), nil)
	end)

	T.it("replaces an existing key", function()
		local s = set.note(set.new(), "k", "v1")
		local s2 = set.note(s, "k", "v2")
		T.eq(set.get(s2, "k"), "v2")
		-- original unchanged
		T.eq(set.get(s, "k"), "v1")
	end)

	T.it("allows reserved _-prefixed keys", function()
		local s = set.note(set.new(), "_system", "hello")
		T.eq(set.get(s, "_system"), "hello")
	end)
end)

T.describe("set.drop", function()
	T.it("removes a key", function()
		local s = set.note(set.new(), "k", "v")
		local s2 = set.drop(s, "k")
		T.eq(set.get(s2, "k"), nil)
	end)

	T.it("is a no-op when key is absent", function()
		local s = set.new()
		local s2 = set.drop(s, "missing")
		T.eq(next(s2), nil)
	end)

	T.it("does not mutate the original", function()
		local s = set.note(set.new(), "k", "v")
		set.drop(s, "k")
		T.eq(set.get(s, "k"), "v")
	end)
end)

T.describe("set.get", function()
	T.it("returns nil for absent key", function()
		T.eq(set.get(set.new(), "x"), nil)
	end)

	T.it("returns the stored value", function()
		local s = set.note(set.new(), "x", 42)
		T.eq(set.get(s, "x"), 42)
	end)
end)

T.describe("set.merge", function()
	T.it("merges two sets", function()
		local s1 = set.note(set.new(), "a", 1)
		local s2 = set.note(set.new(), "b", 2)
		local m  = set.merge(s1, s2)
		T.eq(set.get(m, "a"), 1)
		T.eq(set.get(m, "b"), 2)
	end)

	T.it("s2 wins on collision", function()
		local s1 = set.note(set.new(), "k", "from_s1")
		local s2 = set.note(set.new(), "k", "from_s2")
		local m  = set.merge(s1, s2)
		T.eq(set.get(m, "k"), "from_s2")
	end)

	T.it("does not mutate originals", function()
		local s1 = set.note(set.new(), "k", "s1_val")
		local s2 = set.note(set.new(), "k", "s2_val")
		set.merge(s1, s2)
		T.eq(set.get(s1, "k"), "s1_val")
		T.eq(set.get(s2, "k"), "s2_val")
	end)
end)

T.describe("set.keys", function()
	T.it("returns sorted keys", function()
		local s = set.note(set.note(set.note(set.new(), "z", 1), "a", 2), "m", 3)
		local ks = set.keys(s)
		T.eq(ks[1], "a")
		T.eq(ks[2], "m")
		T.eq(ks[3], "z")
	end)

	T.it("returns empty list for empty set", function()
		T.eq(#set.keys(set.new()), 0)
	end)
end)

-- ---------------------------------------------------------------------------
-- render
-- ---------------------------------------------------------------------------

T.describe("render.render", function()
	T.it("empty set with nil inputs produces one user turn", function()
		local msgs = render.render(set.new(), nil)
		T.eq(#msgs, 1)
		T.eq(msgs[1].role, "user")
		T.eq(msgs[1].content, "")
	end)

	T.it("system field produces system turn first", function()
		local s = set.note(set.new(), "_system", "be helpful")
		local msgs = render.render(s, nil)
		T.eq(#msgs, 2)
		T.eq(msgs[1].role, "system")
		T.eq(msgs[1].content, "be helpful")
		T.eq(msgs[2].role, "user")
	end)

	T.it("no system turn when _system absent", function()
		local msgs = render.render(set.new(), nil)
		T.eq(msgs[1].role, "user")
		-- no system turn
		for _, m in ipairs(msgs) do
			T.ok(m.role ~= "system", "no system turn expected")
		end
	end)

	T.it("task inputs rendered as key: value lines", function()
		local msgs = render.render(set.new(), { query = "hello", lang = "lua" })
		local body = msgs[#msgs - 0].content  -- last user turn (no tool result)
		T.ok(body:find("query: hello"), "query line present")
		T.ok(body:find("lang: lua"), "lang line present")
	end)

	T.it("notes rendered alphabetically after inputs", function()
		local s = set.note(set.note(set.new(), "z_note", "z"), "a_note", "a")
		local msgs = render.render(s, nil)
		local body = msgs[#msgs].content
		-- notes: header
		T.ok(body:find("notes:"), "notes header present")
		-- a_note before z_note
		local ai = body:find("a_note")
		local zi = body:find("z_note")
		T.ok(ai and zi and ai < zi, "a_note before z_note")
	end)

	T.it("_-prefixed keys are excluded from notes", function()
		local s = set.note(set.note(set.new(), "_system", "sys"), "_tool_result", "tr")
		-- no extra notes (both are reserved)
		local msgs = render.render(s, nil)
		-- system turn + user turn only (no tool result in set here)
		-- _tool_result IS rendered as tool result turn
		T.ok(not msgs[#msgs].content:find("notes:"), "no notes section for reserved keys only")
	end)

	T.it("_tool_result produces a final user turn", function()
		local s = set.note(set.new(), "_tool_result", "stdout output")
		local msgs = render.render(s, nil)
		-- last turn is tool result
		local last = msgs[#msgs]
		T.eq(last.role, "user")
		T.ok(last.content:find("tool result:"), "tool result header")
		T.ok(last.content:find("stdout output"), "tool result content")
	end)

	T.it("tool result is the last turn", function()
		local s = set.note(set.note(set.new(), "_system", "sys"), "_tool_result", "out")
		s = set.note(s, "a_note", "val")
		local msgs = render.render(s, nil)
		-- system, user (inputs+notes), tool result
		T.eq(#msgs, 3)
		T.eq(msgs[1].role, "system")
		T.eq(msgs[3].role, "user")
		T.ok(msgs[3].content:find("tool result:"), "last turn is tool result")
	end)
end)

-- ---------------------------------------------------------------------------
-- leaf
-- ---------------------------------------------------------------------------

T.describe("leaf.run", function()
	T.it("returns result immediately from single llm call", function()
		local llm_called = 0
		local mock_caps = {
			llm = {
				generate = function(_req)
					llm_called = llm_called + 1
					return { result = "done" }
				end,
			},
		}
		local task_def  = { type = "test", inputs = { x = 1 } }
		local spec      = { output_schema = nil }
		local result, err = leaf.run(task_def, set.new(), mock_caps, spec)
		T.eq(err, nil)
		T.eq(result, "done")
		T.eq(llm_called, 1)
	end)

	T.it("applies notes_add from response", function()
		local call_count = 0
		local captured_set_state  -- we capture what the second call sees via the messages
		local mock_caps = {
			llm = {
				generate = function(req)
					call_count = call_count + 1
					if call_count == 1 then
						-- Add a note; no result yet.
						return { notes_add = { { key = "hyp", value = "maybe" } } }
					else
						-- On second call, result should include the note in messages.
						captured_set_state = req.messages
						return { result = "ok" }
					end
				end,
			},
		}
		local task_def = { type = "test", inputs = {} }
		local spec     = { output_schema = nil }
		local result, err = leaf.run(task_def, set.new(), mock_caps, spec)
		T.eq(err, nil)
		T.eq(result, "ok")
		-- The second messages array should include the note.
		local found = false
		for _, m in ipairs(captured_set_state) do
			if m.content:find("hyp") then found = true end
		end
		T.ok(found, "note 'hyp' appears in second call messages")
	end)

	T.it("executes tool_call and stores result in _tool_result", function()
		local call_count  = 0
		local exec_called = false
		local exec_args_received
		local mock_caps = {
			llm = {
				generate = function(req)
					call_count = call_count + 1
					if call_count == 1 then
						return { tool_call = { name = "normalize", args = { "view", "." } } }
					else
						-- Verify tool result is in messages.
						local found_tr = false
						for _, m in ipairs(req.messages) do
							if m.content:find("tool result:") then found_tr = true end
						end
						T.ok(found_tr, "_tool_result present in messages after tool call")
						return { result = "finished" }
					end
				end,
			},
			exec = function(name, args)
				exec_called = true
				exec_args_received = { name = name, args = args }
				return "tool stdout"
			end,
		}
		local task_def = { type = "test", inputs = {} }
		local spec     = { output_schema = nil }
		local result, err = leaf.run(task_def, set.new(), mock_caps, spec)
		T.eq(err, nil)
		T.eq(result, "finished")
		T.ok(exec_called, "exec was called")
		T.eq(exec_args_received.name, "normalize")
	end)

	T.it("errors when tool_call present but no exec cap", function()
		local mock_caps = {
			llm = {
				generate = function(_req)
					return { tool_call = { name = "foo", args = {} } }
				end,
			},
		}
		local task_def = { type = "test", inputs = {} }
		local spec     = { output_schema = nil }
		local result, err = leaf.run(task_def, set.new(), mock_caps, spec)
		T.eq(result, nil)
		T.ok(err and err:find("no exec cap"), "error mentions no exec cap")
	end)

	T.it("returns error after max_iterations exhausted", function()
		local mock_caps = {
			llm = {
				generate = function(_req)
					-- Never returns a result.
					return { notes_add = {} }
				end,
			},
		}
		local task_def = { type = "test", inputs = {}, max_iterations = 3 }
		local spec     = { output_schema = nil }
		local result, err = leaf.run(task_def, set.new(), mock_caps, spec)
		T.eq(result, nil)
		T.ok(err and err:find("max_iterations"), "error mentions max_iterations")
	end)

	T.it("skips reserved keys in notes_add", function()
		local call_count = 0
		local mock_caps = {
			llm = {
				generate = function(_req)
					call_count = call_count + 1
					if call_count == 1 then
						-- Try to overwrite _system via notes_add.
						return { notes_add = { { key = "_system", value = "hijacked" } } }
					else
						return { result = "done" }
					end
				end,
			},
		}
		local s = set.note(set.new(), "_system", "original")
		local task_def = { type = "test", inputs = {} }
		local spec     = { output_schema = nil }
		local result, err = leaf.run(task_def, s, mock_caps, spec)
		T.eq(err, nil)
		T.eq(result, "done")
		-- _system should remain "original" (reserved key was dropped).
		T.eq(set.get(s, "_system"), "original")
	end)

	T.it("propagates llm errors", function()
		local mock_caps = {
			llm = {
				generate = function(_req)
					return nil, "connection refused"
				end,
			},
		}
		local task_def = { type = "test", inputs = {} }
		local spec     = { output_schema = nil }
		local result, err = leaf.run(task_def, set.new(), mock_caps, spec)
		T.eq(result, nil)
		T.ok(err and err:find("connection refused"), "llm error propagated")
	end)
end)

-- ---------------------------------------------------------------------------
-- preset
-- ---------------------------------------------------------------------------

T.describe("preset.register + run", function()
	T.it("run dispatches to leaf.run for spec without executor_fn", function()
		local llm_called = false
		preset.register("test_preset_leaf", {
			input_schema   = nil,
			output_schema  = nil,
			system         = "you are a test agent",
			max_iterations = 5,
		})
		local caps = {
			llm = {
				generate = function(req)
					llm_called = true
					-- Verify system turn is present.
					T.eq(req.messages[1].role, "system")
					T.ok(req.messages[1].content:find("you are a test agent"), "system content")
					return { result = "preset_output" }
				end,
			},
		}
		local result, err = preset.run("test_preset_leaf", { data = "x" }, caps)
		T.eq(err, nil)
		T.eq(result, "preset_output")
		T.ok(llm_called, "llm was called")
	end)

	T.it("run dispatches to executor_fn when provided", function()
		local fn_called = false
		preset.register("test_preset_fn", {
			input_schema  = nil,
			output_schema = nil,
			executor_fn   = function(inputs, _caps)
				fn_called = true
				T.eq(inputs.key, "value")
				return "fn_result"
			end,
		})
		local caps = { llm = { generate = function() return { result = "x" } end } }
		local result, err = preset.run("test_preset_fn", { key = "value" }, caps)
		T.eq(err, nil)
		T.eq(result, "fn_result")
		T.ok(fn_called, "executor_fn was called")
	end)

	T.it("run returns error for unknown preset", function()
		local result, err = preset.run("no_such_preset_xyz", {}, {})
		T.eq(result, nil)
		T.ok(err and err:find("not registered"), "error mentions not registered")
	end)

	T.it("preset without system does not add system turn", function()
		local system_found = false
		preset.register("test_preset_nosys", {
			input_schema  = nil,
			output_schema = nil,
			-- no system field
		})
		local caps = {
			llm = {
				generate = function(req)
					for _, m in ipairs(req.messages) do
						if m.role == "system" then system_found = true end
					end
					return { result = "ok" }
				end,
			},
		}
		local result, err = preset.run("test_preset_nosys", {}, caps)
		T.eq(err, nil)
		T.eq(result, "ok")
		T.ok(not system_found, "no system turn when system is nil")
	end)
end)
