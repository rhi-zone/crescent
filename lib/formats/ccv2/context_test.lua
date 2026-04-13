-- lib/formats/ccv2/context_test.lua

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local context = require("lib.formats.ccv2.context")
local lorebook = require("lib.formats.ccv2.lorebook")

-- ── helpers ──────────────────────────────────────────────────────────────────

-- Simple token counter: 1 token per word.
local function count_tokens(text)
	if not text or text == "" then return 0 end
	local n = 0
	for _ in text:gmatch("%S+") do n = n + 1 end
	return n
end

local function make_card(overrides)
	local card = {
		name = "Alice",
		description = "A helpful assistant",
		personality = "Friendly and cheerful",
		scenario = "A chat room",
		first_mes = "Hello!",
		mes_example = "",
		system_prompt = "You are Alice",
		post_history_instructions = "Stay in character",
		creator_notes = "",
		character_version = "1.0",
		alternate_greetings = {},
		tags = {},
		extensions = {},
	}
	if overrides then
		for k, v in pairs(overrides) do card[k] = v end
	end
	return card
end

local function make_history(messages)
	local h = {}
	for _, m in ipairs(messages) do
		h[#h + 1] = { role = m[1], content = m[2] }
	end
	return h
end

-- ── parse_examples ──────────────────────────────────────────────────────────

T.describe("context: parse_examples", function()
	T.it("parses empty string", function()
		local blocks = context._parse_examples("")
		T.eq(#blocks, 0)
	end)

	T.it("parses single example block", function()
		local input = "{{user}}: Hi there\n{{char}}: Hello!"
		local blocks = context._parse_examples(input)
		T.eq(#blocks, 1)
		T.eq(#blocks[1], 2)
		T.eq(blocks[1][1].role, "user")
		T.eq(blocks[1][1].content, "Hi there")
		T.eq(blocks[1][2].role, "assistant")
		T.eq(blocks[1][2].content, "Hello!")
	end)

	T.it("parses multiple blocks separated by <START>", function()
		local input = "{{user}}: First\n{{char}}: Reply1<START>{{user}}: Second\n{{char}}: Reply2"
		local blocks = context._parse_examples(input)
		T.eq(#blocks, 2)
		T.eq(blocks[1][1].content, "First")
		T.eq(blocks[2][1].content, "Second")
	end)

	T.it("handles multiline content", function()
		local input = "{{char}}: Line one\nLine two\nLine three"
		local blocks = context._parse_examples(input)
		T.eq(#blocks, 1)
		T.eq(blocks[1][1].role, "assistant")
		T.eq(blocks[1][1].content, "Line one\nLine two\nLine three")
	end)
end)

-- ── basic assembly ──────────────────────────────────────────────────────────

T.describe("context: basic assembly", function()
	T.it("requires card", function()
		local msgs, err = context.assemble({
			count_tokens = count_tokens,
			max_context = 1000,
			max_response = 100,
		})
		T.fail(msgs)
		T.ok(err:find("card"))
	end)

	T.it("requires count_tokens", function()
		local msgs, err = context.assemble({
			card = make_card(),
			max_context = 1000,
			max_response = 100,
		})
		T.fail(msgs)
		T.ok(err:find("count_tokens"))
	end)

	T.it("assembles minimal card with no history", function()
		local msgs = assert(context.assemble({
			card = make_card(),
			count_tokens = count_tokens,
			max_context = 10000,
			max_response = 100,
			char_name = "Alice",
			user_name = "Bob",
		}))
		T.ok(#msgs > 0)
		-- First message should be system prompt
		T.eq(msgs[1].role, "system")
		T.eq(msgs[1].content, "You are Alice")
		-- Last should be post_history
		T.eq(msgs[#msgs].role, "system")
		T.eq(msgs[#msgs].content, "Stay in character")
	end)

	T.it("includes all fixed blocks in default order", function()
		local msgs = assert(context.assemble({
			card = make_card(),
			count_tokens = count_tokens,
			max_context = 10000,
			max_response = 100,
		}))
		-- Default order: system_prompt, (lorebook_before), (persona), description,
		-- personality, scenario, (lorebook_after), (examples), (history), post_history
		local contents = {}
		for _, m in ipairs(msgs) do contents[#contents + 1] = m.content end
		-- Check order: system_prompt first, post_history last
		T.eq(contents[1], "You are Alice")
		T.eq(contents[#contents], "Stay in character")
		-- description, personality, scenario should be in between
		local found_desc, found_pers, found_scen = false, false, false
		for _, c in ipairs(contents) do
			if c == "A helpful assistant" then found_desc = true end
			if c == "Friendly and cheerful" then found_pers = true end
			if c == "A chat room" then found_scen = true end
		end
		T.ok(found_desc)
		T.ok(found_pers)
		T.ok(found_scen)
	end)

	T.it("includes history messages", function()
		local history = make_history({
			{ "user", "Hello" },
			{ "assistant", "Hi there" },
		})
		local msgs = assert(context.assemble({
			card = make_card(),
			history = history,
			count_tokens = count_tokens,
			max_context = 10000,
			max_response = 100,
		}))
		-- History should appear before post_history
		local found_hello = false
		for i, m in ipairs(msgs) do
			if m.content == "Hello" then
				found_hello = true
				T.eq(m.role, "user")
				T.eq(msgs[i + 1].content, "Hi there")
				T.eq(msgs[i + 1].role, "assistant")
			end
		end
		T.ok(found_hello)
	end)
end)

-- ── macro expansion ─────────────────────────────────────────────────────────

T.describe("context: macro expansion", function()
	T.it("expands {{char}} and {{user}} in card fields", function()
		local card = make_card({
			description = "{{char}} is a robot",
			system_prompt = "You are {{char}}, talking to {{user}}",
		})
		local msgs = assert(context.assemble({
			card = card,
			count_tokens = count_tokens,
			max_context = 10000,
			max_response = 100,
			char_name = "Alice",
			user_name = "Bob",
		}))
		T.eq(msgs[1].content, "You are Alice, talking to Bob")
		-- Find description
		local found = false
		for _, m in ipairs(msgs) do
			if m.content == "Alice is a robot" then found = true end
		end
		T.ok(found)
	end)

	T.it("expands macros in history messages", function()
		local history = make_history({
			{ "user", "Hi {{char}}" },
		})
		local msgs = assert(context.assemble({
			card = make_card(),
			history = history,
			count_tokens = count_tokens,
			max_context = 10000,
			max_response = 100,
			char_name = "Alice",
		}))
		local found = false
		for _, m in ipairs(msgs) do
			if m.content == "Hi Alice" then found = true end
		end
		T.ok(found)
	end)
end)

-- ── dialogue examples ───────────────────────────────────────────────────────

T.describe("context: dialogue examples", function()
	T.it("includes parsed examples", function()
		local card = make_card({
			mes_example = "{{user}}: How are you?\n{{char}}: I'm great!",
		})
		local msgs = assert(context.assemble({
			card = card,
			count_tokens = count_tokens,
			max_context = 10000,
			max_response = 100,
		}))
		local found_user, found_char = false, false
		for _, m in ipairs(msgs) do
			if m.content:find("How are you") then found_user = true end
			if m.content:find("I'm great") then found_char = true end
		end
		T.ok(found_user)
		T.ok(found_char)
	end)

	T.it("drops examples when over budget", function()
		local card = make_card({
			mes_example = "{{user}}: " .. ("word "):rep(50) .. "\n{{char}}: " .. ("word "):rep(50),
		})
		local msgs = assert(context.assemble({
			card = card,
			count_tokens = count_tokens,
			max_context = 50, -- very tight budget
			max_response = 10,
		}))
		-- Examples should be dropped (they'd exceed the remaining budget)
		local found_example = false
		for _, m in ipairs(msgs) do
			if m.content:find("word word word") then found_example = true end
		end
		T.fail(found_example)
	end)
end)

-- ── history trimming ────────────────────────────────────────────────────────

T.describe("context: history trimming", function()
	T.it("trims oldest messages first", function()
		-- Build history with 20 messages
		local history = {}
		for i = 1, 20 do
			history[#history + 1] = {
				role = i % 2 == 1 and "user" or "assistant",
				content = "message" .. i,
			}
		end
		local msgs = assert(context.assemble({
			card = make_card({ system_prompt = "", description = "", personality = "",
				scenario = "", post_history_instructions = "" }),
			history = history,
			count_tokens = count_tokens,
			max_context = 12, -- very tight: only ~12 tokens for history
			max_response = 0,
		}))
		-- Should have kept most recent messages, dropped oldest
		T.ok(#msgs > 0)
		T.ok(#msgs < 20)
		-- Last message should be the most recent
		T.eq(msgs[#msgs].content, "message20")
	end)

	T.it("preserves message order after trimming", function()
		local history = make_history({
			{ "user", "old1" },
			{ "assistant", "old2" },
			{ "user", "new1" },
			{ "assistant", "new2" },
		})
		local msgs = assert(context.assemble({
			card = make_card({ system_prompt = "", description = "", personality = "",
				scenario = "", post_history_instructions = "" }),
			history = history,
			count_tokens = count_tokens,
			max_context = 3, -- only room for ~3 tokens
			max_response = 0,
		}))
		-- Should keep most recent messages in order
		if #msgs >= 2 then
			-- Verify chronological order (new1 before new2)
			local idx1, idx2
			for i, m in ipairs(msgs) do
				if m.content == "new1" then idx1 = i end
				if m.content == "new2" then idx2 = i end
			end
			if idx1 and idx2 then
				T.ok(idx1 < idx2)
			end
		end
		T.ok(#msgs > 0)
	end)
end)

-- ── lorebook integration ────────────────────────────────────────────────────

T.describe("context: lorebook", function()
	T.it("includes triggered lorebook entries", function()
		local entries = {
			lorebook.normalize({
				key = { "dragon" },
				content = "Dragons are powerful creatures",
				position = 0, -- before
				order = 10,
			}),
			lorebook.normalize({
				key = { "unicorn" },
				content = "Unicorns are magical",
				position = 1, -- after
				order = 5,
			}),
		}
		local history = make_history({
			{ "user", "Tell me about the dragon" },
		})
		local msgs = assert(context.assemble({
			card = make_card(),
			history = history,
			lorebook_entries = entries,
			count_tokens = count_tokens,
			max_context = 10000,
			max_response = 100,
		}))
		-- Dragon entry should be present (triggered), unicorn should not
		local found_dragon, found_unicorn = false, false
		for _, m in ipairs(msgs) do
			if m.content:find("Dragons are powerful") then found_dragon = true end
			if m.content:find("Unicorns are magical") then found_unicorn = true end
		end
		T.ok(found_dragon)
		T.fail(found_unicorn)
	end)

	T.it("includes constant entries without keyword match", function()
		local entries = {
			lorebook.normalize({
				key = { "nonexistent_keyword_xyz" },
				content = "Always included lore",
				position = 0,
				constant = true,
			}),
		}
		local history = make_history({
			{ "user", "Hello there" },
		})
		local msgs = assert(context.assemble({
			card = make_card(),
			history = history,
			lorebook_entries = entries,
			count_tokens = count_tokens,
			max_context = 10000,
			max_response = 100,
		}))
		local found = false
		for _, m in ipairs(msgs) do
			if m.content:find("Always included") then found = true end
		end
		T.ok(found)
	end)

	T.it("respects lorebook budget", function()
		local entries = {}
		for i = 1, 10 do
			entries[#entries + 1] = lorebook.normalize({
				key = { "trigger" },
				content = ("word "):rep(20), -- 20 tokens each
				position = 0,
				order = i,
			})
		end
		local history = make_history({
			{ "user", "trigger word here" },
		})
		local msgs = assert(context.assemble({
			card = make_card({ system_prompt = "", description = "", personality = "",
				scenario = "", post_history_instructions = "" }),
			history = history,
			lorebook_entries = entries,
			count_tokens = count_tokens,
			max_context = 400,
			max_response = 0,
			lorebook_budget_pct = 25, -- 100 tokens budget
		}))
		-- With 100 token budget and 20 tokens each, should fit 5 entries
		local lore_count = 0
		for _, m in ipairs(msgs) do
			if m.content:find("word word word") then lore_count = lore_count + 1 end
		end
		T.eq(lore_count, 5)
	end)

	T.it("ignoreBudget entries always included", function()
		local entries = {
			lorebook.normalize({
				key = { "trigger" },
				content = ("word "):rep(200), -- huge entry
				position = 0,
				ignoreBudget = true,
			}),
		}
		local history = make_history({
			{ "user", "trigger word" },
		})
		local msgs = assert(context.assemble({
			card = make_card({ system_prompt = "", description = "", personality = "",
				scenario = "", post_history_instructions = "" }),
			history = history,
			lorebook_entries = entries,
			count_tokens = count_tokens,
			max_context = 100,
			max_response = 0,
			lorebook_budget_pct = 1, -- tiny budget
		}))
		local found = false
		for _, m in ipairs(msgs) do
			if m.content:find("word word word") then found = true end
		end
		T.ok(found)
	end)
end)

-- ── custom block order ──────────────────────────────────────────────────────

T.describe("context: custom order", function()
	T.it("respects custom block ordering", function()
		local msgs = assert(context.assemble({
			card = make_card(),
			count_tokens = count_tokens,
			max_context = 10000,
			max_response = 100,
			-- Put post_history before description
			context_order = { "post_history", "description", "system_prompt" },
		}))
		-- Should have post_history first, then description, then system_prompt
		T.eq(msgs[1].content, "Stay in character")
		T.eq(msgs[2].content, "A helpful assistant")
		T.eq(msgs[3].content, "You are Alice")
	end)
end)

-- ── depth-based lorebook ────────────────────────────────────────────────────

T.describe("context: depth-based lorebook", function()
	T.it("injects at specified depth in history", function()
		local entries = {
			lorebook.normalize({
				key = { "trigger" },
				content = "Injected at depth",
				position = 4, -- AT_DEPTH
				depth = 1,    -- before the last message
			}),
		}
		local history = make_history({
			{ "user", "first" },
			{ "assistant", "second" },
			{ "user", "trigger third" },
		})
		local msgs = assert(context.assemble({
			card = make_card({ system_prompt = "", description = "", personality = "",
				scenario = "", post_history_instructions = "" }),
			history = history,
			lorebook_entries = entries,
			count_tokens = count_tokens,
			max_context = 10000,
			max_response = 100,
		}))
		-- Find the injection point
		local inject_idx
		for i, m in ipairs(msgs) do
			if m.content == "Injected at depth" then inject_idx = i end
		end
		T.ok(inject_idx)
		-- Should be before "trigger third" (depth=1 means 1 from the end)
		local last_idx
		for i, m in ipairs(msgs) do
			if m.content == "trigger third" then last_idx = i end
		end
		T.ok(last_idx)
		T.ok(inject_idx < last_idx)
	end)
end)

-- ── persona ─────────────────────────────────────────────────────────────────

T.describe("context: persona", function()
	T.it("includes persona when provided", function()
		local msgs = assert(context.assemble({
			card = make_card(),
			count_tokens = count_tokens,
			max_context = 10000,
			max_response = 100,
			persona = "I am a brave warrior",
		}))
		local found = false
		for _, m in ipairs(msgs) do
			if m.content == "I am a brave warrior" then found = true end
		end
		T.ok(found)
	end)

	T.it("omits persona when empty", function()
		local msgs = assert(context.assemble({
			card = make_card(),
			count_tokens = count_tokens,
			max_context = 10000,
			max_response = 100,
		}))
		-- No persona message should exist beyond the card fields
		for _, m in ipairs(msgs) do
			T.ok(m.content ~= "")
		end
	end)
end)

-- ── empty card fields ───────────────────────────────────────────────────────

T.describe("context: empty fields", function()
	T.it("skips empty card fields", function()
		local card = make_card({
			system_prompt = "",
			description = "",
			personality = "",
			scenario = "",
			post_history_instructions = "",
		})
		local msgs = assert(context.assemble({
			card = card,
			count_tokens = count_tokens,
			max_context = 10000,
			max_response = 100,
		}))
		T.eq(#msgs, 0)
	end)
end)
