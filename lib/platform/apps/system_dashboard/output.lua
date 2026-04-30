-- lib/platform/apps/system_dashboard/output.lua
-- Pack output envelope schema.
--
-- This module is the data contract between pack actions (Lua, in-process) and
-- the dashboard frontend (web, generic). Pack actions return a single envelope
-- whose `body` field is a primitive (often a composite). The frontend chooses
-- how to render. No rendering happens here.
--
-- See `docs/system_dashboard_primitives.md` for the catalogue and worked
-- examples; this file is the executable form of that doc.
--
-- Public surface:
--   M.<primitive>(...)       -> primitive constructor (e.g. M.text, M.code, ...)
--   M.cite_<kind>(...)       -> cite-channel constructors (registry, http, ...)
--   M.ok(body, opts?)        -> ok envelope { ok=true, body=..., cite?, stream?, ttl_ms? }
--   M.err(error, body?)      -> err envelope { ok=false, error=..., body? }
--   M.validate(envelope)     -> true | nil, errmsg
--   M.PRIMITIVES             -> { [name]=true } set of known primitive types
--   M.CITE_KINDS             -> { [name]=true } set of known cite kinds

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

-- ── Type declarations ─────────────────────────────────────────────────────────
--
-- The discriminated-union types (`Primitive`, `Cite`, `Envelope`, and all
-- their constituents) live in `primitive_types.lua` and are loaded by callers
-- via `opts.globals_files` (see `lib/platform/apps/system_dashboard/projections/`
-- for an example). They are kept out of this file so projection authors and
-- other consumers can reference them without re-declaring or coupling to
-- output.lua's runtime constructors. The catalogue is documented in
-- `docs/system_dashboard_primitives.md`; the executable type-level form is
-- `primitive_types.lua` — keep them in sync.

-- ── Known sets ────────────────────────────────────────────────────────────────

local PRIMITIVES = {
	-- atomic
	text = true, code = true, markdown = true, status_badge = true,
	link = true, icon = true, kbd = true,
	-- numeric / scalar
	single_stat = true, gauge = true, progress_bar = true, sparkline = true,
	-- tabular
	table = true, key_value = true, list = true,
	-- time-series
	line_chart = true, bar_chart = true, area_chart = true, heatmap = true,
	top_list = true,
	-- composite
	card = true, grid = true, panel = true, tabs = true, split = true,
	-- streaming
	log_stream = true, live_table = true, event_stream = true,
	-- hierarchical
	tree = true, json_view = true, diff = true,
	-- action
	button = true, form = true, confirm = true, action_menu = true,
}
M.PRIMITIVES = PRIMITIVES

local CITE_KINDS = {
	registry     = true,
	registry_key = true,
	http         = true,
	url          = true,
	file         = true,
	command      = true,
	exec         = true,
	db           = true,
	env          = true,
	text         = true,
}
M.CITE_KINDS = CITE_KINDS

local TEXT_STYLES   = { muted = true, strong = true, error = true, success = true }
local BADGE_STATES  = { ok = true, warn = true, error = true, unknown = true, info = true }
local COLUMN_TYPES  = { string = true, number = true, bytes = true, duration = true,
	timestamp = true, status = true, code = true, link = true }
local FIELD_TYPES   = { text = true, password = true, number = true, bool = true,
	select = true, multiselect = true, path = true, host = true }
local BUTTON_STYLES = { primary = true, danger = true }
local SPLIT_DIRS    = { row = true, col = true }

-- ── Constructors ──────────────────────────────────────────────────────────────
--
-- These are typed loosely (parameters as `unknown`) — the real contract is the
-- `--::` declarations above and `M.validate` below. Constructors are just
-- ergonomic sugar so packs don't write `{ type = "...", ... }` literals.
-- Each returns the envelope/primitive table; the validator is what packs
-- (and the dispatcher) call to confirm shape.

-- Atomic
function M.text(s, style)
	return { type = "text", text = s, style = style }
end

function M.code(text, lang)
	return { type = "code", text = text, lang = lang }
end

function M.markdown(s)
	return { type = "markdown", text = s }
end

function M.status_badge(label, state)
	return { type = "status_badge", label = label, state = state }
end

