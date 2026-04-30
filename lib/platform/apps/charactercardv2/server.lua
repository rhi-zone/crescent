-- lib/platform/apps/charactercardv2/server.lua
-- Card app BFF backend.
--
-- Serves static files + JSON API endpoints for the card conversation UI.
-- All business logic lives here — the frontend is a dumb terminal.
--
-- Messages are stored in a SQLite-backed conversation tree (lib/conversation).
-- Each message has a parent_id. Siblings (same parent) are what were previously
-- called "swipes". Editing forks (creates a new sibling). Regenerating creates
-- a new sibling. The "active path" is the canonical path from root to leaf.
--
-- Capabilities (injected via caps table):
--   caps.llm.call(messages, opts?) -> string | nil, err  (temporary — will be replaced by http_client cap + LLM library)
--   caps.llm.count_tokens(text) -> integer (optional)
--   caps.self.metadata(keyword) -> string | nil
--   caps.self.entry(path) -> string | nil
--   caps.self.entries() -> string[]
--   caps.kv.get(key) / caps.kv.set(key, val) — persistence (optional)
--   caps.time.now() -> integer — Unix timestamp

if package and not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local json = require("lib.format.json")
local card_mod = require("lib.formats.ccv2.card")
local context_mod = require("lib.formats.ccv2.context")
local macro_mod = require("lib.formats.ccv2.macro")
local lorebook_mod = require("lib.formats.ccv2.lorebook")
local presets_mod = require("lib.platform.apps.charactercardv2.presets")
local base64_mod = require("lib.encode.base64")
local png_mod = require("lib.png")

local M = {}

-- ── Conversation DB helpers ──────────────────────────────────────────────────
--
-- When caps.conversations is a shared_db cap, state.conv is that cap and these
-- helpers call raw SQL via db.query(sql, params_array) → rows_array.
--
-- When the fallback path is used (lib.conversation handle), state.conv has a
-- :create_session() etc. API. The helpers detect which type is present via
-- is_lib_conv() and dispatch accordingly.

local function is_lib_conv(db)
	return type(db.create_session) == "function"
end

local CONV_SCHEMA = {
	{ name = "sessions", cols = [[
    id         TEXT PRIMARY KEY,
    app_id     TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    metadata   TEXT
  ]] },
	{ name = "messages", cols = [[
    id                 TEXT PRIMARY KEY,
    session_id         TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    parent_id          TEXT REFERENCES messages(id),
    role               TEXT NOT NULL,
    content            TEXT NOT NULL,
    created_at         INTEGER NOT NULL,
    canonical_child_id TEXT REFERENCES messages(id),
    metadata           TEXT
  ]] },
}

local function conv_uuid()
	return string.format(
		"%08x-%04x-4%03x-%04x-%012x",
		math.random(0, 0xffffffff),
		math.random(0, 0xffff),
		math.random(0, 0xfff),
		math.random(0x8000, 0xbfff),
		math.random(0, 0xffffffffffff)
	)
end

-- conv_query: runs sql with params_array on a shared_db cap (dot-call API).
-- Works for both SELECT (returns rows) and DML (returns {}).
-- Returns rows_array, nil on success; nil, err on failure.
local function conv_query(db, sql, params)
	return db.query(sql, params)
end

local function conv_create_session(db, time_fn)
	if is_lib_conv(db) then return db:create_session("card") end
	local id = conv_uuid()
	local now = time_fn()
	local _, err = conv_query(db,
		"INSERT INTO sessions (id, app_id, created_at) VALUES (?, ?, ?)",
		{ id, "card", now }
	)
	if err then return nil, err end
	return { id = id, app_id = "card", created_at = now }
end

local function conv_get_session(db, id)
	if is_lib_conv(db) then return db:get_session(id) end
	local rows, err = conv_query(db,
		"SELECT id, app_id, created_at, metadata FROM sessions WHERE id = ?",
		{ id }
	)
	if not rows then return nil, err end
	if #rows == 0 then return nil, "conversation: session not found: " .. tostring(id) end
	return rows[1]
end

local function conv_list_sessions(db)
	if is_lib_conv(db) then return db:list_sessions("card") end
	local rows, err = conv_query(db,
		"SELECT id, app_id, created_at, metadata FROM sessions WHERE app_id = 'card' ORDER BY created_at DESC",
		{}
	)
	if not rows then return nil, err end
	return rows
end

local function conv_delete_session(db, id)
	if is_lib_conv(db) then return db:delete_session(id) end
	local _, err = conv_query(db, "DELETE FROM sessions WHERE id = ?", { id })
	if err then return nil, err end
	return true
end

local function conv_add_message(db, session_id, parent_id, role, content, time_fn, metadata)
	if is_lib_conv(db) then return db:add_message(session_id, parent_id, role, content, metadata) end
	local id = conv_uuid()
	local now = time_fn()
	local meta_s = nil
	if metadata ~= nil then
		local json_mod = require("lib.format.json")
		local s, jerr = json_mod.encode(metadata)
		if not s then return nil, "conv_add_message: json encode: " .. tostring(jerr) end
		meta_s = s
	end
	local _, err = conv_query(db,
		"INSERT INTO messages (id, session_id, parent_id, role, content, created_at, canonical_child_id, metadata) VALUES (?, ?, ?, ?, ?, ?, NULL, ?)",
		{ id, session_id, parent_id, role, content, now, meta_s }
	)
	if err then return nil, err end
	if parent_id ~= nil then
		conv_query(db,
			"UPDATE messages SET canonical_child_id = ? WHERE id = ?",
			{ id, parent_id }
		)
	end
	return {
		id = id, session_id = session_id, parent_id = parent_id,
		role = role, content = content, created_at = now,
		canonical_child_id = nil, metadata = metadata,
	}
end

local function conv_decode_metadata(r)
	if r and r.metadata and type(r.metadata) == "string" then
		local json_mod = require("lib.format.json")
		local v = json_mod.decode(r.metadata)
		if v then r.metadata = v end
	end
	return r
end

local function conv_get_message(db, id)
	if is_lib_conv(db) then return db:get_message(id) end
	local rows, err = conv_query(db,
		"SELECT id, session_id, parent_id, role, content, created_at, canonical_child_id, metadata FROM messages WHERE id = ?",
		{ id }
	)
	if not rows then return nil, err end
	if #rows == 0 then return nil, "conversation: message not found: " .. tostring(id) end
	return conv_decode_metadata(rows[1])
end

local function conv_get_children(db, parent_id)
	if is_lib_conv(db) then return db:get_children(parent_id) end
	local rows, err = conv_query(db,
		"SELECT id, session_id, parent_id, role, content, created_at, canonical_child_id, metadata FROM messages WHERE parent_id = ?",
		{ parent_id }
	)
	if not rows then return nil, err end
	for i = 1, #rows do conv_decode_metadata(rows[i]) end
	return rows
end

local function conv_get_roots(db, session_id)
	if is_lib_conv(db) then return db:get_roots(session_id) end
	local rows, err = conv_query(db,
		"SELECT id, session_id, parent_id, role, content, created_at, canonical_child_id, metadata FROM messages WHERE session_id = ? AND parent_id IS NULL ORDER BY created_at ASC",
		{ session_id }
	)
	if not rows then return nil, err end
	for i = 1, #rows do conv_decode_metadata(rows[i]) end
	return rows
end

