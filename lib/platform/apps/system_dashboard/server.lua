-- lib/platform/apps/system_dashboard/server.lua
-- System Dashboard HTTP BFF.
--
-- M.create(caps, opts) -> { handler }
--
-- Routes:
--   GET  /                        -> static/index.html
--   GET  /static/<path>           -> tarball static file
--   GET  /api/search?q=<q>        -> JSON alias results (limit 20)
--   GET  /api/packs               -> JSON pack metadata
--   GET  /api/cap_info?alias=&action= -> cap declarations for an action
--   POST /api/execute             -> attenuate caps then invoke action

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local json       = require("lib.format.json") --: any
local search     = require("lib.platform.apps.system_dashboard.search")
local packs      = require("lib.platform.apps.system_dashboard.packs")
local cap_dispatch = require("lib.platform.cap_dispatch")
local output_mod = require("lib.platform.apps.system_dashboard.output") --: any

-- Streaming primitive set. When `exec.output.type` is one of these the
-- dispatcher takes the SSE path instead of returning a JSON envelope.
local STREAMING_TYPES = { log_stream = true, live_table = true, event_stream = true }

-- Default columns for log_stream when the action does not specify them.
local DEFAULT_LOG_STREAM_COLUMNS = {
	{ key = "time",    label = "Time",    type = "timestamp" },
	{ key = "level",   label = "Level",   type = "string" },
	{ key = "message", label = "Message", type = "string" },
}

local M = {}

local MIME = {
	html = "text/html; charset=utf-8",
	js   = "application/javascript; charset=utf-8",
	css  = "text/css; charset=utf-8",
	json = "application/json",
	png  = "image/png",
	ico  = "image/x-icon",
	svg  = "image/svg+xml",
}

--: (string) -> string
local function ext_of(path)
	return path:match("%.([^./]+)$") or ""
end

-- Percent-decode a single hex escape like "2F" -> "/".
local pct_decode = function(h) --: (string) -> string
	return string.char(tonumber(h, 16) or 0x3F)
end

-- Parse ?key=value&... from a query string.
--: (string) -> { [string]: string }
local function parse_qs(qs)
	local params = {} --: { [string]: string }
	if qs == "" then return params end
	for kv in qs:gmatch("[^&]+") do
		local k, v = kv:match("^([^=]+)=?(.*)")
		if k and v then
			local v1 = (v:gsub("%%(%x%x)", pct_decode))
			local v2 = (v1:gsub("+", " "))
			params[k] = v2
		end
	end
	return params
end

-- Serve a static file from the tarball via caps.self.entry.
--: (any, any, any) -> boolean | nil
local function serve_static(self_cap, req, res)
	if not self_cap then return nil end
	local req_path = tostring(req.path or "/")
	local tarball_path
	if req_path == "/" then
		tarball_path = "static/index.html"
	elseif req_path:sub(1, 8) == "/static/" then
		tarball_path = "static" .. req_path:sub(8)
	else
		return nil
	end
	local content = self_cap.entry(tarball_path)
	if not content then return nil end
	local ext = ext_of(tarball_path)
	res.status = 200
	res.headers["Content-Type"] = MIME[ext] or "application/octet-stream"
	res.body = content
	return true
end

-- Build a lookup table from alias id -> alias for fast /api/execute dispatch.
--: ({ [string]: any }) -> { [string]: any }
local function build_alias_index(aliases)
	local idx = {} --: { [string]: any }
	for _, a in ipairs(aliases) do
		if a.id then idx[a.id] = a end
	end
	return idx
end

-- Find the first cap in the caps table whose _type matches cap_type.
--: (any, string) -> any | nil
local function find_cap_by_type(caps, cap_type)
	for _, c in pairs(caps) do
		if type(c) == "table" and c._type == cap_type then
			return c
		end
	end
	return nil
end

-- Strip trailing newline for text-shaped output adapters.
--: (string) -> string
local function rstrip_newline(s)
	local out, _ = s:gsub("\n+$", "")
	return out
end

