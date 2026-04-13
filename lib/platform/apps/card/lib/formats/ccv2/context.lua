-- lib/formats/ccv2/context.lua
-- Context assembly engine for CCv2 cards. Builds the messages array for LLM
-- calls from card fields, lorebook, conversation history, and token budget.
--
-- Follows SillyTavern's context ordering and trimming strategy.
--
-- API:
--   context.assemble(opts) -> messages[] | nil, err
--
-- opts:
--   card          — normalized CCv2 card data (from ccv2.card)
--   history       — {role, content}[] from conversation tree (oldest first)
--   count_tokens  — (string) -> integer
--   max_context   — total context window in tokens
--   max_response  — tokens reserved for response
--   char_name     — character name (for macros)
--   user_name     — user name (for macros)
--   persona       — user persona text (optional)
--   lorebook_entries  — normalized ST-format entries (optional, overrides card.character_book)
--   lorebook_budget_pct — lorebook budget as % of max_context (default 25)
--   lorebook_scan_depth — how many recent messages to scan (default 10)
--   pin_examples  — if true, never drop dialogue examples (default false)
--   context_order — optional string[] of block names to reorder

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local macro = require("lib.formats.ccv2.macro")
local lorebook = require("lib.formats.ccv2.lorebook")

local M = {}
M._tier = "pure"

-- ── mes_example parsing ───────────────────────────────────────────────────────