local function conv_get_canonical_path(db, session_id)
	if is_lib_conv(db) then return db:get_canonical_path(session_id) end
	local rows, err = conv_query(db,
		"SELECT id, session_id, parent_id, role, content, created_at, canonical_child_id, metadata FROM messages WHERE session_id = ? AND parent_id IS NULL",
		{ session_id }
	)
	if not rows then return nil, err end
	if #rows == 0 then return {} end
	local path = {}
	local cur = conv_decode_metadata(rows[1])
	while cur ~= nil do
		path[#path + 1] = cur
		if not cur.canonical_child_id then break end
		local next_rows, nerr = conv_query(db,
			"SELECT id, session_id, parent_id, role, content, created_at, canonical_child_id, metadata FROM messages WHERE id = ?",
			{ cur.canonical_child_id }
		)
		if not next_rows or #next_rows == 0 then
			return nil, "conversation: broken canonical link from " .. tostring(cur.id)
		end
		cur = conv_decode_metadata(next_rows[1])
	end
	return path
end

local function conv_swipe_to(db, message_id)
	if is_lib_conv(db) then return db:swipe_to(message_id) end
	local rows, err = conv_query(db,
		"SELECT parent_id FROM messages WHERE id = ?",
		{ message_id }
	)
	if not rows then return nil, err end
	if #rows == 0 then return nil, "conversation: message not found: " .. tostring(message_id) end
	local parent_id = rows[1].parent_id
	if parent_id == nil then return nil, "conversation: swipe_to: message has no parent (it is a root)" end
	conv_query(db, "UPDATE messages SET canonical_child_id = ? WHERE id = ?", { message_id, parent_id })
	return true
end

local function conv_update_message(db, id, fields)
	if is_lib_conv(db) then return db:update_message(id, fields) end
	local sets = {}
	local params = {}
	if fields.content ~= nil then
		sets[#sets + 1] = "content = ?"
		params[#params + 1] = fields.content
	end
	if fields.metadata ~= nil then
		local json_mod = require("lib.format.json")
		local meta_s, jerr = json_mod.encode(fields.metadata)
		if not meta_s then return nil, "conv_update_message: json encode: " .. tostring(jerr) end
		sets[#sets + 1] = "metadata = ?"
		params[#params + 1] = meta_s
	end
	if fields.canonical_child_id ~= nil then
		sets[#sets + 1] = "canonical_child_id = ?"
		params[#params + 1] = fields.canonical_child_id
	end
	if #sets == 0 then return conv_get_message(db, id) end
	params[#params + 1] = id
	conv_query(db, "UPDATE messages SET " .. table.concat(sets, ", ") .. " WHERE id = ?", params)
	return conv_get_message(db, id)
end

local function conv_delete_subtree(db, message_id)
	if is_lib_conv(db) then return db:delete_subtree(message_id) end
	local rows, err = conv_query(db,
		"SELECT parent_id FROM messages WHERE id = ?",
		{ message_id }
	)
	if not rows then return nil, err end
	if #rows == 0 then return nil, "conversation: message not found: " .. tostring(message_id) end
	local parent_id = rows[1].parent_id
	local id_rows, ierr = conv_query(db,
		"WITH RECURSIVE subtree(id) AS (SELECT id FROM messages WHERE id = ? UNION ALL SELECT m.id FROM messages m JOIN subtree s ON m.parent_id = s.id) SELECT id FROM subtree",
		{ message_id }
	)
	if not id_rows then return nil, ierr end
	local ids = {}
	for _, r in ipairs(id_rows) do ids[#ids + 1] = r.id end
	for _, did in ipairs(ids) do
		conv_query(db, "UPDATE messages SET canonical_child_id = NULL WHERE canonical_child_id = ?", { did })
	end
	for i = #ids, 1, -1 do
		conv_query(db, "DELETE FROM messages WHERE id = ?", { ids[i] })
	end
	if parent_id ~= nil then
		local children, cerr = conv_get_children(db, parent_id)
		if not children then return nil, cerr end
		if #children > 0 then
			conv_query(db, "UPDATE messages SET canonical_child_id = ? WHERE id = ?", { children[1].id, parent_id })
		else
			conv_query(db, "UPDATE messages SET canonical_child_id = NULL WHERE id = ?", { parent_id })
		end
	end
	return { deleted = #ids }
end

-- ── Helpers ─────────────────────────────────────────────────────────────────

local function parse_target(target)
	local qpos = target:find("?", 1, true)
	if not qpos then return target, {} end
	local path = target:sub(1, qpos - 1)
	local qs = target:sub(qpos + 1)
	local params = {}
	for kv in qs:gmatch("[^&]+") do
		local eq = kv:find("=", 1, true)
		if eq then
			params[kv:sub(1, eq - 1)] = kv:sub(eq + 1)
		else
			params[kv] = ""
		end
	end
	return path, params
end

local function json_ok(res, data)
	res.status = 200
	res.headers["Content-Type"] = "application/json"
	res.body = json.encode(data)
	return true
end

local function json_err(res, status, msg)
	res.status = status
	res.headers["Content-Type"] = "application/json"
	res.body = json.encode({ error = msg })
	return true
end

local function read_json_body(req)
	if not req.body or #req.body == 0 then return {} end
	local ok, val = pcall(json.decode, req.body)
	if not ok then return nil end
	return val
end

-- ── State ───────────────────────────────────────────────────────────────────

local DEFAULT_SETTINGS = {
	temperature = 0.7,
	top_p = 1.0,
	max_tokens = 512,
	frequency_penalty = 0.0,
	presence_penalty = 0.0,
	max_context = 4096,
}

local SETTINGS_KEYS = { "temperature", "top_p", "max_tokens", "frequency_penalty", "presence_penalty", "max_context" }

local function create_state()
	return {
		card = nil,           -- CardData
		lorebook = nil,       -- NormalizedEntry[]
		user_name = "User",
		conv = nil,           -- conversation db handle (shared_db cap or lib.conversation handle)
		_time_fn = nil,       -- () -> integer, set in create() before first use
		session_id = nil,     -- active session id
		settings = nil,       -- generation settings (initialized from defaults + kv)
		personas = nil,       -- {name, description}[] (initialized on create)
		active_persona = nil, -- name string or nil
		authors_note = nil,   -- {text, depth, position} (initialized on create)
		regex_scripts = {},   -- {name, find, replace, enabled, scope, order}[]
		instruct_templates = {}, -- instruct template definitions
		instruct_active = nil,   -- name of active template (nil = chat mode)
		user_lorebooks = {},  -- { id, name, entries[], active }[] (user-scope lorebooks, persists across cards)
		_card_state_warned = false, -- whether we've logged the "no self_write" fallback warning
		group = nil,          -- {enabled, members[], turn_order, next_speaker}
	}
end

-- gen_book_id: stable identifier for a user lorebook. Not a UUID; just a
-- time+random composite sufficient for uniqueness within a single user's
-- kv store.
local function gen_book_id(time_fn)
	local now = (time_fn and time_fn()) or 0
	return string.format("book-%d-%d", now, math.random(1, 1000000))
end

-- ── Card-state persistence (PNG via self_write, kv fallback) ───────────────
--
-- Card state (character_book, top-level fields, authors_note extension, regex
-- scripts extension) lives in the card's PNG `chara` iTXt chunk. Writes go
-- through caps.self_write.write_metadata so sharing the PNG shares everything.
-- When self_write is not granted, we fall back to the legacy per-bucket kv
-- keys ("lorebook", "card_overrides", "authors_note", "regex_scripts") so the
-- app still functions without write access to the card file.
--
-- Debouncing: the design spec calls for a 100ms coalesce window. This server
-- has no timer infrastructure, so we take the simpler correct path and flush
-- synchronously on every mutation. This is more PNG rewrites than the spec's
-- ideal (one per burst of edits), but correctness-equivalent. Adding a timer
-- later would replace the inline flush calls with schedule() calls.

local AUTHORS_NOTE_EXT_KEY = "depth_prompt"

-- build_chara_for_write: construct the chara JSON object representing the
-- current card state. Preserves unrelated fields already present on
-- state.card (e.g. creator_notes, alternate_greetings). Bakes the lorebook
-- into character_book (ST <-> CCv2 conversion), the author's note into
-- extensions.depth_prompt/depth_prompt_depth/depth_prompt_role, and the
-- regex scripts into extensions.regex_scripts.
local function build_chara_for_write(state)
	local card = state.card
	if not card then return nil end
	local envelope = { spec = "chara_card_v2", spec_version = "2.0", data = {} }
	local data = envelope.data
	-- Copy all current card fields (name, description, personality, ...).
	for k, v in pairs(card) do data[k] = v end
	-- Bake the in-memory lorebook back into character_book.
	if state.lorebook and #state.lorebook > 0 then
		data.character_book = lorebook_mod.to_ccv2(--[[:! any]] state.lorebook)
	else
		-- Preserve existing character_book if we have no in-memory entries but
		-- the card did have one on disk (edge case: load then clear).
		data.character_book = card.character_book or nil
	end
	local ext = {}
	if type(data.extensions) == "table" then
		for k, v in pairs(data.extensions) do ext[k] = v end
	end
	local an = state.authors_note
	if an and an.text and #an.text > 0 then
		ext[AUTHORS_NOTE_EXT_KEY] = an.text
		ext.depth_prompt_depth = an.depth
		ext.depth_prompt_role = an.position  -- "before"/"after" (ST uses "role" loosely)
	else
		ext[AUTHORS_NOTE_EXT_KEY] = nil
		ext.depth_prompt_depth = nil
		ext.depth_prompt_role = nil
	end
	if state.regex_scripts and #state.regex_scripts > 0 then
		ext.regex_scripts = state.regex_scripts
	else
		ext.regex_scripts = nil
	end
	data.extensions = ext
	return envelope
end

-- write_chara_to_png: serialize + base64 + write via caps.self_write.
-- Returns (true | nil, err).
local function write_chara_to_png(state, caps)
	if not caps.self_write or not caps.self_write.write_metadata then
		return nil, "no self_write capability"
	end
	local envelope = build_chara_for_write(state)
	if not envelope then return nil, "no card loaded" end
	local encoded_json, jerr = json.encode(envelope)
	if not encoded_json then return nil, "json encode: " .. tostring(jerr) end
	local encoded_b64 = base64_mod.encode(encoded_json)
	return caps.self_write.write_metadata("chara", encoded_b64)
end

-- Legacy kv writers (fallback when self_write absent). Declared up-front so
-- flush_card_state can call them; individual save_* functions below also
-- remain available for tests / introspection.
local function kv_save_lorebook(state, caps)
	if not caps.kv then return end
	caps.kv.set("lorebook", json.encode(state.lorebook or {}))
end

local function kv_save_card_overrides(state, caps)
	if not caps.kv or not state.card then return end
	-- Same schema card_edit_response uses; we inline a minimal set to avoid
	-- forward reference to card_edit_response.
	local data = {}
	for k, v in pairs(state.card) do data[k] = v end
	-- character_book is card-state; we store it in lorebook kv instead.
	data.character_book = nil
	caps.kv.set("card_overrides", json.encode(data))
end

local function kv_save_authors_note(state, caps)
	if not caps.kv then return end
	caps.kv.set("authors_note", json.encode(state.authors_note))
end

local function kv_save_regex_scripts(state, caps)
	if not caps.kv then return end
	caps.kv.set("regex_scripts", json.encode(state.regex_scripts))
end

-- flush_card_state: persist all card-state buckets. Uses self_write when
-- available; otherwise falls back to per-bucket kv writes. Logs a single
-- warning per session on first fallback.
local function flush_card_state(state, caps)
	if caps.self_write and state.card then
		local ok, werr = write_chara_to_png(state, caps)
		if ok then return true end
		-- Fall through to kv on error (graceful degradation).
		if not state._card_state_warned then
			state._card_state_warned = true
			print("[ccv2] self_write.write_metadata failed, falling back to kv: " .. tostring(werr))
		end
	elseif not caps.self_write and not state._card_state_warned and state.card then
		-- Warn only when there's an actual card that we can't persist back to.
		-- No card means we're running without a self cap at all (e.g. headless
		-- tests); no warning needed.
		state._card_state_warned = true
		print("[ccv2] self_write cap not granted; card state will be stored in kv (legacy fallback). The card file will not be self-contained.")
	end
	kv_save_lorebook(state, caps)
	kv_save_card_overrides(state, caps)
	kv_save_authors_note(state, caps)
	kv_save_regex_scripts(state, caps)
	return true
end

-- ── User lorebook persistence (always kv) ──────────────────────────────────

local function save_user_lorebooks(state, caps)
	if not caps.kv then return end
	caps.kv.set("user_lorebooks", json.encode(state.user_lorebooks or {}))
end

local function find_user_book(state, id)
	for i, b in ipairs(state.user_lorebooks) do
		if b.id == id then return b, i end
	end
	return nil
end

local function default_settings()
	local s = {}
	for k, v in pairs(DEFAULT_SETTINGS) do s[k] = v end
	return s
end

local function llm_opts_from_settings(settings)
	return {
		temperature = settings.temperature,
		top_p = settings.top_p,
		max_tokens = settings.max_tokens,
		frequency_penalty = settings.frequency_penalty,
		presence_penalty = settings.presence_penalty,
	}
end

-- ── Card loading ────────────────────────────────────────────────────────────

local function load_card(state, caps)
	if not caps.self then return nil, "no self capability" end
	local raw = caps.self.metadata("chara")
	if not raw then return nil, "no chara chunk" end
	local json_str = raw
	if json_str:sub(1, 1) ~= "{" then
		local ok, b64 = pcall(require, "lib.base64")
		if not ok then return nil, "cannot decode base64: no decoder available" end
		local decoded, err = b64.decode(json_str)
		if not decoded then return nil, "base64 decode failed: " .. tostring(err) end
		json_str = decoded
	end
	local card_data, err = card_mod.from_json(json_str)
	if not card_data then return nil, err end
	state.card = card_data
	if card_data.character_book then
		state.lorebook = lorebook_mod.from_ccv2(card_data.character_book)
	end
	-- Pull author's note and regex scripts from extensions when present so
	-- the card is self-contained (they round-trip through flush_card_state).
	local ext = card_data.extensions
	if type(ext) == "table" then
		if ext.depth_prompt and type(ext.depth_prompt) == "string" and #ext.depth_prompt > 0 then
			state.authors_note = state.authors_note or { text = "", depth = 4, position = "after" }
			state.authors_note.text = ext.depth_prompt
			if type(ext.depth_prompt_depth) == "number" then
				state.authors_note.depth = ext.depth_prompt_depth
			end
			if ext.depth_prompt_role == "before" or ext.depth_prompt_role == "after" then
				state.authors_note.position = ext.depth_prompt_role
			end
		end
		if type(ext.regex_scripts) == "table" then
			state.regex_scripts = ext.regex_scripts
		end
		if type(ext.linked_lorebooks) == "table" then
			state.linked_lorebooks = ext.linked_lorebooks
		end
	end
	return card_data
end

-- ── Tree helpers ────────────────────────────────────────────────────────────

-- get_canonical_path: returns the active path for the session.
-- Wraps conv_get_canonical_path().
local function get_canonical_path(state)
	return conv_get_canonical_path(state.conv, state.session_id)
end

-- get_siblings: returns all siblings of a message (children of its parent).
-- For root messages (parent_id is nil), returns all roots in the session.
local function get_siblings(state, msg)
	if msg.parent_id == nil then
		return conv_get_roots(state.conv, state.session_id)
	end
	return conv_get_children(state.conv, msg.parent_id)
end

-- sibling_info: compute sibling_index (0-based) and sibling_count for a message.
local function sibling_info(state, msg)
	local siblings, err = get_siblings(state, msg)
	if not siblings then return 0, 1 end
	local index = 0
	for i, s in ipairs(siblings) do
		if s.id == msg.id then index = i - 1; break end
	end
	return index, #siblings
end

-- msg_response: format a message for the API response.
local function msg_response(state, msg)
	local idx, total = sibling_info(state, msg)
	local resp = {
		id = msg.id,
		role = msg.role,
		content = msg.content,
		parent_id = msg.parent_id,
		sibling_index = idx,
		sibling_count = total,
	}
	local speaker = msg.speaker
	if not speaker and msg.metadata and msg.metadata.speaker then
		speaker = msg.metadata.speaker
	end
	if speaker then resp.speaker = speaker end
	return resp
end

-- ── Persona helpers (forward declarations for context assembly) ────────────

local function find_persona(personas, name)
	for i, p in ipairs(personas) do
		if p.name == name then return p, i end
	end
	return nil
end

local function get_active_persona(state)
	if not state.active_persona then return nil end
	return find_persona(state.personas, state.active_persona)
end

-- ── Context assembly ────────────────────────────────────────────────────────

local function make_macro_env(state)
	local card = state.card
	if not card then return {} end
	return { char = card.name or "", user = state.user_name }
end

local function build_context(state, caps, path)
	local card = state.card
	if not path then
		local err
		path, err = get_canonical_path(state)
		if not path then return nil, err end
	end

	if not card then
		local result = {}
		for i = 1, #path do
			result[#result + 1] = { role = path[i].role, content = path[i].content }
		end
		return result
	end

	local count_tokens
	if caps.llm and caps.llm.count_tokens then
		count_tokens = caps.llm.count_tokens
	else
		count_tokens = function(text) return math.ceil(#text / 4) end
	end

	local max_context = state.settings and state.settings.max_context or 4096
	local max_response = state.settings and state.settings.max_tokens or 512

	local active_p = get_active_persona(state)
	local result, err = context_mod.assemble({
		card = card,
		history = path,
		count_tokens = count_tokens,
		max_context = max_context,
		max_response = max_response,
		char_name = card.name,
		user_name = state.user_name,
		persona = active_p and active_p.description or nil,
		lorebook_entries = (function()
			local all = {}
			if state.lorebook then
				for _, e in ipairs(state.lorebook) do all[#all + 1] = e end
			end
			for _, book in ipairs(state.linked_lorebooks or {}) do
				if type(book.entries) == "table" then
					for _, e in ipairs(book.entries) do all[#all + 1] = e end
				end
			end
			for _, book in ipairs(state.user_lorebooks or {}) do
				if book.active and book.entries then
					for _, e in ipairs(book.entries) do all[#all + 1] = e end
				end
			end
			return #all > 0 and all or nil
		end)(),
	})
	if not result then
		local fallback = {}
		for i = 1, #path do
			fallback[#fallback + 1] = { role = path[i].role, content = path[i].content }
		end
		result = fallback
	end

	-- Insert Author's Note at configured depth.
	local an = state.authors_note
	if an and an.text and #an.text > 0 then
		local depth = an.depth or 4
		local pos = an.position or "after"
		local insert_pos = #result - depth
		if pos == "before" then insert_pos = insert_pos end
		if pos == "after" then insert_pos = insert_pos + 1 end
		if insert_pos < 1 then insert_pos = 1 end
		if insert_pos > #result + 1 then insert_pos = #result + 1 end
		table.insert(result, insert_pos, { role = "system", content = an.text })
	end

	return result
end

-- compute_token_count: build context and count tokens without calling the LLM.
-- Returns a table suitable for JSON response.
local function compute_token_count(state, caps)
	local path, perr = get_canonical_path(state)
	if not path then return nil, perr end

	local context, cerr = build_context(state, caps, path)
	if not context then return nil, cerr end

	local count_tokens
	if caps.llm and caps.llm.count_tokens then
		count_tokens = caps.llm.count_tokens
	else
		count_tokens = function(text) return math.ceil(#text / 4) end
	end

	local total = 0
	for _, msg in ipairs(context) do
		total = total + count_tokens(msg.content)
	end

	local max_context = state.settings and state.settings.max_context or 4096
	local max_tokens = state.settings and state.settings.max_tokens or 512
	local available = math.max(0, max_context - total - max_tokens)

	-- Count triggered lorebook entries.
	local lorebook_count = 0
	if state.lorebook then
		for _, e in ipairs(state.lorebook) do
			if e.enabled then lorebook_count = lorebook_count + 1 end
		end
	end

	return {
		context_used = total,
		context_max = max_context,
		response_budget = max_tokens,
		available = available,
		messages = #path,
		lorebook_entries = lorebook_count,
	}
end

-- build_context_to_parent: build context from root to a given parent message.
-- Used for generating siblings (swipe/new, edit).
local function build_context_to_parent(state, caps, parent_id)
	if parent_id == nil then
		-- Parent is the session root — context is empty (no messages before root).
		return build_context(state, caps, {})
	end
	-- Walk up from parent_id to root, then reverse.
	local chain = {}
	local current_id = parent_id
	while current_id do
		local msg, err = conv_get_message(state.conv, current_id)
		if not msg then return nil, err end
		chain[#chain + 1] = msg
		current_id = msg.parent_id
	end
	-- Reverse: root first.
	local path = {}
	for i = #chain, 1, -1 do
		path[#path + 1] = chain[i]
	end
	return build_context(state, caps, path)
end

-- ── Regex scripts ──────────────────────────────────────────────────────────

local function apply_regex_scripts(state, text, scope)
	local scripts = state.regex_scripts
	if not scripts or #scripts == 0 then return text end
	-- Collect enabled scripts matching scope, sorted by order.
	local sorted = {}
	for _, s in ipairs(scripts) do
		if s.enabled and s.scope == scope then
			sorted[#sorted + 1] = s
		end
	end
	table.sort(sorted, function(a, b) return (a.order or 0) < (b.order or 0) end)
	for _, s in ipairs(sorted) do
		local ok, result = pcall(string.gsub, text, s.find, s.replace)
		if ok then text = result end
	end
	return text
end

local function save_regex_scripts(state, caps)
	flush_card_state(state, caps)
end

-- ── Instruct templates ─────────────────────────────────────────────────────

local DEFAULT_INSTRUCT_TEMPLATES = {
	{
		name = "OpenAI (native)",
		mode = "chat",
		system_prefix = "", system_suffix = "",
		user_prefix = "", user_suffix = "",
		assistant_prefix = "", assistant_suffix = "",
		separator = "",
		stop_strings = {},
	},
	{
		name = "ChatML",
		mode = "instruct",
		system_prefix = "<|im_start|>system\n",
		system_suffix = "<|im_end|>\n",
		user_prefix = "<|im_start|>user\n",
		user_suffix = "<|im_end|>\n",
		assistant_prefix = "<|im_start|>assistant\n",
		assistant_suffix = "<|im_end|>\n",
		separator = "",
		stop_strings = { "<|im_end|>" },
	},
	{
		name = "Llama2",
		mode = "instruct",
		system_prefix = "[INST] <<SYS>>\n",
		system_suffix = "\n<</SYS>>\n\n",
		user_prefix = "",
		user_suffix = " [/INST] ",
		assistant_prefix = "",
		assistant_suffix = " </s><s>[INST] ",
		separator = "",
		stop_strings = { "</s>" },
	},
	{
		name = "Alpaca",
		mode = "instruct",
		system_prefix = "### Instruction:\n",
		system_suffix = "\n\n",
		user_prefix = "### Input:\n",
		user_suffix = "\n\n",
		assistant_prefix = "### Response:\n",
		assistant_suffix = "\n\n",
		separator = "",
		stop_strings = { "### Instruction:", "### Input:", "### Response:" },
	},
	{
		name = "Mistral",
		mode = "instruct",
		system_prefix = "[INST] ",
		system_suffix = "\n",
		user_prefix = "[INST] ",
		user_suffix = " [/INST] ",
		assistant_prefix = "",
		assistant_suffix = " </s> ",
		separator = "",
		stop_strings = { "</s>" },
	},
	{
		name = "Vicuna",
		mode = "instruct",
		system_prefix = "",
		system_suffix = "\n\n",
		user_prefix = "USER: ",
		user_suffix = "\n",
		assistant_prefix = "ASSISTANT: ",
		assistant_suffix = "\n",
		separator = "",
		stop_strings = { "USER:", "ASSISTANT:" },
	},
	{
		name = "Plain",
		mode = "instruct",
		system_prefix = "System: ",
		system_suffix = "\n",
		user_prefix = "User: ",
		user_suffix = "\n",
		assistant_prefix = "Assistant: ",
		assistant_suffix = "\n",
		separator = "",
		stop_strings = {},
	},
}

-- format_for_instruct(messages, template) -> messages
-- If template is nil or mode="chat", returns messages unchanged.
-- If mode="instruct", formats into a single user message using template prefixes/suffixes.
local function format_for_instruct(messages, template)
	if not template or template.mode == "chat" then return messages end
	local parts = {}
	local sep = template.separator or ""
	for i, msg in ipairs(messages) do
		local prefix, suffix
		if msg.role == "system" then
			prefix = template.system_prefix or ""
			suffix = template.system_suffix or ""
		elseif msg.role == "user" then
			prefix = template.user_prefix or ""
			suffix = template.user_suffix or ""
		elseif msg.role == "assistant" then
			prefix = template.assistant_prefix or ""
			suffix = template.assistant_suffix or ""
		else
			prefix = ""
			suffix = ""
		end
		if i > 1 and sep ~= "" then parts[#parts + 1] = sep end
		parts[#parts + 1] = prefix
		parts[#parts + 1] = msg.content
		parts[#parts + 1] = suffix
	end
	-- Append the assistant prefix to prompt a response.
	parts[#parts + 1] = template.assistant_prefix or ""
	return { { role = "user", content = table.concat(parts) } }
end

-- Expose for testing.
M._format_for_instruct = format_for_instruct
M._DEFAULT_INSTRUCT_TEMPLATES = DEFAULT_INSTRUCT_TEMPLATES

local function find_instruct_template(templates, name)
	for i, t in ipairs(templates) do
		if t.name == name then return t, i end
	end
	return nil
end

local function save_instruct(state, caps)
	if not caps.kv then return end
	caps.kv.set("instruct_templates", json.encode(state.instruct_templates))
	caps.kv.set("instruct_active", state.instruct_active or "")
end

-- Get the active instruct template (nil if none or chat mode).
local function get_active_instruct(state)
	if not state.instruct_active or state.instruct_active == "" then return nil end
	return find_instruct_template(state.instruct_templates, state.instruct_active)
end

-- Apply instruct template to messages before LLM call.
local function apply_instruct(state, messages)
	local template = get_active_instruct(state)
	return format_for_instruct(messages, template)
end

-- ── Persistence ─────────────────────────────────────────────────────────────

local function save_session_id(state, caps)
	if not caps.kv then return end
	caps.kv.set("card_session_id", state.session_id)
end

local function load_session_id(caps)
	if not caps.kv then return nil end
	return caps.kv.get("card_session_id")
end

-- ── Greeting ────────────────────────────────────────────────────────────────

local function init_greeting(state)
	local card = state.card
	if not card or not card.first_mes or #card.first_mes == 0 then return end

	local env = make_macro_env(state)
	local content = macro_mod.substitute(card.first_mes, env)

	-- Create primary greeting as root message.
	local msg, err = conv_add_message(state.conv, state.session_id, nil, "assistant", content, state._time_fn)
	if not msg then return end

	-- Create alternate greetings as root siblings (also parent_id = nil).
	if card.alternate_greetings then
		for _, g in ipairs(card.alternate_greetings) do
			if g and #g > 0 then
				local alt_content = macro_mod.substitute(g, env)
				conv_add_message(state.conv, state.session_id, nil, "assistant", alt_content, state._time_fn)
			end
		end
	end

	-- Swipe back to the first greeting so canonical path starts from it.
	-- add_message updates nothing for roots (no parent), but the last root added
	-- will be picked by get_canonical_path (first in query order).
	-- We need to ensure the first greeting is the one on the canonical path.
	-- get_canonical_path picks the first root by created_at (or insertion order).
	-- Since all roots share the same created_at (os.time() granularity is 1s),
	-- we rely on SQLite rowid ordering which matches insertion order.
	-- The first root inserted is the primary greeting — this is correct.
end

-- ── Session helpers ─────────────────────────────────────────────────────────

local function get_session_preview(state, session_id)
	local path = conv_get_canonical_path(state.conv, session_id)
	if not path or #path == 0 then return "" end
	for _, msg in ipairs(path) do
		if msg.role == "user" then
			local text = msg.content
			if #text > 80 then text = text:sub(1, 77) .. "..." end
			return text
		end
	end
	local text = path[1].content
	if #text > 80 then text = text:sub(1, 77) .. "..." end
	return text
end

local function format_messages(state, path)
	local result = {}
	for _, msg in ipairs(path) do
		result[#result + 1] = msg_response(state, msg)
	end
	return result
end

local function switch_to_session(state, caps, session_id)
	state.session_id = session_id
	save_session_id(state, caps)
end

local function create_new_session(state, caps)
	local session, serr = conv_create_session(state.conv, state._time_fn)
	if not session then return nil, nil, serr end
	state.session_id = session.id
	init_greeting(state)
	switch_to_session(state, caps, session.id)
	local path = get_canonical_path(state)
	local messages = format_messages(state, path or {})
	return session, messages
end

-- ── Group chat helpers ────────────────────────────────────────────────────

local function init_group(state)
	local primary_name = state.card and state.card.name or "Character"
	state.group = {
		enabled = false,
		members = { { card = state.card, name = primary_name, is_primary = true } },
		turn_order = "round_robin",
		next_speaker = 1,
	}
end

local function save_group(state, caps)
	if not caps.kv then return end
	local serializable = {
		enabled = state.group.enabled,
		turn_order = state.group.turn_order,
		next_speaker = state.group.next_speaker,
		members = {},
	}
	for i, m in ipairs(state.group.members) do
		if m.is_primary then
			serializable.members[i] = { name = m.name, is_primary = true }
		else
			serializable.members[i] = {
				name = m.name,
				card_json = card_mod.to_json(m.card),
			}
		end
	end
	caps.kv.set("group", json.encode(serializable))
end

local function group_members_response(state)
	local members = {}
	for _, m in ipairs(state.group.members) do
		members[#members + 1] = { name = m.name, is_primary = m.is_primary or false }
	end
	return members
end

local function group_response(state)
	return {
		enabled = state.group.enabled,
		members = group_members_response(state),
		turn_order = state.group.turn_order,
	}
end

-- Build context for a specific group member's turn.
local function build_group_context(state, caps, speaker_member, path)
	local speaker_card = speaker_member.card
	if not speaker_card then return build_context(state, caps, path) end

	local count_tokens
	if caps.llm and caps.llm.count_tokens then
		count_tokens = caps.llm.count_tokens
	else
		count_tokens = function(text) return math.ceil(#text / 4) end
	end

	local max_context = state.settings and state.settings.max_context or 4096
	local max_response = state.settings and state.settings.max_tokens or 512

	-- Label history messages with speaker names for group context.
	local labeled_history = {}
	for _, msg in ipairs(path) do
		local content = msg.content
		if msg.role == "assistant" and msg.speaker then
			content = msg.speaker .. ": " .. content
		elseif msg.role == "user" then
			content = state.user_name .. ": " .. content
		end
		labeled_history[#labeled_history + 1] = { role = msg.role, content = content }
	end

	local active_p = get_active_persona(state)
	local result = context_mod.assemble({
		card = speaker_card,
		history = labeled_history,
		count_tokens = count_tokens,
		max_context = max_context,
		max_response = max_response,
		char_name = speaker_card.name,
		user_name = state.user_name,
		persona = active_p and active_p.description or nil,
		lorebook_entries = state.lorebook,
	})
	if not result then
		return labeled_history
	end

	-- Insert Author's Note at configured depth.
	local an = state.authors_note
	if an and an.text and #an.text > 0 then
		local depth = an.depth or 4
		local pos = an.position or "after"
		local insert_pos = #result - depth
		if pos == "after" then insert_pos = insert_pos + 1 end
		if insert_pos < 1 then insert_pos = 1 end
		if insert_pos > #result + 1 then insert_pos = #result + 1 end
		table.insert(result, insert_pos, { role = "system", content = an.text })
	end

	return result
end

-- Pick the next speaker(s) based on turn order.
local function pick_next_speakers(state)
	local group = state.group
	local members = group.members
	if #members == 0 then return {} end

	if group.turn_order == "round_robin" then
		local idx = group.next_speaker
		if idx < 1 or idx > #members then idx = 1 end
		group.next_speaker = (idx % #members) + 1
		return { members[idx] }
	elseif group.turn_order == "random" then
		local idx = math.random(1, #members)
		return { members[idx] }
	elseif group.turn_order == "all" then
		return members
	end
	-- Default: round_robin behavior.
	local idx = group.next_speaker
	if idx < 1 or idx > #members then idx = 1 end
	group.next_speaker = (idx % #members) + 1
	return { members[idx] }
end

-- ── Group endpoints ──────────────────────────────────────────────────────

local function api_get_group(state, _caps, _params, _body, res)
	return json_ok(res, group_response(state))
end

local function api_post_group_toggle(state, caps, _params, body, res)
	if not body or body.enabled == nil then
		return json_err(res, 400, "enabled field required")
	end
	state.group.enabled = not not body.enabled
	save_group(state, caps)
	return json_ok(res, group_response(state))
end

local function api_post_group_add(state, caps, _params, body, res)
	if not body or not body.card_json then
		return json_err(res, 400, "card_json required")
	end
	local card_data, cerr = card_mod.from_json(body.card_json)
	if not card_data then
		return json_err(res, 400, "invalid card: " .. tostring(cerr))
	end
	local name = card_data.name
	for _, m in ipairs(state.group.members) do
		if m.name == name then
			return json_err(res, 409, "character '" .. name .. "' already in group")
		end
	end
	state.group.members[#state.group.members + 1] = {
		card = card_data,
		name = name,
		is_primary = false,
	}
	save_group(state, caps)
	return json_ok(res, group_response(state))
end

local function api_post_group_remove(state, caps, _params, body, res)
	if not body or not body.name then
		return json_err(res, 400, "name required")
	end
	for i, m in ipairs(state.group.members) do
		if m.name == body.name then
			if m.is_primary then
				return json_err(res, 400, "cannot remove primary character")
			end
			table.remove(state.group.members, i)
			if state.group.next_speaker > #state.group.members then
				state.group.next_speaker = 1
			end
			save_group(state, caps)
			return json_ok(res, group_response(state))
		end
	end
	return json_err(res, 404, "character not found")
end

local function api_post_group_order(state, caps, _params, body, res)
	if not body or not body.turn_order then
		return json_err(res, 400, "turn_order required")
	end
	local order = body.turn_order
	if order ~= "round_robin" and order ~= "random" and order ~= "all" and order ~= "manual" then
		return json_err(res, 400, "invalid turn_order: " .. tostring(order))
	end
	state.group.turn_order = order
	state.group.next_speaker = 1
	save_group(state, caps)
	return json_ok(res, group_response(state))
end


-- ── API endpoints ───────────────────────────────────────────────────────────

local function api_get_card(state, caps, _params, _body, res)
	if not state.card then return json_err(res, 404, "no card loaded") end
	local path = get_canonical_path(state)
	local data = { name = state.card.name }
	if path and #path > 0 and path[1].role == "assistant" then
		data.greeting = msg_response(state, path[1])
	end
	-- writable: true iff self_write is granted AND we have a chara chunk to
	-- write back to. Frontend uses this to gate the "read-only" notice on the
	-- Card Lorebook panel — edits still persist via kv fallback, but they
	-- won't ride with the card PNG.
	data.writable = caps.self_write ~= nil
		and caps.self_write.write_metadata ~= nil
		and state.card ~= nil
	return json_ok(res, data)
end

-- api_get_card_export: stream the card PNG as a file download.
-- Requires caps.self.read (read-only self cap is sufficient).
local function api_get_card_export(state, caps, _params, _body, res)
	if not caps.self or not caps.self.read then
		return json_err(res, 503, "self cap not available")
	end
	local bytes, rerr = caps.self.read()
	if not bytes then
		return json_err(res, 500, "export: " .. tostring(rerr))
	end
	local card_name = (state.card and state.card.name) or "card"
	local safe_name = card_name:gsub('[/\\:*?"<>|]', "_")
	res.status = 200
	res.headers["Content-Type"] = "image/png"
	res.headers["Content-Disposition"] = 'attachment; filename="' .. safe_name .. '.png"'
	res.body = bytes
	return true
end

local function api_get_avatar(_state, caps, _params, _body, res)
	if not caps.self or not caps.self.entry then
		res.status = 404
		res.headers["Content-Type"] = "text/plain"
		res.body = "no avatar"
		return true
	end
	local bytes = caps.self.entry("avatar.png")
	if not bytes then
		res.status = 404
		res.headers["Content-Type"] = "text/plain"
		res.body = "no avatar"
		return true
	end
	res.status = 200
	res.headers["Content-Type"] = "image/png"
	res.headers["Cache-Control"] = "max-age=3600"
	res.body = bytes
	return true
end

local function api_get_messages(state, _caps, _params, _body, res)
	local path, err = get_canonical_path(state)
	if not path then return json_err(res, 500, err) end
	local result = {}
	for _, msg in ipairs(path) do
		result[#result + 1] = msg_response(state, msg)
	end
	return json_ok(res, { messages = result })
end

local function api_post_message(state, caps, _params, body, res)
	if not body or not body.content then return json_err(res, 400, "content required") end
	local text = body.content
	if type(text) ~= "string" or #text == 0 then return json_err(res, 400, "empty content") end

	-- Apply user_input regex scripts.
	text = apply_regex_scripts(state, text, "user_input")

	-- Find current leaf (last node in canonical path).
	local path, perr = get_canonical_path(state)
	if not path then return json_err(res, 500, perr) end
	local leaf_id = path[#path] and path[#path].id or nil

	-- Add user message as child of leaf.
	local user_msg, uerr = conv_add_message(state.conv, state.session_id, leaf_id, "user", text, state._time_fn)
	if not user_msg then return json_err(res, 500, uerr) end

	-- Group mode: generate responses from multiple characters.
	if state.group and state.group.enabled and #state.group.members > 0 then
		local speakers = pick_next_speakers(state)
		local responses = {}
		local parent_id = user_msg.id
		for _, speaker in ipairs(speakers) do
			local path2 = get_canonical_path(state)
			local context = build_group_context(state, caps, speaker, path2)
			local resp, gerr = caps.llm.call(apply_instruct(state, context), llm_opts_from_settings(state.settings))
			if not resp then
				if #responses == 0 then
					conv_delete_subtree(state.conv, user_msg.id)
					return json_err(res, 502, "LLM error: " .. tostring(gerr))
				end
				break
			end
			resp = apply_regex_scripts(state, resp, "ai_output")
			local meta = { speaker = speaker.name }
			local asst_msg, aerr = conv_add_message(state.conv, state.session_id, parent_id, "assistant", resp, state._time_fn, meta)
			if not asst_msg then return json_err(res, 500, aerr) end
			asst_msg.speaker = speaker.name
			parent_id = asst_msg.id
			local r = msg_response(state, asst_msg)
			r.speaker = speaker.name
			responses[#responses + 1] = r
		end
		save_group(state, caps)
		save_session_id(state, caps)
		return json_ok(res, {
			user = { id = user_msg.id, role = "user", content = text },
			assistants = responses,
			token_count = compute_token_count(state, caps),
		})
	end

	-- Build context (canonical path now includes user_msg).
	local context = build_context(state, caps)
	local response, err = caps.llm.call(apply_instruct(state, context), llm_opts_from_settings(state.settings))
	if not response then
		-- Rollback: delete user message.
		conv_delete_subtree(state.conv, user_msg.id)
		return json_err(res, 502, "LLM error: " .. tostring(err))
	end

	-- Apply ai_output regex scripts.
	response = apply_regex_scripts(state, response, "ai_output")

	-- Add assistant message as child of user message.
	local asst_msg, aerr = conv_add_message(state.conv, state.session_id, user_msg.id, "assistant", response, state._time_fn)
	if not asst_msg then return json_err(res, 500, aerr) end

	save_session_id(state, caps)
	return json_ok(res, {
		user = { id = user_msg.id, role = "user", content = text },
		assistant = msg_response(state, asst_msg),
		token_count = compute_token_count(state, caps),
	})
end

-- ── SSE streaming (via res.send_event / res.close from http_server cap) ───

local function api_post_message_stream(state, caps, _params, body, res)
	if not body or not body.content then return json_err(res, 400, "content required") end
	local text = body.content
	if type(text) ~= "string" or #text == 0 then return json_err(res, 400, "empty content") end

	-- Apply user_input regex scripts.
	text = apply_regex_scripts(state, text, "user_input")

	-- Check streaming support.
	if not caps.llm.call_stream then
		-- Fall back to non-streaming (text already transformed, pass it through).
		body = { content = text }
		return api_post_message(state, caps, _params, body, res)
	end

	-- Find current leaf.
	local path, perr = get_canonical_path(state)
	if not path then return json_err(res, 500, perr) end
	local leaf_id = path[#path] and path[#path].id or nil

	-- Add user message.
	local user_msg, uerr = conv_add_message(state.conv, state.session_id, leaf_id, "user", text, state._time_fn)
	if not user_msg then return json_err(res, 500, uerr) end

	-- Build context.
	local context = build_context(state, caps)

	-- Track client connection state. Once a send_event fails (client disconnect
	-- or revocation), further sends are skipped. The LLM stream cannot be
	-- cancelled mid-flight, but we stop forwarding tokens to a dead socket.
	local client_gone = false

	-- Send user message event.
	local ok = res.send_event(json.encode({
		type = "user",
		id = user_msg.id,
		role = "user",
		content = text,
	}))
	if not ok then
		client_gone = true
		res.close()
		return true
	end

	-- Stream LLM response.
	local response, err = caps.llm.call_stream(apply_instruct(state, context), function(token)
		if client_gone then return end
		local sok = res.send_event(json.encode({ type = "token", token = token }))
		if not sok then client_gone = true end
	end, llm_opts_from_settings(state.settings))

	if not response then
		-- Rollback: delete user message.
		conv_delete_subtree(state.conv, user_msg.id)
		if not client_gone then
			-- Best-effort error notify; ignore failure since we're closing anyway.
			res.send_event(json.encode({ type = "error", error = "LLM error: " .. tostring(err) }))
		end
		res.close()
		return true
	end

	-- Apply ai_output regex scripts.
	response = apply_regex_scripts(state, response, "ai_output")

	-- Add assistant message.
	local asst_msg, aerr = conv_add_message(state.conv, state.session_id, user_msg.id, "assistant", response, state._time_fn)
	if not asst_msg then
		if not client_gone then
			-- Best-effort error notify; ignore failure since we're closing anyway.
			res.send_event(json.encode({ type = "error", error = "db error: " .. tostring(aerr) }))
		end
		res.close()
		return true
	end

	save_session_id(state, caps)

	if client_gone then
		res.close()
		return true
	end

	-- Send done event with final message data.
	local idx, total = sibling_info(state, asst_msg)
	-- Best-effort terminal send; failure here just means client disconnected
	-- between tokens and the final event. Conversation state is already saved.
	res.send_event(json.encode({
		type = "done",
		id = asst_msg.id,
		role = "assistant",
		content = response,
		sibling_index = idx,
		sibling_count = total,
	}))

	res.close()
	return true
end

local function api_post_continue(state, caps, _params, _body, res)
	local path, perr = get_canonical_path(state)
	if not path or #path == 0 then return json_err(res, 400, "no messages") end

	local context = build_context(state, caps, path)
	local response, err = caps.llm.call(apply_instruct(state, context), llm_opts_from_settings(state.settings))
	if not response then return json_err(res, 502, "LLM error: " .. tostring(err)) end

	-- Apply ai_output regex scripts.
	response = apply_regex_scripts(state, response, "ai_output")

	local leaf = path[#path]
	if leaf.role == "assistant" then
		-- Append to existing assistant message (in-place update).
		local updated, uerr = conv_update_message(state.conv, leaf.id, {
			content = leaf.content .. response,
		})
		if not updated then return json_err(res, 500, uerr) end
		save_session_id(state, caps)
		local resp = msg_response(state, updated)
		resp.token_count = compute_token_count(state, caps)
		return json_ok(res, resp)
	else
		-- Add new assistant message as child of leaf.
		local asst_msg, aerr = conv_add_message(state.conv, state.session_id, leaf.id, "assistant", response, state._time_fn)
		if not asst_msg then return json_err(res, 500, aerr) end
		save_session_id(state, caps)
		local resp = msg_response(state, asst_msg)
		resp.token_count = compute_token_count(state, caps)
		return json_ok(res, resp)
	end
end

local function api_post_impersonate(state, caps, _params, body, res)
	local context = build_context(state, caps)
	if not context then return json_err(res, 500, "failed to build context") end
	-- Append instruction to generate as the user character.
	local hint = "Continue the conversation as {{user}}, writing their next message in character."
	local env = make_macro_env(state)
	hint = hint:gsub("{{user}}", env.user or "User")
	if body and body.prompt and type(body.prompt) == "string" and #body.prompt > 0 then
		hint = hint .. " " .. body.prompt
	end
	context[#context + 1] = { role = "system", content = hint }

	local response, err = caps.llm.call(apply_instruct(state, context), llm_opts_from_settings(state.settings))
	if not response then return json_err(res, 502, "LLM error: " .. tostring(err)) end

	return json_ok(res, { content = response })
end

local function api_get_swipes(state, _caps, params, _body, res)
	local msg_id = params.message_id
	if not msg_id then return json_err(res, 400, "message_id required") end

	local msg, merr = conv_get_message(state.conv, msg_id)
	if not msg then return json_err(res, 404, "message not found") end

	local siblings, serr = get_siblings(state, msg)
	if not siblings then return json_err(res, 500, serr) end

	local swipes = {}
	local current = 0
	for i, s in ipairs(siblings) do
		swipes[#swipes + 1] = { id = s.id, content = s.content, index = i - 1 }
		if s.id == msg_id then current = i - 1 end
	end
	return json_ok(res, { swipes = swipes, current = current })
end

local function api_post_swipe_new(state, caps, _params, body, res)
	local msg_id = body and body.message_id
	if not msg_id then return json_err(res, 400, "message_id required") end

	local msg, merr = conv_get_message(state.conv, msg_id)
	if not msg then return json_err(res, 404, "message not found") end

	-- Build context up to (but not including) this message.
	local context, cerr = build_context_to_parent(state, caps, msg.parent_id)
	if not context then return json_err(res, 500, cerr) end

	local response, err = caps.llm.call(apply_instruct(state, context), llm_opts_from_settings(state.settings))
	if not response then return json_err(res, 502, "LLM error: " .. tostring(err)) end

	-- Apply ai_output regex scripts.
	response = apply_regex_scripts(state, response, "ai_output")

	-- Add as sibling (same parent, same role).
	local new_msg, nerr = conv_add_message(state.conv, state.session_id, msg.parent_id, msg.role, response, state._time_fn)
	if not new_msg then return json_err(res, 500, nerr) end

	-- For root siblings, add_message doesn't update any parent canonical_child_id.
	-- The canonical path still starts from the first root. We rely on the frontend
	-- calling /api/branch/navigate to switch to the new sibling.
	-- For non-root siblings, add_message already updated parent's canonical_child_id.

	save_session_id(state, caps)
	return json_ok(res, msg_response(state, new_msg))
end

local function api_post_message_edit(state, caps, _params, body, res)
	if not body or not body.message_id or not body.content then
		return json_err(res, 400, "message_id and content required")
	end
	local msg_id = body.message_id
	local new_content = body.content

	local msg, merr = conv_get_message(state.conv, msg_id)
	if not msg then return json_err(res, 404, "message not found") end

	-- Create a new sibling with the edited content (fork).
	-- The old message and its subtree remain accessible by swiping back.
	local edited, eerr = conv_add_message(state.conv, state.session_id, msg.parent_id, msg.role, new_content, state._time_fn)
	if not edited then return json_err(res, 500, eerr) end

	save_session_id(state, caps)
	local resp = msg_response(state, edited)
	resp.reload_below = true
	return json_ok(res, resp)
end

local function api_post_message_delete(state, _caps, _params, body, res)
	if not body or not body.message_id then
		return json_err(res, 400, "message_id required")
	end
	local msg_id = body.message_id

	local result, err = conv_delete_subtree(state.conv, msg_id)
	if not result then return json_err(res, 404, "message not found") end

	return json_ok(res, { deleted = result.deleted })
end

local function api_post_branch_navigate(state, _caps, _params, body, res)
	if not body or not body.message_id then
		return json_err(res, 400, "message_id required")
	end

	local msg, merr = conv_get_message(state.conv, body.message_id)
	if not msg then return json_err(res, 404, "message not found") end

	if msg.parent_id ~= nil then
		-- Non-root: use swipe_to to update parent's canonical_child_id.
		local ok, err = conv_swipe_to(state.conv, body.message_id)
		if not ok then return json_err(res, 400, err) end
	end
	-- For root messages, get_canonical_path picks the first root by insertion order.
	-- We don't have root-level canonical tracking yet — this is a known limitation.
	-- TODO: support root-level swipe navigation.

	local resp = msg_response(state, msg)
	resp.reload_below = true
	return json_ok(res, resp)
end

-- ── Session endpoints ──────────────────────────────────────────────────────

local function api_get_sessions(state, _caps, _params, _body, res)
	local sessions, err = conv_list_sessions(state.conv)
	if not sessions then return json_err(res, 500, err) end
	local result = {}
	for _, s in ipairs(sessions) do
		result[#result + 1] = {
			id = s.id,
			created_at = s.created_at,
			preview = get_session_preview(state, s.id),
		}
	end
	return json_ok(res, { sessions = result, current = state.session_id })
end

local function api_post_session_new(state, caps, _params, _body, res)
	local session, messages, serr = create_new_session(state, caps)
	if not session then return json_err(res, 500, serr) end
	return json_ok(res, {
		session = { id = session.id, created_at = session.created_at },
		messages = messages,
	})
end

local function api_post_session_switch(state, caps, _params, body, res)
	if not body or not body.session_id then
		return json_err(res, 400, "session_id required")
	end
	local target_id = body.session_id
	local session, serr = conv_get_session(state.conv, target_id)
	if not session then return json_err(res, 404, "session not found") end
	switch_to_session(state, caps, target_id)
	local path = get_canonical_path(state)
	local messages = format_messages(state, path or {})
	return json_ok(res, {
		session = { id = session.id, created_at = session.created_at },
		messages = messages,
	})
end

local function api_post_session_delete(state, caps, _params, body, res)
	if not body or not body.session_id then
		return json_err(res, 400, "session_id required")
	end
	local target_id = body.session_id
	local session, serr = conv_get_session(state.conv, target_id)
	if not session then return json_err(res, 404, "session not found") end
	local ok, derr = conv_delete_session(state.conv, target_id)
	if not ok then return json_err(res, 500, derr) end
	local current_id = state.session_id
	local messages
	if target_id == current_id then
		local remaining = conv_list_sessions(state.conv)
		if remaining and #remaining > 0 then
			switch_to_session(state, caps, remaining[1].id)
			local path = get_canonical_path(state)
			messages = format_messages(state, path or {})
		else
			local new_session, new_messages, nerr = create_new_session(state, caps)
			if not new_session then return json_err(res, 500, nerr) end
			messages = new_messages
		end
	else
		local path = get_canonical_path(state)
		messages = format_messages(state, path or {})
	end
	return json_ok(res, {
		deleted = true,
		current_session_id = state.session_id,
		messages = messages,
	})
end

-- ── Lorebook endpoints ──────────────────────────────────────────────────────

local function entry_to_json(e)
	return {
		uid = e.uid,
		keys = e.key or {},
		content = e.content or "",
		enabled = e.enabled,
		constant = e.constant,
		position = e.position or 0,
		order = e.order or 0,
		role = e.role or 0,
	}
end

local function save_lorebook(state, caps)
	flush_card_state(state, caps)
end

local function api_get_lorebook(state, _caps, _params, _body, res)
	local entries = state.lorebook or {}
	local result = {}
	for _, e in ipairs(entries) do
		result[#result + 1] = entry_to_json(e)
	end
	return json_ok(res, { entries = result })
end

local function api_post_lorebook_update(state, caps, _params, body, res)
	if not body or not body.uid then return json_err(res, 400, "uid required") end
	local entries = state.lorebook or {}
	for _, e in ipairs(entries) do
		if e.uid == body.uid then
			if body.keys ~= nil then e.key = body.keys end
			if body.content ~= nil then e.content = body.content end
			if body.enabled ~= nil then e.enabled = body.enabled end
			if body.constant ~= nil then e.constant = body.constant end
			if body.position ~= nil then e.position = body.position end
			if body.order ~= nil then e.order = body.order end
			if body.role ~= nil then e.role = body.role end
			save_lorebook(state, caps)
			return json_ok(res, entry_to_json(e))
		end
	end
	return json_err(res, 404, "entry not found")
end

local function api_post_lorebook_add(state, caps, _params, body, res)
	if not body or not body.keys or not body.content then
		return json_err(res, 400, "keys and content required")
	end
	local entry = lorebook_mod.normalize({
		key = body.keys,
		content = body.content,
		enabled = body.enabled,
		constant = body.constant,
		position = body.position,
		order = body.order,
		role = body.role,
	})
	if not state.lorebook then state.lorebook = {} end
	state.lorebook[#state.lorebook + 1] = entry
	save_lorebook(state, caps)
	return json_ok(res, entry_to_json(entry))
end

local function api_post_lorebook_delete(state, caps, _params, body, res)
	if not body or not body.uid then return json_err(res, 400, "uid required") end
	local entries = state.lorebook or {}
	for i, e in ipairs(entries) do
		if e.uid == body.uid then
			table.remove(entries, i)
			save_lorebook(state, caps)
			return json_ok(res, { deleted = true })
		end
	end
	return json_err(res, 404, "entry not found")
end

-- ── World info endpoints ───────────────────────────────────────────────────

-- ── User lorebook endpoints ──────────────────────────────────────────────
--
-- User-scope lorebooks (scope: this user, across all cards). State lives in
-- state.user_lorebooks[] and persists to kv under "user_lorebooks". Each
-- book carries { id, name, entries[], active }; active books merge into the
-- prompt at context-assembly time.

local function book_summary(b)
	return {
		id = b.id,
		name = b.name,
		active = b.active == true,
		entry_count = b.entries and #b.entries or 0,
	}
end

local function api_get_user_lorebooks(state, _caps, _params, _body, res)
	local books = {}
	for _, b in ipairs(state.user_lorebooks) do
		books[#books + 1] = book_summary(b)
	end
	return json_ok(res, { books = books })
end

local function api_post_user_lorebooks_create(state, caps, _params, body, res)
	if not body or not body.name or type(body.name) ~= "string" or #body.name == 0 then
		return json_err(res, 400, "name required")
	end
	local book = {
		id = gen_book_id(caps.time and caps.time.now),
		name = body.name,
		entries = {},
		active = false,
	}
	state.user_lorebooks[#state.user_lorebooks + 1] = book
	save_user_lorebooks(state, caps)
	return json_ok(res, book_summary(book))
end

local function api_post_user_lorebooks_rename(state, caps, _params, body, res)
	if not body or not body.id or not body.name then
		return json_err(res, 400, "id and name required")
	end
	local book = find_user_book(state, body.id)
	if not book then return json_err(res, 404, "book not found") end
	book.name = body.name
	save_user_lorebooks(state, caps)
	return json_ok(res, book_summary(book))
end

local function api_post_user_lorebooks_delete(state, caps, _params, body, res)
	if not body or not body.id then return json_err(res, 400, "id required") end
	local _, idx = find_user_book(state, body.id)
	if not idx then return json_err(res, 404, "book not found") end
	table.remove(state.user_lorebooks, idx)
	save_user_lorebooks(state, caps)
	return json_ok(res, { deleted = true })
end

local function api_post_user_lorebooks_toggle(state, caps, _params, body, res)
	if not body or not body.id or body.active == nil then
		return json_err(res, 400, "id and active required")
	end
	local book = find_user_book(state, body.id)
	if not book then return json_err(res, 404, "book not found") end
	book.active = not not body.active
	save_user_lorebooks(state, caps)
	return json_ok(res, book_summary(book))
end

-- Entry CRUD. Book id can arrive as a path param (/api/user_lorebooks/:id/...)
-- or as a body/query "book_id" — we accept both; path param wins if routed.
local function resolve_book(state, params, body)
	local id = (params and params.book_id) or (body and body.book_id)
	if not id then return nil, "book_id required" end
	local book = find_user_book(state, id)
	if not book then return nil, "book not found" end
	return book
end

local function api_get_user_lorebook_entries(state, _caps, params, body, res)
	local book, err = resolve_book(state, params, body)
	if not book then return json_err(res, err == "book not found" and 404 or 400, err) end
	local entries = {}
	for _, e in ipairs(book.entries or {}) do
		entries[#entries + 1] = entry_to_json(e)
	end
	return json_ok(res, { id = book.id, name = book.name, active = book.active, entries = entries })
end

local function api_post_user_lorebook_entry_add(state, caps, params, body, res)
	local book, err = resolve_book(state, params, body)
	if not book then return json_err(res, err == "book not found" and 404 or 400, err) end
	if not body or not body.keys or not body.content then
		return json_err(res, 400, "keys and content required")
	end
	local entry = lorebook_mod.normalize({
		key = body.keys,
		content = body.content,
		enabled = body.enabled,
		constant = body.constant,
		position = body.position,
		order = body.order,
		role = body.role,
	})
	book.entries = book.entries or {}
	book.entries[#book.entries + 1] = entry
	save_user_lorebooks(state, caps)
	return json_ok(res, entry_to_json(entry))
end

local function api_post_user_lorebook_entry_update(state, caps, params, body, res)
	local book, err = resolve_book(state, params, body)
	if not book then return json_err(res, err == "book not found" and 404 or 400, err) end
	if not body or not body.uid then return json_err(res, 400, "uid required") end
	for _, e in ipairs(book.entries or {}) do
		if e.uid == body.uid then
			if body.keys ~= nil then e.key = body.keys end
			if body.content ~= nil then e.content = body.content end
			if body.enabled ~= nil then e.enabled = body.enabled end
			if body.constant ~= nil then e.constant = body.constant end
			if body.position ~= nil then e.position = body.position end
			if body.order ~= nil then e.order = body.order end
			if body.role ~= nil then e.role = body.role end
			save_user_lorebooks(state, caps)
			return json_ok(res, entry_to_json(e))
		end
	end
	return json_err(res, 404, "entry not found")
end

local function api_post_user_lorebook_entry_delete(state, caps, params, body, res)
	local book, err = resolve_book(state, params, body)
	if not book then return json_err(res, err == "book not found" and 404 or 400, err) end
	if not body or not body.uid then return json_err(res, 400, "uid required") end
	for i, e in ipairs(book.entries or {}) do
		if e.uid == body.uid then
			table.remove(book.entries, i)
			save_user_lorebooks(state, caps)
			return json_ok(res, { deleted = true })
		end
	end
	return json_err(res, 404, "entry not found")
end

-- Per-book export / import. Export returns the book's {name, entries} with a
-- Content-Disposition attachment header so the browser triggers a download.
-- Import accepts a {name?, entries} payload and creates a new book by routing
-- each entry through lorebook_mod.normalize (so partial/malformed entries get
-- their required fields filled in with defaults).

-- Replace filesystem-unfriendly characters with underscore. Keeps letters,
-- digits, dot, dash, space, underscore; everything else -> "_". Trims to a
-- reasonable length.
local function sanitize_filename(name)
	if type(name) ~= "string" or #name == 0 then return "lorebook" end
	local out = name:gsub("[^%w%.%-_ ]", "_")
	if #out > 80 then out = out:sub(1, 80) end
	if #out == 0 then return "lorebook" end
	return out
end

local function api_get_user_lorebooks_export(state, _caps, params, _body, res)
	local id = params and params.book_id
	if not id then return json_err(res, 400, "book_id required") end
	local book = find_user_book(state, id)
	if not book then return json_err(res, 404, "book not found") end
	local entries = {}
	for _, e in ipairs(book.entries or {}) do
		entries[#entries + 1] = entry_to_json(e)
	end
	local payload = { name = book.name, entries = entries }
	res.status = 200
	res.headers["Content-Type"] = "application/json"
	res.headers["Content-Disposition"] =
		'attachment; filename="' .. sanitize_filename(book.name) .. '.lorebook.json"'
	res.body = json.encode(payload)
	return true
end

local function api_post_user_lorebooks_import(state, caps, _params, body, res)
	if not body or type(body.entries) ~= "table" then
		return json_err(res, 400, "entries required")
	end
	local name = (type(body.name) == "string" and #body.name > 0) and body.name or "Imported"
	local normalized = {}
	for _, raw in ipairs(body.entries) do
		if type(raw) == "table" then
			-- Accept either {keys=...} (our export shape) or {key=...} (raw storage shape).
			local entry_in = {
				uid             = raw.uid,
				comment         = raw.comment,
				key             = raw.key or raw.keys,
				keysecondary    = raw.keysecondary,
				selectiveLogic  = raw.selectiveLogic,
				content         = raw.content,
				enabled         = raw.enabled,
				constant        = raw.constant,
				order           = raw.order,
				position        = raw.position,
				depth           = raw.depth,
				role            = raw.role,
				caseSensitive   = raw.caseSensitive,
				matchWholeWords = raw.matchWholeWords,
				probability     = raw.probability,
				sticky          = raw.sticky,
				cooldown        = raw.cooldown,
				delay           = raw.delay,
				ignoreBudget    = raw.ignoreBudget,
				excludeRecursion = raw.excludeRecursion,
				preventRecursion = raw.preventRecursion,
				group           = raw.group,
				groupWeight     = raw.groupWeight,
				displayIndex    = raw.displayIndex,
			}
			normalized[#normalized + 1] = lorebook_mod.normalize(entry_in)
		end
	end
	local book = {
		id = gen_book_id(caps.time and caps.time.now),
		name = name,
		entries = normalized,
		active = false,
	}
	state.user_lorebooks[#state.user_lorebooks + 1] = book
	save_user_lorebooks(state, caps)
	return json_ok(res, book_summary(book))
end

-- ── Persona endpoints helpers ──────────────────────────────────────────────

local function save_personas(state, caps)
	if not caps.kv then return end
	caps.kv.set("personas", json.encode(state.personas))
	caps.kv.set("personas:active", state.active_persona or "")
end

local function activate_persona(state, name)
	local persona = find_persona(state.personas, name)
	if not persona then return nil, "persona not found" end
	state.active_persona = name
	state.user_name = persona.name
	return persona
end

-- ── Persona endpoints ─────────────────────────────────────────────────────

local function api_get_personas(state, _caps, _params, _body, res)
	local result = {}
	for _, p in ipairs(state.personas) do
		result[#result + 1] = { name = p.name, description = p.description }
	end
	return json_ok(res, { personas = result, active = state.active_persona })
end

local function api_post_personas_save(state, caps, _params, body, res)
	if not body or not body.name or type(body.name) ~= "string" or #body.name == 0 then
		return json_err(res, 400, "name required")
	end
	local name = body.name
	local description = body.description or ""
	local existing = find_persona(state.personas, name)
	if existing then
		existing.description = description
	else
		state.personas[#state.personas + 1] = { name = name, description = description }
	end
	-- If the active persona was updated, sync user_name.
	if state.active_persona == name then
		state.user_name = name
	end
	save_personas(state, caps)
	return json_ok(res, { name = name, description = description })
end

local function api_post_personas_delete(state, caps, _params, body, res)
	if not body or not body.name or type(body.name) ~= "string" then
		return json_err(res, 400, "name required")
	end
	local name = body.name
	local _, idx = find_persona(state.personas, name)
	if not idx then return json_err(res, 404, "persona not found") end
	table.remove(state.personas, idx)
	-- If we deleted the active persona, switch to first remaining or create Default.
	if state.active_persona == name then
		if #state.personas == 0 then
			state.personas[1] = { name = "User", description = "" }
		end
		activate_persona(state, state.personas[1].name)
	end
	save_personas(state, caps)
	return json_ok(res, { deleted = true, active = state.active_persona })
end

local function api_post_personas_activate(state, caps, _params, body, res)
	if not body or not body.name or type(body.name) ~= "string" then
		return json_err(res, 400, "name required")
	end
	local persona, err = activate_persona(state, body.name)
	if not persona then return json_err(res, 404, err) end
	save_personas(state, caps)
	return json_ok(res, { active = state.active_persona })
end

-- ── Token count endpoint ───────────────────────────────────────────────────

local function api_get_token_count(state, caps, _params, _body, res)
	local tc, err = compute_token_count(state, caps)
	if not tc then return json_err(res, 500, err) end
	return json_ok(res, tc)
end

-- ── Settings endpoints ─────────────────────────────────────────────────────

local function api_get_settings(state, _caps, _params, _body, res)
	return json_ok(res, state.settings)
end

local function api_post_settings(state, caps, _params, body, res)
	if not body then return json_err(res, 400, "body required") end
	for _, key in ipairs(SETTINGS_KEYS) do
		if body[key] ~= nil then
			local val = tonumber(body[key])
			if val then state.settings[key] = val end
		end
	end
	-- Persist to kv.
	if caps.kv then
		caps.kv.set("settings", json.encode(state.settings))
	end
	return json_ok(res, state.settings)
end

-- ── Card editor endpoints ──────────────────────────────────────────────────

local CARD_EDIT_FIELDS = {
	"name", "description", "personality", "scenario", "first_mes", "mes_example",
	"system_prompt", "post_history_instructions", "creator_notes", "creator",
	"character_version",
}

local function card_edit_response(card)
	local data = {}
	for _, key in ipairs(CARD_EDIT_FIELDS) do
		data[key] = card[key] or ""
	end
	data.alternate_greetings = card.alternate_greetings or {}
	data.tags = card.tags or {}
	return data
end

local function api_get_card_edit(state, _caps, _params, _body, res)
	if not state.card then return json_err(res, 404, "no card loaded") end
	return json_ok(res, card_edit_response(state.card))
end

local function api_post_card_edit(state, caps, _params, body, res)
	if not state.card then return json_err(res, 404, "no card loaded") end
	if not body then return json_err(res, 400, "body required") end

	-- Merge provided fields into card.
	for _, key in ipairs(CARD_EDIT_FIELDS) do
		if body[key] ~= nil then
			state.card[key] = body[key]
		end
	end
	if body.alternate_greetings ~= nil then
		state.card.alternate_greetings = body.alternate_greetings
	end
	if body.tags ~= nil then
		state.card.tags = body.tags
	end

	-- Persist: writes chara back to the PNG if self_write is available,
	-- else falls back to per-bucket kv writes (card_overrides).
	flush_card_state(state, caps)

	return json_ok(res, card_edit_response(state.card))
end

local function api_post_card_reset(state, caps, _params, _body, res)
	if not state.card then return json_err(res, 404, "no card loaded") end

	-- Delete legacy kv overrides (post-migration we only need the PNG state,
	-- but older installs may still carry these keys).
	if caps.kv then
		caps.kv.set("card_overrides", nil)
	end

	-- Reload card from PNG data.
	state.card = nil
	state.lorebook = nil
	load_card(state, caps)

	if not state.card then return json_err(res, 500, "failed to reload card") end
	return json_ok(res, card_edit_response(state.card))
end

-- ── Preset endpoints ───────────────────────────────────────────────────────

local function api_get_presets(_state, caps, _params, _body, res)
	if not caps.kv then return json_err(res, 500, "kv not available") end
	local data = presets_mod.load_all(caps.kv)
	return json_ok(res, data)
end

local function api_post_presets_save(_state, caps, _params, body, res)
	if not caps.kv then return json_err(res, 500, "kv not available") end
	if not body or not body.type or not body.preset then
		return json_err(res, 400, "type and preset required")
	end
	local preset = body.preset
	if not preset.name or type(preset.name) ~= "string" or #preset.name == 0 then
		return json_err(res, 400, "preset must have a name")
	end
	local ok, err = presets_mod.save(caps.kv, body.type, preset.name, --[[:! any]] preset)
	if not ok then return json_err(res, 400, err) end
	return json_ok(res, { ok = true })
end

local function api_post_presets_delete(_state, caps, _params, body, res)
	if not caps.kv then return json_err(res, 500, "kv not available") end
	if not body or not body.type or not body.name then
		return json_err(res, 400, "type and name required")
	end
	local ok, err = presets_mod.delete(caps.kv, body.type, body.name)
	if not ok then return json_err(res, 400, err) end
	return json_ok(res, { ok = true })
end

local function api_post_presets_activate(_state, caps, _params, body, res)
	if not caps.kv then return json_err(res, 500, "kv not available") end
	if not body or not body.type or not body.name then
		return json_err(res, 400, "type and name required")
	end
	local ok, err = presets_mod.set_active(caps.kv, body.type, body.name)
	if not ok then return json_err(res, 400, err) end
	return json_ok(res, { ok = true })
end

local function api_post_presets_import(_state, caps, _params, body, res)
	if not caps.kv then return json_err(res, 500, "kv not available") end
	if not body or not body.json then
		return json_err(res, 400, "json field required")
	end
	local preset, err = presets_mod.import_preset(body.json)
	if not preset then return json_err(res, 400, err) end
	return json_ok(res, { preset = preset })
end

local function api_post_presets_export(_state, caps, _params, body, res)
	if not caps.kv then return json_err(res, 500, "kv not available") end
	if not body or not body.type or not body.name then
		return json_err(res, 400, "type and name required")
	end
	-- Find the preset.
	local list = presets_mod.load_all(caps.kv)
	local type_key = body.type .. "s"
	local presets_list = list[type_key]
	if not presets_list then return json_err(res, 404, "no presets for type") end
	local found
	for i = 1, #presets_list do
		if presets_list[i].name == body.name then
			found = presets_list[i]
			break
		end
	end
	if not found then return json_err(res, 404, "preset not found: " .. body.name) end
	return json_ok(res, { json = presets_mod.export_preset(found) })
end

-- ── Regex script endpoints ─────────────────────────────────────────────────

local function regex_script_to_json(s)
	return {
		name = s.name,
		find = s.find,
		replace = s.replace,
		enabled = s.enabled,
		scope = s.scope,
		order = s.order,
	}
end

local function api_get_regex(state, _caps, _params, _body, res)
	local result = {}
	for _, s in ipairs(state.regex_scripts) do
		result[#result + 1] = regex_script_to_json(s)
	end
	return json_ok(res, { scripts = result })
end

local function api_post_regex_save(state, caps, _params, body, res)
	if not body or not body.name or type(body.name) ~= "string" or #body.name == 0 then
		return json_err(res, 400, "name required")
	end
	if not body.find or type(body.find) ~= "string" then
		return json_err(res, 400, "find required")
	end
	-- Validate the pattern.
	local ok_pat, pat_err = pcall(string.find, "", body.find)
	if not ok_pat then
		return json_err(res, 400, "invalid pattern: " .. tostring(pat_err))
	end
	-- Find existing by name.
	local found
	for _, s in ipairs(state.regex_scripts) do
		if s.name == body.name then found = s; break end
	end
	if found then
		found.find = body.find
		found.replace = body.replace or ""
		if body.enabled ~= nil then found.enabled = body.enabled end
		if body.scope ~= nil then found.scope = body.scope end
		if body.order ~= nil then found.order = tonumber(body.order) or 0 end
	else
		found = {
			name = body.name,
			find = body.find,
			replace = body.replace or "",
			enabled = body.enabled ~= false,
			scope = body.scope or "ai_output",
			order = tonumber(body.order) or 0,
		}
		state.regex_scripts[#state.regex_scripts + 1] = found
	end
	save_regex_scripts(state, caps)
	return json_ok(res, regex_script_to_json(found))
end

local function api_post_regex_delete(state, caps, _params, body, res)
	if not body or not body.name or type(body.name) ~= "string" then
		return json_err(res, 400, "name required")
	end
	local scripts = state.regex_scripts
	for i, s in ipairs(scripts) do
		if s.name == body.name then
			table.remove(scripts, i)
			save_regex_scripts(state, caps)
			return json_ok(res, { deleted = true })
		end
	end
	return json_err(res, 404, "script not found")
end

local function api_post_regex_test(_state, _caps, _params, body, res)
	if not body or not body.find or not body.input then
		return json_err(res, 400, "find and input required")
	end
	local ok_pat, pat_err = pcall(string.find, "", body.find)
	if not ok_pat then
		return json_err(res, 400, "invalid pattern: " .. tostring(pat_err))
	end
	local replace = body.replace or ""
	local ok_gsub, output = pcall(string.gsub, body.input, body.find, replace)
	if not ok_gsub then
		return json_err(res, 400, "gsub error: " .. tostring(output))
	end
	return json_ok(res, { output = output })
end


-- ── Author's Note endpoints ───────────────────────────────────────────────

local function save_authors_note(state, caps)
	flush_card_state(state, caps)
end

local function api_get_authors_note(state, _caps, _params, _body, res)
	return json_ok(res, state.authors_note)
end

local function api_post_authors_note(state, caps, _params, body, res)
	if not body then return json_err(res, 400, "body required") end
	local an = state.authors_note
	if body.text ~= nil then an.text = tostring(body.text) end
	if body.depth ~= nil then
		local d = tonumber(body.depth)
		if d then an.depth = d end
	end
	if body.position ~= nil then
		if body.position == "before" or body.position == "after" then
			an.position = body.position
		end
	end
	save_authors_note(state, caps)
	return json_ok(res, an)
end

-- ── Instruct template endpoints ───────────────────────────────────────────

local function api_get_instruct(state, _caps, _params, _body, res)
	local result = {}
	for _, t in ipairs(state.instruct_templates) do
		result[#result + 1] = {
			name = t.name,
			mode = t.mode,
			system_prefix = t.system_prefix,
			system_suffix = t.system_suffix,
			user_prefix = t.user_prefix,
			user_suffix = t.user_suffix,
			assistant_prefix = t.assistant_prefix,
			assistant_suffix = t.assistant_suffix,
			separator = t.separator,
			stop_strings = t.stop_strings,
		}
	end
	return json_ok(res, { templates = result, active = state.instruct_active or "" })
end

local INSTRUCT_FIELDS = {
	"name", "mode",
	"system_prefix", "system_suffix",
	"user_prefix", "user_suffix",
	"assistant_prefix", "assistant_suffix",
	"separator",
}

local function api_post_instruct_save(state, caps, _params, body, res)
	if not body or not body.name or type(body.name) ~= "string" or #body.name == 0 then
		return json_err(res, 400, "name required")
	end
	local template = {}
	for _, key in ipairs(INSTRUCT_FIELDS) do
		template[key] = body[key] ~= nil and body[key] or ""
	end
	template.name = body.name
	template.mode = body.mode == "instruct" and "instruct" or "chat"
	template.stop_strings = body.stop_strings or {}
	-- Ensure stop_strings is a table.
	if type(template.stop_strings) ~= "table" then template.stop_strings = {} end

	local existing, idx = find_instruct_template(state.instruct_templates, body.name)
	if existing then
		state.instruct_templates[idx] = template
	else
		state.instruct_templates[#state.instruct_templates + 1] = template
	end
	save_instruct(state, caps)
	return json_ok(res, template)
end

local function api_post_instruct_delete(state, caps, _params, body, res)
	if not body or not body.name or type(body.name) ~= "string" then
		return json_err(res, 400, "name required")
	end
	local _, idx = find_instruct_template(state.instruct_templates, body.name)
	if not idx then return json_err(res, 404, "template not found") end
	table.remove(state.instruct_templates, idx)
	-- If we deleted the active template, clear active.
	if state.instruct_active == body.name then
		state.instruct_active = nil
	end
	save_instruct(state, caps)
	return json_ok(res, { deleted = true, active = state.instruct_active or "" })
end

local function api_post_instruct_activate(state, caps, _params, body, res)
	if not body or not body.name or type(body.name) ~= "string" then
		return json_err(res, 400, "name required")
	end
	-- Empty name clears active template (reverts to chat mode).
	if body.name == "" then
		state.instruct_active = nil
		save_instruct(state, caps)
		return json_ok(res, { active = "" })
	end
	local template = find_instruct_template(state.instruct_templates, body.name)
	if not template then return json_err(res, 404, "template not found") end
	state.instruct_active = body.name
	save_instruct(state, caps)
	return json_ok(res, { active = state.instruct_active })
end

-- ── Chat export endpoint ──────────────────────────────────────────────────

local function api_get_export_chat(state, caps, params, _body, res)
	local path, err = get_canonical_path(state)
	if not path then return json_err(res, 500, err) end

	local card_name = state.card and state.card.name or "Chat"
	local now = caps.time and caps.time.now() or os.time()
	local date_str = os.date("!%Y-%m-%d", now)
	local format = params.format or "text"

	if format == "json" then
		local messages = {}
		for _, msg in ipairs(path) do
			messages[#messages + 1] = { role = msg.role, content = msg.content }
		end
		local data = {
			card_name = card_name,
			messages = messages,
			exported_at = os.date("!%Y-%m-%dT%H:%M:%SZ", now),
		}
		res.status = 200
		res.headers["Content-Type"] = "application/json"
		res.headers["Content-Disposition"] = 'attachment; filename="chat_' .. card_name .. '_' .. date_str .. '.json"'
		res.body = json.encode(data)
		return true
	else
		-- Plain text format.
		local lines = {}
		lines[#lines + 1] = "# Conversation with " .. card_name
		lines[#lines + 1] = "# Exported " .. date_str
		lines[#lines + 1] = ""
		for _, msg in ipairs(path) do
			local sender
			if msg.role == "assistant" then
				sender = card_name
			elseif msg.role == "user" then
				sender = state.user_name or "User"
			else
				sender = "System"
			end
			lines[#lines + 1] = sender .. ": " .. msg.content
			lines[#lines + 1] = ""
		end
		res.status = 200
		res.headers["Content-Type"] = "text/plain; charset=utf-8"
		res.headers["Content-Disposition"] = 'attachment; filename="chat_' .. card_name .. '_' .. date_str .. '.txt"'
		res.body = table.concat(lines, "\n")
		return true
	end
end

-- ── Connection test ─────────────────────────────────────────────────────────

local function api_post_connection_test(state, caps, params, body, res)
	if not caps.llm or not caps.llm.call then
		return json_ok(res, { success = false, error = "no LLM capability configured" })
	end
	local test_messages = {{ role = "user", content = "Hello" }}
	local t0 = os.clock()
	local response, err = caps.llm.call(test_messages, { max_tokens = 10 })
	local elapsed_ms = math.floor((os.clock() - t0) * 1000 + 0.5)
	if response then
		return json_ok(res, {
			success = true,
			response = response:sub(1, 100),
			latency_ms = elapsed_ms,
		})
	else
		return json_ok(res, {
			success = false,
			error = tostring(err),
		})
	end
end

-- ── New Card ────────────────────────────────────────────────────────────────

-- Minimal 1×1 white PNG (RGB, no alpha). 67 bytes.
-- PNG sig + IHDR + IDAT (zlib-compressed single white pixel) + IEND.
local BLANK_PNG_1X1 = (
	"\137PNG\r\n\26\n"                                -- PNG signature
	.. "\0\0\0\13IHDR"                               -- IHDR length + type
	.. "\0\0\0\1\0\0\0\1\8\2\0\0\0"                  -- 1×1, 8-bit RGB
	.. "\144\119\83\222"                              -- IHDR CRC
	.. "\0\0\0\12IDAT"                               -- IDAT length + type
	.. "\8\215c\248\207\192\0\0\0\2\0\1"             -- zlib(filter=0, 255,255,255)
	.. "\226\33\188\51"                              -- IDAT CRC
	.. "\0\0\0\0IEND"                                -- IEND length + type
	.. "\174\66\96\130"                              -- IEND CRC
)

-- Minimal CCv2 card JSON for a new blank character.
--: string
local BLANK_CHARA_JSON = '{"spec":"chara_card_v2","spec_version":"2.0","data":{"name":"New Character","description":"","personality":"","scenario":"","first_mes":"","mes_example":"","creator_notes":"","system_prompt":"","post_history_instructions":"","tags":[],"creator":"","character_version":"","alternate_greetings":[],"extensions":{},"character_book":{"name":"","description":"","scan_depth":50,"token_budget":500,"recursive_scanning":false,"extensions":{},"entries":[]}}}'

-- api_post_new_card: build a blank CCv2 PNG and return it as a file download.
-- The client receives a PNG the user can import to create a new card.
local function api_post_new_card(_state, _caps, _params, _body, res)
	local chunks, cerr = png_mod.read(BLANK_PNG_1X1)
	if not chunks then
		return json_err(res, 500, "new-card: PNG parse failed: " .. tostring(cerr))
	end
	--: string
	local chara_b64 = tostring(base64_mod.encode(BLANK_CHARA_JSON))
	chunks = png_mod.set_itxt(chunks, "chara", chara_b64, { language_tag = "" })
	local png_bytes, werr = png_mod.write(chunks)
	if not png_bytes then
		return json_err(res, 500, "new-card: PNG write failed: " .. tostring(werr))
	end
	res.status = 200
	res.headers["Content-Type"] = "image/png"
	res.headers["Content-Disposition"] = 'attachment; filename="new-character.png"'
	res.body = png_bytes
	return true
end

-- ── Router ──────────────────────────────────────────────────────────────────

local routes = {
	["GET /api/card"]             = api_get_card,
	["GET /api/card/export"]      = api_get_card_export,
	["GET /api/avatar"]           = api_get_avatar,
	["GET /api/messages"]         = api_get_messages,
	["POST /api/message"]         = api_post_message,
	["POST /api/continue"]        = api_post_continue,
	["GET /api/swipes"]           = api_get_swipes,
	["POST /api/swipe/new"]       = api_post_swipe_new,
	["POST /api/message/edit"]    = api_post_message_edit,
	["POST /api/message/delete"]  = api_post_message_delete,
	["POST /api/message/stream"]  = api_post_message_stream,
	["POST /api/impersonate"]     = api_post_impersonate,
	["POST /api/branch/navigate"] = api_post_branch_navigate,
	["GET /api/lorebook"]          = api_get_lorebook,
	["POST /api/lorebook/update"]  = api_post_lorebook_update,
	["POST /api/lorebook/add"]     = api_post_lorebook_add,
	["POST /api/lorebook/delete"]  = api_post_lorebook_delete,
	-- User-scope lorebooks (new primary interface).
	["GET /api/user_lorebooks"]                = api_get_user_lorebooks,
	["POST /api/user_lorebooks"]               = api_post_user_lorebooks_create,
	["POST /api/user_lorebooks/rename"]        = api_post_user_lorebooks_rename,
	["POST /api/user_lorebooks/delete"]        = api_post_user_lorebooks_delete,
	["POST /api/user_lorebooks/toggle"]        = api_post_user_lorebooks_toggle,
	["GET /api/user_lorebooks/entries"]        = api_get_user_lorebook_entries,
	["POST /api/user_lorebooks/entry/add"]     = api_post_user_lorebook_entry_add,
	["POST /api/user_lorebooks/entry/update"]  = api_post_user_lorebook_entry_update,
	["POST /api/user_lorebooks/entry/delete"]  = api_post_user_lorebook_entry_delete,
	["GET /api/user_lorebooks/export"]         = api_get_user_lorebooks_export,
	["POST /api/user_lorebooks/import"]        = api_post_user_lorebooks_import,
	["GET /api/sessions"]         = api_get_sessions,
	["POST /api/session/new"]     = api_post_session_new,
	["POST /api/session/switch"]  = api_post_session_switch,
	["POST /api/session/delete"]  = api_post_session_delete,
	["GET /api/personas"]           = api_get_personas,
	["POST /api/personas/save"]     = api_post_personas_save,
	["POST /api/personas/delete"]   = api_post_personas_delete,
	["POST /api/personas/activate"] = api_post_personas_activate,
	["GET /api/token_count"]      = api_get_token_count,
	["GET /api/settings"]         = api_get_settings,
	["POST /api/settings"]        = api_post_settings,
	["GET /api/card/edit"]          = api_get_card_edit,
	["POST /api/card/edit"]         = api_post_card_edit,
	["POST /api/card/reset"]        = api_post_card_reset,
	["GET /api/presets"]           = api_get_presets,
	["POST /api/presets/save"]     = api_post_presets_save,
	["POST /api/presets/delete"]   = api_post_presets_delete,
	["POST /api/presets/activate"] = api_post_presets_activate,
	["POST /api/presets/import"]   = api_post_presets_import,
	["POST /api/presets/export"]   = api_post_presets_export,
	["GET /api/regex"]             = api_get_regex,
	["POST /api/regex/save"]       = api_post_regex_save,
	["POST /api/regex/delete"]     = api_post_regex_delete,
	["POST /api/regex/test"]       = api_post_regex_test,
	["GET /api/authors_note"]       = api_get_authors_note,
	["POST /api/authors_note"]      = api_post_authors_note,
	["GET /api/export/chat"]        = api_get_export_chat,
	["POST /api/connection/test"]    = api_post_connection_test,
	["POST /api/new-card"]           = api_post_new_card,
	["GET /api/instruct"]             = api_get_instruct,
	["POST /api/instruct/save"]       = api_post_instruct_save,
	["POST /api/instruct/delete"]     = api_post_instruct_delete,
	["POST /api/instruct/activate"]   = api_post_instruct_activate,
	["GET /api/group"]              = api_get_group,
	["POST /api/group/toggle"]      = api_post_group_toggle,
	["POST /api/group/add"]         = api_post_group_add,
	["POST /api/group/remove"]      = api_post_group_remove,
	["POST /api/group/order"]       = api_post_group_order,
	-- Aliases for renamed endpoints.
	["GET /api/siblings"]         = api_get_swipes,
	["POST /api/branch/new"]      = api_post_swipe_new,
}

function M.create(caps, opts)
	opts = opts or {}
	-- Seed RNG for UUID generation. Use time cap if available.
	local time_fn = caps.time and caps.time.now or nil
	math.randomseed(time_fn and (time_fn() * 1000 + math.random(999)) or math.random(2^31))
	local state = create_state()

	-- Read user name from opts (previously from caps.config, now passed directly).
	if opts.user_name then
		state.user_name = opts.user_name
	end

	-- Initialize generation settings from defaults, then overlay persisted values.
	state.settings = default_settings()
	if caps.kv then
		local raw = caps.kv.get("settings")
		if raw then
			local ok, saved = pcall(json.decode, raw)
			if ok and type(saved) == "table" then
				for _, key in ipairs(SETTINGS_KEYS) do
					if saved[key] ~= nil then
						local val = tonumber(saved[key])
						if val then state.settings[key] = val end
					end
				end
			end
		end
	end

	-- Load card.
	load_card(state, caps)

	-- Apply card overrides from kv (user edits take precedence over PNG data).
	if caps.kv and state.card then
		local raw = caps.kv.get("card_overrides")
		if raw then
			local ok, overrides = pcall(json.decode, raw)
			if ok and type(overrides) == "table" then
				for k, v in pairs(overrides) do
					state.card[k] = v
				end
			end
		end
	end

	-- Load lorebook from kv (overrides card's character_book if present).
	if caps.kv then
		local raw = caps.kv.get("lorebook")
		if raw then
			local ok, saved = pcall(json.decode, raw)
			if ok and type(saved) == "table" then
				state.lorebook = saved
			end
		end
	end

	-- Load user_lorebooks from kv.
	if caps.kv then
		local raw = caps.kv.get("user_lorebooks")
		if raw then
			local ok, saved = pcall(json.decode, raw)
			if ok and type(saved) == "table" then
				state.user_lorebooks = saved
			end
		end

		-- One-pass migration: legacy "world_info" kv key → a single
		-- user lorebook named "Imported", active by default. Idempotent:
		-- runs only if user_lorebooks is empty and the legacy key exists.
		if #state.user_lorebooks == 0 then
			local legacy = caps.kv.get("world_info")
			if legacy then
				local ok_l, parsed = pcall(json.decode, legacy)
				if ok_l and type(parsed) == "table" then
					state.user_lorebooks[1] = {
						id = gen_book_id(caps.time and caps.time.now),
						name = "Imported",
						entries = parsed,
						active = true,
					}
					save_user_lorebooks(state, caps)
				end
			end
		end
		-- Always clear the legacy key on successful migration (also clears if
		-- it was bogus JSON, which is fine — nothing to preserve).
		if caps.kv.get("world_info") ~= nil and #state.user_lorebooks > 0 then
			caps.kv.set("world_info", nil)
		end
	end

	-- Load personas from kv or initialize defaults.
	state.personas = { { name = state.user_name, description = "" } }
	state.active_persona = state.user_name
	if caps.kv then
		local raw = caps.kv.get("personas")
		if raw then
			local ok_p, saved = pcall(json.decode, raw)
			if ok_p and type(saved) == "table" and #saved > 0 then
				state.personas = saved
			end
		end
		local active = caps.kv.get("personas:active")
		if active and active ~= "" then
			local p = find_persona(state.personas, active)
			if p then
				state.active_persona = active
				state.user_name = p.name
			end
		end
	end

	-- Load regex scripts from kv.
	if caps.kv then
		local raw = caps.kv.get("regex_scripts")
		if raw then
			local ok_r, saved = pcall(json.decode, raw)
			if ok_r and type(saved) == "table" then
				state.regex_scripts = saved
			end
		end
	end

	-- Load instruct templates from kv or initialize defaults.
	do
		local templates = {}
		for _, t in ipairs(DEFAULT_INSTRUCT_TEMPLATES) do
			local copy = {}
			for k, v in pairs(t) do
				if type(v) == "table" then
					local arr = {}
					for _, item in ipairs(v) do arr[#arr + 1] = item end
					copy[k] = arr
				else
					copy[k] = v
				end
			end
			templates[#templates + 1] = copy
		end
		state.instruct_templates = templates
		state.instruct_active = "OpenAI (native)"
	end
	if caps.kv then
		local raw = caps.kv.get("instruct_templates")
		if raw then
			local ok_it, saved = pcall(json.decode, raw)
			if ok_it and type(saved) == "table" and #saved > 0 then
				state.instruct_templates = saved
			end
		end
		local active = caps.kv.get("instruct_active")
		if active ~= nil then
			if active == "" then
				state.instruct_active = nil
			else
				local t = find_instruct_template(state.instruct_templates, active)
				if t then state.instruct_active = active end
			end
		end
	end

	-- Load author's note from kv or initialize defaults. PNG-resident values
	-- (loaded by load_card from chara.extensions.depth_prompt) take
	-- precedence because kv is a legacy fallback.
	if not state.authors_note then
		state.authors_note = { text = "", depth = 4, position = "after" }
	end
	if caps.kv and (state.authors_note.text == nil or state.authors_note.text == "") then
		local raw = caps.kv.get("authors_note")
		if raw then
			local ok_an, saved = pcall(json.decode, raw)
			if ok_an and type(saved) == "table" then
				if saved.text ~= nil then state.authors_note.text = saved.text end
				if saved.depth ~= nil then state.authors_note.depth = saved.depth end
				if saved.position ~= nil then state.authors_note.position = saved.position end
			end
		end
	end

	-- One-pass card-state migration: when self_write is available and legacy
	-- kv keys exist (lorebook/card_overrides/authors_note/regex_scripts),
	-- bake the merged state into the PNG and delete the legacy keys.
	-- Idempotent: after the first run the legacy keys are gone so this is a
	-- no-op on subsequent starts.
	if caps.self_write and caps.kv and state.card then
		local had_any = false
		for _, k in ipairs({ "lorebook", "card_overrides", "authors_note", "regex_scripts" }) do
			if caps.kv.get(k) ~= nil then had_any = true; break end
		end
		if had_any then
			local ok = write_chara_to_png(state, caps)
			if ok then
				for _, k in ipairs({ "lorebook", "card_overrides", "authors_note", "regex_scripts" }) do
					caps.kv.set(k, nil)
				end
			end
		end
	end

	-- Open conversation database.
	local time_fn = caps.time and caps.time.now or os.time
	state._time_fn = time_fn
	local conv_db
	if caps.conversations then
		-- shared_db cap: set up schema (idempotent) and use raw SQL helpers.
		caps.conversations.setup(CONV_SCHEMA)
		conv_db = caps.conversations
	elseif opts.conv_db then
		conv_db = opts.conv_db  -- for tests: pass a pre-built conversation handle
	else
		-- Fallback: use lib.conversation with in-memory db.
		local conv_mod = require("lib.conversation")
		local db_path = opts.db_path or ":memory:"
		local db_err
		conv_db, db_err = conv_mod.open(db_path, time_fn)
		if not conv_db then
			error("card server: failed to open conversation db: " .. tostring(db_err))
		end
	end
	state.conv = conv_db

	-- Restore or create session.
	local session_id = load_session_id(caps)
	if session_id then
		local session = conv_get_session(conv_db, session_id)
		if session then
			state.session_id = session_id
		end
	end
	if not state.session_id then
		local session, serr = conv_create_session(conv_db, time_fn)
		if not session then
			error("card server: failed to create session: " .. tostring(serr))
		end
		state.session_id = session.id
		save_session_id(state, caps)
	end

	-- Initialize group chat.
	init_group(state)
	if caps.kv then
		local raw = caps.kv.get("group")
		if raw then
			local ok_g, saved = pcall(json.decode, raw)
			if ok_g and type(saved) == "table" then
				state.group.enabled = saved.enabled or false
				state.group.turn_order = saved.turn_order or "round_robin"
				state.group.next_speaker = saved.next_speaker or 1
				if saved.members then
					for i, sm in ipairs(saved.members) do
						if sm.is_primary then
							-- Primary member already initialized from card.
						elseif sm.card_json then
							local cdata = card_mod.from_json(sm.card_json)
							if cdata then
								state.group.members[#state.group.members + 1] = {
									card = cdata,
									name = sm.name,
									is_primary = false,
								}
							end
						end
					end
				end
			end
		end
	end

	-- If session has no messages and card has a greeting, create it.
	local path = get_canonical_path(state)
	if not path or #path == 0 then
		init_greeting(state)
	end

	-- Extension -> content-type map for static file serving via caps.self.
	local MIME_TYPES = {
		html = "text/html; charset=utf-8",
		js = "application/javascript; charset=utf-8",
		css = "text/css; charset=utf-8",
		json = "application/json",
		png = "image/png",
		jpg = "image/jpeg",
		jpeg = "image/jpeg",
		gif = "image/gif",
		svg = "image/svg+xml",
		ico = "image/x-icon",
		woff = "font/woff",
		woff2 = "font/woff2",
		ttf = "font/ttf",
		txt = "text/plain",
	}

	local serve_static = not opts.no_static and caps.self and caps.self.entry

	local function handler(req, res)
		local req_path, params = parse_target(req.target or req.path or "/")
		local key = req.method .. " " .. req_path
		local route = routes[key]
		if route then
			local req_body = read_json_body(req)
			return route(state, caps, params, req_body, res)
		end
		-- Static files via caps.self tarball entries.
		if serve_static then
			local entry_path = "static" .. req_path
			if req_path == "/" then entry_path = "static/index.html" end
			local content = caps.self.entry(entry_path)
			if content then
				local ext = entry_path:match("%.([^%.]+)$")
				res.status = 200
				res.headers["Content-Type"] = MIME_TYPES[ext] or "application/octet-stream"
				res.body = content
				return true
			end
		end
	end

	return { handler = handler, state = state }
end

return M
