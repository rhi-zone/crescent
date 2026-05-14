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

--:: require "lib.platform.caps.cap_types"

-- json.encode is typed as returning (string|nil,string|nil) in the module, but
-- this file always encodes well-formed app data and does not check for error;
-- the cast to string here is safe for these call sites.
--:: JsonMod = { encode: (unknown) -> string, decode: (string) -> (unknown, string | nil), ... }
local json = require("lib.format.json") --[[:! JsonMod]]
local card_mod = require("lib.formats.ccv2.card")
local context_mod = require("lib.formats.ccv2.context")
local macro_mod = require("lib.formats.ccv2.macro")
local lorebook_mod = require("lib.formats.ccv2.lorebook")
local presets_mod = require("lib.platform.apps.charactercardv2.presets")
local base64_mod = require("lib.encode.base64")
local png_mod = require("lib.png")

local M = {}

-- ConvRow: a row returned by the conversation DB (lib.conversation or shared_db).
--:: ConvRow = { id: string, session_id: string, parent_id: string | nil, role: string, content: string, created_at: integer, canonical_child_id: string | nil, metadata: unknown, speaker?: string, ... }
-- ConvSession: a session row from the conversation DB.
--:: ConvSession = { id: string, app_id: string, created_at: integer, metadata: unknown, ... }
-- LibConvDb: the lib.conversation handle interface.
-- Methods use `:` call syntax. Used after is_lib_conv() narrows a ConvDb to LibConvDb.
--:: LibConvDb = { create_session: (self: LibConvDb, string) -> (ConvSession | nil, string | nil), get_session: (self: LibConvDb, string) -> (ConvSession | nil, string | nil), list_sessions: (self: LibConvDb, string) -> (ConvSession[] | nil, string | nil), delete_session: (self: LibConvDb, string) -> (boolean | nil, string | nil), add_message: (self: LibConvDb, string, string | nil, string, string, unknown) -> (ConvRow | nil, string | nil), get_message: (self: LibConvDb, string) -> (ConvRow | nil, string | nil), get_children: (self: LibConvDb, string | nil) -> (ConvRow[] | nil, string | nil), get_roots: (self: LibConvDb, string) -> (ConvRow[] | nil, string | nil), get_canonical_path: (self: LibConvDb, string | nil) -> (ConvRow[] | nil, string | nil), swipe_to: (self: LibConvDb, string) -> (boolean | nil, string | nil), update_message: (self: LibConvDb, string, unknown) -> (ConvRow | nil, string | nil), delete_subtree: (self: LibConvDb, string) -> ({ deleted: integer } | nil, string | nil) }
-- ConvDb: the conversation DB interface (SharedDbCap + lib.conversation compat).
-- is_lib_conv() narrows ConvDb to LibConvDb at runtime.
--:: ConvDb = { query: (string, { [integer]: unknown }) -> (unknown, string | nil), setup?: unknown, [string]: unknown }
-- Caps: the app capability table. All fields are optional (nil when not granted).
-- Cap types come from lib/platform/caps/cap_types.lua (loaded via --:: require above).
--:: Caps = {
--::   self?: SelfCap,
--::   self_write?: SelfWriteCap,
--::   kv?: KvCap,
--::   llm?: LlmCap,
--::   time?: TimeCap,
--::   conversations?: ConvDb,
--:: }
-- Internal types: complex duck-typed objects. Open index signatures allow body
-- code to access fields freely (returning unknown). These are NOT cap types —
-- they're app-internal data structures.
--:: CardData = { [string]: unknown, name?: string, description?: string, personality?: string, scenario?: string, system_prompt?: string, post_history_instructions?: string, creator_notes?: string, character_version?: string, mes_example?: string, first_mes?: string, character_book?: unknown, extensions?: { [string]: unknown }, alternate_greetings?: string[], ... }
--:: AuthorsNote = { text: string, depth: integer | nil, position: string | nil }
--:: GroupMember = { [string]: unknown, name?: string, description?: string, card_json?: string, is_primary?: boolean, card?: CardData | nil, ... }
--:: GroupState = { enabled: boolean, members: Arr<GroupMember>, turn_order: string, next_speaker: integer, ... }
-- RegexScript: a regex find-replace script entry.
--:: RegexScript = { name: string, find: string, replace: string, enabled: boolean, scope: string, order: integer | nil, ... }
-- InstructTemplate: an instruct formatting template.
--:: InstructTemplate = { name: string, mode: string, system_prefix: string, system_suffix: string, user_prefix: string, user_suffix: string, assistant_prefix: string, assistant_suffix: string, separator: string, stop_strings: string[], ... }
-- UserLorebook: a user-scope lorebook entry.
--:: UserLorebook = { id: string, name: string, entries: { [integer]: unknown } | nil, active: boolean, ... }
-- State: the per-session app state table. conv, session_id, _time_fn, and
-- group are initialized to placeholder values in create_state() and replaced
-- by M.create() before any handler runs.
--:: State = { card: CardData | nil, lorebook: { [integer]: unknown } | nil, user_name: string, conv: ConvDb, _time_fn: () -> integer, session_id: string, settings: { [string]: unknown } | nil, personas: { [integer]: { name: string, description: string } } | nil, active_persona: string | nil, authors_note: AuthorsNote | nil, regex_scripts: Arr<RegexScript>, instruct_templates: Arr<InstructTemplate>, instruct_active: string | nil, user_lorebooks: Arr<UserLorebook>, _card_state_warned: boolean, group: GroupState, linked_lorebooks?: { [integer]: unknown }, ... }
-- Persona: a persona entry.
--:: Persona = { name: string, description: string }
-- Settings: generation settings table.
--:: Settings = { [string]: unknown, ... }
-- Context: the assembled LLM message array (chat turns).
--:: Context = LlmMessage[]
-- TokenCount: result of compute_token_count.
--:: TokenCount = { context_used: integer, context_max: integer, response_budget: integer, available: integer, messages: integer, lorebook_entries: integer }
-- MsgResponse: the per-message response object sent to the frontend.
--:: MsgResponse = { id: string, role: string, content: string, parent_id: string | nil, sibling_index: integer, sibling_count: integer, speaker?: string, token_count?: TokenCount | nil, reload_below?: boolean, ... }
-- CreateOpts: options passed to M.create.
--:: CreateOpts = { user_name?: string, no_static?: boolean, conversations?: ConvDb, ... }
-- JsonBody: parsed JSON request body. Values are unknown since structure varies
-- by endpoint; endpoint code checks and casts as needed.
--:: JsonBody = { [string]: unknown }
-- OpaqueData: a return value whose structure is complex and duck-typed internally.
-- Functions returning OpaqueData are typed precisely enough for their callers;
-- the open index signature allows all the internal duck-typing patterns.
--:: OpaqueData = { [string]: unknown, ... }
--:: Req = { method: string, target?: string, path?: string, body?: string, last_event_id?: string, ... }
--:: Res = { status: integer, headers: { [string]: unknown }, body: string | nil, send_event: (data: string, opts: { id?: unknown, event?: string } | nil) -> (true | nil, string | nil), close: () -> nil, ... }

-- ── Conversation DB helpers ──────────────────────────────────────────────────
--
-- When caps.conversations is a shared_db cap, state.conv is that cap and these
-- helpers call raw SQL via db.query(sql, params_array) → rows_array.
--
-- When the fallback path is used (lib.conversation handle), state.conv has a
-- :create_session() etc. API. The helpers detect which type is present via
-- is_lib_conv() and dispatch accordingly.

--: (db: ConvDb) -> db is LibConvDb
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
		math.random(0, math.floor(0xffffffff)),
		math.random(0, 0xffff),
		math.random(0, 0xfff),
		math.random(0x8000, 0xbfff),
		math.random(0, math.floor(0xffffffffffff))
	)
end

-- conv_query: runs sql with params_array on a shared_db cap (dot-call API).
-- Works for both SELECT (returns rows) and DML (returns {}).
-- Returns rows_array, nil on success; nil, err on failure.
--: (ConvDb, string, { [integer]: unknown }) -> (ConvRow[] | nil, string | nil)
local function conv_query(db, sql, params)
	local rows, err = db.query(sql, params)
	return rows --[[:! ConvRow[] | nil]], err
end

--: (ConvDb, () -> integer) -> (ConvSession | nil, string | nil)
local function conv_create_session(db, time_fn)
	if is_lib_conv(db) then return db:create_session("card") end
	local id = conv_uuid()
	local now = time_fn()
	local _, err = conv_query(db,
		"INSERT INTO sessions (id, app_id, created_at) VALUES (?, ?, ?)",
		{ id, "card", now }
	)
	if err then return nil, err end
	return { id = id, app_id = "card", created_at = now, metadata = nil }
end

--: (ConvDb, string) -> (ConvSession | nil, string | nil)
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

--: (ConvDb) -> (ConvSession[] | nil, string | nil)
local function conv_list_sessions(db)
	if is_lib_conv(db) then return db:list_sessions("card") end
	local rows, err = conv_query(db,
		"SELECT id, app_id, created_at, metadata FROM sessions WHERE app_id = 'card' ORDER BY created_at DESC",
		{}
	)
	if not rows then return nil, err end
	return rows
end

--: (ConvDb, string) -> (boolean | nil, string | nil)
local function conv_delete_session(db, id)
	if is_lib_conv(db) then return db:delete_session(id) end
	local _, err = conv_query(db, "DELETE FROM sessions WHERE id = ?", { id })
	if err then return nil, err end
	return true
end

--: (ConvDb, string, string | nil, string, string, () -> integer, unknown) -> (ConvRow | nil, string | nil)
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

--: (ConvRow | nil) -> ConvRow | nil
local function conv_decode_metadata(r)
	if r and r.metadata and type(r.metadata) == "string" then
		local json_mod = require("lib.format.json")
		local v = json_mod.decode(r.metadata --[[:! string]])
		if v then r.metadata = v end
	end
	return r
end

--: (ConvDb, string) -> (ConvRow | nil, string | nil)
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

--: (ConvDb, string | nil) -> (ConvRow[] | nil, string | nil)
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

--: (ConvDb, string) -> (ConvRow[] | nil, string | nil)
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