function M.link(href, label)
	return { type = "link", href = href, label = label }
end

function M.icon(name, tone)
	return { type = "icon", name = name, tone = tone }
end

function M.kbd(keys)
	return { type = "kbd", keys = keys }
end

-- Numeric / scalar
function M.single_stat(opts)
	local o = opts --: any
	return {
		type  = "single_stat",
		value = o.value,
		unit  = o.unit,
		label = o.label,
		delta = o.delta,
		state = o.state,
	}
end

function M.gauge(opts)
	local o = opts --: any
	return {
		type       = "gauge",
		value      = o.value,
		min        = o.min,
		max        = o.max,
		unit       = o.unit,
		thresholds = o.thresholds,
	}
end

function M.progress_bar(opts)
	local o = opts --: any
	return {
		type          = "progress_bar",
		value         = o.value,
		max           = o.max,
		label         = o.label,
		indeterminate = o.indeterminate,
	}
end

function M.sparkline(points, unit)
	return { type = "sparkline", points = points, unit = unit }
end

-- Tabular
function M.table(opts)
	local o = opts --: any
	return {
		type         = "table",
		columns      = o.columns,
		rows         = o.rows,
		default_sort = o.default_sort,
		row_actions  = o.row_actions,
	}
end

function M.key_value(pairs_)
	local pl = pairs_ --: any
	if pl.pairs ~= nil then
		return { type = "key_value", pairs = pl.pairs }
	end
	return { type = "key_value", pairs = pairs_ }
end

function M.list(items)
	return { type = "list", items = items }
end

-- Time-series
function M.line_chart(opts)
	local o = opts --: any
	return {
		type   = "line_chart",
		series = o.series,
		unit   = o.unit,
		y_min  = o.y_min,
		y_max  = o.y_max,
	}
end

function M.bar_chart(opts)
	local o = opts --: any
	return { type = "bar_chart", series = o.series, unit = o.unit, stacked = o.stacked }
end

function M.area_chart(opts)
	local o = opts --: any
	return { type = "area_chart", series = o.series, unit = o.unit, stacked = o.stacked }
end

function M.heatmap(opts)
	local o = opts --: any
	return {
		type   = "heatmap",
		x_bins = o.x_bins,
		y_bins = o.y_bins,
		values = o.values,
	}
end

function M.top_list(opts)
	local o = opts --: any
	return { type = "top_list", items = o.items, max = o.max }
end

-- Composite
function M.card(opts)
	local o = opts --: any
	return {
		type     = "card",
		title    = o.title,
		subtitle = o.subtitle,
		body     = o.body,
		footer   = o.footer,
	}
end

function M.grid(opts)
	local o = opts --: any
	return { type = "grid", cells = o.cells, columns = o.columns }
end

function M.panel(opts)
	local o = opts --: any
	return { type = "panel", title = o.title, body = o.body, actions = o.actions }
end

function M.tabs(tabs_)
	return { type = "tabs", tabs = tabs_ }
end

function M.split(direction, parts)
	return { type = "split", direction = direction, parts = parts }
end

-- Streaming
function M.log_stream(columns)
	return { type = "log_stream", frame_type = "log", columns = columns }
end

function M.live_table(opts)
	local o = opts --: any
	return {
		type        = "live_table",
		frame_type  = "table",
		columns     = o.columns,
		key         = o.key,
		row_actions = o.row_actions,
	}
end

function M.event_stream()
	return { type = "event_stream", frame_type = "event" }
end

-- Hierarchical
function M.tree(root)
	return { type = "tree", root = root }
end

function M.json_view(value, expand_depth)
	return { type = "json_view", value = value, expand_depth = expand_depth }
end

function M.diff(before, after, lang)
	return { type = "diff", before = before, after = after, lang = lang }
end

-- Action
function M.button(opts)
	local o = opts --: any
	return {
		type    = "button",
		label   = o.label,
		alias   = o.alias,
		args    = o.args,
		confirm = o.confirm,
		style   = o.style,
	}
end

function M.form(opts)
	local o = opts --: any
	return {
		type         = "form",
		fields       = o.fields,
		submit_alias = o.submit_alias,
		submit_label = o.submit_label,
	}
end

