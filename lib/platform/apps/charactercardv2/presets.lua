-- lib/platform/apps/charactercardv2/presets.lua
-- Preset management for the card app.
--
-- Manages connection, generation, and prompt presets via caps.kv.
-- Presets are stored as JSON arrays keyed by type. An "active" preset
-- is tracked per type via a separate kv key.
--
-- Storage keys:
--   presets:connection       -> JSON array of connection presets
--   presets:generation       -> JSON array of generation presets
--   presets:prompt           -> JSON array of prompt presets
--   presets:active:connection -> name of active connection preset
--   presets:active:generation -> name of active generation preset
--   presets:active:prompt     -> name of active prompt preset

if package and not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local json = require("lib.format.json")

local M = {}

-- ── Preset type validation ─────────────────────────────────────────────────

local VALID_TYPES = { connection = true, generation = true, prompt = true }

local function validate_type(ptype)
	if not ptype or not VALID_TYPES[ptype] then
		return nil, "invalid preset type: " .. tostring(ptype)
	end
	return true
end

-- ── KV helpers ─────────────────────────────────────────────────────────────

local function list_key(ptype)
	return "presets:" .. ptype
end

local function active_key(ptype)
	return "presets:active:" .. ptype
end

local function load_list(kv, ptype)
	local raw = kv.get(list_key(ptype))
	if not raw then return {} end
	local ok, val = pcall(json.decode, raw)
	if not ok or type(val) ~= "table" then return {} end
	return val
end

local function save_list(kv, ptype, list)
	local encoded = json.encode(list)
	kv.set(list_key(ptype), encoded)
end

-- ── Default presets ────────────────────────────────────────────────────────

local DEFAULT_CONNECTIONS = {
	{
		name = "Local (localhost:5001)",
		endpoint = "http://localhost:5001",
		model = "default",
		api_key = "",
		path = "/v1/chat/completions",
	},
	{
		name = "OpenAI-compatible",
		endpoint = "http://localhost:8000",
		model = "default",
		api_key = "",
		path = "/v1/chat/completions",
	},
}

local DEFAULT_GENERATIONS = {
	{
		name = "Balanced",
		temperature = 0.7,
		top_p = 1.0,
		top_k = 0,
		max_tokens = 512,
		frequency_penalty = 0.0,
		presence_penalty = 0.0,
		repetition_penalty = 1.0,
	},
	{
		name = "Creative",
		temperature = 1.2,
		top_p = 0.9,
		top_k = 40,
		max_tokens = 800,
		frequency_penalty = 0.3,
		presence_penalty = 0.3,
		repetition_penalty = 1.1,
	},
	{
		name = "Precise",
		temperature = 0.3,
		top_p = 0.95,
		top_k = 0,
		max_tokens = 512,
		frequency_penalty = 0.0,
		presence_penalty = 0.0,
		repetition_penalty = 1.0,
	},
}

local DEFAULT_PROMPTS = {
	{
		name = "Default",
		system_prompt = "Write {{char}}'s next reply in a fictional chat between {{char}} and {{user}}.",
		context_order = {
			"system_prompt", "lorebook_before", "persona", "description",
			"personality", "scenario", "lorebook_after", "examples",
			"history", "post_history",
		},
		post_history_instructions = "",
	},
}

--: () -> { connections: { ... }[], generations: { ... }[], prompts: { ... }[] }
function M.get_defaults()
	-- Deep copy defaults so callers can't mutate them.
	--: (any) -> any
	local function copy_list(src)
		local out = {}
		for i = 1, #src do
			local item = {}
			for k, v in pairs(src[i]) do
				if type(v) == "table" then
					local t = {}
					for j = 1, #v do t[j] = v[j] end
					item[k] = t
				else
					item[k] = v
				end
			end
			out[i] = item
		end
		return out
	end
	return {
		connections = copy_list(DEFAULT_CONNECTIONS),
		generations = copy_list(DEFAULT_GENERATIONS),
		prompts = copy_list(DEFAULT_PROMPTS),
	}
end

-- ── CRUD ───────────────────────────────────────────────────────────────────

--- Load all presets for all types.
--- If a type has no stored presets, returns the defaults.
--: ({ get: (string) -> (string | nil), set: (string, string | nil) -> nil, ... }) -> { connections: { ... }[], generations: { ... }[], prompts: { ... }[], active: { connection: (string | nil), generation: (string | nil), prompt: (string | nil) } }
function M.load_all(kv)
	local result = {}
	for ptype in pairs(VALID_TYPES) do
		local list = load_list(kv, ptype)
		if #list == 0 then
			local defaults = M.get_defaults()
			list = defaults[ptype .. "s"]
		end
		result[ptype .. "s"] = list
	end
	result.active = {
		connection = kv.get(active_key("connection")),
		generation = kv.get(active_key("generation")),
		prompt = kv.get(active_key("prompt")),
	}
	return result