--: (ConvDb, string | nil) -> (ConvRow[] | nil, string | nil)
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
		if not next_rows then return nil, nerr end
		if #next_rows == 0 then
			return nil, "conversation: broken canonical link from " .. tostring(cur.id)
		end
		cur = conv_decode_metadata(next_rows[1])
	end
	return path
end

--: (ConvDb, string) -> (boolean | nil, string | nil)
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

--: (ConvDb, string, { content?: string, metadata?: unknown, canonical_child_id?: string | nil, ... }) -> (ConvRow | nil, string | nil)
local function conv_update_message(db, id, fields)
	if is_lib_conv(db) then return db:update_message(id, fields) end
	local sets = {} --[[: { [integer]: string }]]
	local params = {} --[[: { [integer]: unknown }]]
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

--: (ConvDb, string) -> ({ deleted: integer } | nil, string | nil)
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

--: (string) -> (string, { [string]: string })
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

--: (Res, unknown) -> boolean
local function json_ok(res, data)
	res.status = 200
	res.headers["Content-Type"] = "application/json"
	res.body = json.encode(data)
	return true
end

--: (Res, integer, string | nil) -> boolean
local function json_err(res, status, msg)
	res.status = status
	res.headers["Content-Type"] = "application/json"
	res.body = json.encode({ error = msg })
	return true
end

--: (Req) -> JsonBody | nil
local function read_json_body(req)
	if not req.body then return {} end
	local body = --[[:! string]] req.body
	if #body == 0 then return {} end
	local ok, val = pcall(json.decode, body)
	if not ok then return nil end
	return --[[:! { [string]: unknown }]] val
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
	-- Fields conv, _time_fn, session_id, group are nil at construction but are
	-- always set in M.create() before the handler is returned. The State type
	-- reflects the post-init invariant; M.create() must uphold it.
	-- conv, _time_fn, session_id, group use placeholder values here and are
	-- replaced by M.create() before handlers run; the casts are safe.
	return {
		card = nil,
		lorebook = nil,
		user_name = "User",
		conv = {} --[[:! ConvDb]],
		_time_fn = function() return 0 end,
		session_id = "" --[[:! string]],
		settings = nil,
		personas = nil,
		active_persona = nil,
		authors_note = nil,
		regex_scripts = {},
		instruct_templates = {},
		instruct_active = nil,
		user_lorebooks = {},
		_card_state_warned = false,
		group = {} --[[:! GroupState]],
	} --[[:! State]]
end

-- gen_book_id: stable identifier for a user lorebook. Not a UUID; just a
-- time+random composite sufficient for uniqueness within a single user's
-- kv store.
--: ((() -> integer) | nil) -> string
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
--: (State) -> unknown
local function build_chara_for_write(state)
	local card = state.card
	if not card then return nil end
	local data = {} --[[:! { [string]: unknown }]]
	local envelope = { spec = "chara_card_v2", spec_version = "2.0", data = data }
	-- Copy all current card fields (name, description, personality, ...).
	for k, v in pairs(--[[:! { [string]: unknown }]] card) do data[k] = v end
	-- Bake the in-memory lorebook back into character_book.
	if state.lorebook and #state.lorebook > 0 then
		data.character_book = lorebook_mod.to_ccv2(--[[:! { ... }[] ]] state.lorebook)
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
	if state.linked_lorebooks and #(--[[:! { [integer]: unknown }]] state.linked_lorebooks) > 0 then
		ext.linked_lorebooks = state.linked_lorebooks
	else
		ext.linked_lorebooks = nil
	end
	data.extensions = ext
	return envelope
end

-- write_chara_to_png: serialize + base64 + write via caps.self_write.
-- Returns (true | nil, err).
--: (State, Caps) -> (boolean | nil, string | nil)
local function write_chara_to_png(state, caps)
	if not caps.self_write or not caps.self_write.write_metadata then
		return nil, "no self_write capability"
	end
	local envelope = build_chara_for_write(state)
	if not envelope then return nil, "no card loaded" end
	local encoded_json, jerr = json.encode(envelope)
	if not encoded_json then return nil, "json encode: " .. tostring(jerr) end
	local encoded_b64 = base64_mod.encode(--[[:! string]] encoded_json)
	return caps.self_write.write_metadata("chara", encoded_b64)
end

-- Legacy kv writers (fallback when self_write absent). Declared up-front so
-- flush_card_state can call them; individual save_* functions below also
-- remain available for tests / introspection.
--: (State, Caps) -> nil
local function kv_save_lorebook(state, caps)
	if not caps.kv then return end
	caps.kv.set("lorebook", json.encode(state.lorebook or {}))
end

--: (State, Caps) -> nil
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

--: (State, Caps) -> nil
local function kv_save_authors_note(state, caps)
	if not caps.kv then return end
	caps.kv.set("authors_note", json.encode(state.authors_note))
end

--: (State, Caps) -> nil
local function kv_save_regex_scripts(state, caps)
	if not caps.kv then return end
	caps.kv.set("regex_scripts", json.encode(state.regex_scripts))
end

-- flush_card_state: persist all card-state buckets. Uses self_write when
-- available; otherwise falls back to per-bucket kv writes. Logs a single
-- warning per session on first fallback.
--: (State, Caps) -> boolean
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

--: (State, Caps) -> nil
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

--: (Settings | nil) -> LlmCallOpts
local function llm_opts_from_settings(settings)
	return {
		temperature = settings and (settings.temperature --[[:! number | nil]]) or nil,
		top_p = settings and (settings.top_p --[[:! number | nil]]) or nil,
		max_tokens = settings and (settings.max_tokens --[[:! integer | nil]]) or nil,
		stop = nil,
	} --[[:! LlmCallOpts]]
end

-- ── Card loading ────────────────────────────────────────────────────────────

--: (State, Caps) -> (CardData | nil, string | nil)
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
		state.lorebook = lorebook_mod.from_ccv2(card_data.character_book --[[:! { ... }]])
	end
	-- Pull author's note and regex scripts from extensions when present so
	-- the card is self-contained (they round-trip through flush_card_state).
	local ext = card_data.extensions
	if type(ext) == "table" then
		local ext_ = ext --[[:! { [string]: unknown }]]
		local depth_prompt = ext_.depth_prompt
		if depth_prompt and type(depth_prompt) == "string" and #depth_prompt > 0 then
			state.authors_note = state.authors_note or { text = "", depth = 4, position = "after" }
			state.authors_note.text = depth_prompt
			if type(ext_.depth_prompt_depth) == "number" then
				state.authors_note.depth = ext_.depth_prompt_depth
			end
			if ext_.depth_prompt_role == "before" or ext_.depth_prompt_role == "after" then
				state.authors_note.position = ext_.depth_prompt_role --[[:! string]]
			end
		end
		if type(ext_.regex_scripts) == "table" then
			state.regex_scripts = ext_.regex_scripts --[[:! { [integer]: { enabled: boolean, find: string, name: string, order: integer | nil, replace: string, scope: string } }]]
		end
		if type(ext_.linked_lorebooks) == "table" then
			state.linked_lorebooks = ext_.linked_lorebooks --[[:! { [integer]: unknown }]]
		end
	end
	return card_data
end

-- ── Tree helpers ────────────────────────────────────────────────────────────

-- get_canonical_path: returns the active path for the session.
-- Wraps conv_get_canonical_path().
--: (State) -> (ConvRow[] | nil, string | nil)
local function get_canonical_path(state)
	return conv_get_canonical_path(state.conv --[[:! ConvDb]], state.session_id)
end

-- get_siblings: returns all siblings of a message (children of its parent).
-- For root messages (parent_id is nil), returns all roots in the session.
--: (State, ConvRow) -> (ConvRow[] | nil, string | nil)
local function get_siblings(state, msg)
	if msg.parent_id == nil then
		return conv_get_roots(state.conv --[[:! ConvDb]], state.session_id --[[:! string]])
	end
	return conv_get_children(state.conv --[[:! ConvDb]], msg.parent_id)
end

-- sibling_info: compute sibling_index (0-based) and sibling_count for a message.
--: (State, ConvRow) -> (integer, integer)
local function sibling_info(state, msg)
	local siblings, err = get_siblings(state, msg)
	if not siblings then return 0, 1 end
	local sibs = --[[:! ConvRow[] ]] siblings
	local index = 0
	for i, s in ipairs(sibs) do
		if s.id == msg.id then index = i - 1; break end
	end
	return index, #sibs
end

-- msg_response: format a message for the API response.
--: (State, ConvRow) -> MsgResponse
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
	if not speaker and type(msg.metadata) == "table" then
		local meta = msg.metadata --[[:! { [string]: unknown }]]
		if meta.speaker then speaker = meta.speaker --[[:! string]] end
	end
	if speaker then resp.speaker = speaker --[[:! string]] end
	return resp
end

-- ── Persona helpers (forward declarations for context assembly) ────────────

--: (Persona[] | nil, string | nil) -> (Persona | nil, integer | nil)
local function find_persona(personas, name)
	for i, p in ipairs(personas) do
		if p.name == name then return p, i end
	end
	return nil
end

--: (State) -> Persona | nil
local function get_active_persona(state)
	if not state.active_persona then return nil end
	local p = find_persona(state.personas, state.active_persona)
	return p
end

-- ── Context assembly ────────────────────────────────────────────────────────

--: (State) -> { char: string, user: string }
local function make_macro_env(state)
	local card = state.card
	if not card then return { char = "", user = state.user_name } end
	return { char = card.name --[[:! string]] or "", user = state.user_name }
end