function M.confirm(opts)
	local o = opts --: any
	return {
		type   = "confirm",
		prompt = o.prompt,
		alias  = o.alias,
		args   = o.args,
		danger = o.danger,
	}
end

function M.action_menu(items)
	return { type = "action_menu", items = items }
end

-- ── Cite constructors ─────────────────────────────────────────────────────────

function M.cite_registry(path, value)
	return { kind = "registry", path = path, value = value }
end

function M.cite_registry_key(path)
	return { kind = "registry_key", path = path }
end

function M.cite_http(method, url)
	return { kind = "http", method = method, url = url }
end

function M.cite_url(href)
	return { kind = "url", href = href }
end

function M.cite_file(path)
	return { kind = "file", path = path }
end

function M.cite_command(argv)
	return { kind = "command", argv = argv }
end

function M.cite_exec(argv)
	return { kind = "exec", argv = argv }
end

function M.cite_db(query)
	return { kind = "db", query = query }
end

function M.cite_env(name)
	return { kind = "env", name = name }
end

function M.cite_text(text)
	return { kind = "text", text = text }
end

-- ── Envelope constructors ────────────────────────────────────────────────────

function M.ok(body, opts)
	local env = { ok = true, body = body, cite = nil, stream = nil, ttl_ms = nil }
	if opts then
		local o = opts --: any
		if o.cite    ~= nil then env.cite    = o.cite end
		if o.stream  ~= nil then env.stream  = o.stream end
		if o.ttl_ms  ~= nil then env.ttl_ms  = o.ttl_ms end
	end
	return env
end

function M.err(error_msg, body)
	return { ok = false, error = error_msg, body = body }
end

-- ── Validation ────────────────────────────────────────────────────────────────
--
-- validate(envelope) -> true | nil, errmsg
-- Walks the envelope, checking:
--   - top-level shape (ok bool, ok→body present, err→error string)
--   - body.type is a known primitive
--   - per-primitive required fields
--   - cite (if present) is an array of entries with recognized kinds
--
-- Validation is a *structural* check on what packs return. It does not check
-- that, e.g., button.alias points at a real alias — that is the dispatcher's
-- job. The error message names the primitive and the missing or invalid field.

local validate_primitive

-- Spec table: primitive name -> {
--   required = { field_name = type_or_check, ... },
--   recurse  = { field_name = "primitive" | "primitive_list" | "tab_list", ... },
-- }
-- The `required` field accepts a string ("string"/"number"/"table"/"boolean")
-- or "array" (table with integer indices) or "any" (just non-nil).
local PSPEC = {
	text         = { required = { text = "string" } },
	code         = { required = { text = "string" } },
	markdown     = { required = { text = "string" } },
	status_badge = { required = { label = "string", state = "badge_state" } },
	link         = { required = { href = "string" } },
	icon         = { required = { name = "string" } },
	kbd          = { required = { keys = "array" } },

	single_stat  = { required = { value = "any" } },
	gauge        = { required = { value = "number", min = "number", max = "number" } },
	progress_bar = { required = { value = "number", max = "number" } },
	sparkline    = { required = { points = "array" } },

	table = {
		required = { columns = "array", rows = "array" },
		check_columns = true,
	},
	key_value = {
		required = { pairs = "array" },
		check_kv_pairs = true,
	},
	list = { required = { items = "array" } },

	line_chart = { required = { series = "array" } },
	bar_chart  = { required = { series = "array" } },
	area_chart = { required = { series = "array" } },
	heatmap    = { required = { x_bins = "number", y_bins = "number", values = "array" } },
	top_list   = { required = { items = "array" } },

	card  = { required = { body  = "primitive" }, recurse = { body = "primitive", footer = "primitive_opt" } },
	grid  = { required = { cells = "array" },     recurse = { cells = "primitive_list" } },
	panel = { required = { title = "string", body = "primitive" }, recurse = { body = "primitive" } },
	tabs  = { required = { tabs  = "array" },     recurse = { tabs = "tab_list" } },
	split = { required = { direction = "split_dir", parts = "array" }, recurse = { parts = "primitive_list" } },

	log_stream   = { required = { frame_type = "frame_log" } },
	live_table   = { required = { frame_type = "frame_table", columns = "array", key = "string" }, check_columns = true },
	event_stream = { required = { frame_type = "frame_event" } },

	tree      = { required = { root = "table" } },
	json_view = { required = { value = "any" } },
	diff      = { required = { before = "string", after = "string" } },

	button      = { required = { label = "string", alias = "string" } },
	form        = { required = { fields = "array", submit_alias = "string" }, check_form_fields = true },
	confirm     = { required = { prompt = "string", alias = "string" } },
	action_menu = { required = { items = "array" } },
}