end

--- Save or update a preset. If a preset with the same name exists, it is replaced.
--: ({ get: (string) -> (string | nil), set: (string, string | nil) -> nil, ... }, string, string, { name: string, ... }) -> (boolean | nil, string | nil)
function M.save(kv, ptype, name, preset)
	local ok, err = validate_type(ptype)
	if not ok then return nil, err end
	if not name or type(name) ~= "string" or #name == 0 then
		return nil, "preset name required"
	end
	if not preset or type(preset) ~= "table" then
		return nil, "preset data required"
	end

	preset.name = name
	local list = load_list(kv, ptype)

	-- Replace existing or append.
	local found = false
	for i = 1, #list do
		if list[i].name == name then
			list[i] = preset
			found = true
			break
		end
	end
	if not found then
		list[#list + 1] = preset
	end

	save_list(kv, ptype, list)
	return true
end

--- Delete a preset by name.
--: ({ get: (string) -> (string | nil), set: (string, string | nil) -> nil, ... }, string, string) -> (boolean | nil, string | nil)
function M.delete(kv, ptype, name)
	local ok, err = validate_type(ptype)
	if not ok then return nil, err end
	if not name or type(name) ~= "string" or #name == 0 then
		return nil, "preset name required"
	end

	local list = load_list(kv, ptype)
	local new_list = {}
	local found = false
	for i = 1, #list do
		if list[i].name == name then
			found = true
		else
			new_list[#new_list + 1] = list[i]
		end
	end

	if not found then return nil, "preset not found: " .. name end

	save_list(kv, ptype, new_list)

	-- If the deleted preset was active, clear active.
	local current_active = kv.get(active_key(ptype))
	if current_active == name then
		kv.set(active_key(ptype), nil)
	end

	return true
end

--- Get the active preset for a type.
--: ({ get: (string) -> (string | nil), set: (string, string | nil) -> nil, ... }, string) -> { name: string, ... } | nil
function M.get_active(kv, ptype)
	local ok, err = validate_type(ptype)
	if not ok then return nil end

	local name = kv.get(active_key(ptype))
	if not name then return nil end

	local list = load_list(kv, ptype)
	for i = 1, #list do
		if list[i].name == name then return list[i] end
	end

	-- Active name set but preset not found — check defaults.
	local defaults = M.get_defaults()
	local default_list = defaults[ptype .. "s"] --[[:! { [integer]: { name: string, ... } }]]
	for i = 1, #default_list do
		if default_list[i].name == name then return default_list[i] end
	end

	return nil
end

--- Set the active preset by name.
--: ({ get: (string) -> (string | nil), set: (string, string | nil) -> nil, ... }, string, string) -> (boolean | nil, string | nil)
function M.set_active(kv, ptype, name)
	local ok, err = validate_type(ptype)
	if not ok then return nil, err end
	if not name or type(name) ~= "string" or #name == 0 then
		return nil, "preset name required"
	end

	-- Verify the preset exists (in stored list or defaults).
	local list = load_list(kv, ptype)
	local found = false
	for i = 1, #list do
		if list[i].name == name then found = true; break end
	end
	if not found then
		-- Check defaults.
		local defaults = M.get_defaults()
		local default_list = defaults[ptype .. "s"] --[[:! { [integer]: { name: string, ... } }]]
		for i = 1, #default_list do
			if default_list[i].name == name then found = true; break end
		end
	end
	if not found then return nil, "preset not found: " .. name end

	kv.set(active_key(ptype), name)
	return true
end

-- ── Import / Export ────────────────────────────────────────────────────────

--- Export a preset to a JSON string.
--: ({ name: string, ... }) -> string
function M.export_preset(preset)
	local s = json.encode(preset)
	return s --[[:! string]]
end

--- Import a preset from a JSON string.
--: (string) -> ({ name: string, ... } | nil, string)
function M.import_preset(json_string)
	if not json_string or type(json_string) ~= "string" or #json_string == 0 then
		return nil, "empty input"
	end
	local ok, val = pcall(json.decode, json_string)
	if not ok then return nil, "invalid JSON: " .. tostring(val) end
	if type(val) ~= "table" then return nil, "preset must be a JSON object" end
	if not val.name or type(val.name) ~= "string" or #val.name == 0 then
		return nil, "preset must have a name"
	end
	return val
end

return M