--: (State, Caps, ConvRow[] | nil) -> (Context | nil, string | nil)
local function build_context(state, caps, path)
	local card = state.card
	if not path then
		local err
		path, err = get_canonical_path(state)
		if not path then return nil, err end
	end
	local path_ = path --[[:! ConvRow[] ]]

	if not card then
		local result = {} --[[: LlmMessage[] ]]
		for i = 1, #path_ do
			result[#result + 1] = { role = path_[i].role --[[:! "user" | "assistant" | "system"]], content = path_[i].content }
		end
		return result
	end

	local count_tokens
	if caps.llm and caps.llm.count_tokens then
		count_tokens = caps.llm.count_tokens
	else
		count_tokens = function(text) return math.ceil(#text / 4) end
	end

	local max_context = (state.settings and state.settings.max_context --[[:! integer | nil]]) or 4096
	local max_response = (state.settings and state.settings.max_tokens --[[:! integer | nil]]) or 512

	local active_p = get_active_persona(state)
	local lorebook_all = {} --[[: unknown[] ]]
	if state.lorebook then
		for _, e in ipairs(--[[:! { [integer]: unknown }]] state.lorebook) do lorebook_all[#lorebook_all + 1] = e end
	end
	for _, book in ipairs(--[[:! { [string]: unknown }[] ]] (state.linked_lorebooks or {})) do
		if type((book --[[:! { [string]: unknown }]]).entries) == "table" then
			for _, e in ipairs((book --[[:! { entries: { [integer]: unknown }, [string]: unknown }]]).entries) do lorebook_all[#lorebook_all + 1] = e end
		end
	end
	for _, book in ipairs(state.user_lorebooks or {}) do
		if book.active and book.entries then
			for _, e in ipairs(--[[:! { [integer]: unknown }]] book.entries) do lorebook_all[#lorebook_all + 1] = e end
		end
	end
	local assemble_opts = {
		card = card,
		history = path_,
		count_tokens = count_tokens,
		max_context = max_context,
		max_response = max_response,
		char_name = card.name --[[:! string | nil]],
		user_name = state.user_name,
		persona = active_p and active_p.description or nil,
	} --[[: { [string]: unknown, ... }]]
	if #lorebook_all > 0 then
		(assemble_opts --[[:! { lorebook_entries: { [integer]: { content?: string, role?: integer, position?: integer, depth?: integer, order?: integer, constant?: boolean, enabled?: boolean, ignoreBudget?: boolean, ... } }, ... }]]).lorebook_entries = lorebook_all --[[:! { [integer]: { content?: string, role?: integer, position?: integer, depth?: integer, order?: integer, constant?: boolean, enabled?: boolean, ignoreBudget?: boolean, ... } }]]
	end
	local result_raw, err = context_mod.assemble(assemble_opts)
	local result = result_raw --[[:! LlmMessage[] | nil]]
	if not result then
		local fallback = {} --[[: LlmMessage[] ]]
		for i = 1, #path_ do
			fallback[#fallback + 1] = { role = path_[i].role --[[:! "user" | "assistant" | "system"]], content = path_[i].content }
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
--: (State, Caps) -> (TokenCount | nil, string | nil)
local function compute_token_count(state, caps)
	local path, perr = get_canonical_path(state)
	if not path then return nil, perr end

	local context, cerr = build_context(state, caps, path)
	if not context then return nil, cerr end

	local count_tokens
	if caps.llm and caps.llm.count_tokens then
		count_tokens = --[[: (string) -> integer]] caps.llm.count_tokens
	else
		count_tokens = function(text) return math.ceil(#text / 4) end
	end

	local total = 0
	for _, msg in ipairs(--[[:! LlmMessage[] ]] context) do
		total = total + count_tokens(msg.content)
	end

	local max_context = (state.settings and state.settings.max_context --[[:! integer | nil]]) or 4096
	local max_tokens = (state.settings and state.settings.max_tokens --[[:! integer | nil]]) or 512
	local available = math.max(0, max_context - total - max_tokens)

	-- Count triggered lorebook entries.
	local lorebook_count = 0
	if state.lorebook then
		for _, e in ipairs(--[[:! { [integer]: { enabled?: boolean, [string]: unknown } }]] state.lorebook) do
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
--: (State, Caps, string | nil) -> (Context | nil, string | nil)
local function build_context_to_parent(state, caps, parent_id)
	if parent_id == nil then
		-- Parent is the session root — context is empty (no messages before root).
		return build_context(state, caps, {})
	end
	-- Walk up from parent_id to root, then reverse.
	local chain = {}
	local current_id = parent_id --[[:! string | nil]]
	while current_id do
		local cid = current_id --[[:! string]]
		local msg, err = conv_get_message(state.conv, cid)
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

--: (State, string, string) -> string
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

--: (State, Caps) -> nil
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
--: (Context, InstructTemplate | nil) -> Context
local function format_for_instruct(messages, template)
	if not template or template.mode == "chat" then return messages end
	local parts = {}
	local sep = template.separator or ""
	for i, msg in ipairs(--[[:! LlmMessage[] ]] messages) do
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

--: (InstructTemplate[] | nil, string | nil) -> (InstructTemplate | nil, integer | nil)
local function find_instruct_template(templates, name)
	for i, t in ipairs(templates) do
		if t.name == name then return t, i end
	end
	return nil
end

--: (State, Caps) -> nil
local function save_instruct(state, caps)
	if not caps.kv then return end
	caps.kv.set("instruct_templates", json.encode(state.instruct_templates))
	caps.kv.set("instruct_active", state.instruct_active or "")
end

-- Get the active instruct template (nil if none or chat mode).
--: (State) -> InstructTemplate | nil
local function get_active_instruct(state)
	if not state.instruct_active or state.instruct_active == "" then return nil end
	local t = find_instruct_template(state.instruct_templates, state.instruct_active)
	return t
end

-- Apply instruct template to messages before LLM call.
--: (State, Context) -> Context
local function apply_instruct(state, messages)
	local template = get_active_instruct(state)
	return format_for_instruct(messages, template)
end

-- ── Persistence ─────────────────────────────────────────────────────────────

--: (State, Caps) -> nil
local function save_session_id(state, caps)
	if not caps.kv then return end
	caps.kv.set("card_session_id", state.session_id)
end

--: (Caps) -> string | nil
local function load_session_id(caps)
	if not caps.kv then return nil end
	local v = caps.kv.get("card_session_id")
	return v --[[:! string | nil]]
end

-- ── Greeting ────────────────────────────────────────────────────────────────

--: (State) -> nil
local function init_greeting(state)
	local card = state.card
	if not card then return end
	local first_mes = card.first_mes --[[:! string | nil]]
	if not first_mes then return end
	if #first_mes == 0 then return end

	local env = make_macro_env(state)
	local content = macro_mod.substitute(first_mes, env)

	-- Create primary greeting as root message.
	local msg, err = conv_add_message(state.conv, state.session_id, nil, "assistant", content, state._time_fn)
	if not msg then return end

	-- Create alternate greetings as root siblings (also parent_id = nil).
	if card.alternate_greetings then
		for _, g in ipairs(--[[:! string[] ]] card.alternate_greetings) do
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

--: (State, string) -> string
local function get_session_preview(state, session_id)
	local path = conv_get_canonical_path(state.conv, session_id)
	if not path then return "" end
	if #path == 0 then return "" end
	for _, msg in ipairs(path) do
		if msg.role == "user" then
			local text = msg.content
			if #text > 80 then text = text:sub(1, 77) .. "..." end
			return text
		else -- not user, continue
		end
	end
	local text = path[1].content
	if #text > 80 then text = text:sub(1, 77) .. "..." end
	return text
end

--: (State, ConvRow[]) -> MsgResponse[]
local function format_messages(state, path)
	local result = {}
	for _, msg in ipairs(path) do
		result[#result + 1] = msg_response(state, msg)
	end
	return result
end

--: (State, Caps, string) -> nil
local function switch_to_session(state, caps, session_id)
	state.session_id = session_id
	save_session_id(state, caps)
end

--: (State, Caps) -> (ConvSession | nil, MsgResponse[] | nil, string | nil)
local function create_new_session(state, caps)
	local session, serr = conv_create_session(state.conv, state._time_fn)
	if not session then return nil, nil, serr end
	state.session_id = session.id
	init_greeting(state)
	switch_to_session(state, caps, session.id)
	local path = get_canonical_path(state)
	local messages = format_messages(state, path or {})
	return session, messages, nil
end

-- ── Group chat helpers ────────────────────────────────────────────────────

--: (State) -> nil
local function init_group(state)
	local primary_name = state.card and state.card.name or "Character"
	state.group = {
		enabled = false,
		members = { { card = state.card, name = primary_name, is_primary = true } },
		turn_order = "round_robin",
		next_speaker = 1,
	}
end

--: (State, Caps) -> nil
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
				card_json = card_mod.to_json((m.card --[[: unknown]]) --[[:! { alternate_greetings: { [number]: string }, character_book: CharacterBook | nil, character_version: string, creator: string, creator_notes: string, description: string, extensions: { [string]: unknown }, first_mes: string, mes_example: string, name: string, personality: string, post_history_instructions: string, scenario: string, system_prompt: string, tags: { [number]: string } }]]),
			}
		end
	end
	caps.kv.set("group", json.encode(serializable))
end

--: (State) -> { name: string, is_primary: boolean }[]
local function group_members_response(state)
	local g = state.group --[[:! GroupState]]
	local members = {} --[[: { name: string, is_primary: boolean }[] ]]
	for _, m in ipairs(g.members) do
		members[#members + 1] = { name = m.name --[[:! string]] or "", is_primary = m.is_primary and true or false }
	end
	return members
end

--: (State) -> { enabled: boolean, members: { name: string, is_primary: boolean }[], turn_order: string }
local function group_response(state)
	local g = state.group --[[:! GroupState]]
	return {
		enabled = g.enabled,
		members = group_members_response(state),
		turn_order = g.turn_order,
	}
end

-- Build context for a specific group member's turn.
--: (State, Caps, GroupMember, ConvRow[]) -> (Context | nil, string | nil)
local function build_group_context(state, caps, speaker_member, path)
	local speaker_card = speaker_member.card --[[:! CardData | nil]]
	if not speaker_card then return build_context(state, caps, path) end

	local count_tokens
	if caps.llm and caps.llm.count_tokens then
		count_tokens = --[[: (string) -> integer]] caps.llm.count_tokens
	else
		count_tokens = function(text) return math.ceil(#text / 4) end
	end

	local max_context = (state.settings and state.settings.max_context --[[:! integer | nil]]) or 4096
	local max_response = (state.settings and state.settings.max_tokens --[[:! integer | nil]]) or 512

	-- Label history messages with speaker names for group context.
	local labeled_history = {} --[[: LlmMessage[] ]]
	for _, msg in ipairs(--[[:! ConvRow[] ]] path) do
		local content --[[: string]] = msg.content
		if msg.role == "assistant" and msg.speaker then
			content = (msg.speaker --[[:! string]]) .. ": " .. content
		elseif msg.role == "user" then
			content = state.user_name .. ": " .. content
		end
		labeled_history[#labeled_history + 1] = { role = msg.role --[[:! "user" | "assistant" | "system"]], content = content }
	end

	local active_p = get_active_persona(state)
	local result_raw2 = context_mod.assemble({
		card = speaker_card,
		history = labeled_history,
		count_tokens = count_tokens,
		max_context = max_context,
		max_response = max_response,
		char_name = (speaker_card.name --[[:! string | nil]]) or "",
		user_name = state.user_name,
		lorebook_entries = (state.lorebook or {}) --[[:! { [integer]: { constant?: boolean, content?: string, depth?: integer, enabled?: boolean, ignoreBudget?: boolean, order?: integer, position?: integer, role?: integer, ... } }]],
	})
	if not result_raw2 then
		return labeled_history
	end
	local res2 = result_raw2 --[[:! LlmMessage[] ]]

	-- Insert Author's Note at configured depth.
	local an = state.authors_note
	if an and an.text and #an.text > 0 then
		local depth = an.depth or 4
		local pos = an.position or "after"
		local insert_pos = #res2 - depth
		if pos == "after" then insert_pos = insert_pos + 1 end
		if insert_pos < 1 then insert_pos = 1 end
		if insert_pos > #res2 + 1 then insert_pos = #res2 + 1 end
		table.insert(res2, insert_pos, { role = "system", content = an.text })
	end

	return res2
end

-- Pick the next speaker(s) based on turn order.
--: (State) -> GroupMember[]
local function pick_next_speakers(state)
	local group = state.group --[[:! GroupState]]
	local members = group.members
	if #members == 0 then return {} end

	if group.turn_order == "round_robin" then
		local idx = group.next_speaker or 1
		if idx < 1 or idx > #members then idx = 1 end
		group.next_speaker = (idx % #members) + 1
		return { members[idx] }
	elseif group.turn_order == "random" then
		local idx = math.random(1, #members)
		return { members[idx] }
	elseif group.turn_order == "all" then
		return members
	else
		-- Default: round_robin behavior.
		local idx = group.next_speaker or 1
		if idx < 1 or idx > #members then idx = 1 end
		group.next_speaker = (idx % #members) + 1
		return { members[idx] }
	end
end

-- ── Group endpoints ──────────────────────────────────────────────────────

--: (State, Caps, { [string]: string }, JsonBody | nil, Res) -> boolean
local function api_get_group(state, _caps, _params, _body, res)
	return json_ok(res, group_response(state))
end

--: (State, Caps, { [string]: string }, JsonBody | nil, Res) -> boolean
local function api_post_group_toggle(state, caps, _params, body, res)
	if not body or body.enabled == nil then
		return json_err(res, 400, "enabled field required")
	end
	state.group.enabled = not not body.enabled
	save_group(state, caps)
	return json_ok(res, group_response(state))
end

--: (State, Caps, { [string]: string }, JsonBody | nil, Res) -> boolean
local function api_post_group_add(state, caps, _params, body, res)
	if not body or not body.card_json then
		return json_err(res, 400, "card_json required")
	end
	local card_data, cerr = card_mod.from_json(body.card_json --[[:! string]])
	if not card_data then
		return json_err(res, 400, "invalid card: " .. tostring(cerr))
	end
	local name = tostring(card_data.name)
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

--: (State, Caps, { [string]: string }, JsonBody | nil, Res) -> boolean
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

--: (State, Caps, { [string]: string }, JsonBody | nil, Res) -> boolean
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

--: (State, Caps, { [string]: string }, JsonBody | nil, Res) -> boolean
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
--: (State, Caps, { [string]: string }, JsonBody | nil, Res) -> boolean
local function api_get_card_export(state, caps, _params, _body, res)
	if not caps.self or not caps.self.read then
		return json_err(res, 503, "self cap not available")
	end
	local bytes, rerr = caps.self.read()
	if not bytes then
		return json_err(res, 500, "export: " .. tostring(rerr))
	end
	local card_name = ((state.card and state.card.name --[[:! string | nil]]) or "card")
	local safe_name = (card_name --[[:! string]]):gsub('[/\\:*?"<>|]', "_")
	res.status = 200
	res.headers["Content-Type"] = "image/png"
	res.headers["Content-Disposition"] = 'attachment; filename="' .. safe_name .. '.png"'
	res.body = bytes
	return true
end

--: (State, Caps, { [string]: string }, JsonBody | nil, Res) -> boolean
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

--: (State, Caps, { [string]: string }, JsonBody | nil, Res) -> boolean
local function api_get_messages(state, _caps, _params, _body, res)
	local path, err = get_canonical_path(state)
	if not path then return json_err(res, 500, err) end
	local result = {}
	for _, msg in ipairs(path) do
		result[#result + 1] = msg_response(state, msg)
	end
	return json_ok(res, { messages = result })
end

--: (State, Caps, { [string]: string }, JsonBody | nil, Res) -> boolean
local function api_post_message(state, caps, _params, body, res)
	if not caps.llm then return json_err(res, 503, "no LLM capability configured") end
	if not body or not body.content then return json_err(res, 400, "content required") end
	local text = body.content --[[:! string]]
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
			local path2, p2err = get_canonical_path(state)
			if not path2 then return json_err(res, 500, p2err) end
			local context, ctx_err = build_group_context(state, caps, speaker, path2)
			if not context then return json_err(res, 500, ctx_err) end
			local ctx_ = context --[[:! LlmMessage[] ]]
			local inst_ctx = apply_instruct(state, ctx_) --[[:! LlmMessage[] ]]
			local llm_ret = { caps.llm.call(inst_ctx, llm_opts_from_settings(state.settings)) }
			local resp_raw = llm_ret[1] --[[:! string | nil]]
			local gerr = llm_ret[2] --[[:! string | nil]]
			if not resp_raw then
				if #responses == 0 then
					conv_delete_subtree(state.conv, user_msg.id)
					return json_err(res, 502, "LLM error: " .. tostring(gerr))
				end
				break
			end
			local resp = resp_raw
			local resp_str = apply_regex_scripts(state, resp, "ai_output")
			local speaker_name = speaker.name --[[:! string]] or ""
			local meta = { speaker = speaker_name }
			local asst_msg, aerr = conv_add_message(state.conv, state.session_id, parent_id, "assistant", resp_str, state._time_fn, meta)
			if not asst_msg then return json_err(res, 500, aerr) end
			asst_msg.speaker = speaker_name
			parent_id = asst_msg.id
			local r = msg_response(state, asst_msg)
			r.speaker = speaker_name
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
	local context, ctx_err = build_context(state, caps)
	if not context then
		conv_delete_subtree(state.conv, user_msg.id)
		return json_err(res, 500, ctx_err)
	end
	local llm_r1 = { caps.llm.call(apply_instruct(state, context), llm_opts_from_settings(state.settings)) }
	local response = llm_r1[1] --[[:! string | nil]]
	local err = llm_r1[2] --[[:! string | nil]]
	if not response then
		-- Rollback: delete user message.
		conv_delete_subtree(state.conv, user_msg.id)
		return json_err(res, 502, "LLM error: " .. tostring(err))
	end

	-- Apply ai_output regex scripts.
	local resp_str = apply_regex_scripts(state, --[[:! string]] response, "ai_output")

	-- Add assistant message as child of user message.
	local asst_msg, aerr = conv_add_message(state.conv, state.session_id, user_msg.id, "assistant", resp_str, state._time_fn)
	if not asst_msg then return json_err(res, 500, aerr) end

	save_session_id(state, caps)
	return json_ok(res, {
		user = { id = user_msg.id, role = "user", content = text },
		assistant = msg_response(state, asst_msg),
		token_count = compute_token_count(state, caps),
	})
end

-- ── SSE streaming (via res.send_event / res.close from http_server cap) ───

--: (State, Caps, { [string]: string }, JsonBody | nil, Res) -> boolean
local function api_post_message_stream(state, caps, _params, body, res)
	if not caps.llm then return json_err(res, 503, "no LLM capability configured") end
	if not body or not body.content then return json_err(res, 400, "content required") end
	local text = body.content --[[:! string]]
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
	local context, bctx_err = build_context(state, caps)
	if not context then
		conv_delete_subtree(state.conv, user_msg.id)
		return json_err(res, 500, bctx_err)
	end

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
	local llm_stream_opts = llm_opts_from_settings(state.settings)
	local ctx_stream = context --[[:! LlmMessage[] ]]
	local llm_rs = { caps.llm.call_stream(apply_instruct(state, ctx_stream), function(token)
		if client_gone then return end
		local sok = res.send_event(json.encode({ type = "token", token = token }))
		if not sok then client_gone = true end
	end, llm_stream_opts) }
	local response = llm_rs[1] --[[:! string | nil]]
	local err = llm_rs[2] --[[:! string | nil]]

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
	local resp_str = apply_regex_scripts(state, response --[[:! string]], "ai_output")

	-- Add assistant message.
	local asst_msg, aerr = conv_add_message(state.conv, state.session_id, user_msg.id, "assistant", resp_str, state._time_fn)
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
		content = resp_str,
		sibling_index = idx,
		sibling_count = total,
	}))

	res.close()
	return true
end

--: (State, Caps, { [string]: string }, JsonBody | nil, Res) -> boolean
local function api_post_continue(state, caps, _params, _body, res)
	if not caps.llm then return json_err(res, 503, "no LLM capability configured") end
	local path, perr = get_canonical_path(state)
	if not path then return json_err(res, 400, "no messages") end
	if #path == 0 then return json_err(res, 400, "no messages") end

	local context, cerr = build_context(state, caps, path)
	if not context then return json_err(res, 500, cerr) end
	local ctx_cont = context --[[:! LlmMessage[] ]]
	local llm_r2 = { caps.llm.call(apply_instruct(state, ctx_cont), llm_opts_from_settings(state.settings)) }
	local response = llm_r2[1] --[[:! string | nil]]
	local err = llm_r2[2] --[[:! string | nil]]
	if not response then return json_err(res, 502, "LLM error: " .. tostring(err)) end

	-- Apply ai_output regex scripts.
	local response_str = apply_regex_scripts(state, response, "ai_output")

	local leaf = path[#path]
	if leaf.role == "assistant" then
		-- Append to existing assistant message (in-place update).
		local updated, uerr = conv_update_message(state.conv, leaf.id, {
			content = leaf.content .. response_str,
		})
		if not updated then return json_err(res, 500, uerr) end
		save_session_id(state, caps)
		local resp = msg_response(state, updated)
		resp.token_count = compute_token_count(state, caps)
		return json_ok(res, resp)
	else
		-- Add new assistant message as child of leaf.
		local asst_msg, aerr = conv_add_message(state.conv, state.session_id, leaf.id, "assistant", response_str, state._time_fn)
		if not asst_msg then return json_err(res, 500, aerr) end
		save_session_id(state, caps)
		local resp = msg_response(state, asst_msg)
		resp.token_count = compute_token_count(state, caps)
		return json_ok(res, resp)
	end
end

--: (State, Caps, { [string]: string }, JsonBody | nil, Res) -> boolean
local function api_post_impersonate(state, caps, _params, body, res)
	if not caps.llm then return json_err(res, 503, "no LLM capability configured") end
	local context = build_context(state, caps)
	if not context then return json_err(res, 500, "failed to build context") end
	-- Append instruction to generate as the user character.
	local hint = "Continue the conversation as {{user}}, writing their next message in character."
	local env = make_macro_env(state)
	hint = hint:gsub("{{user}}", env.user or "User")
	if body and body.prompt and type(body.prompt) == "string" then
		local prompt_str = body.prompt --[[:! string]]
		if #prompt_str > 0 then
			hint = hint .. " " .. prompt_str
		end
	end
	local ctx_imp = context --[[:! LlmMessage[] ]]
	ctx_imp[#ctx_imp + 1] = { role = "system", content = hint }

	local llm_r3 = { caps.llm.call(apply_instruct(state, ctx_imp), llm_opts_from_settings(state.settings)) }
	local response = llm_r3[1] --[[:! string | nil]]
	local err = llm_r3[2] --[[:! string | nil]]
	if not response then return json_err(res, 502, "LLM error: " .. tostring(err)) end

	return json_ok(res, { content = response })
end

--: (State, Caps, { [string]: string }, JsonBody | nil, Res) -> boolean
local function api_get_swipes(state, _caps, params, _body, res)
	local msg_id = params.message_id
	if not msg_id then return json_err(res, 400, "message_id required") end

	local msg, merr = conv_get_message(state.conv, msg_id)
	if not msg then return json_err(res, 404, "message not found") end

	local siblings, serr = get_siblings(state, msg)
	if not siblings then return json_err(res, 500, serr) end

	local swipes = {}
	local current = 0
	for i, s in ipairs(--[[:! ConvRow[] ]] siblings) do
		swipes[#swipes + 1] = { id = s.id, content = s.content, index = i - 1 }
		if s.id == msg_id then current = i - 1 end
	end
	return json_ok(res, { swipes = swipes, current = current })
end

--: (State, Caps, { [string]: string }, JsonBody | nil, Res) -> boolean
local function api_post_swipe_new(state, caps, _params, body, res)
	if not caps.llm then return json_err(res, 503, "no LLM capability configured") end
	local msg_id = body and body.message_id --[[:! string | nil]]
	if not msg_id then return json_err(res, 400, "message_id required") end

	local msg, merr = conv_get_message(state.conv, msg_id)
	if not msg then return json_err(res, 404, "message not found") end

	-- Build context up to (but not including) this message.
	local context, cerr = build_context_to_parent(state, caps, msg.parent_id)
	if not context then return json_err(res, 500, cerr) end
	local ctx_swipe = context --[[:! LlmMessage[] ]]

	local llm_r4 = { caps.llm.call(apply_instruct(state, ctx_swipe), llm_opts_from_settings(state.settings)) }
	local response = llm_r4[1] --[[:! string | nil]]
	local err = llm_r4[2] --[[:! string | nil]]
	if not response then return json_err(res, 502, "LLM error: " .. tostring(err)) end

	-- Apply ai_output regex scripts.
	local response_str2 = apply_regex_scripts(state, response, "ai_output")

	-- Add as sibling (same parent, same role).
	local new_msg, nerr = conv_add_message(state.conv, state.session_id, msg.parent_id, msg.role, response_str2, state._time_fn)
	if not new_msg then return json_err(res, 500, nerr) end

	-- For root siblings, add_message doesn't update any parent canonical_child_id.
	-- The canonical path still starts from the first root. We rely on the frontend
	-- calling /api/branch/navigate to switch to the new sibling.
	-- For non-root siblings, add_message already updated parent's canonical_child_id.

	save_session_id(state, caps)
	return json_ok(res, msg_response(state, new_msg))
end

--: (State, Caps, { [string]: string }, JsonBody | nil, Res) -> boolean
local function api_post_message_edit(state, caps, _params, body, res)
	if not body or not body.message_id or not body.content then
		return json_err(res, 400, "message_id and content required")
	end
	local msg_id = body.message_id --[[:! string]]
	local new_content = body.content --[[:! string]]

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

--: (State, Caps, { [string]: string }, JsonBody | nil, Res) -> boolean
local function api_post_message_delete(state, _caps, _params, body, res)
	if not body or not body.message_id then
		return json_err(res, 400, "message_id required")
	end
	local msg_id = body.message_id --[[:! string]]

	local result, err = conv_delete_subtree(state.conv, msg_id)
	if not result then return json_err(res, 404, "message not found") end

	return json_ok(res, { deleted = result.deleted })
end

--: (State, Caps, { [string]: string }, JsonBody | nil, Res) -> boolean
local function api_post_branch_navigate(state, _caps, _params, body, res)
	if not body or not body.message_id then
		return json_err(res, 400, "message_id required")
	end
	local branch_msg_id = body.message_id --[[:! string]]

	local msg, merr = conv_get_message(state.conv, branch_msg_id)
	if not msg then return json_err(res, 404, "message not found") end

	if msg.parent_id ~= nil then
		-- Non-root: use swipe_to to update parent's canonical_child_id.
		local ok, err = conv_swipe_to(state.conv, branch_msg_id)
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

--: (State, Caps, { [string]: string }, JsonBody | nil, Res) -> boolean
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

--: (State, Caps, { [string]: string }, JsonBody | nil, Res) -> boolean
local function api_post_session_new(state, caps, _params, _body, res)
	local session, messages, serr = create_new_session(state, caps)
	if not session then return json_err(res, 500, serr) end
	return json_ok(res, {
		session = { id = session.id, created_at = session.created_at },
		messages = messages,
	})
end

--: (State, Caps, { [string]: string }, JsonBody | nil, Res) -> boolean
local function api_post_session_switch(state, caps, _params, body, res)
	if not body or not body.session_id then
		return json_err(res, 400, "session_id required")
	end
	local target_id = body.session_id --[[:! string]]
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

--: (State, Caps, { [string]: string }, JsonBody | nil, Res) -> boolean
local function api_post_session_delete(state, caps, _params, body, res)
	if not body or not body.session_id then
		return json_err(res, 400, "session_id required")
	end
	local target_id = body.session_id --[[:! string]]
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

--: ({ [string]: unknown }) -> { [string]: unknown }
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

--: (State, Caps, { [string]: string }, JsonBody | nil, Res) -> boolean
local function api_get_lorebook(state, _caps, _params, _body, res)
	local entries = state.lorebook or {}
	local result = {}
	for _, e in ipairs(--[[:! { [integer]: { [string]: unknown } }]] entries) do
		result[#result + 1] = entry_to_json(e --[[:! { [string]: unknown }]])
	end
	return json_ok(res, { entries = result })
end

--: (State, Caps, { [string]: string }, JsonBody | nil, Res) -> boolean
local function api_post_lorebook_update(state, caps, _params, body, res)
	if not body or not body.uid then return json_err(res, 400, "uid required") end
	local entries = state.lorebook or {}
	for _, e_raw in ipairs(--[[:! { [integer]: { [string]: unknown } }]] entries) do
		local e = e_raw --[[:! { [string]: unknown }]]
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

--: (State, Caps, { [string]: string }, JsonBody | nil, Res) -> boolean
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
	if not state.lorebook then state.lorebook = {} --[[: { [integer]: unknown }]] end
	local lb = state.lorebook --[[:! { [integer]: unknown }]]
	lb[#lb + 1] = entry
	save_lorebook(state, caps)
	return json_ok(res, entry_to_json(entry))
end

--: (State, Caps, { [string]: string }, JsonBody | nil, Res) -> boolean
local function api_post_lorebook_delete(state, caps, _params, body, res)
	if not body or not body.uid then return json_err(res, 400, "uid required") end
	local entries = state.lorebook or {}
	for i, e in ipairs(--[[:! { [integer]: { [string]: unknown } }]] entries) do
		local e_ = e --[[:! { [string]: unknown }]]
		if e_.uid == body.uid then
			table.remove(entries --[[:! Arr<RegexScript>]], i)
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

--: (UserLorebook) -> { id: string, name: string, active: boolean, entry_count: integer }
local function book_summary(b)
	return {
		id = b.id,
		name = b.name,
		active = b.active == true,
		entry_count = b.entries and #(--[[:! { [integer]: unknown }]] b.entries) or 0,
	}
end

--: (State, Caps, { [string]: string }, JsonBody | nil, Res) -> boolean
local function api_get_user_lorebooks(state, _caps, _params, _body, res)
	local books = {}
	for _, b in ipairs(state.user_lorebooks) do
		books[#books + 1] = book_summary(b)
	end
	return json_ok(res, { books = books })
end

--: (State, Caps, { [string]: string }, JsonBody | nil, Res) -> boolean
local function api_post_user_lorebooks_create(state, caps, _params, body, res)
	if not body or not body.name or type(body.name) ~= "string" or body.name == "" then
		return json_err(res, 400, "name required")
	end
	local book = {
		id = gen_book_id(caps.time and caps.time.now),
		name = body.name --[[:! string]],
		entries = {} --[[: { [integer]: unknown } | nil]],
		active = false,
	}
	state.user_lorebooks[#state.user_lorebooks + 1] = book
	save_user_lorebooks(state, caps)
	return json_ok(res, book_summary(book))
end

--: (State, Caps, { [string]: string }, JsonBody | nil, Res) -> boolean
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

--: (State, Caps, { [string]: string }, JsonBody | nil, Res) -> boolean
local function api_post_user_lorebooks_delete(state, caps, _params, body, res)
	if not body or not body.id then return json_err(res, 400, "id required") end
	local _, idx = find_user_book(state, body.id)
	if not idx then return json_err(res, 404, "book not found") end
	table.remove(state.user_lorebooks, idx)
	save_user_lorebooks(state, caps)
	return json_ok(res, { deleted = true })
end

--: (State, Caps, { [string]: string }, JsonBody | nil, Res) -> boolean
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

--: (State, Caps, { [string]: string }, JsonBody | nil, Res) -> boolean
local function api_get_user_lorebook_entries(state, _caps, params, body, res)
	local book, err = resolve_book(state, params, body)
	if not book then return json_err(res, err == "book not found" and 404 or 400, err) end
	local entries = {}
	for _, e in ipairs(book.entries or {}) do
		entries[#entries + 1] = entry_to_json(e)
	end
	return json_ok(res, { id = book.id, name = book.name, active = book.active, entries = entries })
end

--: (State, Caps, { [string]: string }, JsonBody | nil, Res) -> boolean
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

--: (State, Caps, { [string]: string }, JsonBody | nil, Res) -> boolean
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

--: (State, Caps, { [string]: string }, JsonBody | nil, Res) -> boolean
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

--: (State, Caps, { [string]: string }, JsonBody | nil, Res) -> boolean
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

--: (State, Caps, { [string]: string }, JsonBody | nil, Res) -> boolean
local function api_post_user_lorebooks_import(state, caps, _params, body, res)
	if not body or type(body.entries) ~= "table" then
		return json_err(res, 400, "entries required")
	end
	local body_name = body.name --[[:! string | nil]]
	local name = (type(body_name) == "string" and #(body_name --[[:! string]]) > 0) and (body_name --[[:! string]]) or "Imported"
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
		name = name --[[:! string]],
		entries = normalized --[[:! { [integer]: unknown }]],
		active = false,
	}
	state.user_lorebooks[#state.user_lorebooks + 1] = book
	save_user_lorebooks(state, caps)
	return json_ok(res, book_summary(book))
end

-- ── Linked lorebooks (card-vendored snapshots) ────────────────────────────
--
-- Linked lorebooks live on the card itself under
-- extensions.linked_lorebooks. They're informational snapshots
-- (`{ name, source?, entries }`) that the context-assembly side merges
-- into the prompt. The Card Editor surfaces them so authors can view
-- which books are bundled and add/remove entries. Persistence rides on
-- flush_card_state (writes the chara PNG chunk).

--: ({ [string]: unknown }) -> { name: string, source: string | nil, entry_count: integer }
local function linked_book_summary(b)
	local entries = b.entries
	local count = 0
	if type(entries) == "table" then count = #(--[[:! { [integer]: unknown }]] entries) end
	return {
		name = (type(b.name) == "string" and (b.name --[[:! string]])) or "",
		source = (type(b.source) == "string" and (b.source --[[:! string]])) or nil,
		entry_count = count,
	}
end

--: (State, Caps, { [string]: string }, JsonBody | nil, Res) -> boolean
local function api_get_linked_lorebooks(state, _caps, _params, _body, res)
	local books = {}
	local entries_out = {}
	local raw = state.linked_lorebooks or {}
	for i, b in ipairs(--[[:! { [integer]: { [string]: unknown } }]] raw) do
		books[i] = linked_book_summary(b --[[:! { [string]: unknown }]])
		local e_out = {}
		if type(b.entries) == "table" then
			for _, e in ipairs(--[[:! { [integer]: { [string]: unknown } }]] b.entries) do
				e_out[#e_out + 1] = entry_to_json(e --[[:! { [string]: unknown }]])
			end
		end
		entries_out[i] = e_out
	end
	return json_ok(res, { books = books, entries = entries_out })
end

--: (State, Caps, { [string]: string }, JsonBody | nil, Res) -> boolean
local function api_post_linked_lorebooks_add(state, caps, _params, body, res)
	if not body or not body.name or type(body.name) ~= "string" or body.name == "" then
		return json_err(res, 400, "name required")
	end
	if body.entries ~= nil and type(body.entries) ~= "table" then
		return json_err(res, 400, "entries must be an array")
	end
	local entries_in = (body.entries --[[:! { [integer]: { [string]: unknown } } | nil]]) or {}
	local entries = {}
	for _, raw in ipairs(--[[:! { [integer]: { [string]: unknown } }]] entries_in) do
		entries[#entries + 1] = lorebook_mod.normalize({
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
		})
	end
	local book = {
		name = body.name --[[:! string]],
		source = (type(body.source) == "string" and (body.source --[[:! string]])) or nil,
		entries = entries,
	}
	state.linked_lorebooks = state.linked_lorebooks or {}
	local list = --[[:! { [integer]: unknown }]] state.linked_lorebooks
	list[#list + 1] = book
	flush_card_state(state, caps)
	return json_ok(res, linked_book_summary(book --[[:! { [string]: unknown }]]))
end

--: (State, Caps, { [string]: string }, JsonBody | nil, Res) -> boolean
local function api_post_linked_lorebooks_delete(state, caps, params, body, res)
	local idx_str = (params and params.index) or (body and body.index)
	if idx_str == nil then return json_err(res, 400, "index required") end
	local idx = tonumber(--[[:! number | string]] idx_str)
	if not idx then return json_err(res, 400, "index must be a number") end
	local list = state.linked_lorebooks
	if not list then return json_err(res, 404, "no linked lorebooks") end
	local lua_idx = math.floor(--[[:! number]] idx) + 1  -- 0-indexed → 1-indexed
	local list_t = --[[:! { [integer]: { [string]: unknown } }]] list
	if lua_idx < 1 or lua_idx > #list_t then
		return json_err(res, 404, "index out of range")
	end
	table.remove(list_t, lua_idx)
	flush_card_state(state, caps)
	return json_ok(res, { deleted = true })
end

--: (State, Caps, { [string]: string }, JsonBody | nil, Res) -> boolean
local function api_post_linked_lorebooks_import(state, caps, _params, body, res)
	if not body or type(body.entries) ~= "table" then
		return json_err(res, 400, "entries required")
	end
	local body_name = body.name --[[:! string | nil]]
	local name = (type(body_name) == "string" and #(body_name --[[:! string]]) > 0) and (body_name --[[:! string]]) or "Imported"
	local normalized = {}
	for _, raw in ipairs(body.entries) do
		if type(raw) == "table" then
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
	local source_v = body.source --[[:! string | nil]]
	local book = {
		name = name,
		source = (type(source_v) == "string" and (source_v --[[:! string]])) or nil,
		entries = normalized,
	}
	state.linked_lorebooks = state.linked_lorebooks or {}
	local list = --[[:! { [integer]: unknown }]] state.linked_lorebooks
	list[#list + 1] = book
	flush_card_state(state, caps)
	return json_ok(res, linked_book_summary(book --[[:! { [string]: unknown }]]))
end

-- ── Persona endpoints helpers ──────────────────────────────────────────────

--: (State, Caps) -> nil
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

--: (State, Caps, { [string]: string }, JsonBody | nil, Res) -> boolean
local function api_get_personas(state, _caps, _params, _body, res)
	local result = {}
	for _, p in ipairs(state.personas) do
		result[#result + 1] = { name = p.name, description = p.description }
	end
	return json_ok(res, { personas = result, active = state.active_persona })
end

--: (State, Caps, { [string]: string }, JsonBody | nil, Res) -> boolean
local function api_post_personas_save(state, caps, _params, body, res)
	if not body or not body.name or type(body.name) ~= "string" or body.name == "" then
		return json_err(res, 400, "name required")
	end
	local name = body.name --[[:! string]]
	local description = (body.description --[[:! string | nil]]) or ""
	local existing = find_persona(state.personas, name)
	if existing then
		existing.description = description
	else
		local ps = state.personas --[[:! { [integer]: { description: string, name: string } }]] or {}
		ps[#ps + 1] = { name = name, description = description }
		state.personas = ps
	end
	-- If the active persona was updated, sync user_name.
	if state.active_persona == name then
		state.user_name = name
	end
	save_personas(state, caps)
	return json_ok(res, { name = name, description = description })
end

--: (State, Caps, { [string]: string }, JsonBody | nil, Res) -> boolean
local function api_post_personas_delete(state, caps, _params, body, res)
	if not body or not body.name or type(body.name) ~= "string" then
		return json_err(res, 400, "name required")
	end
	local name = body.name --[[:! string]]
	local _, idx = find_persona(state.personas, name)
	if not idx then return json_err(res, 404, "persona not found") end
	table.remove(state.personas --[[:! Arr<Persona>]], idx)
	-- If we deleted the active persona, switch to first remaining or create Default.
	if state.active_persona == name then
		local ps = state.personas --[[:! { [integer]: { description: string, name: string } }]] or {}
		if #ps == 0 then
			ps[1] = { name = "User", description = "" }
		end
		activate_persona(state, ps[1].name)
		state.personas = ps
	end
	save_personas(state, caps)
	return json_ok(res, { deleted = true, active = state.active_persona })
end

--: (State, Caps, { [string]: string }, JsonBody | nil, Res) -> boolean
local function api_post_personas_activate(state, caps, _params, body, res)
	if not body or not body.name or type(body.name) ~= "string" then
		return json_err(res, 400, "name required")
	end
	local persona, err = activate_persona(state, body.name --[[:! string]])
	if not persona then return json_err(res, 404, err) end
	save_personas(state, caps)
	return json_ok(res, { active = state.active_persona })
end

-- ── Token count endpoint ───────────────────────────────────────────────────

--: (State, Caps, { [string]: string }, JsonBody | nil, Res) -> boolean
local function api_get_token_count(state, caps, _params, _body, res)
	local tc, err = compute_token_count(state, caps)
	if not tc then return json_err(res, 500, err) end
	return json_ok(res, tc)
end

-- ── Settings endpoints ─────────────────────────────────────────────────────

--: (State, Caps, { [string]: string }, JsonBody | nil, Res) -> boolean
local function api_get_settings(state, _caps, _params, _body, res)
	return json_ok(res, state.settings)
end

--: (State, Caps, { [string]: string }, JsonBody | nil, Res) -> boolean
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

--: (CardData) -> { [string]: unknown }
local function card_edit_response(card)
	local data = {}
	for _, key in ipairs(CARD_EDIT_FIELDS) do
		data[key] = card[key] or ""
	end
	data.alternate_greetings = card.alternate_greetings or {}
	data.tags = card.tags or {}
	return data
end

--: (State, Caps, { [string]: string }, JsonBody | nil, Res) -> boolean
local function api_get_card_edit(state, _caps, _params, _body, res)
	if not state.card then return json_err(res, 404, "no card loaded") end
	return json_ok(res, card_edit_response(state.card))
end

--: (State, Caps, { [string]: string }, JsonBody | nil, Res) -> boolean
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

	-- Surface which storage path the edit took so the frontend can show the
	-- user where the card state landed (PNG = self-contained; kv = legacy
	-- per-bucket fallback). Mirrors the flush_card_state branch condition.
	local storage_path = (caps.self_write and caps.self_write.write_metadata) and "png" or "kv"
	local data = card_edit_response(state.card)
	data.storage = storage_path
	return json_ok(res, data)
end

--: (State, Caps, { [string]: string }, JsonBody | nil, Res) -> boolean
local function api_post_card_reset(state, caps, _params, _body, res)
	if not state.card then return json_err(res, 404, "no card loaded") end

	-- Delete legacy kv overrides (post-migration we only need the PNG state,
	-- but older installs may still carry these keys).
	if caps.kv then
		caps.kv.set("card_overrides", nil)
	end

	-- Reload card from PNG data (reset before re-loading).
	-- Use rawset to bypass narrowing — state.card was narrowed to CardData above.
	rawset(state, "card", nil)
	rawset(state, "lorebook", nil)
	load_card(state, caps)

	if not state.card then return json_err(res, 500, "failed to reload card") end
	return json_ok(res, card_edit_response(state.card --[[:! CardData]]))
end

-- ── Preset endpoints ───────────────────────────────────────────────────────
--
-- presets_mod expects a kv with string-returning get/set. KvCap.get returns
-- (unknown | nil, string | nil); the first return is always a string in practice
-- (kv stores JSON strings). The cast below narrows to what presets_mod expects.
--:: PresetsKv = { get: (string) -> (string | nil), set: (string, string | nil) -> nil, ... }

--: (State, Caps, { [string]: string }, JsonBody | nil, Res) -> boolean
local function api_get_presets(_state, caps, _params, _body, res)
	if not caps.kv then return json_err(res, 500, "kv not available") end
	local data = presets_mod.load_all(caps.kv --[[:! PresetsKv]])
	return json_ok(res, data)
end

--: (State, Caps, { [string]: string }, JsonBody | nil, Res) -> boolean
local function api_post_presets_save(_state, caps, _params, body, res)
	if not caps.kv then return json_err(res, 500, "kv not available") end
	if not body or not body.type or not body.preset then
		return json_err(res, 400, "type and preset required")
	end
	local preset = body.preset --[[:! { [string]: unknown }]]
	if not preset.name or type(preset.name) ~= "string" or #(preset.name --[[:! string]]) == 0 then
		return json_err(res, 400, "preset must have a name")
	end
	local ok, err = presets_mod.save(caps.kv --[[:! PresetsKv]], body.type --[[:! string]], preset.name --[[:! string]], preset --[[:! { name: string, ... }]])
	if not ok then return json_err(res, 400, err) end
	return json_ok(res, { ok = true })
end

--: (State, Caps, { [string]: string }, JsonBody | nil, Res) -> boolean
local function api_post_presets_delete(_state, caps, _params, body, res)
	if not caps.kv then return json_err(res, 500, "kv not available") end
	if not body or not body.type or not body.name then
		return json_err(res, 400, "type and name required")
	end
	local ok, err = presets_mod.delete(caps.kv --[[:! PresetsKv]], body.type --[[:! string]], body.name --[[:! string]])
	if not ok then return json_err(res, 400, err) end
	return json_ok(res, { ok = true })
end

--: (State, Caps, { [string]: string }, JsonBody | nil, Res) -> boolean
local function api_post_presets_activate(_state, caps, _params, body, res)
	if not caps.kv then return json_err(res, 500, "kv not available") end
	if not body or not body.type or not body.name then
		return json_err(res, 400, "type and name required")
	end
	local ok, err = presets_mod.set_active(caps.kv --[[:! PresetsKv]], body.type --[[:! string]], body.name --[[:! string]])
	if not ok then return json_err(res, 400, err) end
	return json_ok(res, { ok = true })
end

--: (State, Caps, { [string]: string }, JsonBody | nil, Res) -> boolean
local function api_post_presets_import(_state, caps, _params, body, res)
	if not caps.kv then return json_err(res, 500, "kv not available") end
	if not body or not body.json then
		return json_err(res, 400, "json field required")
	end
	local preset, err = presets_mod.import_preset(body.json --[[:! string]])
	if not preset then return json_err(res, 400, err) end
	return json_ok(res, { preset = preset })
end

--: (State, Caps, { [string]: string }, JsonBody | nil, Res) -> boolean
local function api_post_presets_export(_state, caps, _params, body, res)
	if not caps.kv then return json_err(res, 500, "kv not available") end
	if not body or not body.type or not body.name then
		return json_err(res, 400, "type and name required")
	end
	-- Find the preset.
	local list = presets_mod.load_all(caps.kv --[[:! PresetsKv]])
	local type_key = (body.type --[[:! string]]) .. "s"
	local presets_list = list[type_key]
	if not presets_list then return json_err(res, 404, "no presets for type") end
	local found
	for i = 1, #(--[[:! { [integer]: unknown }]] presets_list) do
		if (--[[:! { [string]: unknown }]] presets_list[i]).name == body.name then
			found = presets_list[i]
			break
		end
	end
	if not found then return json_err(res, 404, "preset not found: " .. (body.name --[[:! string]])) end
	return json_ok(res, { json = presets_mod.export_preset(found) })
end

-- ── Regex script endpoints ─────────────────────────────────────────────────

--: (RegexScript) -> { [string]: unknown }
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

--: (State, Caps, { [string]: string }, JsonBody | nil, Res) -> boolean
local function api_get_regex(state, _caps, _params, _body, res)
	local result = {}
	for _, s in ipairs(state.regex_scripts) do
		result[#result + 1] = regex_script_to_json(s)
	end
	return json_ok(res, { scripts = result })
end

--: (State, Caps, { [string]: string }, JsonBody | nil, Res) -> boolean
local function api_post_regex_save(state, caps, _params, body, res)
	if not body or not body.name or type(body.name) ~= "string" or body.name == "" then
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
	local found_raw
	for _, s in ipairs(state.regex_scripts) do
		if s.name == (body.name --[[:! string]]) then found_raw = s; break end
	end
	local found --[[:! RegexScript]]
	if found_raw then
		found = found_raw
		found.find = body.find --[[:! string]]
		found.replace = (body.replace --[[:! string | nil]]) or ""
		if body.enabled ~= nil then found.enabled = body.enabled and true or false end
		if body.scope ~= nil then found.scope = body.scope --[[:! string]] end
		if body.order ~= nil then found.order = tonumber(body.order) or 0 end
	else
		found = {
			name = body.name --[[:! string]],
			find = body.find --[[:! string]],
			replace = (body.replace --[[:! string | nil]]) or "",
			enabled = body.enabled ~= false,
			scope = (body.scope --[[:! string | nil]]) or "ai_output",
			order = (tonumber(body.order) or 0) --[[:! integer | nil]],
		} --[[:! RegexScript]]
		state.regex_scripts[#state.regex_scripts + 1] = found
	end
	save_regex_scripts(state, caps)
	return json_ok(res, regex_script_to_json(found))
end

--: (State, Caps, { [string]: string }, JsonBody | nil, Res) -> boolean
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

--: (State, Caps, { [string]: string }, JsonBody | nil, Res) -> boolean
local function api_post_regex_test(_state, _caps, _params, body, res)
	if not body or not body.find or not body.input then
		return json_err(res, 400, "find and input required")
	end
	local ok_pat, pat_err = pcall(string.find, "", body.find)
	if not ok_pat then
		return json_err(res, 400, "invalid pattern: " .. tostring(pat_err))
	end
	local replace = (body.replace --[[:! string | nil]]) or ""
	local ok_gsub, output = pcall(string.gsub, body.input --[[:! string]], body.find --[[:! string]], replace)
	if not ok_gsub then
		return json_err(res, 400, "gsub error: " .. tostring(output))
	end
	return json_ok(res, { output = output })
end


-- ── Author's Note endpoints ───────────────────────────────────────────────

local function save_authors_note(state, caps)
	flush_card_state(state, caps)
end

--: (State, Caps, { [string]: string }, JsonBody | nil, Res) -> boolean
local function api_get_authors_note(state, _caps, _params, _body, res)
	return json_ok(res, state.authors_note)
end

--: (State, Caps, { [string]: string }, JsonBody | nil, Res) -> boolean
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

--: (State, Caps, { [string]: string }, JsonBody | nil, Res) -> boolean
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

--: (State, Caps, { [string]: string }, JsonBody | nil, Res) -> boolean
local function api_post_instruct_save(state, caps, _params, body, res)
	if not body or not body.name or type(body.name) ~= "string" or body.name == "" then
		return json_err(res, 400, "name required")
	end
	local t_name = body.name --[[:! string]]
	local template = {} --[[:! { [string]: unknown }]]
	for _, key in ipairs(INSTRUCT_FIELDS) do
		template[key] = (body[key] ~= nil and body[key] or "") --[[:! unknown]]
	end
	template.name = t_name
	template.mode = (body.mode == "instruct" and "instruct" or "chat") --[[:! unknown]]
	template.stop_strings = (body.stop_strings --[[:! unknown]]) or {}
	-- Ensure stop_strings is a table.
	if type(template.stop_strings) ~= "table" then template.stop_strings = {} --[[:! unknown]] end

	local existing, idx = find_instruct_template(state.instruct_templates, t_name)
	if existing then
		state.instruct_templates[idx --[[:! integer]]] = template --[[:! InstructTemplate]]
	else
		state.instruct_templates[#state.instruct_templates + 1] = template --[[:! InstructTemplate]]
	end
	save_instruct(state, caps)
	return json_ok(res, template)
end

--: (State, Caps, { [string]: string }, JsonBody | nil, Res) -> boolean
local function api_post_instruct_delete(state, caps, _params, body, res)
	if not body or not body.name or type(body.name) ~= "string" then
		return json_err(res, 400, "name required")
	end
	local del_name = body.name --[[:! string]]
	local _, idx = find_instruct_template(state.instruct_templates, del_name)
	if not idx then return json_err(res, 404, "template not found") end
	table.remove(state.instruct_templates, idx)
	-- If we deleted the active template, clear active.
	if state.instruct_active == del_name then
		state.instruct_active = nil
	end
	save_instruct(state, caps)
	return json_ok(res, { deleted = true, active = state.instruct_active or "" })
end

--: (State, Caps, { [string]: string }, JsonBody | nil, Res) -> boolean
local function api_post_instruct_activate(state, caps, _params, body, res)
	if not body or not body.name or type(body.name) ~= "string" then
		return json_err(res, 400, "name required")
	end
	local act_name = body.name --[[:! string]]
	-- Empty name clears active template (reverts to chat mode).
	if act_name == "" then
		state.instruct_active = nil
		save_instruct(state, caps)
		return json_ok(res, { active = "" })
	else
		local template = find_instruct_template(state.instruct_templates, act_name)
		if not template then return json_err(res, 404, "template not found") end
		state.instruct_active = act_name
		save_instruct(state, caps)
		return json_ok(res, { active = state.instruct_active })
	end
end

-- ── Chat export endpoint ──────────────────────────────────────────────────

--: (State, Caps, { [string]: string }, JsonBody | nil, Res) -> boolean
local function api_get_export_chat(state, caps, params, _body, res)
	local path, err = get_canonical_path(state)
	if not path then return json_err(res, 500, err) end

	local card_name = tostring(state.card and state.card.name or "Chat")
	local now = (caps.time and (caps.time.now()) or os.time()) --[[:! integer]]
	local date_str = --[[:! string]] os.date("!%Y-%m-%d", now)
	local format = params.format or "text"

	if format == "json" then
		local messages = {}
		for _, msg in ipairs(path) do
			messages[#messages + 1] = { role = msg.role, content = msg.content }
		end
		local data = {
			card_name = card_name,
			messages = messages,
			exported_at = --[[:! string]] os.date("!%Y-%m-%dT%H:%M:%SZ", now),
		}
		res.status = 200
		res.headers["Content-Type"] = "application/json"
		res.headers["Content-Disposition"] = 'attachment; filename="chat_' .. card_name .. '_' .. date_str .. '.json"'
		local enc = json.encode(data)
		res.body = enc
		return true
	else
		-- Plain text format.
		local lines = {}
		lines[#lines + 1] = "# Conversation with " .. card_name
		lines[#lines + 1] = "# Exported " .. date_str
		lines[#lines + 1] = ""
		for _, msg in ipairs(--[[:! ConvRow[] ]] path) do
			local sender --[[: string]]
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

--: (State, Caps, { [string]: string }, JsonBody | nil, Res) -> boolean
local function api_post_connection_test(state, caps, params, body, res)
	if not caps.llm or not caps.llm.call then
		return json_ok(res, { success = false, error = "no LLM capability configured" })
	end
	local test_messages = {{ role = "user", content = "Hello" }}
	local t0 = os.clock()
	local response, err = caps.llm.call(test_messages, { max_tokens = 10 } --[[:! LlmCallOpts]])
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

-- api_post_new_card: build a blank CCv2 PNG. If the `create_instance` cap is
-- available, use it to install the PNG as a new app instance and return
-- { launch_url } so the frontend can redirect into the new card. Otherwise
-- fall back to a file download (the user re-imports it manually).
--: (State, Caps, { [string]: string }, JsonBody | nil, Res) -> boolean
local function api_post_new_card(_state, caps, _params, _body, res)
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

	-- Preferred path: use the create_instance cap to install the new card as
	-- a fresh app and hand the frontend a launch URL. Avoids the cross-origin
	-- problem of trying to POST /api/apps directly from the app subdomain.
	local caps_t = caps --[[:! { create_instance: { create: (string) -> (integer | nil, string) } | nil, ... }]]
	local ci = caps_t.create_instance
	if ci then
		local create_fn = ci.create
		local new_id, launch_or_err = create_fn(png_bytes)
		if new_id then
			return json_ok(res, { launch_url = launch_or_err })
		end
		-- Fall through to download on cap failure.
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
	-- Card-vendored linked lorebooks (live under extensions.linked_lorebooks).
	["GET /api/linked_lorebooks"]              = api_get_linked_lorebooks,
	["POST /api/linked_lorebooks"]             = api_post_linked_lorebooks_add,
	["POST /api/linked_lorebooks/delete"]      = api_post_linked_lorebooks_delete,
	["POST /api/linked_lorebooks/import"]      = api_post_linked_lorebooks_import,
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

--: (Caps, CreateOpts | nil) -> { handler: (Req, Res) -> unknown, state: State }
function M.create(caps, opts)
	opts = opts or {}
	-- Seed RNG for UUID generation. Use time cap if available.
	local time_fn = caps.time and (caps.time.now --[[:! () -> integer]]) or nil
	local big = math.floor(2^31)
	local seed = math.floor(time_fn and (time_fn() * 1000 + math.random(999)) or math.random(big))
	math.randomseed(--[[:! integer]] seed)
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
			local ok, saved = pcall(json.decode, raw --[[:! string]])
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
			local ok, overrides = pcall(json.decode, raw --[[:! string]])
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
			local ok, saved = pcall(json.decode, raw --[[:! string]])
			if ok and type(saved) == "table" then
				state.lorebook = saved
			end
		end
	end

	-- Load user_lorebooks from kv.
	if caps.kv then
		local raw = caps.kv.get("user_lorebooks")
		if raw then
			local ok, saved = pcall(json.decode, raw --[[:! string]])
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
				local ok_l, parsed = pcall(json.decode, legacy --[[:! string]])
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
			local ok_p, saved = pcall(json.decode, raw --[[:! string]])
			if ok_p and type(saved) == "table" and #(--[[:! { [integer]: unknown }]] saved) > 0 then
				state.personas = saved
			end
		end
		local active = caps.kv.get("personas:active")
		if active and active ~= "" then
			local p = find_persona(state.personas, active --[[:! string | nil]])
			if p then
				state.active_persona = active --[[:! string]]
				state.user_name = p.name
			end
		end
	end

	-- Load regex scripts from kv.
	if caps.kv then
		local raw = caps.kv.get("regex_scripts")
		if raw then
			local ok_r, saved = pcall(json.decode, raw --[[:! string]])
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
			local ok_it, saved = pcall(json.decode, raw --[[:! string]])
			if ok_it and type(saved) == "table" and #(--[[:! { [integer]: unknown }]] saved) > 0 then
				state.instruct_templates = saved
			end
		end
		local active = caps.kv.get("instruct_active")
		if type(active) == "string" then
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
			local ok_an, saved = pcall(json.decode, raw --[[:! string]])
			if ok_an and type(saved) == "table" then
				local s = --[[:! { [string]: unknown }]] saved
				if s.text ~= nil then state.authors_note.text = s.text --[[:! string]] end
				if s.depth ~= nil then state.authors_note.depth = s.depth --[[:! integer]] end
				if s.position ~= nil then state.authors_note.position = s.position --[[:! string]] end
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
	-- time_fn: () -> integer. Wraps caps.time.now (extracts first return) or os.time.
	--: () -> integer
	local time_fn = function() return os.time() end
	do
		local _time_cap = caps.time
		if _time_cap then
			--: () -> integer
			time_fn = function()
				local t = _time_cap.now()
				return t or 0
			end
		end
	end
	state._time_fn = time_fn
	local conv_db
	if caps.conversations then
		-- shared_db cap: set up schema (idempotent) and use raw SQL helpers.
		-- setup is a platform-internal method not in the cap_types spec.
		local setup_fn = caps.conversations.setup --[[:! (unknown) -> nil]]
		setup_fn(CONV_SCHEMA)
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
		local session = conv_get_session(conv_db --[[:! ConvDb]], session_id)
		if session then
			state.session_id = session_id
		end
	end
	if not state.session_id or state.session_id == "" then
		local session, serr = conv_create_session(conv_db --[[:! ConvDb]], time_fn)
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
			local ok_g, saved = pcall(json.decode, raw --[[:! string]])
			if ok_g and type(saved) == "table" then
				local sg = --[[:! { [string]: unknown }]] saved
				state.group.enabled = sg.enabled --[[:! boolean]] or false
				state.group.turn_order = sg.turn_order --[[:! string]] or "round_robin"
				state.group.next_speaker = sg.next_speaker --[[:! integer]] or 1
				if sg.members then
					for i, sm in ipairs(--[[:! { [integer]: { [string]: unknown } }]] sg.members) do
						if sm.is_primary then
							-- Primary member already initialized from card.
						elseif sm.card_json then
							local cdata = card_mod.from_json(sm.card_json --[[:! string]])
							if cdata then
								state.group.members[#state.group.members + 1] = {
									card = cdata,
									name = sm.name --[[:! string]],
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
	local path3 = get_canonical_path(state)
	if not path3 then
		init_greeting(state)
	else
		local p3 = path3 --[[:! ConvRow[] ]]
		if #p3 == 0 then init_greeting(state) end
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

	--: (Req, Res) -> unknown
	local function handler(req, res)
		local req_path, params = parse_target(req.target or req.path or "/")
		local key = req.method .. " " .. req_path
		local route = routes[key]
		if route then
			local req_body = read_json_body(req)
			return route(state, caps, params, req_body, res)
		end
		-- Static files via caps.self tarball entries.
		local entry_fn = --[[:! ((string) -> string | nil) | nil]] (caps.self and caps.self.entry)
		if serve_static and entry_fn then
			local entry_path = "static" .. req_path
			if req_path == "/" then entry_path = "static/index.html" end
			local content = entry_fn(entry_path)
			if content then
				local ext = (--[[:! string]] entry_path):match("%.([^%.]+)$")
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