-- Type check helpers
local function is_array(v)
	if type(v) ~= "table" then return false end
	-- Permit empty tables; pack-emitted arrays are typically dense, but an
	-- empty "no rows" array must validate.
	return true
end

local function check_field(prim_name_a, field_a, val, expected_a)
	local prim_name = tostring(prim_name_a)
	local field     = tostring(field_a)
	local expected  = tostring(expected_a)
	if expected == "any" then
		if val == nil then return nil, prim_name .. ": missing field '" .. field .. "'" end
		return true
	end
	if expected == "string" or expected == "number" or expected == "boolean" or expected == "table" then
		if type(val) ~= expected then
			return nil, prim_name .. ": field '" .. field .. "' must be " .. expected
				.. " (got " .. type(val) .. ")"
		end
		return true
	end
	if expected == "array" then
		if not is_array(val) then
			return nil, prim_name .. ": field '" .. field .. "' must be an array"
		end
		return true
	end
	if expected == "primitive" then
		return validate_primitive(val, prim_name .. "." .. field)
	end
	if expected == "badge_state" then
		if type(val) ~= "string" then
			return nil, prim_name .. ": field '" .. field .. "' must be a badge state"
		end
		local s = val --: string
		if not BADGE_STATES[s] then
			return nil, prim_name .. ": field '" .. field .. "' must be a badge state"
		end
		return true
	end
	if expected == "split_dir" then
		if type(val) ~= "string" then
			return nil, prim_name .. ": field '" .. field .. "' must be 'row' or 'col'"
		end
		local s = val --: string
		if not SPLIT_DIRS[s] then
			return nil, prim_name .. ": field '" .. field .. "' must be 'row' or 'col'"
		end
		return true
	end
	if expected == "frame_log" then
		if val ~= "log" then return nil, prim_name .. ": frame_type must be 'log'" end
		return true
	end
	if expected == "frame_table" then
		if val ~= "table" then return nil, prim_name .. ": frame_type must be 'table'" end
		return true
	end
	if expected == "frame_event" then
		if val ~= "event" then return nil, prim_name .. ": frame_type must be 'event'" end
		return true
	end
	return nil, prim_name .. ": unknown field check '" .. expected .. "'"
end

local function check_columns(prim_name_a, columns)
	local prim_name = tostring(prim_name_a)
	local cols = columns --: any
	for i, col in ipairs(cols) do
		if type(col) ~= "table" then
			return nil, prim_name .. ": columns[" .. tostring(i) .. "] must be a table"
		end
		local c = col --: any
		if type(c.key) ~= "string" then
			return nil, prim_name .. ": columns[" .. tostring(i) .. "].key must be a string"
		end
		if type(c.label) ~= "string" then
			return nil, prim_name .. ": columns[" .. tostring(i) .. "].label must be a string"
		end
		if type(c.type) ~= "string" then
			return nil, prim_name .. ": columns[" .. tostring(i) .. "].type must be a known column type"
		end
		local ct = c.type --: string
		if not COLUMN_TYPES[ct] then
			return nil, prim_name .. ": columns[" .. tostring(i) .. "].type must be one of "
				.. "(string|number|bytes|duration|timestamp|status|code|link)"
		end
	end
	return true
end

local function check_kv_pairs(prim_name_a, pairs_)
	local prim_name = tostring(prim_name_a)
	local pl = pairs_ --: any
	for i, p in ipairs(pl) do
		if type(p) ~= "table" then
			return nil, prim_name .. ": pairs[" .. tostring(i) .. "] must be a table"
		end
		local pt = p --: any
		if type(pt.key) ~= "string" then
			return nil, prim_name .. ": pairs[" .. tostring(i) .. "].key must be a string"
		end
		if pt.value == nil then
			return nil, prim_name .. ": pairs[" .. tostring(i) .. "].value missing"
		end
		-- value must itself be a primitive
		local ok, err = validate_primitive(pt.value, prim_name .. ".pairs[" .. tostring(i) .. "].value")
		if not ok then return nil, err end
	end
	return true