-- Parse mes_example into blocks. Each block is a sequence of messages
-- separated by <START>. Returns {{role, content}, ...}[]
local function parse_examples(mes_example)
	if not mes_example or mes_example == "" then return {} end
	local blocks = {}
	-- Split on <START>
	for block in (mes_example .. "<START>"):gmatch("(.-)<START>") do
		block = block:match("^%s*(.-)%s*$") -- trim
		if block ~= "" then
			-- Parse individual messages within the block.
			-- Format: {{char}}: text or {{user}}: text
			local messages = {}
			-- Split on lines that start with {{char}}: or {{user}}:
			-- We'll process line by line and accumulate.
			local current_role, current_lines
			for line in (block .. "\n"):gmatch("(.-)\n") do
				-- Check for role prefix (case-insensitive)
				local role_tag, rest = line:match("^{{(%w+)}}:%s*(.*)")
				if role_tag then
					local tag_lower = role_tag:lower()
					if tag_lower == "char" or tag_lower == "user" then
						-- Flush previous
						if current_role then
							messages[#messages + 1] = {
								role = current_role,
								content = table.concat(current_lines, "\n"),
							}
						end
						current_role = tag_lower == "char" and "assistant" or "user"
						current_lines = { rest }
					else
						-- Unknown tag, treat as content
						if current_lines then
							current_lines[#current_lines + 1] = line
						end
					end
				else
					if current_lines then
						current_lines[#current_lines + 1] = line
					end
				end
			end
			-- Flush last
			if current_role then
				messages[#messages + 1] = {
					role = current_role,
					content = table.concat(current_lines, "\n"),
				}
			end
			if #messages > 0 then
				blocks[#blocks + 1] = messages
			end
		end
	end
	return blocks
end

-- ── macro environment builder ─────────────────────────────────────────────────

local function make_macro_env(opts, history)
	local card = opts.card
	local env = {
		char = opts.char_name or card.name or "",
		user = opts.user_name or "User",
		description = card.description or "",
		personality = card.personality or "",
		scenario = card.scenario or "",
		persona = opts.persona or "",
		charPrompt = card.system_prompt or "",
		charInstruction = card.post_history_instructions or "",
		charCreatorNotes = card.creator_notes or "",
		charVersion = card.character_version or "",
		mesExamples = card.mes_example or "",
		charFirstMessage = card.first_mes or "",
		maxPrompt = tostring(opts.max_context or 0),
		maxContextTokens = tostring(opts.max_context or 0),
		maxResponseTokens = tostring(opts.max_response or 0),
	}
	-- Chat history macros
	if history and #history > 0 then
		env.lastMessage = history[#history].content
		-- Find last user/char messages
		for i = #history, 1, -1 do
			if not env.lastUserMessage and history[i].role == "user" then
				env.lastUserMessage = history[i].content
			end
			if not env.lastCharMessage and history[i].role == "assistant" then
				env.lastCharMessage = history[i].content
			end
			if env.lastUserMessage and env.lastCharMessage then break end
		end
	end
	return env
end

-- ── block assembly ────────────────────────────────────────────────────────────

-- Default block order matching ST.
local DEFAULT_ORDER = {
	"system_prompt",
	"lorebook_before",
	"persona",
	"description",
	"personality",
	"scenario",
	"lorebook_after",
	"examples",
	"history",
	"post_history",
}

-- Blocks that are never trimmed.
local FIXED_BLOCKS = {
	system_prompt = true,
	persona = true,
	description = true,
	personality = true,
	scenario = true,
	post_history = true,
}

-- assemble(opts) -> messages[] | nil, err
function M.assemble(opts)
	if not opts.card then return nil, "context: card is required" end
	if not opts.count_tokens then return nil, "context: count_tokens is required" end
	if not opts.max_context then return nil, "context: max_context is required" end
	if not opts.max_response then return nil, "context: max_response is required" end

	local card = opts.card
	local history = opts.history or {}
	local count_tokens = opts.count_tokens
	local budget = opts.max_context - opts.max_response
	local lorebook_budget_pct = opts.lorebook_budget_pct or 25
	local lorebook_scan_depth = opts.lorebook_scan_depth or 10
	local pin_examples = opts.pin_examples or false
	local order = opts.context_order or DEFAULT_ORDER

	local macro_env = make_macro_env(opts, history)
	local function expand(text)
		if not text or text == "" then return "" end
		return macro.substitute(text, macro_env)
	end

	-- ── Lorebook scanning ─────────────────────────────────────────────────────

	local entries = opts.lorebook_entries
	if not entries and card.character_book then
		entries = lorebook.from_ccv2(card.character_book)
	end

	local triggered_before = {}
	local triggered_after = {}
	local triggered_depth = {}

	if entries and #entries > 0 then
		-- Build scan text from recent history
		local scan_parts = {}
		local scan_start = math.max(1, #history - lorebook_scan_depth + 1)
		for i = scan_start, #history do
			scan_parts[#scan_parts + 1] = history[i].content
		end
		local scan_text = table.concat(scan_parts, "\n")

		-- Also add constant entries (always triggered)
		local triggered_indices = lorebook.scan(entries, scan_text)

		-- Collect constant entries
		local triggered_set = {}
		for _, idx in ipairs(triggered_indices) do
			triggered_set[idx] = true
		end
		for i, entry in ipairs(entries) do
			if entry.constant and entry.enabled then
				triggered_set[i] = true
			end
		end

		-- Sort all triggered by order descending
		local all_triggered = {}
		for idx in pairs(triggered_set) do
			all_triggered[#all_triggered + 1] = idx
		end
		table.sort(all_triggered, function(a, b)
			return (entries[a].order or 0) > (entries[b].order or 0)
		end)

		-- Partition by position
		for _, idx in ipairs(all_triggered) do
			local entry = entries[idx]
			local pos = entry.position or 0
			if pos == lorebook.POS_BEFORE then
				triggered_before[#triggered_before + 1] = entry
			elseif pos == lorebook.POS_AFTER then
				triggered_after[#triggered_after + 1] = entry
			elseif pos == lorebook.POS_AT_DEPTH then
				triggered_depth[#triggered_depth + 1] = entry
			end
			-- POS_AN_TOP, POS_AN_BOTTOM, POS_EM_TOP, POS_EM_BOTTOM handled as
			-- before/after for simplicity (ST also treats them similarly in
			-- most configurations).
		end
	end

	-- ── Build block contents ──────────────────────────────────────────────────

	local function lorebook_to_messages(triggered_list)
		local msgs = {}
		for _, entry in ipairs(triggered_list) do
			local role_map = { [0] = "system", [1] = "user", [2] = "assistant" }
			local role = role_map[entry.role] or "system"
			local content = expand(entry.content)
			if content ~= "" then
				msgs[#msgs + 1] = { role = role, content = content }
			end
		end
		return msgs
	end

	-- Parse dialogue examples
	local example_blocks = parse_examples(card.mes_example)

	-- Build expanded example messages
	local example_messages = {}
	for _, block in ipairs(example_blocks) do
		local block_msgs = {}
		for _, msg in ipairs(block) do
			block_msgs[#block_msgs + 1] = {
				role = msg.role,
				content = expand(msg.content),
			}
		end
		example_messages[#example_messages + 1] = block_msgs
	end

	-- Expand history messages
	local expanded_history = {}
	for _, msg in ipairs(history) do
		expanded_history[#expanded_history + 1] = {
			role = msg.role,
			content = expand(msg.content),
		}
	end

	-- Block generators: each returns {role, content}[]
	local block_gen = {
		system_prompt = function()
			local text = expand(card.system_prompt or "")
			if text == "" then return {} end
			return { { role = "system", content = text } }
		end,
		lorebook_before = function()
			return lorebook_to_messages(triggered_before)
		end,
		persona = function()
			local text = expand(opts.persona or "")
			if text == "" then return {} end
			return { { role = "system", content = text } }
		end,
		description = function()
			local text = expand(card.description or "")
			if text == "" then return {} end
			return { { role = "system", content = text } }
		end,
		personality = function()
			local text = expand(card.personality or "")
			if text == "" then return {} end
			return { { role = "system", content = text } }
		end,
		scenario = function()
			local text = expand(card.scenario or "")
			if text == "" then return {} end
			return { { role = "system", content = text } }
		end,
		lorebook_after = function()
			return lorebook_to_messages(triggered_after)
		end,
		examples = function()
			-- Flatten all example blocks into messages
			local msgs = {}
			for _, block in ipairs(example_messages) do
				for _, msg in ipairs(block) do
					msgs[#msgs + 1] = msg
				end
			end
			return msgs
		end,
		history = function()
			return expanded_history
		end,
		post_history = function()
			local text = expand(card.post_history_instructions or "")
			if text == "" then return {} end
			return { { role = "system", content = text } }
		end,
	}

	-- ── Token counting and trimming ───────────────────────────────────────────

	local function count_messages(msgs)
		local total = 0
		for _, msg in ipairs(msgs) do
			total = total + count_tokens(msg.content)
		end
		return total
	end

	-- Phase 1: count fixed blocks (always included).
	local fixed_tokens = 0
	for _, name in ipairs(order) do
		if FIXED_BLOCKS[name] and block_gen[name] then
			local msgs = block_gen[name]()
			fixed_tokens = fixed_tokens + count_messages(msgs)
		end
	end

	-- Phase 2: lorebook budget.
	local lorebook_max = math.floor(opts.max_context * lorebook_budget_pct / 100)
	local lorebook_used = 0

	-- Trim lorebook entries to budget.
	local function trim_lorebook(triggered_list)
		local kept = {}
		for _, entry in ipairs(triggered_list) do
			local content = expand(entry.content)
			if content ~= "" then
				local tokens = count_tokens(content)
				if entry.ignoreBudget or lorebook_used + tokens <= lorebook_max then
					lorebook_used = lorebook_used + tokens
					kept[#kept + 1] = entry
				end
			end
		end
		return kept
	end

	triggered_before = trim_lorebook(triggered_before)
	triggered_after = trim_lorebook(triggered_after)

	-- Phase 3: remaining budget for examples + history.
	local remaining = budget - fixed_tokens - lorebook_used

	-- Examples: drop as whole blocks if over budget (unless pinned).
	local kept_examples = {}
	if pin_examples then
		kept_examples = example_messages
	else
		local example_tokens = 0
		for _, block in ipairs(example_messages) do
			local block_tokens = count_messages(block)
			if example_tokens + block_tokens <= remaining then
				example_tokens = example_tokens + block_tokens
				kept_examples[#kept_examples + 1] = block
			end
		end
	end
	local example_tokens_used = 0
	for _, block in ipairs(kept_examples) do
		example_tokens_used = example_tokens_used + count_messages(block)
	end

	-- History: trim oldest first.
	local history_budget = remaining - example_tokens_used
	local kept_history = {}
	local history_tokens = 0
	-- Walk from newest to oldest, keep as many as fit.
	for i = #expanded_history, 1, -1 do
		local tokens = count_tokens(expanded_history[i].content)
		if history_tokens + tokens <= history_budget then
			history_tokens = history_tokens + tokens
			kept_history[#kept_history + 1] = expanded_history[i]
		else
			break -- oldest messages dropped
		end
	end
	-- Reverse to restore chronological order.
	local reversed_history = {}
	for i = #kept_history, 1, -1 do
		reversed_history[#reversed_history + 1] = kept_history[i]
	end

	-- Depth-based lorebook entries: inject at specified depth in history.
	-- depth=0 means after the last message, depth=1 means before the last, etc.
	for _, entry in ipairs(triggered_depth) do
		local content = expand(entry.content)
		if content ~= "" then
			local role_map = { [0] = "system", [1] = "user", [2] = "assistant" }
			local role = role_map[entry.role] or "system"
			local depth = entry.depth or 0
			local insert_pos = #reversed_history - depth + 1
			if insert_pos < 1 then insert_pos = 1 end
			table.insert(reversed_history, insert_pos, { role = role, content = content })
		end
	end

	-- ── Assemble final messages ───────────────────────────────────────────────

	-- Override block generators with trimmed versions.
	block_gen.lorebook_before = function()
		return lorebook_to_messages(triggered_before)
	end
	block_gen.lorebook_after = function()
		return lorebook_to_messages(triggered_after)
	end
	block_gen.examples = function()
		local msgs = {}
		for _, block in ipairs(kept_examples) do
			for _, msg in ipairs(block) do
				msgs[#msgs + 1] = msg
			end
		end
		return msgs
	end
	block_gen.history = function()
		return reversed_history
	end

	local messages = {}
	for _, name in ipairs(order) do
		local gen = block_gen[name]
		if gen then
			local msgs = gen()
			for _, msg in ipairs(msgs) do
				messages[#messages + 1] = msg
			end
		end
	end

	return messages
end

-- Expose for testing.
M._parse_examples = parse_examples

return M