-- Split a string into lines (no trailing empty line).
--: (string) -> string[]
local function split_lines(s)
	local lines = {} --: string[]
	for line in s:gmatch("[^\n]+") do
		lines[#lines + 1] = line
	end
	return lines
end

-- Tokenise a line by whitespace runs.
--: (string) -> string[]
local function split_ws(line)
	local toks = {} --: string[]
	for tok in line:gmatch("%S+") do
		toks[#toks + 1] = tok
	end
	return toks
end

-- Determine output shape spec from action.exec.output. Accepts:
--   nil / "text" / "code" / "key_value" / table with .type
--: (any) -> { [string]: any }
local function output_spec_of(exec_info)
	local exec = exec_info --: any
	local o = exec and exec.output
	if o == nil then return { type = "text" } end
	if type(o) == "string" then return { type = o } end
	if type(o) == "table" then
		local ot = o --: any
		if type(ot.type) ~= "string" then
			return { type = "text" }
		end
		return ot
	end
	return { type = "text" }
end

-- Build a default cite list from exec_info + cap type. Best-effort: caps don't
-- expose root paths, so use what we can read off the action declaration.
--: (any, string) -> any[]
local function make_cite(exec_info, cap_type)
	local exec = exec_info --: any
	if cap_type == "shell" then
		return { output_mod.cite_command({ tostring(exec.args or "") }) }
	end
	if cap_type == "exec" then
		local argv = {} --: any
		argv[1] = tostring(exec.binary or "")
		local args = exec.args
		if type(args) == "table" then
			local args_t = args --: any[]
			for i, a in ipairs(args_t) do argv[i + 1] = tostring(a) end
		end
		return { output_mod.cite_exec(argv) }
	end
	if cap_type == "registry" then
		local op = exec.op
		local subkey = tostring(exec.subkey or "")
		local name_raw = exec.name
		local name = type(name_raw) == "string" and name_raw or ""
		if op == "get" or op == "set" then
			local path = subkey
			if name ~= "" then
				if subkey ~= "" then
					path = subkey .. "\\" .. name
				else
					path = name
				end
			end
			local val = nil --: any
			if op == "set" then val = tostring(exec.value or "") end
			return { output_mod.cite_registry(path, val) }
		end
		return { output_mod.cite_registry_key(subkey) }
	end
	return {}
end

-- Build the *empty* schema body for a streaming primitive. The streamer sends
-- this as the first SSE event so the frontend can render the table/log frame
-- skeleton immediately. Frame data arrives in subsequent events.
--: (any) -> any
local function build_stream_schema(spec)
	local s = spec --: any
	local ty = s.type
	if ty == "log_stream" then
		return {
			type = "log_stream",
			frame_type = "log",
			columns = s.columns or DEFAULT_LOG_STREAM_COLUMNS,
		}
	end
	if ty == "live_table" then
		return {
			type = "live_table",
			frame_type = "table",
			columns = s.columns,
			key = s.key,
			row_actions = s.row_actions,
		}
	end
	if ty == "event_stream" then
		return { type = "event_stream", frame_type = "event" }
	end
	return nil
end

-- Pump a streaming sub_cap iterator into the SSE response.
--   sub_cap.run_stream(args) -> iter | nil, err
-- Frames are JSON-encoded as { type="frame", frame=<payload> } and assigned
-- monotonic ids starting at 1. A ring buffer of `replay_buffer` size is kept
-- for Last-Event-ID resume.
--: (any, any, any, any, string, any, any) -> nil
local function pump_stream(spec, sub_cap, exec_info, time_cap, cap_type, req, res)
	local s = spec --: any
	local cite = make_cite(exec_info, cap_type)

	-- 1. Set headers first; http_server cap writes them on first send_event.
	res.status = 200
	res.headers["Content-Type"]  = "text/event-stream"
	res.headers["Cache-Control"] = "no-cache"
	res.headers["Connection"]    = "keep-alive"

	-- 2. Build & validate the schema envelope.
	local schema_body = build_stream_schema(spec)
	if not schema_body then
		local env_err = output_mod.err("unknown streaming output type: " .. tostring(s.type))
		res.send_event(json.encode(env_err), { event = "error" })
		res.close()
		return
	end
	local schema_env = output_mod.ok(schema_body, { cite = cite })
	local sok, serr = output_mod.validate(schema_env)
	if not sok then
		local env_err = output_mod.err("invalid stream schema: " .. tostring(serr))
		res.send_event(json.encode(env_err), { event = "error" })
		res.close()
		return
	end

	-- 3. Emit schema as id=0. ALWAYS sent regardless of Last-Event-ID — the
	--    frontend uses it to construct the renderer skeleton.
	local ok_send = res.send_event(json.encode(schema_env), { id = 0, event = "schema" })
	if not ok_send then res.close(); return end

	-- 4. Open the stream. shell is the only cap with run_stream in this phase.
	if cap_type ~= "shell" then
		res.send_event(json.encode(output_mod.err(
			"streaming not implemented for cap type: " .. cap_type)),
			{ event = "error" })
		res.close()
		return
	end
	local iter, ierr = sub_cap.run_stream(exec_info.args)
	if not iter then
		res.send_event(json.encode(output_mod.err(tostring(ierr or "run_stream failed"))),
			{ event = "error" })
		res.close()
		return
	end

	-- 5. Ring buffer for Last-Event-ID resume.
	local replay_size = 256 --: integer
	local rb = s.replay_buffer
	if type(rb) == "number" then
		local rb_n = rb --: number
		if rb_n > 0 then replay_size = math.floor(rb_n) end
	end
	local ring = {} --: any
	local ring_count = 0
	local last_id = 0
	--: (integer, string) -> nil
	local function ring_push(id, payload)
		ring_count = ring_count + 1
		ring[((ring_count - 1) % replay_size) + 1] = { id = id, payload = payload }
	end
	--: () -> integer
	local function ring_oldest_id()
		local count = ring_count --: integer
		if count == 0 then return 0 end
		local r = ring --: any
		if count <= replay_size then return r[1].id end
		-- Oldest is at slot (count % replay_size) + 1.
		local idx = (count % replay_size) + 1
		return r[idx].id
	end

	-- 6. Last-Event-ID handling. Replay buffered frames newer than the client's
	--    last id. If the requested id is older than what the buffer holds we
	--    cannot replay everything missed: emit a `gap` event to tell the
	--    client to drop state, then resume live.
	local resume_from
	local lei_str = req.last_event_id
	if type(lei_str) == "string" then
		local n = tonumber(lei_str)
		if n then resume_from = math.floor(n) end
	end
	if resume_from ~= nil then
		local rfrom = resume_from --: integer
		-- Pull replayable entries.
		local oldest = ring_oldest_id()
		if rfrom < oldest and ring_count > 0 then
			-- Buffer doesn't cover the gap.
			local gap_ok = res.send_event("{}", { event = "gap" })
			if not gap_ok then iter:close(); res.close(); return end
		else
			local r = ring --: any
			for i = 1, math.min(ring_count, replay_size) do
				local entry = r[i]
				if entry and entry.id > rfrom then
					local rok = res.send_event(entry.payload, { id = entry.id })
					if not rok then iter:close(); res.close(); return end
				end
			end
		end
	end

	-- Frame format: "jsonl" decodes each line as JSON and forwards the parsed
	-- object as the frame body. Required for live_table / event_stream demos
	-- (their frame shapes are structured, not flat strings). Default (nil)
	-- preserves the legacy log_stream message-wrapping behaviour.
	local frame_format = s.frame_format
	if frame_format ~= nil and frame_format ~= "jsonl" then
		res.send_event(json.encode(output_mod.err(
			"unknown frame_format: " .. tostring(frame_format))),
			{ event = "error" })
		iter:close()
		res.close()
		return
	end

	-- 7. Live pump.
	while true do
		local line, lerr = iter()
		if lerr then
			res.send_event(json.encode(output_mod.err(tostring(lerr))), { event = "error" })
			iter:close()
			res.close()
			return
		end
		if line == nil then break end -- EOF

		local frame_payload --: any
		local skip = false
		if frame_format == "jsonl" then
			-- json.decode returns (nil, errmsg) on parse failure, but may also
			-- raise on FFI corner cases; pcall guards both paths.
			local ok_dec, decoded, derr = pcall(json.decode, tostring(line))
			local fail_msg --: string | nil
			if not ok_dec then
				fail_msg = tostring(decoded)
			elseif decoded == nil then
				fail_msg = tostring(derr or "decode returned nil")
			end
			if fail_msg ~= nil then
				local err_ok = res.send_event(json.encode(output_mod.err(
					"frame decode failed: " .. fail_msg)),
					{ event = "error" })
				if not err_ok then iter:close(); res.close(); return end
				skip = true
			else
				frame_payload = decoded
			end
		elseif s.type == "log_stream" then
			local now
			if time_cap then now = time_cap.now() end
			frame_payload = {
				time    = now,
				level   = "info",
				message = tostring(line),
			}
		else
			-- live_table / event_stream without frame_format: raw line passthrough
			-- as a placeholder. Authors should set frame_format = "jsonl" and
			-- emit structured frames.
			frame_payload = { message = tostring(line) }
		end
		if not skip then
			last_id = last_id + 1
			local payload = json.encode({ type = "frame", frame = frame_payload })
			ring_push(last_id, payload)
			local ok_f, _ = res.send_event(payload, { id = last_id })
			if not ok_f then
				iter:close()
				res.close()
				return
			end
		end
	end

	-- 8. Stream end.
	res.send_event("{}", { event = "end" })
	res.close()
end

-- Adapt a raw cap result into a primitive body.
-- raw is the value returned by the cap (string for shell/exec/registry get,
-- list of records for list_values/list_keys, etc.).
--: (any, any) -> (any | nil, string | nil)
local function adapt_body(spec, raw)
	local s = spec --: any
	local ty = s.type
	if ty == "text" then
		local txt
		if type(raw) == "string" then
			txt = rstrip_newline(raw)
		elseif type(raw) == "table" then
			-- list_keys returns string[]; render as joined lines.
			local r = raw --: any[]
			local parts = {} --: any
			for i, v in ipairs(r) do parts[i] = tostring(v) end
			txt = table.concat(parts, "\n")
		else
			txt = tostring(raw)
		end
		return { type = "text", text = txt }
	end
	if ty == "code" then
		local txt = type(raw) == "string" and rstrip_newline(raw) or tostring(raw)
		return { type = "code", text = txt, lang = s.lang }
	end
	if ty == "key_value" then
		if type(raw) ~= "table" then
			return nil, "key_value: cap result must be a list of records, got " .. type(raw)
		end
		local list = raw --: any[]
		local pairs_ = {} --: any[]
		for i, rec in ipairs(list) do
			if type(rec) ~= "table" then
				return nil, "key_value: list[" .. tostring(i) .. "] must be a record"
			end
			local r = rec --: any
			local k = r.name or r.key
			local v = r.value
			if v == nil then v = r.type end
			pairs_[#pairs_ + 1] = {
				key   = tostring(k or ("item_" .. tostring(i))),
				value = { type = "text", text = tostring(v == nil and "" or v) },
			}
		end
		return { type = "key_value", pairs = pairs_ }
	end
	if ty == "table" then
		local cols = s.columns
		if type(cols) ~= "table" then
			return nil, "table: spec.columns missing"
		end
		local cols_t = cols --: any[]
		local rows = {} --: any[]
		if type(raw) == "string" then
			local lines = split_lines(raw)
			local start = 1
			if s.skip_header then start = 2 end
			for i = start, #lines do
				local line = lines[i]
				local toks = split_ws(line)
				local row = {} --: { [string]: any }
				for ci, col in ipairs(cols_t) do
					local c = col --: any
					local key = tostring(c.key)
					-- Last column captures the remainder (mountpoints with spaces, etc.).
					if ci == #cols_t and #toks > #cols_t then
						local extra = {} --: any
						local n = 0
						for j = ci, #toks do n = n + 1; extra[n] = toks[j] end
						row[key] = table.concat(extra, " ")
					else
						row[key] = toks[ci] or ""
					end
				end
				rows[#rows + 1] = row
			end
		elseif type(raw) == "table" then
			local r = raw --: any[]
			for _, item in ipairs(r) do
				if type(item) ~= "table" then
					return nil, "table: row must be a record"
				end
				rows[#rows + 1] = item
			end
		else
			return nil, "table: cap result must be a string or list, got " .. type(raw)
		end
		-- Normalise columns to satisfy validator: every entry must have key/label/type.
		local norm_cols = {} --: any[]
		for _, col in ipairs(cols_t) do
			local c = col --: any
			norm_cols[#norm_cols + 1] = {
				key      = tostring(c.key or ""),
				label    = tostring(c.label or c.key or ""),
				type     = tostring(c.type or "string"),
				sortable = c.sortable,
				align    = c.align,
			}
		end
		return { type = "table", columns = norm_cols, rows = rows }
	end
	if ty == "status_badge" then
		local raw_str = type(raw) == "string" and raw or tostring(raw)
		local on_match = s.on_match --: any
		local default  = s.default  --: any
		if on_match and type(on_match.pattern) == "string" then
			if raw_str:find(on_match.pattern) then
				return { type = "status_badge",
					label = tostring(on_match.label or ""),
					state = tostring(on_match.state or "info") }
			end
		end
		if default then
			return { type = "status_badge",
				label = tostring(default.label or ""),
				state = tostring(default.state or "unknown") }
		end
		return { type = "status_badge", label = raw_str, state = "unknown" }
	end
	return nil, "unknown output spec type: " .. tostring(ty)
end

-- Build an envelope for a successful cap result. Returns the envelope table.
--: (any, any, string) -> any
local function adapt_envelope(exec_info, raw, cap_type)
	local spec = output_spec_of(exec_info)
	local body, err = adapt_body(spec, raw)
	if not body then
		return output_mod.err(tostring(err))
	end
	local cite = make_cite(exec_info, cap_type)
	return output_mod.ok(body, { cite = cite })
end

-- Encode an envelope as JSON, validating first; on validation failure replace
-- with an err envelope so the client always sees a valid shape.
--: (any) -> string
local function encode_envelope(env)
	local ok_v, err_v = output_mod.validate(env)
	if not ok_v then
		env = output_mod.err("invalid envelope: " .. tostring(err_v))
	end
	return json.encode(env)
end

-- Handle API routes.
--: (any, any, any) -> boolean | nil
local function handle_api(state, req, res)
	local path   = tostring(req.path or "/")
	local method = tostring(req.method or "GET"):upper()

	-- POST /api/execute
	if path == "/api/execute" and method == "POST" then
		local body_str = type(req.body) == "string" and req.body or ""
		local ok, body = pcall(json.decode, body_str)
		if not ok or type(body) ~= "table" then
			res.status = 400
			res.headers["Content-Type"] = MIME.json
			res.body = encode_envelope(output_mod.err("invalid JSON body"))
			return true
		end
		local alias_id     = body.alias_id
		local action_index = body.action_index
		if type(alias_id) ~= "string" or type(action_index) ~= "number" then
			res.status = 400
			res.headers["Content-Type"] = MIME.json
			res.body = encode_envelope(output_mod.err("alias_id (string) and action_index (number) required"))
			return true
		end
		local alias = state.alias_index[alias_id]
		if not alias then
			res.status = 404
			res.headers["Content-Type"] = MIME.json
			res.body = encode_envelope(output_mod.err("unknown alias_id"))
			return true
		end
		-- action_index is 0-based from the frontend
		local idx = math.floor(action_index) + 1
		local actions = alias.actions
		if type(actions) ~= "table" or not actions[idx] then
			res.status = 404
			res.headers["Content-Type"] = MIME.json
			res.body = encode_envelope(output_mod.err("action_index out of range"))
			return true
		end
		local action = actions[idx]
		-- Attenuate each declared cap to produce sub-caps keyed by local name.
		local attenuated = {} --: { [string]: any }
		local action_caps = type(action.caps) == "table" and action.caps or {}
		for name_k, decl_v in pairs(action_caps) do
			local name = tostring(name_k)
			local decl = --[[:! any]] decl_v
			local parent = find_cap_by_type(state.caps, decl.type)
			if not parent then
				res.status = 200
				res.headers["Content-Type"] = MIME.json
				res.body = encode_envelope(output_mod.err("no parent cap of type " .. tostring(decl.type)))
				return true
			end
			local sub, err = parent.attenuate(decl)
			if not sub then
				res.status = 200
				res.headers["Content-Type"] = MIME.json
				res.body = encode_envelope(output_mod.err(tostring(err or ("attenuate failed for cap " .. name))))
				return true
			end
			attenuated[name] = sub
		end
		-- Invoke via action.exec
		local exec_info = action.exec
		if type(exec_info) ~= "table" then
			res.status = 200
			res.headers["Content-Type"] = MIME.json
			res.body = encode_envelope(output_mod.err("action.exec missing or not a table"))
			return true
		end
		local sub_cap = attenuated[exec_info.cap]
		if not sub_cap then
			res.status = 200
			res.headers["Content-Type"] = MIME.json
			res.body = encode_envelope(output_mod.err("action.exec references unknown cap name: " .. tostring(exec_info.cap)))
			return true
		end
		local cap_type = tostring(sub_cap._type)
		-- Streaming branch: when the action's output type is a streaming
		-- primitive, switch to SSE. Pump runs synchronously inside the
		-- handler — the http_server cap streams frames as they're produced.
		local stream_spec = output_spec_of(exec_info)
		if STREAMING_TYPES[stream_spec.type] then
			pump_stream(stream_spec, sub_cap, exec_info, state.time_cap, cap_type, req, res)
			return true
		end
		local VTYPE_MAP = { REG_SZ = 1, REG_EXPAND_SZ = 2, REG_DWORD = 4, REG_MULTI_SZ = 7 }
		local raw, err
		if cap_type == "shell" then
			raw, err = sub_cap.run(exec_info.args)
		elseif cap_type == "exec" then
			raw, err = sub_cap.exec(exec_info.binary, exec_info.args)
		elseif cap_type == "registry" then
			local op = exec_info.op
			if op == "get" then
				raw, err = sub_cap.get(exec_info.subkey or "", exec_info.name)
			elseif op == "set" then
				local vtype_str = exec_info.vtype or "REG_SZ"
				local vtype_int = VTYPE_MAP[vtype_str]
				if not vtype_int then
					res.status = 200
					res.headers["Content-Type"] = MIME.json
					res.body = encode_envelope(output_mod.err("unknown vtype: " .. tostring(vtype_str)))
					return true
				end
				raw, err = sub_cap.set(exec_info.subkey or "", exec_info.name, exec_info.value, vtype_int)
			elseif op == "list_keys" then
				raw, err = sub_cap.list_keys(exec_info.subkey or "")
			elseif op == "list_values" then
				raw, err = sub_cap.list_values(exec_info.subkey or "")
			else
				res.status = 200
				res.headers["Content-Type"] = MIME.json
				res.body = encode_envelope(output_mod.err("unknown registry op: " .. tostring(op)))
				return true
			end
		else
			res.status = 200
			res.headers["Content-Type"] = MIME.json
			res.body = encode_envelope(output_mod.err("unsupported cap type: " .. cap_type))
			return true
		end
		if raw == nil then
			res.status = 200
			res.headers["Content-Type"] = MIME.json
			res.body = encode_envelope(output_mod.err(err or "exec failed"))
			return true
		end
		local env = adapt_envelope(exec_info, raw, cap_type)
		res.status = 200
		res.headers["Content-Type"] = MIME.json
		res.body = encode_envelope(env)
		return true
	end

	if method ~= "GET" then return nil end

	-- GET /api/cap_info?alias=<alias_id>&action=<action_index>
	if path == "/api/cap_info" or path:sub(1, 14) == "/api/cap_info?" then
		local raw_qs = req.query
		local qs --: { [string]: string }
		if type(raw_qs) == "table" then
			qs = raw_qs
		else
			local qpart = path:match("^[^?]*%??(.*)")
			qs = parse_qs(qpart or "")
		end
		local alias_id     = qs.alias
		local action_str   = qs.action
		if type(alias_id) ~= "string" or alias_id == "" or type(action_str) ~= "string" then
			res.status = 400
			res.headers["Content-Type"] = MIME.json
			res.body = json.encode({ ok = false, error = "alias (string) and action (number) query params required" })
			return true
		end
		local action_index = tonumber(action_str)
		if not action_index then
			res.status = 400
			res.headers["Content-Type"] = MIME.json
			res.body = json.encode({ ok = false, error = "action must be a number" })
			return true
		end
		local alias = state.alias_index[alias_id]
		if not alias then
			res.status = 404
			res.headers["Content-Type"] = MIME.json
			res.body = json.encode({ ok = false, error = "unknown alias" })
			return true
		end
		-- action_index is 0-based from the frontend
		local idx = math.floor(action_index) + 1
		local actions = alias.actions
		if type(actions) ~= "table" or not actions[idx] then
			res.status = 404
			res.headers["Content-Type"] = MIME.json
			res.body = json.encode({ ok = false, error = "action_index out of range" })
			return true
		end
		local action = actions[idx]
		local cap_entries = {} --: any
		local action_caps = type(action.caps) == "table" and action.caps or {}
		for name_k, decl_v in pairs(action_caps) do
			local decl = --[[:! any]] decl_v
			cap_entries[#cap_entries + 1] = {
				name   = name_k,
				type   = decl.type,
				reason = decl.reason,
				risk   = cap_dispatch.risk(decl),
			}
		end
		local exec_args --: any
		if type(action.exec) == "table" then
			exec_args = action.exec.args
		end
		res.status = 200
		res.headers["Content-Type"] = MIME.json
		res.body = json.encode({
			label     = action.label,
			exec_args = exec_args,
			caps      = cap_entries,
		})
		return true
	end

	if path == "/api/packs" or path:sub(1, 11) == "/api/packs?" then
		res.status = 200
		res.headers["Content-Type"] = MIME.json
		res.body = json.encode(state.pack_meta)
		return true
	end

	if path == "/api/search" or path:sub(1, 12) == "/api/search?" then
		local raw_qs = req.query
		local qs --: { [string]: string }
		if type(raw_qs) == "table" then
			qs = raw_qs
		else
			local qpart = path:match("^[^?]*%??(.*)")
			qs = parse_qs(qpart or "")
		end
		local q = qs.q or ""
		local results
		if q == "" then
			results = {}
			local aliases = state.aliases
			for i = 1, math.min(20, #aliases) do
				local a = aliases[i]
				local r = {}
				for k, v in pairs(a) do r[k] = v end
				r.score = 0
				results[#results + 1] = r
			end
		else
			results = search.search(state.aliases, q, 20)
		end
		res.status = 200
		res.headers["Content-Type"] = MIME.json
		res.body = json.encode(results)
		return true
	end

	return nil
end

function M.create(caps, opts)
	local caps_t     = caps  --: any
	local self_cap   = caps_t and caps_t.self
	local user_packs = caps_t and caps_t.user_packs
	local stdout_cap = caps_t and caps_t.stdout

	local no_self = {
		entries = function() return {} end,
		entry   = function() return nil end,
	}
	local effective_self = self_cap or no_self

	local builtin_aliases, builtin_meta = packs.load_builtin(effective_self, stdout_cap)
	local user_aliases,    user_meta    = packs.load_user(user_packs, stdout_cap)
	local merged = packs.merge(builtin_aliases, user_aliases)

	local all_meta = {}
	for _, m in ipairs(builtin_meta) do all_meta[#all_meta + 1] = m end
	for _, m in ipairs(user_meta)    do all_meta[#all_meta + 1] = m end

	if stdout_cap then
		stdout_cap.write("system_dashboard: loaded " .. #merged
			.. " aliases from " .. #all_meta .. " packs\n")
	end

	local state = {
		aliases      = merged,
		alias_index  = build_alias_index(merged),
		pack_meta    = all_meta,
		caps         = caps_t,
		time_cap     = caps_t and caps_t.time,
	}

	local function handler(req, res)
		res.headers = res.headers or {}
		if handle_api(state, req, res) then return true end
		if serve_static(self_cap, req, res) then return true end
		res.status = 404
		res.headers["Content-Type"] = "text/plain; charset=utf-8"
		res.body = "not found"
		return true
	end

	return { handler = handler }
end

return M