end

local function check_form_fields(prim_name_a, fields)
	local prim_name = tostring(prim_name_a)
	local fl = fields --: any
	for i, f in ipairs(fl) do
		if type(f) ~= "table" then
			return nil, prim_name .. ": fields[" .. tostring(i) .. "] must be a table"
		end
		local ft = f --: any
		if type(ft.name) ~= "string" then
			return nil, prim_name .. ": fields[" .. tostring(i) .. "].name must be a string"
		end
		if type(ft.label) ~= "string" then
			return nil, prim_name .. ": fields[" .. tostring(i) .. "].label must be a string"
		end
		if type(ft.type) ~= "string" then
			return nil, prim_name .. ": fields[" .. tostring(i) .. "].type must be a known field type"
		end
		local fty = ft.type --: string
		if not FIELD_TYPES[fty] then
			return nil, prim_name .. ": fields[" .. tostring(i) .. "].type must be a known field type"
		end
	end
	return true
end

local function recurse_field(prim_name_a, field_a, val, mode_a)
	local prim_name = tostring(prim_name_a)
	local field     = tostring(field_a)
	local mode      = tostring(mode_a)
	if mode == "primitive" then
		return validate_primitive(val, prim_name .. "." .. field)
	elseif mode == "primitive_opt" then
		if val == nil then return true end
		return validate_primitive(val, prim_name .. "." .. field)
	elseif mode == "primitive_list" then
		if type(val) ~= "table" then
			return nil, prim_name .. "." .. field .. " must be an array"
		end
		local arr = val --: unknown[]
		for i, item in ipairs(arr) do
			local ok, err = validate_primitive(item, prim_name .. "." .. field .. "[" .. tostring(i) .. "]")
			if not ok then return nil, err end
		end
		return true
	elseif mode == "tab_list" then
		if type(val) ~= "table" then
			return nil, prim_name .. "." .. field .. " must be an array"
		end
		local arr = val --: any
		for i, t in ipairs(arr) do
			if type(t) ~= "table" then
				return nil, prim_name .. ".tabs[" .. tostring(i) .. "] must be a table"
			end
			local tt = t --: any
			if type(tt.label) ~= "string" then
				return nil, prim_name .. ".tabs[" .. tostring(i) .. "].label must be a string"
			end
			local ok, err = validate_primitive(tt.body, prim_name .. ".tabs[" .. tostring(i) .. "].body")
			if not ok then return nil, err end
		end
		return true
	end
	return nil, prim_name .. ": unknown recurse mode '" .. tostring(mode) .. "'"
end

local function validate_cite(cite, ctx_a)
	local ctx = tostring(ctx_a)
	if type(cite) ~= "table" then
		return nil, ctx .. ": cite must be an array of cite entries"
	end
	local arr = cite --: any
	for i, entry in ipairs(arr) do
		if type(entry) ~= "table" then
			return nil, ctx .. ": cite[" .. tostring(i) .. "] must be a table"
		end
		local e = entry --: any
		local kind = e.kind
		if type(kind) ~= "string" then
			return nil, ctx .. ": cite[" .. tostring(i) .. "].kind must be a string"
		end
		local k = kind --: string
		if not CITE_KINDS[k] then
			return nil, ctx .. ": cite[" .. tostring(i) .. "].kind '" .. k .. "' is not a known cite kind"
		end
	end
	return true
end

