-- lib/formats/ccv2/macro_test.lua
if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local macro = require("lib.formats.ccv2.macro")

-- deterministic mock time
local function mock_time()
	return { year = 2026, month = 4, day = 13, hour = 14, min = 30, sec = 45, wday = 2 }
end

-- deterministic rng that cycles through 0.0, 0.25, 0.5, 0.75
local function make_rng(val)
	return function() return val end
end

T.describe("macro.substitute", function()

	T.describe("core names", function()
		T.it("substitutes {{char}} and {{user}}", function()
			local r = macro.substitute("Hello {{char}}, I am {{user}}", { char = "Alice", user = "Bob" })
			T.eq(r, "Hello Alice, I am Bob")
		end)

		T.it("returns empty string for missing fields", function()
			local r = macro.substitute("Hello {{char}}", {})
			T.eq(r, "Hello ")
		end)
	end)

	T.describe("case insensitivity", function()
		T.it("matches macro names case-insensitively", function()
			T.eq(macro.substitute("{{CHAR}}", { char = "X" }), "X")
			T.eq(macro.substitute("{{Char}}", { char = "X" }), "X")
			T.eq(macro.substitute("{{USER}}", { user = "Y" }), "Y")
			T.eq(macro.substitute("{{ChArPrOmPt}}", { system_prompt = "hi" }), "hi")
		end)
	end)

	T.describe("legacy angle-bracket aliases", function()
		T.it("replaces <USER>", function()
			T.eq(macro.substitute("<USER> says hi", { user = "Bob" }), "Bob says hi")
		end)
		T.it("replaces <BOT>", function()
			T.eq(macro.substitute("<BOT> replies", { char = "Alice" }), "Alice replies")
		end)
		T.it("replaces <CHAR>", function()
			T.eq(macro.substitute("<CHAR> replies", { char = "Alice" }), "Alice replies")
		end)
		T.it("is case-insensitive for legacy aliases", function()
			T.eq(macro.substitute("<user>", { user = "Bob" }), "Bob")
			T.eq(macro.substitute("<bot>", { char = "Alice" }), "Alice")
			T.eq(macro.substitute("<char>", { char = "Alice" }), "Alice")
		end)
	end)

	T.describe("character fields", function()
		T.it("substitutes description, personality, scenario, persona", function()
			local env = { description = "D", personality = "P", scenario = "S", persona = "PE" }
			T.eq(macro.substitute("{{description}}", env), "D")
			T.eq(macro.substitute("{{personality}}", env), "P")
			T.eq(macro.substitute("{{scenario}}", env), "S")
			T.eq(macro.substitute("{{persona}}", env), "PE")
		end)

		T.it("substitutes charPrompt, charInstruction, mesExamples", function()
			local env = {
				system_prompt = "sys",
				post_history_instructions = "post",
				mes_examples = "ex",
				first_mes = "hello",
				creator_notes = "cn",
				char_version = "1.0",
			}
			T.eq(macro.substitute("{{charPrompt}}", env), "sys")
			T.eq(macro.substitute("{{charInstruction}}", env), "post")
			T.eq(macro.substitute("{{mesExamples}}", env), "ex")
			T.eq(macro.substitute("{{mesExamplesRaw}}", env), "ex")
			T.eq(macro.substitute("{{charFirstMessage}}", env), "hello")
			T.eq(macro.substitute("{{charCreatorNotes}}", env), "cn")
			T.eq(macro.substitute("{{charVersion}}", env), "1.0")
		end)
	end)

	T.describe("newline and space", function()
		T.it("inserts single newline by default", function()
			T.eq(macro.substitute("a{{newline}}b", {}), "a\nb")
		end)
		T.it("inserts N newlines", function()
			T.eq(macro.substitute("a{{newline::3}}b", {}), "a\n\n\nb")
		end)
		T.it("inserts single space by default", function()
			T.eq(macro.substitute("a{{space}}b", {}), "a b")
		end)
		T.it("inserts N spaces", function()
			T.eq(macro.substitute("a{{space::4}}b", {}), "a    b")
		end)
	end)

	T.describe("noop and trim", function()
		T.it("noop returns empty", function()
			T.eq(macro.substitute("a{{noop}}b", {}), "ab")
		end)
		T.it("trim returns empty", function()
			T.eq(macro.substitute("a{{trim}}b", {}), "ab")
		end)
	end)

	T.describe("time macros", function()
		T.it("formats time as HH:MM", function()
			T.eq(macro.substitute("{{time}}", { time_fn = mock_time }), "14:30")
		end)
		T.it("formats date as Month Day, Year", function()
			T.eq(macro.substitute("{{date}}", { time_fn = mock_time }), "April 13, 2026")
		end)
		T.it("formats weekday", function()
			T.eq(macro.substitute("{{weekday}}", { time_fn = mock_time }), "Monday")
		end)
		T.it("formats isotime", function()
			T.eq(macro.substitute("{{isotime}}", { time_fn = mock_time }), "14:30:45")
		end)
		T.it("formats isodate", function()
			T.eq(macro.substitute("{{isodate}}", { time_fn = mock_time }), "2026-04-13")
		end)
		T.it("formats idle_duration", function()
			T.eq(macro.substitute("{{idle_duration}}", { idle_duration = 125 }), "2m 5s")
			T.eq(macro.substitute("{{idle_duration}}", { idle_duration = 3661 }), "1h 1m 1s")
			T.eq(macro.substitute("{{idle_duration}}", { idle_duration = 45 }), "45s")
			T.eq(macro.substitute("{{idle_duration}}", {}), "")
		end)
	end)

	T.describe("chat history", function()
		T.it("substitutes lastMessage, lastUserMessage, lastCharMessage", function()
			local env = {
				last_message = "hi",
				last_user_message = "hello",
				last_char_message = "hey",
			}
			T.eq(macro.substitute("{{lastMessage}}", env), "hi")
			T.eq(macro.substitute("{{lastUserMessage}}", env), "hello")
			T.eq(macro.substitute("{{lastCharMessage}}", env), "hey")
		end)
		T.it("substitutes lastMessageId, firstIncludedMessageId", function()
			local env = { last_message_id = 42, first_included_message_id = 7 }
			T.eq(macro.substitute("{{lastMessageId}}", env), "42")
			T.eq(macro.substitute("{{firstIncludedMessageId}}", env), "7")
		end)
		T.it("returns empty for missing history", function()
			T.eq(macro.substitute("{{lastMessage}}", {}), "")
			T.eq(macro.substitute("{{lastMessageId}}", {}), "")
		end)
	end)

	T.describe("local variables", function()
		local vars = {}
		local env = {
			getvar = function(name) return vars[name] end,
			setvar = function(name, value) vars[name] = (value ~= "" and value or nil) end,
		}

		T.it("getvar returns empty when unset", function()
			vars = {}
			T.eq(macro.substitute("{{getvar::foo}}", env), "")
		end)

		T.it("setvar + getvar round-trips", function()
			vars = {}
			macro.substitute("{{setvar::foo::bar}}", env)
			T.eq(macro.substitute("{{getvar::foo}}", env), "bar")
		end)

		T.it("incvar increments and returns new value", function()
			vars = {}
			T.eq(macro.substitute("{{incvar::count}}", env), "1")
			T.eq(macro.substitute("{{incvar::count}}", env), "2")
		end)

		T.it("decvar decrements and returns new value", function()
			vars = { count = "5" }
			T.eq(macro.substitute("{{decvar::count}}", env), "4")
			T.eq(macro.substitute("{{decvar::count}}", env), "3")
		end)

		T.it("addvar adds a numeric value", function()
			vars = { score = "10" }
			macro.substitute("{{addvar::score::5}}", env)
			T.eq(vars.score, "15")
		end)

		T.it("hasvar checks presence", function()
			vars = { x = "yes" }
			T.eq(macro.substitute("{{hasvar::x}}", env), "true")
			T.eq(macro.substitute("{{hasvar::nope}}", env), "false")
		end)

		T.it("deletevar removes variable", function()
			vars = { x = "yes" }
			macro.substitute("{{deletevar::x}}", env)
			T.eq(vars.x, nil)
		end)
	end)

	T.describe("global variables", function()
		local gvars = {}
		local env = {
			getglobalvar = function(name) return gvars[name] end,
			setglobalvar = function(name, value) gvars[name] = (value ~= "" and value or nil) end,
		}

		T.it("getglobalvar returns empty when unset", function()
			gvars = {}
			T.eq(macro.substitute("{{getglobalvar::foo}}", env), "")
		end)

		T.it("setglobalvar + getglobalvar round-trips", function()
			gvars = {}
			macro.substitute("{{setglobalvar::foo::baz}}", env)
			T.eq(macro.substitute("{{getglobalvar::foo}}", env), "baz")
		end)

		T.it("incglobalvar increments", function()
			gvars = {}
			T.eq(macro.substitute("{{incglobalvar::g}}", env), "1")
			T.eq(macro.substitute("{{incglobalvar::g}}", env), "2")
		end)

		T.it("decglobalvar decrements", function()
			gvars = { g = "10" }
			T.eq(macro.substitute("{{decglobalvar::g}}", env), "9")
		end)

		T.it("hasglobalvar checks presence", function()
			gvars = { x = "1" }
			T.eq(macro.substitute("{{hasglobalvar::x}}", env), "true")
			T.eq(macro.substitute("{{hasglobalvar::nope}}", env), "false")
		end)

		T.it("deleteglobalvar removes variable", function()
			gvars = { x = "1" }
			macro.substitute("{{deleteglobalvar::x}}", env)
			T.eq(gvars.x, nil)
		end)
	end)

	T.describe("random", function()
		T.it("picks from options based on rng", function()
			-- rng returns 0.0 -> index 2 (first option after name)
			T.eq(macro.substitute("{{random::a::b::c}}", { rng = make_rng(0.0) }), "a")
			-- rng returns 0.99 -> index 4 (last of 3 options)
			T.eq(macro.substitute("{{random::a::b::c}}", { rng = make_rng(0.99) }), "c")
		end)

		T.it("returns empty with no options", function()
			T.eq(macro.substitute("{{random}}", { rng = make_rng(0.0) }), "")
		end)
	end)

	T.describe("roll", function()
		T.it("rolls 1d6", function()
			-- rng=0.0 -> floor(0.0*6)+1 = 1
			T.eq(macro.substitute("{{roll::1d6}}", { rng = make_rng(0.0) }), "1")
			-- rng=0.99 -> floor(0.99*6)+1 = 6
			T.eq(macro.substitute("{{roll::1d6}}", { rng = make_rng(0.99) }), "6")
		end)

		T.it("rolls 2d10", function()
			-- rng=0.5 -> each die = floor(0.5*10)+1 = 6, total = 12
			T.eq(macro.substitute("{{roll::2d10}}", { rng = make_rng(0.5) }), "12")
		end)

		T.it("returns 0 for invalid dice spec", function()
			T.eq(macro.substitute("{{roll::abc}}", { rng = make_rng(0.5) }), "0")
		end)
	end)

	T.describe("runtime macros", function()
		T.it("substitutes maxPrompt, maxContextTokens, maxResponseTokens, model", function()
			local env = {
				max_prompt = 4096,
				max_context_tokens = 8192,
				max_response_tokens = 2048,
				model = "gpt-4",
			}
			T.eq(macro.substitute("{{maxPrompt}}", env), "4096")
			T.eq(macro.substitute("{{maxContextTokens}}", env), "8192")
			T.eq(macro.substitute("{{maxResponseTokens}}", env), "2048")
			T.eq(macro.substitute("{{model}}", env), "gpt-4")
		end)

		T.it("returns empty for missing runtime fields", function()
			T.eq(macro.substitute("{{maxPrompt}}", {}), "")
			T.eq(macro.substitute("{{model}}", {}), "")
		end)
	end)

	T.describe("unknown macros", function()
		T.it("preserves unknown macros verbatim", function()
			T.eq(macro.substitute("{{unknown_thing}}", {}), "{{unknown_thing}}")
		end)
	end)

	T.describe("no recursion", function()
		T.it("does not recurse into replacement results", function()
			-- char contains a macro — it should NOT be expanded
			local r = macro.substitute("{{char}}", { char = "{{user}}" })
			T.eq(r, "{{user}}")
		end)
	end)

	T.describe("multiple macros in one string", function()
		T.it("substitutes all macros in one pass", function()
			local r = macro.substitute(
				"{{char}} greets {{user}} on {{weekday}}",
				{ char = "Alice", user = "Bob", time_fn = mock_time }
			)
			T.eq(r, "Alice greets Bob on Monday")
		end)
	end)
end)