-- Forward-declared above
validate_primitive = function(prim, ctx_a)
	local ctx = tostring(ctx_a)
	if type(prim) ~= "table" then
		return nil, ctx .. ": primitive must be a table"
	end
	local p = prim --: any
	local ty = p.type
	if type(ty) ~= "string" then
		return nil, ctx .. ": primitive.type must be a string"
	end
	local ty_s = ty --: string
	if not PRIMITIVES[ty_s] then
		return nil, ctx .. ": '" .. ty_s .. "' is not a known primitive"
	end
	local spec = PSPEC[ty_s]
	if not spec then
		-- All known primitives must be in PSPEC; missing entry = bug, not user error.
		return nil, ctx .. ": no validation spec for primitive '" .. ty_s .. "'"
	end
	local spec_t = --[[:! { required: { [string]: string }, check_columns: boolean | nil, check_kv_pairs: boolean | nil, check_form_fields: boolean | nil, recurse: { [string]: string } | nil }]] spec
	-- Required fields
	for field, expected in pairs(spec_t.required) do
		if p[field] == nil then
			return nil, ctx .. " (" .. ty_s .. "): missing required field '" .. tostring(field) .. "'"
		end
		local ok, err = check_field(ty_s, field, p[field], expected)
		if not ok then return nil, ctx .. ": " .. tostring(err) end
	end
	-- Per-primitive structural checks
	if spec_t.check_columns and p.columns then
		local ok, err = check_columns(ty_s, p.columns)
		if not ok then return nil, ctx .. ": " .. tostring(err) end
	end
	if spec_t.check_kv_pairs and p.pairs then
		local ok, err = check_kv_pairs(ty_s, p.pairs)
		if not ok then return nil, ctx .. ": " .. tostring(err) end
	end
	if spec_t.check_form_fields and p.fields then
		local ok, err = check_form_fields(ty_s, p.fields)
		if not ok then return nil, ctx .. ": " .. tostring(err) end
	end
	-- Recursion
	if spec_t.recurse then
		for field, mode in pairs(spec_t.recurse) do
			local v = p[field]
			if not (mode == "primitive_opt" and v == nil) then
				local ok, err = recurse_field(ty_s, field, v, mode)
				if not ok then return nil, ctx .. ": " .. tostring(err) end
			end
		end
	end
	-- Optional cite on the primitive itself
	if p.cite ~= nil then
		local ok, err = validate_cite(p.cite, ctx .. "." .. ty_s)
		if not ok then return nil, err end
	end
	-- Optional style validation on text and button primitives
	local style = p.style
	if ty_s == "text" and style ~= nil then
		if type(style) ~= "string" then
			return nil, ctx .. ": text.style must be a string"
		end
		local sty = style --: string
		if not TEXT_STYLES[sty] then
			return nil, ctx .. ": text.style '" .. sty .. "' is not a known style"
		end
	end
	if ty_s == "button" and style ~= nil then
		if type(style) ~= "string" then
			return nil, ctx .. ": button.style must be a string"
		end
		local sty = style --: string
		if not BUTTON_STYLES[sty] then
			return nil, ctx .. ": button.style '" .. sty .. "' is not a known style"
		end
	end
	return true
end

function M.validate(envelope)
	if type(envelope) ~= "table" then
		return nil, "envelope: must be a table"
	end
	local e = envelope --: any
	if type(e.ok) ~= "boolean" then
		return nil, "envelope: 'ok' must be a boolean"
	end
	if e.ok then
		if e.body == nil then
			return nil, "envelope: ok envelope must have a 'body'"
		end
		local ok, err = validate_primitive(e.body, "body")
		if not ok then return nil, err end
		if e.cite ~= nil then
			local cok, cerr = validate_cite(e.cite, "envelope")
			if not cok then return nil, cerr end
		end
		if e.ttl_ms ~= nil and type(e.ttl_ms) ~= "number" then
			return nil, "envelope: ttl_ms must be a number"
		end
	else
		if type(e.error) ~= "string" then
			return nil, "envelope: err envelope must have an 'error' string"
		end
		if e.body ~= nil then
			local ok, err = validate_primitive(e.body, "body")
			if not ok then return nil, err end
		end
		if e.cite ~= nil then
			local cok, cerr = validate_cite(e.cite, "envelope")
			if not cok then return nil, cerr end
		end
	end
	return true
end

-- Expose validate_primitive for tests / callers that want to validate a bare
-- primitive without wrapping in an envelope.
M.validate_primitive = function(prim) return validate_primitive(prim, "primitive") end
M.validate_cite      = function(cite) return validate_cite(cite, "cite") end

return M
